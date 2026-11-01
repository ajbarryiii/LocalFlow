import Accelerate
import Foundation

/// A word model for autocorrect (ARCHITECTURE.md, "Word autocorrect", word models; reference: localflow-swipe
/// `tap/wordlm.py`): natural-log probabilities of words given the previous words of their sentence
/// (`Autocorrector.sentenceWords`), normalized over the lexicon's forms, "<unk>" and "</s>". A word outside
/// the vocabulary gets the probability of "<unk>". Main thread only: models may cache by context.
protocol WordModel: AnyObject {
    func logProbs(context: [String], words: [String]) -> [Double]
    /// `logProbs` of every form of `lexicon`, by form id, in one call: what suggestions while typing rank completions
    /// by, once per context (ARCHITECTURE.md, "Word autocorrect", Suggestions).
    func logProbs(context: [String], allFormsOf lexicon: WordLexicon) -> [Double]
    /// Whether the word has its own probability (not "<unk>"'s).
    func inVocab(_ word: String) -> Bool
    /// Drops every cache of contexts; results after it are the same as before.
    func forgetContext()
}

extension WordModel {
    /// Every form by name.
    func logProbs(context: [String], allFormsOf lexicon: WordLexicon) -> [Double] {
        logProbs(context: context, words: (0 ..< lexicon.formCount).map(lexicon.form(at:)))
    }
}

/// Word model constants shared with the reference (`tap.wordlm`).
enum WordModelVocabulary {
    static let unknown = "<unk>"
    static let end = "</s>"
    /// The AOSP prior's exponent per frequency step: exp(beta f) spans 10⁸ over AOSP's 0–255.
    static let beta = 8 * log(10.0) / 255
}

/// W0 (`tap.wordlm.UnigramLM`, kind "unigram", no file): the context is ignored. A lexicon form with AOSP
/// frequency f gets (1 − unknownMass) exp(beta f) / Z, Z over every form; "<unk>", "</s>" and every other
/// word get `unknownMass`. Beta and the mass come from the lexicon file.
final class UnigramWordModel: WordModel {
    let lexicon: WordLexicon
    /// log P by AOSP frequency (0...255).
    private let byFrequency: [Double]
    private let logUnknown: Double

    init(lexicon: WordLexicon) {
        self.lexicon = lexicon
        let unknownMass = lexicon.unigramUnknownMass
        byFrequency = lexicon.aospPrior(beta: lexicon.unigramBeta).map { log((1 - unknownMass) * $0) }
        logUnknown = log(unknownMass)
    }

    func logProbs(context: [String], words: [String]) -> [Double] {
        words.map { word in lexicon.frequency(of: word).map { byFrequency[$0] } ?? logUnknown }
    }

    func inVocab(_ word: String) -> Bool {
        word == WordModelVocabulary.unknown || lexicon.contains(word)
    }

    /// Nothing to drop: the model keeps no context.
    func forgetContext() {}
}

/// W1 (`tap.wordlm.WordNGram`, kind "ngram"): an interpolated Kneser-Ney word n-gram, the "LFWN" version 1
/// file of localflow-swipe `tap/export_word_ios.py`, read in place from a mapped file:
///
///     "LFWN"  u32 version (1)  u32 order n  u32 id bits b  u32 I = N + 4 word ids  u32 0  f64 alpha  f64 beta
///     32 bytes lexicon hash; per order k = 2 ... n: u64 contexts C_k, u64 n-grams G_k, f64 discount D_k
///     sections (each 8-aligned): p1 f32[I]; per order k = 2 ... n: ctx_codes u64[C_k], ctx_total f32[C_k],
///     ctx_gamma f32[C_k], gram_codes u64[G_k], gram_counts f32[G_k]
///
/// Word ids: form f is f + 4, "</s>" 2, "<s>" 1 (padding only), anything else 3 ("<unk>"). The code of ids
/// oldest first is built as code = (code << b) | id; an n-gram's code is (its context's code << b) | word.
/// log P(w | context): p = p1[w]; for k = 2 ... n, h the code of the history's last k − 1 ids (the context's
/// last n − 1 words, left-padded with "<s>"), if h is a stored context i, p = max(c − D_k, 0) / total_i +
/// gamma_i p, c the stored count of (h << b) | w or 0. Computed in Float64 from the Float32 tables. The
/// initializer validates the file against its lexicon (the hash and form count).
final class NGramWordModel: WordModel {
    static let version: UInt32 = 1

    let lexicon: WordLexicon
    let order: Int
    let bits: Int

    private let data: Data
    private let p1: Int
    private let orders: [Order]

    private struct Order {
        var contexts: Int, grams: Int, discount: Double
        var contextCodes = 0, contextTotal = 0, contextGamma = 0, gramCodes = 0, gramCounts = 0
    }

    init(data input: Data, lexicon: WordLexicon) throws {
        try LFBinaryFile.checkHeader(input, magic: "LFWN", version: Self.version, header: 72, as: WordFileError.self)
        let data = LFBinaryFile.aligned(input)
        let (header, alpha, beta, hash) = data.withUnsafeBytes { raw in
            ((2 ..< 6).map { Int(LFBinaryFile.u32(raw, 4 * $0)) }, LFBinaryFile.f64(raw, 24), LFBinaryFile.f64(raw, 32),
             Data(raw[40 ..< 72]))
        }
        let order = header[0], bits = header[1], ids = header[2]
        // Each factor bounded before the product, so a huge header cannot overflow.
        guard (1 ... 63).contains(order), (1 ... 63).contains(bits), order * bits <= 63, header[3] == 0, ids <= 1 << bits else {
            throw WordFileError.unsupportedShape
        }
        guard hash == lexicon.hash, ids == lexicon.formCount + 4 else { throw WordFileError.lexiconMismatch }
        guard alpha.isFinite, beta.isFinite else { throw WordFileError.invalidValues }
        let directory = 72 + 24 * (order - 1)
        guard data.count >= directory else { throw WordFileError.wrongSize }
        var orders = try data.withUnsafeBytes { raw in
            try (0 ..< order - 1).map { index -> Order in
                let contexts = LFBinaryFile.u64(raw, 72 + 24 * index), grams = LFBinaryFile.u64(raw, 80 + 24 * index)
                guard contexts <= UInt64(UInt32.max), grams <= UInt64(UInt32.max) else { throw WordFileError.unsupportedShape }
                return Order(contexts: Int(contexts), grams: Int(grams), discount: LFBinaryFile.f64(raw, 88 + 24 * index))
            }
        }
        var sections = WordFileSections(header: directory)
        let p1 = try sections.next(count: ids, size: 4)
        for index in orders.indices {
            orders[index].contextCodes = try sections.next(count: orders[index].contexts, size: 8)
            orders[index].contextTotal = try sections.next(count: orders[index].contexts, size: 4)
            orders[index].contextGamma = try sections.next(count: orders[index].contexts, size: 4)
            orders[index].gramCodes = try sections.next(count: orders[index].grams, size: 8)
            orders[index].gramCounts = try sections.next(count: orders[index].grams, size: 4)
        }
        guard sections.end == data.count else { throw WordFileError.wrongSize }
        try data.withUnsafeBytes { raw in
            for id in 0 ..< ids {
                let p = LFBinaryFile.f32(raw, p1 + 4 * id)
                guard p.isFinite, p >= 0 else { throw WordFileError.invalidValues }
            }
            for table in orders {
                guard table.discount.isFinite, table.discount >= 0 else { throw WordFileError.invalidValues }
                for i in 0 ..< table.contexts {
                    let total = LFBinaryFile.f32(raw, table.contextTotal + 4 * i)
                    let gamma = LFBinaryFile.f32(raw, table.contextGamma + 4 * i)
                    guard total.isFinite, total > 0, gamma.isFinite, gamma >= 0 else { throw WordFileError.invalidValues }
                    if i > 0 {
                        guard LFBinaryFile.u64(raw, table.contextCodes + 8 * (i - 1)) < LFBinaryFile.u64(raw, table.contextCodes + 8 * i)
                        else { throw WordFileError.invalidStructure }
                    }
                }
                // Codes strictly increasing, and every n-gram's context stored (a merge: both are sorted).
                var context = 0
                for i in 0 ..< table.grams {
                    let count = LFBinaryFile.f32(raw, table.gramCounts + 4 * i)
                    guard count.isFinite, count >= 0 else { throw WordFileError.invalidValues }
                    let code = LFBinaryFile.u64(raw, table.gramCodes + 8 * i)
                    if i > 0 {
                        guard LFBinaryFile.u64(raw, table.gramCodes + 8 * (i - 1)) < code else { throw WordFileError.invalidStructure }
                    }
                    let owner = code >> UInt64(bits)
                    while context < table.contexts, LFBinaryFile.u64(raw, table.contextCodes + 8 * context) < owner { context += 1 }
                    guard context < table.contexts, LFBinaryFile.u64(raw, table.contextCodes + 8 * context) == owner else {
                        throw WordFileError.invalidStructure
                    }
                }
            }
        }
        self.lexicon = lexicon
        self.order = order
        self.bits = bits
        self.data = data
        self.p1 = p1
        self.orders = orders
    }

    /// Maps a model file made for `lexicon`. Call off the main thread.
    static func load(from url: URL, lexicon: WordLexicon) throws -> NGramWordModel {
        try NGramWordModel(data: Data(contentsOf: url, options: .alwaysMapped), lexicon: lexicon)
    }

    func inVocab(_ word: String) -> Bool {
        word == WordModelVocabulary.unknown || word == WordModelVocabulary.end || lexicon.contains(word)
    }

    /// Nothing to drop: the model keeps no context (a lookup is a few binary searches).
    func forgetContext() {}

    /// The word id of a word: form f is f + 4, "</s>" 2, anything else "<unk>" (3).
    private func id(_ word: String) -> UInt64 {
        if let form = lexicon.formID(of: word) { return UInt64(form + 4) }
        return word == WordModelVocabulary.end ? 2 : 3
    }

    func logProbs(context: [String], words: [String]) -> [Double] {
        let n = order - 1
        let tail = context.suffix(n).map(id)
        let history = [UInt64](repeating: 1, count: n - tail.count) + tail
        let ids = words.map(id)
        let b = UInt64(bits)
        return data.withUnsafeBytes { raw in
            // The stored contexts of the history, lowest order first: (table, context index, n-gram range).
            var found: [(Order, Int, Range<Int>, UInt64)] = []
            for (index, table) in orders.enumerated() {
                let k = index + 2
                var h: UInt64 = 0
                for a in history.suffix(k - 1) { h = (h << b) | a }
                let i = Self.lowerBound(raw, table.contextCodes, table.contexts, h)
                guard i < table.contexts, LFBinaryFile.u64(raw, table.contextCodes + 8 * i) == h else { continue }
                let lo = Self.lowerBound(raw, table.gramCodes, table.grams, h << b)
                let hi = Self.lowerBound(raw, table.gramCodes, table.grams, (h + 1) << b)
                found.append((table, i, lo ..< hi, h))
            }
            return ids.map { w in
                var p = Double(LFBinaryFile.f32(raw, p1 + 4 * Int(w)))
                for (table, i, range, h) in found {
                    let code = (h << b) | w
                    let j = range.lowerBound + Self.lowerBound(raw, table.gramCodes + 8 * range.lowerBound, range.count, code)
                    let c = j < range.upperBound && LFBinaryFile.u64(raw, table.gramCodes + 8 * j) == code
                        ? Double(LFBinaryFile.f32(raw, table.gramCounts + 4 * j)) : 0
                    let total = Double(LFBinaryFile.f32(raw, table.contextTotal + 4 * i))
                    let gamma = Double(LFBinaryFile.f32(raw, table.contextGamma + 4 * i))
                    p = max(c - table.discount, 0) / total + gamma * p
                }
                return log(p)
            }
        }
    }

    /// The first index in the sorted u64 array at `offset` (`count` long) whose value is at least `value`.
    private static func lowerBound(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ count: Int, _ value: UInt64) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if LFBinaryFile.u64(raw, offset + 8 * mid) < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// W2 (`tap.wordlstm.WordLSTM`, kind "lstm"): a one-layer word LSTM with tied embeddings, the "LFWR" version 1
/// file of localflow-swipe `tap/export_word_ios.py`, read in place from a mapped file:
///
///     "LFWR"  u32 version (1)  u32 E embed  u32 H hidden  u32 V model words  u32 N lexicon forms
///     f64 u  f64 beta  f64 log_z_rare  32 bytes lexicon hash
///     sections (each 8-aligned; weights f32, row-major): words u32[V], form_words u32[N],
///     embedding [V + 3][E], w_ih [4H][E], w_hh [4H][H], bias [4H], proj [E][H], out_bias [V + 2]
///
/// - Input ids: 0 "<s>", 1 "</s>", 2 "<unk>", 3 + k model word k (form `words[k]`); every other word, rare
///   lexicon forms included, reads as "<unk>". Output class = input id − 1.
/// - From h = c = 0 it reads "<s>" then the context: z = w_ih x + w_hh h + bias, gates in torch's order
///   (input, forget, cell, output), c = f c + i g, h = o tanh(c). Then out = proj h,
///   logits = embedding[1...] out + out_bias, log P(class) = logits − logsumexp(logits).
/// - A model word k scores log P(k + 2); "</s>" log P(0); a rare form r log P(1) + log(1 − u) +
///   beta freq(r) − log_z_rare; anything else log P(1) + log u.
/// - Matrix products are Float32 (Accelerate, on the mapped weights) as the reference's weights are; the
///   normalizer and the scores are Float64.
/// - States are cached by context (input ids), at most `cacheLimit`, least recently used out first, so
///   extending a cached context costs one step; results are the same as from a cold cache.
final class LSTMWordModel: WordModel {
    static let version: UInt32 = 1
    static let cacheLimit = 64
    /// Accepted sizes; the bundled models are far smaller.
    static let sizeRange = 1 ... 4_096
    private static let rare: UInt32 = 0xFFFF_FFFF

    let lexicon: WordLexicon
    let embed: Int
    let hidden: Int
    /// Model words.
    let vocabulary: Int

    private let data: Data
    private let offsets: Offsets
    private let logUnknown: Double
    /// log(1 − u) + beta f − log_z_rare by frequency f.
    private let rareByFrequency: [Double]

    private struct Offsets {
        var formWords = 0, embedding = 0, wIH = 0, wHH = 0, bias = 0, proj = 0, outBias = 0
    }

    private struct State {
        var h: [Float]
        var c: [Float]
        var out: [Float]
        var logZ: Double
        var used: Int
    }

    private var cache: [[Int32]: State] = [:]
    private var clock = 0

    init(data input: Data, lexicon: WordLexicon) throws {
        try LFBinaryFile.checkHeader(input, magic: "LFWR", version: Self.version, header: 80, as: WordFileError.self)
        let data = LFBinaryFile.aligned(input)
        let (header, u, beta, logZRare, hash) = data.withUnsafeBytes { raw in
            ((2 ..< 6).map { Int(LFBinaryFile.u32(raw, 4 * $0)) }, LFBinaryFile.f64(raw, 24), LFBinaryFile.f64(raw, 32),
             LFBinaryFile.f64(raw, 40), Data(raw[48 ..< 80]))
        }
        let e = header[0], h = header[1], v = header[2], n = header[3]
        guard hash == lexicon.hash, n == lexicon.formCount else { throw WordFileError.lexiconMismatch }
        guard Self.sizeRange.contains(e), Self.sizeRange.contains(h), v <= n else { throw WordFileError.unsupportedShape }
        guard u > 0, u <= 1, (v < n) == (u < 1), beta.isFinite, logZRare.isFinite else { throw WordFileError.invalidValues }
        var sections = WordFileSections(header: 80)
        let words = try sections.next(count: v, size: 4)
        var offsets = Offsets()
        offsets.formWords = try sections.next(count: n, size: 4)
        offsets.embedding = try sections.next(count: (v + 3) * e, size: 4)
        offsets.wIH = try sections.next(count: 4 * h * e, size: 4)
        offsets.wHH = try sections.next(count: 4 * h * h, size: 4)
        offsets.bias = try sections.next(count: 4 * h, size: 4)
        offsets.proj = try sections.next(count: e * h, size: 4)
        offsets.outBias = try sections.next(count: v + 2, size: 4)
        guard sections.end == data.count else { throw WordFileError.wrongSize }
        try data.withUnsafeBytes { raw in
            // form_words is the inverse of words: model word k's form maps to k, every other form is rare.
            var models = 0
            for form in 0 ..< n {
                let k = LFBinaryFile.u32(raw, offsets.formWords + 4 * form)
                guard k == Self.rare || (Int(k) < v && Int(LFBinaryFile.u32(raw, words + 4 * Int(k))) == form) else {
                    throw WordFileError.invalidStructure
                }
                if k != Self.rare { models += 1 }
            }
            guard models == v else { throw WordFileError.invalidStructure }
            for offset in stride(from: offsets.embedding, to: offsets.outBias + 4 * (v + 2), by: 4) {
                guard LFBinaryFile.f32(raw, offset).isFinite else { throw WordFileError.invalidValues }
            }
        }
        self.lexicon = lexicon
        embed = e
        hidden = h
        vocabulary = v
        self.data = data
        self.offsets = offsets
        logUnknown = log(u)
        rareByFrequency = (0 ... 255).map { log(1 - u) + beta * Double($0) - logZRare }
    }

    /// Maps a model file made for `lexicon`. Call off the main thread.
    static func load(from url: URL, lexicon: WordLexicon) throws -> LSTMWordModel {
        try LSTMWordModel(data: Data(contentsOf: url, options: .alwaysMapped), lexicon: lexicon)
    }

    /// How many contexts are cached (at most `cacheLimit`).
    var cachedCount: Int { cache.count }

    /// Drops the cached states, and with them every context they came from.
    func forgetContext() {
        cache = [:]
        clock = 0
    }

    func inVocab(_ word: String) -> Bool {
        word == WordModelVocabulary.unknown || word == WordModelVocabulary.end || lexicon.contains(word)
    }

    func logProbs(context: [String], words: [String]) -> [Double] {
        let key = context.map(input)
        let state = state(for: key)
        return data.withUnsafeBytes { raw in
            let embedding = raw.baseAddress!.advanced(by: offsets.embedding).assumingMemoryBound(to: Float.self)
            let outBias = raw.baseAddress!.advanced(by: offsets.outBias).assumingMemoryBound(to: Float.self)
            return words.map { word in
                let (output, extra) = score(word, raw)
                let row = embedding + (output + 1) * embed
                var dot = 0.0
                for i in 0 ..< embed { dot += Double(row[i]) * Double(state.out[i]) }
                return dot + Double(outBias[output]) - state.logZ + extra
            }
        }
    }

    /// Every form of the model's own lexicon from one read-out of the context's state: a model word's logit, or a
    /// rare form's "<unk>" class with its frequency's share, as `logProbs` scores each.
    func logProbs(context: [String], allFormsOf lexicon: WordLexicon) -> [Double] {
        guard lexicon === self.lexicon else { return logProbs(context: context, words: (0 ..< lexicon.formCount).map(lexicon.form(at:))) }
        let state = state(for: context.map(input))
        let classes = vocabulary + 2
        return data.withUnsafeBytes { raw in
            let embedding = raw.baseAddress!.advanced(by: offsets.embedding).assumingMemoryBound(to: Float.self)
            let outBias = raw.baseAddress!.advanced(by: offsets.outBias).assumingMemoryBound(to: Float.self)
            // Class c's logit is embedding row c + 1 · out, as the step's read-out computes them (Float32: within
            // rounding of `logProbs`, which sums each in Float64; enough to rank by).
            var logits = [Float](repeating: 0, count: classes)
            vDSP_mmul(embedding + embed, 1, state.out, 1, &logits, 1, vDSP_Length(classes), 1, vDSP_Length(embed))
            return (0 ..< lexicon.formCount).map { form in
                let k = LFBinaryFile.u32(raw, offsets.formWords + 4 * form)
                let output = k == Self.rare ? 1 : Int(k) + 2
                let extra = k == Self.rare ? rareByFrequency[lexicon.frequency(ofFormAt: form)] : 0
                return Double(logits[output]) + Double(outBias[output]) - state.logZ + extra
            }
        }
    }

    /// A context word's input id: 3 + k for model word k, else "<unk>" (2).
    private func input(_ word: String) -> Int32 {
        guard let form = lexicon.formID(of: word) else { return 2 }
        let k = data.withUnsafeBytes { LFBinaryFile.u32($0, offsets.formWords + 4 * form) }
        return k == Self.rare ? 2 : Int32(k) + 3
    }

    /// A scored word's output class and the log probability added to it.
    private func score(_ word: String, _ raw: UnsafeRawBufferPointer) -> (Int, Double) {
        if word == WordModelVocabulary.end { return (0, 0) }
        guard let form = lexicon.formID(of: word) else { return (1, logUnknown) }
        let k = LFBinaryFile.u32(raw, offsets.formWords + 4 * form)
        if k != Self.rare { return (Int(k) + 2, 0) }
        return (1, rareByFrequency[lexicon.frequency(ofFormAt: form)])
    }

    // MARK: States

    private func state(for key: [Int32]) -> State {
        clock += 1
        if var state = cache[key] {
            state.used = clock
            cache[key] = state
            return state
        }
        var length = key.count - 1
        while length >= 0, cache[Array(key[0 ..< length])] == nil { length -= 1 }
        var state: State
        if length < 0 {
            let zero = [Float](repeating: 0, count: hidden)
            state = step(State(h: zero, c: zero, out: [], logZ: 0, used: 0), input: 0)
            store([], state)
            length = 0
        } else {
            state = cache[Array(key[0 ..< length])]!
        }
        for index in length ..< key.count {
            state = step(state, input: Int(key[index]))
            store(Array(key[0 ... index]), state)
        }
        return state
    }

    private func store(_ key: [Int32], _ state: State) {
        clock += 1
        var state = state
        state.used = clock
        cache[key] = state
        while cache.count > Self.cacheLimit, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key {
            cache[oldest] = nil
        }
    }

    /// One LSTM step on input id `input`, then the read-out and its log normalizer.
    private func step(_ previous: State, input: Int) -> State {
        let e = embed, h = hidden, gates = 4 * hidden, classes = vocabulary + 2
        var state = previous
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            func floats(_ offset: Int) -> UnsafePointer<Float> { base.advanced(by: offset).assumingMemoryBound(to: Float.self) }
            let embedding = floats(offsets.embedding), bias = floats(offsets.bias), outBias = floats(offsets.outBias)
            var z = [Float](repeating: 0, count: gates)
            var recurrent = [Float](repeating: 0, count: gates)
            vDSP_mmul(floats(offsets.wIH), 1, embedding + input * e, 1, &z, 1, vDSP_Length(gates), 1, vDSP_Length(e))
            vDSP_mmul(floats(offsets.wHH), 1, previous.h, 1, &recurrent, 1, vDSP_Length(gates), 1, vDSP_Length(h))
            for j in 0 ..< gates { z[j] = (z[j] + recurrent[j]) + bias[j] }
            for i in 0 ..< h {
                let inputGate = Self.sigmoid(z[i]), forget = Self.sigmoid(z[h + i])
                let cell = tanh(z[2 * h + i]), output = Self.sigmoid(z[3 * h + i])
                state.c[i] = forget * previous.c[i] + inputGate * cell
                state.h[i] = output * tanh(state.c[i])
            }
            var out = [Float](repeating: 0, count: e)
            vDSP_mmul(floats(offsets.proj), 1, state.h, 1, &out, 1, vDSP_Length(e), 1, vDSP_Length(h))
            var logits = [Float](repeating: 0, count: classes)
            vDSP_mmul(embedding + e, 1, out, 1, &logits, 1, vDSP_Length(classes), 1, vDSP_Length(e))
            // logsumexp(logits + out_bias) in Float64, vectorized.
            let count = vDSP_Length(classes)
            var scaled = [Double](repeating: 0, count: classes), readOut = scaled
            vDSP_vspdp(logits, 1, &scaled, 1, count)
            vDSP_vspdp(outBias, 1, &readOut, 1, count)
            vDSP_vaddD(scaled, 1, readOut, 1, &scaled, 1, count)
            var top = 0.0
            vDSP_maxvD(scaled, 1, &top, count)
            var shift = -top
            vDSP_vsaddD(scaled, 1, &shift, &scaled, 1, count)
            var n = Int32(classes)
            vvexp(&scaled, scaled, &n)
            var sum = 0.0
            vDSP_sveD(scaled, 1, &sum, count)
            state.out = out
            state.logZ = top + log(sum)
        }
        return state
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }
}
