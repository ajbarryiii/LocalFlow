import AVFoundation
import Foundation

/// The session's microphone: one `AVAudioEngine` input tap for the whole session. The tap converts to
/// 16 kHz mono `Float32` only while a request is recording; every other buffer is dropped in the
/// callback without being converted or retained. Audio is never written to disk or logged.
@MainActor
final class MicrophoneCapture: HostCapture {
    /// Interruption: the session must end. Failure: the engine stopped or must be rebuilt.
    var onInterruption: (@MainActor () -> Void)?
    var onFailure: (@MainActor () -> Void)?

    private let buffer: DictationSampleBuffer
    private let deliver: @Sendable (DictationSampleBuffer.AppendOutcome) -> Void
    private let clock = BufferClock()
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []

    init(buffer: DictationSampleBuffer, deliver: @escaping @Sendable (DictationSampleBuffer.AppendOutcome) -> Void) {
        self.buffer = buffer
        self.deliver = deliver
        observeAudioSession()
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

    var lastBufferAt: Date? { clock.lastBufferAt }

    func start() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true)
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
            let tap = try InputTap(format: format, buffer: buffer, clock: clock, deliver: deliver)
            input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: tap.block)
            engine.prepare()
            try engine.start()
            self.engine = engine
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                // The engine stopped and its input format may have changed; it must be rebuilt.
                MainActor.assumeIsolated { self?.onFailure?() }
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        clock.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                guard type == .began else { return }
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil else { return }
                    self.onInterruption?()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                // Every audio object is invalid now; the engine is rebuilt (foreground) or the session ends.
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil else { return }
                    self.onFailure?()
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                // A route change usually arrives with an engine configuration change; this catches an
                // engine that stopped without one.
                MainActor.assumeIsolated {
                    guard let self, let engine = self.engine, !engine.isRunning else { return }
                    self.onFailure?()
                }
            },
        ]
    }

    private enum CaptureError: Error { case noInput }
}

/// When the latest input buffer arrived, written on the tap thread and read on main.
final class BufferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?

    var lastBufferAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func mark() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        last = nil
        lock.unlock()
    }
}

/// Owned by the tap thread. Created outside any actor, so its block carries no actor isolation.
private final class InputTap: @unchecked Sendable {
    private let buffer: DictationSampleBuffer
    private let clock: BufferClock
    private let deliver: @Sendable (DictationSampleBuffer.AppendOutcome) -> Void
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var convertingGeneration: UInt64?

    init(format: AVAudioFormat, buffer: DictationSampleBuffer, clock: BufferClock,
                     deliver: @escaping @Sendable (DictationSampleBuffer.AppendOutcome) -> Void) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DictationSampleBuffer.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else { throw ConversionError.unsupported }
        converter.downmix = true
        self.buffer = buffer
        self.clock = clock
        self.deliver = deliver
        self.converter = converter
        outputFormat = output
    }

    var block: AVAudioNodeTapBlock {
        { [self] pcm, _ in process(pcm) }
    }

    private func process(_ pcm: AVAudioPCMBuffer) {
        clock.mark()
        // Between dictations the buffer is dropped here, before conversion.
        guard buffer.recordingRequestID != nil else {
            convertingGeneration = nil
            return
        }
        let generation = buffer.generation
        if convertingGeneration != generation {
            // A new recording starts with clean resampler state, so no earlier audio bleeds into it.
            converter.reset()
            convertingGeneration = generation
        }
        guard let samples = convert(pcm) else { return }
        deliver(buffer.append(samples))
    }

    private func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
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
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private enum ConversionError: Error { case unsupported }
}
