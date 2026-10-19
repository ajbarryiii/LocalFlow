import Foundation

/// Autocorrect in the editor (ARCHITECTURE.md, "Word autocorrect"): the word's tap record, the word before the
/// caret and its gates, the corrector's inputs, the case of the correction, the replacement in one edit with
/// the commit key, the revert and the reverted words, and that nothing changes with autocorrect off. The
/// corrector is a fake; every word, text and point is invented.
enum AutocorrectEditorTests {
    static var tests: [TestCase] {
        [
            ("recordKeepsTheWordsTapsInOrder", testRecordKeepsTheWordsTapsInOrder),
            ("recordPopsOnDeleteAndClearsOnOtherCharacters", testRecordPopsOnDeleteAndClearsOnOtherCharacters),
            ("recordMatchesOnlyTheRunItRecorded", testRecordMatchesOnlyTheRunItRecorded),
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
            ("unrecordedCharactersGiveNoPoints", testUnrecordedCharactersGiveNoPoints),
            ("deleteRemovesTheLastTap", testDeleteRemovesTheLastTap),
            ("outsideEditsCaretMovesAndFieldsClearTheRecord", testOutsideEditsCaretMovesAndFieldsClearTheRecord),
            ("correctionIsOneOwnEditBeforeTheKey", testCorrectionIsOneOwnEditBeforeTheKey),
            ("unverifiedCaretContextIsNotCorrected", testUnverifiedCaretContextIsNotCorrected),
            ("proxyThatHasNotShownTheWordIsNotCorrected", testProxyThatHasNotShownTheWordIsNotCorrected),
            ("layoutChangeDropsTheRecordedPoints", testLayoutChangeDropsTheRecordedPoints),
            ("deleteRightAfterRevertsAndRemembers", testDeleteRightAfterRevertsAndRemembers),
            ("heldDeleteRevertsThenRepeatsAsUsual", testHeldDeleteRevertsThenRepeatsAsUsual),
            ("revertRestoresTheTypedWordsTaps", testRevertRestoresTheTypedWordsTaps),
            ("anyOtherKeyForgetsThePendingRevert", testAnyOtherKeyForgetsThePendingRevert),
            ("revertNeedsTheFieldUnchanged", testRevertNeedsTheFieldUnchanged),
            ("revertedWordsOutlastHiding", testRevertedWordsOutlastHiding),
            ("nothingChangesWithAutocorrectOff", testNothingChangesWithAutocorrectOff),
            ("tapsCarryTheirTouchDownPointThroughTheKeyArea", testTapsCarryTheirTouchDownPointThroughTheKeyArea),
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
        TestSupport.expectEqual(record.entries.map(\.character), ["T", "e", "'", "h"])
        TestSupport.expectEqual(record.entries.map(\.point), [p(1), p(2), nil, p(3)])
        TestSupport.expect(!record.entries.contains(where: \.swiped), "a tap recorded as swiped")
        // Only the last character of an edit carries the tap's point (a space owed after a swiped word goes in
        // with the tapped letter).
        record.edited(deleted: 0, inserted: " a", point: p(4))
        TestSupport.expectEqual(record.entries, [WordTapRecord.Entry(character: "a", point: p(4), swiped: false)])
        // A swipe's characters have no point.
        record.edited(deleted: 0, inserted: " word", swiped: true)
        TestSupport.expectEqual(record.entries.map(\.point), [nil, nil, nil, nil])
        TestSupport.expect(record.entries.allSatisfy(\.swiped), "a swipe recorded as tapped")
    }

    private static func testRecordPopsOnDeleteAndClearsOnOtherCharacters() {
        var record = WordTapRecord()
        for (index, letter) in "abc".enumerated() { record.edited(deleted: 0, inserted: String(letter), point: p(Double(index))) }
        record.edited(deleted: 1, inserted: "")
        TestSupport.expectEqual(record.entries.map(\.character), ["a", "b"])
        record.edited(deleted: 1, inserted: "x", point: p(9))
        TestSupport.expectEqual(record.entries.map(\.point), [p(0), p(9)])
        // Deleting further back than the record empties it.
        record.edited(deleted: 5, inserted: "")
        TestSupport.expectEqual(record.entries, [])
        // A commit key, a digit or a symbol starts a new word.
        for other in [" ", "\n", ".", "-", "7", "@"] {
            record.edited(deleted: 0, inserted: "q", point: p(1))
            record.edited(deleted: 0, inserted: other)
            TestSupport.expect(record.entries.isEmpty, "\(other) kept the record")
        }
        record.edited(deleted: 0, inserted: "q", point: p(1))
        record.clear()
        TestSupport.expectEqual(record.entries, [])
    }

    private static func testRecordMatchesOnlyTheRunItRecorded() {
        var record = WordTapRecord()
        record.edited(deleted: 0, inserted: "h", point: p(1))
        record.edited(deleted: 0, inserted: "i", point: p(2))
        TestSupport.expectEqual(record.entries(matching: "hi")?.map(\.point), [p(1), p(2)])
        TestSupport.expectEqual(record.entries(matching: "ohi"), nil)
        TestSupport.expectEqual(record.entries(matching: "i"), nil)
        TestSupport.expectEqual(record.entries(matching: "Hi"), nil)
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
            let rig = AutocorrectRig("so ", corrections: ["teh": "the"])
            rig.tap("teh")
            rig.press(key)
            TestSupport.expectEqual(rig.text, "so the" + text)
            TestSupport.expectEqual(rig.document.host.caret, ("so the" + text).utf16.count)
            TestSupport.expectEqual(rig.events, [.checked, .corrected])
        }
    }

    private static func testCorrectorGetsContextWordPointsLayoutAndParams() {
        let rig = AutocorrectRig("Well, I \u{2019}said\u{2019}\nNo WAY 42 ", corrections: ["teh": "the"])
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
        // A curly apostrophe in the proxy's text is given to the corrector as "'".
        let curly = AutocorrectRig("don\u{2019}t", corrections: [:])
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
        // A space after a space, or a key after punctuation, has no word.
        rig.press(.space)
        rig.press(.space)
        rig.press(.character("."))
        TestSupport.expectEqual(rig.corrector.calls.count, 2)
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

    private static func testUnrecordedCharactersGiveNoPoints() {
        // The word started in the proxy's text: the record ("h") does not match it ("teh").
        let rig = AutocorrectRig("so te", corrections: ["teh": "the"])
        rig.tap("h")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so the ")
        TestSupport.expectEqual(rig.corrector.calls[0].points.map { $0 == nil }, [true, true, true])
        // A letter from another layer (no point) is recorded as none.
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
        TestSupport.expectEqual(rig.corrector.calls[0].word, "xabc")
        TestSupport.expectEqual(rig.corrector.calls[0].points.map { $0 == nil }, [true, true, true, true])
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
        // Once the proxy has shown where the caret is, the next word is corrected again.
        harness.press(.character("t"))
        harness.press(.character("e"))
        harness.press(.character("h"))
        harness.settle()
        harness.press(.space)
        TestSupport.expectEqual(corrector.calls.count, 1)
        TestSupport.expect(harness.document.text.hasPrefix("teh\u{1F44D} the"), "\(harness.document.text)")
    }

    private static func testProxyThatHasNotShownTheWordIsNotCorrected() {
        // A proxy that lags our own edits does not show the word yet: its text before the caret is not verified,
        // so the word is committed as typed.
        let rig = AutocorrectRig("so ", corrections: ["teh": "the"])
        rig.document.host.editContextLagFrames = 3
        rig.tap("teh")
        TestSupport.expect(rig.document.host.isContextStale, "the proxy showed the letters at once")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so teh ")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // Once it shows the word, the word is corrected.
        rig.tap("teh")
        for _ in 0 ..< 4 { rig.document.host.advanceFrame() }
        TestSupport.expect(!rig.document.host.isContextStale, "the proxy never caught up")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so teh the ")
    }

    private static func testLayoutChangeDropsTheRecordedPoints() {
        // Code review (2026-10-19, P2): points recorded in one layout mean nothing in another (a resize or a
        // rotation). A layout change keeps the word's characters and drops their points; later taps have theirs.
        var record = WordTapRecord()
        record.edited(deleted: 0, inserted: "a", point: p(1))
        record.edited(deleted: 0, inserted: "b", swiped: true)
        record.forgetPoints()
        TestSupport.expectEqual(record.entries, [WordTapRecord.Entry(character: "a", point: nil, swiped: false),
                                                 WordTapRecord.Entry(character: "b", point: nil, swiped: true)])
        let rig = AutocorrectRig("", corrections: [:])
        rig.tap("hel", from: 0)
        rig.editor.layoutChanged()
        rig.tap("lo", from: 50)
        rig.press(.space)
        TestSupport.expectEqual(rig.corrector.calls[0].word, "hello")
        TestSupport.expectEqual(rig.corrector.calls[0].points.map { $0.map { TapPoint(x: $0.x, y: $0.y) } },
                                [nil, nil, nil, p(50), p(51)])
    }

    // MARK: Revert

    private static func testDeleteRightAfterRevertsAndRemembers() {
        let rig = AutocorrectRig("so ", corrections: ["teh": "the"])
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
        // VoiceOver's delete reverts too, after punctuation or Return.
        for (key, text) in [(KeyAction.character(","), ","), (.returnKey, "\n")] {
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
        let rig = AutocorrectRig("so ", corrections: ["teh": "the"])
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

/// A corrector that maps words as told and remembers every call.
final class FakeCorrector: WordCorrecting {
    struct Call {
        var context: String
        var word: String
        var points: [(x: Double, y: Double)?]
        var keys: [PlacedKey]
        var params: AutocorrectParams
    }

    var corrections: [String: String]
    private(set) var calls: [Call] = []

    init(_ corrections: [String: String]) {
        self.corrections = corrections
    }

    func correct(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                 params: AutocorrectParams) -> String {
        calls.append(Call(context: context, word: word, points: points, keys: keys, params: params))
        return corrections[word] ?? word
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
    var autocapitalization: AutocapitalizationMode = .none
    private(set) var events: [WordAutocorrect.Event] = []
    private var time: TimeInterval = 100

    init(_ text: String, corrections: [String: String], editCallbackDelay: Int? = nil) {
        document = FakeDocument(FakeTextHost(text: text))
        document.editCallbackDelay = editCallbackDelay
        let trackpad = TrackpadController(host: document)
        trackpad.parameters = .flat
        editor = KeyboardEditor(document: document, trackpad: trackpad)
        corrector = FakeCorrector(corrections)
        editor.autocapitalization = { [unowned self] in self.autocapitalization }
        editor.autocorrect = { [unowned self] in
            guard self.enabled else { return nil }
            return AutocorrectSetup(corrector: self.corrector, keys: Self.keys, params: self.params, secureTextEntry: self.secure)
        }
        editor.onAutocorrectEvent = { [unowned self] in self.events.append($0) }
        editor.reset(numeric: false)
    }

    var text: String { document.text }

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

    func swipe(_ words: [String]) {
        let candidates = words.enumerated().map { SwipeCandidate(word: $1, score: -Double($0)) }
        editor.insertSwipe(candidates, field: document.documentID, now: tick())
    }

    @discardableResult
    func pump() -> [EditingCore.CallbackOutcome] {
        document.pump(editor, at: tick())
    }
}
