import Foundation

/// What the app's own screens show for a state, apart from layout (ARCHITECTURE.md, "Host app"): the session card's
/// state and its one accent, the speech model's state dot, the start-session screen's phase word and return cue, the
/// route it names, and onboarding's spoken progress. The views only draw these. Pure.

/// One of the brand colours a state may carry, on a small dot or glyph only (never a fill).
enum AppAccent: Equatable, Sendable {
    case aurora, glacier, coral, ember
}

/// The session card on Home, as the Live Activity's Lock Screen shows a session.
enum SessionCardState: Equatable, Sendable {
    /// No session: the mark and the Start pill.
    case off
    /// No session, and the microphone is off for LocalFlow: Open Settings is the only action.
    case microphoneOff
    case starting
    /// A session is waiting for the keyboard: the time left.
    case ready
    case listening
    case transcribing
    /// Stopped, and waiting for the model to finish preparing before transcribing.
    case preparing

    init(session: HostStatus.Session, permission: CapturePermission, sessionError: HostErrorCode?,
         dictation: DictationStatus.Phase?, dictationInProgress: Bool, model: HostStatus.Model) {
        switch session {
        case .inactive:
            // A denial the user has since lifted in Settings no longer blocks Start.
            let denied = permission == .denied || (permission != .granted && sessionError == .microphonePermissionDenied)
            self = denied ? .microphoneOff : .off
        case .starting:
            self = .starting
        case .active:
            switch (dictationInProgress ? dictation : nil) {
            case .starting?, .recording?: self = .listening
            case .transcribing?: self = model == .preparing ? .preparing : .transcribing
            default: self = .ready
            }
        }
    }

    /// The state in words, as the Live Activity names its phases; nil where the card shows only the Start pill.
    var title: String? {
        switch self {
        case .off: return nil
        case .microphoneOff: return "Microphone off"
        case .starting: return "Starting"
        case .ready: return "Ready to dictate"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing model"
        }
    }

    /// The mark's dot: aurora when ready (and on Start), coral while recording, glacier while waiting; nil where the
    /// card shows the microphone-off glyph instead, in ember.
    var accent: AppAccent? {
        switch self {
        case .off, .ready: return .aurora
        case .listening: return .coral
        case .starting, .transcribing, .preparing: return .glacier
        case .microphoneOff: return nil
        }
    }

    /// Whether the session is running, so the card offers End rather than Start.
    var isSessionOn: Bool {
        switch self {
        case .off, .microphoneOff, .starting: return false
        case .ready, .listening, .transcribing, .preparing: return true
        }
    }
}

/// The speech model's row on Home: "Speech model" and a state dot, with its state in words for VoiceOver.
enum ModelBadge {
    /// Nil: a neutral grey dot (not prepared yet).
    static func accent(_ model: HostStatus.Model) -> AppAccent? {
        switch model {
        case .ready: return .aurora
        case .preparing: return .glacier
        case .failed, .unavailable: return .ember
        case .notPrepared: return nil
        }
    }

    static func spoken(_ model: HostStatus.Model) -> String {
        switch model {
        case .unavailable: return "Not included in this build"
        case .notPrepared: return "Not prepared yet"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .failed: return "Preparation failed"
        }
    }
}

/// The start-session screen (the bounce): its one word, the island's accent, and whether the return cue shows.
enum BouncePhase: Equatable, Sendable {
    case starting, listening, transcribing, done, cancelled, stopped

    init(_ phase: DictationStatus.Phase?) {
        switch phase {
        case .starting?, nil: self = .starting
        case .recording?: self = .listening
        case .transcribing?: self = .transcribing
        case .completed?: self = .done
        case .cancelled?: self = .cancelled
        case .failed?: self = .stopped
        }
    }

    var word: String {
        switch self {
        case .starting: return "Starting"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .stopped: return "Stopped"
        }
    }

    /// The island's accent: the recording dot, the wait's glint, or the mark's dot when it is over.
    var accent: AppAccent {
        switch self {
        case .starting, .transcribing: return .glacier
        case .listening: return .coral
        case .done: return .aurora
        case .cancelled, .stopped: return .ember
        }
    }

    /// Swiping back is the next step while the text is still on its way, and once it is ready.
    var showsReturnCue: Bool {
        switch self {
        case .listening, .transcribing, .done: return true
        case .starting, .cancelled, .stopped: return false
        }
    }
}

/// How the start-session screen shows the way back to the app that opened LocalFlow (settled decision: an app cannot
/// send the user back; they swipe or tap the status bar's link).
enum SwipeBackCue: Equatable, Sendable {
    /// The status bar's "◀ App" link: an iPhone with a Home button has no swipe along the bottom edge.
    case statusBarLink
    /// The swipe right along the bottom edge.
    case bottomEdgeSwipe

    /// From the window's bottom safe-area inset, which only a Home-button iPhone has at zero.
    init(bottomSafeAreaInset: Double) {
        self = bottomSafeAreaInset > 0 ? .bottomEdgeSwipe : .statusBarLink
    }

    /// How many times the cue shows its motion before it rests: once, and never with Reduce Motion.
    static func demonstrations(reduceMotion: Bool) -> Int { reduceMotion ? 0 : 1 }

    var spoken: String {
        switch self {
        case .statusBarLink: return "Tap the back link at the top left to return to your app"
        case .bottomEdgeSwipe: return "Swipe right along the bottom edge to return to your app"
        }
    }
}

extension HeadphonesNotice {
    /// The route in two words beside its glyph, on the start-session screen.
    var shortLabel: String {
        switch self {
        case .iPhoneMicrophone: return "iPhone mic"
        case .headphonesMicrophone: return "Headphones mic"
        }
    }

    var symbol: String {
        switch self {
        case .iPhoneMicrophone: return "iphone"
        case .headphonesMicrophone: return "headphones"
        }
    }
}

/// Onboarding's progress, as VoiceOver reads it.
enum OnboardingProgress {
    /// "Step 2 of 4" for the second of four steps (`index` from 0).
    static func spoken(index: Int, count: Int) -> String {
        let count = max(count, 1)
        return "Step \(min(max(index, 0), count - 1) + 1) of \(count)"
    }
}
