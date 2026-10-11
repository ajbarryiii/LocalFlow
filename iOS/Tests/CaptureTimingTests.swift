import Foundation

/// `CaptureTiming`: which frames of a buffer belong to a recording, by capture time, before conversion.
/// Host ticks are nanoseconds here unless a test says otherwise.
enum CaptureTimingTests {
    static var tests: [TestCase] {
        [
            ("bufferInsideTheWindowIsKeptWhole", testBufferInsideTheWindowIsKeptWhole),
            ("bufferStraddlingBeginKeepsOnlyLaterFrames", testBufferStraddlingBeginKeepsOnlyLaterFrames),
            ("bufferEntirelyBeforeBeginIsDropped", testBufferEntirelyBeforeBeginIsDropped),
            ("bufferStraddlingEndKeepsEarlierFramesAndEndsTheTail", testBufferStraddlingEndKeepsEarlierFramesAndEndsTheTail),
            ("bufferEntirelyAfterEndIsDroppedAndEndsTheTail", testBufferEntirelyAfterEndIsDroppedAndEndsTheTail),
            ("frameOffsetsUseTheInputRateAndHostTimebase", testFrameOffsetsUseTheInputRateAndHostTimebase),
            ("untimedBuffersAreConservative", testUntimedBuffersAreConservative),
            ("sampleTimeEstimatesTheHostTime", testSampleTimeEstimatesTheHostTime),
        ]
    }

    private static let ns: Double = 1_000_000_000
    private static let begin: UInt64 = 5_000_000_000

    private static func decide(start: UInt64?, frames: Int = 3_200, rate: Double = 16_000, ticks: Double = ns,
                               begin: UInt64 = begin, end: UInt64? = nil,
                               deliveredAt: UInt64 = begin + 10_000_000_000) -> CaptureTiming.Decision {
        CaptureTiming.decide(start: start, frameCount: frames, sampleRate: rate, ticksPerSecond: ticks,
                             window: RecordingWindow(token: 1, begin: begin, end: end), deliveredAt: deliveredAt)
    }

    private static func testBufferInsideTheWindowIsKeptWhole() {
        TestSupport.expectEqual(decide(start: begin), CaptureTiming.Decision(keep: 0..<3_200, reachesEnd: false))
        TestSupport.expectEqual(decide(start: begin + 1), CaptureTiming.Decision(keep: 0..<3_200, reachesEnd: false))
        // Ending exactly at the end boundary: everything kept, but no frame at or after the end yet.
        TestSupport.expectEqual(decide(start: begin, end: begin + 200_000_000),
                                CaptureTiming.Decision(keep: 0..<3_200, reachesEnd: false))
    }

    /// P0: a 0.2 s buffer captured partly before begin. Its first 0.05 s is idle audio.
    private static func testBufferStraddlingBeginKeepsOnlyLaterFrames() {
        let decision = decide(start: begin - 50_000_000)
        TestSupport.expectEqual(decision.keep, 800..<3_200)   // 0.05 s at 16 kHz trimmed
        TestSupport.expect(!decision.reachesEnd, "an open recording has no end")
        // A begin between two frames keeps the next frame only.
        TestSupport.expectEqual(decide(start: begin - 62_500 - 1).keep, 2..<3_200)
        TestSupport.expectEqual(decide(start: begin - 62_500).keep, 1..<3_200)
    }

    private static func testBufferEntirelyBeforeBeginIsDropped() {
        TestSupport.expectEqual(decide(start: begin - 200_000_000), .drop)   // ends exactly at begin
        TestSupport.expectEqual(decide(start: begin - 900_000_000), .drop)
    }

    private static func testBufferStraddlingEndKeepsEarlierFramesAndEndsTheTail() {
        let end = begin + 1_000_000_000
        let decision = decide(start: end - 50_000_000, end: end)
        TestSupport.expectEqual(decision, CaptureTiming.Decision(keep: 0..<800, reachesEnd: true))
        // A short recording inside one buffer: both ends trimmed.
        TestSupport.expectEqual(decide(start: begin - 50_000_000, end: begin + 100_000_000),
                                CaptureTiming.Decision(keep: 800..<2_400, reachesEnd: true))
    }

    private static func testBufferEntirelyAfterEndIsDroppedAndEndsTheTail() {
        let end = begin + 1_000_000_000
        TestSupport.expectEqual(decide(start: end, end: end), CaptureTiming.Decision(keep: 0..<0, reachesEnd: true))
        TestSupport.expectEqual(decide(start: end + 300_000_000, end: end), CaptureTiming.Decision(keep: 0..<0, reachesEnd: true))
    }

    /// Offsets are counted in the input's own frames (before resampling), and host ticks convert through
    /// the timebase: 24 MHz ticks on Apple silicon.
    private static func testFrameOffsetsUseTheInputRateAndHostTimebase() {
        // 48 kHz: 0.05 s before begin is 2,400 input frames.
        TestSupport.expectEqual(decide(start: begin - 50_000_000, frames: 9_600, rate: 48_000).keep, 2_400..<9_600)
        // 44.1 kHz: 0.01 s is 441 frames.
        TestSupport.expectEqual(decide(start: begin - 10_000_000, frames: 8_820, rate: 44_100).keep, 441..<8_820)
        // 24 MHz ticks: 0.05 s is 1,200,000 ticks, still 800 frames at 16 kHz.
        let ticks = 24_000_000.0
        let begin24: UInt64 = 120_000_000_000
        TestSupport.expectEqual(decide(start: begin24 - 1_200_000, ticks: ticks, begin: begin24,
                                       deliveredAt: begin24 + 240_000_000).keep, 800..<3_200)
        TestSupport.expect(CaptureTiming.hostTicksPerSecond > 0, "no host timebase")
    }

    private static func testUntimedBuffersAreConservative() {
        // Its earliest possible capture is its 0.2 s length plus the allowance before delivery.
        let span = UInt64((0.2 + CaptureTiming.untimedLatencyAllowance) * ns)
        let safe = begin + span + 1_000_000
        // Delivered so long after begin that even its earliest possible capture was after it: kept.
        TestSupport.expectEqual(decide(start: nil, deliveredAt: safe), CaptureTiming.Decision(keep: 0..<3_200, reachesEnd: false))
        // Delivered soon after begin: it may straddle the begin, so the whole buffer is dropped.
        TestSupport.expectEqual(decide(start: nil, deliveredAt: begin + span - 1_000_000), .drop)
        TestSupport.expectEqual(decide(start: nil, deliveredAt: begin + 100_000_000), .drop)
        // Closing: its frames cannot be placed against the end, so it is dropped and ends the tail.
        TestSupport.expectEqual(decide(start: nil, end: begin + 1_000_000_000, deliveredAt: safe + 10_000_000_000),
                                CaptureTiming.Decision(keep: 0..<0, reachesEnd: true))
        TestSupport.expectEqual(decide(start: begin, frames: 0), .drop)
    }

    private static func testSampleTimeEstimatesTheHostTime() {
        let estimate = CaptureTiming.estimatedStart(sampleTime: 48_000 + 4_800, anchorHostTime: begin, anchorSampleTime: 48_000,
                                                    sampleRate: 48_000, ticksPerSecond: ns)
        TestSupport.expectEqual(estimate, begin + 100_000_000)
        let earlier = CaptureTiming.estimatedStart(sampleTime: 0, anchorHostTime: begin, anchorSampleTime: 16_000,
                                                   sampleRate: 16_000, ticksPerSecond: ns)
        TestSupport.expectEqual(earlier, begin - 1_000_000_000)
        TestSupport.expectEqual(CaptureTiming.estimatedStart(sampleTime: 0, anchorHostTime: 10, anchorSampleTime: 16_000,
                                                             sampleRate: 16_000, ticksPerSecond: ns), nil)
    }
}
