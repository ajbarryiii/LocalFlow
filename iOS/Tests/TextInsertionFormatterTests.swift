import Foundation

enum TextInsertionFormatterTests {
    static var tests: [TestCase] {
        [
            ("trimsTranscript", testTrimsTranscript),
            ("emptyTranscriptInsertsNothing", testEmptyTranscriptInsertsNothing),
            ("noSpaceAtStartOrAfterWhitespace", testNoSpaceAtStartOrAfterWhitespace),
            ("spaceAfterWordsAndPunctuation", testSpaceAfterWordsAndPunctuation),
            ("noSpaceAfterOpeningBracketOrQuote", testNoSpaceAfterOpeningBracketOrQuote),
            ("straightQuotesOpenOrClose", testStraightQuotesOpenOrClose),
            ("noSpaceBeforeClosingPunctuation", testNoSpaceBeforeClosingPunctuation),
            ("pressEnterAppendsNewline", testPressEnterAppendsNewline),
        ]
    }

    private static func text(_ transcript: String, after context: String?, pressEnter: Bool = false) -> String {
        TextInsertionFormatter.text(for: Fixture.result(text: transcript, pressEnter: pressEnter), contextBefore: context)
    }

    private static func testTrimsTranscript() {
        TestSupport.expectEqual(text("  Synthetic words \n\t", after: nil), "Synthetic words")
        TestSupport.expectEqual(text("\nSynthetic words", after: "Prefix"), " Synthetic words")
    }

    private static func testEmptyTranscriptInsertsNothing() {
        for transcript in ["", "   ", "\n\t "] {
            TestSupport.expectEqual(text(transcript, after: nil), "")
            TestSupport.expectEqual(text(transcript, after: "Prefix"), "")
        }
    }

    private static func testNoSpaceAtStartOrAfterWhitespace() {
        for context in [nil, "", "Prefix ", "Prefix\n", "Prefix\t", "Prefix\u{00A0}"] as [String?] {
            TestSupport.expectEqual(text("synthetic", after: context), "synthetic")
        }
    }

    private static func testSpaceAfterWordsAndPunctuation() {
        for context in ["Prefix", "Prefix.", "Prefix,", "Prefix:", "Prefix)", "Prefix]", "Prefix}", "42", "-", "…",
                        "Prefix\u{201D}", "Prefix\u{2019}", "🎙️"] {
            TestSupport.expectEqual(text("synthetic", after: context), " synthetic")
        }
    }

    private static func testNoSpaceAfterOpeningBracketOrQuote() {
        for context in ["(", "Prefix [", "Prefix {", "Prefix \u{201C}", "Prefix \u{2018}", "Prefix \u{00AB}"] {
            TestSupport.expectEqual(text("synthetic", after: context), "synthetic")
        }
    }

    private static func testStraightQuotesOpenOrClose() {
        for context in ["\"", "Prefix \"", "Prefix '", "(\"", "Prefix\n\""] {
            TestSupport.expectEqual(text("synthetic", after: context), "synthetic")
        }
        for context in ["\"Prefix\"", "Prefix'", "Prefix.\""] {
            TestSupport.expectEqual(text("synthetic", after: context), " synthetic")
        }
    }

    private static func testNoSpaceBeforeClosingPunctuation() {
        for transcript in [".", ", then", "; more", ": list", "! yes", "? no", ") end", "] end", "} end"] {
            TestSupport.expectEqual(text(transcript, after: "Prefix"), transcript)
        }
        TestSupport.expectEqual(text("- item", after: "Prefix"), " - item")
    }

    private static func testPressEnterAppendsNewline() {
        TestSupport.expectEqual(text("Synthetic send", after: "Prefix", pressEnter: true), " Synthetic send\n")
        TestSupport.expectEqual(text("Synthetic send", after: nil, pressEnter: true), "Synthetic send\n")
        // "press enter" alone still presses Enter, as on macOS.
        TestSupport.expectEqual(text("", after: "Prefix", pressEnter: true), "\n")
    }
}
