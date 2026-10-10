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

/// A content-free explanation Diagnostics shows for a failed transcription.
enum ComputeFailureHint: String, Sendable {
    /// A background attempt failed on iOS 27 or later, where background Neural Engine use needs the
    /// continued-processing inference entitlement this prototype does not have.
    case backgroundNeuralEngineNeedsEntitlement
}

/// The compute policy is fixed (contract: "No compute-policy picker"): the live app always uses the
/// Neural Engine, about 165 MB at peak with its preparation cached across launches. The CPU runtime
/// (about 3.2 GB) is measured only by the self-test, and nothing ever falls back to it.
enum ComputePolicy {
    /// Core ML compute units, mirrored so this file stays Foundation-only.
    enum Units: String, Sendable { case cpuAndNeuralEngine, cpuOnly }

    /// What the live app loads.
    static let units = Units.cpuAndNeuralEngine
    /// The first iOS on which background Neural Engine use needs an entitlement.
    static let backgroundEntitlementOSVersion = 27

    /// The hint for a failure, if one applies: a model or transcription failure in the background on iOS
    /// 27 or later most likely means the missing entitlement. The request fails either way.
    static func failureHint(after failure: TranscriptionFailure, inBackground: Bool,
                            osMajorVersion: Int) -> ComputeFailureHint? {
        guard failure == .modelFailed || failure == .transcriptionFailed, inBackground,
              osMajorVersion >= backgroundEntitlementOSVersion else { return nil }
        return .backgroundNeuralEngineNeedsEntitlement
    }
}
