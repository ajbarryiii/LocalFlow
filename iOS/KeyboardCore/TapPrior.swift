import Accelerate
import Foundation

/// A tap GRU: the "LFTP" version 1 file of localflow-swipe `tap/export_ios.py` (ARCHITECTURE.md, "Soft
/// key edges"). Little-endian:
///
///     "LFTP"  u32 version (1)  u32 embed  u32 hidden  u32 context_length  u32 inputs (33)  u32 outputs (31)
///     f32 temperature
///     f32 arrays, row-major: embedding [inputs][embed] (row 0, padding, unused), w_ih [3 hidden][embed],
///     w_hh [3 hidden][hidden], b_ih [3 hidden], b_hh [3 hidden], w_out [outputs][hidden], b_out [outputs]
///
/// Gates are PyTorch's, in r, z, n order: r = σ(W_ir x + b_ir + W_hr h + b_hr), z likewise,
/// n = tanh(W_in x + b_in + r ⊙ (W_hn h + b_hn)), h' = (1 − z) ⊙ n + z ⊙ h, from h = 0. Inputs are symbol
/// ids 1...31 (`TapPrior.symbols`) and BOS (32); output j is the logit of symbol id j + 1. Float32 as in
/// the reference. Immutable after loading, so it is shared unchecked.
final class TapModel: @unchecked Sendable {
    enum FormatError: Error, Equatable {
        case badMagic
        case unsupportedVersion
        /// Inputs or outputs other than 33 and 31, or sizes out of range.
        case unsupportedShape
        /// The data's length disagrees with the header's sizes.
        case wrongSize
        /// A weight or the temperature is not finite (or the temperature not positive).
        case invalidValues
    }

    static let version: UInt32 = 1
    static let inputs = 33
    static let outputs = 31
    static let bos = 32
    /// Accepted sizes; the bundled models are far smaller.
    static let sizeRange = 1 ... 4_096

    let embed: Int
    let hidden: Int
    /// A context at least this long is read as its last `contextLength` symbols from a zero state.
    let contextLength: Int
    let temperature: Float

    /// W_ih · E[id] + b_ih for every input id, [inputs][3 hidden].
    private let inputProjections: [Float]
    private let wHH: [Float]
    private let bHH: [Float]
    /// The read-out rows of the OUTPUT symbols only (ids 1...27, a–z and space), [27][hidden].
    private let wOut: [Float]
    private let bOut: [Float]

    init(data: Data) throws {
        guard data.count >= 4 else { throw FormatError.wrongSize }
        guard data.prefix(4).elementsEqual("LFTP".utf8) else { throw FormatError.badMagic }
        guard data.count >= 32 else { throw FormatError.wrongSize }
        let floats: [Float] = data.withUnsafeBytes { raw in
            stride(from: 28, to: raw.count - raw.count % 4, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        let header: [Int] = data.withUnsafeBytes { raw in
            (0 ..< 6).map { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 + 4 * $0, as: UInt32.self))) }
        }
        guard header[0] == Self.version else { throw FormatError.unsupportedVersion }
        let embed = header[1], hidden = header[2], contextLength = header[3]
        guard header[4] == Self.inputs, header[5] == Self.outputs, Self.sizeRange.contains(embed),
              Self.sizeRange.contains(hidden), Self.sizeRange.contains(contextLength) else {
            throw FormatError.unsupportedShape
        }
        let gates = 3 * hidden
        let sizes = [Self.inputs * embed, gates * embed, gates * hidden, gates, gates, Self.outputs * hidden, Self.outputs]
        guard data.count == 32 + 4 * sizes.reduce(0, +) else { throw FormatError.wrongSize }
        // floats[0] is the temperature; the arrays follow.
        guard floats.allSatisfy(\.isFinite), floats[0] > 0 else { throw FormatError.invalidValues }
        var offset = 1
        func take(_ count: Int) -> ArraySlice<Float> {
            defer { offset += count }
            return floats[offset ..< offset + count]
        }
        let embedding = Array(take(sizes[0])), wIH = Array(take(sizes[1]))
        let wHH = Array(take(sizes[2])), bIH = Array(take(sizes[3])), bHH = Array(take(sizes[4]))
        let wOut = Array(take(sizes[5])), bOut = Array(take(sizes[6]))

        var projections = [Float](repeating: 0, count: Self.inputs * gates)
        for id in 0 ..< Self.inputs {
            for row in 0 ..< gates {
                var sum: Float = 0
                for column in 0 ..< embed { sum += wIH[row * embed + column] * embedding[id * embed + column] }
                projections[id * gates + row] = sum + bIH[row]
            }
        }
        self.embed = embed
        self.hidden = hidden
        self.contextLength = contextLength
        temperature = floats[0]
        inputProjections = projections
        self.wHH = wHH
        self.bHH = bHH
        self.wOut = Array(wOut[0 ..< TapPrior.output.count * hidden])
        self.bOut = Array(bOut[0 ..< TapPrior.output.count])
    }

    /// Reads a model file. Call off the main thread.
    static func load(from url: URL) throws -> TapModel {
        try TapModel(data: Data(contentsOf: url))
    }

    /// A zero state.
    var initialState: [Float] { [Float](repeating: 0, count: hidden) }

    /// One GRU step on input id `symbol` (1...32), in place. `scratch` holds W_hh · h.
    func step(_ state: inout [Float], symbol: Int, scratch: inout [Float]) {
        let h = hidden
        state.withUnsafeBufferPointer { hPointer in
            scratch.withUnsafeMutableBufferPointer { out in
                vDSP_mmul(wHH, 1, hPointer.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(3 * h), 1, vDSP_Length(h))
            }
        }
        let x = symbol * 3 * h
        for i in 0 ..< h {
            let r = Self.sigmoid(inputProjections[x + i] + (scratch[i] + bHH[i]))
            let z = Self.sigmoid(inputProjections[x + h + i] + (scratch[h + i] + bHH[h + i]))
            let n = tanh(inputProjections[x + 2 * h + i] + r * (scratch[2 * h + i] + bHH[2 * h + i]))
            state[i] = (1 - z) * n + z * state[i]
        }
    }

    /// log_softmax(logits / temperature) over the OUTPUT symbols, from a state.
    func logProbs(_ state: [Float]) -> [Double] {
        let count = TapPrior.output.count
        var logits = [Float](repeating: 0, count: count)
        state.withUnsafeBufferPointer { hPointer in
            logits.withUnsafeMutableBufferPointer { out in
                vDSP_mmul(wOut, 1, hPointer.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(count), 1, vDSP_Length(hidden))
            }
        }
        let scaled = (0 ..< count).map { Double((logits[$0] + bOut[$0]) / temperature) }
        let top = scaled.max() ?? 0
        let logSum = top + log(scaled.reduce(0) { $0 + exp($1 - top) })
        return scaled.map { $0 - logSum }
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }
}

/// The tap prior (ARCHITECTURE.md, "Soft key edges"): from the text before the cursor, the log
/// probabilities of the next letter or space, and the recent surprise. Reference: localflow-swipe
/// `tap/neural.py`, `tap/alphabet.py` and `keyboard_prior` in `tap/export_ios.py`.
///
/// - A normalized context shorter than the model's `contextLength` is read as BOS then the context, so
///   one run gives every prefix's output; a longer one as its last `contextLength` symbols from a zero
///   state.
/// - Log probabilities (and, for BOS runs, the state) are cached in memory by normalized prefix, at
///   most `cacheLimit` entries, least recently used out first: a typical tap costs one GRU step. Results
///   are the same as from a cold cache.
/// - Main thread only. The context, its normalized form, the cache and the predictions stay in memory;
///   `clear()` drops them. Nothing here logs, stores or sends them.
struct TapPrior {
    /// The context alphabet: ids 1...31 in this order; BOS is 32.
    static let symbols = Array("abcdefghijklmnopqrstuvwxyz '0.#".unicodeScalars)
    /// The prior's columns: a–z and space.
    static let output = Array("abcdefghijklmnopqrstuvwxyz ".unicodeScalars)
    static let cacheLimit = 64

    let model: TapModel
    /// How many of the context's last letters and spaces the recent surprise averages.
    let surpriseWindow: Int

    private struct Entry {
        var logProbs: [Double]
        /// The state after the prefix, for BOS runs (to continue from); nil for windows.
        var state: [Float]?
        var used: Int
    }

    private var cache: [String: Entry] = [:]
    private var clock = 0
    private var scratch: [Float]

    init(model: TapModel, surpriseWindow: Int = 8) {
        self.model = model
        self.surpriseWindow = max(surpriseWindow, 0)
        scratch = [Float](repeating: 0, count: 3 * model.hidden)
    }

    /// How many prefixes are cached (at most `cacheLimit`).
    var cachedCount: Int { cache.count }

    /// Drops the cache: on hiding and on a field change.
    mutating func clear() {
        cache = [:]
        clock = 0
    }

    /// Log probabilities over `output` (a–z, space) of the character after `context`, the raw text before
    /// the cursor.
    mutating func logProbs(context: String) -> [Double] {
        prediction(context: context).logProbs
    }

    /// The mean, over the normalized context's last `surpriseWindow` letters and spaces, of
    /// −log2 P(that character | the context before it); 0 when there are none.
    mutating func recentSurprise(context: String) -> Double {
        prediction(context: context).surprise
    }

    /// Both at once, from one normalization and one batch of runs.
    mutating func prediction(context text: String) -> (logProbs: [Double], surprise: Double) {
        let context = Self.normalizeContext(text)
        let ids = context.unicodeScalars.map { scalar in Self.symbols.firstIndex(of: scalar).map { $0 + 1 } ?? 31 }
        let taps = ids.indices.filter { ids[$0] <= Self.output.count }.suffix(surpriseWindow)
        let rows = logProbs(ids: ids, prefixes: [ids.count] + taps)
        guard !taps.isEmpty else { return (rows[0], 0) }
        var bits = 0.0
        for (row, index) in zip(rows.dropFirst(), taps) { bits += -row[ids[index] - 1] / log(2.0) }
        return (rows[0], bits / Double(taps.count))
    }

    // MARK: Runs

    /// The rows for the given prefix lengths of `ids`, in that order.
    private mutating func logProbs(ids: [Int], prefixes: [Int]) -> [[Double]] {
        let n = model.contextLength
        var rows: [Int: [Double]] = [:]
        // Windows: each its own run from a zero state.
        for length in Set(prefixes) where length >= n {
            let window = Array(ids[length - n ..< length])
            let key = Self.key(window)
            if let entry = lookUp(key) {
                rows[length] = entry.logProbs
                continue
            }
            var state = model.initialState
            for symbol in window { model.step(&state, symbol: symbol, scratch: &scratch) }
            let logProbs = model.logProbs(state)
            store(key, Entry(logProbs: logProbs, state: nil, used: 0))
            rows[length] = logProbs
        }
        // Message starts: one run from BOS (or the longest cached prefix) through every requested prefix.
        var current: (length: Int, state: [Float])?
        for length in Set(prefixes).filter({ $0 < n }).sorted() {
            let key = Self.key(ids[0 ..< length])
            if let entry = lookUp(key), let state = entry.state {
                rows[length] = entry.logProbs
                current = (length, state)
                continue
            }
            var (position, state) = current.map { ($0.length, $0.state) } ?? start(before: length, ids: ids)
            while position < length {
                model.step(&state, symbol: ids[position], scratch: &scratch)
                position += 1
            }
            let logProbs = model.logProbs(state)
            store(key, Entry(logProbs: logProbs, state: state, used: 0))
            rows[length] = logProbs
            current = (length, state)
        }
        return prefixes.map { rows[$0] ?? [] }
    }

    /// The longest cached message-start prefix shorter than `length`, or the state after BOS.
    private mutating func start(before length: Int, ids: [Int]) -> (Int, [Float]) {
        for shorter in stride(from: length - 1, through: 0, by: -1) {
            if let state = lookUp(Self.key(ids[0 ..< shorter]))?.state { return (shorter, state) }
        }
        var state = model.initialState
        model.step(&state, symbol: TapModel.bos, scratch: &scratch)
        return (0, state)
    }

    private mutating func lookUp(_ key: String) -> Entry? {
        guard var entry = cache[key] else { return nil }
        clock += 1
        entry.used = clock
        cache[key] = entry
        return entry
    }

    private mutating func store(_ key: String, _ entry: Entry) {
        clock += 1
        var entry = entry
        entry.used = clock
        cache[key] = entry
        while cache.count > Self.cacheLimit, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key {
            cache[oldest] = nil
        }
    }

    /// Normalized text again: a context shorter than the model's length and a window never collide, as a
    /// window is exactly that long.
    private static func key<C: Collection>(_ ids: C) -> String where C.Element == Int {
        String(String.UnicodeScalarView(ids.map { symbols[$0 - 1] }))
    }

    // MARK: Normalization

    /// What the prior sees, from the text before the cursor (`normalize_context`): only the current line
    /// (after the last line break); accents dropped (NFKD, combining marks removed), lowercased, curly
    /// apostrophes and backticks as "'"; a–z, space and "'" kept, digits as "0", `. ! ?` as ".", anything
    /// else as "#"; whitespace runs as one space, leading whitespace dropped, trailing whitespace kept as
    /// one space.
    static func normalizeContext(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let start = scalars.lastIndex(where: isLineBreak).map { $0 + 1 } ?? 0
        let line = scalars[start...]
        let decomposed = String(String.UnicodeScalarView(line)).decomposedStringWithCompatibilityMapping
        var folded = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where scalar.properties.canonicalCombiningClass == .notReordered {
            for lower in scalar.properties.lowercaseMapping.unicodeScalars { folded.append(symbol(lower)) }
        }
        let words = String(folded).split(separator: " ")
        let joined = words.joined(separator: " ")
        if !joined.isEmpty, let last = line.last, isSpace(last) { return joined + " " }
        return joined
    }

    private static func symbol(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{2019}", "\u{2018}", "`", "\u{2BC}", "'": return "'"
        case "a" ... "z": return scalar
        case ".", "!", "?": return "."
        default:
            if isSpace(scalar) { return " " }
            if let type = scalar.properties.numericType, type == .decimal || type == .digit { return "0" }
            return "#"
        }
    }

    /// Python's line breaks for `normalize_context`: \r\n, \n, \r, U+2028, U+2029, U+0085.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"].contains(scalar)
    }

    /// Python's `str.isspace`: general category Zs, or bidirectional class WS, B or S.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09 ... 0x0D, 0x1C ... 0x20, 0x85, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}
