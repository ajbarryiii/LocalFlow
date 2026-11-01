import Foundation

/// The short, content-free text the keyboard shows for a mode, an error or the host status. Pure and
/// Foundation-only, so it can move to Shared with tests.
enum KeyboardMessages {
    static let openLocalFlow = "Open LocalFlow to start a session"
    static let noSpeech = "No speech detected"
    static let preparingModel = "Preparing model…"
    /// Recording while the host prepares the model (`KeyboardPresenter.isModelPreparing`). Short enough for a
    /// 375-point phone beside Cancel and the labelled Stop capsule.
    static let listeningWhilePreparing = "Listening · model loads"
    /// Idle with a live session and a released model: a tap prepares it (ARCHITECTURE.md, "Keyboard
    /// presentation"), nothing prepares it now.
    static let modelLoadsWhenDictating = "Model loads when you dictate"
    /// The Start capsule's label while a finished recording waits for the model.
    static let preparingCaption = "Preparing"
    /// Beside the recording wave while the host still prepares the model: the wave itself says "listening".
    static let modelLoadingCaption = "Model loading"
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
        case .ready: return "Ready to dictate"
        // Describes, never instructs: a tap on the bar's text types the top-row key under it.
        case .hostUnavailable: return launcherFailed ? openLocalFlow : "Start opens LocalFlow"
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
    /// After `trackpadTip`, before the menu's text-width choice; and at the accessibility sizes, where the choice
    /// comes first.
    static let layoutTipBelow = ". Wrong line? Switch this field to:"
    static let layoutTipAbove = ". Wrong line? Switch this field above."

    /// The menu's rows, top to bottom.
    enum MenuItem: Equatable, Sendable {
        /// The session line, and the full explanation of a state the top row condenses.
        case session, details
        case open, divider
        /// The trackpad tip and the field's text-width choice.
        case tip, picker
    }

    /// The menu's order: the session first; at the accessibility sizes, where the session line alone can fill the
    /// first screen, the actions first ("Open LocalFlow" and the text width), the tip then pointing above.
    static func menuItems(accessibilitySize: Bool) -> [MenuItem] {
        accessibilitySize ? [.open, .picker, .divider, .session, .details, .tip] : [.session, .details, .open, .divider, .tip, .picker]
    }

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
        // The bar's words: short enough for one line at large text sizes.
        return "Session " + idleTimeout(minutes: minutesLeft(until: expiresAt, now: now))
    }

    /// How the bar and the menu name the session's end: it ends after this many idle minutes, not at a fixed time.
    static func idleTimeout(minutes: Int) -> String {
        "ends after \(minutes) min idle"
    }

    private static func minutesLeft(until expiresAt: Date, now: Date) -> Int {
        max(1, Int((expiresAt.timeIntervalSince(now) / 60).rounded(.up)))
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
        return "Session " + idleTimeout(minutes: minutesLeft(until: expiresAt, now: now))
    }
}

/// The Start capsule's colour for a mode (ARCHITECTURE.md, "Keyboard look"): aurora Start, coral Stop while starting
/// and recording, glacier while the recording waits for its transcript, and Start dimmed where dictation cannot run.
enum CapsuleStyle: Equatable, Sendable {
    case start, stop, working, unavailable

    init(mode: KeyboardMode) {
        switch mode {
        case .starting, .recording: self = .stop
        case .transcribing, .waitingForModel: self = .working
        case .needsFullAccess, .configurationError, .incompatible: self = .unavailable
        case .ready, .preparingModel, .hostUnavailable, .error: self = .start
        }
    }
}

/// What the bar's middle shows beside any chips (ARCHITECTURE.md, "Top row"): a notice whenever one is up; while
/// recording the live wave, with a caption only when it says something the user needs (the model still loading);
/// otherwise the one-line status (ready and idle: only the model or session hint), unless a chip shows.
enum BarStatus: Equatable, Sendable {
    case notice(String)
    case wave(caption: String?)
    /// `attention`: an error or a state that keeps dictation from working.
    case text(String, attention: Bool)
    case none

    init(mode: KeyboardMode, title: String, hint: String?, notice: String?, chipsShown: Bool) {
        if let notice {
            self = .notice(notice)
            return
        }
        if case .recording = mode {
            self = .wave(caption: title == KeyboardMessages.listeningWhilePreparing ? KeyboardMessages.modelLoadingCaption : nil)
            return
        }
        let line: String?
        switch mode {
        case .ready: line = hint
        default: line = title.isEmpty ? nil : title
        }
        guard let line, !chipsShown else {
            self = .none
            return
        }
        switch mode {
        case .error, .needsFullAccess, .configurationError, .incompatible: self = .text(line, attention: true)
        default: self = .text(line, attention: false)
        }
    }
}
