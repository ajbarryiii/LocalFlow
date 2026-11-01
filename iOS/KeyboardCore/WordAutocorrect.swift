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
    /// The kind of field: URL and email fields get no suggestions while typing.
    var field = KeyboardField.standard

    /// Whether words are corrected here at all: not in a secure field or one that turns autocorrection off.
    var corrects: Bool { !secureTextEntry && !autocorrectionDisabled }
    /// Whether the strip suggests words while one is typed: where words are corrected, but not in URL and email
    /// fields.
    var suggestsWhileTyping: Bool { corrects && field != .url && field != .email }
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

    /// Day and month names, always written with a capital first letter, also with "'s". Not "may" and "march",
    /// which are as often ordinary words.
    static let capitalizedNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "april", "june", "july", "august", "september", "october", "november", "december",
    ]

    /// Whether a word (as the corrector sees it) is always written with a capital first letter: the pronoun I
    /// (`pronounForms`) and the day and month names (`capitalizedNames`).
    static func takesCapital(_ word: String) -> Bool {
        pronounForms.contains(word) || capitalizedNames.contains(word)
            || (word.hasSuffix("'s") && capitalizedNames.contains(String(word.dropLast(2))))
    }

    /// Common chat abbreviations and slang, kept as typed without asking the corrector, as the user's never-correct
    /// words are: the corrector's lexicon would turn some of them into words ("lol" into "lil", "ur" into "our",
    /// "alot" into "almost").
    static let chatWords: Set<String> = [
        "lol", "lmao", "lmk", "omg", "btw", "idk", "tbh", "imo", "brb", "ty", "thx", "np", "smh", "ikr", "nvm",
        "ok", "okay", "haha", "hahaha", "ugh", "yay", "gonna", "wanna", "gotta", "kinda", "sorta", "yeah", "nah",
        "yep", "nope", "ur", "alot",
    ]

    /// Corrections made whatever the corrector says: lexicon words ("cant", "wont") almost always typed for the
    /// contraction, as the corrector already corrects "dont".
    static let fixedCorrections: [String: String] = ["cant": "can't", "wont": "won't"]

    /// Very common misspellings known for certain, corrected as `fixedCorrections` are: the touch model scores a letter
    /// typed for one far from it ("definately") as almost impossible, so the corrector never offers these. Every
    /// target is a word of the bundle's lexicon and no source is one (checked against bundle b34).
    static let commonMisspellings: [String: String] = [
        "accomodate": "accommodate", "acheive": "achieve", "adress": "address", "arguement": "argument",
        "basicly": "basically", "becuase": "because", "begining": "beginning", "beleive": "believe", "belive": "believe",
        "buisness": "business", "calender": "calendar", "comming": "coming", "completly": "completely",
        "concious": "conscious", "definately": "definitely", "diffrent": "different", "dissapoint": "disappoint",
        "embarass": "embarrass", "enviroment": "environment", "existance": "existence", "experiance": "experience",
        "familar": "familiar", "finaly": "finally", "foriegn": "foreign", "freind": "friend", "goverment": "government",
        "happend": "happened", "immediatly": "immediately", "independant": "independent", "knowlege": "knowledge",
        "libary": "library", "maintainance": "maintenance", "millenium": "millennium", "neccessary": "necessary",
        "noticable": "noticeable", "occassion": "occasion", "occured": "occurred", "posession": "possession",
        "prefered": "preferred", "probaly": "probably", "publically": "publicly", "recieve": "receive",
        "recomend": "recommend", "relevent": "relevant", "religous": "religious", "remeber": "remember", "rythm": "rhythm",
        "seperate": "separate", "sucess": "success", "suprise": "surprise", "thier": "their", "tommorow": "tomorrow",
        "tounge": "tongue", "truely": "truly", "untill": "until", "wich": "which", "wierd": "weird", "writting": "writing",
    ]

    /// The correction made whatever the corrector says (`fixedCorrections`, `commonMisspellings`), if any.
    static func fixedCorrection(_ word: String) -> String? {
        fixedCorrections[word] ?? commonMisspellings[word]
    }

    /// `candidates` with spelling matches (ARCHITECTURE.md, "Word autocorrect", Spelling matches): the best always (in
    /// the last slot when the strip is full, never over the first `protected`), the others in the slots left.
    static func adding(spelling matches: [String], to candidates: [String], protected: Int) -> [String] {
        var out = candidates
        for (rank, match) in matches.enumerated() where !out.contains(match) {
            if out.count < SwipeStrip.limit {
                out.append(match)
            } else if rank == 0, out.count > protected {
                out[out.count - 1] = match
            }
        }
        return out
    }

    /// The correction (lowercase) in the typed word's case: all capitals (two letters or more) stays all
    /// capitals, a capital first letter (or a word that always takes one, `takesCapital`) takes a capital first
    /// letter, and anything else is the lexicon form.
    static func cased(_ correction: String, like typed: String) -> String {
        let lower = correction.lowercased()
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return lower.uppercased() }
        guard let head = lower.first else { return lower }
        let capital = typed.first(where: \.isLetter)?.isUppercase == true
        guard capital || takesCapital(lower) else { return lower }
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
    /// the typed word first, then the correction, then the corrector's suggestions, with the best spelling match of a
    /// word outside the lexicon (`adding(spelling:to:protected:)`), at most `SwipeStrip.limit` and only when there is
    /// a choice (none for a lexicon word the corrector keeps).
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
    /// holding other characters, reverted in this keyboard session, one the user asked never to correct
    /// (`neverCorrect`) or a chat word (`chatWords`).
    static func review(before: String, record: WordTapRecord, reverted: Set<String>, neverCorrect: Set<String> = [],
                       setup: AutocorrectSetup?) -> Review? {
        guard let setup, !setup.secureTextEntry, !setup.autocorrectionDisabled, record.owned,
              let found = word(before: record.text) else { return nil }
        let entries = record.entries
        let word = String(entries[found.word].map(\.character))
        guard isCorrectable(word) else { return nil }
        let lowered = correctorWord(word)
        guard !reverted.contains(lowered), !neverCorrect.contains(lowered), !chatWords.contains(lowered) else { return nil }
        let points: [(x: Double, y: Double)?] = entries[found.word].map { $0.point.map { (x: $0.x, y: $0.y) } }
        // The text before the word, when the editor's text ends with it (it always should); none otherwise.
        let leading = entries.count - found.word.lowerBound
        let context = before.hasSuffix(found.run) ? TapPrior.normalizeContext(String(before.dropLast(leading))) : ""
        let modelled = setup.corrector.correct(context: context, word: lowered, points: points, keys: setup.keys,
                                               params: setup.params)
        let corrected = fixedCorrection(lowered) ?? modelled
        let suggested = setup.corrector.suggestions(context: context, word: lowered, points: points, keys: setup.keys,
                                                    params: setup.params, limit: SwipeStrip.limit)
        let tail = String(entries[found.word.upperBound...].map(\.character))
        let typed = word + tail
        var correction: Correction?
        if !corrected.isEmpty, corrected.lowercased() != lowered, cased(corrected, like: word) != word {
            correction = Correction(word: lowered, typed: typed, replacement: cased(corrected, like: word) + tail, record: record)
        } else if takesCapital(lowered), let first = word.first, first.isLowercase {
            // A kept word that always takes a capital (the pronoun I, one letter below the corrector's minimum
            // length, or a day or month name) gets it, the rest as typed.
            correction = Correction(word: lowered, typed: typed, replacement: first.uppercased() + word.dropFirst() + tail,
                                    record: record)
        }
        var choices = [typed]
        for choice in (correction.map { [$0.replacement] } ?? []) + suggested.map({ cased($0, like: word) + tail })
        where choices.count < SwipeStrip.limit && !choices.contains(choice) {
            choices.append(choice)
        }
        let spelled = setup.corrector.spellingMatches(context: context, word: lowered, params: setup.params, limit: SwipeStrip.limit)
        choices = adding(spelling: spelled.map { cased($0, like: word) + tail }, to: choices, protected: correction == nil ? 1 : 2)
        return Review(correction: correction, typed: typed, choices: choices.count > 1 ? choices : [])
    }

    /// The strip while a word is typed (ARCHITECTURE.md, "Word autocorrect", Suggestions), and what a choice replaces.
    struct Typing: Equatable {
        var strip: SwipeStrip
        /// The word so far as typed, trailing apostrophes included: what keeping it leaves.
        var typed: String
        /// The word as the corrector sees it (lowercased): what keeping it over a pending correction reverts.
        var word: String
        /// The characters a choice deletes: the word's from its start, trailing apostrophes included.
        var deletes: Int
    }

    /// The strip for the owned word being typed in `record` (`before`: the text before the caret as the editor
    /// knows it, for the context), or nil for none. Nil where `review` would not ask the corrector (except for a word
    /// it keeps: a reverted, never-correct or chat word still gets suggestions, without a pending correction), in URL
    /// and email fields, and when there is nothing to offer but the word as typed.
    /// - A pending correction (what a commit key would do, `review`'s rules included: "cant" → "can't", day names'
    ///   capitals): the word as typed, quoted (a tap keeps it), the correction, marked, then the best other.
    /// - Otherwise the word as typed when it is a lexicon word (or kept, or nothing else is offered), then the best
    ///   others. Every word takes the typed word's case and trailing apostrophes.
    /// - A word that is no lexicon word (and not kept) that none of the others completes also gets its spelling matches
    ///   (`adding(spelling:to:protected:)`), after the word as typed when nothing else is offered.
    static func typingStrip(before: String, record: WordTapRecord, reverted: Set<String>, neverCorrect: Set<String> = [],
                            allCapitals: Bool = false, setup: AutocorrectSetup?) -> Typing? {
        guard let setup, setup.suggestsWhileTyping, record.owned, let found = word(before: record.text) else { return nil }
        let entries = record.entries
        let word = String(entries[found.word].map(\.character))
        guard isCorrectable(word) else { return nil }
        let lowered = correctorWord(word)
        let deletes = entries.count - found.word.lowerBound
        let context = before.hasSuffix(found.run) ? TapPrior.normalizeContext(String(before.dropLast(deletes))) : ""
        let tail = String(entries[found.word.upperBound...].map(\.character))
        let typed = word + tail
        // Apostrophes after the word so far are the middle of a contraction ("don'"), not a closing quote: the
        // completions start with them, and nothing is put back after the words offered.
        let contraction = !tail.isEmpty
        let prefix = contraction ? correctorWord(typed) : lowered
        let points: [(x: Double, y: Double)?] = entries[found.word.lowerBound...].prefix(contraction ? deletes : found.word.count)
            .map { $0.point.map { (x: $0.x, y: $0.y) } }
        let predicted = setup.corrector.predictions(context: context, word: prefix, points: points, keys: setup.keys,
                                                    params: setup.params, limit: SwipeStrip.limit)
        // Caps lock (`allCapitals`): a word typed in capitals so far, one letter included, is all capitals.
        let capitals = allCapitals && !word.isEmpty && word.filter(\.isLetter).allSatisfy(\.isUppercase)
        let kept = reverted.contains(lowered) || neverCorrect.contains(lowered) || chatWords.contains(lowered)
        var correction: String?
        if !kept, !contraction {
            if let corrected = fixedCorrection(lowered) ?? predicted.correction, corrected.lowercased() != lowered,
               cased(corrected, like: word) != word {
                correction = (capitals ? corrected.uppercased() : cased(corrected, like: word)) + tail
            } else if takesCapital(lowered), let first = word.first, first.isLowercase {
                correction = first.uppercased() + word.dropFirst() + tail
            }
        }
        let others = predicted.words.map { (capitals ? $0.uppercased() : cased($0, like: word)) + (contraction ? "" : tail) }
        // A word that is no word and that nothing offered completes also gets its spelling matches.
        var spelled: [String] = []
        if !predicted.isWord, !kept, !contraction, !predicted.words.contains(where: { $0.hasPrefix(prefix) }) {
            spelled = setup.corrector.spellingMatches(context: context, word: lowered, params: setup.params, limit: SwipeStrip.limit)
                .map { (capitals ? $0.uppercased() : cased($0, like: word)) + tail }
        }
        var candidates: [String] = []
        // Spelling matches are a guess: they never hide the word as typed, which is what a space keeps.
        let showsTyped = predicted.isWord || kept || others.isEmpty
        for choice in (correction.map { [typed, $0] } ?? (showsTyped ? [typed] : [])) + others
        where candidates.count < SwipeStrip.limit && !candidates.contains(choice) {
            candidates.append(choice)
        }
        candidates = adding(spelling: spelled, to: candidates, protected: correction != nil ? 2 : showsTyped ? 1 : 0)
        guard candidates != [typed], !candidates.isEmpty else { return nil }
        let live = correction == nil ? SwipeStrip.Live(quoted: nil, marked: nil) : SwipeStrip.Live(quoted: 0, marked: 1)
        return Typing(strip: SwipeStrip(candidates: candidates, inserted: live.marked ?? 0, live: live), typed: typed, word: lowered,
                      deletes: deletes)
    }
}
