import Foundation

/// The menu panel's colours (ARCHITECTURE.md, "Top row", menu): every text on the card reads at WCAG AA (4.5:1) in
/// light and dark mode, with and without Increase Contrast.
enum MenuPaletteTests {
    static var tests: [TestCase] {
        [
            ("contrastIsWCAGsRatio", testContrastIsWCAGsRatio),
            ("everyMenuTextReadsAtAA", testEveryMenuTextReadsAtAA),
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
            }
        }
    }
}
