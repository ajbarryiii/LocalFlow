import Foundation

/// One finished recording on its way to the model. A class, so ownership is explicit: the session core
/// hands it to the transcriber and keeps no other reference, so it is freed as soon as the request ends.
final class RecordedAudio: Sendable {
    let samples: [Float]

    init(samples: [Float]) {
        self.samples = samples
    }

    var duration: TimeInterval { Double(samples.count) / DictationSampleBuffer.sampleRate }
}

/// The host-owned model runtime as the session core sees it.
@MainActor
protocol HostTranscriber: AnyObject {
    var modelState: HostStatus.Model { get }
    /// Starts preparing unless the model is ready or already preparing.
    func prepare()
    /// Waits for readiness, then transcribes. Cancellation ends the wait at once. Throws
    /// `TranscriptionFailure` or `CancellationError`.
    func transcribe(_ audio: RecordedAudio) async throws -> String
    /// Releases the runtime and returns true, or returns false and changes nothing while it is preparing
    /// or transcribing.
    @discardableResult
    func releaseIfIdle() -> Bool
}

/// One loaded speech model: `LocalParakeetService` on the Neural Engine in the app, fakes in tests.
protocol SpeechRuntime: AnyObject, Sendable {
    func prepare() async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Owns the speech model runtime: preparation, readiness and transcription, always on the Neural Engine
/// (contract: "No compute-policy picker"). At most one runtime is alive: it is released only while
/// nothing prepares or transcribes, and a new one is created only after that.
@MainActor
final class TranscriptionEngine: HostTranscriber {
    struct PreparationReport: Sendable {
        var seconds: Double
        var inBackground: Bool
        var succeeded: Bool
    }

    /// One transcription's content-free measurements.
    struct AttemptReport: Sendable {
        enum Outcome: String, Sendable { case transcribed, failed, cancelled }
        var audioSeconds: Double
        /// Waiting for readiness, including preparation when the model was cold.
        var waitSeconds: Double = 0
        var transcriptionSeconds: Double = 0
        var inBackground: Bool
        var outcome: Outcome = .failed
        var hint: ComputeFailureHint?
    }

    private(set) var modelState: HostStatus.Model
    private(set) var preparationStartedAt: Date?
    /// A runtime exists (preparing, ready or transcribing).
    var isLoaded: Bool { loaded != nil }
    /// Preparing, or a transcription is running or waiting.
    var isBusy: Bool { loaded?.readiness == .preparing || activeTranscriptions > 0 }

    var onStateChange: (@MainActor () -> Void)?
    var onPreparation: (@MainActor (PreparationReport) -> Void)?
    var onAttempt: (@MainActor (AttemptReport) -> Void)?

    private let isAvailable: Bool
    private let osMajorVersion: Int
    private let isInBackground: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let makeRuntime: @MainActor () -> SpeechRuntime
    private var loaded: LoadedRuntime?
    private var activeTranscriptions = 0

    init(isAvailable: Bool, osMajorVersion: Int, isInBackground: @escaping @MainActor () -> Bool,
         now: @escaping @MainActor () -> Date = { Date() }, makeRuntime: @escaping @MainActor () -> SpeechRuntime) {
        self.isAvailable = isAvailable
        self.osMajorVersion = osMajorVersion
        self.isInBackground = isInBackground
        self.now = now
        self.makeRuntime = makeRuntime
        modelState = isAvailable ? .notPrepared : .unavailable
    }

    // MARK: HostTranscriber

    func prepare() {
        guard isAvailable else { return setState(.unavailable) }
        guard loaded == nil else { return }
        let handle = LoadedRuntime(runtime: makeRuntime())
        loaded = handle
        let started = now()
        let startedInBackground = isInBackground()
        preparationStartedAt = started
        setState(.preparing)
        Task { [weak self] in
            let succeeded: Bool
            do {
                try await handle.runtime.prepare()
                succeeded = true
            } catch {
                succeeded = false
            }
            handle.finishPreparing(succeeded: succeeded)
            self?.preparationFinished(handle, succeeded: succeeded, started: started, startedInBackground: startedInBackground)
        }
    }

    func transcribe(_ audio: RecordedAudio) async throws -> String {
        guard isAvailable else { throw TranscriptionFailure.modelUnavailable }
        activeTranscriptions += 1
        let startedInBackground = isInBackground()
        var report = AttemptReport(audioSeconds: audio.duration, inBackground: startedInBackground)
        defer {
            activeTranscriptions -= 1
            onAttempt?(report)
        }
        let waitStart = now()
        do {
            try Task.checkCancellation()
            if loaded == nil { prepare() }   // never prepared, released, or failed before
            guard let handle = loaded else { throw TranscriptionFailure.modelFailed }
            try await waitUntilReady(handle)
            // Readiness and a cancellation can resume together: never start work for a cancelled request.
            try Task.checkCancellation()
            report.waitSeconds = now().timeIntervalSince(waitStart)
            let start = now()
            let text = try await run(handle.runtime, audio)
            report.transcriptionSeconds = now().timeIntervalSince(start)
            report.outcome = .transcribed
            return text
        } catch is CancellationError {
            report.outcome = .cancelled
            throw CancellationError()
        } catch let failure as TranscriptionFailure {
            report.hint = ComputePolicy.failureHint(after: failure, inBackground: startedInBackground || isInBackground(),
                                                    osMajorVersion: osMajorVersion)
            throw failure
        }
    }

    @discardableResult
    func releaseIfIdle() -> Bool {
        guard !isBusy else { return false }
        if loaded != nil {
            loaded = nil
            preparationStartedAt = nil
            setState(.notPrepared)
        }
        return true
    }

    // MARK: Private

    private func setState(_ state: HostStatus.Model) {
        guard state != modelState else { return }
        modelState = state
        onStateChange?()
    }

    private func preparationFinished(_ handle: LoadedRuntime, succeeded: Bool, started: Date, startedInBackground: Bool) {
        onPreparation?(PreparationReport(seconds: now().timeIntervalSince(started),
                                         inBackground: startedInBackground || isInBackground(), succeeded: succeeded))
        guard loaded === handle else { return }
        preparationStartedAt = nil
        if succeeded {
            setState(.ready)
        } else {
            loaded = nil   // the next prepare() or transcription retries
            setState(.failed)
        }
    }

    /// Cancellation resumes the wait at once instead of when preparation ends.
    private func waitUntilReady(_ handle: LoadedRuntime) async throws {
        switch handle.readiness {
        case .ready: return
        case .failed: throw TranscriptionFailure.modelFailed
        case .preparing: break
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handle.readinessWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in handle.resumeWaiter(id, with: .failure(CancellationError())) }
        }
    }

    private func run(_ runtime: SpeechRuntime, _ audio: RecordedAudio) async throws -> String {
        do {
            return try await runtime.transcribe(audio.samples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.transcriptionFailed
        }
    }
}

/// A runtime with its readiness and the transcriptions waiting for it.
@MainActor
private final class LoadedRuntime {
    enum Readiness { case preparing, ready, failed }

    let runtime: SpeechRuntime
    var readiness = Readiness.preparing
    var readinessWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(runtime: SpeechRuntime) {
        self.runtime = runtime
    }

    func finishPreparing(succeeded: Bool) {
        readiness = succeeded ? .ready : .failed
        for id in Array(readinessWaiters.keys) {
            resumeWaiter(id, with: succeeded ? .success(()) : .failure(TranscriptionFailure.modelFailed))
        }
    }

    func resumeWaiter(_ id: UUID, with result: Result<Void, Error>) {
        readinessWaiters.removeValue(forKey: id)?.resume(with: result)
    }
}
