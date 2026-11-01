import Foundation

/// ARCHITECTURE.md, "Press-and-hold alternates": the table and the row's geometry.
enum KeyAlternatesTests {
    static var tests: [TestCase] {
        [
            ("everyDailyKeyHasItsAlternates", testEveryDailyKeyHasItsAlternates),
            ("theRowStartsOverTheKeyAndRunsInwards", testTheRowStartsOverTheKeyAndRunsInwards),
            ("theRowStaysInsideTheKeyboard", testTheRowStaysInsideTheKeyboard),
            ("theFingerPicksTheCellItIsOver", testTheFingerPicksTheCellItIsOver),
            ("webSearchDotOffersTheDomains", testWebSearchDotOffersTheDomains),
            ("domainRowsStartOverTheirKey", testDomainRowsStartOverTheirKey),
            ("voiceOverOffersEveryAlternateAsAnAction", testVoiceOverOffersEveryAlternateAsAnAction),
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
            for field in [KeyboardField.standard, .url, .webSearch] {
                for layer in [KeyboardLayer.letters, .numbers] {
                    for key in KeyboardLayout.keys(for: layer, metrics: metrics, showsGlobe: true, field: field) {
                        guard case .character(let character) = key.action else { continue }
                        let options = KeyAlternates.options(for: character, field: layer == .letters ? field : .standard)
                        guard !options.isEmpty else { continue }
                        let cells = KeyAlternates.frames(options: options, key: key.frame, width: width)
                        // As wide as the key, or as a domain cell for a row of domains, narrower only when it would not fit.
                        let widest = options.contains { $0.count > 1 } ? max(key.frame.width, KeyAlternates.domainCellWidth) : key.frame.width
                        for cell in cells {
                            TestSupport.expect(cell.x >= KeyAlternates.margin - 1e-9 && cell.maxX <= width - KeyAlternates.margin + 1e-9,
                                               "\(character) row outside at \(width)")
                            TestSupport.expect(cell.width <= widest + 1e-9 && cell.width > 20, "\(character) cell width")
                        }
                        // Cells touch without overlapping.
                        let sorted = cells.sorted { $0.x < $1.x }
                        for (a, b) in zip(sorted, sorted.dropFirst()) { TestSupport.expect(abs(a.maxX - b.x) < 1e-9, "gap in row") }
                    }
                }
            }
        }
    }

    /// Safari's address bar is a web search field: holding its "." offers the domains, as the URL field's ".com" does;
    /// "." elsewhere keeps the ellipsis.
    private static func testWebSearchDotOffersTheDomains() {
        TestSupport.expectEqual(KeyAlternates.options(for: ".", field: .webSearch), [".", ".com", ".org", ".net", ".edu", ".us"])
        for field in [KeyboardField.standard, .email, .url] {
            TestSupport.expectEqual(KeyAlternates.options(for: ".", field: field), [".", "…"])
        }
        TestSupport.expectEqual(KeyAlternates.options(for: KeyboardLayout.dotCom, field: .url),
                                [KeyboardLayout.dotCom, ".org", ".net", ".edu", ".us"])
        // Only "." changes: letters keep their accents in a web search field.
        TestSupport.expectEqual(KeyAlternates.options(for: "e", field: .webSearch), KeyAlternates.options(for: "e"))
    }

    /// A row of domains has cells wide enough for ".com", and starts over its key (the key's own option first, centred
    /// over it) on the phones LocalFlow runs on, not moved off it to stay on screen.
    private static func testDomainRowsStartOverTheirKey() {
        for width in [375.0, 402, 440] {
            let metrics = KeyboardMetrics(width: width, height: KeyboardMetrics.regularHeight)
            for (field, character) in [(KeyboardField.webSearch, "."), (.url, KeyboardLayout.dotCom)] {
                for showsGlobe in [false, true] {
                    let keys = KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: showsGlobe, field: field)
                    let key = keys.first { $0.action == .character(character) }!.frame
                    let options = KeyAlternates.options(for: character, field: field)
                    let cells = KeyAlternates.frames(options: options, key: key, width: width)
                    TestSupport.expectEqual(cells.count, options.count)
                    TestSupport.expect(abs(cells[0].midX - key.midX) < 1e-9, "\(character) row moved off its key at \(width)")
                    TestSupport.expect(cells.allSatisfy { abs($0.width - KeyAlternates.domainCellWidth) < 1e-9 },
                                       "\(character) cells at \(width)")
                    TestSupport.expect(cells.allSatisfy { $0.y == key.y - KeyAlternates.gap - key.height }, "\(character) row height")
                }
            }
        }
        // Rows of single characters keep the key's width.
        let key = KeyRect(x: 40, y: 62, width: 32, height: 42)
        TestSupport.expectEqual(KeyAlternates.frames(options: ["e", "é", "è"], key: key, width: 402),
                                KeyAlternates.frames(count: 3, key: key, width: 402))
    }

    /// Round 1 council (Sol): VoiceOver had no route to the alternates. Each character key with alternates offers
    /// them as custom actions, the key's own character excluded (activating the key types it), in the row's order;
    /// the field's own ones on the letters layer only, as the row shows them.
    private static func testVoiceOverOffersEveryAlternateAsAnAction() {
        TestSupport.expectEqual(KeyAlternates.accessibilityActions(for: "e", layer: .letters, field: .standard),
                                KeyAlternates.alternates(for: "e"))
        TestSupport.expectEqual(KeyAlternates.accessibilityActions(for: KeyboardLayout.dotCom, layer: .letters, field: .url),
                                [".org", ".net", ".edu", ".us"])
        TestSupport.expectEqual(KeyAlternates.accessibilityActions(for: ".", layer: .letters, field: .webSearch),
                                [".com", ".org", ".net", ".edu", ".us"])
        TestSupport.expectEqual(KeyAlternates.accessibilityActions(for: ".", layer: .numbers, field: .webSearch), ["…"])
        TestSupport.expectEqual(KeyAlternates.accessibilityActions(for: "b", layer: .letters, field: .standard), [])
        // Every key the row opens for has its actions, and only those.
        let metrics = KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight)
        for field in [KeyboardField.standard, .email, .url, .webSearch] {
            for layer in [KeyboardLayer.letters, .numbers, .symbols] {
                var model = KeyTouchModel()
                let keys = KeyboardLayout.keys(for: layer, metrics: metrics, showsGlobe: false, field: field)
                _ = model.keysChanged(keys, layer: layer, field: field)
                for key in keys {
                    guard case .character(let character) = key.action else { continue }
                    TestSupport.expectEqual(KeyAlternates.accessibilityActions(for: character, layer: layer, field: field),
                                            Array(model.alternateOptions(for: character).dropFirst()))
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
