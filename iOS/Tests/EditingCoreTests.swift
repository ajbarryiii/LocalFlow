import Foundation

/// The editing side's bookkeeping against a fake field, driven by real callback sequences: the host
/// moves the caret, edits, and delivers `textDidChange` the way the proxy does. No generation is ever
/// set by hand.
enum EditingCoreTests {
    static var tests: [TestCase] {
        [
            ("caretMovedToAnotherNewlineIsNeverUndone", testCaretMovedToAnotherNewlineIsNeverUndone),
            ("silentCaretMoveIsCaughtByTheAnchors", testSilentCaretMoveIsCaughtByTheAnchors),
            ("ownEditReportsAreNeverOutsideButEndUndo", testOwnEditReportsAreNeverOutsideButEndUndo),
            ("ownEditReportsDelayedAndCoalesced", testOwnEditReportsDelayedAndCoalesced),
            ("ownEditReportsComeBeforeAGesturesOwn", testOwnEditReportsComeBeforeAGesturesOwn),
            ("undoRemovesExactlyTheInsertion", testUndoRemovesExactlyTheInsertion),
            ("progressiveUndoWithTheMeasuredWindow", testProgressiveUndoWithTheMeasuredWindow),
            ("editsEndTheUndo", testEditsEndTheUndo),
            ("trackpadCallbacksAreAttributedToIt", testTrackpadCallbacksAreAttributedToIt),
            ("anotherFieldEndsEverything", testAnotherFieldEndsEverything),
            ("hideForgetsAtOnce", testHideForgetsAtOnce),
            ("selectionCallbackAtAnIdenticalPassageEndsUndo", testSelectionCallbackAtAnIdenticalPassageEndsUndo),
            ("hostMoveToAnIdenticalPassageEndsUndoEarlyOrLate", testHostMoveToAnIdenticalPassageEndsUndoEarlyOrLate),
            ("selectedTextRefusesUndo", testSelectedTextRefusesUndo),
            ("undoNeverTakesANeighbourItMergedWith", testUndoNeverTakesANeighbourItMergedWith),
            ("heldDeleteNeverReachesAnotherField", testHeldDeleteNeverReachesAnotherField),
        ]
    }

    private static func core(_ text: String, caret: Int? = nil,
                             model: FakeContextModel = .uikit) -> (EditingCore, FakeDocument) {
        let document = FakeDocument(FakeTextHost(text: text, caret: caret, model: model))
        let core = EditingCore(document: document)
        core.reset()
        return (core, document)
    }

    private static func testCaretMovedToAnotherNewlineIsNeverUndone() {
        // The third keyboard review's P0: a dictation ending in "\n", then the host moves the caret to
        // another line break and reports it. Undo must not delete anything there, whatever the context
        // shows, and not after the caret comes back either. With the measured context the insertion is
        // proven in place; a context of just "\n" proves nothing about a short insertion, so Undo is
        // never offered there at all (the original bug offered it and deleted the other "\n").
        for model in [FakeContextModel.uikit, .lineBreakOnly] {
            let (core, document) = core("First note.\nSecond note.\n", model: model)
            core.insertDictation("Send this\n", now: 10)
            TestSupport.expectEqual(core.canUndo(now: 10.1), model == .uikit)
            let inserted = document.text
            document.host.moveCaret(to: 12)   // after "First note.\n"
            TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.15), .outside)
            TestSupport.expect(!core.canUndo(now: 10.2), "offered at another line break in \(model)")
            TestSupport.expectEqual(core.beginUndo(now: 10.2), .stopped)
            TestSupport.expectEqual(document.text, inserted)
            // Back where it was: the ownership is gone for good.
            document.host.moveCaret(to: inserted.utf16.count)
            _ = core.hostChanged(textChanged: true, now: 10.25)
            TestSupport.expect(!core.canUndo(now: 10.3), "offered again after coming back in \(model)")
            TestSupport.expectEqual(core.beginUndo(now: 10.3), .stopped)
            TestSupport.expectEqual(document.text, inserted)
        }
    }

    private static func testSilentCaretMoveIsCaughtByTheAnchors() {
        // A host that moves the caret without any callback: the anchors still tell.
        for model in [FakeContextModel.uikit, .lineBreakOnly] {
            let (core, document) = core("First note.\nSecond note.\n", model: model)
            core.insertDictation("Send this\n", now: 10)
            let inserted = document.text
            document.host.moveCaret(to: 12)
            TestSupport.expect(!core.canUndo(now: 10.2), "offered at another line break in \(model)")
            TestSupport.expectEqual(core.beginUndo(now: 10.2), .stopped)
            TestSupport.expectEqual(document.text, inserted)
        }
    }

    private static func testOwnEditReportsAreNeverOutsideButEndUndo() {
        // A host that reports our insertion (WebKit echoes edits): the report is our own edit's, never an
        // outside change, so the generation stays (nothing bound to it ends); but Undo fails closed.
        let (core, document) = core("Earlier note. ")
        document.editCallbackDelay = 1
        core.insertDictation("Invented dictation.", now: 10)
        TestSupport.expect(core.canUndo(now: 10.01), "not offered before the report")
        let generation = core.generation
        TestSupport.expectEqual(document.pump(core, at: 10.02), [.ownEdit])
        TestSupport.expectEqual(core.generation, generation)
        TestSupport.expect(!core.canUndo(now: 10.1), "an own edit's report kept the undo")
        // A second report of the same state has nothing left to explain it: an outside change.
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.2), .outside)
        TestSupport.expectEqual(core.generation, generation &+ 1)
    }

    private static func testOwnEditReportsDelayedAndCoalesced() {
        // Typed edits reported late, each on its own or several as the latest state: all are ours.
        for delay in [1, 2, 3] {
            let (core, document) = core("Notes: ")
            document.editCallbackDelay = delay
            var outcomes: [EditingCore.CallbackOutcome] = []
            var now = 10.0
            for character in ["a", "b", "c"] {
                core.userEdit()
                document.insertText(character)
                core.recordOwnEdit(now: now)
                now += 0.01
                outcomes += document.pump(core, at: now)
            }
            core.userEdit()
            document.deleteBackward()
            core.recordOwnEdit(now: now)
            for _ in 0 ..< 4 {
                now += 0.01
                outcomes += document.pump(core, at: now)
            }
            TestSupport.expectEqual(document.text, "Notes: ab")
            TestSupport.expect(!outcomes.isEmpty && outcomes.allSatisfy { $0 == .ownEdit },
                               "an own edit's report taken for an outside change: \(outcomes) at delay \(delay)")
        }
        // A report of a state no edit of ours left is an outside change, and so is one long after.
        let (core, document) = core("Notes: ")
        core.userEdit()
        document.insertText("x")
        core.recordOwnEdit(now: 10)
        document.host.moveCaret(to: 0)
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.1), .outside)
        document.host.moveCaret(to: document.text.utf16.count)
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10 + EditingCore.ownEditLifetime + 0.1), .outside)
    }

    private static func testOwnEditReportsComeBeforeAGesturesOwn() {
        // Found by the typing torture test: a gesture began right after typing, and the report of the
        // typing (showing the field before the gesture's probe had landed) was taken for the probe's
        // "unchanged" outcome, which taught the wrong unit. Reports arrive in order: ours come first.
        let (core, document) = core("Notes: ")
        document.editCallbackDelay = 1
        core.userEdit()
        document.insertText("x")
        core.recordOwnEdit(now: 10)
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        TestSupport.expectEqual(document.pump(core, at: 10.02), [.ownEdit])
        TestSupport.expectEqual(trackpad.acknowledged, 0)
    }

    private static func testUndoRemovesExactlyTheInsertion() {
        let (core, document) = core("Line one.\nLine two.", caret: 9)
        core.insertDictation(" Inserted words.", now: 10)
        TestSupport.expectEqual(document.text, "Line one. Inserted words.\nLine two.")
        TestSupport.expect(core.canUndo(now: 10.5), "not offered")
        TestSupport.expectEqual(core.beginUndo(now: 10.5), .finished)
        TestSupport.expectEqual(document.text, "Line one.\nLine two.")
        TestSupport.expect(!core.canUndo(now: 10.6), "offered after undoing")
    }

    private static func testProgressiveUndoWithTheMeasuredWindow() {
        // Several sentences: the measured context shows only a sentence or two back, so the undo deletes
        // what it proves, re-checks, and goes on until the anchor shows.
        let dictation = " One invented sentence. Two invented sentences. Three of them. Four now. Five at last."
        let (core, document) = core("Before.")
        core.insertDictation(dictation, now: 10)
        TestSupport.expect(core.canUndo(now: 10.1), "not offered on a truncated context")
        var step = core.beginUndo(now: 10.1)
        var now = 10.1
        while step == .wait {
            now += 1.0 / 60
            step = core.continueUndo(now: now)
        }
        TestSupport.expectEqual(step, .finished)
        TestSupport.expectEqual(document.text, "Before.")
    }

    private static func testEditsEndTheUndo() {
        let (core, document) = core("Earlier note. ")
        core.insertDictation("Invented dictation here.", now: 10)
        core.userEdit()
        TestSupport.expect(!core.canUndo(now: 10.1), "offered after typing")
        // Another dictation is the one to undo.
        core.insertDictation(" More.", now: 11)
        TestSupport.expect(core.canUndo(now: 11.1), "the new insertion is not offered")
        TestSupport.expectEqual(core.beginUndo(now: 11.1), .finished)
        TestSupport.expectEqual(document.text, "Earlier note. Invented dictation here.")
    }

    private static func testTrackpadCallbacksAreAttributedToIt() {
        let (core, document) = core("Earlier note. ")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        core.insertDictation("Invented dictation here.", now: 10)
        trackpad.isActive = true
        TestSupport.expect(!core.canUndo(now: 10.1), "offered while the trackpad is busy")
        document.host.moveCaret(to: 3)
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.15), .own)
        TestSupport.expectEqual(trackpad.acknowledged, 1)
        // One the gesture cannot explain is an outside change, and the undo is gone.
        trackpad.explains = false
        document.host.moveCaret(to: 5)
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.16), .outside)
        trackpad.isActive = false
        TestSupport.expect(!core.canUndo(now: 10.2), "offered after an outside change")
    }

    private static func testAnotherFieldEndsEverything() {
        let (core, document) = core("Earlier note. ")
        core.insertDictation("Invented dictation here.", now: 10)
        document.documentID = UUID()
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.05), .newField)
        TestSupport.expect(!core.canUndo(now: 10.1), "offered in another field")
        // A nil identity never matches anything.
        document.documentID = nil
        TestSupport.expectEqual(core.hostChanged(textChanged: false, now: 10.06), .newField)
        core.insertDictation(" More.", now: 11)
        TestSupport.expect(!core.canUndo(now: 11.1), "offered without a field identity")
    }

    private static func testHideForgetsAtOnce() {
        let (core, _) = core("Earlier note. ")
        core.insertDictation("Invented dictation here.", now: 10)
        core.hide()
        TestSupport.expectEqual(core.documentID, nil)
        TestSupport.expectEqual(core.undo.insertion, nil)
        TestSupport.expect(!core.canUndo(now: 10.1), "offered after hiding")
    }

    private static func testSelectionCallbackAtAnIdenticalPassageEndsUndo() {
        // The fourth review's P0: the host moved the caret to an older passage with the same anchors and
        // reported it with selectionDidChange, which was taken as ours. Selection callbacks are never
        // attributed to insertions or deletions.
        let passage = "Team, send this\n"
        let (core, document) = core(passage + passage + passage + "Team, ")
        core.insertDictation("send this\n", now: 10)
        TestSupport.expect(core.canUndo(now: 10.1), "not offered in place")
        let inserted = document.text
        // The older passage proves the same anchors: a silent move there would be offered (the residual
        // risk the anchors mitigate), so the callback is what must end it.
        document.moveCaret(to: 3 * passage.utf16.count)
        TestSupport.expectEqual(document.pump(core, at: 10.2), [.outside])
        TestSupport.expect(!core.canUndo(now: 10.2), "offered after a selection change")
        TestSupport.expectEqual(core.beginUndo(now: 10.2), .stopped)
        TestSupport.expectEqual(document.text, inserted)
        // Even a selection callback that shows the insertion in place ends it: it is not ours.
        let (again, againDocument) = self.core("Earlier note. ")
        again.insertDictation("Invented dictation here.", now: 10)
        againDocument.moveCaret(to: againDocument.host.text.utf16.count)
        TestSupport.expectEqual(againDocument.pump(again, at: 10.05), [.ownEdit])
        TestSupport.expect(!again.canUndo(now: 10.1), "offered after a selection change in place")
    }

    private static func testHostMoveToAnIdenticalPassageEndsUndoEarlyOrLate() {
        // The round-6 review's P0: UIKit sends no callback for our insertText and reports the host moving
        // the caret with textDidChange. An allowance for the insertion's callback, even a brief one, let
        // a move to an older passage with the same anchors (here 0.2 s after the insertion) count as the
        // insertion's report. No allowance is made: any callback but a pending trackpad adjustment's ends
        // the undo.
        let passage = "Team, send this\n"
        for delay in [0.01, 0.2, 1.0] {
            let (core, document) = core(passage + passage + passage + "Team, ")
            core.insertDictation("send this\n", now: 10)
            TestSupport.expect(core.canUndo(now: 10.005), "not offered in place")
            let inserted = document.text
            document.moveCaret(to: 3 * passage.utf16.count, reportedAsTextChange: true)
            TestSupport.expectEqual(document.pump(core, at: 10 + delay), [.outside])
            TestSupport.expect(!core.canUndo(now: 10 + delay), "offered after the host moved the caret at \(delay)")
            TestSupport.expectEqual(core.beginUndo(now: 10 + delay), .stopped)
            TestSupport.expectEqual(document.text, inserted)
        }
        // A host that reports the insertion itself loses Undo (fails closed), and nothing is deleted.
        let (echo, echoDocument) = self.core(passage + "Team, ")
        echoDocument.editCallbackDelay = 1
        echo.insertDictation("send this\n", now: 10)
        TestSupport.expectEqual(echoDocument.pump(echo, at: 10.02), [.ownEdit])
        TestSupport.expectEqual(echo.beginUndo(now: 10.1), .stopped)
        TestSupport.expectEqual(echoDocument.text, passage + "Team, send this\n")
    }

    private static func testSelectedTextRefusesUndo() {
        let (core, document) = core("Earlier note. ")
        core.insertDictation("Invented dictation here.", now: 10)
        TestSupport.expect(core.canUndo(now: 10.1), "not offered")
        // Text selected without any callback: deleting would remove the selection, not the insertion.
        document.host.select(from: 0, length: 7)
        TestSupport.expect(!core.canUndo(now: 10.2), "offered with text selected")
        TestSupport.expectEqual(core.beginUndo(now: 10.2), .stopped)
        TestSupport.expectEqual(document.text, "Earlier note. Invented dictation here.")
        // The rest of the field selected after the insertion: the context before still ends with it and
        // the context after shows nothing, so the anchors alone would still offer it, and deleting would
        // remove the selection instead.
        let (following, followingDocument) = self.core("Earlier note. Later words.", caret: 14)
        following.insertDictation("Invented dictation here. ", now: 30)
        TestSupport.expect(following.canUndo(now: 30.1), "not offered")
        followingDocument.host.select(from: 39, length: 12)
        TestSupport.expectEqual(followingDocument.host.context.before, "Earlier note. Invented dictation here. ")
        TestSupport.expectEqual(followingDocument.host.context.after, "")
        TestSupport.expect(!following.canUndo(now: 30.2), "offered with the text after it selected")
        TestSupport.expectEqual(following.beginUndo(now: 30.2), .stopped)
        TestSupport.expectEqual(followingDocument.text, "Earlier note. Invented dictation here. Later words.")
        // Dictation that replaces a selection is not undoable by deleting it.
        let (replacing, replacingDocument) = self.core("Earlier note. Old words.")
        replacingDocument.host.select(from: 14, length: 10)
        replacing.insertDictation("New words here, dictated.", now: 20)
        TestSupport.expect(!replacing.canUndo(now: 20.1), "offered after replacing a selection")
    }

    private static func testUndoNeverTakesANeighbourItMergedWith() {
        // The fourth review's P1: a lone "\n" inserted after "\r" forms one "\r\n" character, so one
        // deleteBackward removed the "\r" that was there before; a combining mark merges the same way.
        let (crlf, crlfDocument) = core("Line one\r", model: .whole)
        crlf.insertDictation("\n", now: 10)
        TestSupport.expect(!crlf.canUndo(now: 10.1), "offered across a merged \\r\\n")
        TestSupport.expectEqual(crlf.beginUndo(now: 10.1), .stopped)
        TestSupport.expectEqual(crlfDocument.text, "Line one\r\n")
        let (accent, accentDocument) = core("Cafe", model: .whole)
        accent.insertDictation("\u{301} and a long invented sentence.", now: 10)
        TestSupport.expect(!accent.canUndo(now: 10.1), "offered across a merged accent")
        TestSupport.expectEqual(accent.beginUndo(now: 10.1), .stopped)
        TestSupport.expectEqual(accentDocument.text, "Cafe\u{301} and a long invented sentence.")
        // Without a merge, the same insertions undo exactly.
        let (plain, plainDocument) = core("Line one", model: .whole)
        plain.insertDictation("\n", now: 10)
        TestSupport.expectEqual(plain.beginUndo(now: 10.1), .finished)
        TestSupport.expectEqual(plainDocument.text, "Line one")
    }

    private static func testHeldDeleteNeverReachesAnotherField() {
        // The fourth review's P1: delete pressed in A, focus moved before its first deletion (0.12 s), and
        // the timer deleted in B. The press is bound to A; a focus change also ends it outright.
        let (core, document) = core("Field A text.")
        var key = HeldDeleteKey()
        let press = key.began(at: 100, documentID: document.documentID)
        let fieldB = FakeTextHost(text: "Field B text.", model: .uikit)
        document.focus(fieldB, id: UUID())
        TestSupport.expectEqual(document.pump(core, at: 1), [.newField])
        // Even before the keyboard ends the press, the timer finds another field and deletes nothing.
        TestSupport.expect(key.fire(token: press.token, documentID: document.documentID) == nil, "deleted in field B")
        TestSupport.expectEqual(document.text, "Field B text.")
        TestSupport.expect(key.press == nil, "press kept after the field changed")
        // The keyboard's own response to the focus change, before the timer: the press ends.
        var other = HeldDeleteKey()
        let second = other.began(at: 200, documentID: document.documentID)
        TestSupport.expectEqual(other.cancel(), second.token)
        TestSupport.expect(other.fire(token: second.token, documentID: document.documentID) == nil, "fired after cancel")
    }
}
