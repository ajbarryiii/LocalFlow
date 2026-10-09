import Foundation

/// Why a transcription attempt failed, without any content.
enum TranscriptionFailure: Error, Equatable, Sendable {
    /// The build has no model bundle.
    case modelUnavailable
    /// The model could not be prepared (loaded, verified or warmed).
    case modelFailed
    /// The model was ready but transcribing the samples failed.
    case transcriptionFailed

    var errorCode: HostErrorCode {
        switch self {
        case .modelUnavailable: return .modelUnavailable
        case .modelFailed: return .modelFailed
        case .transcriptionFailed: return .transcriptionFailed
        }
    }
}

/// The Diagnostics compute-policy picker. The background loses the GPU, and on iOS 27 the Neural
/// Engine needs an entitlement this prototype does not have yet, so Automatic falls back to the CPU.
enum ComputePolicy: String, CaseIterable, Sendable {
    /// The Neural Engine; a failed background attempt is retried once on a CPU-only model.
    case automatic
    /// The Neural Engine with no fallback, to measure it on its own.
    case neuralEngine
    /// The CPU only.
    case cpuOnly

    /// Core ML compute units, mirrored so this file stays Foundation-only.
    enum Units: String, Sendable { case cpuAndNeuralEngine, cpuOnly }

    static let defaultPolicy = ComputePolicy.automatic

    init(storedValue: String?) {
        self = storedValue.flatMap(ComputePolicy.init(rawValue:)) ?? Self.defaultPolicy
    }

    var primaryUnits: Units { self == .cpuOnly ? .cpuOnly : .cpuAndNeuralEngine }

    /// Whether to retry once on a lazily created CPU-only model. Only Automatic retries, only in the
    /// background (where Neural Engine loss is expected), and only failures a CPU model could avoid:
    /// a missing bundle or a cancellation is final.
    func retriesOnCPU(after failure: TranscriptionFailure, inBackground: Bool, alreadyRetried: Bool) -> Bool {
        guard self == .automatic, inBackground, !alreadyRetried else { return false }
        return failure == .modelFailed || failure == .transcriptionFailed
    }
}
