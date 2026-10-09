#if LOCALFLOW_SELFTEST
import AVFoundation
import Foundation

/// Self-test builds only (`LOCALFLOW_SYNTHETIC_MIC`). Replaces the microphone with an invented 16 kHz
/// recording fed at real-time pace through the same `DictationSampleBuffer` path: each dictation hears
/// the file from its start, then silence. To keep the app running in the simulator's background it
/// plays silence through a `.playback` session; the microphone is never touched, so the Mac shows no
/// permission prompt. It cannot prove device background behavior.
@MainActor
final class SyntheticCapture: HostCapture {
    private let feeder: SyntheticFeeder
    private var keepAlive: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var lastRestartAttempt = Date.distantPast

    init(samples: [Float], buffer: DictationSampleBuffer,
         deliver: @escaping @Sendable (DictationSampleBuffer.AppendOutcome) -> Void) {
        feeder = SyntheticFeeder(samples: samples, buffer: buffer, deliver: deliver)
    }

    var permission: CapturePermission { .granted }

    func requestPermission() async -> Bool { true }

    /// The feeder is the capture. The keep-alive engine only keeps the simulator from suspending the app,
    /// and is restarted when it stops (the simulator rebuilds its audio I/O a few seconds after the app
    /// is backgrounded), so simulator audio quirks never end a session.
    var isRunning: Bool {
        if let keepAlive, !keepAlive.isRunning { restartKeepAlive("stopped") }
        return feeder.isRunning
    }

    var lastBufferAt: Date? { feeder.clock.lastBufferAt }

    func start() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let silence = Self.makeSilence()
        engine.attach(silence)
        engine.connect(silence, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        try engine.start()
        keepAlive = engine
        feeder.start()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartKeepAlive("configuration_change") }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
                Self.event("interruption type=\((note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99)")
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { _ in
                Self.event("media_services_reset")
            },
        ]
    }

    func stop() {
        feeder.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let keepAlive else { return }
        keepAlive.stop()
        self.keepAlive = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restartKeepAlive(_ reason: String) {
        guard let keepAlive, !keepAlive.isRunning, Date().timeIntervalSince(lastRestartAttempt) > 2 else { return }
        lastRestartAttempt = Date()
        Self.event("\(reason) keep_alive_restarted=\((try? keepAlive.start()) != nil)")
    }

    nonisolated private static func event(_ text: String) {
        print("LocalFlow self-test: synthetic_mic event=\(text)")
        fflush(stdout)
    }

    // Built outside the main actor: the render block runs on the audio thread.
    nonisolated private static func makeSilence() -> AVAudioSourceNode {
        AVAudioSourceNode { isSilence, _, _, audioBufferList in
            isSilence.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
}

/// Delivers 100 ms chunks on its own queue, like an input tap: dropped unless a request is recording.
private final class SyntheticFeeder: @unchecked Sendable {
    static let chunk = Int(DictationSampleBuffer.sampleRate / 10)

    let clock = BufferClock()
    private let samples: [Float]
    private let buffer: DictationSampleBuffer
    private let deliver: @Sendable (DictationSampleBuffer.AppendOutcome) -> Void
    private let queue = DispatchQueue(label: "localflow.synthetic-mic", qos: .userInitiated)
    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var generation: UInt64?
    private var position = 0

    init(samples: [Float], buffer: DictationSampleBuffer,
         deliver: @escaping @Sendable (DictationSampleBuffer.AppendOutcome) -> Void) {
        self.samples = samples
        self.buffer = buffer
        self.deliver = deliver
    }

    var isRunning: Bool { queue.sync { timer != nil } }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            generation = nil
        }
        clock.reset()
    }

    private func tick() {
        clock.mark()
        guard buffer.recordingRequestID != nil else {
            generation = nil
            return
        }
        let current = buffer.generation
        if generation != current {
            generation = current
            position = 0
        }
        var chunk = [Float](repeating: 0, count: Self.chunk)
        if position < samples.count {
            let count = min(Self.chunk, samples.count - position)
            chunk.replaceSubrange(0..<count, with: samples[position..<(position + count)])
        }
        position += Self.chunk
        deliver(buffer.append(chunk))
    }
}
#endif
