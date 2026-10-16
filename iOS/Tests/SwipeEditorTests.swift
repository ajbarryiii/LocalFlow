import Foundation

/// Swipe typing in the editor (ARCHITECTURE.md, "Typing model v4 and swipe typing": "Inserting a swiped
/// word" and "Candidate strip"): the best candidate goes in with its leading space and casing, the strip
/// offers up to three, a tap replaces the word only while the field still ends with it, the strip closes
/// on anything else, and the first deletion while it shows removes the whole word. Invented words only.
enum SwipeEditorTests {
    static var tests: [TestCase] {
        [
            ("insertsTheBestCandidateAfterASpace", testInsertsTheBestCandidateAfterASpace),
            ("noSpaceAtTheStartOrAfterWhitespaceOrOpeners", testNoSpaceAtTheStartOrAfterWhitespaceOrOpeners),
            ("eachSwipeAddsItsOwnSpace", testEachSwipeAddsItsOwnSpace),
            ("noCandidateDoesNothing", testNoCandidateDoesNothing),
            ("automaticShiftCapitalizesAndIsConsumed", testAutomaticShiftCapitalizesAndIsConsumed),
            ("oneShotShiftCapitalizesTheFirstLetterOnly", testOneShotShiftCapitalizesTheFirstLetterOnly),
            ("capsLockUppercasesAndStays", testCapsLockUppercasesAndStays),
            ("caseOnlyRises", testCaseOnlyRises),
            ("automaticShiftCountsTheInsertedSpace", testAutomaticShiftCountsTheInsertedSpace),
            ("userShiftTakesPrecedenceOverTheInsertedSpace", testUserShiftTakesPrecedenceOverTheInsertedSpace),
            ("allCharactersUppercasesTheWholeWord", testAllCharactersUppercasesTheWholeWord),
            ("wordsCapitalizesEveryWord", testWordsCapitalizesEveryWord),
            ("refusedInAnotherIdentifiedField", testRefusedInAnotherIdentifiedField),
            ("stripShowsUpToThreeInsertedFirst", testStripShowsUpToThreeInsertedFirst),
            ("tapReplacesTheInsertedWord", testTapReplacesTheInsertedWord),
            ("tapAfterAnOutsideEditDoesNothing", testTapAfterAnOutsideEditDoesNothing),
            ("tapWhenTheTextNoLongerEndsWithTheWordDoesNothing", testTapWhenTheTextNoLongerEndsWithTheWordDoesNothing),
            ("tapAfterAFieldChangeDoesNothing", testTapAfterAFieldChangeDoesNothing),
            ("reportsOfOurOwnEditsKeepTheStrip", testReportsOfOurOwnEditsKeepTheStrip),
            ("stripClosesOnAnyOtherKey", testStripClosesOnAnyOtherKey),
            ("stripClosesOnDictationTrackpadFieldChangeAndHiding", testStripClosesOnDictationTrackpadFieldChangeAndHiding),
            ("stripClosesOnAnOutsideTextChange", testStripClosesOnAnOutsideTextChange),
            ("typingWithoutAStripNeverNotifiesTheStrip", testTypingWithoutAStripNeverNotifiesTheStrip),
            ("firstDeletionRemovesTheWholeWord", testFirstDeletionRemovesTheWholeWord),
            ("heldDeleteRemovesTheWordThenRepeatsAsUsual", testHeldDeleteRemovesTheWordThenRepeatsAsUsual),
            ("deleteRemovesAReplacedWordWhole", testDeleteRemovesAReplacedWordWhole),
            ("deleteAfterTheStripClosedDeletesOneCharacter", testDeleteAfterTheStripClosedDeletesOneCharacter),
            ("deleteWhenTheTextNoLongerEndsWithTheWordDeletesOneCharacter", testDeleteWhenTheTextNoLongerEndsWithTheWordDeletesOneCharacter),
            ("manifestReadsTheDecodeSettings", testManifestReadsTheDecodeSettings),
            ("engineRunsThePipeline", testEngineRunsThePipeline),
            ("engineFindsNothingWithoutAUsableSwipe", testEngineFindsNothingWithoutAUsableSwipe),
            ("loadingAnIncompleteBundleFails", testLoadingAnIncompleteBundleFails),
        ]
    }

    // MARK: Inserting a swiped word

    private static func testInsertsTheBestCandidateAfterASpace() {
        let rig = SwipeRig("Hello")
        rig.swipe(["world", "word", "would"])
        TestSupport.expectEqual(rig.text, "Hello world")
        // No space after the word.
        TestSupport.expectEqual(rig.document.host.caret, "Hello world".utf16.count)
        // After punctuation that is not an opener, the space still goes in.
        for (before, expected) in [("Done.", "Done. word"), ("one,", "one, word"), ("x)", "x) word"), ("ok!", "ok! word")] {
            let other = SwipeRig(before)
            other.swipe(["word"])
            TestSupport.expectEqual(other.text, expected)
        }
    }

    private static func testNoSpaceAtTheStartOrAfterWhitespaceOrOpeners() {
        let empty = SwipeRig("")
        empty.swipe(["word"])
        TestSupport.expectEqual(empty.text, "word")
        for before in ["a ", "a\n", "a\t", "(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "/", "-", "@", "#"] {
            let rig = SwipeRig(before)
            rig.swipe(["word"])
            TestSupport.expectEqual(rig.text, before + "word")
        }
        // In the middle of a field, only the text before the caret counts.
        let middle = SwipeRig("ab cd", caret: 3)
        middle.swipe(["word"])
        TestSupport.expectEqual(middle.text, "ab wordcd")
    }

    private static func testEachSwipeAddsItsOwnSpace() {
        let rig = SwipeRig("")
        rig.swipe(["one"])
        rig.swipe(["two"])
        rig.swipe(["three"])
        TestSupport.expectEqual(rig.text, "one two three")
    }

    private static func testNoCandidateDoesNothing() {
        let rig = SwipeRig("Hi", autocapitalization: .sentences)
        rig.swipe([])
        TestSupport.expectEqual(rig.text, "Hi")
        TestSupport.expect(rig.editor.swipeStrip == nil, "a strip without candidates")
        TestSupport.expectEqual(rig.stripChanges, 0)
        // A strip already showing stays, and its word can still be replaced.
        rig.swipe(["there", "these"])
        rig.swipe([])
        TestSupport.expectEqual(rig.editor.swipeStrip?.candidates ?? [], ["there", "these"])
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "Hi these")
    }

    private static func testAutomaticShiftCapitalizesAndIsConsumed() {
        let rig = SwipeRig("", autocapitalization: .sentences)
        TestSupport.expectEqual(rig.editor.typing.shift, .once)
        rig.swipe(["hello", "help", "jello"])
        TestSupport.expectEqual(rig.text, "Hello")
        TestSupport.expectEqual(rig.editor.swipeStrip?.candidates ?? [], ["Hello", "Help", "Jello"])
        TestSupport.expectEqual(rig.editor.typing.shift, .off)
        rig.swipe(["world"])
        TestSupport.expectEqual(rig.text, "Hello world")
        // After a sentence end and a space the automatic shift is back.
        rig.press(.character("."))
        rig.press(.space)
        TestSupport.expectEqual(rig.editor.typing.shift, .once)
        rig.swipe(["again"])
        TestSupport.expectEqual(rig.text, "Hello world. Again")
    }

    private static func testOneShotShiftCapitalizesTheFirstLetterOnly() {
        let rig = SwipeRig("say")
        rig.press(.shift)
        TestSupport.expectEqual(rig.editor.typing.shift, .once)
        rig.swipe(["word", "ward", "wired"])
        TestSupport.expectEqual(rig.text, "say Word")
        TestSupport.expectEqual(rig.editor.swipeStrip?.candidates ?? [], ["Word", "Ward", "Wired"])
        // Consumed, as a typed letter would be.
        TestSupport.expectEqual(rig.editor.typing.shift, .off)
        rig.swipe(["next"])
        TestSupport.expectEqual(rig.text, "say Word next")
    }

    private static func testCapsLockUppercasesAndStays() {
        let rig = SwipeRig("")
        rig.press(.shift)
        rig.press(.shift)
        TestSupport.expectEqual(rig.editor.typing.shift, .capsLock)
        rig.swipe(["loud", "lewd"])
        TestSupport.expectEqual(rig.text, "LOUD")
        TestSupport.expectEqual(rig.editor.swipeStrip?.candidates ?? [], ["LOUD", "LEWD"])
        TestSupport.expectEqual(rig.editor.typing.shift, .capsLock)
        rig.swipe(["noise"])
        TestSupport.expectEqual(rig.text, "LOUD NOISE")
    }

    private static func testCaseOnlyRises() {
        // Unshifted: the lexicon's capitals stay.
        let plain = SwipeRig("so")
        plain.swipe(["I", "London", "iPhone"])
        TestSupport.expectEqual(plain.text, "so I")
        TestSupport.expectEqual(plain.editor.swipeStrip?.candidates ?? [], ["I", "London", "iPhone"])
        // A one-shot shift raises only the first letter; nothing is lowered.
        let shifted = SwipeRig("so")
        shifted.press(.shift)
        shifted.swipe(["iPhone", "London", "i"])
        TestSupport.expectEqual(shifted.text, "so IPhone")
        TestSupport.expectEqual(shifted.editor.swipeStrip?.candidates ?? [], ["IPhone", "London", "I"])
    }

    private static func testAutomaticShiftCountsTheInsertedSpace() {
        // The word is cased as a letter typed after the space it brings would be.
        for (before, expected) in [("Done.", "Done. Next"), ("Wow!", "Wow! Next"), ("Really?", "Really? Next"),
                                   ("Done.)", "Done.) Next"), ("one,", "one, next"), ("Done. ", "Done. Next")] {
            let rig = SwipeRig(before, autocapitalization: .sentences)
            rig.swipe(["next", "nest"])
            TestSupport.expectEqual(rig.text, expected)
            TestSupport.expectEqual(rig.editor.swipeStrip?.candidates.first, String(expected.split(separator: " ").last!))
            // Nothing is left over for the next letter.
            TestSupport.expectEqual(rig.editor.typing.shift, .off)
        }
        let strip = SwipeRig("Done.", autocapitalization: .sentences)
        strip.swipe(["next", "nest"])
        TestSupport.expectEqual(strip.editor.swipeStrip?.candidates ?? [], ["Next", "Nest"])
        // The field's type decides: without autocapitalization nothing rises.
        let none = SwipeRig("Done.", autocapitalization: .none)
        none.swipe(["next"])
        TestSupport.expectEqual(none.text, "Done. next")
    }

    private static func testUserShiftTakesPrecedenceOverTheInsertedSpace() {
        // Caps lock and a one-shot shift the user set apply as before.
        let caps = SwipeRig("Done.", autocapitalization: .sentences)
        caps.press(.shift)
        caps.press(.shift)
        caps.swipe(["next"])
        TestSupport.expectEqual(caps.text, "Done. NEXT")
        let once = SwipeRig("one,", autocapitalization: .sentences)
        once.press(.shift)
        once.swipe(["next"])
        TestSupport.expectEqual(once.text, "one, Next")
        // An automatic shift the user turned off stays off.
        let declined = SwipeRig("", autocapitalization: .sentences)
        TestSupport.expectEqual(declined.editor.typing.shift, .once)
        declined.press(.shift)
        TestSupport.expectEqual(declined.editor.typing.shift, .off)
        declined.swipe(["hello"])
        TestSupport.expectEqual(declined.text, "hello")
        let declinedAfterSpace = SwipeRig("Done. ", autocapitalization: .sentences)
        declinedAfterSpace.press(.shift)
        declinedAfterSpace.swipe(["next"])
        TestSupport.expectEqual(declinedAfterSpace.text, "Done. next")
    }

    private static func testAllCharactersUppercasesTheWholeWord() {
        let rig = SwipeRig("", autocapitalization: .allCharacters)
        rig.swipe(["hello", "help"])
        TestSupport.expectEqual(rig.text, "HELLO")
        TestSupport.expectEqual(rig.editor.swipeStrip?.candidates ?? [], ["HELLO", "HELP"])
        rig.swipe(["world"])
        TestSupport.expectEqual(rig.text, "HELLO WORLD")
        // Turned off by the user, it stays off for that word.
        let declined = SwipeRig("", autocapitalization: .allCharacters)
        declined.press(.shift)
        declined.swipe(["quiet"])
        TestSupport.expectEqual(declined.text, "quiet")
    }

    private static func testWordsCapitalizesEveryWord() {
        let rig = SwipeRig("", autocapitalization: .words)
        rig.swipe(["new"])
        rig.swipe(["york"])
        TestSupport.expectEqual(rig.text, "New York")
        // After an opener no space goes in, and no word starts at whitespace.
        let opener = SwipeRig("re-", autocapitalization: .words)
        opener.swipe(["enter"])
        TestSupport.expectEqual(opener.text, "re-enter")
    }

    private static func testRefusedInAnotherIdentifiedField() {
        let rig = SwipeRig("Hi")
        rig.swipe(["there"], field: .some(UUID()))
        TestSupport.expectEqual(rig.text, "Hi")
        TestSupport.expect(rig.editor.swipeStrip == nil, "a strip for a refused word")
        // A swipe with no identity is typed, as keys are.
        rig.swipe(["there"], field: .some(nil))
        TestSupport.expectEqual(rig.text, "Hi there")
    }

    // MARK: Candidate strip

    private static func testStripShowsUpToThreeInsertedFirst() {
        let rig = SwipeRig("")
        rig.swipe(["alpha", "alps", "also", "altar", "atlas"])
        TestSupport.expectEqual(rig.editor.swipeStrip, SwipeStrip(candidates: ["alpha", "alps", "also"], inserted: 0))
        TestSupport.expectEqual(rig.stripChanges, 1)
        let single = SwipeRig("")
        single.swipe(["only"])
        TestSupport.expectEqual(single.editor.swipeStrip, SwipeStrip(candidates: ["only"], inserted: 0))
    }

    private static func testTapReplacesTheInsertedWord() {
        let rig = SwipeRig("x")
        rig.swipe(["word", "ward", "wired"])
        TestSupport.expectEqual(rig.text, "x word")
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "x ward")
        TestSupport.expectEqual(rig.editor.swipeStrip, SwipeStrip(candidates: ["word", "ward", "wired"], inserted: 1))
        rig.choose(2)
        TestSupport.expectEqual(rig.text, "x wired")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "x word")
        // Tapping the word already inserted changes nothing.
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "x word")
        TestSupport.expect(rig.editor.swipeStrip != nil, "the strip closed on the inserted word")
        // Out of range: nothing.
        rig.choose(7)
        TestSupport.expectEqual(rig.text, "x word")
        // The next key types after the replacement, which ended where the word did.
        rig.choose(1)
        rig.press(.character("s"))
        TestSupport.expectEqual(rig.text, "x wards")
    }

    private static func testTapAfterAnOutsideEditDoesNothing() {
        let rig = SwipeRig("x")
        rig.swipe(["word", "ward"])
        rig.document.hostInserts("Q", at: 0)
        rig.pump()
        TestSupport.expect(rig.editor.swipeStrip == nil, "the strip outlived an outside edit")
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "Qx word")
    }

    private static func testTapWhenTheTextNoLongerEndsWithTheWordDoesNothing() {
        // The host moved the caret and has not reported it yet: the text before the caret no longer ends
        // with the word, so the tap does nothing and the strip closes.
        let rig = SwipeRig("x")
        rig.swipe(["word", "ward"])
        rig.document.moveCaret(to: 1)
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "x word")
        TestSupport.expect(rig.editor.swipeStrip == nil, "the strip stayed after a refused tap")
    }

    private static func testTapAfterAFieldChangeDoesNothing() {
        // The proxy already serves another field whose text happens to end with the word.
        let rig = SwipeRig("x")
        rig.swipe(["word", "ward"])
        rig.document.switchField(to: FakeTextHost(text: "my word"), id: UUID())
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "my word")
        TestSupport.expect(rig.editor.swipeStrip == nil, "the strip stayed in another field")
    }

    private static func testReportsOfOurOwnEditsKeepTheStrip() {
        // A host that reports our own edits (WebKit) sends callbacks that are echoes, not outside changes.
        let rig = SwipeRig("x", editCallbackDelay: 1)
        rig.swipe(["word", "ward"])
        rig.pump()
        rig.pump()
        TestSupport.expect(rig.editor.swipeStrip != nil, "an echo of the swipe closed the strip")
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "x ward")
        rig.pump()
        rig.pump()
        TestSupport.expect(rig.editor.swipeStrip != nil, "an echo of the replacement closed the strip")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "x word")
    }

    private static func testStripClosesOnAnyOtherKey() {
        let keys: [KeyAction] = [.character("a"), .space, .returnKey, .shift, .layer(.numbers), .nextKeyboard]
        for key in keys {
            let rig = SwipeRig("x")
            rig.swipe(["word", "ward"])
            rig.press(key)
            TestSupport.expect(rig.editor.swipeStrip == nil, "the strip stayed after \(key)")
            TestSupport.expectEqual(rig.stripChanges, 2)
            let text = rig.text
            rig.choose(1)
            TestSupport.expectEqual(rig.text, text)
        }
        // A key pressed in another field is refused, but still closes the strip.
        let refused = SwipeRig("x")
        refused.swipe(["word"])
        refused.press(.character("a"), field: .some(UUID()))
        TestSupport.expect(refused.editor.swipeStrip == nil, "the strip stayed after a refused key")
        // Touching a key down types nothing yet (v4) and leaves the strip.
        let touched = SwipeRig("x")
        touched.swipe(["word"])
        touched.editor.keyTouchedDown(now: touched.time)
        TestSupport.expect(touched.editor.swipeStrip != nil, "a touch-down closed the strip")
        // A new swipe replaces the strip.
        touched.swipe(["more", "mire"])
        TestSupport.expectEqual(touched.editor.swipeStrip, SwipeStrip(candidates: ["more", "mire"], inserted: 0))
    }

    private static func testStripClosesOnDictationTrackpadFieldChangeAndHiding() {
        let dictation = SwipeRig("x")
        dictation.swipe(["word", "ward"])
        dictation.editor.insertDictation(" dictated", now: dictation.time)
        TestSupport.expect(dictation.editor.swipeStrip == nil, "the strip stayed after a dictation")
        dictation.choose(1)
        TestSupport.expectEqual(dictation.text, "x word dictated")

        let trackpad = SwipeRig("x")
        trackpad.swipe(["word", "ward"])
        trackpad.editor.beginTrackpad(layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
        TestSupport.expect(trackpad.editor.swipeStrip == nil, "the strip stayed in trackpad mode")

        let field = SwipeRig("x")
        field.swipe(["word", "ward"])
        field.document.focus(FakeTextHost(text: "other"), id: UUID())
        field.pump()
        TestSupport.expect(field.editor.swipeStrip == nil, "the strip stayed after a field change")

        let hidden = SwipeRig("x")
        hidden.swipe(["word", "ward"])
        hidden.editor.hide(now: hidden.time)
        TestSupport.expect(hidden.editor.swipeStrip == nil, "the strip outlived hiding")
        hidden.editor.reset(numeric: false)
        hidden.choose(1)
        TestSupport.expectEqual(hidden.text, "x word")

        let closed = SwipeRig("x")
        closed.swipe(["word", "ward"])
        closed.editor.closeSwipeStrip()
        TestSupport.expect(closed.editor.swipeStrip == nil, "closeSwipeStrip left it open")
        closed.choose(1)
        TestSupport.expectEqual(closed.text, "x word")
    }

    private static func testStripClosesOnAnOutsideTextChange() {
        let rig = SwipeRig("x")
        rig.swipe(["word", "ward"])
        // A caret tap reported by selectionDidChange.
        rig.document.moveCaret(to: 0)
        rig.pump()
        TestSupport.expect(rig.editor.swipeStrip == nil, "the strip stayed after a caret tap")
        TestSupport.expectEqual(rig.stripChanges, 2)
    }

    private static func testTypingWithoutAStripNeverNotifiesTheStrip() {
        // The bar re-renders only when the strip changes, never for ordinary typing.
        let rig = SwipeRig("", autocapitalization: .sentences)
        rig.press(.character("h"))
        rig.press(.character("i"))
        rig.press(.space)
        rig.press(.shift)
        rig.press(.returnKey)
        rig.heldDelete()
        rig.editor.insertDictation("text", now: rig.time)
        rig.editor.closeSwipeStrip()
        TestSupport.expectEqual(rig.stripChanges, 0)
    }

    // MARK: Delete after a swipe

    private static func testFirstDeletionRemovesTheWholeWord() {
        let rig = SwipeRig("Hi")
        rig.swipe(["there", "these"])
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "Hi ")
        TestSupport.expect(rig.editor.swipeStrip == nil, "the strip stayed after the deletion")
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "Hi")
        // VoiceOver's delete key acts the same way.
        let voiceOver = SwipeRig("Hi")
        voiceOver.swipe(["there"])
        voiceOver.press(.delete)
        TestSupport.expectEqual(voiceOver.text, "Hi ")
        voiceOver.press(.delete)
        TestSupport.expectEqual(voiceOver.text, "Hi")
        // At the start of a field nothing precedes the word.
        let start = SwipeRig("")
        start.swipe(["word"])
        start.heldDelete()
        TestSupport.expectEqual(start.text, "")
    }

    private static func testHeldDeleteRemovesTheWordThenRepeatsAsUsual() {
        // A held delete's first deletion takes the word; the repeats that follow are the usual ones.
        let rig = SwipeRig("one two")
        rig.swipe(["three"])
        rig.heldDelete(.character)
        TestSupport.expectEqual(rig.text, "one two ")
        rig.heldDelete(.character)
        TestSupport.expectEqual(rig.text, "one two")
        rig.heldDelete(.character)
        TestSupport.expectEqual(rig.text, "one tw")
        // Word deletion (with the spaces before the word) is unchanged.
        rig.heldDelete(.words(1))
        TestSupport.expectEqual(rig.text, "one")
    }

    private static func testDeleteRemovesAReplacedWordWhole() {
        let rig = SwipeRig("a")
        rig.swipe(["cat", "chart"])
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "a chart")
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "a ")
    }

    private static func testDeleteAfterTheStripClosedDeletesOneCharacter() {
        let rig = SwipeRig("a")
        rig.swipe(["cat"])
        rig.press(.character("s"))
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "a cat")
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "a ca")
    }

    private static func testDeleteWhenTheTextNoLongerEndsWithTheWordDeletesOneCharacter() {
        // The host moved the caret without a report yet: the deletion is an ordinary one.
        let rig = SwipeRig("ab")
        rig.swipe(["cat"])
        rig.document.moveCaret(to: 2)
        rig.heldDelete()
        TestSupport.expectEqual(rig.text, "a cat")
        TestSupport.expect(rig.editor.swipeStrip == nil, "the strip stayed after the deletion")
    }

    // MARK: Swipe engine (the pipeline around the encoder; Core ML itself is faked)

    private static func manifest(format: Int = 1, beam: Int = 4, decode: Bool = true) -> Data {
        let settings = #""decode": {"beam": \#(beam), "freq_weight": 0.01, "length_bonus": 0.25, "length_power": 0.5, "top_k": 3}, "#
        return Data(#"{"files": {"lexicon.bin": "00"}, \#(decode ? settings : "")"format": \#(format)}"#.utf8)
    }

    private static func testManifestReadsTheDecodeSettings() {
        TestSupport.expectEqual(try? SwipeBundleManifest.decodeConfig(from: manifest()),
                                SwipeDecodeConfig(beam: 4, topK: 3, lengthPower: 0.5, freqWeight: 0.01, lengthBonus: 0.25))
        func error(_ data: Data) -> Error? {
            do {
                _ = try SwipeBundleManifest.decodeConfig(from: data)
                return nil
            } catch {
                return error
            }
        }
        TestSupport.expectEqual(error(manifest(format: 2)) as? SwipeEngineError, .unsupportedFormat)
        TestSupport.expectEqual(error(manifest(beam: 0)) as? SwipeEngineError, .invalidSettings)
        TestSupport.expect(error(manifest(decode: false)) != nil, "a manifest without decode settings was accepted")
        TestSupport.expect(error(Data("not json".utf8)) != nil, "a manifest that is not JSON was accepted")
    }

    private static var letterKeys: [PlacedKey] {
        KeyboardLayout.keys(for: .letters, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                            showsGlobe: false)
    }

    private static func fixtureEngine(_ encoder: FakeSwipeEncoder) -> (SwipeEngine, SwipeLexicon, SwipeDecodeConfig) {
        let lexicon = try! SwipeLexicon(data: Data(base64Encoded: SwipeFixtures.lexiconBase64)!)
        let fixture = SwipeFixtures.decode[0]
        let config = SwipeDecodeConfig(beam: fixture.beam, topK: fixture.topK, lengthPower: fixture.lengthPower,
                                       freqWeight: fixture.freqWeight, lengthBonus: fixture.lengthBonus)
        return (SwipeEngine(encoder: encoder, lexicon: lexicon, config: config), lexicon, config)
    }

    private static func testEngineRunsThePipeline() {
        let fixture = SwipeFixtures.decode[0]
        let encoder = FakeSwipeEncoder(output: fixture.logProbs)
        let (engine, lexicon, config) = fixtureEngine(encoder)
        // Invented samples in key-area points, timestamps in seconds.
        let samples = [SwipeSample(x: 30, y: 30, t: 10.000), SwipeSample(x: 120, y: 80, t: 10.040),
                       SwipeSample(x: 200, y: 60, t: 10.090), SwipeSample(x: 260, y: 140, t: 10.160)]
        let candidates = engine.candidates(for: samples, keys: letterKeys)

        // The encoder sees the samples in the frame, resampled from millisecond timestamps, and the a–z
        // centers in the same frame, as Float32.
        let frame = SwipeFrame(keys: letterKeys)!
        let points = samples.map { frame.normalize(x: $0.x, y: $0.y) }
        let trajectory = SwipeResampler.resample(t: samples.map { $0.t * 1000 }, x: points.map(\.x), y: points.map(\.y))
        TestSupport.expectEqual(encoder.calls.count, 1)
        TestSupport.expectEqual(encoder.calls.first?.trajectory ?? [], trajectory.map { Float($0) })
        TestSupport.expectEqual(encoder.calls.first?.keys ?? [], frame.letterCenters.map { Float($0) })
        TestSupport.expectEqual(encoder.calls.first?.trajectory.count, SwipeResampler.points * 2)
        TestSupport.expectEqual(encoder.calls.first?.keys.count, 52)
        // The decoder runs on the encoder's output with the bundle's settings.
        let expected = SwipeDecoder.decode(logProbs: fixture.logProbs, frames: SwipeFixtures.frames, lexicon: lexicon,
                                           config: config)
        TestSupport.expect(!expected.isEmpty, "the fixture decodes to nothing")
        TestSupport.expectEqual(candidates, expected)
        TestSupport.expectEqual(candidates.map(\.word), fixture.words)
    }

    private static func testEngineFindsNothingWithoutAUsableSwipe() {
        let sample = [SwipeSample(x: 30, y: 30, t: 1), SwipeSample(x: 90, y: 40, t: 1.1)]
        let encoder = FakeSwipeEncoder(output: SwipeFixtures.decode[0].logProbs)
        let (engine, _, _) = fixtureEngine(encoder)
        TestSupport.expect(engine.candidates(for: [], keys: letterKeys).isEmpty, "candidates without samples")
        let numbers = KeyboardLayout.keys(for: .numbers, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                                          showsGlobe: false)
        TestSupport.expect(engine.candidates(for: sample, keys: numbers).isEmpty, "candidates without letter keys")
        TestSupport.expectEqual(encoder.calls.count, 0)
        // A failing encoder, or one whose output is not whole frames, finds nothing (and never traps).
        encoder.fails = true
        TestSupport.expect(engine.candidates(for: sample, keys: letterKeys).isEmpty, "candidates from a failed encoder")
        encoder.fails = false
        encoder.output = [0, 0, 0]
        TestSupport.expect(engine.candidates(for: sample, keys: letterKeys).isEmpty, "candidates from a ragged output")
        encoder.output = []
        TestSupport.expect(engine.candidates(for: sample, keys: letterKeys).isEmpty, "candidates from an empty output")
    }

    private static func testLoadingAnIncompleteBundleFails() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        TestSupport.expect((try? SwipeEngine.load(from: directory)) == nil, "an empty bundle loaded")
        try! manifest().write(to: directory.appendingPathComponent("bundle.json"))
        TestSupport.expect((try? SwipeEngine.load(from: directory)) == nil, "a bundle without a lexicon loaded")
        try! Data("not a lexicon".utf8).write(to: directory.appendingPathComponent("lexicon.bin"))
        TestSupport.expect((try? SwipeEngine.load(from: directory)) == nil, "a bundle with an invalid lexicon loaded")
        try! Data(base64Encoded: SwipeFixtures.lexiconBase64)!.write(to: directory.appendingPathComponent("lexicon.bin"))
        TestSupport.expect((try? SwipeEngine.load(from: directory)) == nil, "a bundle without a model loaded")
    }
}

/// An encoder that records its inputs and answers with fixed log-probabilities.
private final class FakeSwipeEncoder: SwipeEncoding {
    struct Failure: Error {}
    var output: [Double]
    var fails = false
    private(set) var calls: [(trajectory: [Float], keys: [Float])] = []

    init(output: [Double]) {
        self.output = output
    }

    func logProbs(trajectory: [Float], keys: [Float]) throws -> [Double] {
        calls.append((trajectory, keys))
        if fails { throw Failure() }
        return output
    }
}

/// The editor with a fake document, driven as `KeyboardInput` drives it: swipes arrive decoded, keys and
/// deletions in the field current when they were pressed, and host callbacks between turns.
private final class SwipeRig {
    let document: FakeDocument
    let editor: KeyboardEditor
    private(set) var time: TimeInterval = 100
    var autocapitalization: AutocapitalizationMode
    /// How many times the strip was reported changed.
    private(set) var stripChanges = 0

    init(_ text: String, caret: Int? = nil, autocapitalization: AutocapitalizationMode = .none,
         editCallbackDelay: Int? = nil) {
        document = FakeDocument(FakeTextHost(text: text, caret: caret))
        document.editCallbackDelay = editCallbackDelay
        let trackpad = TrackpadController(host: document)
        trackpad.parameters = .flat
        editor = KeyboardEditor(document: document, trackpad: trackpad)
        self.autocapitalization = autocapitalization
        editor.autocapitalization = { [unowned self] in self.autocapitalization }
        editor.reset(numeric: false)
        editor.onSwipeStripChanged = { [unowned self] in self.stripChanges += 1 }
    }

    var text: String { document.text }

    private func tick() { time += 0.05 }

    /// A swipe decoded to these words, best first, pressed in `field` (the current one unless given).
    func swipe(_ words: [String], field: UUID?? = .none) {
        tick()
        let candidates = words.enumerated().map { SwipeCandidate(word: $1, score: -Double($0)) }
        editor.insertSwipe(candidates, field: field ?? document.documentID, now: time)
    }

    func choose(_ index: Int) {
        tick()
        editor.chooseSwipeCandidate(at: index, now: time)
    }

    func press(_ action: KeyAction, field: UUID?? = .none) {
        tick()
        editor.press(action, field: field ?? document.documentID, at: time, now: time)
    }

    func heldDelete(_ unit: DeleteRepeat.Unit = .character) {
        tick()
        editor.heldDelete(unit, field: document.documentID, now: time)
    }

    /// One run-loop turn: due host events reach the editor.
    func pump() {
        tick()
        document.pump(editor, at: time)
    }
}
