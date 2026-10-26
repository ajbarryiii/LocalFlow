import Foundation

/// The spelling channel's edit tables (ARCHITECTURE.md, "Word autocorrect", "Spelling channel"; reference:
/// localflow-swipe `tap/spelling.py` `SpellingTables`): natural-log probabilities of a writer's spelling
/// errors, the letters a–z as 0–25 and `start` (26) the start of a word. Row-major, 26 columns:
/// - `sub[c * 26 + x]`: x typed for intended c (26 × 26); −∞ on the diagonal;
/// - `dele[p * 26 + c]`: c left out after p, p = `start` for a first letter (27 × 26);
/// - `ins[p * 26 + x]`: x typed extra after p, p = `start` before the first letter (27 × 26);
/// - `trans[c * 26 + d]`: "dc" typed for "cd" (26 × 26); −∞ on the diagonal.
///
/// Every entry off those diagonals is finite and at most 0; the initializers throw otherwise.
///
/// The file is "LFWE" version 1 of localflow-swipe `tap/export_word_ios.py`: little-endian, the 4-byte magic
/// and a u32 version, then the four tables as f32 in the order sub, dele, ins, trans (each section a
/// multiple of 8 bytes, so unpadded): exactly `fileSize` bytes, −∞ stored as f32 −∞. The values are widened
/// to Double once, so the corrector computes as the reference does with the tables read back from the file.
/// Immutable after loading, so it is shared unchecked.
final class SpellingTables: @unchecked Sendable, Equatable {
    static let version: UInt32 = 1
    static let start = 26
    static let columns = 26
    static let headerSize = 8
    /// Rows of sub, dele, ins and trans, in file order.
    static let rows = [26, 27, 27, 26]
    static let fileSize = headerSize + rows.reduce(0, +) * columns * 4

    let sub: [Double]
    let dele: [Double]
    let ins: [Double]
    let trans: [Double]

    /// Tables from their row-major values; throws `unsupportedShape` for a wrong count and `invalidValues` for
    /// an entry outside the rules above.
    init(sub: [Double], dele: [Double], ins: [Double], trans: [Double]) throws {
        let tables = [sub, dele, ins, trans]
        guard zip(tables, Self.rows).allSatisfy({ $0.count == $1 * Self.columns }) else { throw WordFileError.unsupportedShape }
        for (index, table) in tables.enumerated() {
            let diagonal = index == 0 || index == 3
            for (offset, value) in table.enumerated() {
                if diagonal, offset / Self.columns == offset % Self.columns {
                    guard value == -.infinity else { throw WordFileError.invalidValues }
                } else {
                    guard value.isFinite, value <= 0 else { throw WordFileError.invalidValues }
                }
            }
        }
        self.sub = sub
        self.dele = dele
        self.ins = ins
        self.trans = trans
    }

    /// Reads an LFWE file: `badMagic`, `unsupportedVersion`, `wrongSize` for any length but `fileSize`, and
    /// the initializer's checks on the widened values.
    convenience init(data: Data) throws {
        try LFBinaryFile.checkHeader(data, magic: "LFWE", version: Self.version, header: Self.headerSize,
                                     as: WordFileError.self)
        guard data.count == Self.fileSize else { throw WordFileError.wrongSize }
        var sections = WordFileSections(header: Self.headerSize)
        let offsets = try Self.rows.map { try sections.next(count: $0 * Self.columns, size: 4) }
        guard sections.end == data.count else { throw WordFileError.wrongSize }
        let tables = data.withUnsafeBytes { raw in
            zip(offsets, Self.rows).map { offset, rows in
                (0 ..< rows * Self.columns).map { Double(LFBinaryFile.f32(raw, offset + 4 * $0)) }
            }
        }
        try self.init(sub: tables[0], dele: tables[1], ins: tables[2], trans: tables[3])
    }

    /// Reads a tables file. Call off the main thread.
    static func load(from url: URL) throws -> SpellingTables {
        try SpellingTables(data: Data(contentsOf: url))
    }

    static func == (a: SpellingTables, b: SpellingTables) -> Bool {
        a.sub == b.sub && a.dele == b.dele && a.ins == b.ins && a.trans == b.trans
    }
}
