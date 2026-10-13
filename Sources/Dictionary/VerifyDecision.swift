import Foundation

/// The per-strength acceptance rule for a `replace` candidate (DESIGN §1.6,
/// pins P2 and P3). Pure, so the shared vectors can test it.
enum VerifyDecision {
    static let strengths: [Float] = [1.0, 1.41, 2.0, 2.83, 4.0]

    static func norms(_ text: String) -> [[Unicode.Scalar]] { DictionaryWord.split(text).map(\.norm) }

    /// §1.6.2: the run `B[i..<j]` the block's typed words align to with exact
    /// norm matches, or nil when they do not map onto a contiguous run.
    static func mapBlock(typed: String, candidate: CorrectionCandidate, base: [[Unicode.Scalar]]) -> Range<Int>? {
        let words = DictionaryWord.split(typed)
        let operations = WordAlignment.align(words.map(\.norm), base)
        var mapped: [Int] = []
        var blockWords = 0
        for operation in operations {
            let typedIndex: Int
            switch operation {
            case .match(let a, _), .substitute(let a, _), .delete(let a, _): typedIndex = a
            case .insert: continue
            }
            guard candidate.beforeRange.contains(words[typedIndex].index) else { continue }
            blockWords += 1
            guard case .match(_, let b) = operation else { return nil }
            mapped.append(b)
        }
        guard blockWords == candidate.beforeWords.count, let first = mapped.first,
              mapped == Array(first..<first + mapped.count),
              Array(base[first..<first + mapped.count]) == candidate.beforeWords else { return nil }
        return first..<first + mapped.count
    }

    /// Whether a re-decode `decoded` (after casing restoration) accepts the candidate.
    static func accepts(typed: String, candidate: CorrectionCandidate, base: String, decoded: String) -> Bool {
        let b = norms(base)
        guard let run = mapBlock(typed: typed, candidate: candidate, base: b) else { return false }
        let x = norms(candidate.surface)
        let expected = Array(b[..<run.lowerBound]) + x + Array(b[run.upperBound...])
        let n = norms(decoded)
        let operations = WordAlignment.align(n, expected)

        let lo = max(0, run.lowerBound - 2)
        let hi = min(expected.count, run.lowerBound + x.count + 2)
        // (a) No edit touches E[lo..<hi]; an N-only word placed before E[p] is in
        // the window when lo <= p <= hi.
        func inWindow(_ operation: WordAlignment.Operation) -> Bool {
            switch operation {
            case .match: return false
            case .substitute(_, let e), .insert(let e, _): return (lo..<hi).contains(e)
            case .delete(_, let p): return lo <= p && p <= hi
            }
        }
        guard !operations.contains(where: inWindow) else { return false }

        // (b) Any other edit block must replace the block's typed words by x.
        var start = 0
        while start < operations.count {
            guard !operations[start].isMatch else { start += 1; continue }
            var end = start
            var eRun: [[Unicode.Scalar]] = [], nRun: [[Unicode.Scalar]] = []
            while end < operations.count && !operations[end].isMatch {
                switch operations[end] {
                case .substitute(let a, let e): nRun.append(n[a]); eRun.append(expected[e])
                case .delete(let a, _): nRun.append(n[a])
                case .insert(let e, _): eRun.append(expected[e])
                case .match: break
                }
                end += 1
            }
            guard eRun == candidate.beforeWords, nRun == x else { return false }
            start = end
        }
        return true
    }
}

struct DictionarySuggestion: Equatable {
    let word: String
    let strength: Float
    let kind: CorrectionKind

    static func == (lhs: DictionarySuggestion, rhs: DictionarySuggestion) -> Bool {
        DictionaryText.same(lhs.word, rhs.word) && lhs.strength == rhs.strength && lhs.kind == rhs.kind
    }
}

/// Candidates in order, at most three attempted, five decodes each, within
/// 2 s of elapsed time, stopping when cancelled (DESIGN §1.6 budgets).
enum DictionarySuggestionFinder {
    static let maxCandidates = 3
    static let maxSeconds: TimeInterval = 2

    /// `decode` re-decodes the retained audio with the snapshot plus the given
    /// entry and returns the casing-restored text, or nil on failure.
    static func find(typed: String, edited: String, base: String, dictionary: [DictionaryEntry], ignore: Set<DictionaryKey>,
                     encoder: BPEEncoder?, now: () -> TimeInterval, isCancelled: () -> Bool,
                     decode: (DictionaryEntry) -> String?) -> DictionarySuggestion? {
        let start = now()
        let candidates = CorrectionCandidates.find(before: typed, after: edited, dictionary: dictionary, ignore: ignore,
                                                   encoder: encoder)
        for candidate in candidates.prefix(maxCandidates) {
            if candidate.kind == .casing {
                return DictionarySuggestion(word: candidate.surface, strength: DictionaryValidation.defaultStrength, kind: .casing)
            }
            for strength in VerifyDecision.strengths {
                guard !isCancelled(), now() - start < maxSeconds else { return nil }
                guard let decoded = decode(DictionaryEntry(text: candidate.surface, strength: strength)) else { break }
                if VerifyDecision.accepts(typed: typed, candidate: candidate, base: base, decoded: decoded) {
                    return DictionarySuggestion(word: candidate.surface, strength: strength, kind: .replace)
                }
            }
        }
        return nil
    }
}
