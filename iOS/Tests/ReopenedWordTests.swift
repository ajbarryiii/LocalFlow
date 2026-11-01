import Foundation

/// Deleting back into the word just finished (ARCHITECTURE.md, "Word autocorrect", Owned words, Deletion): a Delete of the
/// space this keyboard typed right after a word it owned, nothing else in between, makes that word its own again, with its
/// strip, as if it had never been finished. Round 6 council (Opus finding 1): "ok see you at the " then Delete fell back to
/// the status line, and typing on ("them") showed nothing. Every word, text and point is invented.
enum ReopenedWordTests {
    static var tests: [TestCase] {
        [
            ("theRecordTakesBackTheWordItsSpaceFinished", testTheRecordTakesBackTheWordItsSpaceFinished),
            ("deletingTheSpaceBringsTheWordsStripBack", testDeletingTheSpaceBringsTheWordsStripBack),
            ("theWordGoesOnAsIfNeverFinished", testTheWordGoesOnAsIfNeverFinished),
            ("aCorrectionStillRevertsAndASwipeStillGoesWhole", testACorrectionStillRevertsAndASwipeStillGoesWhole),
            ("anythingInBetweenEndsIt", testAnythingInBetweenEndsIt),
            ("onlyTheKeyboardsOwnWordAndSpaceComeBack", testOnlyTheKeyboardsOwnWordAndSpaceComeBack),
            ("theProxyMustShowTheWord", testTheProxyMustShowTheWord),
        ]
    }

    private static func p(_ x: Double, _ y: Double = 10) -> TapPoint { TapPoint(x: x, y: y) }

    private static let the = ["the": WordPredictions(words: ["then", "they"], isWord: true),
                              "them": WordPredictions(words: ["themselves"], isWord: true),
                              "th": WordPredictions(words: ["the", "that", "this"], isWord: false)]

    private static func live(_ candidates: [String]) -> SwipeStrip { TypingSuggestionsTests.live(candidates) }

    /// "so " typed, then "the" and a space: nothing is pending, and no strip shows.
    private static func typed(corrections: [String: String] = [:]) -> AutocorrectRig {
        let rig = AutocorrectRig.typingASpace(after: "so", corrections: corrections)
        rig.corrector.predicted = the
        rig.tap("the")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so the ")
        TestSupport.expectEqual(rig.strip, nil)
        return rig
    }

    // MARK: The record

    private static func testTheRecordTakesBackTheWordItsSpaceFinished() {
        var record = WordTapRecord()
        record.startOwned()
        record.edited(deleted: 0, inserted: "t", point: p(1))
        record.edited(deleted: 0, inserted: "o", point: p(2))
        record.edited(deleted: 0, inserted: " ")
        TestSupport.expect(record.owned && record.entries.isEmpty, "the space did not start a word")
        // A Delete of that space: the word again, its points and the separator it began after (the field's start).
        TestSupport.expect(record.edited(deleted: 1, inserted: ""), "the word did not come back")
        TestSupport.expectEqual(record.text, "to")
        TestSupport.expectEqual(record.entries.map(\.point), [p(1), p(2)])
        TestSupport.expect(record.isShown(before: "to") && !record.isShown(before: "x to"), "its separator")
        // Once: deleting past its start makes the record unowned, as before.
        record.edited(deleted: 2, inserted: "")
        TestSupport.expect(!record.edited(deleted: 1, inserted: ""), "a word came back twice")
        TestSupport.expect(!record.owned, "deleting past the word's start kept it owned")
        // Letters typed after the space and deleted again: the space still follows the word.
        var typedOn = WordTapRecord()
        typedOn.edited(deleted: 0, inserted: " go", point: p(3))
        typedOn.edited(deleted: 0, inserted: " ")
        typedOn.edited(deleted: 0, inserted: "x", point: p(4))
        typedOn.edited(deleted: 1, inserted: "")
        TestSupport.expect(typedOn.edited(deleted: 1, inserted: ""), "the word did not come back after its space")
        TestSupport.expectEqual(typedOn.text, "go")
        TestSupport.expect(typedOn.isShown(before: "so go"), "the word after its own space")
        // Only a space right after an owned word with a letter, and only a Delete of that one character.
        for finishing in [",", "\n", "-", "7"] {
            var record = WordTapRecord()
            record.edited(deleted: 0, inserted: " go" + finishing)
            record.edited(deleted: 1, inserted: "")
            TestSupport.expect(!record.owned, "\(finishing) brought the word back")
        }
        for setup in [" go, ", " go  ", " ' "] {
            var record = WordTapRecord()
            record.edited(deleted: 0, inserted: setup)
            TestSupport.expect(!record.edited(deleted: 1, inserted: ""), "\(setup) brought a word back")
        }
        var unowned = WordTapRecord()
        unowned.edited(deleted: 0, inserted: "go ")
        TestSupport.expect(!unowned.edited(deleted: 1, inserted: "") && !unowned.owned, "an unowned word came back")
        var replaced = WordTapRecord()
        replaced.edited(deleted: 0, inserted: " go ")
        TestSupport.expect(!replaced.edited(deleted: 1, inserted: ". "), "a deletion that inserts brought the word back")
        // Anything that clears the record, or starts it again, forgets the word.
        var cleared = WordTapRecord()
        cleared.edited(deleted: 0, inserted: " go ")
        cleared.clear()
        TestSupport.expect(!cleared.edited(deleted: 1, inserted: ""), "a cleared record brought the word back")
        var restarted = WordTapRecord()
        restarted.edited(deleted: 0, inserted: " go ")
        restarted.startOwned()
        TestSupport.expect(!restarted.edited(deleted: 1, inserted: ""), "a field start brought the word back")
        // The keys moved: its points go too.
        var moved = WordTapRecord()
        moved.edited(deleted: 0, inserted: " g", point: p(5))
        moved.edited(deleted: 0, inserted: "o", point: p(6))
        moved.edited(deleted: 0, inserted: " ")
        moved.forgetPoints()
        moved.edited(deleted: 1, inserted: "")
        TestSupport.expectEqual(moved.entries.map(\.point), [nil, nil])
    }

    // MARK: The editor

    private static func testDeletingTheSpaceBringsTheWordsStripBack() {
        let rig = typed()
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "so the")
        TestSupport.expectEqual(rig.strip, live(["the", "then", "they"]))
        TestSupport.expect(rig.editor.wordTaps.owned, "the word is not owned")
        // Typing on continues it.
        rig.tap("m")
        TestSupport.expectEqual(rig.strip, live(["them", "themselves"]))
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so them ")
        TestSupport.expectEqual(rig.corrector.calls.last?.word, "them")
        // VoiceOver's Delete does the same; further Deletes go on within the word.
        let spoken = typed()
        spoken.press(.delete)
        TestSupport.expectEqual(spoken.strip, live(["the", "then", "they"]))
        spoken.press(.delete)
        TestSupport.expectEqual(spoken.text, "so th")
        TestSupport.expectEqual(spoken.strip, live(["the", "that", "this"]))
        // A tapped suggestion's space is the keyboard's own too.
        let chosen = AutocorrectRig.typingASpace(after: "so", corrections: [:])
        chosen.corrector.predicted = the
        chosen.tap("th")
        chosen.choose(1)
        TestSupport.expectEqual(chosen.text, "so that ")
        chosen.corrector.predicted["that"] = WordPredictions(words: ["that's"], isWord: true)
        chosen.heldDelete()
        TestSupport.expectEqual(chosen.text, "so that")
        TestSupport.expectEqual(chosen.strip, live(["that", "that's"]))
        // Sol review (round 7, run 1): another word chosen on a commit key's strip replaces the word and its space at once;
        // a Delete of the space it ends with still brings that word back, owned: corrected at the next space.
        let replaced = AutocorrectRig.typingASpace(after: "so", corrections: ["thme": "them"], alternatives: ["thm": ["the", "them"]])
        replaced.corrector.predicted = the
        replaced.tap("thm")
        replaced.press(.space)
        TestSupport.expectEqual(replaced.strip, SwipeStrip(candidates: ["thm", "the", "them"], inserted: 0))
        replaced.choose(1)
        TestSupport.expectEqual(replaced.text, "so the ")
        replaced.heldDelete()
        TestSupport.expectEqual(replaced.text, "so the")
        TestSupport.expectEqual(replaced.strip, live(["the", "then", "they"]))
        replaced.heldDelete()
        replaced.tap("me")
        replaced.press(.space)
        TestSupport.expectEqual(replaced.text, "so them ")
        TestSupport.expectEqual(replaced.corrector.calls.last?.word, "thme")
    }

    private static func testTheWordGoesOnAsIfNeverFinished() {
        // "thm " kept as typed, Delete, "e", Space: corrected with every tap's point, the first three from before the space.
        let rig = AutocorrectRig.typingASpace(after: "so", corrections: ["thme": "them"])
        rig.tap("thm", from: 0)
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so thm ")
        rig.heldDelete()
        rig.tap("e", from: 7)
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so them ")
        TestSupport.expectEqual(rig.corrector.calls.last?.word, "thme")
        TestSupport.expectEqual(rig.corrector.calls.last?.points.map { $0.map { p($0.x, $0.y) } }, [p(0), p(1), p(2), p(7)])
        TestSupport.expectEqual(rig.corrector.calls.last?.context, "so ")
        // Its correction reverts as any.
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "so thme")
        TestSupport.expectEqual(rig.editor.revertedWords, ["thme"])
        // The keys moved in between: the word comes back without its points.
        let moved = AutocorrectRig.typingASpace(after: "so", corrections: ["thme": "them"])
        moved.tap("thm", from: 0)
        moved.press(.space)
        moved.editor.layoutChanged()
        moved.heldDelete()
        moved.tap("e", from: 7)
        moved.press(.space)
        TestSupport.expectEqual(moved.corrector.calls.last?.points.map { $0 == nil }, [true, true, true, false])
    }

    private static func testACorrectionStillRevertsAndASwipeStillGoesWhole() {
        // Right after an autocorrection, Delete puts the typed word back, as before.
        let corrected = typed(corrections: ["teh": "the"])
        corrected.tap("teh")
        corrected.press(.space)
        TestSupport.expectEqual(corrected.text, "so the the ")
        corrected.heldDelete()
        TestSupport.expectEqual(corrected.text, "so the teh")
        TestSupport.expectEqual(corrected.editor.revertedWords, ["teh"])
        // Sol review (round 7, run 5): the typed word put back is owned as before, so deleting it and its space still brings
        // back the word before it.
        corrected.heldDelete()
        corrected.heldDelete()
        corrected.heldDelete()
        corrected.heldDelete()
        TestSupport.expectEqual(corrected.text, "so the")
        TestSupport.expectEqual(corrected.strip, live(["the", "then", "they"]))
        // Right after a swiped word, Delete removes the whole word, as before.
        let swiped = AutocorrectRig.typingASpace(after: "so", corrections: [:])
        swiped.swipe(["late", "later"])
        TestSupport.expectEqual(swiped.text, "so late")
        swiped.heldDelete()
        TestSupport.expectEqual(swiped.text, "so ")
        // A held Delete that deletes by words deletes as before, and leaves nothing owned.
        let held = typed()
        held.heldDelete(.words(1))
        TestSupport.expectEqual(held.text, "so")
        TestSupport.expectEqual(held.strip, nil)
        TestSupport.expect(!held.editor.wordTaps.owned, "a word deletion left a word owned")
    }

    private static func testAnythingInBetweenEndsIt() {
        func expectNothingOwned(_ rig: AutocorrectRig, _ name: String) {
            TestSupport.expectEqual(rig.strip, nil)
            TestSupport.expect(!rig.editor.wordTaps.owned, "\(name): a word is owned")
            let calls = rig.corrector.calls.count
            rig.tap("m")
            rig.press(.space)
            TestSupport.expectEqual(rig.corrector.calls.count, calls)
        }
        // A caret moved away and back.
        let moved = typed()
        moved.document.moveCaret(to: 2)
        moved.pump()
        moved.document.moveCaret(to: 7)
        moved.pump()
        moved.heldDelete()
        TestSupport.expectEqual(moved.text, "so the")
        expectNothingOwned(moved, "caret move")
        // The host edited the field.
        let edited = typed()
        edited.document.hostInserts("Hi ", at: 0)
        edited.pump()
        edited.heldDelete()
        TestSupport.expectEqual(edited.text, "Hi so the")
        expectNothingOwned(edited, "host edit")
        // Dictated text, deleted again up to the space.
        let dictated = typed()
        dictated.editor.insertDictation("ok", now: dictated.tick())
        dictated.heldDelete()
        dictated.heldDelete()
        dictated.heldDelete()
        TestSupport.expectEqual(dictated.text, "so the")
        expectNothingOwned(dictated, "dictation")
        // Hiding and showing, the trackpad, and another field and back.
        let hidden = typed()
        hidden.hide()
        hidden.show()
        hidden.heldDelete()
        expectNothingOwned(hidden, "hiding")
        let trackpad = typed()
        trackpad.editor.closeSwipeStrip()
        trackpad.heldDelete()
        expectNothingOwned(trackpad, "trackpad")
        let away = typed()
        let host = away.document.host, id = away.document.documentID
        away.document.focus(FakeTextHost(text: "other"), id: UUID())
        away.pump()
        away.document.focus(host, id: id)
        away.pump()
        away.heldDelete()
        TestSupport.expectEqual(away.text, "so the")
        expectNothingOwned(away, "another field")
    }

    private static func testOnlyTheKeyboardsOwnWordAndSpaceComeBack() {
        func expectNothingOwned(_ rig: AutocorrectRig, _ text: String, _ name: String) {
            rig.heldDelete()
            TestSupport.expectEqual(rig.text, text)
            TestSupport.expectEqual(rig.strip, nil)
            TestSupport.expect(!rig.editor.wordTaps.owned, "\(name): a word is owned")
        }
        // A word someone else typed, and its space.
        let foreign = AutocorrectRig("so the ", corrections: [:])
        foreign.corrector.predicted = the
        expectNothingOwned(foreign, "so the", "foreign")
        // The keyboard's space after a word it did not type.
        let half = AutocorrectRig("so the", corrections: [:])
        half.corrector.predicted = the
        half.press(.space)
        expectNothingOwned(half, "so the", "foreign word, own space")
        // Letters the keyboard typed after text it did not type ("so" + "the"): never its own word.
        let joined = AutocorrectRig("so", corrections: [:])
        joined.corrector.predicted = the
        joined.tap("the")
        joined.press(.space)
        expectNothingOwned(joined, "sothe", "joined")
        // A swiped word and the space after it: the decoder chose it.
        let swiped = AutocorrectRig.typingASpace(after: "so", corrections: [:])
        swiped.corrector.predicted = the
        swiped.swipe(["the"])
        swiped.press(.space)
        expectNothingOwned(swiped, "so the", "swipe")
        // Not across punctuation, a Return or a double space's period.
        for (key, left) in [(KeyAction.character(","), "so the,"), (.returnKey, "so the")] {
            let rig = AutocorrectRig.typingASpace(after: "so", corrections: [:])
            rig.corrector.predicted = the
            rig.tap("the")
            rig.press(key)
            if key != .returnKey { rig.press(.space) }
            expectNothingOwned(rig, left, "\(key)")
        }
    }

    private static func testTheProxyMustShowTheWord() {
        // The proxy still shows the space (late): no word comes back, and none is corrected later.
        let late = typed()
        late.document.lateBefore = .some("so the ")
        late.heldDelete()
        late.document.lateBefore = nil
        TestSupport.expectEqual(late.text, "so the")
        TestSupport.expectEqual(late.strip, nil)
        TestSupport.expect(!late.editor.wordTaps.owned, "a word the proxy did not show is owned")
        // The host changed the word before reporting it: the proxy shows another word.
        let changed = typed()
        changed.document.host.hostDelete(3 ..< 6)
        changed.document.host.hostInsert("thy", at: 3)
        changed.heldDelete()
        TestSupport.expectEqual(changed.text, "so thy")
        TestSupport.expectEqual(changed.strip, nil)
        TestSupport.expect(!changed.editor.wordTaps.owned, "another word is owned")
        // Sol review (round 7, run 3): the host moved the caret right after an earlier copy of the word and its space, not
        // reported yet. The proxy shows the same word before the caret, but other text after it: that copy is not taken.
        let copy = AutocorrectRig("x the y", corrections: [:])
        copy.corrector.predicted = the
        copy.press(.space)
        copy.tap("the")
        copy.press(.space)
        TestSupport.expectEqual(copy.text, "x the y the ")
        copy.document.host.moveCaret(to: 6)
        copy.heldDelete()
        TestSupport.expectEqual(copy.text, "x they the ")
        TestSupport.expectEqual(copy.strip, nil)
        TestSupport.expect(!copy.editor.wordTaps.owned, "an earlier copy of the word is owned")
    }
}
