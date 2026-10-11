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
/// - Every deletion it schedules belongs to its press (`token`) and carries the press's field. A press
///   that began while the field had no identity (connecting) binds to the first identity seen after
///   it. A deletion in another identified field ends the press, deleting nothing; a missing identity
///   never blocks one (ARCHITECTURE.md, "Typing model v2").
/// - A release before the first deletion deletes once. A cancellation (the system's, the menu covering
///   the keys, hiding) deletes nothing.
/// - A focus change to another identified field ends the press.
struct HeldDeleteKey: Equatable, Sendable {
    struct Press: Equatable, Sendable {
        var token: Int
        /// The field it began in; nil until one has been identified.
        var documentID: UUID?
        var pressedAt: TimeInterval
        /// Deletions done so far: the first, then the repeats.
        var deletions = 0

        /// Binds a press made without an identity to the first identity seen; false for another field.
        mutating func bind(to field: UUID?) -> Bool {
            guard let field else { return true }
            guard let documentID else {
                documentID = field
                return true
            }
            return documentID == field
        }
    }

    let schedule: DeleteRepeat
    private(set) var press: Press?
    private var nextToken = 1

    init(schedule: DeleteRepeat = DeleteRepeat()) {
        self.schedule = schedule
    }

    /// Touch-down, in the field identified as `documentID` (nil while it connects): returns the press's
    /// token and when its first deletion is due (seconds after touch-down).
    mutating func began(at time: TimeInterval, documentID: UUID?) -> (token: Int, firstAt: TimeInterval) {
        let token = nextToken
        nextToken += 1
        press = Press(token: token, documentID: documentID, pressedAt: time)
        return (token, schedule.firstDeletion)
    }

    /// A scheduled deletion for `token` fires while the keyboard serves `documentID`: what to delete now,
    /// the field it belongs to, and when the next one is due (seconds after touch-down). Nil if the press
    /// is gone or another identified field is current (which ends the press).
    mutating func fire(token: Int, documentID: UUID?) -> (unit: DeleteRepeat.Unit, field: UUID?, nextAt: TimeInterval)? {
        guard var current = press, current.token == token else { return nil }
        guard current.bind(to: documentID) else {
            press = nil
            return nil
        }
        let unit: DeleteRepeat.Unit = current.deletions == 0 ? .character : schedule.repeatAt(current.deletions).unit
        current.deletions += 1
        press = current
        return (unit, current.documentID, schedule.repeatAt(current.deletions).time)
    }

    /// The touch ended while the keyboard serves `documentID`. Returns the press's field and whether to
    /// delete once now: a release before the first deletion, unless another identified field is
    /// current. A cancellation never deletes.
    mutating func ended(cancelled: Bool, documentID: UUID?) -> (field: UUID?, deleteOnce: Bool)? {
        guard var current = press else { return nil }
        press = nil
        let sameField = current.bind(to: documentID)
        return (current.documentID, !cancelled && current.deletions == 0 && sameField)
    }

    /// The keyboard is hiding: the press ends, deleting nothing.
    mutating func cancel() {
        press = nil
    }

    /// Another field became current (ARCHITECTURE.md, "Typing model v2"): a press made before any
    /// identity binds to this one; a press bound to a different identified field ends, deleting nothing
    /// (true). One made in this field goes on.
    mutating func fieldChanged(to field: UUID?) -> Bool {
        guard var current = press else { return false }
        guard current.bind(to: field) else {
            press = nil
            return true
        }
        press = current
        return false
    }
}
