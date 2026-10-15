import Foundation

/// Writes spoken numbers as digits ("twenty three stores" → "23 stores"). It is a small set of rules,
/// not a grammar of English; when a run of number words doesn't parse cleanly it stays as words. The
/// behaviour is pinned by linux/testdata/number-vectors.json, shared with the Rust port
/// (linux/crates/lf-dictation/src/numbers.rs).
///
/// - Ten and up, and compound numbers, become digits. Thousands separators start at 10,000 (so "two
///   thousand nine" reads as the year 2009), and a whole number of millions, billions or trillions keeps
///   its word ("5 million"). A run starting with a scale word ("a hundred times") stays as words.
/// - Zero to nine stay as words, except in a comma-separated run ("1, 2, 3"), after a label word
///   ("step 3") or a capital letter ("Q3"), before a unit ("5 GB") or a capital letter ("5G"), after a
///   month, or at either end of a range whose other end is digits ("5 to 15").
/// - Number words said in pairs: years ("nineteen eighty four" → 1984), runs of single digits ("four two
///   seven nine" → 4279), and times before am/pm ("three thirty pm" → 3:30 PM).
/// - Decimals ("three point one four", "point five"), percent, dollars, cents and euros.
/// - Ordinals from tenth up ("21st"); first to ninth stay as words except after a month ("March 4th").
///
/// Words are split on whitespace, and leading and trailing punctuation is kept as written. Number words
/// never span punctuation.
enum SpokenNumberFormatter {
    static func format(_ text: String) -> String {
        var (tokens, tail) = tokenize(text)
        guard !tokens.isEmpty else { return text }
        rewriteOrdinals(&tokens)
        var pieces = numberSpans(tokens)
        chooseSmallNumbers(&pieces)
        attachSuffixes(&pieces)
        joinLettersAndMonths(&pieces)
        return pieces.map { $0.separator + $0.lead + $0.value + $0.trail }.joined() + tail
    }

    // MARK: Word lists

    private static let units = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    /// Scale words above a hundred, with their values.
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000, "trillion": 1_000_000_000_000,
    ]
    /// Scales that keep their word after a whole multiplier ("5 million").
    private static let bigScales: Set<String> = ["million", "billion", "trillion"]
    private static let unitOrdinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
    /// Ordinals that always become digits, with their values.
    private static let largeOrdinals: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
        "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]
    /// Words after which a small number is a label: "step 3", "page 4".
    private static let labels: Set<String> = [
        "step", "steps", "version", "page", "pages", "line", "lines", "chapter", "section", "option", "item",
        "number", "issue", "level", "phase", "figure", "fig", "table", "slide", "slides", "grade", "part", "episode",
        "season", "volume", "vol", "row", "column", "exhibit", "appendix", "room", "gate", "platform", "floor",
    ]
    /// Words before which a small number is a measurement: "5 GB", "3 feet".
    private static let unitWords: Set<String> = [
        "percent", "percentage", "basis", "bps", "bytes", "byte", "kb", "mb", "gb", "tb", "kilobytes", "megabytes",
        "gigabytes", "terabytes", "bits", "kilobits", "megabits", "gigabits", "milliseconds", "ms", "microseconds",
        "nanoseconds", "hertz", "hz", "khz", "mhz", "ghz", "kilometers", "kilometres", "km", "meters", "metres",
        "centimeters", "cm", "millimeters", "mm", "miles", "mile", "feet", "foot", "inches", "inch", "kilograms", "kg",
        "grams", "pounds", "lbs", "tons", "tonnes", "ounces", "liters", "litres", "ml", "degrees", "volts", "watts",
        "kw", "kwh", "megawatts", "gigawatts", "amps", "pixels", "px", "cores", "threads", "cents", "cent", "dollars",
        "dollar", "bucks", "euros", "euro",
    ]
    private static let currencies: [String: String] = [
        "dollars": "$", "dollar": "$", "bucks": "$", "euros": "€", "euro": "€",
    ]
    /// After these, "point five" is a noun phrase, not 0.5: "a good point".
    private static let pointNounPrevious: Set<String> = [
        "a", "an", "the", "this", "that", "my", "your", "our", "their", "his", "her", "its", "good", "great", "fair",
        "valid", "main", "key", "next", "last", "first", "second", "one", "no", "each", "every", "some", "any",
        "which", "what", "another", "final",
    ]
    /// Words that join the two ends of a range. "and" only does after "between".
    private static let rangeWords: Set<String> = ["to", "through", "or"]
    /// Single capital letters that label a number ("Q3", "5G"); "A" and "I" are words.
    private static let letterLabels = Set("BCDEFGHJKLMNOPQRSTUVWXYZ".map(String.init))

    // MARK: Tokens

    /// A whitespace-separated word as written.
    private struct Token {
        var separator: String
        var lead: String
        var core: String
        var trail: String

        init(separator: String, text: String) {
            let start = text.firstIndex { !$0.isPunctuation } ?? text.endIndex
            var end = text.endIndex
            while end > start, text[text.index(before: end)].isPunctuation {
                end = text.index(before: end)
            }
            self.separator = separator
            lead = String(text[..<start])
            core = String(text[start..<end])
            trail = String(text[end...])
        }

        var lower: String { core.lowercased() }
        var text: String { lead + core + trail }
    }

    /// Splits `text` into words and the whitespace after the last word.
    private static func tokenize(_ text: String) -> ([Token], String) {
        var tokens: [Token] = []
        var separator = ""
        var word = ""
        for character in text {
            if character.isWhitespace {
                if !word.isEmpty {
                    tokens.append(Token(separator: separator, text: word))
                    separator = ""
                    word = ""
                }
                separator.append(character)
            } else {
                word.append(character)
            }
        }
        guard !word.isEmpty else { return (tokens, separator) }
        tokens.append(Token(separator: separator, text: word))
        return (tokens, "")
    }

    // MARK: Number words

    private static func unitValue(_ word: String) -> Int? { units.firstIndex(of: word) }

    private static func tensValue(_ word: String) -> Int? { tens.firstIndex(of: word).map { 10 * ($0 + 2) } }

    private static func isNumberWord(_ word: String) -> Bool {
        word == "hundred" || word == "oh" || unitValue(word) != nil || tensValue(word) != nil || scales[word] != nil
    }

    /// The token's number words ("twenty-three" is two), or nil if it has any other word.
    private static func numberWords(_ token: Token) -> [String]? {
        let lower = token.lower
        let words = lower.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        return !lower.isEmpty && words.allSatisfy(isNumberWord) ? words : nil
    }

    private static func singleDigit(_ word: String) -> Int? { unitValue(word).flatMap { $0 < 10 ? $0 : nil } }

    /// One ASCII digit: "5️⃣" is a single `Character` that sorts between "5" and "6", but isn't a digit.
    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.asciiValue.map { (48...57).contains($0) } ?? false
    }

    private static func isDigits(_ text: Substring, maxCount: Int = .max) -> Bool {
        (1...maxCount).contains(text.count) && text.allSatisfy(isASCIIDigit)
    }

    /// One cardinal number: "one hundred and thirty four thousand".
    private static func parseCardinal(_ words: [String]) -> Int? {
        enum Last { case unit, teen, tens, hundred, scale }
        var total = 0
        var current: Int?
        var last: Last?
        var largestScale = Int.max
        for (index, word) in words.enumerated() {
            if word == "and" {
                guard last == .hundred || last == .scale, index + 1 < words.count else { return nil }
            } else if let value = unitValue(word) {
                let afterUnits = last == .unit || last == .teen
                let afterTens = last == .tens && (value >= 10 || value == 0)
                let loneZero = value == 0 && (current != nil || total > 0 || words.count > 1)
                if afterUnits || afterTens || loneZero { return nil }
                current = (current ?? 0) + value
                last = value >= 10 ? .teen : .unit
            } else if let value = tensValue(word) {
                if last == .unit || last == .teen || last == .tens { return nil }
                current = (current ?? 0) + value
                last = .tens
            } else if word == "hundred" {
                guard let multiplier = current, multiplier < 100, last != .hundred else { return nil }
                current = multiplier * 100
                last = .hundred
            } else {
                guard let scale = scales[word], let multiplier = current, scale < largestScale else { return nil }
                total += multiplier * scale
                current = nil
                largestScale = scale
                last = .scale
            }
        }
        return last == nil ? nil : total + (current ?? 0)
    }

    /// 10 to 99 as written ("twenty one", "fifteen"), or "oh five" as "05".
    private static func twoDigits(_ words: [String]) -> String? {
        if words.count == 2, words[0] == "oh", let value = singleDigit(words[1]), value > 0 { return "0\(value)" }
        return parseCardinal(words).flatMap { (10...99).contains($0) ? String($0) : nil }
    }

    /// "nineteen eighty four", "twenty twenty one", "twenty oh five". The first half is 13 to 20, so "twelve
    /// thirty" isn't read as a year.
    private static func parseYear(_ words: [String]) -> String? {
        guard let century = parseCardinal([words[0]]), (13...20).contains(century),
              let rest = twoDigits(Array(words.dropFirst())) else { return nil }
        return "\(century)\(rest)"
    }

    /// Two or more single digits: "four two seven nine", "four oh four".
    private static func parseDigitRun(_ words: [String]) -> String? {
        guard words.count >= 2, words.first != "oh", words.last != "oh" else { return nil }
        var digits = ""
        for word in words {
            if word == "oh" {
                digits += "0"
            } else if let value = singleDigit(word) {
                digits += String(value)
            } else {
                return nil
            }
        }
        return digits
    }

    /// An hour and minutes before am/pm: "three thirty", "ten oh five".
    private static func parseTime(_ words: [String]) -> String? {
        for split in 1..<min(words.count, 3) {
            guard let hour = parseCardinal(Array(words[..<split])), (1...12).contains(hour),
                  let minutes = twoDigits(Array(words[split...])), let value = Int(minutes), value < 60 else { continue }
            return "\(hour):\(minutes)"
        }
        return nil
    }

    /// Thousands separators from 10,000 up.
    private static func group(_ value: Int) -> String {
        let digits = String(value)
        guard value >= 10_000 else { return digits }
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func ordinal(_ value: Int) -> String { "\(value)\(ordinalSuffix(value))" }

    /// A month name, except a lowercase "may", which is usually the verb.
    private static func isMonth(_ word: String) -> Bool {
        word != "may" && months.contains(word.lowercased())
    }

    private static func capitalized(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }

    // MARK: Ordinals

    /// "twenty first" → "21st", "thirteenth" → "13th", and a month's day ("march fourth" → "March 4th"). A
    /// tens word after another number word is part of a year ("twenty twenty first quarter"), and "a tenth"
    /// is a fraction.
    private static func rewriteOrdinals(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            let previous = i > 0 && tokens[i - 1].trail.isEmpty ? tokens[i - 1] : nil
            let afterNumber = previous.map { numberWords($0) != nil } ?? false
            let lower = tokens[i].lower
            if let dash = lower.firstIndex(of: "-"),
               let value = compoundOrdinal(String(lower[..<dash]), String(lower[lower.index(after: dash)...])) {
                if !afterNumber { tokens[i].core = ordinal(value) }
            } else if tokens[i].trail.isEmpty, i + 1 < tokens.count, tokens[i + 1].lead.isEmpty,
                      let value = compoundOrdinal(lower, tokens[i + 1].lower) {
                if !afterNumber {
                    let next = tokens.remove(at: i + 1)
                    tokens[i].core = ordinal(value)
                    tokens[i].trail = next.trail
                }
            } else if let value = largeOrdinals[lower] {
                let fraction = previous.map { ["a", "an", "one", "per"].contains($0.lower) } ?? false
                if !fraction { tokens[i].core = ordinal(value) }
            }
            i += 1
        }
        // A month's day: "december 28th", "March fourth".
        for i in tokens.indices.dropFirst() {
            let month = tokens[i - 1]
            let day = tokens[i]
            guard isMonth(month.core), month.trail.isEmpty, day.lead.isEmpty else { continue }
            let lower = day.lower
            if let index = unitOrdinals.firstIndex(of: lower) {
                tokens[i].core = ordinal(index + 1)
            } else if !isWrittenOrdinal(lower) {
                continue
            }
            tokens[i - 1].core = capitalized(month.core)
        }
    }

    /// "twenty" + "first" → 21.
    private static func compoundOrdinal(_ tens: String, _ unit: String) -> Int? {
        guard let unit = unitOrdinals.firstIndex(of: unit), let tens = tensValue(tens) else { return nil }
        return tens + unit + 1
    }

    /// "28th", "1st".
    private static func isWrittenOrdinal(_ word: String) -> Bool {
        let digits = word.prefix(while: isASCIIDigit)
        return !digits.isEmpty && ["st", "nd", "rd", "th"].contains(String(word.dropFirst(digits.count)))
    }

    // MARK: Number spans

    private enum Kind {
        /// Zero to nine, kept only in context.
        case small
        /// Anything else written as digits.
        case other
    }

    /// Output text: a word as written, or a run of number words written as digits (`kind` is set and
    /// `original` holds the words).
    private struct Piece {
        var separator: String
        var lead: String
        var value: String
        var trail: String
        var kind: Kind?
        var original = ""

        init(_ token: Token) {
            self.init(separator: token.separator, lead: token.lead, value: token.core, trail: token.trail, kind: nil)
        }

        init(separator: String, lead: String, value: String, trail: String, kind: Kind?, original: String = "") {
            self.separator = separator
            self.lead = lead
            self.value = value
            self.trail = trail
            self.kind = kind
            self.original = original
        }

        var lower: String { value.lowercased() }

        /// Nothing is attached after the word.
        var isBare: Bool { trail.isEmpty }

        /// Digits written by the recognizer or by these rules: "42", "$5", "3:30".
        var isNumeric: Bool {
            let digits = value.drop { $0 == "$" || $0 == "€" }
            return kind != nil
                || (digits.first.map(SpokenNumberFormatter.isASCIIDigit) ?? false
                    && digits.allSatisfy { SpokenNumberFormatter.isASCIIDigit($0) || ",.:".contains($0) })
        }
    }

    /// Replaces each run of number words with digits where it parses.
    private static func numberSpans(_ tokens: [Token]) -> [Piece] {
        var pieces: [Piece] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            var words: [String]
            var end: Int
            if let found = numberWords(token) {
                words = found
                end = i + 1
            } else if startsBareDecimal(tokens, i) {
                // "point five" → 0.5
                words = ["zero"]
                end = i
            } else {
                pieces.append(Piece(token))
                i += 1
                continue
            }
            var decimals: String?
            while end < tokens.count, end == i || tokens[end - 1].trail.isEmpty, tokens[end].lead.isEmpty {
                let next = tokens[end]
                let lower = next.lower
                if let more = numberWords(next) {
                    if let last = words.last, bigScales.contains(last),
                       !runContains(tokens, from: end, ["hundred", "thousand"]) {
                        break // "fifteen billion three year" is not 15,000,000,003
                    }
                    words += more
                    end += 1
                } else if let after = andAHalf(tokens, at: end) {
                    // "twelve and a half percent" → 12.5%; "two and a half hours" stays.
                    decimals = "5"
                    end = takeBigScale(tokens, at: after, &words)
                    break
                } else if lower == "and", next.trail.isEmpty,
                          let last = words.last, last == "hundred" || scales[last] != nil,
                          end + 1 < tokens.count, tokens[end + 1].lead.isEmpty, numberWords(tokens[end + 1]) != nil {
                    words.append("and")
                    end += 1
                } else if lower == "point", next.trail.isEmpty {
                    var digits = ""
                    var k = end + 1
                    while k < tokens.count, tokens[k].lead.isEmpty, let value = singleDigit(tokens[k].lower) {
                        digits += String(value)
                        k += 1
                        if !tokens[k - 1].trail.isEmpty { break }
                    }
                    if !digits.isEmpty {
                        decimals = digits
                        end = takeBigScale(tokens, at: k, &words)
                    }
                    break
                } else {
                    break
                }
            }
            if end == i {
                // A lone "point" with no digits after it.
                pieces.append(Piece(token))
                i += 1
                continue
            }
            let beforeAmPm = tokens[end - 1].trail.isEmpty && end < tokens.count
                && tokens[end].lead.isEmpty && isAmPm(tokens[end].lower)
            let time = beforeAmPm && decimals == nil ? parseTime(words).map { ($0, Kind.other) } : nil
            guard let rendered = time ?? render(words, decimals: decimals) else {
                pieces += tokens[i..<end].map { Piece($0) }
                i = end
                continue
            }
            let (value, kind) = rendered
            // "five G" → 5G, "four K" → 4K.
            if kind == .small, tokens[end - 1].trail.isEmpty, end < tokens.count, tokens[end].lead.isEmpty,
               letterLabels.contains(tokens[end].core) {
                let letter = tokens[end]
                pieces.append(Piece(separator: token.separator, lead: token.lead, value: value + letter.core,
                                    trail: letter.trail, kind: nil))
                i = end + 1
                continue
            }
            let original = tokens[i..<end].enumerated()
                .map { ($0.offset == 0 ? "" : $0.element.separator) + $0.element.text }.joined()
            pieces.append(Piece(separator: token.separator, lead: token.lead, value: value,
                                trail: tokens[end - 1].trail, kind: kind, original: original))
            i = end
        }
        return pieces
    }

    /// "point five" with no whole number, unless it is a noun phrase ("a good point five times").
    private static func startsBareDecimal(_ tokens: [Token], _ i: Int) -> Bool {
        let token = tokens[i]
        guard token.lower == "point", token.trail.isEmpty, i + 1 < tokens.count, tokens[i + 1].lead.isEmpty,
              singleDigit(tokens[i + 1].lower) != nil else { return false }
        return !(i > 0 && tokens[i - 1].trail.isEmpty && pointNounPrevious.contains(tokens[i - 1].lower))
    }

    /// Whether the run of number words starting at `tokens[start]` contains one of `needles`.
    private static func runContains(_ tokens: [Token], from start: Int, _ needles: Set<String>) -> Bool {
        for token in tokens[start...] {
            guard let words = numberWords(token) else { return false }
            if words.contains(where: needles.contains) { return true }
            if !token.trail.isEmpty { return false }
        }
        return false
    }

    /// The index after "and a half" when a percent, scale or currency follows.
    private static func andAHalf(_ tokens: [Token], at index: Int) -> Int? {
        guard index + 4 <= tokens.count else { return nil }
        let (and, a, half, next) = (tokens[index], tokens[index + 1], tokens[index + 2], tokens[index + 3])
        let follows = next.lower == "percent" || bigScales.contains(next.lower) || currencies[next.lower] != nil
        guard and.lower == "and", a.lower == "a", half.lower == "half",
              [and, a, half].allSatisfy({ $0.trail.isEmpty }), [a, half, next].allSatisfy({ $0.lead.isEmpty }),
              follows else { return nil }
        return index + 3
    }

    /// Takes a million/billion/trillion after a decimal: "22.7 million".
    private static func takeBigScale(_ tokens: [Token], at index: Int, _ words: inout [String]) -> Int {
        guard index < tokens.count, tokens[index - 1].trail.isEmpty, tokens[index].lead.isEmpty,
              bigScales.contains(tokens[index].lower) else { return index }
        words.append(tokens[index].lower)
        return index + 1
    }

    private static func isAmPm(_ word: String) -> Bool { ["am", "pm", "a.m", "p.m"].contains(word) }

    /// Digits for a run of number words, or nil to leave the words.
    private static func render(_ words: [String], decimals: String?) -> (String, Kind)? {
        let scale = words.count > 1 && bigScales.contains(words[words.count - 1]) ? words[words.count - 1] : nil
        if let decimals {
            let whole = scale == nil ? words : Array(words.dropLast())
            let head: String
            if whole == ["zero"] {
                head = "0"
            } else {
                guard let value = parseCardinal(whole) else { return nil }
                head = group(value)
            }
            return ("\(head).\(decimals)" + (scale.map { " \($0)" } ?? ""), .other)
        }
        if let value = parseCardinal(words) {
            if words.count == 1, value < 10 { return (String(value), .small) }
            if let scale, let head = parseCardinal(Array(words.dropLast())), head < 1000 {
                return ("\(head) \(scale)", .other)
            }
            return (group(value), .other)
        }
        return (parseYear(words) ?? parseDigitRun(words)).map { ($0, .other) }
    }

    // MARK: Small numbers

    /// Keeps a small number as digits only in context; the rest go back to words.
    private static func chooseSmallNumbers(_ pieces: inout [Piece]) {
        var keep = pieces.indices.map { keptBeforeRanges(pieces, $0) }
        // Both ends of a range: "one to two meters" → "1 to 2 meters".
        var changed = true
        while changed {
            changed = false
            for k in pieces.indices where pieces[k].kind == .small && !keep[k] {
                if (k >= 2 && inRange(pieces, keep, k - 2, k)) || inRange(pieces, keep, k, k + 2) {
                    keep[k] = true
                    changed = true
                }
            }
        }
        for k in pieces.indices where pieces[k].kind != nil && !keep[k] {
            pieces[k].lead = ""
            pieces[k].value = pieces[k].original
            pieces[k].trail = ""
            pieces[k].kind = nil
        }
    }

    /// Digits that stay digits: kept by these rules, or written by the recognizer.
    private static func isDigits(_ pieces: [Piece], _ keep: [Bool], _ k: Int) -> Bool {
        keep[k] || (pieces[k].kind == nil && pieces[k].isNumeric)
    }

    /// Whether `pieces[first]` and `pieces[second]` are the two ends of a range ("five to fifteen", "between
    /// five and twelve") and one of them is digits.
    private static func inRange(_ pieces: [Piece], _ keep: [Bool], _ first: Int, _ second: Int) -> Bool {
        let joiner = first + 1
        guard second < pieces.count, pieces[first].kind != nil || pieces[first].isNumeric,
              pieces[second].kind != nil || pieces[second].isNumeric,
              isDigits(pieces, keep, first) || isDigits(pieces, keep, second),
              pieces[first].isBare, pieces[joiner].isBare, pieces[joiner].lead.isEmpty,
              pieces[second].lead.isEmpty else { return false }
        let word = pieces[joiner].lower
        return rangeWords.contains(word)
            || (word == "and" && first > 0 && pieces[first - 1].isBare && pieces[first - 1].lower == "between")
    }

    /// Whether `pieces[k]` stays as digits before ranges are considered.
    private static func keptBeforeRanges(_ pieces: [Piece], _ k: Int) -> Bool {
        switch pieces[k].kind {
        case nil: return false
        case .other: return true
        case .small: break
        }
        let piece = pieces[k]
        let previous = k > 0 && pieces[k - 1].isBare ? pieces[k - 1] : nil
        let next = k + 1 < pieces.count && piece.isBare && pieces[k + 1].lead.isEmpty ? pieces[k + 1] : nil
        let label = previous.map {
            labels.contains($0.lower) || letterLabels.contains($0.value) || isMonth($0.value)
        } ?? false
        let unit = next.map { unitWords.contains($0.lower) || isAmPm($0.lower) } ?? false
        // A list: "one, two, three", "five, 10 years".
        func number(_ p: Int) -> Bool { p < pieces.count && (pieces[p].kind != nil || pieces[p].isNumeric) }
        func listed(_ p: Int) -> Bool { number(p) && pieces[p].trail == "," }
        let list = (k > 0 && listed(k - 1)) || (number(k + 1) && piece.trail == ",")
        // The last item after "and"/"or" once two items are listed: "one, two, and three".
        let lastItem = k >= 3 && (previous.map { $0.lead.isEmpty && ["and", "or"].contains($0.lower) } ?? false)
            && listed(k - 2) && listed(k - 3)
        return label || unit || list || lastItem
    }

    // MARK: Suffixes

    /// Percent, currency, am/pm and cents.
    private static func attachSuffixes(_ pieces: inout [Piece]) {
        var k = 0
        while k + 1 < pieces.count {
            guard pieces[k].isNumeric, pieces[k].isBare, pieces[k + 1].lead.isEmpty else {
                k += 1
                continue
            }
            let lower = pieces[k + 1].lower
            if lower == "percent" {
                let next = pieces.remove(at: k + 1)
                pieces[k].value += "%"
                pieces[k].trail = next.trail
            } else if let symbol = currencies[lower], !pieces[k].value.hasPrefix("$"), !pieces[k].value.hasPrefix("€") {
                let next = pieces.remove(at: k + 1)
                var value = pieces[k].value
                // Money groups thousands: $5,000.
                if value.count == 4, value.allSatisfy(isASCIIDigit) { value.insert(",", at: value.index(after: value.startIndex)) }
                pieces[k].value = symbol + value
                pieces[k].trail = next.trail
            } else if isAmPm(lower), isClockTime(pieces[k].value) {
                let next = pieces.remove(at: k + 1)
                var trail = next.trail
                // The period of "p.m." ends a sentence only at the end or before a capital.
                if lower.contains("."), trail.hasPrefix(".") {
                    let sentenceEnds = k + 1 >= pieces.count
                        || (pieces[k + 1].lead.isEmpty && (pieces[k + 1].value.first?.isUppercase ?? false))
                    if !sentenceEnds { trail.removeFirst() }
                }
                pieces[k].value += lower.hasPrefix("p") ? " PM" : " AM"
                pieces[k].trail = trail
            }
            k += 1
        }
        attachCents(&pieces)
    }

    /// "3", "11", "3:30": an hour from 1 to 12, with optional minutes.
    private static func isClockTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let hour = parts[0]
        let minutes = parts.count > 1 ? parts[1] : "00"
        return isDigits(hour, maxCount: 2) && minutes.count == 2 && isDigits(minutes)
            && (1...12).contains(Int(hour) ?? 0)
    }

    /// "$2 and 37 cents" → "$2.37".
    private static func attachCents(_ pieces: inout [Piece]) {
        var k = 0
        while k < pieces.count {
            let wholeDollars = pieces[k].isBare && pieces[k].value.hasPrefix("$")
                && isDigits(pieces[k].value.dropFirst())
            let and = k + 1 < pieces.count && pieces[k + 1].isBare && pieces[k + 1].lead.isEmpty
                && pieces[k + 1].lower == "and" ? 1 : 0
            let cents = k + 1 + and
            let word = k + 2 + and
            if wholeDollars, word < pieces.count,
               pieces[cents].isBare, pieces[cents].lead.isEmpty, isDigits(Substring(pieces[cents].value), maxCount: 2),
               pieces[word].lead.isEmpty, ["cents", "cent"].contains(pieces[word].lower) {
                let centsValue = Int(pieces[cents].value) ?? 0
                pieces[k].value += "." + (centsValue < 10 ? "0" : "") + String(centsValue)
                pieces[k].trail = pieces[word].trail
                pieces.removeSubrange((k + 1)...word)
            }
            k += 1
        }
    }

    // MARK: Letters and months

    /// "Q 3" → "Q3", and a month before digits is capitalized.
    private static func joinLettersAndMonths(_ pieces: inout [Piece]) {
        for k in pieces.indices.dropFirst() {
            guard pieces[k].kind != nil, pieces[k - 1].isBare, pieces[k].lead.isEmpty else { continue }
            if letterLabels.contains(pieces[k - 1].value), pieces[k - 1].lead.isEmpty,
               pieces[k].value.allSatisfy(isASCIIDigit) {
                pieces[k].separator = ""
            } else if isMonth(pieces[k - 1].value) {
                pieces[k - 1].value = capitalized(pieces[k - 1].value)
            }
        }
    }
}
