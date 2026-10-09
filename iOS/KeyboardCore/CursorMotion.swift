import Foundation

/// Turns finger movement into pointer travel over the text, like the floating cursor of Apple's
/// trackpad mode: the pointer moves by the accelerated finger delta, and the caret follows it to
/// the nearest character boundary and line. Pure and driven by touch timestamps, so a synthesized
/// UI-test drag and a real finger behave the same.
struct CursorMotion: Equatable, Sendable {
    /// What one horizontal pass moved, and whether the pointer wants to go past the known text.
    struct HorizontalSteps: Equatable, Sendable {
        var steps = 0
        var blockedForward = false
        var blockedBackward = false
    }

    let parameters: TrackpadParameters
    /// Smoothed finger speed in points per second.
    private(set) var speed: Double = 0
    /// Pointer offset from the caret along the text, in layout points; positive is forward.
    private(set) var horizontal: Double = 0
    /// Pointer offset from the center of the caret's line, in layout points; positive is down.
    private(set) var vertical: Double = 0
    private var lastTimestamp: TimeInterval?

    init(parameters: TrackpadParameters) {
        self.parameters = parameters
    }

    /// Adds one touch sample. Returns the accelerated delta added to the pointer.
    @discardableResult
    mutating func add(dx: Double, dy: Double, timestamp: TimeInterval) -> (dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return (0, 0) }
        if let last = lastTimestamp, timestamp > last {
            // Samples closer than a 240 Hz touch frame would overstate the speed.
            let dt = max(timestamp - last, 1.0 / 240)
            let instant = (dx * dx + dy * dy).squareRoot() / dt
            let alpha = 1 - exp(-dt / max(parameters.speedSmoothing, .ulpOfOne))
            speed += alpha * (instant - speed)
        }
        lastTimestamp = max(timestamp, lastTimestamp ?? timestamp)
        let gain = parameters.gain(forSpeed: speed)
        horizontal += dx * gain
        vertical += dy * gain
        return (dx * gain, dy * gain)
    }

    /// Crosses whole characters while the pointer is past the next one's midpoint plus hysteresis,
    /// so wide characters take more travel than narrow ones. `width(k)` is the advance of the
    /// character between caret positions `k` and `k + 1`, relative to the caret (0 is the next one
    /// forward, -1 the previous one), or nil past the known text.
    mutating func takeHorizontalSteps(width: (Int) -> Double?) -> HorizontalSteps {
        var result = HorizontalSteps()
        let crossing = 0.5 + parameters.horizontalHysteresis
        // The pointer has to reach as far as crossing a typical character before an edge counts.
        let edgeThreshold = parameters.fallbackAdvance * crossing
        while horizontal > 0 {
            guard let advance = width(result.steps) else {
                result.blockedForward = horizontal >= edgeThreshold
                break
            }
            let w = max(advance, 0.5)
            guard horizontal >= w * crossing else { break }
            result.steps += 1
            horizontal -= w
        }
        while horizontal < 0, !result.blockedForward {
            guard let advance = width(result.steps - 1) else {
                result.blockedBackward = -horizontal >= edgeThreshold
                break
            }
            let w = max(advance, 0.5)
            guard -horizontal >= w * crossing else { break }
            result.steps -= 1
            horizontal += w
        }
        return result
    }

    /// Whole lines crossed, with the first change halfway to the next line's center plus
    /// hysteresis. Positive is down.
    mutating func takeLineSteps(lineHeight: Double) -> Int {
        guard lineHeight > 0 else { return 0 }
        let threshold = lineHeight * (0.5 + parameters.verticalHysteresis)
        var lines = 0
        while vertical >= threshold {
            lines += 1
            vertical -= lineHeight
        }
        while vertical <= -threshold {
            lines -= 1
            vertical += lineHeight
        }
        return lines
    }

    /// Gives back line steps that could not be applied yet.
    mutating func restoreLines(_ lines: Int, lineHeight: Double) {
        vertical += Double(lines) * lineHeight
    }

    /// Spends pointer travel on a character crossed outside `takeHorizontalSteps`.
    mutating func consumeHorizontal(_ distance: Double) {
        horizontal -= distance
    }

    /// At a document edge: travel past it is discarded, so reversing responds at once.
    mutating func stopHorizontal(atEnd: Bool) {
        horizontal = atEnd ? min(horizontal, 0) : max(horizontal, 0)
    }

    mutating func stopVertical() {
        vertical = 0
    }

    /// While waiting for more text, keep the travel but not without bound.
    mutating func limitHorizontal(to limit: Double) {
        horizontal = min(max(horizontal, -limit), limit)
    }
}
