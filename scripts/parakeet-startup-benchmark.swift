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
