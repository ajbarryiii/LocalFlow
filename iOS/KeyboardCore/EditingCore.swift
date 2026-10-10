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
    /// A gesture is running or settling; edits wait for it.
    var isActive: Bool { get }
    /// `textDidChange`: consumes the expectation it matches; false for an outside change.
    func acknowledge(before: String?, after: String?) -> Bool
    /// `selectionDidChange`: whether it matches an adjustment still owed a callback; consumes nothing.
    func fits(before: String?, after: String?) -> Bool
}

/// The editing side's bookkeeping, independent of UIKit (ARCHITECTURE.md, "Undo ownership v2" and
/// "Queued edits are bound to a field"):
/// - **Field identity.** A nil `documentIdentifier` never matches anything; a different one ends
///   everything that belonged to the old field.
/// - **Edit generation.** Advances on every edit the current owner did not make: typing, each delete,
///   a dictated insertion, a focus change, hiding, and any host callback no pending operation of
///   ours explains. Owners remember the generation they started at.
/// - **Attribution.** A `textDidChange` is ours only if it matches the expected outcome of a pending
///   operation we issued (the trackpad's adjustments, the insertion, undo deletions), consumed once;
///   the insertion and the deletions stop owing one shortly after they were issued
///   (`UndoTracker.callbackTimeout`). A `selectionDidChange` is ours only if it matches a trackpad
///   adjustment still owed a callback (our insertions and deletions were never measured to cause
///   one); any other is an outside change and ends the undo for good. Time never makes a callback
///   ours.
/// - **Dictation undo**, through `UndoTracker`, never while text is selected.
/// - **Queued edits.** Edits that arrive while the trackpad is busy wait, each bound to its field and
///   generation and, for a held key, to its press. Only a gesture that completes lets them run, one at
///   a time: each runs only if its field is still the current one and nothing but the previous queued
///   edit changed the document since; the first mismatch discards the rest. An aborted gesture, a
///   focus change or a cancelled key press discards them.
final class EditingCore<Edit> {
    struct QueuedEdit {
        var edit: Edit
        var documentID: UUID
        var generation: Int
        /// The held-key press the edit belongs to, so cancelling the press revokes it.
        var token: Int?
    }

    enum CallbackOutcome: Equatable {
        /// An outcome of our own pending operation.
        case own
        /// Anything else: the generation advanced, and the undo is gone.
        case outside
        /// Another field (or none): everything bound to the old one is gone.
        case newField
    }

    static var queueLimit: Int { 64 }

    let document: TextDocument
    weak var adjustments: AdjustmentOwner?
    private(set) var documentID: UUID?
    private(set) var generation = 0
    private(set) var undo = UndoTracker()
    private(set) var queue: [QueuedEdit] = []
    /// A completed gesture's queue is running, one edit at a time.
    private(set) var isDraining = false
    /// The generation the next queued edit may run at: the one the queue was bound to, then the one the
    /// previous queued edit left.
    private var drainGeneration = 0

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

    /// An edit the current owner did not make: typing, a delete, a caret move by the trackpad.
    func userEdit() {
        generation &+= 1
        undo.invalidate()
    }

    private func invalidate() {
        generation &+= 1
        undo.invalidate()
        discardQueue()
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
        let own: Bool
        if let adjustments, adjustments.isActive {
            own = textChanged ? adjustments.acknowledge(before: before, after: after)
                              : adjustments.fits(before: before, after: after)
        } else {
            // Our insertions and deletions cause no selection callback (measured); a selection change is
            // the host's or the user's, even when the context looks like ours (an identical passage).
            own = textChanged && undo.acknowledge(before: before, after: after, now: now)
        }
        guard !own else { return .own }
        // An outside change ends the undo for good. The generation tells everything else.
        generation &+= 1
        undo.invalidate()
        return .outside
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
            step = nextUndoStep(now: now)
        }
        return step
    }

    // MARK: Queued edits

    /// Queues an edit for the current field while the trackpad is busy or a queue is running. Without a
    /// field identity, or past the limit, the edit is dropped. Returns whether it was queued.
    @discardableResult
    func enqueue(_ edit: Edit, token: Int? = nil) -> Bool {
        guard let documentID, document.documentID == documentID, queue.count < Self.queueLimit else { return false }
        queue.append(QueuedEdit(edit: edit, documentID: documentID, generation: generation, token: token))
        return true
    }

    /// A held key's press was cancelled: what it queued never runs.
    func revoke(token: Int) {
        queue.removeAll { $0.token == token }
        if queue.isEmpty { isDraining = false }
    }

    /// The gesture completed: its queue may run, one edit at a time (`nextQueuedEdit`), so callbacks a
    /// queued edit causes (a Return that moves focus) arrive before the next one runs.
    func beginDrain() {
        guard let first = queue.first else { return }
        isDraining = true
        drainGeneration = first.generation
    }

    /// The next queued edit, if its field is still the current one and nothing but the previous
    /// queued edit changed the document since. Anything else ends the drain and discards the rest.
    func nextQueuedEdit() -> Edit? {
        guard isDraining, let entry = queue.first else {
            isDraining = false
            return nil
        }
        guard let documentID, document.documentID == documentID, entry.documentID == documentID,
              generation == drainGeneration else {
            discardQueue()
            return nil
        }
        queue.removeFirst()
        return entry.edit
    }

    /// Call right after running the edit `nextQueuedEdit` returned: the change it made is its own.
    func queuedEditRan() {
        drainGeneration = generation
        if queue.isEmpty { isDraining = false }
    }

    /// The gesture was aborted (an outside change, a stale field, a cancellation, hiding).
    func discardQueue() {
        queue = []
        isDraining = false
    }
}
