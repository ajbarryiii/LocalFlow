import Foundation

/// Consumes linux/testdata/dictionary-vectors.json (version 1), shared with
/// the Rust tests. Every section that applies to the Mac runs here.
enum DictionaryVectorTests {
    static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("linux/testdata/dictionary-vectors.json")
    }

    private typealias Object = [String: Any]

    static func run() {
        guard let data = try? Data(contentsOf: vectorsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? Object else {
            fatalError("Shared dictionary vectors are missing or unreadable at \(vectorsURL.path)")
        }
        TestSupport.expectEqual(root["version"] as? Int, 1)
        let constants = root["constants"] as! Object
        TestSupport.expectEqual(constants["alpha"] as? Double, BiasGraph.alpha)
        TestSupport.expectEqual(constants["context_score"] as? Double, BiasGraph.contextScore)
        TestSupport.expectEqual(constants["depth_scaling"] as? Double, BiasGraph.depthScaling)
        TestSupport.expectEqual(constants["blank"] as? Int, 1024)
        TestSupport.expectEqual((constants["verify_strengths"] as! [Double]).map(Float.init), VerifyDecision.strengths)

        let encoder = BPEEncoder(pieces: root["vocab"] as! [String])
        var counts: [String: Int] = [:]
        func section(_ name: String) -> [Object] {
            let items = root[name] as! [Object]
            TestSupport.expect(!items.isEmpty, "Vector section \(name) is empty")
            counts[name] = items.count
            return items
        }

        for item in section("encode") {
            let text = item["text"] as! String
            TestSupport.expect(encoder.encode(text) == item["tokens"] as! [Int],
                               "encode \(text.debugDescription): got \(encoder.encode(text))")
        }

        for item in section("validation") {
            let text = item["text"] as! String
            let strength = Float(item["strength"] as? Double ?? 1)
            let result = DictionaryValidation.validate(text: text, strength: strength, encoder: encoder)
            if item["ok"] as! Bool {
                guard case .success(let entry) = result else { fatalError("validation \(text.debugDescription): \(result)") }
                DictionaryTests.expectScalars(entry.text, item["normalized"] as! String)
                TestSupport.expectEqual(entry.strength, strength)
            } else {
                guard case .failure(let error) = result else { fatalError("validation \(text.debugDescription) must fail") }
                TestSupport.expectEqual(error.rawValue, item["error"] as! String)
            }
        }

        for item in section("phrases") {
            let entries = (item["entries"] as! [Object]).map(entry)
            let expected = (item["phrases"] as! [Object]).map { ($0["tokens"] as! [Int], Float($0["strength"] as! Double)) }
            let actual = BiasGraph.phrases(entries: entries, encoder: encoder)
                .sorted { $0.tokens.lexicographicallyPrecedes($1.tokens) }
            TestSupport.expect(actual.map(\.tokens) == expected.map(\.0) && actual.map(\.strength) == expected.map(\.1),
                               "phrases \(item["name"]!): got \(actual)")
        }

        for item in section("graph") {
            let graph = try! BiasGraph(phrases: phrases(item["phrases"]), tokens: 1024)
            for step in item["steps"] as! [Object] {
                var state = BiasGraph.root
                for token in step["path"] as! [Int] where token >= 0 { state = graph.step(state, token).state }
                let bonus = graph.step(state, step["token"] as! Int).bonus
                DictionaryTests.expectULP(bonus, Float(step["bonus"] as! Double))
            }
        }

        for item in section("decision") {
            let graph = try! BiasGraph(phrases: phrases(item["phrases"]), tokens: 1024)
            var state = BiasGraph.root
            for token in item["path"] as! [Int] where token >= 0 { state = graph.step(state, token).state }
            var values: [Int: Float] = [:]
            for (key, value) in item["logits"] as! Object { values[Int(key)!] = Float(value as! Double) }
            let logits = DictionaryTests.decisionLogits(values)
            let token = logits.withUnsafeBufferPointer { graph.biasedArgmax(state: state, logits: $0.baseAddress!) }
            TestSupport.expect(token == item["expected_token"] as! Int, "decision \(item["name"]!): got \(token)")
        }

        for item in section("casing") {
            let entries = (item["entries"] as! [String]).map { DictionaryEntry(text: $0, strength: 1) }
            DictionaryTests.expectScalars(CasingRestorer.apply(item["transcript"] as! String, entries: entries),
                                          item["expected"] as! String)
        }

        for item in section("candidates") {
            let found = CorrectionCandidates.find(
                before: item["before"] as! String, after: item["after"] as! String,
                dictionary: (item["dictionary"] as! [String]).map { DictionaryEntry(text: $0, strength: 1) },
                ignore: Set((item["ignore"] as! [String]).map(DictionaryKey.init)), encoder: encoder)
            let expected = (item["expected"] as! [Object]).map { candidate -> CorrectionCandidate in
                let range = candidate["before_range"] as! [Int]
                return CorrectionCandidate(surface: candidate["surface"] as! String,
                                           kind: CorrectionKind(rawValue: candidate["kind"] as! String)!,
                                           beforeRange: range[0]..<range[1],
                                           beforeWords: (candidate["before_words"] as! [String]).map { Array($0.unicodeScalars) })
            }
            TestSupport.expect(found == expected, "candidates \((item["before"] as! String).prefix(60)): got \(found)")
        }

        for item in section("verify") {
            let before = item["before"] as! String, after = item["after"] as! String, base = item["B"] as! String
            let found = CorrectionCandidates.find(before: before, after: after, dictionary: [], ignore: [], encoder: encoder)
            let index = item["candidate_index"] as! Int
            TestSupport.expect(found.indices.contains(index), "verify \(item["name"]!): no candidate \(index)")
            let candidate = found[index]
            let decoded = item["N_by_strength"] as! [String: String]
            var accepted: Float?
            if candidate.kind == .casing {
                accepted = DictionaryValidation.defaultStrength
            } else {
                for strength in VerifyDecision.strengths {
                    let n = decoded[strengthKey(strength)] ?? base
                    if VerifyDecision.accepts(typed: before, candidate: candidate, base: base, decoded: n) {
                        accepted = strength
                        break
                    }
                }
            }
            let expected = (item["expected_strength"] as? Double).map(Float.init)
            TestSupport.expect(accepted == expected, "verify \(item["name"]!): got \(String(describing: accepted))")
        }

        // Pin P6: stored identity and ignore keys.
        for item in section("keys") {
            let scalars = Array((item["key"] as! String).unicodeScalars)
            let key = DictionaryKey(folded: scalars)
            TestSupport.expect(key.isValid == item["valid"] as! Bool, "key \(scalars.count) scalars: got \(key.isValid)")
            if let from = item["from"] as? String {
                TestSupport.expect(DictionaryKey(from) == key, "fold(from) must equal the key")
            }
            // Valid keys round-trip through storage; invalid ones are never saved or loaded.
            var dictionary = CustomDictionary()
            let saved = dictionary.addIgnore(key) == nil
            TestSupport.expect(saved == key.isValid, "Only valid keys are saved")
            let json = try! JSONSerialization.data(withJSONObject: ["version": 1, "ignore": [item["key"] as! String]])
            let loaded = DictionaryStorage.load(entriesData: nil, ignoreData: json, encoder: encoder)
            TestSupport.expect(loaded.isSuccess == key.isValid, "Only valid keys load")
        }

        for name in ["encode", "validation", "phrases", "graph", "decision", "casing", "candidates", "verify", "keys"] {
            TestSupport.expect(counts[name] != nil, "Vector section \(name) was not run")
        }
    }

    private static func entry(_ object: Object) -> DictionaryEntry {
        DictionaryEntry(text: object["text"] as! String, strength: Float(object["strength"] as! Double))
    }

    private static func phrases(_ value: Any?) -> [(tokens: [Int], strength: Float)] {
        (value as! [Object]).map { ($0["tokens"] as! [Int], Float($0["strength"] as! Double)) }
    }

    /// The vector keys: "1.0", "1.41", "2.0", "2.83", "4.0", "5.66", "8.0".
    private static func strengthKey(_ strength: Float) -> String {
        let text = DictionaryValidation.label(strength).dropFirst()
        return text.contains(".") ? String(text) : text + ".0"
    }
}
