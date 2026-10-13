import Foundation

/// Aho-Corasick trie over token ids with per-entry strengths (DESIGN §1.2).
/// Immutable after construction, so one graph can serve every decode of a
/// dictionary snapshot; per-decision scratch lives in the caller.
final class BiasGraph {
    static let alpha = 1.414
    static let contextScore = 1.0
    static let depthScaling = 3.0
    static let root = 0

    /// Non-blank vocabulary size; the blank is row `tokens`.
    let tokens: Int
    private var children: [[Int: Int]] = [[:]]
    private var fail: [Int] = [0]
    /// α · score(n), computed in f64 and stored as f32.
    private var bonus: [Float] = [0]
    /// Bonuses for every row from the root, the end of every failure chain.
    private var rootRow: [Float] = []

    var isEmpty: Bool { children.count == 1 }

    init(phrases: [(tokens: [Int], strength: Float)], tokens: Int) throws {
        self.tokens = tokens
        var depth = [0]
        var sigma: [Double] = [0]
        for phrase in phrases {
            guard !phrase.tokens.isEmpty, phrase.strength.isFinite, phrase.strength > 0,
                  phrase.tokens.allSatisfy({ (0..<tokens).contains($0) }) else {
                throw LocalParakeetError.invalid("Invalid dictionary phrase.")
            }
            let strength = Double(phrase.strength)
            var node = Self.root
            for token in phrase.tokens {
                if let next = children[node][token] {
                    node = next
                } else {
                    children.append([:])
                    depth.append(depth[node] + 1)
                    sigma.append(0)
                    children[node][token] = children.count - 1
                    node = children.count - 1
                }
                // σ: the strongest phrase passing through or ending at the node.
                sigma[node] = max(sigma[node], strength)
            }
        }
        fail = [Int](repeating: Self.root, count: children.count)
        var score = [Double](repeating: 0, count: children.count)
        // Breadth-first, so each failure target is final before it is read.
        var queue = children[Self.root].values.sorted()
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            let own = sigma[node] * (Self.contextScore + Self.depthScaling * log(Double(depth[node])))
            score[node] = max(own, score[fail[node]])
            for (token, child) in children[node].sorted(by: { $0.key < $1.key }) {
                fail[child] = transition(from: fail[node], token: token)
                queue.append(child)
            }
        }
        bonus = score.map { Float(Self.alpha * $0) }
        rootRow = [Float](repeating: 0, count: tokens + 1)
        for (token, child) in children[Self.root] { rootRow[token] = bonus[child] }
    }

    private func transition(from state: Int, token: Int) -> Int {
        var state = state
        while true {
            if let next = children[state][token] { return next }
            if state == Self.root { return Self.root }
            state = fail[state]
        }
    }

    /// `goto(state, token)` and the bonus for taking a non-blank token there.
    /// The blank keeps the state and earns nothing.
    func step(_ state: Int, _ token: Int) -> (state: Int, bonus: Float) {
        guard token != tokens else { return (state, 0) }
        let next = transition(from: state, token: token)
        return (next, next == Self.root ? 0 : bonus[next])
    }

    /// argmax over rows 0...tokens of f64(logit) + f64(bonus), first maximum
    /// winning. `logits` must hold at least `tokens + 1` finite values.
    func biasedArgmax(state: Int, logits: UnsafePointer<Float>) -> Int {
        // Only tokens with a transition from the state or its suffixes get a
        // bonus; the deepest state on the failure chain decides each token.
        // Start from the root's row and overwrite from shallow to deep.
        var row = rootRow
        var chain: [Int] = []
        var node = state
        while node != Self.root {
            chain.append(node)
            node = fail[node]
        }
        for node in chain.reversed() {
            for (token, child) in children[node] { row[token] = bonus[child] }
        }
        var best = 0
        var bestValue = Double(logits[0]) + Double(row[0])
        for index in 1...tokens {
            let value = Double(logits[index]) + Double(row[index])
            if value > bestValue { best = index; bestValue = value }
        }
        return best
    }

    /// Phrase surfaces of an entry, deduplicated by scalars: the text, its
    /// fold, `upper1`, and every word through `upper1`.
    static func surfaces(of text: String) -> [[Unicode.Scalar]] {
        let scalars = Array(text.unicodeScalars)
        let words = scalars.split(separator: " ", omittingEmptySubsequences: false)
        var eachWord: [Unicode.Scalar] = []
        for (index, word) in words.enumerated() {
            if index > 0 { eachWord.append(" ") }
            eachWord += DictionaryText.upper1(word)
        }
        var result: [[Unicode.Scalar]] = []
        for surface in [scalars, DictionaryText.fold(scalars), DictionaryText.upper1(scalars), eachWord]
        where !result.contains(surface) {
            result.append(surface)
        }
        return result
    }

    /// nil when no surface encodes, including an empty dictionary: callers
    /// then take the unbiased decoding path.
    static func build(entries: [DictionaryEntry], encoder: BPEEncoder) -> BiasGraph? {
        let list = phrases(entries: entries, encoder: encoder)
        guard !list.isEmpty else { return nil }
        return try? BiasGraph(phrases: list, tokens: 1024)
    }

    /// The token sequences an entry list boosts, in first-seen order. Surfaces
    /// with <unk> are skipped; duplicate sequences keep the largest strength.
    static func phrases(entries: [DictionaryEntry], encoder: BPEEncoder) -> [(tokens: [Int], strength: Float)] {
        var strengths: [[Int]: Float] = [:]
        var order: [[Int]] = []
        for entry in entries {
            for surface in surfaces(of: entry.text) {
                let tokens = encoder.encode(DictionaryText.string(surface))
                guard !tokens.isEmpty, !tokens.contains(BPEEncoder.unknownID) else { continue }
                if let existing = strengths[tokens] {
                    strengths[tokens] = max(existing, entry.strength)
                } else {
                    strengths[tokens] = entry.strength
                    order.append(tokens)
                }
            }
        }
        return order.map { ($0, strengths[$0]!) }
    }
}

extension LocalParakeetCore {
    /// Biased greedy TDT decoding: same loop and limits as the unbiased
    /// `decode`, but the token is the f64 biased argmax over the exposed
    /// logits, and the bias state follows non-blank emissions.
    static func decode(length: Int, bias: BiasGraph, predict: (Int) throws -> Void,
                       joint: (Int) throws -> (logits: UnsafePointer<Float>, duration: Int),
                       check: () throws -> Void) throws -> [ParakeetToken] {
        let blank = 1024
        precondition(bias.tokens == blank, "Bias graph must cover the model vocabulary")
        var tokens: [ParakeetToken] = [], frame = 0, lastFrame = -1, symbols = 0, state = BiasGraph.root
        try predict(blank)
        while frame < length {
            try check()
            let (logits, duration) = try joint(frame)
            let token = bias.biasedArgmax(state: state, logits: logits)
            guard (0...blank).contains(token), (0...4).contains(duration) else {
                throw LocalParakeetError.invalid("Invalid local model decision.")
            }
            var advance = token == blank && duration == 0 ? 1 : duration
            if token != blank {
                symbols = lastFrame == frame ? symbols + 1 : 1
                lastFrame = frame
                tokens.append(ParakeetToken(id: token, frame: frame))
                state = bias.step(state, token).state
                try predict(token)
                if advance == 0 && symbols >= 10 { advance = 1 }
            }
            frame += advance
        }
        return tokens
    }
}
