import Foundation

/// The keyboard's in-memory copy of the result files, and when it must read them again. Reading lists
/// and decodes every `result-<UUID>.json` (after purging expired ones), so the keyboard reads only
/// when a result may have arrived or a known file needs cleaning up. Every other pass, including the
/// status passes that drive the level meter, decides from this copy. Held per keyboard instance,
/// in memory, and only while visible; a result leaves it once it is no longer fresh.
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

    /// How soon a read is retried after the directory could not be listed, and how often a file that
    /// could not be decoded is retried. Slower than the pass; it only costs reads while that lasts.
    static let retryInterval: TimeInterval = 1
    /// How soon a file is purged again when it was still there after the read that should have
    /// purged it (a failed removal).
    static let cleanupRetryInterval: TimeInterval = 5

    /// The fresh decoded results of the last successful read, minus those discarded since. In
    /// file-name order; the ledger sorts them.
    private(set) var results: [DictationResult] = []
    private var resultPending = false
    /// The last successful read.
    private var readAt: Date?
    /// The last read whose directory listing failed, since the last successful one.
    private var listingFailedAt: Date?
    /// Every request ID the last read listed, decodable or not.
    private var listed: Set<UUID> = []
    /// The completed request and the host run the status reported at the last read.
    private var completionAtRead: UUID?
    private var hostRunAtRead: UUID?
    /// When each file the last read listed is due to be purged (or purged again).
    private var cleanupAt: [UUID: Date] = [:]
    private var hasUnreadable = false

    /// Call when `.result` is delivered.
    mutating func resultPosted() {
        resultPending = true
    }

    /// Call when the keyboard hides: no transcript stays in memory, and the next pass reads again.
    mutating func reset() {
        self = KeyboardResultInbox()
    }

    /// Drops requests whose files are gone: the ledger consumed them, or a read of the file found it
    /// absent (another claimant removed it).
    mutating func discard(_ requestIDs: Set<UUID>) {
        results.removeAll { requestIDs.contains($0.requestID) }
        for requestID in requestIDs { cleanupAt[requestID] = nil }
    }

    /// Whether this pass must read the result files, and why; nil to decide from memory.
    func readReason(status: StoreRead<HostStatus>, now: Date) -> ReadReason? {
        let tolerance = DictationProtocol.clockSkewTolerance
        if let failedAt = listingFailedAt, now >= failedAt - tolerance, now < failedAt + Self.retryInterval {
            return nil
        }
        guard let readAt else { return .firstRead }
        if resultPending { return .resultPosted }
        if now < readAt - tolerance { return .clockMovedBack }
        if let status = status.value {
            if let dictation = status.dictation, dictation.phase == .completed,
               !listed.contains(dictation.requestID), dictation.requestID != completionAtRead {
                return .completionReported
            }
            if status.hostRunID != hostRunAtRead { return .hostRunChanged }
        }
        if let next = cleanupAt.values.min(), now > next { return .expiry }
        if hasUnreadable, now >= readAt + Self.retryInterval { return .unreadableRetry }
        return nil
    }

    /// Records a successful read: `files` is what each listed file held, `status` the status of the
    /// same pass. Purging ran just before, so a file that should have been purged failed to be.
    mutating func didRead(_ files: [(requestID: UUID, read: StoreRead<DictationResult>)],
                          status: StoreRead<HostStatus>, now: Date) {
        resultPending = false
        readAt = now
        listingFailedAt = nil
        listed = Set(files.map { $0.requestID })
        results = files.compactMap { $0.read.value }.filter { Self.isFresh($0, now: now) }
        var next: [UUID: Date] = [:]
        for (requestID, read) in files {
            switch read {
            case .absent:
                continue
            case .value(let result):
                next[requestID] = Self.isFresh(result, now: now) ? result.createdAt + DictationProtocol.resultTTL
                    : now + Self.cleanupRetryInterval
            case .unreadable, .incompatible:
                // Purged by modification date, which is no later than the first read that saw it.
                let due = cleanupAt[requestID] ?? now + DictationProtocol.resultTTL
                next[requestID] = due > now ? due : now + Self.cleanupRetryInterval
            }
        }
        cleanupAt = next
        hasUnreadable = files.contains { $0.read == .unreadable }
        // A status that cannot be read says nothing new; keep what the last one said.
        if let status = status.value {
            completionAtRead = status.dictation.flatMap { $0.phase == .completed ? $0.requestID : nil }
            hostRunAtRead = status.hostRunID
        }
    }

    /// Records a read whose directory listing failed. Nothing it was due for is acknowledged, and what
    /// was read before stays; the read is retried after `retryInterval`.
    mutating func listingFailed(now: Date) {
        listingFailedAt = now
    }

    /// One pass: drops results that are no longer fresh, then, if a read is due, purges expired
    /// results and lists and decodes every result file. Returns why it read, or nil if it decided
    /// from memory.
    @discardableResult
    mutating func update(from store: SharedDictationStore, status: StoreRead<HostStatus>, now: Date) -> ReadReason? {
        results.removeAll { !Self.isFresh($0, now: now) }
        guard let reason = readReason(status: status, now: now) else { return nil }
        store.purgeExpiredResults(now: now)
        guard let requestIDs = store.listResultRequestIDs() else {
            listingFailed(now: now)
            return reason
        }
        didRead(requestIDs.map { (requestID: $0, read: store.readResult(requestID: $0)) }, status: status, now: now)
        return reason
    }

    private static func isFresh(_ result: DictationResult, now: Date) -> Bool {
        DictationProtocol.isFresh(result.createdAt, ttl: DictationProtocol.resultTTL, now: now)
    }
}
