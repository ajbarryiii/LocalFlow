import Foundation

/// The emoji panel's recents (ARCHITECTURE.md, "Emoji panel"): the emoji last typed from it, newest first, each once,
/// at most `limit`. Only emoji from `EmojiCatalog` are kept, so a stored list can hold nothing else. The keyboard keeps
/// the list in its own `UserDefaults` (no Full Access needed); nothing else about typing is stored. Pure.
struct EmojiRecents: Equatable, Sendable {
    static let limit = 30

    private(set) var emoji: [String] = []

    /// A stored list, without anything not in the catalog, duplicates or anything past `limit`.
    init(stored: [String] = []) {
        for item in stored where Self.known.contains(item) && !emoji.contains(item) && emoji.count < Self.limit {
            emoji.append(item)
        }
    }

    /// An emoji was typed from the panel: it moves to the front.
    mutating func use(_ item: String) {
        guard Self.known.contains(item) else { return }
        emoji.removeAll { $0 == item }
        emoji.insert(item, at: 0)
        if emoji.count > Self.limit { emoji.removeLast(emoji.count - Self.limit) }
    }

    private static let known: Set<String> = Set(EmojiCatalog.categories.flatMap(\.emoji))
}
