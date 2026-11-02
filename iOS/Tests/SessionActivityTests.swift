import Foundation

/// The session's Live Activity (ARCHITECTURE.md, "Live Activity"): what it shows for each host state, what its
/// content may carry, and when the driver starts, updates and ends it, against a fake ActivityKit backend.
enum SessionActivityTests {
    static var tests: [TestCase] {
        [
            ("onlyAnActiveSessionShows", testOnlyAnActiveSessionShows),
            ("phaseForEachDictationPhase", testPhaseForEachDictationPhase),
            ("contentCarriesOnlyThePhaseAndDates", testContentCarriesOnlyThePhaseAndDates),
            ("staleDates", testStaleDates),
            ("launchEndsLeftovers", isolated(testLaunchEndsLeftovers)),
            ("startsOnceInTheForeground", isolated(testStartsOnceInTheForeground)),
            ("disabledOrRefusedNeverNags", isolated(testDisabledOrRefusedNeverNags)),
            ("updatesOnlyWhenThePhaseOrDatesChange", isolated(testUpdatesOnlyWhenThePhaseOrDatesChange)),
            ("dictationRoundTrip", isolated(testDictationRoundTrip)),
            ("briefTranscriptionStaysReadable", isolated(testBriefTranscriptionStaysReadable)),
            ("recordingIsNeverHeld", isolated(testRecordingIsNeverHeld)),
            ("sessionEndEndsAtOnce", isolated(testSessionEndEndsAtOnce)),
            ("newSessionReplacesTheOldActivity", isolated(testNewSessionReplacesTheOldActivity)),
            ("reduceMotionChangesOnlyOpacity", testReduceMotionChangesOnlyOpacity),
            ("countdownSpeaksTheBarsWords", testCountdownSpeaksTheBarsWords),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let now = Fixture.now
    private static let sessionA = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
    private static let sessionB = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!

    private static func input(_ session: HostStatus.Session = .active, id: UUID? = sessionA,
                              expiresAt: Date? = now + 300, dictation: DictationStatus? = nil,
                              model: HostStatus.Model = .ready) -> SessionActivityInput {
        SessionActivityInput(sessionID: session == .inactive ? nil : id, session: session, sessionExpiresAt: expiresAt,
                             dictation: dictation, model: model)
    }

    private static func ready(endsAt: Date? = now + 300) -> SessionActivityState {
        SessionActivityState(phase: .ready, endsAt: endsAt, since: nil)
    }

    private static func recording(since: Date) -> SessionActivityState {
        SessionActivityState(phase: .recording, endsAt: nil, since: since)
    }

    private static let transcribing = SessionActivityState(phase: .transcribing, endsAt: nil, since: nil)
    private static let preparing = SessionActivityState(phase: .preparing, endsAt: nil, since: nil)

    // MARK: Motion and words

    /// Sol, round 8: with Reduce Motion every phase change of the activity is opacity only: no view grows, shrinks or
    /// slides as it arrives or leaves, and neither the mark's dot nor the strip's dots change size, so the strip's shape
    /// shows in brightness alone. Without it, the small scale changes stay. Nothing animates in Always On.
    private static func testReduceMotionChangesOnlyOpacity() {
        let handovers: [(Bool) -> SessionActivityMotion.Handover] = [
            SessionActivityMotion.words, SessionActivityMotion.compactTrailing, SessionActivityMotion.minimalDot,
        ]
        for handover in handovers {
            TestSupport.expectEqual(handover(true), .fade)
            TestSupport.expect(handover(false) != .fade, "no motion without Reduce Motion")
        }
        for phase in SessionActivityState.Phase.allCases {
            for stale in [false, true] {
                TestSupport.expectEqual(SessionActivityMotion.markDotScale(phase: phase, isStale: stale, reduceMotion: true), 1)
            }
        }
        TestSupport.expect(SessionActivityMotion.markDotScale(phase: .recording, isStale: false, reduceMotion: false) > 1,
                           "the mark's dot no longer swells while recording")
        TestSupport.expectEqual(SessionActivityMotion.markDotScale(phase: .ready, isStale: false, reduceMotion: false), 1)
        for lit in [0.0, 0.3, 1] {
            TestSupport.expectEqual(SessionActivityMotion.dotScale(lit: lit, reduceMotion: true), 1)
        }
        TestSupport.expect(SessionActivityMotion.dotScale(lit: 1, reduceMotion: false)
            > SessionActivityMotion.dotScale(lit: 0, reduceMotion: false), "lit dots do not grow")
        TestSupport.expect(SessionActivityMotion.dotScale(lit: 1, reduceMotion: false) <= 1, "a lit dot outgrows its place")
        TestSupport.expectEqual(SessionActivityMotion.duration(luminanceReduced: true), nil)
        TestSupport.expect((SessionActivityMotion.duration(luminanceReduced: false) ?? 1) <= 0.3, "phase changes are slow")
    }

    /// Opus, round 8: the bar said "Session ends after 3 min idle" while the island said "ends in 2:15"; round 9 gave both
    /// the same words. Round 10 (owner: the words were wordy): the island and the Lock Screen show the countdown beside a
    /// small timer glyph, "4:58" in the expanded island and "4:53 left" on the Lock Screen, instead of "ends in 4:58" and
    /// "Session ends in 4:53 if idle". VoiceOver still hears the whole meaning, in the menu's words ("Session ends in 2
    /// min if idle", whole minutes to the nearest, never under one).
    private static func testCountdownSpeaksTheBarsWords() {
        let lead = SessionActivityState.countdownLead, tail = SessionActivityState.countdownTail
        TestSupport.expectEqual(lead, "ends in")
        TestSupport.expectEqual(SessionActivityState.countdownSymbol, "timer")
        TestSupport.expectEqual(SessionActivityState.lockScreenCountdownTail, "left")
        let spoken = SessionActivityState.countdownSpokenLead
        TestSupport.expect(spoken.hasPrefix("Session ends") && spoken.contains(tail), "VoiceOver misses the meaning: \(spoken)")
        TestSupport.expect(("4:53 " + SessionActivityState.lockScreenCountdownTail).count < "Session ends in 4:53 if idle".count / 2,
                           "the Lock Screen's countdown is still wordy")
        TestSupport.expectEqual(KeyboardMessages.idleTimeout(minutes: 2), "\(lead) 2 min \(tail)")
        var status = Fixture.status(.active, heartbeatAt: now)
        status.model = .ready
        for (left, minutes) in [(135.0, 2), (150, 3), (179, 3), (20, 1), (300, 5)] {
            status.sessionExpiresAt = now + left
            TestSupport.expectEqual(KeyboardMessages.sessionSummary(for: status, now: now), "Session \(lead) \(minutes) min \(tail)")
            TestSupport.expectEqual(KeyboardMessages.spokenStatus(mode: .ready, status: status, launcherFailed: false, now: now),
                                    "Session \(lead) \(minutes) min \(tail)")
        }
    }

    // MARK: What it shows

    private static func testOnlyAnActiveSessionShows() {
        TestSupport.expectEqual(SessionActivityPolicy.state(for: input(.inactive, expiresAt: nil)), nil)
        // Starting: capture is not running yet, and a failed start never flashes an activity.
        TestSupport.expectEqual(SessionActivityPolicy.state(for: input(.starting, expiresAt: nil)), nil)
        TestSupport.expectEqual(SessionActivityPolicy.state(for: input(.starting, expiresAt: nil,
                                                                        dictation: Fixture.dictation(.starting))), nil)
        // A transcription the session's end left running is not a session.
        TestSupport.expectEqual(SessionActivityPolicy.state(for: input(.inactive, expiresAt: nil,
                                                                        dictation: Fixture.dictation(.transcribing))), nil)
        TestSupport.expectEqual(SessionActivityPolicy.state(for: input()), ready())
    }

    private static func testPhaseForEachDictationPhase() {
        let startedAt = now - 2
        func state(_ phase: DictationStatus.Phase, model: HostStatus.Model = .ready,
                   expiresAt: Date? = nil) -> SessionActivityState? {
            SessionActivityPolicy.state(for: input(expiresAt: expiresAt, dictation: Fixture.dictation(phase, startedAt: startedAt),
                                                   model: model))
        }
        // The timer counts from the admission, so the island turns the moment Start is tapped.
        TestSupport.expectEqual(state(.starting), recording(since: startedAt))
        TestSupport.expectEqual(state(.recording), recording(since: startedAt))
        TestSupport.expectEqual(state(.recording, model: .preparing), recording(since: startedAt))
        TestSupport.expectEqual(state(.transcribing), transcribing)
        // Waiting for the model after Stop says why it takes a while.
        TestSupport.expectEqual(state(.transcribing, model: .preparing), preparing)
        for phase in [DictationStatus.Phase.completed, .failed, .cancelled] {
            TestSupport.expectEqual(state(phase, expiresAt: now + 120), ready(endsAt: now + 120))
            TestSupport.expectEqual(state(phase, model: .preparing, expiresAt: now + 120), ready(endsAt: now + 120))
        }
    }

    private static func testContentCarriesOnlyThePhaseAndDates() {
        // Every stored property is the phase or a date: no text, no audio, no level.
        for child in Mirror(reflecting: recording(since: now)).children {
            TestSupport.expect(child.value is SessionActivityState.Phase || child.value is Date?,
                               "\(child.label ?? "?") is neither the phase nor a date")
        }
        TestSupport.expectEqual(Mirror(reflecting: recording(since: now)).children.compactMap(\.label),
                                ["phase", "endsAt", "since"])
        TestSupport.expectEqual(SessionActivityState.Phase.allCases.map(\.rawValue),
                                ["ready", "recording", "transcribing", "preparing"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try! encoder.encode(ready(endsAt: Date(timeIntervalSinceReferenceDate: 10))), as: UTF8.self)
        TestSupport.expectEqual(json, #"{"endsAt":10,"phase":"ready"}"#)
        let decoded = try! JSONDecoder().decode(SessionActivityState.self, from: try! JSONEncoder().encode(recording(since: now)))
        TestSupport.expectEqual(decoded, recording(since: now))
    }

    private static func testStaleDates() {
        let grace = SessionActivityPolicy.staleGrace
        TestSupport.expect(grace > 0 && grace <= 60, "the grace is a few seconds, not a session")
        // A killed app's activity turns stale just after the session would have ended or the recording been cut off.
        TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: ready(endsAt: now + 300), now: now), now + 300 + grace)
        TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: recording(since: now - 10), now: now),
                                now - 10 + DictationProtocol.maxDictationDuration + grace)
        for state in [transcribing, preparing] {
            TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: state, now: now),
                                    now + SessionActivityPolicy.waitStaleInterval)
        }
        TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: ready(endsAt: nil), now: now),
                                now + SessionActivityPolicy.waitStaleInterval)
    }

    // MARK: Start, update, end

    @MainActor
    private static func testLaunchEndsLeftovers() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.launch()
        driver.launch()
        TestSupport.expectEqual(backend.calls, [.endLeftovers])
        driver.sync(input(.inactive, expiresAt: nil), isForeground: true, now: now)
        TestSupport.expectEqual(backend.calls, [.endLeftovers])
    }

    @MainActor
    private static func testStartsOnceInTheForeground() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(.starting, expiresAt: nil), isForeground: true, now: now)
        TestSupport.expectEqual(backend.calls, [])
        // ActivityKit starts an activity only in the foreground.
        driver.sync(input(), isForeground: false, now: now)
        TestSupport.expectEqual(backend.calls, [])
        driver.sync(input(), isForeground: true, now: now)
        let content = SessionActivityContent(state: ready(), staleDate: now + 300 + SessionActivityPolicy.staleGrace)
        TestSupport.expectEqual(backend.calls, [.start(content)])
        driver.sync(input(), isForeground: true, now: now + 1)
        driver.sync(input(), isForeground: false, now: now + 2)
        TestSupport.expectEqual(backend.calls, [.start(content)])
    }

    @MainActor
    private static func testDisabledOrRefusedNeverNags() {
        let backend = FakeActivityBackend()
        backend.enabled = false
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(), isForeground: true, now: now)
        driver.sync(input(dictation: Fixture.dictation(.recording)), isForeground: true, now: now + 1)
        driver.sync(input(.inactive, expiresAt: nil), isForeground: true, now: now + 2)
        TestSupport.expectEqual(backend.calls, [])
        // Turned back on: the next session in the foreground shows.
        backend.enabled = true
        driver.sync(input(id: sessionB), isForeground: true, now: now + 3)
        TestSupport.expectEqual(backend.calls.count, 1)
        // A start the system refuses is not retried for that session.
        let refusing = FakeActivityBackend()
        refusing.refuses = true
        let other = SessionActivityDriver(backend: refusing)
        other.sync(input(), isForeground: true, now: now)
        other.sync(input(dictation: Fixture.dictation(.recording)), isForeground: true, now: now + 1)
        other.sync(input(expiresAt: now + 400), isForeground: true, now: now + 2)
        TestSupport.expectEqual(refusing.calls.count, 1)
        other.sync(input(.inactive, expiresAt: nil), isForeground: true, now: now + 3)
        TestSupport.expectEqual(refusing.calls.count, 1)
        refusing.refuses = false
        other.sync(input(id: sessionB), isForeground: true, now: now + 4)
        TestSupport.expectEqual(refusing.calls.count, 2)
    }

    @MainActor
    private static func testUpdatesOnlyWhenThePhaseOrDatesChange() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        let startedAt = now - 1
        driver.sync(input(dictation: Fixture.dictation(.recording, startedAt: startedAt, updatedAt: now)), isForeground: true, now: now)
        // Heartbeats (a new `updatedAt`, levels) and the model state while recording change nothing shown.
        for step in 1 ... 20 {
            let at = now + Double(step) * 0.1
            driver.sync(input(dictation: Fixture.dictation(.recording, startedAt: startedAt, updatedAt: at),
                              model: step.isMultiple(of: 2) ? .preparing : .ready), isForeground: false, now: at)
        }
        TestSupport.expectEqual(backend.calls.count, 1)
        // A new idle expiry (the session length changed) is a date change.
        let backend2 = FakeActivityBackend()
        let idle = SessionActivityDriver(backend: backend2)
        idle.sync(input(expiresAt: now + 300), isForeground: true, now: now)
        idle.sync(input(expiresAt: now + 300), isForeground: false, now: now + 5)
        idle.sync(input(expiresAt: now + 900), isForeground: false, now: now + 6)
        TestSupport.expectEqual(backend2.calls.last,
                                .update(SessionActivityContent(state: ready(endsAt: now + 900),
                                                               staleDate: now + 900 + SessionActivityPolicy.staleGrace)))
        TestSupport.expectEqual(backend2.calls.count, 2)
    }

    @MainActor
    private static func testDictationRoundTrip() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(), isForeground: true, now: now)
        // In the background from here, as when dictating from another app.
        let startedAt = now + 10
        driver.sync(input(expiresAt: nil, dictation: Fixture.dictation(.starting, startedAt: startedAt)), isForeground: false,
                    now: startedAt)
        driver.sync(input(expiresAt: nil, dictation: Fixture.dictation(.recording, startedAt: startedAt)), isForeground: false,
                    now: startedAt + 0.2)
        driver.sync(input(expiresAt: nil, dictation: Fixture.dictation(.transcribing, startedAt: startedAt), model: .preparing),
                    isForeground: false, now: startedAt + 5)
        driver.sync(input(expiresAt: nil, dictation: Fixture.dictation(.transcribing, startedAt: startedAt)), isForeground: false,
                    now: startedAt + 9)
        driver.sync(input(expiresAt: startedAt + 310, dictation: Fixture.dictation(.completed, startedAt: startedAt)),
                    isForeground: false, now: startedAt + 10)
        TestSupport.expectEqual(backend.calls.map(\.state), [
            ready(), recording(since: startedAt), preparing, transcribing, ready(endsAt: startedAt + 310),
        ])
        TestSupport.expectEqual(backend.calls.map(\.kind), [.start, .update, .update, .update, .update])
    }

    @MainActor
    private static func testBriefTranscriptionStaysReadable() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        let hold = SessionActivityPolicy.minimumWaitDisplay
        TestSupport.expect(hold >= 0.3 && hold <= 0.6, "the hold is long enough to read, short enough to stay snappy")
        driver.sync(input(dictation: Fixture.dictation(.recording)), isForeground: true, now: now)
        driver.sync(input(dictation: Fixture.dictation(.transcribing)), isForeground: false, now: now + 1)
        // A fast transcription: the result is in 50 ms later. Transcribing stays until it has been shown `hold`.
        let done = input(expiresAt: now + 301, dictation: Fixture.dictation(.completed))
        driver.sync(done, isForeground: false, now: now + 1.05)
        driver.sync(done, isForeground: false, now: now + 1 + hold - 0.01)
        TestSupport.expectEqual(backend.calls.last?.state, transcribing)
        driver.sync(done, isForeground: false, now: now + 1 + hold)
        TestSupport.expectEqual(backend.calls.last?.state, ready(endsAt: now + 301))
        TestSupport.expectEqual(backend.calls.count, 3)
    }

    @MainActor
    private static func testRecordingIsNeverHeld() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(dictation: Fixture.dictation(.transcribing)), isForeground: true, now: now)
        // The next dictation starts while the last transcript is still showing as "transcribing".
        driver.sync(input(dictation: Fixture.dictation(.starting, Fixture.otherRequestID, startedAt: now + 0.1)),
                    isForeground: false, now: now + 0.1)
        TestSupport.expectEqual(backend.calls.last?.state, recording(since: now + 0.1))
    }

    @MainActor
    private static func testSessionEndEndsAtOnce() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(dictation: Fixture.dictation(.transcribing)), isForeground: true, now: now)
        // Ended in the background (idle expiry, an interruption), even while a wait is being held.
        driver.sync(input(.inactive, expiresAt: nil, dictation: Fixture.dictation(.transcribing)), isForeground: false,
                    now: now + 0.05)
        TestSupport.expectEqual(backend.calls.last, .end)
        driver.sync(input(.inactive, expiresAt: nil), isForeground: false, now: now + 1)
        driver.sync(input(.starting, id: sessionB, expiresAt: nil), isForeground: true, now: now + 2)
        TestSupport.expectEqual(backend.calls.map(\.kind), [.start, .end])
    }

    @MainActor
    private static func testNewSessionReplacesTheOldActivity() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(), isForeground: true, now: now)
        // The end of session A was never seen (the two writes fell between syncs): B gets its own activity.
        driver.sync(input(id: sessionB, expiresAt: now + 400), isForeground: true, now: now + 1)
        TestSupport.expectEqual(backend.calls.map(\.kind), [.start, .end, .start])
        TestSupport.expectEqual(backend.calls.last?.state, ready(endsAt: now + 400))
        // In the background it cannot start one, so A's is still ended.
        let background = FakeActivityBackend()
        let other = SessionActivityDriver(backend: background)
        other.sync(input(), isForeground: true, now: now)
        other.sync(input(id: sessionB), isForeground: false, now: now + 1)
        TestSupport.expectEqual(background.calls.map(\.kind), [.start, .end])
    }
}

@MainActor
private final class FakeActivityBackend: SessionActivityBackend {
    enum Call: Equatable {
        case endLeftovers, start(SessionActivityContent), update(SessionActivityContent), end

        enum Kind: Equatable { case endLeftovers, start, update, end }

        var kind: Kind {
            switch self {
            case .endLeftovers: .endLeftovers
            case .start: .start
            case .update: .update
            case .end: .end
            }
        }

        var state: SessionActivityState? {
            switch self {
            case .start(let content), .update(let content): content.state
            case .endLeftovers, .end: nil
            }
        }
    }

    var calls: [Call] = []
    var enabled = true
    var refuses = false

    var areActivitiesEnabled: Bool { enabled }

    func endLeftovers() { calls.append(.endLeftovers) }

    func start(_ content: SessionActivityContent) -> Bool {
        calls.append(.start(content))
        return !refuses
    }

    func update(_ content: SessionActivityContent) { calls.append(.update(content)) }

    func end() { calls.append(.end) }
}
