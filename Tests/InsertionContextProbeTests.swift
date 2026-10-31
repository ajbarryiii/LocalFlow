import Foundation

/// Contract tests for reading the text around the insertion point of the
/// focused field. A fake reader stands in for Accessibility; all text is
/// invented.
enum InsertionContextProbeTests {
    static func run() {
        testReadsAroundTheCaret()
        testReadsAroundASelection()
        testCaretAtEitherEnd()
        testReadsOnlyAFewCharacters()
        testNothingWithoutAnEligibleField()
        testFailedReads()
    }

    private static func read(_ reader: FakeTextFieldReader) -> InsertionContext? {
        InsertionContextProbe.read(using: reader)
    }

    private static func testReadsAroundTheCaret() {
        let reader = FakeTextFieldReader("Like this one. Next.")
        reader.caret = "Like this one".utf16.count
        TestSupport.expectEqual(read(reader), InsertionContext(before: "Like this one", after: ". Next."))
    }

    private static func testReadsAroundASelection() {
        let reader = FakeTextFieldReader("Keep this, drop that, keep.")
        reader.caret = "Keep this, ".utf16.count
        reader.selectionLength = "drop that".utf16.count
        TestSupport.expectEqual(read(reader), InsertionContext(before: "Keep this, ", after: ", keep."))
    }

    private static func testCaretAtEitherEnd() {
        let reader = FakeTextFieldReader("Some words")
        reader.caret = 0
        TestSupport.expectEqual(read(reader), InsertionContext(before: "", after: "Some words"))
        reader.caret = reader.units.count
        TestSupport.expectEqual(read(reader), InsertionContext(before: "Some words", after: ""))
        let empty = FakeTextFieldReader("")
        TestSupport.expectEqual(read(empty), InsertionContext(before: "", after: ""))
        TestSupport.expectEqual(empty.rangeReads.count, 0)
    }

    private static func testReadsOnlyAFewCharacters() {
        let filler = String(repeating: "synthetic filler ", count: 20)
        let reader = FakeTextFieldReader(filler + "|" + filler)
        reader.caret = filler.utf16.count
        let context = read(reader)
        TestSupport.expectEqual(context?.before?.utf16.count, InsertionContextProbe.span)
        TestSupport.expectEqual(context?.after?.utf16.count, InsertionContextProbe.span)
        TestSupport.expect(reader.rangeReads.allSatisfy { $0.length <= InsertionContextProbe.span },
                           "Reads stay within the span")
    }

    private static func testNothingWithoutAnEligibleField() {
        for configure in [{ (r: FakeTextFieldReader) in r.trusted = false },
                          { (r: FakeTextFieldReader) in r.focused = false },
                          { (r: FakeTextFieldReader) in r.secure = true }] {
            let reader = FakeTextFieldReader("Private words")
            configure(reader)
            TestSupport.expect(read(reader) == nil, "No context without an eligible field")
            TestSupport.expectEqual(reader.rangeReads.count, 0)
        }
    }

    private static func testFailedReads() {
        let failing = FakeTextFieldReader("Some words")
        failing.failReads = true
        TestSupport.expect(read(failing) == nil, "No context when reads fail")
        let unsupported = FakeTextFieldReader("Some words")
        unsupported.caret = 4
        unsupported.supportsRangeReads = false
        TestSupport.expect(read(unsupported) == nil, "No context without range reads")
        // A selection past the end is inconsistent: nothing is trusted.
        let inconsistent = FakeTextFieldReader("Some words")
        inconsistent.selectionLength = 3
        TestSupport.expect(read(inconsistent) == nil, "No context from an inconsistent selection")
    }
}
