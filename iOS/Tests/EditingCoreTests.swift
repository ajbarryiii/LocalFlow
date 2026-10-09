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
            TestSupport.expectEqual(core.hostChanged(textChanged: true), .outside)
            TestSupport.expect(!core.canUndo(now: 10.2), "offered at another line break in \(model)")
            TestSupport.expectEqual(core.beginUndo(now: 10.2), .stopped)
            TestSupport.expectEqual(document.text, inserted)
            // Back where it was: the ownership is gone for good.
            document.host.moveCaret(to: inserted.utf16.count)
            _ = core.hostChanged(textChanged: true)
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
        TestSupport.expectEqual(core.hostChanged(textChanged: true), .own)
        TestSupport.expect(core.canUndo(now: 10.1), "an own callback ended the undo")
        // A second one has nothing pending to explain it: an outside change.
        TestSupport.expectEqual(core.hostChanged(textChanged: true), .outside)
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
        TestSupport.expectEqual(core.hostChanged(textChanged: true), .own)
        TestSupport.expectEqual(trackpad.acknowledged, 1)
        // One the gesture cannot explain is an outside change, and the undo is gone.
        trackpad.explains = false
        TestSupport.expectEqual(core.hostChanged(textChanged: true), .outside)
        trackpad.isActive = false
        TestSupport.expect(!core.canUndo(now: 10.2), "offered after an outside change")
    }

    private static func testAnotherFieldEndsEverything() {
        let (core, document) = core("Earlier note. ")
        core.insertDictation("Invented dictation here.", now: 10)
        document.documentID = UUID()
        TestSupport.expectEqual(core.hostChanged(textChanged: true), .newField)
        TestSupport.expect(!core.canUndo(now: 10.1), "offered in another field")
        // A nil identity never matches anything.
        document.documentID = nil
        TestSupport.expectEqual(core.hostChanged(textChanged: false), .newField)
        core.insertDictation(" More.", now: 11)
        TestSupport.expect(!core.canUndo(now: 11.1), "offered without a field identity")
    }

    private static func testQueuedEditsAreBoundToTheirField() {
        let (core, document) = core("Text. ")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        TestSupport.expect(core.enqueue("a"), "not queued")
        TestSupport.expect(core.enqueue("b"), "not queued")
        // A completed gesture flushes them in order.
        TestSupport.expectEqual(core.takeQueueForCompletion(), ["a", "b"])
        TestSupport.expectEqual(core.takeQueueForCompletion(), [])
        // An aborted one discards them.
        core.enqueue("c")
        core.discardQueue()
        TestSupport.expectEqual(core.takeQueueForCompletion(), [])
        // An outside change while they wait: they belonged to the document as it was.
        core.enqueue("d")
        trackpad.explains = false
        _ = core.hostChanged(textChanged: true)
        TestSupport.expectEqual(core.takeQueueForCompletion(), [])
        // Without a field identity nothing is queued.
        document.documentID = nil
        _ = core.hostChanged(textChanged: true)
        TestSupport.expect(!core.enqueue("e"), "queued without a field identity")
        // Bounded.
        document.documentID = UUID()
        _ = core.hostChanged(textChanged: true)
        for index in 0 ..< EditingCore<String>.queueLimit { core.enqueue("\(index)") }
        TestSupport.expect(!core.enqueue("over"), "past the limit")
    }

    private static func testStaleCompletionNeverInsertsIntoAnotherField() {
        // The third review's P1: the trackpad's stale check (the field changed before its callback
        // arrived) used to flush queued typing into the new field. Even a completion reported then
        // yields nothing: the queue is bound to the old field.
        let (core, document) = core("Old field. ")
        let trackpad = FakeAdjustments()
        core.adjustments = trackpad
        trackpad.isActive = true
        core.enqueue("typed in the old field")
        document.documentID = UUID()
        document.host = FakeTextHost(text: "New field.", model: .uikit)
        TestSupport.expectEqual(core.takeQueueForCompletion(), [])
        TestSupport.expectEqual(document.text, "New field.")
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
