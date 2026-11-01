import Foundation

/// The menu panel's colours (ARCHITECTURE.md, "Top row", menu), as sRGB components so their contrast is testable:
/// a white card in light mode and a dark grey one in dark mode, with text that reads at WCAG AA (4.5:1) on it, and
/// "Open LocalFlow" in the brand's accent (`BrandPalette.link`). The round 1 card was the key fill (grey in dark
/// mode), where Apple's blue measured 1.7:1. Pure.
struct MenuPalette: Equatable {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    var card: RGB
    var primary: RGB
    var secondary: RGB
    /// "Open LocalFlow": aurora on the dark card, a deep aurora on the light one.
    var link: RGB
    /// The text-width choice: its track on the card, and the chosen segment on the track; `primary` text reads on both.
    var track: RGB
    var selectedSegment: RGB

    /// `highContrast`: Increase Contrast, which darkens the light mode's secondary text and brightens the dark mode's.
    init(dark: Bool, highContrast: Bool) {
        if dark {
            card = RGB(0.173, 0.173, 0.180)
            primary = RGB(1, 1, 1)
            secondary = Self.secondary(dark: true, highContrast: highContrast)
            track = RGB(0.235, 0.235, 0.245)
            selectedSegment = highContrast ? RGB(0.36, 0.36, 0.37) : RGB(0.42, 0.42, 0.43)
        } else {
            card = RGB(1, 1, 1)
            primary = RGB(0, 0, 0)
            secondary = Self.secondary(dark: false, highContrast: highContrast)
            track = highContrast ? RGB(0.86, 0.86, 0.88) : RGB(0.92, 0.92, 0.93)
            selectedSegment = RGB(1, 1, 1)
        }
        link = BrandPalette(dark: dark, highContrast: highContrast).link
    }

    /// The secondary text's ink, which the light keyboard's status line shares (`BrandPalette.statusInk`).
    static func secondary(dark: Bool, highContrast: Bool) -> RGB {
        if dark { return highContrast ? RGB(0.84, 0.84, 0.86) : RGB(0.68, 0.68, 0.70) }
        return highContrast ? RGB(0.28, 0.28, 0.29) : RGB(0.39, 0.39, 0.40)
    }

    /// WCAG contrast ratio, 1 to 21.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (high, low) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (high + 0.05) / (low + 0.05)
    }
}
