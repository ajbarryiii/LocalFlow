import Foundation

/// Every held-delete constant, in one place. Times are seconds.
///
/// Measured on Apple's keyboard (ARCHITECTURE.md, "Measured Apple keyboard behavior", and the
/// calibration report): the first deletion 0.12 s after touch-down on device (0.087 s in the
/// simulator), or at lift if the key is released sooner; the first repeat 0.50 s after that (0.494 s
/// on device), then a character every 0.10 s (0.101 s); after 21 single characters (about 2.52 s after
/// touch-down on device) word mode, 2 words every 0.354 s (0.351 s), each word with the space before
/// it. A touch the system cancels deletes nothing.
struct DeleteRepeatParameters: Equatable, Sendable {
    var firstDeletionDelay: TimeInterval = 0.12
    var initialDelay: TimeInterval = 0.50
    var characterInterval: TimeInterval = 0.10
    /// Character deletions, the first one included, before word mode.
    var charactersBeforeWords = 21
    var wordInterval: TimeInterval = 0.354
    var wordsPerTick = 2

    static let standard = DeleteRepeatParameters()
}

/// The held delete key's schedule. Pure: the keyboard asks when each deletion happens and what it
/// deletes.
struct DeleteRepeat: Equatable, Sendable {
    enum Unit: Equatable, Sendable {
        case character
        case words(Int)
    }

    let parameters: DeleteRepeatParameters

    init(parameters: DeleteRepeatParameters = .standard) {
        self.parameters = parameters
    }

    /// When the first deletion happens, in seconds after touch-down (or at lift, if sooner).
    var firstDeletion: TimeInterval { parameters.firstDeletionDelay }

    /// Repeat `index` (1 is the first repeat after the first deletion): when it fires, in seconds after
    /// touch-down, and what it deletes.
    func repeatAt(_ index: Int) -> (time: TimeInterval, unit: Unit) {
        let index = max(index, 1)
        let start = parameters.firstDeletionDelay + parameters.initialDelay
        // Repeats before this one, plus the first deletion, were all characters until the switch.
        let firstWordRepeat = max(parameters.charactersBeforeWords, 1)
        guard index >= firstWordRepeat else {
            return (start + Double(index - 1) * parameters.characterInterval, .character)
        }
        let switchTime = start + Double(firstWordRepeat - 1) * parameters.characterInterval
        return (switchTime + Double(index - firstWordRepeat) * parameters.wordInterval,
                .words(max(parameters.wordsPerTick, 1)))
    }
}

/// The held delete key: its press, bound to the field it began in. Pure; the keyboard owns the timers
/// and asks this what each one may do.
/// - Every deletion it schedules belongs to its press (`token`). A deletion fires only while that press
///   is current and the field is still the one it began in; otherwise the press ends, deleting nothing.
/// - A release before the first deletion deletes once, in that field. A cancellation (the system's, the
///   menu covering the keys, hiding) deletes nothing, and the keyboard revokes what the press queued.
/// - A focus change ends the press.
struct HeldDeleteKey: Equatable, Sendable {
    struct Press: Equatable, Sendable {
        var token: Int
        var documentID: UUID
        var pressedAt: TimeInterval
        /// Deletions done so far: the first, then the repeats.
        var deletions = 0
    }

    let schedule: DeleteRepeat
    private(set) var press: Press?
    private var nextToken = 1

    init(schedule: DeleteRepeat = DeleteRepeat()) {
        self.schedule = schedule
    }

    /// Touch-down in a field: returns the press's token and when its first deletion is due (seconds
    /// after touch-down). Without a field identity nothing is scheduled.
    mutating func began(at time: TimeInterval, documentID: UUID?) -> (token: Int, firstAt: TimeInterval)? {
        press = nil
        guard let documentID else { return nil }
        let token = nextToken
        nextToken += 1
        press = Press(token: token, documentID: documentID, pressedAt: time)
        return (token, schedule.firstDeletion)
    }

    /// A scheduled deletion for `token` fires in the field `documentID`: what to delete now and when the
    /// next one is due (seconds after touch-down). Nil if the press is gone or the field changed (which
    /// ends the press).
    mutating func fire(token: Int, documentID: UUID?) -> (unit: DeleteRepeat.Unit, nextAt: TimeInterval)? {
        guard var current = press, current.token == token else { return nil }
        guard let documentID, documentID == current.documentID else {
            press = nil
            return nil
        }
        let unit: DeleteRepeat.Unit = current.deletions == 0 ? .character : schedule.repeatAt(current.deletions).unit
        current.deletions += 1
        press = current
        return (unit, schedule.repeatAt(current.deletions).time)
    }

    /// The touch ended. Returns the press's token, and whether to delete once now: a release before the
    /// first deletion, in the field it began in. A cancellation never deletes.
    mutating func ended(cancelled: Bool, documentID: UUID?) -> (token: Int, deleteOnce: Bool)? {
        guard let current = press else { return nil }
        press = nil
        let deleteOnce = !cancelled && current.deletions == 0 && documentID != nil && documentID == current.documentID
        return (current.token, deleteOnce)
    }

    /// The field changed or the keyboard is hiding: the press ends, deleting nothing. Returns its token.
    mutating func cancel() -> Int? {
        defer { press = nil }
        return press?.token
    }
}
