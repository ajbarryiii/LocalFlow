import Foundation

enum DictationSampleBufferTests {
    static var tests: [TestCase] {
        [
            ("dropsWhenIdle", testDropsWhenIdle),
            ("collectsOnlyBetweenBeginAndFinish", testCollectsOnlyBetweenBeginAndFinish),
            ("finishIsForTheRecordingRequestOnly", testFinishIsForTheRecordingRequestOnly),
            ("beginSupersedesAndAdvancesGeneration", testBeginSupersedesAndAdvancesGeneration),
            ("cancelPaths", testCancelPaths),
            ("capsAtMaxDuration", testCapsAtMaxDuration),
            ("defaultCapIsFiveMinutes", testDefaultCapIsFiveMinutes),
            ("levelTracksSpeechAndStaysInRange", testLevelTracksSpeechAndStaysInRange),
            ("finishDrainsAtomicallyUnderConcurrentAppends", testFinishDrainsAtomicallyUnderConcurrentAppends),
        ]
    }

    private static func tone(_ count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { amplitude * sinf(Float($0) * 0.2) }
    }

    private static func testDropsWhenIdle() {
        let buffer = DictationSampleBuffer()
        TestSupport.expectEqual(buffer.append(tone(1_600, amplitude: 0.5)), .dropped)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
        TestSupport.expectEqual(buffer.level, 0)
        TestSupport.expectEqual(buffer.recordingRequestID, nil)
        TestSupport.expectEqual(buffer.generation, 0)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
    }

    private static func testCollectsOnlyBetweenBeginAndFinish() {
        let buffer = DictationSampleBuffer()
        let generation = buffer.begin(requestID: Fixture.requestID)
        TestSupport.expectEqual(generation, 1)
        TestSupport.expectEqual(buffer.recordingRequestID, Fixture.requestID)
        TestSupport.expectEqual(buffer.append([Float]()), .dropped)
        TestSupport.expectEqual(buffer.append([0.1, 0.2]), .started(generation: 1))
        TestSupport.expectEqual(buffer.append([0.3]), .accepted)
        [Float](repeating: 0.4, count: 2).withUnsafeBufferPointer { pointer in
            TestSupport.expectEqual(buffer.append(pointer), .accepted)
        }
        TestSupport.expectEqual(buffer.recordedDuration, 5 / DictationSampleBuffer.sampleRate)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), [0.1, 0.2, 0.3, 0.4, 0.4])
        TestSupport.expectEqual(buffer.recordingRequestID, nil)
        TestSupport.expectEqual(buffer.append([0.5]), .dropped)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
    }

    private static func testFinishIsForTheRecordingRequestOnly() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        buffer.append([0.1])
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID), nil)
        TestSupport.expectEqual(buffer.recordingRequestID, Fixture.requestID)
        TestSupport.expectEqual(buffer.append([0.2]), .accepted)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), [0.1, 0.2])
    }

    private static func testBeginSupersedesAndAdvancesGeneration() {
        let buffer = DictationSampleBuffer()
        TestSupport.expectEqual(buffer.begin(requestID: Fixture.requestID), 1)
        buffer.append([0.9, 0.9])
        TestSupport.expectEqual(buffer.begin(requestID: Fixture.otherRequestID), 2)
        TestSupport.expectEqual(buffer.generation, 2)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
        TestSupport.expectEqual(buffer.append([0.1]), .started(generation: 2))
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID), [0.1])
        // The generation identifies recordings; finishing does not reset it.
        TestSupport.expectEqual(buffer.generation, 2)
        TestSupport.expectEqual(buffer.begin(requestID: Fixture.requestID), 3)
    }

    private static func testCancelPaths() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        buffer.append([0.1])
        TestSupport.expect(!buffer.cancel(requestID: Fixture.otherRequestID), "cancelled another request")
        TestSupport.expectEqual(buffer.recordingRequestID, Fixture.requestID)
        TestSupport.expect(buffer.cancel(requestID: Fixture.requestID), "did not cancel the recording")
        TestSupport.expectEqual(buffer.append([0.2]), .dropped)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
        buffer.begin(requestID: Fixture.otherRequestID)
        buffer.append([0.3])
        buffer.cancelAll()
        TestSupport.expectEqual(buffer.recordingRequestID, nil)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
        TestSupport.expectEqual(buffer.level, 0)
    }

    private static func testCapsAtMaxDuration() {
        let buffer = DictationSampleBuffer(maxDuration: 10 / DictationSampleBuffer.sampleRate)
        TestSupport.expectEqual(buffer.maxSampleCount, 10)
        let generation = buffer.begin(requestID: Fixture.requestID)
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.1, count: 6)), .started(generation: generation))
        TestSupport.expect(!buffer.hasReachedLimit, "limit reached early")
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.2, count: 6)), .reachedLimit(generation: generation))
        TestSupport.expect(buffer.hasReachedLimit, "limit not reported")
        TestSupport.expectEqual(buffer.append([0.3]), .dropped)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID),
                                [Float](repeating: 0.1, count: 6) + [Float](repeating: 0.2, count: 4))
        TestSupport.expect(!buffer.hasReachedLimit, "limit outlived the recording")

        // A first buffer that fills the cap reports the limit.
        buffer.begin(requestID: Fixture.otherRequestID)
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.1, count: 20)), .reachedLimit(generation: 2))
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID)?.count, 10)
    }

    private static func testDefaultCapIsFiveMinutes() {
        TestSupport.expectEqual(DictationSampleBuffer().maxSampleCount, 300 * 16_000)
    }

    private static func testLevelTracksSpeechAndStaysInRange() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        buffer.append([Float](repeating: 0, count: 1_600))
        TestSupport.expectEqual(buffer.level, 0)
        var previous: Float = 0
        for _ in 0..<6 {
            buffer.append(tone(1_600, amplitude: 0.3))
            TestSupport.expect(buffer.level > previous && buffer.level <= 1, "level did not rise toward speech")
            previous = buffer.level
        }
        TestSupport.expect(previous > 0.8, "loud speech reads low: \(previous)")
        buffer.append(tone(1_600, amplitude: 0.001))
        TestSupport.expect(buffer.level < previous && buffer.level > 0, "level did not release smoothly")
        buffer.append([Float](repeating: .nan, count: 160))
        TestSupport.expect(buffer.level.isFinite, "NaN input produced a NaN level")
        buffer.append([Float](repeating: 10, count: 160))
        TestSupport.expect(buffer.level <= 1, "clipped input exceeded 1")
        _ = buffer.finish(requestID: Fixture.requestID)
        TestSupport.expectEqual(buffer.level, 0)
    }

    /// The audio tap appends from its own thread while the main thread finishes the request. Every
    /// chunk lands either in the drained snapshot or is dropped; none is lost or retained.
    private static func testFinishDrainsAtomicallyUnderConcurrentAppends() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        let chunk = [Float](repeating: 0.25, count: 160)
        let accepted = LockedCounter()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<2_000 {
                switch buffer.append(chunk) {
                case .dropped: break
                default: accepted.increment()
                }
            }
            done.signal()
        }
        while buffer.recordedDuration < 0.05 { _ = buffer.level }
        let drained = buffer.finish(requestID: Fixture.requestID)!
        done.wait()
        TestSupport.expectEqual(drained.count, accepted.value * chunk.count)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
