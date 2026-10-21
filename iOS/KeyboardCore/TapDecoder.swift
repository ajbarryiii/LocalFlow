import Foundation

/// Which key a soft tap types (ARCHITECTURE.md, "Soft key edges"): the key nearest the touch-down point,
/// unless the tap is outside that key's centre box and a letter or the space bar is likelier by the
/// rule's margin under the prior and the touch model. Pure, Float64. Reference: localflow-swipe
/// `tap/decide.py` (rule "strict") and `tap/touch.py`.
///
/// - Lengths of the touch model are in letter pitches: the distance between neighbouring top-row
///   letter centres (`letterPitch`).
/// - Only letters and the space bar are ever chosen; if the nearest key is anything else, it types.
/// - Ties go to the earlier key in layout order, as `argmax` does.
struct TapDecoder: Equatable, Sendable {
    /// Where a finger lands when it aims at a key: the key's centre (for the space bar, uniform along the
    /// middle `spaceSpread` of its width) plus (0, `offsetY`), plus noise: with weight 1 − `tailWeight` a
    /// Gaussian with sd (`sigma`, `sigma` × `ratio`), with `tailWeight` the same scaled by `tailScale`.
    struct TouchModel: Equatable, Sendable {
        var sigma = 0.25
        var ratio = 1.0
        var offsetY = 0.1
        var tailWeight = 0.05
        var tailScale = 2.0
        var spaceSpread = 0.6

        static let standard = TouchModel()
    }

    /// `centre`: the centre box as a fraction of the key's width and height. `margin`: the posterior
    /// odds an override needs. `maxSurprise`: no override when the recent surprise (bits) exceeds it;
    /// nil turns the gate off.
    struct Rule: Equatable, Sendable {
        var centre: Double
        var margin: Double
        var maxSurprise: Double?
    }

    var touch: TouchModel
    var rule: Rule

    /// The prior's columns: a–z, then the space bar (`TapPrior.output`).
    static let outputCount = 27

    /// The OUTPUT column of a key's action, or nil for keys a prior never chooses.
    static func outputIndex(of action: KeyAction) -> Int? {
        switch action {
        case .space:
            return 26
        case .character(let character):
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                  ("a" ... "z").contains(scalar) else { return nil }
            return Int(scalar.value - Unicode.Scalar("a").value)
        default:
            return nil
        }
    }

    /// The distance between neighbouring top-row letter centres, or nil without two of them.
    static func letterPitch(in keys: [PlacedKey]) -> Double? {
        let letters = keys.filter { outputIndex(of: $0.action).map { $0 < 26 } ?? false }
        guard let top = letters.map(\.frame.y).min() else { return nil }
        let centres = letters.filter { $0.frame.y == top }.map(\.frame.midX).sorted()
        guard centres.count >= 2, let first = centres.first, let last = centres.last, last > first else { return nil }
        return (last - first) / Double(centres.count - 1)
    }

    /// The log density (per square point) of a tap at (x, y) under each key, in `keys` order; −∞ for keys
    /// other than letters and space. Empty without a letter pitch.
    func logLikelihoods(x: Double, y: Double, keys: [PlacedKey]) -> [Double] {
        guard let pitch = Self.letterPitch(in: keys) else { return [] }
        let sx = touch.sigma * pitch, sy = touch.sigma * touch.ratio * pitch
        return keys.map { key in
            guard Self.outputIndex(of: key.action) != nil else { return -.infinity }
            let half = key.action == .space ? touch.spaceSpread * key.frame.width / 2 : 0
            let dx0 = x - (key.frame.midX - half), dx1 = x - (key.frame.midX + half)
            let dy = y - (key.frame.midY + touch.offsetY * pitch)
            let main = Self.component(dx0: dx0, dx1: dx1, dy: dy, sx: sx, sy: sy)
            guard touch.tailWeight > 0 else { return main }
            let tail = Self.component(dx0: dx0, dx1: dx1, dy: dy, sx: sx * touch.tailScale, sy: sy * touch.tailScale)
            return Self.logAddExp(main + log1p(-touch.tailWeight), tail + log(touch.tailWeight))
        }
    }

    /// The key a tap whose touch-down point is (x, y) types: `logPrior` over the OUTPUT columns
    /// (`outputCount` values) and `surprise` in bits (`TapPrior`). Nil only without keys; the nearest key
    /// when the prior has the wrong size or the keys have no letter pitch.
    func decide(x: Double, y: Double, keys: [PlacedKey], logPrior: [Double], surprise: Double) -> KeyAction? {
        guard let near = KeyboardLayout.nearestKey(toX: x, y: y, in: keys) else { return nil }
        let nearest = keys[near]
        guard logPrior.count == Self.outputCount, Self.outputIndex(of: nearest.action) != nil else { return nearest.action }
        let likelihoods = logLikelihoods(x: x, y: y, keys: keys)
        guard likelihoods.count == keys.count else { return nearest.action }
        var scores: [Double] = []
        scores.reserveCapacity(keys.count)
        for (key, likelihood) in zip(keys, likelihoods) {
            scores.append(Self.outputIndex(of: key.action).map { likelihood + logPrior[$0] } ?? -.infinity)
        }
        // The first of equal maxima, as numpy's argmax.
        var best = 0
        for index in scores.indices where scores[index] > scores[best] { best = index }
        guard best != near, scores[best] - scores[near] >= log(rule.margin) else { return nearest.action }
        let frame = nearest.frame
        let halfWidth = frame.width * rule.centre / 2, halfHeight = frame.height * rule.centre / 2
        if abs(x - frame.midX) <= halfWidth, abs(y - frame.midY) <= halfHeight { return nearest.action }
        if let maxSurprise = rule.maxSurprise, !(surprise <= maxSurprise) { return nearest.action }
        return keys[best].action
    }

    /// What a letter tap recorded as `recorded` (its nearest key at touch-down) types now: `decide`'s letter
    /// or space, but `recorded` itself whenever the keys have changed under the point since (a resize: the
    /// point's nearest key is no longer `recorded`) or `decide` would give anything else.
    func resolve(_ recorded: KeyAction, x: Double, y: Double, keys: [PlacedKey], logPrior: [Double], surprise: Double)
        -> KeyAction {
        guard let near = KeyboardLayout.nearestKey(toX: x, y: y, in: keys), keys[near].action == recorded,
              let action = decide(x: x, y: y, keys: keys, logPrior: logPrior, surprise: surprise),
              Self.outputIndex(of: action) != nil else { return recorded }
        return action
    }

    // MARK: Densities

    /// The log density of one Gaussian component around a target segment from a to b, given dx0 = x − a
    /// and dx1 = x − b (a point when they are equal): (Φ((x − a) / s) − Φ((x − b) / s)) / (b − a) across.
    private static func component(dx0: Double, dx1: Double, dy: Double, sx: Double, sy: Double) -> Double {
        let root2Pi = (2 * Double.pi).squareRoot()
        let logY = -0.5 * (dy / sy) * (dy / sy) - log(sy * root2Pi)
        if dx0 == dx1 { return logY + (-0.5 * (dx0 / sx) * (dx0 / sx) - log(sx * root2Pi)) }
        let length = dx0 - dx1
        let logSegment: Double
        if dx1 > 0 {
            // Far beyond the segment's upper end both terms vanish; mirrored for stability.
            let upper = logNdtr(-dx1 / sx), lower = logNdtr(-dx0 / sx)
            logSegment = upper + log1p(-exp(min(lower - upper, 0))) - log(length)
        } else {
            let upper = logNdtr(dx0 / sx), lower = logNdtr(dx1 / sx)
            logSegment = upper + log1p(-exp(min(lower - upper, 0))) - log(length)
        }
        return logY + logSegment
    }

    /// log Φ(z), finite for every finite z, as scipy's `log_ndtr`: log1p(−erfc(z/√2)/2) from −1 up, the
    /// log of erfc below, and the asymptotic series where erfc would underflow.
    static func logNdtr(_ z: Double) -> Double {
        let t = z / 2.0.squareRoot()
        if z >= -1 { return log1p(-erfc(t) / 2) }
        if z > -36 { return log(erfc(-t) / 2) }
        // log Φ(z) = −z²/2 − log(−z) − log √(2π) + log(1 − 1/z² + 3/z⁴ − 15/z⁶ + …).
        let z2 = z * z
        var sum = 1.0, term = 1.0
        for k in 1 ... 12 {
            term *= -Double(2 * k - 1) / z2
            sum += term
            if abs(term) < 1e-17 { break }
        }
        return -z2 / 2 - log(-z) - 0.5 * log(2 * Double.pi) + log(sum)
    }

    /// numpy's `logaddexp`.
    static func logAddExp(_ a: Double, _ b: Double) -> Double {
        if a == b { return a + log(2.0) }
        let d = a - b
        if d > 0 { return a + log1p(exp(-d)) }
        if d <= 0 { return b + log1p(exp(d)) }
        return a + b
    }
}

extension TapDecoder.TouchModel {
    init(_ manifest: SoftKeyEdgesManifest.Touch) {
        self.init(sigma: manifest.sigma, ratio: manifest.ratio, offsetY: manifest.offsetY, tailWeight: manifest.tailWeight,
                  tailScale: manifest.tailScale, spaceSpread: manifest.spaceSpread)
    }
}

extension TapDecoder.Rule {
    /// The bundle's rule, with the surprise gate on.
    init(_ manifest: SoftKeyEdgesManifest.Rule) {
        self.init(centre: manifest.centre, margin: manifest.margin, maxSurprise: manifest.maxSurprise)
    }
}
