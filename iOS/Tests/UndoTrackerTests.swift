import Foundation

/// The proof rules of "Undo ownership v2". Ownership through the edit generation and real callback
/// sequences is covered by `EditingCoreTests`.
enum UndoTrackerTests {
    static var tests: [TestCase] {
        [
            ("fullAnchorsProveTheInsertion", testFullAnchorsProveTheInsertion),
            ("anchorsAreRecordedFromTheContextBeforeInserting", testAnchorsAreRecordedFromTheContextBeforeInserting),
            ("shortInsertionsNeedBothAnchorsInFull", testShortInsertionsNeedBothAnchorsInFull),
            ("truncatedContextNeedsSixteenVisibleCharacters", testTruncatedContextNeedsSixteenVisibleCharacters),
            ("afterAnchorAsFarAsVisible", testAfterAnchorAsFarAsVisible),
            ("emptyDocumentNeedsTheExactWholeContext", testEmptyDocumentNeedsTheExactWholeContext),
            ("neverOfferedWithoutProof", testNeverOfferedWithoutProof),
            ("progressiveDeletionReverifiesContinuity", testProgressiveDeletionReverifiesContinuity),
            ("stopsWhenContinuityBreaks", testStopsWhenContinuityBreaks),
            ("waitsForTheContextThenTimesOut", testWaitsForTheContextThenTimesOut),
            ("countsGraphemes", testCountsGraphemes),
            ("acknowledgesOnlyStatesOfTheInsertion", testAcknowledgesOnlyStatesOfTheInsertion),
            ("withinThirtySeconds", testWithinThirtySeconds),
            ("bothEndsMustBeCharacterBoundaries", testBothEndsMustBeCharacterBoundaries),
        ]
    }

    private static let document = Fixture.documentA
    private static let inserted = " Invented dictation, long enough."

    private static func tracker(_ text: String = inserted, before: String? = "Earlier words here.",
                                after: String? = nil, at time: TimeInterval = 100) -> UndoTracker {
        var tracker = UndoTracker()
        tracker.recordInsertion(text, contextBefore: before, contextAfter: after, documentID: document, generation: 7,
                                at: time)
        return tracker
    }

    private static func offered(_ tracker: UndoTracker, before: String?, after: String? = nil, now: TimeInterval = 101) -> Bool {
        tracker.isOffered(documentID: document, generation: 7, before: before, after: after, now: now)
    }

    /// A field: the document, a caret at its end unless `after` follows, and a window of graphemes the
    /// proxy shows before the caret.
    private struct Field {
        var text: String
        var after = ""
        var window: Int?
        var deletions = 0

        var before: String {
            guard let window else { return text }
            return String(text.suffix(window))
        }

        mutating func delete(_ count: Int) {
            text = String(text.dropLast(count))
            deletions += count
        }
    }

    /// Runs an undo to the end against `field`, deleting what each step asks.
    private static func runUndo(_ tracker: inout UndoTracker, _ field: inout Field) -> UndoTracker.Step {
        var now = 101.0
        var step = tracker.begin(documentID: document, generation: 7, before: field.before, after: field.after, now: now)
        while true {
            switch step {
            case .delete(let count):
                field.delete(count)
            case .wait:
                now += 0.6
            case .finished, .stopped:
                return step
            }
            step = tracker.step(documentID: document, generation: 7, before: field.before, after: field.after, now: now)
        }
    }

    private static func testFullAnchorsProveTheInsertion() {
        var undo = tracker()
        var field = Field(text: "Earlier words here." + inserted)
        TestSupport.expect(offered(undo, before: field.before), "not offered with both anchors")
        TestSupport.expectEqual(runUndo(&undo, &field), .finished)
        TestSupport.expectEqual(field.text, "Earlier words here.")
        TestSupport.expectEqual(undo.insertion, nil)
    }

    private static func testAnchorsAreRecordedFromTheContextBeforeInserting() {
        let undo = tracker(before: String(repeating: "x", count: 40) + " tail of what came before", after: "Rest of the line and more.")
        TestSupport.expectEqual(undo.insertion?.anchorBefore, "x tail of what came before".suffix(24).description)
        TestSupport.expectEqual(undo.insertion?.anchorBefore.count, UndoTracker.anchorLength)
        TestSupport.expectEqual(undo.insertion?.anchorAfter, "Rest of the line and mor")
        // Nothing to anchor without a field identity: no undo.
        var anonymous = UndoTracker()
        anonymous.recordInsertion(inserted, contextBefore: "x", contextAfter: nil, documentID: nil, generation: 7, at: 100)
        TestSupport.expectEqual(anonymous.insertion, nil)
    }

    private static func testShortInsertionsNeedBothAnchorsInFull() {
        // Regression (third keyboard review): a lone "\n" was offered wherever the visible context ended
        // in "\n", so moving the caret to another line break could delete it there.
        let undo = tracker("\n", before: "First note.\nSecond note.", after: "")
        TestSupport.expect(offered(undo, before: "First note.\nSecond note.\n"), "not offered in place")
        TestSupport.expect(!offered(undo, before: "First note.\n"), "offered at another line break")
        TestSupport.expect(!offered(undo, before: "\n"), "offered on a context of just \"\\n\"")
        TestSupport.expect(!offered(undo, before: "note.\n"), "offered on a partial anchor")
        // The after-anchor too, in full.
        let middle = tracker("\n", before: "Line one", after: "Line two")
        TestSupport.expect(offered(middle, before: "Line one\n", after: "Line two"), "not offered in place")
        TestSupport.expect(!offered(middle, before: "Line one\n", after: "Line"), "offered on a partial after-anchor")
        TestSupport.expect(!offered(middle, before: "Line one\n", after: "Other two"), "offered before other text")
    }

    private static func testTruncatedContextNeedsSixteenVisibleCharacters() {
        let long = " Forty characters of invented dictation."
        let undo = tracker(long)
        TestSupport.expect(offered(undo, before: String(long.suffix(16))), "16 visible characters")
        TestSupport.expect(!offered(undo, before: String(long.suffix(15))), "15 visible characters")
        // A truncated context that shows part of the anchor and all of the insertion.
        TestSupport.expect(offered(undo, before: "here." + long), "anchor partly visible")
        // What is visible must be the end of anchor and insertion.
        TestSupport.expect(!offered(undo, before: "Changed " + String(long.suffix(20))), "a different context")
    }

    private static func testAfterAnchorAsFarAsVisible() {
        let undo = tracker(inserted, after: "Rest of the line.")
        let before = "Earlier words here." + inserted
        TestSupport.expect(offered(undo, before: before, after: "Rest of the line."), "full after-anchor")
        TestSupport.expect(offered(undo, before: before, after: "Rest"), "truncated after-context")
        TestSupport.expect(offered(undo, before: before, after: nil), "no after-context shown")
        TestSupport.expect(!offered(undo, before: before, after: "Other text"), "other text after")
    }

    private static func testEmptyDocumentNeedsTheExactWholeContext() {
        let undo = tracker("Hi", before: nil, after: nil)
        TestSupport.expect(offered(undo, before: "Hi", after: nil), "not offered in the empty document")
        TestSupport.expect(!offered(undo, before: "Oh Hi", after: nil), "offered with text before")
        TestSupport.expect(!offered(undo, before: "Hi", after: " there"), "offered with text after")
    }

    private static func testNeverOfferedWithoutProof() {
        let undo = tracker()
        TestSupport.expect(!offered(undo, before: nil), "nil context")
        TestSupport.expect(!offered(undo, before: ""), "empty context")
        TestSupport.expect(!offered(undo, before: "Something else entirely"), "other text")
        var stopped = undo
        TestSupport.expectEqual(stopped.begin(documentID: document, generation: 7, before: "Other", after: nil, now: 101), .stopped)
        TestSupport.expectEqual(stopped.insertion, nil)
        // Another field is not ours. (Generations change only through real callbacks and edits; see
        // `EditingCoreTests`.)
        TestSupport.expect(!undo.isOffered(documentID: UUID(), generation: 7, before: "Earlier words here." + inserted,
                                           after: nil, now: 101), "another field")
        TestSupport.expect(!undo.isOffered(documentID: nil, generation: 7, before: "Earlier words here." + inserted,
                                           after: nil, now: 101), "no field identity")
    }

    private static func testProgressiveDeletionReverifiesContinuity() {
        // A window of 20 graphemes: the first step deletes what it shows (at least 16 characters of the
        // insertion), each next step only what still continues the insertion, until the anchor shows.
        let long = " First invented sentence. Second invented sentence. Third one."
        var undo = tracker(long)
        var field = Field(text: "Earlier words here." + long, window: 20)
        TestSupport.expect(offered(undo, before: field.before), "not offered on a truncated context")
        TestSupport.expectEqual(runUndo(&undo, &field), .finished)
        TestSupport.expectEqual(field.text, "Earlier words here.")
        TestSupport.expectEqual(field.deletions, long.count)
    }

    private static func testStopsWhenContinuityBreaks() {
        let long = " First invented sentence. Second invented sentence. Third one."
        var undo = tracker(long)
        var field = Field(text: "Earlier words here." + long, window: 20)
        guard case .delete(let first) = undo.begin(documentID: document, generation: 7, before: field.before,
                                                    after: nil, now: 101) else {
            return TestSupport.expect(false, "no first step")
        }
        field.delete(first)
        // The host changed the text before the caret meanwhile: the rest is not proven.
        field.text = "Earlier words here. Something the host typed."
        TestSupport.expectEqual(undo.step(documentID: document, generation: 7, before: field.before, after: nil, now: 101.1),
                                .stopped)
        TestSupport.expectEqual(field.deletions, 20)
    }

    private static func testWaitsForTheContextThenTimesOut() {
        // A truncated context: the first step deletes only what it shows, and the rest needs to see it go.
        var undo = tracker()
        let before = String(inserted.suffix(20))
        TestSupport.expectEqual(undo.begin(documentID: document, generation: 7, before: before, after: nil, now: 101),
                                .delete(20))
        // The deletion never shows: wait, then give up.
        TestSupport.expectEqual(undo.step(documentID: document, generation: 7, before: before, after: nil, now: 101.2), .wait)
        TestSupport.expectEqual(undo.step(documentID: document, generation: 7, before: before, after: nil, now: 101.6), .stopped)
        TestSupport.expectEqual(undo.insertion, nil)
    }

    private static func testCountsGraphemes() {
        let text = " Thumbs \u{1F44D}\u{1F3FD} and caf\u{E9} and cafe\u{301} too."
        var undo = tracker(text)
        var field = Field(text: "Earlier words here." + text)
        TestSupport.expectEqual(runUndo(&undo, &field), .finished)
        TestSupport.expectEqual(field.deletions, text.count)
        TestSupport.expectEqual(field.text, "Earlier words here.")
    }

    private static func testAcknowledgesOnlyStatesOfTheInsertion() {
        var undo = tracker()
        let after = "Earlier words here." + inserted
        // The insertion may cause one callback, which must show it.
        TestSupport.expect(!undo.acknowledge(before: "Somewhere else", after: nil, now: 100.01), "another place")
        TestSupport.expect(undo.acknowledge(before: after, after: nil, now: 100.02), "the insertion's own state")
        TestSupport.expect(!undo.acknowledge(before: after, after: nil, now: 100.03), "consumed twice")
        // Each deletion may cause one, showing what is left.
        var field = Field(text: after, window: 20)
        guard case .delete(let count) = undo.begin(documentID: document, generation: 7, before: field.before,
                                                    after: nil, now: 101) else {
            return TestSupport.expect(false, "no first step")
        }
        field.delete(count)
        TestSupport.expect(undo.acknowledge(before: field.before, after: nil, now: 101.01), "a partly undone state")
        TestSupport.expect(!undo.acknowledge(before: "Earlier words here.\nOther", after: nil, now: 101.02),
                           "not a state of it")
        // A callback owed is owed only briefly: measured hosts send none for our edits, and a later change
        // that shows the same text (the caret moved to an identical passage) is not ours.
        var late = tracker()
        TestSupport.expect(!late.acknowledge(before: after, after: nil, now: 100 + UndoTracker.callbackTimeout + 0.01),
                           "a late callback taken for the insertion's")
        TestSupport.expect(!late.acknowledge(before: after, after: nil, now: 100.02), "a lapsed callback owed again")
    }

    private static func testBothEndsMustBeCharacterBoundaries() {
        // The fourth review's P1: deletion counts characters, so the insertion's start must not have merged
        // with the character before it ("\r" + "\n") and the caret must not sit inside a character (text
        // followed by a combining mark that joined its last letter).
        let crlf = tracker("\n", before: "Line one\r", after: "")
        TestSupport.expect(!offered(crlf, before: "Line one\r\n"), "offered across \"\\r\\n\"")
        let merged = tracker(" Invented words, long enough to show", before: "Earlier words here.", after: "\u{301} tail")
        TestSupport.expect(!offered(merged, before: "Earlier words here. Invented words, long enough to show",
                                    after: "\u{301} tail"), "offered with the caret inside a character")
        // Truncated contexts: deleting only what is visible never reaches the start, so only the caret counts.
        let long = " Forty characters of invented dictation."
        let undo = tracker(long, before: "Earlier words here\r")
        TestSupport.expect(offered(undo, before: String(long.suffix(20))), "a truncated context")
        TestSupport.expect(UndoTracker.isBoundary(9, in: "Line one\r\n") == false, "inside \"\\r\\n\"")
        TestSupport.expect(UndoTracker.isBoundary(10, in: "Line one\r\n"), "after \"\\r\\n\"")
    }

    private static func testWithinThirtySeconds() {
        var undo = tracker(at: 100)
        let before = "Earlier words here." + inserted
        TestSupport.expect(offered(undo, before: before, now: 129.9), "not offered within the window")
        TestSupport.expect(!offered(undo, before: before, now: 130), "offered after the window")
        TestSupport.expect(!offered(undo, before: before, now: 99), "offered before the insertion")
        undo.expire(now: 129)
        TestSupport.expect(undo.insertion != nil, "expired early")
        undo.expire(now: 130)
        TestSupport.expectEqual(undo.insertion, nil)
    }
}
