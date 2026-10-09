import Foundation

/// What one word of a held delete key's word mode removes, from the text before the caret. Pure;
/// the keyboard reads the context in memory only and drops it after the deletion.
///
/// Measured on Apple's keyboard: each word goes with the space before it, and the first word tick
/// finishes a partly deleted word. From the caret backwards: trailing spaces and tabs, then one of
/// - a single line break (a paragraph boundary is its own step),
/// - a single emoji,
/// - trailing punctuation plus the word it is attached to ("world." or "dogs'"). Apostrophes
///   inside a word ("don't") and a period or comma between digits ("3.14") stay part of the word.
///
/// then the spaces and tabs before it (never a line break).
enum WordBoundaries {
    struct Deletion: Equatable, Sendable {
        /// The number of `deleteBackward()` calls: one per grapheme cluster.
        var graphemes: Int
        var utf16: Int
    }

    static func previousWord(before text: String) -> Deletion {
        let characters = Array(text)
        var i = characters.count
        while i > 0, kind(of: characters[i - 1]) == .space { i -= 1 }
        if i > 0 {
            switch kind(of: characters[i - 1]) {
            case .newline, .emoji:
                i -= 1
            case .punctuation, .word:
                while i > 0, kind(of: characters[i - 1]) == .punctuation, !isJoiner(at: i - 1, in: characters) {
                    i -= 1
                }
                while i > 0, kind(of: characters[i - 1]) == .word || isJoiner(at: i - 1, in: characters) {
                    i -= 1
                }
            case .space:
                break
            }
            if i < characters.count, !characters[i].isNewline {
                while i > 0, kind(of: characters[i - 1]) == .space { i -= 1 }
            }
        }
        let removed = characters[i...]
        return Deletion(graphemes: removed.count, utf16: removed.reduce(0) { $0 + $1.utf16.count })
    }

    private enum Kind { case space, newline, word, emoji, punctuation }

    private static func kind(of character: Character) -> Kind {
        if character.isNewline { return .newline }
        if character.isWhitespace { return .space }
        if isEmoji(character) { return .emoji }
        if character.isLetter || character.isNumber || character == "_" { return .word }
        return .punctuation
    }

    /// Emoji presentation by default, or made graphical by a variation selector, modifier or
    /// composition (❤️, 👍🏽, flags, keycaps). A plain digit or © is not an emoji here.
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && scalars.count > 1
    }

    /// An apostrophe between letters, or a period or comma between digits, inside a word.
    private static func isJoiner(at index: Int, in characters: [Character]) -> Bool {
        guard index > 0, index + 1 < characters.count else { return false }
        let previous = characters[index - 1], next = characters[index + 1]
        switch characters[index] {
        case "'", "\u{2019}":
            return kind(of: previous) == .word && kind(of: next) == .word
        case ".", ",":
            return previous.isNumber && next.isNumber
        default:
            return false
        }
    }
}
