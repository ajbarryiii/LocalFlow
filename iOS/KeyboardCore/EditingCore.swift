import Foundation

/// The text document as the editing side sees it: `UITextDocumentProxy` in the keyboard, a fake in
/// tests. Context is read in memory only and never stored beyond the rules below.
protocol TextDocument: AnyObject {
    /// The field's identity (`documentIdentifier`); nil while a field connects or goes away.
    var documentID: UUID? { get }
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    /// Text is selected (the selection's text is never read beyond whether it is empty).
    var hasSelection: Bool { get }
    func insertText(_ text: String)
    func deleteBackward()
}

/// Whatever issues its own adjustments and can tell its own callbacks apart: the trackpad.
protocol AdjustmentOwner: AnyObject {
    /// A gesture is running or settling.
    var isActive: Bool { get }
    /// `textDidChange`: consumes the expectation it matches; false for an outside change.
    func acknowledge(before: String?, after: String?) -> Bool
    /// `textDidChange`, asked before anything else: only a report of an adjustment as it was issued
    /// (WebKit reports each adjustment so first), which may look like the report of our last edit.
    func acknowledgeAsIssued(before: String?, after: String?) -> Bool
    /// `selectionDidChange`: whether it matches an adjustment still owed a callback; consumes nothing.
    func fits(before: String?, after: String?) -> Bool
    /// Only edits made before this may be echoed now (nil: any), while adjustments still owe reports.
    var echoCutoff: TimeInterval? { get }
    /// A `textDidChange` that is not an echo of our edits: it pays the oldest report owed.
    func reportArrived()
}

extension AdjustmentOwner {
    func acknowledgeAsIssued(before: String?, after: String?) -> Bool { false }
    var echoCutoff: TimeInterval? { nil }
    func reportArrived() {}
}

/// The editing side's bookkeeping, independent of UIKit (ARCHITECTURE.md, "Undo ownership v2" and
/// "Typing model v2: immediate execution"):
/// - **Field identity.** A nil `documentIdentifier` never matches anything; a different one ends
///   everything that belonged to the old field.
/// - **Edit generation.** Advances on every edit the current owner did not make: typing, each delete,
///   a dictated insertion, a focus change, hiding, and any host callback nothing of ours explains.
///   Owners (a trackpad gesture, a dictated insertion) remember the generation they started at.
/// - **Attribution.** A callback is the trackpad's only if it matches the expected outcome of an
///   adjustment still owed one (consumed once). A callback that shows the context one of our own
///   recent inserts or deletes left is a report of our edits (`ownEdit`, at most one per edit, within
///   `ownEditLifetime`): never an outside change, so it never ends a gesture or anything typed. A
///   report a gesture still owes is never taken for the echo of an edit made after its adjustment.
///   Anything else is an outside change.
/// - **Dictation undo**, through `UndoTracker`, never while text is selected, and failing closed:
///   every callback that is not a pending trackpad adjustment's own ends it for good, our own edits'
///   reports included (UIKit sends none for them, so no allowance is made; a host that reports them,
///   such as WebKit, loses Undo). No time windows.
final class EditingCore {
    enum CallbackOutcome: Equatable {
        /// An outcome of a pending trackpad adjustment.
        case own
        /// The report of one of our own inserts or deletes. The undo is gone; nothing else changes.
        case ownEdit
        /// Anything else: the generation advanced, and the undo is gone.
        case outside
        /// Another field (or none): everything bound to the old one is gone.
        case newField
    }

    /// Our own recent edits whose reports may still arrive, at most this many, for at most this long.
    static let ownEditLimit = 32
    static let ownEditLifetime: TimeInterval = 1

    let document: TextDocument
    weak var adjustments: AdjustmentOwner?
    private(set) var documentID: UUID?
    private(set) var generation = 0
    private(set) var undo = UndoTracker()
    /// The contexts our own recent edits left, as hashes (no text is kept), oldest first.
    private var ownEdits: [(state: String, at: TimeInterval)] = []

    init(document: TextDocument) {
        self.document = document
    }

    // MARK: Fields

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset() {
        documentID = document.documentID
        invalidate()
    }

    /// The keyboard is hiding: forget the field and everything bound to it, at once.
    func hide() {
        documentID = nil
        invalidate()
    }

    /// The proxy already serves a field other than the one the last callback showed (a key typed before
    /// the new field's first callback): adopt it now, as that callback would. True if it changed.
    func adoptCurrentField() -> Bool {
        guard document.documentID != documentID else { return false }
        documentID = document.documentID
        invalidate()
        return true
    }

    /// An edit the current owner did not make: typing, a delete, a caret move by the trackpad.
    func userEdit() {
        generation &+= 1
        undo.invalidate()
    }

    private func invalidate() {
        generation &+= 1
        undo.invalidate()
        ownEdits = []
    }

    // MARK: Callbacks

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback, arriving at `now`.
    func hostChanged(textChanged: Bool, now: TimeInterval) -> CallbackOutcome {
        let current = document.documentID
        guard let current, current == documentID else {
            documentID = current
            invalidate()
            return .newField
        }
        let before = document.contextBefore
        let after = document.contextAfter
        // A gesture's report of its oldest adjustment as issued (WebKit) shows the context it was issued in,
        // often the one our last key left: the gesture must hear it, or it reads that stale caret as current.
        // A host that also reported our edits would report that key first; then its own report comes
        // next and is taken below.
        if textChanged, let adjustments, adjustments.isActive, adjustments.acknowledgeAsIssued(before: before, after: after) {
            adjustments.reportArrived()
            return .own
        }
        // Reports arrive in order: those of our own edits come before those of a gesture begun after
        // them, and one of them can look like a gesture's outcome (a probe not yet landed). A report still
        // owed for an adjustment comes before the echo of any edit made after it (ARCHITECTURE.md, "Typing
        // model v2": late gesture reports are never echoes), so while one is owed only edits made before
        // `echoCutoff` may be echoed now: none while a finished gesture owes reports (an edit made since ends
        // a gesture, and deleting what was typed can bring back the very state an earlier edit left, so an
        // owed report showing it is no echo).
        if consumeOwnEdit(Self.state(before: before, after: after), madeBefore: adjustments?.echoCutoff, now: now) {
            undo.invalidate()
            return .ownEdit
        }
        if textChanged { adjustments?.reportArrived() }
        if let adjustments, adjustments.isActive,
           textChanged ? adjustments.acknowledge(before: before, after: after) : adjustments.fits(before: before, after: after) {
            return .own
        }
        // Nothing of ours explains it: the undo is gone, and so is anything bound to the document as it
        // was. A report a finished gesture still owed is no different (it has been counted above).
        undo.invalidate()
        generation &+= 1
        return .outside
    }

    /// Call right after one of our own inserts or deletes: the context it left (read from the proxy,
    /// which shows our edits at once), so the host's report of it is never taken for an outside change.
    func recordOwnEdit(now: TimeInterval) {
        ownEdits.removeAll { now - $0.at > Self.ownEditLifetime || now < $0.at }
        ownEdits.append((Self.state(before: document.contextBefore, after: document.contextAfter), now))
        if ownEdits.count > Self.ownEditLimit { ownEdits.removeFirst(ownEdits.count - Self.ownEditLimit) }
    }

    /// A report showing what one of our recent edits left. Each edit owes at most one report, and a
    /// report shows the field as it is when it arrives (after later edits, too), so it may show any of
    /// the states still owed; it settles the oldest. Only edits made before `madeBefore` (a gesture's
    /// report still owed) can be reported yet.
    private func consumeOwnEdit(_ state: String, madeBefore owedSince: TimeInterval?, now: TimeInterval) -> Bool {
        ownEdits.removeAll { now - $0.at > Self.ownEditLifetime || now < $0.at }
        let reportable = ownEdits.filter { edit in owedSince.map { edit.at < $0 } ?? true }
        guard reportable.contains(where: { $0.state == state }) else { return false }
        ownEdits.removeFirst()
        return true
    }

    private static func state(before: String?, after: String?) -> String {
        FieldFingerprint.hash((before ?? "") + "\u{0}" + (after ?? ""))
    }

    // MARK: Dictation and undo

    /// Inserts dictated text and records it, with its anchors, for undo.
    func insertDictation(_ text: String, now: TimeInterval) {
        guard !text.isEmpty else { return }
        let before = document.contextBefore
        let after = document.contextAfter
        let replacesSelection = document.hasSelection
        generation &+= 1
        document.insertText(text)
        recordOwnEdit(now: now)
        // Text that replaced a selection is not undone by deleting it alone.
        guard !replacesSelection else { return undo.invalidate() }
        undo.recordInsertion(text, contextBefore: before, contextAfter: after, documentID: documentID,
                             generation: generation, at: now)
    }

    func canUndo(now: TimeInterval) -> Bool {
        guard adjustments?.isActive != true, !document.hasSelection else { return false }
        return undo.isOffered(documentID: currentDocumentID, generation: generation, before: document.contextBefore,
                              after: document.contextAfter, now: now)
    }

    /// Starts undoing and deletes what the context proves. Returns `.wait` while the context has not
    /// shown the last deletion yet (call `continueUndo` later), else how it ended.
    func beginUndo(now: TimeInterval) -> UndoTracker.Step {
        guard adjustments?.isActive != true, !undo.isUndoing, !document.hasSelection else { return .stopped }
        return run(undo.begin(documentID: currentDocumentID, generation: generation, before: document.contextBefore,
                              after: document.contextAfter, now: now), now: now)
    }

    func continueUndo(now: TimeInterval) -> UndoTracker.Step {
        guard undo.isUndoing else { return .stopped }
        return run(nextUndoStep(now: now), now: now)
    }

    func expireUndo(now: TimeInterval) {
        undo.expire(now: now)
    }

    private var currentDocumentID: UUID? {
        guard let current = document.documentID, current == documentID else { return nil }
        return current
    }

    private func nextUndoStep(now: TimeInterval) -> UndoTracker.Step {
        undo.step(documentID: currentDocumentID, generation: generation, before: document.contextBefore,
                  after: document.contextAfter, now: now)
    }

    private func run(_ first: UndoTracker.Step, now: TimeInterval) -> UndoTracker.Step {
        var step = first
        while case .delete(let count) = step {
            // Deleting with text selected would delete the selection instead.
            guard !document.hasSelection else {
                undo.invalidate()
                return .stopped
            }
            for _ in 0 ..< count { document.deleteBackward() }
            recordOwnEdit(now: now)
            step = nextUndoStep(now: now)
        }
        return step
    }
}
