import Foundation

/// The swipe decoding core against the reference implementation's fixtures (ARCHITECTURE.md,
/// "Typing model v4 and swipe typing", decoding pipeline). Every input is synthetic.
enum SwipeCoreTests {
    static var tests: [TestCase] {
        [
            ("resampleMatchesReference", testResampleMatchesReference),
            ("decodeMatchesReference", testDecodeMatchesReference),
            ("decodeWithoutFramesFindsNothing", testDecodeWithoutFramesFindsNothing),
            ("decodeRefusesAnInvalidConfig", testDecodeRefusesAnInvalidConfig),
            ("decodeSurvivesUnboundedSettings", testDecodeSurvivesUnboundedSettings),
            ("bundleRejectsOutOfRangeSettings", testBundleRejectsOutOfRangeSettings),
            ("lexiconReadsADataSlice", testLexiconReadsADataSlice),
            ("lexiconRejectsHeaderAndSizeCorruption", testLexiconRejectsHeaderAndSizeCorruption),
            ("lexiconRejectsBadEdges", testLexiconRejectsBadEdges),
            ("lexiconRejectsBadWords", testLexiconRejectsBadWords),
            ("frameMatchesTrainingLayout", testFrameMatchesTrainingLayout),
            ("frameNeedsEveryLetter", testFrameNeedsEveryLetter),
        ]
    }

    private static let tolerance = 1e-9

    private static var lexiconBytes: Data { Data(base64Encoded: SwipeFixtures.lexiconBase64)! }

    private static func close(_ a: Double, _ b: Double) -> Bool {
        a == b || abs(a - b) <= tolerance
    }

    // MARK: - Resample

    private static func testResampleMatchesReference() {
        TestSupport.expectEqual(SwipeResampler.points, 64)
        TestSupport.expect(!SwipeFixtures.resample.isEmpty, "no resample fixtures")
        for (index, fixture) in SwipeFixtures.resample.enumerated() {
            let out = SwipeResampler.resample(t: fixture.t, x: fixture.x, y: fixture.y)
            TestSupport.expectEqual(out.count, SwipeResampler.points * 2)
            TestSupport.expectEqual(fixture.expected.count, SwipeResampler.points * 2)
            for (k, (actual, expected)) in zip(out, fixture.expected).enumerated() {
                TestSupport.expect(close(actual, expected), "resample case \(index) value \(k): \(actual) != \(expected)")
            }
        }
    }

    // MARK: - Decode

    private static func config(_ fixture: SwipeFixtures.Decode) -> SwipeDecodeConfig {
        SwipeDecodeConfig(beam: fixture.beam, topK: fixture.topK, lengthPower: fixture.lengthPower,
                          freqWeight: fixture.freqWeight, lengthBonus: fixture.lengthBonus)
    }

    private static func expectReference(_ lexicon: SwipeLexicon, file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expectEqual(SwipeDecoder.columns, 27)
        TestSupport.expect(!SwipeFixtures.decode.isEmpty, "no decode fixtures")
        for (index, fixture) in SwipeFixtures.decode.enumerated() {
            TestSupport.expectEqual(fixture.logProbs.count, SwipeFixtures.frames * SwipeDecoder.columns)
            let out = SwipeDecoder.decode(logProbs: fixture.logProbs, frames: SwipeFixtures.frames, lexicon: lexicon,
                                          config: config(fixture))
            TestSupport.expect(out.map(\.word) == fixture.words,
                               "decode case \(index): \(out.map(\.word)) != \(fixture.words)", file: file, line: line)
            for (candidate, expected) in zip(out, fixture.scores) {
                TestSupport.expect(close(candidate.score, expected),
                                   "decode case \(index) \(candidate.word): \(candidate.score) != \(expected)",
                                   file: file, line: line)
            }
        }
    }

    private static func testDecodeMatchesReference() {
        expectReference(try! SwipeLexicon(data: lexiconBytes))
    }

    private static func testDecodeWithoutFramesFindsNothing() {
        let lexicon = try! SwipeLexicon(data: lexiconBytes)
        TestSupport.expectEqual(SwipeDecoder.decode(logProbs: [], frames: 0, lexicon: lexicon, config: SwipeDecodeConfig()),
                                [])
    }

    /// A beam or result count far past the lexicon's size neither traps nor changes the result.
    private static func testDecodeSurvivesUnboundedSettings() {
        let lexicon = try! SwipeLexicon(data: lexiconBytes)
        for fixture in SwipeFixtures.decode {
            var wide = config(fixture)
            wide.beam = 4096
            wide.topK = 4096
            var unbounded = wide
            unbounded.beam = .max
            unbounded.topK = .max
            let expected = SwipeDecoder.decode(logProbs: fixture.logProbs, frames: SwipeFixtures.frames, lexicon: lexicon,
                                               config: wide)
            TestSupport.expect(!expected.isEmpty, "a wide beam found nothing")
            TestSupport.expectEqual(SwipeDecoder.decode(logProbs: fixture.logProbs, frames: SwipeFixtures.frames,
                                                        lexicon: lexicon, config: unbounded), expected)
        }
    }

    private static func bundleManifest(beam: String = "32", topK: String = "5") -> Data {
        Data("""
        {"format": 1, "decode": {"beam": \(beam), "top_k": \(topK), "length_power": 0.0, "freq_weight": 0.02,
         "length_bonus": 0.0}, "files": {}}
        """.utf8)
    }

    /// `bundle.json` decode settings outside 1...1024 (beam) and 1...64 (top_k) reject the bundle.
    private static func testBundleRejectsOutOfRangeSettings() {
        for (beam, topK) in [("1", "1"), ("1024", "64"), ("32", "5")] {
            let config = try? SwipeBundleManifest.decodeConfig(from: bundleManifest(beam: beam, topK: topK))
            TestSupport.expectEqual(config, SwipeDecodeConfig(beam: Int(beam)!, topK: Int(topK)!))
        }
        let rejected = [("0", "5"), ("1025", "5"), ("\(Int.max)", "5"), ("-1", "5"),
                        ("32", "0"), ("32", "65"), ("32", "\(Int.max)")]
        for (beam, topK) in rejected {
            do {
                _ = try SwipeBundleManifest.decodeConfig(from: bundleManifest(beam: beam, topK: topK))
                TestSupport.expect(false, "beam \(beam), top_k \(topK) accepted")
            } catch {
                TestSupport.expectEqual(error as? SwipeEngineError, .invalidSettings)
            }
        }
        // A beam too large for an Int is not a number the manifest can hold.
        TestSupport.expect((try? SwipeBundleManifest.decodeConfig(from: bundleManifest(beam: "1e300"))) == nil,
                           "a huge beam accepted")
    }

    private static func testDecodeRefusesAnInvalidConfig() {
        let lexicon = try! SwipeLexicon(data: lexiconBytes)
        let fixture = SwipeFixtures.decode[0]
        for bad in [SwipeDecodeConfig(beam: 0), SwipeDecodeConfig(topK: 0)] {
            TestSupport.expectEqual(SwipeDecoder.decode(logProbs: fixture.logProbs, frames: SwipeFixtures.frames,
                                                        lexicon: lexicon, config: bad), [])
        }
    }

    // MARK: - Lexicon

    /// A memory-mapped or sliced `Data` need not start at index 0.
    private static func testLexiconReadsADataSlice() {
        let padded = Data([0xEE, 0xEE, 0xEE]) + lexiconBytes + Data([0xEE])
        let slice = padded[3 ..< padded.count - 1]
        expectReference(try! SwipeLexicon(data: slice))
    }

    private struct Layout {
        let nodes: Int, edges: Int, words: Int, blob: Int
        var edgeStart: Int { 24 }
        var edgeLetter: Int { edgeStart + 4 * (nodes + 1) }
        var edgeChild: Int { edgeLetter + edges }
        var wordStart: Int { edgeChild + 4 * edges }
        var wordFreq: Int { wordStart + 4 * (nodes + 1) }
        var textStart: Int { wordFreq + words }
        var blobStart: Int { textStart + 4 * (words + 1) }

        init(_ data: Data) {
            nodes = Int(SwipeCoreTests.u32(data, 8))
            edges = Int(SwipeCoreTests.u32(data, 12))
            words = Int(SwipeCoreTests.u32(data, 16))
            blob = Int(SwipeCoreTests.u32(data, 20))
        }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    private static func setU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for k in 0 ..< 4 {
            data[data.startIndex + offset + k] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(k)))
        }
    }

    private static func expectRejected(_ data: Data, _ expected: SwipeLexicon.FormatError, _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try SwipeLexicon(data: data)
            TestSupport.expect(false, "\(what): accepted", file: file, line: line)
        } catch let error as SwipeLexicon.FormatError {
            TestSupport.expect(error == expected, "\(what): \(error), expected \(expected)", file: file, line: line)
        } catch {
            TestSupport.expect(false, "\(what): unexpected error \(error)", file: file, line: line)
        }
    }

    private static func mutated(_ change: (inout Data, Layout) -> Void) -> Data {
        var data = lexiconBytes
        change(&data, Layout(data))
        return data
    }

    private static func testLexiconRejectsHeaderAndSizeCorruption() {
        let good = lexiconBytes
        let layout = Layout(good)
        TestSupport.expectEqual(layout.blobStart + layout.blob, good.count)

        expectRejected(mutated { data, _ in data[0] = UInt8(ascii: "X") }, .badMagic, "bad magic")
        expectRejected(mutated { data, _ in setU32(&data, 4, 2) }, .unsupportedVersion, "version 2")
        expectRejected(mutated { data, _ in setU32(&data, 4, 0) }, .unsupportedVersion, "version 0")
        expectRejected(Data(), .wrongSize, "empty")
        expectRejected(good.prefix(3), .wrongSize, "shorter than the magic")
        expectRejected(good.prefix(20), .wrongSize, "truncated header")
        expectRejected(good.dropLast(), .wrongSize, "truncated blob")
        expectRejected(good.prefix(layout.wordStart), .wrongSize, "truncated tables")
        expectRejected(good + Data([0]), .wrongSize, "trailing byte")
        expectRejected(mutated { data, _ in setU32(&data, 8, 0) }, .wrongSize, "no root node")
        expectRejected(mutated { data, layout in setU32(&data, 20, UInt32(layout.blob + 1)) }, .wrongSize,
                       "blob size larger than the data")
        expectRejected(mutated { data, _ in setU32(&data, 12, .max) }, .wrongSize, "huge edge count")
        // The magic is checked before the size, and the size of the header before the version.
        expectRejected(Data("XFLX".utf8), .badMagic, "bad magic without a header")
        expectRejected(good.prefix(4), .wrongSize, "the magic alone")
        expectRejected(mutated { data, _ in setU32(&data, 4, 2) }.prefix(20), .wrongSize, "truncated header of version 2")
    }

    private static func testLexiconRejectsBadEdges() {
        // Edge offsets: the root's must start at 0, they never decrease, and the last is the edge count.
        expectRejected(mutated { data, layout in setU32(&data, layout.edgeStart, 1) }, .badEdgeOffsets,
                       "edges not starting at 0")
        expectRejected(mutated { data, layout in setU32(&data, layout.edgeStart + 4 * layout.nodes, UInt32(layout.edges - 1)) },
                       .badEdgeOffsets, "last edge offset short of the edge count")
        expectRejected(mutated { data, layout in
            setU32(&data, layout.edgeStart + 4, u32(data, layout.edgeStart + 8) + 1)
        }, .badEdgeOffsets, "decreasing edge offsets")

        // Letters: 'a'...'z', strictly ascending within a node. The root's edges are a, b, c, ...
        let good = lexiconBytes
        let layout = Layout(good)
        TestSupport.expect(good[layout.edgeLetter] == UInt8(ascii: "a") && good[layout.edgeLetter + 1] == UInt8(ascii: "b"),
                           "fixture root edges changed")
        expectRejected(mutated { data, layout in data.swapAt(layout.edgeLetter, layout.edgeLetter + 1) }, .badLetters,
                       "descending letters")
        expectRejected(mutated { data, layout in data[layout.edgeLetter + 1] = UInt8(ascii: "a") }, .badLetters,
                       "repeated letter")
        expectRejected(mutated { data, layout in data[layout.edgeLetter] = UInt8(ascii: "A") }, .badLetters,
                       "uppercase letter")
        expectRejected(mutated { data, layout in data[layout.edgeLetter] = UInt8(ascii: "'") }, .badLetters,
                       "apostrophe edge")

        // Children: in range, never the root, and the edges form a tree.
        expectRejected(mutated { data, layout in setU32(&data, layout.edgeChild, UInt32(layout.nodes)) }, .badChild,
                       "child out of range")
        expectRejected(mutated { data, layout in setU32(&data, layout.edgeChild, .max) }, .badChild, "child way out of range")
        expectRejected(mutated { data, layout in setU32(&data, layout.edgeChild, 0) }, .badChild, "edge back to the root")
        expectRejected(mutated { data, layout in setU32(&data, layout.edgeChild + 4, u32(data, layout.edgeChild)) },
                       .badChild, "node with two parents")
        // Node 1 ("a") pointing at itself, and node 1's first child pointing back at node 1: cycles.
        expectRejected(mutated { data, layout in
            let first = Int(u32(data, layout.edgeStart + 4))
            setU32(&data, layout.edgeChild + 4 * first, 1)
        }, .badChild, "cycle")
    }

    private static func testLexiconRejectsBadWords() {
        expectRejected(mutated { data, layout in setU32(&data, layout.wordStart, 1) }, .badWordOffsets,
                       "words not starting at 0")
        expectRejected(mutated { data, layout in setU32(&data, layout.wordStart + 4 * layout.nodes, UInt32(layout.words + 1)) },
                       .badWordOffsets, "last word offset past the word count")
        expectRejected(mutated { data, layout in
            // Every node from 1 on gets more words than there are.
            for node in 1 ..< layout.nodes { setU32(&data, layout.wordStart + 4 * node, UInt32(layout.words + 1)) }
        }, .badWordOffsets, "word offsets past the word count")

        expectRejected(mutated { data, layout in setU32(&data, layout.textStart, 1) }, .badTextOffsets,
                       "text not starting at 0")
        expectRejected(mutated { data, layout in setU32(&data, layout.textStart + 4, UInt32(layout.blob + 1)) },
                       .badTextOffsets, "text offset past the blob")
        expectRejected(mutated { data, layout in setU32(&data, layout.textStart + 4 * layout.words, UInt32(layout.blob - 1)) },
                       .badTextOffsets, "last text offset short of the blob")
        expectRejected(mutated { data, layout in setU32(&data, layout.textStart + 8, u32(data, layout.textStart + 4)) },
                       .badTextOffsets, "empty word")
        expectRejected(mutated { data, layout in
            setU32(&data, layout.textStart + 8, u32(data, layout.textStart + 4) - 1)
        }, .badTextOffsets, "decreasing text offsets")

        expectRejected(mutated { data, layout in data[layout.blobStart] = 0xFF }, .invalidUTF8, "invalid byte")
        expectRejected(mutated { data, layout in data[layout.blobStart] = 0xC3 }, .invalidUTF8, "truncated sequence")
        // Replaces the bytes of the first word of `bytes.count` bytes.
        func word(_ bytes: [UInt8]) -> Data {
            mutated { data, layout in
                for j in 0 ..< layout.words {
                    let start = Int(u32(data, layout.textStart + 4 * j)), end = Int(u32(data, layout.textStart + 4 * j + 4))
                    guard end - start == bytes.count else { continue }
                    for (k, byte) in bytes.enumerated() { data[layout.blobStart + start + k] = byte }
                    return
                }
                TestSupport.expect(false, "no fixture word of \(bytes.count) bytes")
            }
        }
        expectRejected(word([0xC0, 0xAF]), .invalidUTF8, "overlong encoding")
        expectRejected(word([0xE0, 0x80, 0xAF]), .invalidUTF8, "overlong three-byte encoding")
        expectRejected(word([0xED, 0xA0, 0x80]), .invalidUTF8, "surrogate")
        expectRejected(word([0xF4, 0x90, 0x80, 0x80]), .invalidUTF8, "past U+10FFFF")
        expectRejected(word([0x80, 0x61]), .invalidUTF8, "lone continuation byte")
        // Valid multi-byte words are accepted.
        _ = try! SwipeLexicon(data: word([0xC3, 0xA9]))
        _ = try! SwipeLexicon(data: word([0xE2, 0x80, 0x99]))
        _ = try! SwipeLexicon(data: word([0xF0, 0x9F, 0x98, 0x80]))
        expectRejected(mutated { data, layout in
            // A two-byte character split across the first two words.
            let end = Int(u32(data, layout.textStart + 4))
            data[layout.blobStart + end - 1] = 0xC3
            data[layout.blobStart + end] = 0xA9
        }, .invalidUTF8, "character split across words")
    }

    // MARK: - Frame

    private static func centers(_ frame: SwipeFrame) -> [Character: (x: Double, y: Double)] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let values = frame.letterCenters
        TestSupport.expectEqual(values.count, 52)
        var out: [Character: (x: Double, y: Double)] = [:]
        for (index, letter) in letters.enumerated() { out[letter] = (values[2 * index], values[2 * index + 1]) }
        return out
    }

    private static func testFrameMatchesTrainingLayout() {
        let metrics = KeyboardMetrics(width: 402, height: 216)
        let keys = KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: false)
        guard let frame = SwipeFrame(keys: keys) else {
            TestSupport.expect(false, "no frame for the letters layer")
            return
        }
        let c = centers(frame)
        func near(_ value: Double, _ expected: Double, _ what: String, _ tolerance: Double = 1e-6) {
            TestSupport.expect(abs(value - expected) <= tolerance, "\(what): \(value), expected \(expected)")
        }
        near(c["q"]!.x, 0.05, "q x", 1e-9)
        near(c["p"]!.x, 0.95, "p x", 1e-9)
        near(c["a"]!.x, 0.10, "a x", 1e-3)
        near(c["z"]!.x, 0.20, "z x", 1e-3)

        // The top row's center sits half a row pitch below y = 0, and the rows are one pitch apart,
        // in units of the frame width (54-point pitch, 397-point frame width on this layout).
        let pitch = metrics.rowHeight + metrics.rowGap
        let width = 397.0
        near(c["q"]!.y, 0.5 * pitch / width, "top row y")
        near(c["a"]!.y, 1.5 * pitch / width, "middle row y")
        near(c["z"]!.y, 2.5 * pitch / width, "bottom row y")
        near(c["a"]!.y / c["q"]!.y, 3, "middle row / top row")
        near(c["m"]!.y / c["p"]!.y, 5, "bottom row / top row")

        // normalize is the same map: the frame origin and the top row's centers.
        let origin = frame.normalize(x: 2.5, y: 2)
        near(origin.x, 0, "origin x")
        near(origin.y, 0, "origin y")
        let right = frame.normalize(x: 399.5, y: 2 + 397)
        near(right.x, 1, "frame right edge")
        near(right.y, 1, "one frame width down")
        guard let q = keys.first(where: { $0.action == .character("q") }) else { return }
        let qn = frame.normalize(x: q.frame.midX, y: q.frame.midY)
        near(qn.x, c["q"]!.x, "normalize q x", 1e-12)
        near(qn.y, c["q"]!.y, "normalize q y", 1e-12)
    }

    private static func testFrameNeedsEveryLetter() {
        let metrics = KeyboardMetrics(width: 402, height: 216)
        TestSupport.expect(SwipeFrame(keys: KeyboardLayout.keys(for: .numbers, metrics: metrics, showsGlobe: false)) == nil,
                           "numbers layer has a frame")
        TestSupport.expect(SwipeFrame(keys: KeyboardLayout.keys(for: .symbols, metrics: metrics, showsGlobe: false)) == nil,
                           "symbols layer has a frame")
        TestSupport.expect(SwipeFrame(keys: []) == nil, "no keys has a frame")
        let letters = KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: true)
        TestSupport.expect(SwipeFrame(keys: letters) != nil, "letters layer with a globe has no frame")
        TestSupport.expect(SwipeFrame(keys: letters.filter { $0.action != .character("j") }) == nil,
                           "letters without j have a frame")
        // Letters are stored lowercase; an uppercase caption key is not the letter.
        let upper = letters.map { key -> PlacedKey in
            var key = key
            if key.action == .character("k") { key.action = .character("K") }
            return key
        }
        TestSupport.expect(SwipeFrame(keys: upper) == nil, "uppercase K counts as k")
    }
}
