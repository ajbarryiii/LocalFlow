import Foundation

/// The short, content-free text the keyboard shows for a mode, an error or the host status. Pure and
/// Foundation-only, so it can move to Shared with tests.
enum KeyboardMessages {
    static let openLocalFlow = "Open LocalFlow to start a session"
    static let noSpeech = "No speech detected"
    static let preparingModel = "Preparing model…"
    /// Recording while the host prepares the model (`KeyboardPresenter.isModelPreparing`).
    static let listeningWhilePreparing = "Listening · preparing model"
    /// Idle with a live session and a released model: a tap prepares it (ARCHITECTURE.md, "Keyboard
    /// presentation"), nothing prepares it now.
    static let modelLoadsWhenDictating = "Model loads when you dictate"
    /// The Start capsule's label while a finished recording waits for the model.
    static let preparingCaption = "Preparing"
    static let storeWriteFailed = "Couldn't reach LocalFlow"
    static let fullAccessExplanation = "Full Access lets this keyboard talk to the LocalFlow app, which transcribes "
        + "your speech on this iPhone. Nothing leaves your phone."
    static let configurationErrorDetail = "The keyboard cannot reach LocalFlow's shared storage. Reinstall LocalFlow, "
        + "then add the keyboard again."
    static let incompatibleDetail = "The keyboard and the LocalFlow app are different versions. Update LocalFlow, "
        + "then open it once."

    static func fullAccessSteps(keyboardName: String) -> String {
        "Open Settings › General › Keyboard › Keyboards › \(keyboardName), then turn on Allow Full Access."
    }

    /// `launcherFailed`: opening LocalFlow from this keyboard instance has failed before, so idle
    /// guidance asks the user to open it instead of promising a tap will.
    static func title(for mode: KeyboardMode, launcherFailed: Bool) -> String {
        switch mode {
        case .needsFullAccess: return "Allow Full Access to dictate"
        case .configurationError: return "LocalFlow is not installed correctly"
        case .incompatible: return "Update LocalFlow"
        case .starting: return "Starting…"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing…"
        case .waitingForModel, .preparingModel: return preparingModel
        case .error(let code): return text(for: code)
        case .ready: return "Tap to dictate"
        case .hostUnavailable: return launcherFailed ? openLocalFlow : "Tap to start LocalFlow"
        }
    }

    /// Text beside the Start capsule's spinner. The capsule is never replaced by the candidate strip, the
    /// chips or a notice, so the wait for the model is explained whatever else holds the bar.
    static func capsuleCaption(for mode: KeyboardMode) -> String? {
        mode == .waitingForModel ? preparingCaption : nil
    }

    static func text(for code: HostErrorCode) -> String {
        switch code {
        case .microphonePermissionDenied: return "Allow microphone access in LocalFlow"
        case .audioSessionFailed: return "The microphone could not start"
        case .startupTimeout: return "The microphone took too long to start"
        case .interrupted: return "Dictation was interrupted"
        case .deviceLocked: return "Dictation stopped when iPhone locked"
        case .keyboardDismissed: return "Stopped because the keyboard closed"
        case .sessionInactive: return openLocalFlow
        case .modelUnavailable: return "The speech model is missing"
        case .modelFailed: return "The speech model failed to load"
        case .transcriptionFailed: return "Transcription failed"
        case .backgroundTimeExpired: return "Ran out of background time"
        case .notRecording: return "Stopped before recording began"
        case .tooLong: return "The dictation was too long"
        case .superseded: return "Replaced by a newer dictation"
        }
    }

    static let trackpadTip = "Hold space to move the cursor"

    /// The menu panel's session line, only from a live host.
    static func sessionSummary(for status: HostStatus?, now: Date) -> String {
        guard let status, status.schema == DictationProtocol.schema,
              DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
        else { return "No session running" }
        switch status.session {
        case .inactive: return "No session running"
        case .starting: return "Session starting…"
        case .active: break
        }
        guard let expiresAt = status.sessionExpiresAt else { return "Session active" }
        let minutes = max(1, Int((expiresAt.timeIntervalSince(now) / 60).rounded(.up)))
        return "Session active · ends after \(minutes) min idle"
    }

    /// A small hint about the model or session, only from a live host: a dead host's last status
    /// would otherwise claim "Preparing model…" forever.
    static func hint(for status: HostStatus?, now: Date) -> String? {
        guard let status, status.schema == DictationProtocol.schema,
              DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
        else { return nil }
        switch status.model {
        case .preparing: return preparingModel
        case .failed: return "Model failed to load"
        case .unavailable: return "Model missing"
        case .notPrepared, .ready: break
        }
        guard status.session == .active else { return nil }
        if status.model == .notPrepared { return modelLoadsWhenDictating }
        guard let expiresAt = status.sessionExpiresAt else { return "Session on" }
        let minutes = max(1, Int((expiresAt.timeIntervalSince(now) / 60).rounded(.up)))
        return "Session · \(minutes) min left"
    }
}
