import Foundation

/// Drives `HostSessionCore` through the contract's host scenarios with a fake capture, transcriber,
/// clock and background-task source. Files go to a temporary directory; no Darwin signals are posted.
enum HostSessionCoreTests {
    static var tests: [TestCase] {
        [
            ("launchRecoversInterruptedRequestAndPurges", isolated(testLaunchRecoversInterruptedRequestAndPurges)),
            ("foregroundRecordStartsSessionAndRecords", isolated(testForegroundRecordStartsSessionAndRecords)),
            ("finishWritesResultBeforeCompleted", isolated(testFinishWritesResultBeforeCompleted)),
            ("backgroundRecordWithoutSessionIsRejected", isolated(testBackgroundRecordWithoutSessionIsRejected)),
            ("rejectionDuringDictationIsOnlyRemembered", isolated(testRejectionDuringDictationIsOnlyRemembered)),
            ("newerRecordSupersedesTranscription", isolated(testNewerRecordSupersedesTranscription)),
            ("staleFirstBufferIsIgnored", isolated(testStaleFirstBufferIsIgnored)),
            ("cancelAndEarlyFinish", isolated(testCancelAndEarlyFinish)),
            ("startupTimeout", isolated(testStartupTimeout)),
            ("dismissedKeyboardCancelsInBackground", isolated(testDismissedKeyboardCancelsInBackground)),
            ("maxDurationAutoFinishes", isolated(testMaxDurationAutoFinishes)),
            ("idleExpiryCountsOnlyWhileIdle", isolated(testIdleExpiryCountsOnlyWhileIdle)),
            ("deviceLockCancelsEverything", isolated(testDeviceLockCancelsEverything)),
            ("backgroundTimeExpiry", isolated(testBackgroundTimeExpiry)),
            ("transcriptionFailureIsReported", isolated(testTranscriptionFailureIsReported)),
            ("permissionPrompt", isolated(testPermissionPrompt)),
            ("audioStartFailure", isolated(testAudioStartFailure)),
            ("interruptionEndsSession", isolated(testInterruptionEndsSession)),
            ("engineFailureRestartsOnlyInForeground", isolated(testEngineFailureRestartsOnlyInForeground)),
            ("prewarmedLaunchDoesNotReject", isolated(testPrewarmedLaunchDoesNotReject)),
            ("urlOpenBeforeForegroundDefersCapture", isolated(testURLOpenBeforeForegroundDefersCapture)),
            ("missingModelFailsAtAdmission", isolated(testMissingModelFailsAtAdmission)),
            ("statusCadence", isolated(testStatusCadence)),
            ("heartbeatPurgesExpiredResults", isolated(testHeartbeatPurgesExpiredResults)),
            ("memoryWarningReleasesOnlyWhenIdle", isolated(testMemoryWarningReleasesOnlyWhenIdle)),
            ("inAppStopAndCancel", isolated(testInAppStopAndCancel)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let R = Fixture.requestID
    private static let S = Fixture.otherRequestID

    // MARK: Scenarios

    @MainActor
    private static func testLaunchRecoversInterruptedRequestAndPurges() {
        let h = CoreHarness(launch: false)
        defer { h.cleanup() }
        var previous = Fixture.status(dictation: Fixture.dictation(.recording, hostRunID: Fixture.otherHostRunID))
        previous.hostRunID = Fixture.otherHostRunID
        try! h.store.writeStatus(previous)
        try! h.store.writeResult(Fixture.result(S, hostRunID: Fixture.otherHostRunID))
        h.writeIntent(.record, R)   // still fresh: the bounce relaunched the app
        h.core.launch()
        let interrupted = h.published.first?.dictation
        TestSupport.expectEqual(interrupted?.phase, .failed)
        TestSupport.expectEqual(interrupted?.error, .interrupted)
        TestSupport.expectEqual(interrupted?.requestID, R)
        TestSupport.expectEqual(h.status?.hostRunID, Fixture.hostRunID)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.store.resultRequestIDs(), [])
        TestSupport.expectEqual(h.capture.startCount, 0)
        TestSupport.expect(h.core.knownRequestIDs.contains(R), "recovered request unknown")
        for trigger in [ReconcileTrigger.activation, .urlOpen, .poll] { h.core.reconcile(trigger) }
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.status?.dictation?.error, .interrupted)
    }

    @MainActor
    private static func testForegroundRecordStartsSessionAndRecords() {
        let h = CoreHarness()
        defer { h.cleanup() }
        TestSupport.expectEqual(h.status?.session, .inactive)
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.transcriber.prepareCount, 1)
        TestSupport.expectEqual(h.status?.dictation?.phase, .starting)
        TestSupport.expectEqual(h.status?.sessionExpiresAt, nil)
        TestSupport.expect(h.status?.sessionID != nil, "active session has no ID")
        h.deliver(loud: true)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .recording }, "first buffer ignored")
        TestSupport.expectEqual(h.status?.dictation?.phase, .recording)
        TestSupport.expectEqual(h.status?.dictation?.startedAt, Fixture.now)
        TestSupport.expect((h.status?.level ?? 0) > 0, "no level while recording")
        TestSupport.expect(h.status?.captureReady == true, "fresh capture not ready")
        // Re-evaluating the same intent changes nothing.
        h.core.reconcile(.poll)
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.core.current?.phase, .recording)
    }

    @MainActor
    private static func testFinishWritesResultBeforeCompleted() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.core.onPublish = { status in
            if status.dictation?.phase == .completed {
                TestSupport.expect(h.store.readResult(requestID: status.dictation!.requestID).value != nil,
                                   "completed was published before its result")
            }
        }
        h.record(R)
        h.clock.now += 3
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.phase, .transcribing)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "transcription not started")
        TestSupport.expectEqual(h.transcriber.received.first?.count, 1_600)
        TestSupport.expectEqual(h.background.begun, 1)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
        h.clock.now += 1
        h.transcriber.complete(.success("synthetic words"))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .completed }, "not completed")
        let result = h.store.readResult(requestID: R).value
        TestSupport.expectEqual(result?.text, "<synthetic words>")
        TestSupport.expectEqual(result?.pressEnter, true)
        TestSupport.expectEqual(result?.hostRunID, Fixture.hostRunID)
        TestSupport.expectEqual(result?.createdAt, h.clock.now)
        TestSupport.expectEqual(h.status?.dictation?.phase, .completed)
        TestSupport.expectEqual(h.background.ended, 1)
        // Idle expiry restarts from the completion.
        TestSupport.expectEqual(h.status?.sessionExpiresAt, h.clock.now + 300)
        h.core.reconcile(.poll)
        TestSupport.expectEqual(h.core.current?.phase, .completed)

        // The settings are read when formatting.
        h.settings.pressEnterEnabled = false
        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        h.deliver()
        _ = TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .recording }
        h.writeIntent(.finish, S)
        h.core.reconcile(.intentSignal)
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.transcriber.complete(.success("more"))
        _ = TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .completed }
        TestSupport.expectEqual(h.store.readResult(requestID: S).value?.pressEnter, false)
    }

    @MainActor
    private static func testBackgroundRecordWithoutSessionIsRejected() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.writeIntent(.record, R)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.requestID, R)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .sessionInactive)
        // Once rejected, bringing the app forward does not resurrect it.
        h.clock.isForeground = true
        h.core.reconcile(.activation)
        TestSupport.expectEqual(h.capture.startCount, 0)
        TestSupport.expectEqual(h.core.session, .inactive)
    }

    @MainActor
    private static func testRejectionDuringDictationIsOnlyRemembered() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, S)   // a stale writer names a request this host never saw
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.requestID, R)
        TestSupport.expectEqual(h.status?.dictation?.phase, .recording)
        TestSupport.expect(h.core.knownRequestIDs.contains(S), "rejected request not remembered")
    }

    @MainActor
    private static func testNewerRecordSupersedesTranscription() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.requestID, S)
        TestSupport.expectEqual(h.status?.dictation?.phase, .starting)
        TestSupport.expectEqual(h.background.ended, 1)
        // R's transcription finishes anyway; its outcome is discarded.
        h.transcriber.complete(.success("late words"))
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.store.readResult(requestID: R), .absent)
        TestSupport.expectEqual(h.core.current?.requestID, S)
        TestSupport.expectEqual(h.core.current?.phase, .starting)
        TestSupport.expectEqual(h.background.ended, 1)
        TestSupport.expectEqual(h.capture.startCount, 1)
    }

    @MainActor
    private static func testStaleFirstBufferIsIgnored() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        let first = h.buffer.generation
        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        h.core.captureDelivered(.started(generation: first))
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.core.current?.requestID, S)
        TestSupport.expectEqual(h.core.current?.phase, .starting)
        h.deliver()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .recording }, "current buffer ignored")
    }

    @MainActor
    private static func testCancelAndEarlyFinish() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.cancel, R)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.phase, .cancelled)
        TestSupport.expectEqual(h.status?.dictation?.error, nil)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expect(h.status?.sessionExpiresAt != nil, "idle expiry did not restart")

        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        h.writeIntent(.finish, S)   // before any audio arrived
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .notRecording)
        TestSupport.expectEqual(h.transcriber.pendingCount, 0)
    }

    @MainActor
    private static func testStartupTimeout() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        h.clock.now += DictationProtocol.startupTimeout
        h.core.tick()
        TestSupport.expectEqual(h.core.current?.phase, .starting)
        h.clock.now += 0.1
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .startupTimeout)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
    }

    @MainActor
    private static func testDismissedKeyboardCancelsInBackground() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.tick()
        h.clock.isForeground = false   // the user swiped back
        try! h.store.writePresence(Fixture.presence(seenAt: h.clock.now + 1))
        h.clock.now += 15
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        h.clock.now += 1.2
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation?.phase, .cancelled)
        TestSupport.expectEqual(h.status?.dictation?.error, .keyboardDismissed)
        TestSupport.expectEqual(h.core.session, .active)
    }

    @MainActor
    private static func testMaxDurationAutoFinishes() {
        let h = CoreHarness(maxDuration: 0.2)
        defer { h.cleanup() }
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        h.deliver(count: 4_000)   // more than the cap in the first buffer
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .transcribing }, "not auto-finished")
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "not transcribing")
        TestSupport.expectEqual(h.transcriber.received.first?.count, 3_200)
    }

    @MainActor
    private static func testIdleExpiryCountsOnlyWhileIdle() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.core.userStartSession()
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.status?.sessionExpiresAt, Fixture.now + 300)
        h.clock.now += 200
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.core.session, .active)

        // A long dictation in progress never expires the session.
        h.record(R)
        h.clock.now += 250
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.core.session, .active)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.clock.now += 400
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.core.session, .active)
        h.transcriber.complete(.success("words"))
        _ = TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .completed }
        let idleSince = h.clock.now
        TestSupport.expectEqual(h.core.sessionExpiresAt, idleSince + 300)

        h.settings.sessionMinutes = 15   // takes effect at once
        TestSupport.expectEqual(h.core.sessionExpiresAt, idleSince + 900)
        h.settings.sessionMinutes = 5
        h.clock.now = idleSince + 300
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.core.session, .active)
        h.clock.now += 0.1
        h.core.tick()
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, nil)
        TestSupport.expectEqual(h.capture.isRunning, false)
        TestSupport.expectEqual(h.store.readResult(requestID: R), .absent)   // expired meanwhile, purged at session end
    }

    @MainActor
    private static func testDeviceLockCancelsEverything() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.core.deviceWillLock()
        TestSupport.expectEqual(h.status?.dictation?.phase, .cancelled)
        TestSupport.expectEqual(h.status?.dictation?.error, .deviceLocked)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .deviceLocked)
        TestSupport.expectEqual(h.capture.isRunning, false)
        TestSupport.expectEqual(h.background.ended, 1)
        h.transcriber.complete(.success("late words"))
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.store.readResult(requestID: R), .absent)
        TestSupport.expectEqual(h.core.current?.phase, .cancelled)

        // A recording in a live session is cancelled the same way.
        h.core.userStartSession()
        h.record(S)
        h.core.deviceWillLock()
        TestSupport.expectEqual(h.status?.dictation?.error, .deviceLocked)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
    }

    @MainActor
    private static func testBackgroundTimeExpiry() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.background.expire(0)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .backgroundTimeExpired)
        TestSupport.expectEqual(h.background.ended, 1)
        h.transcriber.complete(.success("late words"))
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.store.readResult(requestID: R), .absent)
        TestSupport.expectEqual(h.background.ended, 1)
    }

    @MainActor
    private static func testTranscriptionFailureIsReported() {
        let h = CoreHarness()
        defer { h.cleanup() }
        for (request, failure) in [(R, TranscriptionFailure.modelFailed), (S, .transcriptionFailed)] {
            h.record(request)
            h.writeIntent(.finish, request)
            h.core.reconcile(.intentSignal)
            _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
            h.transcriber.complete(.failure(failure))
            TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .failed }, "failure not reported")
            TestSupport.expectEqual(h.status?.dictation?.error, failure.errorCode)
            TestSupport.expectEqual(h.store.readResult(requestID: request), .absent)
        }
        TestSupport.expectEqual(h.background.ended, 2)
    }

    @MainActor
    private static func testPermissionPrompt() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.capture.permission = .undetermined
        h.writeIntent(.record, R)
        h.core.reconcile(.urlOpen)
        TestSupport.expectEqual(h.status?.session, .starting)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.capture.hasPendingRequest }, "no prompt")
        h.capture.answer(false)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.session == .inactive }, "denial ignored")
        TestSupport.expectEqual(h.status?.error, .microphonePermissionDenied)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .microphonePermissionDenied)
        TestSupport.expectEqual(h.capture.startCount, 0)

        h.capture.permission = .undetermined
        h.core.userStartSession()
        _ = TestSupport.waitUntil(timeout: 2) { h.capture.hasPendingRequest }
        h.capture.answer(true)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.session == .active }, "grant ignored")
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.status?.error, nil)

        // A session ended while the prompt is up ignores the late answer.
        h.core.userEndSession()
        h.capture.permission = .undetermined
        h.core.userStartSession()
        _ = TestSupport.waitUntil(timeout: 2) { h.capture.hasPendingRequest }
        h.core.userEndSession()
        h.capture.answer(true)
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.capture.startCount, 1)

        h.capture.permission = .denied
        h.core.userStartSession()
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .microphonePermissionDenied)
    }

    @MainActor
    private static func testAudioStartFailure() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.capture.failStart = true
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
    }

    @MainActor
    private static func testInterruptionEndsSession() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.captureInterrupted()
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .interrupted)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .interrupted)
        TestSupport.expectEqual(h.capture.isRunning, false)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
        // A new session clears the session-level error.
        h.core.userStartSession()
        TestSupport.expectEqual(h.status?.error, nil)

        // A call stops the engine just before its notification arrives: still reported as interrupted.
        h.record(S)
        h.capture.isRunning = false
        h.core.tick()
        h.clock.now += 0.2
        h.core.tick()
        h.core.captureInterrupted()
        TestSupport.expectEqual(h.status?.error, .interrupted)
        TestSupport.expectEqual(h.status?.dictation?.error, .interrupted)
        TestSupport.expectEqual(h.capture.startCount, 2)
    }

    @MainActor
    private static func testEngineFailureRestartsOnlyInForeground() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.captureFailed()
        TestSupport.expectEqual(h.capture.startCount, 2)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        // A silently stopped engine is noticed by the timer, after a grace period.
        h.capture.isRunning = false
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 2)
        h.clock.now += HostSessionPolicy.captureStallGrace
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 3)
        h.clock.isForeground = false
        h.core.captureFailed()
        TestSupport.expectEqual(h.capture.startCount, 3)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
    }

    @MainActor
    private static func testPrewarmedLaunchDoesNotReject() {
        let h = CoreHarness(launch: false)
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.writeIntent(.record, R)
        h.core.launch()
        h.core.reconcile(.intentSignal)
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation, nil)
        h.clock.isForeground = true
        h.core.reconcile(.activation)
        TestSupport.expectEqual(h.status?.dictation?.phase, .starting)
        TestSupport.expectEqual(h.core.session, .active)
    }

    @MainActor
    private static func testURLOpenBeforeForegroundDefersCapture() {
        let h = CoreHarness(launch: false)
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.core.launch()
        h.writeIntent(.record, R)
        h.core.reconcile(.urlOpen)
        TestSupport.expectEqual(h.status?.dictation?.phase, .starting)
        TestSupport.expectEqual(h.status?.session, .starting)
        TestSupport.expectEqual(h.capture.startCount, 0)
        h.clock.isForeground = true
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.status?.session, .active)

        // A deferred start nobody waits for any more is abandoned.
        h.core.userEndSession()
        h.clock.isForeground = false
        h.writeIntent(.record, S)
        h.core.reconcile(.urlOpen)
        h.clock.now += DictationProtocol.startupTimeout + 0.1
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation?.error, .startupTimeout)
        TestSupport.expectEqual(h.status?.session, .inactive)
        h.clock.isForeground = true
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.capture.startCount, 1)
    }

    @MainActor
    private static func testMissingModelFailsAtAdmission() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.transcriber.modelState = .unavailable
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .modelUnavailable)
        TestSupport.expectEqual(h.status?.model, .unavailable)
        TestSupport.expectEqual(h.capture.startCount, 0)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
    }

    @MainActor
    private static func testStatusCadence() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.core.userStartSession()
        func publishes(over seconds: Double) -> Int {
            let before = h.published.count
            for _ in 0..<Int(seconds * 10) {
                h.clock.now += 0.1
                h.keepCaptureFresh()
                h.core.tick()
            }
            return h.published.count - before
        }
        let idle = publishes(over: 3)
        TestSupport.expect(idle >= 3 && idle <= 4, "idle heartbeat \(idle) in 3 s")
        h.record(R)
        let recording = publishes(over: 1)
        TestSupport.expect(recording >= 9, "recording status \(recording) in 1 s")
        TestSupport.expect(h.status.map { $0.heartbeatAt == h.clock.now } == true, "heartbeat stale")
        // In the background with no session and nothing in progress, nothing is published.
        h.core.userEndSession()
        h.clock.isForeground = false
        TestSupport.expectEqual(publishes(over: 2), 0)
    }

    @MainActor
    private static func testHeartbeatPurgesExpiredResults() {
        let h = CoreHarness()
        defer { h.cleanup() }
        try! h.store.writeResult(Fixture.result(R, createdAt: Fixture.now - DictationProtocol.resultTTL + 0.5))
        try! h.store.writeResult(Fixture.result(S, createdAt: Fixture.now))
        h.clock.now += 1
        h.core.tick()
        TestSupport.expectEqual(h.store.resultRequestIDs(), [S])
    }

    @MainActor
    private static func testMemoryWarningReleasesOnlyWhenIdle() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.memoryWarning()
        TestSupport.expectEqual(h.transcriber.releaseCount, 0)
        h.writeIntent(.cancel, R)
        h.core.reconcile(.intentSignal)
        h.core.memoryWarning()
        TestSupport.expectEqual(h.transcriber.releaseCount, 1)
        TestSupport.expectEqual(h.status?.model, .notPrepared)
    }

    @MainActor
    private static func testInAppStopAndCancel() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.userStopDictation()
        TestSupport.expectEqual(h.status?.dictation?.phase, .transcribing)
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.core.userCancelDictation()
        TestSupport.expectEqual(h.status?.dictation?.phase, .cancelled)
        // The keyboard's record intent for R still stands; it is not restarted.
        h.core.reconcile(.poll)
        TestSupport.expectEqual(h.core.current?.phase, .cancelled)
        h.transcriber.complete(.success("late"))
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.store.readResult(requestID: R), .absent)
    }
}

// MARK: Harness

@MainActor
private final class CoreHarness {
    @MainActor
    final class Clock {
        var now = Fixture.now
        var isForeground = true
    }

    @MainActor
    final class BackgroundTasks {
        var begun = 0
        var ended = 0
        var expirations: [@MainActor () -> Void] = []

        func expire(_ index: Int) { expirations[index]() }
    }

    let clock = Clock()
    let background = BackgroundTasks()
    let directory = TestSupport.makeTemporaryDirectory()
    let suite = "LocalFlowIOSTests.\(UUID().uuidString)"
    let store: SharedDictationStore
    let settings: LocalFlowSettings
    let buffer: DictationSampleBuffer
    let capture: FakeCapture
    let transcriber = FakeTranscriber()
    let core: HostSessionCore
    var published: [HostStatus] = []

    init(launch: Bool = true, maxDuration: TimeInterval = DictationProtocol.maxDictationDuration) {
        store = SharedDictationStore(directory: directory)
        settings = LocalFlowSettings(defaults: UserDefaults(suiteName: suite)!)
        buffer = DictationSampleBuffer(maxDuration: maxDuration)
        capture = FakeCapture(clock: clock)
        let clock = self.clock
        let background = self.background
        let environment = HostEnvironment(
            now: { clock.now },
            isForeground: { clock.isForeground },
            beginBackgroundTask: { expiration in
                background.begun += 1
                background.expirations.append(expiration)
                return { background.ended += 1 }
            },
            formatTranscript: { text, pressEnter, _ in ("<\(text)>", pressEnter) })
        core = HostSessionCore(hostRunID: Fixture.hostRunID, store: store, settings: settings, buffer: buffer,
                               capture: capture, transcriber: transcriber, notifier: nil, environment: environment)
        core.onChange = { [unowned self] in
            if let status = self.store.readStatus().value { self.published.append(status) }
        }
        if launch { core.launch() }
    }

    func cleanup() {
        transcriber.cancelAll()
        _ = TestSupport.waitUntil(timeout: 0.05) { false }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    var status: HostStatus? { store.readStatus().value }

    func writeIntent(_ action: KeyboardIntent.Action, _ requestID: UUID) {
        try! store.writeIntent(Fixture.intent(action, requestID, at: clock.now))
    }

    /// Delivers one buffer from another thread, as the audio tap does.
    func deliver(count: Int = 1_600, loud: Bool = false) {
        let samples = (0..<count).map { (loud ? 0.3 : 0.01) * sinf(Float($0) * 0.2) }
        let buffer = self.buffer
        let core = self.core
        DispatchQueue.global().sync { core.captureDelivered(buffer.append(samples)) }
        keepCaptureFresh()
    }

    func keepCaptureFresh() { capture.lastBufferAt = clock.now }

    /// Admits `requestID` from the foreground and waits until it is recording.
    func record(_ requestID: UUID) {
        writeIntent(.record, requestID)
        core.reconcile(.activation)
        deliver()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { self.core.current?.phase == .recording },
                           "\(requestID) did not start recording")
    }
}

@MainActor
private final class FakeCapture: HostCapture {
    let clock: CoreHarness.Clock
    var permission = CapturePermission.granted
    var failStart = false
    var startCount = 0
    var isRunning = false
    var lastBufferAt: Date?
    private var pendingRequest: CheckedContinuation<Bool, Never>?

    init(clock: CoreHarness.Clock) { self.clock = clock }

    var hasPendingRequest: Bool { pendingRequest != nil }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { pendingRequest = $0 }
    }

    func answer(_ granted: Bool) {
        permission = granted ? .granted : .denied
        pendingRequest?.resume(returning: granted)
        pendingRequest = nil
    }

    func start() throws {
        TestSupport.expect(clock.isForeground, "capture started in the background")
        guard !failStart else { throw CocoaError(.featureUnsupported) }
        startCount += 1
        isRunning = true
        lastBufferAt = clock.now
    }

    func stop() { isRunning = false }
}

@MainActor
private final class FakeTranscriber: HostTranscriber {
    var modelState = HostStatus.Model.ready
    var prepareCount = 0
    var releaseCount = 0
    var received: [[Float]] = []
    private var pending: [CheckedContinuation<String, Error>] = []

    var pendingCount: Int { pending.count }

    func prepare() { prepareCount += 1 }

    func transcribe(_ samples: [Float]) async throws -> String {
        received.append(samples)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func releaseIfIdle() {
        releaseCount += 1
        modelState = .notPrepared
    }

    func complete(_ result: Result<String, Error>) {
        pending.removeFirst().resume(with: result)
    }

    func cancelAll() {
        while !pending.isEmpty { complete(.failure(CancellationError())) }
    }
}
