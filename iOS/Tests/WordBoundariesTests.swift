import Foundation

enum WordBoundariesTests {
    static var tests: [TestCase] {
        [
            ("wordAndTrailingSpaces", testWordAndTrailingSpaces),
            ("punctuationStaysWithItsWord", testPunctuationStaysWithItsWord),
            ("apostrophesAndDigitSeparatorsJoin", testApostrophesAndDigitSeparatorsJoin),
            ("lineBreaksAreTheirOwnStep", testLineBreaksAreTheirOwnStep),
            ("emojiAreTheirOwnStep", testEmojiAreTheirOwnStep),
            ("countsGraphemesAndCodeUnits", testCountsGraphemesAndCodeUnits),
            ("repeatedStepsEmptyTheText", testRepeatedStepsEmptyTheText),
        ]
    }

    /// The text that one step deletes.
    private static func deleted(_ text: String) -> String {
        String(text.suffix(WordBoundaries.previousWord(before: text).graphemes))
    }

    private static func testWordAndTrailingSpaces() {
        TestSupport.expectEqual(deleted("The quick brown"), "brown")
        TestSupport.expectEqual(deleted("The quick "), "quick ")
        TestSupport.expectEqual(deleted("The quick  \t"), "quick  \t")
        TestSupport.expectEqual(deleted("word"), "word")
        TestSupport.expectEqual(deleted("   "), "   ")
        TestSupport.expectEqual(deleted(""), "")
        TestSupport.expectEqual(deleted("snake_case"), "snake_case")
        TestSupport.expectEqual(deleted("caf\u{E9}"), "caf\u{E9}")
        TestSupport.expectEqual(deleted("cafe\u{301}"), "cafe\u{301}")
    }

    private static func testPunctuationStaysWithItsWord() {
        TestSupport.expectEqual(deleted("Hello, world."), "world.")
        TestSupport.expectEqual(deleted("Hello, "), "Hello, ")
        TestSupport.expectEqual(deleted("Really?! "), "Really?! ")
        TestSupport.expectEqual(deleted("say (hello)"), "hello)")
        TestSupport.expectEqual(deleted("say ("), "(")
        TestSupport.expectEqual(deleted("wait ..."), "...")
        TestSupport.expectEqual(deleted("a - "), "- ")
        TestSupport.expectEqual(deleted("well-known"), "known")
    }

    private static func testApostrophesAndDigitSeparatorsJoin() {
        TestSupport.expectEqual(deleted("I don't"), "don't")
        TestSupport.expectEqual(deleted("I don\u{2019}t"), "don\u{2019}t")
        TestSupport.expectEqual(deleted("the dogs'"), "dogs'")
        TestSupport.expectEqual(deleted("said 'hi'"), "hi'")
        TestSupport.expectEqual(deleted("pi is 3.14"), "3.14")
        TestSupport.expectEqual(deleted("about 1,200"), "1,200")
        TestSupport.expectEqual(deleted("end.Next"), "Next")
    }

    private static func testLineBreaksAreTheirOwnStep() {
        TestSupport.expectEqual(deleted("first\n"), "\n")
        TestSupport.expectEqual(deleted("first\n  "), "\n  ")
        TestSupport.expectEqual(deleted("first\r\n"), "\r\n")
        TestSupport.expectEqual(deleted("first\n\n"), "\n")
    }

    private static func testEmojiAreTheirOwnStep() {
        TestSupport.expectEqual(deleted("nice \u{1F44D}\u{1F3FD}"), "\u{1F44D}\u{1F3FD}")
        TestSupport.expectEqual(deleted("hi\u{1F44B}"), "\u{1F44B}")
        TestSupport.expectEqual(deleted("love \u{2764}\u{FE0F} "), "\u{2764}\u{FE0F} ")
        TestSupport.expectEqual(deleted("go \u{1F1EB}\u{1F1F7}"), "\u{1F1EB}\u{1F1F7}")
        TestSupport.expectEqual(deleted("press 1\u{FE0F}\u{20E3}"), "1\u{FE0F}\u{20E3}")
        TestSupport.expectEqual(deleted("\u{1F44B}hi"), "hi")
        // A plain digit or sign is not an emoji.
        TestSupport.expect(!WordBoundaries.isEmoji("1"), "digit")
        TestSupport.expect(!WordBoundaries.isEmoji("\u{A9}"), "copyright sign")
        TestSupport.expect(WordBoundaries.isEmoji("\u{A9}\u{FE0F}"), "emoji copyright")
    }

    private static func testCountsGraphemesAndCodeUnits() {
        TestSupport.expectEqual(WordBoundaries.previousWord(before: "ok \u{1F44D}\u{1F3FD}"),
                                WordBoundaries.Deletion(graphemes: 1, utf16: 4))
        TestSupport.expectEqual(WordBoundaries.previousWord(before: "cafe\u{301} "),
                                WordBoundaries.Deletion(graphemes: 5, utf16: 6))
        TestSupport.expectEqual(WordBoundaries.previousWord(before: ""), WordBoundaries.Deletion(graphemes: 0, utf16: 0))
    }

    private static func testRepeatedStepsEmptyTheText() {
        var text = "Dictated text, with a typo \u{1F605}\nand more words."
        var steps: [String] = []
        while !text.isEmpty {
            let count = WordBoundaries.previousWord(before: text).graphemes
            TestSupport.expect(count > 0, "no progress on \(text.count) characters")
            steps.append(String(text.suffix(count)))
            text = String(text.dropLast(count))
        }
        TestSupport.expectEqual(steps, ["words.", "more ", "and ", "\n", "\u{1F605}", "typo ", "a ", "with ",
                                        "text, ", "Dictated "])
    }
}
