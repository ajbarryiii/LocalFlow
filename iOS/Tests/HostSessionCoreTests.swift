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
            ("engineFailureWaitsForGraceAndRestartsInBackground", isolated(testEngineFailureWaitsForGraceAndRestartsInBackground)),
            ("staleEngineFailureIsIgnored", isolated(testStaleEngineFailureIsIgnored)),
            ("starvedEngineIsRestartedThenGivenUp", isolated(testStarvedEngineIsRestartedThenGivenUp)),
            ("stalledRecordingFails", isolated(testStalledRecordingFails)),
            ("conversionFailureFailsRecording", isolated(testConversionFailureFailsRecording)),
            ("elapsedTimeCapsRecording", isolated(testElapsedTimeCapsRecording)),
            ("prewarmedLaunchDoesNotReject", isolated(testPrewarmedLaunchDoesNotReject)),
            ("urlHintWaitsForForeground", isolated(testURLHintWaitsForForeground)),
            ("staleIntentAtForegroundArrivalIsNotAdmitted", isolated(testStaleIntentAtForegroundArrivalIsNotAdmitted)),
            ("missingModelFailsAtAdmission", isolated(testMissingModelFailsAtAdmission)),
            ("statusCadence", isolated(testStatusCadence)),
            ("heartbeatPurgesExpiredResults", isolated(testHeartbeatPurgesExpiredResults)),
            ("memoryWarningReleasesOnlyWhenIdle", isolated(testMemoryWarningReleasesOnlyWhenIdle)),
            ("memoryWarningDuringPreparationIsRemembered", isolated(testMemoryWarningDuringPreparationIsRemembered)),
            ("endedRequestsReleaseTheirSamples", isolated(testEndedRequestsReleaseTheirSamples)),
            ("unusableSyntheticInputFailsClosed", isolated(testUnusableSyntheticInputFailsClosed)),
            ("inAppStopAndCancel", isolated(testInAppStopAndCancel)),
            ("finishWaitsForTheTail", isolated(testFinishWaitsForTheTail)),
            ("tailTimeoutTranscribesWhatArrived", isolated(testTailTimeoutTranscribesWhatArrived)),
            ("cancelDuringTheTailDiscardsTheRecording", isolated(testCancelDuringTheTailDiscardsTheRecording)),
            ("sessionEndDuringTheTailTranscribes", isolated(testSessionEndDuringTheTailTranscribes)),
            ("mediaServicesResetEndsTheSession", isolated(testMediaServicesResetEndsTheSession)),
            ("microphoneChoiceAppliesInTheForegroundOnly", isolated(testMicrophoneChoiceAppliesInTheForegroundOnly)),
            ("staleConversionFailureAfterReconfigurationIsIgnored", isolated(testStaleConversionFailureAfterReconfigurationIsIgnored)),
            ("backgroundChoiceIsDeferredOnTheRoutePath", isolated(testBackgroundChoiceIsDeferredOnTheRoutePath)),
            ("unresolvedMicrophoneChoiceKeepsDictating", isolated(testUnresolvedMicrophoneChoiceKeepsDictating)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let R = Fixture.requestID
    private static let S = Fixture.otherRequestID
    private static let R2 = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    /// Just past the capture grace, so accumulated floating-point clock steps never land a hair short.
    private static let grace = HostSessionPolicy.captureStallGrace + 0.001

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
        h.completeTail()
        TestSupport.expectEqual(h.status?.dictation?.phase, .transcribing)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "transcription not started")
        TestSupport.expectEqual(h.transcriber.received.first, 1_600)
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
        h.completeTail()
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
        h.transcriber.honorsCancellation = false   // a runtime that finishes anyway: the fence must drop it
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.completeTail()
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
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        h.clock.now += 1.2
        h.feed()
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
        TestSupport.expectEqual(h.transcriber.received.first, 3_200)
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
        h.completeTail()
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
        h.transcriber.honorsCancellation = false   // a runtime that finishes anyway: the fence must drop it
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.completeTail()
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
        h.transcriber.honorsCancellation = false   // a runtime that finishes anyway: the fence must drop it
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.completeTail()
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
            h.completeTail()
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
    private static func testInAppStopAndCancel() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.transcriber.honorsCancellation = false   // a runtime that finishes anyway: the fence must drop it
        h.record(R)
        h.core.userStopDictation()
        h.completeTail()
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

    // MARK: Capture supervision

    @MainActor
    private static func testEngineFailureWaitsForGraceAndRestartsInBackground() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        // A configuration change waits out the same grace as a stopped engine.
        h.core.captureFailed(generation: h.capture.engineGeneration)
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 1)
        h.clock.now += HostSessionPolicy.captureStallGrace - 0.1
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 1)
        h.clock.now += 0.101
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 2)   // foreground: a full start
        TestSupport.expectEqual(h.core.current?.phase, .recording)

        // In the background the engine is rebuilt inside the active audio session, never started anew.
        h.clock.isForeground = false
        try! h.store.writePresence(Fixture.presence(seenAt: h.clock.now))
        h.feed()
        h.core.captureFailed(generation: h.capture.engineGeneration)
        h.clock.now += grace
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.capture.restartCount, 1)
        TestSupport.expectEqual(h.capture.startCount, 2)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.core.current?.phase, .recording)

        // A restart that fails ends the session.
        h.capture.failRestart = true
        h.core.captureFailed(generation: h.capture.engineGeneration)
        h.clock.now += grace
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.capture.startCount, 2)
    }

    @MainActor
    private static func testStaleEngineFailureIsIgnored() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.core.userStartSession()
        let first = h.capture.engineGeneration
        h.core.captureFailed(generation: first)
        h.clock.now += grace
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 2)
        // A notification queued for the replaced engine arrives afterwards.
        h.core.captureFailed(generation: first)
        h.clock.now += grace + 0.1
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 2)
        TestSupport.expectEqual(h.core.session, .active)
    }

    @MainActor
    private static func testStarvedEngineIsRestartedThenGivenUp() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.core.userStartSession()
        h.capture.stall()   // running, but no buffers arrive
        func advance(_ seconds: Double) {
            for _ in 0..<Int((seconds * 10).rounded()) {
                h.clock.now += 0.1
                h.core.tick()
            }
        }
        let cycle = HostSessionPolicy.captureStarvationTimeout + HostSessionPolicy.captureStallGrace
        advance(HostSessionPolicy.captureStarvationTimeout - 0.3)
        TestSupport.expectEqual(h.capture.startCount, 1)
        advance(0.3 + HostSessionPolicy.captureStallGrace + 0.2)
        TestSupport.expectEqual(h.capture.startCount, 2)
        // Input after a recovery resets the budget.
        h.capture.resumeDelivery()
        advance(1)
        h.capture.stall()
        advance(cycle + 0.2)
        TestSupport.expectEqual(h.capture.startCount, 3)
        TestSupport.expectEqual(h.core.session, .active)
        // Recoveries that keep producing no input end the session.
        advance(2 * cycle + 0.2)
        TestSupport.expectEqual(h.capture.startCount, 2 + HostSessionPolicy.maxRecoveriesWithoutInput)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
    }

    @MainActor
    private static func testStalledRecordingFails() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.tick()   // the growth baseline
        // Buffers keep arriving (the engine runs), but no samples reach the recording.
        h.clock.now += HostSessionPolicy.captureStarvationTimeout - 0.1
        h.core.tick()
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        h.clock.now += 0.101
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
        // The capture is rebuilt after the grace, and the session goes on.
        h.clock.now += grace
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 2)
        TestSupport.expectEqual(h.core.session, .active)
    }

    @MainActor
    private static func testConversionFailureFailsRecording() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        let generation = h.buffer.generation
        let engine = h.capture.engineGeneration
        h.core.captureDelivered(.conversionFailed(generation: generation &- 1, engine: engine))   // an older recording's
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        h.core.captureDelivered(.conversionFailed(generation: generation, engine: engine))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .failed }, "conversion failure ignored")
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
        h.clock.now += grace
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 2)
    }

    @MainActor
    private static func testElapsedTimeCapsRecording() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)   // admitted at Fixture.now; a trickle of samples never reaches the sample cap
        while h.clock.now < Fixture.now + DictationProtocol.maxDictationDuration {
            h.clock.now += 1
            h.feed(count: 160)
            h.core.tick()
            TestSupport.expectEqual(h.core.current?.phase, .recording)
        }
        h.clock.now += 0.1
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation?.phase, .transcribing)
        h.completeTail()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "not transcribing")
        TestSupport.expect((h.transcriber.received.first ?? 0) < h.buffer.maxSampleCount, "sample cap used instead")
    }

    // MARK: URL hint

    @MainActor
    private static func testURLHintWaitsForForeground() {
        let h = CoreHarness()   // launched in the foreground earlier in this run
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.writeIntent(.record, R)
        h.core.reconcile(.urlOpen)
        h.core.reconcile(.urlOpen)
        // Neither admitted nor rejected, nothing prepared, and the request ID is not consumed.
        TestSupport.expectEqual(h.status?.dictation, nil)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.transcriber.prepareCount, 0)
        TestSupport.expect(!h.core.knownRequestIDs.contains(R), "the hint consumed the request")
        h.core.foregroundChanged()   // still in the background: willEnterForeground
        TestSupport.expectEqual(h.status?.dictation, nil)
        h.clock.now += 3
        h.clock.isForeground = true
        h.core.foregroundChanged()   // arrived
        TestSupport.expectEqual(h.status?.dictation?.requestID, R)
        TestSupport.expectEqual(h.status?.dictation?.phase, .starting)
        TestSupport.expectEqual(h.status?.dictation?.startedAt, h.clock.now)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.transcriber.prepareCount, 1)

        // A prewarmed process ignores the hint too.
        let prewarmed = CoreHarness(launch: false)
        defer { prewarmed.cleanup() }
        prewarmed.clock.isForeground = false
        prewarmed.core.launch()
        prewarmed.writeIntent(.record, S)
        prewarmed.core.reconcile(.urlOpen)
        TestSupport.expectEqual(prewarmed.status?.dictation, nil)
        TestSupport.expectEqual(prewarmed.transcriber.prepareCount, 0)
    }

    @MainActor
    private static func testStaleIntentAtForegroundArrivalIsNotAdmitted() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.writeIntent(.record, R)
        h.core.reconcile(.urlOpen)
        h.clock.now += DictationProtocol.pendingRecordTTL + 0.1
        h.clock.isForeground = true
        h.core.foregroundChanged()
        h.core.tick()
        TestSupport.expectEqual(h.status?.dictation, nil)
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.capture.startCount, 0)
    }

    // MARK: Memory and samples

    @MainActor
    private static func testMemoryWarningReleasesOnlyWhenIdle() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.core.memoryWarning()
        TestSupport.expectEqual(h.transcriber.releaseCount, 0)
        h.writeIntent(.cancel, R)
        h.core.reconcile(.intentSignal)   // the dictation ends: the remembered warning applies now
        TestSupport.expectEqual(h.transcriber.releaseCount, 1)
        TestSupport.expectEqual(h.status?.model, .notPrepared)
        h.core.tick()
        TestSupport.expectEqual(h.transcriber.releaseCount, 1)
    }

    @MainActor
    private static func testMemoryWarningDuringPreparationIsRemembered() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.transcriber.modelState = .preparing
        h.transcriber.busy = true
        h.core.memoryWarning()
        h.clock.now += 1
        h.core.tick()
        TestSupport.expectEqual(h.transcriber.releaseCount, 0)
        TestSupport.expect(h.transcriber.releaseAttempts >= 2, "the pending release was not retried")
        h.transcriber.busy = false
        h.transcriber.modelState = .ready
        h.core.modelStateChanged()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.releaseCount == 1 }, "warning forgotten")
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.status?.model == .notPrepared }, "release unpublished")
        h.clock.now += 1
        h.core.tick()
        TestSupport.expectEqual(h.transcriber.releaseCount, 1)
    }

    /// Cancel, supersede, device lock and background expiry all end the transcription at once, so the
    /// recorded samples are freed instead of waiting for the model.
    @MainActor
    private static func testEndedRequestsReleaseTheirSamples() {
        let endings: [(String, @MainActor (CoreHarness) -> Void)] = [
            ("cancel", { h in
                h.writeIntent(.cancel, R)
                h.core.reconcile(.intentSignal)
            }),
            ("supersede", { h in
                h.writeIntent(.record, S)
                h.core.reconcile(.intentSignal)
            }),
            ("lock", { h in h.core.deviceWillLock() }),
            ("expiry", { h in h.background.expire(0) }),
        ]
        for (name, end) in endings {
            let h = CoreHarness()
            defer { h.cleanup() }
            h.record(R)
            h.writeIntent(.finish, R)
            h.core.reconcile(.intentSignal)
            h.completeTail()
            TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "\(name): not transcribing")
            TestSupport.expect(h.transcriber.lastAudio != nil, "\(name): no audio handed over")
            end(h)
            TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.lastAudio == nil },
                               "\(name): samples still held")
            TestSupport.expectEqual(h.transcriber.pendingCount, 0)
            TestSupport.expectEqual(h.store.readResult(requestID: R), .absent)
        }
    }

    @MainActor
    private static func testUnusableSyntheticInputFailsClosed() {
        var madeMicrophone = false
        let capture = SyntheticInputRequest.unusable.capture { madeMicrophone = true; return UnavailableCapture() }
        TestSupport.expect(!madeMicrophone, "an unusable synthetic input fell back to the microphone")
        TestSupport.expect(capture is UnavailableCapture, "wrong capture")
        let h = CoreHarness(capture: capture)
        defer { h.cleanup() }
        h.writeIntent(.record, R)
        h.core.reconcile(.activation)
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
        _ = SyntheticInputRequest.notRequested.capture { madeMicrophone = true; return UnavailableCapture() }
        TestSupport.expect(madeMicrophone, "no synthetic input did not use the microphone")
    }

    // MARK: Tail and media services

    /// Finish stops the recording at the current capture time but keeps the frames still in flight:
    /// transcription starts once the capture reports the tail complete.
    @MainActor
    private static func testFinishWaitsForTheTail() {
        let h = CoreHarness()
        defer { h.cleanup() }
        let boundaries = h.capture.boundaryCount
        h.record(R)
        TestSupport.expectEqual(h.capture.boundaryCount, boundaries + 1)   // begin
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.phase, .transcribing)
        TestSupport.expectEqual(h.buffer.recordingWindow?.token, h.buffer.generation)
        TestSupport.expect(h.buffer.recordingWindow?.end != nil, "not closing")
        h.feed()   // captured before the finish, delivered after it
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.transcriber.pendingCount, 0)
        h.completeTail()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "tail never drained")
        TestSupport.expectEqual(h.transcriber.received, [3_200])
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
        TestSupport.expectEqual(h.capture.boundaryCount, boundaries + 2)   // drain
        h.completeTail()   // a late duplicate changes nothing
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.transcriber.pendingCount, 1)
    }

    @MainActor
    private static func testTailTimeoutTranscribesWhatArrived() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.clock.now += HostSessionPolicy.tailTimeout - 0.2
        h.core.tick()
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.transcriber.pendingCount, 0)
        h.clock.now += 0.2
        h.core.tick()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "tail timeout ignored")
        TestSupport.expectEqual(h.transcriber.received, [1_600])

        // With the engine stopped, nothing more can arrive: the recording drains at once.
        h.transcriber.complete(.success("words"))
        h.record(S)
        h.capture.isRunning = false
        h.writeIntent(.finish, S)
        h.core.reconcile(.intentSignal)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "stopped engine waited")
    }

    @MainActor
    private static func testCancelDuringTheTailDiscardsTheRecording() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.writeIntent(.cancel, R)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.phase, .cancelled)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
        h.completeTail()
        h.clock.now += HostSessionPolicy.tailTimeout + 0.1
        h.core.tick()
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.transcriber.pendingCount, 0)
        TestSupport.expectEqual(h.core.current?.phase, .cancelled)
    }

    /// A call during the tail ends the session, but the finished recording is still transcribed.
    @MainActor
    private static func testSessionEndDuringTheTailTranscribes() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.core.captureInterrupted()
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "recording lost at session end")
        TestSupport.expectEqual(h.transcriber.received, [1_600])
        TestSupport.expectEqual(h.core.current?.phase, .transcribing)
    }

    /// Media services reset: the session ends at once (no background restart), a recording fails with
    /// `.audioSessionFailed`, and only a new foreground start captures again.
    @MainActor
    private static func testMediaServicesResetEndsTheSession() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        h.clock.isForeground = false
        h.core.captureMediaServicesReset()
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.capture.isRunning, false)
        h.clock.now += 1
        h.core.tick()
        TestSupport.expectEqual(h.capture.restartCount, 0)
        TestSupport.expectEqual(h.capture.startCount, 1)
        // From the background the next request is rejected; in the foreground it starts a new session.
        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.error, .sessionInactive)
        h.clock.isForeground = true
        h.core.userStartSession()
        TestSupport.expectEqual(h.capture.startCount, 2)
        TestSupport.expectEqual(h.core.session, .active)

        // A finished recording waiting for its tail is still transcribed.
        h.record(R2)
        h.writeIntent(.finish, R2)
        h.core.reconcile(.intentSignal)
        h.core.captureMediaServicesReset()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "finished recording lost")
    }

    /// A changed microphone choice reconfigures an active session in the foreground at once, keeps the
    /// recording going, and otherwise waits for the next session start; never in the background.
    @MainActor
    private static func testMicrophoneChoiceAppliesInTheForegroundOnly() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.core.captureSettingsChanged()   // no session: applies at the next start
        TestSupport.expectEqual(h.capture.reconfigureCount, 0)
        h.record(R)
        let generation = h.capture.engineGeneration
        h.core.captureSettingsChanged()
        TestSupport.expectEqual(h.capture.reconfigureCount, 1)
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expect(h.capture.engineGeneration > generation, "same engine after reconfiguring")
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        h.core.captureFailed(generation: generation)   // the old engine's queued report is ignored
        h.clock.now += grace
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 1)
        // In the background nothing is reconfigured.
        h.clock.isForeground = false
        try! h.store.writePresence(Fixture.presence(seenAt: h.clock.now))
        h.core.captureSettingsChanged()
        TestSupport.expectEqual(h.capture.reconfigureCount, 1)
        // A reconfiguration that fails ends the session.
        h.clock.isForeground = true
        h.capture.failReconfigure = true
        h.core.captureSettingsChanged()
        TestSupport.expectEqual(h.status?.session, .inactive)
        TestSupport.expectEqual(h.status?.error, .audioSessionFailed)
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
    }

    /// P1: a conversion failure the old pipeline queued just before a live reconfiguration replaced its
    /// engine arrives afterwards. It must neither fail the recording nor rebuild the new engine.
    @MainActor
    private static func testStaleConversionFailureAfterReconfigurationIsIgnored() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.record(R)
        let oldEngine = h.capture.engineGeneration
        h.core.captureDelivered(.conversionFailed(generation: h.buffer.generation, engine: oldEngine))   // queued
        h.setUseBuiltInMicrophone(false)   // the foreground swap runs before the queued event
        TestSupport.expectEqual(h.capture.reconfigureCount, 1)
        _ = TestSupport.waitUntil(timeout: 0.2) { false }   // the queued event is delivered now
        TestSupport.expectEqual(h.core.current?.phase, .recording)
        h.clock.now += grace
        h.feed()
        h.core.tick()
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.capture.reconfigureCount, 1)
        // The replacement engine's own failure still counts.
        h.core.captureDelivered(.conversionFailed(generation: h.buffer.generation, engine: h.capture.engineGeneration))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .failed }, "current failure ignored")
        TestSupport.expectEqual(h.status?.dictation?.error, .audioSessionFailed)
    }

    /// P1, through the controller and route path: a choice changed while the app is in the background is
    /// only recorded. Route changes keep re-asserting the applied choice under its own category, and the
    /// desired one is applied when the app is next in front.
    @MainActor
    private static func testBackgroundChoiceIsDeferredOnTheRoutePath() {
        let h = CoreHarness()
        defer { h.cleanup() }
        let session = h.capture.routeSession
        h.core.userStartSession()
        let builtIn = MicrophoneRoute.categoryOptions(useBuiltInMicrophone: true)
        TestSupport.expectEqual(session.categories, [builtIn])
        TestSupport.expectEqual(session.preferences, [.builtInMic])

        h.clock.isForeground = false
        h.setUseBuiltInMicrophone(false)   // deferred
        TestSupport.expectEqual(h.capture.reconfigureCount, 0)
        TestSupport.expect(h.capture.needsReconfiguration, "deferred change not pending")
        // Headphones plugged in while in the background: the applied (built-in) choice is re-asserted,
        // and the category is still the built-in one.
        h.capture.routeChanged(to: .headset)
        TestSupport.expectEqual(session.preferences, [.builtInMic, .builtInMic])
        TestSupport.expectEqual(session.categories, [builtIn])

        // Back in front: the desired choice is applied (hands-free category, preference cleared), and
        // from then on the system's choice stands.
        h.clock.isForeground = true
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.capture.reconfigureCount, 1)
        TestSupport.expectEqual(session.categories.last, MicrophoneRoute.categoryOptions(useBuiltInMicrophone: false))
        TestSupport.expectEqual(session.preferences.last, .some(nil))
        TestSupport.expect(!h.capture.needsReconfiguration, "still pending")
        let count = session.preferences.count
        h.capture.routeChanged(to: .headset)
        TestSupport.expectEqual(session.preferences.count, count)
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.capture.reconfigureCount, 1)
    }

    /// The built-in microphone cannot be selected (iOS refuses the request, a headset stays in use): the
    /// routing is unresolved, which Home reports, and dictation goes on with the headset.
    @MainActor
    private static func testUnresolvedMicrophoneChoiceKeepsDictating() {
        let h = CoreHarness()
        defer { h.cleanup() }
        h.capture.routeSession.current = .headset
        h.capture.routeSession.answer = .fail
        h.record(R)
        TestSupport.expectEqual(h.capture.router.routing, .unresolved(.headset))
        TestSupport.expectEqual(h.status?.session, .active)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.completeTail()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "dictation stopped")
        h.transcriber.complete(.success("words"))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .completed }, "not completed")
        // The headset is unplugged: the next route change retries and resolves.
        h.capture.routeSession.answer = .immediately
        h.capture.routeChanged(to: .headset)
        TestSupport.expectEqual(h.capture.router.routing, .builtInMicrophone)
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

    let clock: Clock
    let background = BackgroundTasks()
    let directory = TestSupport.makeTemporaryDirectory()
    let suite = "LocalFlowIOSTests.\(UUID().uuidString)"
    let store: SharedDictationStore
    let settings: LocalFlowSettings
    let buffer: DictationSampleBuffer
    let fakeCapture: FakeCapture?
    let transcriber = FakeTranscriber()
    let core: HostSessionCore
    var published: [HostStatus] = []

    /// The fake capture; tests that inject another capture do not use it.
    var capture: FakeCapture { fakeCapture! }

    init(launch: Bool = true, maxDuration: TimeInterval = DictationProtocol.maxDictationDuration,
         capture injected: HostCapture? = nil) {
        let clock = Clock()
        self.clock = clock
        store = SharedDictationStore(directory: directory)
        settings = LocalFlowSettings(defaults: UserDefaults(suiteName: suite)!)
        buffer = DictationSampleBuffer(maxDuration: maxDuration)
        fakeCapture = injected == nil ? FakeCapture(clock: clock) : nil
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
                               capture: injected ?? fakeCapture!, transcriber: transcriber, notifier: nil,
                               environment: environment)
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

    /// Delivers one buffer from another thread, as the capture pipeline does.
    func deliver(count: Int = 1_600, loud: Bool = false) {
        let samples = (0..<count).map { (loud ? 0.3 : 0.01) * sinf(Float($0) * 0.2) }
        let buffer = self.buffer
        let core = self.core
        DispatchQueue.global().sync {
            guard let token = buffer.recordingToken,
                  let event = CaptureEvent(buffer.append(samples, token: token)) else { return }
            core.captureDelivered(event)
        }
        keepCaptureFresh()
    }

    /// Samples arriving while recording, between ticks.
    func feed(count: Int = 1_600) { deliver(count: count) }

    /// What `HostSessionController.setUseBuiltInMicrophone` does: record the desired choice on the
    /// capture's router, then let the core apply it if it may.
    func setUseBuiltInMicrophone(_ value: Bool) {
        capture.router.setDesired(value)
        core.captureSettingsChanged()
    }

    /// The capture reports that every frame captured before the finish has arrived.
    func completeTail() {
        core.captureDelivered(.tailComplete(generation: buffer.generation))
    }

    func keepCaptureFresh() { fakeCapture?.resumeDelivery() }

    /// Admits `requestID` from the foreground and waits until it is recording.
    func record(_ requestID: UUID) {
        writeIntent(.record, requestID)
        core.reconcile(.activation)
        deliver()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { self.core.current?.phase == .recording },
                           "\(requestID) did not start recording")
    }
}

/// A capture whose buffers arrive whenever it runs, until `stall()`.
@MainActor
private final class FakeCapture: HostCapture {
    let clock: CoreHarness.Clock
    var permission = CapturePermission.granted
    var failStart = false
    var failRestart = false
    var startCount = 0
    var restartCount = 0
    var reconfigureCount = 0
    var failReconfigure = false
    var boundaryCount = 0
    var isRunning = false
    /// The route path of `MicrophoneCapture`: the real router over a fake audio session.
    let router = MicrophoneRouter()
    let routeSession = FakeRouteSession(available: [.builtInMic, .headset])
    private(set) var engineGeneration: UInt64 = 0
    private var delivering = true
    private var stalledAt: Date?
    private var pendingRequest: CheckedContinuation<Bool, Never>?

    init(clock: CoreHarness.Clock) { self.clock = clock }

    var lastBufferAt: Date? { delivering ? (isRunning ? clock.now : nil) : stalledAt }

    func stall() {
        stalledAt = clock.now
        delivering = false
    }

    func resumeDelivery() { delivering = true }

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
        TestSupport.expect(clock.isForeground, "a session was started in the background")
        guard !failStart else { throw CocoaError(.featureUnsupported) }
        startCount += 1
        try router.configureCategory(routeSession)
        router.applyInput(routeSession)
        isRunning = true
        engineGeneration += 1
    }

    func restart() throws {
        TestSupport.expect(isRunning, "restart without a running session")
        guard !failRestart else { throw CocoaError(.featureUnsupported) }
        restartCount += 1
        engineGeneration += 1
    }

    func reconfigure() throws {
        TestSupport.expect(clock.isForeground, "capture reconfigured in the background")
        TestSupport.expect(isRunning, "reconfigured without a session")
        guard !failReconfigure else { throw CocoaError(.featureUnsupported) }
        reconfigureCount += 1
        try router.configureCategory(routeSession)
        router.applyInput(routeSession)
        engineGeneration += 1
    }

    func stop() {
        isRunning = false
        router.sessionEnded()
    }

    func recordingBoundary() { boundaryCount += 1 }

    var needsReconfiguration: Bool { isRunning && router.needsReconfiguration }

    /// A route notification, as `MicrophoneCapture` handles it.
    func routeChanged(to input: InputPortKind) {
        routeSession.current = input
        if isRunning { router.routeChanged(routeSession, change: RouteChange(reason: .newDeviceAvailable)) }
    }
}

/// A model that answers when told to. It honors cancellation like `TranscriptionEngine`, unless a test
/// simulates a runtime that finishes anyway. It never keeps the audio beyond the call.
@MainActor
private final class FakeTranscriber: HostTranscriber {
    var modelState = HostStatus.Model.ready
    var honorsCancellation = true
    var busy = false
    var prepareCount = 0
    var releaseAttempts = 0
    var releaseCount = 0
    /// Sample counts of every recording handed over.
    var received: [Int] = []
    weak var lastAudio: RecordedAudio?
    private var pending: [(id: UUID, continuation: CheckedContinuation<String, Error>)] = []

    var pendingCount: Int { pending.count }

    func prepare() { prepareCount += 1 }

    func transcribe(_ audio: RecordedAudio) async throws -> String {
        received.append(audio.samples.count)
        lastAudio = audio
        let id = UUID()
        let honors = honorsCancellation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending.append((id, $0)) }
        } onCancel: {
            guard honors else { return }
            Task { @MainActor in self.resume(id, with: .failure(CancellationError())) }
        }
    }

    func releaseIfIdle() -> Bool {
        releaseAttempts += 1
        guard !busy else { return false }
        releaseCount += 1
        modelState = .notPrepared
        return true
    }

    /// Completes the oldest pending transcription.
    func complete(_ result: Result<String, Error>) {
        guard let id = pending.first?.id else { return }
        resume(id, with: result)
    }

    func cancelAll() {
        while let id = pending.first?.id { resume(id, with: .failure(CancellationError())) }
    }

    private func resume(_ id: UUID, with result: Result<String, Error>) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(with: result)
    }
}
