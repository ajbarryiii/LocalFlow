import Foundation

/// Suggestions while typing (ARCHITECTURE.md, "Word autocorrect", Suggestions): the corrector's predictions for
/// the word being typed (completions of it ranked by the word model in the sentence's context, and typo-tolerant
/// matches), the strip they make in the top row, its gates, and a tapped suggestion's one space. Every word, text
/// and model is invented or a tiny fixture.
enum TypingSuggestionsTests {
    static var tests: [TestCase] {
        [
            ("everyFormIsScoredInOneCallPerContext", testEveryFormIsScoredInOneCallPerContext),
            ("aPrefixIsARangeOfForms", testAPrefixIsARangeOfForms),
            ("completionsAreRankedByTheWordModel", testCompletionsAreRankedByTheWordModel),
            ("theContextChangesTheOrder", testTheContextChangesTheOrder),
            ("typoMatchesJoinTheCompletions", testTypoMatchesJoinTheCompletions),
            ("theCorrectionIsWhatACommitKeyWouldDo", testTheCorrectionIsWhatACommitKeyWouldDo),
            ("theWordModelStepsOncePerContext", testTheWordModelStepsOncePerContext),
            ("theStripShowsCompletionsWhileTyping", testTheStripShowsCompletionsWhileTyping),
            ("aPendingCorrectionIsMarkedBesideTheQuotedWord", testAPendingCorrectionIsMarkedBesideTheQuotedWord),
            ("theStripFollowsTheCommitRules", testTheStripFollowsTheCommitRules),
            ("aContractionsApostropheIsPartOfTheWord", testAContractionsApostropheIsPartOfTheWord),
            ("nothingPlausibleShowsNothing", testNothingPlausibleShowsNothing),
            ("suggestionsOnlyWhereAutocorrectRuns", testSuggestionsOnlyWhereAutocorrectRuns),
            ("aTappedSuggestionReplacesTheWordWithOneSpace", testATappedSuggestionReplacesTheWordWithOneSpace),
            ("keepingTheQuotedWordCommitsItAsTyped", testKeepingTheQuotedWordCommitsItAsTyped),
            ("aSpaceAlreadyThereIsNotDoubled", testASpaceAlreadyThereIsNotDoubled),
            ("theStripGoesWithTheWord", testTheStripGoesWithTheWord),
            ("aProxyShowingAnotherWordHidesTheStrip", testAProxyShowingAnotherWordHidesTheStrip),
            ("aChoiceStaysInItsField", testAChoiceStaysInItsField),
            ("aChoiceStaysAtItsCaret", testAChoiceStaysAtItsCaret),
            ("aChosenWordsSpaceReturnsToLetters", testAChosenWordsSpaceReturnsToLetters),
            ("completionsSurviveATypedWordWithNoProbability", testCompletionsSurviveATypedWordWithNoProbability),
            ("theStripReturnsWhenALateProxyCatchesUp", testTheStripReturnsWhenALateProxyCatchesUp),
            ("allCapitalsTypingSuggestsAllCapitals", testAllCapitalsTypingSuggestsAllCapitals),
            ("anInfiniteMarginIsNoPendingCorrection", testAnInfiniteMarginIsNoPendingCorrection),
            ("aSwipeAfterAChoiceKeepsOneRecord", testASwipeAfterAChoiceKeepsOneRecord),
            ("aCommitStripChoiceEndsWithOneSpace", testACommitStripChoiceEndsWithOneSpace),
            ("aSwipeStripChoiceEndsWithOneSpace", testASwipeStripChoiceEndsWithOneSpace),
            ("typingSuggestionsAreCandidatesForTheBar", testTypingSuggestionsAreCandidatesForTheBar),
        ]
    }

    // MARK: The corrector's predictions

    /// A word model that counts its calls; P(word) from a table, one per previous word if given.
    final class CountingModel: WordModel {
        let probs: [String: Double]
        let byPrevious: [String: [String: Double]]
        private(set) var allFormCalls = 0
        private(set) var calls = 0

        init(_ probs: [String: Double], byPrevious: [String: [String: Double]] = [:]) {
            self.probs = probs
            self.byPrevious = byPrevious
        }

        func inVocab(_ word: String) -> Bool { probs[word] != nil }
        func forgetContext() {}

        func logProbs(context: [String], words: [String]) -> [Double] {
            calls += 1
            let table = context.last.flatMap { byPrevious[$0] } ?? probs
            return words.map { log(probs[$0] != nil ? table[$0] ?? 1e-3 : 1e-3) }
        }

        func logProbs(context: [String], allFormsOf lexicon: WordLexicon) -> [Double] {
            allFormCalls += 1
            let table = context.last.flatMap { byPrevious[$0] } ?? probs
            return (0 ..< lexicon.formCount).map { log(table[lexicon.form(at: $0)] ?? 1e-3) }
        }
    }

    static let entries: [(String, Int)] = [
        ("hello", 200), ("help", 180), ("held", 120), ("helmet", 90), ("he", 230), ("her", 220), ("the", 250), ("then", 200),
        ("ten", 150), ("tea", 140), ("cat", 200), ("can't", 210), ("cant", 60), ("car", 190),
    ]
    static let probs: [String: Double] = [
        "hello": 0.05, "help": 0.03, "held": 0.02, "helmet": 0.001, "he": 0.08, "her": 0.06, "the": 0.2, "then": 0.04,
        "ten": 0.01, "tea": 0.005, "cat": 0.02, "can't": 0.03, "cant": 0.0001, "car": 0.02,
    ]

    static func corrector(byPrevious: [String: [String: Double]] = [:]) -> (Autocorrector, CountingModel) {
        let model = CountingModel(probs, byPrevious: byPrevious)
        return (Autocorrector(lexicon: AutocorrectCoreTests.lexicon(entries), model: model, touch: AutocorrectCoreTests.touch), model)
    }

    static func predict(_ corrector: Autocorrector, _ context: String, _ word: String,
                        _ params: AutocorrectParams = .standard) -> WordPredictions {
        corrector.predictions(context: context, word: word, points: AutocorrectCoreTests.centreTaps(word),
                              keys: AutocorrectCoreTests.keys, params: params, limit: SwipeStrip.limit)
    }

    private static func testEveryFormIsScoredInOneCallPerContext() {
        // The default scores every form by name; the LSTM reads them all out of one step, to the same values within
        // rounding.
        let lexicon = AutocorrectCoreTests.fixtureLexicon
        for name in ["unigram", "ngram", "lstm"] {
            let model = AutocorrectCoreTests.fixtureModel(name)
            let forms = (0 ..< lexicon.formCount).map(lexicon.form(at:))
            for context in [[], ["they", "love"], ["zork"]] {
                let all = model.logProbs(context: context, allFormsOf: lexicon)
                let named = model.logProbs(context: context, words: forms)
                TestSupport.expectEqual(all.count, lexicon.formCount)
                // The LSTM's read-out sums in Float32: within its rounding.
                for (a, b) in zip(all, named) { TestSupport.expect(abs(a - b) < 1e-4, "\(name) \(context): \(a) vs \(b)") }
            }
        }
    }

    private static func testAPrefixIsARangeOfForms() {
        let lexicon = AutocorrectCoreTests.lexicon(entries)
        func forms(_ prefix: String) -> [String] { lexicon.formRange(prefix: prefix).map(lexicon.form(at:)) }
        TestSupport.expectEqual(forms("hel"), ["held", "hello", "helmet", "help"])
        TestSupport.expectEqual(forms("he"), ["he", "held", "hello", "helmet", "help", "her"])
        TestSupport.expectEqual(forms("can"), ["can't", "cant"])
        TestSupport.expectEqual(forms("can'"), ["can't"])
        TestSupport.expectEqual(forms("zz"), [])
        TestSupport.expectEqual(lexicon.formRange(prefix: "").count, lexicon.formCount)
    }

    private static func testCompletionsAreRankedByTheWordModel() {
        let (corrector, _) = corrector()
        // From the first letter: the forms starting with it, best first by the word model.
        TestSupport.expectEqual(predict(corrector, "", "h").words, ["he", "her", "hello"])
        TestSupport.expectEqual(predict(corrector, "", "h").isWord, false)
        // A lexicon word's own completions; the word itself is never among them.
        let he = predict(corrector, "", "he")
        TestSupport.expect(he.isWord, "he is a word")
        TestSupport.expectEqual(he.words, ["her", "hello", "help"])
        TestSupport.expectEqual(predict(corrector, "", "hel").words, ["hello", "help", "held"])
        TestSupport.expectEqual(predict(corrector, "", "helm").words, ["helmet"])
    }

    private static func testTheContextChangesTheOrder() {
        let (corrector, _) = corrector(byPrevious: ["please": ["help": 0.3, "hello": 0.01, "held": 0.001]])
        TestSupport.expectEqual(predict(corrector, "", "hel").words, ["hello", "help", "held"])
        TestSupport.expectEqual(predict(corrector, "please ", "hel").words, ["help", "hello", "held"])
    }

    private static func testTypoMatchesJoinTheCompletions() {
        // "teh" starts no form; the corrector's typo-tolerant match "the" comes first.
        let (corrector, _) = corrector()
        let teh = predict(corrector, "", "teh")
        TestSupport.expectEqual(teh.words.first, "the")
        TestSupport.expect(!teh.isWord, "teh is no word")
        // Completions and matches merge: "cat" (typed exactly) is a word, and "car" a near match, after "cat"'s own
        // completions (none).
        let cat = predict(corrector, "", "cat")
        TestSupport.expect(cat.isWord, "cat is a word")
        TestSupport.expect(!cat.words.contains("cat"), "the word itself suggested")
    }

    private static func testTheCorrectionIsWhatACommitKeyWouldDo() {
        let (corrector, _) = corrector()
        for word in ["teh", "hel", "he", "cat", "cnat", "h"] {
            let expected = corrector.correct(context: "", word: word, points: AutocorrectCoreTests.centreTaps(word),
                                             keys: AutocorrectCoreTests.keys, params: .standard)
            TestSupport.expectEqual(predict(corrector, "", word).correction, expected == word ? nil : expected)
        }
        TestSupport.expectEqual(predict(corrector, "", "teh").correction, "the")
        // Known words keep their margin: infinite by default, so "cant" is no pending correction here.
        TestSupport.expectEqual(predict(corrector, "", "cant").correction, nil)
    }

    private static func testTheWordModelStepsOncePerContext() {
        // Typing a word letter by letter scores every form once for its context, not once per letter.
        let (corrector, model) = corrector()
        for prefix in ["h", "he", "hel", "help"] { _ = predict(corrector, "i need ", prefix) }
        TestSupport.expectEqual(model.allFormCalls, 1)
        for prefix in ["t", "th", "the"] { _ = predict(corrector, "i need help ", prefix) }
        TestSupport.expectEqual(model.allFormCalls, 2)
    }

    // MARK: The strip while typing

    static func rig(_ text: String = "", corrections: [String: String] = [:],
                    predictions: [String: WordPredictions]) -> AutocorrectRig {
        let rig = AutocorrectRig(text, corrections: corrections)
        rig.corrector.predicted = predictions
        return rig
    }

    static func live(_ candidates: [String], quoted: Int? = nil, marked: Int? = nil) -> SwipeStrip {
        SwipeStrip(candidates: candidates, inserted: marked ?? 0, live: SwipeStrip.Live(quoted: quoted, marked: marked))
    }

    private static func testTheStripShowsCompletionsWhileTyping() {
        let rig = rig(predictions: [
            "h": WordPredictions(words: ["he", "her", "his"], isWord: false),
            "he": WordPredictions(words: ["hello", "her", "help"], isWord: true),
            "hel": WordPredictions(words: ["hello", "help", "held"], isWord: false),
        ])
        rig.tap("h")
        // Not a word, with better ones: the typed letters are not offered.
        TestSupport.expectEqual(rig.strip, live(["he", "her", "his"]))
        rig.tap("e")
        // A word: first, as typed, then the best others.
        TestSupport.expectEqual(rig.strip, live(["he", "hello", "her"]))
        rig.tap("l")
        TestSupport.expectEqual(rig.strip, live(["hello", "help", "held"]))
        // One prediction per keystroke, with the word so far and its taps.
        TestSupport.expectEqual(rig.corrector.predictionCalls.map(\.word), ["h", "he", "hel"])
        TestSupport.expectEqual(rig.corrector.predictionCalls.last?.points.count, 3)
        // Suggestions take the typed word's case.
        let capital = Self.rig(predictions: ["hel": WordPredictions(words: ["hello", "help"], isWord: false)])
        capital.tap("Hel")
        TestSupport.expectEqual(capital.strip, live(["Hello", "Help"]))
    }

    private static func testAPendingCorrectionIsMarkedBesideTheQuotedWord() {
        let rig = rig(predictions: ["teh": WordPredictions(correction: "the", words: ["the", "ten", "tea"], isWord: false)])
        rig.tap("teh")
        // The word as typed (quoted: a tap keeps it), the correction a space would make (marked), the next best.
        TestSupport.expectEqual(rig.strip, live(["teh", "the", "ten"], quoted: 0, marked: 1))
        let capital = Self.rig(predictions: ["teh": WordPredictions(correction: "the", words: ["ten"], isWord: false)])
        capital.tap("Teh")
        TestSupport.expectEqual(capital.strip, live(["Teh", "The", "Ten"], quoted: 0, marked: 1))
    }

    private static func testTheStripFollowsTheCommitRules() {
        // A chat word is kept: no pending correction, the word first.
        let chat = rig(predictions: ["lol": WordPredictions(correction: "lil", words: ["lil", "lot"], isWord: false)])
        chat.tap("lol")
        TestSupport.expectEqual(chat.strip, live(["lol", "lil", "lot"]))
        // "cant" will become "can't"; a day name will take its capital.
        let cant = rig(predictions: ["cant": WordPredictions(words: ["can't", "canteen"], isWord: true)])
        cant.tap("cant")
        TestSupport.expectEqual(cant.strip, live(["cant", "can't", "canteen"], quoted: 0, marked: 1))
        let friday = rig(predictions: ["friday": WordPredictions(words: ["fridays"], isWord: true)])
        friday.tap("friday")
        TestSupport.expectEqual(friday.strip, live(["friday", "Friday", "fridays"], quoted: 0, marked: 1))
        // A word reverted in this session is no pending correction either.
        let reverted = rig("so", corrections: ["teh": "the"], predictions: ["teh": WordPredictions(correction: "the", words: ["the"],
                                                                                                    isWord: false)])
        reverted.press(.space)
        reverted.tap("teh")
        reverted.press(.space)
        reverted.heldDelete()
        reverted.press(.space)
        reverted.tap("teh")
        TestSupport.expectEqual(reverted.strip, live(["teh", "the"]))
    }

    /// Sol round 2, run 4: an apostrophe typed at the end of a word so far is the middle of a contraction, not a
    /// closing quote: the completions start with it and never get a second one.
    private static func testAContractionsApostropheIsPartOfTheWord() {
        let rig = rig(predictions: ["don'": WordPredictions(words: ["don't"], isWord: false)])
        rig.tap("Don'")
        TestSupport.expectEqual(rig.corrector.predictionCalls.last?.word, "don'")
        TestSupport.expectEqual(rig.strip, live(["Don't"]))
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "Don't ")
        // A curly apostrophe is the corrector's "'".
        let curly = Self.rig(predictions: ["don'": WordPredictions(words: ["don't"], isWord: false)])
        curly.tap("don\u{2019}")
        TestSupport.expectEqual(curly.strip, live(["don't"]))
    }

    private static func testNothingPlausibleShowsNothing() {
        let rig = rig(predictions: ["zq": WordPredictions(words: [], isWord: false), "ok": WordPredictions(words: [], isWord: true)])
        var changes = 0
        rig.editor.onSwipeStripChanged = { changes += 1 }
        rig.tap("zq")
        TestSupport.expectEqual(rig.strip, nil)
        rig.press(.space)
        rig.tap("ok")
        TestSupport.expectEqual(rig.strip, nil)
        TestSupport.expectEqual(changes, 0)
    }

    private static func testSuggestionsOnlyWhereAutocorrectRuns() {
        let predictions = ["hel": WordPredictions(words: ["hello"], isWord: false), "zhel": WordPredictions(words: ["hello"], isWord: false)]
        func shows(_ configure: (AutocorrectRig) -> Void, text: String = "") -> Bool {
            let rig = rig(text, predictions: predictions)
            configure(rig)
            rig.tap("hel")
            let shown = rig.strip != nil
            if !shown { TestSupport.expectEqual(rig.corrector.predictionCalls.count, 0) }
            return shown
        }
        TestSupport.expect(shows { _ in }, "no strip where autocorrect runs")
        TestSupport.expect(!shows { $0.enabled = false }, "strip with autocorrect off")
        TestSupport.expect(!shows { $0.secure = true }, "strip in a secure field")
        TestSupport.expect(!shows { $0.autocorrectionDisabled = true }, "strip where autocorrection is off")
        TestSupport.expect(!shows { $0.field = .url }, "strip in a URL field")
        TestSupport.expect(!shows { $0.field = .email }, "strip in an email field")
        // A word the keyboard did not type from its start.
        TestSupport.expect(!shows({ _ in }, text: "z"), "strip for a word the keyboard does not own")
    }

    private static func testATappedSuggestionReplacesTheWordWithOneSpace() {
        let rig = rig("well", predictions: ["hel": WordPredictions(words: ["hello", "help", "held"], isWord: false)])
        rig.press(.space)
        rig.tap("hel")
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "well help ")
        TestSupport.expectEqual(rig.document.host.caret, "well help ".utf16.count)
        TestSupport.expectEqual(rig.strip, nil)
        // The next word is the keyboard's own again: its letters are predicted, and a commit key reviews it.
        rig.corrector.predicted["m"] = WordPredictions(words: ["me", "my"], isWord: false)
        rig.tap("m")
        TestSupport.expectEqual(rig.strip, live(["me", "my"]))
        // A pending correction tapped is the correction; the case follows the typed word.
        let pending = Self.rig(predictions: ["teh": WordPredictions(correction: "the", words: ["ten"], isWord: false)])
        pending.tap("Teh")
        pending.choose(1)
        TestSupport.expectEqual(pending.text, "The ")
        // Not corrected again by the space it ends with.
        TestSupport.expectEqual(pending.corrector.calls.count, 0)
    }

    private static func testKeepingTheQuotedWordCommitsItAsTyped() {
        let rig = rig("so", corrections: ["teh": "the"], predictions: ["teh": WordPredictions(correction: "the", words: ["ten"],
                                                                                              isWord: false)])
        rig.press(.space)
        rig.tap("teh")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "so teh ")
        TestSupport.expectEqual(rig.strip, nil)
        // Kept, it is not corrected again in this session.
        TestSupport.expect(rig.editor.revertedWords.contains("teh"), "the kept word is corrected again")
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so teh teh ")
        // A word kept from the plain strip (no pending correction) just gets its space.
        let plain = Self.rig(predictions: ["he": WordPredictions(words: ["hello"], isWord: true)])
        plain.tap("he")
        plain.choose(0)
        TestSupport.expectEqual(plain.text, "he ")
        TestSupport.expect(plain.editor.revertedWords.isEmpty, "a plain keep reverts")
    }

    private static func testASpaceAlreadyThereIsNotDoubled() {
        // Typing before " there": the chosen word goes in, and the space already after the caret is its one space.
        let rig = AutocorrectRig(document: FakeDocument(FakeTextHost(text: "hi there", caret: 2)), corrections: [:])
        rig.corrector.predicted = ["wo": WordPredictions(words: ["world"], isWord: false)]
        rig.press(.space)
        rig.tap("wo")
        TestSupport.expectEqual(rig.text, "hi wo there")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "hi world there")
        TestSupport.expectEqual(rig.document.host.caret, "hi world".utf16.count)
        // The next word still gets its own space (Sol round 2, run 1): it never joins the chosen one.
        rig.tap("new")
        TestSupport.expectEqual(rig.text, "hi world new there")
    }

    private static func testTheStripGoesWithTheWord() {
        let rig = rig(predictions: ["hel": WordPredictions(words: ["hello", "help"], isWord: false),
                                    "he": WordPredictions(words: ["her"], isWord: true)])
        rig.tap("hel")
        TestSupport.expect(rig.strip != nil, "no strip")
        // Delete within the word predicts again for what is left.
        rig.heldDelete()
        TestSupport.expectEqual(rig.strip, live(["he", "her"]))
        // A caret move or an outside edit drops the word, and the strip with it.
        rig.tap("l")
        rig.document.hostInserts("!", at: 0)
        rig.pump()
        TestSupport.expectEqual(rig.strip, nil)
        // A commit key ends the word: its own strip, if any, follows (none here: the fake reviews nothing).
        let committed = Self.rig(predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        committed.tap("hel")
        committed.press(.space)
        TestSupport.expectEqual(committed.strip, nil)
        // Hiding drops it.
        let hidden = Self.rig(predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        hidden.tap("hel")
        hidden.editor.hide(now: hidden.tick())
        TestSupport.expectEqual(hidden.strip, nil)
    }

    /// The proxy may show the keyboard's own letters late, but never other text: a field the host switched to without
    /// a report (a web page's next input) shows something else, and the strip does not suggest for the old word.
    private static func testAProxyShowingAnotherWordHidesTheStrip() {
        let record = { (text: String, boundary: Character?) -> WordTapRecord in
            var record = WordTapRecord()
            record.startOwned(after: boundary)
            record.edited(deleted: 0, inserted: text)
            return record
        }
        let typed = record("hel", " ")
        for lagging in ["thanks for the hel", "thanks for the he", "thanks for the h", "thanks for the "] {
            TestSupport.expect(typed.mayBeShown(before: lagging), "\(lagging) contradicts the word")
        }
        for other in ["hel", "thanks for thehel", "thanks for the help", "a ahel", "", "thanks"] {
            TestSupport.expect(!typed.mayBeShown(before: other), "\(other) shows the word")
        }
        TestSupport.expect(!typed.mayBeShown(before: nil), "no reading shows the word")
        let start = record("hel", nil)
        for lagging in ["hel", "he", "h", ""] { TestSupport.expect(start.mayBeShown(before: lagging), "\(lagging) at the start") }
        TestSupport.expect(!start.mayBeShown(before: "x hel"), "text before a word at the field's start")
        // In the editor: the host switched fields without a report, the proxy shows only what was typed there.
        let rig = rig("thanks for the", predictions: ["hel": WordPredictions(words: ["hello"], isWord: false),
                                                     "ahel": WordPredictions(words: ["angel"], isWord: false)])
        rig.press(.space)
        rig.tap("a")
        rig.document.switchField(to: FakeTextHost(text: ""), id: rig.document.documentID)
        rig.tap("hel")
        TestSupport.expectEqual(rig.strip, nil)
    }

    /// Sol round 2, run 1: the proxy switched to another field before reporting it, and that field shows the same
    /// word: the choice, made for the first field, changes nothing in it.
    private static func testAChoiceStaysInItsField() {
        let rig = rig(predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        rig.tap("hel")
        TestSupport.expect(rig.strip != nil, "no strip")
        rig.document.switchField(to: FakeTextHost(text: "hel"), id: UUID())
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "hel")
        TestSupport.expectEqual(rig.strip, nil)
    }

    /// Sol round 2, run 2: a proxy that shows a Delete late hides the strip for the moment (it shows another word);
    /// once it shows the word, the strip is back without another key.
    private static func testTheStripReturnsWhenALateProxyCatchesUp() {
        let rig = rig("so", predictions: ["hel": WordPredictions(words: ["hello"], isWord: false),
                                          "he": WordPredictions(words: ["her"], isWord: true)])
        rig.press(.space)
        rig.tap("hel")
        rig.document.lateBefore = .some("so hel")
        rig.heldDelete()
        TestSupport.expectEqual(rig.strip, nil)
        rig.document.lateBefore = nil
        rig.editor.service(now: rig.tick())
        TestSupport.expectEqual(rig.strip, live(["he", "her"]))
    }

    /// Sol round 2, run 2: with Caps Lock (or a field that capitalizes every character), one capital letter already
    /// means all capitals.
    private static func testAllCapitalsTypingSuggestsAllCapitals() {
        let rig = rig(predictions: ["h": WordPredictions(words: ["hello", "help"], isWord: false)])
        rig.autocapitalization = .allCharacters
        rig.tap("H")
        TestSupport.expectEqual(rig.strip, live(["HELLO", "HELP"]))
        // A one-shot capital stays a first capital.
        let once = Self.rig(predictions: ["h": WordPredictions(words: ["hello", "help"], isWord: false)])
        once.tap("H")
        TestSupport.expectEqual(once.strip, live(["Hello", "Help"]))
    }

    /// Sol round 2, run 2: where `correct` keeps a word without looking (an infinite margin), the strip marks no
    /// correction, even when the model gives the typed word no probability at all.
    private static func testAnInfiniteMarginIsNoPendingCorrection() {
        let model = CountingModel(["cat": 0, "car": 0.5])
        let corrector = Autocorrector(lexicon: AutocorrectCoreTests.lexicon([("cat", 200), ("car", 190)]), model: model,
                                      touch: AutocorrectCoreTests.touch)
        let never = AutocorrectCoreTests.params { $0.marginKnown = .infinity; $0.marginApostrophe = .infinity }
        TestSupport.expectEqual(corrector.correct(context: "", word: "cat", points: AutocorrectCoreTests.centreTaps("cat"),
                                                  keys: AutocorrectCoreTests.keys, params: never), "cat")
        TestSupport.expectEqual(predict(corrector, "", "cat", never).correction, nil)
    }

    /// Sol round 2, run 3: the host moved the caret after another copy of the word and has not reported it yet: the
    /// text after the caret is no longer what it was, and the choice changes nothing.
    private static func testAChoiceStaysAtItsCaret() {
        let rig = rig("x hel x", predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        rig.press(.space)
        rig.tap("hel")
        TestSupport.expect(rig.strip != nil, "no strip")
        rig.document.moveCaret(to: 5)
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "x hel x hel")
        TestSupport.expectEqual(rig.strip, nil)
        // Sol round 2, run 5: nor after a Shift or layer key made the strip again at the moved caret.
        let shifted = Self.rig("x hel x", predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        shifted.press(.space)
        shifted.tap("hel")
        shifted.document.moveCaret(to: 5)
        shifted.press(.shift)
        shifted.choose(0)
        TestSupport.expectEqual(shifted.text, "x hel x hel")
    }

    /// Sol round 2, run 5: a space a choice adds is a space: the numbers layer goes back to letters, as after the
    /// space key.
    private static func testAChosenWordsSpaceReturnsToLetters() {
        let rig = AutocorrectRig("", corrections: ["teh": "the"])
        rig.tap("teh")
        rig.press(.layer(.numbers))
        rig.press(.character(","))
        TestSupport.expectEqual(rig.editor.typing.layer, .numbers)
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "teh, ")
        TestSupport.expectEqual(rig.editor.typing.layer, .letters)
        // While typing, and for punctuation that takes a choice's space.
        let typed = Self.rig(predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        typed.tap("hel")
        typed.press(.layer(.numbers))
        typed.choose(0)
        TestSupport.expectEqual(typed.editor.typing.layer, .letters)
        typed.press(.layer(.numbers))
        typed.press(.character("!"))
        TestSupport.expectEqual(typed.text, "hello! ")
        TestSupport.expectEqual(typed.editor.typing.layer, .letters)
    }

    /// Sol round 2, run 5: a model may give the typed letters no probability at all (an n-gram's zero): every
    /// completion is then infinitely better than keeping them, and they still rank by the model.
    private static func testCompletionsSurviveATypedWordWithNoProbability() {
        let model = CountingModel(["h": 0, "hello": 0.5, "help": 0.3])
        let corrector = Autocorrector(lexicon: AutocorrectCoreTests.lexicon([("h", 100), ("hello", 200), ("help", 180)]),
                                      model: model, touch: AutocorrectCoreTests.touch)
        TestSupport.expectEqual(predict(corrector, "", "h").words, ["hello", "help"])
        TestSupport.expectEqual(predict(corrector, "", "hel").words, ["hello", "help"])
    }

    /// Sol round 2, run 1: a swipe after a choice that added its space keeps one recorded edit, as every strip does.
    private static func testASwipeAfterAChoiceKeepsOneRecord() {
        let rig = AutocorrectRig("so", corrections: [:])
        rig.swipe(["hello", "help"])
        rig.choose(1)
        TestSupport.expectEqual(rig.editor.swipeEditCount, 1)
        rig.swipe(["world"])
        TestSupport.expectEqual(rig.text, "so help world")
        TestSupport.expectEqual(rig.editor.swipeEditCount, 1)
        // The same after a choice while typing.
        let typed = Self.rig("so", predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        typed.press(.space)
        typed.tap("hel")
        typed.choose(0)
        typed.swipe(["world"])
        TestSupport.expectEqual(typed.text, "so hello world")
        TestSupport.expectEqual(typed.editor.swipeEditCount, 1)
    }

    // MARK: One space after a tapped word (strips after a commit key or a swipe)

    private static func testACommitStripChoiceEndsWithOneSpace() {
        // After a correction on space: one space, not two, whichever word is chosen.
        let rig = AutocorrectRig.typingASpace(after: "so", alternatives: ["teh": ["the", "ten"]])
        rig.tap("teh")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "so the ")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "so teh ")
        rig.choose(2)
        TestSupport.expectEqual(rig.text, "so ten ")
        // After punctuation, the word and the mark, then one space.
        let comma = AutocorrectRig("", corrections: ["teh": "the"])
        comma.tap("teh")
        comma.press(.character(","))
        TestSupport.expectEqual(comma.text, "the,")
        comma.choose(0)
        TestSupport.expectEqual(comma.text, "teh, ")
        comma.choose(1)
        TestSupport.expectEqual(comma.text, "the, ")
        // A kept word with plausible alternatives: the chosen one, one space.
        let kept = AutocorrectRig.typingASpace(after: "hi", alternatives: ["wrld": ["world", "would"]])
        kept.tap("wrld")
        kept.press(.space)
        kept.choose(1)
        TestSupport.expectEqual(kept.text, "hi world ")
        // Tapping the word already in the field adds nothing.
        kept.choose(1)
        TestSupport.expectEqual(kept.text, "hi world ")
        // Before a space already there (Sol round 2, run 3): none is added, and the next letter gets its own.
        let inside = AutocorrectRig(document: FakeDocument(FakeTextHost(text: "x tail", caret: 1)), corrections: ["teh": "the"])
        inside.press(.space)
        inside.tap("teh")
        inside.press(.character(","))
        TestSupport.expectEqual(inside.text, "x the, tail")
        inside.choose(0)
        TestSupport.expectEqual(inside.text, "x teh, tail")
        inside.tap("a")
        TestSupport.expectEqual(inside.text, "x teh, a tail")
    }

    private static func testASwipeStripChoiceEndsWithOneSpace() {
        let rig = AutocorrectRig("so", corrections: [:])
        rig.swipe(["hello", "help"])
        TestSupport.expectEqual(rig.text, "so hello")
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "so help ")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "so hello ")
        // The next letter needs no space of its own: the word already has one.
        rig.tap("a")
        TestSupport.expectEqual(rig.text, "so hello a")
        // Tapping the swiped word itself gives it its space.
        let same = AutocorrectRig("so", corrections: [:])
        same.swipe(["hello", "help"])
        same.choose(0)
        TestSupport.expectEqual(same.text, "so hello ")
    }

    private static func testTypingSuggestionsAreCandidatesForTheBar() {
        // The bar shows the strip as candidates: dictation, notices and Undo still win (BarMiddleContent).
        let rig = rig(predictions: ["hel": WordPredictions(words: ["hello"], isWord: false)])
        rig.tap("hel")
        let candidates = rig.strip != nil
        TestSupport.expectEqual(BarMiddleContent.resolve(neverCorrectOffer: false, candidates: candidates, dictationInProgress: false,
                                                         notice: false, dictationUndoShown: false), .candidates)
        for (progress, notice, undo) in [(true, false, false), (false, true, false), (false, false, true)] {
            TestSupport.expectEqual(BarMiddleContent.resolve(neverCorrectOffer: false, candidates: candidates, dictationInProgress: progress,
                                                             notice: notice, dictationUndoShown: undo), .dictation)
        }
    }
}
