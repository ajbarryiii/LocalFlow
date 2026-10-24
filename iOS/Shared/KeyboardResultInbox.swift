import Foundation

/// The keyboard's in-memory copy of the result files, and when it must read them again. Reading lists
/// and decodes every `result-<UUID>.json` (after purging expired ones), so the keyboard reads only
/// when a result may have arrived or a known file needs cleaning up. Every other pass, including the
/// status passes that drive the level meter, decides from this copy. Held per keyboard instance,
/// in memory, and only while visible.
struct KeyboardResultInbox: Equatable, Sendable {
    /// Why a pass must read the result files.
    enum ReadReason: Equatable, Sendable {
        /// Nothing has been read since this instance appeared: results may have arrived while it was
        /// hidden, when no notification is observed.
        case firstRead
        /// A `.result` notification arrived. Deliveries coalesce, so a read lists every file.
        case resultPosted
        /// The status reports a completed request the last read did not list. The host writes
        /// `result-R.json` before it publishes R as completed, so a result arrived even if its
        /// `.result` was missed.
        case completionReported
        /// The status names a host run other than the last read's. A new run deletes the previous
        /// runs' results at launch, so a cached result may be gone.
        case hostRunChanged
        /// A file the last read saw has expired and must be purged.
        case expiry
        /// The last read found a file it could not decode (for example a transient I/O error).
        case unreadableRetry
        /// The clock went back past the last read; purging and freshness are judged again.
        case clockMovedBack
    }

    /// How often a file that could not be decoded is retried. Slower than the pass, which only
    /// costs reads while such a file exists.
    static let unreadableRetryInterval: TimeInterval = 1

    /// The decoded results of the last read, minus those discarded since. In file-name order; the
    /// ledger sorts them.
    private(set) var results: [DictationResult] = []
    private var resultPending = false
    private var readAt: Date?
    /// Every request ID the last read listed, decodable or not.
    private var listed: Set<UUID> = []
    /// The completed request and the host run the status reported at the last read.
    private var completionAtRead: UUID?
    private var hostRunAtRead: UUID?
    /// Files the last read could not decode are purged by modification date, which is no later than
    /// the read, so they are expired by `readAt + resultTTL`.
    private var undecodedExpireAt: Date?
    private var hasUnreadable = false

    /// Call when `.result` is delivered.
    mutating func resultPosted() {
        resultPending = true
    }

    /// Call when the keyboard hides: no transcript stays in memory, and the next pass reads again.
    mutating func reset() {
        self = KeyboardResultInbox()
    }

    /// Drops results that need no further reading, such as requests the ledger consumed.
    mutating func discard(_ requestIDs: Set<UUID>) {
        results.removeAll { requestIDs.contains($0.requestID) }
    }

    /// Whether this pass must read the result files, and why; nil to decide from memory.
    func readReason(status: StoreRead<HostStatus>, now: Date) -> ReadReason? {
        guard let readAt else { return .firstRead }
        if resultPending { return .resultPosted }
        if now < readAt - DictationProtocol.clockSkewTolerance { return .clockMovedBack }
        if let status = status.value {
            if let dictation = status.dictation, dictation.phase == .completed,
               !listed.contains(dictation.requestID), dictation.requestID != completionAtRead {
                return .completionReported
            }
            if status.hostRunID != hostRunAtRead { return .hostRunChanged }
        }
        let expiries = results.map { $0.createdAt + DictationProtocol.resultTTL } + [undecodedExpireAt].compactMap { $0 }
        if let next = expiries.min(), now > next { return .expiry }
        if hasUnreadable, now >= readAt + Self.unreadableRetryInterval { return .unreadableRetry }
        return nil
    }

    /// Records a read: `files` is what each listed file held, `status` the status of the same pass.
    mutating func didRead(_ files: [(requestID: UUID, read: StoreRead<DictationResult>)],
                          status: StoreRead<HostStatus>, now: Date) {
        resultPending = false
        readAt = now
        listed = Set(files.map(\.requestID))
        results = files.compactMap(\.read.value)
        let undecoded = files.filter { $0.read == .unreadable || $0.read == .incompatible }
        undecodedExpireAt = undecoded.isEmpty ? nil : now + DictationProtocol.resultTTL
        hasUnreadable = undecoded.contains { $0.read == .unreadable }
        // A status that cannot be read says nothing new; keep what the last one said.
        if let status = status.value {
            completionAtRead = status.dictation.flatMap { $0.phase == .completed ? $0.requestID : nil }
            hostRunAtRead = status.hostRunID
        }
    }

    /// One pass: if a read is due, purges expired results, then lists and decodes every result file.
    /// Returns why it read, or nil if it decided from memory.
    @discardableResult
    mutating func update(from store: SharedDictationStore, status: StoreRead<HostStatus>, now: Date) -> ReadReason? {
        guard let reason = readReason(status: status, now: now) else { return nil }
        store.purgeExpiredResults(now: now)
        let files = store.resultRequestIDs().map { (requestID: $0, read: store.readResult(requestID: $0)) }
        didRead(files, status: status, now: now)
        return reason
    }
}
