import Foundation

enum TextNavigatorTests {
    static var tests: [TestCase] {
        [
            ("boundariesAreGraphemeSafe", testBoundariesAreGraphemeSafe),
            ("caretInsideClusterIsKept", testCaretInsideClusterIsKept),
            ("cursorClamps", testCursorClamps),
            ("agreesComparesAroundThePosition", testAgreesComparesAroundThePosition),
            ("linesAndColumns", testLinesAndColumns),
            ("nearestPositionNeverPassesALineBreak", testNearestPositionNeverPassesALineBreak),
            ("fixedWidthLayoutFake", testFixedWidthLayoutFake),
            ("splitIsKnownAndNeverATarget", testSplitIsKnownAndNeverATarget),
            ("locateUsesOverlappingAnchors", testLocateUsesOverlappingAnchors),
            ("clusterAroundAnOffset", testClusterAroundAnOffset),
            ("expectationsMatchAsFarAsVisible", testExpectationsMatchAsFarAsVisible),
        ]
    }

    // Invented text with an emoji with a skin-tone modifier (4 code units), a flag (4) and a
    // combining accent (e + U+0301, 2).
    private static let thumbs = "\u{1F44D}\u{1F3FD}"
    private static let flag = "\u{1F1EB}\u{1F1F7}"
    private static let accented = "e\u{301}"

    private static func testBoundariesAreGraphemeSafe() {
        let navigator = TextNavigator(before: "ab\(thumbs)c", after: "\(accented)\(flag)d")
        TestSupport.expectEqual(navigator.boundaries, [0, 1, 2, 6, 7, 9, 13, 14])
        TestSupport.expectEqual(navigator.cursor, 4)
        TestSupport.expectEqual(navigator.snapshotPosition, 4)
        TestSupport.expectEqual(navigator.cursorUTF16Offset, 7)
        TestSupport.expectEqual(navigator.grapheme(after: 2), thumbs)
        TestSupport.expectEqual(navigator.grapheme(after: 4), accented)
        TestSupport.expectEqual(navigator.grapheme(after: 7), nil)
        TestSupport.expectEqual(navigator.grapheme(after: -1), nil)
        TestSupport.expectEqual(navigator.utf16Distance(from: 4, to: 2), -5)
        TestSupport.expectEqual(navigator.lastPosition, 7)
        let empty = TextNavigator(before: "", after: "")
        TestSupport.expectEqual(empty.boundaries, [0])
        TestSupport.expectEqual(empty.cursor, 0)
    }

    private static func testCaretInsideClusterIsKept() {
        // UIKit can leave the caret between an emoji and its modifier.
        let navigator = TextNavigator(before: "a\u{1F44D}", after: "\u{1F3FD}b")
        TestSupport.expectEqual(navigator.boundaries, [0, 1, 3, 5, 6])
        TestSupport.expectEqual(navigator.cursor, 2)
        TestSupport.expectEqual(navigator.grapheme(after: 1), "\u{1F44D}")
        TestSupport.expectEqual(navigator.grapheme(after: 2), "\u{1F3FD}")
        // Between e and its accent.
        let accent = TextNavigator(before: "xe", after: "\u{301}y")
        TestSupport.expectEqual(accent.boundaries, [0, 1, 2, 3, 4])
        TestSupport.expectEqual(accent.cursor, 2)
    }

    private static func testCursorClamps() {
        var navigator = TextNavigator(before: "abc", after: "de")
        navigator.setCursor(-4)
        TestSupport.expectEqual(navigator.cursor, 0)
        navigator.setCursor(99)
        TestSupport.expectEqual(navigator.cursor, 5)
    }

    private static func testAgreesComparesAroundThePosition() {
        let navigator = TextNavigator(before: "The quick ", after: "brown fox")
        TestSupport.expect(navigator.agrees(before: "The quick ", after: "brown fox", at: 10), "same")
        // A different window around the same caret still agrees.
        TestSupport.expect(navigator.agrees(before: "Earlier. The quick ", after: "brown", at: 10), "window")
        TestSupport.expect(navigator.agrees(before: "quick b", after: "rown fox", at: 11), "moved")
        TestSupport.expect(!navigator.agrees(before: "The quick ", after: "brown fox", at: 11), "stale")
        TestSupport.expect(!navigator.agrees(before: "The quick b", after: "rown fox", at: 10), "ahead")
        // At the snapshot's start the host may show more before; only the after side decides.
        TestSupport.expect(navigator.agrees(before: "Earlier text ", after: "The quick", at: 0), "start")
        TestSupport.expect(!navigator.agrees(before: "", after: "he quick", at: 0), "start mismatch")
        let empty = TextNavigator(before: "", after: "")
        TestSupport.expect(empty.agrees(before: "", after: "", at: 0), "empty")
        TestSupport.expect(!empty.agrees(before: "x", after: "", at: 0), "an empty snapshot against text")
    }

    private static func testLinesAndColumns() {
        // Columns of 5: "abcde|fghij|kl\n|mn" with the caret after "h".
        let layout = FixedWidthLayout(columns: 5)
        let navigator = TextNavigator(before: "abcdefgh", after: "ijkl\nmn")
        let lines = layout.lines(in: navigator.text)
        TestSupport.expectEqual(lines, [0 ..< 5, 5 ..< 10, 10 ..< 13, 13 ..< 15])
        TestSupport.expectEqual(navigator.line(of: navigator.cursor, in: lines), 1)
        TestSupport.expectEqual(navigator.x(of: navigator.cursor, lines: lines, layout: layout), 30)
        // A position at a soft wrap belongs to the line it starts.
        TestSupport.expectEqual(navigator.line(of: 5, in: lines), 1)
        TestSupport.expectEqual(navigator.line(of: 15, in: lines), 3)
        TestSupport.expectEqual(navigator.position(nearestX: 30, onLine: 0, lines: lines, layout: layout), 3)
        TestSupport.expectEqual(navigator.position(nearestX: 34, onLine: 3, lines: lines, layout: layout), 15)
        TestSupport.expectEqual(navigator.position(nearestX: 0, onLine: 2, lines: lines, layout: layout), 10)
    }

    private static func testNearestPositionNeverPassesALineBreak() {
        let layout = FixedWidthLayout(columns: 40)
        let navigator = TextNavigator(before: "ab\n", after: "longer line")
        let lines = layout.lines(in: navigator.text)
        TestSupport.expectEqual(lines, [0 ..< 3, 3 ..< 14])
        // Far right on "ab\n" stops before the break, not after it.
        TestSupport.expectEqual(navigator.position(nearestX: 200, onLine: 0, lines: lines, layout: layout), 2)
        TestSupport.expectEqual(navigator.position(nearestX: 200, onLine: 1, lines: lines, layout: layout), 14)
        // Text ending in a line break has an empty last line where the caret can go.
        let trailing = TextNavigator(before: "ab\n", after: "")
        let trailingLines = layout.lines(in: trailing.text)
        TestSupport.expectEqual(trailingLines, [0 ..< 3, 3 ..< 3])
        TestSupport.expectEqual(trailing.line(of: 3, in: trailingLines), 1)
        TestSupport.expectEqual(trailing.position(nearestX: 50, onLine: 1, lines: trailingLines, layout: layout), 3)
    }

    private static func testFixedWidthLayoutFake() {
        let layout = FixedWidthLayout(columns: 3)
        TestSupport.expectEqual(layout.lines(in: ""), [0 ..< 0])
        TestSupport.expectEqual(layout.lines(in: "abc"), [0 ..< 3])
        TestSupport.expectEqual(layout.lines(in: "abcd"), [0 ..< 3, 3 ..< 4])
        TestSupport.expectEqual(layout.lines(in: "a\(thumbs)b"), [0 ..< 6])
        TestSupport.expectEqual(layout.x(atUTF16: 5, line: 0 ..< 6, in: "a\(thumbs)b"), 20)
    }

    private static func testSplitIsKnownAndNeverATarget() {
        let navigator = TextNavigator(before: "a\u{1F44D}", after: "\u{1F3FD}b")
        TestSupport.expect(navigator.snapshotSplit! == (back: 2, forward: 2), "split lengths")
        TestSupport.expectEqual(navigator.splitPosition, 2)
        // Nearest x to the split, in a fixed-width layout: the split is skipped for a real boundary.
        let layout = FixedWidthLayout(columns: 100)
        let lines = layout.lines(in: navigator.text)
        let target = navigator.position(nearestX: 20, onLine: 0, lines: lines, layout: layout)
        TestSupport.expect(target != 2, "the split position was a target")
        TestSupport.expect(TextNavigator(before: "ab", after: "cd").snapshotSplit == nil, "a split at a boundary")
    }

    private static func testLocateUsesOverlappingAnchors() {
        let navigator = TextNavigator(before: "Hello there", after: " world.")
        // A shifted, narrower window places the caret by what it shows on both sides.
        TestSupport.expectEqual(navigator.locate(before: "there", after: " wor"), [11])
        TestSupport.expectEqual(navigator.locate(before: "Earlier. Hello th", after: "ere world."), [8])
        // Inside a cluster.
        let thumbs = TextNavigator(before: "a\(thumbs)", after: "b")
        TestSupport.expectEqual(thumbs.locate(before: "a\u{1F44D}", after: "\u{1F3FD}b"), [3])
        // Repetitive text fits several places; unrelated text none.
        let repeated = TextNavigator(before: "\(accented)\(accented)", after: "")
        TestSupport.expectEqual(repeated.locate(before: accented, after: accented), [0, 2, 4])
        TestSupport.expectEqual(navigator.locate(before: "Other", after: "text"), [])
    }

    private static func testClusterAroundAnOffset() {
        let navigator = TextNavigator(before: "a\(thumbs)\(accented)", after: "")
        TestSupport.expect(navigator.cluster(aroundUTF16: 3)! == (start: 1, end: 5), "inside the emoji")
        TestSupport.expect(navigator.cluster(aroundUTF16: 6)! == (start: 5, end: 7), "inside the accent")
        TestSupport.expect(navigator.cluster(aroundUTF16: 5) == nil, "at a boundary")
        TestSupport.expectEqual(navigator.position(atUTF16: 5), 2)
        TestSupport.expectEqual(navigator.position(atUTF16: 3), nil)
    }

    private static func testExpectationsMatchAsFarAsVisible() {
        let navigator = TextNavigator(before: "Hello there", after: " world.")
        let expected = navigator.expectation(at: 11)
        TestSupport.expect(expected.matches(before: "there", after: " w"), "a narrower window")
        TestSupport.expect(expected.matches(before: "Earlier. Hello there", after: " world. More."), "a wider window")
        TestSupport.expect(!expected.matches(before: "Hello ther", after: "e world."), "one character off")
        // One hidden character past the snapshot's end (a jump past its edge).
        let crossed = CaretExpectation(before: Array("world.".utf16), after: nil, hiddenBefore: 1)
        TestSupport.expect(crossed.matches(before: "Hello world.\n", after: "Next line"), "crossed a line break")
        TestSupport.expect(!crossed.matches(before: "Something else\n", after: "Next line"), "other text")
    }
}
