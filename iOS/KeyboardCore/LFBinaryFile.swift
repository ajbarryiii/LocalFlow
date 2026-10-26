import Foundation

/// The header failures every LocalFlow binary file reports, each through its own error type's cases.
protocol LFBinaryFileError: Error {
    /// Shorter than the magic or the header (and, for each format, a length the header disagrees with).
    static var wrongSize: Self { get }
    static var badMagic: Self { get }
    static var unsupportedVersion: Self { get }
}

/// Reads LocalFlow's binary model files: the swipe lexicon (LFLX), the tap model (LFTP) and the word files
/// (LFWL, LFWN, LFWR, LFWE). Each is little-endian and starts with a 4-byte magic and a u32 version; the rest
/// of each header and its data are the format's own.
enum LFBinaryFile {
    /// Checks the magic and version of a file at least `header` bytes long, in this order: shorter than the
    /// magic is `wrongSize`, another magic `badMagic`, shorter than the header `wrongSize`, another version
    /// `unsupportedVersion`, each as `E`.
    static func checkHeader<E: LFBinaryFileError>(_ data: Data, magic: String, version: UInt32, header: Int,
                                                  as _: E.Type) throws {
        guard data.count >= 4 else { throw E.wrongSize }
        guard data.prefix(4).elementsEqual(magic.utf8) else { throw E.badMagic }
        guard data.count >= header else { throw E.wrongSize }
        let found = data.withUnsafeBytes { u32($0, 4) }
        guard found == version else { throw E.unsupportedVersion }
    }

    /// Data whose bytes start at an 8-byte boundary, so sections can be read in place as typed arrays: the
    /// data itself when it does (a mapped file always does), else a copy.
    static func aligned(_ data: Data) -> Data {
        let misaligned = data.withUnsafeBytes { raw in raw.baseAddress.map { Int(bitPattern: $0) % 8 != 0 } ?? false }
        return misaligned ? Data(data) : data
    }

    static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    static func u64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    static func f64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Double {
        Double(bitPattern: u64(raw, offset))
    }

    static func f32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Float {
        Float(bitPattern: u32(raw, offset))
    }
}
