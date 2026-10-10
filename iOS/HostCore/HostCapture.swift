import Foundation

enum CapturePermission: Equatable, Sendable { case undetermined, denied, granted }

/// The session's audio input: `MicrophoneCapture` in the app, a synthetic source in self-test builds and
/// a fake in tests. Its `CapturePipeline` appends to the session's `DictationSampleBuffer` on the capture
/// thread and reports through `HostSessionCore.captureDelivered(_:)`.
@MainActor
protocol HostCapture: AnyObject {
    var permission: CapturePermission { get }
    /// Shows the system prompt; call only in the foreground.
    func requestPermission() async -> Bool
    /// Configures and activates the audio session, then starts the engine. Foreground only: this is
    /// what starts a session.
    func start() throws
    /// Rebuilds and starts the engine inside the audio session that is already active, without
    /// activating anything, so it is allowed in the background. Throws when that session is gone.
    func restart() throws
    /// Applies changed capture settings (the microphone choice) inside the active session: category,
    /// preferred input and a new engine. Foreground only.
    func reconfigure() throws
    /// Settings changed while they could not be applied (in the background): reconfigure once in front.
    var needsReconfiguration: Bool { get }
    /// Stops the engine and deactivates the audio session. Idempotent.
    func stop()
    var isRunning: Bool { get }
    /// When the latest input buffer arrived, whether or not it was kept.
    var lastBufferAt: Date? { get }
    /// Increases with every start and restart. Failure reports carry it, so a notification queued for
    /// an engine that has since been replaced is ignored.
    var engineGeneration: UInt64 { get }
    /// A recording began, was drained or was discarded: clear converter state now.
    func recordingBoundary()
}

/// What the capture thread reports to the session core. `.accepted` and `.dropped` appends need no
/// attention and are not reported.
enum CaptureEvent: Equatable, Sendable {
    /// The first samples of recording `generation` arrived.
    case started(generation: UInt64)
    /// Recording `generation` filled the buffer to the maximum duration.
    case reachedLimit(generation: UInt64)
    /// Input for recording `generation` repeatedly failed to convert in engine `engine`'s pipeline. The
    /// engine generation fences the report: one queued before the engine was replaced is ignored.
    case conversionFailed(generation: UInt64, engine: UInt64)
    /// Closing recording `generation` has received every frame captured before its end.
    case tailComplete(generation: UInt64)

    init?(_ outcome: DictationSampleBuffer.AppendOutcome) {
        switch outcome {
        case .dropped, .accepted: return nil
        case .started(let generation): self = .started(generation: generation)
        case .reachedLimit(let generation): self = .reachedLimit(generation: generation)
        }
    }
}

/// Stands in for an input that was requested but cannot work (a self-test build whose synthetic
/// recording is unreadable). Every start fails, so the session fails closed instead of falling back to
/// the real microphone.
@MainActor
final class UnavailableCapture: HostCapture {
    struct Unavailable: Error {}

    var permission: CapturePermission { .granted }
    func requestPermission() async -> Bool { false }
    func start() throws { throw Unavailable() }
    func restart() throws { throw Unavailable() }
    func reconfigure() throws { throw Unavailable() }
    var needsReconfiguration: Bool { false }
    func stop() {}
    var isRunning: Bool { false }
    var lastBufferAt: Date? { nil }
    var engineGeneration: UInt64 { 0 }
    func recordingBoundary() {}
}

/// How a self-test build asked for its input.
enum SyntheticInputRequest {
    /// No synthetic input: use the microphone.
    case notRequested
    case ready(HostCapture)
    /// Requested, but unusable: never fall back to the microphone.
    case unusable

    /// The capture for this request. `makeMicrophone` runs only when no synthetic input was requested.
    @MainActor
    func capture(orMicrophone makeMicrophone: () -> HostCapture) -> HostCapture {
        switch self {
        case .notRequested: return makeMicrophone()
        case .ready(let capture): return capture
        case .unusable: return UnavailableCapture()
        }
    }
}
