import Foundation

/// "Find strength": one sentence from the microphone, at most `maxDuration`, kept in memory only
/// (invariant 1). It has its own `MicrophoneCapture` and `DictationSampleBuffer`, so it runs only while
/// no Flow session holds the microphone, and only in the foreground.
@MainActor
final class VoiceSampleRecorder {
    static let maxDuration: TimeInterval = 15
    /// How long `finish()` waits for audio captured before Done that is still in flight.
    static let tailTimeout: TimeInterval = 0.5

    /// The duration cap was reached: the owner should call `finish()`.
    var onLimit: (@MainActor () -> Void)?
    /// The input was lost (interruption, media reset, an engine that cannot restart): the recording is
    /// discarded.
    var onInterrupted: (@MainActor () -> Void)?

    private let buffer = DictationSampleBuffer(maxDuration: VoiceSampleRecorder.maxDuration)
    private var capture: MicrophoneCapture?
    private var requestID: UUID?
    private var generation: UInt64 = 0
    private var tailWaiter: CheckedContinuation<Void, Never>?

    var level: Float { buffer.level }

    var permission: CapturePermission { MicrophoneCapture.currentPermission }

    func requestPermission() async -> Bool { await MicrophoneCapture.requestRecordPermission() }

    func start(useBuiltInMicrophone: Bool) throws {
        cancel()
        let capture = MicrophoneCapture(buffer: buffer) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        capture.router.setDesired(useBuiltInMicrophone)
        capture.onInterruption = { [weak self] in self?.interrupted() }
        capture.onMediaServicesReset = { [weak self] in self?.interrupted() }
        capture.onFailure = { [weak self] generation in self?.engineFailed(generation) }
        try capture.start()
        self.capture = capture
        let id = UUID()
        generation = buffer.begin(requestID: id)
        capture.recordingBoundary()
        requestID = id
    }

    /// Stops at the current capture time and returns the samples once the tail has arrived, or nil when
    /// nothing is recording.
    func finish() async -> [Float]? {
        guard let id = requestID, buffer.close(requestID: id) else { return nil }
        if !buffer.hasReachedLimit, capture?.isRunning == true {
            await withCheckedContinuation { continuation in
                tailWaiter = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.tailTimeout) { [weak self] in
                    MainActor.assumeIsolated { self?.resumeTailWaiter() }
                }
            }
        }
        // A cancel during the wait has already discarded everything.
        guard requestID == id else { return nil }
        let samples = buffer.finish(requestID: id)
        stopCapture()
        return samples
    }

    /// Discards the recording and releases the microphone. Idempotent.
    func cancel() {
        buffer.cancelAll()
        stopCapture()
        resumeTailWaiter()
    }

    private func stopCapture() {
        requestID = nil
        guard let capture else { return }
        capture.recordingBoundary()
        capture.stop()
        self.capture = nil
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .reachedLimit(let generation) where generation == self.generation && requestID != nil:
            onLimit?()
        case .tailComplete(let generation) where generation == self.generation:
            resumeTailWaiter()
        case .conversionFailed(let generation, _) where generation == self.generation && requestID != nil:
            interrupted()
        default:
            break
        }
    }

    /// A configuration change in the foreground: one new engine inside the same audio session, as the
    /// session core does; if that fails, the recording ends.
    private func engineFailed(_ engineGeneration: UInt64) {
        guard let capture, requestID != nil, engineGeneration == capture.engineGeneration else { return }
        do {
            try capture.restart()
        } catch {
            interrupted()
        }
    }

    private func interrupted() {
        guard requestID != nil else { return }
        cancel()
        onInterrupted?()
    }

    private func resumeTailWaiter() {
        tailWaiter?.resume()
        tailWaiter = nil
    }
}
