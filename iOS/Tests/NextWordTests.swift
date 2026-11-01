import Foundation

/// Next words after a space (ARCHITECTURE.md, "Word autocorrect", Next words): after a finished word and a space this
/// keyboard typed, when no other strip shows, up to three likely next words from the word model, cased as typing would
/// case them; a tap puts one in with one space and the strip predicts the word after it. Every word, text and model is
/// invented or a tiny fixture.
enum NextWordTests {
    static var tests: [TestCase] {
        [
            ("theLikeliestWordsInTheContext", testTheLikeliestWordsInTheContext),
            ("unlikelyAndJunkWordsAreNotOffered", testUnlikelyAndJunkWordsAreNotOffered),
            ("oneReadOutServesTheNextWordAndItsCompletions", testOneReadOutServesTheNextWordAndItsCompletions),
            ("predictionsFollowAFinishedWordAndASpace", testPredictionsFollowAFinishedWordAndASpace),
            ("aTappedPredictionGoesInWithOneSpaceAndChains", testATappedPredictionGoesInWithOneSpaceAndChains),
            ("predictionsAreCasedAsTypingWouldCaseThem", testPredictionsAreCasedAsTypingWouldCaseThem),
            ("noPredictionsWhereSuggestionsAreOff", testNoPredictionsWhereSuggestionsAreOff),
            ("anotherStripComesFirst", testAnotherStripComesFirst),
            ("predictionsCloseWithAnyOtherKey", testPredictionsCloseWithAnyOtherKey),
            ("aTapAppliesOnlyWhereThePredictionsWereMade", testATapAppliesOnlyWhereThePredictionsWereMade),
            ("dictationWinsTheBar", testDictationWinsTheBar),
            ("aTapNeedsTheProxyToShowTheSpace", testATapNeedsTheProxyToShowTheSpace),
        ]
    }

    // MARK: The corrector

    static let entries: [(String, Int)] = [
        ("you", 250), ("the", 250), ("tomorrow", 200), ("later", 200), ("soon", 180), ("a", 250), ("i", 250), ("x", 100),
        ("home", 200), ("bit", 180), ("late", 190), ("my", 240), ("way", 200), ("cant", 60), ("can't", 210), ("think", 220),
    ]

    static func corrector(_ byPrevious: [String: [String: Double]]) -> (Autocorrector, TypingSuggestionsTests.CountingModel) {
        let model = TypingSuggestionsTests.CountingModel(Dictionary(uniqueKeysWithValues: entries.map { ($0.0, 0.01) }),
                                                         byPrevious: byPrevious)
        return (Autocorrector(lexicon: AutocorrectCoreTests.lexicon(entries), model: model, touch: AutocorrectCoreTests.touch), model)
    }

    private static func testTheLikeliestWordsInTheContext() {
        let (corrector, _) = corrector(["see": ["you": 0.5, "the": 0.2, "tomorrow": 0.05, "later": 0.01]])
        // Best first, by the word model given the sentence so far; at most `limit`.
        TestSupport.expectEqual(corrector.nextWords(context: "i will see ", limit: 3), ["you", "the", "tomorrow"])
        TestSupport.expectEqual(corrector.nextWords(context: "i will see ", limit: 2), ["you", "the"])
        TestSupport.expectEqual(corrector.nextWords(context: "i will see ", limit: 0), [])
        // The sentence is what counts: the text before its last period is not.
        TestSupport.expectEqual(corrector.nextWords(context: "we see. i will see ", limit: 3), ["you", "the", "tomorrow"])
    }

    private static func testUnlikelyAndJunkWordsAreNotOffered() {
        let (corrector, _) = corrector([
            "hmm": ["you": 0.02, "the": 0.015],
            "on": ["my": 0.8, "the": 0.03, "way": 0.045],
            "got": ["x": 0.3, "a": 0.2, "i": 0.1, "home": 0.1],
            "bit": ["bit": 0.3, "late": 0.2],
            "i": ["cant": 0.3, "can't": 0.1, "think": 0.2],
            "can't": ["cant": 0.3, "think": 0.2],
        ])
        // Nothing likely enough (`nextWordFloor`): nothing at all, rather than noise.
        TestSupport.expect(Autocorrector.nextWordFloor >= 0.02, "floor \(Autocorrector.nextWordFloor)")
        TestSupport.expectEqual(corrector.nextWords(context: "hmm ", limit: 3), [])
        // Far less likely than the best (`nextWordRatio`): left out, so fewer words show.
        TestSupport.expectEqual(corrector.nextWords(context: "on ", limit: 3), ["my", "way"])
        // No single letters but "a" and "I".
        TestSupport.expectEqual(corrector.nextWords(context: "just got ", limit: 3), ["a", "i", "home"])
        // Never the previous word again.
        TestSupport.expectEqual(corrector.nextWords(context: "a bit ", limit: 3), ["late"])
        // One form per spelling, the likelier; a contraction typed without its apostrophe is offered with it.
        TestSupport.expectEqual(corrector.nextWords(context: "i ", limit: 3), ["can't", "think"])
        // Sol review (round 5, run 2): the previous word is a repeat in any spelling ("cant" after "can't").
        TestSupport.expectEqual(corrector.nextWords(context: "i can't ", limit: 3), ["think"])
    }

    private static func testOneReadOutServesTheNextWordAndItsCompletions() {
        // The word model reads out every form once for a context: the next words after the space, then the completions
        // of the word typed there, share it.
        let (corrector, model) = corrector(["see": ["you": 0.5, "the": 0.2]])
        _ = corrector.nextWords(context: "i will see ", limit: 3)
        _ = corrector.nextWords(context: "i will see ", limit: 3)
        for prefix in ["y", "yo"] {
            _ = corrector.predictions(context: "i will see ", word: prefix, points: AutocorrectCoreTests.centreTaps(prefix),
                                      keys: AutocorrectCoreTests.keys, params: .standard, limit: SwipeStrip.limit)
        }
        TestSupport.expectEqual(model.allFormCalls, 1)
        _ = corrector.nextWords(context: "i will see you ", limit: 3)
        TestSupport.expectEqual(model.allFormCalls, 2)
    }

    // MARK: The strip

    static func plain(_ candidates: [String]) -> SwipeStrip {
        SwipeStrip(candidates: candidates, inserted: 0, live: SwipeStrip.Live(quoted: nil, marked: nil))
    }

    private static func testPredictionsFollowAFinishedWordAndASpace() {
        let rig = AutocorrectRig("", corrections: [:])
        rig.corrector.following = ["see ": ["you", "the", "tomorrow"]]
        rig.tap("see")
        TestSupport.expectEqual(rig.strip, nil)
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, plain(["you", "the", "tomorrow"]))
        TestSupport.expectEqual(rig.corrector.nextWordCalls.last?.context, "see ")
        TestSupport.expectEqual(rig.corrector.nextWordCalls.last?.limit, SwipeStrip.limit)
        // Nothing likely: no strip.
        rig.tap("hmm")
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, nil)
        // After punctuation and a space, and after a sentence's end: the corrector is asked for the whole line.
        rig.corrector.following = ["see hmm hi# ": ["there"], "see hmm hi# ok. ": ["i"]]
        rig.tap("hi")
        rig.press(.character(","))
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, plain(["there"]))
        rig.tap("ok")
        rig.press(.character("."))
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, plain(["I"]))
        // Not in an empty field, nor after a space typed at the field's start or after another space.
        let empty = AutocorrectRig("", corrections: [:])
        empty.corrector.following = ["": ["i"], " ": ["i"]]
        TestSupport.expectEqual(empty.strip, nil)
        empty.press(.space)
        TestSupport.expectEqual(empty.strip, nil)
        let spaced = AutocorrectRig("so ", corrections: [:])
        spaced.corrector.following = ["so ": ["much"]]
        spaced.press(.space)
        TestSupport.expectEqual(spaced.strip, nil)
    }

    private static func testATappedPredictionGoesInWithOneSpaceAndChains() {
        let rig = AutocorrectRig("", corrections: [:])
        rig.corrector.following = ["see ": ["you", "the"], "see you ": ["tomorrow", "later"]]
        rig.tap("see")
        rig.press(.space)
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "see you ")
        // The strip then predicts the word after it.
        TestSupport.expectEqual(rig.strip, plain(["tomorrow", "later"]))
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "see you later ")
        TestSupport.expectEqual(rig.strip, nil)
        // Punctuation right after goes before the tapped word's space, as after any tapped word.
        rig.press(.character("!"))
        TestSupport.expectEqual(rig.text, "see you later! ")
        // The next word typed is the keyboard's own: it is corrected.
        let owned = AutocorrectRig("", corrections: ["teh": "the"])
        owned.corrector.following = ["see ": ["you"]]
        owned.tap("see")
        owned.press(.space)
        owned.choose(0)
        owned.tap("teh")
        owned.press(.space)
        TestSupport.expectEqual(owned.text, "see you the ")
        // A space already after the caret is not doubled.
        let before = AutocorrectRig(" now", corrections: [:])
        before.document.host.moveCaret(to: 0)
        before.pump()
        before.corrector.following = ["see ": ["you"]]
        before.tap("see")
        before.press(.space)
        TestSupport.expectEqual(before.text, "see  now")
        before.choose(0)
        TestSupport.expectEqual(before.text, "see you now")
    }

    private static func testPredictionsAreCasedAsTypingWouldCaseThem() {
        // At a sentence's start, capitalized as a letter typed there would be; "I" and day names always.
        let rig = AutocorrectRig("", corrections: [:])
        rig.autocapitalization = .sentences
        rig.corrector.following = ["ok. ": ["thanks", "i"], "ok. thanks ": ["i", "for", "friday"]]
        rig.tap("ok")
        rig.press(.character("."))
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, plain(["Thanks", "I"]))
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "ok. Thanks ")
        TestSupport.expectEqual(rig.strip, plain(["I", "for", "Friday"]))
        // A shift the user sets recases them; caps lock (or a field of capitals) makes them all capitals.
        let shifted = AutocorrectRig("", corrections: [:])
        shifted.corrector.following = ["see ": ["you", "the"]]
        shifted.tap("see")
        shifted.press(.space)
        shifted.press(.shift)
        TestSupport.expectEqual(shifted.strip, plain(["You", "The"]))
        shifted.choose(1)
        TestSupport.expectEqual(shifted.text, "see The ")
        TestSupport.expectEqual(shifted.editor.typing.shift, .off)
        let capitals = AutocorrectRig("", corrections: [:])
        capitals.autocapitalization = .allCharacters
        capitals.corrector.following = ["see ": ["you"]]
        capitals.tap("SEE")
        capitals.press(.space)
        TestSupport.expectEqual(capitals.strip, plain(["YOU"]))
    }

    private static func testNoPredictionsWhereSuggestionsAreOff() {
        func shows(_ configure: (AutocorrectRig) -> Void) -> Bool {
            let rig = AutocorrectRig("", corrections: [:])
            rig.corrector.following = ["see ": ["you"]]
            configure(rig)
            rig.tap("see")
            rig.press(.space)
            return rig.strip != nil
        }
        TestSupport.expect(shows { _ in }, "ordinary field")
        TestSupport.expect(!shows { $0.enabled = false }, "autocorrect off")
        TestSupport.expect(!shows { $0.secure = true }, "secure field")
        TestSupport.expect(!shows { $0.autocorrectionDisabled = true }, "autocorrection off")
        TestSupport.expect(!shows { $0.field = .email }, "email field")
        TestSupport.expect(!shows { $0.field = .url }, "URL field")
        TestSupport.expect(!shows { $0.numeric = true }, "number field")
        TestSupport.expect(shows { $0.field = .webSearch }, "search field")
        let off = AutocorrectRig("", corrections: [:])
        off.field = .url
        off.corrector.following = ["see ": ["you"]]
        off.tap("see")
        off.press(.space)
        TestSupport.expectEqual(off.corrector.nextWordCalls.count, 0)
    }

    private static func testAnotherStripComesFirst() {
        // A correction's strip (a choice) shows instead; the word typed next gets its own.
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.corrector.following = ["the ": ["end"], "teh ": ["end"]]
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["teh", "the"], inserted: 1))
        // A swipe's strip too.
        let swiped = AutocorrectRig("", corrections: [:])
        swiped.corrector.following = ["see ": ["you"]]
        swiped.tap("see")
        swiped.press(.space)
        swiped.swipe(["your", "you"])
        TestSupport.expectEqual(swiped.strip, SwipeStrip(candidates: ["your", "you"], inserted: 0))
        // Sol review (round 5, lead run 1): a swiped word's choice that adds the space keeps its strip first, and once
        // Shift closes that strip the next words follow, as after the space key.
        swiped.corrector.following["see you "] = ["later"]
        swiped.choose(1)
        TestSupport.expectEqual(swiped.text, "see you ")
        TestSupport.expectEqual(swiped.strip?.candidates, ["your", "you"])
        swiped.press(.shift)
        TestSupport.expectEqual(swiped.strip, plain(["Later"]))
        // The word typed after the space has its own strip, or none.
        let typed = AutocorrectRig("", corrections: [:])
        typed.corrector.following = ["see ": ["you"]]
        typed.corrector.predicted = ["y": WordPredictions(words: ["you", "yes"], isWord: false)]
        typed.tap("see")
        typed.press(.space)
        typed.tap("y")
        TestSupport.expectEqual(typed.strip, plain(["you", "yes"]))
        typed.tap("q")
        TestSupport.expectEqual(typed.strip, nil)
    }

    private static func testPredictionsCloseWithAnyOtherKey() {
        func rig() -> AutocorrectRig {
            let rig = AutocorrectRig("", corrections: [:])
            rig.corrector.following = ["see ": ["you"]]
            rig.tap("see")
            rig.press(.space)
            TestSupport.expectEqual(rig.strip, plain(["you"]))
            return rig
        }
        let deleted = rig()
        deleted.heldDelete()
        TestSupport.expectEqual(deleted.strip, nil)
        let returned = rig()
        returned.press(.returnKey)
        TestSupport.expectEqual(returned.strip, nil)
        let numbers = rig()
        numbers.press(.layer(.numbers))
        TestSupport.expectEqual(numbers.strip, plain(["you"]))
        numbers.press(.character("4"))
        TestSupport.expectEqual(numbers.strip, nil)
        let moved = rig()
        moved.document.moveCaret(to: 1)
        moved.pump()
        TestSupport.expectEqual(moved.strip, nil)
        let hidden = rig()
        hidden.hide()
        TestSupport.expectEqual(hidden.strip, nil)
        hidden.show()
        TestSupport.expectEqual(hidden.strip, nil)
        let trackpad = rig()
        trackpad.editor.closeSwipeStrip()
        TestSupport.expectEqual(trackpad.strip, nil)
    }

    private static func testATapAppliesOnlyWhereThePredictionsWereMade() {
        // Focus moved to another field before any callback: the tap types nothing anywhere, and the strip closes.
        let rig = AutocorrectRig("", corrections: [:])
        rig.corrector.following = ["see ": ["you"]]
        rig.tap("see")
        rig.press(.space)
        let other = FakeTextHost(text: "other")
        rig.document.switchField(to: other, id: UUID())
        rig.choose(0)
        TestSupport.expectEqual(rig.document.previousHosts.first?.text, "see ")
        TestSupport.expectEqual(rig.text, "other")
        TestSupport.expectEqual(rig.strip, nil)
        // The caret moved (not reported yet): the same.
        let moved = AutocorrectRig("", corrections: [:])
        moved.corrector.following = ["see ": ["you"]]
        moved.tap("see")
        moved.press(.space)
        moved.document.host.moveCaret(to: 1)
        moved.choose(0)
        TestSupport.expectEqual(moved.text, "see ")
        TestSupport.expectEqual(moved.strip, nil)
    }

    /// Sol review (round 5, run 1): the editor's copy of the text before the caret is not proof. The host took the space
    /// back before reporting it: the tap types nothing ("seeyou " before). A proxy whose window is longer than the
    /// editor's copy, showing the same space, still takes the tap.
    private static func testATapNeedsTheProxyToShowTheSpace() {
        let rig = AutocorrectRig("", corrections: [:])
        rig.corrector.following = ["see ": ["you"]]
        rig.tap("see")
        rig.press(.space)
        rig.document.host.hostDelete(3 ..< 4)
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "see")
        TestSupport.expectEqual(rig.strip, nil)
        // The proxy has not shown the space yet: a missed tap, never a wrong one.
        let late = AutocorrectRig("", corrections: [:])
        late.corrector.following = ["see ": ["you"]]
        late.tap("see")
        late.press(.space)
        late.document.lateBefore = .some("see")
        late.choose(0)
        TestSupport.expectEqual(late.text, "see ")
        // A long field: the editor's copy is bounded, the proxy's window longer; the tap applies.
        let long = String(repeating: "word ", count: 80) + "end"
        let windowed = AutocorrectRig(long, corrections: [:])
        windowed.corrector.followingAny = ["now"]
        windowed.press(.space)
        TestSupport.expectEqual(windowed.strip, plain(["now"]))
        windowed.choose(0)
        TestSupport.expectEqual(windowed.text, long + " now ")
    }

    private static func testDictationWinsTheBar() {
        // The bar's precedence is unchanged: predictions are candidates, and dictation, notices and Undo win.
        let rig = AutocorrectRig("", corrections: [:])
        rig.corrector.following = ["see ": ["you"]]
        rig.tap("see")
        rig.press(.space)
        TestSupport.expect(rig.strip != nil, "no predictions")
        for (inProgress, notice, undo) in [(true, false, false), (false, true, false), (false, false, true)] {
            TestSupport.expectEqual(BarMiddleContent.resolve(neverCorrectOffer: false, candidates: rig.strip != nil,
                                                             dictationInProgress: inProgress, notice: notice,
                                                             dictationUndoShown: undo), .dictation)
        }
        // A dictation's text closes them.
        rig.editor.insertDictation("hello there", now: rig.tick())
        TestSupport.expectEqual(rig.strip, nil)
    }
}

/// The word being typed across hiding (ARCHITECTURE.md, "Word autocorrect", Owned words): the word this keyboard was
/// typing is kept in memory when it hides, and is its own again only where it can tell it is the same place: the same
/// identified field, the text around the caret as it was, nothing selected. Anything else drops it. Every text is
/// invented.
enum ParkedWordTests {
    static var tests: [TestCase] {
        [
            ("theWordComesBackInTheSameField", testTheWordComesBackInTheSameField),
            ("aNewIdentifierForTheSameTextKeepsIt", testANewIdentifierForTheSameTextKeepsIt),
            ("anUnchangedCallbackAfterAppearingKeepsIt", testAnUnchangedCallbackAfterAppearingKeepsIt),
            ("anotherFieldDropsIt", testAnotherFieldDropsIt),
            ("changedTextDropsIt", testChangedTextDropsIt),
            ("aFieldWithoutIdentityNeverKeepsIt", testAFieldWithoutIdentityNeverKeepsIt),
            ("aSelectionDropsIt", testASelectionDropsIt),
            ("onlyTheKeyboardsOwnWordIsKept", testOnlyTheKeyboardsOwnWordIsKept),
            ("aLateProxyStillFindsIt", testALateProxyStillFindsIt),
            ("theNextKeyboardInTheProcessTakesItBack", testTheNextKeyboardInTheProcessTakesItBack),
            ("callbacksWhileHiddenLeaveIt", testCallbacksWhileHiddenLeaveIt),
            ("theStripComesWithTheModel", testTheStripComesWithTheModel),
        ]
    }

    static let accom = ["accom": WordPredictions(words: ["accommodate", "accomplished"], isWord: false),
                        "accomm": WordPredictions(words: ["accommodate", "accommodation"], isWord: false)]

    /// "see " typed, then "accom", with the strip showing. Only "see" has been to the corrector.
    static func typing(_ documentID: UUID? = UUID()) -> AutocorrectRig {
        let rig = AutocorrectRig("", corrections: [:], documentID: documentID)
        rig.corrector.predicted = accom
        rig.tap("see")
        rig.press(.space)
        rig.tap("accom")
        return rig
    }

    private static func testTheWordComesBackInTheSameField() {
        let rig = typing()
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accomplished"]))
        rig.hide()
        TestSupport.expectEqual(rig.strip, nil)
        rig.show()
        // Back in the same field, unchanged: the strip shows again, and typing goes on with the same word.
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accomplished"]))
        rig.tap("m")
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accommodation"]))
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "see accommodate ")
        // A commit key corrects it; the letters typed before hiding carry no point (the keys may have moved).
        let corrected = typing()
        corrected.corrector.corrections = ["accomm": "accommodate"]
        corrected.hide()
        corrected.show()
        corrected.tap("m", from: 40)
        corrected.press(.space)
        TestSupport.expectEqual(corrected.text, "see accommodate ")
        TestSupport.expectEqual(corrected.corrector.calls.last?.word, "accomm")
        TestSupport.expectEqual(corrected.corrector.calls.last?.points.map { $0 == nil }, [true, true, true, true, true, false])
        // Once only: kept until the keyboard appears again and then a key acts, never longer.
        let once = typing()
        once.hide()
        once.show()
        once.press(.space)
        once.hide()
        once.show()
        TestSupport.expectEqual(once.strip, nil)
    }

    /// After an app switch Messages and Reminders hand the keyboard the same field under a new identifier: the text around
    /// the caret, unchanged, is what tells it is the same place.
    private static func testANewIdentifierForTheSameTextKeepsIt() {
        let rig = typing()
        rig.hide()
        rig.document.switchField(to: rig.document.host, id: UUID())
        rig.show()
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accomplished"]))
        rig.tap("m")
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accommodation"]))
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "see accommodate ")
    }

    /// Sol review (round 5, lead run 1), and seen in Messages: after appearing the host reports the field unchanged, a
    /// callback the editor cannot tell from an outside edit; the word stays its own. A callback that moves the caret
    /// drops it for good.
    private static func testAnUnchangedCallbackAfterAppearingKeepsIt() {
        let rig = typing()
        rig.hide()
        rig.document.switchField(to: rig.document.host, id: UUID())
        rig.show()
        rig.document.moveCaret(to: 9)
        rig.pump()
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accomplished"]))
        rig.tap("m")
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accommodation"]))
        let moved = typing()
        moved.hide()
        moved.show()
        moved.document.moveCaret(to: 3)
        moved.pump()
        TestSupport.expectEqual(moved.strip, nil)
        moved.document.moveCaret(to: 9)
        moved.pump()
        TestSupport.expectEqual(moved.strip, nil)
    }

    private static func testAnotherFieldDropsIt() {
        let rig = typing()
        let original = rig.document.host
        let id = rig.document.documentID
        rig.hide()
        rig.document.switchField(to: FakeTextHost(text: "elsewhere"), id: UUID())
        rig.show()
        TestSupport.expectEqual(rig.strip, nil)
        // Dropped for good: coming back to the first field later does not bring it back.
        rig.hide()
        rig.document.switchField(to: original, id: id)
        rig.show()
        TestSupport.expectEqual(rig.strip, nil)
        rig.tap("m")
        TestSupport.expectEqual(rig.strip, nil)
        rig.press(.space)
        TestSupport.expect(!rig.corrector.calls.contains { $0.word.hasPrefix("accom") }, "the word was corrected")
    }

    private static func testChangedTextDropsIt() {
        // Text added before or after the caret while hidden.
        for change in [{ (rig: AutocorrectRig) in rig.document.host.hostInsert("Hi ", at: 0) },
                       { (rig: AutocorrectRig) in rig.document.host.hostInsert(" there", at: rig.text.utf16.count) }] {
            let rig = typing()
            rig.hide()
            change(rig)
            rig.show()
            TestSupport.expectEqual(rig.strip, nil)
            rig.tap("m")
            rig.press(.space)
            TestSupport.expect(!rig.corrector.calls.contains { $0.word.hasPrefix("accom") }, "the word was corrected")
        }
        // The word itself changed (the same length, another word).
        let rig = typing()
        rig.hide()
        rig.document.host.hostDelete(4 ..< 9)
        rig.document.host.hostInsert("acorn", at: 4)
        rig.show()
        TestSupport.expectEqual(rig.text, "see acorn")
        TestSupport.expectEqual(rig.strip, nil)
    }

    private static func testAFieldWithoutIdentityNeverKeepsIt() {
        // No identity when it hides: nothing is kept.
        let unidentified = typing(nil)
        TestSupport.expect(unidentified.strip != nil, "no strip while typing")
        unidentified.hide()
        unidentified.show()
        TestSupport.expectEqual(unidentified.strip, nil)
        // No identity when it appears: not the same place, so not its own again.
        let lost = typing()
        lost.hide()
        lost.document.documentID = nil
        lost.show()
        TestSupport.expectEqual(lost.strip, nil)
        lost.tap("m")
        lost.press(.space)
        TestSupport.expect(!lost.corrector.calls.contains { $0.word.hasPrefix("accom") }, "the word was corrected")
    }

    private static func testASelectionDropsIt() {
        let rig = typing()
        rig.hide()
        rig.document.host.select(from: 0, length: 3)
        rig.show()
        TestSupport.expectEqual(rig.strip, nil)
    }

    private static func testOnlyTheKeyboardsOwnWordIsKept() {
        // A word the keyboard did not type is never adopted, before or after hiding.
        let rig = AutocorrectRig("see accom", corrections: ["accom": "accommodate"])
        rig.corrector.predicted = accom
        rig.hide()
        rig.show()
        TestSupport.expectEqual(rig.strip, nil)
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "see accom ")
        TestSupport.expectEqual(rig.corrector.calls.count, 0)
        // Nor a word the keyboard stopped owning (a caret move) before it hid.
        let moved = typing()
        moved.document.moveCaret(to: 5)
        moved.pump()
        moved.document.moveCaret(to: 9)
        moved.pump()
        moved.hide()
        moved.show()
        TestSupport.expectEqual(moved.strip, nil)
    }

    private static func testALateProxyStillFindsIt() {
        // The field's identity reaches the proxy only with its first callback after the keyboard appears: the word
        // comes back then, if nothing else has happened.
        let rig = typing()
        let id = rig.document.documentID
        rig.hide()
        rig.document.documentID = nil
        rig.show()
        TestSupport.expectEqual(rig.strip, nil)
        rig.document.documentID = id
        rig.document.moveCaret(to: 9)
        rig.pump()
        TestSupport.expectEqual(rig.strip, TypingSuggestionsTests.live(["accommodate", "accomplished"]))
    }

    private static func testTheNextKeyboardInTheProcessTakesItBack() {
        // iOS makes a new view controller when the keyboard comes back after an app switch: the editors of one process
        // share the slot, so the next one takes the word back (in the same field, unchanged).
        let first = typing()
        first.hide()
        let next = AutocorrectRig(document: first.document, corrections: ["accomm": "accommodate"], parking: first.editor.parking)
        next.corrector.predicted = accom
        next.tap("m")
        TestSupport.expectEqual(next.strip, TypingSuggestionsTests.live(["accommodate", "accommodation"]))
        next.press(.space)
        TestSupport.expectEqual(next.text, "see accommodate ")
        // Another slot (another process): nothing comes back.
        let other = typing()
        other.hide()
        let restarted = AutocorrectRig(document: other.document, corrections: ["accomm": "accommodate"])
        restarted.corrector.predicted = accom
        restarted.tap("m")
        TestSupport.expectEqual(restarted.strip, nil)
        restarted.press(.space)
        TestSupport.expectEqual(restarted.text, "see accomm ")
    }

    /// Sol review (round 5, run 1): a callback that reaches the hidden editor late never takes the word, so the next
    /// editor still finds it.
    private static func testCallbacksWhileHiddenLeaveIt() {
        let first = typing()
        first.hide()
        first.document.moveCaret(to: 9)
        first.pump()
        let next = AutocorrectRig(document: first.document, corrections: [:], parking: first.editor.parking)
        next.corrector.predicted = accom
        next.tap("m")
        TestSupport.expectEqual(next.strip, TypingSuggestionsTests.live(["accommodate", "accommodation"]))
    }

    /// Sol review (round 5, run 1): the next controller loads autocorrect's model after it appears; the word it took
    /// back gets its strip when the model is there, without another key.
    private static func testTheStripComesWithTheModel() {
        let first = typing()
        first.hide()
        let next = AutocorrectRig(document: first.document, corrections: [:], parking: first.editor.parking)
        next.corrector.predicted = accom
        TestSupport.expectEqual(next.strip, nil)
        next.editor.autocorrectChanged()
        TestSupport.expectEqual(next.strip, TypingSuggestionsTests.live(["accommodate", "accomplished"]))
    }
}
