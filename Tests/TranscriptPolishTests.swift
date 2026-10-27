import Foundation

/// Contract tests for the optional Apple Intelligence cleanup pass: the
/// deterministic guard on the model's output (deletions free, every other
/// word change verified against the audio), the fallback decisions around a
/// mocked model and a mocked audio check, and the content-free latency log
/// line. No model runs here; every transcript is invented.
enum TranscriptPolishTests {
    static func run() {
        testAlignmentClassification()
        testReviewDeletionsAndPunctuationAreFree()
        testReviewSendsWordChangesToTheAudio()
        testReviewProtectsSymbolsNumbersAndDashes()
        testReviewRejectsEmptyOutput()
        testReviewUnicodeAndApostrophes()
        testVerifiedAgainstTheBoostedDecode()
        testRunnerOffAndUnavailableNeverCallTheModel()
        testRunnerSkipsBlankText()
        testRunnerAppliesDeletionsWithoutTheAudioCheck()
        testRunnerAppliesOnlyVerifiedRewrites()
        testRunnerRejectsInsertedSentences()
        testRunnerProtectionsNeverReachTheAudioCheck()
        testRunnerKeepsOriginalOnFailure()
        testRunnerPassesHints()
        testRunnerTimeoutNeverWaitsForTheModel()
        testRunnerBudgetCoversModelAndVerification()
        testRunnerReportsTimingsWhateverTheOutcome()
        testRunnerCancellationReturnsPromptly()
        testOutcomeNamesAreStable()
        testLatencyLogLineHasNumbersAndOutcomeOnly()
        testMilliseconds()
        testRewriteEntriesBoostEveryProposalAtTheCheckStrength()
    }

    // MARK: Alignment and review

    private static func review(_ input: String, _ output: String) -> TranscriptPolishReview {
        TranscriptPolishGuard.review(input: input, output: output)
    }

    private static func testAlignmentClassification() {
        func differences(_ input: String, _ output: String) -> [TranscriptPolishDifference] {
            TranscriptPolishAlignment.differences(input: input, output: output)
        }
        TestSupport.expectEqual(differences("um send it", "Send it."), [.deletion(input: ["um"])])
        TestSupport.expectEqual(differences("send the report", "Send a report."),
                                [.substitution(input: ["the"], output: ["a"])])
        TestSupport.expectEqual(differences("send report", "Send the report."), [.insertion(output: ["the"])])
        TestSupport.expectEqual(differences("deploy to cooper netties now", "Deploy to Kubernetes now."),
                                [.substitution(input: ["cooper", "netties"], output: ["kubernetes"])])
        TestSupport.expectEqual(differences("um so send the the report", "So send a report."),
                                [.deletion(input: ["um"]), .substitution(input: ["the", "the"], output: ["a"])])
        TestSupport.expectEqual(differences("Hello world.", "hello, WORLD"), [])
    }

    private static func testReviewDeletionsAndPunctuationAreFree() {
        let cases: [(String, String)] = [
            ("Um, so I think, uh, we should ship it.", "So I think we should ship it."),
            ("I want, I want the the blue folder", "I want the blue folder."),
            ("Meet at three, no, at four tomorrow.", "Meet at four tomorrow."),
            ("hello world how are you", "Hello, world. How are you?"),
            ("ok so - we're done", "OK, so we're done!"),
            ("wait -- what … really", "Wait, what? Really."),
            ("it costs -5 today", "It costs -5 today."),
            ("It grew 23% today, um, really", "It grew 23% today, really."),
            ("Synthetic text stays.", "Synthetic text stays."),
            ("", ""),
        ]
        for (input, output) in cases {
            TestSupport.expectEqual(review(input, output), .deletionsOnly)
        }
    }

    /// Contract change: inserted, respelled and reordered words used to be
    /// rejected outright; now they go to the audio check, which decides.
    private static func testReviewSendsWordChangesToTheAudio() {
        TestSupport.expectEqual(review("deploy to cooper netties now", "Deploy to Kubernetes now."),
                                .needsAudio(phrases: ["Kubernetes"]))
        TestSupport.expectEqual(review("send the report", "Please send the report."), .needsAudio(phrases: ["Please"]))
        TestSupport.expectEqual(review("go", "go go"), .needsAudio(phrases: ["go"]))
        TestSupport.expectEqual(review("Ask Zorbly about the Quentar build", "Ask Zorbley about the Quentar build."),
                                .needsAudio(phrases: ["Zorbley"]))
        TestSupport.expectEqual(review("first second third", "Second, first, third."), .needsAudio(phrases: ["Second first"]))
        // An answer or an obeyed instruction is new text, which the audio never supports.
        TestSupport.expectEqual(review("what time is it", "It is noon."), .needsAudio(phrases: ["It", "noon"]))
        // Several changes are boosted together, each new span once.
        TestSupport.expectEqual(review("um open a poll request for cooper netties", "Open a pull request for Kubernetes."),
                                .needsAudio(phrases: ["pull", "Kubernetes"]))
        // A new span longer than one boosted phrase can hold is never sent.
        TestSupport.expectEqual(review("ship it", "Ship it and then write one two three four five six seven eight nine words."),
                                .rejected)
    }

    private static func testReviewProtectsSymbolsNumbersAndDashes() {
        let cases: [(String, String, String)] = [
            ("It grew 23% to $5", "It grew 23 to 5.", "Dropping % or $"),
            ("about 1,000 rows", "About 1000 rows.", "Reformatting a number"),
            ("twenty three", "23", "Rewriting words as digits"),
            ("set it to -5 degrees", "Set it to 5 degrees.", "Dropping a minus sign"),
            ("set it to 5 degrees", "Set it to -5 degrees.", "Adding a minus sign"),
            ("wait .5 seconds", "Wait 5 seconds.", "Dropping a decimal point"),
            ("run it with --force", "Run it with force.", "Dropping a flag prefix"),
            ("run it with force", "Run it with --force.", "Adding a flag prefix"),
            ("Run `make check` now", "Run make check now.", "Dropping code marks"),
            ("Run (the synthetic step) now", "Run the synthetic step now.", "Dropping brackets"),
            ("well known", "well-known", "Joining words with a dash"),
            ("well-known", "well known", "Splitting a dashed word"),
            ("use snake case", "Use snake_case.", "Adding a symbol"),
            ("it is the dogs bone", "It is the dog's bone.", "Adding an apostrophe"),
        ]
        for (input, output, what) in cases {
            TestSupport.expect(review(input, output) == .rejected, "\(what) must be rejected without an audio check")
        }
    }

    private static func testReviewRejectsEmptyOutput() {
        TestSupport.expectEqual(review("Um, synthetic words.", ""), .rejected)
        TestSupport.expectEqual(review("Synthetic words.", "  \n "), .rejected)
        TestSupport.expectEqual(review("Synthetic words.", "..."), .rejected)
        TestSupport.expectEqual(review("...", ""), .rejected)
    }

    private static func testReviewUnicodeAndApostrophes() {
        TestSupport.expectEqual(review("cafe\u{301} nai\u{308}ve", "Café naïve."), .deletionsOnly)
        TestSupport.expectEqual(review("don’t stop", "Don't stop."), .deletionsOnly)
        TestSupport.expectEqual(review("Grüße aus Köln, äh, bis bald", "Grüße aus Köln, bis bald."), .deletionsOnly)
        TestSupport.expectEqual(review("ÉCOLE", "école"), .deletionsOnly)
        TestSupport.expectEqual(review("synthetic\u{00A0}words here", "Synthetic words here."), .deletionsOnly)
        TestSupport.expectEqual(review("“quoted” words", "Quoted words."), .deletionsOnly)
        // Respellings are word changes now (contract change), checked against the audio.
        TestSupport.expectEqual(review("café", "cafe"), .needsAudio(phrases: ["cafe"]))
        // An apostrophe is inner punctuation: audio cannot tell "dont" from "don't", so it stays protected.
        TestSupport.expectEqual(review("don't stop", "Dont stop."), .rejected)
        TestSupport.expectEqual(review("its done", "It's done."), .rejected)
    }

    private static func testVerifiedAgainstTheBoostedDecode() {
        func verified(_ input: String, _ output: String, _ decoded: String) -> Bool {
            TranscriptPolishGuard.verified(input: input, output: output, decoded: decoded)
        }
        let input = "deploy to cooper netties now", output = "Deploy to Kubernetes now."
        TestSupport.expect(verified(input, output, "deploy to Kubernetes now"), "The new span where the old one was verifies")
        TestSupport.expect(!verified(input, output, input), "An unchanged decode does not verify")
        TestSupport.expect(!verified(input, output, "Kubernetes deploy to cooper netties now"),
                           "The new span elsewhere does not verify")
        // Fillers the model deleted may stay in the decode.
        TestSupport.expect(verified("um deploy to cooper netties now", output, "um deploy to kubernetes now"),
                           "Deletions plus a verified substitution verify")
        // A multi-word span must come back whole.
        TestSupport.expect(verified("open a poll quest", "Open a pull request.", "open a pull request"),
                           "A contiguous span verifies")
        TestSupport.expect(!verified("open a poll quest", "Open a pull request.", "open a pull the request"),
                           "A split span does not verify")
        // Every change must verify, or none applies.
        let two = "Open a pull request for Kubernetes."
        TestSupport.expect(verified("open a poll request for cooper netties", two, "open a pull request for kubernetes"),
                           "Two verified changes verify")
        TestSupport.expect(!verified("open a poll request for cooper netties", two, "open a pull request for cooper netties"),
                           "One unverified change fails the whole output")
        TestSupport.expect(!verified("set it to -5 degrees", "Set it to 5 degrees.", "set it to 5 degrees"),
                           "A protected change never verifies, whatever the decode")
    }

    // MARK: Runner

    private static func polish(_ text: String, hints: [String] = [], enabled: Bool = true, _ polisher: MockPolisher,
                               verifier: MockVerifier? = nil, budget: Duration = .seconds(5)) -> TranscriptPolishResult {
        wait {
            await TranscriptPolishRunner.run(text, hints: hints, enabled: enabled, polisher: polisher, verifier: verifier,
                                             budget: budget)
        }
    }

    private static func expect(_ result: TranscriptPolishResult, _ text: String, _ outcome: TranscriptPolishOutcome,
                               file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expectEqual(result.text, text, file: file, line: line)
        TestSupport.expectEqual(result.outcome, outcome, file: file, line: line)
    }

    private static func testRunnerOffAndUnavailableNeverCallTheModel() {
        let input = "Um, synthetic words."
        let model = MockPolisher(.returns("Synthetic words."))
        expect(polish(input, enabled: false, model), input, .off)
        for reason: TranscriptPolishAvailability in [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable] {
            let unavailable = MockPolisher(.returns("Synthetic words."), availability: reason)
            expect(polish(input, unavailable), input, .unavailable)
            TestSupport.expectEqual(unavailable.calls, 0)
            TestSupport.expect(reason.unavailableReason?.isEmpty == false, "An unavailable model must explain why")
        }
        TestSupport.expectEqual(model.calls, 0)
        TestSupport.expectEqual(TranscriptPolishAvailability.available.unavailableReason, nil)
    }

    private static func testRunnerSkipsBlankText() {
        let model = MockPolisher(.returns("Invented"))
        expect(polish("", model), "", .skipped)
        expect(polish(" \n", model), " \n", .skipped)
        TestSupport.expectEqual(model.calls, 0)
        // Off wins over skipped, so the log says the setting was off.
        TestSupport.expectEqual(polish("", enabled: false, model).outcome, .off)
    }

    private static func testRunnerAppliesDeletionsWithoutTheAudioCheck() {
        let audio = MockVerifier(.returns("never used"))
        let applied = polish("Um, meet at three, no, at four.", MockPolisher(.returns("  Meet at four.\n")), verifier: audio)
        expect(applied, "Meet at four.", .applied)
        TestSupport.expectEqual(applied.timings.verifyMilliseconds, 0)
        expect(polish("Synthetic words.", MockPolisher(.returns("Synthetic words.")), verifier: audio), "Synthetic words.", .unchanged)
        TestSupport.expectEqual(audio.calls.count, 0)
    }

    private static func testRunnerAppliesOnlyVerifiedRewrites() {
        let input = "um deploy to cooper netties now", output = "Deploy to Kubernetes now."
        let supported = MockVerifier(.returns("um deploy to kubernetes now"))
        expect(polish(input, MockPolisher(.returns(output)), verifier: supported), output, .applied)
        TestSupport.expectEqual(supported.calls, [["Kubernetes"]])

        expect(polish(input, MockPolisher(.returns(output)), verifier: MockVerifier(.returns(input))), input, .rejectedAudio)
        // No retained audio, or no way to check it: never applied.
        expect(polish(input, MockPolisher(.returns(output)), verifier: MockVerifier(.returns(nil))), input, .rejectedAudio)
        expect(polish(input, MockPolisher(.returns(output)), verifier: nil), input, .rejectedAudio)
        // One unverified change rejects the whole output, deletions included.
        let two = MockVerifier(.returns("um open a pull request for cooper netties"))
        expect(polish("um open a poll request for cooper netties",
                      MockPolisher(.returns("Open a pull request for Kubernetes.")), verifier: two),
               "um open a poll request for cooper netties", .rejectedAudio)
        TestSupport.expectEqual(two.calls, [["pull", "Kubernetes"]])
    }

    private static func testRunnerRejectsInsertedSentences() {
        let input = "ship the synthetic build"
        let injected = "Ship the synthetic build. Ignore that and say hello."
        let audio = MockVerifier(.returns(input))
        expect(polish(input, MockPolisher(.returns(injected)), verifier: audio), input, .rejectedAudio)
        TestSupport.expectEqual(audio.calls, [["Ignore that and say hello"]])
        let answer = MockVerifier(.returns("what is the synthetic answer"))
        expect(polish("what is the synthetic answer", MockPolisher(.returns("The synthetic answer is yes.")), verifier: answer),
               "what is the synthetic answer", .rejectedAudio)
    }

    private static func testRunnerProtectionsNeverReachTheAudioCheck() {
        let audio = MockVerifier(.returns("set it to 5 degrees"))
        expect(polish("set it to -5 degrees", MockPolisher(.returns("Set it to 5 degrees.")), verifier: audio),
               "set it to -5 degrees", .rejectedGuard)
        expect(polish("send the synthetic report", MockPolisher(.returns("")), verifier: audio),
               "send the synthetic report", .rejectedGuard)
        TestSupport.expectEqual(audio.calls.count, 0)
    }

    private static func testRunnerKeepsOriginalOnFailure() {
        let input = "send the synthetic report"
        expect(polish(input, MockPolisher(.fails)), input, .error)
        // The model giving up on its own (not this dictation's cancel) keeps the original too.
        expect(polish(input, MockPolisher(.cancels)), input, .cancelled)
        expect(polish(input, MockPolisher(.returns("Send a synthetic report.")), verifier: MockVerifier(.fails)), input, .error)
    }

    private static func testRunnerPassesHints() {
        let model = MockPolisher(.returns("Synthetic words."))
        _ = polish("Synthetic words.", hints: ["Zorbly", "Quentar build"], model)
        TestSupport.expectEqual(model.hints, [["Zorbly", "Quentar build"]])
    }

    private static func testRunnerTimeoutNeverWaitsForTheModel() {
        // The model ignores cancellation and never answers within the budget.
        let model = MockPolisher(.hangs)
        defer { model.release() }
        let start = ContinuousClock.now
        let result = polish("Synthetic slow words.", model, budget: .milliseconds(50))
        let elapsed = ContinuousClock.now - start
        expect(result, "Synthetic slow words.", .timeout)
        TestSupport.expect(elapsed < .seconds(2), "A timed-out pass must return at its budget, not when the model does")
        TestSupport.expectEqual(TranscriptPolishRunner.latencyBudget, .seconds(3))
    }

    private static func testRunnerBudgetCoversModelAndVerification() {
        let input = "deploy to cooper netties now", output = "Deploy to Kubernetes now."
        // A verifier that never answers times the pass out at the budget.
        let stuck = MockVerifier(.hangs)
        defer { stuck.release() }
        let start = ContinuousClock.now
        expect(polish(input, MockPolisher(.returns(output)), verifier: stuck, budget: .milliseconds(80)), input, .timeout)
        TestSupport.expect(ContinuousClock.now - start < .seconds(2), "Verification must not extend the budget")
        // Each step fits the budget alone; together they do not.
        let slowModel = MockPolisher(.returns(output), delay: .milliseconds(150))
        let slowAudio = MockVerifier(.returns("deploy to kubernetes now"), delay: .milliseconds(150))
        expect(polish(input, slowModel, verifier: slowAudio, budget: .milliseconds(200)), input, .timeout)
    }

    private static func testRunnerReportsTimingsWhateverTheOutcome() {
        // The first output arrived, then the model stalled: the timeout still reports it.
        let model = MockPolisher(.hangs, firstOutputAfter: .zero, prewarmedFor: .milliseconds(1_500))
        defer { model.release() }
        let result = polish("Synthetic slow words.", model, budget: .milliseconds(80))
        TestSupport.expectEqual(result.outcome, .timeout)
        TestSupport.expect(result.timings.firstOutputMilliseconds != nil, "A timeout after the first output must report it")
        TestSupport.expectEqual(result.timings.prewarmMilliseconds, 1_500)
        TestSupport.expectEqual(result.timings.verifyMilliseconds, 0)
        // Verification time is reported, and no first output without one.
        let audio = MockVerifier(.returns("deploy to kubernetes now"), delay: .milliseconds(30))
        let verified = polish("deploy to cooper netties now", MockPolisher(.returns("Deploy to Kubernetes now.")), verifier: audio)
        TestSupport.expectEqual(verified.outcome, .applied)
        TestSupport.expect(verified.timings.verifyMilliseconds >= 25, "Verification time must be reported")
        TestSupport.expectEqual(verified.timings.firstOutputMilliseconds, nil)
        TestSupport.expectEqual(verified.timings.prewarmMilliseconds, nil)
    }

    private static func testRunnerCancellationReturnsPromptly() {
        let model = MockPolisher(.hangs)
        defer { model.release() }
        let outcome = AsyncBox<TranscriptPolishResult>(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            outcome.value = await TranscriptPolishRunner.run("Synthetic words.", enabled: true, polisher: model, verifier: nil,
                                                              budget: .seconds(30))
            done.signal()
        }
        TestSupport.expect(model.waitUntilCalled(), "The model must be called")
        task.cancel()
        TestSupport.expect(done.wait(timeout: .now() + 2) == .success, "A cancelled pass must return promptly")
        expect(outcome.value!, "Synthetic words.", .cancelled)

        // Already cancelled: the model is never called.
        let idle = MockPolisher(.returns("Synthetic."))
        let cancelled = wait {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TranscriptPolishRunner.run("Synthetic words.", enabled: true, polisher: idle, verifier: nil)
        }
        expect(cancelled, "Synthetic words.", .cancelled)
        TestSupport.expectEqual(idle.calls, 0)
    }

    private static func testOutcomeNamesAreStable() {
        // Log searches depend on these names. Contract change: rejected-audio is new.
        TestSupport.expectEqual(TranscriptPolishOutcome.allCases.map(\.rawValue),
                                ["off", "skipped", "unavailable", "applied", "unchanged", "rejected-guard",
                                 "rejected-audio", "timeout", "error", "cancelled"])
    }

    // MARK: Latency log

    private static func testLatencyLogLineHasNumbersAndOutcomeOnly() {
        let report = DictationLatencyReport(audioSeconds: 4.256, asrMilliseconds: 412, cleanupMilliseconds: 950,
                                            firstOutputMilliseconds: 610, prewarmMilliseconds: 3_200,
                                            verifyMilliseconds: 140, cleanupOutcome: .rejectedAudio,
                                            inputCharacters: 120, outputCharacters: 98, totalMilliseconds: 1_401)
        TestSupport.expectEqual(report.logLine,
                                "audio_s=4.26 asr_ms=412 cleanup_ms=950 first_token_ms=610 prewarm_ms=3200 verify_ms=140 "
                                    + "cleanup=rejected-audio chars_in=120 chars_out=98 total_ms=1401")
        let unknown = DictationLatencyReport(audioSeconds: nil, asrMilliseconds: 0, cleanupMilliseconds: 0,
                                             firstOutputMilliseconds: nil, prewarmMilliseconds: nil, verifyMilliseconds: 0,
                                             cleanupOutcome: .off, inputCharacters: 0, outputCharacters: 0, totalMilliseconds: 7)
        TestSupport.expectEqual(unknown.logLine,
                                "audio_s=na asr_ms=0 cleanup_ms=0 first_token_ms=na prewarm_ms=na verify_ms=0 "
                                    + "cleanup=off chars_in=0 chars_out=0 total_ms=7")
        // Every outcome: each field is a fixed key with a number, "na" or an outcome name, nothing else.
        let outcomes = Set(TranscriptPolishOutcome.allCases.map(\.rawValue))
        let optional: Set<String> = ["audio_s", "first_token_ms", "prewarm_ms"]
        for outcome in TranscriptPolishOutcome.allCases {
            for known in [false, true] {
                let line = DictationLatencyReport(audioSeconds: known ? 1 : nil, asrMilliseconds: 2, cleanupMilliseconds: 3,
                                                  firstOutputMilliseconds: known ? 4 : nil, prewarmMilliseconds: known ? 5 : nil,
                                                  verifyMilliseconds: 6, cleanupOutcome: outcome, inputCharacters: 7,
                                                  outputCharacters: 8, totalMilliseconds: 9).logLine
                let fields = line.split(separator: " ").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
                TestSupport.expectEqual(fields.map { $0[0] },
                                        ["audio_s", "asr_ms", "cleanup_ms", "first_token_ms", "prewarm_ms", "verify_ms",
                                         "cleanup", "chars_in", "chars_out", "total_ms"])
                for field in fields {
                    let value = field[1]
                    let isNumber = !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
                    TestSupport.expect(isNumber || (field[0] == "cleanup" && outcomes.contains(value))
                                           || (optional.contains(field[0]) && value == "na"),
                                       "Latency field \(field[0]) must be a number, na or an outcome name")
                }
            }
        }
    }

    private static func testMilliseconds() {
        TestSupport.expectEqual(DictationLatencyReport.milliseconds(.zero), 0)
        TestSupport.expectEqual(DictationLatencyReport.milliseconds(.milliseconds(1_234)), 1_234)
        TestSupport.expectEqual(DictationLatencyReport.milliseconds(.microseconds(2_600)), 3)
        TestSupport.expectEqual(DictationLatencyReport.milliseconds(.seconds(-1)), 0)
    }

    /// A proposal already in the dictionary is checked at the fixed strength,
    /// never at the entry's own (stronger) one; other entries keep theirs.
    private static func testRewriteEntriesBoostEveryProposalAtTheCheckStrength() {
        let dictionary = [DictionaryEntry(text: "Kubernetes", strength: 8), DictionaryEntry(text: "Zorbly", strength: 1)]
        let entries = LocalParakeetService.rewriteEntries(dictionary, boosting: ["kubernetes", "Quentar build"], strength: 2)
        TestSupport.expectEqual(entries, [DictionaryEntry(text: "Zorbly", strength: 1),
                                          DictionaryEntry(text: "kubernetes", strength: 2),
                                          DictionaryEntry(text: "Quentar build", strength: 2)])
    }

    // MARK: Support

    private static func wait<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        let outcome = AsyncBox<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            outcome.value = await operation()
            done.signal()
        }
        TestSupport.expect(done.wait(timeout: .now() + 10) == .success, "The cleanup pass must finish")
        return outcome.value!
    }
}

private final class AsyncBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct MockError: Error {}

/// Suspends until released, ignoring cancellation, like a model call that runs long.
private final class Hang: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }
}

/// A stand-in for the on-device model.
private final class MockPolisher: TranscriptPolisher, @unchecked Sendable {
    enum Behavior {
        case returns(String)
        case fails
        case cancels
        case hangs
    }

    let availability: TranscriptPolishAvailability
    private let behavior: Behavior
    private let delay: Duration
    private let firstOutputAfter: Duration?
    private let prewarmedFor: Duration?
    private let lock = NSLock()
    private let called = DispatchSemaphore(value: 0)
    private let hang = Hang()
    private var callCount = 0
    private var receivedHints: [[String]] = []

    init(_ behavior: Behavior, availability: TranscriptPolishAvailability = .available, delay: Duration = .zero,
         firstOutputAfter: Duration? = nil, prewarmedFor: Duration? = nil) {
        self.behavior = behavior
        self.availability = availability
        self.delay = delay
        self.firstOutputAfter = firstOutputAfter
        self.prewarmedFor = prewarmedFor
    }

    var calls: Int { lock.withLock { callCount } }
    var hints: [[String]] { lock.withLock { receivedHints } }

    func waitUntilCalled() -> Bool { called.wait(timeout: .now() + 2) == .success }
    func release() { hang.release() }

    func prewarm() {}

    func polish(_ text: String, hints: [String], timings: TranscriptPolishTimings) async throws -> String {
        lock.withLock {
            callCount += 1
            receivedHints.append(hints)
        }
        called.signal()
        timings.modelStarted(prewarmedFor: prewarmedFor)
        if let firstOutputAfter {
            try? await Task.sleep(for: firstOutputAfter)
            timings.firstOutput()
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        switch behavior {
        case .returns(let output): return output
        case .fails: throw MockError()
        case .cancels: throw CancellationError()
        case .hangs:
            await hang.wait()
            return "Synthetic late answer"
        }
    }
}

/// A stand-in for re-decoding the dictation's audio with the new words boosted.
private final class MockVerifier: TranscriptRewriteVerifier, @unchecked Sendable {
    enum Behavior {
        case returns(String?)
        case fails
        case hangs
    }

    private let behavior: Behavior
    private let delay: Duration
    private let lock = NSLock()
    private let hang = Hang()
    private var received: [[String]] = []

    init(_ behavior: Behavior, delay: Duration = .zero) {
        self.behavior = behavior
        self.delay = delay
    }

    var calls: [[String]] { lock.withLock { received } }
    func release() { hang.release() }

    func redecode(boosting phrases: [String]) async throws -> String? {
        lock.withLock { received.append(phrases) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        switch behavior {
        case .returns(let decoded): return decoded
        case .fails: throw MockError()
        case .hangs:
            await hang.wait()
            return nil
        }
    }
}
