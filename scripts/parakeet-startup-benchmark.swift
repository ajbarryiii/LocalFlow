import AVFoundation
import Foundation

/// Standalone synthetic benchmark. Never opens the app, microphone, settings,
/// history, clipboard or a provider. Output contains timings and match flags only.
@main
struct ParakeetStartupBenchmark {
    static let phrase = "the blue lantern is beside the green notebook"

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 3, args[0] == "fixtures" {
                try makeFixtures(source: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2]))
                return
            }
            if args.count == 4, args[0] == "native-worker" {
                try nativeWorker(bundle: URL(fileURLWithPath: args[1]), fixtures: URL(fileURLWithPath: args[2]),
                                 scratch: URL(fileURLWithPath: args[3]))
                return
            }
            guard args.count == 3, let strategy = ParakeetStartupStrategy(rawValue: args[0]) else {
                throw LocalParakeetError.invalid("Invalid benchmark arguments")
            }
            let directory = URL(fileURLWithPath: args[1])
            let fixtures = URL(fileURLWithPath: args[2])
            let service = LocalParakeetService(startupStrategy: strategy)
            let clock = ContinuousClock()
            let start = clock.now
            try await service.prepare(directory: directory)
            let preparation = seconds(start.duration(to: clock.now))
            var timings: [[String: Any]] = []
            var firstTranscriptReady = 0.0
            for duration in [14, 4, 7, 18] {
                let predictionStart = clock.now
                let text = try await service.transcribe(
                    fileURL: fixtures.appendingPathComponent("synthetic-\(duration).aiff"), directory: directory)
                let elapsed = seconds(predictionStart.duration(to: clock.now))
                if timings.isEmpty { firstTranscriptReady = seconds(start.duration(to: clock.now)) }
                let expected = duration == 18 ? phrase + " " + phrase : phrase
                let normalized = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
                let match = normalized == expected
                timings.append(["audio_seconds": duration, "transcription_seconds": elapsed, "expected_match": match])
                guard match else { throw LocalParakeetError.invalid("Synthetic benchmark mismatch") }
            }
            let repeatedStart = clock.now
            try await service.prepare(directory: directory)
            let report: [String: Any] = [
                "schema": 1, "strategy": strategy.rawValue, "preparation_seconds": preparation,
                "first_transcript_ready_seconds": firstTranscriptReady,
                "repeated_preparation_seconds": seconds(repeatedStart.duration(to: clock.now)),
                "fixtures": timings
            ]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            // Do not print framework errors, transcripts or input paths.
            fputs("Synthetic startup benchmark failed.\n", stderr)
            exit(1)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // A synthetic-only bridge lets the Python MLX experiment reuse the app's
    // actual frontend and FP32 decoder. Only timings and match flags leave it.
    private static func nativeWorker(bundle: URL, fixtures: URL, scratch: URL) throws {
        let frontend = try VDSPFrontEnd(constantsDir: bundle)
        let math = NativeMath(try NativeWeights(directory: bundle))
        let vocab = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: bundle.appendingPathComponent("vocabulary.json")))
        guard vocab.count == 1024, (0..<1024).allSatisfy({ vocab[String($0)] != nil }) else {
            throw LocalParakeetError.invalid("Invalid synthetic benchmark vocabulary")
        }
        let vocabulary = (0..<1024).map { vocab[String($0)]! }
        func reply(_ object: [String: Any]) throws {
            print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
        try reply(["ready": true])
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let duration = request["duration"] as? Int, [4, 7, 14, 18].contains(duration),
                  let operation = request["operation"] as? String else {
                throw LocalParakeetError.invalid("Invalid synthetic benchmark request")
            }
            if operation == "features" {
                var samples: [Float] = []
                try ParakeetAudioReader.read(fileURL: fixtures.appendingPathComponent("synthetic-\(duration).aiff"), check: {}) {
                    samples.append(contentsOf: $0)
                }
                var chunks: [[String: Int]] = []
                for offset in stride(from: 0, to: samples.count, by: LocalParakeetCore.maxSamples) {
                    let pcm = Array(samples[offset..<min(samples.count, offset + LocalParakeetCore.maxSamples)])
                    let result = frontend.compute(pcm)
                    try result.features.withUnsafeBytes { try Data($0).write(to: scratch.appendingPathComponent("features-\(chunks.count).bin")) }
                    chunks.append(["frames": result.frames, "valid": result.valid])
                }
                try reply(["chunks": chunks])
            } else if operation == "decode", let lengths = request["lengths"] as? [Int],
                      lengths.count == (duration == 18 ? 2 : 1), lengths.allSatisfy({ (1...188).contains($0) }) {
                var pieces: [String] = []
                for (index, length) in lengths.enumerated() {
                    let data = try Data(contentsOf: scratch.appendingPathComponent("encoder-\(index).bin"))
                    guard data.count == length * 1024 * 4 else { throw LocalParakeetError.invalid("Invalid synthetic encoder size") }
                    var values = [Float](repeating: 0, count: length * 1024)
                    _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                    guard values.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Nonfinite synthetic encoder") }
                    let frames = try EncoderFrames(timeMajor: FloatBuffer(values), frames: length)
                    let projection = FloatBuffer(count: length * 640)
                    math.project(frames, length: length, into: projection.pointer)
                    var h = [Float](repeating: 0, count: 1280), c = h
                    var g = [Float](repeating: 0, count: 640), z = g, logits = [Float](repeating: 0, count: 1030)
                    let tokens = try LocalParakeetCore.decode(length: length, predict: { token in
                        math.predict(token, h: &h, c: &c, g: &g)
                    }, joint: { frame in
                        let decision = math.joint(f: projection.pointer + frame * 640, g: &g, z: &z, logits: &logits)
                        guard logits.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Nonfinite synthetic decoder") }
                        return decision
                    }, check: {})
                    pieces.append(try LocalParakeetCore.detokenize(tokens, vocabulary: vocabulary))
                }
                let result = pieces.joined(separator: " ").lowercased().filter { $0.isLetter || $0.isWhitespace }
                try reply(["expected_match": result == (duration == 18 ? phrase + " " + phrase : phrase)])
            } else { throw LocalParakeetError.invalid("Unknown synthetic benchmark operation") }
        }
    }

    private static func makeFixtures(source: URL, directory: URL) throws {
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0, file.processingFormat.channelCount == 1,
              Double(file.length) / file.processingFormat.sampleRate < 2.9 else {
            throw LocalParakeetError.invalid("Synthetic speech must be mono and under 2.9 seconds")
        }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for duration in [4, 7, 14, 18] {
            let count = Int(Double(duration) * file.processingFormat.sampleRate)
            let padded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            padded.frameLength = padded.frameCapacity
            let samples = padded.floatChannelData![0]
            samples.initialize(repeating: 0, count: count)
            samples.update(from: input.floatChannelData![0], count: Int(input.frameLength))
            if duration == 18 {
                let offset = Int(15.1 * file.processingFormat.sampleRate)
                guard offset + Int(input.frameLength) <= count else {
                    throw LocalParakeetError.invalid("Synthetic speech exceeds chunk fixture")
                }
                (samples + offset).update(from: input.floatChannelData![0], count: Int(input.frameLength))
            }
            var settings = file.processingFormat.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let output = try AVAudioFile(forWriting: directory.appendingPathComponent("synthetic-\(duration).aiff"), settings: settings)
            try output.write(from: padded)
        }
    }
}
