import Foundation

/// Apple's trackpad mode as measured: a 2D floating point in text-layout coordinates. It starts
/// exactly at the caret (where the finger lands does not matter), and each delivered touch event moves
/// it by g(|d|)·d, with d the 2D finger step and one gain for both axes (`TrackpadParameters`). The
/// caret follows it to the nearest character boundary on the nearest line; that mapping lives in
/// `TrackpadSession`. There is no hysteresis, dead zone or momentum, and clamped overshoot is
/// forgotten, so reversals respond at once. Pure; no clocks are involved.
struct FloatingCursor: Equatable, Sendable {
    var parameters: TrackpadParameters
    /// Points from the leading edge of the text, as a column kept across lines.
    private(set) var x: Double
    /// Points from the top of the first known line.
    private(set) var y: Double

    init(parameters: TrackpadParameters, x: Double, y: Double) {
        self.parameters = parameters
        self.x = x
        self.y = y
    }

    /// Adds one delivered touch event's finger movement. Returns the point's movement.
    @discardableResult
    mutating func move(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return (0, 0) }
        let factor = parameters.travelFactor(forStep: (dx * dx + dy * dy).squareRoot())
        x += dx * factor
        y += dy * factor
        return (dx * factor, dy * factor)
    }

    /// Holds the point inside the ranges; the overshoot is dropped, not remembered.
    mutating func clamp(x xRange: ClosedRange<Double>, y yRange: ClosedRange<Double>) {
        x = min(max(x, xRange.lowerBound), xRange.upperBound)
        y = min(max(y, yRange.lowerBound), yRange.upperBound)
    }

    /// Moves the point to new coordinates without motion, when the text it lies over is laid out anew.
    mutating func place(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
