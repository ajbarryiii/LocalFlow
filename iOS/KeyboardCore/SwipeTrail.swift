import Foundation

/// The swipe trace's shape (ARCHITECTURE.md, "Typing model v4 and swipe typing", "Swipe trace"): the
/// last moments of a running swipe's samples, as points that taper and fade from the finger back to the
/// tail. Pure; the key area draws it. Built from samples in memory only.
enum SwipeTrail {
    /// One point of the trail, in key-area points: the stroke's width there, its opacity, and how far along the trail
    /// it is (0 at the tail, 1 at the finger), which sets its colour (`BrandPalette.trailColor`).
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var alpha: Double
        var fraction: Double
    }

    /// How far back the trail reaches, in seconds of samples.
    static let duration: TimeInterval = 0.15
    /// The stroke's width at the finger, in points; it narrows to nothing at the tail.
    static let maximumWidth: Double = 8
    /// The stroke's opacity at the finger by default; it fades to transparent at the tail. The keyboard passes its
    /// palette's (`BrandPalette.trailAlpha`), which its brand colours need.
    static let maximumAlpha: Double = 0.45

    /// The trail's points, oldest first and the finger (the newest sample) last: every sample at most
    /// `window` seconds older than the finger, walking back from it, and at least the last two. A sample
    /// stamped later than one after it counts as no newer than that one, so ages never decrease towards
    /// the tail. Width and opacity follow the age: full at the finger, zero at the oldest point (by
    /// position along the trail when every age is the same). Fewer than two samples draw nothing.
    static func points(from samples: [SwipeSample], window: TimeInterval = duration,
                       maximumWidth: Double = maximumWidth, maximumAlpha: Double = maximumAlpha) -> [Point] {
        guard samples.count >= 2, let now = samples.last?.t else { return [] }
        var ages: [Double] = [0]
        var age = 0.0
        for sample in samples.dropLast().reversed() {
            age = max(age, now - sample.t)
            guard age <= window || ages.count < 2 else { break }
            ages.append(age)
        }
        let first = samples.count - ages.count
        let span = ages.last ?? 0
        let last = Double(ages.count - 1)
        return samples[first...].enumerated().map { offset, sample in
            let fraction = span > 0 ? 1 - ages[ages.count - 1 - offset] / span : Double(offset) / last
            return Point(x: sample.x, y: sample.y, width: maximumWidth * fraction, alpha: maximumAlpha * fraction, fraction: fraction)
        }
    }
}
