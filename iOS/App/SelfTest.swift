#if LOCALFLOW_SELFTEST
import CoreML
import Darwin
import Foundation

/// Self-test builds only. Options come from the launch environment (`SIMCTL_CHILD_…`):
/// - `LOCALFLOW_SELFTEST_AUDIO=<path>`: transcribes an invented synthetic recording with the bundled
///   model and prints one content-free line, never the transcript, the audio path or error messages,
///   then exits. `LOCALFLOW_SELFTEST_EXPECTED` and `LOCALFLOW_SELFTEST_COMPUTE=cpuOnly` refine it.
/// - `LOCALFLOW_SYNTHETIC_MIC=<path>`: replaces the microphone with that recording (`SyntheticCapture`).
/// - `LOCALFLOW_SELFTEST_SKIP_ONBOARDING=1`: lands on Home.
/// - `LOCALFLOW_SELFTEST_SCREEN=<screen>`: opens one screen, for screenshots without taps.
/// - `LOCALFLOW_SELFTEST_START_SESSION=1`: starts a session once the app is active.
///
/// Relative paths resolve inside the app's data container.
enum SelfTest {
    private static let defaultPhrase = "The blue lantern is beside the green notebook."
    private static let environment = ProcessInfo.processInfo.environment

    /// Screens `LOCALFLOW_SELFTEST_SCREEN` can open.
    enum Screen: String {
        case onboarding, onboardingMicrophone = "onboarding-microphone", onboardingKeyboard = "onboarding-keyboard",
             onboardingModel = "onboarding-model", home, tryIt = "tryit", keyboardSetup = "keyboard-setup", diagnostics
    }

    static var launchOptions: LaunchOptions {
        var options = LaunchOptions()
        options.skipOnboarding = environment["LOCALFLOW_SELFTEST_SKIP_ONBOARDING"] == "1"
        options.startSession = environment["LOCALFLOW_SELFTEST_START_SESSION"] == "1"
        switch environment["LOCALFLOW_SELFTEST_SCREEN"].flatMap(Screen.init(rawValue:)) {
        case .onboarding?: options.onboardingStep = .welcome
        case .onboardingMicrophone?: options.onboardingStep = .microphone
        case .onboardingKeyboard?: options.onboardingStep = .keyboard
        case .onboardingModel?: options.onboardingStep = .model
        case .home?: options.skipOnboarding = true
        case .tryIt?: options.skipOnboarding = true; options.homePath = [.tryIt]
        case .keyboardSetup?: options.skipOnboarding = true; options.homePath = [.keyboardSetup]
        case .diagnostics?: options.skipOnboarding = true; options.homePath = [.diagnostics]
        case nil: break
        }
        return options
    }

    /// The synthetic microphone, if `LOCALFLOW_SYNTHETIC_MIC` names a readable recording. Prints one
    /// content-free line either way, so a test can tell a missing file from a silent one.
    @MainActor
    static func syntheticCapture(buffer: DictationSampleBuffer,
                                 deliver: @escaping @Sendable (DictationSampleBuffer.AppendOutcome) -> Void) -> HostCapture? {
        guard let path = environment["LOCALFLOW_SYNTHETIC_MIC"], !path.isEmpty else { return nil }
        var samples: [Float] = []
        do {
            try ParakeetAudioReader.read(fileURL: resolve(path), check: {}) { samples.append(contentsOf: $0) }
        } catch {
            print("LocalFlow self-test: synthetic_mic=unreadable")
            fflush(stdout)
            return nil
        }
        print(String(format: "LocalFlow self-test: synthetic_mic=loaded audio_s=%.2f",
                     Double(samples.count) / DictationSampleBuffer.sampleRate))
        fflush(stdout)
        return SyntheticCapture(samples: samples, buffer: buffer, deliver: deliver)
    }

    /// One content-free line per dictation, so end-to-end runs record latency and memory.
    static func report(_ measurement: DictationMeasurement) {
        print(String(format: "LocalFlow self-test: dictation outcome=%@ audio_s=%.2f wait_ms=%.0f transcription_ms=%.0f compute=%@ background=%@ footprint_mb=%.0f peak_footprint_mb=%.0f",
                     measurement.outcome.rawValue, measurement.audioSeconds, measurement.waitMilliseconds,
                     measurement.transcriptionMilliseconds, measurement.computeUnits.replacingOccurrences(of: " ", with: "_"),
                     String(measurement.inBackground), measurement.footprint?.currentMB ?? -1,
                     measurement.footprint?.peakMB ?? -1))
        fflush(stdout)
    }

    static func report(_ preparation: PreparationMeasurement) {
        print(String(format: "LocalFlow self-test: preparation result=%@ seconds=%.1f compute=%@ background=%@ footprint_mb=%.0f peak_footprint_mb=%.0f",
                     preparation.succeeded ? "ready" : "failed", preparation.seconds,
                     preparation.computeUnits.replacingOccurrences(of: " ", with: "_"), String(preparation.inBackground),
                     preparation.footprint?.currentMB ?? -1, preparation.footprint?.peakMB ?? -1))
        fflush(stdout)
    }

    static func startIfRequested() {
        guard let path = environment["LOCALFLOW_SELFTEST_AUDIO"], !path.isEmpty else { return }
        let audio = resolve(path)
        let expected = environment["LOCALFLOW_SELFTEST_EXPECTED"] ?? defaultPhrase
        let cpuOnly = environment["LOCALFLOW_SELFTEST_COMPUTE"] == "cpuOnly"
        Task.detached(priority: .userInitiated) {
            let passed = await run(audio: audio, expected: expected, computeUnits: cpuOnly ? .cpuOnly : .cpuAndNeuralEngine)
            exit(passed ? 0 : 1)
        }
    }

    private static func resolve(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    private static func run(audio: URL, expected: String, computeUnits: MLComputeUnits) async -> Bool {
        let appGroup = appGroupState()
        var stage = "model", failure = "none", matched = false
        var preparation = -1.0, transcription = -1.0, seconds = 0.0
        do {
            guard LocalParakeetService.isAvailable, let directory = LocalParakeetService.bundleDirectory else {
                throw SelfTestFailure.modelMissing
            }
            let service = LocalParakeetService(startupStrategy: .fifteenSecondsFirst, computeUnits: computeUnits)
            stage = "prepare"
            var start = Date()
            try await service.prepare(directory: directory)
            preparation = Date().timeIntervalSince(start)
            stage = "read"
            var samples: [Float] = []
            try ParakeetAudioReader.read(fileURL: audio, check: {}) { samples.append(contentsOf: $0) }
            seconds = Double(samples.count) / Double(LocalParakeetCore.sampleRate)
            stage = "transcribe"
            start = Date()
            let text = try await service.transcribe(samples: samples)
            transcription = Date().timeIntervalSince(start)
            stage = "compare"
            matched = normalized(text) == normalized(expected)
            stage = "done"
        } catch {
            failure = describe(error)
        }
        let passed = matched && appGroup == "usable"
        print(String(format: "LocalFlow self-test: result=%@ stage=%@ transcript_match=%@ app_group=%@ compute=%@ preparation_s=%.3f transcription_s=%.3f audio_s=%.2f peak_footprint_mb=%.0f available_devices=%@ error=%@",
                     passed ? "pass" : "fail", stage, String(matched), appGroup,
                     computeUnits == .cpuOnly ? "cpuOnly" : "cpuAndNeuralEngine", preparation, transcription, seconds,
                     ProcessMemory.footprint()?.peakMB ?? -1, availableDevices(), failure))
        return passed
    }

    // Resolves the container and proves it is writable with an empty probe file.
    private static func appGroupState() -> String {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "LocalFlowAppGroupIdentifier") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return "unresolved"
        }
        let probe = container.appendingPathComponent(".localflow-selftest-\(UUID().uuidString)")
        guard (try? Data().write(to: probe)) != nil else { return "unwritable" }
        try? FileManager.default.removeItem(at: probe)
        return "usable"
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Error class only; messages could carry details we do not print.
    private static func describe(_ error: Error) -> String {
        if error is LocalParakeetError || error is SelfTestFailure || error is CancellationError {
            return String(describing: type(of: error))
        }
        let error = error as NSError
        return "\(error.domain):\(error.code)"
    }

    private static func availableDevices() -> String {
        MLModel.availableComputeDevices.map { device -> String in
            switch device {
            case .cpu: return "cpu"
            case .gpu: return "gpu"
            case .neuralEngine: return "ane"
            @unknown default: return "other"
            }
        }.joined(separator: ",")
    }
}

private enum SelfTestFailure: Error { case modelMissing }
#endif
