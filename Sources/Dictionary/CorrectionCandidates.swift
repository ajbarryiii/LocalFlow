// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
import Foundation

/// Word-level Levenshtein alignment (unit costs) with the pinned backtrack
/// order: diagonal (match or substitution), then deletion, then insertion
/// (pin P2). Positions record where an unpaired word sits in the other side.
enum WordAlignment {
    enum Operation: Equatable {
        case match(a: Int, b: Int)
        case substitute(a: Int, b: Int)
        /// `a[a]` has no counterpart; it sits before `b[beforeB]`.
        case delete(a: Int, beforeB: Int)
        /// `b[b]` has no counterpart; it sits before `a[beforeA]`.
        case insert(b: Int, beforeA: Int)

        var isMatch: Bool { if case .match = self { return true } else { return false } }
    }

    static func align(_ a: [[Unicode.Scalar]], _ b: [[Unicode.Scalar]]) -> [Operation] {
        let width = b.count + 1
        var distance = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in 0...a.count { distance[i * width] = i }
        for j in 0...b.count { distance[j] = j }
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    let diagonal = distance[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                    distance[i * width + j] = min(diagonal, distance[(i - 1) * width + j] + 1, distance[i * width + j - 1] + 1)
                }
            }
        }
        var operations: [Operation] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            let here = distance[i * width + j]
            if i > 0, j > 0 {
                let same = a[i - 1] == b[j - 1]
                if here == distance[(i - 1) * width + j - 1] + (same ? 0 : 1) {
                    operations.append(same ? .match(a: i - 1, b: j - 1) : .substitute(a: i - 1, b: j - 1))
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, here == distance[(i - 1) * width + j] + 1 {
                operations.append(.delete(a: i - 1, beforeB: j))
                i -= 1
            } else {
                operations.append(.insert(b: j - 1, beforeA: i))
                j -= 1
            }
        }
        return operations.reversed()
    }
}

/// A word of a text with its whitespace-split index (DESIGN §1.5.2).
struct DictionaryWord {
    let index: Int
    let surface: [Unicode.Scalar]
    let norm: [Unicode.Scalar]

    /// Words with empty norms are dropped; indices stay those of the split.
    static func split(_ text: String) -> [DictionaryWord] {
        DictionaryText.words(text.unicodeScalars).enumerated().compactMap { index, word in
            let norm = DictionaryText.norm(word)
            return norm.isEmpty ? nil : DictionaryWord(index: index, surface: word, norm: norm)
        }
    }

    /// Edge-stripped surface with case kept, for pin P1.
    var stripped: [Unicode.Scalar] { DictionaryText.stripEdgePunctuation(surface) }
}

enum CorrectionKind: String, Equatable {
    case replace, casing
}

struct CorrectionCandidate: Equatable {
    let surface: String
    let kind: CorrectionKind
    /// Whitespace-split word indices of the block in the typed text.
    let beforeRange: Range<Int>
    let beforeWords: [[Unicode.Scalar]]

    static func == (lhs: CorrectionCandidate, rhs: CorrectionCandidate) -> Bool {
        DictionaryText.same(lhs.surface, rhs.surface) && lhs.kind == rhs.kind
            && lhs.beforeRange == rhs.beforeRange && lhs.beforeWords == rhs.beforeWords
    }
}

/// Correction → candidate words (DESIGN §1.5, pins P1, P2, P5).
enum CorrectionCandidates {
    static let maxBytes = 4096
    static let maxWords = 200
    static let maxBlockWords = 3

    static func withinBounds(_ text: String) -> Bool {
        text.utf8.count <= maxBytes && DictionaryText.words(text.unicodeScalars).count <= maxWords
    }

    static func find(before: String, after: String, dictionary: [DictionaryEntry], ignore: Set<DictionaryKey>,
                     encoder: BPEEncoder?) -> [CorrectionCandidate] {
        guard withinBounds(before), withinBounds(after) else { return [] }
        let old = DictionaryWord.split(before), new = DictionaryWord.split(after)
        let operations = WordAlignment.align(old.map(\.norm), new.map(\.norm))

        let longest = max(old.count, new.count)
        let edits = operations.filter { !$0.isMatch }.count
        if longest >= 5 && edits * 2 > longest { return [] }

        // P1: blocks also include norm matches whose stripped surfaces differ.
        func inBlock(_ operation: WordAlignment.Operation) -> Bool {
            if case .match(let a, let b) = operation { return old[a].stripped != new[b].stripped }
            return true
        }
        let known = Set(dictionary.map(\.key))
        var result: [CorrectionCandidate] = []
        var start = 0
        while start < operations.count {
            guard inBlock(operations[start]) else { start += 1; continue }
            var end = start
            while end < operations.count && inBlock(operations[end]) { end += 1 }
            if let candidate = candidate(operations[start..<end], old: old, new: new, known: known, ignore: ignore,
                                         encoder: encoder) {
                result.append(candidate)
            }
            start = end
        }
        return result
    }

    private static func candidate(_ block: ArraySlice<WordAlignment.Operation>, old: [DictionaryWord], new: [DictionaryWord],
                                  known: Set<DictionaryKey>, ignore: Set<DictionaryKey>,
                                  encoder: BPEEncoder?) -> CorrectionCandidate? {
        var beforeWords: [DictionaryWord] = [], afterWords: [DictionaryWord] = []
        for operation in block {
            switch operation {
            case .match(let a, let b), .substitute(let a, let b):
                beforeWords.append(old[a]); afterWords.append(new[b])
            case .delete(let a, _): beforeWords.append(old[a])
            case .insert(let b, _): afterWords.append(new[b])
            }
        }
        guard (1...maxBlockWords).contains(beforeWords.count), (1...maxBlockWords).contains(afterWords.count) else { return nil }

        var joined: [Unicode.Scalar] = []
        for (index, word) in afterWords.enumerated() {
            if index > 0 { joined.append(" ") }
            joined += word.surface
        }
        let surface = DictionaryText.stripEdgePunctuation(joined)
        guard case .success(let entry) = DictionaryValidation.validate(text: DictionaryText.string(surface),
                                                                      strength: DictionaryValidation.defaultStrength,
                                                                      encoder: encoder),
              !known.contains(entry.key), !ignore.contains(entry.key) else { return nil }

        let kind: CorrectionKind
        if beforeWords.map(\.norm) == afterWords.map(\.norm) {
            // P1: an uppercase scalar past the first, so sentence-start capitals never qualify.
            let text = Array(entry.text.unicodeScalars)
            guard text.dropFirst().contains(where: DictionaryText.isUppercase) else { return nil }
            kind = .casing
        } else {
            kind = .replace
        }
        let indices = beforeWords.map(\.index)
        return CorrectionCandidate(surface: entry.text, kind: kind, beforeRange: indices.min()!..<indices.max()! + 1,
                                   beforeWords: beforeWords.map(\.norm))
    }
}
