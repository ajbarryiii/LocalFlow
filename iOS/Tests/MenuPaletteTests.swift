import Foundation

/// The menu panel's colours (ARCHITECTURE.md, "Top row", menu): every text on the card reads at WCAG AA (4.5:1) in
/// light and dark mode, with and without Increase Contrast.
enum MenuPaletteTests {
    static var tests: [TestCase] {
        [
            ("contrastIsWCAGsRatio", testContrastIsWCAGsRatio),
            ("everyMenuTextReadsAtAA", testEveryMenuTextReadsAtAA),
            ("menuCardLeavesNoKeyPeekingOut", testMenuCardLeavesNoKeyPeekingOut),
            ("shortContentFillsTheMenuCard", testShortContentFillsTheMenuCard),
        ]
    }

    private static func testContrastIsWCAGsRatio() {
        let white = MenuPalette.RGB(1, 1, 1), black = MenuPalette.RGB(0, 0, 0)
        TestSupport.expect(abs(MenuPalette.contrast(white, black) - 21) < 1e-9, "white on black")
        TestSupport.expect(abs(MenuPalette.contrast(white, white) - 1) < 1e-9, "white on white")
        TestSupport.expectEqual(MenuPalette.contrast(white, black), MenuPalette.contrast(black, white))
        // Round 1 council: Apple's dark blue on the old grey card.
        let blue = MenuPalette.RGB(0, 145.0 / 255, 1), grey = MenuPalette.RGB(104.0 / 255, 104.0 / 255, 104.0 / 255)
        TestSupport.expect(MenuPalette.contrast(blue, grey) < 2, "the old pair")
    }

    private static func testEveryMenuTextReadsAtAA() {
        for dark in [false, true] {
            for high in [false, true] {
                let palette = MenuPalette(dark: dark, highContrast: high)
                for (name, text) in [("primary", palette.primary), ("secondary", palette.secondary), ("link", palette.link)] {
                    let ratio = MenuPalette.contrast(text, palette.card)
                    TestSupport.expect(ratio >= 4.5, "\(name) \(dark ? "dark" : "light")\(high ? " high" : ""): \(ratio)")
                }
                // The text-width choice's words, on its track and on the chosen segment.
                for (name, fill) in [("track", palette.track), ("selected segment", palette.selectedSegment)] {
                    let ratio = MenuPalette.contrast(palette.primary, fill)
                    TestSupport.expect(ratio >= 4.5, "text on the \(name) \(dark ? "dark" : "light")\(high ? " high" : ""): \(ratio)")
                }
            }
        }
    }

    /// Round 4 council (Opus finding 4): the card was inset 8 points but the keys only 3 to 6, so slivers of dimmed keys
    /// showed at its edges and corners. The card covers every key it lies over, rounded corners included, on the Pro, the
    /// SE and in landscape, and every letter, number and symbol layout: over the three rows above the bottom row when its
    /// content fits there (the bottom row shows whole below it), otherwise over all four.
    private static func testMenuCardLeavesNoKeyPeekingOut() {
        let radius = KeyboardMetrics.keyCornerRadius, cardRadius = MenuCover.cornerRadius
        /// Whether the rounded `key` lies inside the rounded `card`: inside its rectangle, and at each of the card's
        /// corners the key's corner arc inside the card's.
        func covers(_ card: KeyRect, _ key: KeyRect) -> Bool {
            let e = 1e-9
            guard key.x >= card.x - e, key.y >= card.y - e, key.maxX <= card.maxX + e, key.maxY <= card.maxY + e else { return false }
            for (kx, cx, sx) in [(key.x + radius, card.x + cardRadius, 1.0), (key.maxX - radius, card.maxX - cardRadius, -1.0)] {
                for (ky, cy, sy) in [(key.y + radius, card.y + cardRadius, 1.0), (key.maxY - radius, card.maxY - cardRadius, -1.0)] {
                    // The key's corner centre lies in the card's corner zone only when it is outside the card's straight
                    // edges' reach on both axes.
                    guard (kx - cx) * sx < 0, (ky - cy) * sy < 0 else { continue }
                    let distance = ((kx - cx) * (kx - cx) + (ky - cy) * (ky - cy)).squareRoot()
                    if distance + radius > cardRadius + e { return false }
                }
            }
            return true
        }
        for (width, height) in [(402.0, KeyboardMetrics.regularHeight), (375, KeyboardMetrics.regularHeight),
                                (874, KeyboardMetrics.compactHeight), (667, KeyboardMetrics.compactHeight)] {
            let metrics = KeyboardMetrics(width: width, height: height)
            let small = MenuCover.card(metrics: metrics, contentHeight: 100)
            let tall = MenuCover.card(metrics: metrics, contentHeight: 1_000)
            TestSupport.expect(small.x >= 0 && small.maxX <= width && small.y >= 0, "card outside the key area at \(width)")
            TestSupport.expect(tall.maxY <= height, "card below the key area at \(width)")
            for layer in [KeyboardLayer.letters, .numbers, .symbols] {
                for key in KeyboardLayout.keys(for: layer, metrics: metrics, showsGlobe: true, field: .url) {
                    let bottomRow = key.frame.y >= metrics.rowY(3) - 1e-9
                    TestSupport.expect(covers(tall, key.frame), "\(key.label) peeks out of the tall card at \(width)")
                    if bottomRow {
                        TestSupport.expect(key.frame.y >= small.maxY, "the card cuts the bottom row's \(key.label) at \(width)")
                    } else {
                        TestSupport.expect(covers(small, key.frame), "\(key.label) peeks out of the card at \(width)")
                    }
                }
            }
            // Content that fits over the three rows keeps the short card; more takes the tall one.
            let threeRows = small.height
            TestSupport.expectEqual(MenuCover.card(metrics: metrics, contentHeight: threeRows), small)
            TestSupport.expectEqual(MenuCover.card(metrics: metrics, contentHeight: threeRows + 1), tall)
        }
        TestSupport.expect(MenuCover.dimmedAlpha > 0.2 && MenuCover.dimmedAlpha < 0.6, "dimmed alpha \(MenuCover.dimmedAlpha)")
    }

    /// Round 6 council (Opus finding 7): at the default text size the card, which covers whole rows of keys, left about 45
    /// points of empty card under the width choice. Content shorter than the card spreads to fill it: the space left over goes
    /// half above and half below the divider between the session and the tip, so the card's two parts sit at its top and
    /// bottom. Content that fills the card or scrolls in it gets none.
    private static func testShortContentFillsTheMenuCard() {
        for (width, height) in [(402.0, KeyboardMetrics.regularHeight), (375, KeyboardMetrics.regularHeight),
                                (874, KeyboardMetrics.compactHeight)] {
            let metrics = KeyboardMetrics(width: width, height: height)
            for content in [80.0, 117, 140] {
                let card = MenuCover.card(metrics: metrics, contentHeight: content)
                let space = MenuCover.dividerSpace(card: card, contentHeight: content)
                TestSupport.expect(space >= 0, "negative space at \(width)")
                if content <= card.height {
                    TestSupport.expect(abs(content + 2 * space - card.height) < 1e-9, "content and space miss the card at \(width)")
                }
            }
            let tall = MenuCover.card(metrics: metrics, contentHeight: 1_000)
            TestSupport.expectEqual(MenuCover.dividerSpace(card: tall, contentHeight: 1_000), 0)
            TestSupport.expectEqual(MenuCover.dividerSpace(card: tall, contentHeight: tall.height), 0)
        }
    }
}
