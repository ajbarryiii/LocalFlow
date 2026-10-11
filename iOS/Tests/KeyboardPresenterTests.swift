import Foundation

enum KeyboardPresenterTests {
    static var tests: [TestCase] {
        [
            ("accessComesFirst", testAccessComesFirst),
            ("incompatibleComesBeforeHostState", testIncompatibleComesBeforeHostState),
            ("noHostIsUnavailable", testNoHostIsUnavailable),
            ("readyNeedsLiveHostAndCapture", testReadyNeedsLiveHostAndCapture),
            ("livenessBoundaryAndSkew", testLivenessBoundaryAndSkew),
            ("onlyAnActiveSessionIsAlive", testOnlyAnActiveSessionIsAlive),
            ("showsAdmittedRequestPhases", testShowsAdmittedRequestPhases),
            ("recordingLevelIsClamped", testRecordingLevelIsClamped),
            ("newInstanceAdoptsRequestAfterBounce", testNewInstanceAdoptsRequestAfterBounce),
            ("deadHostHidesProgress", testDeadHostHidesProgress),
            ("startingWhileRecordIntentIsPending", testStartingWhileRecordIntentIsPending),
            ("startingWindowAndSkew", testStartingWindowAndSkew),
            ("otherRequestsDoNotShow", testOtherRequestsDoNotShow),
            ("failureShowsErrorForFiveSeconds", testFailureShowsErrorForFiveSeconds),
            ("hostCancellationWithErrorIsShown", testHostCancellationWithErrorIsShown),
            ("errorShownAfterSessionEnds", testErrorShownAfterSessionEnds),
            ("finalPhasesReturnToIdle", testFinalPhasesReturnToIdle),
            ("staleWriterGuard", testStaleWriterGuard),
        ]
    }

    private static func mode(_ status: HostStatus?, _ intent: KeyboardIntent?, now: Date = Fixture.now,
                             access: KeyboardAccess = .fullAccess) -> KeyboardMode {
        KeyboardPresenter.mode(access: access, status: status.map { .value($0) } ?? .absent,
                               intent: intent.map { .value($0) } ?? .absent, now: now)
    }

    private static var startedAt: Date { Fixture.dictation(.recording).startedAt }

    private static func testAccessComesFirst() {
        let recording = Fixture.status(dictation: Fixture.dictation(.recording), level: 0.5)
        let cases: [(HostStatus?, KeyboardIntent?)] = [
            (nil, nil), (recording, Fixture.intent(.record)), (nil, Fixture.intent(.record)),
        ]
        for (status, intent) in cases {
            TestSupport.expectEqual(mode(status, intent, access: .noFullAccess), .needsFullAccess)
            TestSupport.expectEqual(mode(status, intent, access: .containerUnavailable), .configurationError)
        }
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .noFullAccess, status: .incompatible,
                                                       intent: .incompatible, now: Fixture.now), .needsFullAccess)
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .containerUnavailable, status: .incompatible,
                                                       intent: .absent, now: Fixture.now), .configurationError)
    }

    private static func testIncompatibleComesBeforeHostState() {
        let recording = Fixture.status(dictation: Fixture.dictation(.recording))
        let intent = Fixture.intent(.record)
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .fullAccess, status: .incompatible, intent: .value(intent),
                                                       now: Fixture.now), .incompatible)
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .fullAccess, status: .value(recording), intent: .incompatible,
                                                       now: Fixture.now), .incompatible)
        // Unreadable records are treated as absent.
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .fullAccess, status: .unreadable, intent: .value(intent),
                                                       now: Fixture.now), .starting)
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .fullAccess, status: .value(Fixture.status()),
                                                       intent: .unreadable, now: Fixture.now), .ready)
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .fullAccess, status: .unreadable, intent: .unreadable,
                                                       now: Fixture.now), .hostUnavailable)
    }

    private static func testNoHostIsUnavailable() {
        TestSupport.expectEqual(mode(nil, nil), .hostUnavailable)
        TestSupport.expectEqual(mode(nil, Fixture.intent(.finish)), .hostUnavailable)
        TestSupport.expectEqual(mode(nil, Fixture.intent(.cancel)), .hostUnavailable)
    }

    private static func testReadyNeedsLiveHostAndCapture() {
        TestSupport.expectEqual(mode(Fixture.status(), nil), .ready)
        TestSupport.expectEqual(mode(Fixture.status(), Fixture.intent(.finish)), .ready)
        TestSupport.expectEqual(mode(Fixture.status(), Fixture.intent(.cancel)), .ready)
        TestSupport.expectEqual(mode(Fixture.status(captureReady: false), nil), .hostUnavailable)
    }

    private static func testLivenessBoundaryAndSkew() {
        let timeout = DictationProtocol.livenessTimeout
        let tolerance = DictationProtocol.clockSkewTolerance
        let status = Fixture.status()
        TestSupport.expectEqual(mode(status, nil, now: Fixture.now + timeout), .ready)
        TestSupport.expectEqual(mode(status, nil, now: Fixture.now + timeout + 0.001), .hostUnavailable)
        TestSupport.expectEqual(mode(status, nil, now: Fixture.now - tolerance), .ready)
        // After a backward clock jump, a heartbeat "from the future" cannot keep a dead host alive.
        TestSupport.expectEqual(mode(status, nil, now: Fixture.now - tolerance - 0.001), .hostUnavailable)
    }

    private static func testOnlyAnActiveSessionIsAlive() {
        TestSupport.expectEqual(mode(Fixture.status(.inactive), nil), .hostUnavailable)
        TestSupport.expectEqual(mode(Fixture.status(.starting), nil), .hostUnavailable)
        let inactiveRecording = Fixture.status(.inactive, dictation: Fixture.dictation(.recording))
        TestSupport.expectEqual(mode(inactiveRecording, Fixture.intent(.record)), .hostUnavailable)
    }

    private static func testShowsAdmittedRequestPhases() {
        for intent in [Fixture.intent(.record), Fixture.intent(.finish), Fixture.intent(.cancel)] {
            TestSupport.expectEqual(mode(Fixture.status(dictation: Fixture.dictation(.starting)), intent), .starting)
            TestSupport.expectEqual(mode(Fixture.status(dictation: Fixture.dictation(.recording), level: 0.4), intent),
                                    .recording(level: 0.4, startedAt: startedAt))
            TestSupport.expectEqual(mode(Fixture.status(dictation: Fixture.dictation(.transcribing)), intent), .transcribing)
        }
        // Capture readiness only gates `ready`; an admitted request shows regardless.
        TestSupport.expectEqual(mode(Fixture.status(captureReady: false, dictation: Fixture.dictation(.starting)),
                                     Fixture.intent(.record)), .starting)
    }

    private static func testRecordingLevelIsClamped() {
        for (level, shown) in [(Float(0.4), Float(0.4)), (1.7, 1), (-1, 0), (.nan, 0), (.infinity, 0)] {
            let status = Fixture.status(dictation: Fixture.dictation(.recording), level: level)
            TestSupport.expectEqual(mode(status, Fixture.intent(.record)), .recording(level: shown, startedAt: startedAt))
        }
    }

    private static func testNewInstanceAdoptsRequestAfterBounce() {
        // Instance A wrote the record intent and bounced; instance B appears after the swipe back.
        let intentFromA = Fixture.intent(.record, instance: Fixture.instanceID)
        TestSupport.expectEqual(mode(nil, intentFromA), .starting)
        TestSupport.expectEqual(mode(Fixture.status(.starting, captureReady: false), intentFromA, now: Fixture.now + 2),
                                .starting)
        let admitted = Fixture.status(heartbeatAt: Fixture.now + 3, dictation: Fixture.dictation(.starting))
        TestSupport.expectEqual(mode(admitted, intentFromA, now: Fixture.now + 3), .starting)
        let recording = Fixture.status(heartbeatAt: Fixture.now + 4, dictation: Fixture.dictation(.recording), level: 0.2)
        TestSupport.expectEqual(mode(recording, intentFromA, now: Fixture.now + 5),
                                .recording(level: 0.2, startedAt: startedAt))
        let finishFromB = Fixture.intent(.finish, instance: Fixture.otherInstanceID, at: Fixture.now + 6)
        let transcribing = Fixture.status(heartbeatAt: Fixture.now + 6, dictation: Fixture.dictation(.transcribing))
        TestSupport.expectEqual(mode(transcribing, finishFromB, now: Fixture.now + 6), .transcribing)
    }

    private static func testDeadHostHidesProgress() {
        let late = Fixture.now + DictationProtocol.livenessTimeout + 1
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing] {
            let status = Fixture.status(dictation: Fixture.dictation(phase), level: 0.5)
            // Not `starting` either: the host already picked the request up.
            TestSupport.expectEqual(mode(status, Fixture.intent(.record), now: late), .hostUnavailable)
            TestSupport.expectEqual(mode(status, Fixture.intent(.finish), now: late), .hostUnavailable)
        }
    }

    private static func testStartingWhileRecordIntentIsPending() {
        let intent = Fixture.intent(.record)
        TestSupport.expectEqual(mode(nil, intent), .starting)
        TestSupport.expectEqual(mode(Fixture.status(.inactive), intent), .starting)
        TestSupport.expectEqual(mode(Fixture.status(captureReady: false), intent), .starting)
        TestSupport.expectEqual(mode(Fixture.status(), intent), .starting)
        for phase in [DictationStatus.Phase.recording, .completed, .failed] {
            let other = Fixture.status(dictation: Fixture.dictation(phase, Fixture.otherRequestID, error: .superseded))
            TestSupport.expectEqual(mode(other, intent), .starting)
        }
    }

    private static func testStartingWindowAndSkew() {
        let ttl = DictationProtocol.pendingRecordTTL
        let tolerance = DictationProtocol.clockSkewTolerance
        let intent = Fixture.intent(.record)
        TestSupport.expectEqual(mode(nil, intent, now: Fixture.now + ttl), .starting)
        TestSupport.expectEqual(mode(nil, intent, now: Fixture.now + ttl + 0.001), .hostUnavailable)
        TestSupport.expectEqual(mode(nil, intent, now: Fixture.now - tolerance), .starting)
        TestSupport.expectEqual(mode(nil, intent, now: Fixture.now - tolerance - 0.001), .hostUnavailable)
        let alive = Fixture.status(heartbeatAt: Fixture.now + ttl + 1)
        TestSupport.expectEqual(mode(alive, intent, now: Fixture.now + ttl + 1), .ready)
    }

    private static func testOtherRequestsDoNotShow() {
        // A dictation that the latest intent does not name is not this keyboard's to show.
        let intent = Fixture.intent(.finish)
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing, .failed] {
            let status = Fixture.status(dictation: Fixture.dictation(phase, Fixture.otherRequestID, error: .tooLong))
            TestSupport.expectEqual(mode(status, intent), .ready)
            TestSupport.expectEqual(mode(status, nil), .ready)
        }
    }

    private static func testFailureShowsErrorForFiveSeconds() {
        let window = KeyboardPresenter.errorDisplayDuration
        TestSupport.expectEqual(window, 5)
        let failed = Fixture.dictation(.failed, error: .notRecording)
        TestSupport.expectEqual(mode(Fixture.status(dictation: failed), Fixture.intent(.finish)), .error(.notRecording))
        let later = Fixture.status(heartbeatAt: Fixture.now + window + 1, dictation: failed)
        TestSupport.expectEqual(mode(later, Fixture.intent(.finish), now: Fixture.now + window), .error(.notRecording))
        TestSupport.expectEqual(mode(later, Fixture.intent(.finish), now: Fixture.now + window + 0.001), .ready)
        // A failed record does not fall back to `starting` once the host picked it up.
        TestSupport.expectEqual(mode(later, Fixture.intent(.record), now: Fixture.now + window + 1), .ready)
        // An error stamped beyond the skew tolerance ahead of now is not shown.
        let ahead = Fixture.status(heartbeatAt: Fixture.now - 3, dictation: failed)
        TestSupport.expectEqual(mode(ahead, Fixture.intent(.finish), now: Fixture.now - 2.001), .ready)
        let missingCode = Fixture.status(dictation: Fixture.dictation(.failed))
        TestSupport.expectEqual(mode(missingCode, Fixture.intent(.finish)), .error(.transcriptionFailed))
        // The session-level error is not the request's error.
        let sessionError = Fixture.status(dictation: Fixture.dictation(.failed, error: .startupTimeout),
                                          error: .audioSessionFailed)
        TestSupport.expectEqual(mode(sessionError, Fixture.intent(.record)), .error(.startupTimeout))
    }

    private static func testHostCancellationWithErrorIsShown() {
        for code in [HostErrorCode.keyboardDismissed, .backgroundTimeExpired, .superseded] {
            let cancelled = Fixture.status(dictation: Fixture.dictation(.cancelled, error: code))
            TestSupport.expectEqual(mode(cancelled, Fixture.intent(.record)), .error(code))
        }
        // The user's own cancel carries no error and returns to idle.
        TestSupport.expectEqual(mode(Fixture.status(dictation: Fixture.dictation(.cancelled)), Fixture.intent(.cancel)), .ready)
    }

    private static func testErrorShownAfterSessionEnds() {
        let window = KeyboardPresenter.errorDisplayDuration
        let ended = Fixture.status(.inactive, captureReady: false, dictation: Fixture.dictation(.failed, error: .interrupted))
        TestSupport.expectEqual(mode(ended, Fixture.intent(.record), now: Fixture.now + 1), .error(.interrupted))
        TestSupport.expectEqual(mode(ended, Fixture.intent(.record), now: Fixture.now + window + 1), .hostUnavailable)
        let rejected = Fixture.status(.inactive, captureReady: false,
                                      dictation: Fixture.dictation(.failed, error: .sessionInactive))
        TestSupport.expectEqual(mode(rejected, Fixture.intent(.record)), .error(.sessionInactive))
    }

    private static func testFinalPhasesReturnToIdle() {
        for intent in [Fixture.intent(.record), Fixture.intent(.finish), Fixture.intent(.cancel)] {
            TestSupport.expectEqual(mode(Fixture.status(dictation: Fixture.dictation(.completed)), intent), .ready)
            TestSupport.expectEqual(mode(Fixture.status(.inactive, dictation: Fixture.dictation(.completed)), intent),
                                    .hostUnavailable)
        }
    }

    private static func testStaleWriterGuard() {
        let current = StoreRead.value(Fixture.intent(.record))
        for action in [KeyboardIntent.Action.finish, .cancel] {
            TestSupport.expect(KeyboardPresenter.mayWrite(action, requestID: Fixture.requestID, currentIntent: current),
                               "\(action) for the current request")
            TestSupport.expect(!KeyboardPresenter.mayWrite(action, requestID: Fixture.otherRequestID, currentIntent: current),
                               "\(action) for a superseded request")
            for read in [StoreRead<KeyboardIntent>.absent, .incompatible, .unreadable] {
                TestSupport.expect(!KeyboardPresenter.mayWrite(action, requestID: Fixture.requestID, currentIntent: read),
                                   "\(action) without a readable intent")
            }
        }
        let finished = StoreRead.value(Fixture.intent(.finish, instance: Fixture.otherInstanceID))
        TestSupport.expect(KeyboardPresenter.mayWrite(.cancel, requestID: Fixture.requestID, currentIntent: finished),
                           "cancel after another instance's finish of the same request")
        for read in [StoreRead<KeyboardIntent>.absent, .unreadable, current] {
            TestSupport.expect(KeyboardPresenter.mayWrite(.record, requestID: Fixture.otherRequestID, currentIntent: read),
                               "a new record is always allowed")
        }
    }
}
