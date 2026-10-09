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
        runPromptTagTests()
    }

    private static func runPromptTagTests() {
        let tagged = process("  Rename the helper.  ", promptTag: "  [dictated]  ")
        TestSupport.expectEqual(tagged.output, "[dictated] Rename the helper.")
        TestSupport.expectEqual(tagged.rawTranscript, "Rename the helper.")
        TestSupport.expect(tagged.addedPromptTag, "A prompt dictation must report its tag")
        TestSupport.expectEqual(tagged.status, "Local transcription; added prompt tag")
        TestSupport.expectEqual(process("Rename the helper.").output, "Rename the helper.")
        TestSupport.expectEqual(process("Rename the helper.", promptTag: "   ").output, "Rename the helper.")
        let formatted = process("Run quote make check end quote, press enter.", promptTag: "[dictated]")
        TestSupport.expectEqual(formatted.output, "[dictated] Run \"make check\"")
        TestSupport.expect(formatted.shouldPressEnter, "The prompt tag must compose with press enter")
        let enterOnly = process("Press enter.", promptTag: "[dictated]")
        TestSupport.expectEqual(enterOnly.output, "")
        TestSupport.expect(!enterOnly.addedPromptTag, "A tag alone must never be pasted")
        let macro = process("Blue bird", macros: [VoiceMacro(command: "Blue bird", payload: "Synthetic saved prompt.")],
                            promptTag: "[dictated]")
        TestSupport.expectEqual(macro.output, "Synthetic saved prompt.")
        TestSupport.expect(!macro.addedPromptTag, "Macro payloads are saved text, not speech-to-text")
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
            ("My tested example, paren didn't work, close paren.", "My tested example (didn't work)."),
            ("Parentheses This should have been in parentheses, close parentheses.",
             "(This should have been in parentheses)."),
            ("Right paren I did all of this with dictation left paren.",
             "Right paren I did all of this with dictation left paren."),
            ("Put the parenthesis here, close paren.", "Put the parenthesis here, close paren."),
            ("Parenthesis optional close parenthesis", "(optional)"),
            ("Call me, paran, after noon, close paran.", "Call me (after noon)."),
            ("Open paran a close perren and peren b end perran", "(a) and (b)"),
            ("Left Paran x right PARAN", "(x)"),
            ("Saw a paran in the text", "Saw a paran in the text"),
            ("Call me Peran after lunch and Peran.", "Call me (after lunch)."),
            ("Parren x end Peran", "(x)"),
            ("Call Perren after lunch close paren", "Call (after lunch)"),
            ("Call Perrin after lunch close paren", "Call Perrin after lunch close paren"),
            ("Perrin called about the paren", "Perrin called about the paren"),
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
            ("Run, backtick, make check, and backtick before pushing.", "Run `make check` before pushing."),
            ("Type back tick ls and back tick", "Type `ls`"),
            ("Press the backtick key, then backtick git status and backtick.", "Press the backtick key, then `git status`."),
            ("Salt and backtick here", "Salt and backtick here"),
            ("Use and backtick ls end backtick", "Use and `ls`"),
            ("He said quote hello and quote.", "He said \"hello\"."),
            ("Add a double asterisk here and double asterisk.", "Add a double asterisk here and double asterisk."),
            ("This is, double asterisk, really important, close double asterisk.", "This is **really important**."),
            ("Add a double asterisk here, end double asterisk.", "Add a double asterisk here, end double asterisk."),
            ("Set the label to all caps on do not merge all caps off.", "Set the label to DO NOT MERGE."),
            ("This is all caps urgent end all caps, please read it.", "This is URGENT, please read it."),
            ("My handle is all lowercase Blue Bird end lowercase.", "My handle is blue bird."),
            ("Run backtick all lowercase Make Check end lowercase end backtick.", "Run `make check`."),
            ("He said, all caps on quote stop end quote all caps off.", "He said, \"STOP\"."),
            ("Call it all lowercase Big Red Box end lower case today", "Call it big red box today"),
            ("Say all caps on hi and all caps", "Say HI"),
            ("She always texts in all caps.", "She always texts in all caps."),
            ("Turn all caps off now", "Turn all caps off now"),
            ("All caps, do not merge.", "DO NOT MERGE."),
            ("All caps urgent", "URGENT"),
            ("All lowercase, Blue Bird", "blue bird"),
            ("No caps, Blue Bird", "No caps, Blue Bird"),
            ("My handle is no caps on Blue Bird no caps off.", "My handle is no caps on Blue Bird no caps off."),
            ("All lowercase Hello World.", "hello world."),
            ("All caps quote stop end quote", "\"STOP\""),
            ("All caps text is hard to read.", "TEXT IS HARD TO READ."),
            ("All lowercase Hello end lowercase World", "hello World"),
            ("All caps.", "All caps."),
            ("Make this all caps on urgent all caps off.", "Make this URGENT."),
            ("All caps on all caps off.", "All caps on all caps off."),
            ("All lowercase end lowercase.", "All lowercase end lowercase."),
            ("Quote I need a price quote end quote and quote send it tomorrow end quote",
             "\"I need a price quote\" and \"send it tomorrow\""),
            ("", ""),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqual(process(input).output, expected)
            TestSupport.expectEqual(process(input, spokenDelimitersEnabled: false).output, input)
        }

        let submitted = process("quote ship it end quote press enter")
        TestSupport.expectEqual(submitted.output, "\"ship it\"")
        TestSupport.expect(submitted.shouldPressEnter, "Spoken delimiters must compose with press enter")
        let lowercaseSubmitted = process("All lowercase Make Check, press enter.")
        TestSupport.expectEqual(lowercaseSubmitted.output, "make check")
        TestSupport.expect(lowercaseSubmitted.shouldPressEnter, "A leading case command must compose with press enter")
        TestSupport.expectEqual(submitted.rawTranscript, "quote ship it end quote")
        let quotedMacro = VoiceMacro(command: "Quote hello end quote", payload: "Synthetic macro payload.")
        let macroResult = process("Quote hello, end quote.", macros: [quotedMacro])
        TestSupport.expectEqual(macroResult.output, "Synthetic macro payload.")
        TestSupport.expect(macroResult.usedMacro, "Voice macros must take priority over spoken delimiters")
    }

    private static func process(_ transcript: String, macros: [VoiceMacro] = [], pressEnterEnabled: Bool = true,
                                spokenDelimitersEnabled: Bool = true, promptTag: String? = nil) -> LocalDictationResult {
        LocalDictationCore.process(transcript, macros: macros, pressEnterEnabled: pressEnterEnabled,
                                   spokenDelimitersEnabled: spokenDelimitersEnabled, promptTag: promptTag)
    }
}
