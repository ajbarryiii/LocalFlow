import Foundation

/// The bounded backoff between failed model preparations (ARCHITECTURE.md, "Transcription").
enum ModelPreparationBackoffTests {
    static var tests: [TestCase] {
        [
            ("noFailureAllowsAnAttempt", testNoFailureAllowsAnAttempt),
            ("delayDoublesUpToTheCap", testDelayDoublesUpToTheCap),
            ("attemptWaitsOutTheDelay", testAttemptWaitsOutTheDelay),
            ("consecutiveFailuresGrowTheDelay", testConsecutiveFailuresGrowTheDelay),
            ("backwardClockJumpAllowsAnAttempt", testBackwardClockJumpAllowsAnAttempt),
            ("successResets", testSuccessResets),
        ]
    }

    private static let now = Fixture.now

    private static func testNoFailureAllowsAnAttempt() {
        let backoff = ModelPreparationBackoff()
        TestSupport.expect(backoff.allowsAttempt(now: now), "no failure yet, but no attempt allowed")
        TestSupport.expectEqual(backoff.nextAttemptAt, nil)
        TestSupport.expectEqual(ModelPreparationBackoff.delay(afterFailures: 0), 0)
    }

    private static func testDelayDoublesUpToTheCap() {
        let delays = (1...7).map { ModelPreparationBackoff.delay(afterFailures: $0) }
        TestSupport.expectEqual(delays, [5, 10, 20, 40, 60, 60, 60])
        TestSupport.expectEqual(ModelPreparationBackoff.delay(afterFailures: 10_000), ModelPreparationBackoff.maximumDelay)
        TestSupport.expectEqual(ModelPreparationBackoff.maximumDelay, 60)
    }

    private static func testAttemptWaitsOutTheDelay() {
        var backoff = ModelPreparationBackoff()
        backoff.recordFailure(at: now)
        TestSupport.expect(!backoff.allowsAttempt(now: now), "retried at once after a failure")
        TestSupport.expect(!backoff.allowsAttempt(now: now + 4.999), "retried before the delay")
        TestSupport.expect(backoff.allowsAttempt(now: now + 5), "not retried after the delay")
        TestSupport.expectEqual(backoff.nextAttemptAt, now + 5)
    }

    private static func testConsecutiveFailuresGrowTheDelay() {
        var backoff = ModelPreparationBackoff()
        var at = now
        for expected in [5.0, 10, 20, 40, 60, 60] {
            backoff.recordFailure(at: at)
            TestSupport.expect(!backoff.allowsAttempt(now: at + expected - 0.001), "retried before \(expected) s")
            TestSupport.expect(backoff.allowsAttempt(now: at + expected), "not retried after \(expected) s")
            at += expected + 1
        }
        TestSupport.expectEqual(backoff.consecutiveFailures, 6)
    }

    /// A backward clock jump never holds preparation off for longer than the cap: it allows an attempt.
    private static func testBackwardClockJumpAllowsAnAttempt() {
        var backoff = ModelPreparationBackoff()
        backoff.recordFailure(at: now)
        TestSupport.expect(backoff.allowsAttempt(now: now - 0.001), "a backward clock jump held preparation off")
        TestSupport.expect(backoff.allowsAttempt(now: now - 3_600), "a backward clock jump held preparation off")
    }

    private static func testSuccessResets() {
        var backoff = ModelPreparationBackoff()
        backoff.recordFailure(at: now)
        backoff.recordFailure(at: now + 10)
        backoff.recordSuccess()
        TestSupport.expect(backoff.allowsAttempt(now: now + 10), "a success left the backoff in place")
        TestSupport.expectEqual(backoff.consecutiveFailures, 0)
        backoff.recordFailure(at: now + 20)
        TestSupport.expect(backoff.allowsAttempt(now: now + 25), "the delay did not restart from the first step")
    }
}
