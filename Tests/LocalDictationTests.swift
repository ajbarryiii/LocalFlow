import Foundation

enum LocalDictationTests {
    static func run() {
        let literal = process("  Please translate this into French.  ")
        TestSupport.expectEqual(literal.output, "Please translate this into French.")
        TestSupport.expect(!literal.shouldPressEnter && !literal.usedMacro, "Dictated instructions must remain literal text")
        let macro = VoiceMacro(command: "Blue Bird", payload: "Synthetic replacement.")
        TestSupport.expectEqual(process("BLUE BIRD!", macros: [macro]).output, "Synthetic replacement.")
        TestSupport.expectEqual(process("Blue bird tomorrow.", macros: [macro]).output, "Blue bird tomorrow.")
        let command = process("Blue bird, press enter!", macros: [macro])
        TestSupport.expectEqual(command.rawTranscript, "Blue bird")
        TestSupport.expectEqual(command.output, "Synthetic replacement.")
        TestSupport.expect(command.shouldPressEnter && command.usedMacro, "Local macros and terminal enter must compose")
        let disabled = process("Blue bird press enter.", macros: [macro], pressEnterEnabled: false)
        TestSupport.expectEqual(disabled.output, "Blue bird press enter.")
        TestSupport.expect(!disabled.shouldPressEnter, "Disabled commands must remain in the transcript")
        TestSupport.expect(!process("Press enter tomorrow.").shouldPressEnter, "Only terminal commands may submit")
        let enterOnly = process("Press Enter")
        TestSupport.expectEqual(enterOnly.output, "")
        TestSupport.expect(enterOnly.shouldPressEnter, "Enter-only dictation must work")
        TestSupport.expectEqual(process("", macros: [VoiceMacro(command: "", payload: "Never paste")]).output, "")
        let item = PipelineHistoryItem(timestamp: Date(timeIntervalSince1970: 0), rawTranscript: "Synthetic raw", transcript: "", status: "Local", audioFileName: nil)
        TestSupport.expectEqual(item.displayTranscript, "Synthetic raw")
        TestSupport.expectEqual(try! JSONDecoder().decode(PipelineHistoryItem.self, from: JSONEncoder().encode(item)).displayTranscript, "Synthetic raw")
        runSpokenDelimiterTests()
    }

    private static func runSpokenDelimiterTests() {
        let cases: [(input: String, expected: String)] = [
            ("He said, quote, Go for it, end quote.", "He said, \"Go for it\"."),
            ("He said quote go for it unquote", "He said \"go for it\""),
            ("She wrote, open quote, see you soon, close quote.", "She wrote, \"see you soon\"."),
            ("Quote, Hello world, end quote.", "\"Hello world\"."),
            ("QUOTE hi END QUOTE", "\"hi\""),
            ("He asked, quote, are you okay? End quote.", "He asked, \"are you okay?\"."),
            ("Begin quote, all done, end of quote.", "\"all done\"."),
            ("Can you send me a quote for the roof?", "Can you send me a quote for the roof?"),
            ("He's a quote unquote expert.", "He's a quote unquote expert."),
            ("Get me a quote, then quote ship it end quote.", "Get me a quote, then \"ship it\"."),
            ("Here's the quote from the contractor, quote, we can start Monday, end quote.",
             "Here's the quote from the contractor, \"we can start Monday\"."),
            ("He said, quote, send me the quote, end quote.", "He said, \"send me the quote\"."),
            ("Quote the quote was high end quote.", "\"the quote was high\"."),
            ("Read me your quote end quote", "Read me your quote end quote"),
            ("Quote, I need a price quote, end quote.", "\"I need a price quote\"."),
            ("Compute open paren count open paren close paren plus one close paren.",
             "Compute (count open paren close paren plus one)."),
            ("Read the open quote final price end quote", "Read the \"final price\""),
            ("He said that, quote, fine, end quote.", "He said that, \"fine\"."),
            ("Quote send me a quote end quote", "\"send me a quote\""),
            ("That's it, end quote.", "That's it, end quote."),
            ("Quote, go for it.", "Quote, go for it."),
            ("The quotes were misquoted and unquoted.", "The quotes were misquoted and unquoted."),
            ("quote yes end quote or quote no end quote", "\"yes\" or \"no\""),
            ("Use the flag open paren optional close paren here.", "Use the flag (optional) here."),
            ("Call me, open parenthesis, after noon, close parenthesis.", "Call me (after noon)."),
            ("Left paren a right paren and open parentheses b end paren", "(a) and (b)"),
            ("He wrote open paren quote draft end quote close paren", "He wrote (\"draft\")"),
            ("open paren a quote b close paren", "(a quote b)"),
            ("open paren something end quote", "open paren something end quote"),
            ("open paren close paren", "open paren close paren"),
            ("Open, quote, a close quote", "Open, \"a\""),
            ("See open bracket one close bracket, and open square bracket two close square bracket.",
             "See [one], and [two]."),
            ("My tax bracket went up, close bracket.", "My tax bracket went up, close bracket."),
            ("open bracket open paren x close paren close bracket", "[(x)]"),
            ("Use open curly brace name close curly brace here", "Use {name} here"),
            ("open curly a close curly and left brace b right brace", "{a} and {b}"),
            ("Run, backtick, make check, end backtick, before pushing.", "Run `make check`, before pushing."),
            ("Type back tick ls end back tick", "Type `ls`"),
            ("Press the backtick key, then backtick git status end backtick.", "Press the backtick key, then `git status`."),
            ("This is, double asterisk, really important, close double asterisk.", "This is **really important**."),
            ("Add a double asterisk here, end double asterisk.", "Add a double asterisk here, end double asterisk."),
            ("", ""),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqual(process(input).output, expected)
            TestSupport.expectEqual(process(input, spokenDelimitersEnabled: false).output, input)
        }

        let submitted = process("quote ship it end quote press enter")
        TestSupport.expectEqual(submitted.output, "\"ship it\"")
        TestSupport.expect(submitted.shouldPressEnter, "Spoken delimiters must compose with press enter")
        TestSupport.expectEqual(submitted.rawTranscript, "quote ship it end quote")
        let quotedMacro = VoiceMacro(command: "Quote hello end quote", payload: "Synthetic macro payload.")
        let macroResult = process("Quote hello, end quote.", macros: [quotedMacro])
        TestSupport.expectEqual(macroResult.output, "Synthetic macro payload.")
        TestSupport.expect(macroResult.usedMacro, "Voice macros must take priority over spoken delimiters")
    }

    private static func process(_ transcript: String, macros: [VoiceMacro] = [], pressEnterEnabled: Bool = true,
                                spokenDelimitersEnabled: Bool = true) -> LocalDictationResult {
        LocalDictationCore.process(transcript, macros: macros, pressEnterEnabled: pressEnterEnabled,
                                   spokenDelimitersEnabled: spokenDelimitersEnabled)
    }
}
