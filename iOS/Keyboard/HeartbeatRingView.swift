import SwiftUI
import UIKit

/// The session's heartbeat on the ridge mark's dot (ARCHITECTURE.md, "Top row"; `SessionDot.Heartbeat`): a ring that
/// grows from the dot's edge and fades, then rests, on repeat. Core Animation runs each ripple in the render server, at
/// most 30 frames a second, so the keyboard does no work per frame; between ripples nothing animates, so the render
/// server rests too (a repeating group spanning the rest kept it compositing: about 9% of a core on the simulator). A
/// timer on the main thread starts each ripple, once per `period`. It runs only while the view is in a window, its
/// first ripple `firstDelay` after it arrives there. Drawn in the mark's box, whose dot it finds as `RidgeMarkShape`
/// does; it draws outside that box.
struct HeartbeatRing: UIViewRepresentable {
    let color: UIColor
    /// The mark's weight (`RidgeMarkShape`), to find its dot.
    let weight: Double

    func makeUIView(context: Context) -> HeartbeatRingView {
        HeartbeatRingView()
    }

    func updateUIView(_ view: HeartbeatRingView, context: Context) {
        view.weight = weight
        view.color = color
    }
}

final class HeartbeatRingView: UIView {
    private let ring = CAShapeLayer()
    private static let key = "lf.heartbeat"
    private var timer: Timer?

    var weight = 1.0 {
        didSet { if weight != oldValue { setNeedsLayout() } }
    }

    var color = UIColor.clear {
        didSet { ring.strokeColor = color.cgColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false
        ring.fillColor = nil
        ring.lineWidth = CGFloat(SessionDot.Heartbeat.lineWidth)
        // At rest the ring is not there: it shows only inside a ripple.
        ring.opacity = 0
        layer.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The dot's centre and radius in this view.
    private var dot: (center: CGPoint, radius: CGFloat) {
        let mark = RidgeMark.fitted(in: KeyRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height)),
                                    weight: weight)
        return (CGPoint(x: mark.dot.x, y: mark.dot.y), CGFloat(mark.dotRadius))
    }

    /// A circle about the dot's centre, `radius` points across from it.
    private func circle(_ radius: CGFloat) -> CGPath {
        let center = dot.center
        return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
                      transform: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = circle(dot.radius)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        ring.removeAnimation(forKey: Self.key)
        guard window != nil else { return }
        let beat = SessionDot.Heartbeat.self
        // Leaving the window (always before the view goes) stops it.
        let timer = Timer(fire: Date(timeIntervalSinceNow: beat.firstDelay), interval: beat.period,
                          repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ripple() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One ripple: the ring grows from the dot's edge to `reach` beyond it and fades.
    private func ripple() {
        let beat = SessionDot.Heartbeat.self
        // The stroke sits on the dot's edge at first and `reach` beyond it at the end.
        let start = dot.radius + ring.lineWidth / 2, end = dot.radius + CGFloat(beat.reach) - ring.lineWidth / 2
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = circle(start)
        grow.toValue = circle(end)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = beat.opacity
        fade.toValue = 0
        for part in [grow, fade] {
            part.duration = beat.ripple
            part.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        let ripple = CAAnimationGroup()
        ripple.animations = [grow, fade]
        ripple.duration = beat.ripple
        ripple.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        ring.add(ripple, forKey: Self.key)
    }
}
