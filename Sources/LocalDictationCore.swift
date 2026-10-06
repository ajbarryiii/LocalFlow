import Foundation

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

struct LocalDictationResult: Equatable {
    let rawTranscript: String
    let output: String
    let shouldPressEnter: Bool
    let usedMacro: Bool

    var status: String {
        let base = usedMacro ? "Local voice macro" : "Local transcription"
        return shouldPressEnter ? "\(base); detected press enter command" : base
    }
}

/// Deterministic commands only. Dictated instructions are always text; no model
/// other than the bundled speech recognizer processes the result.
enum LocalDictationCore {
    private static let trailingPressEnter = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    static func process(_ transcript: String, macros: [VoiceMacro], pressEnterEnabled: Bool,
                        spokenDelimitersEnabled: Bool) -> LocalDictationResult {
        var raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var shouldPressEnter = false
        if pressEnterEnabled,
           let match = trailingPressEnter.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
           let range = Range(match.range, in: raw) {
            raw.removeSubrange(range)
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            shouldPressEnter = true
        }
        let normalized = normalize(raw)
        let macro = normalized.isEmpty ? nil : macros.first { normalize($0.command) == normalized }
        let dictated = spokenDelimitersEnabled ? SpokenDelimiterFormatter.format(raw) : raw
        return LocalDictationResult(rawTranscript: raw,
                                    output: (macro?.payload ?? dictated).trimmingCharacters(in: .whitespacesAndNewlines),
                                    shouldPressEnter: shouldPressEnter, usedMacro: macro != nil)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().components(separatedBy: .punctuationCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Converts matched spoken delimiter pairs ("quote … end quote", "open paren …
/// close paren") into punctuation, and "all caps on … all caps off" style pairs
/// into a case change. A closer pairs with the nearest opener of its kind;
/// unmatched or empty pairs stay literal text. An unmatched case command that
/// opens the dictation ("All caps, do not merge") applies to all of it.
enum SpokenDelimiterFormatter {
    private enum Kind {
        case quote, paren, bracket, brace, backtick, bold, upper, lower

        var delimiters: (opening: String, closing: String) {
            switch self {
            case .quote: return ("\"", "\"")
            case .paren: return ("(", ")")
            case .bracket: return ("[", "]")
            case .brace: return ("{", "}")
            case .backtick: return ("`", "`")
            case .bold: return ("**", "**")
            case .upper, .lower: return ("", "")
            }
        }

        var changesCase: Bool { self == .upper || self == .lower }

        /// Only a quotation ("He said, "…"") or a case change reads naturally after a comma.
        var keepsCommaBefore: Bool { self == .quote || changesCase }

        func applyCase(_ text: Substring) -> String {
            self == .upper ? text.uppercased() : text.lowercased()
        }
    }

    private struct Phrase {
        let words: [String]
        let kind: Kind
        let opens: Bool
        /// The recognizer often hears "end" as "and"; that reading only closes an open pair.
        var needsOpener = false

        /// Openers without an "open"/"begin"/"left" prefix can also be ordinary nouns ("the quote").
        /// Case commands are never nouns ("make this all caps on …").
        var isBare: Bool { opens && !kind.changesCase && !["open", "begin", "left"].contains(words[0]) }
    }

    private struct Word {
        let separator: String
        let text: String
        let core: String
        let hasLeadingPunctuation: Bool
        let trailing: String
    }

    private enum Item {
        case word(Int)
        case marker(Phrase, Range<Int>)
    }

    /// Keyed by first word so each transcript word costs one lookup, not a scan of every phrase.
    private static let phrasesByFirstWord: [String: [Phrase]] = {
        let entries: [(String, Kind, Bool)] = [
            ("quote", .quote, true), ("open quote", .quote, true), ("begin quote", .quote, true),
            ("end quote", .quote, false), ("close quote", .quote, false), ("unquote", .quote, false),
            ("end of quote", .quote, false),
            ("open paren", .paren, true), ("open parenthesis", .paren, true), ("open parentheses", .paren, true),
            ("left paren", .paren, true), ("paren", .paren, true), ("parenthesis", .paren, true),
            ("parentheses", .paren, true),
            ("close paren", .paren, false), ("close parenthesis", .paren, false), ("close parentheses", .paren, false),
            ("end paren", .paren, false), ("right paren", .paren, false),
            ("open bracket", .bracket, true), ("open square bracket", .bracket, true), ("left bracket", .bracket, true),
            ("close bracket", .bracket, false), ("close square bracket", .bracket, false),
            ("end bracket", .bracket, false), ("right bracket", .bracket, false),
            ("open brace", .brace, true), ("open curly brace", .brace, true), ("open curly", .brace, true),
            ("left brace", .brace, true),
            ("close brace", .brace, false), ("close curly brace", .brace, false), ("close curly", .brace, false),
            ("end brace", .brace, false), ("right brace", .brace, false),
            ("backtick", .backtick, true), ("back tick", .backtick, true), ("open backtick", .backtick, true),
            ("open back tick", .backtick, true),
            ("end backtick", .backtick, false), ("end back tick", .backtick, false),
            ("close backtick", .backtick, false), ("close back tick", .backtick, false),
            ("double asterisk", .bold, true), ("open double asterisk", .bold, true),
            ("close double asterisk", .bold, false), ("end double asterisk", .bold, false),
            ("all caps on", .upper, true), ("all caps", .upper, true),
            ("all caps off", .upper, false), ("end all caps", .upper, false),
            ("all lowercase", .lower, true), ("all lower case", .lower, true),
            ("end lowercase", .lower, false), ("end lower case", .lower, false),
        ]
        let parsed = entries.map { Phrase(words: $0.0.split(separator: " ").map(String.init), kind: $0.1, opens: $0.2) }
        let misheardEnds = parsed.filter { !$0.opens && $0.words[0] == "end" }.map {
            Phrase(words: ["and"] + $0.words.dropFirst(), kind: $0.kind, opens: false, needsOpener: true)
        }
        // Longest phrases first so "end quote" is never read as "end" plus an opening "quote".
        return Dictionary(grouping: (parsed + misheardEnds).sorted { $0.words.count > $1.words.count }) { $0.words[0] }
    }()

    /// Recognizer punctuation dropped just inside a closing delimiter; "?" and "!" are kept.
    private static let strippedBeforeClosing: Set<Character> = [",", ";", ":", "."]

    /// A bare opener directly after one of these is a noun ("the quote"), never an opener.
    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "my", "your", "his", "her", "our", "their", "its",
    ]

    /// The speech recognizer spells "paren" many ways in manual testing (paran, peren, peran, perran, …).
    private static func recognizerSpelling(_ core: String) -> String {
        // Cheap guard first: the regex runs for every word otherwise.
        guard core.first == "p", (5...6).contains(core.count) else { return core }
        return core.range(of: #"^p[ae]r{1,2}[ae]n$"#, options: .regularExpression) != nil ? "paren" : core
    }

    static func format(_ text: String) -> String {
        let words = Self.words(in: text)
        var items: [Item] = []
        var paired = Set<Int>()
        // Pairing happens during the scan so "and …" closers see exactly which openers are still open.
        var openers: [(item: Int, kind: Kind)] = []
        var index = 0
        while index < words.count {
            guard let phrase = phrasesByFirstWord[words[index].core]?.first(where: { phrase in
                (!phrase.needsOpener || openers.contains { $0.kind == phrase.kind }) && matches(phrase, at: index, in: words)
            }) else {
                items.append(.word(index))
                index += 1
                continue
            }
            let itemIndex = items.count
            items.append(.marker(phrase, index..<index + phrase.words.count))
            index += phrase.words.count
            if phrase.opens {
                openers.append((itemIndex, phrase.kind))
                continue
            }
            while let position = openers.lastIndex(where: { $0.kind == phrase.kind }) {
                let opener = openers[position].item
                if opener == itemIndex - 1 {
                    // Empty pairs stay literal. A bare opener may be a noun ("a price quote,
                    // end quote"), so keep looking for an earlier opener; otherwise the closer is spent.
                    openers.remove(at: position)
                    if case .marker(let openerPhrase, _) = items[opener], openerPhrase.isBare { continue }
                    break
                }
                paired.formUnion([opener, itemIndex])
                // Openers of another kind left inside the pair become literal text.
                openers.removeSubrange(position...)
                break
            }
        }
        // A case command that opens the dictation and is still unclosed (not paired, not part
        // of a rejected empty pair) applies to all of it.
        var casePrefix: Kind?
        if items.count > 1, openers.first?.item == 0, case .marker(let phrase, _) = items[0],
           phrase.opens, phrase.kind.changesCase {
            casePrefix = phrase.kind
        }
        guard !paired.isEmpty || casePrefix != nil else { return text }

        var output = ""
        var contentStarts: [Int] = []
        var afterOpening = false
        func append(_ word: Word) {
            output += (afterOpening ? "" : word.separator) + word.text
            afterOpening = false
        }
        for (itemIndex, item) in items.enumerated() {
            if itemIndex == 0, casePrefix != nil {
                afterOpening = true
                continue
            }
            switch item {
            case .word(let wordIndex):
                append(words[wordIndex])
            case .marker(let phrase, let range):
                guard paired.contains(itemIndex) else {
                    range.forEach { append(words[$0]) }
                    continue
                }
                if phrase.opens {
                    if !phrase.kind.keepsCommaBefore, output.last == "," { output.removeLast() }
                    output += (afterOpening ? "" : words[range.lowerBound].separator) + phrase.kind.delimiters.opening
                    contentStarts.append(output.utf8.count)
                    afterOpening = true
                } else {
                    let contentStart = contentStarts.removeLast()
                    while output.utf8.count > contentStart, let last = output.last, strippedBeforeClosing.contains(last) {
                        output.removeLast()
                    }
                    if phrase.kind.changesCase {
                        let start = output.utf8.index(output.utf8.startIndex, offsetBy: contentStart)
                        output.replaceSubrange(start..., with: phrase.kind.applyCase(output[start...]))
                    }
                    output += phrase.kind.delimiters.closing + words[range.upperBound - 1].trailing
                }
            }
        }
        return casePrefix?.applyCase(output[...]) ?? output
    }

    private static func matches(_ phrase: Phrase, at index: Int, in words: [Word]) -> Bool {
        guard index + phrase.words.count <= words.count else { return false }
        if phrase.isBare, index > 0, words[index - 1].trailing.isEmpty,
           determiners.contains(words[index - 1].core) {
            return false
        }
        return phrase.words.indices.allSatisfy { offset in
            let word = words[index + offset]
            return word.core == phrase.words[offset] && !word.hasLeadingPunctuation
                && (offset == phrase.words.count - 1 || word.trailing.isEmpty)
        }
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var separator = ""
        var current = ""
        for character in text {
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(word(current, separator: separator))
                    separator = ""
                    current = ""
                }
                separator.append(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(word(current, separator: separator)) }
        return result
    }

    private static func word(_ text: String, separator: String) -> Word {
        let start = text.firstIndex { !$0.isPunctuation } ?? text.endIndex
        var end = text.endIndex
        while end > start, text[text.index(before: end)].isPunctuation {
            end = text.index(before: end)
        }
        let core = text[start..<end].lowercased()
        return Word(separator: separator, text: text, core: recognizerSpelling(core),
                    hasLeadingPunctuation: start != text.startIndex, trailing: String(text[end...]))
    }
}
