import Foundation

/// Double-tap Hold to Talk for prompt mode (off by default). It only reads
/// the sequence of already-matched Hold to Talk events, each with a stamp
/// taken when the event arrived; shortcut matching is untouched. Main thread
/// only.
///
/// While enabled: a Hold to Talk recording shorter than `minimumHold` is
/// discarded. It arms a pending tap only if it started while the app was idle,
/// ended by a genuine release of the shortcut's own key, was not itself a
/// prompt hold, and nothing interrupted it. A Hold to Talk press within
/// `window` of that release (inclusive) starts in prompt mode. Anything else
/// clears the pending tap.
struct DoubleTapPromptDetector {
    static let minimumHold: TimeInterval = 0.3
    static let window: TimeInterval = 0.4

    /// Taken when the event arrives, before it is queued for handling, so a
    /// state change or cancellation in between is seen.
    struct Stamp: Equatable {
        /// Monotonic seconds (event timestamp or system uptime at the event).
        let time: TimeInterval
        /// Not recording, transcribing or starting when the event arrived.
        let appWasIdle: Bool
        /// The interruption count when the event arrived.
        let epoch: UInt64
        /// For a Hold to Talk deactivation: how it came about.
        let releaseOrigin: ShortcutReleaseOrigin?
    }

    var isEnabled = false {
        didSet { if !isEnabled { reset() } }
    }

    private struct Hold {
        let start: TimeInterval
        let prompt: Bool
        var canArm: Bool
    }

    private var hold: Hold?
    private var armedRelease: TimeInterval?
    /// Recordings begun when the tap armed; any recording begun since (a manual
    /// start from the menu, even one that then failed) voids the tap.
    private var armedRecordings: UInt64 = 0
    /// Counts interruptions, so a stamp taken before one is recognised as stale.
    private(set) var epoch: UInt64 = 0

    func stamp(at time: TimeInterval, appIdle: Bool, releaseOrigin: ShortcutReleaseOrigin? = nil) -> Stamp {
        Stamp(time: time, appWasIdle: appIdle, epoch: epoch, releaseOrigin: releaseOrigin)
    }

    /// A Hold to Talk recording started. Returns true when it is the second
    /// tap of a double-tap and must start in prompt mode.
    mutating func holdStarted(_ stamp: Stamp, recordingsBegun: UInt64 = 0) -> Bool {
        let armed = armedRelease
        let sameRecordings = armedRecordings == recordingsBegun
        armedRelease = nil
        guard isEnabled else {
            hold = nil
            return false
        }
        let eligible = stamp.appWasIdle && stamp.epoch == epoch
        // Absolute deadline, so the inclusive boundary holds at any origin.
        let prompt = eligible && sameRecordings
            && armed.map { stamp.time >= $0 && stamp.time <= $0 + Self.window } == true
        hold = Hold(start: stamp.time, prompt: prompt, canArm: eligible && !prompt)
        return prompt
    }

    /// The Hold to Talk recording stopped on a deactivation. Returns true when
    /// it is too short and must be discarded untranscribed.
    mutating func holdReleased(_ stamp: Stamp, recordingsBegun: UInt64 = 0) -> Bool {
        let ended = hold
        hold = nil
        armedRelease = nil
        guard isEnabled, let ended else { return false }
        let tooShort = stamp.time < ended.start + Self.minimumHold
        if stamp.releaseOrigin == .reset {
            interruptInput()
        } else if tooShort, ended.canArm, stamp.releaseOrigin == .keyReleased, stamp.epoch == epoch {
            armedRelease = stamp.time
            armedRecordings = recordingsBegun
        }
        return tooShort
    }

    /// An app-level cancellation (Escape, a cancelled transcription, a manual
    /// start, monitoring stopped), applied when it happens: no pending tap, the
    /// current hold can no longer arm one, and events that arrived before it but
    /// are still queued are stale.
    mutating func interrupt() {
        epoch &+= 1
        interruptInput()
    }

    /// An input-order interruption (another shortcut, Paste Again, a backend
    /// reset), applied when it is handled, in event order: no pending tap and
    /// the current hold can no longer arm one. Events that arrived after it are
    /// handled after it, so they stay fresh.
    mutating func interruptInput() {
        armedRelease = nil
        hold?.canArm = false
    }

    mutating func reset() {
        armedRelease = nil
        hold = nil
    }

    /// Whether the app counts as idle for a shortcut event arriving now. The
    /// app's own state lags behind events still queued for handling, so a Hold
    /// to Talk hold whose release has already arrived counts as ended: it is
    /// handled first. Transcription is still read at arrival.
    static func appIdleAtArrival(transcribing: Bool, sessionMode: RecordingTriggerMode?, recordingOrStarting: Bool,
                                 holdReleasesInFlight: Int) -> Bool {
        guard !transcribing else { return false }
        if sessionMode == nil && !recordingOrStarting { return true }
        return sessionMode == .hold && holdReleasesInFlight > 0
    }

    // Conveniences for an event that arrives and is handled at once.
    mutating func holdStarted(at time: TimeInterval, fromIdle: Bool) -> Bool {
        holdStarted(stamp(at: time, appIdle: fromIdle))
    }

    mutating func holdReleased(at time: TimeInterval) -> Bool {
        holdReleased(stamp(at: time, appIdle: true, releaseOrigin: .keyReleased))
    }
}

/// What the app does with one matched shortcut event (Paste Again excluded).
struct DictationShortcutDecision: Equatable {
    let action: DictationShortcutAction?
    /// The started hold is a double-tapped prompt dictation.
    let markedPrompt: Bool
    /// The stopped hold is under the minimum and must be discarded.
    let discardTooShort: Bool
}

extension DoubleTapPromptDetector {
    /// The session controller decides start and stop exactly as before; the
    /// detector only reads Hold to Talk starts and stops, and every other
    /// event interrupts it.
    /// `recordingsBegun` is the app's count of recordings begun so far (see
    /// `RecordingAttempts.begun`), read when the event is handled.
    mutating func route(_ event: ShortcutEvent, stamp: Stamp, controller: DictationShortcutSessionController,
                        isTranscribing: Bool, recordingsBegun: UInt64 = 0) -> DictationShortcutDecision {
        let action = controller.handle(event: event, isTranscribing: isTranscribing)
        switch (event, action) {
        case (.holdActivated, .start(.hold)?):
            let prompt = holdStarted(stamp, recordingsBegun: recordingsBegun)
            if prompt { controller.markPromptSession() }
            return DictationShortcutDecision(action: action, markedPrompt: prompt, discardTooShort: false)
        case (.holdDeactivated, .stop?):
            return DictationShortcutDecision(action: action, markedPrompt: false, discardTooShort: holdReleased(stamp, recordingsBegun: recordingsBegun))
        default:
            interruptInput()
            return DictationShortcutDecision(action: action, markedPrompt: false, discardTooShort: false)
        }
    }
}
