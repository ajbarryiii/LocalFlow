import SwiftUI
import UIKit

/// `BrandPalette` as UIKit and SwiftUI colours (ARCHITECTURE.md, "Keyboard look").
extension BrandPalette {
    init(_ traits: UITraitCollection) {
        self.init(dark: traits.userInterfaceStyle == .dark, highContrast: traits.accessibilityContrast == .high)
    }

    init(colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
        self.init(dark: colorScheme == .dark, highContrast: contrast == .increased)
    }

    /// A colour that follows light and dark mode and Increase Contrast without re-rendering.
    static func dynamic(_ pick: @escaping @Sendable (BrandPalette) -> RGB) -> UIColor {
        UIColor { UIColor(pick(BrandPalette($0))) }
    }
}

extension UIColor {
    convenience init(_ rgb: BrandPalette.RGB, alpha: CGFloat = 1) {
        self.init(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: alpha)
    }
}

extension Color {
    init(_ rgb: BrandPalette.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// The ridge mark (`RidgeMark`) as a SwiftUI shape: its line, or with `dot` its dot, at `weight`. Stroke the line with
/// `RidgeMarkShape.style(side:weight:)` and fill the dot.
struct RidgeMarkShape: Shape {
    var dot = false
    var weight = 1.0

    func path(in rect: CGRect) -> Path {
        let mark = RidgeMark.fitted(in: KeyRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width),
                                                height: Double(rect.height)), weight: weight)
        var path = Path()
        if dot {
            path.addEllipse(in: CGRect(x: mark.dot.x - mark.dotRadius, y: mark.dot.y - mark.dotRadius,
                                       width: 2 * mark.dotRadius, height: 2 * mark.dotRadius))
        } else {
            path.addLines(mark.line.map { CGPoint(x: $0.x, y: $0.y) })
        }
        return path
    }

    /// The line's stroke in a box `side` points across.
    static func style(side: CGFloat, weight: Double = 1) -> StrokeStyle {
        let mark = RidgeMark.fitted(in: KeyRect(x: 0, y: 0, width: Double(side), height: Double(side)), weight: weight)
        return StrokeStyle(lineWidth: CGFloat(mark.lineWidth), lineCap: .round, lineJoin: .round)
    }
}

/// The ridge mark, its line in `color` and its dot in `dot` (the line's colour by default), `side` points across, its
/// line and dot `weight` times the icon's.
struct RidgeMarkGlyph: View {
    var color: Color
    var dot: Color?
    var side: CGFloat
    var weight = 1.0

    var body: some View {
        ZStack {
            RidgeMarkShape(weight: weight).stroke(color, style: RidgeMarkShape.style(side: side, weight: weight))
            RidgeMarkShape(dot: true, weight: weight).fill(dot ?? color)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
