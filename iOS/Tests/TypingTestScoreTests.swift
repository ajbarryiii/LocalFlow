import Foundation

/// ARCHITECTURE.md, "Typing test": aligning a typed attempt with its passage. Invented text only.
enum TypingTestScoreTests {
    static var tests: [TestCase] {
        [
            ("perfectAttemptMatchesEverything", testPerfectAttemptMatchesEverything),
            ("droppedLettersAreFoundWhereTheyWere", testDroppedLettersAreFoundWhereTheyWere),
            ("wrongAndExtraLetters", testWrongAndExtraLetters),
            ("droppedSpacesAndRows", testDroppedSpacesAndRows),
            ("countsAddUpAndCaseIsIgnored", testCountsAddUpAndCaseIsIgnored),
            ("charactersPerMinute", testCharactersPerMinute),
            ("passagesAreLowercaseLettersAndSingleSpaces", testPassagesAreLowercaseLettersAndSingleSpaces),
        ]
    }

    private typealias Op = TypingTestScore.Op

    private static func testPerfectAttemptMatchesEverything() {
        let score = TypingTestScore.score(passage: "get on", typed: "get on")
        TestSupport.expectEqual(score.ops, "get on".map { Op.matched($0) })
        TestSupport.expectEqual(score.matched, 6)
        TestSupport.expectEqual(score.dropped, 0)
        TestSupport.expectEqual(score.wrong, 0)
        TestSupport.expectEqual(score.extra, 0)
    }

    private static func testDroppedLettersAreFoundWhereTheyWere() {
        // The device examples: a word's first letter, and its last.
        let start = TypingTestScore.score(passage: "to get", typed: "to et")
        TestSupport.expectEqual(start.ops, [.matched("t"), .matched("o"), .matched(" "), .dropped("g"), .matched("e"), .matched("t")])
        TestSupport.expectEqual(start.dropped(at: .wordStart), 1)
        TestSupport.expectEqual(start.dropped(in: .middle), 1)
        let end = TypingTestScore.score(passage: "actually no", typed: "actuall no")
        TestSupport.expectEqual(end.dropped, 1)
        TestSupport.expectEqual(end.dropped(at: .wordEnd), 1)
        TestSupport.expectEqual(end.dropped(in: .top), 1)
        TestSupport.expectEqual(end.ops[7], .dropped("y"))
        let inside = TypingTestScore.score(passage: "being", typed: "beng")
        TestSupport.expectEqual(inside.dropped(at: .inside), 1)
        TestSupport.expectEqual(inside.ops[2], .dropped("i"))
        // A one-letter word counts as a word's first letter.
        let single = TypingTestScore.score(passage: "a cat", typed: " cat")
        TestSupport.expectEqual(single.dropped(at: .wordStart), 1)
        TestSupport.expectEqual(single.dropped(at: .wordEnd), 0)
        // Nothing typed: everything dropped.
        TestSupport.expectEqual(TypingTestScore.score(passage: "ab c", typed: "").dropped, 4)
    }

    private static func testWrongAndExtraLetters() {
        let wrong = TypingTestScore.score(passage: "cat", typed: "cst")
        TestSupport.expectEqual(wrong.ops, [.matched("c"), .wrong(expected: "a", typed: "s"), .matched("t")])
        TestSupport.expectEqual(wrong.wrong, 1)
        TestSupport.expectEqual(wrong.dropped, 0)
        let extra = TypingTestScore.score(passage: "cat", typed: "cart")
        TestSupport.expectEqual(extra.extra, 1)
        TestSupport.expectEqual(extra.dropped + extra.wrong, 0)
        TestSupport.expect(extra.ops.contains(.extra("r")), "no extra r: \(extra.ops)")
        // A substitution costs less than a drop plus an extra.
        TestSupport.expectEqual(TypingTestScore.score(passage: "ab", typed: "ax").ops, [.matched("a"), .wrong(expected: "b", typed: "x")])
    }

    private static func testDroppedSpacesAndRows() {
        let score = TypingTestScore.score(passage: "the cat zips", typed: "thecat ips")
        TestSupport.expectEqual(score.dropped, 2)
        TestSupport.expectEqual(score.dropped(at: .space), 1)
        TestSupport.expectEqual(score.dropped(in: .space), 1)
        TestSupport.expectEqual(score.dropped(in: .bottom), 1)
        TestSupport.expectEqual(score.dropped(at: .wordStart), 1)
        // Rows of the letters layer.
        TestSupport.expectEqual(TypingTestScore.Row.of("q"), .top)
        TestSupport.expectEqual(TypingTestScore.Row.of("l"), .middle)
        TestSupport.expectEqual(TypingTestScore.Row.of("m"), .bottom)
        TestSupport.expectEqual(TypingTestScore.Row.of(" "), .space)
        TestSupport.expectEqual(TypingTestScore.Row.of("7"), .other)
    }

    private static func testCountsAddUpAndCaseIsIgnored() {
        let score = TypingTestScore.score(passage: "the quick brown fox", typed: "The quck brpwn  fox x")
        TestSupport.expectEqual(score.matched + score.dropped + score.wrong, "the quick brown fox".count)
        TestSupport.expectEqual(score.matched + score.wrong + score.extra, "The quck brpwn  fox x".count)
        TestSupport.expectEqual(score.ops.first, .matched("t"))
        TestSupport.expectEqual(score.typedCount, "The quck brpwn  fox x".count)
        TestSupport.expectEqual(score.passageCount, "the quick brown fox".count)
    }

    private static func testCharactersPerMinute() {
        let score = TypingTestScore.score(passage: "abcdef", typed: "abcdef")
        TestSupport.expectEqual(score.charactersPerMinute(seconds: 3), 120)
        TestSupport.expectEqual(score.charactersPerMinute(seconds: 0), nil)
    }

    private static func testPassagesAreLowercaseLettersAndSingleSpaces() {
        TestSupport.expect(TypingTestScore.passages.count >= 8, "too few passages")
        var letters = Set<Character>()
        for passage in TypingTestScore.passages {
            TestSupport.expect(passage.allSatisfy { ("a" ... "z").contains($0) || $0 == " " }, "not lowercase letters: \(passage)")
            TestSupport.expect(!passage.contains("  ") && passage.first != " " && passage.last != " ", "spacing: \(passage)")
            letters.formUnion(passage.filter { $0 != " " })
        }
        TestSupport.expectEqual(letters.count, 26)
    }
}
