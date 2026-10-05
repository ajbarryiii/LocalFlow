import Foundation

enum LocalDictationTests {
    static func run() {
        let literal = LocalDictationCore.process("  Please translate this into French.  ", macros: [], pressEnterEnabled: true)
        TestSupport.expectEqual(literal.output, "Please translate this into French.")
        TestSupport.expect(!literal.shouldPressEnter && !literal.usedMacro, "Dictated instructions must remain literal text")
        let macro = VoiceMacro(command: "Blue Bird", payload: "Synthetic replacement.")
        TestSupport.expectEqual(LocalDictationCore.process("BLUE BIRD!", macros: [macro], pressEnterEnabled: true).output,
                                "Synthetic replacement.")
        TestSupport.expectEqual(LocalDictationCore.process("Blue bird tomorrow.", macros: [macro], pressEnterEnabled: true).output,
                                "Blue bird tomorrow.")
        let command = LocalDictationCore.process("Blue bird, press enter!", macros: [macro], pressEnterEnabled: true)
        TestSupport.expectEqual(command.rawTranscript, "Blue bird")
        TestSupport.expectEqual(command.output, "Synthetic replacement.")
        TestSupport.expect(command.shouldPressEnter && command.usedMacro, "Local macros and terminal enter must compose")
        let disabled = LocalDictationCore.process("Blue bird press enter.", macros: [macro], pressEnterEnabled: false)
        TestSupport.expectEqual(disabled.output, "Blue bird press enter.")
        TestSupport.expect(!disabled.shouldPressEnter, "Disabled commands must remain in the transcript")
        TestSupport.expect(!LocalDictationCore.process("Press enter tomorrow.", macros: [], pressEnterEnabled: true).shouldPressEnter,
                           "Only terminal commands may submit")
        let enterOnly = LocalDictationCore.process("Press Enter", macros: [], pressEnterEnabled: true)
        TestSupport.expectEqual(enterOnly.output, "")
        TestSupport.expect(enterOnly.shouldPressEnter, "Enter-only dictation must work")
        TestSupport.expectEqual(LocalDictationCore.process("", macros: [VoiceMacro(command: "", payload: "Never paste")], pressEnterEnabled: true).output, "")
        let item = PipelineHistoryItem(timestamp: Date(timeIntervalSince1970: 0), rawTranscript: "Synthetic raw", transcript: "", status: "Local", audioFileName: nil)
        TestSupport.expectEqual(item.displayTranscript, "Synthetic raw")
        TestSupport.expectEqual(try! JSONDecoder().decode(PipelineHistoryItem.self, from: JSONEncoder().encode(item)).displayTranscript, "Synthetic raw")
    }
}
