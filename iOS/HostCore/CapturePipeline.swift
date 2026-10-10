import Foundation

/// One input buffer from the capture thread: its frames and when they were captured.
protocol CaptureInput {
    var frameCount: Int { get }
    /// The input's own sample rate; frame offsets are in it.
    var sampleRate: Double { get }
    /// Host time (`mach_absolute_time`) of the first frame, if known.
    var hostTime: UInt64? { get }
    /// Sample time of the first frame on the input's own timeline, if known: the fallback timestamp.
    var sampleTime: Int64? { get }
    /// Only `frames`, for conversion. Timestamps are not used afterwards.
    func slice(_ frames: Range<Int>) -> Self?
}

/// Turns one input buffer into 16 kHz mono samples. It may keep state derived from earlier input (a
/// resampler's filter history), and `reset()` must discard all of it. `CapturePipeline` never runs
/// `convert` and `reset` at the same time.
protocol SampleConverter: AnyObject {
    associatedtype Input: CaptureInput
    /// Nil when the buffer cannot be converted.
    func convert(_ input: Input) -> [Float]?
    func reset()
}

/// The capture thread's side of the dictation boundary, shared by the microphone and the synthetic
/// input. For each input buffer it:
/// - records the arrival time, for capture liveness;
/// - drops the buffer unconverted while idle;
/// - trims, before conversion, the frames captured before the recording's begin or after its end
///   (`CaptureTiming`), so idle audio never enters a dictation even with long buffers;
/// - appends with the token it read with the window, so samples whose recording ended or was replaced
///   during the conversion are dropped under the buffer's lock;
/// - reports when a closing recording's tail has fully arrived, and repeated conversion failures.
///
/// Converter state never outlives a recording: `boundaryPassed()` (begin, drain, discard) resets the
/// converter at once, or, if a conversion is running, as soon as it returns, without waiting for another
/// buffer. `process` must be called serially, as an audio tap does.
final class CapturePipeline<Converter: SampleConverter>: @unchecked Sendable {
    let clock = BufferClock()
    private let buffer: DictationSampleBuffer
    private let converter: Converter
    private let deliver: @Sendable (CaptureEvent) -> Void
    private let hostClock: @Sendable () -> UInt64
    private let ticksPerSecond: Double

    // Guarded by `lock`: what serializes `convert` and `reset`.
    private let lock = NSLock()
    private var converting = false
    private var resetPending = false
    private var convertedToken: UInt64?
    private var engine: UInt64

    // Confined to the capture thread.
    private var consecutiveFailures = 0
    private var tailReported: UInt64?
    private var anchor: (hostTime: UInt64, sampleTime: Int64)?

    /// `engineGeneration` names the engine this pipeline converts for, in its conversion-failure reports.
    init(buffer: DictationSampleBuffer, converter: Converter, engineGeneration: UInt64 = 0,
         ticksPerSecond: Double = CaptureTiming.hostTicksPerSecond,
         hostClock: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
         deliver: @escaping @Sendable (CaptureEvent) -> Void) {
        self.buffer = buffer
        self.converter = converter
        engine = engineGeneration
        self.ticksPerSecond = ticksPerSecond
        self.hostClock = hostClock
        self.deliver = deliver
    }

    func process(_ input: Converter.Input) {
        clock.mark()
        let deliveredAt = hostClock()
        let start = timestamp(of: input)
        guard let window = buffer.recordingWindow else {
            resetIfTokenChanged(to: nil)   // idle: nothing converted, nothing allocated
            return
        }
        let decision = CaptureTiming.decide(start: start, frameCount: input.frameCount, sampleRate: input.sampleRate,
                                            ticksPerSecond: ticksPerSecond, window: window, deliveredAt: deliveredAt)
        if !decision.keep.isEmpty, let frames = input.slice(decision.keep), beginConversion(for: window.token) {
            let samples = converter.convert(frames)
            endConversion()
            if let samples {
                consecutiveFailures = 0
                if let event = CaptureEvent(buffer.append(samples, token: window.token)) { deliver(event) }
            } else {
                consecutiveFailures += 1
                if consecutiveFailures == HostSessionPolicy.maxConsecutiveConversionFailures {
                    deliver(.conversionFailed(generation: window.token, engine: engineGeneration))
                }
            }
        }
        if decision.reachesEnd, tailReported != window.token {
            tailReported = window.token
            deliver(.tailComplete(generation: window.token))
        }
    }

    /// A recording began, was drained or was discarded. Called on main.
    func boundaryPassed() {
        lock.lock()
        defer { lock.unlock() }
        if converting {
            resetPending = true   // the running conversion resets when it returns
        } else {
            converter.reset()
            convertedToken = nil
            resetPending = false
        }
    }

    /// The engine this pipeline now converts for, when one pipeline outlives several engines.
    var engineGeneration: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return engine }
        set { lock.lock(); engine = newValue; lock.unlock() }
    }

    /// Forgets the arrival time, when the engine that fed this pipeline stops.
    func resetClock() { clock.reset() }

    // MARK: Private

    /// Marks a conversion as running, resetting first if the recording changed; false if a boundary
    /// passed since the window was read, so the buffer is dropped unconverted.
    private func beginConversion(for token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if convertedToken != token || resetPending {
            converter.reset()
            convertedToken = token
            resetPending = false
            consecutiveFailures = 0
        }
        guard buffer.recordingToken == token else { return false }
        converting = true
        return true
    }

    private func endConversion() {
        lock.lock()
        defer { lock.unlock() }
        converting = false
        if resetPending {
            converter.reset()
            convertedToken = nil
            resetPending = false
        }
    }

    private func resetIfTokenChanged(to token: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        guard convertedToken != token, !converting else { return }
        converter.reset()
        convertedToken = token
        resetPending = false
    }

    /// The host time of the first frame: given, or estimated from the sample time and the last buffer
    /// that had both.
    private func timestamp(of input: Converter.Input) -> UInt64? {
        if let hostTime = input.hostTime {
            if let sampleTime = input.sampleTime { anchor = (hostTime, sampleTime) }
            return hostTime
        }
        guard let sampleTime = input.sampleTime, let anchor else { return nil }
        return CaptureTiming.estimatedStart(sampleTime: sampleTime, anchorHostTime: anchor.hostTime,
                                            anchorSampleTime: anchor.sampleTime, sampleRate: input.sampleRate,
                                            ticksPerSecond: ticksPerSecond)
    }
}

/// When the latest input buffer arrived: written on the capture thread, read on main.
final class BufferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?

    var lastBufferAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func mark(_ now: Date = Date()) {
        lock.lock()
        last = now
        lock.unlock()
    }

    func reset() {
        lock.lock()
        last = nil
        lock.unlock()
    }
}
