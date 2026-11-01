import Foundation

/// The menu panel's colours (ARCHITECTURE.md, "Top row", menu), as sRGB components so their contrast is testable:
/// a white card in light mode and a dark grey one in dark mode, with text that reads at WCAG AA (4.5:1) on it.
/// The round 1 card was the key fill (grey in dark mode), where Apple's blue measured 1.7:1. Pure.
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
    /// "Open LocalFlow": a blue that keeps its contrast on the card.
    var link: RGB

    /// `highContrast`: Increase Contrast, which darkens the light mode's secondary text and brightens the dark mode's.
    init(dark: Bool, highContrast: Bool) {
        if dark {
            card = RGB(0.173, 0.173, 0.180)
            primary = RGB(1, 1, 1)
            secondary = highContrast ? RGB(0.84, 0.84, 0.86) : RGB(0.68, 0.68, 0.70)
            link = RGB(0.392, 0.710, 1)
        } else {
            card = RGB(1, 1, 1)
            primary = RGB(0, 0, 0)
            secondary = highContrast ? RGB(0.28, 0.28, 0.29) : RGB(0.39, 0.39, 0.40)
            link = RGB(0, 0.384, 0.800)
        }
    }

    /// WCAG contrast ratio, 1 to 21.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (high, low) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (high + 0.05) / (low + 0.05)
    }
}
