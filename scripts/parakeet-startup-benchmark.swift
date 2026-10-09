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
            let trace = BucketTrace()
            let service = LocalParakeetService(startupStrategy: strategy, onBucketUsed: { trace.record($0) })
            let clock = ContinuousClock()
            let start = clock.now
            try await service.prepare(directory: directory)
            let preparation = seconds(start.duration(to: clock.now))
            let initialProgress = try await service.preparationProgress(directory: directory)
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
                timings.append(["audio_seconds": duration, "transcription_seconds": elapsed,
                                "expected_match": match, "buckets_used": trace.take()])
                guard match else { throw LocalParakeetError.invalid("Synthetic benchmark mismatch") }
            }
            var backgroundTimes: [Double] = []
            var backgroundMatches = true
            var backgroundBucketCounts: [String: Int] = [:]
            let durations = [2, 4, 7, 14, 18, 33]
            while try await service.preparationProgress(directory: directory).isOptimizing {
                let duration = durations[backgroundTimes.count % durations.count]
                let predictionStart = clock.now
                let text = try await service.transcribe(fileURL: fixtures.appendingPathComponent("synthetic-\(duration).aiff"),
                                                        directory: directory)
                backgroundTimes.append(seconds(predictionStart.duration(to: clock.now)))
                let expected = expectedText(duration)
                backgroundMatches = backgroundMatches && text.lowercased().filter { $0.isLetter || $0.isWhitespace } == expected
                guard backgroundMatches else { throw LocalParakeetError.invalid("Synthetic background mismatch") }
                for bucket in trace.take() { backgroundBucketCounts[String(bucket), default: 0] += 1 }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let backgroundCompletion = seconds(start.duration(to: clock.now))
            let finalProgress = try await service.preparationProgress(directory: directory)
            var optimized: [[String: Any]] = []
            if !strategy.backgroundBuckets.isEmpty {
                guard finalProgress.preparedBuckets == LocalParakeetCore.buckets else {
                    throw LocalParakeetError.invalid("Synthetic optimization did not finish")
                }
                for duration in [2, 4, 7, 14, 18, 33] {
                    let predictionStart = clock.now
                    let text = try await service.transcribe(fileURL: fixtures.appendingPathComponent("synthetic-\(duration).aiff"),
                                                            directory: directory)
                    let elapsed = seconds(predictionStart.duration(to: clock.now))
                    let expected = expectedText(duration)
                    let match = text.lowercased().filter { $0.isLetter || $0.isWhitespace } == expected
                    let buckets = trace.take()
                    let expectedBuckets = duration == 18 ? [30] : duration == 33 ? [30, 4] : [try LocalParakeetCore.bucket(samples: duration * 16000)]
                    guard match, buckets == expectedBuckets else { throw LocalParakeetError.invalid("Synthetic handoff mismatch") }
                    optimized.append(["audio_seconds": duration, "transcription_seconds": elapsed,
                                      "expected_match": match, "buckets_used": buckets])
                }
            }
            let repeatedStart = clock.now
            try await service.prepare(directory: directory)
            var report: [String: Any] = [
                "schema": 1, "strategy": strategy.rawValue, "preparation_seconds": preparation,
                "first_transcript_ready_seconds": firstTranscriptReady,
                "repeated_preparation_seconds": seconds(repeatedStart.duration(to: clock.now)),
                "fixtures": timings, "initial_prepared_buckets": initialProgress.preparedBuckets,
                "final_prepared_buckets": finalProgress.preparedBuckets
            ]
            if !strategy.backgroundBuckets.isEmpty {
                let sorted = backgroundTimes.sorted()
                report["optimization_finished_seconds"] = backgroundCompletion
                report["optimized_fixtures"] = optimized
                report["during_optimization"] = ["samples": sorted.count, "all_expected_matches": backgroundMatches,
                    "bucket_counts": backgroundBucketCounts,
                    "median_seconds": sorted.isEmpty ? NSNull() : sorted[sorted.count / 2] as Any,
                    "p95_seconds": sorted.isEmpty ? NSNull() : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] as Any,
                    "max_seconds": sorted.last.map { $0 as Any } ?? NSNull()]
            }
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
            // Repeats cross the 15s split, end near the 30s window edge and
            // fall in a remainder chunk after 30s.
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
