import QuartzCore
import SwiftUI
import UIKit

/// The island's dots (ARCHITECTURE.md, "Keyboard look"): the recording wave (`DotWave.dots`, with the mark's dot) or the
/// wait's shimmer (`DotWave.shimmer`), each dot a small layer that Core Animation composites. Round 8 drew them in a
/// SwiftUI `Canvas` inside `TimelineView(.animation)`, which in some keyboard processes drew nothing at all for the rest
/// of the process (round 8 council, finding 1). Here every change of size, level or colour draws a frame at once, so the
/// first frame never waits for a clock, and a display link moves the dots only while the view is in a window, shown,
/// and animating (recording, or the wait's sweep), at most 60 frames a second.
struct DotFieldRepresentable: UIViewRepresentable {
    let kind: DotFieldView.Kind
    /// The latest input level, 0 to 1.
    let level: Double
    let ink: BrandPalette.RGB
    /// The mark's dot at the wave's right end, if any.
    let mark: BrandPalette.RGB?
    let reduceMotion: Bool

    func makeUIView(context: Context) -> DotFieldView { DotFieldView() }

    func updateUIView(_ view: DotFieldView, context: Context) {
        view.configure(kind: kind, level: level, ink: ink, mark: mark, reduceMotion: reduceMotion)
    }
}

final class DotFieldView: UIView {
    enum Kind: Equatable {
        /// The recording wave; `live` while recording (it follows the voice and drifts), otherwise its still, calm row.
        case wave(live: Bool)
        /// The wait's shimmer.
        case shimmer
    }

    /// One shimmer sweep, in seconds, entering at the left and leaving at the right.
    static let shimmerPeriod = 1.1

    private var kind = Kind.wave(live: false)
    private var level = 0.0
    private var ink = BrandPalette.RGB(1, 1, 1)
    private var mark: BrandPalette.RGB?
    private var reduceMotion = false

    private var follower = DotWave.LevelFollower()
    private var startedAt: CFTimeInterval?
    private var lastFrame: CFTimeInterval?
    private var link: CADisplayLink?
    private var dotLayers: [DotLayer] = []
    private let markLayer = DotLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        layer.addSublayer(markLayer.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        link?.invalidate()
    }

    func configure(kind: Kind, level: Double, ink: BrandPalette.RGB, mark: BrandPalette.RGB?, reduceMotion: Bool) {
        if kind != self.kind {
            // A new recording starts its drift and its level from rest.
            follower = DotWave.LevelFollower()
            startedAt = nil
            lastFrame = nil
        }
        self.kind = kind
        self.level = level
        self.ink = ink
        self.mark = mark
        self.reduceMotion = reduceMotion
        updateClock()
        render(at: CACurrentMediaTime())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        render(at: CACurrentMediaTime())
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClock()
        render(at: CACurrentMediaTime())
    }

    override var isHidden: Bool {
        didSet { updateClock() }
    }

    /// Whether the dots move between changes: the live wave and the shimmer, never with Reduce Motion.
    private var animates: Bool {
        guard !reduceMotion else { return false }
        switch kind {
        case .wave(let live): return live
        case .shimmer: return true
        }
    }

    /// Runs the display link only while the dots move and can be seen.
    private func updateClock() {
        let wanted = animates && window != nil && !isHidden
        if wanted, link == nil {
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(1 / DotWave.frameInterval),
                                                            preferred: Float(1 / DotWave.frameInterval))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
            lastFrame = nil
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        render(at: link.targetTimestamp)
    }

    /// Lays the dots out for the moment `now`: the level and drift advanced to it while the wave is live.
    private func render(at now: CFTimeInterval) {
        let width = Double(bounds.width), height = Double(bounds.height)
        var dots: [DotWave.Dot] = []
        var markDot: DotWave.Dot?
        switch kind {
        case .wave(let live):
            var shown = live ? level : 0
            var phase = 0.0
            if live && !reduceMotion {
                follower.follow(level, over: min(now - (lastFrame ?? now), 0.1))
                lastFrame = now
                let start = startedAt ?? now
                startedAt = start
                shown = follower.value
                phase = DotWave.phase(elapsed: now - start)
            }
            dots = DotWave.dots(level: shown, phase: phase, width: width, height: height)
            if mark != nil, !dots.isEmpty { markDot = DotWave.markDot(level: shown, width: width, height: height) }
        case .shimmer:
            let sweep = animates ? (now.truncatingRemainder(dividingBy: Self.shimmerPeriod) / Self.shimmerPeriod) * 1.6 - 0.3 : -1
            dots = DotWave.shimmer(sweep: sweep, width: width, height: height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while dotLayers.count < dots.count {
            let dot = DotLayer()
            layer.insertSublayer(dot.layer, below: markLayer.layer)
            dotLayers.append(dot)
        }
        for (index, dotLayer) in dotLayers.enumerated() {
            if index < dots.count {
                dotLayer.show(dots[index], color: ink)
            } else {
                dotLayer.hide()
            }
        }
        if let markDot, let mark {
            markLayer.show(markDot, color: mark)
        } else {
            markLayer.hide()
        }
        CATransaction.commit()
    }
}

/// One dot's layer: a disc of the largest radius any dot has, scaled to the dot's, so a frame changes at most its scale
/// and opacity. It writes only what changed since its last frame, and Core Animation composites it.
private final class DotLayer {
    let layer = CALayer()
    private var shown: (x: Double, y: Double, scale: Double, opacity: Double, color: BrandPalette.RGB)?
    private static let diameter = 2 * max(DotWave.fullRadius, DotWave.markRadius * (1 + DotWave.markGrowth))

    init() {
        layer.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        layer.cornerRadius = Self.diameter / 2
        layer.isHidden = true
    }

    func show(_ dot: DotWave.Dot, color: BrandPalette.RGB) {
        let scale = 2 * dot.radius / Self.diameter, opacity = min(max(dot.brightness, 0), 1)
        let last = shown
        if last == nil { layer.isHidden = false }
        if last?.x != dot.x || last?.y != dot.y { layer.position = CGPoint(x: dot.x, y: dot.y) }
        if last.map({ abs($0.scale - scale) > 0.002 }) ?? true {
            layer.transform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        }
        if last.map({ abs($0.opacity - opacity) > 0.002 }) ?? true { layer.opacity = Float(opacity) }
        if last?.color != color { layer.backgroundColor = UIColor(color).cgColor }
        shown = (dot.x, dot.y, last.map { abs($0.scale - scale) > 0.002 ? scale : $0.scale } ?? scale,
                 last.map { abs($0.opacity - opacity) > 0.002 ? opacity : $0.opacity } ?? opacity, color)
    }

    func hide() {
        guard shown != nil else { return }
        layer.isHidden = true
        shown = nil
    }
}

/// The display link's target, which holds the view weakly: a display link retains its target.
private final class Tick: NSObject {
    private weak var view: DotFieldView?

    init(_ view: DotFieldView) {
        self.view = view
    }

    @objc func fire(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
