import Foundation

/// Every trackpad-mode constant, in one place so measured values drop in with a one-line change.
/// Distances are in points, times in seconds (touch timestamps), speeds in points per second.
///
/// Where the defaults come from (researched 2026-10-09; replace with the XCUITest measurements):
/// - `holdDuration`: Apple documents only "touch and hold the space bar" and reviewers describe "a
///   short pause". 0.5 s is UIKit's default `UILongPressGestureRecognizer.minimumPressDuration` and
///   KeyboardKit's `longPressDelay`.
/// - Gain: Flutter's documentation of the iOS floating cursor says it "follows the user's
///   horizontal movements exactly" and snaps to lines vertically; Apple Support and press
///   coverage say faster drags cover more distance. No curve is published, so the shape is
///   iOS-pointer-like and our own: 1:1 below `lowSpeed`, rising smoothly (smoothstep) to
///   `maximumGain` at `highSpeed`.
/// - Vertical: the floating cursor snaps to the line under it, so a line changes about halfway to
///   the next line's center. The extra `verticalHysteresis` against thumb wobble is our choice.
/// - Edges: the floating cursor stops at the text's edges, so travel past the document's start or
///   end is discarded and reversing responds at once.
/// - `dragActivationDistance`: LocalFlow's addition, not Apple's. A deliberate drag along the space
///   bar starts the trackpad without waiting for the hold. Set it to `.infinity` to disable.
struct TrackpadParameters: Equatable, Sendable {
    var holdDuration: TimeInterval = 0.5
    /// Movement allowed during the hold before it stops counting as a hold.
    var holdSlop: Double = 10
    var dragActivationDistance: Double = 24
    /// Gain is exactly `baseGain` below this finger speed.
    var lowSpeed: Double = 120
    /// Gain reaches `maximumGain * baseGain` at this finger speed and stays there.
    var highSpeed: Double = 1_200
    var baseGain: Double = 1
    var maximumGain: Double = 3
    /// Time constant of the exponential finger-speed smoothing, so one jittery sample does not
    /// change the gain.
    var speedSmoothing: TimeInterval = 0.04
    /// Extra travel past a character's midpoint before the caret crosses it, as a fraction of the
    /// character's advance. It keeps a resting finger from flickering the caret back and forth.
    var horizontalHysteresis: Double = 0.1
    /// The same for line changes, as a fraction of the line height.
    var verticalHysteresis: Double = 0.15
    /// Advance used for a line break and for any character whose width is unknown.
    var fallbackAdvance: Double = 9
    /// Travel kept while waiting for the proxy to show more text, so a fast drag is not lost.
    var maximumPendingTravel: Double = 600
    /// Re-read the proxy's context when the cursor gets this many characters from a snapshot edge.
    var resnapshotMargin = 6
    /// How long to wait for the proxy to reflect an adjustment before trusting what it reports.
    var syncTimeout: TimeInterval = 0.3
    /// How long after the finger lifts pending adjustments may still be issued.
    var settleTimeout: TimeInterval = 0.5
    /// The field's text width is estimated as the keyboard's width minus this (typical margins).
    var fieldInsets: Double = 40

    static let standard = TrackpadParameters()

    static var multiplierRange: ClosedRange<Double> { LocalFlowSettings.cursorMultiplierRange }

    /// Applies the user's multipliers: `sensitivity` scales every gain, and `acceleration` scales
    /// how far the gain rises above 1 at speed.
    func tuned(sensitivity: Double, acceleration: Double) -> TrackpadParameters {
        var tuned = self
        let sensitivity = Self.clampedMultiplier(sensitivity)
        let acceleration = Self.clampedMultiplier(acceleration)
        tuned.baseGain = baseGain * sensitivity
        tuned.maximumGain = 1 + (maximumGain - 1) * acceleration
        return tuned
    }

    /// Pointer travel per point of finger travel at a finger speed.
    func gain(forSpeed speed: Double) -> Double {
        let span = max(highSpeed - lowSpeed, .ulpOfOne)
        let t = min(max((speed - lowSpeed) / span, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return baseGain * (1 + (maximumGain - 1) * eased)
    }

    private static func clampedMultiplier(_ value: Double) -> Double {
        value.isFinite ? min(max(value, multiplierRange.lowerBound), multiplierRange.upperBound) : 1
    }
}
