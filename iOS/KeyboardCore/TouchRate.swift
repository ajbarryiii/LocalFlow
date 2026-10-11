import Foundation

/// How often this extension receives the trackpad finger's `touchesMoved` events, and the
/// `eventStepScale` that follows. Apple's gain is per delivered event and was measured at 60 Hz
/// (confirmed on an iPhone 15 Pro), so a step is normalized to a 60 Hz event:
/// scale = (1/60 s) / the median interval between the extension's own events, clamped to
/// `scaleRange`. That is 1 at 60 Hz and 2 at 120 Hz.
///
/// A running median over the most recent intervals: robust to a dropped frame, a pause, or a burst.
/// Only intervals within one gesture count, and implausible ones (a resting finger, coalesced
/// deliveries) are ignored. Timings only; pure.
struct TouchRateEstimator: Equatable, Sendable {
    static let referenceInterval: TimeInterval = 1.0 / 60
    static let scaleRange: ClosedRange<Double> = 0.5...2.5
    /// Intervals remembered across gestures.
    static let capacity = 31
    /// Intervals before the median is trusted.
    static let minimumSamples = 5
    /// Intervals outside this range are not the delivery rate: a resting finger, or two events
    /// coalesced into one delivery.
    static let plausibleIntervals: ClosedRange<TimeInterval> = 0.002...0.05

    private(set) var intervals: [TimeInterval] = []
    private var lastTimestamp: TimeInterval?

    /// A new gesture: no interval spans the time between gestures.
    mutating func beginGesture() {
        lastTimestamp = nil
    }

    /// One delivered `touchesMoved` event of the trackpad finger, at its touch timestamp.
    mutating func record(_ timestamp: TimeInterval) {
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp, timestamp.isFinite else { return }
        let interval = timestamp - last
        guard Self.plausibleIntervals.contains(interval) else { return }
        intervals.append(interval)
        if intervals.count > Self.capacity { intervals.removeFirst(intervals.count - Self.capacity) }
    }

    /// The median interval, once there are enough samples.
    var medianInterval: TimeInterval? {
        guard intervals.count >= Self.minimumSamples else { return nil }
        let sorted = intervals.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Events per second, once measured.
    var touchRate: Double? { medianInterval.map { 1 / $0 } }

    /// The step scale for `TrackpadParameters.eventStepScale`; 1 until measured.
    var eventStepScale: Double {
        guard let median = medianInterval else { return 1 }
        return min(max(Self.referenceInterval / median, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }
}
