import Foundation

/// The editing side's bookkeeping against a fake field, driven by real callback sequences: the host
/// moves the caret, edits, and delivers `textDidChange` the way the proxy does. No generation is ever
/// set by hand.
enum EditingCoreTests {
    static var tests: [TestCase] {
        [
            ("caretMovedToAnotherNewlineIsNeverUndone", testCaretMovedToAnotherNewlineIsNeverUndone),
            ("silentCaretMoveIsCaughtByTheAnchors", testSilentCaretMoveIsCaughtByTheAnchors),
            ("ownCallbackIsConsumedOnce", testOwnCallbackIsConsumedOnce),
            ("undoRemovesExactlyTheInsertion", testUndoRemovesExactlyTheInsertion),
            ("progressiveUndoWithTheMeasuredWindow", testProgressiveUndoWithTheMeasuredWindow),
            ("editsEndTheUndo", testEditsEndTheUndo),
            ("trackpadCallbacksAreAttributedToIt", testTrackpadCallbacksAreAttributedToIt),
            ("anotherFieldEndsEverything", testAnotherFieldEndsEverything),
            ("queuedEditsAreBoundToTheirField", testQueuedEditsAreBoundToTheirField),
            ("staleCompletionNeverInsertsIntoAnotherField", testStaleCompletionNeverInsertsIntoAnotherField),
            ("hideForgetsAtOnce", testHideForgetsAtOnce),
            ("queuedReturnThatMovesFocusStopsTheDrain", testQueuedReturnThatMovesFocusStopsTheDrain),
            ("selectionCallbackAtAnIdenticalPassageEndsUndo", testSelectionCallbackAtAnIdenticalPassageEndsUndo),
            ("lateTextCallbackAtAnIdenticalPassageEndsUndo", testLateTextCallbackAtAnIdenticalPassageEndsUndo),
            ("selectedTextRefusesUndo", testSelectedTextRefusesUndo),
            ("undoNeverTakesANeighbourItMergedWith", testUndoNeverTakesANeighbourItMergedWith),
            ("heldDeleteNeverReachesAnotherField", testHeldDeleteNeverReachesAnotherField),
            ("cancelledDeleteRevokesWhatItQueued", testCancelledDeleteRevokesWhatItQueued),
        ]
    }

    private static func core(_ text: String, caret: Int? = nil,
                             model: FakeContextModel = .uikit) -> (EditingCore<String>, FakeDocument) {
        let document = FakeDocument(FakeTextHost(text: text, caret: caret, model: model))
        let core = EditingCore<String>(document: document)
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

    private static func testOwnCallbackIsConsumedOnce() {
        // A host that reports our insertion: the callback shows its state and is ours, once.
        let (core, _) = core("Earlier note. ")
        core.insertDictation("Invented dictation.", now: 10)
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.05), .own)
        TestSupport.expect(core.canUndo(now: 10.1), "an own callback ended the undo")
        // A second one has nothing pending to explain it: an outside change.
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.06), .outside)
        TestSupport.expect(!core.canUndo(now: 10.2), "offered after an unexplained callback")
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
        let (core, _) = core("Earlier note. ")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        core.insertDictation("Invented dictation here.", now: 10)
        trackpad.isActive = true
        TestSupport.expect(!core.canUndo(now: 10.1), "offered while the trackpad is busy")
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 10.15), .own)
        TestSupport.expectEqual(trackpad.acknowledged, 1)
        // One the gesture cannot explain is an outside change, and the undo is gone.
        trackpad.explains = false
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

    /// Runs a completed gesture's queue the way the keyboard does: one edit per run-loop turn, each a
    /// typed edit (`userEdit`, then the text), with the host's callbacks delivered between them.
    /// Returns the edits that ran.
    @discardableResult
    private static func drain(_ core: EditingCore<String>, _ document: FakeDocument) -> [String] {
        var ran: [String] = []
        core.beginDrain()
        while let edit = core.nextQueuedEdit() {
            core.userEdit()
            document.insertText(edit)
            core.queuedEditRan()
            ran.append(edit)
            document.pump(core, at: 0)
        }
        return ran
    }

    private static func testQueuedEditsAreBoundToTheirField() {
        let (core, document) = core("Text. ")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        TestSupport.expect(core.enqueue("a"), "not queued")
        TestSupport.expect(core.enqueue("b"), "not queued")
        trackpad.isActive = false
        // A completed gesture runs them in order, one per turn.
        TestSupport.expectEqual(drain(core, document), ["a", "b"])
        TestSupport.expectEqual(document.text, "Text. ab")
        TestSupport.expect(!core.isDraining, "still draining")
        // An aborted one discards them.
        trackpad.isActive = true
        core.enqueue("c")
        core.discardQueue()
        TestSupport.expectEqual(drain(core, document), [])
        // An outside change while they wait: they belonged to the document as it was.
        core.enqueue("d")
        trackpad.explains = false
        _ = core.hostChanged(textChanged: true, now: 1)
        TestSupport.expectEqual(drain(core, document), [])
        // Without a field identity nothing is queued.
        document.documentID = nil
        _ = core.hostChanged(textChanged: true, now: 1)
        TestSupport.expect(!core.enqueue("e"), "queued without a field identity")
        // Bounded.
        document.documentID = UUID()
        _ = core.hostChanged(textChanged: true, now: 1)
        for index in 0 ..< EditingCore<String>.queueLimit { core.enqueue("\(index)") }
        TestSupport.expect(!core.enqueue("over"), "past the limit")
    }

    private static func testStaleCompletionNeverInsertsIntoAnotherField() {
        // The third review's P1: the trackpad's stale check (the field changed before its callback
        // arrived) used to flush queued typing into the new field. A completion reported then runs
        // nothing: the queue is bound to the old field.
        let (core, document) = core("Old field. ")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        core.enqueue("typed in the old field")
        document.switchField(to: FakeTextHost(text: "New field.", model: .uikit), id: UUID())
        trackpad.isActive = false
        TestSupport.expectEqual(drain(core, document), [])
        TestSupport.expectEqual(document.text, "New field.")
    }

    private static func testQueuedReturnThatMovesFocusStopsTheDrain() {
        // The fourth review's P1: a queued Return made the host focus field B, and the characters queued
        // after it for field A ran in B. Each queued edit is bound again right before it runs.
        let (core, document) = core("Form field A. ")
        let fieldB = FakeTextHost(text: "Field B.", model: .uikit)
        document.returnMovesFocusTo = (fieldB, UUID())
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        for edit in ["x", "\n", "y", "z"] { core.enqueue(edit) }
        trackpad.isActive = false
        TestSupport.expectEqual(drain(core, document), ["x", "\n"])
        TestSupport.expectEqual(document.text, "Field B.")
        TestSupport.expect(core.queue.isEmpty, "the rest kept")
        // The same when the proxy already serves B before any callback says so.
        let (quiet, quietDocument) = self.core("Form field A. ")
        let quietTrackpad = FakeAdjustments()
        quiet.adjustments = quietTrackpad
        quietTrackpad.isActive = true
        for edit in ["x", "y"] { quiet.enqueue(edit) }
        quietTrackpad.isActive = false
        quiet.beginDrain()
        let first = quiet.nextQueuedEdit()
        TestSupport.expectEqual(first, "x")
        quietDocument.switchField(to: fieldB, id: UUID())
        quiet.queuedEditRan()
        TestSupport.expectEqual(quiet.nextQueuedEdit(), nil)
        TestSupport.expect(quiet.queue.isEmpty, "the rest kept")
        // And when anything else changes the document between two queued edits.
        let (busy, busyDocument) = self.core("Some text. ")
        let busyTrackpad = FakeAdjustments()
        busy.adjustments = busyTrackpad
        busyTrackpad.isActive = true
        for edit in ["x", "y"] { busy.enqueue(edit) }
        busyTrackpad.isActive = false
        busy.beginDrain()
        _ = busy.nextQueuedEdit()
        busy.queuedEditRan()
        busyDocument.moveCaret(to: 0, reportedAsTextChange: true)
        busyDocument.pump(busy, at: 1)
        TestSupport.expectEqual(busy.nextQueuedEdit(), nil)
    }

    private static func testSelectionCallbackAtAnIdenticalPassageEndsUndo() {
        // The fourth review's P0: after the insertion's own callback was consumed, the host moved the
        // caret to an older passage with the same anchors and reported it with selectionDidChange, which
        // was taken as ours. Selection callbacks are never attributed to insertions or deletions.
        let passage = "Team, send this\n"
        let (core, document) = core(passage + passage + passage + "Team, ")
        document.editCallbackDelay = 1
        core.insertDictation("send this\n", now: 10)
        TestSupport.expectEqual(document.pump(core, at: 10.02), [.own])
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
        TestSupport.expectEqual(againDocument.pump(again, at: 10.05), [.outside])
        TestSupport.expect(!again.canUndo(now: 10.1), "offered after a selection change in place")
    }

    private static func testLateTextCallbackAtAnIdenticalPassageEndsUndo() {
        // Measured in the simulator (round 6): UIKit sends no callback for our insertText, and reports
        // the host moving the caret with textDidChange. The callback the insertion was allowed to cause
        // was still owed when the host moved the caret to an older passage with the same anchors, and
        // that textDidChange was taken for the insertion's. An owed callback lapses quickly.
        let passage = "Team, send this\n"
        let (core, document) = core(passage + passage + passage + "Team, ")
        core.insertDictation("send this\n", now: 10)
        TestSupport.expect(core.canUndo(now: 10.1), "not offered in place")
        let inserted = document.text
        document.moveCaret(to: 3 * passage.utf16.count, reportedAsTextChange: true)
        TestSupport.expectEqual(document.pump(core, at: 11), [.outside])
        TestSupport.expect(!core.canUndo(now: 11.1), "offered after the host moved the caret")
        TestSupport.expectEqual(core.beginUndo(now: 11.1), .stopped)
        TestSupport.expectEqual(document.text, inserted)
        // A host that reports the insertion itself does so at once, and that callback is ours.
        let (prompt, promptDocument) = self.core(passage + "Team, ")
        promptDocument.editCallbackDelay = 1
        prompt.insertDictation("send this\n", now: 10)
        TestSupport.expectEqual(promptDocument.pump(prompt, at: 10.02), [.own])
        TestSupport.expectEqual(prompt.beginUndo(now: 10.1), .finished)
        TestSupport.expectEqual(promptDocument.text, passage + "Team, ")
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
        let press = key.began(at: 100, documentID: document.documentID)!
        let fieldB = FakeTextHost(text: "Field B text.", model: .uikit)
        document.focus(fieldB, id: UUID())
        TestSupport.expectEqual(document.pump(core, at: 1), [.newField])
        // Even before the keyboard ends the press, the timer finds another field and deletes nothing.
        TestSupport.expect(key.fire(token: press.token, documentID: document.documentID) == nil, "deleted in field B")
        TestSupport.expectEqual(document.text, "Field B text.")
        TestSupport.expect(key.press == nil, "press kept after the field changed")
        // The keyboard's own response to the focus change, before the timer: the press ends.
        var other = HeldDeleteKey()
        let second = other.began(at: 200, documentID: document.documentID)!
        TestSupport.expectEqual(other.cancel(), second.token)
        TestSupport.expect(other.fire(token: second.token, documentID: document.documentID) == nil, "fired after cancel")
    }

    private static func testCancelledDeleteRevokesWhatItQueued() {
        // The fourth review's P1: a delete timer queued a deletion behind a settling trackpad gesture,
        // then the touch was cancelled; the queued deletion still ran. Cancelling revokes it.
        let (core, document) = core("Some text here.")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        var key = HeldDeleteKey()
        let press = key.began(at: 100, documentID: document.documentID)!
        TestSupport.expect(key.fire(token: press.token, documentID: document.documentID) != nil, "first deletion")
        core.enqueue("<delete>", token: press.token)
        core.enqueue("typed", token: nil)
        let ended = key.ended(cancelled: true, documentID: document.documentID)!
        TestSupport.expect(!ended.deleteOnce, "a cancellation deletes")
        core.revoke(token: ended.token)
        TestSupport.expectEqual(core.queue.map(\.edit), ["typed"])
        trackpad.isActive = false
        TestSupport.expectEqual(drain(core, document), ["typed"])
    }

    private static func testHideForgetsAtOnce() {
        let (core, _) = core("Earlier note. ")
        core.insertDictation("Invented dictation here.", now: 10)
        core.enqueue("x")
        core.hide()
        TestSupport.expectEqual(core.documentID, nil)
        TestSupport.expectEqual(core.undo.insertion, nil)
        TestSupport.expect(core.queue.isEmpty, "queue kept")
        TestSupport.expect(!core.canUndo(now: 10.1), "offered after hiding")
    }
}
