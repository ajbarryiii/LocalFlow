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

/// The recording wave (ARCHITECTURE.md, "Top row"): the ridge mark's line come alive across the bar's middle. One corner
/// per input level, the newest at the right, alternately above and below the middle line as the mark's ridge is, each
/// as far from it as its level is loud; older corners flow left as levels arrive. Pure.
enum RidgeWave {
    /// The distance between corners, in points.
    static let step = 11.0

    /// The stroke's width in a wave `height` points tall: the mark's proportion, at least 1.5 pt.
    static func lineWidth(height: Double) -> Double { max(1.5, height * 0.075) }

    /// The room the stroke's round caps and joins need inside the box.
    static func inset(height: Double) -> Double { lineWidth(height: height) / 2 + 0.5 }

    /// How far a silent level's corner sits from the middle line: a gentle ridge, so the wave never reads as dead.
    static func quietAmplitude(height: Double) -> Double { max(0.75, (height / 2 - inset(height: height)) * 0.1) }

    /// The wave's corners in a `width` by `height` box, left to right. `levels` are the latest input levels, oldest
    /// first (0 to 1, clamped; not a number counts as silence); `serial` is how many levels have arrived in all, which
    /// keeps each level on its side of the middle line as it travels. `progress` (0 to 1) is how far the wave has
    /// flowed since the newest level arrived: at 0 every corner sits one `step` right of its place, at 1 in it. Corners
    /// older than the levels are quiet, out to the left edge. No room, no corners.
    static func corners(levels: [Float], serial: Int, width: Double, height: Double, progress: Double) -> [RidgeMark.Point] {
        let inset = inset(height: height)
        guard width > 2 * inset, height > 2 * inset else { return [] }
        let progress = min(max(progress, 0), 1)
        let newestX = width - inset + (1 - progress) * step
        let oldestAge = Int(((newestX - inset) / step).rounded(.up))
        // The loudest corner keeps a little air above and below it.
        let mid = height / 2, quiet = quietAmplitude(height: height), loud = (mid - inset) * 0.85
        return (0 ... oldestAge).reversed().map { age in
            let index = levels.count - 1 - age
            let level = index >= 0 && levels[index].isFinite ? Double(min(max(levels[index], 0), 1)) : 0
            // Speech sits high on the level's decibel scale: the power spreads ordinary speech over the height.
            let amplitude = quiet + (loud - quiet) * pow(level, 1.6)
            let number = serial - 1 - age
            let above = (number % 2 + 2) % 2 == 0
            return RidgeMark.Point(x: newestX - Double(age) * step, y: above ? mid - amplitude : mid + amplitude)
        }
    }
}
