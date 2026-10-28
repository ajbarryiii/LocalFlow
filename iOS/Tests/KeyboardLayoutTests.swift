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
            ("reachAboveTheKeysIsTheBarBelowItsControls", testReachAboveTheKeysIsTheBarBelowItsControls),
            ("theSpaceBarGetsTheLeastOfItsGaps", testTheSpaceBarGetsTheLeastOfItsGaps),
            ("theBarOutsideItsControlsGoesToTheKeys", testTheBarOutsideItsControlsGoesToTheKeys),
            ("startReachesUpAndStopReachesIntoTheTopRow", testStartReachesUpAndStopReachesIntoTheTopRow),
            ("theDeleteKeyReachesTowardsM", testTheDeleteKeyReachesTowardsM),
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

    private static func testReachAboveTheKeysIsTheBarBelowItsControls() {
        // ARCHITECTURE.md, "Dropped taps": the key area takes the strip of the bar below its controls, half the
        // difference of their heights (the controls are centred in the bar).
        TestSupport.expectEqual(KeyboardMetrics.barHeight, 56)
        TestSupport.expectEqual(KeyboardMetrics.barControlHeight, 38)
        TestSupport.expectEqual(KeyboardMetrics.compactBarHeight, 40)
        TestSupport.expectEqual(KeyboardMetrics.compactBarControlHeight, 32)
        TestSupport.expectEqual(KeyboardMetrics.reachAboveKeys(compact: false), 9)
        TestSupport.expectEqual(KeyboardMetrics.reachAboveKeys(compact: true), 4)
        // A touch there is the top-row key below it, in every layer, portrait and landscape.
        for (width, height, compact) in [(402.0, KeyboardMetrics.regularHeight, false), (874, KeyboardMetrics.compactHeight, true)] {
            let reach = KeyboardMetrics.reachAboveKeys(compact: compact)
            for layer in [KeyboardLayer.letters, .numbers, .symbols] {
                let placed = keys(layer, width: width, height: height)
                let top = placed.map(\.frame.y).min()!
                for key in placed where key.frame.y == top {
                    let hit = KeyboardLayout.nearestKey(toX: key.frame.midX, y: -reach, in: placed).map { placed[$0].action }
                    TestSupport.expectEqual(hit, key.action)
                }
            }
        }
    }

    private static func testTheSpaceBarGetsTheLeastOfItsGaps() {
        // ARCHITECTURE.md, "A stricter space bar": a point outside the space bar counts as `spaceMissPenalty`
        // (8 pt) farther from it, so a low tap on the bottom letter row types its letter.
        TestSupport.expectEqual(KeyboardLayout.spaceMissPenalty, 8)
        for globe in [false, true] {
            let letters = keys(.letters, globe: globe)
            func hit(_ x: Double, _ y: Double) -> KeyAction? {
                KeyboardLayout.nearestKey(toX: x, y: y, in: letters).map { letters[$0].action }
            }
            let space = key(.space, in: letters).frame, n = key(.character("n"), in: letters).frame
            TestSupport.expect(n.midX > space.x && n.midX < space.maxX, "n is not above the space bar")
            // The 12 pt gap above it: 10 pt for the letter, 2 pt for the space bar.
            TestSupport.expectEqual(hit(n.midX, n.maxY + 6), .character("n"))
            TestSupport.expectEqual(hit(n.midX, space.y - 2.5), .character("n"))
            TestSupport.expectEqual(hit(n.midX, space.y - 1.5), .space)
            // Inside its frame, and below it, the space bar as before.
            TestSupport.expectEqual(hit(n.midX, space.y + 0.5), .space)
            TestSupport.expectEqual(hit(space.midX, space.maxY + 3), .space)
            // The gaps beside it go to the neighbours, right up to its edge.
            let left = letters[letters.firstIndex { $0.action == .space }! - 1]
            TestSupport.expectEqual(hit(space.x - 0.5, space.midY), left.action)
            TestSupport.expectEqual(hit(space.maxX + 0.5, space.midY), .returnKey)
            TestSupport.expectEqual(hit(space.x + 0.5, space.midY), .space)
            // Other keys are unchanged: the gap between two letters still splits in half.
            let m = key(.character("m"), in: letters).frame
            TestSupport.expectEqual(hit(n.maxX + 0.4 * (m.x - n.maxX), n.midY), .character("n"))
            TestSupport.expectEqual(hit(n.maxX + 0.6 * (m.x - n.maxX), n.midY), .character("m"))
        }
        // In landscape the letters take the whole 7 pt gap above it.
        let landscape = keys(.letters, width: 874, height: KeyboardMetrics.compactHeight)
        let space = key(.space, in: landscape).frame, n = key(.character("n"), in: landscape).frame
        TestSupport.expect(n.midX > space.x && n.midX < space.maxX, "n is not above the landscape space bar")
        let hit = KeyboardLayout.nearestKey(toX: n.midX, y: space.y - 0.5, in: landscape).map { landscape[$0].action }
        TestSupport.expectEqual(hit, .character("n"))
    }

    private static func testTheBarOutsideItsControlsGoesToTheKeys() {
        // ARCHITECTURE.md, "Reach above the keys" (2026-10-18): any point of the bar outside every control's frame goes
        // to the keys (each control's tap area is exactly its frame, so no point is dead); with no control frames
        // reported yet, only the strip below the controls. Code review replaced a 4 pt slop around each control.
        let bar = KeyboardMetrics.barHeight
        let menu = KeyRect(x: 8, y: 9, width: 38, height: 38), start = KeyRect(x: 300, y: 9, width: 92, height: 38)
        func goes(_ x: Double, _ y: Double, compact: Bool = false, _ controls: [KeyRect] = [menu, start]) -> Bool {
            KeyboardMetrics.barPointGoesToKeys(x: x, y: y, barHeight: compact ? KeyboardMetrics.compactBarHeight : bar,
                                               compact: compact, controls: controls)
        }
        // Empty bar space, top to bottom, and the status line's place in the middle.
        TestSupport.expect(goes(150, 0) && goes(150, menu.midY) && goes(150, bar - 0.5), "empty bar space kept from the keys")
        // On a control, its edges included, the bar keeps the touch; just outside, the keys take it.
        TestSupport.expect(!goes(20, menu.midY), "the menu button")
        TestSupport.expect(!goes(menu.maxX, menu.midY) && !goes(start.x, start.maxY), "a control's edge")
        TestSupport.expect(goes(menu.maxX + 0.5, menu.midY), "just right of the menu button")
        TestSupport.expect(goes(350, start.maxY + 0.5), "just below the Start capsule")
        TestSupport.expect(goes(start.x - 0.5, start.y - 0.5), "just outside the Start capsule's corner")
        // Outside the bar, nothing.
        TestSupport.expect(!goes(150, -1) && !goes(150, bar + 1), "outside the bar")
        // No frames yet: only the strip below the controls (9 pt in portrait, 4 in landscape).
        TestSupport.expect(goes(150, bar - 8.5, []) && !goes(150, bar - 9.5, []), "portrait strip without frames")
        let compactBar = KeyboardMetrics.compactBarHeight
        TestSupport.expect(goes(150, compactBar - 3.5, compact: true, []) && !goes(150, compactBar - 4.5, compact: true, []),
                           "landscape strip without frames")
    }

    private static func testStartReachesUpAndStopReachesIntoTheTopRow() {
        // ARCHITECTURE.md, "Reach and touch regions": the Start capsule's tap area is its frame inset by
        // `startHitInset` (6 pt) at the sides and bottom, reaching up to the bar's top; while dictation is starting
        // or recording it also reaches down through the top key row, to halfway into the gap below it.
        TestSupport.expectEqual(KeyboardMetrics.startHitInset, 6)
        for (width, height, compact) in [(402.0, KeyboardMetrics.regularHeight, false), (874, KeyboardMetrics.compactHeight, true)] {
            let bar = compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight
            let control = compact ? KeyboardMetrics.compactBarControlHeight : KeyboardMetrics.barControlHeight
            let top = KeyboardMetrics.reachAboveKeys(compact: compact)
            let capsule = KeyRect(x: width - 100, y: top, width: 92, height: control)
            let idle = KeyboardMetrics.startTapArea(capsule: capsule, barHeight: bar, compact: compact, capturing: false)
            let stop = KeyboardMetrics.startTapArea(capsule: capsule, barHeight: bar, compact: compact, capturing: true)
            TestSupport.expectEqual(idle, KeyRect(x: capsule.x + 6, y: 0, width: 80, height: capsule.maxY - 6))
            TestSupport.expectEqual(stop, KeyRect(x: capsule.x + 6, y: 0, width: 80,
                                                  height: bar + KeyboardMetrics.stopReachIntoKeys(compact: compact)))

            // Into the keys only while capturing, and only through the top row: the row below keeps all its keys.
            let metrics = KeyboardMetrics(width: width, height: height)
            TestSupport.expectEqual(KeyboardMetrics.stopReachIntoKeys(compact: compact),
                                    metrics.rowY(0) + metrics.rowHeight + metrics.rowGap / 2)
            let placed = keys(.letters, width: width, height: height)
            for key in placed where key.frame.x < stop.maxX && key.frame.maxX > stop.x {
                let point = (x: min(max(key.frame.midX, stop.x), stop.maxX), y: key.frame.midY)
                let underStop = KeyboardMetrics.keyPointGoesToStart(x: point.x, y: point.y, barHeight: bar, start: stop)
                TestSupport.expect(underStop == (key.frame.y == metrics.rowY(0)), "\(key.label) under Stop: \(underStop)")
                TestSupport.expect(!KeyboardMetrics.keyPointGoesToStart(x: point.x, y: point.y, barHeight: bar, start: idle),
                                   "\(key.label) under Start")
            }
            let below = KeyboardMetrics.stopReachIntoKeys(compact: compact)
            TestSupport.expect(KeyboardMetrics.keyPointGoesToStart(x: stop.midX, y: below, barHeight: bar, start: stop)
                               && !KeyboardMetrics.keyPointGoesToStart(x: stop.midX, y: below + 0.5, barHeight: bar, start: stop)
                               && !KeyboardMetrics.keyPointGoesToStart(x: stop.x - 0.5, y: 1, barHeight: bar, start: stop),
                               "Stop's edges in the keys")
            // Points above the key area are the bar's (`barPointGoesToKeys`), never this test's.
            TestSupport.expect(!KeyboardMetrics.keyPointGoesToStart(x: stop.midX, y: -1, barHeight: bar, start: stop),
                               "above the key area")
            TestSupport.expect(!KeyboardMetrics.keyPointGoesToStart(x: stop.midX, y: 1, barHeight: bar, start: nil), "no frame")

            // In the bar: everything above the capsule is Start's; the ring below and beside it is still the keys'.
            func goes(_ x: Double, _ y: Double, _ area: KeyRect) -> Bool {
                KeyboardMetrics.barPointGoesToKeys(x: x, y: y, barHeight: bar, compact: compact, controls: [area])
            }
            TestSupport.expect(!goes(capsule.midX, 0, idle) && !goes(capsule.midX, top / 2, idle), "above Start")
            TestSupport.expect(goes(capsule.midX, idle.maxY + 0.5, idle) && goes(capsule.x + 5.5, capsule.midY, idle),
                               "the ring around Start")
            TestSupport.expect(!goes(capsule.midX, bar, stop), "below Stop")
        }
    }

    private static func testTheDeleteKeyReachesTowardsM() {
        // ARCHITECTURE.md, "A wider delete key": delete's frame counts `deleteReachLeft` (8 pt) further left.
        TestSupport.expectEqual(KeyboardLayout.deleteReachLeft, 8)
        for globe in [false, true] {
            let letters = keys(.letters, globe: globe)
            func hit(_ x: Double, _ y: Double) -> KeyAction? {
                KeyboardLayout.nearestKey(toX: x, y: y, in: letters).map { letters[$0].action }
            }
            let delete = key(.delete, in: letters).frame, m = key(.character("m"), in: letters).frame
            let gap = delete.x - m.maxX
            TestSupport.expect(gap > 8, "the gap beside m is only \(gap)")
            // The gap splits at 8 pt plus half the rest from delete's edge, not at half.
            let split = 8 + (gap - 8) / 2
            TestSupport.expectEqual(hit(delete.x - split + 0.5, delete.midY), .delete)
            TestSupport.expectEqual(hit(delete.x - split - 0.5, delete.midY), .character("m"))
            TestSupport.expectEqual(hit(m.maxX - 0.5, delete.midY), .character("m"))
            // Above and below its frame, the gaps split as before.
            let l = key(.character("l"), in: letters).frame, ret = key(.returnKey, in: letters).frame
            TestSupport.expectEqual(hit(delete.midX, delete.y - (delete.y - l.maxY) / 2 + 0.5), .delete)
            TestSupport.expectEqual(hit(delete.midX, delete.y - (delete.y - l.maxY) / 2 - 0.5), .character("l"))
            TestSupport.expectEqual(hit(delete.midX, delete.maxY + (ret.y - delete.maxY) / 2 - 0.5), .delete)
            TestSupport.expectEqual(hit(delete.midX, delete.maxY + (ret.y - delete.maxY) / 2 + 0.5), .returnKey)
        }
    }
}
