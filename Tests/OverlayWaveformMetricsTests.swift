import Foundation

enum OverlayWaveformMetricsTests {
    static func run() {
        testBarCounts()
        testBarAmplitudeWithoutPulse()
        testBarAmplitudeWithPulse()
        testBarSpring()
        testProcessingPulse()
    }

    private static func testBarCounts() {
        TestSupport.expectEqual(WaveformMetrics.regular.barCount, 9)
        TestSupport.expectEqual(WaveformMetrics.compact.barCount, 5)
        TestSupport.expectEqual(WaveformMetrics.processingBarCount, 5)
    }

    private static func testBarAmplitudeWithoutPulse() {
        let regular = WaveformMetrics.regular
        let compact = WaveformMetrics.compact
        expectAmplitude(regular.barAmplitude(for: 4, audioLevel: 0.5, pulseTime: nil), 0.5)
        expectAmplitude(regular.barAmplitude(for: 0, audioLevel: 0.5, pulseTime: nil), 0.175)
        expectAmplitude(regular.barAmplitude(for: 4, audioLevel: 2, pulseTime: nil), 1)
        expectAmplitude(regular.barAmplitude(for: 4, audioLevel: -1, pulseTime: nil), 0)
        expectAmplitude(compact.barAmplitude(for: 0, audioLevel: 0.5, pulseTime: nil), 0.25)
        expectAmplitude(compact.barAmplitude(for: 2, audioLevel: 0.5, pulseTime: nil), 0.5)
    }

    private static func testBarAmplitudeWithPulse() {
        let regular = WaveformMetrics.regular
        let compact = WaveformMetrics.compact
        expectAmplitude(regular.barAmplitude(for: 0, audioLevel: 0.5, pulseTime: 1.25), 0.255605430692)
        expectAmplitude(regular.barAmplitude(for: 4, audioLevel: 0.5, pulseTime: 1.25), 0.401817468410)
        expectAmplitude(regular.barAmplitude(for: 4, audioLevel: 0, pulseTime: 1.25), 0.045170142429)
        expectAmplitude(compact.barAmplitude(for: 0, audioLevel: 0.5, pulseTime: 1.25), 0.320488911621)
        expectAmplitude(compact.barAmplitude(for: 2, audioLevel: 0.75, pulseTime: 1.25), 0.647131369387)
        expectAmplitude(compact.barAmplitude(for: 2, audioLevel: 2, pulseTime: 0), 0.795250540319)
    }

    private static func testBarSpring() {
        let regular = WaveformMetrics.regular
        expectSpring(regular.barSpring(for: 0), response: 0.24, delay: 0.04)
        expectSpring(regular.barSpring(for: 2), response: 0.21, delay: 0.02)
        expectSpring(regular.barSpring(for: 4), response: 0.18, delay: 0)
        expectSpring(regular.barSpring(for: 8), response: 0.24, delay: 0.04)
        for index in 0..<WaveformMetrics.compact.barCount {
            expectSpring(WaveformMetrics.compact.barSpring(for: index), response: 0.18, delay: nil)
        }
    }

    private static func testProcessingPulse() {
        let cases: [(index: Int, time: TimeInterval, amplitude: Double, opacity: Double)] = [
            (0, 0, 0.18, 0.42),
            (0, 0.5, 0.852802849599, 0.934496296752),
            (2, 0, 0.385055959692, 0.500336910353),
            (2, 0.5, 0.500083788654, 0.588299367794),
            (4, 0, 0.780556004059, 0.879248708986),
            (4, 0.5, 0.180975573706, 0.420746026952),
        ]
        for testCase in cases {
            expectAmplitude(
                WaveformMetrics.processingAmplitude(for: testCase.index, time: testCase.time),
                testCase.amplitude
            )
            expectAmplitude(
                WaveformMetrics.processingOpacity(for: testCase.index, time: testCase.time),
                testCase.opacity
            )
        }
    }

    private static func expectAmplitude(
        _ actual: CGFloat,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        TestSupport.expectApproximatelyEqual(Double(actual), expected, accuracy: 1e-9, file: file, line: line)
    }

    private static func expectSpring(
        _ actual: (response: Double, delay: Double?),
        response: Double,
        delay: Double?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        TestSupport.expectApproximatelyEqual(actual.response, response, accuracy: 1e-12, file: file, line: line)
        switch (actual.delay, delay) {
        case (nil, nil):
            break
        case let (actualDelay?, expectedDelay?):
            TestSupport.expectApproximatelyEqual(actualDelay, expectedDelay, accuracy: 1e-12, file: file, line: line)
        default:
            TestSupport.expect(false, "Expected delay \(String(describing: delay)), got \(String(describing: actual.delay))", file: file, line: line)
        }
    }
}
