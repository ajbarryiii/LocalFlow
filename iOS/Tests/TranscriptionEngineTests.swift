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
