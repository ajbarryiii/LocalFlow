import Foundation

enum DictionarySuggestionAction: Equatable {
    case add, notNow, dontSuggest
}

/// Binds the suggestion overlay's timers and button callbacks to one
/// suggestion id (DESIGN §3.5), so a stale timer or late click can never act
/// on a later phase. Used on the main thread only.
struct SuggestionPresentationGate {
    static let lifetime: TimeInterval = 12

    private(set) var activeID: UUID?

    mutating func present() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    /// Another phase (recording, transcribing, an error) took the panel.
    mutating func preempt() { activeID = nil }

    /// True exactly once, for the suggestion still on screen.
    mutating func resolve(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}
