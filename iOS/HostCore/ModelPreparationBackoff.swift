import Foundation

/// The bounded backoff between failed model preparations (ARCHITECTURE.md, "Transcription"). After the
/// n-th failure in a row, the next automatic attempt waits `delay(afterFailures: n)`: 5 s, doubling, at
/// most 60 s. A success resets it. Pure, so the engine's clock drives it and tests are deterministic.
struct ModelPreparationBackoff: Equatable, Sendable {
    static let initialDelay: TimeInterval = 5
    static let maximumDelay: TimeInterval = 60

    private(set) var consecutiveFailures = 0
    private(set) var lastFailureAt: Date?

    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Capped before it can overflow: 2^(n-1) passes the cap long before Double's range.
        let steps = min(failures - 1, 16)
        return min(initialDelay * Double(1 << steps), maximumDelay)
    }

    /// When the next automatic attempt is allowed, or nil when one is allowed now whatever the clock.
    var nextAttemptAt: Date? {
        lastFailureAt.map { $0.addingTimeInterval(Self.delay(afterFailures: consecutiveFailures)) }
    }

    /// A backward clock jump allows an attempt at once, so the wait is never longer than the cap.
    func allowsAttempt(now: Date) -> Bool {
        guard let lastFailureAt else { return true }
        let elapsed = now.timeIntervalSince(lastFailureAt)
        return elapsed < 0 || elapsed >= Self.delay(afterFailures: consecutiveFailures)
    }

    mutating func recordFailure(at date: Date) {
        consecutiveFailures += 1
        lastFailureAt = date
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        lastFailureAt = nil
    }
}
