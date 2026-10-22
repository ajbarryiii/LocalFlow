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
            guard args.count == 2 else { throw LocalParakeetError.invalid("Invalid benchmark arguments") }
            let directory = URL(fileURLWithPath: args[0])
            let fixtures = URL(fileURLWithPath: args[1])
            let trace = BucketTrace()
            let service = LocalParakeetService(onBucketUsed: { trace.record($0) })
            let clock = ContinuousClock()
            let start = clock.now
            try await service.prepare(directory: directory)
            let preparation = seconds(start.duration(to: clock.now))
            var timings: [[String: Any]] = []
            var firstTranscriptReady = 0.0
            for duration in [14, 2, 4, 7, 18, 33] {
                let predictionStart = clock.now
                let text = try await service.transcribe(
                    fileURL: fixtures.appendingPathComponent("synthetic-\(duration).aiff"), directory: directory)
                let elapsed = seconds(predictionStart.duration(to: clock.now))
                if timings.isEmpty { firstTranscriptReady = seconds(start.duration(to: clock.now)) }
                let expected = expectedText(duration)
                let normalized = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
                let match = normalized == expected
                // Every encoder pass, of any recording, uses the 15 s function.
                let buckets = trace.take()
                timings.append(["audio_seconds": duration, "transcription_seconds": elapsed,
                                "expected_match": match, "buckets_used": buckets])
                guard match, !buckets.isEmpty, buckets.allSatisfy({ $0 == LocalParakeetCore.encoderSeconds }) else {
                    throw LocalParakeetError.invalid("Synthetic benchmark mismatch")
                }
            }
            let repeatedStart = clock.now
            try await service.prepare(directory: directory)
            let report: [String: Any] = [
                "schema": 2, "encoder_seconds": LocalParakeetCore.encoderSeconds, "preparation_seconds": preparation,
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

    // Additional phrase starts after the one at 0s. Each phrase is under 1.9s.
    private static let repeatOffsets: [Int: [Double]] = [18: [15.1], 33: [15.1, 27.5, 30.5]]

    private static func expectedText(_ duration: Int) -> String {
        Array(repeating: phrase, count: 1 + (repeatOffsets[duration]?.count ?? 0)).joined(separator: " ")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func makeFixtures(source: URL, directory: URL) throws {
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0, file.processingFormat.channelCount == 1,
              Double(file.length) / file.processingFormat.sampleRate < 1.9 else {
            throw LocalParakeetError.invalid("Synthetic speech must be mono and under 1.9 seconds")
        }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for duration in [2, 4, 7, 14, 18, 33] {
            let count = Int(Double(duration) * file.processingFormat.sampleRate)
            let padded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            padded.frameLength = padded.frameCapacity
            let samples = padded.floatChannelData![0]
            samples.initialize(repeating: 0, count: count)
            samples.update(from: input.floatChannelData![0], count: Int(input.frameLength))
            // Repeats follow long pauses, which are shortened before chunking.
            for start in repeatOffsets[duration] ?? [] {
                let offset = Int(start * file.processingFormat.sampleRate)
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

    private final class BucketTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var buckets: [Int] = []
        func record(_ bucket: Int) { lock.lock(); buckets.append(bucket); lock.unlock() }
        func take() -> [Int] {
            lock.lock(); defer { lock.unlock() }
            let result = buckets; buckets.removeAll(); return result
        }
    }
}
