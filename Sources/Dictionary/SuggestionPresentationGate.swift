import Foundation

enum DictionarySuggestionAction: Equatable {
    case add, notNow, dontSuggest
}

/// The overlay's only copy of a suggestion (DESIGN §3.5). Timers and button
/// callbacks are bound to its id, so a stale timer or late click can never
/// act on a later phase. Every way it leaves the screen (a button, the
/// timeout, pre-emption, the setting turned off) clears the word.
/// Used on the main thread only.
struct SuggestionPresentationGate {
    static let lifetime: TimeInterval = 12

    private(set) var activeID: UUID?
    /// The suggestion on screen; nil once it is resolved or withdrawn.
    private(set) var suggestion: DictionarySuggestion?

    /// Counts withdrawals (a recording press or start, a dictionary edit, the
    /// setting turned off). A presentation requested before one never shows.
    private(set) var withdrawals: UInt64 = 0

    /// Pre-empts the visible suggestion and voids every presentation already
    /// requested; one requested afterwards still shows.
    mutating func withdraw() {
        withdrawals &+= 1
        preempt()
    }

    /// Presents `suggestion` if nothing was withdrawn since `requestedAt`
    /// (the `withdrawals` value when the presentation was requested).
    mutating func present(_ suggestion: DictionarySuggestion, requestedAt: UInt64) -> UUID? {
        guard requestedAt == withdrawals else { return nil }
        return present(suggestion)
    }

    mutating func present(_ suggestion: DictionarySuggestion) -> UUID {
        let id = UUID()
        activeID = id
        self.suggestion = suggestion
        return id
    }

    /// Another phase took the panel, or the suggestion was withdrawn.
    mutating func preempt() {
        activeID = nil
        suggestion = nil
    }

    /// The suggestion, exactly once, if `id` is still the one on screen.
    mutating func resolve(_ id: UUID) -> DictionarySuggestion? {
        guard activeID == id, let suggestion else { return nil }
        preempt()
        return suggestion
    }
}

/// When a verified suggestion may be shown: suggestions on, the dictionary
/// editable, and no dictation under way. A shortcut start that is pending (a
/// start delay) or a shortcut session already counts as under way.
enum CorrectionSuggestionTiming {
    static func mayPresent(enabled: Bool, dictionaryEditable: Bool, recording: Bool, transcribing: Bool,
                           startPending: Bool, shortcutSessionActive: Bool) -> Bool {
        enabled && dictionaryEditable && !recording && !transcribing && !startPending && !shortcutSessionActive
    }
}
