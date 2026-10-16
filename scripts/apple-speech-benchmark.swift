import AVFoundation
import Foundation
import os
import Speech

/// Standalone accuracy and speed comparison on public LibriSpeech audio. Build
/// with Sources/Parakeet and Sources/Dictionary; driven by scripts/benchmark-apple-speech.py.
/// Never opens the app, microphone, settings, history, clipboard or a provider.
/// Usage: apple-speech-benchmark ENGINE BUNDLE MANIFEST.tsv. Writes one JSON
/// line per utterance to stdout. Preparation and one warmup are untimed.
@main
struct AppleSpeechBenchmark {
    static let locale = Locale(identifier: "en-US")

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3 else { throw BenchmarkError("Usage: ENGINE BUNDLE MANIFEST") }
            let items = try String(contentsOfFile: args[2], encoding: .utf8)
                .split(separator: "\n").map { line -> (String, URL) in
                    let fields = line.split(separator: "\t", maxSplits: 1)
                    guard fields.count == 2 else { throw BenchmarkError("Invalid manifest line") }
                    return (String(fields[0]), URL(fileURLWithPath: String(fields[1])))
                }
            guard let first = items.first else { return }
            let transcribe = try await engine(args[0], bundle: URL(fileURLWithPath: args[1]))
            _ = try await transcribe(first.1)
            let clock = ContinuousClock()
            for (identifier, url) in items {
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.fileFormat.sampleRate
                let start = clock.now
                var hypothesis = "", failure: String?
                do { hypothesis = try await transcribe(url) } catch { failure = String(describing: type(of: error)) }
                let elapsed = start.duration(to: clock.now)
                var record: [String: Any] = ["id": identifier, "hypothesis": hypothesis, "duration": duration,
                                             "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18]
                if let failure { record["error"] = failure }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                fflush(stdout)
            }
        } catch {
            fputs("Speech benchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func engine(_ name: String, bundle: URL) async throws -> (URL) async throws -> String {
        switch name {
        case "localflow":
            let service = LocalParakeetService.shared
            try await service.prepare(directory: bundle)
            // Steady-state dictation: wait until every encoder function is ready.
            while try await service.preparationProgress(directory: bundle).isOptimizing {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return { try await service.transcribe(fileURL: $0, directory: bundle) }
        case "speech-transcriber":
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw BenchmarkError("SpeechTranscriber is unavailable for en-US")
            }
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            return { url in
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
                let collector = Task {
                    try await transcriber.results.reduce(into: [String]()) { $0.append(String($1.text.characters)) }
                }
                let file = try AVAudioFile(forReading: url)
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await collector.value.joined(separator: " ")
            }
        case "sf-speech-recognizer":
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw BenchmarkError("Speech Recognition permission was not granted") }
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                throw BenchmarkError("On-device SFSpeechRecognizer is unavailable for en-US")
            }
            recognizer.queue = OperationQueue()
            return { url in try await recognize(url, with: recognizer) }
        default:
            throw BenchmarkError("Unknown engine")
        }
    }

    static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let finished = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                guard result?.isFinal == true || error != nil else { return }
                guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else {
                    continuation.resume(throwing: error ?? BenchmarkError("Recognition ended without a result"))
                }
            }
        }
    }
}

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
