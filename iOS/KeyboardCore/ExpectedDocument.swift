import Foundation

/// The keyboard's own edits, recorded as expectations about what the text proxy will show. The proxy
/// reports context late and sends no callback for `insertText` or `deleteBackward`, so whether a reading
/// shows an edit of ours, has not shown it yet, or shows that something else happened can only be told
/// by comparing it with what each edit was issued against and what it should leave. Pure; in memory
/// only. The owner drops it on hiding and on a field change.
///
/// - **Record.** One expectation per edit: the graphemes it deleted and the text it inserted, the
///   proxy's reading it was issued against (`readingBefore`: field, text before and after the caret),
///   the text it should leave around the caret (`expected`), the `witness` (the text a reading must show
///   right before the caret to count as showing the edit; the inserted text unless given), the `match`
///   rule, the edit generation it was made at, and when it was issued. Kept oldest first.
/// - **Lifetime.** An expectation lives from its issue time for less than `lifetime`, and among at most
///   `capacity` (the oldest goes first). A clock earlier than its issue time ends it too. Expired ones
///   are invisible to every query at once, and dropped by `expire`, `observe` and `record`. Both bounds
///   are fixed per owner at `init`; the defaults are 32 and 30 s. `lifetime` may be `.infinity` (count
///   bound only) for an owner whose expectations live exactly as long as something it shows.
/// - **Showing an edit** (one expectation, one reading): the same field, and the text after the caret
///   exactly the expected one. `.exact`: the text before the caret is exactly the expected one too.
///   `.window`: hosts show a window of the field, and owners keep bounded copies, so the reading and
///   the expected text may each be a suffix of the other; the reading must also end with the witness,
///   and an empty reading shows only an empty expected text.
/// - **Attribution** (`attribute`; all live expectations against one reading, in issue order):
///   1. The caller's edit generation must equal that of the newest live expectation: the generation
///      advances on every edit the owner did not record here, so any other value means something else
///      edited the field, and every expectation is contradicted.
///   2. A reading of another field (or of none, for an edit made in an identified one) contradicts.
///   3. The proxy applies edits in issue order, so the newest expectation the reading shows confirms
///      itself and every older one in the field, whatever those left.
///   4. A newer one is pending while it has never been shown and the reading is a state the field
///      passes through before it shows: exactly its `readingBefore`, or exactly what an older one left.
///   5. Anything else contradicts, and so does every newer one, issued on top of it.
/// - **Shown.** `observe` latches `shown` on everything a reading confirms: from then on its
///   `readingBefore` is an older state of the field (the host undid the edit without a report yet),
///   never a lagging proxy. Nothing is consumed; owners remove what they no longer need.
///
/// The owners today and how each one's rule maps onto this one. Only the swipe anchors use this type
/// yet; the others are later migrations, and the differences listed are what those must reconcile.
/// - **Swipe anchors** (`KeyboardEditor`, the strip and the pending space): `.window`, the witness is the
///   swiped word, one expectation at a time, no time limit (`lifetime` `.infinity`). The editor adds the
///   conditions that are not about the reading: no selection, its own field, and its best estimate of the
///   text before the caret ending with the word.
/// - **`EditingCore.ownEdits`** (a host's reports of our edits): `.exact` on the whole context, at most
///   32 for 1 s. Differences: it keeps only hashes, no text; a report matching any owed state settles
///   the oldest owed one (consumption, not latching); an outside change does not end what is owed (no
///   generation rule); and a gesture's owed report limits which edits may be echoed (`echoCutoff`).
/// - **`UndoTracker`** (dictation undo): anchors of up to 24 characters before and after the insertion,
///   for 30 s, at an exact generation. Differences: the text after the caret is proven as a prefix as
///   far as visible, not by equality; a truncated window must show at least 16 characters of a long
///   insertion; both ends must be character boundaries; and no reading is ever attributed to it (any
///   callback ends it).
/// - **`ContextTail`, `contextWatchUntil`, `untrustedReading`** (the typing tail): 256 characters for at
///   most 10 s from when it is first held, never extended; up to 8 earlier readings and models count as
///   lagging, by exact equality and by suffix; a shorter view of the model also lets the model answer;
///   and a reading taken after a key abandoned a trackpad probe is trusted less. Its lag states are rule
///   4 here; the 10 s, never-extended lifetime and the unverified reading are not expressed yet.
/// - **Trackpad `CaretExpectation` and `ReportDebt`**: not covered; their adjustments are caret moves,
///   not text edits, and their reports are consumed in order.
struct ExpectedDocument: Equatable, Sendable {
    static let defaultCapacity = 32
    static let defaultLifetime: TimeInterval = 30

    struct ID: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    /// What the proxy shows: the field's identity and the text before and after the caret (nil reads as
    /// empty).
    struct Reading: Equatable, Sendable {
        var documentID: UUID?
        var before: String
        var after: String

        init(documentID: UUID?, before: String?, after: String?) {
            self.documentID = documentID
            self.before = before ?? ""
            self.after = after ?? ""
        }
    }

    enum Match: Equatable, Sendable {
        /// Either the reading or the expected text before the caret may be a suffix of the other.
        case window
        /// The text before the caret must be exactly the expected one.
        case exact
    }

    enum Verdict: Equatable, Sendable {
        /// The proxy has not shown the edit yet.
        case pending
        /// The proxy shows the edit, or a later one issued on top of it.
        case confirmed
        /// The field is not as the edit would leave it, and not on its way there.
        case contradicted
    }

    struct Expectation: Equatable, Sendable {
        let id: ID
        /// Graphemes deleted before the caret (a selection counts as one).
        let deleted: Int
        let inserted: String
        let witness: String
        let match: Match
        /// The proxy's reading the edit was issued against.
        let readingBefore: Reading
        /// What the edit should leave around the caret, in the same field.
        let expected: Reading
        let generation: Int
        let issuedAt: TimeInterval
        /// A reading has been seen showing the edit.
        fileprivate(set) var shown = false

        var documentID: UUID? { readingBefore.documentID }
    }

    /// Every live expectation's verdict for one reading, each list in issue order.
    struct Attribution: Equatable, Sendable {
        var confirmed: [ID]
        var contradicted: [ID]
        var pending: [ID]

        func verdict(of id: ID) -> Verdict? {
            if confirmed.contains(id) { return .confirmed }
            if contradicted.contains(id) { return .contradicted }
            if pending.contains(id) { return .pending }
            return nil
        }
    }

    let capacity: Int
    let lifetime: TimeInterval
    /// Oldest first, expired ones included until something drops them.
    private(set) var expectations: [Expectation] = []
    private var nextID: UInt64 = 0

    init(capacity: Int = defaultCapacity, lifetime: TimeInterval = defaultLifetime) {
        self.capacity = max(capacity, 1)
        self.lifetime = lifetime
    }

    subscript(id: ID) -> Expectation? {
        expectations.first { $0.id == id }
    }

    // MARK: Recording

    /// Records an edit just issued at `time` on `reading`, expected to leave `leaving` around the caret.
    @discardableResult
    mutating func record(deleting deleted: Int = 0, inserting inserted: String, on reading: Reading,
                         leaving result: (before: String, after: String), witness: String? = nil,
                         match: Match = .window, generation: Int, at time: TimeInterval) -> ID {
        expire(now: time)
        let id = ID(value: nextID)
        nextID &+= 1
        let expected = Reading(documentID: reading.documentID, before: result.before, after: result.after)
        expectations.append(Expectation(id: id, deleted: deleted, inserted: inserted, witness: witness ?? inserted,
                                        match: match, readingBefore: reading, expected: expected,
                                        generation: generation, issuedAt: time))
        if expectations.count > capacity { expectations.removeFirst(expectations.count - capacity) }
        return id
    }

    mutating func remove(_ id: ID) {
        expectations.removeAll { $0.id == id }
    }

    /// Forgets every expectation except `kept`.
    mutating func removeAll(keeping kept: Set<ID> = []) {
        expectations.removeAll { !kept.contains($0.id) }
    }

    /// Drops what has expired by `now`.
    mutating func expire(now: TimeInterval) {
        let lifetime = lifetime
        expectations.removeAll { !Self.isLive($0, now: now, lifetime: lifetime) }
    }

    // MARK: Attribution

    /// The verdict on one expectation for `reading`, judged among all live ones; nil if it is not
    /// recorded or has expired.
    func verdict(of id: ID, for reading: Reading, generation: Int, now: TimeInterval) -> Verdict? {
        attribute(reading, generation: generation, now: now).verdict(of: id)
    }

    /// Every live expectation's verdict for `reading`, at the caller's edit `generation`.
    func attribute(_ reading: Reading, generation: Int, now: TimeInterval) -> Attribution {
        var attribution = Attribution(confirmed: [], contradicted: [], pending: [])
        let live = expectations.filter { Self.isLive($0, now: now, lifetime: lifetime) }
        guard let newest = live.last else { return attribution }
        guard generation == newest.generation else {
            attribution.contradicted = live.map(\.id)
            return attribution
        }
        let newestShown = live.lastIndex { Self.shows($0, reading) }
        var broken = false
        for (index, expectation) in live.enumerated() {
            guard expectation.documentID == reading.documentID else {
                attribution.contradicted.append(expectation.id)
                continue
            }
            if let newestShown, index <= newestShown {
                attribution.confirmed.append(expectation.id)
            } else if !broken, !expectation.shown,
                      expectation.readingBefore == reading
                        || live[..<index].contains(where: { $0.expected == reading }) {
                attribution.pending.append(expectation.id)
            } else {
                broken = true
                attribution.contradicted.append(expectation.id)
            }
        }
        return attribution
    }

    /// Latches `shown` on every expectation `reading` confirms, and drops what has expired.
    mutating func observe(_ reading: Reading, generation: Int, now: TimeInterval) {
        expire(now: now)
        let confirmed = Set(attribute(reading, generation: generation, now: now).confirmed)
        guard !confirmed.isEmpty else { return }
        for index in expectations.indices where confirmed.contains(expectations[index].id) {
            expectations[index].shown = true
        }
    }

    private static func isLive(_ expectation: Expectation, now: TimeInterval, lifetime: TimeInterval) -> Bool {
        let age = now - expectation.issuedAt
        return age >= 0 && age < lifetime
    }

    /// Whether `reading` shows what `expectation`'s edit left (its match rule; see the type's comment).
    private static func shows(_ expectation: Expectation, _ reading: Reading) -> Bool {
        let expected = expectation.expected
        guard reading.documentID == expected.documentID, reading.after == expected.after else { return false }
        switch expectation.match {
        case .exact:
            return reading.before == expected.before
        case .window:
            guard !expected.before.isEmpty else { return reading.before.isEmpty }
            guard !reading.before.isEmpty, reading.before.hasSuffix(expectation.witness) else { return false }
            return reading.before.hasSuffix(expected.before) || expected.before.hasSuffix(reading.before)
        }
    }
}
