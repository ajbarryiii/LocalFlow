import Foundation

/// Whether "Undo" may remove the last dictation the keyboard inserted, and how much to delete.
/// Pure. The inserted text is held in instance memory only, for at most `window`, and dropped on
/// any other edit. It is offered only while all of these hold:
/// - the field (`documentIdentifier`) is the one it went into;
/// - fewer than `window` seconds have passed (on a monotonic clock);
/// - nothing else was typed, deleted, moved or inserted since (`editHappened()`);
/// - the text before the caret still ends with it. The proxy shows only a window of context (in
///   UIKit, just "\n" right after a line break), so a context shorter than the insertion must be
///   non-empty and the end of the insertion.
struct UndoTracker: Equatable, Sendable {
    static let window: TimeInterval = 30

    struct Insertion: Equatable, Sendable {
        var text: String
        var documentID: UUID
        var insertedAt: TimeInterval
    }

    private(set) var insertion: Insertion?

    mutating func recordInsertion(_ text: String, documentID: UUID?, at time: TimeInterval) {
        guard !text.isEmpty, let documentID else {
            insertion = nil
            return
        }
        insertion = Insertion(text: text, documentID: documentID, insertedAt: time)
    }

    /// Typing, delete, trackpad movement or another insertion.
    mutating func editHappened() {
        insertion = nil
    }

    /// Forgets the text once undo can no longer be offered for it.
    mutating func expire(now: TimeInterval) {
        guard let insertion, !isWithinWindow(insertion, now: now) else { return }
        self.insertion = nil
    }

    /// The number of `deleteBackward()` calls that remove the insertion, or nil if undo is not
    /// offered now.
    func undoableGraphemes(documentID: UUID?, contextBefore: String?, now: TimeInterval) -> Int? {
        guard let insertion, let documentID, documentID == insertion.documentID, isWithinWindow(insertion, now: now),
              let context = contextBefore, !context.isEmpty else { return nil }
        let consistent = context.count >= insertion.text.count
            ? context.hasSuffix(insertion.text)
            : insertion.text.hasSuffix(context)
        return consistent ? insertion.text.count : nil
    }

    /// Takes the undo: returns how many graphemes to delete and forgets the insertion.
    mutating func takeUndo(documentID: UUID?, contextBefore: String?, now: TimeInterval) -> Int? {
        guard let count = undoableGraphemes(documentID: documentID, contextBefore: contextBefore, now: now) else { return nil }
        insertion = nil
        return count
    }

    private func isWithinWindow(_ insertion: Insertion, now: TimeInterval) -> Bool {
        let age = now - insertion.insertedAt
        return age >= 0 && age < Self.window
    }
}
