import Foundation

/// `TranscriptionEngine` with fake runtimes from a factory that counts live instances.
enum TranscriptionEngineTests {
    static var tests: [TestCase] {
        [
            ("transcriptionWaitsForReadiness", isolated(testTranscriptionWaitsForReadiness)),
            ("cancellationEndsTheWaitAndReleasesSamples", isolated(testCancellationEndsTheWaitAndReleasesSamples)),
            ("cancellationRacingReadinessNeverTranscribes", isolated(testCancellationRacingReadinessNeverTranscribes)),
            ("failedPreparationIsRetriedByTheNextDictation", isolated(testFailedPreparationIsRetriedByTheNextDictation)),
            ("backgroundFailureFailsWithHint", isolated(testBackgroundFailureFailsWithHint)),
            ("releaseOnlyWhenIdleAndOneRuntimeAlive", isolated(testReleaseOnlyWhenIdleAndOneRuntimeAlive)),
            ("unavailableModel", isolated(testUnavailableModel)),
            ("readyRuntimeWaitsAndIsNotADictation", isolated(testReadyRuntimeWaitsAndIsNotADictation)),
            ("readyRuntimeFailures", isolated(testReadyRuntimeFailures)),
            ("readyRuntimeCancelledWhileWaiting", isolated(testReadyRuntimeCancelledWhileWaiting)),
            ("streamOnlyFromAReadyModel", isolated(testStreamOnlyFromAReadyModel)),
            ("streamedRecordingIsNotTranscribedAgain", isolated(testStreamedRecordingIsNotTranscribedAgain)),
            ("failedStreamFallsBackToTheRecording", isolated(testFailedStreamFallsBackToTheRecording)),
            ("cancellationCancelsTheStream", isolated(testCancellationCancelsTheStream)),
            ("streamKeepsTheRuntimeUntilItsWorkDrains", isolated(testStreamKeepsTheRuntimeUntilItsWorkDrains)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static func audio(_ count: Int = 16_000) -> RecordedAudio {
        RecordedAudio(samples: [Float](repeating: 0.1, count: count))
    }

    @MainActor
    private static func testTranscriptionWaitsForReadiness() {
        let h = EngineHarness()
        h.engine.prepare()
        TestSupport.expectEqual(h.engine.modelState, .preparing)
        TestSupport.expect(h.engine.isBusy && h.engine.isLoaded, "preparing is not busy")
        let result = h.transcribe(audio())
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.runtime(0)?.transcribeCalls, 0)
        h.runtime(0)!.finishPreparing()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.runtime(0)!.transcribeCalls == 1 }, "never transcribed")
        h.runtime(0)!.finishTranscribing(.success("words"))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.value != nil }, "no result")
        TestSupport.expectEqual(result.text, "words")
        TestSupport.expectEqual(h.engine.modelState, .ready)
        TestSupport.expectEqual(h.made, 1)
        TestSupport.expectEqual(h.attempts.last?.outcome, .transcribed)
        TestSupport.expectEqual(h.attempts.last?.audioSeconds, 1)
        TestSupport.expectEqual(h.attempts.last?.hint, nil)
        TestSupport.expectEqual(h.preparations.map(\.succeeded), [true])
        TestSupport.expect(!h.engine.isBusy, "idle engine is busy")
    }

    /// A request cancelled while the model prepares returns at once and lets go of its samples.
    @MainActor
    private static func testCancellationEndsTheWaitAndReleasesSamples() {
        let h = EngineHarness()
        var recording: RecordedAudio? = audio()
        weak let weakRecording = recording
        let result = h.transcribe(recording!)
        recording = nil
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.made == 1 }, "not preparing")
        result.task?.cancel()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.error != nil }, "the wait ignored cancellation")
        TestSupport.expect(result.error is CancellationError, "not a cancellation: \(String(describing: result.error))")
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { weakRecording == nil }, "samples still held")
        TestSupport.expectEqual(h.engine.modelState, .preparing)   // shared preparation goes on
        TestSupport.expectEqual(h.attempts.last?.outcome, .cancelled)
        h.runtime(0)!.finishPreparing()
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.runtime(0)!.transcribeCalls, 0)
        TestSupport.expectEqual(h.engine.modelState, .ready)
    }

    /// Readiness and a cancellation arrive together: whichever resumes the wait, the cancelled request
    /// never reaches the runtime.
    @MainActor
    private static func testCancellationRacingReadinessNeverTranscribes() {
        let h = EngineHarness()
        let result = h.transcribe(audio())
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.made == 1 }, "not preparing")
        h.runtime(0)!.finishPreparing()
        result.task?.cancel()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.error != nil }, "no outcome")
        TestSupport.expect(result.error is CancellationError, "not a cancellation")
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.runtime(0)?.transcribeCalls, 0)
        TestSupport.expectEqual(h.engine.modelState, .ready)
    }

    @MainActor
    private static func testFailedPreparationIsRetriedByTheNextDictation() {
        let h = EngineHarness()
        let first = h.transcribe(audio())
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.made == 1 }, "not preparing")
        h.runtime(0)!.finishPreparing(succeeded: false)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { first.error != nil }, "no failure")
        TestSupport.expectEqual(first.error as? TranscriptionFailure, .modelFailed)
        TestSupport.expectEqual(h.engine.modelState, .failed)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.live.current == 0 }, "failed runtime kept")
        let second = h.transcribe(audio())
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.made == 2 }, "preparation not retried")
        TestSupport.expectEqual(h.liveWhenMade, [0, 0])
        h.runtime(1)!.finishPreparing()
        _ = TestSupport.waitUntil(timeout: 2) { h.runtime(1)!.transcribeCalls == 1 }
        h.runtime(1)!.finishTranscribing(.success("words"))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { second.text == "words" }, "retry failed")
    }

    /// No fallback runtime ever: a background failure on iOS 27 or later fails the request with a
    /// content-free hint; on iOS 26 or in the foreground there is no hint.
    @MainActor
    private static func testBackgroundFailureFailsWithHint() {
        let hint = ComputeFailureHint.backgroundNeuralEngineNeedsEntitlement
        for (version, background, expectedHint) in [(27, true, Optional(hint)), (26, true, nil), (27, false, nil)] {
            let h = EngineHarness(osMajorVersion: version)
            h.background = background
            let result = h.transcribe(audio())
            _ = TestSupport.waitUntil(timeout: 2) { h.made == 1 }
            h.runtime(0)!.finishPreparing()
            _ = TestSupport.waitUntil(timeout: 2) { h.runtime(0)!.transcribeCalls == 1 }
            h.runtime(0)!.finishTranscribing(.failure(FakeRuntime.Failure()))
            TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.error != nil }, "no failure")
            TestSupport.expectEqual(result.error as? TranscriptionFailure, .transcriptionFailed)
            TestSupport.expectEqual(h.attempts.last?.hint, expectedHint)
            TestSupport.expectEqual(h.made, 1)
        }
        let h = EngineHarness(osMajorVersion: 27)
        h.background = true
        let result = h.transcribe(audio())
        _ = TestSupport.waitUntil(timeout: 2) { h.made == 1 }
        h.runtime(0)!.finishPreparing(succeeded: false)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.error != nil }, "no failure")
        TestSupport.expectEqual(result.error as? TranscriptionFailure, .modelFailed)
        TestSupport.expectEqual(h.attempts.last?.hint, hint)
        TestSupport.expectEqual(h.made, 1)
    }

    @MainActor
    private static func testReleaseOnlyWhenIdleAndOneRuntimeAlive() {
        let h = EngineHarness()
        TestSupport.expect(h.engine.releaseIfIdle(), "nothing loaded is idle")
        h.engine.prepare()
        TestSupport.expect(!h.engine.releaseIfIdle(), "released while preparing")
        h.runtime(0)!.finishPreparing()
        _ = TestSupport.waitUntil(timeout: 2) { h.engine.modelState == .ready }
        let result = h.transcribe(audio())
        _ = TestSupport.waitUntil(timeout: 2) { h.runtime(0)!.transcribeCalls == 1 }
        TestSupport.expect(!h.engine.releaseIfIdle(), "released while transcribing")
        h.runtime(0)!.finishTranscribing(.success("words"))
        _ = TestSupport.waitUntil(timeout: 2) { result.text != nil }
        TestSupport.expect(h.engine.releaseIfIdle(), "idle engine not released")
        TestSupport.expectEqual(h.engine.modelState, .notPrepared)
        TestSupport.expect(!h.engine.isLoaded, "still loaded")
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.live.current == 0 }, "runtime kept after release")
        h.engine.prepare()
        TestSupport.expectEqual(h.liveWhenMade, [0, 0])
    }

    @MainActor
    private static func testUnavailableModel() {
        let h = EngineHarness(isAvailable: false)
        TestSupport.expectEqual(h.engine.modelState, .unavailable)
        h.engine.prepare()
        TestSupport.expectEqual(h.made, 0)
        let result = h.transcribe(audio())
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.error != nil }, "no failure")
        TestSupport.expectEqual(result.error as? TranscriptionFailure, .modelUnavailable)
    }

    // MARK: Streams (transcription while recording)

    @MainActor
    private static func readyHarness() -> EngineHarness {
        let h = EngineHarness()
        h.engine.prepare()
        h.runtime(0)!.finishPreparing()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.engine.modelState == .ready }, "not ready")
        return h
    }

    /// Only a ready model streams, so a recording's audio never waits behind preparation.
    @MainActor
    private static func testStreamOnlyFromAReadyModel() {
        TestSupport.expect(EngineHarness(isAvailable: false).engine.beginStream() == nil, "a stream without a model")
        let h = EngineHarness()
        TestSupport.expect(h.engine.beginStream() == nil, "a stream before preparation")
        h.engine.prepare()
        TestSupport.expect(h.engine.beginStream() == nil, "a stream while preparing")
        h.runtime(0)!.finishPreparing()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.engine.modelState == .ready }, "not ready")
        let stream = h.engine.beginStream()
        TestSupport.expect(stream != nil && stream === h.runtime(0)!.streams.first, "no stream from a ready model")
        let failed = EngineHarness()
        failed.engine.prepare()
        failed.runtime(0)!.finishPreparing(succeeded: false)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { failed.engine.modelState == .failed }, "not failed")
        TestSupport.expect(failed.engine.beginStream() == nil, "a stream from a failed model")
    }

    /// A streamed recording returns the stream's result; the runtime does not transcribe it again.
    @MainActor
    private static func testStreamedRecordingIsNotTranscribedAgain() {
        let h = readyHarness()
        let stream = h.engine.beginStream() as! FakeSpeechStream
        let result = h.transcribe(RecordedAudio(samples: [0.1, 0.2], stream: stream))
        stream.complete(.success("streamed words"))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.value != nil }, "no result")
        TestSupport.expectEqual(result.text, "streamed words")
        TestSupport.expectEqual(h.runtime(0)!.transcribeCalls, 0)
        TestSupport.expectEqual(stream.finishCount, 1)
        TestSupport.expect(!stream.isCancelled, "a finished stream was cancelled")
        TestSupport.expectEqual(h.attempts.last?.outcome, .transcribed)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { !h.engine.isBusy }, "busy after the stream drained")
    }

    /// A stream that fails for any reason but cancellation falls back to transcribing the recording.
    @MainActor
    private static func testFailedStreamFallsBackToTheRecording() {
        let h = readyHarness()
        let stream = h.engine.beginStream() as! FakeSpeechStream
        let result = h.transcribe(RecordedAudio(samples: [0.1], stream: stream))
        stream.complete(.failure(FakeRuntime.Failure()))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.runtime(0)!.transcribeCalls == 1 }, "no fallback")
        h.runtime(0)!.finishTranscribing(.success("recorded words"))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.value != nil }, "no result")
        TestSupport.expectEqual(result.text, "recorded words")
        TestSupport.expectEqual(h.attempts.last?.outcome, .transcribed)
    }

    /// Cancelling the transcription cancels its stream and never falls back.
    @MainActor
    private static func testCancellationCancelsTheStream() {
        let h = readyHarness()
        let stream = h.engine.beginStream() as! FakeSpeechStream
        let result = h.transcribe(RecordedAudio(samples: [0.1], stream: stream))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { stream.finishCount == 1 }, "stream not finishing")
        result.task?.cancel()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { result.error != nil }, "cancellation ignored")
        TestSupport.expect(result.error is CancellationError, "not a cancellation: \(String(describing: result.error))")
        TestSupport.expect(stream.isCancelled, "the stream outlived its transcription")
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.runtime(0)!.transcribeCalls, 0)
        TestSupport.expectEqual(h.attempts.last?.outcome, .cancelled)
    }

    /// A stream is runtime work from `beginStream` until its model work has drained: a memory warning
    /// during a blocked chunk, then a cancel, releases nothing and prepares no second runtime until the
    /// chunk returns.
    @MainActor
    private static func testStreamKeepsTheRuntimeUntilItsWorkDrains() {
        let h = readyHarness()
        let stream = h.engine.beginStream() as! FakeSpeechStream
        stream.holdsWork = true   // a chunk is being encoded
        TestSupport.expect(h.engine.isBusy, "an open stream is not busy")
        TestSupport.expect(!h.engine.releaseIfIdle(), "released under a recording's stream")   // memory warning
        stream.cancel()
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expect(!h.engine.releaseIfIdle(), "released while the cancelled stream's chunk runs")
        h.engine.prepare()
        TestSupport.expectEqual(h.made, 1)
        TestSupport.expectEqual(h.engine.modelState, .ready)
        stream.finishWork()   // the chunk returns; the cancel's cleanup drains
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.engine.releaseIfIdle() }, "never released after the stream drained")
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.live.current == 0 }, "released runtime kept")
        h.engine.prepare()
        TestSupport.expectEqual(h.made, 2)
        TestSupport.expectEqual(h.liveWhenMade, [0, 0])
    }

    // MARK: withReadyRuntime ("Find strength")

    @MainActor
    private final class ProbeOutcome {
        var task: Task<Void, Never>?
        var value: Result<Int, Error>?
        var ran = false
        var release: CheckedContinuation<Void, Never>?
        var error: Error? {
            if case .failure(let error)? = value { return error }
            return nil
        }
    }

    /// Runs an operation that holds the runtime until `release` is resumed, then returns 7 or throws `failure`.
    @MainActor
    private static func probe(_ h: EngineHarness, failure: Error? = nil) -> ProbeOutcome {
        let outcome = ProbeOutcome()
        let engine = h.engine!
        outcome.task = Task {
            do {
                let value = try await engine.withReadyRuntime { runtime -> Int in
                    outcome.ran = runtime is FakeRuntime
                    await withCheckedContinuation { outcome.release = $0 }
                    if let failure { throw failure }
                    return 7
                }
                outcome.value = .success(value)
            } catch {
                outcome.value = .failure(error)
            }
        }
        return outcome
    }

    /// The operation waits for readiness like a dictation, holds the runtime while it runs, and is not
    /// reported as a dictation attempt.
    @MainActor
    private static func testReadyRuntimeWaitsAndIsNotADictation() {
        let h = EngineHarness()
        let outcome = probe(h)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.made == 1 }, "not preparing")
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expect(!outcome.ran, "ran before the model was ready")
        h.runtime(0)!.finishPreparing()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { outcome.release != nil }, "never ran")
        TestSupport.expect(outcome.ran, "not given the loaded runtime")
        TestSupport.expect(h.engine.isBusy, "idle while the operation runs")
        TestSupport.expect(!h.engine.releaseIfIdle(), "released while the operation runs")
        outcome.release?.resume()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { outcome.value != nil }, "no result")
        TestSupport.expectEqual(try? outcome.value?.get(), 7)
        TestSupport.expect(!h.engine.isBusy, "busy afterwards")
        TestSupport.expect(h.attempts.isEmpty, "reported as a dictation")
        TestSupport.expectEqual(h.runtime(0)?.transcribeCalls, 0)
    }

    @MainActor
    private static func testReadyRuntimeFailures() {
        let h = EngineHarness()
        h.engine.prepare()
        h.runtime(0)!.finishPreparing()
        _ = TestSupport.waitUntil(timeout: 2) { h.engine.modelState == .ready }
        let failing = probe(h, failure: FakeRuntime.Failure())
        _ = TestSupport.waitUntil(timeout: 2) { failing.release != nil }
        failing.release?.resume()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { failing.error != nil }, "no failure")
        TestSupport.expectEqual(failing.error as? TranscriptionFailure, .transcriptionFailed)

        let cancelled = probe(h, failure: CancellationError())
        _ = TestSupport.waitUntil(timeout: 2) { cancelled.release != nil }
        cancelled.release?.resume()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { cancelled.error != nil }, "no failure")
        TestSupport.expect(cancelled.error is CancellationError, "not a cancellation")
        TestSupport.expect(h.attempts.isEmpty, "reported as a dictation")

        let unavailableHarness = EngineHarness(isAvailable: false)
        let unavailable = probe(unavailableHarness)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { unavailable.error != nil }, "no failure")
        TestSupport.expectEqual(unavailable.error as? TranscriptionFailure, .modelUnavailable)
        TestSupport.expect(!unavailable.ran && unavailable.release == nil, "ran without a model")
    }

    /// Cancelled while the model prepares: returns at once and never runs.
    @MainActor
    private static func testReadyRuntimeCancelledWhileWaiting() {
        let h = EngineHarness()
        let outcome = probe(h)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.made == 1 }, "not preparing")
        outcome.task?.cancel()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { outcome.error != nil }, "the wait ignored cancellation")
        TestSupport.expect(outcome.error is CancellationError, "not a cancellation")
        h.runtime(0)!.finishPreparing()
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expect(outcome.release == nil, "ran after cancellation")
        TestSupport.expect(!h.engine.isBusy, "still busy")
    }
}

@MainActor
private final class EngineHarness {
    let live = Locked(0)
    /// Weak, so the harness never keeps a runtime alive: `live` counts what the engine keeps.
    private var created: [WeakRuntime] = []
    var made = 0
    var liveWhenMade: [Int] = []
    var background = false
    var attempts: [TranscriptionEngine.AttemptReport] = []
    var preparations: [TranscriptionEngine.PreparationReport] = []
    var engine: TranscriptionEngine!

    init(isAvailable: Bool = true, osMajorVersion: Int = 26) {
        engine = TranscriptionEngine(
            isAvailable: isAvailable, osMajorVersion: osMajorVersion,
            isInBackground: { [unowned self] in self.background },
            makeRuntime: { [unowned self] in
                self.made += 1
                self.liveWhenMade.append(self.live.current)
                let runtime = FakeRuntime(live: self.live)
                self.created.append(WeakRuntime(runtime: runtime))
                return runtime
            })
        engine.onAttempt = { [unowned self] in self.attempts.append($0) }
        engine.onPreparation = { [unowned self] in self.preparations.append($0) }
    }

    @MainActor
    final class Outcome {
        var task: Task<Void, Never>?
        var value: Result<String, Error>?
        var text: String? { try? value?.get() }
        var error: Error? {
            if case .failure(let error)? = value { return error }
            return nil
        }
    }

    func runtime(_ index: Int) -> FakeRuntime? { created.indices.contains(index) ? created[index].runtime : nil }

    private struct WeakRuntime { weak var runtime: FakeRuntime? }

    /// Starts a transcription; the harness keeps no reference to `audio`.
    func transcribe(_ audio: RecordedAudio) -> Outcome {
        let outcome = Outcome()
        let engine = self.engine!
        outcome.task = Task {
            do { outcome.value = .success(try await engine.transcribe(audio)) } catch { outcome.value = .failure(error) }
        }
        return outcome
    }
}

/// A runtime that prepares and transcribes when told to, and ignores cancellation, like Core ML work.
@MainActor
private final class FakeRuntime: SpeechRuntime {
    struct Failure: Error {}

    private let live: Locked<Int>
    private var preparation: CheckedContinuation<Void, Error>?
    private var transcription: CheckedContinuation<String, Error>?
    private var pendingPreparation: Result<Void, Error>?
    private(set) var transcribeCalls = 0
    private(set) var streams: [FakeSpeechStream] = []

    init(live: Locked<Int>) {
        self.live = live
        live.update { $0 += 1 }
    }

    deinit { live.update { $0 -= 1 } }

    func prepare() async throws {
        if let pendingPreparation { return try pendingPreparation.get() }
        try await withCheckedThrowingContinuation { preparation = $0 }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        transcribeCalls += 1
        return try await withCheckedThrowingContinuation { transcription = $0 }
    }

    func beginStream(onEnd: @escaping @Sendable () -> Void) -> SpeechStream? {
        let stream = FakeSpeechStream(onEnd: onEnd)
        streams.append(stream)
        return stream
    }

    func finishPreparing(succeeded: Bool = true) {
        let result: Result<Void, Error> = succeeded ? .success(()) : .failure(Failure())
        if let preparation {
            preparation.resume(with: result)
            self.preparation = nil
        } else {
            pendingPreparation = result
        }
    }

    func finishTranscribing(_ result: Result<String, Error>) {
        transcription?.resume(with: result)
        transcription = nil
    }
}
