import Foundation

/// The text document as the editing side sees it: `UITextDocumentProxy` in the keyboard, a fake in
/// tests. Context is read in memory only and never stored beyond the rules below.
protocol TextDocument: AnyObject {
    /// The field's identity (`documentIdentifier`); nil while a field connects or goes away.
    var documentID: UUID? { get }
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

/// Whatever issues its own adjustments and can tell its own callbacks apart: the trackpad.
protocol AdjustmentOwner: AnyObject {
    /// A gesture is running or settling; edits wait for it.
    var isActive: Bool { get }
    /// `textDidChange`: consumes the expectation it matches; false for an outside change.
    func acknowledge(before: String?, after: String?) -> Bool
    /// Any other callback: whether it fits; consumes nothing.
    func fits(before: String?, after: String?) -> Bool
}

/// The editing side's bookkeeping, independent of UIKit (ARCHITECTURE.md, "Undo ownership v2" and
/// "Queued edits are bound to a field"):
/// - **Field identity.** A nil `documentIdentifier` never matches anything; a different one ends
///   everything that belonged to the old field.
/// - **Edit generation.** Advances on every edit the current owner did not make: typing, each delete,
///   a dictated insertion, a focus change, hiding, and any host callback no pending operation of
///   ours explains. Owners remember the generation they started at.
/// - **Attribution.** A callback is ours only if it matches the expected outcome of a pending
///   operation we issued (the trackpad's adjustments, the insertion, undo deletions), consumed once.
///   No time windows.
/// - **Dictation undo**, through `UndoTracker`.
/// - **Queued edits.** Edits that arrive while the trackpad is busy wait, each bound to its field and
///   generation. Only a gesture that completes flushes them, and only those still bound to the current
///   field and generation; an aborted gesture discards them.
final class EditingCore<Edit> {
    struct QueuedEdit {
        var edit: Edit
        var documentID: UUID
        var generation: Int
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
        queue = []
    }

    // MARK: Callbacks

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback.
    func hostChanged(textChanged: Bool) -> CallbackOutcome {
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
            own = textChanged ? undo.acknowledge(before: before, after: after) : undo.fits(before: before, after: after)
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
        generation &+= 1
        document.insertText(text)
        undo.recordInsertion(text, contextBefore: before, contextAfter: after, documentID: documentID,
                             generation: generation, at: now)
    }

    func canUndo(now: TimeInterval) -> Bool {
        guard adjustments?.isActive != true else { return false }
        return undo.isOffered(documentID: currentDocumentID, generation: generation, before: document.contextBefore,
                              after: document.contextAfter, now: now)
    }

    /// Starts undoing and deletes what the context proves. Returns `.wait` while the context has not
    /// shown the last deletion yet (call `continueUndo` later), else how it ended.
    func beginUndo(now: TimeInterval) -> UndoTracker.Step {
        guard adjustments?.isActive != true, !undo.isUndoing else { return .stopped }
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
            for _ in 0 ..< count { document.deleteBackward() }
            step = nextUndoStep(now: now)
        }
        return step
    }

    // MARK: Queued edits

    /// Queues an edit for the current field while the trackpad is busy. Without a field identity, or
    /// past the limit, the edit is dropped. Returns whether it was queued.
    @discardableResult
    func enqueue(_ edit: Edit) -> Bool {
        guard let documentID, document.documentID == documentID, queue.count < Self.queueLimit else { return false }
        queue.append(QueuedEdit(edit: edit, documentID: documentID, generation: generation))
        return true
    }

    /// The gesture completed: the queued edits still bound to this field and generation, in order.
    func takeQueueForCompletion() -> [Edit] {
        let edits = queue
        queue = []
        guard let documentID, document.documentID == documentID else { return [] }
        return edits.filter { $0.documentID == documentID && $0.generation == generation }.map(\.edit)
    }

    /// The gesture was aborted (an outside change, a stale field, a cancellation, hiding).
    func discardQueue() {
        queue = []
    }
}
