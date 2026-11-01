import Foundation

/// The recording wave (ARCHITECTURE.md, "Keyboard look"): one row of dots along the island's middle line that shows the
/// voice, its dots growing and brightening with what was said, and comes to rest in the mark's dot at the right. In
/// silence it is one calm row of equal dots. Round 9 (owner): ours rather than the reference video's braided strands over
/// a dim dot grid. Round 10 (owner: "slow, consistent and wavelike"): the row's shape is the voice's own, the last `span`
/// seconds of it, the newest beside the mark's dot; what was said moves left as it ages, so a syllable is a pulse that
/// crosses the row at the wait shimmer's pace. The view records the level (`LevelFollower`) into a `Trace` every frame.
/// Which dot is how large and bright for a trace and a moment is all here, so the view only draws. Pure.
enum DotWave {
    /// One dot, in the box's points: its centre, radius, and brightness from 0 (unlit) to 1.
    struct Dot: Equatable, Sendable {
        var x: Double
        var y: Double
        var radius: Double
        var brightness: Double
    }

    /// The distance between neighbouring dots, in points.
    static let pitch = 6.2
    /// A dot at rest: its radius and brightness (a calm line, not a texture).
    static let restRadius = 1.4
    static let restBrightness = 0.5
    /// A dot at the top of the swell, still clear of its neighbours. Round 10 (owner: "a tiny bit bigger"): the dots,
    /// the swell and the mark's dot are about 16 percent larger than round 9's.
    static let fullRadius = 2.85
    /// The mark's dot: its radius at rest, and how much the voice swells it.
    static let markRadius = 2.55
    static let markGrowth = 0.35
    /// How many seconds of the voice the row shows: a syllable crosses it in this long.
    static let span = 1.1
    /// One sweep of the wait's shimmer, in seconds, entering at the left and leaving at the right; the wave keeps its pace.
    static let shimmerPeriod = 1.1
    /// The shimmer's room inside the wait's pill, on each side.
    static let shimmerInset = 11.0
    /// The wave's and the shimmer's frame interval: at most 60 frames a second, even on a 120 Hz display.
    static let frameInterval = 1.0 / 60

    /// How much of the swell a level (0 to 1, clamped; not a number is silence) takes: nothing for the quietest levels,
    /// a background murmur, then rising faster than the level, so a loud word looks clearly larger than a quiet one.
    static func voice(_ level: Double) -> Double {
        guard !level.isNaN else { return 0 }
        let level = min(max(level, 0), 1)
        return pow(max(level - 0.15, 0) / 0.85, 1.5)
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

    /// How far the row lets the voice lift the dot `u` of the way along it (0 at the left end, 1 at the right): none at
    /// the left end, so the voice rises out of the line there, all of it from a little past the middle, a little less
    /// beside the mark's dot, which it settles into.
    private static func envelope(_ u: Double) -> Double {
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        return smooth(0, 0.6, u) * (1 - 0.2 * smooth(0.85, 1, u))
    }

    /// How far the voice lifts the dot `u` of the way along the row, 0 at rest and 1 at the top of the swell, where
    /// `levelAt(age)` is the level heard `age` seconds ago: the dot at `u` shows what was said `(1 - u) * span` ago.
    static func lift(at u: Double, levelAt: (Double) -> Double) -> Double {
        let u = u.isFinite ? min(max(u, 0), 1) : 0
        let lift = voice(levelAt((1 - u) * span)) * envelope(u)
        return lift.isFinite ? min(max(lift, 0), 1) : 0
    }

    /// The lift for the voice in `trace` at the moment `now`.
    static func lift(at u: Double, trace: Trace, now: Double) -> Double {
        lift(at: u) { trace.level(age: $0, now: now) }
    }

    /// The wave's dots in a `width` by `height` box for the voice `levelAt(age)` (as `lift`). No room, no dots.
    static func dots(width: Double, height: Double, levelAt: (Double) -> Double) -> [Dot] {
        let xs = row(width: width, height: height, trailing: markRoom)
        guard xs.count > 1 else { return [] }
        let first = xs.first!, length = xs.last! - first
        return xs.map { x in
            let lift = lift(at: (x - first) / length, levelAt: levelAt)
            return Dot(x: x, y: height / 2, radius: restRadius + (fullRadius - restRadius) * lift,
                       brightness: restBrightness + (1 - restBrightness) * lift)
        }
    }

    /// The wave's dots for the voice in `trace` at the moment `now`.
    static func dots(trace: Trace, now: Double, width: Double, height: Double) -> [Dot] {
        dots(width: width, height: height) { trace.level(age: $0, now: now) }
    }

    /// The wave's dots for a voice held at `level` for the whole row (with Reduce Motion, the row stands still at each
    /// level).
    static func dots(level: Double, width: Double, height: Double) -> [Dot] {
        dots(width: width, height: height) { _ in level }
    }

    /// An invented moment of speech for the Live Activity's still strip, which cannot animate: three words of different
    /// loudness, newest last.
    private static let stillVoice: [(age: Double, level: Double)] = [(0.12, 0.95), (0.42, 0.7), (0.78, 0.85)]

    /// The Live Activity's strip while recording: the lift at `u` for `stillVoice`, each word a soft pulse.
    static func stillLift(at u: Double) -> Double {
        lift(at: u) { age in
            stillVoice.map { $0.level * exp(-pow((age - $0.age) / 0.09, 2)) }.max() ?? 0
        }
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
        let radius = min(markRadius * (1 + markGrowth * voice(level)), max(height / 2, 0.01))
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

    /// The level the wave draws: the input's, smoothed so it rises with a syllable at once and falls quickly after it
    /// (round 10: syllables read as distinct pulses; round 9 fell over 0.4 s), without stepping between the levels the
    /// keyboard reads (about ten a second).
    struct LevelFollower: Equatable, Sendable {
        /// The time constants of the rise and the fall, in seconds.
        static let rise = 0.025
        static let fall = 0.09

        private(set) var value = 0.0

        /// Moves towards `target` (clamped to 0...1; not a number is silence) over `seconds` of the display's clock.
        mutating func follow(_ target: Double, over seconds: Double) {
            guard seconds > 0 else { return }
            let target = target.isNaN ? 0 : min(max(target, 0), 1)
            let constant = target > value ? Self.rise : Self.fall
            value += (target - value) * (1 - exp(-seconds / constant))
        }
    }

    /// The voice over the last `span` seconds, as the view records it each frame: what the row shows. A level read back
    /// is softened over `blur` seconds either side, so levels that arrive ten times a second draw a smooth row, and a dot
    /// changes gently from frame to frame as the row moves.
    struct Trace: Equatable, Sendable {
        /// The softening's standard deviation, in seconds.
        static let blur = 0.06

        private var times: [Double] = []
        private var levels: [Double] = []

        init() {}

        /// Adds the level heard at `time` (clamped to 0...1; not a number is silence). A time that is not after the
        /// last is ignored; samples older than the row shows are dropped.
        mutating func record(_ level: Double, at time: Double) {
            guard time.isFinite, times.last.map({ time > $0 }) ?? true else { return }
            times.append(time)
            levels.append(level.isNaN ? 0 : min(max(level, 0), 1))
            let oldest = time - DotWave.span - 4 * Self.blur
            if let keep = times.firstIndex(where: { $0 >= oldest }), keep > 0 {
                times.removeFirst(keep)
                levels.removeFirst(keep)
            }
        }

        /// The level heard `age` seconds before `now`, softened; 0 where nothing was recorded.
        func level(age: Double, now: Double) -> Double {
            let at = now - age
            guard at.isFinite, !times.isEmpty else { return 0 }
            let reach = 2.5 * Self.blur
            // The first sample in reach, by bisection: the trace is in time order.
            var index = 0, high = times.count
            while index < high {
                let middle = (index + high) / 2
                if times[middle] < at - reach { index = middle + 1 } else { high = middle }
            }
            var sum = 0.0, weights = 0.0
            while index < times.count, times[index] <= at + reach {
                let d = (times[index] - at) / Self.blur
                let weight = exp(-0.5 * d * d)
                sum += weight * levels[index]
                weights += weight
                index += 1
            }
            return weights > 0 ? sum / weights : 0
        }
    }
}
