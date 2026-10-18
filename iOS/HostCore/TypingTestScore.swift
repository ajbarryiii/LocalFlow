import Foundation

/// The TestFlight typing test's score (ARCHITECTURE.md, "Typing test"): a typed attempt aligned with its
/// passage by Levenshtein distance (unit costs; ties in the backtrace prefer a match or substitution, then a
/// dropped character, then an extra one), compared lowercased. Pure. Remove before the first production
/// release, with the typing counters.
struct TypingTestScore: Equatable, Sendable {
    /// One step of the alignment, in passage order: a passage character matched, dropped or typed wrong,
    /// or a typed character with no passage character.
    enum Op: Equatable, Sendable {
        case matched(Character)
        case dropped(Character)
        case wrong(expected: Character, typed: Character)
        case extra(Character)
    }

    /// The row of the intended key on the letters layer.
    enum Row: String, CaseIterable, Sendable {
        case top, middle, bottom, space, other

        static func of(_ character: Character) -> Row {
            if character == " " { return .space }
            if "qwertyuiop".contains(character) { return .top }
            if "asdfghjkl".contains(character) { return .middle }
            if "zxcvbnm".contains(character) { return .bottom }
            return .other
        }
    }

    /// Where a passage character sits: the space itself, the first letter of a word (a one-letter word
    /// included), the last letter of a word, or inside a word.
    enum Position: String, CaseIterable, Sendable {
        case space, wordStart, wordEnd, inside
    }

    let ops: [Op]
    let passageCount: Int
    let typedCount: Int
    private let droppedRows: [Row: Int]
    private let droppedPositions: [Position: Int]

    var matched: Int { count { if case .matched = $0 { return true }; return false } }
    var dropped: Int { count { if case .dropped = $0 { return true }; return false } }
    var wrong: Int { count { if case .wrong = $0 { return true }; return false } }
    var extra: Int { count { if case .extra = $0 { return true }; return false } }

    private func count(_ isIncluded: (Op) -> Bool) -> Int { ops.filter(isIncluded).count }

    func dropped(in row: Row) -> Int { droppedRows[row] ?? 0 }
    func dropped(at position: Position) -> Int { droppedPositions[position] ?? 0 }

    /// Characters typed per minute over `seconds`; nil without a span.
    func charactersPerMinute(seconds: TimeInterval) -> Double? {
        guard seconds > 0 else { return nil }
        return Double(typedCount) / seconds * 60
    }

    static func score(passage: String, typed: String) -> TypingTestScore {
        let a = Array(passage.lowercased()), b = Array(typed.lowercased())
        let n = a.count, m = b.count
        // distance[i][j]: the cost of aligning the first i passage characters with the first j typed ones.
        var distance = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0 ... n { distance[i][0] = i }
        for j in 0 ... m { distance[0][j] = j }
        if n > 0, m > 0 {
            for i in 1 ... n {
                for j in 1 ... m {
                    let diagonal = distance[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                    distance[i][j] = min(diagonal, distance[i - 1][j] + 1, distance[i][j - 1] + 1)
                }
            }
        }
        var ops: [Op] = []
        var rows: [Row: Int] = [:], positions: [Position: Int] = [:]
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, distance[i][j] == distance[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                ops.append(a[i - 1] == b[j - 1] ? .matched(a[i - 1]) : .wrong(expected: a[i - 1], typed: b[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0, distance[i][j] == distance[i - 1][j] + 1 {
                ops.append(.dropped(a[i - 1]))
                rows[Row.of(a[i - 1]), default: 0] += 1
                positions[position(of: i - 1, in: a), default: 0] += 1
                i -= 1
            } else {
                ops.append(.extra(b[j - 1]))
                j -= 1
            }
        }
        return TypingTestScore(ops: ops.reversed(), passageCount: n, typedCount: m, droppedRows: rows,
                               droppedPositions: positions)
    }

    private static func position(of index: Int, in text: [Character]) -> Position {
        if text[index] == " " { return .space }
        if index == 0 || text[index - 1] == " " { return .wordStart }
        if index == text.count - 1 || text[index + 1] == " " { return .wordEnd }
        return .inside
    }

    /// Invented practice sentences: lowercase letters and single spaces, every letter of the alphabet among
    /// them.
    static let passages = [
        "the quick brown fox jumps over the lazy dog",
        "we were going to get the bikes out but it actually started raining",
        "pack my box with five dozen liquor jugs",
        "she said the meeting was being moved to thursday afternoon",
        "how vexingly quick daft zebras jump",
        "i think we should leave a little earlier to beat the traffic",
        "the five boxing wizards jump quickly",
        "can you send me the address of the place where we are meeting",
        "my sister just got a new puppy and he is very excited about the snow",
        "jackdaws love my big sphinx of quartz",
    ]
}
