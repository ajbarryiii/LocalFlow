import Foundation

/// The recording wave (ARCHITECTURE.md, "Keyboard look"): one row of dots along the island's middle line that swells with
/// the voice, its dots growing and brightening in a smooth hump that drifts slowly along the row, and comes to rest in
/// the mark's dot at the right. In silence it is one calm row of equal dots. Round 9 (owner): ours rather than the
/// reference video's braided strands over a dim dot grid. The view advances `phase` while recording; the level is
/// smoothed (`LevelFollower`). Which dot is how large and bright for a level and phase is all here, so the view only
/// draws. Pure.
enum DotWave {
    /// One dot, in the box's points: its centre, radius, and brightness from 0 (unlit) to 1.
    struct Dot: Equatable, Sendable {
        var x: Double
        var y: Double
        var radius: Double
        var brightness: Double
    }

    /// The distance between neighbouring dots, in points.
    static let pitch = 5.4
    /// A dot at rest: its radius and brightness (a calm line, not a texture).
    static let restRadius = 1.2
    static let restBrightness = 0.5
    /// A dot at the top of the swell, still clear of its neighbours.
    static let fullRadius = 2.45
    /// The mark's dot: its radius at rest, and how much the voice swells it.
    static let markRadius = 2.2
    static let markGrowth = 0.25
    /// How fast the swell drifts along the row while recording, in radians a second: slow, under a fifth of a cycle.
    static let drift = 1.1
    /// The wave's and the shimmer's frame interval: at most 60 frames a second, which their slow motion needs, even on
    /// a 120 Hz display.
    static let frameInterval = 1.0 / 60

    /// The drift's phase after `elapsed` seconds of recording.
    static func phase(elapsed: TimeInterval) -> Double { elapsed * drift }

    /// Speech sits high on the level's decibel scale: the power spreads ordinary speech over the swell's height.
    private static func shaped(_ level: Double) -> Double {
        guard !level.isNaN else { return 0 }
        return pow(min(max(level, 0), 1), 1.6)
    }

    /// The row's dots' x positions in a box, leaving `trailing` points at the right; centred, a pitch apart, with room for
    /// the largest dot at each end. Empty without room for three dots or for the largest dot's height.
    private static func row(width: Double, height: Double, trailing: Double) -> [Double] {
        let margin = fullRadius
        let span = width - trailing - 2 * margin
        guard height >= 2 * fullRadius, span >= 2 * pitch else { return [] }
        let columns = Int((span / pitch).rounded(.down))
        let minX = margin + (span - Double(columns) * pitch) / 2
        return (0 ... columns).map { minX + Double($0) * pitch }
    }

    /// The room the mark's dot takes at the row's right: its widest, and a gap.
    private static let markRoom = 2 * markRadius * (1 + markGrowth) + pitch * 0.9

    /// The wave's dots in a `width` by `height` box for an input `level` (0 to 1, clamped; not a number is silence) at
    /// drift `phase`. No room, no dots.
    static func dots(level: Double, phase: Double, width: Double, height: Double) -> [Dot] {
        let xs = row(width: width, height: height, trailing: markRoom)
        guard xs.count > 1 else { return [] }
        let voice = shaped(level)
        let first = xs.first!, length = xs.last! - first
        return xs.map { x in
            let lift = swell(at: (x - first) / length, voice: voice, phase: phase)
            return Dot(x: x, y: height / 2, radius: restRadius + (fullRadius - restRadius) * lift,
                       brightness: restBrightness + (1 - restBrightness) * lift)
        }
    }

    /// How far the swell lifts the dot `u` of the way along the row (0 at the left end, 1 at the right) for a level
    /// (0 to 1, clamped; not a number is silence) at drift `phase`: 0 at rest, 1 at the top of a full swell. Zero at both
    /// ends, so the swell rises out of the line at the left and settles into the mark's dot at the right. The Live
    /// Activity's strip draws the same swell.
    static func lift(at u: Double, level: Double, phase: Double) -> Double {
        swell(at: u, voice: shaped(level), phase: phase)
    }

    private static func swell(at u: Double, voice: Double, phase: Double) -> Double {
        let u = u.isFinite ? min(max(u, 0), 1) : 0
        let phase = phase.isFinite ? phase : 0
        let envelope = pow(sin(Double.pi * u), 0.9)
        return voice * envelope * (0.62 + 0.38 * sin(2 * .pi * 1.3 * u - phase))
    }

    /// How bright the shimmer's spot makes the dot `u` of the way along a row whose spot is at `sweep` (as `shimmer`):
    /// 0 away from it, 1 under it.
    static func glow(at u: Double, sweep: Double, spread: Double = 0.22) -> Double {
        let d = ((u.isFinite ? u : 0) - (sweep.isFinite ? sweep : -1)) / max(spread, 0.01)
        let glow = exp(-d * d)
        return glow < 0.01 ? 0 : glow
    }

    /// The mark's dot the row settles into: on the middle line at the box's right, swelling a little with the voice.
    static func markDot(level: Double, width: Double, height: Double) -> Dot {
        let widest = markRadius * (1 + markGrowth)
        let radius = min(markRadius * (1 + markGrowth * shaped(level)), max(height / 2, 0.01))
        return Dot(x: max(width - widest, radius), y: height / 2, radius: radius, brightness: 1)
    }

    /// The wait's shimmer, the wave's row at rest with a brighter, larger spot centred `sweep` of the way along it (0 at
    /// the left end, 1 at the right; outside that it is entering or leaving).
    static func shimmer(sweep: Double, width: Double, height: Double) -> [Dot] {
        let xs = row(width: width, height: height, trailing: 0)
        guard xs.count > 1 else { return [] }
        let first = xs.first!, length = xs.last! - first
        let spread = max(0.22, pitch / length)
        return xs.map { x in
            let lift = glow(at: (x - first) / length, sweep: sweep, spread: spread)
            return Dot(x: x, y: height / 2, radius: restRadius + (fullRadius - restRadius) * 0.7 * lift,
                       brightness: 0.45 + 0.55 * lift)
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
