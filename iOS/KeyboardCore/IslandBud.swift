import Foundation

/// Cancel's × as a bud of the dictation island (ARCHITECTURE.md, "Top row"): starting a dictation it buds off the
/// island's end that faces the bar's middle and pinches free as the island grows; at Stop it slides with the
/// contracting island; when the text lands it travels to Undo's place, stretching on the way, and becomes Undo; with no
/// text, or on Cancel, the island absorbs it. The island, the bud and the neck between them are drawn as one body in
/// the island's fill (`IslandBodyView`), so the × and Undo look like the island. This is its motion and shape, as
/// values along the bar's centre line in the bar's coordinates; what takes taps is unchanged (`IslandLayout`). Pure.
enum IslandBud {
    /// A damped spring as SwiftUI's `spring(response:dampingFraction:)` moves a value: unit mass, stiffness
    /// (2π/response)², damping 4π·dampingFraction/response. The island drawn here keeps step with its content, which
    /// SwiftUI moves with the same spring.
    struct Spring: Equatable, Sendable {
        var response: Double
        var dampingFraction: Double
    }

    /// The bud's timing, in one place.
    enum Motion {
        /// The island's grow and shrink (`DictationBarView.islandSpring`): quick and firm, a touch of give, no wobble.
        static let island = Spring(response: 0.26, dampingFraction: 0.88)
        /// Budding out and being taken back: a touch behind the island and with a little more give, so the bud swells
        /// out of its end and pinches free.
        static let bud = Spring(response: 0.34, dampingFraction: 0.74)
        /// To Undo, the leading edge first and the trailing edge `trailDelay` later and softer, so the bud stretches on
        /// the way and gathers into the chip; its height meets the chip's with the leading edge.
        static let lead = Spring(response: 0.28, dampingFraction: 0.76)
        static let trail = Spring(response: 0.34, dampingFraction: 0.82)
        static let trailDelay = 0.02
        static let height = Spring(response: 0.28, dampingFraction: 0.8)
        /// Leaving for Undo, the × fades this quickly; Undo's label fades in over `labelFade`, `labelDelay` after it sets off.
        static let glyphFade = 0.08
        static let labelDelay = 0.2
        static let labelFade = 0.12
        /// Taken back, the × fades this quickly.
        static let absorbFade = 0.06
        /// Landed, the bud fades over the Undo chip, which looks the same, for this long.
        static let handover = 0.1
    }

    /// The bud at home, hidden in the island's end: `homeRadius` round, its centre `homeInset` in from the end's.
    static let homeRadius = 7.0
    static let homeInset = 3.0
    /// The neck thins to nothing as the gap between the island and the bud opens to this, under Cancel's gap
    /// (`IslandLayout.cancelGap`), so a bud resting beside the island is never joined to it.
    static let reach = 9.0
    /// How far the neck spreads over the two circles while they overlap (0 is a point, 1 their outer tangents).
    static let spread = 0.6

    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// The neck's outline, closed: from `p1` on the island's edge along the top curve (handles `h1`, `h3`) to `p3` on the
    /// bud's, across to `p4`, and back along the bottom curve (handles `h4`, `h2`) to `p2`. Its straight sides lie inside
    /// the two circles, which are drawn with it.
    struct Neck: Equatable, Sendable {
        var p1, h1, h3, p3, p4, h4, h2, p2: Point
    }

    /// A capsule on the bar's centre line: the bud, round at home and at Cancel, Undo's chip at the end of its travel.
    struct Body: Equatable, Sendable {
        var minX: Double
        var maxX: Double
        var height: Double

        var midX: Double { (minX + maxX) / 2 }
        var width: Double { maxX - minX }

        /// A round body as wide as `span`: Cancel's circle.
        static func circle(_ span: IslandLayout.Span) -> Body { Body(minX: span.x, maxX: span.maxX, height: span.width) }
    }

    /// Where the bud should be: at home in the island (none showing), at Cancel's place, or on Undo's chip.
    enum Target: Equatable, Sendable {
        case home
        case cancel(Body)
        case undo(Body)
    }

    enum Event: Equatable, Sendable {
        /// The bud set off for Undo: the chip stays hidden until it lands.
        case flightStarted
        /// The bud is on Undo's chip: the chip takes over.
        case landed
    }

    /// What to draw at a moment: the island, the bud (none at home), the neck joining them (about a centre line at y 0),
    /// and how opaque the bud, its × and Undo's label are.
    struct Frame: Equatable, Sendable {
        var island: IslandLayout.Span
        var bud: Body?
        var neck: Neck?
        var budAlpha: Double
        var glyphAlpha: Double
        var labelAlpha: Double
    }

    /// A value moving under a spring from where it was, at the speed it had, towards a target.
    struct Moving: Equatable, Sendable {
        private(set) var target: Double
        private var origin: Double
        private var speed = 0.0
        private var start = 0.0
        private var spring = Motion.island

        init(_ value: Double) {
            target = value
            origin = value
        }

        func value(at time: TimeInterval) -> Double { state(at: time).value }
        func velocity(at time: TimeInterval) -> Double { state(at: time).velocity }

        /// Close enough to its target, slowly enough, to stop drawing.
        func isSettled(at time: TimeInterval) -> Bool {
            let now = state(at: time)
            return abs(now.value - target) < 0.01 && abs(now.velocity) < 0.5
        }

        /// From where it is now and as fast, towards `target`, after `delay` held still.
        mutating func move(to target: Double, with spring: Spring, at now: TimeInterval, delay: Double = 0) {
            let current = state(at: now)
            origin = current.value
            speed = delay > 0 ? 0 : current.velocity
            start = now + delay
            self.target = target
            self.spring = spring
        }

        mutating func snap(to value: Double) {
            target = value
            origin = value
            speed = 0
        }

        private func state(at time: TimeInterval) -> (value: Double, velocity: Double) {
            let t = time - start
            guard t > 0 else { return (origin, t == 0 ? speed : 0) }
            let natural = 2 * Double.pi / spring.response, zeta = spring.dampingFraction
            let offset = origin - target
            if zeta < 1 {
                let damped = natural * (1 - zeta * zeta).squareRoot()
                let decay = exp(-zeta * natural * t)
                let a = offset, b = (speed + zeta * natural * offset) / damped
                let c = cos(damped * t), s = sin(damped * t)
                let value = decay * (a * c + b * s)
                let velocity = decay * (-zeta * natural * (a * c + b * s) + damped * (-a * s + b * c))
                return (target + value, velocity)
            }
            let b = speed + natural * offset
            let decay = exp(-natural * t)
            return (target + (offset + b * t) * decay, (b - natural * (offset + b * t)) * decay)
        }
    }

    /// The neck between the island's end, a circle `radius` r1 about `island` (c1), and the bud, a circle r2 about
    /// `bud` (c2), on the centre line `y`: a metaball bridge whose spread narrows to nothing as the gap between them opens
    /// to `reach`; none once it has, or while the bud lies wholly inside the island's end.
    static func neck(island c1: Double, radius r1: Double, bud c2: Double, radius r2: Double, y: Double) -> Neck? {
        let d = abs(c2 - c1)
        guard r1 > 0, r2 > 0, d > abs(r1 - r2) + 0.01, d < r1 + r2 + reach else { return nil }
        var u1 = 0.0, u2 = 0.0
        if d < r1 + r2 {
            u1 = acos((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d))
            u2 = acos((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d))
        }
        let gap = d - r1 - r2
        let v = spread * (gap > 0 ? pow(1 - gap / reach, 1.6) : 1)
        let towards = c2 > c1 ? 0 : Double.pi
        let widest = acos(max(-1, min(1, (r1 - r2) / d)))
        let a1 = towards + u1 + (widest - u1) * v, a2 = towards - u1 - (widest - u1) * v
        let a3 = towards + .pi - u2 - (.pi - u2 - widest) * v, a4 = towards - .pi + u2 + (.pi - u2 - widest) * v
        func on(_ centre: Double, _ angle: Double, _ radius: Double) -> Point {
            Point(x: centre + radius * cos(angle), y: y + radius * sin(angle))
        }
        let p1 = on(c1, a1, r1), p2 = on(c1, a2, r1), p3 = on(c2, a3, r2), p4 = on(c2, a4, r2)
        let handle = min(v * 2.4, hypot(p1.x - p3.x, p1.y - p3.y) / (r1 + r2)) * min(1, d * 2 / (r1 + r2))
        // A handle never reaches past the centre line, so the neck's two sides never cross as it thins.
        func from(_ point: Point, _ angle: Double, _ length: Double) -> Point {
            var length = length
            if sin(angle) != 0, (y - point.y) / sin(angle) >= 0 { length = min(length, (y - point.y) / sin(angle)) }
            return Point(x: point.x + length * cos(angle), y: point.y + length * sin(angle))
        }
        return Neck(p1: p1, h1: from(p1, a1 - .pi / 2, r1 * handle), h3: from(p3, a3 + .pi / 2, r2 * handle), p3: p3,
                    p4: p4, h4: from(p4, a4 - .pi / 2, r2 * handle), h2: from(p2, a2 + .pi / 2, r1 * handle), p2: p2)
    }

    /// Where the bud goes: beside the island while there is a Cancel; on Undo's chip (`undo`, where it will show) only
    /// when the dictation that just finished put in text that can be undone, else home into the island (an earlier
    /// dictation's Undo keeps its chip).
    static func target(cancel: Body?, undo: Body?, dictationInserted: Bool) -> Target {
        if let cancel { return .cancel(cancel) }
        if let undo, dictationInserted { return .undo(undo) }
        return .home
    }

    /// Which dictation the island shows, by its request, so the bud becomes Undo only when this keyboard put in that very
    /// dictation (`target`). Fed each form of the island and the request the intent names, from the bar's first
    /// appearance.
    struct Shown: Equatable, Sendable {
        private var request: UUID?
        private var idle = true

        /// `lastInserted`, the dictation this keyboard put in last, is the one shown.
        func isInserted(lastInserted: UUID?) -> Bool { request != nil && lastInserted == request }

        mutating func observe(form: IslandForm, request: UUID?) {
            guard form != .compact else {
                // Kept for the landing, which comes as the island goes idle.
                idle = true
                return
            }
            if idle {
                // A new dictation (or the bar's first sight of one): the last is forgotten even before this one's
                // request is known.
                self.request = request
                idle = false
            } else if let request {
                self.request = request
            }
        }
    }

    /// The island and its bud over time. The bar tells it where they should be (`update`) and draws `frame(at:)` while
    /// `needsFrames`, calling `advance` each frame.
    struct Model {
        private var islandX: Moving
        private var islandWidth: Moving
        private var minX = Moving(0)
        private var maxX = Moving(0)
        private var height = Moving(0)
        private var phase = Phase.none
        private var radius: Double
        private var side: IslandLayout.End

        private enum Phase: Equatable {
            /// No bud: at home in the island.
            case none
            /// Out of the island, at Cancel's place or on its way there.
            case out
            /// On its way back into the island since then.
            case absorbing(since: TimeInterval)
            /// On its way to Undo since then.
            case flying(since: TimeInterval)
            /// On Undo's chip since then, fading over it.
            case landed(at: TimeInterval)
        }

        init(island: IslandLayout.Span, controlHeight: Double, side: IslandLayout.End) {
            islandX = Moving(island.x)
            islandWidth = Moving(island.width)
            radius = controlHeight / 2
            self.side = side
        }

        /// The island at `island` and the bud at `target`, from `now`: moving there when `animated` (the island changed
        /// form, without Reduce Motion), else at once. Undo's chip is a target only for a bud that is out.
        mutating func update(island: IslandLayout.Span, target: Target, side: IslandLayout.End, controlHeight: Double,
                             animated: Bool, now: TimeInterval) -> Event? {
            let moves = animated && side == self.side && controlHeight / 2 == radius
            let islandMoved = island.x != islandX.target || island.width != islandWidth.target
            self.side = side
            radius = controlHeight / 2
            guard moves else {
                islandX.snap(to: island.x)
                islandWidth.snap(to: island.width)
                switch (target, phase) {
                case (.cancel(let body), _):
                    place(body)
                    phase = .out
                case (_, .none), (_, .out):
                    // A bud at rest goes at once.
                    phase = .none
                case _ where animated:
                    // The bar itself changed (the hand, its height): whatever was on its way goes.
                    phase = .none
                case (.undo(let chip), .flying), (.undo(let chip), .landed):
                    // Undo moved (a turn): the bud is there at once, and lands.
                    place(chip)
                case (.home, .flying), (.home, .landed):
                    // Undo went before the bud reached it.
                    phase = .none
                case (_, .absorbing):
                    // On its way into an island that has moved: gone with it.
                    if islandMoved { phase = .none }
                }
                return nil
            }
            let from = frame(at: now)
            islandX.move(to: island.x, with: Motion.island, at: now)
            islandWidth.move(to: island.width, with: Motion.island, at: now)
            switch target {
            case .cancel(let body):
                if phase == .out {
                    // Beside the island as it changes form: in the island's own spring, keeping its gap.
                    move(to: body, with: Motion.island, at: now)
                } else {
                    if case .absorbing = phase {} else { place(home(of: from.island)) }
                    move(to: body, with: Motion.bud, at: now)
                    phase = .out
                }
                return nil
            case .home:
                guard phase == .out else { return nil }
                move(to: home(of: island), with: Motion.bud, at: now)
                phase = .absorbing(since: now)
                return nil
            case .undo(let chip):
                guard phase == .out, let bud = from.bud else { return nil }
                // The edge facing Undo leads.
                let leftwards = chip.midX < bud.midX
                minX.move(to: chip.minX, with: leftwards ? Motion.lead : Motion.trail, at: now,
                          delay: leftwards ? 0 : Motion.trailDelay)
                maxX.move(to: chip.maxX, with: leftwards ? Motion.trail : Motion.lead, at: now,
                          delay: leftwards ? Motion.trailDelay : 0)
                height.move(to: chip.height, with: Motion.height, at: now)
                phase = .flying(since: now)
                return .flightStarted
            }
        }

        /// Everything at its place at once (Reduce Motion turned on midway): the island and the bud where they were going,
        /// a bud going home gone, one going to Undo on it, to land.
        mutating func settle(at now: TimeInterval) {
            islandX.snap(to: islandX.target)
            islandWidth.snap(to: islandWidth.target)
            switch phase {
            case .out, .flying:
                place(Body(minX: minX.target, maxX: maxX.target, height: height.target))
            case .absorbing, .landed:
                phase = .none
            case .none:
                break
            }
        }

        /// Moves the bud's phase on at `now`: a bud taken back is gone once inside, one on Undo lands once it rests there
        /// and fades over the chip.
        mutating func advance(to now: TimeInterval) -> Event? {
            switch phase {
            case .absorbing:
                if budSettled(at: now), islandX.isSettled(at: now), islandWidth.isSettled(at: now) { phase = .none }
            case .flying:
                if budArrived(at: now) {
                    phase = .landed(at: now)
                    return .landed
                }
            case .landed(let at):
                if now - at >= Motion.handover { phase = .none }
            case .none, .out:
                break
            }
            return nil
        }

        /// On its way to Undo: the chip waits for it.
        var isFlying: Bool {
            if case .flying = phase { return true }
            return false
        }

        /// Whether anything moves or fades at `now`: the bar draws frames only then.
        func needsFrames(at now: TimeInterval) -> Bool {
            switch phase {
            case .absorbing, .flying, .landed: return true
            case .none: return !islandSettled(at: now)
            case .out: return !islandSettled(at: now) || !budSettled(at: now)
            }
        }

        func frame(at now: TimeInterval) -> Frame {
            let island = IslandLayout.Span(x: islandX.value(at: now), width: max(islandWidth.value(at: now), 0))
            guard phase != .none else {
                return Frame(island: island, bud: nil, neck: nil, budAlpha: 1, glyphAlpha: 0, labelAlpha: 0)
            }
            let bud = Body(minX: minX.value(at: now), maxX: max(maxX.value(at: now), minX.value(at: now)),
                           height: max(height.value(at: now), 0))
            let end = side == .left ? island.x + radius : island.maxX - radius
            let gap = abs(bud.midX - end) - radius - bud.height / 2
            // Joined only while it is round: budding out and being taken back.
            let round = abs(bud.width - bud.height) < 0.5
            let neck = round ? IslandBud.neck(island: end, radius: radius, bud: bud.midX, radius: bud.height / 2, y: 0) : nil
            let parting = min(max((gap + 2) / 10, 0), 1)
            switch phase {
            case .absorbing(let since):
                let glyph = min(parting, max(1 - (now - since) / Motion.absorbFade, 0))
                return Frame(island: island, bud: bud, neck: neck, budAlpha: 1, glyphAlpha: glyph, labelAlpha: 0)
            case .flying(let since):
                return Frame(island: island, bud: bud, neck: nil, budAlpha: 1,
                             glyphAlpha: max(1 - (now - since) / Motion.glyphFade, 0),
                             labelAlpha: min(max((now - since - Motion.labelDelay) / Motion.labelFade, 0), 1))
            case .landed(let at):
                return Frame(island: island, bud: bud, neck: nil, budAlpha: max(1 - (now - at) / Motion.handover, 0),
                             glyphAlpha: 0, labelAlpha: 1)
            case .out, .none:
                return Frame(island: island, bud: bud, neck: neck, budAlpha: 1, glyphAlpha: parting, labelAlpha: 0)
            }
        }

        /// At home in `island`'s end that faces the middle.
        private func home(of island: IslandLayout.Span) -> Body {
            let centre = side == .left ? island.x + radius + IslandBud.homeInset : island.maxX - radius - IslandBud.homeInset
            return Body(minX: centre - IslandBud.homeRadius, maxX: centre + IslandBud.homeRadius, height: 2 * IslandBud.homeRadius)
        }

        private mutating func place(_ body: Body) {
            minX.snap(to: body.minX)
            maxX.snap(to: body.maxX)
            height.snap(to: body.height)
        }

        private mutating func move(to body: Body, with spring: Spring, at now: TimeInterval) {
            minX.move(to: body.minX, with: spring, at: now)
            maxX.move(to: body.maxX, with: spring, at: now)
            height.move(to: body.height, with: spring, at: now)
        }

        private func budSettled(at now: TimeInterval) -> Bool {
            minX.isSettled(at: now) && maxX.isSettled(at: now) && height.isSettled(at: now)
        }

        /// On its target to under a pixel and all but still: Undo's chip, drawn there, can take over.
        private func budArrived(at now: TimeInterval) -> Bool {
            [minX, maxX, height].allSatisfy { abs($0.value(at: now) - $0.target) < 0.2 && abs($0.velocity(at: now)) < 5 }
        }

        private func islandSettled(at now: TimeInterval) -> Bool {
            islandX.isSettled(at: now) && islandWidth.isSettled(at: now)
        }
    }
}
