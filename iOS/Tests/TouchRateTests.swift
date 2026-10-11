import Foundation

enum TouchRateTests {
    static var tests: [TestCase] {
        [
            ("sixtyHertzIsTheReference", testSixtyHertzIsTheReference),
            ("oneTwentyHertzDoublesTheStep", testOneTwentyHertzDoublesTheStep),
            ("defaultUntilMeasured", testDefaultUntilMeasured),
            ("robustToPausesAndDroppedFrames", testRobustToPausesAndDroppedFrames),
            ("clampedToTheRange", testClampedToTheRange),
            ("noIntervalSpansGestures", testNoIntervalSpansGestures),
            ("runningMedianFollowsAChange", testRunningMedianFollowsAChange),
        ]
    }

    private static func close(_ actual: Double?, _ expected: Double, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expect(actual.map { abs($0 - expected) < 1e-6 } ?? false,
                           "\(what): expected \(expected), got \(String(describing: actual))", file: file, line: line)
    }

    private static func events(_ estimator: inout TouchRateEstimator, every interval: TimeInterval, count: Int,
                               from start: TimeInterval = 10) {
        for index in 0 ..< count { estimator.record(start + Double(index) * interval) }
    }

    private static func testSixtyHertzIsTheReference() {
        // Device calibration: touches at 60 Hz (median 16.67 ms) are the steps the curve was measured with.
        var estimator = TouchRateEstimator()
        events(&estimator, every: 1.0 / 60, count: 20)
        close(estimator.touchRate, 60, "rate")
        close(estimator.eventStepScale, 1, "scale")
    }

    private static func testOneTwentyHertzDoublesTheStep() {
        var estimator = TouchRateEstimator()
        events(&estimator, every: 1.0 / 120, count: 20)
        close(estimator.touchRate, 120, "rate")
        close(estimator.eventStepScale, 2, "scale")
    }

    private static func testDefaultUntilMeasured() {
        var estimator = TouchRateEstimator()
        TestSupport.expectEqual(estimator.eventStepScale, 1)
        TestSupport.expectEqual(estimator.touchRate, nil)
        events(&estimator, every: 1.0 / 120, count: TouchRateEstimator.minimumSamples)
        // Four intervals: not yet enough.
        TestSupport.expectEqual(estimator.eventStepScale, 1)
        estimator.record(10 + Double(TouchRateEstimator.minimumSamples) / 120)
        close(estimator.eventStepScale, 2, "scale")
    }

    private static func testRobustToPausesAndDroppedFrames() {
        // A resting finger (no events for a while) and a few dropped frames do not move the median.
        var estimator = TouchRateEstimator()
        var time = 10.0
        for index in 0 ..< 30 {
            time += index == 10 ? 0.5 : (index % 7 == 0 ? 2.0 / 120 : 1.0 / 120)
            estimator.record(time)
        }
        close(estimator.eventStepScale, 2, "scale")
        TestSupport.expect(estimator.intervals.allSatisfy { TouchRateEstimator.plausibleIntervals.contains($0) },
                           "a pause counted as an interval")
    }

    private static func testClampedToTheRange() {
        var fast = TouchRateEstimator()
        events(&fast, every: 1.0 / 240, count: 20)
        close(fast.eventStepScale, 2.5, "fast")
        var slow = TouchRateEstimator()
        events(&slow, every: 1.0 / 25, count: 20)
        close(slow.eventStepScale, 0.5, "slow")
    }

    private static func testNoIntervalSpansGestures() {
        var estimator = TouchRateEstimator()
        events(&estimator, every: 1.0 / 60, count: 3, from: 10)
        estimator.beginGesture()
        events(&estimator, every: 1.0 / 60, count: 3, from: 10.03)
        TestSupport.expectEqual(estimator.intervals.count, 4)
    }

    private static func testRunningMedianFollowsAChange() {
        // A host that switches to 120 Hz: once most recent intervals are 120 Hz, so is the scale.
        var estimator = TouchRateEstimator()
        events(&estimator, every: 1.0 / 60, count: 32, from: 10)
        close(estimator.eventStepScale, 1, "before")
        estimator.beginGesture()
        events(&estimator, every: 1.0 / 120, count: 20, from: 20)
        close(estimator.eventStepScale, 2, "after")
        TestSupport.expectEqual(estimator.intervals.count, TouchRateEstimator.capacity)
    }
}
