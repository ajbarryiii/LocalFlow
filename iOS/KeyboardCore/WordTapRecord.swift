import Foundation

/// A tap's touch-down point in key-area points.
struct TapPoint: Equatable, Sendable {
    var x: Double
    var y: Double
}

/// The current word's characters as the editor typed them, each with the touch-down point of the tap that
/// typed it, or none (ARCHITECTURE.md, "Word autocorrect", Taps). Pure; in memory only.
///
/// - Every edit the editor makes is applied as its deletions, then its insertion: a deletion removes the
///   last records (all of them when it reaches further back), and an inserted letter or apostrophe is
///   recorded. Any other inserted character (a commit key, a space, a digit, a symbol) starts a new word:
///   the record clears.
/// - Only the last character of an insertion carries the tap's point (a tapped letter may follow the space
///   owed after a swiped word in the same edit).
/// - The editor clears the record on a caret move, a field change and any edit it did not make.
/// - If the record does not match the word before the caret, the word's points are all none.
struct WordTapRecord: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var character: Character
        var point: TapPoint?
        /// Typed by a swipe (or a swipe candidate).
        var swiped: Bool
    }

    private(set) var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The apostrophes a word may hold (`tap/words.py`).
    static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || apostrophes.contains(character)
    }

    mutating func clear() {
        entries = []
    }

    /// An edit the editor made: `deleted` characters before the caret removed, then `inserted` typed, by a tap
    /// at `point` (nil for none) or by a swipe.
    mutating func edited(deleted: Int, inserted: String, point: TapPoint? = nil, swiped: Bool = false) {
        entries.removeLast(min(max(deleted, 0), entries.count))
        for (index, character) in zip(inserted.indices, inserted) {
            guard Self.isWordCharacter(character) else {
                entries = []
                continue
            }
            let last = inserted.index(after: index) == inserted.endIndex
            entries.append(Entry(character: character, point: last ? point : nil, swiped: swiped))
        }
    }

    /// The record of `run` (the run of letters and apostrophes before the caret) when it matches it character
    /// for character; nil otherwise.
    func entries(matching run: String) -> [Entry]? {
        entries.map(\.character).elementsEqual(run) ? entries : nil
    }
}
