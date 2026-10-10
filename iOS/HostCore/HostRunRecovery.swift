import Foundation

/// What a newly launched host inherits from the previous run's `status.json`.
struct HostRunRecovery: Equatable, Sendable {
    /// The dictation to treat as current. An in-progress request from another run comes back
    /// failed with `.interrupted`; publish it before reconciling.
    var current: DictationStatus?
    /// Seed for the reconciler, so the previous run's request is never restarted.
    var knownRequestIDs: Set<UUID>

    init(previous: StoreRead<HostStatus>, hostRunID: UUID, now: Date) {
        guard var dictation = previous.value?.dictation else {
            self.init(current: nil, knownRequestIDs: [])
            return
        }
        if dictation.hostRunID != hostRunID && !dictation.phase.isTerminal {
            dictation.phase = .failed
            dictation.error = .interrupted
            dictation.updatedAt = now
        }
        // Terminal requests are known too: a still-fresh record intent must not run them again.
        self.init(current: dictation, knownRequestIDs: [dictation.requestID])
    }

    init(current: DictationStatus?, knownRequestIDs: Set<UUID>) {
        self.current = current
        self.knownRequestIDs = knownRequestIDs
    }

    /// The run-change cleanup: results from other runs, or whose run cannot be read, are deleted.
    static func isFromAnotherRun(_ result: StoreRead<DictationResult>, hostRunID: UUID) -> Bool {
        result.value?.hostRunID != hostRunID
    }
}
