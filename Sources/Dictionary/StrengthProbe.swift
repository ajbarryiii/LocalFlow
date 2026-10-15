import Foundation

/// "Find strength" on iOS (iOS/ARCHITECTURE.md, "Custom dictionary"): one recorded sentence with the
/// word, decoded without it, then with it at each of `VerifyDecision.strengths` until a decode is
/// accepted. There is no typed correction, so the misheard span is wherever the boosted decode differs.
/// Pure, so it is tested without a model.
enum StrengthProbe {
    enum Outcome: Equatable, Sendable {
        /// The unboosted transcript already contains the word.
        case alreadyRecognized
        /// The lowest strength whose decode was accepted.
        case recognized(strength: Float)
        /// No strength produced the word without disturbing the rest.
        case notRecognized
    }

    struct Result: Equatable, Sendable {
        let outcome: Outcome
        /// The transcript without the word, for display.
        let base: String
        /// The accepted decode; nil unless `.recognized`.
        let boosted: String?
    }

    /// A replaced span may be at most this many words longer than the word itself.
    static let maxExtraReplacedWords = 2

    /// Whether `text` contains the word's normalized words contiguously.
    static func contains(_ word: String, in text: String) -> Bool {
        let w = VerifyDecision.norms(word)
        let t = VerifyDecision.norms(text)
        guard !w.isEmpty, t.count >= w.count else { return false }
        return (0...(t.count - w.count)).contains { Array(t[$0..<$0 + w.count]) == w }
    }

    /// The decode contains the word, and every edit block against the unboosted transcript has the word,
    /// exactly, as its new side, replacing at most `maxExtraReplacedWords` more words than it has.
    static func accepts(word: String, base: String, decoded: String) -> Bool {
        let w = VerifyDecision.norms(word)
        let b = VerifyDecision.norms(base)
        let n = VerifyDecision.norms(decoded)
        guard !w.isEmpty else { return false }
        let operations = WordAlignment.align(n, b)
        var blocks = 0
        var start = 0
        while start < operations.count {
            guard !operations[start].isMatch else { start += 1; continue }
            var end = start
            var nRun: [[Unicode.Scalar]] = [], bCount = 0
            while end < operations.count && !operations[end].isMatch {
                switch operations[end] {
                case .substitute(let a, _): nRun.append(n[a]); bCount += 1
                case .delete(let a, _): nRun.append(n[a])
                case .insert: bCount += 1
                case .match: break
                }
                end += 1
            }
            guard nRun == w, bCount <= w.count + maxExtraReplacedWords else { return false }
            blocks += 1
            start = end
        }
        return blocks > 0
    }

    /// `decode` re-decodes the same audio with the word at a strength and returns the casing-restored
    /// text. Strengths are tried in order and the first accepted one wins; a decode error ends the probe.
    static func find(word: String, base: String, decode: (Float) throws -> String) rethrows -> Result {
        if contains(word, in: base) { return Result(outcome: .alreadyRecognized, base: base, boosted: nil) }
        for strength in VerifyDecision.strengths {
            let decoded = try decode(strength)
            if accepts(word: word, base: base, decoded: decoded) {
                return Result(outcome: .recognized(strength: strength), base: base, boosted: decoded)
            }
        }
        return Result(outcome: .notRecognized, base: base, boosted: nil)
    }
}
