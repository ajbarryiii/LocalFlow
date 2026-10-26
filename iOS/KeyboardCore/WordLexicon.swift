import CryptoKit
import Foundation

/// Why a word file (LFWL, LFWN or LFWR) was rejected.
enum WordFileError: LFBinaryFileError, Equatable {
    case badMagic
    case unsupportedVersion
    /// The data's length disagrees with the header's sizes (truncated, trailing bytes).
    case wrongSize
    /// Sizes out of range (zero, too large, inconsistent with each other).
    case unsupportedShape
    /// Offsets, ordering, ids or the trie are inconsistent.
    case invalidStructure
    /// A number is not finite or outside its domain.
    case invalidValues
    /// A model file made for another lexicon (its hash or form count differs), or a lexicon whose forms do
    /// not hash to its header's hash.
    case lexiconMismatch
}

/// Lays out the sections of a word file (`LFBinaryFile`): a header that is a multiple of 8 bytes, then sections
/// in order, each starting at a multiple of 8 and padded with zeros to one; the file ends right after the
/// last section's padding.
struct WordFileSections {
    private(set) var end: Int

    init(header: Int) { end = header }

    /// The next section's offset, for `count` elements of `size` bytes.
    mutating func next(count: Int, size: Int) throws -> Int {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: size)
        guard count >= 0, !overflow, bytes <= Int(UInt32.max) * 8 else { throw WordFileError.unsupportedShape }
        let offset = end
        end += (bytes + 7) / 8 * 8
        return offset
    }
}

/// The autocorrect lexicon: the "LFWL" version 1 file of localflow-swipe `tap/export_word_ios.py`
/// (ARCHITECTURE.md, "Word autocorrect"), read in place from a mapped file with no per-entry objects.
///
///     "LFWL"  u32 version (1)  u32 N forms  u32 M trie nodes  u32 edges (M − 1)  u32 T text bytes
///     u32 longest key  u32 0  f64 W0 beta  f64 W0 unk mass  32 bytes lexicon hash
///     sections (each 8-aligned): form_offsets u32[N + 1], form_freqs u8[N], text u8[T],
///     node_edges u32[M + 1], edge_letters u8[M − 1], edge_children u32[M − 1], node_forms u32[M + 1],
///     form_list u32[N]
///
/// - Form id f is the index of a display form ("don't", "london") in the forms sorted by code point; a
///   form's key is its letters (apostrophes removed), non-empty a–z.
/// - The trie spells every key from the root (node 0); nodes are numbered breadth first, children in
///   letter order, so edge e leads to node e + 1. A node's forms are its key's forms by frequency (highest
///   first), then code point order.
/// - The hash is the SHA-256 of the sorted forms joined by "\n"; word model files carry it.
///
/// The initializer validates the whole structure (and the hash), so readers never go out of bounds.
/// Immutable after loading, so it is shared unchecked.
final class WordLexicon: @unchecked Sendable {
    static let version: UInt32 = 1
    static let headerSize = 80

    /// Display forms.
    let formCount: Int
    let nodeCount: Int
    /// Keys: nodes with forms.
    let keyCount: Int
    /// The longest key's length in letters.
    let longestKey: Int
    /// W0 (`UnigramWordModel`): the AOSP prior's exponent per frequency step and the "<unk>" mass.
    let unigramBeta: Double
    let unigramUnknownMass: Double
    /// SHA-256 of the sorted forms joined by "\n".
    let hash: Data

    private let data: Data
    private let offsets: Offsets

    private struct Offsets {
        var formOffsets = 0, formFreqs = 0, text = 0, nodeEdges = 0, edgeLetters = 0, edgeChildren = 0, nodeForms = 0,
            formList = 0
    }

    init(data input: Data) throws {
        try LFBinaryFile.checkHeader(input, magic: "LFWL", version: Self.version, header: Self.headerSize,
                                     as: WordFileError.self)
        let data = LFBinaryFile.aligned(input)
        let (header, beta, unknownMass, hash) = data.withUnsafeBytes { raw in
            ((2 ..< 8).map { Int(LFBinaryFile.u32(raw, 4 * $0)) }, LFBinaryFile.f64(raw, 32), LFBinaryFile.f64(raw, 40),
             Data(raw[48 ..< 80]))
        }
        let n = header[0], m = header[1], edges = header[2], textBytes = header[3], longest = header[4]
        guard m >= 1, edges == m - 1, header[5] == 0 else { throw WordFileError.unsupportedShape }
        var sections = WordFileSections(header: Self.headerSize)
        var offsets = Offsets()
        offsets.formOffsets = try sections.next(count: n + 1, size: 4)
        offsets.formFreqs = try sections.next(count: n, size: 1)
        offsets.text = try sections.next(count: textBytes, size: 1)
        offsets.nodeEdges = try sections.next(count: m + 1, size: 4)
        offsets.edgeLetters = try sections.next(count: edges, size: 1)
        offsets.edgeChildren = try sections.next(count: edges, size: 4)
        offsets.nodeForms = try sections.next(count: m + 1, size: 4)
        offsets.formList = try sections.next(count: n, size: 4)
        guard sections.end == data.count else { throw WordFileError.wrongSize }
        guard beta.isFinite, beta >= 0, unknownMass > 0, unknownMass < 1 else { throw WordFileError.invalidValues }

        let keys = try data.withUnsafeBytes { raw in
            try View(raw: raw, offsets: offsets, forms: n, nodes: m).validate(textBytes: textBytes, longest: longest)
        }
        // The hash covers the forms joined by "\n".
        var hasher = SHA256()
        data.withUnsafeBytes { raw in
            let view = View(raw: raw, offsets: offsets, forms: n, nodes: m)
            for form in 0 ..< n {
                if form > 0 { hasher.update(data: [0x0A]) }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[view.textRange(form)]))
            }
        }
        guard Data(hasher.finalize()) == hash else { throw WordFileError.lexiconMismatch }
        self.data = data
        self.offsets = offsets
        formCount = n
        nodeCount = m
        keyCount = keys
        longestKey = longest
        unigramBeta = beta
        unigramUnknownMass = unknownMass
        self.hash = hash
    }

    /// Maps a lexicon file. Call off the main thread.
    static func load(from url: URL) throws -> WordLexicon {
        try WordLexicon(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    // MARK: Forms

    func form(at id: Int) -> String {
        withView { view in String(decoding: UnsafeRawBufferPointer(rebasing: view.raw[view.textRange(id)]), as: UTF8.self) }
    }

    /// The AOSP frequency (0–255) of form `id`.
    func frequency(ofFormAt id: Int) -> Int {
        withView { Int($0.raw[offsets.formFreqs + id]) }
    }

    /// The id of a display form, by binary search over the sorted forms; nil when it is not one.
    func formID(of form: String) -> Int? {
        var form = form
        return form.withUTF8 { bytes in
            withView { view in
                var lo = 0, hi = formCount
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let other = UnsafeRawBufferPointer(rebasing: view.raw[view.textRange(mid)])
                    if other.lexicographicallyPrecedes(bytes) {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }
                guard lo < formCount, view.raw[view.textRange(lo)].elementsEqual(bytes) else { return nil }
                return lo
            }
        }
    }

    func contains(_ form: String) -> Bool { formID(of: form) != nil }

    func frequency(of form: String) -> Int? { formID(of: form).map(frequency(ofFormAt:)) }

    /// The ids of a key's forms (a node's), by frequency, highest first, then code point order.
    func formIDs(ofNode node: Int) -> [Int] {
        withView { view in view.formRange(node).map { Int(LFBinaryFile.u32(view.raw, offsets.formList + 4 * $0)) } }
    }

    /// The display forms of a key (its letters), as `formIDs(ofNode:)` orders them; empty for any other text.
    func forms(ofKey key: String) -> [String] {
        guard let node = node(ofKey: key) else { return [] }
        return formIDs(ofNode: node).map(form(at:))
    }

    /// The trie node that spells `key`, if any.
    func node(ofKey key: String) -> Int? {
        withView { view in
            var node = 0
            for byte in key.utf8 {
                guard let child = view.child(of: node, letter: byte) else { return nil }
                node = child
            }
            return node
        }
    }

    /// The AOSP prior by frequency (`tap.wordlm` `_Vocab.aosp`): P(f) = w(f) / Σ over every form g of
    /// w(freq g), w(f) = exp(beta (f − the highest frequency)), summed as numpy does.
    func aospPrior(beta: Double) -> [Double] {
        let top = Double((0 ..< formCount).map(frequency(ofFormAt:)).max() ?? 0)
        let weights = (0 ... 255).map { exp(beta * (Double($0) - top)) }
        let total = Autocorrector.pairwiseSum((0 ..< formCount).map { weights[frequency(ofFormAt: $0)] })
        return weights.map { $0 / total }
    }

    // MARK: Candidates

    /// Every key within optimal-string-alignment distance `limit` (Levenshtein plus adjacent transpositions,
    /// no substring edited twice) of the typed letter codes (0...25), in key order, with its node and letter
    /// codes: a depth-first walk with one distance column per node, pruned where the column's minimum exceeds
    /// the limit (exact: no descendant can come back under it).
    ///
    /// Distances are capped at limit + 1, which keeps every comparison with the limit exact (the cap commutes
    /// with min and with adding), and only the band of cells within `limit` of the diagonal is computed: a
    /// cell further off it is at least its distance from the diagonal, so always the cap.
    func keys(within limit: Int, of codes: [Int]) -> [(node: Int, codes: [Int])] {
        let n = codes.count, width = n + 1
        let limit = min(limit, n + longestKey)
        let depth = min(longestKey, n + limit)
        guard limit >= 0, depth >= 1 else { return [] }
        let cap = Int32(limit + 1), band = Int32(limit)
        var found: [(node: Int, codes: [Int])] = []
        // Plain pointers and comparisons throughout: this loop runs for every node the walk visits, and the
        // keyboard may be built without optimization.
        let rows = depth + 1
        let columns = UnsafeMutablePointer<Int32>.allocate(capacity: rows * width)
        columns.initialize(repeating: cap, count: rows * width)
        let path = UnsafeMutablePointer<Int32>.allocate(capacity: rows)
        path.initialize(repeating: -1, count: rows)
        let cursor = UnsafeMutablePointer<Int>.allocate(capacity: rows), end = UnsafeMutablePointer<Int>.allocate(capacity: rows)
        cursor.initialize(repeating: 0, count: rows)
        end.initialize(repeating: 0, count: rows)
        let typed = UnsafeMutablePointer<Int32>.allocate(capacity: max(n, 1))
        for i in 0 ..< n { typed[i] = Int32(codes[i]) }
        defer {
            columns.deallocate()
            path.deallocate()
            cursor.deallocate()
            end.deallocate()
            typed.deallocate()
        }
        for i in 0 ... n { columns[i] = Int32(i) < cap ? Int32(i) : cap }
        let n32 = Int32(n)
        data.withUnsafeBytes { raw in
            // Sections are 8-aligned in 8-aligned data; the host is little-endian (every Apple platform).
            let base = raw.baseAddress!
            let nodeEdges = base.advanced(by: offsets.nodeEdges).assumingMemoryBound(to: UInt32.self)
            let nodeForms = base.advanced(by: offsets.nodeForms).assumingMemoryBound(to: UInt32.self)
            let edgeLetters = base.advanced(by: offsets.edgeLetters).assumingMemoryBound(to: UInt8.self)
            cursor[1] = Int(nodeEdges[0])
            end[1] = Int(nodeEdges[1])
            var d = 1
            while d >= 1 {
                if cursor[d] >= end[d] {
                    d -= 1
                    continue
                }
                let edge = cursor[d]
                cursor[d] = edge + 1
                let c = Int32(edgeLetters[edge]) &- 97
                let child = edge + 1
                let up = columns + (d - 1) * width, current = columns + d * width
                let grand = d >= 2 ? columns + (d - 2) * width : columns
                let parent: Int32 = d >= 2 ? path[d - 1] : -1
                let d32 = Int32(d)
                current[0] = d32 < cap ? d32 : cap
                var smallest = current[0]
                let lo = d32 - band > 1 ? d32 - band : 1, hi = d32 + band < n32 ? d32 + band : n32
                var i = lo
                while i <= hi {
                    let k = Int(i)
                    var value = up[k - 1] + (typed[k - 1] == c ? 0 : 1)
                    let deleted = up[k] + 1, inserted = current[k - 1] + 1
                    if deleted < value { value = deleted }
                    if inserted < value { value = inserted }
                    if k >= 2, parent >= 0, parent != c, typed[k - 1] == parent, typed[k - 2] == c {
                        let swapped = grand[k - 2] + 1
                        if swapped < value { value = swapped }
                    }
                    if value > cap { value = cap }
                    current[k] = value
                    if value < smallest { smallest = value }
                    i += 1
                }
                path[d] = c
                if current[n] <= band, nodeForms[child] < nodeForms[child + 1] {
                    found.append((child, (1 ... d).map { Int(path[$0]) }))
                }
                if d < depth, smallest <= band {
                    d += 1
                    cursor[d] = Int(nodeEdges[child])
                    end[d] = Int(nodeEdges[child + 1])
                }
            }
        }
        return found
    }

    // MARK: Reading

    private func withView<R>(_ body: (View) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in try body(View(raw: raw, offsets: offsets, forms: formCount, nodes: nodeCount)) }
    }

    private struct View {
        let raw: UnsafeRawBufferPointer
        let offsets: Offsets
        let forms: Int
        let nodes: Int

        func u32(_ offset: Int, _ index: Int) -> Int { Int(LFBinaryFile.u32(raw, offset + 4 * index)) }

        func textRange(_ form: Int) -> Range<Int> {
            offsets.text + u32(offsets.formOffsets, form) ..< offsets.text + u32(offsets.formOffsets, form + 1)
        }

        func edgeRange(_ node: Int) -> Range<Int> { u32(offsets.nodeEdges, node) ..< u32(offsets.nodeEdges, node + 1) }

        func formRange(_ node: Int) -> Range<Int> { u32(offsets.nodeForms, node) ..< u32(offsets.nodeForms, node + 1) }

        func child(of node: Int, letter: UInt8) -> Int? {
            var lo = u32(offsets.nodeEdges, node), hi = u32(offsets.nodeEdges, node + 1)
            while lo < hi {
                let mid = (lo + hi) / 2, found = raw[offsets.edgeLetters + mid]
                if found == letter { return mid + 1 }
                if found < letter { lo = mid + 1 } else { hi = mid }
            }
            return nil
        }

        /// Validates everything a reader relies on; returns the number of keys.
        func validate(textBytes: Int, longest: Int) throws -> Int {
            // Forms: offsets from 0 to T, non-empty a–z and "'" with a letter, strictly increasing.
            guard u32(offsets.formOffsets, 0) == 0, u32(offsets.formOffsets, forms) == textBytes else {
                throw WordFileError.invalidStructure
            }
            var longestFound = 0
            for form in 0 ..< forms {
                let start = u32(offsets.formOffsets, form), end = u32(offsets.formOffsets, form + 1)
                guard start < end, end <= textBytes else { throw WordFileError.invalidStructure }
                var letters = 0
                for byte in raw[offsets.text + start ..< offsets.text + end] {
                    if (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) {
                        letters += 1
                    } else if byte != UInt8(ascii: "'") {
                        throw WordFileError.invalidStructure
                    }
                }
                guard letters > 0 else { throw WordFileError.invalidStructure }
                longestFound = max(longestFound, letters)
                if form > 0 {
                    guard raw[textRange(form - 1)].lexicographicallyPrecedes(raw[textRange(form)]) else {
                        throw WordFileError.invalidStructure
                    }
                }
            }
            guard longest == longestFound else { throw WordFileError.invalidStructure }
            // The trie: breadth first, edge e to node e + 1, letters strictly increasing within a node.
            guard u32(offsets.nodeEdges, 0) == 0, u32(offsets.nodeEdges, nodes) == nodes - 1,
                  u32(offsets.nodeForms, 0) == 0, u32(offsets.nodeForms, 1) == 0, u32(offsets.nodeForms, nodes) == forms else {
                throw WordFileError.invalidStructure
            }
            var keys = 0
            for node in 0 ..< nodes {
                // The integers first: a range of decreasing bounds would trap.
                let edgeStart = u32(offsets.nodeEdges, node), edgeEnd = u32(offsets.nodeEdges, node + 1)
                let listStart = u32(offsets.nodeForms, node), listEnd = u32(offsets.nodeForms, node + 1)
                guard edgeStart <= edgeEnd, edgeEnd <= nodes - 1, listStart <= listEnd, listEnd <= forms else {
                    throw WordFileError.invalidStructure
                }
                let edges = edgeStart ..< edgeEnd, list = listStart ..< listEnd
                // Breadth first: a node's children come after it, and a node without forms has a child.
                guard edges.isEmpty || edges.lowerBound >= node, !(edges.isEmpty && list.isEmpty && node > 0) else {
                    throw WordFileError.invalidStructure
                }
                if !list.isEmpty { keys += 1 }
                var previous: UInt8 = 0
                for edge in edges {
                    let letter = raw[offsets.edgeLetters + edge]
                    guard (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(letter), letter > previous,
                          u32(offsets.edgeChildren, edge) == edge + 1 else { throw WordFileError.invalidStructure }
                    previous = letter
                }
            }
            // Every form once, at its key's node, in frequency then code point order.
            var seen = [Bool](repeating: false, count: forms)
            for node in 1 ..< max(nodes, 1) {
                var previous: Int?
                for index in formRange(node) {
                    let form = u32(offsets.formList, index)
                    guard form < forms, !seen[form] else { throw WordFileError.invalidStructure }
                    seen[form] = true
                    var at = 0
                    for byte in raw[textRange(form)] where byte != UInt8(ascii: "'") {
                        guard let child = child(of: at, letter: byte) else { throw WordFileError.invalidStructure }
                        at = child
                    }
                    guard at == node else { throw WordFileError.invalidStructure }
                    if let previous {
                        let a = Int(raw[offsets.formFreqs + previous]), b = Int(raw[offsets.formFreqs + form])
                        guard a > b || (a == b && previous < form) else { throw WordFileError.invalidStructure }
                    }
                    previous = form
                }
            }
            return keys
        }
    }
}
