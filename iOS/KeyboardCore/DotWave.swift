import Foundation

/// The recording wave (ARCHITECTURE.md, "Keyboard look"): a field of dim dots in the island, staggered row to row,
/// through which two smooth strands of lit dots braid and swell with the voice and come to rest in the mark's dot at
/// the right. In silence the strands lie on the middle row: one calm line of dots. The strands drift slowly while
/// recording (the view advances `phase`); the level they follow is smoothed (`LevelFollower`). Which dots are lit how
/// brightly for a level and phase is all here, so the view only draws. Pure.
enum DotWave {
    /// One dot, in the box's points: its centre, radius, and brightness from 0 (unlit) to 1.
    struct Dot: Equatable, Sendable {
        var x: Double
        var y: Double
        var radius: Double
        var brightness: Double
    }

    /// The distance between neighbouring dots in a row, in points. Rows are staggered by half of it and sit
    /// `rowPitch` apart, so each dot has six even neighbours.
    static let pitch = 4.0
    static let rowPitch = pitch * 0.866
    /// The most rows the field has; fewer where the box is short. Odd, so one row runs along the middle.
    static let maximumRows = 5
    /// A resting dot's brightness: a texture in the island, not a mark.
    static let restBrightness = 0.16
    /// A dot at least this bright is part of a strand.
    static let litThreshold = 0.5
    /// A resting dot's radius, and how much a lit one grows.
    static let restRadius = pitch * 0.26
    static let litGrowth = 0.45
    /// The mark's dot: its radius at rest, and how much the voice swells it.
    static let markRadius = pitch * 0.55
    static let markGrowth = 0.25
    /// How fast the strands drift while recording, in radians a second: slow, under a fifth of a cycle.
    static let drift = 1.1
    /// The wave's and the shimmer's frame interval: at most 60 frames a second, which their slow motion needs, even on
    /// a 120 Hz display.
    static let frameInterval = 1.0 / 60

    /// The drift's phase after `elapsed` seconds of recording.
    static func phase(elapsed: TimeInterval) -> Double { elapsed * drift }

    /// Speech sits high on the level's decibel scale: the power spreads ordinary speech over the strands' height.
    private static func shaped(_ level: Double) -> Double {
        guard !level.isNaN else { return 0 }
        return pow(min(max(level, 0), 1), 1.6)
    }

    /// The field's rows and columns in a box: the rows centred on the middle line, the even rows from `minX` to `maxX`
    /// and the odd ones offset half a pitch inside them. Nil without room for three columns or one row.
    private struct Field {
        var rows: Int
        var minX: Double
        var maxX: Double
        var mid: Double

        init?(width: Double, height: Double, trailing: Double) {
            let margin = restRadius * (1 + litGrowth)
            var rows = maximumRows
            while rows > 1, Double(rows - 1) * rowPitch + 2 * margin > height { rows -= 2 }
            let span = width - trailing - 2 * margin
            guard height >= 2 * margin, span >= 2 * pitch else { return nil }
            self.rows = rows
            let columns = (span / pitch).rounded(.down)
            minX = margin + (span - columns * pitch) / 2
            maxX = minX + columns * pitch
            mid = height / 2
        }

        /// Every dot's place: the row's offset from the middle (in rows) and its x.
        func places() -> [(row: Int, x: Double)] {
            var places: [(row: Int, x: Double)] = []
            let half = rows / 2
            for row in -half ... half {
                let odd = row % 2 != 0
                var x = odd ? minX + pitch / 2 : minX
                while x <= (odd ? maxX - pitch / 2 : maxX) + 1e-9 {
                    places.append((row, x))
                    x += pitch
                }
            }
            return places
        }
    }

    /// The room the mark's dot takes at the field's right: its widest, and a gap of a pitch and a half.
    private static func markRoom() -> Double { 2 * markRadius * (1 + markGrowth) + pitch * 1.5 }

    /// The wave's dots in a `width` by `height` box for an input `level` (0 to 1, clamped; not a number is silence) at
    /// drift `phase`. No room, no dots.
    static func dots(level: Double, phase: Double, width: Double, height: Double) -> [Dot] {
        guard let field = Field(width: width, height: height, trailing: markRoom()) else { return [] }
        let voice = shaped(level)
        let phase = phase.isFinite ? phase : 0
        // The outer row's centre: the strands' widest swing at full voice.
        let reach = Double(field.rows / 2) * rowPitch * voice
        let glow = 0.82 + 0.18 * voice
        let length = field.maxX - field.minX
        return field.places().map { place in
            let u = min(max((place.x - field.minX) / length, 0), 1)
            // Zero at both ends: the strands rise out of the line at the left and settle into the mark's dot at the right.
            let envelope = pow(sin(Double.pi * u), 1.5)
            let first = reach * envelope * sin(2 * .pi * 1.6 * u - phase)
            let second = 0.6 * reach * envelope * sin(2 * .pi * 1.05 * u + 0.8 * phase + 2.1)
            let y = Double(place.row) * rowPitch
            func strand(_ offset: Double) -> Double {
                let d = abs(y - offset) / rowPitch
                return max(0, 1 - d * d)
            }
            let lit = min(1, max(strand(first), 0.85 * strand(second))) * glow
            let brightness = restBrightness + (1 - restBrightness) * lit
            return Dot(x: place.x, y: field.mid + y, radius: restRadius * (1 + litGrowth * lit), brightness: brightness)
        }
    }

    /// The mark's dot the strands settle into: on the middle line at the field's right, swelling a little with the voice.
    static func markDot(level: Double, width: Double, height: Double) -> Dot {
        let widest = markRadius * (1 + markGrowth)
        let radius = min(markRadius * (1 + markGrowth * shaped(level)), max(height / 2, 0.01))
        return Dot(x: max(width - widest, radius), y: height / 2, radius: radius, brightness: 1)
    }

    /// The wait's shimmer: up to three rows of dots across the box, the middle row brighter, and a bright spot centred
    /// `sweep` of the way across (0 at the left end, 1 at the right; outside that it is entering or leaving).
    static func shimmer(sweep: Double, width: Double, height: Double) -> [Dot] {
        guard var field = Field(width: width, height: height, trailing: 0) else { return [] }
        field.rows = min(field.rows, 3)
        let spot = field.minX + (sweep.isFinite ? sweep : 0) * (field.maxX - field.minX)
        let spread = max(width * 0.16, pitch)
        return field.places().map { place in
            let d = (place.x - spot) / spread
            let lift = exp(-d * d) * (place.row == 0 ? 1 : 0.5)
            let base = place.row == 0 ? 0.42 : 0.22
            let brightness = base + (1 - base) * lift
            return Dot(x: place.x, y: field.mid + Double(place.row) * rowPitch,
                       radius: restRadius * (1 + litGrowth * lift), brightness: brightness)
        }
    }

    /// The level the wave draws: the input's, smoothed so the strands rise with a syllable at once and sink slowly
    /// after it, without stepping between the levels the keyboard reads (several a second).
    struct LevelFollower: Equatable, Sendable {
        /// The time constants of the rise and the fall, in seconds.
        static let rise = 0.045
        static let fall = 0.4

        private(set) var value = 0.0

        /// Moves towards `target` (clamped to 0...1; not a number is silence) over `seconds` of the display's clock.
        mutating func follow(_ target: Double, over seconds: Double) {
            guard seconds > 0 else { return }
            let target = target.isNaN ? 0 : min(max(target, 0), 1)
            let constant = target > value ? Self.rise : Self.fall
            value += (target - value) * (1 - exp(-seconds / constant))
        }
    }
}
