import Foundation

/// A recording's token and capture-time boundaries, in host-clock ticks (`mach_absolute_time`, the clock
/// of `AVAudioTime.hostTime`).
struct RecordingWindow: Equatable, Sendable {
    var token: UInt64
    /// Frames captured before this belong to idle time and never enter the recording.
    var begin: UInt64
    /// Set once the recording is closing: frames captured at or after it are not part of it.
    var end: UInt64?
}

/// Which frames of one input buffer belong to a recording, decided before conversion. Pure.
enum CaptureTiming {
    /// Without a timestamp, a buffer may have been captured up to its own length plus this much before it
    /// was delivered (the I/O buffer, at most about 0.26 s here, plus scheduling).
    static let untimedLatencyAllowance: TimeInterval = 0.5

    struct Decision: Equatable, Sendable {
        /// Frames to convert and keep; empty to drop the buffer.
        var keep: Range<Int>
        /// The buffer reaches the recording's end: every frame captured before the end has now been
        /// delivered, so the recording can be drained.
        var reachesEnd: Bool

        static let drop = Decision(keep: 0..<0, reachesEnd: false)
    }

    /// Host-clock ticks per second, from `mach_timebase_info`.
    static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0 else { return 1_000_000_000 }
        return 1_000_000_000 * Double(info.denom) / Double(info.numer)
    }()

    /// Frame `i` of a buffer whose first frame was captured at `start` was captured at
    /// `start + i / sampleRate`; it is kept when `begin <= t < end`. Frame offsets are in the buffer's own
    /// (input) sample rate, so trimming happens before resampling.
    ///
    /// Without `start` (no host time, and no sample time to estimate it from) the decision is
    /// conservative: while open, the buffer is kept whole only if even its earliest possible capture
    /// time (`deliveredAt` minus its length and `untimedLatencyAllowance`) is after `begin`, and dropped
    /// otherwise, since it may straddle the begin; once closing it is dropped and ends the recording,
    /// since its frames cannot be placed against the end.
    static func decide(start: UInt64?, frameCount: Int, sampleRate: Double, ticksPerSecond: Double,
                       window: RecordingWindow, deliveredAt: UInt64) -> Decision {
        guard frameCount > 0, sampleRate > 0, ticksPerSecond > 0 else { return .drop }
        guard let start else {
            if window.end != nil { return Decision(keep: 0..<0, reachesEnd: true) }
            let span = Double(frameCount) / sampleRate + untimedLatencyAllowance
            let earliest = seconds(from: window.begin, to: deliveredAt, ticksPerSecond: ticksPerSecond) - span
            return earliest >= 0 ? Decision(keep: 0..<frameCount, reachesEnd: false) : .drop
        }
        let lower = frameOffset(of: window.begin, from: start, sampleRate: sampleRate, ticksPerSecond: ticksPerSecond,
                                frameCount: frameCount)
        let upper = window.end.map {
            frameOffset(of: $0, from: start, sampleRate: sampleRate, ticksPerSecond: ticksPerSecond, frameCount: frameCount)
        } ?? frameCount
        return Decision(keep: lower < upper ? lower..<upper : 0..<0, reachesEnd: window.end != nil && upper < frameCount)
    }

    /// The host time of a buffer that has only a sample time, from the last buffer that had both. Sample
    /// times count frames of the same input, so the difference converts at `sampleRate`.
    static func estimatedStart(sampleTime: Int64, anchorHostTime: UInt64, anchorSampleTime: Int64, sampleRate: Double,
                               ticksPerSecond: Double) -> UInt64? {
        guard sampleRate > 0 else { return nil }
        let ticks = (Double(sampleTime - anchorSampleTime) / sampleRate * ticksPerSecond).rounded()
        let estimate = Double(anchorHostTime) + ticks
        guard estimate >= 0, estimate < Double(UInt64.max) else { return nil }
        return UInt64(estimate)
    }

    /// The first frame captured at or after `time`, clamped to `0...frameCount`. A millionth of a frame of
    /// slack keeps a boundary that falls exactly on a frame from losing it to rounding.
    private static func frameOffset(of time: UInt64, from start: UInt64, sampleRate: Double, ticksPerSecond: Double,
                                    frameCount: Int) -> Int {
        let ticks = time >= start ? Double(time - start) : -Double(start - time)
        let offset = (ticks * sampleRate / ticksPerSecond - 0.000_001).rounded(.up)
        return Int(min(max(offset, 0), Double(frameCount)))
    }

    /// Signed seconds from `a` to `b`; the tick difference is exact before it becomes a `Double`.
    private static func seconds(from a: UInt64, to b: UInt64, ticksPerSecond: Double) -> Double {
        let ticks = b >= a ? Double(b - a) : -Double(a - b)
        return ticks / ticksPerSecond
    }
}
