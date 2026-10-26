import Foundation

/// Consumes linux/testdata/chunking-vectors.json (version 1), shared with the
/// Rust tests: silence compaction, chunk boundaries, words from tokens, seams
/// and whole chunked transcriptions. Signals are generated from the file's
/// descriptions with exact arithmetic, so both platforms see the same samples.
enum ChunkingVectorTests {
    static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("linux/testdata/chunking-vectors.json")
    }

    private typealias Object = [String: Any]

    static func run() {
        guard let data = try? Data(contentsOf: vectorsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? Object else {
            fatalError("Shared chunking vectors are missing or unreadable at \(vectorsURL.path)")
        }
        TestSupport.expectEqual(root["version"] as? Int, 1)
        let constants = root["constants"] as! Object
        TestSupport.expectEqual(constants["sample_rate"] as? Int, LocalParakeetCore.sampleRate)
        TestSupport.expectEqual(constants["chunk_samples"] as? Int, LocalParakeetCore.chunkSamples)
        TestSupport.expectEqual(constants["chunk_overlap_samples"] as? Int, LocalParakeetCore.chunkOverlapSamples)
        TestSupport.expectEqual(constants["samples_per_encoder_frame"] as? Int, LocalParakeetCore.samplesPerEncoderFrame)
        TestSupport.expectEqual(constants["alignment_tolerance"] as? Int, ParakeetTranscriptAssembler.alignmentTolerance)
        TestSupport.expectEqual(constants["compactor_margin"] as? Int, ParakeetSilenceCompactor.defaultMargin)
        TestSupport.expectEqual(constants["compactor_interior_pause"] as? Int, ParakeetSilenceCompactor.defaultInteriorPause)
        TestSupport.expectEqual(constants["compactor_max_piece_samples"] as? Int, ParakeetSilenceCompactor.maxPieceSamples)
        TestSupport.expectEqual(constants["compactor_frame_samples"] as? Int, ParakeetSilenceCompactor.frameSamples)

        func section(_ name: String) -> [Object] {
            let items = root[name] as! [Object]
            TestSupport.expect(!items.isEmpty, "Vector section \(name) is empty")
            return items
        }

        let compactorReads = root["compactor_reads"] as! [[Int]]
        for item in section("compactor") {
            let input = signal(item["signal"])
            var expected: [Float] = []
            for range in item["kept"] as! [[Int]] { expected += input[range[0]..<range[1]] }
            TestSupport.expectEqual(expected.count, item["output_samples"] as! Int)
            for pattern in compactorReads {
                var compactor = ParakeetSilenceCompactor(
                    margin: item["margin"] as? Int ?? ParakeetSilenceCompactor.defaultMargin,
                    interiorPause: item["interior_pause"] as? Int ?? ParakeetSilenceCompactor.defaultInteriorPause)
                var output: [Float] = []
                let emit: ([Float]) -> Void = { piece in
                    TestSupport.expect(!piece.isEmpty && piece.count <= ParakeetSilenceCompactor.maxPieceSamples,
                                       "compactor \(item["name"]!): unbounded piece")
                    output += piece
                }
                for part in split(input, pattern) { compactor.append(part, emit: emit) }
                compactor.finish(emit: emit)
                TestSupport.expect(same(output, expected), "compactor \(item["name"]!) reads \(pattern)")
            }
        }

        let chunkerReads = root["chunker_reads"] as! [[Int]]
        for item in section("chunker") {
            let input = (0..<(item["total"] as! Int)).map { Float($0) }
            for pattern in chunkerReads {
                var chunker = ParakeetChunker(size: item["size"] as! Int, overlap: item["overlap"] as! Int)
                var chunks: [[Int]] = []
                let emit: (ParakeetChunk) -> Void = { chunk in
                    TestSupport.expect(same(chunk.samples, Array(input[chunk.range])), "chunker \(item["name"]!): samples")
                    chunks.append([chunk.start, chunk.samples.count])
                }
                for part in split(input, pattern) { chunker.append(part, emit: emit) }
                chunker.finish(emit: emit)
                TestSupport.expect(chunks == item["chunks"] as! [[Int]], "chunker \(item["name"]!) reads \(pattern): got \(chunks)")
            }
        }

        let words = root["words"] as! Object
        let vocabulary = (words["vocab"] as! [String]).map(native)
        let cases = words["cases"] as! [Object]
        TestSupport.expect(!cases.isEmpty, "Vector section words is empty")
        for item in cases {
            let tokens = (item["tokens"] as! [[Int]]).map { ParakeetToken(id: $0[0], frame: $0[1]) }
            let result = try? LocalParakeetCore.words(tokens, vocabulary: vocabulary, offset: item["offset"] as! Int)
            if item["error"] as? Bool == true {
                TestSupport.expect(result == nil, "words \(item["name"]!) must fail")
            } else {
                TestSupport.expect(result == parakeetWords(item["words"]), "words \(item["name"]!): got \(String(describing: result))")
            }
        }

        for item in section("assembler") {
            var assembler = ParakeetTranscriptAssembler()
            for append in item["appends"] as! [Object] {
                let range = append["range"] as! [Int]
                assembler.append(parakeetWords(append["words"]), covering: range[0]..<range[1])
            }
            TestSupport.expect(assembler.text.unicodeScalars.elementsEqual((item["text"] as! String).unicodeScalars),
                               "assembler \(item["name"]!): got \(assembler.text.debugDescription)")
        }

        let transcriptionReads = root["transcription_reads"] as! [[Int]]
        for item in section("transcription") {
            let input = signal(item["signal"]), every = item["every"] as! Int
            for pattern in transcriptionReads {
                var transcription = item["compact"] as! Bool
                    ? ParakeetChunkedTranscription.recording()
                    : ParakeetChunkedTranscription(size: item["size"] as? Int ?? LocalParakeetCore.chunkSamples,
                                                   overlap: item["overlap"] as? Int ?? LocalParakeetCore.chunkOverlapSamples)
                var chunks: [[Int]] = []
                let transcribe: (ParakeetChunk) -> [ParakeetWord] = { chunk in
                    chunks.append([chunk.start, chunk.samples.count])
                    return fakeWords(chunk, every: every)
                }
                for part in split(input, pattern) { transcription.append(part, transcribe: transcribe) }
                let text = transcription.finish(transcribe: transcribe)
                TestSupport.expect(chunks == item["chunks"] as! [[Int]], "transcription \(item["name"]!) reads \(pattern): got \(chunks)")
                TestSupport.expectEqual(text, item["text"] as! String)
            }
        }
    }

    /// The file's fake recognizer: a word at every multiple of `every`, the
    /// chunk's first capitalized and its last ending in "."; none for silence.
    private static func fakeWords(_ chunk: ParakeetChunk, every: Int) -> [ParakeetWord] {
        if chunk.samples.allSatisfy({ $0 == 0 }) { return [] }
        var words = chunk.range.filter { $0 % every == 0 }.map { ParakeetWord(text: "w\($0 / every)", start: $0) }
        if let first = words.first { words[0] = ParakeetWord(text: "W" + first.text.dropFirst(), start: first.start) }
        if let last = words.last { words[words.count - 1] = ParakeetWord(text: last.text + ".", start: last.start) }
        return words
    }

    private static func signal(_ value: Any?) -> [Float] {
        var samples: [Float] = []
        for segment in value as! [[Any]] {
            let count = segment[1] as! Int
            switch segment[0] as! String {
            case "zeros": samples += [Float](repeating: 0, count: count)
            case "nan": samples += [Float](repeating: .nan, count: count)
            case "constant": samples += [Float](repeating: Float(segment[2] as! Double), count: count)
            case "square":
                let amplitude = Float(segment[2] as! Double), half = (segment[3] as! Int) / 2
                samples += (0..<count).map { ($0 / half) % 2 == 0 ? amplitude : -amplitude }
            case "noise":
                let amplitude = Float(segment[2] as! Double)
                var x = UInt64(segment[3] as! Int)
                for _ in 0..<count {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                    samples.append(Float(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648 * amplitude)
                }
            case let kind: fatalError("Unknown signal segment \(kind)")
            }
        }
        return samples
    }

    /// Appends of the pattern's sizes, repeated until the input is used up.
    private static func split(_ samples: [Float], _ pattern: [Int]) -> [[Float]] {
        guard !pattern.isEmpty else { return samples.isEmpty ? [] : [samples] }
        var parts: [[Float]] = [], start = 0, index = 0
        while start < samples.count {
            let end = min(start + pattern[index % pattern.count], samples.count)
            parts.append(Array(samples[start..<end]))
            start = end
            index += 1
        }
        return parts
    }

    private static func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
    }

    private static func parakeetWords(_ value: Any?) -> [ParakeetWord] {
        (value as! [[Any]]).map { ParakeetWord(text: native($0[0] as! String), start: $0[1] as! Int) }
    }

    /// A native Swift string: JSONSerialization returns bridged ones, whose
    /// case mapping may differ from the words the app builds itself.
    private static func native(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }
}
