import Foundation

enum UndoTrackerTests {
    static var tests: [TestCase] {
        [
            ("offeredOnlyWhileOwned", testOfferedOnlyWhileOwned),
            ("anyOtherEditEndsItForGood", testAnyOtherEditEndsItForGood),
            ("withinThirtySeconds", testWithinThirtySeconds),
            ("neverOfferedWithoutEvidence", testNeverOfferedWithoutEvidence),
            ("caretMovedToAnotherNewlineIsNotUndone", testCaretMovedToAnotherNewlineIsNotUndone),
            ("deletesOnlyWhatTheContextProves", testDeletesOnlyWhatTheContextProves),
            ("stopsAtTheFirstMismatch", testStopsAtTheFirstMismatch),
            ("waitsForTheContextThenTimesOut", testWaitsForTheContextThenTimesOut),
            ("stopsWhenOwnershipEndsMidway", testStopsWhenOwnershipEndsMidway),
            ("countsGraphemes", testCountsGraphemes),
            ("explainsItsOwnSteps", testExplainsItsOwnSteps),
            ("expireForgets", testExpireForgets),
        ]
    }

    private static let document = Fixture.documentA
    private static let inserted = " Invented dictation."

    private static func tracker(_ text: String = inserted, generation: Int = 7, at time: TimeInterval = 100) -> UndoTracker {
        var tracker = UndoTracker()
        tracker.recordInsertion(text, documentID: document, generation: generation, at: time)
        return tracker
    }

    /// A field: the text before the caret, as UIKit's window would show it, and what undo did to it.
    private struct Field {
        var text: String
        /// Graphemes the proxy shows before the caret; nil shows all.
        var window: Int?
        /// UIKit shows only "\n" right after a line break.
        var stopsAtLineBreaks = true
        var deletions = 0

        var before: String {
            var visible = Substring(text)
            if stopsAtLineBreaks, let lineBreak = text.lastIndex(where: \.isNewline) {
                visible = text.index(after: lineBreak) == text.endIndex ? text[lineBreak...] : text[text.index(after: lineBreak)...]
            }
            if let window { visible = visible.suffix(window) }
            return String(visible)
        }

        mutating func delete(_ count: Int) {
            text.removeLast(min(count, text.count))
            deletions += count
        }
    }

    /// Runs an undo to the end, with the context updating at once after each step.
    private static func runUndo(_ undo: inout UndoTracker, field: inout Field, generation: Int = 7,
                                now: TimeInterval = 101) -> UndoTracker.Step {
        var step = undo.begin(documentID: document, generation: generation, contextBefore: field.before, now: now)
        var steps = 0
        while case .delete(let count) = step, steps < 50 {
            field.delete(count)
            step = undo.step(documentID: document, generation: generation, contextBefore: field.before, now: now)
            steps += 1
        }
        return step
    }

    private static func testOfferedOnlyWhileOwned() {
        let undo = tracker()
        TestSupport.expect(undo.isOffered(documentID: document, generation: 7, contextBefore: "Earlier." + inserted, now: 100),
                           "right after the insertion")
        TestSupport.expect(!undo.isOffered(documentID: Fixture.documentB, generation: 7, contextBefore: inserted, now: 100),
                           "another field")
        TestSupport.expect(!undo.isOffered(documentID: nil, generation: 7, contextBefore: inserted, now: 100), "no field")
        TestSupport.expect(!undo.isOffered(documentID: document, generation: 8, contextBefore: inserted, now: 100),
                           "a later edit generation")
        TestSupport.expect(!UndoTracker().isOffered(documentID: document, generation: 7, contextBefore: inserted, now: 100),
                           "nothing inserted")
        var empty = UndoTracker()
        empty.recordInsertion("", documentID: document, generation: 7, at: 100)
        TestSupport.expectEqual(empty.insertion, nil)
        var noDocument = UndoTracker()
        noDocument.recordInsertion(inserted, documentID: nil, generation: 7, at: 100)
        TestSupport.expectEqual(noDocument.insertion, nil)
    }

    private static func testAnyOtherEditEndsItForGood() {
        // The keyboard advances the generation for typing, each delete repeat, trackpad movement,
        // another insertion and any outside callback. Going back to the same text does not revive it.
        let undo = tracker(generation: 7)
        TestSupport.expect(!undo.isOffered(documentID: document, generation: 8, contextBefore: inserted, now: 101),
                           "after an edit")
        var invalidated = tracker()
        invalidated.invalidate()
        TestSupport.expectEqual(invalidated.insertion, nil)
        TestSupport.expect(!invalidated.isOffered(documentID: document, generation: 7, contextBefore: inserted, now: 101),
                           "after hiding")
        // A later insertion replaces the earlier one.
        var replaced = tracker()
        replaced.recordInsertion(" Second.", documentID: document, generation: 9, at: 105)
        var field = Field(text: "Start." + inserted + " Second.")
        TestSupport.expectEqual(runUndo(&replaced, field: &field, generation: 9, now: 106), .finished)
        TestSupport.expectEqual(field.text, "Start." + inserted)
    }

    private static func testWithinThirtySeconds() {
        let undo = tracker(at: 100)
        TestSupport.expectEqual(UndoTracker.window, 30)
        TestSupport.expect(undo.isOffered(documentID: document, generation: 7, contextBefore: inserted, now: 129.999), "29.999 s")
        TestSupport.expect(!undo.isOffered(documentID: document, generation: 7, contextBefore: inserted, now: 130), "30 s")
        TestSupport.expect(!undo.isOffered(documentID: document, generation: 7, contextBefore: inserted, now: 99), "clock back")
    }

    private static func testNeverOfferedWithoutEvidence() {
        let undo = tracker()
        for context in [nil, "", "Other text", inserted + "x", "dictation"] as [String?] {
            TestSupport.expect(!undo.isOffered(documentID: document, generation: 7, contextBefore: context, now: 101),
                               "offered with \(String(describing: context))")
        }
        // A visible tail of the insertion is evidence for that tail only.
        TestSupport.expect(undo.isOffered(documentID: document, generation: 7, contextBefore: "dictation.", now: 101),
                           "a truncated window")
        TestSupport.expectEqual(UndoTracker.provenTail(of: inserted, contextBefore: "dictation."), 10)
        TestSupport.expectEqual(UndoTracker.provenTail(of: inserted, contextBefore: "Earlier." + inserted), 20)
        TestSupport.expectEqual(UndoTracker.provenTail(of: inserted, contextBefore: "Dictation."), 0)
    }

    private static func testCaretMovedToAnotherNewlineIsNotUndone() {
        // Regression: " Send this\n" was inserted, then the caret moved to another line break. The
        // "\n" suffix once authorized 11 deletions. The move is an outside callback, which advances
        // the generation; even if it were missed, only the proven "\n" could go, and the next step
        // stops because "Other line" is not " Send this".
        let undo = tracker(" Send this\n")
        TestSupport.expect(!undo.isOffered(documentID: document, generation: 8, contextBefore: "\n", now: 101),
                           "offered after the caret moved")
        var missed = tracker(" Send this\n")
        var field = Field(text: "Other line\nmore\n Send this\n")
        field.text = "Other line\n"
        TestSupport.expectEqual(runUndo(&missed, field: &field), .stopped)
        TestSupport.expectEqual(field.deletions, 1)
        TestSupport.expectEqual(missed.insertion, nil)
    }

    private static func testDeletesOnlyWhatTheContextProves() {
        // UIKit shows only "\n" right after a line break: undo deletes the line break, waits for the
        // context to show the line, re-checks it, then deletes the rest.
        var undo = tracker(" Send this\n")
        var field = Field(text: "Hi. Send this\n")
        var step = undo.begin(documentID: document, generation: 7, contextBefore: field.before, now: 101)
        TestSupport.expectEqual(field.before, "\n")
        TestSupport.expectEqual(step, .delete(1))
        field.delete(1)
        step = undo.step(documentID: document, generation: 7, contextBefore: field.before, now: 101)
        TestSupport.expectEqual(step, .delete(10))
        field.delete(10)
        step = undo.step(documentID: document, generation: 7, contextBefore: field.before, now: 101)
        TestSupport.expectEqual(step, .finished)
        TestSupport.expectEqual(field.text, "Hi.")
        // A window shorter than the insertion: one sentence at a time.
        var long = tracker(" First invented sentence. Second invented sentence here.")
        var longField = Field(text: "Start. First invented sentence. Second invented sentence here.", window: 30)
        TestSupport.expectEqual(runUndo(&long, field: &longField), .finished)
        TestSupport.expectEqual(longField.text, "Start.")
    }

    private static func testStopsAtTheFirstMismatch() {
        // Something before the insertion changed while undoing: stop and keep the rest.
        var undo = tracker(" Send this\n")
        var field = Field(text: "Hi. Send this\n")
        TestSupport.expectEqual(undo.begin(documentID: document, generation: 7, contextBefore: field.before, now: 101),
                                .delete(1))
        field.delete(1)
        field.text = "Hi. Sent this"
        TestSupport.expectEqual(undo.step(documentID: document, generation: 7, contextBefore: field.before, now: 101),
                                .stopped)
        TestSupport.expectEqual(undo.insertion, nil)
    }

    private static func testWaitsForTheContextThenTimesOut() {
        var undo = tracker(" Send this\n")
        let before = "\n"
        TestSupport.expectEqual(undo.begin(documentID: document, generation: 7, contextBefore: before, now: 101), .delete(1))
        // The proxy has not shown the deletion yet.
        TestSupport.expectEqual(undo.step(documentID: document, generation: 7, contextBefore: before, now: 101.2), .wait)
        TestSupport.expect(undo.isUndoing, "still undoing")
        TestSupport.expectEqual(undo.step(documentID: document, generation: 7, contextBefore: before,
                                          now: 101 + UndoTracker.stepTimeout), .stopped)
        TestSupport.expect(!undo.isUndoing, "kept undoing after the timeout")
    }

    private static func testStopsWhenOwnershipEndsMidway() {
        var undo = tracker(" Send this\n")
        TestSupport.expectEqual(undo.begin(documentID: document, generation: 7, contextBefore: "\n", now: 101), .delete(1))
        TestSupport.expectEqual(undo.step(documentID: document, generation: 8, contextBefore: "Hi. Send this", now: 101),
                                .stopped)
        var moved = tracker(" Send this\n")
        _ = moved.begin(documentID: document, generation: 7, contextBefore: "\n", now: 101)
        TestSupport.expectEqual(moved.step(documentID: Fixture.documentB, generation: 7, contextBefore: "Hi. Send this",
                                           now: 101), .stopped)
    }

    private static func testCountsGraphemes() {
        let emoji = " Nice \u{1F44D}\u{1F3FD}"
        var emojiUndo = tracker(emoji)
        var emojiField = Field(text: "Ok." + emoji)
        TestSupport.expectEqual(emojiUndo.begin(documentID: document, generation: 7, contextBefore: emojiField.before,
                                                now: 101), .delete(7))
        emojiField.delete(7)
        TestSupport.expectEqual(emojiField.text, "Ok.")
        let accent = " cafe\u{301}"
        var accentUndo = tracker(accent)
        var accentField = Field(text: "Hi." + accent)
        TestSupport.expectEqual(runUndo(&accentUndo, field: &accentField), .finished)
        TestSupport.expectEqual(accentField.text, "Hi.")
        // A context ending in the accent's base letter alone is not the insertion.
        TestSupport.expect(!tracker(accent).isOffered(documentID: document, generation: 7, contextBefore: " cafe", now: 101),
                           "a lone base letter")
        let flag = "\u{1F1EB}\u{1F1F7}"
        TestSupport.expectEqual(UndoTracker.provenTail(of: flag, contextBefore: flag), 1)
    }

    private static func testExplainsItsOwnSteps() {
        var undo = tracker(" Send this\n")
        TestSupport.expect(!undo.explains(contextBefore: "\n"), "explains before undoing")
        _ = undo.begin(documentID: document, generation: 7, contextBefore: "\n", now: 101)
        TestSupport.expect(undo.explains(contextBefore: "\n"), "the state before the step")
        TestSupport.expect(undo.explains(contextBefore: "Hi. Send this"), "the state after the step")
        TestSupport.expect(!undo.explains(contextBefore: "Elsewhere"), "an outside change")
    }

    private static func testExpireForgets() {
        var expiring = tracker(at: 100)
        expiring.expire(now: 129)
        TestSupport.expect(expiring.insertion != nil, "expired early")
        expiring.expire(now: 130)
        TestSupport.expectEqual(expiring.insertion, nil)
    }
}
