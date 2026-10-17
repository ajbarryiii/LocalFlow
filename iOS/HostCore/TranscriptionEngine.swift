import Foundation

/// One finished recording on its way to the model. A class, so ownership is explicit: the session core
/// hands it to the transcriber and keeps no other reference, so it is freed as soon as the request ends.
final class RecordedAudio: Sendable {
    let samples: [Float]
    /// The transcription that was fed exactly `samples` while they were recorded, if any.
    let stream: SpeechStream?

    init(samples: [Float], stream: SpeechStream? = nil) {
        self.samples = samples
        self.stream = stream
    }

    var duration: TimeInterval { Double(samples.count) / DictationSampleBuffer.sampleRate }
}

/// The host-owned model runtime as the session core sees it.
@MainActor
protocol HostTranscriber: AnyObject {
    var modelState: HostStatus.Model { get }
    /// Starts preparing unless the model is ready or already preparing.
    func prepare()
    /// A transcription fed while the next recording is recorded, or nil unless the model is ready: the
    /// recording is then transcribed after it ends. Give it back in `RecordedAudio`, or cancel it.
    func beginStream() -> SpeechStream?
    /// Waits for readiness, then transcribes; with `audio.stream`, finishes the stream instead and falls
    /// back to the samples only if it fails. Cancellation ends the wait at once and cancels the stream.
    /// Throws `TranscriptionFailure` or `CancellationError`.
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
    /// A transcription fed while recording, whose `finish` returns what `transcribe` returns for the
    /// samples appended; nil when it cannot stream. Only on a prepared runtime. `onEnd` runs once, on
    /// any thread, when the stream is finished or cancelled and its model work has fully drained.
    @MainActor func beginStream(onEnd: @escaping @Sendable () -> Void) -> SpeechStream?
}

/// A recording transcribed while it is recorded (`LocalParakeetService`'s streaming session in the app).
protocol SpeechStream: AnyObject, Sendable {
    /// 16 kHz mono samples in recording order, from the capture thread; never waits for model work.
    func append(_ samples: [Float])
    /// The transcription of every appended sample. Call once.
    func finish() async throws -> String
    /// Drops the audio and any partial result. Idempotent; a later `finish` throws `CancellationError`.
    func cancel()
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
    /// Preparing, a transcription or `withReadyRuntime` operation is running or waiting, or a stream's
    /// model work has not drained.
    var isBusy: Bool { loaded?.readiness == .preparing || activeTranscriptions > 0 || activeStreams > 0 }

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
    /// Streams begun whose model work has not drained: the runtime is neither released nor replaced.
    private var activeStreams = 0

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

    /// Only on a ready runtime, so its audio never waits behind preparation. The engine is busy until the
    /// stream's model work has drained after its finish or cancellation, so the runtime it uses is not
    /// released, and no second one prepared, under it.
    func beginStream() -> SpeechStream? {
        guard isAvailable, let loaded, loaded.readiness == .ready else { return nil }
        guard let stream = loaded.runtime.beginStream(onEnd: { [weak self] in
            Task { @MainActor in self?.activeStreams -= 1 }
        }) else { return nil }
        activeStreams += 1
        return stream
    }

    /// With a stream, its result; after any stream failure but cancellation, `audio` as without one.
    /// Cancelling the calling task cancels the stream.
    func transcribe(_ audio: RecordedAudio) async throws -> String {
        guard isAvailable else {
            audio.stream?.cancel()
            throw TranscriptionFailure.modelUnavailable
        }
        activeTranscriptions += 1
        let startedInBackground = isInBackground()
        var report = AttemptReport(audioSeconds: audio.duration, inBackground: startedInBackground)
        defer {
            activeTranscriptions -= 1
            onAttempt?(report)
        }
        let waitStart = now()
        do {
            if let stream = audio.stream {
                do {
                    let text = try await withTaskCancellationHandler { try await stream.finish() } onCancel: { stream.cancel() }
                    report.transcriptionSeconds = now().timeIntervalSince(waitStart)
                    report.outcome = .transcribed
                    return text
                } catch {
                    try Task.checkCancellation()
                }
            }
            let runtime = try await readyRuntime()
            report.waitSeconds = now().timeIntervalSince(waitStart)
            let start = now()
            let text = try await run(runtime, audio)
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

    /// "Find strength": waits for readiness exactly as a transcription does, then runs `operation` on the
    /// loaded runtime. The engine stays busy meanwhile, so the runtime is not released, but this is not a
    /// dictation and no attempt is reported. Throws `TranscriptionFailure` or `CancellationError`.
    func withReadyRuntime<T>(_ operation: (SpeechRuntime) async throws -> T) async throws -> T {
        guard isAvailable else { throw TranscriptionFailure.modelUnavailable }
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        let runtime = try await readyRuntime()
        do {
            return try await operation(runtime)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.transcriptionFailed
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

    /// The loaded runtime once it is ready, preparing it first if needed.
    private func readyRuntime() async throws -> SpeechRuntime {
        try Task.checkCancellation()
        if loaded == nil { prepare() }   // never prepared, released, or failed before
        guard let handle = loaded else { throw TranscriptionFailure.modelFailed }
        try await waitUntilReady(handle)
        // Readiness and a cancellation can resume together: never start work for a cancelled request.
        try Task.checkCancellation()
        return handle.runtime
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
