import Foundation

/// What the editor needs to autocorrect at a commit key (ARCHITECTURE.md, "Word autocorrect"): the corrector,
/// the letters layout its points are in, the parameters read now, and whether the field is secure text
/// entry. The keyboard gives none while autocorrect is off, without Full Access or before a model has loaded.
struct AutocorrectSetup {
    var corrector: WordCorrecting
    var keys: [PlacedKey]
    var params: AutocorrectParams
    var secureTextEntry: Bool
}

/// The word decisions of autocorrect, pure (ARCHITECTURE.md, "Word autocorrect"): which keys commit a word,
/// which word is before the caret, whether it may be corrected, the corrector's inputs and the correction's
/// case. `KeyboardEditor` applies them.
enum WordAutocorrect {
    /// Events for the TestFlight counters: a word was given to the corrector, replaced, or put back.
    enum Event: Equatable, Sendable {
        case checked, corrected, reverted
    }

    /// The characters that commit a word, from any layer, besides space and Return.
    static let commitCharacters: Set<String> = [".", ",", "!", "?", ";", ":"]

    static func isCommitKey(_ action: KeyAction) -> Bool {
        switch action {
        case .space, .returnKey: return true
        case .character(let character): return commitCharacters.contains(character)
        default: return false
        }
    }

    /// The word before the caret: the run of letters and apostrophes that ends at the end of `text`, and the
    /// word within it without leading or trailing apostrophes (`tap/words.py` `tokens`), as character offsets
    /// into the run. Nil when the run holds no letter.
    static func word(before text: String) -> (run: String, word: Range<Int>)? {
        let run = String(text.reversed().prefix { WordTapRecord.isWordCharacter($0) }.reversed())
        let characters = Array(run)
        guard let first = characters.firstIndex(where: { !WordTapRecord.apostrophes.contains($0) }),
              let last = characters.lastIndex(where: { !WordTapRecord.apostrophes.contains($0) }) else { return nil }
        return (run, first ..< last + 1)
    }

    /// Only a–z, A–Z and apostrophes: anything else (an accent, another script) is never corrected.
    static func isCorrectable(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
            ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || scalar == "'" || scalar == "\u{2019}"
        }
    }

    /// The corrector's word: lowercased, with curly apostrophes as "'".
    static func correctorWord(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// The correction (lowercase) in the typed word's case: all capitals (two letters or more) stays all
    /// capitals, a capital first letter stays a capital first letter, and anything else is the lexicon form.
    static func cased(_ correction: String, like typed: String) -> String {
        let lower = correction.lowercased()
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return lower.uppercased() }
        guard let first = typed.first(where: \.isLetter), first.isUppercase, let head = lower.first else { return lower }
        return head.uppercased() + lower.dropFirst()
    }

    /// A correction to make: what it replaces (the word as typed, with any apostrophes after it: the
    /// characters before the caret from the word's start), what replaces it (the correction cased as the
    /// word, then those apostrophes), and the record of the run before the caret, to restore on a revert
    /// (empty when the record did not match it).
    struct Correction: Equatable {
        /// The word as the corrector saw it (lowercased): what a revert remembers.
        var word: String
        var typed: String
        var replacement: String
        var record: [WordTapRecord.Entry]
    }

    /// The correction for the word ending `before` (the text before the caret as the editor knows it) at a
    /// commit key, or nil to commit it as typed. Nil without a setup, in a secure field, without a word before
    /// the caret, for a word that was swiped or holds other characters, or one reverted in this keyboard
    /// session, or when the corrector keeps it. `checked` is called when the corrector is asked.
    static func correction(before: String, record: WordTapRecord, reverted: Set<String>, setup: AutocorrectSetup?,
                           checked: () -> Void = {}) -> Correction? {
        guard let setup, !setup.secureTextEntry, let found = word(before: before) else { return nil }
        let run = Array(found.run)
        let word = String(run[found.word])
        let matched = record.entries(matching: found.run)
        guard isCorrectable(word), matched?.contains(where: \.swiped) != true else { return nil }
        let lowered = correctorWord(word)
        guard !reverted.contains(lowered) else { return nil }
        // A record that does not match the run gives no points.
        let points: [(x: Double, y: Double)?] = found.word.map { index in
            matched?[index].point.map { (x: $0.x, y: $0.y) }
        }
        let context = TapPrior.normalizeContext(String(before.dropLast(run.count - found.word.lowerBound)))
        checked()
        let corrected = setup.corrector.correct(context: context, word: lowered, points: points, keys: setup.keys,
                                                params: setup.params)
        guard !corrected.isEmpty, corrected.lowercased() != lowered else { return nil }
        let cased = cased(corrected, like: word)
        guard cased != word else { return nil }
        let tail = String(run[found.word.upperBound...])
        return Correction(word: lowered, typed: word + tail, replacement: cased + tail, record: matched ?? [])
    }
}
