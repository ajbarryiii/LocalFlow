import Foundation

/// Fits a dictation to the text around the insertion point, so one placed
/// inside existing text reads as part of it. The model treats every dictation
/// as a whole sentence: it capitalizes the first word and ends with
/// punctuation. Foundation only; shared by the macOS app and the iOS keyboard.
///
/// `before` is the document text just before the insertion point (the
/// selection's start), `after` the text just after it (the selection's end);
/// nil when unknown. A few characters of each are enough. Neither is stored.
enum InsertionContextFormatter {
    private static let closingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
    private static let openingCharacters: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}"]
    private static let straightQuotes: Set<Character> = ["\"", "'"]
    /// After these (or a letter or digit) the sentence goes on.
    private static let continuingPunctuation: Set<Character> = [",", ";", "\u{2014}"]
    /// Following text starting with one of these already ends the clause.
    private static let followingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}"]
    private static let finalPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}"]
    private static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    /// The trimmed transcript with a leading space if it would touch the text
    /// before, its first word lowercased when it continues a sentence, its
    /// final punctuation dropped when the text after makes it redundant, and a
    /// trailing space if it would touch a following word.
    static func text(for transcript: String, before: String?, after: String?) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let before, continuesSentence(before) {
            text = lowercasingFirstWord(text)
        }
        var trailing = ""
        if let after {
            switch following(after) {
            case .punctuation:
                text = dropping(from: text) { finalPunctuation.contains($0) }
            case .continuation(let touching):
                // A lone period only: "..." and "?" or "!" are meant.
                if text.hasSuffix("."), !text.hasSuffix("..") { text = dropping(from: text) { $0 == "." } }
                if touching { trailing = " " }
            case .word:
                trailing = " "
            case .other:
                break
            }
        }
        let leading = before.map { needsLeadingSpace(before: text, contextBefore: $0) } == true ? " " : ""
        return leading + text + trailing
    }

    // MARK: - Before

    /// The last visible character before the insertion point, on its line, is
    /// a letter, a digit, a comma, a semicolon or an em dash.
    private static func continuesSentence(_ before: String) -> Bool {
        guard let last = before.last(where: { !isHorizontalSpace($0) }), !last.isNewline else { return false }
        return last.isLetter || last.isNumber || continuingPunctuation.contains(last)
    }

    /// Lowercases a plainly capitalized first word ("Which", "The", "Don't").
    /// "I" and its contractions, and words with other capitals ("NASA",
    /// "LocalFlow"), are kept.
    private static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix { $0.isLetter || apostrophes.contains($0) }
        guard let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) else { return text }
        if word == "I" || (first == "I" && word.dropFirst().first.map(apostrophes.contains) == true) { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func needsLeadingSpace(before transcript: String, contextBefore: String) -> Bool {
        guard let last = contextBefore.last, !last.isWhitespace else { return false }
        if let first = transcript.first, closingPunctuation.contains(first) { return false }
        if openingCharacters.contains(last) { return false }
        if straightQuotes.contains(last) {
            // A straight quote opens when it starts a word: `say "` versus `"done"`.
            guard let previous = contextBefore.dropLast().last else { return false }
            return !previous.isWhitespace && !openingCharacters.contains(previous)
        }
        return true
    }

    // MARK: - After

    private enum Following {
        /// Punctuation right after the insertion point.
        case punctuation
        /// A lowercase word or a number, the same sentence going on;
        /// `touching` when no space separates it.
        case continuation(touching: Bool)
        /// A capitalized word right after the insertion point.
        case word
        /// The end of the text or line, or anything else.
        case other
    }

    private static func following(_ after: String) -> Following {
        guard let first = after.first else { return .other }
        if followingPunctuation.contains(first) { return .punctuation }
        if isHorizontalSpace(first) {
            guard let next = after.first(where: { !isHorizontalSpace($0) }), next.isLowercase || next.isNumber else {
                return .other
            }
            return .continuation(touching: false)
        }
        if first.isLowercase || first.isNumber { return .continuation(touching: true) }
        return first.isUppercase ? .word : .other
    }

    // MARK: - Helpers

    /// Drops the trailing characters `matching`, unless nothing would remain.
    private static func dropping(from text: String, matching: (Character) -> Bool) -> String {
        guard let end = text.lastIndex(where: { !matching($0) }) else { return text }
        return String(text[...end])
    }

    private static func isHorizontalSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }
}
