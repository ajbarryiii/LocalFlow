import Foundation

/// Lexicon-constrained CTC prefix beam search, exactly as the reference `swipe/decode.py`
/// (ARCHITECTURE.md, "Typing model v4 and swipe typing", step 5).
///
/// Label keys never repeat a letter, so a prefix grows only to a different letter and staying on
/// its last letter keeps the prefix. After each frame the `beam` prefixes with the highest total
/// probability survive; equal totals keep the smaller key (byte order). Each complete key scores
/// its words: `ctc / len(key)^lengthPower + freqWeight × freq + lengthBonus × len(key)`. Words come
/// back best first, unique ignoring case (the higher-scoring spelling wins), equal scores ordered by
/// Unicode scalar values. Float64 throughout.
enum SwipeDecoder {
    static let columns = 27   // blank + a…z

    /// `logProbs`: frames × 27, row-major (column 0 blank, 1 + i = letter i). At most `config.topK` results, best first.
    /// A `beam` or `topK` below 1 finds nothing.
    static func decode(logProbs: [Double], frames: Int, lexicon: SwipeLexicon, config: SwipeDecodeConfig) -> [SwipeCandidate] {
        precondition(frames >= 0 && logProbs.count == frames * columns, "logProbs must be frames × 27")
        guard config.beam >= 1, config.topK >= 1 else { return [] }
        return lexicon.withView { view, rank in
            logProbs.withUnsafeBufferPointer { lp -> [SwipeCandidate] in
                let beams = search(lp, frames: frames, view: view, rank: rank, beam: config.beam)
                return rankWords(beams, view: view, config: config)
            }
        }
    }

    /// `logaddexp` as the reference computes it: `max + log1p(exp(-|a - b|))`.
    static func logAddExp(_ a: Double, _ b: Double) -> Double {
        if a == -.infinity { return b }
        if b == -.infinity { return a }
        let m = a > b ? a : b
        return m + log1p(exp(-abs(a - b)))
    }

    private struct Prefix {
        var node: Int
        /// Log probability of the prefix ending in a blank, and in its last letter.
        var blank: Double
        var letter: Double
        var depth: Int
        /// The column of the key's last letter (0 for the root).
        var last: Int
        var total = -Double.infinity
        var rank: UInt32 = 0
    }

    private static func search(_ lp: UnsafeBufferPointer<Double>, frames: Int, view: SwipeLexicon.View,
                               rank: UnsafeBufferPointer<UInt32>, beam: Int) -> [Prefix] {
        var beams = [Prefix(node: 0, blank: 0, letter: -.infinity, depth: 0, last: 0)]
        var next: [Prefix] = []
        var slot: [Int: Int] = [:]
        slot.reserveCapacity(beam)
        let a = Int(UInt8(ascii: "a"))
        for frame in 0 ..< frames {
            let row = frame * columns
            let blank = lp[row]
            next.removeAll(keepingCapacity: true)
            slot.removeAll(keepingCapacity: true)
            // Each surviving prefix extends itself first, so a child that is also a beam finds its entry.
            for prefix in beams {
                slot[prefix.node] = next.count
                next.append(Prefix(node: prefix.node, blank: -.infinity, letter: -.infinity, depth: prefix.depth,
                                   last: prefix.last))
            }
            for (index, prefix) in beams.enumerated() {
                let total = logAddExp(prefix.blank, prefix.letter)
                next[index].blank = logAddExp(next[index].blank, total + blank)
                if prefix.depth > 0 {
                    next[index].letter = logAddExp(next[index].letter, prefix.letter + lp[row + prefix.last])
                }
                for edge in view.edges(of: prefix.node) {
                    let child = view.child(edge)
                    let column = 1 + Int(view.letter(edge)) - a
                    let value = total + lp[row + column]
                    if let existing = slot[child] {
                        next[existing].letter = logAddExp(next[existing].letter, value)
                    } else {
                        // A node has one parent, so no other prefix reaches this child.
                        next.append(Prefix(node: child, blank: -.infinity, letter: value, depth: prefix.depth + 1,
                                           last: column))
                    }
                }
            }
            for index in next.indices {
                next[index].total = logAddExp(next[index].blank, next[index].letter)
                next[index].rank = rank[next[index].node]
            }
            next.sort { $0.total > $1.total || ($0.total == $1.total && $0.rank < $1.rank) }
            beams.removeAll(keepingCapacity: true)
            beams.append(contentsOf: next.prefix(beam))
        }
        return beams
    }

    private static func rankWords(_ beams: [Prefix], view: SwipeLexicon.View, config: SwipeDecodeConfig) -> [SwipeCandidate] {
        var scored: [(score: Double, word: Int)] = []
        for prefix in beams where prefix.depth > 0 {
            let words = view.words(of: prefix.node)
            guard !words.isEmpty else { continue }
            let depth = Double(prefix.depth)
            let ctc = logAddExp(prefix.blank, prefix.letter) / pow(depth, config.lengthPower)
            for word in words {
                scored.append((ctc + config.freqWeight * Double(view.frequency(word)) + config.lengthBonus * depth, word))
            }
        }
        // UTF-8 byte order is Unicode scalar order.
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return view.text(lhs.word).lexicographicallyPrecedes(view.text(rhs.word))
        }
        var out: [SwipeCandidate] = []
        var seen = Set<[UInt8]>()
        for (score, index) in scored {
            let word = view.string(index)
            guard seen.insert(Array(word.lowercased().utf8)).inserted else { continue }
            out.append(SwipeCandidate(word: word, score: score))
            if out.count == config.topK { break }
        }
        return out
    }
}
