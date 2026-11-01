import Foundation

/// Which words the corrector may offer or put in (ARCHITECTURE.md, "Word autocorrect"): no archaic forms, a word kept with
/// both choices offered when a vowel rival is about as likely as the correction, and the apostrophe form offered beside a
/// word commonly typed for it. Every word, text and model is invented or a tiny fixture.
enum WordChoiceTests {
    static var tests: [TestCase] {
        [
            ("archaicFormsAreNeverOfferedOrPutIn", testArchaicFormsAreNeverOfferedOrPutIn),
            ("aVowelRivalIsAFarVowelAsLikelyAsTheCorrection", testAVowelRivalIsAFarVowelAsLikelyAsTheCorrection),
            ("aVowelRivalKeepsTheWordAndOffersBoth", testAVowelRivalKeepsTheWordAndOffersBoth),
            ("aVowelRivalKeepsTheWordWhileItIsTyped", testAVowelRivalKeepsTheWordWhileItIsTyped),
            ("anUnclearApostropheTwinKeepsTheWord", testAnUnclearApostropheTwinKeepsTheWord),
            ("aWordKeptOverItsTwinOffersIt", testAWordKeptOverItsTwinOffersIt),
            ("apostropheFormsAreOfferedNeverCorrected", testApostropheFormsAreOfferedNeverCorrected),
            ("whatsAndHowsTakeTheirApostrophe", testWhatsAndHowsTakeTheirApostrophe),
        ]
    }

    private static let keys = AutocorrectCoreTests.keys

    // MARK: Archaic forms

    /// Round 6 council (Opus finding 2): "neer" offered "ne'er". Archaic poetic contractions are never a correction, a
    /// suggestion, a completion, a spelling match or a next word, however likely the model finds them.
    private static func testArchaicFormsAreNeverOfferedOrPutIn() {
        for form in ["ne'er", "e'er", "o'er", "e'en", "twas", "tis"] {
            TestSupport.expect(Autocorrector.archaicForms.contains(form), "\(form) is not excluded")
        }
        for form in Autocorrector.archaicForms { TestSupport.expectEqual(form, form.lowercased()) }
        // Common words with an apostrophe are not archaic.
        for form in ["o'clock", "ma'am", "y'all", "ain't", "don't"] {
            TestSupport.expect(!Autocorrector.archaicForms.contains(form), "\(form) is excluded")
        }
        let corrector = AutocorrectCoreTests.make(
            [("ne'er", 70), ("never", 200), ("near", 190), ("beer", 150), ("o'er", 66), ("over", 220), ("twas", 40), ("was", 250)],
            ["ne'er": 0.3, "never": 0.02, "near": 0.02, "beer": 0.01, "o'er": 0.3, "over": 0.05, "twas": 0.3, "was": 0.1])
        func archaic(_ words: [String]) -> [String] { words.filter(Autocorrector.archaicForms.contains) }
        for word in ["neer", "oer"] {
            let points = AutocorrectCoreTests.centreTaps(word)
            let corrected = corrector.correct(context: "", word: word, points: points, keys: keys, params: .standard)
            TestSupport.expectEqual(archaic([corrected]), [])
            TestSupport.expectEqual(archaic(corrector.suggestions(context: "", word: word, points: points, keys: keys,
                                                                  params: .standard, limit: 3)), [])
            TestSupport.expectEqual(archaic(corrector.spellingMatches(context: "", word: word, params: .standard, limit: 3)), [])
            let predicted = corrector.predictions(context: "", word: word, points: points, keys: keys, params: .standard, limit: 3)
            TestSupport.expectEqual(archaic(predicted.words + [predicted.correction ?? ""]), [])
        }
        TestSupport.expectEqual(corrector.correct(context: "", word: "oer", points: AutocorrectCoreTests.centreTaps("oer"), keys: keys,
                                                  params: .standard), "over")
        // The rest is still offered: completions of "ne" and the spelling matches of "neer".
        let completions = corrector.predictions(context: "", word: "ne", points: AutocorrectCoreTests.centreTaps("ne"), keys: keys,
                                                params: .standard, limit: 3).words
        TestSupport.expectEqual(archaic(completions), [])
        TestSupport.expect(completions.contains("never") && completions.contains("near"), "completions \(completions)")
        TestSupport.expect(corrector.spellingMatches(context: "", word: "neer", params: .standard, limit: 3).contains("never"),
                           "spelling matches")
        let next = corrector.nextWords(context: "", limit: 3)
        TestSupport.expectEqual(archaic(next), [])
        TestSupport.expectEqual(next.first, "was")
    }

    // MARK: Vowel rivals

    /// Round 6 council (Opus finding 2): "best pizza neer" became "never", and "near" was not even offered. The touch model
    /// counts a vowel typed for one far from its key as a far miss, yet people misspell vowels: "near" lost on touch alone.
    /// A vowel rival is a lexicon form that differs from a word outside the lexicon (of at least `vowelRivalLength` letters)
    /// by one vowel typed for another on a key not beside it, at least `vowelRivalRatio` as likely as the correction by the
    /// word model in the sentence; the likeliest one.
    private static func testAVowelRivalIsAFarVowelAsLikelyAsTheCorrection() {
        TestSupport.expectEqual(Autocorrector.vowelRivalLength, 4)
        TestSupport.expect(Autocorrector.vowelRivalRatio > 0.05 && Autocorrector.vowelRivalRatio <= 0.25,
                           "ratio \(Autocorrector.vowelRivalRatio)")
        let corrector = AutocorrectCoreTests.make(
            [("never", 200), ("near", 190), ("beer", 150), ("ne'er", 70), ("talp", 100), ("tilp", 100), ("tolp", 100), ("car", 200),
             ("cor", 100)],
            ["never": 0.01, "near": 0.01, "beer": 0.01, "ne'er": 0.01, "talp": 0.01, "tilp": 0.01, "tolp": 0.01, "car": 0.01, "cor": 0.01],
            byPrevious: [
                "pizza": ["never": 0.008, "near": 0.0024, "beer": 0.0005],
                "cheap": ["never": 0.008, "near": 0.0005, "beer": 0.0005],
                "the": ["talp": 0.01, "tilp": 0.05, "tolp": 0.004],
                "a": ["car": 0.01, "cor": 0.01],
            ])
        func rival(_ context: String, _ word: String, _ correction: String) -> String? {
            corrector.vowelRival(context: context, word: word, correction: correction, keys: keys)
        }
        // Three tenths as likely: a rival. A sixteenth: none.
        TestSupport.expectEqual(rival("best pizza ", "neer", "never"), "near")
        TestSupport.expectEqual(rival("a cheap ", "neer", "never"), nil)
        // A vowel on the key beside the typed one is a slip the touch model already weighs: "tilp" for "tulp" is none, though
        // likelier; "tolp" is.
        TestSupport.expectEqual(rival("the ", "tulp", "talp"), "tolp")
        // The correction is no rival of itself: for "tulp" corrected to "tolp", "talp" (a far vowel too) is.
        TestSupport.expectEqual(rival("the ", "tulp", "tolp"), "talp")
        // Only for a word outside the lexicon of four letters or more.
        TestSupport.expectEqual(rival("best pizza ", "beer", "near"), nil)
        TestSupport.expectEqual(rival("a ", "cer", "car"), nil)
    }

    /// The commit keeps a word with a vowel rival as typed and offers the correction and the rival after it; Space then
    /// commits what was typed. The fixed corrections never ask.
    private static func testAVowelRivalKeepsTheWordAndOffersBoth() {
        let rig = AutocorrectRig.typingASpace(after: "pizza", corrections: ["neer": "never"])
        rig.corrector.rivals = ["neer": "near"]
        rig.tap("neer")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "pizza neer ")
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["neer", "never", "near"], inserted: 0))
        TestSupport.expectEqual(rig.corrector.rivalCalls.last?.word, "neer")
        TestSupport.expectEqual(rig.corrector.rivalCalls.last?.correction, "never")
        TestSupport.expectEqual(rig.corrector.rivalCalls.last?.context, "pizza ")
        rig.choose(2)
        TestSupport.expectEqual(rig.text, "pizza near ")
        // In the typed word's case.
        let capital = AutocorrectRig("", corrections: ["neer": "never"])
        capital.corrector.rivals = ["neer": "near"]
        capital.tap("Neer")
        capital.press(.space)
        TestSupport.expectEqual(capital.strip, SwipeStrip(candidates: ["Neer", "Never", "Near"], inserted: 0))
        // No rival: corrected as before.
        let plain = AutocorrectRig.typingASpace(after: "pizza", corrections: ["neer": "never"])
        plain.tap("neer")
        plain.press(.space)
        TestSupport.expectEqual(plain.text, "pizza never ")
        TestSupport.expectEqual(plain.strip, SwipeStrip(candidates: ["neer", "never"], inserted: 1))
        // A fixed correction is made whatever a rival would say, and asks for none.
        let fixed = AutocorrectRig("", corrections: [:])
        fixed.corrector.rivals = ["tommorow": "tommorew"]
        fixed.tap("tommorow")
        fixed.press(.space)
        TestSupport.expectEqual(fixed.text, "tomorrow ")
        TestSupport.expectEqual(fixed.corrector.rivalCalls.count, 0)
        // A word the corrector keeps asks for none.
        let kept = AutocorrectRig("", corrections: [:])
        kept.corrector.rivals = ["neer": "near"]
        kept.tap("neer")
        kept.press(.space)
        TestSupport.expectEqual(kept.text, "neer ")
        TestSupport.expectEqual(kept.corrector.rivalCalls.count, 0)
    }

    /// While the word is typed: no pending correction, the word as typed first, then the correction and the rival.
    private static func testAVowelRivalKeepsTheWordWhileItIsTyped() {
        let rig = AutocorrectRig.typingASpace(after: "pizza", corrections: ["neer": "never"])
        rig.corrector.predicted = ["neer": WordPredictions(correction: "never", words: ["never", "beer"], isWord: false)]
        rig.corrector.rivals = ["neer": "near"]
        rig.tap("neer")
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["neer", "never", "near"], inserted: 0,
                                                      live: SwipeStrip.Live(quoted: nil, marked: nil)))
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "pizza neer ")
        // Without a rival the correction is pending, as before.
        let plain = AutocorrectRig.typingASpace(after: "pizza", corrections: ["neer": "never"])
        plain.corrector.predicted = ["neer": WordPredictions(correction: "never", words: ["never", "beer"], isWord: false)]
        plain.tap("neer")
        TestSupport.expectEqual(plain.strip, SwipeStrip(candidates: ["neer", "never", "beer"], inserted: 1,
                                                        live: SwipeStrip.Live(quoted: 0, marked: 1)))
    }

    // MARK: Apostrophe twins

    /// Round 6 (lead): at a sentence's start "Were you there?" went out as "We're you there?". The corrector picks between
    /// a lexicon word and its apostrophe twin (the same letters: "were", "we're") by the word model alone, and before the
    /// next word is typed a sentence's start can't tell them apart. A lexicon word is kept over its twin unless the twin
    /// is at least `twinRatio` times as likely in the sentence.
    private static func testAnUnclearApostropheTwinKeepsTheWord() {
        TestSupport.expect(Autocorrector.twinRatio >= 5 && Autocorrector.twinRatio <= 7, "ratio \(Autocorrector.twinRatio)")
        let corrector = AutocorrectCoreTests.make(
            [("were", 200), ("we're", 200), ("ill", 100), ("i'll", 200), ("where", 200), ("think", 200)],
            ["were": 0.01, "we're": 0.047, "ill": 0.001, "i'll": 0.007, "where": 0.01, "think": 0.01],
            byPrevious: ["think": ["were": 0.001, "we're": 0.058]])
        func keeps(_ context: String, _ word: String, _ correction: String) -> Bool {
            corrector.keepsWordOverTwin(context: context, word: word, correction: correction)
        }
        // A sentence's start: "we're" 4.7 times "were" keeps it; "I'll" 7 times "ill" corrects it.
        TestSupport.expect(keeps("", "were", "we're"), "were at a sentence start")
        TestSupport.expect(keeps("Ok. ", "were", "we're"), "were after a sentence end")
        TestSupport.expect(!keeps("", "ill", "i'll"), "ill at a sentence start")
        // After "I think", "we're" is 58 times as likely: corrected.
        TestSupport.expect(!keeps("I think ", "were", "we're"), "were after think")
        // Only a lexicon word against its own twin.
        TestSupport.expect(!keeps("", "were", "where"), "not a twin")
        TestSupport.expect(!keeps("", "wont", "won't"), "not a lexicon word")
    }

    /// The commit keeps a word kept over its twin as typed and offers the twin after it, in the typed word's case; while
    /// it is typed no correction is pending. Without that, corrected as before. The fixed corrections never ask.
    private static func testAWordKeptOverItsTwinOffersIt() {
        let rig = AutocorrectRig("", corrections: ["were": "we're"])
        rig.corrector.keptOverTwin = ["were"]
        rig.tap("Were")
        rig.press(.space)
        TestSupport.expectEqual(rig.text, "Were ")
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["Were", "We're"], inserted: 0))
        TestSupport.expectEqual(rig.corrector.twinCalls.last?.word, "were")
        TestSupport.expectEqual(rig.corrector.twinCalls.last?.correction, "we're")
        rig.choose(1)
        TestSupport.expectEqual(rig.text, "We're ")
        let plain = AutocorrectRig("", corrections: ["were": "we're"])
        plain.tap("Were")
        plain.press(.space)
        TestSupport.expectEqual(plain.text, "We're ")
        // While it is typed.
        let typing = AutocorrectRig("", corrections: ["were": "we're"])
        typing.corrector.predicted = ["were": WordPredictions(correction: "we're", words: ["we're", "where"], isWord: true)]
        typing.corrector.keptOverTwin = ["were"]
        typing.tap("Were")
        TestSupport.expectEqual(typing.strip, SwipeStrip(candidates: ["Were", "We're", "Where"], inserted: 0,
                                                         live: SwipeStrip.Live(quoted: nil, marked: nil)))
        // A fixed correction asks for none.
        let fixed = AutocorrectRig("", corrections: [:])
        fixed.corrector.keptOverTwin = ["cant"]
        fixed.tap("cant")
        fixed.press(.space)
        TestSupport.expectEqual(fixed.text, "can't ")
        TestSupport.expectEqual(fixed.corrector.twinCalls.count, 0)
    }

    // MARK: Apostrophe forms

    /// Round 6 council (Opus finding 5): "ill be back" kept "ill" with no "I'll" offered. A short table of real words
    /// commonly typed for a contraction offers the contraction beside the word, while it is typed and after a commit key, in
    /// the typed word's case. Never a correction: Space keeps the word as typed.
    private static func testApostropheFormsAreOfferedNeverCorrected() {
        let table = WordAutocorrect.apostropheForms
        TestSupport.expect(!table.isEmpty && table.count <= 20, "\(table.count) entries")
        for (word, form) in [("ill", "i'll"), ("id", "i'd"), ("well", "we'll"), ("were", "we're"), ("wed", "we'd"), ("hell", "he'll"),
                             ("shell", "she'll"), ("its", "it's"), ("lets", "let's")] {
            TestSupport.expectEqual(table[word], form)
        }
        for (word, form) in table {
            TestSupport.expect(word == word.lowercased() && !word.contains("'"), "word \(word)")
            TestSupport.expect(form.contains("'") && form == form.lowercased(), "form \(form)")
            // The same letters: the form is the word with its apostrophe.
            TestSupport.expectEqual(Autocorrector.key(of: form), word)
            TestSupport.expect(WordAutocorrect.fixedCorrection(word) == nil, "\(word) is corrected")
        }
        // After the space: a choice, in the typed word's case.
        for (typed, offered) in [("ill", "I'll"), ("Ill", "I'll"), ("its", "it's"), ("Well", "We'll"), ("WERE", "WE'RE")] {
            let rig = AutocorrectRig("", corrections: [:])
            rig.tap(typed)
            rig.press(.space)
            TestSupport.expectEqual(rig.text, typed + " ")
            TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: [typed, offered], inserted: 0))
        }
        // Beside the corrector's own suggestions, and chosen like any.
        let rig = AutocorrectRig.typingASpace(after: "so", corrections: [:], alternatives: ["ill": ["will"]])
        rig.tap("ill")
        rig.press(.space)
        TestSupport.expectEqual(rig.strip, SwipeStrip(candidates: ["ill", "will", "I'll"], inserted: 0))
        rig.choose(2)
        TestSupport.expectEqual(rig.text, "so I'll ")
        // While typed: beside the word, which a space keeps.
        let typing = AutocorrectRig.typingASpace(after: "so", corrections: [:])
        typing.corrector.predicted = ["ill": WordPredictions(words: ["illegal"], isWord: true)]
        typing.tap("ill")
        TestSupport.expectEqual(typing.strip, SwipeStrip(candidates: ["ill", "illegal", "I'll"], inserted: 0,
                                                         live: SwipeStrip.Live(quoted: nil, marked: nil)))
        typing.press(.space)
        TestSupport.expectEqual(typing.text, "so ill ")
        // Off with autocorrect.
        let off = AutocorrectRig("", corrections: [:])
        off.enabled = false
        off.tap("ill")
        off.press(.space)
        TestSupport.expectEqual(off.strip, nil)
    }

    /// Round 6 (the apostrophe-less words people type): every one checked on bundle b34 is corrected but "whats" and "hows",
    /// which are lexicon words the corrector keeps. Both are almost always typed for the contraction, as "cant" is.
    private static func testWhatsAndHowsTakeTheirApostrophe() {
        TestSupport.expectEqual(WordAutocorrect.fixedCorrections["whats"], "what's")
        TestSupport.expectEqual(WordAutocorrect.fixedCorrections["hows"], "how's")
        let rig = AutocorrectRig("", corrections: [:])
        for word in ["whats", "Hows"] {
            rig.tap(word)
            rig.press(.space)
        }
        TestSupport.expectEqual(rig.text, "what's How's ")
    }
}
