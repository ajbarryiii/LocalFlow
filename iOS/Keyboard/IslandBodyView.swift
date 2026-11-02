import SwiftUI
import UIKit

/// The dictation island and Cancel's × drawn as one body in the island's fill (ARCHITECTURE.md, "Top row"; `IslandBud`):
/// the island's pill, the bud beside it, and the neck that joins them while it buds out or is taken back, edged as one
/// outline. It moves the island as SwiftUI moves the island's content (`DictationBarView.islandSpring`), so the two keep
/// step. Drawn with Core Animation, a frame at a time only while something moves (`IslandBud.Model.needsFrames`); at
/// rest it does no work. It draws only: the island's button and Cancel's take the taps, where `IslandLayout` puts them.
/// It fills the bar, whose coordinates `IslandBud` uses, with the bar's centre line through its middle.
struct IslandBody: UIViewRepresentable {
    struct Look: Equatable {
        var fill: UIColor
        var edge: UIColor?
        var edgeWidth: Double
        /// Cancel's ×, and Undo's chip as it draws its label (`ChipContent`), as images; nil until rendered.
        var glyph: UIImage?
        var label: UIImage?
    }

    let island: IslandLayout.Span
    let target: IslandBud.Target
    /// A change of form moves the island and the bud; any other change (a turn, the hand, Reduce Motion) places them.
    let form: IslandForm
    let side: IslandLayout.End
    let controlHeight: Double
    let reduceMotion: Bool
    let look: Look
    /// Cancel is held down: its × dims a little, as a pressed control does.
    let pressed: Bool
    /// The bud set off for Undo (true) or is no longer on its way (false): Undo's chip stays hidden while it travels.
    let onFlight: (Bool) -> Void

    func makeUIView(context: Context) -> IslandBodyView {
        IslandBodyView(island: island, controlHeight: controlHeight, side: side)
    }

    func updateUIView(_ view: IslandBodyView, context: Context) {
        view.onFlight = onFlight
        view.apply(look: look, pressed: pressed, reduceMotion: reduceMotion)
        view.place(island: island, target: target, form: form, side: side, controlHeight: controlHeight,
                   reduceMotion: reduceMotion)
    }
}

final class IslandBodyView: UIView {
    var onFlight: (Bool) -> Void = { _ in }

    // Every edge under every fill, so overlapping parts read as one outline.
    private let islandEdge = CAShapeLayer()
    private let budEdge = CAShapeLayer()
    private let islandFill = CAShapeLayer()
    private let budFill = CAShapeLayer()
    private let glyph = CALayer()
    private let label = CALayer()

    private var model: IslandBud.Model
    private var placed: Placement?
    private var look: IslandBody.Look?
    private var pressed = false
    private var reportedFlight = false
    private var link: CADisplayLink?

    private struct Placement: Equatable {
        var island: IslandLayout.Span
        var target: IslandBud.Target
        var form: IslandForm
        var side: IslandLayout.End
        var controlHeight: Double
        var reduceMotion: Bool
    }

    init(island: IslandLayout.Span, controlHeight: Double, side: IslandLayout.End) {
        model = IslandBud.Model(island: island, controlHeight: controlHeight, side: side)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        for edge in [islandEdge, budEdge] {
            edge.fillColor = nil
            layer.addSublayer(edge)
        }
        for part in [islandFill, budFill, glyph, label] { layer.addSublayer(part) }
        for part in [glyph, label] {
            part.contentsGravity = .resizeAspect
            part.opacity = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(look: IslandBody.Look, pressed: Bool, reduceMotion: Bool) {
        if look != self.look {
            self.look = look
            withoutActions {
                islandFill.fillColor = look.fill.cgColor
                budFill.fillColor = look.fill.cgColor
                for edge in [islandEdge, budEdge] {
                    edge.strokeColor = look.edge?.cgColor
                    // Twice the edge: its inner half lies under the fill.
                    edge.lineWidth = CGFloat(2 * look.edgeWidth)
                    edge.isHidden = look.edge == nil
                }
                for (part, image) in [(glyph, look.glyph), (label, look.label)] {
                    part.contents = image?.cgImage
                    part.contentsScale = image?.scale ?? 1
                    part.bounds = CGRect(origin: .zero, size: image?.size ?? .zero)
                }
            }
            draw(at: CACurrentMediaTime())
        }
        if pressed != self.pressed {
            self.pressed = pressed
            // As `PressableStyle` presses a control: quickly, a little smaller and dimmer; with Reduce Motion only dimmer.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            glyph.setAffineTransform(pressed && !reduceMotion ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity)
            CATransaction.commit()
            draw(at: CACurrentMediaTime())
        }
    }

    func place(island: IslandLayout.Span, target: IslandBud.Target, form: IslandForm, side: IslandLayout.End,
               controlHeight: Double, reduceMotion: Bool) {
        let next = Placement(island: island, target: target, form: form, side: side, controlHeight: controlHeight,
                             reduceMotion: reduceMotion)
        guard next != placed else { return }
        let animated = !reduceMotion && placed.map { $0.form != form } == true
        let now = CACurrentMediaTime()
        // Reduce Motion turned on midway: whatever moves takes its place at once.
        if reduceMotion, placed?.reduceMotion == false { model.settle(at: now) }
        placed = next
        _ = model.update(island: island, target: target, side: side, controlHeight: controlHeight, animated: animated,
                         now: now)
        if reduceMotion {
            // Nothing travels: the parts cross-fade into their places, as the island's content does.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            for part in [islandEdge, budEdge, islandFill, budFill, glyph, label] { part.add(fade, forKey: "lf.fade") }
        }
        draw(at: now)
        reportFlight()
        runIfNeeded(at: now)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        } else {
            runIfNeeded(at: CACurrentMediaTime())
        }
        reportFlight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        draw(at: CACurrentMediaTime())
    }

    private func runIfNeeded(at now: TimeInterval) {
        guard window != nil, model.needsFrames(at: now), link == nil else { return }
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        // As SwiftUI draws the island's content beside it, up to the screen's rate.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        _ = model.advance(to: now)
        draw(at: now)
        reportFlight()
        if !model.needsFrames(at: now) {
            link.invalidate()
            self.link = nil
        }
    }

    /// Undo's chip shows once the bud is no longer on its way to it, however that ends.
    private func reportFlight() {
        let flying = window != nil && model.isFlying
        guard flying != reportedFlight else { return }
        reportedFlight = flying
        let onFlight = self.onFlight
        // Not during SwiftUI's update of this view.
        DispatchQueue.main.async { onFlight(flying) }
    }

    private func draw(at now: TimeInterval) {
        let frame = model.frame(at: now)
        let mid = bounds.midY
        let radius = CGFloat((placed?.controlHeight ?? 0) / 2)
        let island = UIBezierPath(roundedRect: CGRect(x: frame.island.x, y: mid - radius, width: frame.island.width,
                                                      height: 2 * radius), cornerRadius: radius).cgPath
        var bud = CGMutablePath() as CGPath
        if let body = frame.bud {
            let half = CGFloat(body.height / 2)
            bud = UIBezierPath(roundedRect: CGRect(x: body.minX, y: mid - half, width: body.width, height: 2 * half),
                               cornerRadius: half).cgPath
            if let neck = frame.neck {
                func point(_ p: IslandBud.Point) -> CGPoint { CGPoint(x: p.x, y: mid + p.y) }
                let joint = CGMutablePath()
                joint.move(to: point(neck.p1))
                joint.addCurve(to: point(neck.p3), control1: point(neck.h1), control2: point(neck.h3))
                joint.addLine(to: point(neck.p4))
                joint.addCurve(to: point(neck.p2), control1: point(neck.h4), control2: point(neck.h2))
                joint.closeSubpath()
                // One outline: the neck's sides run either way round, so it is joined, not added.
                bud = bud.union(joint)
            }
        }
        withoutActions {
            islandEdge.path = island
            islandFill.path = island
            budEdge.path = bud
            budFill.path = bud
            let budAlpha = Float(frame.budAlpha)
            budEdge.opacity = budAlpha
            budFill.opacity = budAlpha
            let centre = CGPoint(x: frame.bud?.midX ?? 0, y: Double(mid))
            glyph.position = centre
            label.position = centre
            glyph.opacity = Float(frame.glyphAlpha * frame.budAlpha * (pressed ? 0.7 : 1))
            label.opacity = Float(frame.labelAlpha * frame.budAlpha)
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Holds the view weakly, so the display link (which retains its target) never keeps it alive.
    @MainActor
    private final class Ticker: NSObject {
        weak var view: IslandBodyView?

        init(_ view: IslandBodyView) { self.view = view }

        @objc func tick(_ link: CADisplayLink) {
            guard let view else { return link.invalidate() }
            view.tick(link)
        }
    }
}
