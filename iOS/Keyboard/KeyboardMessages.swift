import Foundation

/// The short, content-free text the keyboard shows for a mode, an error or the host status. Pure and
/// Foundation-only, so it can move to Shared with tests.
enum KeyboardMessages {
    static let openLocalFlow = "Open LocalFlow to start a session"
    static let noSpeech = "No speech detected"
    static let preparingModel = "Preparing model…"
    /// `preparingModel` where the bar's middle, between Cancel and the wait's pill, has no room for it: the shimmer beside
    /// it and the cold start's caption before it say what is prepared.
    static let preparingShort = "Preparing…"

    /// The short form of a line where one fits better beside Cancel, if it has one.
    static func shortForm(of line: String) -> String? {
        switch line {
        case preparingModel: return preparingShort
        case modelLoadingCaption: return modelLoadingShortCaption
        default: return nil
        }
    }
    static let starting = "Starting…"
    /// Recording while the host prepares the model (`KeyboardPresenter.isModelPreparing`). Short enough for a
    /// 375-point phone beside Cancel and the labelled Stop capsule.
    static let listeningWhilePreparing = "Listening · model loads"
    /// Idle with a live session and a released model: a tap prepares it (ARCHITECTURE.md, "Keyboard
    /// presentation"), nothing prepares it now.
    static let modelLoadsWhenDictating = "Model loads when you dictate"
    /// In the bar's middle while recording as the host still prepares the model: the wave itself says "listening".
    static let modelLoadingCaption = "Model loading"
    /// `modelLoadingCaption` where the bar's middle has no room for it beside Cancel (a 375-point phone, large text): the
    /// rest of the bar says it is a recording, so "Loading" is the model.
    static let modelLoadingShortCaption = "Loading"
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
        case .starting: return starting
        case .recording: return "Listening"
        case .transcribing: return "Transcribing…"
        case .waitingForModel, .preparingModel: return preparingModel
        case .error(let code): return text(for: code)
        case .ready: return "Ready to dictate"
        // Describes, never instructs: a tap on the bar's text types the top-row key under it.
        case .hostUnavailable: return launcherFailed ? openLocalFlow : "Start opens LocalFlow"
        }
    }

    /// What VoiceOver calls the Start capsule; while the recording waits, the capsule shows only a spinner and this
    /// names the wait.
    static func capsuleAccessibilityLabel(for mode: KeyboardMode) -> String {
        switch mode {
        case .starting, .recording: return "Stop dictation"
        case .transcribing: return "Transcribing"
        case .waitingForModel: return "Preparing model"
        default: return "Start dictation"
        }
    }

    /// What VoiceOver hears as the island's value while it is Stop: the mode, and the time while recording. Empty for Start
    /// and the wait. Dictation's text (a notice, the cold start's caption, "Open LocalFlow to start a session") is the
    /// middle's, which VoiceOver reaches on its own (round 9: the island no longer holds it).
    static func islandAccessibilityValue(for mode: KeyboardMode, now: Date) -> String {
        switch mode {
        case .starting: return "Starting"
        case .recording(_, let startedAt):
            let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
            return "Recording, " + Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        default: return ""
        }
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
    static let layoutTipBelow = ". If it lands on the wrong line, switch this field to:"
    static let layoutTipAbove = ". If it lands on the wrong line, switch this field above."

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

    /// How the bar and the menu name the session's end, in the Live Activity's words ("ends in 2:15"): when it ends if
    /// nothing is dictated, not at a fixed time.
    static func idleTimeout(minutes: Int) -> String {
        "ends in \(minutes) min if idle"
    }

    /// The minutes until `expiresAt`, to the nearest, so the bar agrees with the Live Activity's countdown (2:15 is 2
    /// minutes); never under one while the session runs.
    private static func minutesLeft(until expiresAt: Date, now: Date) -> Int {
        max(1, Int((expiresAt.timeIntervalSince(now) / 60).rounded()))
    }

    /// Dictation is ready to go: a live host runs a session and its model has not failed or gone missing (it may
    /// still load when the user dictates). The idle bar then leads its line with the mark's dot.
    static func isSessionReady(_ status: HostStatus?, now: Date) -> Bool {
        guard let status, status.schema == DictationProtocol.schema, status.session == .active,
              DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
        else { return false }
        switch status.model {
        case .failed, .unavailable: return false
        case .notPrepared, .preparing, .ready: return true
        }
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

/// The island's state for a mode (ARCHITECTURE.md, "Keyboard look"): Start, Stop while starting and recording, working
/// while the recording waits for its transcript, and Start dimmed where dictation cannot run.
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

extension IslandForm {
    /// Start (dimmed or not) is the compact island; Stop grows it across the bar; the wait contracts it.
    init(_ style: CapsuleStyle) {
        switch style {
        case .start, .unavailable: self = .compact
        case .stop: self = .expanded
        case .working: self = .processing
        }
    }
}

/// What the island holds (ARCHITECTURE.md, "Top row"): the ridge mark and "Start"; while starting, the status and the
/// stop glyph; while recording, the wave, the time and the stop glyph; while the recording waits for its transcript, only
/// the shimmer (the middle says what it waits for).
enum CapsuleContent: Equatable, Sendable {
    case start
    case starting
    case stop(startedAt: Date)
    case processing

    init(mode: KeyboardMode) {
        switch mode {
        case .starting: self = .starting
        case .recording(_, let startedAt): self = .stop(startedAt: startedAt)
        case .transcribing, .waitingForModel: self = .processing
        case .needsFullAccess, .configurationError, .incompatible, .ready, .preparingModel, .hostUnavailable, .error:
            self = .start
        }
    }
}

/// What the bar's middle shows beside any chips (ARCHITECTURE.md, "Top row"): a notice whenever one is up; while
/// recording, where the island shows the live wave, a caption only when it says something the user needs (the model
/// still loading); while starting, nothing unless it is more than "Starting…" (the island's dimmed row says that);
/// otherwise the one-line status (ready and idle: only the model or session hint, led by the mark's dot while the
/// session is ready, `KeyboardMessages.isSessionReady`), unless a chip shows.
enum BarStatus: Equatable, Sendable {
    case notice(String)
    case wave(caption: String?)
    /// `attention`: an error or a state that keeps dictation from working. `ready`: idle with dictation ready, which
    /// the dot shows; information, not a control.
    case text(String, attention: Bool, ready: Bool = false)
    case none

    init(mode: KeyboardMode, title: String, hint: String?, notice: String?, chipsShown: Bool, sessionReady: Bool = false) {
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
        case .starting: line = title == KeyboardMessages.starting ? nil : title
        default: line = title.isEmpty ? nil : title
        }
        guard let line, !chipsShown else {
            self = .none
            return
        }
        switch mode {
        case .error, .needsFullAccess, .configurationError, .incompatible: self = .text(line, attention: true)
        case .ready: self = .text(line, attention: false, ready: sessionReady)
        default: self = .text(line, attention: false)
        }
    }
}
