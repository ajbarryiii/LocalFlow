import Foundation

enum HostSessionPolicyTests {
    static var tests: [TestCase] {
        [
            ("statusIsFastOnlyWhileStartingOrRecording", testStatusIsFastOnlyWhileStartingOrRecording),
            ("dueToleratesJitterAndClockJumps", testDueToleratesJitterAndClockJumps),
            ("expiryOnlyWhileActiveAndIdle", testExpiryOnlyWhileActiveAndIdle),
            ("idleExpiryFailsClosed", testIdleExpiryFailsClosed),
            ("reconcileForegroundFlag", testReconcileForegroundFlag),
            ("starvationAndElapsedCap", testStarvationAndElapsedCap),
            ("keyboardConnectedNeedsFreshPresence", testKeyboardConnectedNeedsFreshPresence),
            ("cancelOutcomeDependsOnIntent", testCancelOutcomeDependsOnIntent),
            ("watchdogOutcomes", testWatchdogOutcomes),
            ("sessionEndOutcomes", testSessionEndOutcomes),
            ("sessionErrors", testSessionErrors),
            ("statusCaptureReadyAndLevel", testStatusCaptureReadyAndLevel),
        ]
    }

    private static let now = Fixture.now

    private static func testStatusIsFastOnlyWhileStartingOrRecording() {
        TestSupport.expectEqual(HostSessionPolicy.statusInterval(for: nil), DictationProtocol.heartbeatInterval)
        TestSupport.expectEqual(HostSessionPolicy.statusInterval(for: Fixture.dictation(.starting)), 0.1)
        TestSupport.expectEqual(HostSessionPolicy.statusInterval(for: Fixture.dictation(.recording)), 0.1)
        for phase in [DictationStatus.Phase.transcribing, .completed, .failed, .cancelled] {
            TestSupport.expectEqual(HostSessionPolicy.statusInterval(for: Fixture.dictation(phase)), 1)
        }
    }

    private static func testDueToleratesJitterAndClockJumps() {
        TestSupport.expect(HostSessionPolicy.isDue(last: nil, interval: 1, now: now), "never done is due")
        TestSupport.expect(!HostSessionPolicy.isDue(last: now, interval: 1, now: now + 0.9), "due early")
        // A 0.1 s timer that fires a little early still keeps the 1 s heartbeat.
        TestSupport.expect(HostSessionPolicy.isDue(last: now, interval: 1, now: now + 0.96), "jitter stretched the heartbeat")
        TestSupport.expect(HostSessionPolicy.isDue(last: now, interval: 0.1, now: now + 0.06), "fast cadence missed")
        TestSupport.expect(!HostSessionPolicy.isDue(last: now, interval: 0.1, now: now + 0.04), "fast cadence too fast")
        TestSupport.expect(HostSessionPolicy.isDue(last: now, interval: 1, now: now - 5), "backward jump not due")
    }

    private static func testExpiryOnlyWhileActiveAndIdle() {
        TestSupport.expectEqual(HostSessionPolicy.sessionExpiresAt(session: .active, idleSince: now, duration: 300), now + 300)
        TestSupport.expectEqual(HostSessionPolicy.sessionExpiresAt(session: .active, idleSince: nil, duration: 300), nil)
        TestSupport.expectEqual(HostSessionPolicy.sessionExpiresAt(session: .starting, idleSince: now, duration: 300), nil)
        TestSupport.expectEqual(HostSessionPolicy.sessionExpiresAt(session: .inactive, idleSince: now, duration: 300), nil)
    }

    private static func testIdleExpiryFailsClosed() {
        TestSupport.expect(!HostSessionPolicy.isIdleExpired(idleSince: nil, duration: 300, now: now + 9_999),
                           "a dictation in progress expired the session")
        TestSupport.expect(!HostSessionPolicy.isIdleExpired(idleSince: now, duration: 300, now: now + 300), "expired early")
        TestSupport.expect(HostSessionPolicy.isIdleExpired(idleSince: now, duration: 300, now: now + 300.001), "did not expire")
        TestSupport.expect(!HostSessionPolicy.isIdleExpired(idleSince: now, duration: 300, now: now - 2), "skew expired it")
        TestSupport.expect(HostSessionPolicy.isIdleExpired(idleSince: now, duration: 300, now: now - 3_600),
                           "a backward clock jump extended the session")
    }

    private static func testReconcileForegroundFlag() {
        typealias Policy = HostSessionPolicy
        for trigger in [ReconcileTrigger.launch, .intentSignal, .poll, .activation] {
            TestSupport.expectEqual(Policy.reconcileForeground(trigger: trigger, isForeground: true, hasBeenForeground: false), true)
            TestSupport.expectEqual(Policy.reconcileForeground(trigger: trigger, isForeground: false, hasBeenForeground: true), false)
            // A prewarmed process never reconciles: it could only reject.
            TestSupport.expectEqual(Policy.reconcileForeground(trigger: trigger, isForeground: false, hasBeenForeground: false), nil)
        }
        // A URL is only a hint: in the background it neither admits nor rejects, whatever came before.
        TestSupport.expectEqual(Policy.reconcileForeground(trigger: .urlOpen, isForeground: false, hasBeenForeground: false), nil)
        TestSupport.expectEqual(Policy.reconcileForeground(trigger: .urlOpen, isForeground: false, hasBeenForeground: true), nil)
        TestSupport.expectEqual(Policy.reconcileForeground(trigger: .urlOpen, isForeground: true, hasBeenForeground: false), true)
    }

    private static func testStarvationAndElapsedCap() {
        typealias Policy = HostSessionPolicy
        let timeout = Policy.captureStarvationTimeout
        TestSupport.expect(!Policy.isStarved(lastInputAt: now, now: now + timeout - 0.01), "starved early")
        TestSupport.expect(Policy.isStarved(lastInputAt: now, now: now + timeout), "not starved")
        TestSupport.expect(!Policy.isStarved(lastInputAt: now, now: now - 60), "a backward jump counted as starvation")
        let cap = DictationProtocol.maxDictationDuration
        TestSupport.expect(!Policy.hasExceededMaxDuration(startedAt: now, now: now + cap), "capped early")
        TestSupport.expect(Policy.hasExceededMaxDuration(startedAt: now, now: now + cap + 0.01), "not capped")
        TestSupport.expect(Policy.hasExceededMaxDuration(startedAt: now, now: now - 3), "a backward jump extended it")
    }

    private static func testKeyboardConnectedNeedsFreshPresence() {
        typealias Policy = HostSessionPolicy
        let timeout = DictationProtocol.keyboardPresenceTimeout
        TestSupport.expect(Policy.isKeyboardConnected(presence: .value(Fixture.presence(seenAt: now - timeout)), now: now),
                           "fresh presence not connected")
        TestSupport.expect(!Policy.isKeyboardConnected(presence: .value(Fixture.presence(seenAt: now - timeout - 1)), now: now),
                           "a stale presence file counted as connected")
        for read in [StoreRead<KeyboardPresence>.absent, .incompatible, .unreadable] {
            TestSupport.expect(!Policy.isKeyboardConnected(presence: read, now: now), "\(read) counted as connected")
        }
    }

    private static func testCancelOutcomeDependsOnIntent() {
        TestSupport.expectEqual(HostSessionPolicy.cancelOutcome(intentAction: .finish), .failed(.notRecording))
        TestSupport.expectEqual(HostSessionPolicy.cancelOutcome(intentAction: .cancel), .cancelled)
        TestSupport.expectEqual(HostSessionPolicy.cancelOutcome(intentAction: nil), .cancelled)
    }

    private static func testWatchdogOutcomes() {
        TestSupport.expectEqual(HostSessionPolicy.watchdogOutcome(.startupTimeout), .failed(.startupTimeout))
        TestSupport.expectEqual(HostSessionPolicy.watchdogOutcome(.keyboardDismissed), .cancelled(.keyboardDismissed))
    }

    private static func testSessionEndOutcomes() {
        typealias Policy = HostSessionPolicy
        for phase in [DictationStatus.Phase.starting, .recording] {
            TestSupport.expectEqual(Policy.sessionEndOutcome(.user, phase: phase), .cancelled(.sessionInactive))
            TestSupport.expectEqual(Policy.sessionEndOutcome(.idleExpired, phase: phase), .cancelled(.sessionInactive))
            TestSupport.expectEqual(Policy.sessionEndOutcome(.interrupted, phase: phase), .failed(.interrupted))
            TestSupport.expectEqual(Policy.sessionEndOutcome(.deviceLocked, phase: phase), .cancelled(.deviceLocked))
            TestSupport.expectEqual(Policy.sessionEndOutcome(.engineFailed, phase: phase), .failed(.audioSessionFailed))
            TestSupport.expectEqual(Policy.sessionEndOutcome(.mediaServicesReset, phase: phase), .failed(.audioSessionFailed))
            TestSupport.expectEqual(Policy.sessionEndOutcome(.startFailed(.microphonePermissionDenied), phase: phase),
                                    .failed(.microphonePermissionDenied))
        }
        // Transcription needs no audio and survives everything except device lock.
        for reason in [SessionEndReason.user, .idleExpired, .interrupted, .engineFailed, .mediaServicesReset,
                       .startFailed(.audioSessionFailed)] {
            TestSupport.expectEqual(Policy.sessionEndOutcome(reason, phase: .transcribing), nil)
        }
        TestSupport.expectEqual(Policy.sessionEndOutcome(.deviceLocked, phase: .transcribing), .cancelled(.deviceLocked))
        for phase in [DictationStatus.Phase.completed, .failed, .cancelled] {
            TestSupport.expectEqual(Policy.sessionEndOutcome(.deviceLocked, phase: phase), nil)
        }
    }

    private static func testSessionErrors() {
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .user), nil)
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .idleExpired), nil)
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .interrupted), .interrupted)
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .deviceLocked), .deviceLocked)
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .engineFailed), .audioSessionFailed)
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .mediaServicesReset), .audioSessionFailed)
        TestSupport.expectEqual(HostSessionPolicy.sessionError(after: .startFailed(.microphonePermissionDenied)),
                                .microphonePermissionDenied)
    }

    private static func testStatusCaptureReadyAndLevel() {
        func status(_ session: HostStatus.Session = .active, running: Bool = true, lastBufferAt: Date? = now - 0.5,
                    dictation: DictationStatus? = nil) -> HostStatus {
            HostSessionPolicy.status(hostRunID: Fixture.hostRunID, sessionID: Fixture.requestID, session: session,
                                     captureRunning: running, lastBufferAt: lastBufferAt, idleSince: now - 10,
                                     sessionDuration: 300, model: .ready, dictation: dictation, level: 0.7,
                                     error: nil, now: now)
        }
        TestSupport.expect(status().captureReady, "fresh buffers are ready")
        TestSupport.expectEqual(status().sessionExpiresAt, now + 290)
        TestSupport.expectEqual(status().heartbeatAt, now)
        TestSupport.expect(!status(lastBufferAt: now - 1.5).captureReady, "stale buffers are ready")
        TestSupport.expect(!status(lastBufferAt: nil).captureReady, "no buffers are ready")
        TestSupport.expect(!status(running: false).captureReady, "a stopped engine is ready")
        TestSupport.expect(!status(.starting).captureReady, "a starting session is ready")
        TestSupport.expectEqual(status(.inactive).sessionID, nil)
        TestSupport.expectEqual(status(.inactive).sessionExpiresAt, nil)
        TestSupport.expectEqual(status().level, 0)
        TestSupport.expectEqual(status(dictation: Fixture.dictation(.starting)).level, 0)
        TestSupport.expectEqual(status(dictation: Fixture.dictation(.recording)).level, 0.7)
    }
}
