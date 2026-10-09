#if LOCALFLOW_SELFTEST
import CoreML
import Darwin
import Foundation

/// Self-test builds only. Transcribes an invented synthetic recording with the
/// bundled model and prints one content-free line: never the transcript, the
/// audio path, or error messages.
enum SelfTest {
    private static let defaultPhrase = "The blue lantern is beside the green notebook."

    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOCALFLOW_SELFTEST_AUDIO"], !path.isEmpty else { return }
        // Relative paths resolve inside the app's data container.
        let audio = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        let expected = environment["LOCALFLOW_SELFTEST_EXPECTED"] ?? defaultPhrase
        let cpuOnly = environment["LOCALFLOW_SELFTEST_COMPUTE"] == "cpuOnly"
        Task.detached(priority: .userInitiated) {
            let passed = await run(audio: audio, expected: expected, computeUnits: cpuOnly ? .cpuOnly : .cpuAndNeuralEngine)
            exit(passed ? 0 : 1)
        }
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
                     peakFootprintMB(), availableDevices(), failure))
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

    private static func peakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }
}

private enum SelfTestFailure: Error { case modelMissing }
#endif
