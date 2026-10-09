import Foundation

/// Every held-delete constant, in one place so measured values drop in with a one-line change.
/// Times are seconds from touch-down, read from touch and timer timestamps.
///
/// Where the defaults come from (researched 2026-10-09; replace with the XCUITest measurements):
/// - `initialDelay` and `characterInterval`: KeyboardKit, the open-source reimplementation of
///   Apple's keyboard, uses `repeatDelay = 0.5` and a 0.1 s repeat timer; iOS's hardware-key
///   repeat is reported at 0.4 s, then 0.1 s. The tap itself deletes at once, on touch-down.
/// - `wordModeAfter`: Apple's keyboard switches from characters to whole words while delete is
///   held. KeyboardKit switches 3 s into repeating (3.5 s after touch-down); a developer report
///   puts Apple's switch at about 4 s. 3.5 s sits between them.
/// - `wordInterval`: no published value. Words go slower than characters, so the eye can follow.
struct DeleteRepeatParameters: Equatable, Sendable {
    var initialDelay: TimeInterval = 0.5
    var characterInterval: TimeInterval = 0.1
    var wordModeAfter: TimeInterval = 3.5
    var wordInterval: TimeInterval = 0.2

    static let standard = DeleteRepeatParameters()
}

/// The held delete key's schedule. Pure: the keyboard asks what to delete at each fire time.
struct DeleteRepeat: Equatable, Sendable {
    enum Unit: Equatable, Sendable { case character, word }

    let parameters: DeleteRepeatParameters

    init(parameters: DeleteRepeatParameters = .standard) {
        self.parameters = parameters
    }

    /// What a repeat deletes when it fires `elapsed` seconds after touch-down.
    func unit(atElapsed elapsed: TimeInterval) -> Unit {
        elapsed >= parameters.wordModeAfter ? .word : .character
    }

    /// When the next repeat fires, in seconds after touch-down. Pass nil before the first repeat.
    func nextFire(afterRepeatAt elapsed: TimeInterval?) -> TimeInterval {
        guard let elapsed else { return parameters.initialDelay }
        let interval = unit(atElapsed: elapsed) == .word ? parameters.wordInterval : parameters.characterInterval
        let next = elapsed + interval
        // The first word step comes exactly at the switch, not an interval later.
        if elapsed < parameters.wordModeAfter, next > parameters.wordModeAfter { return parameters.wordModeAfter }
        return next
    }
}
