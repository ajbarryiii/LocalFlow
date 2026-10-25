import Foundation

/// What the editor needs to autocorrect at a commit key (ARCHITECTURE.md, "Word autocorrect"): the corrector,
/// the letters layout its points are in, the parameters (the bundle's default preset), and whether the field is
/// secure text entry. The keyboard gives none while autocorrect is off, without Full Access or before a model has loaded.
struct AutocorrectSetup {
    var corrector: WordCorrecting
    var keys: [PlacedKey]
    var params: AutocorrectParams
    var secureTextEntry: Bool
    /// The field turned autocorrection off (`autocorrectionType == .no`): its input stays literal.
    var autocorrectionDisabled = false
}

/// The word decisions of autocorrect, pure (ARCHITECTURE.md, "Word autocorrect"): which keys commit a word,
/// which word is before the caret, whether it may be corrected, the corrector's inputs and the correction's
/// case. `KeyboardEditor` applies them.
enum WordAutocorrect {
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

    /// The pronoun I and its contractions, as the corrector sees them: always written with a capital I.
    static let pronounForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

    /// The correction (lowercase) in the typed word's case: all capitals (two letters or more) stays all
    /// capitals, a capital first letter (or the pronoun I, `pronounForms`) takes a capital first letter, and
    /// anything else is the lexicon form.
    static func cased(_ correction: String, like typed: String) -> String {
        let lower = correction.lowercased()
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return lower.uppercased() }
        guard let head = lower.first else { return lower }
        let capital = typed.first(where: \.isLetter)?.isUppercase == true
        guard capital || pronounForms.contains(lower) else { return lower }
        return head.uppercased() + lower.dropFirst()
    }

    /// A correction to make: what it replaces (the owned word's characters from the word's start, apostrophes
    /// after it included), what replaces it (the correction cased as the word, then those apostrophes), and the
    /// record to restore on a revert.
    struct Correction: Equatable {
        /// The word as the corrector saw it (lowercased): what a revert remembers.
        var word: String
        var typed: String
        var replacement: String
        var record: WordTapRecord
    }

    /// What a commit key does with the owned word: its correction, if any, and the strip's words to choose from
    /// after it. The words replace `typed`, each cased as the typed word and followed by its trailing apostrophes:
    /// the typed word first, then the correction, then the corrector's suggestions, at most `SwipeStrip.limit`
    /// and only when there is a choice (none for a lexicon word the corrector keeps).
    struct Review: Equatable {
        var correction: Correction?
        var typed: String
        var choices: [String]

        /// The index of the word the commit leaves in the field.
        var inserted: Int { correction == nil ? 0 : 1 }
    }

    /// The review of the owned word in `record` at a commit key, or nil to commit it as typed without asking the
    /// corrector. The record is the word: nothing is read from the field but the context before it (`before`, the
    /// text before the caret as the editor knows it, for the word model only). Nil without a setup, in a secure
    /// field or one that turns autocorrection off, for an unowned record or one without a letter, or for a word
    /// holding other characters, reverted in this keyboard session, or one the user asked never to correct
    /// (`neverCorrect`).
    static func review(before: String, record: WordTapRecord, reverted: Set<String>, neverCorrect: Set<String> = [],
                       setup: AutocorrectSetup?) -> Review? {
        guard let setup, !setup.secureTextEntry, !setup.autocorrectionDisabled, record.owned,
              let found = word(before: record.text) else { return nil }
        let entries = record.entries
        let word = String(entries[found.word].map(\.character))
        guard isCorrectable(word) else { return nil }
        let lowered = correctorWord(word)
        guard !reverted.contains(lowered), !neverCorrect.contains(lowered) else { return nil }
        let points: [(x: Double, y: Double)?] = entries[found.word].map { $0.point.map { (x: $0.x, y: $0.y) } }
        // The text before the word, when the editor's text ends with it (it always should); none otherwise.
        let leading = entries.count - found.word.lowerBound
        let context = before.hasSuffix(found.run) ? TapPrior.normalizeContext(String(before.dropLast(leading))) : ""
        let corrected = setup.corrector.correct(context: context, word: lowered, points: points, keys: setup.keys,
                                                params: setup.params)
        let suggested = setup.corrector.suggestions(context: context, word: lowered, points: points, keys: setup.keys,
                                                    params: setup.params, limit: SwipeStrip.limit)
        let tail = String(entries[found.word.upperBound...].map(\.character))
        let typed = word + tail
        var correction: Correction?
        if !corrected.isEmpty, corrected.lowercased() != lowered, cased(corrected, like: word) != word {
            correction = Correction(word: lowered, typed: typed, replacement: cased(corrected, like: word) + tail, record: record)
        } else if pronounForms.contains(lowered), word.first == "i" {
            // A kept pronoun (one letter is below the corrector's minimum length) takes its capital I, the rest as typed.
            correction = Correction(word: lowered, typed: typed, replacement: "I" + word.dropFirst() + tail, record: record)
        }
        var choices = [typed]
        for choice in (correction.map { [$0.replacement] } ?? []) + suggested.map({ cased($0, like: word) + tail })
        where choices.count < SwipeStrip.limit && !choices.contains(choice) {
            choices.append(choice)
        }
        return Review(correction: correction, typed: typed, choices: choices.count > 1 ? choices : [])
    }
}
