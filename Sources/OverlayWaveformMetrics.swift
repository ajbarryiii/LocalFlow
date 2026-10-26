import Foundation

/// Sizes for the overlay's recording waveform and processing indicator.
/// `.regular` fits the floating pill; `.compact` fits a 36pt wing of the
/// winged menu-bar overlay with tighter bars and a smaller spinner.
struct WaveformMetrics {
    /// Recording waveform: one bar per multiplier, scaling the audio level.
    let multipliers: [CGFloat]
    let barSpacing: CGFloat
    let barWidth: CGFloat
    let barMinHeight: CGFloat
    let barMaxHeight: CGFloat
    let frameHeight: CGFloat
    /// Regular bars spring slower and later toward the edges; compact bars all
    /// share one spring with no delay.
    let staggersBarAnimation: Bool

    /// Processing indicator: pulsing pills, then a spinner after one second.
    let processingPillSpacing: CGFloat
    let processingPillWidth: CGFloat
    let processingPillMinHeight: CGFloat
    let processingPillMaxHeight: CGFloat
    let processingFrameHeight: CGFloat
    let spinnerSize: CGFloat
    let spinnerLineWidth: CGFloat

    static let regular = WaveformMetrics(
        multipliers: [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35],
        barSpacing: 2.5,
        barWidth: 3,
        barMinHeight: 2,
        barMaxHeight: 22,
        frameHeight: 24,
        staggersBarAnimation: true,
        processingPillSpacing: 4,
        processingPillWidth: 4,
        processingPillMinHeight: 4,
        processingPillMaxHeight: 18,
        processingFrameHeight: 20,
        spinnerSize: 16,
        spinnerLineWidth: 2.5
    )

    static let compact = WaveformMetrics(
        multipliers: [0.5, 0.75, 1.0, 0.75, 0.5],
        barSpacing: 1.5,
        barWidth: 2,
        barMinHeight: 2,
        barMaxHeight: 14,
        frameHeight: 18,
        staggersBarAnimation: false,
        processingPillSpacing: 2,
        processingPillWidth: 2,
        processingPillMinHeight: 2,
        processingPillMaxHeight: 12,
        processingFrameHeight: 18,
        spinnerSize: 12,
        spinnerLineWidth: 2.0
    )

    static let processingBarCount = 5

    var barCount: Int { multipliers.count }

    private var centerIndex: CGFloat { CGFloat((barCount - 1) / 2) }

    func barAmplitude(for index: Int, audioLevel: Float, pulseTime: TimeInterval?) -> CGFloat {
        let level = CGFloat(max(audioLevel, 0))
        let baseAmplitude = min(level * multipliers[index], 1.0)

        guard let pulseTime else { return baseAmplitude }

        let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = travelingWave * 0.22 + shimmer * 0.06

        let saturationRelief = baseAmplitude * (0.74 + pulse)
        let quietPulse = (1.0 - baseAmplitude) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }

    /// Spring response and delay for a recording bar; `delay` is nil when the
    /// bar's spring has no delay applied.
    func barSpring(for index: Int) -> (response: Double, delay: Double?) {
        guard staggersBarAnimation else { return (0.18, nil) }
        let distance = abs(CGFloat(index) - centerIndex)
        let normalizedDistance = distance / centerIndex
        return (0.18 + Double(normalizedDistance) * 0.06, Double(distance) * 0.01)
    }

    static func processingAmplitude(for index: Int, time: TimeInterval) -> CGFloat {
        let centerIndex = CGFloat((processingBarCount - 1) / 2)
        let centerDistance = abs(CGFloat(index) - centerIndex) / centerIndex
        let baseline = 0.18 + (1.0 - centerDistance) * 0.1
        return min(baseline + processingPulse(for: index, time: time) * 0.68, 1.0)
    }

    static func processingOpacity(for index: Int, time: TimeInterval) -> CGFloat {
        0.42 + processingPulse(for: index, time: time) * 0.52
    }

    private static func processingPhase(for index: Int, time: TimeInterval) -> Double {
        let cycle = 1.05
        let stagger = 0.11
        return ((time - Double(index) * stagger).truncatingRemainder(dividingBy: cycle)) / cycle
    }

    private static func processingPulse(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = processingPhase(for: index, time: time)
        let wave = 0.5 + 0.5 * sin((phase * 2.0 * .pi) - (.pi / 2.0))
        return CGFloat(pow(wave, 1.9))
    }
}
