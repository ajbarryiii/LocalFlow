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

/// Orders capture starts against cancels. A start remembers the generation
/// when it was requested; a cancel advances it at once, from the caller's
/// thread. A start whose session work runs after that cancel creates no
/// session, while a cancel's own teardown, queued first, can never stop a
/// later start. Thread-safe.
final class CaptureStartGate: @unchecked Sendable {
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    func requestStart() -> UInt64 { generation.withLock { $0 } }

    func cancel() { generation.withLock { $0 &+= 1 } }

    func mayStart(_ request: UInt64) -> Bool { generation.withLock { $0 == request } }
}

/// Per-capture recorder state, shared by the session queue and the
/// sample-buffer queue, so it lives behind one lock. It is reset on the
/// session queue when a start is admitted; buffers from any output other than
/// the current one (a late buffer from a discarded tap) are ignored.
struct CaptureAttemptState {
    private(set) var startTime: Double = 0
    private(set) var readyFired = false
    private(set) var failureReported = false
    private var output: ObjectIdentifier?

    /// A start was admitted: nothing from an earlier capture carries over.
    mutating func begin(at time: Double) {
        startTime = time
        readyFired = false
        failureReported = false
        output = nil
    }

    /// The new session's output, attached before it starts running.
    mutating func attach(_ output: ObjectIdentifier) { self.output = output }

    mutating func detach() { output = nil }

    func accepts(_ output: ObjectIdentifier) -> Bool { self.output == output }

    /// The first non-silent buffer of this capture: true exactly once.
    mutating func claimReady(rms: Float) -> Bool {
        guard !readyFired, rms > 0 else { return false }
        readyFired = true
        return true
    }

    /// The first failure of this capture: true exactly once.
    mutating func claimFailure() -> Bool {
        guard !failureReported else { return false }
        failureReported = true
        return true
    }
}

/// Recording attempts, so main-queue work queued for one (the initializing
/// overlay, a readiness or failure callback, the background start's
/// completion) does nothing once that attempt was discarded. Main thread only.
struct RecordingAttempts {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() { current &+= 1 }

    func isCurrent(_ attempt: UInt64) -> Bool { attempt == current }
}

/// The steps for discarding a too-short Hold to Talk tap. Correction cleanup
/// runs even when the tap ended before capture started (a shortcut start
/// delay), since starting would have run it.
struct TooShortHoldDiscard: Equatable {
    let stopCorrectionSuggestions: Bool
    let invalidateAttempt: Bool
    let cancelCapture: Bool

    static func steps(isRecording: Bool) -> TooShortHoldDiscard {
        TooShortHoldDiscard(stopCorrectionSuggestions: true, invalidateAttempt: true, cancelCapture: isRecording)
    }
}
