import Foundation

/// What a commit key does to vowel slips and near-miss words (ARCHITECTURE.md, "Word autocorrect", Evaluation of
/// corrections): 33 invented messages, each ending in a mistyped word, with what should happen to it: corrected to the
/// word meant, or left as typed with the word meant offered beside it (a correction to it counts too). Every case runs the
/// whole commit (`WordAutocorrect.review`: fixed corrections, the corrector, vowel rivals, apostrophe twins) with taps at
/// the key centres.
/// Measured on the shipped word model, which the host tests do not have: the test runs only when `LF_AUTOCORRECT_BUNDLE`
/// names a swipe bundle directory and guards the counts measured on bundle b34. Every phrase is invented.
enum CorrectionEvaluation {
    static var tests: [TestCase] {
        [("vowelSlipsAndNearMissesCommitAsExpected", testVowelSlipsAndNearMissesCommitAsExpected)]
    }

    enum Outcome: Equatable {
        /// The commit puts this word in.
        case corrected(String)
        /// The commit leaves the word as typed and offers this word (or corrects to it).
        case offered(String)
    }

    /// The text before the word, the word as typed, and what should happen to it.
    static let cases: [(before: String, typed: String, outcome: Outcome)] = [
        // A vowel typed for another, far from its key: the touch model counts it as a far miss.
        ("Best pizza ", "neer", .offered("near")),
        ("Let's get ", "lanch", .offered("lunch")),
        ("Can you ", "sind", .offered("send")),
        ("See you ", "lator", .corrected("later")),
        ("Can you ", "halp", .corrected("help")),
        ("Thanks for the ", "halp", .corrected("help")),
        ("I'll be ", "thare", .corrected("there")),
        ("I'm on my ", "wey", .corrected("way")),
        ("Happy ", "berthday", .corrected("birthday")),
        ("How is the ", "weathar", .corrected("weather")),
        ("Good ", "mornong", .corrected("morning")),
        ("I will be back ", "soin", .corrected("soon")),
        ("I'm ", "hungrey", .corrected("hungry")),
        ("We moved the ", "meating", .offered("meeting")),
        ("What's the ", "plen", .offered("plan")),
        ("I ", "thenk", .offered("think")),
        ("I need ", "hilp", .offered("help")),
        ("What's for ", "dinnar", .offered("dinner")),
        ("It was ", "amazeng", .offered("amazing")),
        // Near misses of other kinds: a letter left out, swapped or slipped onto a neighbour.
        ("It's ", "raning", .corrected("raining")),
        ("I'm at the ", "stor", .corrected("store")),
        ("We ", "shuold", .corrected("should")),
        ("I ", "realy", .corrected("really")),
        ("So many ", "pepole", .corrected("people")),
        ("I'm so ", "hapy", .corrected("happy")),
        ("Pass me ", "teh", .corrected("the")),
        ("See you ", "tomorow", .corrected("tomorrow")),
        ("Running ", "abit", .corrected("a bit")),
        ("", "helo", .corrected("hello")),
        ("See ", "yoi", .corrected("you")),
        // A word and its apostrophe twin: at a sentence's start "were" stays (a question, or "we're"); "ill" is "I'll".
        ("", "were", .offered("were")),
        ("I think ", "were", .corrected("we're")),
        ("", "ill", .corrected("i'll")),
    ]

    /// Bundle b34 (round 6): 33 of the cases as expected and no word changed to another than the one meant. Before vowel
    /// rivals and the archaic forms' exclusion, 27 of the first 30, with three wrong ("neer" → "never", "lanch" → "launch",
    /// "sind" → "find"); before apostrophe twins, "were" at a sentence's start became "we're".
    static let expectedAtLeast = 33
    static let wrongAtMost = 0

    /// What the commit makes of a case: the word put in (nil to leave it) and the strip's words, lowercase.
    static func commit(_ corrector: WordCorrecting, params: AutocorrectParams, keys: [PlacedKey], before: String,
                       typed: String) -> (corrected: String?, choices: [String]) {
        let entries = typed.map { letter in
            WordTapRecord.Entry(character: letter, point: keys.first { $0.action == .character(String(letter)) }
                .map { TapPoint(x: $0.frame.midX, y: $0.frame.midY) })
        }
        let record = WordTapRecord(entries: entries, owned: true, boundary: before.isEmpty ? nil : " ")
        let setup = AutocorrectSetup(corrector: corrector, keys: keys, params: params, secureTextEntry: false)
        let review = WordAutocorrect.review(before: before + typed, record: record, reverted: [], setup: setup)
        return (review?.correction?.replacement.lowercased(), (review?.choices ?? []).map { $0.lowercased() })
    }

    /// The cases with the expected outcome, and those whose word was changed to another than the one meant.
    static func measure(_ corrector: WordCorrecting, params: AutocorrectParams, keys: [PlacedKey],
                        report: Bool = false) -> (expected: Int, wrong: Int) {
        var expected = 0, wrong = 0
        for item in cases {
            let result = commit(corrector, params: params, keys: keys, before: item.before, typed: item.typed)
            let meant: String
            let met: Bool
            switch item.outcome {
            case .corrected(let word):
                meant = word
                met = result.corrected == word
            case .offered(let word):
                meant = word
                met = result.corrected == word || (result.corrected == nil && result.choices.contains(word))
            }
            if met { expected += 1 }
            if let corrected = result.corrected, corrected != meant { wrong += 1 }
            if report {
                print("  \(met ? "ok  " : "miss") \(item.before)\(item.typed) -> \(result.corrected ?? "(kept)") \(result.choices)")
            }
        }
        return (expected, wrong)
    }

    private static func testVowelSlipsAndNearMissesCommitAsExpected() {
        TestSupport.expectEqual(cases.count, 33)
        for item in cases {
            TestSupport.expect(!item.typed.isEmpty && item.typed == item.typed.lowercased(), "\(item.typed)")
        }
        guard let path = ProcessInfo.processInfo.environment["LF_AUTOCORRECT_BUNDLE"] else { return }
        let directory = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")),
              let manifest = try? AutocorrectManifest.decode(from: data),
              let corrector = AutocorrectLoader.load(manifest: manifest, bundleURL: directory, model: manifest.defaultModel) else {
            TestSupport.expect(false, "no autocorrect model in \(path)")
            return
        }
        let keys = KeyboardLayout.keys(for: .letters, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                                       showsGlobe: false)
        let measured = measure(corrector, params: manifest.defaultParams, keys: keys,
                               report: ProcessInfo.processInfo.environment["LF_EVALUATION_REPORT"] != nil)
        print("correction evaluation: expected \(measured.expected)/\(cases.count), wrong \(measured.wrong)")
        TestSupport.expect(measured.expected >= expectedAtLeast, "expected \(measured.expected) < \(expectedAtLeast)")
        TestSupport.expect(measured.wrong <= wrongAtMost, "wrong \(measured.wrong) > \(wrongAtMost)")
    }
}
