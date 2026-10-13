import Foundation

/// Contract tests for the custom dictionary (DESIGN v2 §1 and §3, pins P1-P5).
/// All text is invented. The shared vectors live in linux/testdata and are
/// found relative to this file.
enum DictionaryTests {
    static func run() {
        testTextUnits()
        testEncoderHandCases()
        testValidation()
        testDictionaryRules()
        testStorage()
        testGraphHandCases()
        testDecisionHandCases()
        testSurfacesAndBuild()
        testBiasedDecode()
        testCasingHandCases()
        testCandidateHandCases()
        testVerifyHandCases()
        testSuggestionBudgets()
        testRetainedSessions()
        testSpanTracking()
        testWatchLifecycle()
        testSuggestionGate()
        testSuggestionCleanup()
        testKeyValidity()
        testVerificationOrder()
        testCancelDuringRead()
        testStaleDelayedPaste()
        testEligibilityWindow()
        testDeadlineStopsReads()
        testFullDictionaryOffersNothing()
        DictionaryVectorTests.run()
    }

    // MARK: - Shared helpers

    static func s(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    static func expectScalars(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expect(s(actual) == s(expected), "Expected \(expected.debugDescription), got \(actual.debugDescription)",
                           file: file, line: line)
    }

    /// Floats within one unit in the last place, as the vectors require.
    static func expectULP(_ actual: Float, _ expected: Float, file: StaticString = #filePath, line: UInt = #line) {
        let close = actual == expected
            || (actual.sign == expected.sign && actual.isFinite && expected.isFinite
                && (actual.bitPattern > expected.bitPattern ? actual.bitPattern - expected.bitPattern
                    : expected.bitPattern - actual.bitPattern) <= 1)
        TestSupport.expect(close, "Expected \(expected) within 1 ULP, got \(actual)", file: file, line: line)
    }

    /// Every single scalar a test needs, so encodability depends only on the case.
    static let testEncoder: BPEEncoder = {
        var pieces = ["<unk>", "▁"]
        pieces += "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#ïé'.,".unicodeScalars.map { String($0) }
        pieces += ["▁k", "ub", "er", "▁n", "ix", "os"]
        return BPEEncoder(pieces: pieces)
    }()

    static func entry(_ text: String, _ strength: Float = 1) -> DictionaryEntry {
        DictionaryEntry(text: text, strength: strength)
    }

    // MARK: - §1.0 text units

    private static func testTextUnits() {
        // Full lowercase mapping: one scalar can fold to two.
        TestSupport.expect(DictionaryText.fold(s("İX")) == s("i\u{307}x"), "fold must use the full lowercase mapping")
        TestSupport.expect(DictionaryText.fold(s("NixOS")) == s("nixos"), "fold lowercases every scalar")
        TestSupport.expect(DictionaryText.upper1(s("ßtraße")) == s("SStraße"), "upper1 maps only the first scalar, fully")
        TestSupport.expect(DictionaryText.upper1(s("")) == [], "upper1 of empty is empty")
        // Canonically equivalent strings stay distinct: identity is by scalars.
        TestSupport.expect(DictionaryText.fold(s("e\u{301}")) != DictionaryText.fold(s("é")), "No normalization is applied")
        for scalar in s("aZé_\u{301}5") {
            TestSupport.expect(DictionaryText.isWordCharacter(scalar), "\(scalar) is a word character")
        }
        for scalar in s(" -#+/@.'") {
            TestSupport.expect(!DictionaryText.isWordCharacter(scalar), "\(scalar) is not a word character")
        }
        TestSupport.expect(DictionaryText.isWhitespace("\u{3000}") && DictionaryText.isWhitespace("\n"), "White_Space")
        TestSupport.expect(DictionaryText.norm(s("«Kubernetes!»")) == s("kubernetes"), "norm strips edge punctuation")
        TestSupport.expect(DictionaryText.norm(s("C#")) == s("c#"), "Technical symbols are kept")
        TestSupport.expect(DictionaryText.norm(s("—")) == [], "Pure edge punctuation norms to empty")
        TestSupport.expect(DictionaryText.words(s(" a\tb\u{3000}c \n")) == [s("a"), s("b"), s("c")], "Words split on any whitespace")
    }

    // MARK: - §1.3 BPE (P4)

    private static func testEncoderHandCases() {
        let encoder = BPEEncoder(pieces: ["<unk>", "▁t", "he", "▁the", "▁", "t", "h", "e", "c", "a", "at", "▁c", "aa"])
        // ▁ t h e ▁ c a t → ▁t, he, ▁the, at, ▁c: lowest id merges first.
        TestSupport.expectEqual(encoder.encode("the cat"), [3, 11, 10])
        // Equal pairs merge leftmost first.
        TestSupport.expectEqual(encoder.encode("aaa"), [4, 12, 9])
        // A run of non-pieces is one <unk> (P4); separated runs are separate.
        TestSupport.expectEqual(encoder.encode("tzzh"), [1, 0, 6])
        TestSupport.expectEqual(encoder.encode("tzhz"), [1, 0, 6, 0])
        // P7: the dummy prefix applies to empty text too, so "" encodes as "▁".
        TestSupport.expectEqual(encoder.encode(""), [4])
        TestSupport.expect(!encoder.encodesWithoutUnknown("tz"), "<unk> makes text unencodable")
        TestSupport.expect(encoder.encodesWithoutUnknown("the cat"), "Known pieces encode")
        // Pieces are matched by exact scalars: a decomposed é is not the precomposed piece.
        let accents = BPEEncoder(pieces: ["<unk>", "▁", "é"])
        TestSupport.expectEqual(accents.encode("é"), [1, 2])
        TestSupport.expectEqual(accents.encode("e\u{301}"), [1, 0])
        // Duplicate pieces keep their lowest id; <unk> itself is never produced from text.
        let duplicate = BPEEncoder(pieces: ["<unk>", "▁", "x", "x", "<", "u", "n", "k", ">"])
        TestSupport.expectEqual(duplicate.encode("x"), [1, 2])
    }

    // MARK: - §1.1 validation

    private static func testValidation() {
        let encoder = testEncoder
        func validate(_ text: String, _ strength: Float = 1) -> Result<DictionaryEntry, DictionaryEntryError> {
            DictionaryValidation.validate(text: text, strength: strength, encoder: encoder)
        }
        switch validate("  New\t\u{3000}York  ") {
        case .success(let entry): expectScalars(entry.text, "New York")
        case .failure(let error): fatalError("Valid text rejected: \(error)")
        }
        TestSupport.expect(validate("") == .failure(.empty), "Empty text")
        TestSupport.expect(validate(" \n ") == .failure(.empty), "Whitespace-only text")
        TestSupport.expect(validate("a b c d e f g h") .isSuccess, "Eight words are allowed")
        TestSupport.expect(validate("a b c d e f g h i") == .failure(.tooManyWords), "Nine words are not")
        TestSupport.expect(validate(String(repeating: "a", count: 100)).isSuccess, "100 scalars are allowed")
        TestSupport.expect(validate(String(repeating: "a", count: 101)) == .failure(.tooLong), "101 scalars are not")
        // Scalars, not characters: five graphemes that are ten scalars.
        TestSupport.expect(validate(String(repeating: "e\u{301}", count: 51)) == .failure(.tooLong), "Limits count scalars")
        TestSupport.expect(validate("12 34") == .failure(.noLetter), "At least one letter")
        TestSupport.expect(validate("naïve—x") == .failure(.unencodable), "Unencodable text")
        TestSupport.expect(validate("C#", 0.25).isSuccess && validate("C#", 4).isSuccess, "Strength bounds are inclusive")
        for bad: Float in [0.24, 4.01, .nan, .infinity, -1] {
            TestSupport.expect(validate("C#", bad) == .failure(.invalidStrength), "Strength \(bad) is invalid")
        }
        // Without a vocabulary the encodability check cannot run; the rest still applies.
        TestSupport.expect(DictionaryValidation.validate(text: "naïve—x", strength: 1, encoder: nil).isSuccess,
                           "No vocabulary skips only the encodability check")
        TestSupport.expectEqual(DictionaryValidation.presets, [0.5, 1, 1.41, 2, 2.83, 4])
    }

    private static func testDictionaryRules() {
        var dictionary = CustomDictionary()
        TestSupport.expect(dictionary.upsert(entry("NixOS")) == nil, "Add")
        TestSupport.expect(dictionary.upsert(entry("nixos", 2)) == nil, "Same key replaces")
        TestSupport.expectEqual(dictionary.entries.count, 1)
        expectScalars(dictionary.entries[0].text, "nixos")
        TestSupport.expectEqual(dictionary.entries[0].strength, 2)
        TestSupport.expect(dictionary.contains(DictionaryKey("NIXOS")), "Identity is the folded text")
        TestSupport.expect(!dictionary.contains(DictionaryKey("nixos ")), "Identity compares exact scalars")
        TestSupport.expect(dictionary.remove(DictionaryKey("NixOS")), "Remove by key")
        TestSupport.expect(!dictionary.remove(DictionaryKey("NixOS")), "Removing twice reports not found")

        for index in 0..<DictionaryValidation.capacity {
            TestSupport.expect(dictionary.upsert(entry("word\(index)x")) == nil, "Within capacity")
        }
        TestSupport.expect(dictionary.upsert(entry("overflow")) == .full, "Capacity is 1000 entries")
        TestSupport.expect(dictionary.upsert(entry("WORD0X", 3)) == nil, "Replacing at capacity is allowed")

        var ignore = CustomDictionary()
        TestSupport.expect(ignore.addIgnore(DictionaryKey("Eldar")) == nil, "Ignore")
        TestSupport.expect(ignore.addIgnore(DictionaryKey("eldar")) == nil, "Ignoring twice is idempotent")
        TestSupport.expectEqual(ignore.ignore.count, 1)
        for index in 1..<DictionaryValidation.ignoreCapacity {
            TestSupport.expect(ignore.addIgnore(DictionaryKey("w\(index)")) == nil, "Within ignore capacity")
        }
        TestSupport.expect(ignore.addIgnore(DictionaryKey("one more")) == .full, "Ignore capacity is 1000")
        TestSupport.expect(ignore.removeIgnore(DictionaryKey("ELDAR")), "Unignore by key")
    }

    // MARK: - §3.2 storage

    private static func testStorage() {
        let encoder = testEncoder
        func load(_ entries: String?, _ ignore: String?) -> Result<CustomDictionary, DictionaryStorageError> {
            DictionaryStorage.load(entriesData: entries.map { Data($0.utf8) }, ignoreData: ignore.map { Data($0.utf8) },
                                   encoder: encoder)
        }
        switch load(nil, nil) {
        case .success(let dictionary): TestSupport.expect(dictionary.entries.isEmpty && dictionary.ignore.isEmpty, "Missing is empty")
        case .failure: fatalError("Missing data must load as empty")
        }
        let valid = #"{"version":1,"entries":[{"text":"NixOS","strength":1.41},{"text":"New York","strength":1}]}"#
        let ignore = #"{"version":1,"ignore":["eldar"]}"#
        guard case .success(let loaded) = load(valid, ignore) else { fatalError("Valid storage must load") }
        TestSupport.expectEqual(loaded.entries.map(\.strength), [1.41, 1])
        TestSupport.expect(loaded.ignore == [DictionaryKey("eldar")], "Ignore keys load")
        // Round trip through the writer.
        let encoded = DictionaryStorage.encode(loaded)
        guard case .success(let reloaded) = DictionaryStorage.load(entriesData: encoded.entries, ignoreData: encoded.ignore,
                                                                    encoder: encoder) else {
            fatalError("Written storage must load")
        }
        TestSupport.expect(reloaded == loaded, "Storage round-trips")

        let corrupt: [(String?, String?)] = [
            ("not json", nil),
            (#"{"version":2,"entries":[]}"#, nil),
            (#"{"entries":[]}"#, nil),
            (#"{"version":1,"entries":[{"text":"NixOS","strength":9}]}"#, nil),
            (#"{"version":1,"entries":[{"text":"  NixOS","strength":1}]}"#, nil),
            (#"{"version":1,"entries":[{"text":"NixOS","strength":1},{"text":"nixos","strength":2}]}"#, nil),
            (#"{"version":1,"entries":[{"text":"naïve—x","strength":1}]}"#, nil),
            (#"{"version":1,"entries":[{"text":"NixOS"}]}"#, nil),
            (nil, #"{"version":1,"ignore":["Eldar"]}"#),
            (nil, #"{"version":1,"ignore":["eldar","eldar"]}"#),
            (nil, #"{"version":1,"ignore":[""]}"#),
            (nil, #"["eldar"]"#),
        ]
        for (entries, ignore) in corrupt {
            TestSupport.expect(load(entries, ignore) == .failure(.unreadable), "Corrupt storage must be rejected")
        }
        let tooMany = "{\"version\":1,\"entries\":[" + (0...DictionaryValidation.capacity)
            .map { "{\"text\":\"w\($0)x\",\"strength\":1}" }.joined(separator: ",") + "]}"
        TestSupport.expect(load(tooMany, nil) == .failure(.unreadable), "More than 1000 entries is corrupt")
    }

    // MARK: - §1.2 graph (hand cases, mandatory)

    private static func expectedBonus(_ score: Double) -> Float { Float(1.414 * score) }

    private static func bonus(_ graph: BiasGraph, path: [Int], token: Int) -> Float {
        var state = BiasGraph.root
        for step in path where step >= 0 { state = graph.step(state, step).state }
        return graph.step(state, token).bonus
    }

    private static func testGraphHandCases() {
        func own(_ sigma: Double, _ depth: Double) -> Double { sigma * (1 + 3 * log(depth)) }
        let g1 = try! BiasGraph(phrases: [([1, 2, 3], 1)], tokens: 1024)
        expectULP(bonus(g1, path: [], token: 1), expectedBonus(own(1, 1)))
        expectULP(bonus(g1, path: [1], token: 2), expectedBonus(own(1, 2)))
        expectULP(bonus(g1, path: [1, 2], token: 3), expectedBonus(own(1, 3)))
        expectULP(bonus(g1, path: [], token: 9), 0)

        let g2 = try! BiasGraph(phrases: [([1, 2, 3], 0.25), ([2, 3], 4)], tokens: 1024)
        expectULP(bonus(g2, path: [], token: 1), expectedBonus(own(0.25, 1)))
        expectULP(bonus(g2, path: [1], token: 2), expectedBonus(max(own(0.25, 2), own(4, 1))))
        expectULP(bonus(g2, path: [1, 2], token: 3), expectedBonus(max(own(0.25, 3), own(4, 2))))
        // Order-invariant.
        let g2r = try! BiasGraph(phrases: [([2, 3], 4), ([1, 2, 3], 0.25)], tokens: 1024)
        expectULP(bonus(g2r, path: [1, 2], token: 3), bonus(g2, path: [1, 2], token: 3))

        let g3 = try! BiasGraph(phrases: [([5, 6], 1), ([5, 6], 2)], tokens: 1024)
        expectULP(bonus(g3, path: [], token: 5), expectedBonus(own(2, 1)))
        expectULP(bonus(g3, path: [5], token: 6), expectedBonus(own(2, 2)))

        let g4 = try! BiasGraph(phrases: [([1, 2], 1)], tokens: 1024)
        expectULP(bonus(g4, path: [1, -1], token: 2), expectedBonus(own(1, 2)))
        TestSupport.expectEqual(g4.step(g4.step(BiasGraph.root, 1).state, 1024).bonus, 0)
        let afterOne = g4.step(BiasGraph.root, 1).state
        TestSupport.expectEqual(g4.step(afterOne, 1024).state, afterOne)
        expectULP(bonus(g4, path: [1, 7], token: 2), 0)

        // Failure transitions land on the longest suffix state.
        let suffix = try! BiasGraph(phrases: [([1, 2, 3], 1), ([2, 3, 4], 1)], tokens: 1024)
        expectULP(bonus(suffix, path: [1, 2, 3], token: 4), expectedBonus(own(1, 3)))

        for invalid: [([Int], Float)] in [[([1024], 1)], [([-2], 1)], [([1], .nan)]] {
            TestSupport.expect((try? BiasGraph(phrases: invalid, tokens: 1024)) == nil, "Invalid phrases are rejected")
        }
        TestSupport.expect((try! BiasGraph(phrases: [], tokens: 1024)).isEmpty, "No phrases is empty")
    }

    static func decisionLogits(_ values: [Int: Float]) -> [Float] {
        var logits = [Float](repeating: -100, count: 1030)
        for (index, value) in values { logits[index] = value }
        return logits
    }

    private static func testDecisionHandCases() {
        let logits = decisionLogits([1024: 5, 1: 3])
        let d1 = try! BiasGraph(phrases: [([1], 1)], tokens: 1024)
        let d2 = try! BiasGraph(phrases: [([1], 2)], tokens: 1024)
        let empty = try! BiasGraph(phrases: [], tokens: 1024)
        logits.withUnsafeBufferPointer { buffer in
            TestSupport.expectEqual(d1.biasedArgmax(state: BiasGraph.root, logits: buffer.baseAddress!), 1024)
            TestSupport.expectEqual(d2.biasedArgmax(state: BiasGraph.root, logits: buffer.baseAddress!), 1)
            TestSupport.expectEqual(empty.biasedArgmax(state: BiasGraph.root, logits: buffer.baseAddress!), 1024)
        }
        // First maximum wins, after the bonus is added in f64.
        let tie = decisionLogits([1: 1, 2: 1])
        tie.withUnsafeBufferPointer { buffer in
            TestSupport.expectEqual(empty.biasedArgmax(state: BiasGraph.root, logits: buffer.baseAddress!), 1)
        }
    }

    private static func testSurfacesAndBuild() {
        let surfaces = BiasGraph.surfaces(of: "new York city")
        TestSupport.expect(surfaces == [s("new York city"), s("new york city"), s("New York city"), s("New York City")],
                           "Surfaces: text, fold, upper1, each word upper1; got \(surfaces)")
        let deduplicated = BiasGraph.surfaces(of: "kubernetes")
        TestSupport.expect(deduplicated == [s("kubernetes"), s("Kubernetes")], "Duplicate surfaces are removed")
        TestSupport.expect(BiasGraph.build(entries: [], encoder: testEncoder) == nil, "An empty dictionary builds no graph")
        // Unencodable optional variants are skipped, never the whole entry.
        let lowerOnly = BPEEncoder(pieces: ["<unk>", "▁", "k", "u", "b", "e"])
        let graph = BiasGraph.build(entries: [entry("Kube")], encoder: lowerOnly)
        TestSupport.expect(graph != nil, "The folded variant still encodes")
        TestSupport.expect(graph.map { bonus($0, path: [1, 2, 3, 4], token: 5) > 0 } == true, "Folded variant is boosted")
    }

    // MARK: - §3.1 decoder hook

    private static func testBiasedDecode() {
        // Deterministic synthetic logits; the unbiased path returns their plain argmax.
        var generator: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int(generator >> 40) % 2000 - 1000) / 100
        }
        let frames = 40
        var table: [[Float]] = []
        for frame in 0..<frames * 12 {
            var row = (0..<1030).map { _ in next() }
            row[1024] += frame % 3 == 0 ? 0 : 12  // mostly blanks, as real audio
            table.append(row)
        }
        func run(bias: BiasGraph?) -> [Int] {
            var calls = 0
            let buffer = FloatBuffer(count: 1030)
            func argmax(_ row: ArraySlice<Float>) -> Int {
                var best = row.startIndex
                for index in row.indices where row[index] > row[best] { best = index }
                return best - row.startIndex
            }
            if let bias {
                return try! LocalParakeetCore.decode(length: frames, bias: bias, predict: { _ in }, joint: { _ in
                    let row = table[calls % table.count]; calls += 1
                    row.withUnsafeBufferPointer { buffer.pointer.update(from: $0.baseAddress!, count: 1030) }
                    return (UnsafePointer(buffer.pointer), argmax(row[1025..<1030]))
                }, check: {})
            }
            return try! LocalParakeetCore.decode(length: frames, predict: { _ in }, joint: { _ in
                let row = table[calls % table.count]; calls += 1
                return (argmax(row[0..<1025]), argmax(row[1025..<1030]))
            }, check: {})
        }
        let plain = run(bias: nil)
        TestSupport.expect(!plain.isEmpty, "Synthetic decode emits tokens")
        TestSupport.expectEqual(run(bias: try! BiasGraph(phrases: [], tokens: 1024)), plain)
        // Unrelated phrases (tokens never near the argmax) do not change the result.
        TestSupport.expectEqual(run(bias: try! BiasGraph(phrases: [([1023, 1022], 0.25)], tokens: 1024)), plain)
        TestSupport.expect(run(bias: try! BiasGraph(phrases: [([7], 4)], tokens: 1024)) != plain, "A strong boost changes decoding")

        // State advances on emissions only, so a two-token phrase gets its depth-2 bonus.
        let graph = try! BiasGraph(phrases: [([1, 2], 1)], tokens: 1024)
        let scripted: [[Int: Float]] = [[1: 1, 1024: 0, 1025: 5], [1024: 1, 1025: 5], [2: 0, 1024: 4, 1025: 5]]
        var step = 0
        var predicted: [Int] = []
        let buffer = FloatBuffer(count: 1030)
        let tokens = try! LocalParakeetCore.decode(length: 3, bias: graph, predict: { predicted.append($0) }, joint: { _ in
            let row = decisionLogits(scripted[step]); step += 1
            row.withUnsafeBufferPointer { buffer.pointer.update(from: $0.baseAddress!, count: 1030) }
            return (UnsafePointer(buffer.pointer), 1)
        }, check: {})
        // Frame 3: 0 + 1.414 * (1 + 3 ln 2) = 4.35 beats the blank's 4.
        TestSupport.expectEqual(tokens, [1, 2])
        TestSupport.expectEqual(predicted, [1024, 1, 2])
        TestSupport.expect((try? LocalParakeetCore.decode(length: 1, bias: graph, predict: { _ in }, joint: { _ in
            (UnsafePointer(buffer.pointer), 5)
        }, check: {})) == nil, "Invalid durations are rejected on the biased path")
        TestSupport.expect((try? LocalParakeetCore.decode(length: 1, bias: graph, predict: { _ in }, joint: { _ in
            (UnsafePointer(buffer.pointer), 1)
        }, check: { throw CancellationError() })) == nil, "Cancellation is honoured on the biased path")
    }

    // MARK: - §1.4 casing restoration

    private static func testCasingHandCases() {
        let cases: [([String], String, String)] = [
            (["NixOS"], "i installed nixos on my laptop.", "i installed NixOS on my laptop."),
            (["iPhone"], "Iphone is new. my iphone works", "iPhone is new. my iPhone works"),
            (["kubectl"], "Kubectl get pods", "Kubectl get pods"),
            (["New York", "New York City"], "i live in new york city now", "i live in New York City now"),
            (["Rust"], "trusty rust_lang rust.", "trusty rust_lang Rust."),
            // Multi-word entries match single ASCII spaces only.
            (["New York"], "new  york and new\tyork", "new  york and new\tyork"),
            // A combining mark after the match is a word character.
            (["Rust"], "rust\u{301} rust", "rust\u{301} Rust"),
            // Replaced text is never rescanned; ties at equal length go by scalar order.
            (["AB", "Ab"], "ab", "AB"),
        ]
        for (entries, input, expected) in cases {
            expectScalars(CasingRestorer.apply(input, entries: entries.map { entry($0) }), expected)
        }
    }

    // MARK: - §1.5 candidates (P1, P2, P5)

    static func candidates(_ before: String, _ after: String, dictionary: [String] = [], ignore: [String] = []) -> [CorrectionCandidate] {
        CorrectionCandidates.find(before: before, after: after, dictionary: dictionary.map { entry($0) },
                                  ignore: Set(ignore.map(DictionaryKey.init)), encoder: testEncoder)
    }

    private static func testCandidateHandCases() {
        let kubernetes = candidates("we deployed it on cooper netties yesterday", "we deployed it on Kubernetes yesterday")
        TestSupport.expectEqual(kubernetes.count, 1)
        expectScalars(kubernetes[0].surface, "Kubernetes")
        TestSupport.expectEqual(kubernetes[0].kind, .replace)
        TestSupport.expectEqual(kubernetes[0].beforeRange, 4..<6)
        TestSupport.expect(kubernetes[0].beforeWords == [s("cooper"), s("netties")], "Before words are norms")

        TestSupport.expect(candidates("please send the report today", "can you email me the summary").isEmpty, "Rewrite")
        let nixos = candidates("nixos", "NixOS")
        TestSupport.expect(nixos.count == 1 && nixos[0].kind == .casing, "Casing candidate")
        expectScalars(nixos[0].surface, "NixOS")
        let sharp = candidates("i write sea sharp code", "i write C# code")
        TestSupport.expect(sharp.count == 1 && sharp[0].kind == .replace, "C# keeps its symbol")
        expectScalars(sharp[0].surface, "C#")
        TestSupport.expect(candidates("ping the cooper netties team", "ping the Kubernetes team", dictionary: ["kubernetes"]).isEmpty,
                           "Known words are not suggested")
        TestSupport.expect(candidates("ping the cooper netties team", "ping the Kubernetes team", ignore: ["kubernetes"]).isEmpty,
                           "Ignored words are not suggested")
        TestSupport.expect(candidates("hello world", "hello big world").isEmpty, "Pure insertions do not qualify")
        let naive = candidates("the naive approach", "the Naïve approach")
        TestSupport.expect(naive.count == 1 && naive[0].kind == .replace, "naive ≠ naïve")
        expectScalars(naive[0].surface, "Naïve")
        // P1: a capitalised first letter alone is not a casing candidate.
        TestSupport.expect(candidates("the plan works", "The plan works").isEmpty, "Sentence-start capitalisation")
        TestSupport.expect(candidates("we use kubernetes", "we use Kubernetes").isEmpty, "Initial capital only")
        let newYork = candidates("i love new york", "i love New York")
        TestSupport.expect(newYork.count == 1 && newYork[0].kind == .casing, "Two-word casing block")
        expectScalars(newYork[0].surface, "New York")
        TestSupport.expectEqual(newYork[0].beforeRange, 2..<4)
        // Outer edge punctuation is stripped from the surface only.
        let quoted = candidates("try cooper netties.", "try “Kubernetes.”")
        TestSupport.expect(quoted.count == 1, "Quoted replacement")
        expectScalars(quoted[0].surface, "Kubernetes")
        // Short corrections are not rewrites; four words of five are.
        TestSupport.expectEqual(candidates("cart", "chart").count, 1)
        TestSupport.expect(candidates("a b c d e", "a v w x y").isEmpty, "Over half the words changed")
        // Blocks of more than three words do not qualify; other blocks still do.
        TestSupport.expect(candidates("one two three four five six seven eight nine ten",
                                      "one zwei drei vier funf six seven eight nine ten").isEmpty, "Four-word block")
        // Bounds are checked before any alignment.
        let long = Array(repeating: "word", count: 201).joined(separator: " ")
        TestSupport.expect(candidates(long, long + "s").isEmpty, "More than 200 words")
        let heavy = String(repeating: "é", count: 2049)
        TestSupport.expect(candidates(heavy, "x").isEmpty, "More than 4096 UTF-8 bytes")
        // Unencodable surfaces never become candidates.
        TestSupport.expect(candidates("the cart now", "the ¢art now").isEmpty, "Unencodable surface")
        // Multiple qualifying blocks in text order.
        let two = candidates("use the alder package and review the cart patch", "use the Eldar package and review the chart patch")
        TestSupport.expect(two.map { s($0.surface) } == [s("Eldar"), s("chart")],
                           "Blocks are returned in text order")

        // P2 alignment order: diagonal, then deletion, then insertion.
        let ops = WordAlignment.align([s("a"), s("b")], [s("c")])
        TestSupport.expect(ops == [.delete(a: 0, beforeB: 0), .substitute(a: 1, b: 0)], "Tie order, got \(ops)")
        let ops2 = WordAlignment.align([s("c")], [s("a"), s("b")])
        TestSupport.expect(ops2 == [.insert(b: 0, beforeA: 0), .substitute(a: 0, b: 1)], "Tie order, got \(ops2)")
    }

    // MARK: - §1.6 verification (P3)

    static func verifyStrength(base: String, before: String, after: String, candidateIndex: Int = 0,
                               decoded: [Float: String]) -> Float? {
        let found = candidates(before, after)
        guard found.indices.contains(candidateIndex) else { return nil }
        let candidate = found[candidateIndex]
        for strength in VerifyDecision.strengths {
            let n = decoded[strength] ?? base
            if VerifyDecision.accepts(typed: before, candidate: candidate, base: base, decoded: n) { return strength }
        }
        return nil
    }

    private static func testVerifyHandCases() {
        let v1before = "we deployed it on cooper netties yesterday"
        let v1after = "we deployed it on Kubernetes yesterday"
        TestSupport.expectEqual(verifyStrength(base: v1before, before: v1before, after: v1after,
                                               decoded: [1.41: "we deployed it on kubernetes yesterday"]), 1.41)
        let v2 = "use the alder package and review the alder patch"
        TestSupport.expectEqual(verifyStrength(base: v2, before: v2, after: "use the Eldar package and review the alder patch",
                                               decoded: [1.0: "use the alder package and review the eldar patch",
                                                         1.41: "use the eldar package and review the eldar patch"]), 1.41)
        TestSupport.expectEqual(verifyStrength(base: "ship the cart now", before: "ship the cart now", after: "ship the chart now",
                                               decoded: [1.0: "ship the cart chart now", 1.41: "ship the chart now"]), 1.41)
        let monday = "we deploy to kubernetes on monday after lunch"
        TestSupport.expectEqual(verifyStrength(base: "we deploy to cooper netties on friday after lunch", before: v1before,
                                               after: v1after,
                                               decoded: Dictionary(uniqueKeysWithValues: VerifyDecision.strengths.map { ($0, monday) })),
                                nil)
        // The typed text may carry post-processing (a tag, punctuation); the block maps through alignment.
        TestSupport.expectEqual(verifyStrength(base: "ship the cart now", before: "[dictated] Ship the cart now.",
                                               after: "[dictated] Ship the chart now.",
                                               decoded: [2.0: "Ship the chart now"]), 2.0)
        // The block's words must match B exactly; otherwise reject.
        TestSupport.expectEqual(verifyStrength(base: "ship the kart now", before: "ship the cart now", after: "ship the chart now",
                                               decoded: [1.0: "ship the chart now"]), nil)
        // P3: an extra N word just past the window's end counts as a window edit.
        // E = a b chart c d e f; window [0, 5); "zz" before E[5] is inside it.
        TestSupport.expectEqual(verifyStrength(base: "a b cart c d e f", before: "a b cart c d e f", after: "a b chart c d e f",
                                               decoded: [1.0: "a b chart c d zz e f", 1.41: "a b chart c d e f"]), 1.41)
    }

    // MARK: - §1.6 budgets

    private static func testSuggestionBudgets() {
        let typed = "one two three four five six seven eight nine ten"
        let edited = "one zwei three vier five sechs seven acht nine ten"
        func find(clock: @escaping () -> TimeInterval = { 0 }, cancelled: @escaping () -> Bool = { false },
                  decode: @escaping (DictionaryEntry) -> String?) -> DictionarySuggestion? {
            DictionarySuggestionFinder.find(typed: typed, edited: edited, base: typed, dictionary: [], ignore: [],
                                            encoder: testEncoder, now: clock, isCancelled: cancelled, decode: decode)
        }
        var calls: [DictionaryEntry] = []
        TestSupport.expect(find { calls.append($0); return typed } == nil, "Nothing verifies")
        TestSupport.expectEqual(calls.count, 15)  // three candidates, five strengths each
        TestSupport.expectEqual(calls.prefix(5).map(\.strength), VerifyDecision.strengths)
        expectScalars(calls[5].text, "vier")

        var time: TimeInterval = 0
        calls = []
        TestSupport.expect(find(clock: { time }, decode: { calls.append($0); time += 0.5; return typed }) == nil, "Budget")
        TestSupport.expectEqual(calls.count, 4)  // the 2 s budget is spent before the fifth decode

        calls = []
        TestSupport.expect(find(cancelled: { calls.count >= 2 }, decode: { calls.append($0); return typed }) == nil, "Cancel")
        TestSupport.expectEqual(calls.count, 2)

        calls = []
        let accepted = find { candidate in
            calls.append(candidate)
            return candidate.strength >= 2 ? "one zwei three four five six seven eight nine ten" : typed
        }
        TestSupport.expect(accepted.map { s($0.word) == s("zwei") && $0.strength == 2 && $0.kind == .replace } == true,
                           "First accepted strength wins")
        TestSupport.expectEqual(calls.count, 3)

        calls = []
        let casing = DictionarySuggestionFinder.find(typed: "we run nixos", edited: "we run NixOS", base: "we run nixos",
                                                     dictionary: [], ignore: [], encoder: testEncoder, now: { 0 },
                                                     isCancelled: { false }, decode: { calls.append($0); return nil })
        TestSupport.expect(casing.map { s($0.word) == s("NixOS") && $0.strength == 1 && $0.kind == .casing } == true,
                           "Casing needs no audio")
        TestSupport.expect(calls.isEmpty, "Casing candidates are never decoded")
        // A decode failure ends that candidate without a suggestion.
        TestSupport.expect(find { _ in nil } == nil, "Decode failure")
    }

    // MARK: - §3.4 retained sessions

    private static func testRetainedSessions() {
        let store = CorrectionSessionStore<String>(maxBytes: 100, lifetime: 90)
        let first = store.retain("first", bytes: 10, now: 0)
        TestSupport.expect(first != nil, "Retained")
        TestSupport.expectEqual(store.session(id: first!, now: 1), "first")
        let second = store.retain("second", bytes: 100, now: 2)!
        TestSupport.expect(second != first, "IDs are unique")
        TestSupport.expectEqual(store.session(id: first!, now: 3), nil)  // stale
        TestSupport.expectEqual(store.session(id: second, now: 91.9), "second")
        TestSupport.expectEqual(store.session(id: second, now: 92), nil)  // expired
        TestSupport.expectEqual(store.currentID, nil)

        let third = store.retain("third", bytes: 1, now: 100)!
        store.expire(id: second)  // a stale expiry timer must not drop a newer session
        TestSupport.expectEqual(store.session(id: third, now: 101), "third")
        store.expire(id: third)
        TestSupport.expectEqual(store.session(id: third, now: 101), nil)

        let fourth = store.retain("fourth", bytes: 1, now: 200)!
        TestSupport.expect(store.retain("huge", bytes: 101, now: 201) == nil, "Over the byte limit is not retained")
        TestSupport.expectEqual(store.session(id: fourth, now: 202), nil)  // and the previous session is gone
        let fifth = store.retain("fifth", bytes: 1, now: 300)!
        store.discard()
        TestSupport.expectEqual(store.session(id: fifth, now: 300), nil)
        TestSupport.expectEqual(CorrectionSessionStore<String>.defaultMaxBytes, 16 << 20)
        TestSupport.expectEqual(CorrectionSessionStore<String>.defaultLifetime, 90)
    }

    // MARK: - §3.5 span tracking

    private static func begin(_ reader: FakeTextFieldReader, pasted: String, now: TimeInterval = 0) -> Result<CorrectionWatchSession, CorrectionDiscardReason> {
        guard let target = reader.captureFocusedTextField() else { return .failure(.focusChanged) }
        return CorrectionWatchSession.begin(reader: reader, target: target, pasted: pasted, dictationID: 7, now: now)
    }

    private static func watching(_ reader: FakeTextFieldReader, pasted: String) -> CorrectionWatchSession {
        switch begin(reader, pasted: pasted) {
        case .success(let session): return session
        case .failure(let reason): fatalError("Session must begin, got \(reason)")
        }
    }

    /// Polls once per second from `from` until something other than watching happens.
    private static func pollUntilDone(_ session: CorrectionWatchSession, from: Int = 1, to: Int = 70,
                                      each: (Int) -> Void = { _ in }) -> (CorrectionPollOutcome, Int) {
        for second in from...to {
            each(second)
            let outcome = session.poll(now: TimeInterval(second))
            if outcome != .watching { return (outcome, second) }
        }
        return (.watching, to)
    }

    private static func expectFinal(_ outcome: CorrectionPollOutcome, typed: String, edited: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard case .finalize(let final) = outcome else {
            TestSupport.expect(false, "Expected finalize, got \(outcome)", file: file, line: line)
            return
        }
        TestSupport.expect(s(final.typed) == s(typed) && s(final.edited) == s(edited) && final.dictationID == 7,
                           "Expected \(edited.debugDescription), got \(final.edited.debugDescription)", file: file, line: line)
    }

    private static func testSpanTracking() {
        let longAfter = "\nAn unrelated paragraph follows here, long enough to anchor."
        // Empty field: both edges are document sentinels.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("hello wrld. ")
            let session = watching(reader, pasted: "hello wrld. ")
            TestSupport.expect(session.record.before == .documentEdge && session.record.after == .documentEdge, "Sentinels")
            let (outcome, second) = pollUntilDone(session) { if $0 == 2 { reader.replace("wrld", with: "world") } }
            expectFinal(outcome, typed: "hello wrld. ", edited: "hello world. ")
            TestSupport.expectEqual(second, 6)  // edited at 2, quiet for 4 s
        }
        // Anchored on both sides, with an edit in the span only.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = watching(reader, pasted: "ship the cart now. ")
            TestSupport.expect(session.record.before == .text(Array("Intro line.\n".utf16)), "Short before context")
            TestSupport.expect(session.record.after == .text(Array(longAfter.utf16.prefix(40))), "40-unit after context")
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }
            expectFinal(outcome, typed: "ship the cart now. ", edited: "ship the chart now. ")
        }
        // docStart with an after anchor; docEnd with a before anchor.
        do {
            let reader = FakeTextFieldReader(longAfter)
            reader.caret = 0
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            TestSupport.expect(session.record.before == .documentEdge && session.record.after != .documentEdge, "docStart")
            expectFinal(pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }.0, typed: "cart", edited: "chart")
        }
        do {
            let prefix = String(repeating: "p", count: 50) + " "
            let reader = FakeTextFieldReader(prefix)
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            TestSupport.expect(session.record.before == .text(Array(prefix.utf16.suffix(40))) && session.record.after == .documentEdge,
                               "docEnd with a 40-unit before context")
            expectFinal(pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }.0, typed: "cart", edited: "chart")
        }
        // Appended text: at docEnd it joins the span; past an after anchor it does not.
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cooper netties")
            let session = watching(reader, pasted: "cooper netties")
            let (outcome, _) = pollUntilDone(session) { second in
                if second == 1 { reader.replace("cooper netties", with: "Kubernetes") }
                if second == 2 { reader.append(" rocks") }
            }
            expectFinal(outcome, typed: "cooper netties", edited: "Kubernetes rocks")
        }
        do {
            let reader = FakeTextFieldReader(longAfter)
            reader.caret = 0
            reader.paste("cooper netties")
            let session = watching(reader, pasted: "cooper netties")
            let (outcome, _) = pollUntilDone(session) { second in
                if second == 1 { reader.replace("cooper netties", with: "Kubernetes") }
                if second == 2 { reader.append(" More typing at the end.") }
            }
            expectFinal(outcome, typed: "cooper netties", edited: "Kubernetes")
        }
        // Repeated paragraphs: the pasted copy is tracked by offset, not by search.
        do {
            let paragraph = "alpha beta gamma.\n"
            let reader = FakeTextFieldReader(paragraph + paragraph + longAfter)
            reader.caret = paragraph.utf16.count * 2
            reader.paste(paragraph)
            let session = watching(reader, pasted: paragraph)
            let (outcome, _) = pollUntilDone(session) { second in
                if second == 1 { reader.replaceLast("beta", with: "Beta-2") }
            }
            expectFinal(outcome, typed: paragraph, edited: "alpha Beta-2 gamma.\n")
        }
        // An after context that repeats inside the window is ambiguous.
        do {
            let repeated = String(repeating: "x", count: 50)
            let reader = FakeTextFieldReader(repeated + repeated)
            reader.caret = 0
            reader.paste("cart ")
            let session = watching(reader, pasted: "cart ")
            TestSupport.expectEqual(pollUntilDone(session).0, .discard(.endAmbiguous))
        }
        // Edits to either anchor discard.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = watching(reader, pasted: "ship the cart now. ")
            TestSupport.expectEqual(pollUntilDone(session) { if $0 == 1 { reader.replace("Intro", with: "Outro") } }.0,
                                    .discard(.startMoved))
        }
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = watching(reader, pasted: "ship the cart now. ")
            TestSupport.expectEqual(pollUntilDone(session) { if $0 == 1 { reader.replace("unrelated", with: "other") } }.0,
                                    .discard(.endNotFound))
        }
        // Text inserted before the span moves it: the before anchor no longer sits in place.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = watching(reader, pasted: "ship the cart now. ")
            TestSupport.expectEqual(pollUntilDone(session) { if $0 == 1 { reader.insert("Hi. ", at: 0) } }.0,
                                    .discard(.startMoved))
        }
        // Selection replacement inside the span is an edit; across the start edge it discards.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = watching(reader, pasted: "ship the cart now. ")
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replace("the cart", with: "a chart") } }
            expectFinal(outcome, typed: "ship the cart now. ", edited: "ship a chart now. ")
        }
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = watching(reader, pasted: "ship the cart now. ")
            TestSupport.expectEqual(pollUntilDone(session) { if $0 == 1 { reader.replace("line.\nship", with: "Ship") } }.0,
                                    .discard(.startMoved))
        }
        // Growth beyond 200 units discards, at docEnd and before an anchor.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            TestSupport.expectEqual(pollUntilDone(session) { if $0 == 1 { reader.append(String(repeating: "y", count: 201)) } }.0,
                                    .discard(.spanChangedTooMuch))
        }
        do {
            let reader = FakeTextFieldReader(longAfter)
            reader.caret = 0
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            TestSupport.expectEqual(pollUntilDone(session) { if $0 == 1 { reader.insert(String(repeating: "y", count: 201), at: 2) } }.0,
                                    .discard(.endNotFound))
        }
        // Deleting the whole span is tracked (the edited text is empty).
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("cart ")
            let session = watching(reader, pasted: "cart ")
            expectFinal(pollUntilDone(session) { if $0 == 1 { reader.replace("cart ", with: "") } }.0, typed: "cart ", edited: "")
        }
        // UTF-16 offsets: astral scalars and combining marks before the span.
        do {
            let prefix = "👍🏽 cafe\u{301} 𝔘nicode: "
            let reader = FakeTextFieldReader(prefix)
            reader.paste("naive plan")
            let session = watching(reader, pasted: "naive plan")
            TestSupport.expectEqual(session.record.spanStart, prefix.utf16.count)
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replace("naive", with: "naïve 👍") } }
            expectFinal(outcome, typed: "naive plan", edited: "naïve 👍 plan")
        }
        // A context window that would split a surrogate pair still anchors exactly.
        do {
            let prefix = "😀" + String(repeating: "a", count: 39)  // 41 units; the context starts mid-pair
            let reader = FakeTextFieldReader(prefix)
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            expectFinal(pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }.0, typed: "cart", edited: "chart")
        }
    }

    // MARK: - §3.5 lifecycle and discard paths

    private static func testWatchLifecycle() {
        // Begin: the paste must end exactly at an empty selection.
        do {
            let reader = FakeTextFieldReader("abc ")
            reader.paste("cart")
            reader.caret = 2
            TestSupport.expect(begin(reader, pasted: "cart") == .failure(.pasteNotAtCaret), "Caret moved")
            reader.caret = 8
            reader.selectionLength = 2
            reader.caret = 6
            TestSupport.expect(begin(reader, pasted: "cart") == .failure(.pasteNotAtCaret), "Non-empty selection")
            reader.selectionLength = 0
            reader.caret = 8
            TestSupport.expect(begin(reader, pasted: "carts") == .failure(.pasteNotAtCaret), "Different text at the caret")
            TestSupport.expect(begin(reader, pasted: "") == .failure(.pasteNotAtCaret), "Nothing pasted")
            TestSupport.expect(begin(reader, pasted: "cart").isSuccess, "Paste at the caret")
            reader.supportsRangeReads = false
            TestSupport.expect(begin(reader, pasted: "cart") == .failure(.readFailed), "No bounded reads, no session")
        }
        do {
            let reader = FakeTextFieldReader("")
            let pasted = String(repeating: "w ", count: 2100)
            reader.paste(pasted)
            TestSupport.expect(begin(reader, pasted: pasted) == .failure(.tooLong), "Over the window limit")
        }
        // Bounded reads only, inside large documents.
        do {
            let big = String(repeating: "lorem ipsum ", count: 1000)
            let reader = FakeTextFieldReader(big + big)
            reader.caret = big.utf16.count
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            _ = pollUntilDone(session, to: 3) { if $0 == 1 { reader.replace("cart", with: "chart") } }
            TestSupport.expect(reader.rangeReads.first.map { $0.length <= 4 + 80 } == true, "Begin reads the span and 40 around it")
            TestSupport.expect(reader.rangeReads.dropFirst().allSatisfy { $0.length <= 40 + 4 + 200 + 40 }, "Polls read a bounded window")
            TestSupport.expect(reader.rangeReads.allSatisfy { $0.length <= 4600 }, "Never more than 4,600 units")
            TestSupport.expectEqual(reader.uncheckedReads, 0)  // the safety check precedes every read
        }
        // Discard paths, each checked before reading.
        let scenarios: [(String, (FakeTextFieldReader) -> Void, CorrectionDiscardReason)] = [
            ("focus moved", { $0.focused = false }, .focusChanged),
            ("secure subrole", { $0.secure = true }, .secureField),
            ("read error", { $0.failReads = true }, .readFailed),
            ("permission lost", { $0.trusted = false }, .notTrusted),
        ]
        for (name, change, reason) in scenarios {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            TestSupport.expectEqual(session.poll(now: 1), .watching)
            reader.replace("cart", with: "chart")
            TestSupport.expectEqual(session.poll(now: 2), .watching)
            let readsBefore = reader.rangeReads.count
            change(reader)
            let outcome = session.poll(now: 3)
            TestSupport.expect(outcome == .discard(reason), "\(name): expected \(reason), got \(outcome)")
            if reason != .readFailed {
                TestSupport.expectEqual(reader.rangeReads.count, readsBefore)
            }
            TestSupport.expect(session.isFinished && session.record.pasted.isEmpty, "\(name): text is cleared")
            TestSupport.expectEqual(session.poll(now: 4), .discard(reason))
        }
        // No edit within 60 s is a timeout; an undo back to the paste is no edit.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            let (outcome, second) = pollUntilDone(session) { second in
                if second == 10 { reader.replace("cart", with: "chart") }
                if second == 11 { reader.replace("chart", with: "cart") }
            }
            TestSupport.expectEqual(outcome, .discard(.timeout))
            TestSupport.expectEqual(second, 60)
        }
        // Continuous editing finalizes at 60 s.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            let (outcome, second) = pollUntilDone(session) { reader.replace(reader.string, with: "chart\($0)") }
            // Nothing is read at the deadline: the text captured at 59 s is final.
            expectFinal(outcome, typed: "cart", edited: "chart59")
            TestSupport.expectEqual(second, 60)
        }
        // Cancel (setting off, new dictation, dictionary change, quit) discards without finalizing.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            reader.replace("cart", with: "chart")
            TestSupport.expectEqual(session.poll(now: 1), .watching)
            session.cancel()
            TestSupport.expectEqual(session.poll(now: 9), .discard(.cancelled))
            TestSupport.expect(session.record.pasted.isEmpty, "Cancel clears text")
        }
        // Capture refuses fields that cannot be watched.
        do {
            let reader = FakeTextFieldReader("")
            reader.secure = true
            TestSupport.expect(reader.captureFocusedTextField() == nil, "Secure fields are never captured")
        }
        // The watcher generation ignores work from a cancelled session.
        do {
            let generation = CorrectionWatchGeneration()
            let first = generation.advance()
            TestSupport.expect(generation.isCurrent(first), "Current")
            generation.advance()
            TestSupport.expect(!generation.isCurrent(first), "Stale after cancel")
        }
    }

    // MARK: - §3.5 overlay identity

    private static func testSuggestionGate() {
        let eldar = DictionarySuggestion(word: "Eldar", strength: 1.41, kind: .replace)
        let chart = DictionarySuggestion(word: "chart", strength: 2, kind: .replace)
        var gate = SuggestionPresentationGate()
        let first = gate.present(eldar)
        TestSupport.expect(gate.activeID == first && gate.suggestion == eldar, "Presented")
        gate.preempt()  // recording, transcribing or an error took the panel
        TestSupport.expect(gate.resolve(first) == nil, "A pre-empted suggestion's timer does nothing")
        let second = gate.present(chart)
        TestSupport.expect(gate.resolve(first) == nil, "A stale timer cannot dismiss a later suggestion")
        TestSupport.expect(gate.activeID == second && gate.suggestion == chart, "Still showing the later suggestion")
        TestSupport.expect(gate.resolve(second) == chart, "Its own action resolves it, with its word")
        TestSupport.expect(gate.resolve(second) == nil, "Only once")
        TestSupport.expectEqual(SuggestionPresentationGate.lifetime, 12)
    }

    /// Review round 1, #2: no dismissal path may leave the suggested word in
    /// the overlay's state. The gate holds the overlay's only copy (the phase
    /// carries just the id), and the manager's dismissals all go through it.
    private static func testSuggestionCleanup() {
        let word = DictionarySuggestion(word: "Kubernetes", strength: 1, kind: .replace)
        // Not now, Add and Don't suggest (a click) and the 12 s timeout all resolve by id.
        var resolved = SuggestionPresentationGate()
        let id = resolved.present(word)
        TestSupport.expect(resolved.resolve(id) == word, "The action receives the word")
        TestSupport.expect(resolved.suggestion == nil && resolved.activeID == nil, "Resolving clears the word")
        // Turning suggestions off, another phase, or any panel dismissal pre-empts.
        var withdrawn = SuggestionPresentationGate()
        _ = withdrawn.present(word)
        withdrawn.preempt()
        TestSupport.expect(withdrawn.suggestion == nil && withdrawn.activeID == nil, "Withdrawing clears the word")
    }

    // MARK: - Pin P6 (review round 1, #1)

    private static func testKeyValidity() {
        // A valid 100-scalar surface whose key folds to 101 scalars.
        let surface = "İ" + String(repeating: "a", count: 99)
        guard case .success(let entry) = DictionaryValidation.validate(text: surface, strength: 1, encoder: nil) else {
            fatalError("The surface is a valid entry")
        }
        let key = entry.key
        TestSupport.expectEqual(key.scalars.count, 101)
        TestSupport.expect(key.isValid, "Keys of valid surfaces are valid")
        // "Don't suggest" then restart: the dictionary must still load.
        var dictionary = CustomDictionary()
        TestSupport.expect(dictionary.addIgnore(key) == nil, "Ignoring the key")
        TestSupport.expect(dictionary.upsert(entry) == nil, "Adding the entry")
        let stored = DictionaryStorage.encode(dictionary)
        guard case .success(let reloaded) = DictionaryStorage.load(entriesData: stored.entries, ignoreData: stored.ignore,
                                                                    encoder: nil) else {
            fatalError("A saved ignore key must never make storage unreadable")
        }
        TestSupport.expect(reloaded == dictionary && reloaded.isIgnored(key), "Ignore key round-trips")

        TestSupport.expect(DictionaryKey(folded: s(String(repeating: "a", count: 300))).isValid, "300 scalars")
        TestSupport.expect(DictionaryKey(folded: s("a b c d e f g h")).isValid, "Eight words")
        let invalid: [[Unicode.Scalar]] = [
            [], s(String(repeating: "a", count: 301)), s("a b c d e f g h i"), s("a\u{7}b"), s("a\tb"), s("Eldar"),
        ]
        for scalars in invalid {
            var probe = CustomDictionary()
            TestSupport.expect(!DictionaryKey(folded: scalars).isValid, "Invalid key \(scalars)")
            TestSupport.expect(probe.addIgnore(DictionaryKey(folded: scalars)) == .invalidKey, "Never saved")
            let json = String(data: try! JSONSerialization.data(withJSONObject: ["version": 1, "ignore": [DictionaryText.string(scalars)]]),
                              encoding: .utf8)!
            TestSupport.expect(DictionaryStorage.load(entriesData: nil, ignoreData: Data(json.utf8), encoder: nil) == .failure(.unreadable),
                               "Never loaded")
        }
        // A control scalar is unencodable (§1.1), with or without a vocabulary.
        TestSupport.expect(DictionaryValidation.validate(text: "a\u{7}b", strength: 1, encoder: nil) == .failure(.unencodable),
                           "Control scalars are unencodable")
        TestSupport.expect(DictionaryValidation.validate(text: "a\u{7}b", strength: 1, encoder: testEncoder) == .failure(.unencodable),
                           "Control scalars are unencodable")
    }

    // MARK: - Pin P8 (review round 1, #3)

    private static func testVerificationOrder() {
        // The review's case: the unmappable tag rewrite must not spend the budget.
        var time: TimeInterval = 0
        var calls: [DictionaryEntry] = []
        let found = DictionarySuggestionFinder.find(
            typed: "[dictated] ship the cart now", edited: "[spoken] ship the chart now", base: "ship the cart now",
            dictionary: [], ignore: [], encoder: testEncoder, now: { time }, isCancelled: { false },
            decode: { entry in
                calls.append(entry)
                time += 0.5
                return entry.strength >= 1.41 ? "ship the chart now" : "ship the cart now"
            })
        TestSupport.expect(found == DictionarySuggestion(word: "chart", strength: 1.41, kind: .replace),
                           "The mappable candidate verifies, got \(String(describing: found))")
        TestSupport.expect(calls.allSatisfy { s($0.text) == s("chart") }, "The unmappable candidate is never decoded")
        TestSupport.expectEqual(calls.count, 2)

        // Unmappable candidates are dropped before the three-candidate cap.
        calls = []
        _ = DictionarySuggestionFinder.find(
            typed: "[dictated] one two three four five six seven eight nine ten",
            edited: "[spoken] one zwei three vier five sechs seven acht nine ten",
            base: "one two three four five six seven eight nine ten",
            dictionary: [], ignore: [], encoder: testEncoder, now: { 0 }, isCancelled: { false },
            decode: { calls.append($0); return "one two three four five six seven eight nine ten" })
        TestSupport.expectEqual(calls.count, 15)
        TestSupport.expect(Set(calls.map { DictionaryText.string(s($0.text)) }) == ["zwei", "vier", "sechs"],
                           "Three mappable candidates are attempted")

        // One unmappable candidate, then three mappable ones where the third
        // recovers: the unmappable one is free, so it costs 5 + 5 + 1 decodes.
        calls = []
        let third = DictionarySuggestionFinder.find(
            typed: "[dictated] one two three four five six seven eight nine ten",
            edited: "[spoken] one zwei three vier five sechs seven eight nine ten",
            base: "one two three four five six seven eight nine ten",
            dictionary: [], ignore: [], encoder: testEncoder, now: { 0 }, isCancelled: { false },
            decode: { entry in
                calls.append(entry)
                return s(entry.text) == s("sechs") ? "one two three four five sechs seven eight nine ten"
                    : "one two three four five six seven eight nine ten"
            })
        TestSupport.expect(third == DictionarySuggestion(word: "sechs", strength: 1, kind: .replace),
                           "The third mappable candidate verifies, got \(String(describing: third))")
        TestSupport.expectEqual(calls.count, 11)

        // A result that arrives past the deadline is discarded, even if it verifies.
        time = 0
        calls = []
        let late = DictionarySuggestionFinder.find(
            typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now",
            dictionary: [], ignore: [], encoder: testEncoder, now: { time }, isCancelled: { false },
            decode: { calls.append($0); time += 2.5; return "ship the chart now" })
        TestSupport.expect(late == nil && calls.count == 1, "Late results are discarded")

        // Cancellation during a decode also discards its result.
        var cancelled = false
        let interrupted = DictionarySuggestionFinder.find(
            typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now",
            dictionary: [], ignore: [], encoder: testEncoder, now: { 0 }, isCancelled: { cancelled },
            decode: { _ in cancelled = true; return "ship the chart now" })
        TestSupport.expect(interrupted == nil, "Cancelled results are discarded")

        // Casing candidates respect the deadline and cancellation too.
        var clock: [TimeInterval] = [0, 3]
        let lateCasing = DictionarySuggestionFinder.find(
            typed: "we run nixos", edited: "we run NixOS", base: "we run nixos", dictionary: [], ignore: [],
            encoder: testEncoder, now: { clock.count > 1 ? clock.removeFirst() : clock[0] }, isCancelled: { false },
            decode: { _ in nil })
        TestSupport.expect(lateCasing == nil, "Casing past the deadline")
        let cancelledCasing = DictionarySuggestionFinder.find(
            typed: "we run nixos", edited: "we run NixOS", base: "we run nixos", dictionary: [], ignore: [],
            encoder: testEncoder, now: { 0 }, isCancelled: { true }, decode: { _ in nil })
        TestSupport.expect(cancelledCasing == nil, "Casing when cancelled")
    }

    // MARK: - Review round 2

    /// #3: a cancel that lands during an in-flight metadata request stops the
    /// watch before any text is read, in begin and in a poll.
    private static func testCancelDuringRead() {
        do {
            let generation = CorrectionWatchGeneration()
            let token = generation.advance()
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            reader.onCharacterCount = { generation.advance() }  // a new dictation starts meanwhile
            let target = reader.captureFocusedTextField()!
            let begun = CorrectionWatchSession.begin(reader: reader, target: target, pasted: "cart", dictationID: 7, now: 0,
                                                     isCancelled: { !generation.isCurrent(token) })
            TestSupport.expect(begun == .failure(.cancelled), "Begin stops on cancel")
            TestSupport.expect(reader.rangeReads.isEmpty, "No text is read after the cancel")
        }
        do {
            let generation = CorrectionWatchGeneration()
            let token = generation.advance()
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let target = reader.captureFocusedTextField()!
            guard case .success(let session) = CorrectionWatchSession.begin(
                reader: reader, target: target, pasted: "cart", dictationID: 7, now: 0,
                isCancelled: { !generation.isCurrent(token) }) else { fatalError("Session must begin") }
            TestSupport.expectEqual(session.poll(now: 1), .watching)
            let reads = reader.rangeReads.count
            reader.onCharacterCount = { generation.advance() }
            TestSupport.expectEqual(session.poll(now: 2), .discard(.cancelled))
            TestSupport.expectEqual(reader.rangeReads.count, reads)
            TestSupport.expect(session.record.pasted.isEmpty, "Text is cleared")
        }
    }

    /// Runs the main queue until `done` or the timeout.
    private static func spin(timeout: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// #1: a paste still waiting for the shortcut release when a new recording
    /// starts must not capture or watch anything.
    private static func testStaleDelayedPaste() {
        let reader = FakeTextFieldReader("Note: ")
        reader.paste("cart")
        let watcher = CorrectionWatcher(reader: reader)

        let stale = watcher.currentGeneration  // the dictation finished
        watcher.cancel()                       // a new recording starts before the paste
        var staleResult: CorrectionCapture?? = .none
        watcher.capture(expecting: stale) { staleResult = .some($0) }
        TestSupport.expect(staleResult != nil && staleResult! == nil, "A stale context gets no capture, at once")
        spin(timeout: 0.4)
        TestSupport.expectEqual(reader.captureCalls, 0)
        TestSupport.expect(reader.rangeReads.isEmpty, "Nothing is read for a stale paste")

        // A capture that is cancelled before it starts never begins watching.
        var captured: CorrectionCapture?
        watcher.capture(expecting: watcher.currentGeneration) { captured = $0 }
        spin(timeout: 1) { captured != nil }
        TestSupport.expect(captured != nil, "A current context captures")
        watcher.cancel()
        watcher.start(captured!, pasted: "cart", dictationID: 7)
        spin(timeout: 0.4)
        TestSupport.expect(reader.rangeReads.isEmpty, "A cancelled capture never starts")

        // A current one begins, and a cancel ends all further reads.
        captured = nil
        watcher.capture(expecting: watcher.currentGeneration) { captured = $0 }
        spin(timeout: 1) { captured != nil }
        watcher.start(captured!, pasted: "cart", dictationID: 7)
        spin(timeout: 1) { !reader.rangeReads.isEmpty }
        TestSupport.expectEqual(reader.rangeReads.count, 1)
        watcher.cancel()
        spin(timeout: 1.4)
        TestSupport.expectEqual(reader.rangeReads.count, 1)
    }

    // MARK: - Review round 3

    /// #1: past the 60 s window nothing is read again. A late poll finalizes
    /// from text captured inside the window, or discards.
    private static func testDeadlineStopsReads() {
        // A timer callback delayed to 75 s.
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            TestSupport.expectEqual(session.poll(now: 1), .watching)
            reader.replace("cart", with: "chart")
            TestSupport.expectEqual(session.poll(now: 2), .watching)
            reader.replace("chart", with: "chart typed after the window")
            let reads = reader.rangeReads.count
            let outcome = session.poll(now: 75)
            expectFinal(outcome, typed: "cart", edited: "chart")
            TestSupport.expectEqual(reader.rangeReads.count, reads)
        }
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let session = watching(reader, pasted: "cart")
            reader.replace("cart", with: "chart")  // edited, but never read inside the window
            let reads = reader.rangeReads.count
            TestSupport.expectEqual(session.poll(now: 75), .discard(.timeout))
            TestSupport.expectEqual(reader.rangeReads.count, reads)
        }
        // A metadata request that crosses the deadline: no text read follows.
        for edited in [false, true] {
            var time: TimeInterval = 0
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let target = reader.captureFocusedTextField()!
            guard case .success(let session) = CorrectionWatchSession.begin(
                reader: reader, target: target, pasted: "cart", dictationID: 7, now: 0, clock: { time }) else {
                fatalError("Session must begin")
            }
            if edited { reader.replace("cart", with: "chart") }
            time = 2
            TestSupport.expectEqual(session.poll(now: 2), .watching)
            reader.replace(reader.string.hasSuffix("chart") ? "chart" : "cart", with: "late")
            let reads = reader.rangeReads.count
            reader.onCharacterCount = { time = 60.5 }
            time = 59.9
            let outcome = session.poll(now: 59.9)
            TestSupport.expectEqual(reader.rangeReads.count, reads)
            if edited {
                expectFinal(outcome, typed: "cart", edited: "chart")
            } else {
                TestSupport.expectEqual(outcome, .discard(.timeout))
            }
            TestSupport.expect(session.record.pasted.isEmpty, "Text is cleared")
        }
    }

    /// #2: a full dictionary could not take the word, so nothing is offered or decoded.
    private static func testFullDictionaryOffersNothing() {
        let full = (0..<DictionaryValidation.capacity).map { entry("word\($0)x") }
        var calls = 0
        let replace = DictionarySuggestionFinder.find(
            typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now", dictionary: full, ignore: [],
            encoder: testEncoder, now: { 0 }, isCancelled: { false },
            decode: { _ in calls += 1; return "ship the chart now" })
        TestSupport.expect(replace == nil && calls == 0, "No replacement offered at capacity")
        let casing = DictionarySuggestionFinder.find(
            typed: "we run nixos", edited: "we run NixOS", base: "we run nixos", dictionary: full, ignore: [],
            encoder: testEncoder, now: { 0 }, isCancelled: { false }, decode: { _ in nil })
        TestSupport.expect(casing == nil, "No casing suggestion at capacity")
        let room = DictionarySuggestionFinder.find(
            typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now",
            dictionary: Array(full.dropLast()), ignore: [], encoder: testEncoder, now: { 0 }, isCancelled: { false },
            decode: { _ in "ship the chart now" })
        TestSupport.expect(room != nil, "One free slot still offers the word")
        // Adding at capacity is refused, not silently dropped.
        var dictionary = CustomDictionary()
        for item in full { _ = dictionary.upsert(item) }
        TestSupport.expect(dictionary.upsert(entry("chart")) == .full, "The add reports full")
    }

    /// #2: an edit between recording stop and model submission (or any later
    /// cancel) leaves the result ineligible, so its session is released.
    private static func testEligibilityWindow() {
        func eligible(snapshot: UInt64 = 3, current: UInt64 = 3, watch: UInt64 = 5, now: UInt64 = 5, enabled: Bool = true,
                      readable: Bool = true, macro: Bool = false, enter: Bool = false, output: String = "ship the cart now") -> Bool {
            CorrectionEligibility.isEligible(suggestionsEnabled: enabled, dictionaryReadable: readable, retained: true,
                                             snapshotRevision: snapshot, currentRevision: current,
                                             watchGeneration: watch, currentGeneration: now,
                                             usedMacro: macro, shouldPressEnter: enter, output: output)
        }
        TestSupport.expect(eligible(), "A plain current dictation is eligible")
        TestSupport.expect(!eligible(current: 4), "A dictionary edit after recording stopped")
        TestSupport.expect(!eligible(now: 6), "A cancel after recording stopped")
        TestSupport.expect(!eligible(enabled: false) && !eligible(readable: false), "Setting off or unreadable dictionary")
        TestSupport.expect(!eligible(macro: true) && !eligible(enter: true) && !eligible(output: ""), "Macro, enter, empty")
        TestSupport.expect(!eligible(output: String(repeating: "a", count: 4097)), "Over 4096 bytes")
        TestSupport.expect(!CorrectionEligibility.isEligible(
            suggestionsEnabled: true, dictionaryReadable: true, retained: false, snapshotRevision: 1, currentRevision: 1,
            watchGeneration: 1, currentGeneration: 1, usedMacro: false, shouldPressEnter: false, output: "x"),
            "Nothing retained")
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

extension CorrectionWatchSession: Equatable {
    static func == (lhs: CorrectionWatchSession, rhs: CorrectionWatchSession) -> Bool { lhs === rhs }
}

/// A text field held as UTF-16 units, as Accessibility reports it.
final class FakeTextFieldReader: TextFieldReader {
    var units: [UInt16]
    var caret: Int
    var selectionLength = 0
    var trusted = true
    var focused = true
    var secure = false
    var failReads = false
    var supportsRangeReads = true
    private(set) var rangeReads: [(location: Int, length: Int)] = []
    /// Reads not preceded by a safety check since the previous read.
    private(set) var uncheckedReads = 0
    private(set) var captureCalls = 0
    /// Runs inside the character-count request, as if during an in-flight AX call.
    var onCharacterCount: (() -> Void)?
    private var checkedSinceRead = false
    private let element = NSObject()

    init(_ text: String) {
        units = Array(text.utf16)
        caret = units.count
    }

    var string: String { String(decoding: units, as: UTF16.self) }

    func paste(_ text: String) {
        units.insert(contentsOf: text.utf16, at: caret)
        caret += text.utf16.count
    }

    func append(_ text: String) { units.append(contentsOf: text.utf16) }

    func insert(_ text: String, at offset: Int) { units.insert(contentsOf: text.utf16, at: offset) }

    func replace(_ old: String, with new: String) { replace(old, with: new, last: false) }

    func replaceLast(_ old: String, with new: String) { replace(old, with: new, last: true) }

    private func replace(_ old: String, with new: String, last: Bool) {
        let needle = Array(old.utf16)
        let starts = needle.isEmpty ? [] : (0...(units.count - needle.count)).filter { Array(units[$0..<$0 + needle.count]) == needle }
        guard let start = last ? starts.last : starts.first else { fatalError("Fake text has no \(old)") }
        units.replaceSubrange(start..<start + needle.count, with: new.utf16)
    }

    func isTrusted() -> Bool { trusted }

    func captureFocusedTextField() -> TextFieldTarget? {
        captureCalls += 1
        guard trusted, focused, !secure else { return nil }
        return TextFieldTarget(pid: 4242, element: element)
    }

    func check(_ target: TextFieldTarget) -> TextFieldCheck {
        checkedSinceRead = true
        guard focused, target.pid == 4242, target.element === element else { return .focusChanged }
        return secure ? .secure : .ok
    }

    private func noteRead() {
        if !checkedSinceRead { uncheckedReads += 1 }
        checkedSinceRead = false
    }

    func characterCount(_ target: TextFieldTarget) -> Int? {
        noteRead()
        onCharacterCount?()
        return failReads ? nil : units.count
    }

    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? {
        noteRead()
        return failReads ? nil : TextFieldRange(location: caret, length: selectionLength)
    }

    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? {
        noteRead()
        guard supportsRangeReads, !failReads, range.location >= 0, range.length >= 0,
              range.location + range.length <= units.count else { return nil }
        rangeReads.append((range.location, range.length))
        let slice = Array(units[range.location..<range.location + range.length])
        return String(utf16CodeUnits: slice, count: slice.count)
    }
}
