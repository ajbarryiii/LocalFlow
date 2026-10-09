import Foundation

/// How the host ends a request it stops: a terminal phase plus the content-free reason.
struct DictationOutcome: Equatable, Sendable {
    var phase: DictationStatus.Phase
    var error: HostErrorCode?

    static let cancelled = DictationOutcome(phase: .cancelled, error: nil)
    static func cancelled(_ error: HostErrorCode) -> DictationOutcome { DictationOutcome(phase: .cancelled, error: error) }
    static func failed(_ error: HostErrorCode) -> DictationOutcome { DictationOutcome(phase: .failed, error: error) }
}

/// Why a session ends.
enum SessionEndReason: Equatable, Sendable {
    case user
    case idleExpired
    case interrupted
    case deviceLocked
    /// The engine stopped and could not be restarted (or the app was in the background).
    case engineFailed
    /// Permission or audio-session activation failed while starting.
    case startFailed(HostErrorCode)
}

/// What wakes a reconciliation pass.
enum ReconcileTrigger: Equatable, Sendable { case launch, intentSignal, poll, urlOpen, activation }

/// Timing and decision rules of the host session. Pure, so every rule is tested on the Mac.
enum HostSessionPolicy {
    /// The controller's timer. Watchdog, idle expiry, polling and status cadence are evaluated on it.
    static let tickInterval: TimeInterval = 0.1
    /// Intent polling while a session is live or the app is in the foreground.
    static let reconcileInterval: TimeInterval = 0.5
    /// About 10 Hz while starting or recording, for the keyboard's level meter.
    static let fastStatusInterval: TimeInterval = 0.1
    /// How long the engine may be stopped before the session treats it as failed. An interruption stops
    /// the engine and posts its notification at about the same time; this lets the notification win, so
    /// a call is reported as `.interrupted` rather than restarted or reported as an engine failure.
    static let captureStallGrace: TimeInterval = 0.5

    static func statusInterval(for dictation: DictationStatus?) -> TimeInterval {
        switch dictation?.phase {
        case .starting?, .recording?: return fastStatusInterval
        default: return DictationProtocol.heartbeatInterval
        }
    }

    /// Whether a periodic action last done at `last` is due. Half a tick of slack keeps timer jitter from
    /// stretching a 1 s heartbeat to 1.1 s; a backward clock jump makes it due at once.
    static func isDue(last: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= interval - tickInterval / 2
    }

    /// Idle expiry counts from `idleSince`: the session start or the end of the last dictation. It is nil
    /// while a dictation is starting, recording or transcribing, so expiry never interrupts one.
    static func sessionExpiresAt(session: HostStatus.Session, idleSince: Date?, duration: TimeInterval) -> Date? {
        guard session == .active, let idleSince else { return nil }
        return idleSince.addingTimeInterval(duration)
    }

    /// Fails closed like every freshness check: a backward clock jump past the tolerance expires the
    /// session instead of extending it.
    static func isIdleExpired(idleSince: Date?, duration: TimeInterval, now: Date) -> Bool {
        guard let idleSince else { return false }
        return !DictationProtocol.isFresh(idleSince, ttl: duration, now: now)
    }

    /// The `isForeground` to reconcile with, or nil to skip the pass.
    /// - A URL open counts as foreground: the system is bringing the app forward (contract).
    /// - A process that has never been in the foreground (a prewarmed launch) skips: without a session
    ///   it could only reject, and would reject for good the request its own bounce is about to admit.
    static func reconcileForeground(trigger: ReconcileTrigger, isForeground: Bool, hasBeenForeground: Bool) -> Bool? {
        if trigger == .urlOpen { return true }
        guard isForeground || hasBeenForeground else { return nil }
        return isForeground
    }

    /// The reconciler's `cancel(R)`. For a `finish` that reached a request still starting nothing was
    /// captured, which is reported as failed `.notRecording`; a keyboard `cancel` is a plain cancel.
    static func cancelOutcome(intentAction: KeyboardIntent.Action?) -> DictationOutcome {
        intentAction == .finish ? .failed(.notRecording) : .cancelled
    }

    /// `HostWatchdog` reasons: a startup timeout is a failure; a dismissed keyboard is a cancellation.
    static func watchdogOutcome(_ reason: HostErrorCode) -> DictationOutcome {
        reason == .keyboardDismissed ? .cancelled(.keyboardDismissed) : .failed(reason)
    }

    /// What happens to an in-progress request when the session ends, or nil to let it continue.
    /// Transcription needs no audio, so it survives everything but device lock, where class A
    /// result files can no longer be written.
    static func sessionEndOutcome(_ reason: SessionEndReason, phase: DictationStatus.Phase) -> DictationOutcome? {
        switch phase {
        case .starting, .recording:
            switch reason {
            case .user, .idleExpired: return .cancelled(.sessionInactive)
            case .interrupted: return .failed(.interrupted)
            case .deviceLocked: return .cancelled(.deviceLocked)
            case .engineFailed: return .failed(.audioSessionFailed)
            case .startFailed(let code): return .failed(code)
            }
        case .transcribing:
            return reason == .deviceLocked ? .cancelled(.deviceLocked) : nil
        case .completed, .failed, .cancelled:
            return nil
        }
    }

    /// The session-level `HostStatus.error` a session end leaves behind.
    static func sessionError(after reason: SessionEndReason) -> HostErrorCode? {
        switch reason {
        case .user, .idleExpired: return nil
        case .interrupted: return .interrupted
        case .deviceLocked: return .deviceLocked
        case .engineFailed: return .audioSessionFailed
        case .startFailed(let code): return code
        }
    }

    /// The published status. `captureReady` needs a running engine and an input buffer within
    /// `captureFreshness`; the level is meaningful only while recording.
    static func status(hostRunID: UUID, sessionID: UUID?, session: HostStatus.Session, captureRunning: Bool,
                       lastBufferAt: Date?, idleSince: Date?, sessionDuration: TimeInterval, model: HostStatus.Model,
                       dictation: DictationStatus?, level: Float, error: HostErrorCode?, now: Date) -> HostStatus {
        let captureReady = session == .active && captureRunning
            && lastBufferAt.map { DictationProtocol.isFresh($0, ttl: DictationProtocol.captureFreshness, now: now) } == true
        return HostStatus(
            hostRunID: hostRunID, sessionID: session == .inactive ? nil : sessionID, session: session,
            captureReady: captureReady, heartbeatAt: now,
            sessionExpiresAt: sessionExpiresAt(session: session, idleSince: idleSince, duration: sessionDuration),
            model: model, dictation: dictation, level: dictation?.phase == .recording ? level : 0, error: error)
    }
}
