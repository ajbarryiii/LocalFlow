import Foundation

/// Every trackpad-mode constant, in one place. Distances are in points and times in seconds.
///
/// Measured on Apple's keyboard (ARCHITECTURE.md, "Measured Apple keyboard behavior", and the
/// calibration report). Device values (iPhone 15 Pro, iOS 26.6.2, real thumbs and XCUITest)
/// supersede the simulator's:
/// - Activation only by the timer, 0.40 s after touch-down on space (0.381 s in the simulator), if
///   the finger is then within 16 pt (straight line) of its touch-down point. Movement before
///   activation is discarded.
/// - Gain depends only on the finger's 2D step per delivered touch event, s = |Δ|, the same on both
///   axes and in both directions, independent of the time between events (confirmed on device):
///   g = 1 + 0.04·s² up to 2 pt, then 1.16 + 0.16·(s − 2) up to 5.92 pt, then 1.787·(s/5.92)^0.389.
///   The cursor moves g(s)·Δ per event. The steps were measured at 60 Hz; `eventStepScale`
///   normalizes a step to a 60 Hz event (`TouchRateEstimator`: 2 at 120 Hz).
/// - A 2D floating point starts at the caret; the caret is the boundary nearest the point on the line
///   whose center is nearest. No hysteresis, dead zone, momentum or axis lock. Line ends do not wrap.
///   The point is clamped to [1.0, width − 1.5] horizontally (the left clamp measured on device) and
///   to [first line center − 7, last line center + 8] vertically, and overshoot is not remembered.
/// Apple has no drag-to-activate, so that stays off by default.
struct TrackpadParameters: Equatable, Sendable {
    var holdDuration: TimeInterval = 0.40
    /// Straight-line movement from touch-down tolerated at the hold timer (≤ 16 pt activates on
    /// device, ≥ 18 pt does not).
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
    /// Scales the per-event step before the curve, so a step counts as it would in a 60 Hz event.
    /// Set from the measured touch rate (`TouchRateEstimator`); 1 at 60 Hz.
    var eventStepScale = 1.0

    /// The user's multipliers (`LocalFlowSettings`): sensitivity scales the finger movement, and
    /// acceleration scales how far the gain rises above 1.
    var sensitivity = 1.0
    var acceleration = 1.0

    /// The point's clamps: this far inside the text's left and right edges, and this far above the
    /// first line's center and below the last line's center.
    var leftInset = 1.0
    var rightInset = 1.5
    var topOvershoot: Double = 7
    var bottomOvershoot: Double = 8
    /// While the proxy may still show more lines, the point may run this many lines past the known
    /// text before it is held.
    var pendingLines = 1.5
    /// Edge probes in a row whose outcome was ambiguous (an ignored step or a blank line) before the
    /// edge holds like Apple's last line. Each half line of new finger travel past it allows one more.
    var maximumAmbiguousProbes = 8
    /// New finger travel past a held edge, in lines, that allows one more edge probe.
    var probeTravelLines = 0.5
    /// Unit probes whose outcome could not be placed that may be retried without new finger travel.
    var automaticProbeRetries = 2
    /// Re-read the proxy's context when the cursor gets this many characters from a snapshot edge.
    var resnapshotMargin = 6
    /// How long to wait for the host to confirm an adjustment before trusting what it reports.
    var syncTimeout: TimeInterval = 0.3
    /// How long after the finger lifts (or after the last adjustment issued since) pending
    /// adjustments may still land.
    var settleTimeout: TimeInterval = 0.5
    /// Steps from inside a cluster to its edge, in a row, before giving up.
    var maximumRepairs = 4
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
