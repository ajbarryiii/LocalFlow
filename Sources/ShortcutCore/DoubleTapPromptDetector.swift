import Foundation

/// Double-tap Hold to Talk for prompt mode (off by default). It only reads
/// the sequence of already-matched Hold to Talk events and their monotonic
/// timestamps; shortcut matching is untouched. Main thread only.
///
/// While enabled: a Hold to Talk recording shorter than `minimumHold` is
/// discarded. If it started from idle, was ended by its own release, was not
/// itself a prompt hold and no other shortcut intervened, it arms a pending
/// tap. A Hold to Talk press within `window` of that release (inclusive)
/// starts in prompt mode. Anything else clears the pending tap.
struct DoubleTapPromptDetector {
    static let minimumHold: TimeInterval = 0.3
    static let window: TimeInterval = 0.4

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

    /// A Hold to Talk recording started at `time`. Returns true when it is the
    /// second tap of a double-tap and must start in prompt mode.
    mutating func holdStarted(at time: TimeInterval, fromIdle: Bool) -> Bool {
        let armed = armedRelease
        armedRelease = nil
        guard isEnabled else {
            hold = nil
            return false
        }
        let prompt = fromIdle && armed.map { time >= $0 && time - $0 <= Self.window } == true
        hold = Hold(start: time, prompt: prompt, canArm: fromIdle && !prompt)
        return prompt
    }

    /// The Hold to Talk recording was ended by its own release at `time`.
    /// Returns true when it is too short and must be discarded untranscribed.
    mutating func holdReleased(at time: TimeInterval) -> Bool {
        let ended = hold
        hold = nil
        armedRelease = nil
        guard isEnabled, let ended else { return false }
        let tooShort = time - ended.start < Self.minimumHold
        if tooShort && ended.canArm { armedRelease = time }
        return tooShort
    }

    /// Another shortcut, the app becoming busy, or a cancellation: no pending
    /// tap, and the current hold can no longer arm one.
    mutating func interrupt() {
        armedRelease = nil
        hold?.canArm = false
    }

    mutating func reset() {
        armedRelease = nil
        hold = nil
    }
}
