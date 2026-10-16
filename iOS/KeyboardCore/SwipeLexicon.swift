import Foundation

/// The swipe lexicon: the binary "LFLX" version 1 trie of `swipe/lexicon_bin.py`, read in place
/// (ARCHITECTURE.md, "Typing model v4 and swipe typing", step 4). All integers are little-endian:
///
///     magic "LFLX", version u32 = 1, node_count N, edge_count E, word_count W, blob_bytes B (u32)
///     edge_start u32[N+1], edge_letter u8[E], edge_child u32[E]
///     word_start u32[N+1], word_freq u8[W], text_start u32[W+1], blob u8[B]
///
/// Node 0 is the root and a node's key is the path of edge letters from it. The initializer
/// validates the whole structure, so readers never go out of bounds.
final class SwipeLexicon: @unchecked Sendable {   // immutable after init
    enum FormatError: Error, Equatable {
        case badMagic
        case unsupportedVersion
        /// The sizes in the header disagree with the data's length (truncated, trailing bytes, no root).
        case wrongSize
        case badEdgeOffsets
        /// An edge letter outside 'a'...'z', or a node's letters not strictly ascending.
        case badLetters
        /// A child index out of range, or edges that do not form a tree under node 0.
        case badChild
        case badWordOffsets
        /// Text offsets that do not start at 0, end at the blob size and strictly increase (no empty words).
        case badTextOffsets
        case invalidUTF8
    }

    static let version: UInt32 = 1

    let nodeCount: Int
    let edgeCount: Int
    let wordCount: Int

    private let data: Data
    private let layout: Layout
    /// Each node's position in a depth-first walk with children in letter order: comparing two
    /// nodes' ranks compares their keys as byte strings.
    private let keyRank: [UInt32]

    init(data: Data) throws {
        guard data.count >= 4 else { throw FormatError.wrongSize }
        let layout = try data.withUnsafeBytes { raw -> Layout in
            guard raw[0] == UInt8(ascii: "L"), raw[1] == UInt8(ascii: "F"), raw[2] == UInt8(ascii: "L"),
                  raw[3] == UInt8(ascii: "X") else { throw FormatError.badMagic }
            guard raw.count >= 24 else { throw FormatError.wrongSize }
            guard Self.u32(raw, 4) == Self.version else { throw FormatError.unsupportedVersion }
            let layout = Layout(nodes: Int(Self.u32(raw, 8)), edges: Int(Self.u32(raw, 12)), words: Int(Self.u32(raw, 16)),
                                blob: Int(Self.u32(raw, 20)))
            guard layout.nodes >= 1, layout.blobStart + layout.blob == raw.count else { throw FormatError.wrongSize }
            return layout
        }
        let rank = try data.withUnsafeBytes { raw -> [UInt32] in
            let view = View(raw: raw, layout: layout)
            try view.validateOffsets()
            let rank = try view.rankTree()
            try view.validateText()
            return rank
        }
        self.data = data
        self.layout = layout
        keyRank = rank
        nodeCount = layout.nodes
        edgeCount = layout.edges
        wordCount = layout.words
    }

    /// Reads the lexicon in place for the duration of `body`.
    func withView<R>(_ body: (View, UnsafeBufferPointer<UInt32>) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in
            try keyRank.withUnsafeBufferPointer { rank in
                try body(View(raw: raw, layout: layout), rank)
            }
        }
    }

    fileprivate static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    struct Layout: Sendable {
        let nodes: Int, edges: Int, words: Int, blob: Int
        var edgeStart: Int { 24 }
        var edgeLetter: Int { edgeStart + 4 * (nodes + 1) }
        var edgeChild: Int { edgeLetter + edges }
        var wordStart: Int { edgeChild + 4 * edges }
        var wordFreq: Int { wordStart + 4 * (nodes + 1) }
        var textStart: Int { wordFreq + words }
        var blobStart: Int { textStart + 4 * (words + 1) }
    }

    /// Unchecked accessors over validated bytes; valid only inside `withView`.
    struct View {
        let raw: UnsafeRawBufferPointer
        let layout: Layout

        /// Entry `index` of an offsets table and the next one, as a range.
        private func range(_ table: Int, _ index: Int) -> Range<Int> {
            Int(SwipeLexicon.u32(raw, table + 4 * index)) ..< Int(SwipeLexicon.u32(raw, table + 4 * index + 4))
        }

        func edges(of node: Int) -> Range<Int> { range(layout.edgeStart, node) }

        /// ASCII 'a'...'z'.
        func letter(_ edge: Int) -> UInt8 { raw[layout.edgeLetter + edge] }

        func child(_ edge: Int) -> Int { Int(SwipeLexicon.u32(raw, layout.edgeChild + 4 * edge)) }

        func words(of node: Int) -> Range<Int> { range(layout.wordStart, node) }

        func frequency(_ word: Int) -> UInt8 { raw[layout.wordFreq + word] }

        /// The word's UTF-8 bytes.
        func text(_ word: Int) -> UnsafeRawBufferPointer {
            let bytes = range(layout.textStart, word)
            return UnsafeRawBufferPointer(rebasing: raw[layout.blobStart + bytes.lowerBound ..< layout.blobStart + bytes.upperBound])
        }

        func string(_ word: Int) -> String { String(decoding: text(word), as: UTF8.self) }

        // MARK: Validation

        /// `table` holds `count + 1` offsets: the first 0, never decreasing, the last `total`.
        private func validOffsets(at table: Int, count: Int, total: Int, strictly: Bool = false) -> Bool {
            guard SwipeLexicon.u32(raw, table) == 0, Int(SwipeLexicon.u32(raw, table + 4 * count)) == total else { return false }
            var previous: UInt32 = 0
            for index in stride(from: 1, through: count, by: 1) {
                let value = SwipeLexicon.u32(raw, table + 4 * index)
                if value < previous || (strictly && value == previous) { return false }
                previous = value
            }
            return true
        }

        fileprivate func validateOffsets() throws {
            guard validOffsets(at: layout.edgeStart, count: layout.nodes, total: layout.edges) else {
                throw FormatError.badEdgeOffsets
            }
            for node in 0 ..< layout.nodes {
                var previous: UInt8 = 0
                for edge in edges(of: node) {
                    let value = letter(edge)
                    guard value >= UInt8(ascii: "a"), value <= UInt8(ascii: "z"), value > previous else {
                        throw FormatError.badLetters
                    }
                    previous = value
                }
            }
            guard validOffsets(at: layout.wordStart, count: layout.nodes, total: layout.words) else {
                throw FormatError.badWordOffsets
            }
            guard validOffsets(at: layout.textStart, count: layout.words, total: layout.blob, strictly: true) else {
                throw FormatError.badTextOffsets
            }
        }

        /// Checks that the edges form a tree under node 0 (each other node has exactly one parent and
        /// is reachable) and returns each node's preorder rank, children visited in letter order.
        fileprivate func rankTree() throws -> [UInt32] {
            let unranked = UInt32.max
            var rank = [UInt32](repeating: unranked, count: layout.nodes)
            // Mark each child once; a second mark is a second parent.
            for edge in 0 ..< layout.edges {
                let node = child(edge)
                guard node >= 1, node < layout.nodes, rank[node] == unranked else { throw FormatError.badChild }
                rank[node] = 0
            }
            // With at most one parent each, a walk from the root visits each reachable node once.
            var stack = [0]
            var next: UInt32 = 0
            while let node = stack.popLast() {
                rank[node] = next
                next += 1
                for edge in edges(of: node).reversed() { stack.append(child(edge)) }
            }
            guard Int(next) == layout.nodes else { throw FormatError.badChild }
            return rank
        }

        fileprivate func validateText() throws {
            for word in 0 ..< layout.words where !Self.isValidUTF8(text(word)) {
                throw FormatError.invalidUTF8
            }
        }

        /// Strict UTF-8 (Unicode Table 3-7): no overlong forms, surrogates or values past U+10FFFF.
        static func isValidUTF8(_ bytes: UnsafeRawBufferPointer) -> Bool {
            var index = 0
            let count = bytes.count
            func continuation(_ offset: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xBF) -> Bool {
                index + offset < count && bytes[index + offset] >= low && bytes[index + offset] <= high
            }
            while index < count {
                let lead = bytes[index]
                switch lead {
                case 0x00 ... 0x7F:
                    index += 1
                case 0xC2 ... 0xDF:
                    guard continuation(1) else { return false }
                    index += 2
                case 0xE0:
                    guard continuation(1, 0xA0), continuation(2) else { return false }
                    index += 3
                case 0xE1 ... 0xEC, 0xEE ... 0xEF:
                    guard continuation(1), continuation(2) else { return false }
                    index += 3
                case 0xED:
                    guard continuation(1, 0x80, 0x9F), continuation(2) else { return false }
                    index += 3
                case 0xF0:
                    guard continuation(1, 0x90), continuation(2), continuation(3) else { return false }
                    index += 4
                case 0xF1 ... 0xF3:
                    guard continuation(1), continuation(2), continuation(3) else { return false }
                    index += 4
                case 0xF4:
                    guard continuation(1, 0x80, 0x8F), continuation(2), continuation(3) else { return false }
                    index += 4
                default:
                    return false
                }
            }
            return true
        }
    }
}
