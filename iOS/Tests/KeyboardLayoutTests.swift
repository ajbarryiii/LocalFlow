import Foundation

enum KeyboardLayoutTests {
    static var tests: [TestCase] {
        [
            ("portraitMetricsMatchApple", testPortraitMetricsMatchApple),
            ("lettersLayer", testLettersLayer),
            ("numberAndSymbolLayers", testNumberAndSymbolLayers),
            ("globeOnlyWhenNeeded", testGlobeOnlyWhenNeeded),
            ("keysStayInsideAndNeverOverlap", testKeysStayInsideAndNeverOverlap),
            ("nearestKeyHasNoDeadGaps", testNearestKeyHasNoDeadGaps),
            ("landscapeKeepsACenteredBand", testLandscapeKeepsACenteredBand),
        ]
    }

    private static func keys(_ layer: KeyboardLayer, width: Double = 402, height: Double = KeyboardMetrics.regularHeight,
                             globe: Bool = false) -> [PlacedKey] {
        KeyboardLayout.keys(for: layer, metrics: KeyboardMetrics(width: width, height: height), showsGlobe: globe)
    }

    private static func key(_ action: KeyAction, in keys: [PlacedKey]) -> PlacedKey {
        keys.first { $0.action == action }!
    }

    private static func testPortraitMetricsMatchApple() {
        // iPhone 17 Pro (402 points) and SE (375 points), measured from the system keyboard.
        let pro = KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight)
        TestSupport.expectEqual(pro.rowHeight, 42)
        TestSupport.expect(abs(pro.letterWidth - 32.7) < 0.01, "pro letter width \(pro.letterWidth)")
        let se = KeyboardMetrics(width: 375, height: KeyboardMetrics.regularHeight)
        TestSupport.expect(abs(se.letterWidth - 31.5) < 0.01, "SE letter width \(se.letterWidth)")
        TestSupport.expectEqual(se.rowY(0), 8)
        TestSupport.expectEqual(se.rowY(3), 8 + 3 * 54)
    }

    private static func testLettersLayer() {
        let letters = keys(.letters)
        TestSupport.expectEqual(letters.count, 26 + 5)
        let rows = Dictionary(grouping: letters, by: { $0.frame.y }).sorted { $0.key < $1.key }.map(\.value)
        TestSupport.expectEqual(rows.map(\.count), [10, 9, 9, 3])
        TestSupport.expectEqual(rows[0].map(\.label).joined(), "qwertyuiop")
        TestSupport.expectEqual(rows[2].first?.action, .shift)
        TestSupport.expectEqual(rows[2].last?.action, .delete)
        TestSupport.expectEqual(rows[3].map(\.action), [.layer(.numbers), .space, .returnKey])
        // The middle row is centered under the top row.
        let a = key(.character("a"), in: letters), l = key(.character("l"), in: letters)
        TestSupport.expect(abs((a.frame.x + l.frame.maxX) / 2 - 201) < 0.01, "middle row centered")
        TestSupport.expectEqual(key(.character("q"), in: letters).frame.x, 6)
        TestSupport.expectEqual(key(.space, in: letters).label, "space")
    }

    private static func testNumberAndSymbolLayers() {
        let numbers = keys(.numbers)
        TestSupport.expectEqual(numbers.filter { if case .character = $0.action { return true }; return false }
            .map(\.label).joined(), "1234567890-/:;()$&@\".,?!'")
        TestSupport.expectEqual(key(.layer(.symbols), in: numbers).label, "#+=")
        TestSupport.expectEqual(key(.layer(.letters), in: numbers).label, "ABC")
        let symbols = keys(.symbols)
        TestSupport.expectEqual(symbols.filter { if case .character = $0.action { return true }; return false }
            .map(\.label).joined(), "[]{}#%^*+=_\\|~<>€£¥•.,?!'")
        TestSupport.expectEqual(key(.layer(.numbers), in: symbols).label, "123")
        // The five punctuation keys are wider than letters, as on Apple's keyboard.
        let period = key(.character("."), in: numbers)
        TestSupport.expect(period.frame.width > KeyboardMetrics(width: 402, height: 216).letterWidth * 1.2, "wide punctuation")
    }

    private static func testGlobeOnlyWhenNeeded() {
        TestSupport.expect(!keys(.letters).contains { $0.action == .nextKeyboard }, "no globe")
        let withGlobe = keys(.letters, globe: true)
        let globe = key(.nextKeyboard, in: withGlobe)
        let numbers = key(.layer(.numbers), in: withGlobe)
        TestSupport.expectEqual(globe.frame.width, numbers.frame.width)
        TestSupport.expect(key(.space, in: withGlobe).frame.width < key(.space, in: keys(.letters)).frame.width, "space shrinks")
    }

    private static func testKeysStayInsideAndNeverOverlap() {
        for width in [320.0, 375, 402, 440, 874] {
            for layer in [KeyboardLayer.letters, .numbers, .symbols] {
                let height = width > 600 ? KeyboardMetrics.compactHeight : KeyboardMetrics.regularHeight
                let placed = keys(layer, width: width, height: height, globe: true)
                for key in placed {
                    TestSupport.expect(key.frame.x >= 0 && key.frame.maxX <= width + 1e-9, "\(key.action) outside at \(width)")
                    TestSupport.expect(key.frame.y >= 0 && key.frame.maxY <= height + 1e-9, "\(key.action) below at \(width)")
                    TestSupport.expect(key.frame.width > 10, "\(key.action) too narrow at \(width)")
                }
                for (i, first) in placed.enumerated() {
                    for second in placed[(i + 1)...] {
                        let overlaps = first.frame.x < second.frame.maxX - 1e-9 && second.frame.x < first.frame.maxX - 1e-9
                            && first.frame.y < second.frame.maxY - 1e-9 && second.frame.y < first.frame.maxY - 1e-9
                        TestSupport.expect(!overlaps, "\(first.action) overlaps \(second.action) at \(width)")
                    }
                }
            }
        }
    }

    private static func testNearestKeyHasNoDeadGaps() {
        let letters = keys(.letters)
        let q = key(.character("q"), in: letters), w = key(.character("w"), in: letters)
        func hit(_ x: Double, _ y: Double) -> KeyAction? {
            KeyboardLayout.nearestKey(toX: x, y: y, in: letters).map { letters[$0].action }
        }
        TestSupport.expectEqual(hit(q.frame.midX, q.frame.midY), .character("q"))
        // In the gap between q and w, slightly nearer w.
        TestSupport.expectEqual(hit(w.frame.x - 1, q.frame.midY), .character("w"))
        TestSupport.expectEqual(hit(q.frame.maxX + 1, q.frame.midY), .character("q"))
        // Above the keyboard's first row and between rows still hit a key.
        TestSupport.expectEqual(hit(q.frame.midX, -20), .character("q"))
        let a = key(.character("a"), in: letters)
        TestSupport.expectEqual(hit(a.frame.midX, a.frame.y - 2), .character("a"))
        // Left of "a" (the half-key indent) goes to "a", not into nothing.
        TestSupport.expectEqual(hit(1, a.frame.midY), .character("a"))
        TestSupport.expectEqual(hit(201, 400), .space)
        TestSupport.expectEqual(KeyboardLayout.nearestKey(toX: 0, y: 0, in: []), nil)
    }

    private static func testLandscapeKeepsACenteredBand() {
        let metrics = KeyboardMetrics(width: 874, height: KeyboardMetrics.compactHeight)
        TestSupport.expectEqual(metrics.sideMargin, 87)
        TestSupport.expect(metrics.rowHeight > 30 && metrics.rowHeight < 36, "landscape row height \(metrics.rowHeight)")
        let placed = keys(.letters, width: 874, height: KeyboardMetrics.compactHeight)
        TestSupport.expectEqual(key(.character("q"), in: placed).frame.x, 87)
    }
}
