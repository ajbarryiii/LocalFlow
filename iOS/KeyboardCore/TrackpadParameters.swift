import Foundation

/// Every trackpad-mode constant, in one place. Distances are in points and times in seconds.
///
/// Measured on Apple's keyboard (ARCHITECTURE.md, "Measured Apple keyboard behavior", and the
/// calibration report: iOS 26.4 simulator, XCUITest drags with the floating cursor logged):
/// - Activation only by the timer, 0.381 s after touch-down on space, if the finger is then within
///   16 pt (straight line) of its touch-down point. Movement before activation is discarded.
/// - Gain depends only on the finger's 2D step per delivered touch event, s = |Δ|, the same on both
///   axes and in both directions, independent of the time between events:
///   g = 1 + 0.04·s² up to 2 pt, then 1.16 + 0.16·(s − 2) up to 5.92 pt, then 1.787·(s/5.92)^0.389.
///   The cursor moves g(s)·Δ per event. `eventStepScale` corrects s if a 120 Hz device turns out to
///   deliver smaller steps than the 60 Hz simulator did.
/// - A 2D floating point starts at the caret; the caret is the boundary nearest the point on the line
///   whose center is nearest. No hysteresis, dead zone or momentum. Line ends do not wrap. The point
///   is clamped to [1.5, width - 1.5] horizontally and to [first line center - 7, last line center
///   + 8] vertically, and overshoot is not remembered.
/// Apple has no drag-to-activate, so that stays off by default.
struct TrackpadParameters: Equatable, Sendable {
    var holdDuration: TimeInterval = 0.381
    /// Straight-line movement from touch-down tolerated at the hold timer (16.0 activates, 16.33 not).
    var holdSlop: Double = 16
    /// LocalFlow's own drag-along-space activation; off (Apple has none, and it would conflict with
    /// the hold slop).
    var dragActivationDistance: Double = .infinity

    // The measured gain curve.
    var quadraticCoefficient = 0.04
    var quadraticLimit: Double = 2
    var linearSlope = 0.16
    var linearLimit = 5.92
    var powerCoefficient = 1.787
    var powerExponent = 0.389
    /// Scales the measured per-event step before the curve; 1 reproduces the simulator measurement.
    var eventStepScale = 1.0

    /// The user's multipliers (`LocalFlowSettings`): sensitivity scales the finger movement, and
    /// acceleration scales how far the gain rises above 1.
    var sensitivity = 1.0
    var acceleration = 1.0

    /// The point's clamps: this far inside the text width, and this far above the first line's center
    /// and below the last line's center.
    var horizontalInset = 1.5
    var topOvershoot: Double = 7
    var bottomOvershoot: Double = 8
    /// While the proxy may still show more lines, the point may run this many lines past the known
    /// text before it is held.
    var pendingLines = 1.5
    /// Edge probes in a row whose context stayed unchanged (ambiguous: an ignored step or a blank
    /// line) before travel toward that edge is discarded until the context changes.
    var maximumAmbiguousProbes = 8
    /// Re-read the proxy's context when the cursor gets this many characters from a snapshot edge.
    var resnapshotMargin = 6
    /// How long to wait for the proxy to reflect an adjustment before trusting what it reports.
    var syncTimeout: TimeInterval = 0.3
    /// How long after the finger lifts (or after the last adjustment issued since) pending
    /// adjustments may still land.
    var settleTimeout: TimeInterval = 0.5
    /// The field's text width is estimated as the keyboard's width minus this (typical margins).
    var fieldInsets: Double = 40

    static let standard = TrackpadParameters()

    static var multiplierRange: ClosedRange<Double> { LocalFlowSettings.cursorMultiplierRange }

    /// Applies the user's multipliers, clamped to the accepted range.
    func tuned(sensitivity: Double, acceleration: Double) -> TrackpadParameters {
        var tuned = self
        tuned.sensitivity = Self.clampedMultiplier(sensitivity)
        tuned.acceleration = Self.clampedMultiplier(acceleration)
        return tuned
    }

    /// Apple's measured gain for a finger step of `step` points in one delivered event.
    func measuredGain(forStep step: Double) -> Double {
        let s = max(step, 0) * eventStepScale
        if s <= quadraticLimit { return 1 + quadraticCoefficient * s * s }
        if s <= linearLimit {
            return 1 + quadraticCoefficient * quadraticLimit * quadraticLimit + linearSlope * (s - quadraticLimit)
        }
        return powerCoefficient * pow(s / linearLimit, powerExponent)
    }

    /// The gain with the user's acceleration applied.
    func gain(forStep step: Double) -> Double {
        1 + (measuredGain(forStep: step) - 1) * acceleration
    }

    /// Pointer travel per point of finger travel for one event: sensitivity times the gain.
    func travelFactor(forStep step: Double) -> Double {
        sensitivity * gain(forStep: step)
    }

    private static func clampedMultiplier(_ value: Double) -> Double {
        value.isFinite ? min(max(value, multiplierRange.lowerBound), multiplierRange.upperBound) : 1
    }
}
