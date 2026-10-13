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

/// What the app does at a dictation's cleanup points. AppState conforms, and
/// runs the step lists below exactly as written, so tests with a recording
/// fake see the real sequence.
protocol DictationCleanupActions: AnyObject {
    /// End the correction watch, any running verification and retained audio.
    func stopCorrectionSuggestions()
    /// Withdraw a visible dictionary suggestion and void any requested one.
    func withdrawDictionarySuggestion()
    /// Make work already queued for the current recording attempt a no-op.
    func invalidateRecordingAttempt()
    /// Stop and throw away the capture in progress (no transcription).
    func cancelDiscardedCapture()
}

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
}
