import Foundation

/// Autocorrect in the editor (ARCHITECTURE.md, "Word autocorrect"): the word's tap record, the word before the
/// caret and its gates, the corrector's inputs, the case of the correction, the replacement in one edit with
/// the commit key, the revert and the reverted words, and that nothing changes with autocorrect off. The
/// corrector is a fake; every word, text and point is invented.
enum AutocorrectEditorTests {
    static var tests: [TestCase] {
        [
            ("recordKeepsTheWordsTapsInOrder", testRecordKeepsTheWordsTapsInOrder),
            ("recordOwnsOnlyWordsAfterItsOwnSeparator", testRecordOwnsOnlyWordsAfterItsOwnSeparator),
            ("commitKeysAreSpaceReturnAndPunctuation", testCommitKeysAreSpaceReturnAndPunctuation),
            ("wordBeforeTheCaretDropsOuterApostrophes", testWordBeforeTheCaretDropsOuterApostrophes),
            ("onlyLatinLettersAndApostrophesAreCorrectable", testOnlyLatinLettersAndApostrophesAreCorrectable),
            ("correctionTakesTheTypedWordsCase", testCorrectionTakesTheTypedWordsCase),
            ("everyCommitKeyCorrectsTheWordBeforeIt", testEveryCommitKeyCorrectsTheWordBeforeIt),
            ("correctorGetsContextWordPointsLayoutAndParams", testCorrectorGetsContextWordPointsLayoutAndParams),
            ("correctionKeepsTheTypedCase", testCorrectionKeepsTheTypedCase),
            ("apostrophesAreKeptAroundTheWord", testApostrophesAreKeptAroundTheWord),
            ("keptWordsAreNotReplaced", testKeptWordsAreNotReplaced),
            ("swipedWordsAreNotCorrected", testSwipedWordsAreNotCorrected),
            ("secureFieldsAreNotCorrected", testSecureFieldsAreNotCorrected),
            ("otherCharactersAreNotCorrected", testOtherCharactersAreNotCorrected),
            ("onlyWordsTheKeyboardTypedWholeAreCorrected", testOnlyWordsTheKeyboardTypedWholeAreCorrected),
            ("deleteRemovesTheLastTap", testDeleteRemovesTheLastTap),
            ("outsideEditsCaretMovesAndFieldsClearTheRecord", testOutsideEditsCaretMovesAndFieldsClearTheRecord),
            ("correctionIsOneOwnEditBeforeTheKey", testCorrectionIsOneOwnEditBeforeTheKey),
            ("unverifiedCaretContextIsNotCorrected", testUnverifiedCaretContextIsNotCorrected),
            ("anOwnedWordTheProxyDoesNotShowIsNotCorrected", testAnOwnedWordTheProxyDoesNotShowIsNotCorrected),
            ("charactersTheHostRejectedAreNeverDeleted", testCharactersTheHostRejectedAreNeverDeleted),
            ("callbackBetweenCommitKeyDownAndUpIsNotTrusted", testCallbackBetweenCommitKeyDownAndUpIsNotTrusted),
            ("aGestureOrReappearingDisownsTheWord", testAGestureOrReappearingDisownsTheWord),
            ("fieldsWithAutocorrectionOffAreNotCorrected", testFieldsWithAutocorrectionOffAreNotCorrected),
            ("layoutChangeDropsTheRecordedPoints", testLayoutChangeDropsTheRecordedPoints),
            ("layoutChangeDropsThePointsARevertRestores", testLayoutChangeDropsThePointsARevertRestores),
            ("returnNeverArmsARevert", testReturnNeverArmsARevert),
            ("staleReadingAfterHidingIsNotCorrected", testStaleReadingAfterHidingIsNotCorrected),
            ("returnIsSentOnItsOwnAfterTheCorrection", testReturnIsSentOnItsOwnAfterTheCorrection),
            ("revertNeedsAnIdentifiedUnchangedField", testRevertNeedsAnIdentifiedUnchangedField),
            ("deleteRightAfterRevertsAndRemembers", testDeleteRightAfterRevertsAndRemembers),
            ("heldDeleteRevertsThenRepeatsAsUsual", testHeldDeleteRevertsThenRepeatsAsUsual),
            ("revertRestoresTheTypedWordsTaps", testRevertRestoresTheTypedWordsTaps),
            ("anyOtherKeyForgetsThePendingRevert", testAnyOtherKeyForgetsThePendingRevert),
            ("revertNeedsTheFieldUnchanged", testRevertNeedsTheFieldUnchanged),
            ("revertedWordsOutlastHiding", testRevertedWordsOutlastHiding),
            ("nothingChangesWithAutocorrectOff", testNothingChangesWithAutocorrectOff),
            ("tapsCarryTheirTouchDownPointThroughTheKeyArea", testTapsCarryTheirTouchDownPointThroughTheKeyArea),
            ("aCorrectionOffersTheTypedWordAndSuggestions", testACorrectionOffersTheTypedWordAndSuggestions),
            ("aKeptWordWithSuggestionsOffersThem", testAKeptWordWithSuggestionsOffersThem),
            ("noStripWithoutAChoice", testNoStripWithoutAChoice),
            ("choosingReplacesTheWordBeforeTheCommitKey", testChoosingReplacesTheWordBeforeTheCommitKey),
            ("choosingTheTypedWordRevertsTheCorrection", testChoosingTheTypedWordRevertsTheCorrection),
            ("theCommitStripClosesAndRefusesLikeTheSwipeStrip", testTheCommitStripClosesAndRefusesLikeTheSwipeStrip),
        ]
    }

    // MARK: The tap record

    private static func p(_ x: Double, _ y: Double = 10) -> TapPoint { TapPoint(x: x, y: y) }

    private static func testRecordKeepsTheWordsTapsInOrder() {
        var record = WordTapRecord()
        record.edited(deleted: 0, inserted: "T", point: p(1))
        record.edited(deleted: 0, inserted: "e", point: p(2))
        record.edited(deleted: 0, inserted: "'")
        record.edited(deleted: 0, inserted: "h", point: p(3))
        TestSupport.expectEqual(record.text, "Te'h")
        TestSupport.expectEqual(record.entries.map(\.point), [p(1), p(2), nil, p(3)])
        // Only the last character of an edit carries the tap's point (a space owed after a swiped word goes in
        // with the tapped letter).
        record.edited(deleted: 0, inserted: " a", point: p(4))
        TestSupport.expectEqual(record.entries, [WordTapRecord.Entry(character: "a", point: p(4))])
    }

    private static func testRecordOwnsOnlyWordsAfterItsOwnSeparator() {
        // ARCHITECTURE.md, "Word autocorrect", Owned words (code review round 5): the record owns its word only from
        // a separator the editor typed, or a field start it saw empty, until anything else touches it.
        var record = WordTapRecord()
        TestSupport.expect(!record.owned, "a new record is owned")
        record.edited(deleted: 0, inserted: "ab", point: p(1))
        TestSupport.expect(!record.owned, "letters without a separator are owned")
        for separator in [" ", "\n", ".", "-", "7", "@"] {
            record.edited(deleted: 0, inserted: "q" + separator, point: p(1))
            TestSupport.expect(record.owned && record.entries.isEmpty, "\(separator) did not start an owned word")
        }
        for (index, letter) in "abc".enumerated() { record.edited(deleted: 0, inserted: String(letter), point: p(Double(index))) }
        record.edited(deleted: 1, inserted: "")
        TestSupport.expectEqual(record.text, "ab")
        record.edited(deleted: 1, inserted: "x", point: p(9))
        TestSupport.expectEqual(record.entries.map(\.point), [p(0), p(9)])
        TestSupport.expect(record.owned, "deleting within the word disowned it")
        // Deleting the whole word keeps it owned (back at the separator); one more makes it unowned.
        record.edited(deleted: 2, inserted: "")
        TestSupport.expect(record.owned && record.entries.isEmpty, "deleting back to the separator disowned it")
        record.edited(deleted: 1, inserted: "")
        TestSupport.expect(!record.owned, "deleting past the word's start kept it owned")
        record.edited(deleted: 0, inserted: "q", point: p(1))
        TestSupport.expect(!record.owned, "letters after deleting past the start are owned")
        // Clearing disowns; a field start seen empty owns.
        record.startOwned()
        TestSupport.expect(record.owned && record.entries.isEmpty, "startOwned")
        record.edited(deleted: 0, inserted: "q", point: p(1))
        record.clear()
        TestSupport.expectEqual(record, WordTapRecord())
        // Shown by the host (final review): the reading ends with the word right after its separator, or is
        // exactly the word at a field's start; nothing else, and never while unowned.
        record.edited(deleted: 0, inserted: " te", point: p(1))
        TestSupport.expect(record.isShown(before: "so te"), "the word after its space")
        for reading in ["so t", "sote", "so te ", "te", "so tE", nil] as [String?] {
            TestSupport.expect(!record.isShown(before: reading), "shown in \(reading ?? "nil")")
        }
        record.startOwned()
        record.edited(deleted: 0, inserted: "ok", point: p(1))
        TestSupport.expect(record.isShown(before: "ok"), "the word at the field's start")
        TestSupport.expect(!record.isShown(before: "x ok"), "a field start with text before it")
        record.clear()
        TestSupport.expect(!record.isShown(before: ""), "an unowned record shown")
    }

    // MARK: Words

    private static func testCommitKeysAreSpaceReturnAndPunctuation() {
        for key: KeyAction in [.space, .returnKey, .character("."), .character(","), .character("!"), .character("?"),
                               .character(";"), .character(":")] {
            TestSupport.expect(WordAutocorrect.isCommitKey(key), "\(key) commits nothing")
        }
        for key: KeyAction in [.character("a"), .character("'"), .character("-"), .character("\""), .character(")"),
                               .character("7"), .delete, .shift, .layer(.numbers), .nextKeyboard] {
            TestSupport.expect(!WordAutocorrect.isCommitKey(key), "\(key) commits")
        }
    }

    private static func testWordBeforeTheCaretDropsOuterApostrophes() {
        func word(_ text: String) -> String? {
            WordAutocorrect.word(before: text).map { String(Array($0.run)[$0.word]) }
        }
        TestSupport.expectEqual(word("say helo"), "helo")
        TestSupport.expectEqual(word("helo"), "helo")
        TestSupport.expectEqual(word("say 'helo'"), "helo")
        TestSupport.expectEqual(WordAutocorrect.word(before: "say 'helo''")?.run, "'helo''")
        TestSupport.expectEqual(word("it dont"), "dont")
        TestSupport.expectEqual(word("it don't"), "don't")
        TestSupport.expectEqual(word("x-ray"), "ray")
        TestSupport.expectEqual(word("abc1def"), "def")
        for none in ["", "say ", "ok.", "abc1", "'", "''", "a\n"] {
            TestSupport.expect(WordAutocorrect.word(before: none) == nil, "a word in \(none)")
        }
    }

    private static func testOnlyLatinLettersAndApostrophesAreCorrectable() {
        for word in ["helo", "Helo", "HELO", "dont", "don't", "don\u{2019}t"] {
            TestSupport.expect(WordAutocorrect.isCorrectable(word), "\(word) not correctable")
        }
        for word in ["", "caf\u{E9}", "na\u{EF}ve", "\u{3B1}\u{3B2}", "stra\u{DF}e"] {
            TestSupport.expect(!WordAutocorrect.isCorrectable(word), "\(word) correctable")
        }
        TestSupport.expectEqual(WordAutocorrect.correctorWord("Don\u{2019}T"), "don't")
    }

    private static func testCorrectionTakesTheTypedWordsCase() {
        TestSupport.expectEqual(WordAutocorrect.cased("the", like: "teh"), "the")
        TestSupport.expectEqual(WordAutocorrect.cased("the", like: "Teh"), "The")
        TestSupport.expectEqual(WordAutocorrect.cased("the", like: "TEH"), "THE")
        TestSupport.expectEqual(WordAutocorrect.cased("can't", like: "CANT"), "CAN'T")
        TestSupport.expectEqual(WordAutocorrect.cased("of", like: "OD"), "OF")
        // One capital letter is a capital first letter, not all capitals.
        TestSupport.expectEqual(WordAutocorrect.cased("in", like: "I"), "In")
        // Anything else is the lexicon form, lowercase.
        TestSupport.expectEqual(WordAutocorrect.cased("the", like: "tEH"), "the")
        TestSupport.expectEqual(WordAutocorrect.cased("The", like: "teh"), "the")
        TestSupport.expectEqual(WordAutocorrect.cased("it's", like: "'Its"), "It's")
    }

    // MARK: Commit and replacement

    private static func testEveryCommitKeyCorrectsTheWordBeforeIt() {
        let keys: [(KeyAction, String)] = [(.space, " "), (.returnKey, "\n"), (.character("."), "."), (.character(","), ","),
                                           (.character("!"), "!"), (.character("?"), "?"), (.character(";"), ";"),
                                           (.character(":"), ":")]
        for (key, text) in keys {
            let rig = AutocorrectRig.typingASpace(after: "so")
            rig.tap("teh")
            rig.press(key)
            TestSupport.expectEqual(rig.text, "so the" + text)
            TestSupport.expectEqual(rig.document.host.caret, ("so the" + text).utf16.count)
            TestSupport.expectEqual(rig.events, [.checked, .corrected])
        }
    }

    private static func testCorrectorGetsContextWordPointsLayoutAndParams() {
        let rig = AutocorrectRig.typingASpace(after: "Well, I \u{2019}said\u{2019}\nNo WAY 42")
        rig.params.lmWeight = 1.7
        rig.tap("Teh", from: 20)
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls.count, 1)
        let call = rig.corrector.calls[0]
        // The text before the word, normalized as the tap prior's context.
        TestSupport.expectEqual(call.context, TapPrior.normalizeContext("Well, I \u{2019}said\u{2019}\nNo WAY 42 "))
        TestSupport.expectEqual(call.context, "no way 00 ")
        TestSupport.expectEqual(call.word, "teh")
        TestSupport.expectEqual(call.points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } }, [p(20), p(21), p(22)])
        TestSupport.expectEqual(call.keys, AutocorrectRig.keys)
        TestSupport.expectEqual(call.params.lmWeight, 1.7)
        TestSupport.expectEqual(rig.text, "Well, I \u{2019}said\u{2019}\nNo WAY 42 The ")
    }

    private static func testCorrectionKeepsTheTypedCase() {
        let rig = AutocorrectRig("", corrections: ["teh": "the", "wrld": "world"])
        rig.tap("TEH")
        rig.press(.space)
        rig.tap("Wrld")
        rig.press(.character("!"))
        TestSupport.expectEqual(rig.text, "THE World!")
        // The corrector's own capitals never pass through: its forms are lowercase.
        let upper = AutocorrectRig("", corrections: ["paris": "Paris"])
        upper.tap("paris")
        upper.press(.space)
        TestSupport.expectEqual(upper.text, "paris ")
        TestSupport.expectEqual(upper.events, [.checked])
    }

    private static func testApostrophesAreKeptAroundTheWord() {
        let rig = AutocorrectRig("", corrections: ["cant": "can't", "teh": "the", "dont": "don't"])
        rig.tap("cant")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "can't ")
        // Outer apostrophes stay where they were and are not part of the word.
        rig.tap("'teh'")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "can't 'the' ")
        TestSupport.expectEqual(rig.corrector.calls.last?.word, "teh")
        TestSupport.expectEqual(rig.corrector.calls.last?.context, "can't '")
        TestSupport.expectEqual(rig.corrector.calls.last?.points.count, 3)
        // A curly apostrophe is given to the corrector as "'".
        let curly = AutocorrectRig("", corrections: [:])
        curly.tap("don\u{2019}t")
        curly.press(.space)
        TestSupport.expectEqual(curly.corrector.calls.last?.word, "don't")
        TestSupport.expectEqual(curly.text, "don\u{2019}t ")
    }

    private static func testKeptWordsAreNotReplaced() {
        let rig = AutocorrectRig("", corrections: [:])
        rig.tap("hello")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "hello ")
        TestSupport.expectEqual(rig.events, [.checked])
        // Nothing to revert: delete deletes the space.
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "hello")
        // Deleting back into the word disowns it (round 5): committed again, it is not checked. A space after a
        // space, or a key after punctuation, has no word.
        rig.press(.space)
        rig.press(.space)
        rig.press(.character("."))
        TestSupport.expectEqual(rig.corrector.calls.count, 1)
    }

    private static func testSwipedWordsAreNotCorrected() {
        let rig = AutocorrectRig("", corrections: ["teh": "the", "hellp": "hello"])
        rig.swipe(["teh"])
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh ")
        // A word swiped, then edited by taps, is still swiped. (The layer keys close the strip, so the deletions
        // are single characters.)
        rig.swipe(["help"])
        rig.press(.layer(.numbers))
        rig.press(.layer(.letters))
        rig.heldDelete()
        rig.tap("lp")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh hellp ")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // A candidate chosen from the strip is swiped too.
        rig.swipe(["tha", "teh"])
        rig.editor.chooseSwipeCandidate(at: 1, now: rig.tick())
        rig.press(.character("."))
        TestSupport.expectEqual(rig.text, "teh hellp teh.")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // A tapped letter after a swiped word (with its owed space) is a new, tapped word.
        rig.swipe(["word"])
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh hellp teh. word the ")
    }

    private static func testSecureFieldsAreNotCorrected() {
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.secure = true
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh ")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        TestSupport.expectEqual(rig.events, [])
    }

    private static func testOtherCharactersAreNotCorrected() {
        let rig = AutocorrectRig("", corrections: ["cafe": "cafes", "teh": "the"])
        rig.tap("caf")
        rig.press(.character("\u{E9}"))
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "caf\u{E9} ")
        // Digits end the word: the word before "." is only the letters after them.
        rig.tap("abc")
        rig.press(.character("1"))
        rig.press(.character("."))
        TestSupport.expectEqual(rig.text, "caf\u{E9} abc1.")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // Text selected: the key replaces it, so nothing is corrected.
        let selected = AutocorrectRig("a teh b", corrections: ["teh": "the"])
        selected.document.select(from: 5, length: 2)
        selected.pump()
        selected.press(.space)
        TestSupport.expectEqual(selected.corrector.calls.count, 0)
        TestSupport.expectEqual(selected.text, "a teh ")
    }

    private static func testOnlyWordsTheKeyboardTypedWholeAreCorrected() {
        // ARCHITECTURE.md, "Word autocorrect", Owned words (code review round 5): a word that began in the field's
        // own text is never corrected, nor one after text the keyboard did not type, even after a space it did not
        // type.
        for (text, tapped, expected) in [("so te", "h", "so teh "), ("so ", "teh", "so teh "), ("teh", "", "teh ")] {
            let rig = AutocorrectRig(text, corrections: ["teh": "the"])
            rig.tap(tapped)
            rig.press(.space)
            TestSupport.expectEqual(rig.text, expected)
            TestSupport.expectEqual(rig.corrector.calls.count, 0)
        }
        // The start of a field the keyboard saw empty is a boundary; so is one the host emptied (an outside change it
        // reports, such as a sent message).
        let empty = AutocorrectRig("", corrections: ["teh": "the"])
        empty.tap("teh")
        empty.press(.space)
        TestSupport.expectEqual(empty.text, "the ")
        let emptied = AutocorrectRig("", corrections: ["teh": "the"])
        emptied.tap("hi")
        emptied.document.hostDeletes(0 ..< 2)
        emptied.pump()
        emptied.tap("teh")
        emptied.press(.space)
        TestSupport.expectEqual(emptied.text, "the ")
        // A field with text after the caret is not empty.
        let after = AutocorrectRig("x", corrections: ["teh": "the"])
        after.document.moveCaret(to: 0)
        after.pump()
        after.tap("teh")
        after.press(.space)
        TestSupport.expectEqual(after.text, "teh x")
        // A letter from another layer (no point) is the keyboard's own, recorded with none.
        let mixed = AutocorrectRig("", corrections: [:])
        mixed.tap("t")
        mixed.press(.character("e"))
        mixed.tap("h")
        mixed.press(.space)
        TestSupport.expectEqual(mixed.corrector.calls[0].points.map { $0 == nil }, [false, true, false])
    }

    private static func testDeleteRemovesTheLastTap() {
        let rig = AutocorrectRig("", corrections: [:])
        rig.tap("tex", from: 0)
        rig.heldDelete()
        rig.tap("h", from: 7)
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls[0].points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } }, [p(0), p(1), p(7)])
    }

    private static func testOutsideEditsCaretMovesAndFieldsClearTheRecord() {
        let rig = AutocorrectRig("", corrections: [:])
        rig.tap("ab")
        // The host edits the field: the record no longer applies.
        rig.document.hostInserts("x", at: 0)
        rig.pump()
        TestSupport.expect(rig.editor.wordTaps.entries.isEmpty, "an outside edit kept the record")
        rig.tap("c")
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // A caret move.
        rig.tap("de")
        rig.document.moveCaret(to: 2)
        rig.pump()
        TestSupport.expect(rig.editor.wordTaps.entries.isEmpty, "a caret move kept the record")
        // Another field.
        rig.document.moveCaret(to: rig.document.text.utf16.count)
        rig.pump()
        rig.tap("fg")
        rig.document.focus(FakeTextHost(text: "fg"), id: UUID())
        rig.pump()
        TestSupport.expect(rig.editor.wordTaps.entries.isEmpty, "a field change kept the record")
        // Dictation, and hiding.
        rig.tap("hi")
        rig.editor.insertDictation("ok", now: rig.tick())
        TestSupport.expect(rig.editor.wordTaps.entries.isEmpty, "dictation kept the record")
        rig.tap("jk")
        rig.editor.hide(now: rig.tick())
        TestSupport.expect(rig.editor.wordTaps.entries.isEmpty, "hiding kept the record")
    }

    private static func testCorrectionIsOneOwnEditBeforeTheKey() {
        // A host that reports every edit: the correction's reports are our own, never outside changes.
        let rig = AutocorrectRig("", corrections: ["teh": "the"], editCallbackDelay: 1)
        rig.tap("teh")
        rig.pump()
        rig.press(.character("."))
        TestSupport.expectEqual(rig.text, "the.")
        let outcomes = rig.pump()
        TestSupport.expect(!outcomes.isEmpty && outcomes.allSatisfy { $0 == .ownEdit }, "outcomes \(outcomes)")
        // The editor's model of the text follows: the shift after a sentence end, and a revert still works.
        rig.autocapitalization = .sentences
        rig.press(.space)
        TestSupport.expectEqual(rig.editor.typing.shift, .once)
        TestSupport.expectEqual(rig.editor.currentBefore, "the. ")
        // With a proxy that lags, the editor's own text is the context.
        let lagging = AutocorrectRig("", corrections: ["teh": "the", "wrld": "world"])
        lagging.tap("teh")
        lagging.press(.space)
        lagging.tap("wrld")
        lagging.press(.space)
        TestSupport.expectEqual(lagging.corrector.calls.last?.context, "the ")
        TestSupport.expectEqual(lagging.text, "the world ")
    }

    private static func testUnverifiedCaretContextIsNotCorrected() {
        // Code review (2026-10-19, P1): a commit key that ends a trackpad probe whose outcome is unknown reads the
        // proxy's text from before the probe landed. The host's caret may be elsewhere (here inside the emoji), so
        // deleting the word from there would delete other text. The key types without a correction.
        let original = "teh\u{1F44D}\u{1F3FD}"
        let harness = KeyboardHarness(FakeTextHost(text: original, caret: 3, unit: .utf16, lagFrames: 3, callbackFrames: 3))
        let corrector = FakeCorrector(["teh": "the"])
        harness.editor.autocorrect = {
            AutocorrectSetup(corrector: corrector, keys: AutocorrectRig.keys, params: .standard, secureTextEntry: false)
        }
        harness.gesture(dx: 10, events: 1)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        harness.press(.space)
        harness.settle()
        TestSupport.expectEqual(corrector.calls.count, 0)
        // Only the space went in (where the host had the caret; scalars, as a space can join the skin-tone modifier).
        TestSupport.expectEqual(String(String.UnicodeScalarView(harness.document.text.unicodeScalars.filter { $0 != " " })),
                                original)
        TestSupport.expectEqual(harness.document.text.unicodeScalars.filter { $0 == " " }.count, 1)
        // Later words this keyboard types whole, after a separator it typed, are corrected again (code review round
        // 4: after an unconfirmed gesture that is the only kind; "aWordAfterAnUnconfirmedMoveIsCorrectedOnlyWhenAllTyped").
        for letter in ["t", "e", "h"] { harness.press(.character(letter)) }
        harness.press(.space)
        harness.settle()
        for letter in ["t", "e", "h"] { harness.press(.character(letter)) }
        harness.press(.space)
        TestSupport.expectEqual(corrector.calls.count, 1)
        TestSupport.expectEqual(String(String.UnicodeScalarView(harness.document.text.unicodeScalars.filter { $0 != "\u{1F3FD}" })),
                                "teh\u{1F44D} teh the ")
    }

    private static func testCallbackBetweenCommitKeyDownAndUpIsNotTrusted() {
        // Code review round 4 (2026-10-19, P1): Space touches down and ends a trackpad probe; WebKit's report of the
        // adjustment as issued arrives while Space is held and shows the old caret; Space then types at release.
        // That report verifies nothing about where the host has the caret, so the word is not corrected.
        let original = "teh\u{1F44D}\u{1F3FD}x"
        var reproduced = 0
        for callbackFrames in 1 ... 6 {
            for dx in [10.0, 20.0, 30.0] {
                var host = FakeTextHost(text: original, caret: 3, unit: .grapheme, callbackFrames: callbackFrames)
                host.reportsAsIssuedFirst = true
                let harness = KeyboardHarness(host)
                let corrector = FakeCorrector(["teh": "the"])
                harness.editor.autocorrect = {
                    AutocorrectSetup(corrector: corrector, keys: AutocorrectRig.keys, params: .standard, secureTextEntry: false)
                }
                harness.gesture(dx: dx, events: 1)
                guard harness.trackpad.session?.hasOutstandingProbe == true else { continue }
                let space = harness.touchDown(.space)
                let before = harness.outcomes.count
                for _ in 0 ..< 8 where harness.outcomes.count == before { harness.frame() }
                guard harness.outcomes.count > before else { continue }
                reproduced += 1
                harness.touchUp(space)
                harness.settle()
                let label = "frames \(callbackFrames) dx \(dx): \(harness.document.text)"
                TestSupport.expect(corrector.calls.isEmpty, label)
                TestSupport.expectEqual(String(String.UnicodeScalarView(harness.document.text.unicodeScalars.filter { $0 != " " })),
                                        original)
            }
        }
        TestSupport.expect(reproduced > 0, "no configuration had a report between Space's touch-down and release")
    }

    private static func testAGestureOrReappearingDisownsTheWord() {
        // Owned words (code review rounds 4 and 5): only a word this keyboard typed whole, after a separator it also
        // typed, is corrected; deleting it removes only those characters, wherever the host has the caret. A
        // gesture, deleting past the word's start, or hiding and appearing again disowns the word.
        let harness = KeyboardHarness(FakeTextHost(text: "so teh", unit: .utf16))
        let corrector = FakeCorrector(["teh": "the", "tehx": "then", "tehxx": "then"])
        harness.editor.autocorrect = {
            AutocorrectSetup(corrector: corrector, keys: AutocorrectRig.keys, params: .standard, secureTextEntry: false)
        }
        harness.gesture(dx: 0, events: 1)
        harness.settle()
        harness.press(.character("x"))
        harness.press(.space)
        TestSupport.expectEqual(corrector.calls.count, 0)
        TestSupport.expectEqual(harness.document.text, "so tehx ")
        // The next word, typed whole after that space, is corrected.
        harness.press(.character("t"))
        harness.press(.character("e"))
        harness.press(.character("h"))
        harness.press(.space)
        TestSupport.expectEqual(harness.document.text, "so tehx the ")
        // Deleting back past that space brings the earlier text into the run again. (The layer keys forget the
        // pending revert, so the deletions are single characters.)
        harness.press(.layer(.numbers))
        harness.press(.layer(.letters))
        harness.press(.delete)
        harness.press(.delete)
        harness.press(.delete)
        harness.press(.delete)
        harness.press(.delete)
        harness.press(.character("x"))
        harness.press(.space)
        TestSupport.expectEqual(harness.document.text, "so tehxx ")
        TestSupport.expectEqual(corrector.calls.count, 1)
        // Appearing again does not own the word before the caret (the field is not empty).
        harness.press(.character("t"))
        harness.hide()
        harness.show()
        harness.press(.character("e"))
        harness.press(.character("h"))
        harness.press(.space)
        TestSupport.expectEqual(harness.document.text, "so tehxx teh ")
        TestSupport.expectEqual(corrector.calls.count, 1)
    }

    private static func testFieldsWithAutocorrectionOffAreNotCorrected() {
        // Code review round 4 (2026-10-19, P2): a field that turns autocorrection off (`autocorrectionType == .no`,
        // SwiftUI's `.autocorrectionDisabled()`) keeps its literal input.
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.autocorrectionDisabled = true
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh ")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        TestSupport.expectEqual(rig.events, [])
        rig.autocorrectionDisabled = false
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh the ")
    }

    private static func testAnOwnedWordTheProxyDoesNotShowIsNotCorrected() {
        // Final review (2026-10-19, P1): owned AND shown by the host. A proxy that has not shown our edits yet does
        // not show the word, so it is committed as typed: a lagging proxy means a missed correction, never a wrong
        // one. (This reverses round 5's "anOwnedWordIsCorrectedWhileTheProxyLags".)
        let rig = AutocorrectRig.typingASpace(after: "so")
        rig.document.host.editContextLagFrames = 3
        rig.tap("teh")
        TestSupport.expect(rig.document.host.isContextStale, "the proxy showed the letters at once")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so teh ")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // Once the proxy shows the word and the space before it, the word is corrected.
        rig.document.host.editContextLagFrames = 0
        for _ in 0 ..< 4 { rig.document.host.advanceFrame() }
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so teh the ")
        TestSupport.expectEqual(rig.corrector.calls.last?.context, "so teh ")
        // At a field's start the proxy must show nothing before the word.
        let start = AutocorrectRig("", corrections: ["teh": "the"])
        start.tap("teh")
        start.document.host.hostInsert("x", at: 0)
        start.document.host.refreshContext()
        start.press(.space)
        TestSupport.expectEqual(start.text, "xteh ")
        TestSupport.expectEqual(start.corrector.calls.count, 0)
    }

    private static func testCharactersTheHostRejectedAreNeverDeleted() {
        // Final review (2026-10-19, P1): a field capped at 12 characters keeps "prefix helll" of "prefix helllo".
        // The record says "helllo"; the proxy shows "helll", so nothing is corrected, and the separator the
        // correction would have deleted stays.
        let rig = AutocorrectRig("prefix", corrections: ["helllo": "hello", "helll": "hello"])
        rig.document.host.maxLength = 12
        rig.press(.space)
        rig.tap("helllo")
        TestSupport.expectEqual(rig.text, "prefix helll")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "prefix helll")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // A rejected separator: the field is full, so the space never reaches it; room appears later (unreported)
        // and the word goes in. The proxy shows the word but not the space the record expects before it.
        let separator = AutocorrectRig("abcdefghijkl", corrections: ["teh": "the"])
        separator.document.host.maxLength = 12
        separator.press(.space)
        TestSupport.expectEqual(separator.text, "abcdefghijkl")
        separator.document.host.maxLength = nil
        separator.document.host.hostDelete(0 ..< 1)
        separator.document.host.refreshContext()
        separator.tap("teh")
        separator.press(.space)
        TestSupport.expectEqual(separator.text, "bcdefghijklteh ")
        TestSupport.expectEqual(separator.corrector.calls.count, 0)
    }

    private static func testLayoutChangeDropsTheRecordedPoints() {
        // Code review (2026-10-19, P2): points recorded in one layout mean nothing in another (a resize or a
        // rotation). A layout change keeps the word's characters and drops their points; later taps have theirs.
        var record = WordTapRecord()
        record.edited(deleted: 0, inserted: "a", point: p(1))
        record.edited(deleted: 0, inserted: "b", point: p(2))
        record.forgetPoints()
        TestSupport.expectEqual(record.entries, [WordTapRecord.Entry(character: "a", point: nil),
                                                 WordTapRecord.Entry(character: "b", point: nil)])
        let rig = AutocorrectRig("", corrections: [:])
        rig.tap("hel", from: 0)
        rig.editor.layoutChanged()
        rig.tap("lo", from: 50)
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls[0].word, "hello")
        TestSupport.expectEqual(rig.corrector.calls[0].points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } },
                                [nil, nil, nil, p(50), p(51)])
    }

    private static func testLayoutChangeDropsThePointsARevertRestores() {
        // Code review round 2 (2026-10-19, P2): a layout change between a correction and its revert drops the
        // points the revert would restore too.
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.tap("teh", from: 30)
        rig.press(.space)
        rig.editor.layoutChanged()
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "teh")
        rig.tap("s", from: 40)
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls.last?.points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } },
                                [nil, nil, nil, p(40)])
    }

    private static func testReturnNeverArmsARevert() {
        // Code review round 2 (2026-10-19, P1): Return can move focus before the proxy reports the new field, so
        // a Delete right after would delete in the next field. A Return still corrects, but a Delete after it is a
        // plain Delete.
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.document.returnMovesFocusTo = (FakeTextHost(text: "Second field"), UUID())
        rig.tap("teh")
        rig.press(.returnKey)
        TestSupport.expectEqual(rig.text, "the\n")
        rig.heldDelete()
        rig.pump()
        TestSupport.expectEqual(rig.text, "Second fiel")
        TestSupport.expectEqual(rig.document.previousHosts.last?.text, "the\n")
        TestSupport.expect(rig.editor.revertedWords.isEmpty, "reverted across fields")
        // In the same field, too.
        let same = AutocorrectRig("", corrections: ["teh": "the"])
        same.tap("teh")
        same.press(.returnKey)
        same.heldDelete()
        TestSupport.expectEqual(same.text, "the")
        TestSupport.expectEqual(same.events, [.checked, .corrected])
    }

    private static func testStaleReadingAfterHidingIsNotCorrected() {
        // Code review round 5 (2026-10-19, P1): the keyboard hides and appears again before a move a key
        // interrupted reaches the proxy, which still reads "teh" before the caret. The keyboard did not type that
        // word in this appearance, so it is never corrected, wherever the host has the caret.
        let original = "teh\u{1F44D}\u{1F3FD}x"
        var reproduced = 0
        for callbackFrames in 1 ... 4 {
            for lift in [true, false] {
                let harness = KeyboardHarness(FakeTextHost(text: original, caret: 3, unit: .utf16, lagFrames: 3,
                                                           callbackFrames: callbackFrames))
                let corrector = FakeCorrector(["teh": "the"])
                harness.editor.autocorrect = {
                    AutocorrectSetup(corrector: corrector, keys: AutocorrectRig.keys, params: .standard, secureTextEntry: false)
                }
                harness.gesture(dx: 10, events: 1, lift: lift)
                guard harness.trackpad.session?.hasOutstandingProbe == true || !lift else { continue }
                harness.hide()
                harness.show()
                guard harness.document.contextBefore == "teh" else { continue }
                reproduced += 1
                harness.press(.space)
                harness.settle()
                TestSupport.expect(corrector.calls.isEmpty, "frames \(callbackFrames) lift \(lift): \(harness.document.text)")
                TestSupport.expectEqual(String(String.UnicodeScalarView(harness.document.text.unicodeScalars.filter { $0 != " " })),
                                        original)
            }
        }
        TestSupport.expect(reproduced > 0, "the proxy never read the stale word after reappearing")
    }

    private static func testReturnIsSentOnItsOwnAfterTheCorrection() {
        // Code review round 5 (2026-10-19, P2): hosts that act on `text == "\n"` (Send, Next) must still get Return
        // alone: the correction goes in first, then the Return as its own insertion.
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.tap("teh")
        rig.press(.returnKey)
        TestSupport.expectEqual(rig.text, "the\n")
        TestSupport.expectEqual(Array(rig.document.insertions.suffix(2)), ["the", "\n"])
        // So for every commit key.
        rig.tap("teh")
        rig.press(.character("."))
        TestSupport.expectEqual(Array(rig.document.insertions.suffix(2)), ["the", "."])
        // Without a correction, the key is one insertion as ever.
        rig.tap("ok")
        rig.press(.returnKey)
        TestSupport.expectEqual(Array(rig.document.insertions.suffix(2)), ["k", "\n"])
    }

    private static func testRevertNeedsAnIdentifiedUnchangedField() {
        // A field without an identity cannot be told from the next one: no revert there.
        let anonymous = AutocorrectRig("", corrections: ["teh": "the"], documentID: nil)
        anonymous.tap("teh")
        anonymous.press(.space)
        TestSupport.expectEqual(anonymous.text, "the ")
        anonymous.heldDelete()
        TestSupport.expectEqual(anonymous.text, "the")
        TestSupport.expect(anonymous.editor.revertedWords.isEmpty, "reverted without a field identity")
        // A field change the proxy shows before any callback (the identity changed): the Delete is plain, there.
        let switched = AutocorrectRig("", corrections: ["teh": "the"])
        switched.tap("teh")
        switched.press(.space)
        switched.document.switchField(to: FakeTextHost(text: "x the "), id: UUID())
        switched.heldDelete()
        TestSupport.expectEqual(switched.text, "x the")
        TestSupport.expect(switched.editor.revertedWords.isEmpty, "reverted in another field")
        // The identity lost after the correction, before the Delete.
        let lost = AutocorrectRig("", corrections: ["teh": "the"])
        lost.tap("teh")
        lost.press(.space)
        lost.document.documentID = nil
        lost.heldDelete()
        TestSupport.expectEqual(lost.text, "the")
        TestSupport.expect(lost.editor.revertedWords.isEmpty, "reverted after the identity went")
    }

    // MARK: Revert

    private static func testDeleteRightAfterRevertsAndRemembers() {
        let rig = AutocorrectRig.typingASpace(after: "so")
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so the ")
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "so teh")
        TestSupport.expectEqual(rig.document.host.caret, 6)
        TestSupport.expectEqual(rig.events, [.checked, .corrected, .reverted])
        TestSupport.expectEqual(rig.editor.revertedWords, ["teh"])
        // Committed again, it stays; so does any case of it later, without asking the corrector.
        rig.press(.space)
        rig.tap("Teh")
        rig.press(.character("."))
        TestSupport.expectEqual(rig.text, "so teh Teh.")
        TestSupport.expectEqual(rig.corrector.calls.count, 1)
        // VoiceOver's delete reverts too, after punctuation (never after Return: "returnNeverArmsARevert").
        for (key, text) in [(KeyAction.character(","), ","), (.character("."), ".")] {
            let voiceOver = AutocorrectRig("", corrections: ["wrld": "world"])
            voiceOver.tap("Wrld")
            voiceOver.press(key)
            TestSupport.expectEqual(voiceOver.text, "World" + text)
            voiceOver.press(.delete)
            TestSupport.expectEqual(voiceOver.text, "Wrld")
            TestSupport.expectEqual(voiceOver.editor.revertedWords, ["wrld"])
        }
    }

    private static func testHeldDeleteRevertsThenRepeatsAsUsual() {
        let rig = AutocorrectRig.typingASpace(after: "so")
        rig.tap("teh")
        rig.press(.space)
        rig.heldDelete()
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "so te")
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "so t")
        TestSupport.expectEqual(rig.events, [.checked, .corrected, .reverted])
    }

    private static func testRevertRestoresTheTypedWordsTaps() {
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.tap("teh", from: 30)
        rig.press(.space)
        rig.heldDelete()
        // Typing on: the word is "tehs", recorded from all four taps, and not a reverted word.
        rig.tap("s", from: 40)
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls.last?.word, "tehs")
        TestSupport.expectEqual(rig.corrector.calls.last?.points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } },
                                [p(30), p(31), p(32), p(40)])
    }

    private static func testAnyOtherKeyForgetsThePendingRevert() {
        let keys: [KeyAction] = [.shift, .layer(.numbers), .character("x"), .space, .character("."), .returnKey]
        for key in keys {
            let rig = AutocorrectRig("", corrections: ["teh": "the"])
            rig.tap("teh")
            rig.press(.space)
            rig.press(key)
            let before = rig.text
            rig.heldDelete()
            TestSupport.expectEqual(rig.text, String(before.dropLast()))
            TestSupport.expect(rig.editor.revertedWords.isEmpty, "\(key) kept the revert")
            TestSupport.expect(!rig.events.contains(.reverted), "\(key) kept the revert")
        }
        // A swipe, dictation or the trackpad too.
        let swiped = AutocorrectRig("", corrections: ["teh": "the"])
        swiped.tap("teh")
        swiped.press(.space)
        swiped.swipe(["go"])
        swiped.heldDelete()
        TestSupport.expectEqual(swiped.text, "the ")
        let dictated = AutocorrectRig("", corrections: ["teh": "the"])
        dictated.tap("teh")
        dictated.press(.space)
        dictated.editor.insertDictation("now", now: dictated.tick())
        dictated.heldDelete()
        TestSupport.expectEqual(dictated.text, "the no")
        let trackpad = AutocorrectRig("", corrections: ["teh": "the"])
        trackpad.tap("teh")
        trackpad.press(.space)
        trackpad.editor.closeSwipeStrip()
        trackpad.heldDelete()
        TestSupport.expectEqual(trackpad.text, "the")
    }

    private static func testRevertNeedsTheFieldUnchanged() {
        // The host edited the field after the correction: Delete deletes one character.
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.tap("teh")
        rig.press(.space)
        rig.document.hostInserts("A ", at: 0)
        rig.pump()
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "A the")
        TestSupport.expect(rig.editor.revertedWords.isEmpty, "reverted after an outside edit")
        // An unreported caret move to the end of another copy of the same text: no revert.
        let moved = AutocorrectRig("", corrections: ["teh": "the"])
        moved.tap("teh")
        moved.press(.space)
        moved.document.host.hostInsert("the ", at: 0)
        moved.document.host.moveCaret(to: 4)
        moved.document.host.refreshContext()
        moved.heldDelete()
        TestSupport.expectEqual(moved.text, "thethe ")
        TestSupport.expect(moved.editor.revertedWords.isEmpty, "reverted after an unreported caret move")
    }

    private static func testRevertedWordsOutlastHiding() {
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.tap("teh")
        rig.press(.space)
        rig.heldDelete()
        rig.editor.hide(now: rig.tick())
        rig.editor.reset(numeric: false)
        rig.press(.space)
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "teh teh ")
        TestSupport.expectEqual(rig.corrector.calls.count, 1)
    }

    // MARK: Off

    private static func testNothingChangesWithAutocorrectOff() {
        // The same keys with autocorrect off (no setup: off, no Full Access or no model) and with a corrector that
        // keeps every word give the same text, shift and layer as plain typing, and the corrector is never asked
        // when off.
        func run(_ rig: AutocorrectRig) -> (String, ShiftMode, KeyboardLayer, String?) {
            rig.autocapitalization = .sentences
            rig.tap("teh")
            rig.press(.space)
            rig.press(.space)
            rig.tap("wrld")
            rig.press(.character(","))
            rig.heldDelete()
            rig.press(.returnKey)
            rig.swipe(["teh"])
            rig.press(.character("?"))
            rig.tap("cant")
            rig.heldDelete()
            return (rig.text, rig.editor.typing.shift, rig.editor.typing.layer, rig.editor.currentBefore)
        }
        let off = AutocorrectRig("", corrections: ["teh": "the", "wrld": "world", "cant": "can't"])
        off.enabled = false
        let keeping = AutocorrectRig("", corrections: [:])
        let plain = run(off), kept = run(keeping)
        TestSupport.expectEqual(plain.0, "teh. Wrld\nTeh?can")
        TestSupport.expectEqual(off.corrector.calls.count, 0)
        TestSupport.expectEqual(off.events, [])
        TestSupport.expect(plain == kept, "\(plain) differs from \(kept)")
    }

    // MARK: The strip after a commit key

    private static func testACorrectionOffersTheTypedWordAndSuggestions() {
        // The typed word, the correction (in the field), then the best other suggestion: three words at most.
        let rig = AutocorrectRig.typingASpace(after: "so", alternatives: ["teh": ["the", "ten", "tea"]])
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so the ")
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["teh", "the", "ten"], inserted: 1))
        // The corrector is asked for suggestions with the correction's inputs.
        TestSupport.expectEqual(rig.corrector.suggestionCalls.count, 1)
        let asked = rig.corrector.suggestionCalls[0], corrected = rig.corrector.calls[0]
        TestSupport.expectEqual(asked.call.word, corrected.word)
        TestSupport.expectEqual(asked.call.context, corrected.context)
        TestSupport.expectEqual(asked.call.points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } },
                                corrected.points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } })
        TestSupport.expectEqual(asked.call.params, corrected.params)
        TestSupport.expectEqual(asked.limit, SwipeStrip.limit)
        // Every word takes the typed word's case and trailing apostrophes.
        let cased = AutocorrectRig("", corrections: ["teh": "the"], alternatives: ["teh": ["ten"]])
        cased.tap("Teh'")
        cased.press(.character(","))
        TestSupport.expectEqual(cased.text, "The',")
        TestSupport.expectEqual(cased.strip, SwipeStrip(candidates: ["Teh'", "The'", "Ten'"], inserted: 1))
        // A correction without other suggestions still offers the typed word.
        let alone = AutocorrectRig("", corrections: ["teh": "the"])
        alone.tap("teh")
        alone.press(.space)
        TestSupport.expectEqual(alone.strip, SwipeStrip(candidates: ["teh", "the"], inserted: 1))
    }

    private static func testAKeptWordWithSuggestionsOffersThem() {
        let rig = AutocorrectRig.typingASpace(after: "hi", alternatives: ["wrld": ["world", "would", "wild"]])
        rig.tap("wrld")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "hi wrld ")
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["wrld", "world", "would"], inserted: 0))
        TestSupport.expectEqual(rig.events, [.checked])
        // Every commit key but Return, which may move focus.
        for (key, text) in [(KeyAction.character("."), "."), (.character("?"), "?"), (.returnKey, "\n")] {
            let other = AutocorrectRig("", corrections: [:], alternatives: ["wrld": ["world"]])
            other.tap("wrld")
            other.press(key)
            TestSupport.expectEqual(other.text, "wrld" + text)
            TestSupport.expectEqual(other.strip, key == .returnKey ? nil : SwipeStrip(candidates: ["wrld", "world"], inserted: 0))
        }
        let corrected = AutocorrectRig("", corrections: ["teh": "the"], alternatives: ["teh": ["ten"]])
        corrected.tap("teh")
        corrected.press(.returnKey)
        TestSupport.expectEqual(corrected.text, "the\n")
        TestSupport.expectEqual(corrected.strip, nil)
    }

    private static func testNoStripWithoutAChoice() {
        // Kept with no suggestion (the corrector gives none for a lexicon word): the strip stays closed.
        let rig = AutocorrectRig.typingASpace(after: "hi", corrections: [:])
        var changes = 0
        rig.editor.onSwipeStripChanged = { changes += 1 }
        rig.tap("there")
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, nil)
        TestSupport.expectEqual(changes, 0)
        // Nothing is asked where the corrector is not: autocorrect off, a secure field, a field that turns
        // autocorrection off, a swiped word, a word with other characters, a reverted word.
        func asked(_ configure: (AutocorrectRig) -> Void, _ type: (AutocorrectRig) -> Void) -> Int {
            let rig = AutocorrectRig("", corrections: ["teh": "the"], alternatives: ["teh": ["the"], "wrld": ["world"], "café": ["cafe"]])
            configure(rig)
            type(rig)
            TestSupport.expectEqual(rig.strip, nil)
            return rig.corrector.suggestionCalls.count
        }
        TestSupport.expectEqual(asked({ $0.enabled = false }, { $0.tap("wrld"); $0.press(.space) }), 0)
        TestSupport.expectEqual(asked({ $0.secure = true }, { $0.tap("wrld"); $0.press(.space) }), 0)
        TestSupport.expectEqual(asked({ $0.autocorrectionDisabled = true }, { $0.tap("wrld"); $0.press(.space) }), 0)
        TestSupport.expectEqual(asked({ _ in }, { $0.swipe(["wrld"]); $0.press(.space) }), 0)
        TestSupport.expectEqual(asked({ _ in }, { $0.tap("café"); $0.press(.space) }), 0)
        TestSupport.expectEqual(asked({ _ in }, { $0.tap("teh"); $0.press(.space); $0.heldDelete(); $0.press(.space) }), 1)
    }

    private static func testChoosingReplacesTheWordBeforeTheCommitKey() {
        let rig = AutocorrectRig.typingASpace(after: "hi", alternatives: ["wrld": ["world", "would"]])
        rig.tap("wrld")
        rig.press(.character(","))
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "hi world,")
        TestSupport.expectEqual(rig.document.host.caret, 9)
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["wrld", "world", "would"], inserted: 1))
        rig.choose(2)
        TestSupport.expectEqual(rig.text, "hi would,")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "hi wrld,")
        // Choosing the word already in the field does nothing.
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "hi wrld,")
        TestSupport.expectEqual(rig.events, [.checked, .chosen, .chosen, .chosen])
        TestSupport.expect(rig.editor.revertedWords.isEmpty, "a kept word chosen back is not reverted")
        // The next word is still this keyboard's own: corrected at its commit key.
        rig.press(.space)
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "hi wrld, the ")
        // A choice ends the pending revert: Delete then deletes one character.
        let chosen = AutocorrectRig.typingASpace(after: "so", alternatives: ["teh": ["the", "ten"]])
        chosen.tap("teh")
        chosen.press(.space)
        chosen.choose(2)
        TestSupport.expectEqual(chosen.text, "so ten ")
        chosen.heldDelete()
        TestSupport.expectEqual(chosen.text, "so ten")
        TestSupport.expect(chosen.editor.revertedWords.isEmpty, "a Delete after a choice reverted")
        TestSupport.expectEqual(chosen.events, [.checked, .corrected, .chosen])
    }

    private static func testChoosingTheTypedWordRevertsTheCorrection() {
        let rig = AutocorrectRig.typingASpace(after: "so", alternatives: ["teh": ["the"]])
        rig.tap("Teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so The ")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "so Teh ")
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["Teh", "The"], inserted: 0))
        TestSupport.expectEqual(rig.editor.revertedWords, ["teh"])
        TestSupport.expectEqual(rig.events, [.checked, .corrected, .reverted])
        // Never corrected or offered again in this keyboard instance.
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so Teh teh ")
        TestSupport.expectEqual(rig.strip, nil)
        TestSupport.expectEqual(rig.corrector.calls.count, 1)
        TestSupport.expectEqual(rig.corrector.suggestionCalls.count, 1)
        // Choosing the correction back is a choice, and undoes the revert.
        let back = AutocorrectRig("", corrections: ["teh": "the"])
        back.tap("teh")
        back.press(.space)
        back.choose(0)
        back.choose(1)
        TestSupport.expectEqual(back.text, "the ")
        TestSupport.expectEqual(back.events, [.checked, .corrected, .reverted, .chosen])
        TestSupport.expect(back.editor.revertedWords.isEmpty, "the correction chosen back stays reverted")
        // Tapping the correction already in the field confirms it: a Delete after is a plain Delete.
        let confirmed = AutocorrectRig("", corrections: ["teh": "the"])
        confirmed.tap("teh")
        confirmed.press(.space)
        confirmed.choose(1)
        TestSupport.expectEqual(confirmed.text, "the ")
        confirmed.heldDelete()
        TestSupport.expectEqual(confirmed.text, "the")
        TestSupport.expectEqual(confirmed.events, [.checked, .corrected])
        TestSupport.expect(confirmed.editor.revertedWords.isEmpty, "a confirmed correction was reverted")
    }

    private static func testTheCommitStripClosesAndRefusesLikeTheSwipeStrip() {
        let alternatives = ["wrld": ["world"]]
        // Any key closes it; a Delete deletes one character (not the whole word, as after a swipe).
        let typed = AutocorrectRig("", corrections: [:], alternatives: alternatives)
        typed.tap("wrld")
        typed.press(.space)
        typed.tap("a")
        TestSupport.expectEqual(typed.strip, nil)
        let deleted = AutocorrectRig("", corrections: [:], alternatives: alternatives)
        deleted.tap("wrld")
        deleted.press(.space)
        deleted.heldDelete()
        TestSupport.expectEqual(deleted.text, "wrld")
        TestSupport.expectEqual(deleted.strip, nil)
        // After a correction, Delete reverts and closes it.
        let reverted = AutocorrectRig("", corrections: ["teh": "the"], alternatives: ["teh": ["ten"]])
        reverted.tap("teh")
        reverted.press(.space)
        reverted.heldDelete()
        TestSupport.expectEqual(reverted.text, "teh")
        TestSupport.expectEqual(reverted.strip, nil)
        // An outside edit closes it; a field changed without a report yet refuses the choice and closes it.
        let outside = AutocorrectRig("", corrections: [:], alternatives: alternatives)
        outside.tap("wrld")
        outside.press(.space)
        outside.document.hostInserts("A ", at: 0)
        outside.pump()
        TestSupport.expectEqual(outside.strip, nil)
        let moved = AutocorrectRig("", corrections: [:], alternatives: alternatives)
        moved.tap("wrld")
        moved.press(.space)
        moved.document.host.hostInsert("wrld ", at: 0)
        moved.document.host.moveCaret(to: 5)
        moved.document.host.refreshContext()
        moved.choose(1)
        TestSupport.expectEqual(moved.text, "wrld wrld ")
        TestSupport.expectEqual(moved.strip, nil)
        TestSupport.expectEqual(moved.events, [.checked])
    }

    // MARK: Through the key area

    private static func testTapsCarryTheirTouchDownPointThroughTheKeyArea() {
        // With autocorrect on, letter taps are soft taps: each carries its touch-down point, decided at
        // touch-down (`typeDecided`) or not (`tap`), and without soft key edges types its nearest key.
        let harness = KeyboardHarness(FakeTextHost(text: ""))
        let corrector = FakeCorrector(["teh": "the"])
        let keys = KeyboardLayout.keys(for: .letters, metrics: KeyboardHarness.metrics, showsGlobe: false)
        harness.editor.autocorrect = { AutocorrectSetup(corrector: corrector, keys: keys, params: .standard, secureTextEntry: false) }
        harness.softTapsEnabled = true
        func centre(_ letter: String) -> (x: Double, y: Double) {
            let frame = keys.first { $0.action == .character(letter) }!.frame
            return (frame.midX, frame.midY)
        }
        let t = centre("t"), e = centre("e"), h = centre("h")
        // "t" undecided, "e" decided as itself at touch-down, "h" off-centre but still its nearest key.
        harness.touchUp(harness.touchDown(atX: t.x, y: t.y))
        let second = harness.touchDown(atX: e.x, y: e.y)
        harness.decideTap(second, as: .character("e"))
        harness.touchUp(second)
        harness.touchUp(harness.touchDown(atX: h.x + 3, y: h.y - 4))
        harness.tap(.space)
        TestSupport.expectEqual(harness.document.text, "the ")
        TestSupport.expectEqual(corrector.calls.count, 1)
        TestSupport.expectEqual(corrector.calls[0].points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } },
                                [TapPoint(x: t.x, y: t.y), TapPoint(x: e.x, y: e.y), TapPoint(x: h.x + 3, y: h.y - 4)])
    }
}

/// A corrector that maps words and suggests words as told and remembers every call.
final class FakeCorrector: WordCorrecting {
    struct Call {
        var context: String
        var word: String
        var points: [(x: Double, y: Double)?]
        var keys: [PlacedKey]
        var params: AutocorrectParams
    }

    var corrections: [String: String]
    var alternatives: [String: [String]]
    private(set) var calls: [Call] = []
    private(set) var suggestionCalls: [(call: Call, limit: Int)] = []

    init(_ corrections: [String: String], alternatives: [String: [String]] = [:]) {
        self.corrections = corrections
        self.alternatives = alternatives
    }

    func correct(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                 params: AutocorrectParams) -> String {
        calls.append(Call(context: context, word: word, points: points, keys: keys, params: params))
        return corrections[word] ?? word
    }

    func suggestions(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                     params: AutocorrectParams, limit: Int) -> [String] {
        suggestionCalls.append((Call(context: context, word: word, points: points, keys: keys, params: params), limit))
        return Array((alternatives[word] ?? []).prefix(limit))
    }

    func forgetContext() {}
}

/// The editor with autocorrect on (unless `enabled` is false) and a fake corrector, in a fake field. Taps type
/// letters with invented points: consecutive x from `from`.
final class AutocorrectRig {
    static let keys = KeyboardLayout.keys(for: .letters, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                                          showsGlobe: false)

    let document: FakeDocument
    let editor: KeyboardEditor
    let corrector: FakeCorrector
    var params = AutocorrectParams.standard
    var enabled = true
    var secure = false
    var autocorrectionDisabled = false
    var autocapitalization: AutocapitalizationMode = .none
    private(set) var events: [WordAutocorrect.Event] = []
    private var time: TimeInterval = 100

    init(_ text: String, corrections: [String: String], alternatives: [String: [String]] = [:], editCallbackDelay: Int? = nil,
         documentID: UUID? = UUID()) {
        document = FakeDocument(FakeTextHost(text: text), documentID: documentID)
        document.editCallbackDelay = editCallbackDelay
        let trackpad = TrackpadController(host: document)
        trackpad.parameters = .flat
        editor = KeyboardEditor(document: document, trackpad: trackpad)
        corrector = FakeCorrector(corrections, alternatives: alternatives)
        editor.autocapitalization = { [unowned self] in self.autocapitalization }
        editor.autocorrect = { [unowned self] in
            guard self.enabled else { return nil }
            return AutocorrectSetup(corrector: self.corrector, keys: Self.keys, params: self.params, secureTextEntry: self.secure,
                                    autocorrectionDisabled: self.autocorrectionDisabled)
        }
        editor.onAutocorrectEvent = { [unowned self] in self.events.append($0) }
        editor.reset(numeric: false)
    }

    var text: String { document.text }

    /// A field holding `text` the keyboard did not type, then a space it typed: the next word is its own.
    static func typingASpace(after text: String, corrections: [String: String] = ["teh": "the"],
                             alternatives: [String: [String]] = [:]) -> AutocorrectRig {
        let rig = AutocorrectRig(text, corrections: corrections, alternatives: alternatives)
        rig.press(.space)
        return rig
    }

    @discardableResult
    func tick() -> TimeInterval {
        time += 0.05
        return time
    }

    /// Letters tapped on the letters layer, each with a point. A capital types as itself (the shift off).
    func tap(_ letters: String, from x: Double = 0) {
        for (index, letter) in letters.enumerated() {
            tick()
            editor.press(.character(String(letter)), field: document.documentID, at: time, now: time,
                         point: TapPoint(x: x + Double(index), y: 10))
        }
    }

    func press(_ action: KeyAction) {
        tick()
        editor.press(action, field: document.documentID, at: time, now: time)
    }

    func heldDelete(_ unit: DeleteRepeat.Unit = .character) {
        editor.heldDelete(unit, field: document.documentID, now: tick())
    }

    /// A tap on the strip's word `index`.
    func choose(_ index: Int) {
        editor.chooseSwipeCandidate(at: index, now: tick())
    }

    var strip: SwipeStrip? { editor.swipeStrip }

    func swipe(_ words: [String]) {
        let candidates = words.enumerated().map { SwipeCandidate(word: $1, score: -Double($0)) }
        editor.insertSwipe(candidates, field: document.documentID, now: tick())
    }

    @discardableResult
    func pump() -> [EditingCore.CallbackOutcome] {
        document.pump(editor, at: tick())
    }
}
