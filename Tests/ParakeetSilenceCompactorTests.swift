import Foundation

/// Silence is shortened before chunking; speech must reach the model intact.
/// Invented signals only: tones, seeded noise and zeros at 16 kHz.
enum ParakeetSilenceCompactorTests {
    static let margin = ParakeetSilenceCompactor.defaultMargin
    static let pause = ParakeetSilenceCompactor.defaultInteriorPause
    // A long interior pause keeps its first half and its last half.
    static let head = pause / 2, tail = pause - pause / 2

    static func run() {
        TestSupport.expectEqual(margin, s(0.3))
        TestSupport.expect(pause >= 2 * margin, "A kept pause must hold both edge margins")
        testEdges()
        testInteriorPauses()
        testQuietSpeechOverNoise()
        testSustainedSound()
        testWeakOnsetsAndEndings()
        testNoSpeech()
        testInvalidSamplesReachTheModel()
        testSplitInvariance()
        testBoundedPieces()
        testChunkedTranscription()
    }

    // A whole recording appended at once is emitted in bounded pieces, so the
    // compactor never builds a second full-size copy.
    private static func testBoundedPieces() {
        let limit = ParakeetSilenceCompactor.maxPieceSamples
        for (input, expected) in [(tone(60, level: -20), tone(60, level: -20)),
                                  (zeros(3) + tone(60, level: -20) + zeros(3), zeros(0.3) + tone(60, level: -20) + zeros(0.3)),
                                  (zeros(60), zeros(60))] {
            var compactor = ParakeetSilenceCompactor(), pieces: [[Float]] = []
            compactor.append(input) { pieces.append($0) }
            compactor.finish { pieces.append($0) }
            TestSupport.expect(pieces.count >= expected.count / limit, "A long recording must be emitted in several pieces")
            TestSupport.expect(pieces.allSatisfy { !$0.isEmpty && $0.count <= limit }, "Every piece must be bounded")
            TestSupport.expectEqual(Array(pieces.joined()), expected)
        }
    }

    // Leading silence keeps its last margin, trailing silence its first, and a
    // partial final frame of speech is kept.
    private static func testEdges() {
        let speech = tone(1, level: -20)
        TestSupport.expectEqual(compact(zeros(2) + speech + zeros(2)), zeros(0.3) + speech + zeros(0.3))
        TestSupport.expectEqual(compact(zeros(0.1) + speech + zeros(0.2)), zeros(0.1) + speech + zeros(0.2))
        TestSupport.expectEqual(compact(speech), speech)
        let ragged = tone(0.5, level: -20) + Array(tone(0.01, level: -20).prefix(37))
        TestSupport.expectEqual(compact(zeros(2) + ragged), zeros(0.3) + ragged)
    }

    // A pause longer than the kept pause becomes exactly the kept pause: its
    // first half after speech and its last half before the next. Shorter
    // pauses, which cue phrasing and punctuation, pass through untouched.
    // The edges keep only a margin whatever the kept pause.
    private static func testInteriorPauses() {
        let first = tone(1, level: -20, frequency: 300), second = tone(1, level: -20, frequency: 500)
        let lengths = [(s(0.3), s(0.6)), (s(0.3), s(0.8) + 1), (s(0.3), s(1.2)), (s(0.2), s(1)), (margin, pause)]
        for (margin, pause) in lengths {
            let compactor = ParakeetSilenceCompactor(margin: margin, interiorPause: pause)
            let head = pause / 2, tail = pause - head
            // Silence-level noise shows which part of a pause is kept. Speech is
            // decided per 10 ms frame, so pauses here are whole frames.
            let frames = pause / 160 * 160
            for length in [s(0.1), frames - 160, frames, frames + 160, s(3), s(8)] {
                let gap = Array(noise(8, level: -75, seed: 13).prefix(length))
                let kept = length <= pause ? gap : Array(gap.prefix(head) + gap.suffix(tail))
                TestSupport.expectEqual(compact(first + gap + second, compactor), first + kept + second)
                TestSupport.expectEqual(compact(zeros(4) + first + gap + second + zeros(4), compactor, reads: [4096]),
                                        Array(zeros(4).suffix(margin)) + first + kept + second + Array(zeros(4).prefix(margin)))
            }
            // A pause is cut only where it is silent throughout: a click inside
            // it is kept with a whole kept pause on each side.
            let click = tone(0.01, level: -20), around = [Float](repeating: 0, count: pause)
            TestSupport.expectEqual(compact(first + zeros(4) + click + zeros(4) + second, compactor),
                                    first + around + click + around + second)
        }
    }

    // Quiet speech over a room's noise, a noisy fan and a low-gain microphone:
    // the noise floor is learned, and the speech is kept with its margins.
    private static func testQuietSpeechOverNoise() {
        for (floor, level) in [(-60.0, -35.0), (-50.0, -35.0), (-72.0, -45.0)] {
            let room = noise(8, level: floor, seed: 7)
            let burst = tone(1, level: level)
            var input = room
            add(burst, to: &input, at: s(2))
            add(burst, to: &input, at: s(5))
            let expected = Array(input[s(1.7)..<(s(3) + head)]) + Array(input[(s(5) - tail)..<s(6.3)])
            TestSupport.expectEqual(compact(input), expected)
        }
        // Noise-shaped speech is kept as well.
        var input = noise(8, level: -60, seed: 3)
        add(noise(2, level: -30, seed: 4), to: &input, at: s(3))
        TestSupport.expectEqual(compact(input), Array(input[s(2.7)..<s(5.3)]))
    }

    // A long steady sound at speech level, or a held quiet vowel, is never
    // learned as the noise floor and chopped.
    private static func testSustainedSound() {
        for (seconds, level) in [(10.0, -26.0), (4.0, -35.0), (12.0, -35.0), (20.0, -40.0)] {
            var input = noise(seconds + 4, level: -60, seed: 11)
            add(noise(seconds, level: level, seed: 12), to: &input, at: s(2))
            TestSupport.expectEqual(compact(input), Array(input[s(1.7)..<s(2 + seconds + 0.3)]))
        }
    }

    // Low-energy onsets and word endings, such as "h" or a trailing "s",
    // stay inside the kept margins, including right after a long silence.
    private static func testWeakOnsetsAndEndings() {
        let weak = noise(0.2, level: -65, seed: 5), speech = tone(1, level: -20)
        TestSupport.expectEqual(compact(zeros(4) + weak + speech + weak + zeros(4)),
                                zeros(0.1) + weak + speech + weak + zeros(0.1))
        TestSupport.expectEqual(compact(speech + zeros(5) + weak + speech),
                                speech + [Float](repeating: 0, count: pause - weak.count) + weak + speech)
    }

    // Without speech the model hears the recording unchanged.
    private static func testNoSpeech() {
        TestSupport.expectEqual(compact([]), [])
        for input in [zeros(5), noise(5, level: -60, seed: 9), noise(5, level: -50, seed: 9),
                      Array(zeros(1).prefix(1234)), [Float(0.5)]] {
            TestSupport.expectEqual(compact(input), input)
            TestSupport.expectEqual(compact(input, reads: [7, 160, 4096]), input)
        }
        // A finished compactor starts over.
        var compactor = ParakeetSilenceCompactor()
        compactor.append(tone(1, level: -20) + zeros(1)) { _ in }
        compactor.finish { _ in }
        compactor.finish { _ in fatalError("A finished compactor must not emit again") }
        var output: [Float] = []
        compactor.append(zeros(1)) { output += $0 }
        compactor.finish { output += $0 }
        TestSupport.expectEqual(output, zeros(1))
    }

    // Invalid samples are not silence; they reach the model, which rejects them.
    private static func testInvalidSamplesReachTheModel() {
        var pause = zeros(3)
        pause[s(1.5)] = .nan
        let output = compact(tone(1, level: -20) + pause + tone(1, level: -20))
        TestSupport.expectEqual(output.filter(\.isNaN).count, 1)
    }

    // The same recording gives the same output however it is read.
    private static func testSplitInvariance() {
        var input = noise(9, level: -55, seed: 21)
        add(tone(1.3, level: -30), to: &input, at: s(1.25) + 3)
        add(noise(0.4, level: -25, seed: 22), to: &input, at: s(2.95))
        add(tone(0.8, level: -40), to: &input, at: s(6.1) + 77)
        input += zeros(1) + tone(0.5, level: -20) + Array(zeros(0.01).prefix(91))
        let whole = compact(input)
        TestSupport.expect(whole.count < input.count, "The fixture must contain compacted silence")
        for reads in [[1], [7], [159], [160], [161], [4096], [8192], [3, 500, 1, 16_000, 160]] {
            TestSupport.expectEqual(compact(input, reads: reads), whole)
        }
    }

    // A chunked transcription with a compactor chunks the compacted audio: any
    // split into appends gives the chunks and text of one append, and the
    // chunks cover the compacted audio exactly.
    private static func testChunkedTranscription() {
        let input = zeros(1) + tone(2, level: -20) + zeros(4) + tone(1.5, level: -20, frequency: 300) + zeros(2)
        let compacted = compact(input)
        TestSupport.expect(compacted.count < input.count, "The fixture must contain compacted silence")
        func transcribe(_ reads: [Int]) -> (text: String, chunks: [ParakeetChunk]) {
            var transcription = ParakeetChunkedTranscription(size: s(1), overlap: s(0.25), compactor: ParakeetSilenceCompactor())
            var chunks: [ParakeetChunk] = [], start = 0, index = 0
            func words(_ chunk: ParakeetChunk) -> [ParakeetWord] {
                chunks.append(chunk)
                return [ParakeetWord(text: "w\(chunk.start).", start: chunk.start)]
            }
            repeat {
                let end = min(start + (reads.isEmpty ? input.count : reads[index % reads.count]), input.count)
                transcription.append(Array(input[start..<end]), transcribe: words)
                start = end
                index += 1
            } while start < input.count
            return (transcription.finish(transcribe: words), chunks)
        }
        let whole = transcribe([])
        TestSupport.expectEqual(whole.chunks.first?.start, 0)
        TestSupport.expectEqual(whole.chunks.last?.range.upperBound, compacted.count)
        TestSupport.expect(whole.chunks.allSatisfy { Array(compacted[$0.range]) == $0.samples },
                           "Every chunk must hold the compacted audio at its range")
        for reads in [[1], [160], [4096], [s(3)], [3, 500, 16_000, 7]] {
            let split = transcribe(reads)
            TestSupport.expectEqual(split.chunks, whole.chunks)
            TestSupport.expectEqual(split.text, whole.text)
        }
    }

    // MARK: Synthetic signals

    /// Feeds `input` in reads cycling through `reads` (all at once by default).
    static func compact(_ input: [Float], _ compactor: ParakeetSilenceCompactor = .init(),
                        reads: [Int] = []) -> [Float] {
        var compactor = compactor, output: [Float] = [], start = 0, index = 0
        repeat {
            let count = reads.isEmpty ? input.count : reads[index % reads.count]
            let end = min(start + count, input.count)
            compactor.append(Array(input[start..<end])) { piece in
                TestSupport.expect(!piece.isEmpty, "The compactor must not emit empty pieces")
                output += piece
            }
            start = end
            index += 1
        } while start < input.count
        compactor.finish { output += $0 }
        return output
    }

    static func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }

    static func zeros(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: s(seconds)) }

    /// A sine whose RMS is `level` dB relative to full scale.
    static func tone(_ seconds: Double, level: Double, frequency: Double = 440) -> [Float] {
        let amplitude = pow(10, level / 20) * 2.0.squareRoot()
        return (0..<s(seconds)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 16_000)) }
    }

    /// Uniform white noise from a seeded generator, with RMS `level` dB.
    static func noise(_ seconds: Double, level: Double, seed: UInt64) -> [Float] {
        let amplitude = pow(10, level / 20) * 3.0.squareRoot()
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<s(seconds)).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(amplitude * (Double(state >> 11) / Double(1 << 53) * 2 - 1))
        }
    }

    static func add(_ signal: [Float], to input: inout [Float], at start: Int) {
        for (offset, sample) in signal.enumerated() { input[start + offset] += sample }
    }
}
