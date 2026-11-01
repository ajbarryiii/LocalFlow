import Foundation

/// LocalFlow's ridge mark (ARCHITECTURE.md, "Keyboard look"), as the app icon draws it (Resources/AppIcon.svg, the
/// Wilderness Labs site's 32-unit favicon): a W-shaped ridge line, round-capped and round-joined, over a dot. The
/// keyboard draws it as a vector on Start and in the menu. Pure.
enum RidgeMark {
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// The mark fitted into a box: its line's corners, the dot's centre and the sizes, in the box's coordinates.
    struct Fitted: Equatable, Sendable {
        var line: [Point]
        var dot: Point
        var dotRadius: Double
        var lineWidth: Double
    }

    /// The ridge line's corners, in the mark's 32 units.
    static let line = [Point(x: 5.4, y: 6.1), Point(x: 9.2, y: 19), Point(x: 17.2, y: 8.2), Point(x: 19.4, y: 18.8),
                       Point(x: 24.8, y: 11.6), Point(x: 26.6, y: 15.9)]
    static let lineWidth = 2.4
    static let dot = Point(x: 16, y: 26)
    static let dotRadius = 1.8

    /// The mark's ink (the line with its round caps, and the dot), in its units, with the line and dot `weight` times
    /// their size.
    private static func ink(weight: Double) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let half = lineWidth * weight / 2, radius = dotRadius * weight
        return (min(line.map(\.x).min()! - half, dot.x - radius), min(line.map(\.y).min()! - half, dot.y - radius),
                max(line.map(\.x).max()! + half, dot.x + radius), max(line.map(\.y).max()! + half, dot.y + radius))
    }

    /// The mark at one scale, as large as fits in `box`, its ink centred there. `weight` thickens the line and the dot
    /// (1 is the icon's): at small sizes a heavier mark keeps its W from reading as a scribble.
    static func fitted(in box: KeyRect, weight: Double = 1) -> Fitted {
        let ink = ink(weight: weight)
        let width = ink.maxX - ink.minX, height = ink.maxY - ink.minY
        let scale = max(0, min(box.width / width, box.height / height))
        let originX = box.midX - (ink.minX + width / 2) * scale, originY = box.midY - (ink.minY + height / 2) * scale
        func place(_ p: Point) -> Point { Point(x: originX + p.x * scale, y: originY + p.y * scale) }
        return Fitted(line: line.map(place), dot: place(dot), dotRadius: dotRadius * weight * scale,
                      lineWidth: lineWidth * weight * scale)
    }
}
