import Foundation

/// `LFBinaryFile`: the header checks and little-endian reads shared by the binary model files. Invented bytes
/// only; each format's own tests cover its header through its own error type.
enum LFBinaryFileTests {
    static var tests: [TestCase] {
        [
            ("headerChecksRunInOrder", testHeaderChecksRunInOrder),
            ("readsLittleEndian", testReadsLittleEndian),
            ("alignedKeepsTheBytes", testAlignedKeepsTheBytes),
        ]
    }

    private enum TestError: LFBinaryFileError, Equatable {
        case wrongSize, badMagic, unsupportedVersion
    }

    private static func error(_ data: Data, header: Int = 12) -> TestError? {
        do {
            try LFBinaryFile.checkHeader(data, magic: "LFZZ", version: 3, header: header, as: TestError.self)
            return nil
        } catch {
            return error as? TestError
        }
    }

    private static func testHeaderChecksRunInOrder() {
        let valid = Data("LFZZ".utf8) + Data([3, 0, 0, 0, 9, 9, 9, 9])
        TestSupport.expectEqual(error(valid), nil)
        TestSupport.expectEqual(error(valid + Data([1])), nil)
        TestSupport.expectEqual(error(Data()), .wrongSize)
        TestSupport.expectEqual(error(Data("LFZ".utf8)), .wrongSize)
        // The magic before the header's size, and the size before the version.
        TestSupport.expectEqual(error(Data("LFZY".utf8)), .badMagic)
        TestSupport.expectEqual(error(Data("LFZZ".utf8)), .wrongSize)
        TestSupport.expectEqual(error(Data("LFZZ".utf8) + Data([4, 0, 0, 0])), .wrongSize)
        TestSupport.expectEqual(error(Data("LFZZ".utf8) + Data([4, 0, 0, 0]), header: 8), .unsupportedVersion)
        TestSupport.expectEqual(error(Data("LFZZ".utf8) + Data([3, 0, 0, 1, 0, 0, 0, 0])), .unsupportedVersion)
        // A slice reads from its own start.
        TestSupport.expectEqual(error((Data([0x4C, 0x46]) + valid).dropFirst(2)), nil)
    }

    private static func testReadsLittleEndian() {
        let bytes = Data([0, 0x78, 0x56, 0x34, 0x12, 0, 0, 0xC0, 0x3F, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])
        bytes.withUnsafeBytes { raw in
            TestSupport.expectEqual(LFBinaryFile.u32(raw, 1), 0x1234_5678)
            TestSupport.expectEqual(LFBinaryFile.f32(raw, 5), 1.5)
            TestSupport.expectEqual(LFBinaryFile.u64(raw, 1), 0x3FC0_0000_1234_5678)
            TestSupport.expectEqual(LFBinaryFile.f64(raw, 9), 1.5)
        }
    }

    private static func testAlignedKeepsTheBytes() {
        let bytes = Data((0 ..< 24).map { UInt8($0) })
        for offset in 0 ..< 8 {
            let slice = (Data(count: offset) + bytes).dropFirst(offset)
            let aligned = LFBinaryFile.aligned(slice)
            TestSupport.expect(aligned.elementsEqual(bytes), "bytes changed at offset \(offset)")
            let address = aligned.withUnsafeBytes { Int(bitPattern: $0.baseAddress!) }
            TestSupport.expectEqual(address % 8, 0)
        }
    }
}
