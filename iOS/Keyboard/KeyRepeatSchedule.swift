import Foundation

/// Delete-key auto-repeat timing: a pause, then repeats that speed up the longer the key is held.
/// Character deletion only; deleting by word would mean reading the document beyond what spacing
/// needs. Pure and Foundation-only, so it can move to Shared with tests.
enum KeyRepeatSchedule {
    static let initialDelay: TimeInterval = 0.45

    /// The wait before repeat `index` (0 is the first repeat after the initial press).
    static func delay(beforeRepeat index: Int) -> TimeInterval {
        if index <= 0 { return initialDelay }
        if index <= 10 { return 0.1 }
        if index <= 30 { return 0.06 }
        return 0.035
    }
}
