import CryptoKit
import Foundation

/// Writers of the word files (LFWL, LFWN, LFWR; localflow-swipe `tap/export_word_ios.py`) for invented test
/// lexicons and models, so tests can build small ones. The lexicon writer follows `lexicon_bytes` and
/// `tap.words.WordLexicon`'s rules.
enum AutocorrectTestFiles {
    struct Writer {
        private(set) var bytes = Data()

        init(magic: String) { bytes.append(contentsOf: Array(magic.utf8)) }

        mutating func u32(_ value: Int) { append(UInt32(value).littleEndian) }
        mutating func u64(_ value: UInt64) { append(value.littleEndian) }
        mutating func f64(_ value: Double) { append(value.bitPattern.littleEndian) }
        mutating func raw(_ data: Data) { bytes.append(data) }

        /// A section: values then zero padding to a multiple of 8.
        mutating func u8s(_ values: [UInt8]) { bytes.append(contentsOf: values); pad() }
        mutating func u32s(_ values: [Int]) { for value in values { u32(value) }; pad() }
        mutating func u64s(_ values: [UInt64]) { for value in values { u64(value) }; pad() }
        mutating func f32s(_ values: [Float]) { for value in values { append(value.bitPattern.littleEndian) }; pad() }

        private mutating func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
        }

        private mutating func pad() {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: (8 - bytes.count % 8) % 8))
        }
    }

    /// The display forms of entries as `tap.words.WordLexicon` keeps them: lowercased, a–z and apostrophes
    /// with a letter and no leading or trailing apostrophe, merged keeping the highest frequency.
    static func forms(_ entries: [(String, Int)]) -> [String: Int] {
        var forms: [String: Int] = [:]
        for (word, frequency) in entries {
            let form = word.lowercased()
            guard form.utf8.allSatisfy({ (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0) || $0 == UInt8(ascii: "'") }),
                  form.utf8.contains(where: { $0 != UInt8(ascii: "'") }), form.first != "'", form.last != "'" else { continue }
            forms[form] = max(frequency, forms[form] ?? frequency)
        }
        return forms
    }

    static func sortedForms(_ forms: [String: Int]) -> [String] {
        forms.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func hash(_ sorted: [String]) -> Data {
        Data(SHA256.hash(data: Data(sorted.joined(separator: "\n").utf8)))
    }

    /// An LFWL file for the entries.
    static func lexicon(_ entries: [(String, Int)], beta: Double = 8 * log(10.0) / 255, unknownMass: Double = 0.05) -> Data {
        let freqs = forms(entries)
        let sorted = sortedForms(freqs)
        let index = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
        var byKey: [String: [String]] = [:]
        for form in sorted { byKey[Autocorrector.key(of: form), default: []].append(form) }
        for key in byKey.keys {
            byKey[key]!.sort { a, b in freqs[a]! != freqs[b]! ? freqs[a]! > freqs[b]! : a.utf8.lexicographicallyPrecedes(b.utf8) }
        }
        var prefixSet: Set<String> = [""]
        for key in byKey.keys { for d in 1 ... key.count { prefixSet.insert(String(key.prefix(d))) } }
        let prefixes = prefixSet.sorted { a, b in a.count != b.count ? a.count < b.count : a.utf8.lexicographicallyPrecedes(b.utf8) }
        let node = Dictionary(uniqueKeysWithValues: prefixes.enumerated().map { ($1, $0) })
        let m = prefixes.count
        let parents = prefixes.dropFirst().map { node[String($0.dropLast())]! }
        // node_edges[n]: how many non-root prefixes have a parent before n (parents are non-decreasing).
        var nodeEdges = [Int](repeating: 0, count: m + 1)
        for parent in parents { nodeEdges[parent + 1] += 1 }
        for n in 0 ..< m { nodeEdges[n + 1] += nodeEdges[n] }
        let letters = prefixes.dropFirst().map { $0.utf8.last! }
        var nodeForms = [0], formList: [Int] = []
        for prefix in prefixes {
            formList += (byKey[prefix] ?? []).map { index[$0]! }
            nodeForms.append(formList.count)
        }
        let text = sorted.flatMap { Array($0.utf8) }
        var offsets = [0]
        for form in sorted { offsets.append(offsets.last! + form.utf8.count) }
        var w = Writer(magic: "LFWL")
        for value in [1, sorted.count, m, m - 1, text.count, byKey.keys.map(\.count).max() ?? 0, 0] { w.u32(value) }
        w.f64(beta)
        w.f64(unknownMass)
        w.raw(hash(sorted))
        w.u32s(offsets)
        w.u8s(sorted.map { UInt8(freqs[$0]!) })
        w.u8s(text)
        w.u32s(nodeEdges)
        w.u8s(letters)
        w.u32s(Array(1 ..< max(m, 1)))
        w.u32s(nodeForms)
        w.u32s(formList)
        return w.bytes
    }

    /// An order-n LFWN file. `tables` per order k = 2 ... n: (discount, contexts as (code, total, gamma),
    /// n-grams as (code, count)), each sorted by code.
    static func ngram(forms sorted: [String], order: Int, bits: Int, p1: [Float],
                      tables: [(discount: Double, contexts: [(UInt64, Float, Float)], grams: [(UInt64, Float)])]) -> Data {
        var w = Writer(magic: "LFWN")
        for value in [1, order, bits, sorted.count + 4, 0] { w.u32(value) }
        w.f64(0.1)
        w.f64(8 * log(10.0) / 255)
        w.raw(hash(sorted))
        for table in tables {
            w.u64(UInt64(table.contexts.count))
            w.u64(UInt64(table.grams.count))
            w.f64(table.discount)
        }
        w.f32s(p1)
        for table in tables {
            w.u64s(table.contexts.map(\.0))
            w.f32s(table.contexts.map(\.1))
            w.f32s(table.contexts.map(\.2))
            w.u64s(table.grams.map(\.0))
            w.f32s(table.grams.map(\.1))
        }
        return w.bytes
    }

    /// An LFWR file with seeded random weights: model words are the given form ids.
    static func lstm(forms sorted: [String], freqs: [Int], words: [Int], embed: Int, hidden: Int, u: Double,
                     beta: Double = 8 * log(10.0) / 255, seed: UInt64) -> Data {
        var random = SplitMix64(seed: seed)
        func weights(_ count: Int) -> [Float] { (0 ..< count).map { _ in Float.random(in: -1 ... 1, using: &random) } }
        let modelWords = Set(words)
        let rare = sorted.indices.filter { !modelWords.contains($0) }
        var logZRare = 0.0
        if !rare.isEmpty {
            let x = rare.map { beta * Double(freqs[$0]) }
            let top = x.max()!
            logZRare = top + log(x.map { exp($0 - top) }.reduce(0, +))
        }
        var formWords = [Int](repeating: 0xFFFF_FFFF, count: sorted.count)
        for (k, form) in words.enumerated() { formWords[form] = k }
        let v = words.count
        var w = Writer(magic: "LFWR")
        for value in [1, embed, hidden, v, sorted.count] { w.u32(value) }
        w.f64(u)
        w.f64(beta)
        w.f64(logZRare)
        w.raw(hash(sorted))
        w.u32s(words)
        w.u32s(formWords)
        w.f32s(weights((v + 3) * embed))
        w.f32s(weights(4 * hidden * embed))
        w.f32s(weights(4 * hidden * hidden))
        w.f32s(weights(4 * hidden))
        w.f32s(weights(embed * hidden))
        w.f32s(weights(v + 2))
        return w.bytes
    }
}
