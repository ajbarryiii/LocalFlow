import Foundation

/// Builds the text the keyboard inserts for a result. `contextBefore` is the document text before
/// the cursor; it only chooses spacing and is never stored.
enum TextInsertionFormatter {
    private static let closingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
    private static let openingCharacters: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}"]
    private static let straightQuotes: Set<Character> = ["\"", "'"]

    static func text(for result: DictationResult, contextBefore: String?) -> String {
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A transcript that was only "press enter" still presses Enter, as on macOS.
        let enter = result.pressEnter ? "\n" : ""
        guard !transcript.isEmpty else { return enter }
        let space = needsLeadingSpace(before: transcript, contextBefore: contextBefore ?? "") ? " " : ""
        return space + transcript + enter
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
}
