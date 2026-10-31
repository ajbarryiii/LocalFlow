import Foundation

/// ARCHITECTURE.md, "Press-and-hold alternates": the table and the row's geometry.
enum KeyAlternatesTests {
    static var tests: [TestCase] {
        [
            ("everyDailyKeyHasItsAlternates", testEveryDailyKeyHasItsAlternates),
            ("theRowStartsOverTheKeyAndRunsInwards", testTheRowStartsOverTheKeyAndRunsInwards),
            ("theRowStaysInsideTheKeyboard", testTheRowStaysInsideTheKeyboard),
            ("theFingerPicksTheCellItIsOver", testTheFingerPicksTheCellItIsOver),
        ]
    }

    private static func testEveryDailyKeyHasItsAlternates() {
        // Accented vowels and consonants, as on Apple's English keyboard.
        for (key, expected) in [("e", "é"), ("a", "à"), ("o", "ö"), ("u", "ü"), ("i", "í"), ("c", "ç"), ("n", "ñ"), ("s", "ß"),
                                ("y", "ÿ"), ("z", "ž")] {
            TestSupport.expect(KeyAlternates.alternates(for: key).contains(expected), "\(key) lacks \(expected)")
        }
        // Punctuation: dashes, ellipsis, curly quotes, currencies, inverted marks.
        for (key, expected) in [("-", "—"), ("-", "–"), (".", "…"), ("'", "’"), ("\"", "“"), ("\"", "”"), ("$", "€"),
                                ("$", "£"), ("?", "¿"), ("!", "¡")] {
            TestSupport.expect(KeyAlternates.alternates(for: key).contains(expected), "\(key) lacks \(expected)")
        }
        TestSupport.expectEqual(KeyAlternates.alternates(for: KeyboardLayout.dotCom), [".org", ".net", ".edu", ".us"])
        // The row starts with the key's own character; a key without alternates has no row.
        TestSupport.expectEqual(KeyAlternates.options(for: "n"), ["n", "ñ", "ń"])
        for key in ["b", "q", "1", "@", "#", ""] {
            TestSupport.expectEqual(KeyAlternates.options(for: key), [])
        }
        // No alternate repeats its key or another.
        for key in ["a", "c", "e", "i", "l", "n", "o", "s", "u", "y", "z", "-", ".", "'", "\"", "$", "?", "!", KeyboardLayout.dotCom] {
            let options = KeyAlternates.options(for: key)
            TestSupport.expectEqual(Set(options).count, options.count)
        }
    }

    /// One row a gap above the key, cells as wide and tall as the key, the first centred over it, the rest running
    /// towards the keyboard's middle.
    private static func testTheRowStartsOverTheKeyAndRunsInwards() {
        let left = KeyRect(x: 40, y: 62, width: 32, height: 42)
        let cells = KeyAlternates.frames(count: 4, key: left, width: 402)
        TestSupport.expectEqual(cells.count, 4)
        TestSupport.expectEqual(cells[0], KeyRect(x: 40, y: 62 - KeyAlternates.gap - 42, width: 32, height: 42))
        TestSupport.expectEqual(cells.map(\.x), [40, 72, 104, 136])
        let right = KeyRect(x: 300, y: 8, width: 32, height: 42)
        TestSupport.expectEqual(KeyAlternates.frames(count: 3, key: right, width: 402).map(\.x), [300, 268, 236])
        TestSupport.expectEqual(KeyAlternates.frames(count: 0, key: right, width: 402), [])
    }

    private static func testTheRowStaysInsideTheKeyboard() {
        for width in [320.0, 375, 402] {
            let metrics = KeyboardMetrics(width: width, height: KeyboardMetrics.regularHeight)
            for field in [KeyboardField.standard, .url] {
                for layer in [KeyboardLayer.letters, .numbers] {
                    for key in KeyboardLayout.keys(for: layer, metrics: metrics, showsGlobe: true, field: field) {
                        guard case .character(let character) = key.action else { continue }
                        let count = KeyAlternates.options(for: character).count
                        guard count > 0 else { continue }
                        let cells = KeyAlternates.frames(count: count, key: key.frame, width: width)
                        for cell in cells {
                            TestSupport.expect(cell.x >= KeyAlternates.margin - 1e-9 && cell.maxX <= width - KeyAlternates.margin + 1e-9,
                                               "\(character) row outside at \(width)")
                            TestSupport.expect(cell.width <= key.frame.width + 1e-9 && cell.width > 20, "\(character) cell width")
                        }
                        // Cells touch without overlapping.
                        let sorted = cells.sorted { $0.x < $1.x }
                        for (a, b) in zip(sorted, sorted.dropFirst()) { TestSupport.expect(abs(a.maxX - b.x) < 1e-9, "gap in row") }
                    }
                }
            }
        }
    }

    private static func testTheFingerPicksTheCellItIsOver() {
        let cells = KeyAlternates.frames(count: 4, key: KeyRect(x: 40, y: 62, width: 32, height: 42), width: 402)
        TestSupport.expectEqual(KeyAlternates.index(atX: 56, in: cells), 0)
        TestSupport.expectEqual(KeyAlternates.index(atX: 73, in: cells), 1)
        TestSupport.expectEqual(KeyAlternates.index(atX: 150, in: cells), 3)
        // Beyond either end, the end cell.
        TestSupport.expectEqual(KeyAlternates.index(atX: 0, in: cells), 0)
        TestSupport.expectEqual(KeyAlternates.index(atX: 400, in: cells), 3)
    }
}
