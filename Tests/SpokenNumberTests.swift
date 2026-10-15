import Foundation

/// Consumes linux/testdata/number-vectors.json (version 1), shared with the Rust tests, and checks how
/// spoken-number formatting composes with the rest of `LocalDictationCore.process`.
enum SpokenNumberTests {
    static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("linux/testdata/number-vectors.json")
    }

    static func run() {
        runVectors()
        runProcess()
    }

    private static func runVectors() {
        guard let data = try? Data(contentsOf: vectorsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("Shared number vectors are missing or unreadable at \(vectorsURL.path)")
        }
        TestSupport.expectEqual(root["version"] as? Int, 1)
        let cases = root["format"] as! [[String: Any]]
        TestSupport.expect(cases.count >= 80, "Number vectors are incomplete")
        for item in cases {
            let input = item["input"] as! String
            let expected = item["expected"] as! String
            let got = SpokenNumberFormatter.format(input)
            TestSupport.expect(got == expected,
                               "format(\(input.debugDescription)) [\(item["rule"] ?? "")]: expected \(expected.debugDescription), got \(got.debugDescription)")
        }
    }

    private static func runProcess() {
        let enabled = process("Step three takes twenty minutes.", spokenNumbersEnabled: true)
        TestSupport.expectEqual(enabled.output, "Step 3 takes 20 minutes.")
        TestSupport.expectEqual(enabled.rawTranscript, "Step three takes twenty minutes.")
        TestSupport.expectEqual(process("Step three takes twenty minutes.", spokenNumbersEnabled: false).output,
                                "Step three takes twenty minutes.")

        let macro = VoiceMacro(command: "Template twenty", payload: "Synthetic payload with twenty words.")
        let macroResult = process("Template twenty.", macros: [macro], spokenNumbersEnabled: true)
        TestSupport.expect(macroResult.usedMacro, "A macro command with a number word must still match")
        TestSupport.expectEqual(macroResult.output, "Synthetic payload with twenty words.")

        let composed = process("Set quote twenty five percent end quote, press enter.", spokenNumbersEnabled: true,
                               promptTag: "[dictated]")
        TestSupport.expectEqual(composed.output, "[dictated] Set \"25%\"")
        TestSupport.expect(composed.shouldPressEnter, "Spoken numbers must compose with press enter")
    }

    private static func process(_ transcript: String, macros: [VoiceMacro] = [], spokenNumbersEnabled: Bool,
                                promptTag: String? = nil) -> LocalDictationResult {
        LocalDictationCore.process(transcript, macros: macros, pressEnterEnabled: true, spokenDelimitersEnabled: true,
                                   spokenNumbersEnabled: spokenNumbersEnabled, promptTag: promptTag)
    }
}
