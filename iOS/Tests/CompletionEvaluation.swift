import Foundation

/// The completion ranking on ordinary short phrases (ARCHITECTURE.md, "Word autocorrect", Suggestions, Evaluation): 90
/// invented messages about shopping, plans, work and family, each cut after the first letters of a word, with the word
/// meant. Measured on the shipped word model, which the host tests do not have: the test runs only when
/// `LF_AUTOCORRECT_BUNDLE` names a swipe bundle directory (`LF_AUTOCORRECT_BUNDLE=<bundle> make -C iOS test`) and
/// guards the counts measured on bundle b34. Every phrase is invented.
enum CompletionEvaluation {
    static var tests: [TestCase] {
        [("ordinaryPhrasesKeepTheirCompletions", testOrdinaryPhrasesKeepTheirCompletions)]
    }

    /// The text before the word, the word's first letters, and the word meant.
    static let cases: [(before: String, prefix: String, meant: String)] = [
        ("Buy ", "flo", "flowers"),
        ("Can you pick up some ", "mi", "milk"),
        ("We need ", "br", "bread"),
        ("Grab a dozen ", "eg", "eggs"),
        ("Don't forget the shopping ", "l", "list"),
        ("I'm at the ", "st", "store"),
        ("Do we have any ", "cof", "coffee"),
        ("Get some ", "tom", "tomatoes"),
        ("I'll pick up ", "pi", "pizza"),
        ("Should I get ", "gr", "groceries"),
        ("It was on ", "sa", "sale"),
        ("I found a good ", "de", "deal"),
        ("They had a big ", "dis", "discount"),
        ("How much was the ", "ti", "ticket"),
        ("Is the shop ", "op", "open"),
        ("I left my ", "wa", "wallet"),
        ("See you ", "tom", "tomorrow"),
        ("Are you free ", "ton", "tonight"),
        ("Let's meet for ", "lu", "lunch"),
        ("Let's meet for ", "d", "dinner"),
        ("What time is the ", "mo", "movie"),
        ("I'll be there in ten ", "mi", "minutes"),
        ("Running a bit ", "la", "late"),
        ("I'm on my ", "w", "way"),
        ("Do you want to grab ", "co", "coffee"),
        ("Can we ", "res", "reschedule"),
        ("How about ", "sat", "saturday"),
        ("I'm ", "lea", "leaving"),
        ("Just ", "ar", "arrived"),
        ("I'll call you ", "la", "later"),
        ("Have a good ", "we", "weekend"),
        ("Let me know when you ", "ge", "get"),
        ("Happy ", "bi", "birthday"),
        ("Where should we ", "me", "meet"),
        ("I'll send you the ", "re", "report"),
        ("The meeting is ", "can", "canceled"),
        ("Can we move the ", "mee", "meeting"),
        ("I'm working from ", "h", "home"),
        ("Please review the ", "do", "document"),
        ("Thanks for your ", "he", "help"),
        ("I have a ", "dea", "deadline"),
        ("Running late for the ", "m", "meeting"),
        ("Can you check your ", "em", "email"),
        ("I'll be in the ", "of", "office"),
        ("Let me check my ", "cal", "calendar"),
        ("Sorry for the ", "de", "delay"),
        ("Looking forward to ", "se", "seeing"),
        ("I'll finish it by ", "to", "tomorrow"),
        ("Can you join the ", "ca", "call"),
        ("Please send me the ", "pr", "presentation"),
        ("Can you pick up the ", "ki", "kids"),
        ("Dinner is ", "re", "ready"),
        ("Don't forget to ", "fe", "feed"),
        ("The baby is ", "sl", "sleeping"),
        ("Tell your ", "br", "brother"),
        ("We're visiting ", "gra", "grandma"),
        ("Love you ", "to", "too"),
        ("Did you do your ", "ho", "homework"),
        ("Be home ", "so", "soon"),
        ("Can you walk the ", "d", "dog"),
        ("Clean your ", "ro", "room"),
        ("Happy ", "an", "anniversary"),
        ("Call your ", "gr", "grandma"),
        ("What do you want for ", "br", "breakfast"),
        ("Your dad is ", "coo", "cooking"),
        ("Who is picking up the ", "k", "kids"),
        ("Can you buy ", "m", "milk"),
        ("We're out of ", "b", "bread"),
        ("I need to go to the ", "s", "store"),
        ("Pick up some ", "e", "eggs"),
        ("Let's get ", "p", "pizza"),
        ("See you ", "t", "tomorrow"),
        ("Are you coming to the ", "p", "party"),
        ("What time is ", "d", "dinner"),
        ("I'll be ", "l", "late"),
        ("Good ", "m", "morning"),
        ("Good ", "n", "night"),
        ("I'm in a ", "m", "meeting"),
        ("Can you send me the ", "f", "file"),
        ("I'll call you ", "b", "back"),
        ("Thanks for the ", "h", "help"),
        ("How was your ", "d", "day"),
        ("Say hi to your ", "m", "mom"),
        ("Did you feed the ", "c", "cat"),
        ("Have a safe ", "t", "trip"),
        ("Let me know if you need ", "a", "anything"),
        ("Happy ", "b", "birthday"),
        ("Can we talk ", "l", "later"),
        ("Don't forget your ", "k", "keys"),
        ("Buy some ", "f", "food"),
    ]

    /// Bundle b34 (round 5): the word meant was the first completion offered in 57 cases, and among the three offered
    /// in 70.
    static let firstAtLeast = 57
    static let threeAtLeast = 70

    /// The cases where the word meant is the first completion offered, and where it is among the three offered. The letters
    /// carry no tap points: completions do not depend on them.
    static func measure(_ corrector: WordCorrecting, params: AutocorrectParams, keys: [PlacedKey]) -> (first: Int, three: Int) {
        var first = 0, three = 0
        for item in cases {
            let points: [(x: Double, y: Double)?] = Array(repeating: nil, count: item.prefix.utf8.count)
            let words = corrector.predictions(context: TapPrior.normalizeContext(item.before), word: item.prefix, points: points,
                                              keys: keys, params: params, limit: SwipeStrip.limit).words
            if words.first == item.meant { first += 1 }
            if words.contains(item.meant) { three += 1 }
        }
        return (first, three)
    }

    private static func testOrdinaryPhrasesKeepTheirCompletions() {
        TestSupport.expectEqual(cases.count, 90)
        for item in cases {
            TestSupport.expect(item.meant.hasPrefix(item.prefix) && item.meant != item.prefix, "\(item)")
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
        let measured = measure(corrector, params: manifest.defaultParams, keys: keys)
        print("completion evaluation: first \(measured.first)/\(cases.count), three \(measured.three)/\(cases.count)")
        TestSupport.expect(measured.first >= firstAtLeast, "first \(measured.first) < \(firstAtLeast)")
        TestSupport.expect(measured.three >= threeAtLeast, "three \(measured.three) < \(threeAtLeast)")
    }
}
