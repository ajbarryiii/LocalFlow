import Foundation

/// A tap's touch-down point in key-area points.
struct TapPoint: Equatable, Sendable {
    var x: Double
    var y: Double
}

/// The word this keyboard is typing (ARCHITECTURE.md, "Word autocorrect", Owned words): its characters as the
/// editor typed them, each with the touch-down point of the tap that typed it, or none. Pure; in memory only.
///
/// The record is the source of truth for the word: autocorrect corrects only an `owned` record, and deletes
/// exactly its characters. It is owned when it began right after a separator the editor typed (any inserted
/// character other than a letter or apostrophe: a space, a commit key, a digit, a symbol) or at the start of
/// a field the editor saw empty (`startOwned`), and nothing the editor did not type since touched it.
/// - Every edit the editor makes is applied as its deletions, then its insertion. A deletion removes the last
///   characters; one that reaches past the word's start makes the record unowned (empty).
/// - Only the last character of an insertion carries the tap's point (a tapped letter may follow the space
///   owed after a swiped word in the same edit).
/// - `clear` makes it unowned: the editor calls it on a caret move, a trackpad gesture, a selection, a field
///   change, hiding, a swipe, dictation, undo and any host-reported change it did not make. Only the editor's
///   next own separator (or a field it sees empty) owns a word again.
struct WordTapRecord: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var character: Character
        var point: TapPoint?
    }

    private(set) var entries: [Entry]
    private(set) var owned: Bool

    init(entries: [Entry] = [], owned: Bool = false) {
        self.entries = entries
        self.owned = owned
    }

    /// The apostrophes a word may hold (`tap/words.py`).
    static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || apostrophes.contains(character)
    }

    /// The word's characters, as typed.
    var text: String { String(entries.map(\.character)) }

    /// Unowned and empty.
    mutating func clear() {
        entries = []
        owned = false
    }

    /// Owned and empty: the start of a field the editor saw empty.
    mutating func startOwned() {
        entries = []
        owned = true
    }

    /// An edit the editor made: `deleted` characters before the caret removed, then `inserted` typed, by a tap
    /// at `point` (nil for none).
    mutating func edited(deleted: Int, inserted: String, point: TapPoint? = nil) {
        if deleted > entries.count {
            clear()
        } else {
            entries.removeLast(max(deleted, 0))
        }
        for (index, character) in zip(inserted.indices, inserted) {
            guard Self.isWordCharacter(character) else {
                startOwned()
                continue
            }
            let last = inserted.index(after: index) == inserted.endIndex
            entries.append(Entry(character: character, point: last ? point : nil))
        }
    }

    /// The keys moved (a resize or rotation): the points no longer say which key a tap was near. The characters
    /// stay; every point becomes none.
    mutating func forgetPoints() {
        for index in entries.indices { entries[index].point = nil }
    }
}
