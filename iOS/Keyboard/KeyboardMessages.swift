import Foundation

/// The short, content-free text the keyboard shows for a mode, an error or the host status. Pure and
/// Foundation-only, so it can move to Shared with tests.
enum KeyboardMessages {
    static let openLocalFlow = "Open LocalFlow to start a session"
    static let noSpeech = "No speech detected"
    static let preparingModel = "Preparing model…"
    static let starting = "Starting…"
    /// Recording while the host prepares the model (`KeyboardPresenter.isModelPreparing`). Short enough for a
    /// 375-point phone beside Cancel and the labelled Stop capsule.
    static let listeningWhilePreparing = "Listening · model loads"
    /// Idle with a live session and a released model: a tap prepares it (ARCHITECTURE.md, "Keyboard
    /// presentation"), nothing prepares it now. VoiceOver's, after the session line (round 10: the bar shows no words).
    static let modelLoadsWhenDictating = "Model loads when you dictate"
    /// What VoiceOver hears after the time while recording as the host still prepares the model (round 9 showed it in
    /// the bar's middle; round 10, owner: the wave says it is listening, and the wait will show it is busy).
    static let modelLoadingCaption = "Model loading"
    /// VoiceOver's words for Start with no session (round 10: the bar shows the ember dot instead of these words).
    static let noSessionSpoken = "No session. Start opens LocalFlow"
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

    /// What VoiceOver hears as the island's value: while it is Stop, the mode and the time while recording, then any
    /// `detail` (the model still loading); on Start, `detail`, the status the bar shows as Start's dot (round 10: the
    /// session's time left, the model, no session; `spokenStatus`). Empty for the wait, whose label names it. A notice, an
    /// error and "Open LocalFlow to start a session" are the middle's words, which VoiceOver reaches on its own.
    static func islandAccessibilityValue(for mode: KeyboardMode, detail: String?, now: Date) -> String {
        switch mode {
        case .starting: return "Starting"
        case .recording(_, let startedAt):
            let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
            let time = "Recording, " + Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
            return detail.map { time + ". " + $0 } ?? time
        case .transcribing, .waitingForModel: return ""
        default: return detail ?? ""
        }
    }

    /// The status words the bar no longer shows (round 10, owner: "prefer intuitive icons to textual descriptions"),
    /// for VoiceOver, only from a live host: the session's time left in the menu's words, the model loading when the user
    /// dictates or preparing now, no session (Start opens LocalFlow), and the model still loading while recording. Nil
    /// where the bar's own words or the island's label say it all.
    static func spokenStatus(mode: KeyboardMode, status: HostStatus?, launcherFailed: Bool, now: Date) -> String? {
        let live = status.flatMap { status -> HostStatus? in
            status.schema == DictationProtocol.schema && status.session == .active
                && DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now) ? status : nil
        }
        switch mode {
        case .recording: return live?.model == .preparing ? modelLoadingCaption : nil
        case .hostUnavailable: return launcherFailed ? nil : noSessionSpoken
        case .ready, .preparingModel:
            guard let live, isSessionReady(live, now: now) else { return nil }
            let session = sessionSummary(for: live, now: now)
            if mode == .preparingModel || live.model == .preparing { return "Preparing model. " + session }
            return live.model == .notPrepared ? session + ". " + modelLoadsWhenDictating : session
        default: return nil
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
        // Short enough for one line at large text sizes.
        return "Session " + idleTimeout(minutes: minutesLeft(until: expiresAt, now: now))
    }

    /// How the menu and VoiceOver name the session's end, in the Live Activity's spoken words ("ends in 2:15"): when it
    /// ends if nothing is dictated, not at a fixed time.
    static func idleTimeout(minutes: Int) -> String {
        "ends in \(minutes) min if idle"
    }

    /// The minutes until `expiresAt`, to the nearest, so the menu agrees with the Live Activity's countdown (2:15 is 2
    /// minutes); never under one while the session runs.
    private static func minutesLeft(until expiresAt: Date, now: Date) -> Int {
        max(1, Int((expiresAt.timeIntervalSince(now) / 60).rounded()))
    }

    /// Dictation is ready to go: a live host runs a session and its model has not failed or gone missing (it may
    /// still load when the user dictates). Start's mark's dot is then aurora (`SessionDot`).
    static func isSessionReady(_ status: HostStatus?, now: Date) -> Bool {
        guard let status, status.schema == DictationProtocol.schema, status.session == .active,
              DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
        else { return false }
        switch status.model {
        case .failed, .unavailable: return false
        case .notPrepared, .preparing, .ready: return true
        }
    }

    /// The idle line's words about the model, only from a live host's session, and only for a model that cannot load
    /// (round 10: the session's state is Start's dot, and a model that loads or is loading is VoiceOver's,
    /// `spokenStatus`). A dead host's last status says nothing.
    static func hint(for status: HostStatus?, now: Date) -> String? {
        guard let status, status.schema == DictationProtocol.schema, status.session == .active,
              DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
        else { return nil }
        switch status.model {
        case .failed: return "Model failed to load"
        case .unavailable: return "Model missing"
        case .notPrepared, .preparing, .ready: return nil
        }
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

/// What the bar's middle shows beside any chips (ARCHITECTURE.md, "Top row"). Round 10 (owner: "prefer intuitive icons
/// to textual descriptions ... balance between these two poles"): words only where they earn their space. A notice
/// whenever one is up; the words of what the user must act on (Full Access, a broken install or versions, "Open
/// LocalFlow to start a session" after the launcher failed), of an error, and of a model that cannot load (`hint`);
/// otherwise nothing: the island's motion says it is starting, recording or waiting, and Start's dot (`SessionDot`)
/// whether a session is on. Nothing beside a chip but a notice.
enum BarStatus: Equatable, Sendable {
    case notice(String)
    /// `attention`: an error or a state that keeps dictation from working, led by the ember warning symbol.
    case text(String, attention: Bool)
    case none

    init(mode: KeyboardMode, title: String, hint: String?, notice: String?, chipsShown: Bool) {
        if let notice {
            self = .notice(notice)
            return
        }
        guard !chipsShown else {
            self = .none
            return
        }
        switch mode {
        case .error, .needsFullAccess, .configurationError, .incompatible:
            self = title.isEmpty ? .none : .text(title, attention: true)
        case .ready:
            self = hint.map { .text($0, attention: true) } ?? .none
        case .starting, .hostUnavailable:
            self = title == KeyboardMessages.openLocalFlow ? .text(title, attention: false) : .none
        case .recording, .transcribing, .waitingForModel, .preparingModel:
            self = .none
        }
    }
}

/// The session on Start's mark's dot, and on the menu's (round 11, owner, after trying round 10's green and amber dots:
/// amber made the logo look worse, and iOS's own orange microphone dot means a session is on). The dot is always the
/// brand's aurora; the session shows in its motion. A live session that can take a dictation: a heartbeat, a soft ring
/// rippling out from the dot every few seconds; its model preparing: breathing; no session, or dictation cannot run
/// here: the same dot, still. With Reduce Motion nothing moves: lit while a session is on, unlit (a neutral grey) while
/// none is.
enum SessionDot: Equatable, Sendable {
    case ready, preparing, off

    /// How the dot is drawn.
    enum Look: Equatable, Sendable {
        case heartbeat, breathing, lit, unlit
    }

    /// The heartbeat, in one place to tune (the owner judges it on a phone): a ring `ripple` seconds long growing from
    /// the dot's edge to `reach` points beyond it, ease-out, fading from `opacity`, every `period` seconds, the first
    /// `firstDelay` after the mark appears.
    enum Heartbeat {
        static let period = 3.0
        static let ripple = 1.0
        static let reach = 4.5
        static let opacity = 0.6
        static let firstDelay = 0.4
        /// The ring's stroke, in points.
        static let lineWidth = 1.0
    }

    init(mode: KeyboardMode, sessionReady: Bool) {
        switch mode {
        case .preparingModel: self = .preparing
        // Start opens LocalFlow, or dictation cannot run here.
        case .hostUnavailable, .needsFullAccess, .configurationError, .incompatible: self = .off
        default: self = sessionReady ? .ready : .off
        }
    }

    func look(reduceMotion: Bool) -> Look {
        switch self {
        case .ready: return reduceMotion ? .lit : .heartbeat
        case .preparing: return reduceMotion ? .lit : .breathing
        case .off: return reduceMotion ? .unlit : .lit
        }
    }

    /// The dot's colour on the island: aurora, or the unlit grey.
    func color(_ palette: BrandPalette, reduceMotion: Bool) -> BrandPalette.RGB {
        look(reduceMotion: reduceMotion) == .unlit ? palette.unlitDot : palette.live
    }

    /// The dot's colour on the menu's card (round 11, Opus: it was always aurora, beside "No session running").
    func menuColor(_ menu: MenuPalette, reduceMotion: Bool) -> MenuPalette.RGB {
        look(reduceMotion: reduceMotion) == .unlit ? menu.unlitDot : menu.markDot
    }
}
