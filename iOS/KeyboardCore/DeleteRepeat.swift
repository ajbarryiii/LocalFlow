import Foundation

/// Every held-delete constant, in one place. Times are seconds.
///
/// Measured on Apple's keyboard (ARCHITECTURE.md, "Measured Apple keyboard behavior", and the
/// calibration report; iOS 26.4 simulator, XCUITest): the first deletion 0.087 s after touch-down, or
/// at lift if the key is released sooner; the first repeat 0.50 s after that, then a character every
/// 0.10 s; after 21 single characters (about 2.52 s after the first deletion) word mode, 2 words every
/// 0.354 s, each word with the space before it.
struct DeleteRepeatParameters: Equatable, Sendable {
    var firstDeletionDelay: TimeInterval = 0.087
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
