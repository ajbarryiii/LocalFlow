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

/// The ridge mark (`RidgeMark`) as a SwiftUI shape: its line, or with `dot` its dot. Stroke the line with
/// `RidgeMarkShape.style(width:)` and fill the dot.
struct RidgeMarkShape: Shape {
    var dot = false

    func path(in rect: CGRect) -> Path {
        let mark = RidgeMark.fitted(in: KeyRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width),
                                                height: Double(rect.height)))
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
    static func style(side: CGFloat) -> StrokeStyle {
        let mark = RidgeMark.fitted(in: KeyRect(x: 0, y: 0, width: Double(side), height: Double(side)))
        return StrokeStyle(lineWidth: CGFloat(mark.lineWidth), lineCap: .round, lineJoin: .round)
    }
}

/// The ridge mark drawn in one colour, `side` points across.
struct RidgeMarkGlyph: View {
    var color: Color
    var side: CGFloat

    var body: some View {
        ZStack {
            RidgeMarkShape().stroke(color, style: RidgeMarkShape.style(side: side))
            RidgeMarkShape(dot: true).fill(color)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
