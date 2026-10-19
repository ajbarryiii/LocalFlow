import Foundation
import os

/// What happens to the temporary recording file once capture has ended and
/// the writer has drained. Only a completed, non-empty, error-free recording
/// is kept; every other file is deleted, so cancelled or discarded audio never
/// stays on disk.
struct AudioFileDisposition: Equatable {
    let keep: URL?
    let delete: URL?

    static func decide(url: URL?, discard: Bool, recordedFrames: Int64, writeFailed: Bool) -> AudioFileDisposition {
        guard let url else { return AudioFileDisposition(keep: nil, delete: nil) }
        let keep = !discard && recordedFrames > 0 && !writeFailed
        return keep ? AudioFileDisposition(keep: url, delete: nil) : AudioFileDisposition(keep: nil, delete: url)
    }

    /// Removes the file that is not kept, if there is one.
    func removeDiscarded(fileManager: FileManager = .default) {
        if let delete { try? fileManager.removeItem(at: delete) }
    }
}

/// The recorder's capture lifecycle, behind one lock because the main thread,
/// the session queue and the sample-buffer queue all reach it.
///
/// - **Tickets.** A start reserves a ticket on the main thread before its work
///   is dispatched; `cancel()` voids every ticket reserved so far. The session
///   queue admits a start only with a still-valid ticket, so a start that was
///   queued before a cancel but arrives after it creates no session.
/// - **Captures.** Each admitted start is a new capture id. Readiness and
///   failures are claimed for the capture they came from, so a queued failure
///   of capture A can never claim, tear down or call back for capture B, and
///   main-thread deliveries happen only for the latest capture.
/// - **Outputs.** Buffers count only from an output attached to a capture.
///   A stopping capture keeps its output until its queued buffers and the
///   writer have drained (`stop(_:drain:)`), so a normal stop loses nothing.
final class CaptureLifecycle: @unchecked Sendable {
    private struct State {
        var tickets: UInt64 = 0
        var lastCapture: UInt64 = 0
        var current: UInt64?
        /// The only capture whose main-thread deliveries may run. Cleared at once
        /// by a cancel or by reserving a replacement, before that is admitted.
        var deliverable: UInt64?
        var startTime: Double = 0
        var readyFired = false
        var failureReported = false
        var outputs: [ObjectIdentifier: UInt64] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Main thread, before dispatching the start.
    func reserve() -> UInt64 {
        state.withLock { state in
            state.deliverable = nil
            return state.tickets
        }
    }

    /// Any thread, at once: every ticket reserved so far is void.
    func cancel() {
        state.withLock { state in
            state.tickets &+= 1
            state.deliverable = nil
        }
    }

    /// Session queue: the new capture id, or nil when the ticket was cancelled.
    func admit(ticket: UInt64, at time: Double) -> UInt64? {
        state.withLock { state in
            guard ticket == state.tickets else { return nil }
            state.lastCapture &+= 1
            state.current = state.lastCapture
            state.deliverable = state.lastCapture
            state.startTime = time
            state.readyFired = false
            state.failureReported = false
            return state.lastCapture
        }
    }

    /// The capture's output, attached before its session starts running.
    func attach(_ output: ObjectIdentifier, to capture: UInt64) {
        state.withLock { $0.outputs[output] = capture }
    }

    /// The capture a buffer from `output` belongs to, while it is recorded or drained.
    func capture(for output: ObjectIdentifier) -> UInt64? { state.withLock { $0.outputs[output] } }

    var currentCapture: UInt64? { state.withLock { $0.current } }

    var startTime: Double { state.withLock { $0.startTime } }

    func isCurrent(_ capture: UInt64) -> Bool { state.withLock { $0.current == capture } }

    /// Main-thread delivery (readiness, failure): only for the admitted capture
    /// that no cancel or replacement reservation has superseded.
    func mayDeliver(_ capture: UInt64) -> Bool { state.withLock { $0.deliverable == capture } }

    /// Main thread: a successful start may publish `isRecording = true` only while
    /// its capture is still current (not stopped) and deliverable (not cancelled
    /// or replaced).
    func mayPublishStart(_ capture: UInt64) -> Bool {
        state.withLock { $0.current == capture && $0.deliverable == capture }
    }

    /// The first non-silent buffer of the current capture: true exactly once.
    func claimReady(_ capture: UInt64, rms: Float) -> Bool {
        state.withLock { state in
            guard state.current == capture, !state.readyFired, rms > 0 else { return false }
            state.readyFired = true
            return true
        }
    }

    /// The first failure of the current capture: true exactly once. A failure
    /// from an earlier capture claims nothing.
    func claimFailure(_ capture: UInt64) -> Bool {
        state.withLock { state in
            guard state.current == capture, !state.failureReported else { return false }
            state.failureReported = true
            return true
        }
    }

    /// Session queue: admits `ticket` and runs `setup` for the new capture. If
    /// setup throws, `cleanUp` runs and the capture ends before this returns,
    /// inside the same queue operation, so a start queued behind it never has
    /// its state touched by this one's failure. Throws `cancelled` when the
    /// ticket was voided.
    func start(ticket: UInt64, at time: Double, setup: (UInt64) throws -> Void, cleanUp: () -> Void,
               cancelled: Error) throws -> UInt64 {
        guard let capture = admit(ticket: ticket, at: time) else { throw cancelled }
        do {
            try setup(capture)
        } catch {
            cleanUp()
            finish(capture)
            state.withLock { if $0.deliverable == capture { $0.deliverable = nil } }
            throw error
        }
        return capture
    }

    /// Session queue: `drain` (the sample queue and writer) runs first, with the
    /// capture's buffers still accepted; only then is its output detached.
    func stop<T>(_ capture: UInt64?, drain: () -> T) -> T {
        let result = drain()
        finish(capture)
        return result
    }

    private func finish(_ capture: UInt64?) {
        guard let capture else { return }
        state.withLock { state in
            if state.current == capture { state.current = nil }
            state.outputs = state.outputs.filter { $0.value != capture }
        }
    }
}

/// Recording attempts, so main-queue work queued for one (the initializing
/// overlay, a readiness or failure callback, the background start's
/// completion) does nothing once that attempt was discarded. Main thread only.
struct RecordingAttempts {
    private(set) var current: UInt64 = 0
    /// Recordings begun, whatever started them; a discard does not change it.
    private(set) var begun: UInt64 = 0

    mutating func begin() -> UInt64 {
        begun &+= 1
        current &+= 1
        return current
    }

    mutating func invalidate() { current &+= 1 }

    func isCurrent(_ attempt: UInt64) -> Bool { attempt == current }
}

/// The status a teardown leaves behind.
enum DictationCleanupStatus: Equatable {
    /// No error; "Ready" (debug status "Idle").
    case ready
    /// No error; "Cancelled" (debug status "Cancelled").
    case cancelled
    /// The message is shown as the error with status "Error"; the debug
    /// status is left as it was.
    case failed(String)
}

/// What the app does at a dictation's cleanup points. AppState conforms, and
/// runs the step lists below exactly as written, so tests with a recording
/// fake see the real sequence. Main actor: every action touches app state.
@MainActor
protocol DictationCleanupActions: AnyObject {
    // Corrections
    /// End the correction watch, any running verification and retained audio.
    func stopCorrectionSuggestions()
    /// Withdraw a visible dictionary suggestion and void any requested one.
    func withdrawDictionarySuggestion()

    // Shortcuts and attempts
    /// Make work already queued for the current recording attempt a no-op.
    func invalidateRecordingAttempt()
    /// Drop a shortcut start still waiting for the start delay.
    func cancelPendingShortcutStart()
    /// Reset the shortcut session and forget the recording's trigger mode.
    func endShortcutSession()
    /// Stop the global shortcut monitor (it is restarted explicitly later).
    func stopShortcutMonitor()

    // Capture
    /// Stop and throw away the capture in progress (no transcription).
    func cancelDiscardedCapture()
    /// Cancel the timer that shows the initializing overlay for a slow start.
    func cancelRecordingInitializationTimer()
    /// Detach the recorder's readiness and failure callbacks and its level stream.
    func detachRecorderCallbacks()
    /// Cancel the recording's live transcription, dropping its audio and result.
    func cancelStreamingDictation()
    /// Publish that the app is no longer recording.
    func markNotRecording()
    /// Cancel the recorder's capture; its audio file is deleted.
    func cancelRecorderCapture()
    /// Remove the recorder's temporary audio file.
    func cleanUpRecorderFiles()
    /// Unmute system output if dictation muted it.
    func restoreAudioInterruptionIfNeeded()

    // Transcription
    /// Cancel the running transcription task and forget it.
    func cancelTranscriptionTask()
    /// Forget the transcription task without cancelling it (it is finishing).
    func finishTranscriptionTask()
    /// Publish that the app is no longer transcribing.
    func markNotTranscribing()
    /// Delete the saved copy of the recording being transcribed.
    func deleteTranscribingAudio()
    /// Forget the saved copy without deleting it: its history entry keeps it.
    func forgetTranscribingAudio()

    // Presentation and process
    func showStatus(_ status: DictationCleanupStatus)
    func dismissOverlay()
    /// Return to "Ready" a moment after "Cancelled", if nothing started since.
    func scheduleReadyStatusAfterCancel()
    /// Allow automatic termination again.
    func endCriticalDictationActivity()
    /// Refresh the microphone list if a device change arrived while recording.
    func refreshAvailableMicrophonesIfNeeded()
}

/// Each way a dictation is torn down, as one list of steps. AppState's cancel,
/// failure and stop paths call these; each is pinned by DictationCleanupStepsTests.
@MainActor
enum DictationCleanupSteps {
    /// A dictation shortcut press was accepted (its start may still be
    /// delayed): correction work ends, so no verification result can present
    /// during the delay, and a visible suggestion is withdrawn at once.
    static func acceptedPress(_ actions: DictationCleanupActions) {
        actions.stopCorrectionSuggestions()
        actions.withdrawDictionarySuggestion()
    }

    /// A too-short Hold to Talk tap is discarded. Queued work for it is voided
    /// first; correction cleanup and the withdrawal run even when the tap ended
    /// before capture started (a start delay); the capture, if any, goes last.
    static func discardTooShortHold(isRecording: Bool, _ actions: DictationCleanupActions) {
        actions.invalidateRecordingAttempt()
        actions.stopCorrectionSuggestions()
        actions.withdrawDictionarySuggestion()
        if isRecording { actions.cancelDiscardedCapture() }
    }

    /// The capture in progress is thrown away (a too-short hold). The status
    /// goes straight back to Ready: a discard is not a user-visible cancel.
    static func discardCapture(_ actions: DictationCleanupActions) {
        tearDownCapture(showing: .ready, actions)
    }

    /// Escape (or another cancel) during a Tap to Toggle session, recording or
    /// still waiting for its start delay.
    static func cancelToggleSession(_ actions: DictationCleanupActions) {
        actions.cancelPendingShortcutStart()
        actions.endShortcutSession()
        tearDownCapture(showing: .cancelled, actions)
        actions.scheduleReadyStatusAfterCancel()
    }

    /// Escape while transcribing. The task is cancelled first, so its result
    /// can never be pasted; the saved recording is deleted, not kept for history.
    static func cancelTranscription(_ actions: DictationCleanupActions) {
        actions.cancelTranscriptionTask()
        actions.stopCorrectionSuggestions()
        actions.endShortcutSession()
        actions.markNotRecording()
        actions.markNotTranscribing()
        actions.showStatus(.cancelled)
        actions.dismissOverlay()
        actions.cleanUpRecorderFiles()
        actions.deleteTranscribingAudio()
        actions.endCriticalDictationActivity()
        actions.refreshAvailableMicrophonesIfNeeded()
        actions.scheduleReadyStatusAfterCancel()
    }

    /// Before the system microphone prompt. Shortcuts stop while it is shown,
    /// and the start in progress is unwound. Nothing was recorded, no output
    /// was muted and no critical activity began, so none of that is undone.
    static func awaitMicrophonePermission(_ actions: DictationCleanupActions) {
        actions.stopShortcutMonitor()
        actions.endShortcutSession()
        actions.cancelRecordingInitializationTimer()
        actions.detachRecorderCallbacks()
        actions.dismissOverlay()
    }

    /// The recorder failed to start or failed while recording. Unlike a cancel
    /// it cleans up rather than cancels the capture (the recorder has already
    /// torn its session down), and it also ends any transcription in progress.
    static func recordingFailed(message: String, _ actions: DictationCleanupActions) {
        actions.cancelRecordingInitializationTimer()
        actions.detachRecorderCallbacks()
        actions.cancelStreamingDictation()
        actions.cleanUpRecorderFiles()
        actions.restoreAudioInterruptionIfNeeded()
        actions.markNotRecording()
        actions.markNotTranscribing()
        actions.cancelTranscriptionTask()
        actions.deleteTranscribingAudio()
        actions.endShortcutSession()
        actions.endCriticalDictationActivity()
        actions.showStatus(.failed(message))
        actions.dismissOverlay()
        actions.refreshAvailableMicrophonesIfNeeded()
    }

    /// A recording stops normally to be transcribed. The capture itself, the
    /// live transcription and the critical activity carry on into transcription.
    static func stopCaptureForTranscription(_ actions: DictationCleanupActions) {
        actions.cancelPendingShortcutStart()
        actions.cancelRecordingInitializationTimer()
        actions.endShortcutSession()
        actions.detachRecorderCallbacks()
        actions.markNotRecording()
        actions.restoreAudioInterruptionIfNeeded()
    }

    /// The stopped recording produced no audio file.
    static func noAudioRecorded(_ actions: DictationCleanupActions) {
        actions.markNotTranscribing()
        actions.cleanUpRecorderFiles()
        actions.endCriticalDictationActivity()
        actions.showStatus(.failed("No audio recorded"))
        actions.dismissOverlay()
        actions.refreshAvailableMicrophonesIfNeeded()
    }

    /// The recording finished stopping after its transcription was cancelled;
    /// the cancel already reset everything else.
    static func recordingStoppedAfterCancel(_ actions: DictationCleanupActions) {
        actions.cleanUpRecorderFiles()
        actions.refreshAvailableMicrophonesIfNeeded()
    }

    /// A transcription finished, with output or with an error: `report` shows
    /// the result (status, overlay, paste or error, history). The saved
    /// recording is kept because the history entry refers to it.
    static func finishTranscription(_ actions: DictationCleanupActions, report: () -> Void) {
        actions.finishTranscriptionTask()
        actions.forgetTranscribingAudio()
        actions.markNotTranscribing()
        actions.endCriticalDictationActivity()
        report()
        actions.cleanUpRecorderFiles()
        actions.refreshAvailableMicrophonesIfNeeded()
    }

    /// The transcription task observed its cancellation. Whoever cancelled it
    /// reset the rest.
    static func transcriptionCancelled(_ actions: DictationCleanupActions) {
        actions.finishTranscriptionTask()
        actions.endCriticalDictationActivity()
    }

    /// Ends a capture that is thrown away (never transcribed).
    private static func tearDownCapture(showing status: DictationCleanupStatus, _ actions: DictationCleanupActions) {
        actions.detachRecorderCallbacks()
        actions.cancelRecordingInitializationTimer()
        actions.cancelStreamingDictation()
        actions.markNotRecording()
        actions.showStatus(status)
        actions.dismissOverlay()
        actions.cancelRecorderCapture()
        actions.restoreAudioInterruptionIfNeeded()
        actions.endCriticalDictationActivity()
        actions.refreshAvailableMicrophonesIfNeeded()
    }
}
