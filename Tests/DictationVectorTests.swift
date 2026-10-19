import Foundation

/// Consumes linux/testdata/dictation-vectors.json (version 1), shared with
/// linux/crates/lf-dictation/tests/vectors.rs. Every case in every section
/// runs here; nothing is skipped. Failures are collected so a run reports
/// every divergence at once.
enum DictationVectorTests {
    static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("linux/testdata/dictation-vectors.json")
    }

    private typealias Object = [String: Any]

    static func run() {
        guard let data = try? Data(contentsOf: vectorsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? Object else {
            fatalError("Shared dictation vectors are missing or unreadable at \(vectorsURL.path)")
        }
        TestSupport.expectEqual(root["version"] as? Int, 1)
        var failures: [String] = []
        runProcess(root, section: "process", minimumCount: 40, &failures)
        runSpokenDelimiters(root, &failures)
        runProcess(root, section: "prompt_tag", minimumCount: 10, &failures)
        TestSupport.expect(failures.isEmpty, "Dictation vectors failed:\n" + failures.joined(separator: "\n"))
    }

    /// `process` and `prompt_tag` share one case schema; `prompt_tag` defaults to none.
    private static func runProcess(_ root: Object, section: String, minimumCount: Int, _ failures: inout [String]) {
        let cases = root[section] as! [Object]
        TestSupport.expect(cases.count >= minimumCount, "Dictation \(section) vectors are incomplete")
        for (index, item) in cases.enumerated() {
            let input = item["input"] as! String
            let result = LocalDictationCore.process(
                input, macros: macros(item), pressEnterEnabled: flag(item, "press_enter_enabled"),
                spokenDelimitersEnabled: flag(item, "spoken_delimiters_enabled"),
                spokenNumbersEnabled: flag(item, "spoken_numbers_enabled"),
                promptTag: item["prompt_tag"].map { $0 as! String })
            check(item, result, "\(section)[\(index)] \(input.debugDescription)", &failures)
        }
    }

    private static func runSpokenDelimiters(_ root: Object, _ failures: inout [String]) {
        let cases = root["spoken_delimiters"] as! [Object]
        TestSupport.expect(cases.count >= 100, "Spoken delimiter vectors are incomplete")
        TestSupport.expect(cases.filter { $0["origin"] as? String == "swift" }.count >= 86,
                           "Every Swift spoken delimiter case must be ported")
        for (index, item) in cases.enumerated() {
            let input = item["input"] as! String
            let expected = item["expected"] as! String
            let disabled = item["expected_disabled"] as? String ?? input
            // Spoken numbers are pinned by number-vectors.json; these vectors test delimiters alone.
            for (enabled, want) in [(true, expected), (false, disabled)] {
                let got = LocalDictationCore.process(input, macros: [], pressEnterEnabled: true,
                                                     spokenDelimitersEnabled: enabled,
                                                     spokenNumbersEnabled: false).output
                if got != want {
                    failures.append("spoken_delimiters[\(index)]\(enabled ? "" : " disabled") \(input.debugDescription): "
                        + "expected \(want.debugDescription), got \(got.debugDescription)")
                }
            }
        }
    }

    /// Checks only the expected fields the case lists, as the vectors' description requires.
    private static func check(_ item: Object, _ result: LocalDictationResult, _ label: String,
                              _ failures: inout [String]) {
        let expected = item["expected"] as! Object
        TestSupport.expect(!expected.isEmpty, "\(label) checks nothing")
        for key in expected.keys.sorted() {
            let want = expected[key]!
            let got: Any
            switch key {
            case "raw": got = result.rawTranscript
            case "output": got = result.output
            case "press_enter": got = result.shouldPressEnter
            case "used_macro": got = result.usedMacro
            case "added_prompt_tag": got = result.addedPromptTag
            case "status": got = result.status
            default: fatalError("\(label): unknown expected field \(key)")
            }
            if !matches(want, got) {
                failures.append("\(label): \(key) expected \(describe(want)), got \(describe(got))")
            }
        }
    }

    private static func matches(_ want: Any, _ got: Any) -> Bool {
        switch got {
        case let got as String: return (want as? String) == got
        case let got as Bool: return boolean(want) == got
        default: return false
        }
    }

    /// JSONSerialization decodes JSON booleans as CFBoolean-backed NSNumbers; 0 and 1 are not booleans.
    private static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return string.debugDescription }
        if let bool = boolean(value) { return String(bool) }
        return String(describing: value)
    }

    private static func flag(_ item: Object, _ key: String) -> Bool {
        guard let value = item[key] else { return true }
        guard let bool = boolean(value) else { fatalError("\(key) must be a boolean") }
        return bool
    }

    private static func macros(_ item: Object) -> [VoiceMacro] {
        (item["macros"] as? [Object] ?? []).map {
            VoiceMacro(command: $0["command"] as! String, payload: $0["payload"] as! String)
        }
    }
}
