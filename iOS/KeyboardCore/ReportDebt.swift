import Foundation

/// The reports the host still owes for this keyboard's caret adjustments, at the level of callbacks
/// (ARCHITECTURE.md, "Typing model v2": late gesture reports are never echoes). Every adjustment issued
/// owes one `textDidChange`, or two where the host reports each adjustment twice (WebKit) or is not known
/// to report once, whatever the gesture that issued it settled or expects: a probe and the rollback a
/// cancellation issued, a guard's repairs, and the reports of an earlier gesture a new one begins with all
/// count. Callbacks pay the oldest report owed. It never says which adjustment a callback reports.
///
/// Kept for the current field only, until paid, with no time limit: a report later than any timeout is
/// still owed. A host that never sends some of them keeps the debt (bounded by `limit`), which only keeps
/// callbacks from being taken for echoes of our edits; hosts were measured to send no such echoes. Holds
/// no text: issue times and the field's identity.
struct ReportDebt: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var issuedAt: TimeInterval
        /// Reports still to come.
        var remaining: Int
        /// The second of them is assumed: the host was not known to report once.
        var assumedTwice: Bool
    }

    /// Adjustments remembered at most; the oldest go first.
    static let limit = 64
    private(set) var documentID: UUID?
    private(set) var entries: [Entry] = []

    /// An adjustment was issued in `documentID`, whose host reports each adjustment twice (true), once
    /// (false) or is not known to (nil). Another field's debt goes: its callbacks no longer reach us.
    mutating func issued(at time: TimeInterval, in documentID: UUID, reportsTwice: Bool?) {
        if documentID != self.documentID {
            entries = []
            self.documentID = documentID
        }
        entries.append(Entry(issuedAt: time, remaining: reportsTwice == false ? 1 : 2, assumedTwice: reportsTwice == nil))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The field is now known to report each adjustment twice or once. Once: the second report assumed
    /// for each adjustment issued before that was known never comes (one already paid toward it was its
    /// only report, since callbacks pay the oldest first).
    mutating func learned(reportsTwice: Bool, in documentID: UUID) {
        guard documentID == self.documentID else { return }
        for index in entries.indices where entries[index].assumedTwice {
            entries[index].assumedTwice = false
            if !reportsTwice { entries[index].remaining -= 1 }
        }
        entries.removeAll { $0.remaining <= 0 }
    }

    /// A `textDidChange` in `documentID` that is not an echo of our edits: it pays the oldest report owed.
    /// False when none was owed there.
    @discardableResult
    mutating func paid(in documentID: UUID?) -> Bool {
        guard let documentID, documentID == self.documentID, !entries.isEmpty else { return false }
        entries[0].remaining -= 1
        if entries[0].remaining <= 0 { entries.removeFirst() }
        return true
    }

    /// When the oldest adjustment still owed a report in `documentID` was issued.
    func oldest(in documentID: UUID?) -> TimeInterval? {
        guard let documentID, documentID == self.documentID else { return nil }
        return entries.first?.issuedAt
    }

    /// How many reports `documentID` still owes, assumed ones included.
    func owed(in documentID: UUID?) -> Int {
        guard let documentID, documentID == self.documentID else { return 0 }
        return entries.reduce(0) { $0 + $1.remaining }
    }

    /// The reports `documentID` surely still owes (not the assumed second ones), by issue time: what a new
    /// gesture expects before its own.
    func sure(in documentID: UUID?) -> [TimeInterval] {
        guard let documentID, documentID == self.documentID else { return [] }
        return entries.flatMap { Array(repeating: $0.issuedAt, count: $0.remaining - ($0.assumedTwice ? 1 : 0)) }
    }
}
