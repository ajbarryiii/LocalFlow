// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
import Foundation

/// Whether a finished dictation may be watched for corrections (DESIGN §3.4,
/// §3.5). Decided on the main thread when the result arrives.
enum CorrectionEligibility {
    /// - `snapshotRevision`: the dictionary revision the audio was decoded with.
    /// - `currentRevision`: the revision now. An edit after recording stopped
    ///   (even before the model ran) makes the retained session obsolete.
    /// - `watchGeneration`: the watcher generation when recording stopped;
    ///   `currentGeneration` differs once anything cancelled corrections.
    static func isEligible(suggestionsEnabled: Bool, dictionaryReadable: Bool, retained: Bool,
                           snapshotRevision: UInt64, currentRevision: UInt64,
                           watchGeneration: UInt64, currentGeneration: UInt64,
                           usedMacro: Bool, shouldPressEnter: Bool, output: String) -> Bool {
        suggestionsEnabled && dictionaryReadable && retained
            && snapshotRevision == currentRevision && watchGeneration == currentGeneration
            && !usedMacro && !shouldPressEnter && !output.isEmpty
            && output.utf8.count <= CorrectionCandidates.maxBytes
    }
}

/// At most one retained correction session (DESIGN §3.4). Not thread-safe:
/// the owner uses it on one queue (the model queue). Staleness is by id and
/// expiry by deadline; the owner also schedules a hard expiry with `expire`.
final class CorrectionSessionStore<Payload> {
    static var defaultMaxBytes: Int { 16 << 20 }
    static var defaultLifetime: TimeInterval { 90 }

    private struct Session {
        let id: UInt64
        let payload: Payload
        let deadline: TimeInterval
    }

    private let maxBytes: Int
    private let lifetime: TimeInterval
    private var nextID: UInt64 = 1
    private var current: Session?

    init(maxBytes: Int = defaultMaxBytes, lifetime: TimeInterval = defaultLifetime) {
        self.maxBytes = maxBytes
        self.lifetime = lifetime
    }

    var currentID: UInt64? { current?.id }

    /// Replaces any previous session. Over the byte limit nothing is retained.
    func retain(_ payload: Payload, bytes: Int, now: TimeInterval) -> UInt64? {
        current = nil
        guard bytes <= maxBytes else { return nil }
        let id = nextID
        nextID += 1
        current = Session(id: id, payload: payload, deadline: now + lifetime)
        return id
    }

    func session(id: UInt64, now: TimeInterval) -> Payload? {
        guard let current else { return nil }
        if now >= current.deadline {
            self.current = nil
            return nil
        }
        return current.id == id ? current.payload : nil
    }

    /// Drops the session only if it is still the one with `id`.
    func expire(id: UInt64) {
        if current?.id == id { current = nil }
    }

    func discard() { current = nil }
}
