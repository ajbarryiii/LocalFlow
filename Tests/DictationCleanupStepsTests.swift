import Foundation

/// Every way a dictation is torn down runs one step list in
/// `DictationCleanupSteps`; AppState performs the steps. These tests pin each
/// list's exact order and completeness against a recording fake.
enum DictationCleanupStepsTests {
    static func run() {
        MainActor.assumeIsolated {
            testDiscardCapture()
            testCancelToggleSession()
            testCancelTranscription()
            testAwaitMicrophonePermission()
            testRecordingFailed()
            testStopCaptureForTranscription()
            testNoAudioRecorded()
            testRecordingStoppedAfterCancel()
            testFinishTranscription()
            testTranscriptionCancelled()
            testMicrophonesRefreshOnlyAfterRecordingEnds()
        }
    }

    /// The capture teardown shared by a discarded capture and a cancelled
    /// Tap to Toggle session, differing only in the status shown.
    private static func captureTeardown(status: String) -> [String] {
        ["detachRecorder", "cancelInitTimer", "cancelStreaming", "notRecording", status, "dismissOverlay",
         "cancelRecorder", "restoreAudio", "endActivity", "refreshMicrophones"]
    }

    /// A too-short hold's capture: thrown away, back to Ready, no "Cancelled".
    @MainActor
    private static func testDiscardCapture() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.discardCapture(actions)
        TestSupport.expectEqual(actions.log, captureTeardown(status: "status(ready)"))
    }

    /// Escape or a cancel during Tap to Toggle: the pending start and the
    /// session end first, the capture is thrown away, "Cancelled" then resets.
    @MainActor
    private static func testCancelToggleSession() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.cancelToggleSession(actions)
        TestSupport.expectEqual(actions.log, ["cancelPendingStart", "endSession"]
            + captureTeardown(status: "status(cancelled)") + ["scheduleReady"])
    }

    /// Escape while transcribing: the task is cancelled before anything else,
    /// and the saved recording is deleted rather than kept for history.
    @MainActor
    private static func testCancelTranscription() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.cancelTranscription(actions)
        TestSupport.expectEqual(actions.log, [
            "cancelTask", "stopCorrections", "endSession", "notRecording", "notTranscribing", "status(cancelled)",
            "dismissOverlay", "cleanUpRecorder", "deleteAudio", "endActivity", "refreshMicrophones", "scheduleReady",
        ])
    }

    /// Before the system microphone prompt: shortcuts stop and the start in
    /// progress is unwound, but nothing was recorded or begun to clean up.
    @MainActor
    private static func testAwaitMicrophonePermission() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.awaitMicrophonePermission(actions)
        TestSupport.expectEqual(actions.log, ["stopHotkeys", "endSession", "cancelInitTimer", "detachRecorder",
                                              "dismissOverlay"])
    }

    /// A recording that failed to start or stopped with an error: everything
    /// a recording or transcription could hold is released.
    @MainActor
    private static func testRecordingFailed() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.recordingFailed(message: "Synthetic failure", actions)
        TestSupport.expectEqual(actions.log, [
            "cancelInitTimer", "detachRecorder", "cancelStreaming", "cleanUpRecorder", "restoreAudio", "notRecording",
            "notTranscribing", "cancelTask", "deleteAudio", "endSession", "endActivity",
            "status(failed: Synthetic failure)", "dismissOverlay", "refreshMicrophones",
        ])
    }

    /// A normal stop: recording ends and audio output is restored, but the
    /// capture and the critical activity continue into transcription.
    @MainActor
    private static func testStopCaptureForTranscription() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.stopCaptureForTranscription(actions)
        TestSupport.expectEqual(actions.log, ["cancelPendingStart", "cancelInitTimer", "endSession", "detachRecorder",
                                              "notRecording", "restoreAudio"])
    }

    @MainActor
    private static func testNoAudioRecorded() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.noAudioRecorded(actions)
        TestSupport.expectEqual(actions.log, ["notTranscribing", "cleanUpRecorder", "endActivity",
                                              "status(failed: No audio recorded)", "dismissOverlay",
                                              "refreshMicrophones"])
    }

    /// The recording finished stopping after its transcription was cancelled:
    /// the cancel already reset everything else.
    @MainActor
    private static func testRecordingStoppedAfterCancel() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.recordingStoppedAfterCancel(actions)
        TestSupport.expectEqual(actions.log, ["cleanUpRecorder", "refreshMicrophones"])
    }

    /// Success and transcription error share one teardown around their report;
    /// the saved recording stays, since the history entry refers to it.
    @MainActor
    private static func testFinishTranscription() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.finishTranscription(actions) { actions.log.append("report") }
        TestSupport.expectEqual(actions.log, ["finishTask", "forgetAudio", "notTranscribing", "endActivity", "report",
                                              "cleanUpRecorder", "refreshMicrophones"])
    }

    @MainActor
    private static func testTranscriptionCancelled() {
        let actions = RecordingCleanup()
        DictationCleanupSteps.transcriptionCancelled(actions)
        TestSupport.expectEqual(actions.log, ["finishTask", "endActivity"])
    }

    /// The microphone list refresh is skipped while recording, so every list
    /// that ends a recording clears the flag before it refreshes.
    @MainActor
    private static func testMicrophonesRefreshOnlyAfterRecordingEnds() {
        let lists: [(String, (RecordingCleanup) -> Void)] = [
            ("discardCapture", { DictationCleanupSteps.discardCapture($0) }),
            ("cancelToggleSession", { DictationCleanupSteps.cancelToggleSession($0) }),
            ("cancelTranscription", { DictationCleanupSteps.cancelTranscription($0) }),
            ("recordingFailed", { DictationCleanupSteps.recordingFailed(message: "Synthetic failure", $0) }),
        ]
        for (name, list) in lists {
            let actions = RecordingCleanup()
            list(actions)
            guard let cleared = actions.log.firstIndex(of: "notRecording"),
                  let refreshed = actions.log.firstIndex(of: "refreshMicrophones") else {
                TestSupport.expect(false, "\(name) clears recording and refreshes microphones")
                return
            }
            TestSupport.expect(cleared < refreshed, "\(name) clears recording before refreshing microphones")
        }
    }
}

/// Records what a cleanup step list did, in order, with optional effects.
@MainActor
final class RecordingCleanup: DictationCleanupActions {
    var log: [String] = []
    var onStopCorrections: () -> Void = {}
    var onWithdraw: () -> Void = {}

    func stopCorrectionSuggestions() {
        log.append("stopCorrections")
        onStopCorrections()
    }

    func withdrawDictionarySuggestion() {
        log.append("withdraw")
        onWithdraw()
    }

    func invalidateRecordingAttempt() { log.append("invalidate") }
    func cancelDiscardedCapture() { log.append("cancelCapture") }
    func cancelPendingShortcutStart() { log.append("cancelPendingStart") }
    func endShortcutSession() { log.append("endSession") }
    func stopShortcutMonitor() { log.append("stopHotkeys") }
    func cancelRecordingInitializationTimer() { log.append("cancelInitTimer") }
    func detachRecorderCallbacks() { log.append("detachRecorder") }
    func cancelStreamingDictation() { log.append("cancelStreaming") }
    func markNotRecording() { log.append("notRecording") }
    func cancelRecorderCapture() { log.append("cancelRecorder") }
    func cleanUpRecorderFiles() { log.append("cleanUpRecorder") }
    func restoreAudioInterruptionIfNeeded() { log.append("restoreAudio") }
    func cancelTranscriptionTask() { log.append("cancelTask") }
    func finishTranscriptionTask() { log.append("finishTask") }
    func markNotTranscribing() { log.append("notTranscribing") }
    func deleteTranscribingAudio() { log.append("deleteAudio") }
    func forgetTranscribingAudio() { log.append("forgetAudio") }

    func showStatus(_ status: DictationCleanupStatus) {
        switch status {
        case .ready: log.append("status(ready)")
        case .cancelled: log.append("status(cancelled)")
        case .failed(let message): log.append("status(failed: \(message))")
        }
    }

    func dismissOverlay() { log.append("dismissOverlay") }
    func scheduleReadyStatusAfterCancel() { log.append("scheduleReady") }
    func endCriticalDictationActivity() { log.append("endActivity") }
    func refreshAvailableMicrophonesIfNeeded() { log.append("refreshMicrophones") }
}
