#if LOCALFLOW_SELFTEST
import AVFoundation
import Foundation

/// Self-test builds only (`LOCALFLOW_SYNTHETIC_MIC`). Replaces the microphone with an invented 16 kHz
/// recording fed at real-time pace through the same `CapturePipeline` and `DictationSampleBuffer` path:
/// each dictation hears the file from its start, then silence. To keep the app running in the
/// simulator's background it plays silence through a `.playback` session; the microphone is never
/// touched, so the Mac shows no permission prompt. It cannot prove device background behavior.
@MainActor
final class SyntheticCapture: HostCapture {
    private(set) var engineGeneration: UInt64 = 0
    private let pipeline: CapturePipeline<SyntheticSource>
    private let feeder: SyntheticFeeder
    private var keepAlive: AVAudioEngine?
    private var activatedSession = false
    private var lastRestartAttempt = Date.distantPast
    private var requested = AudioSessionTuning.Requested()
    /// Every input start reports what was requested and what iOS granted.
    var onConfigured: (@MainActor (CaptureConfiguration) -> Void)?

    init(samples: [Float], buffer: DictationSampleBuffer, deliver: @escaping @Sendable (CaptureEvent) -> Void) {
        pipeline = CapturePipeline(buffer: buffer, converter: SyntheticSource(samples: samples), deliver: deliver)
        feeder = SyntheticFeeder(pipeline: pipeline)
    }

    var permission: CapturePermission { .granted }

    func requestPermission() async -> Bool { true }

    /// The feeder is the input. The keep-alive engine only keeps the simulator from suspending the app and
    /// is restarted when it stops (the simulator rebuilds its audio I/O a few seconds after the app is
    /// backgrounded), so that quirk never ends a session.
    var isRunning: Bool {
        if let keepAlive, !keepAlive.isRunning { restartKeepAlive("stopped") }
        return feeder.isRunning
    }

    var lastBufferAt: Date? { feeder.isRunning ? pipeline.clock.lastBufferAt : nil }

    func start() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        requested = AudioSessionTuning.requestPreferences(on: session)
        try session.setActive(true)
        activatedSession = true
        do {
            try startInput()
        } catch {
            stop()
            throw error
        }
    }

    func restart() throws {
        guard activatedSession else { throw SyntheticError.noSession }
        stopInput()
        try startInput()
    }

    func stop() {
        stopInput()
        guard activatedSession else { return }
        activatedSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func recordingBoundary() {
        pipeline.boundaryPassed()
    }

    private func startInput() throws {
        let engine = AVAudioEngine()
        let silence = Self.makeSilence()
        engine.attach(silence)
        engine.connect(silence, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        try engine.start()
        keepAlive = engine
        feeder.start()
        engineGeneration &+= 1
        let session = AVAudioSession.sharedInstance()
        onConfigured?(CaptureConfiguration(
            source: "synthetic", requestedIOBufferDuration: requested.ioBufferDuration,
            actualIOBufferDuration: session.ioBufferDuration, requestedSampleRate: requested.sampleRate,
            actualSampleRate: session.sampleRate, inputSampleRate: DictationSampleBuffer.sampleRate, inputChannels: 1,
            tapBufferFrames: SyntheticSource.chunk))
    }

    private func stopInput() {
        feeder.stop()
        pipeline.resetClock()
        keepAlive?.stop()
        keepAlive = nil
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

    private enum SyntheticError: Error { case noSession }
}

/// One 100 ms tick of the synthetic input, timestamped like a tap buffer: it covers the 100 ms before it
/// was delivered.
private struct SyntheticTick: CaptureInput {
    var hostTime: UInt64?
    var frameCount: Int
    var sampleRate: Double { DictationSampleBuffer.sampleRate }
    var sampleTime: Int64? { nil }

    func slice(_ frames: Range<Int>) -> SyntheticTick? {
        frames.isEmpty ? nil : SyntheticTick(hostTime: nil, frameCount: frames.count)
    }
}

/// The recording as a pipeline "converter": each tick yields the next frames of the file (then silence),
/// and every dictation boundary rewinds it. Frames trimmed before a recording's begin are never
/// produced, so each dictation hears the file from its start.
private final class SyntheticSource: SampleConverter {
    static let chunk = Int(DictationSampleBuffer.sampleRate / 10)

    private let samples: [Float]
    private var position = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func convert(_ tick: SyntheticTick) -> [Float]? {
        var chunk = [Float](repeating: 0, count: tick.frameCount)
        if position < samples.count {
            let count = min(tick.frameCount, samples.count - position)
            chunk.replaceSubrange(0..<count, with: samples[position..<(position + count)])
        }
        position += tick.frameCount
        return chunk
    }

    func reset() { position = 0 }
}

/// Drives the pipeline every 100 ms on its own serial queue, as an input tap would.
private final class SyntheticFeeder: @unchecked Sendable {
    private let pipeline: CapturePipeline<SyntheticSource>
    private let queue = DispatchQueue(label: "localflow.synthetic-mic", qos: .userInitiated)
    private var timer: DispatchSourceTimer?   // confined to `queue`

    init(pipeline: CapturePipeline<SyntheticSource>) {
        self.pipeline = pipeline
    }

    var isRunning: Bool { queue.sync { timer != nil } }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
            let pipeline = self.pipeline
            let span = UInt64(0.1 * CaptureTiming.hostTicksPerSecond)
            timer.setEventHandler {
                let now = mach_absolute_time()
                pipeline.process(SyntheticTick(hostTime: now > span ? now - span : 0, frameCount: SyntheticSource.chunk))
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}
#endif
