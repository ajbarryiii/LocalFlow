import Foundation

/// Contract tests for fitting a dictation to the text around the insertion
/// point: spacing, the first word's capital and the final punctuation. All
/// text is invented.
enum InsertionContextTests {
    static func run() {
        testUnknownContextOnlyTrims()
        testEmptyTranscriptInsertsNothing()
        testInsertingIntoTheMiddleOfASentence()
        testNoSpaceAtStartOrAfterWhitespace()
        testSpaceAfterWordsAndPunctuation()
        testNoSpaceAfterOpeningBracketOrQuote()
        testStraightQuotesOpenOrClose()
        testNoSpaceBeforeClosingPunctuation()
        testLowercasesTheFirstWordMidSentence()
        testKeepsTheCapitalAtASentenceStart()
        testKeepsWordsThatAreNotPlainCapitalized()
        testDropsPunctuationBeforePunctuation()
        testDropsThePeriodBeforeAContinuation()
        testKeepsPunctuationBeforeANewSentenceOrLineEnd()
        testSpaceBeforeATouchingWord()
        testPunctuationOnlyTranscriptIsKept()
    }

    private static func text(_ transcript: String, before: String? = nil, after: String? = nil) -> String {
        InsertionContextFormatter.text(for: transcript, before: before, after: after)
    }

    private static func testUnknownContextOnlyTrims() {
        TestSupport.expectEqual(text("  Synthetic words. \n\t"), "Synthetic words.")
        TestSupport.expectEqual(text("Synthetic words."), "Synthetic words.")
    }

    private static func testEmptyTranscriptInsertsNothing() {
        for transcript in ["", "   ", "\n\t "] {
            TestSupport.expectEqual(text(transcript), "")
            TestSupport.expectEqual(text(transcript, before: "Prefix", after: " suffix"), "")
        }
    }

    /// The case that motivated this: a cursor placed before the period that
    /// ends an earlier dictation.
    private static func testInsertingIntoTheMiddleOfASentence() {
        TestSupport.expectEqual(
            text("Which ends like this one.", before: "It ends like this one", after: ". "),
            " which ends like this one")
        TestSupport.expectEqual(text("Middle words.", before: "Start of it", after: " end of it."), " middle words")
    }

    private static func testNoSpaceAtStartOrAfterWhitespace() {
        for before in [nil, "", "Prefix ", "Prefix\n", "Prefix\t", "Prefix\u{00A0}"] as [String?] {
            TestSupport.expectEqual(text("synthetic", before: before), "synthetic")
        }
    }

    private static func testSpaceAfterWordsAndPunctuation() {
        for before in ["Prefix", "Prefix.", "Prefix,", "Prefix:", "Prefix)", "Prefix]", "Prefix}", "42", "-", "…",
                       "Prefix\u{201D}", "Prefix\u{2019}", "🎙️"] {
            TestSupport.expectEqual(text("synthetic", before: before), " synthetic")
        }
    }

    private static func testNoSpaceAfterOpeningBracketOrQuote() {
        for before in ["(", "Prefix [", "Prefix {", "Prefix \u{201C}", "Prefix \u{2018}", "Prefix \u{00AB}"] {
            TestSupport.expectEqual(text("synthetic", before: before), "synthetic")
        }
    }

    private static func testStraightQuotesOpenOrClose() {
        for before in ["\"", "Prefix \"", "Prefix '", "(\"", "Prefix\n\""] {
            TestSupport.expectEqual(text("synthetic", before: before), "synthetic")
        }
        for before in ["\"Prefix\"", "Prefix'", "Prefix.\""] {
            TestSupport.expectEqual(text("synthetic", before: before), " synthetic")
        }
    }

    private static func testNoSpaceBeforeClosingPunctuation() {
        for transcript in [".", ", then", "; more", ": list", "! yes", "? no", ") end", "] end", "} end"] {
            TestSupport.expectEqual(text(transcript, before: "Prefix"), transcript)
        }
        TestSupport.expectEqual(text("- item", before: "Prefix"), " - item")
    }

    /// After a letter, digit, comma, semicolon or em dash the dictation
    /// continues a sentence. A capitalized name is lowercased too; that
    /// occasional mistake is accepted.
    private static func testLowercasesTheFirstWordMidSentence() {
        for before in ["Prefix", "Prefix ", "Prefix,", "Prefix, ", "Prefix;", "Prefix \u{00A0}", "Prefix 42", "Prefix\u{2014}"] {
            TestSupport.expectEqual(text("Which words", before: before).trimmingCharacters(in: .whitespaces), "which words")
        }
        TestSupport.expectEqual(text("A Synthetic Title", before: "Prefix "), "a Synthetic Title")
        TestSupport.expectEqual(text("Don't stop", before: "Prefix "), "don't stop")
        TestSupport.expectEqual(text("Don\u{2019}t stop", before: "Prefix "), "don\u{2019}t stop")
        TestSupport.expectEqual(text("Élan here", before: "Prefix "), "élan here")
    }

    private static func testKeepsTheCapitalAtASentenceStart() {
        for before in [nil, "", "   ", "Done.", "Done. ", "Really?", "Wow! ", "Done.\" ", "Line\n", "Line\n  ",
                       "Note:", "List:\n- ", "(", "\"", "Prefix-", "(aside) ", "e.g."] as [String?] {
            TestSupport.expectEqual(text("Which words", before: before).trimmingCharacters(in: .whitespaces), "Which words")
        }
    }

    private static func testKeepsWordsThatAreNotPlainCapitalized() {
        for transcript in ["I think so", "I'm here", "I\u{2019}ll go", "I'd say", "I've seen", "NASA said", "LocalFlow runs",
                           "iPhone works", "\"Quoted\" words", "42 Words", "OK then"] {
            TestSupport.expectEqual(text(transcript, before: "Prefix "), transcript)
        }
    }

    /// Before following punctuation, the dictation's own closing punctuation
    /// would double it up.
    private static func testDropsPunctuationBeforePunctuation() {
        for after in [".", ". Next", ",", ", more", ";", ":", "!", "?", "\u{2026}"] {
            TestSupport.expectEqual(text("Ends here.", after: after), "Ends here")
        }
        TestSupport.expectEqual(text("Really?", after: "."), "Really")
        TestSupport.expectEqual(text("Wait...", after: "."), "Wait")
        TestSupport.expectEqual(text("Ends here", after: "."), "Ends here")
    }

    /// Before a lowercase word or a number, a final period would split the
    /// sentence; a question or exclamation mark is kept.
    private static func testDropsThePeriodBeforeAContinuation() {
        for after in [" and more", "  and more", "\u{00A0}and more", " 42 more"] {
            TestSupport.expectEqual(text("Ends here.", after: after), "Ends here")
        }
        TestSupport.expectEqual(text("Really?", after: " and more"), "Really?")
        TestSupport.expectEqual(text("Wow!", after: " and more"), "Wow!")
        TestSupport.expectEqual(text("Wait...", after: " and more"), "Wait...")
    }

    private static func testKeepsPunctuationBeforeANewSentenceOrLineEnd() {
        for after in [nil, "", " ", "\n", " \nNext", " Next", "  The next", " \"Quoted\"", ")", "\"", "\u{201D}", " - item"] as [String?] {
            TestSupport.expectEqual(text("Ends here.", after: after), "Ends here.")
        }
    }

    /// Inserted right against a word, a space separates them; before a
    /// lowercase word the period goes, before a capital it stays.
    private static func testSpaceBeforeATouchingWord() {
        TestSupport.expectEqual(text("Ends here.", after: "and more"), "Ends here ")
        TestSupport.expectEqual(text("Ends here.", after: "42"), "Ends here ")
        TestSupport.expectEqual(text("Ends here.", after: "Next one"), "Ends here. ")
        TestSupport.expectEqual(text("No period", after: "Next"), "No period ")
        TestSupport.expectEqual(text("Middle", before: "Prefix", after: "suffix"), " middle ")
    }

    private static func testPunctuationOnlyTranscriptIsKept() {
        TestSupport.expectEqual(text(".", before: "Prefix", after: "."), ".")
        TestSupport.expectEqual(text("?", after: " and more"), "?")
    }
}
