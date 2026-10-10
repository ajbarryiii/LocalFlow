import Foundation

/// "Undo last dictation" (ARCHITECTURE.md, "Undo ownership v2"): whether it may be offered, and how
/// to carry it out. Ownership is proven by anchors, never by timing. Pure.
///
/// - **Anchors.** At insertion: up to `anchorLength` characters of the context before the caret
///   (read before inserting) and up to `anchorLength` after it.
/// - **Proof.** The after-context must start with the after-anchor, as far as both are visible. The
///   before-context must end with the before-anchor followed by the insertion; if the context is
///   truncated, its visible part may instead be a suffix of the insertion at least
///   `minimumVisibleSuffix` characters long, and deletion then proceeds progressively, re-verifying
///   continuity each step. Shorter insertions, such as a lone "\n", need both anchors in full; with an
///   empty document, the exact whole context. Both ends of what is deleted must be character
///   boundaries in the current context, so a deletion never takes a neighbouring character the
///   insertion merged with ("\r" + "\n", a letter + a combining mark).
/// - **Attribution.** None here: no callback ever counts as this undo's (ARCHITECTURE.md, "Typing
///   correctness is paramount"). UIKit sends none for `insertText` or `deleteBackward`, so none is
///   owed; any callback that is not a pending trackpad adjustment's ends the undo for good (the owner,
///   `EditingCore`, invalidates it), our own edits' reports included. A host that edits without
///   callbacks is a residual risk the anchors mitigate.
/// - **No proof, no Undo.**
/// - **Lifetime.** The text and anchors are held in memory for at most `window` and dropped on
///   invalidation.
struct UndoTracker: Equatable, Sendable {
    static let window: TimeInterval = 30
    /// How long one deletion step may take to show in the context.
    static let stepTimeout: TimeInterval = 0.5
    static let anchorLength = 24
    static let minimumVisibleSuffix = 16

    struct Insertion: Equatable, Sendable {
        var text: String
        var anchorBefore: String
        var anchorAfter: String
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
        /// No proof, a mismatch, a timeout or an invalidation: stop and keep the rest.
        case stopped
    }

    private(set) var insertion: Insertion?
    /// While undoing: what is left of the insertion, and the context and time of the last step.
    private(set) var remaining: String?
    private var stepContext: String?
    private var stepAt: TimeInterval?

    var isUndoing: Bool { remaining != nil }

    /// Call right after inserting `text`, with the context read just before inserting it.
    mutating func recordInsertion(_ text: String, contextBefore: String?, contextAfter: String?, documentID: UUID?,
                                  generation: Int, at time: TimeInterval) {
        invalidate()
        guard !text.isEmpty, let documentID else { return }
        insertion = Insertion(text: text, anchorBefore: String((contextBefore ?? "").suffix(Self.anchorLength)),
                              anchorAfter: String((contextAfter ?? "").prefix(Self.anchorLength)),
                              documentID: documentID, generation: generation, insertedAt: time)
    }

    /// Drops the text and anchors: any other edit, a focus change, hiding, or the end of the window.
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

    /// How many characters at the end of `part` (the insertion, or what is left of it) the context
    /// proves are this insertion's, right before the caret: all of `part` with the anchors, or the
    /// visible part of a truncated context. Zero is no proof. `continuing`: a deletion step after the
    /// first, which needs only continuity.
    static func provenCount(of part: String, insertion: Insertion, before: String?, after: String?,
                            continuing: Bool) -> Int {
        guard !part.isEmpty else { return 0 }
        let before = before ?? ""
        let after = after ?? ""
        let isShort = insertion.text.count < minimumVisibleSuffix
        // The after-anchor: in full for a short insertion, else as far as both are visible.
        let compared = isShort ? insertion.anchorAfter.count : min(insertion.anchorAfter.count, after.count)
        guard after.count >= compared, after.prefix(compared) == insertion.anchorAfter.prefix(compared) else { return 0 }
        // The caret must sit on a character boundary: text that merged with what follows it (a
        // combining mark after it) cannot be deleted without its neighbour.
        let joined = before + after
        guard isBoundary(before.utf16.count, in: joined) else { return 0 }
        let proven: Int
        if isShort, insertion.anchorBefore.isEmpty, insertion.anchorAfter.isEmpty {
            // Inserted into an empty document: the context must be exactly what is left of it.
            proven = before == part && after.isEmpty ? part.count : 0
        } else if before.hasSuffix(insertion.anchorBefore + part) {
            proven = part.count
        } else {
            // A truncated context shows less than the anchor and the insertion; what it shows must be the
            // end of them.
            let anchored = insertion.anchorBefore + part
            guard !isShort, !before.isEmpty, before.count < anchored.count, anchored.hasSuffix(before) else { return 0 }
            let visible = min(before.count, part.count)
            proven = continuing || visible >= minimumVisibleSuffix ? visible : 0
        }
        guard proven > 0, proven == part.count else { return proven }
        // Deleting all of it reaches its start, which must also be a character boundary: a lone "\n"
        // inserted after "\r" forms one "\r\n" character, and deleting it would take the "\r" too.
        let start = before.utf16.count - part.utf16.count
        if start > 0 { return isBoundary(start, in: joined) ? proven : 0 }
        let merged = insertion.anchorBefore + part
        return merged.count == insertion.anchorBefore.count + part.count ? proven : 0
    }

    /// Whether UTF-16 `offset` of `text` falls between two characters.
    static func isBoundary(_ offset: Int, in text: String) -> Bool {
        let units = text.utf16
        guard offset >= 0, offset <= units.count else { return false }
        return String.Index(units.index(units.startIndex, offsetBy: offset), within: text) != nil
    }

    /// Whether to show Undo: the insertion is still owned (field, generation, window) and the
    /// context proves it is right before the caret.
    func isOffered(documentID: UUID?, generation: Int, before: String?, after: String?, now: TimeInterval) -> Bool {
        guard let insertion, remaining == nil, owns(insertion, documentID: documentID, generation: generation, now: now)
        else { return false }
        return Self.provenCount(of: insertion.text, insertion: insertion, before: before, after: after,
                                continuing: false) > 0
    }

    /// Starts undoing; returns the first step.
    mutating func begin(documentID: UUID?, generation: Int, before: String?, after: String?, now: TimeInterval) -> Step {
        guard isOffered(documentID: documentID, generation: generation, before: before, after: after, now: now),
              let insertion else {
            invalidate()
            return .stopped
        }
        remaining = insertion.text
        return nextStep(before: before, after: after, continuing: false, now: now)
    }

    /// Call after each deletion step and then once per frame until it no longer returns `.wait`.
    mutating func step(documentID: UUID?, generation: Int, before: String?, after: String?, now: TimeInterval) -> Step {
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
        if before == stepContext {
            guard now - stepAt < Self.stepTimeout else {
                invalidate()
                return .stopped
            }
            return .wait
        }
        return nextStep(before: before, after: after, continuing: true, now: now)
    }

    private mutating func nextStep(before: String?, after: String?, continuing: Bool, now: TimeInterval) -> Step {
        guard let insertion, let remaining else { return .stopped }
        if remaining.isEmpty {
            invalidate()
            return .finished
        }
        let proven = Self.provenCount(of: remaining, insertion: insertion, before: before, after: after,
                                      continuing: continuing)
        guard proven > 0 else {
            invalidate()
            return .stopped
        }
        self.remaining = String(remaining.dropLast(proven))
        stepContext = before
        stepAt = now
        return .delete(proven)
    }

    private func owns(_ insertion: Insertion, documentID: UUID?, generation: Int, now: TimeInterval) -> Bool {
        documentID != nil && documentID == insertion.documentID && generation == insertion.generation
            && Self.isWithinWindow(insertion, now: now)
    }

    private static func isWithinWindow(_ insertion: Insertion, now: TimeInterval) -> Bool {
        let age = now - insertion.insertedAt
        return age >= 0 && age < window
    }
}
