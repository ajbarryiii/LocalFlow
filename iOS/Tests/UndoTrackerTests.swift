import Foundation

enum UndoTrackerTests {
    static var tests: [TestCase] {
        [
            ("offeredRightAfterAnInsertion", testOfferedRightAfterAnInsertion),
            ("onlyInTheSameField", testOnlyInTheSameField),
            ("withinThirtySeconds", testWithinThirtySeconds),
            ("anyOtherEditCancels", testAnyOtherEditCancels),
            ("contextMustStillEndWithTheText", testContextMustStillEndWithTheText),
            ("truncatedContextIsJudgedConservatively", testTruncatedContextIsJudgedConservatively),
            ("pressEnterNewlineIsIncluded", testPressEnterNewlineIsIncluded),
            ("countsGraphemes", testCountsGraphemes),
            ("takeAndExpireForget", testTakeAndExpireForget),
        ]
    }

    private static let document = Fixture.documentA
    private static let inserted = " Invented dictation."

    private static func tracker(_ text: String = inserted, at time: TimeInterval = 100) -> UndoTracker {
        var tracker = UndoTracker()
        tracker.recordInsertion(text, documentID: document, at: time)
        return tracker
    }

    private static func testOfferedRightAfterAnInsertion() {
        let undo = tracker()
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "Earlier text." + inserted,
                                                       now: 100), 20)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: inserted, now: 100), 20)
        // Nothing to undo before anything was inserted, or for an empty insertion.
        TestSupport.expectEqual(UndoTracker().undoableGraphemes(documentID: document, contextBefore: inserted, now: 100), nil)
        TestSupport.expectEqual(tracker("").insertion, nil)
    }

    private static func testOnlyInTheSameField() {
        let undo = tracker()
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: Fixture.documentB, contextBefore: inserted, now: 101), nil)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: nil, contextBefore: inserted, now: 101), nil)
        var noDocument = UndoTracker()
        noDocument.recordInsertion(inserted, documentID: nil, at: 100)
        TestSupport.expectEqual(noDocument.insertion, nil)
    }

    private static func testWithinThirtySeconds() {
        let undo = tracker(at: 100)
        TestSupport.expectEqual(UndoTracker.window, 30)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: inserted, now: 129.999), 20)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: inserted, now: 130), nil)
        // A clock that reads earlier than the insertion offers nothing.
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: inserted, now: 99), nil)
    }

    private static func testAnyOtherEditCancels() {
        var undo = tracker()
        undo.editHappened()
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: inserted, now: 101), nil)
        // A later insertion replaces the earlier one: undo removes only the latest.
        var replaced = tracker()
        replaced.recordInsertion(" Second.", documentID: document, at: 105)
        TestSupport.expectEqual(replaced.undoableGraphemes(documentID: document, contextBefore: inserted + " Second.",
                                                           now: 106), 8)
    }

    private static func testContextMustStillEndWithTheText() {
        let undo = tracker()
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: inserted + "x", now: 101), nil)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "Other text", now: 101), nil)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: nil, now: 101), nil)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "", now: 101), nil)
    }

    private static func testTruncatedContextIsJudgedConservatively() {
        // The proxy shows only the last sentence of a long insertion.
        let long = " First invented sentence. Second invented sentence here."
        let undo = tracker(long)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "Second invented sentence here.",
                                                       now: 101), long.count)
        // What is visible must be the end of the insertion.
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "Second invented sentence herb.",
                                                       now: 101), nil)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "here", now: 101), nil)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "", now: 101), nil)
    }

    private static func testPressEnterNewlineIsIncluded() {
        let undo = tracker(" Send this\n")
        // Right after a line break UIKit's context is just "\n": consistent, so undo removes 11.
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "\n", now: 101), 11)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "Hi. Send this\n", now: 101), 11)
        TestSupport.expectEqual(undo.undoableGraphemes(documentID: document, contextBefore: "Send this", now: 101), nil)
        TestSupport.expectEqual(tracker("\n").undoableGraphemes(documentID: document, contextBefore: "\n", now: 101), 1)
    }

    private static func testCountsGraphemes() {
        let emoji = " Nice \u{1F44D}\u{1F3FD}"
        TestSupport.expectEqual(tracker(emoji).undoableGraphemes(documentID: document, contextBefore: "Ok." + emoji, now: 101), 7)
        let accent = " cafe\u{301}"
        TestSupport.expectEqual(tracker(accent).undoableGraphemes(documentID: document, contextBefore: accent, now: 101), 5)
        // A context ending in the accent's base letter alone is not the insertion.
        TestSupport.expectEqual(tracker(accent).undoableGraphemes(documentID: document, contextBefore: " cafe", now: 101), nil)
        let flag = "\u{1F1EB}\u{1F1F7}"
        TestSupport.expectEqual(tracker(flag).undoableGraphemes(documentID: document, contextBefore: flag, now: 101), 1)
    }

    private static func testTakeAndExpireForget() {
        var undo = tracker()
        TestSupport.expectEqual(undo.takeUndo(documentID: document, contextBefore: "Other", now: 101), nil)
        TestSupport.expect(undo.insertion != nil, "a refused undo keeps the insertion")
        TestSupport.expectEqual(undo.takeUndo(documentID: document, contextBefore: inserted, now: 101), 20)
        TestSupport.expectEqual(undo.insertion, nil)
        TestSupport.expectEqual(undo.takeUndo(documentID: document, contextBefore: inserted, now: 101), nil)
        var expiring = tracker(at: 100)
        expiring.expire(now: 129)
        TestSupport.expect(expiring.insertion != nil, "expired early")
        expiring.expire(now: 130)
        TestSupport.expectEqual(expiring.insertion, nil)
    }
}
