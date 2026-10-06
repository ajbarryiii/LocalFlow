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
/// close paren") into punctuation. A closer pairs with the nearest non-empty
/// opener of its kind; unmatched or empty pairs stay literal text.
enum SpokenDelimiterFormatter {
    private enum Kind {
        case quote, paren

        var opening: String { self == .quote ? "\"" : "(" }
        var closing: String { self == .quote ? "\"" : ")" }
    }

    private struct Phrase {
        let words: [String]
        let kind: Kind
        let opens: Bool
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

    private static let phrases: [Phrase] = {
        let entries: [(String, Kind, Bool)] = [
            ("quote", .quote, true), ("open quote", .quote, true), ("begin quote", .quote, true),
            ("end quote", .quote, false), ("close quote", .quote, false), ("unquote", .quote, false),
            ("end of quote", .quote, false),
            ("open paren", .paren, true), ("open parenthesis", .paren, true), ("open parentheses", .paren, true),
            ("left paren", .paren, true),
            ("close paren", .paren, false), ("close parenthesis", .paren, false), ("close parentheses", .paren, false),
            ("end paren", .paren, false), ("right paren", .paren, false),
        ]
        // Longest phrases first so "end quote" is never read as "end" plus an opening "quote".
        return entries.map { Phrase(words: $0.0.split(separator: " ").map(String.init), kind: $0.1, opens: $0.2) }
            .sorted { $0.words.count > $1.words.count }
    }()

    /// Recognizer punctuation dropped just inside a closing delimiter; "?" and "!" are kept.
    private static let strippedBeforeClosing: Set<Character> = [",", ";", ":", "."]

    static func format(_ text: String) -> String {
        let words = Self.words(in: text)
        var items: [Item] = []
        var index = 0
        while index < words.count {
            if let phrase = phrases.first(where: { matches($0, at: index, in: words) }) {
                items.append(.marker(phrase, index..<index + phrase.words.count))
                index += phrase.words.count
            } else {
                items.append(.word(index))
                index += 1
            }
        }

        var paired = Set<Int>()
        var openers: [(item: Int, kind: Kind)] = []
        for (itemIndex, item) in items.enumerated() {
            guard case .marker(let phrase, _) = item else { continue }
            if phrase.opens {
                openers.append((itemIndex, phrase.kind))
                continue
            }
            while let position = openers.lastIndex(where: { $0.kind == phrase.kind }) {
                let opener = openers[position].item
                if opener == itemIndex - 1 {
                    // Empty pair ("quote unquote"): leave this opener literal and keep looking.
                    openers.remove(at: position)
                    continue
                }
                paired.formUnion([opener, itemIndex])
                // Openers of another kind left inside the pair become literal text.
                openers.removeSubrange(position...)
                break
            }
        }
        guard !paired.isEmpty else { return text }

        var output = ""
        var contentStarts: [Int] = []
        var afterOpening = false
        func append(_ word: Word) {
            output += (afterOpening ? "" : word.separator) + word.text
            afterOpening = false
        }
        for (itemIndex, item) in items.enumerated() {
            switch item {
            case .word(let wordIndex):
                append(words[wordIndex])
            case .marker(let phrase, let range):
                guard paired.contains(itemIndex) else {
                    range.forEach { append(words[$0]) }
                    continue
                }
                if phrase.opens {
                    if phrase.kind == .paren, output.last == "," { output.removeLast() }
                    output += (afterOpening ? "" : words[range.lowerBound].separator) + phrase.kind.opening
                    contentStarts.append(output.utf8.count)
                    afterOpening = true
                } else {
                    let contentStart = contentStarts.removeLast()
                    while output.utf8.count > contentStart, let last = output.last, strippedBeforeClosing.contains(last) {
                        output.removeLast()
                    }
                    output += phrase.kind.closing + words[range.upperBound - 1].trailing
                }
            }
        }
        return output
    }

    private static func matches(_ phrase: Phrase, at index: Int, in words: [Word]) -> Bool {
        guard index + phrase.words.count <= words.count else { return false }
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
        return Word(separator: separator, text: text, core: text[start..<end].lowercased(),
                    hasLeadingPunctuation: start != text.startIndex, trailing: String(text[end...]))
    }
}
