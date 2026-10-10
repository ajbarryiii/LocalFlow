import AVFoundation
import Foundation

/// The session's microphone: one `AVAudioEngine` input tap for the whole session, feeding a
/// `CapturePipeline` (HostCore) with each buffer's capture time. The pipeline trims frames captured
/// outside the recording before converting the rest to 16 kHz mono, with a converter replaced at every
/// dictation boundary; every other buffer is dropped in the callback unconverted. Large I/O and tap
/// buffers keep an idle session from waking the app often (`AudioSessionTuning`). The input follows the
/// "Use iPhone microphone" choice (`MicrophoneRoute`). Audio is never written to disk or logged.
@MainActor
final class MicrophoneCapture: HostCapture {
    /// The audio session was interrupted: the session must end.
    var onInterruption: (@MainActor () -> Void)?
    /// Engine `generation` stopped or its configuration changed, within a surviving audio session.
    var onFailure: (@MainActor (_ generation: UInt64) -> Void)?
    /// Media services were reset: this object no longer owns an audio session, and the session must end.
    var onMediaServicesReset: (@MainActor () -> Void)?
    /// Every engine start reports what was requested and what iOS granted.
    var onConfigured: (@MainActor (CaptureConfiguration) -> Void)?
    /// The input in use changed or became known; nil once capture stops. Content-free.
    var onInputChanged: (@MainActor (InputPortKind?) -> Void)?
    /// Whether the built-in microphone choice is in effect changed. Content-free.
    var onRoutingChanged: (@MainActor (MicrophoneRouting) -> Void)?
    /// "Use iPhone microphone": the desired choice, kept apart from the one the session was configured
    /// with (`MicrophoneRouter`).
    let router = MicrophoneRouter()
    private let routeSession = SystemAudioRouteSession()

    private(set) var engineGeneration: UInt64 = 0
    private let buffer: DictationSampleBuffer
    private let deliver: @Sendable (CaptureEvent) -> Void
    private var engine: AVAudioEngine?
    private var pipeline: CapturePipeline<InputConverter>?
    /// This object activated the audio session and must deactivate it.
    private var activatedSession = false
    private var requested = AudioSessionTuning.Requested()
    private var engineObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []

    init(buffer: DictationSampleBuffer, deliver: @escaping @Sendable (CaptureEvent) -> Void) {
        self.buffer = buffer
        self.deliver = deliver
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                guard type == .began else { return }
                MainActor.assumeIsolated {
                    guard let self, self.activatedSession else { return }
                    self.onInterruption?()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaServicesWereReset() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.routeChanged() }
            },
        ]
    }

    var permission: CapturePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    var lastBufferAt: Date? { pipeline?.clock.lastBufferAt }

    func start() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try router.configureCategory(routeSession)
        requested = AudioSessionTuning.requestPreferences(on: session)
        try session.setActive(true)
        activatedSession = true
        applyInputChoice()
        do {
            try startEngine()
        } catch {
            stop()
            throw error
        }
    }

    /// A new engine inside the audio session this object already activated. Nothing is activated, so a
    /// session that iOS ended (an interruption) makes the engine start fail instead of reviving it from
    /// the background.
    func restart() throws {
        guard activatedSession else { throw CaptureError.noSession }
        tearDownEngine()
        try startEngine()
    }

    /// The microphone choice changed during a session in the foreground: the new category and input, then
    /// a new engine for the new input format, without deactivating the session.
    func reconfigure() throws {
        guard activatedSession else { throw CaptureError.noSession }
        tearDownEngine()
        try router.configureCategory(routeSession)
        applyInputChoice()
        try startEngine()
    }

    func stop() {
        tearDownEngine()
        onInputChanged?(nil)
        router.sessionEnded()
        onRoutingChanged?(router.routing)
        guard activatedSession else { return }
        activatedSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func recordingBoundary() {
        pipeline?.boundaryPassed()
    }

    var needsReconfiguration: Bool { activatedSession && router.needsReconfiguration }

    /// The applied choice's input, then mono input for the port now in use (the channel preference
    /// belongs to the port).
    private func applyInputChoice() {
        if router.applyInput(routeSession) { scheduleRoutingCheck() }
        AudioSessionTuning.preferMonoInput(on: AVAudioSession.sharedInstance())
        onRoutingChanged?(router.routing)
    }

    /// A request iOS answers with no route change at all is judged after `requestSettleTime`.
    private func scheduleRoutingCheck() {
        let requestID = router.requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + MicrophoneRouter.requestSettleTime) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activatedSession else { return }
                self.router.verify(self.routeSession, requestID: requestID)
                self.onRoutingChanged?(self.router.routing)
            }
        }
    }

    /// Headphones plugged in or out, AirPods connecting, or iOS answering a request: the router reads the
    /// route and, if the system moved the input off the built-in microphone, asks again. The engine's
    /// configuration-change report then rebuilds it for the new input (in the background too, within
    /// this session), through the usual grace period.
    private func routeChanged() {
        guard activatedSession else { return }
        // Only the applied choice: one deferred from the background must not move the input while the
        // category options still belong to the old one.
        if router.routeChanged(routeSession) { scheduleRoutingCheck() }
        AudioSessionTuning.preferMonoInput(on: AVAudioSession.sharedInstance())
        onInputChanged?(routeSession.currentInput)
        onRoutingChanged?(router.routing)
    }

    /// Every audio object is invalid, including the session this object activated, so there is nothing to
    /// deactivate and nothing to restart: ownership is dropped and only a new foreground `start()` can
    /// capture again (contract: "Media services reset ends the session").
    private func mediaServicesWereReset() {
        guard activatedSession else { return }
        activatedSession = false
        router.sessionEnded()
        onRoutingChanged?(router.routing)
        tearDownEngine()
        onMediaServicesReset?()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        // Numbered before its pipeline exists, so the pipeline's reports carry the engine they belong to.
        engineGeneration &+= 1
        let pipeline = CapturePipeline(buffer: buffer, converter: try InputConverter(input: format),
                                       engineGeneration: engineGeneration, deliver: deliver)
        let tapFrames = AudioSessionTuning.tapBufferFrames(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: format, block: Self.tapBlock(for: pipeline))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.pipeline = pipeline
        observe(engine, generation: engineGeneration)
        let session = AVAudioSession.sharedInstance()
        onConfigured?(CaptureConfiguration(
            source: "microphone", requestedIOBufferDuration: requested.ioBufferDuration,
            actualIOBufferDuration: session.ioBufferDuration, requestedSampleRate: requested.sampleRate,
            actualSampleRate: session.sampleRate, inputSampleRate: format.sampleRate, inputChannels: Int(format.channelCount),
            tapBufferFrames: Int(tapFrames), inputPort: routeSession.currentInput))
        onInputChanged?(routeSession.currentInput)
    }

    private func tearDownEngine() {
        for observer in engineObservers { NotificationCenter.default.removeObserver(observer) }
        engineObservers = []
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        pipeline = nil   // its converter, with any resampler state, goes with it
    }

    /// Every report carries the generation of the engine it was registered for, so one queued before a
    /// restart is ignored afterwards. The session core applies the grace period.
    private func observe(_ engine: AVAudioEngine, generation: UInt64) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let report: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.onFailure?(generation) }
        }
        engineObservers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: report),
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                // A route change usually brings a configuration change; this catches an engine that
                // stopped without one.
                MainActor.assumeIsolated {
                    guard let self, self.engineGeneration == generation, self.engine?.isRunning == false else { return }
                    self.onFailure?(generation)
                }
            },
        ]
    }

    // Built outside the main actor: the tap runs on an audio thread.
    nonisolated private static func tapBlock(for pipeline: CapturePipeline<InputConverter>) -> AVAudioNodeTapBlock {
        { buffer, time in pipeline.process(TapBuffer(pcm: buffer, time: time)) }
    }

    private enum CaptureError: Error { case noInput, noSession }
}

/// One tap buffer with its capture time. Slicing copies frames, so it allocates only while recording.
private struct TapBuffer: CaptureInput {
    let pcm: AVAudioPCMBuffer
    let hostTime: UInt64?
    let sampleTime: Int64?

    init(pcm: AVAudioPCMBuffer, time: AVAudioTime) {
        self.pcm = pcm
        hostTime = time.isHostTimeValid ? time.hostTime : nil
        sampleTime = time.isSampleTimeValid ? time.sampleTime : nil
    }

    private init(pcm: AVAudioPCMBuffer) {
        self.pcm = pcm
        hostTime = nil
        sampleTime = nil
    }

    var frameCount: Int { Int(pcm.frameLength) }
    var sampleRate: Double { pcm.format.sampleRate }

    func slice(_ frames: Range<Int>) -> TapBuffer? {
        if frames == 0..<frameCount { return self }
        guard !frames.isEmpty, frames.upperBound <= frameCount,
              let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: AVAudioFrameCount(frames.count)) else { return nil }
        copy.frameLength = AVAudioFrameCount(frames.count)
        // Per channel buffer when deinterleaved, one buffer when interleaved: either way frames are
        // `mBytesPerFrame` apart within each buffer.
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let from = from.mData, let to = to.mData else { return nil }
            memcpy(to, from + frames.lowerBound * bytesPerFrame, frames.count * bytesPerFrame)
        }
        return TapBuffer(pcm: copy)
    }
}

/// Hardware format to 16 kHz mono `Float32`. Owned by the tap thread through the pipeline.
private final class InputConverter: SampleConverter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter

    init(input: AVAudioFormat) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DictationSampleBuffer.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = Self.makeConverter(from: input, to: output) else { throw ConversionError.unsupported }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    /// A new converter, so no filter history from earlier audio survives the boundary.
    func reset() {
        if let fresh = Self.makeConverter(from: inputFormat, to: outputFormat) {
            converter = fresh
        } else {
            converter.reset()
        }
    }

    func convert(_ tapBuffer: TapBuffer) -> [Float]? {
        let input = tapBuffer.pcm
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard input.frameLength > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: input, to: output)
        converter?.downmix = true
        return converter
    }

    private enum ConversionError: Error { case unsupported }
}

extension InputPortKind {
    init(_ port: AVAudioSession.Port) {
        switch port {
        case .builtInMic: self = .builtInMic
        case .bluetoothHFP, .bluetoothLE: self = .bluetooth
        case .headsetMic: self = .headset
        case .usbAudio: self = .usb
        default: self = .other
        }
    }
}

extension AVAudioSession.CategoryOptions {
    init(_ options: Set<MicrophoneRoute.CategoryOption>) {
        self = []
        for option in options {
            switch option {
            case .mixWithOthers: insert(.mixWithOthers)
            case .defaultToSpeaker: insert(.defaultToSpeaker)
            case .allowBluetoothA2DP: insert(.allowBluetoothA2DP)
            case .allowBluetoothHFP: insert(.allowBluetoothHFP)
            }
        }
    }
}

/// `AVAudioSession` as the router sees it.
@MainActor
private final class SystemAudioRouteSession: AudioRouteSession {
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    var availableInputs: [InputPortKind] { (session.availableInputs ?? []).map { InputPortKind($0.portType) } }

    var currentInput: InputPortKind? { session.currentRoute.inputs.first.map { InputPortKind($0.portType) } }

    func setCategoryOptions(_ options: Set<MicrophoneRoute.CategoryOption>) throws {
        try session.setCategory(.playAndRecord, mode: .default, options: AVAudioSession.CategoryOptions(options))
    }

    func setPreferredInput(_ kind: InputPortKind?) throws {
        var port: AVAudioSessionPortDescription?
        if let kind {
            port = session.availableInputs?.first { InputPortKind($0.portType) == kind }
            guard port != nil else { throw RouteError.inputUnavailable }
        }
        try session.setPreferredInput(port)
    }

    private enum RouteError: Error { case inputUnavailable }
}
