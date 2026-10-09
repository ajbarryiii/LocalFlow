import Foundation

/// "Undo last dictation": whether it may be offered, and how to carry it out safely. Pure.
///
/// A suffix match alone never authorizes deletion (ARCHITECTURE.md, "Undo ownership"):
/// - **Ownership.** The insertion is bound to its field and to the edit generation after it
///   (`EditTracker`). Any other change, such as typing, a delete (including each repeat), trackpad
///   movement, another insertion, an outside callback, a focus change or hiding, changes the
///   generation, and the undo is gone for good.
/// - **Progress.** Undo deletes only the part of the insertion the context proves is right before
///   the caret, waits until the context shows the deletion, re-checks that what is left of the
///   insertion now ends the context, and repeats. It stops at the first mismatch or timeout.
///   The proxy shows only a window of context (in UIKit, just "\n" right after a line break), so a
///   context shorter than the insertion proves only what it shows.
/// - **Lifetime.** The text is held in memory for at most `window`, and dropped on invalidation.
struct UndoTracker: Equatable, Sendable {
    static let window: TimeInterval = 30
    /// How long one deletion step may take to show in the context.
    static let stepTimeout: TimeInterval = 0.5

    struct Insertion: Equatable, Sendable {
        var text: String
        var documentID: UUID
        var generation: Int
        var insertedAt: TimeInterval
    }

    enum Step: Equatable, Sendable {
        /// Call `deleteBackward()` this many times now, then call `step` again.
        case delete(Int)
        /// The context has not shown the last deletion yet; call `step` again later.
        case wait
        /// The whole insertion is gone.
        case finished
        /// A mismatch, a timeout or an invalidation: stop and keep the rest.
        case stopped
    }

    private(set) var insertion: Insertion?
    /// While undoing: what is left of the insertion, and the context and time of the last step.
    private(set) var remaining: String?
    private var stepContext: String?
    private var stepAt: TimeInterval?

    var isUndoing: Bool { remaining != nil }

    mutating func recordInsertion(_ text: String, documentID: UUID?, generation: Int, at time: TimeInterval) {
        invalidate()
        guard !text.isEmpty, let documentID else { return }
        insertion = Insertion(text: text, documentID: documentID, generation: generation, insertedAt: time)
    }

    /// Drops the text: any other edit, a focus change, hiding, or the end of the window.
    mutating func invalidate() {
        insertion = nil
        remaining = nil
        stepContext = nil
        stepAt = nil
    }

    /// Forgets the text once the window has passed.
    mutating func expire(now: TimeInterval) {
        guard let insertion, !Self.isWithinWindow(insertion, now: now) else { return }
        invalidate()
    }

    /// The graphemes at the end of `text` that `contextBefore` proves are right before the caret: all
    /// of it when the context ends with it, or the whole context when that is shorter and is the
    /// end of `text`. Zero for a nil or empty context.
    static func provenTail(of text: String, contextBefore: String?) -> Int {
        guard let context = contextBefore, !context.isEmpty, !text.isEmpty else { return 0 }
        if context.count >= text.count { return context.hasSuffix(text) ? text.count : 0 }
        return text.hasSuffix(context) ? context.count : 0
    }

    /// Whether to show Undo: the insertion is still owned, and the context shows at least its end.
    func isOffered(documentID: UUID?, generation: Int, contextBefore: String?, now: TimeInterval) -> Bool {
        guard let insertion, remaining == nil, owns(insertion, documentID: documentID, generation: generation, now: now)
        else { return false }
        return Self.provenTail(of: insertion.text, contextBefore: contextBefore) > 0
    }

    /// Starts undoing; returns the first step.
    mutating func begin(documentID: UUID?, generation: Int, contextBefore: String?, now: TimeInterval) -> Step {
        guard isOffered(documentID: documentID, generation: generation, contextBefore: contextBefore, now: now),
              let insertion else {
            invalidate()
            return .stopped
        }
        remaining = insertion.text
        return nextStep(contextBefore: contextBefore, now: now)
    }

    /// Call after each deletion step and then once per frame until it no longer returns `.wait`.
    mutating func step(documentID: UUID?, generation: Int, contextBefore: String?, now: TimeInterval) -> Step {
        guard let insertion, let stepAt, let remaining,
              owns(insertion, documentID: documentID, generation: generation, now: now) else {
            invalidate()
            return .stopped
        }
        // The last proven part has been deleted; there is nothing left to check.
        if remaining.isEmpty {
            invalidate()
            return .finished
        }
        if contextBefore == stepContext {
            guard now - stepAt < Self.stepTimeout else {
                invalidate()
                return .stopped
            }
            return .wait
        }
        return nextStep(contextBefore: contextBefore, now: now)
    }

    /// Whether a host callback fits the undo in progress: the context still shows the last step's
    /// state, or what is left of the insertion right before the caret.
    func explains(contextBefore: String?) -> Bool {
        guard let remaining else { return false }
        return contextBefore == stepContext || remaining.isEmpty
            || Self.provenTail(of: remaining, contextBefore: contextBefore) > 0
    }

    private mutating func nextStep(contextBefore: String?, now: TimeInterval) -> Step {
        guard let remaining else { return .stopped }
        if remaining.isEmpty {
            invalidate()
            return .finished
        }
        let proven = Self.provenTail(of: remaining, contextBefore: contextBefore)
        guard proven > 0 else {
            invalidate()
            return .stopped
        }
        self.remaining = String(remaining.dropLast(proven))
        stepContext = contextBefore
        stepAt = now
        return .delete(proven)
    }

    private func owns(_ insertion: Insertion, documentID: UUID?, generation: Int, now: TimeInterval) -> Bool {
        documentID == insertion.documentID && generation == insertion.generation && Self.isWithinWindow(insertion, now: now)
    }

    private static func isWithinWindow(_ insertion: Insertion, now: TimeInterval) -> Bool {
        let age = now - insertion.insertedAt
        return age >= 0 && age < window
    }
}
