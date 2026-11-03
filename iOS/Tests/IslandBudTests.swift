import Foundation

/// ARCHITECTURE.md, "Top row": Cancel's × as a bud of the dictation island. It buds off the island's end that faces the
/// bar's middle and pinches free as the island grows, slides with it at Stop, and when the text lands it travels to
/// Undo's place and becomes Undo; with no text, or on Cancel, the island absorbs it. With Reduce Motion nothing
/// travels.
enum IslandBudTests {
    static var tests: [TestCase] {
        [
            ("springsMoveAsSwiftUIsDo", testSpringsMoveAsSwiftUIsDo),
            ("theBudStartsInsideTheIslandAndPinchesFree", testTheBudStartsInsideTheIslandAndPinchesFree),
            ("aBudBesideTheIslandHasNoNeck", testABudBesideTheIslandHasNoNeck),
            ("theNeckThinsToNothingBeforeItLetsGo", testTheNeckThinsToNothingBeforeItLetsGo),
            ("theBudTravelsToUndoAndBecomesIt", testTheBudTravelsToUndoAndBecomesIt),
            ("withNoTextTheIslandAbsorbsTheBud", testWithNoTextTheIslandAbsorbsTheBud),
            ("reduceMotionMovesNothing", testReduceMotionMovesNothing),
            ("onlyANewDictationBecomesUndo", testOnlyANewDictationBecomesUndo),
            ("aTurnOnTheWayLandsOnUndosNewPlace", testATurnOnTheWayLandsOnUndosNewPlace),
            ("reduceMotionTurnedOnMidwaySettlesAtOnce", testReduceMotionTurnedOnMidwaySettlesAtOnce),
            ("theBarKnowsWhichDictationItShows", testTheBarKnowsWhichDictationItShows),
        ]
    }

    private typealias Span = IslandLayout.Span

    private static let barWidths = [375.0, 402, 440, 874]
    private static let controlHeights = [38.0, 32]
    private static let frameRate = 120.0

    private static func layout(_ bar: Double, _ height: Double, _ form: IslandForm, leftHanded: Bool) -> IslandLayout {
        IslandLayout(barWidth: bar, controlHeight: height, startWidth: IslandLayout.startWidth(labelWidth: 36, controlHeight: height),
                     form: form, leftHanded: leftHanded)
    }

    /// Undo's chip where the middle starts, beside the menu button, in either hand.
    private static func undo(_ layout: IslandLayout, height: Double) -> IslandBud.Body {
        let width = 72.0
        let x = layout.middleStart == .left ? layout.middle.x : layout.middle.maxX - width
        return IslandBud.Body(minX: x, maxX: x + width, height: height - 8)
    }

    /// A model with the island in `form`, its bud resting at Cancel when there is one.
    private static func settled(_ bar: Double, _ height: Double, _ form: IslandForm, leftHanded: Bool) -> IslandBud.Model {
        let frames = layout(bar, height, form, leftHanded: leftHanded)
        var model = IslandBud.Model(island: frames.island, controlHeight: height, side: frames.growsTowards)
        _ = model.update(island: frames.island, target: frames.cancel.map { .cancel(.circle($0)) } ?? .home,
                         side: frames.growsTowards, controlHeight: height, animated: false, now: 0)
        return model
    }

    /// Steps `model` from `start` to `end` seconds at 120 frames a second, showing `look` each frame; the events, timed.
    @discardableResult
    private static func run(_ model: inout IslandBud.Model, from start: Double = 0, to end: Double,
                            _ look: (Double, IslandBud.Frame) -> Void = { _, _ in }) -> [(Double, IslandBud.Event)] {
        var events: [(Double, IslandBud.Event)] = []
        var t = start
        while t <= end + 1e-9 {
            if let event = model.advance(to: t) { events.append((t, event)) }
            look(t, model.frame(at: t))
            t += 1 / frameRate
        }
        return events
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    private static func near(_ a: Span, _ b: Span, _ tolerance: Double = 0.01) -> Bool {
        near(a.x, b.x, tolerance) && near(a.width, b.width, tolerance)
    }

    private static func near(_ a: IslandBud.Body?, _ b: IslandBud.Body, _ tolerance: Double = 0.05) -> Bool {
        guard let a else { return false }
        return near(a.minX, b.minX, tolerance) && near(a.maxX, b.maxX, tolerance) && near(a.height, b.height, tolerance)
    }

    /// The bud's edge-to-edge gap from the island's end that faces it.
    private static func gap(_ frame: IslandBud.Frame, side: IslandLayout.End) -> Double {
        guard let bud = frame.bud else { return .infinity }
        return side == .left ? frame.island.x - bud.maxX : bud.minX - frame.island.maxX
    }

    /// The island and the bud move as SwiftUI's `spring(response:dampingFraction:)` moves a value (unit mass, stiffness
    /// (2π/response)², damping 4π·dampingFraction/response), so the island drawn here keeps step with the island's
    /// content, which SwiftUI moves with `DictationBarView.islandSpring` (the same `IslandBud.Motion.island`). A new
    /// target keeps the value's place and speed; a delay holds it still.
    private static func testSpringsMoveAsSwiftUIsDo() {
        for spring in [IslandBud.Motion.island, IslandBud.Motion.bud, IslandBud.Motion.lead, IslandBud.Motion.trail] {
            var value = IslandBud.Moving(0)
            value.move(to: 100, with: spring, at: 1)
            TestSupport.expect(near(value.value(at: 1), 0) && near(value.velocity(at: 1), 0), "a spring does not start still")
            TestSupport.expect(near(value.value(at: 1 + 4 * spring.response), 100, 0.05), "\(spring) has not settled")
            // The overshoot of an underdamped spring: exp(-πζ/√(1-ζ²)).
            let zeta = spring.dampingFraction
            let overshoot = 100 * exp(-Double.pi * zeta / (1 - zeta * zeta).squareRoot())
            let peak = stride(from: 1.0, through: 3, by: 0.0005).map { value.value(at: $0) }.max()!
            TestSupport.expect(near(peak - 100, overshoot, 0.05), "\(spring) overshoots \(peak - 100), not \(overshoot)")
            // Its quarter period: halfway (from rest, ζ near 1) in about a quarter of the response.
            let natural = 2 * Double.pi / spring.response
            let analytic = 100 - 100 * exp(-zeta * natural * 0.05)
                * (cos(natural * (1 - zeta * zeta).squareRoot() * 0.05)
                   + zeta / (1 - zeta * zeta).squareRoot() * sin(natural * (1 - zeta * zeta).squareRoot() * 0.05))
            TestSupport.expect(near(value.value(at: 1.05), analytic, 1e-6), "\(spring) is not a damped harmonic spring")
            // Retargeted midway, it keeps its place and speed.
            let before = (value.value(at: 1.08), value.velocity(at: 1.08))
            value.move(to: 40, with: spring, at: 1.08)
            TestSupport.expect(near(value.value(at: 1.08), before.0, 1e-9) && near(value.velocity(at: 1.08), before.1, 1e-6),
                               "a new target jolts \(spring)")
            TestSupport.expect(near(value.value(at: 3), 40, 0.05), "a retargeted \(spring) does not settle at its new target")
            var held = IslandBud.Moving(10)
            held.move(to: 20, with: spring, at: 0, delay: 0.02)
            TestSupport.expect(near(held.value(at: 0.019), 10, 1e-9), "a delayed spring moves early")
            TestSupport.expect(held.value(at: 0.05) > 10, "a delayed spring never starts")
        }
        TestSupport.expect(IslandBud.Motion.island == IslandBud.Spring(response: 0.26, dampingFraction: 0.88),
                           "the island's spring is not round 8's")
    }

    /// Starting a dictation, the × buds out of the island's end that faces the bar's middle: hidden inside it at first,
    /// joined to it by a neck as it swells, then pinched free (within 0.3 s) and settled exactly at Cancel's place, its
    /// × fading in as it parts; once free it never rejoins. Right-handed it buds leftwards, left-handed rightwards.
    private static func testTheBudStartsInsideTheIslandAndPinchesFree() {
        for bar in barWidths {
            for height in controlHeights {
                for leftHanded in [false, true] {
                    let start = layout(bar, height, .compact, leftHanded: leftHanded)
                    let recording = layout(bar, height, .expanded, leftHanded: leftHanded)
                    let side = recording.growsTowards
                    TestSupport.expectEqual(side, leftHanded ? IslandLayout.End.right : .left)
                    var model = settled(bar, height, .compact, leftHanded: leftHanded)
                    let cancel = IslandBud.Body.circle(recording.cancel!)
                    let event = model.update(island: recording.island, target: .cancel(cancel), side: side,
                                             controlHeight: height, animated: true, now: 0)
                    TestSupport.expectEqual(event, nil)
                    let first = model.frame(at: 0)
                    TestSupport.expect(near(first.island, start.island), "the island jumps at Start at \(bar)")
                    guard let bud = first.bud else {
                        TestSupport.expect(false, "no bud at Start at \(bar)")
                        continue
                    }
                    TestSupport.expect(bud.minX >= start.island.x && bud.maxX <= start.island.maxX && bud.height < height,
                                       "the bud starts outside the island at \(bar): \(bud), \(start.island)")
                    TestSupport.expectEqual(first.glyphAlpha, 0)
                    var necks: [Double] = []
                    var widest = 0.0
                    var last = first
                    run(&model, to: 1) { t, frame in
                        if frame.neck != nil { necks.append(t) }
                        // Never past Cancel's place by more than a little give.
                        if let bud = frame.bud {
                            widest = max(widest, side == .left ? cancel.minX - bud.minX : bud.maxX - cancel.maxX)
                        }
                        last = frame
                    }
                    if let joinedAt = necks.first, let freeAt = necks.last {
                        TestSupport.expect(freeAt <= 0.3, "the bud pinches free only at \(freeAt) s at \(bar)")
                        TestSupport.expectEqual(necks.count, Int(((freeAt - joinedAt) * frameRate).rounded()) + 1)
                    } else {
                        TestSupport.expect(false, "the bud never joins the island at \(bar)")
                    }
                    // A little give, never into the middle's room beside Cancel.
                    TestSupport.expect(widest < IslandLayout.spacing, "the bud overshoots Cancel by \(widest) pt at \(bar)")
                    TestSupport.expect(near(last.bud, cancel, 0.01), "the bud rests at \(String(describing: last.bud)), not \(cancel)")
                    TestSupport.expect(near(last.island, recording.island), "the island rests at \(last.island) at \(bar)")
                    TestSupport.expectEqual(last.glyphAlpha, 1)
                    TestSupport.expectEqual(last.budAlpha, 1)
                    TestSupport.expect(!model.needsFrames(at: 1), "a resting bud still asks for frames")
                    // It goes the way the island grows.
                    let moved = cancel.midX - bud.midX
                    TestSupport.expect(side == .left ? moved < 0 : moved > 0, "the bud goes the wrong way at \(bar)")
                }
            }
        }
    }

    /// The neck lets go before the gap reaches Cancel's (`IslandLayout.cancelGap`), so a bud resting at Cancel, beside the
    /// recording or the wait's pill, is never joined to the island; at Stop it slides with the contracting island, in the
    /// island's spring, keeping its gap the whole way.
    private static func testABudBesideTheIslandHasNoNeck() {
        TestSupport.expect(IslandBud.reach < IslandLayout.cancelGap, "a resting bud would keep a neck")
        for bar in barWidths {
            for height in controlHeights {
                for leftHanded in [false, true] {
                    for form in [IslandForm.expanded, .processing] {
                        let frame = settled(bar, height, form, leftHanded: leftHanded).frame(at: 0)
                        TestSupport.expectEqual(frame.neck, nil)
                        TestSupport.expectEqual(frame.glyphAlpha, 1)
                    }
                    var model = settled(bar, height, .expanded, leftHanded: leftHanded)
                    let waiting = layout(bar, height, .processing, leftHanded: leftHanded)
                    _ = model.update(island: waiting.island, target: .cancel(.circle(waiting.cancel!)), side: waiting.growsTowards,
                                     controlHeight: height, animated: true, now: 0)
                    var moved = false
                    run(&model, to: 0.8) { t, frame in
                        TestSupport.expectEqual(frame.neck, nil)
                        TestSupport.expect(near(gap(frame, side: waiting.growsTowards), IslandLayout.cancelGap, 0.01),
                                           "the gap is \(gap(frame, side: waiting.growsTowards)) at \(t) s at \(bar)")
                        if t > 0, t < 0.2, frame.island != waiting.island { moved = true }
                    }
                    TestSupport.expect(moved, "the island does not contract over time at \(bar)")
                    TestSupport.expect(near(model.frame(at: 0.8).bud, .circle(waiting.cancel!), 0.01), "the bud is not beside the wait")
                }
            }
        }
    }

    /// The neck between the island's end and the bud (`IslandBud.neck`) meets both circles, thins steadily as the gap
    /// between them opens and is gone, under half a point thick, before it lets go at `IslandBud.reach`, so the bud pinches
    /// free rather than popping off. It is the same either way round.
    private static func testTheNeckThinsToNothingBeforeItLetsGo() {
        let r1 = 19.0, r2 = 16.0, y = 28.0, c1 = 300.0
        /// The neck's half thickness at its middle (the top curve's midpoint above the centre line).
        func waist(_ neck: IslandBud.Neck) -> Double {
            let (a, b, c, d) = (neck.p1, neck.h1, neck.h3, neck.p3)
            return y - (a.y + 3 * b.y + 3 * c.y + d.y) / 8
        }
        var previous = Double.infinity
        for step in 0...90 {
            let gap = Double(step) / 10 - 0.05
            let c2 = c1 - r1 - r2 - gap
            guard let neck = IslandBud.neck(island: c1, radius: r1, bud: c2, radius: r2, y: y) else {
                TestSupport.expect(false, "no neck at a gap of \(gap)")
                continue
            }
            for point in [neck.p1, neck.p2] {
                TestSupport.expect(near(hypot(point.x - c1, point.y - y), r1, 1e-6), "the neck leaves the island's edge")
            }
            for point in [neck.p3, neck.p4] {
                TestSupport.expect(near(hypot(point.x - c2, point.y - y), r2, 1e-6), "the neck leaves the bud's edge")
            }
            let thickness = waist(neck)
            if gap > 0 {
                TestSupport.expect(thickness < previous + 1e-9, "the neck thickens at a gap of \(gap)")
                previous = thickness
            }
            TestSupport.expect(thickness > 0, "the neck turns inside out at a gap of \(gap)")
            // Mirrored, the same neck.
            if let mirrored = IslandBud.neck(island: -c1, radius: r1, bud: -c2, radius: r2, y: y) {
                TestSupport.expect(near(mirrored.p1.x, -neck.p1.x, 1e-6) && near(mirrored.p3.x, -neck.p3.x, 1e-6)
                                   && near(abs(mirrored.p1.y - y), abs(neck.p1.y - y), 1e-6), "the neck is lopsided")
            } else {
                TestSupport.expect(false, "no mirrored neck at a gap of \(gap)")
            }
        }
        TestSupport.expect(previous < 0.5, "the neck is \(previous) pt thick as it lets go")
        for gap in [IslandBud.reach, IslandBud.reach + 0.5, 30] {
            TestSupport.expectEqual(IslandBud.neck(island: c1, radius: r1, bud: c1 - r1 - r2 - gap, radius: r2, y: y), nil)
        }
        // Wholly inside the island, there is nothing to join.
        TestSupport.expectEqual(IslandBud.neck(island: c1, radius: r1, bud: c1 - 2, radius: 7, y: y), nil)
    }

    /// When the text lands, the bud travels from Cancel's place to Undo's and becomes it: its leading edge leads, so it
    /// stretches on the way and gathers into the chip, ending exactly on Undo's chip; its × fades as it leaves and Undo's
    /// label fades in before it arrives. Within 0.6 s it reports that it has landed, the chip takes over, and the bud
    /// fades out over the chip and stops asking for frames. Right-handed it goes left, left-handed right.
    private static func testTheBudTravelsToUndoAndBecomesIt() {
        for bar in barWidths {
            for height in controlHeights {
                for leftHanded in [false, true] {
                    let start = layout(bar, height, .compact, leftHanded: leftHanded)
                    let side = start.growsTowards
                    let chip = undo(start, height: height)
                    var model = settled(bar, height, .processing, leftHanded: leftHanded)
                    guard let from = model.frame(at: 0).bud else {
                        TestSupport.expect(false, "no bud beside the wait at \(bar)")
                        continue
                    }
                    let event = model.update(island: start.island, target: .undo(chip), side: side, controlHeight: height,
                                             animated: true, now: 0)
                    TestSupport.expectEqual(event, .flightStarted)
                    TestSupport.expect(model.isFlying, "a bud on its way to Undo is not flying")
                    var widest = 0.0
                    var leadFirst = false
                    var labelBy: Double?
                    var frames: [(Double, IslandBud.Frame)] = []
                    let events = run(&model, to: 1.2) { t, frame in
                        frames.append((t, frame))
                        TestSupport.expectEqual(frame.neck, nil)
                        TestSupport.expectEqual(frame.island, start.island)
                        guard let bud = frame.bud else { return }
                        widest = max(widest, bud.maxX - bud.minX)
                        if t >= 0.1, frame.glyphAlpha > 0 { TestSupport.expect(false, "the × lingers at \(t) s") }
                        if labelBy == nil, frame.labelAlpha >= 1 { labelBy = t }
                        if near(t, 0.1, 0.001) {
                            let lead = side == .left ? (from.minX - bud.minX) / (from.minX - chip.minX)
                                                     : (bud.maxX - from.maxX) / (chip.maxX - from.maxX)
                            let trail = side == .left ? (from.maxX - bud.maxX) / (from.maxX - chip.maxX)
                                                      : (bud.minX - from.minX) / (chip.minX - from.minX)
                            leadFirst = lead > trail + 0.05
                        }
                    }
                    TestSupport.expect(leadFirst, "the bud does not stretch towards Undo at \(bar)")
                    TestSupport.expect(widest > chip.maxX - chip.minX + 4, "the bud never stretches at \(bar): \(widest)")
                    guard let landed = events.first(where: { $0.1 == .landed }) else {
                        TestSupport.expect(false, "the bud never lands at \(bar)")
                        continue
                    }
                    TestSupport.expectEqual(events.count, 1)
                    TestSupport.expect(landed.0 <= 0.6, "the bud lands only at \(landed.0) s at \(bar)")
                    TestSupport.expect(labelBy != nil && labelBy! <= landed.0, "Undo's label shows only after the landing")
                    let after = frames.filter { $0.0 >= landed.0 }
                    let atLanding = after[0].1
                    // On the chip to under a pixel.
                    TestSupport.expect(near(atLanding.bud, chip, 0.25), "the bud lands at \(String(describing: atLanding.bud)), not \(chip)")
                    TestSupport.expectEqual(atLanding.glyphAlpha, 0)
                    TestSupport.expect(!model.isFlying, "a landed bud is still flying")
                    let handing = after.first { $0.0 >= landed.0 + IslandBud.Motion.handover / 2 }!.1
                    TestSupport.expect(handing.budAlpha < 1 && near(handing.bud, chip, 0.25), "the bud does not hand over to the chip")
                    TestSupport.expectEqual(model.frame(at: 1.2).bud, nil)
                    TestSupport.expect(!model.needsFrames(at: 1.2), "a landed bud still asks for frames")
                }
            }
        }
    }

    /// With no text (nothing heard, an error) or on Cancel, the island takes the bud back: its × fades at once, it slips
    /// back inside the island's end, and is gone, asking for no more frames. Undo arriving while it is on its way back
    /// does not send it to Undo.
    private static func testWithNoTextTheIslandAbsorbsTheBud() {
        for bar in barWidths {
            for leftHanded in [false, true] {
                for form in [IslandForm.expanded, .processing] {
                    let start = layout(bar, 38, .compact, leftHanded: leftHanded)
                    var model = settled(bar, 38, form, leftHanded: leftHanded)
                    _ = model.update(island: start.island, target: .home, side: start.growsTowards, controlHeight: 38,
                                     animated: true, now: 0)
                    TestSupport.expect(model.frame(at: IslandBud.Motion.absorbFade).glyphAlpha <= 0, "the × lingers")
                    // The text arrives late: no flight.
                    var gone: Double?
                    var inside = false
                    let look = { (t: Double, frame: IslandBud.Frame) in
                        if gone == nil, frame.bud == nil { gone = t }
                        if let bud = frame.bud, bud.minX >= frame.island.x, bud.maxX <= frame.island.maxX { inside = true }
                    }
                    var events = run(&model, to: 0.04, look)
                    let late = model.update(island: start.island, target: .undo(undo(start, height: 38)),
                                            side: start.growsTowards, controlHeight: 38, animated: false, now: 0.05)
                    events += run(&model, from: 0.05, to: 1.2, look)
                    TestSupport.expectEqual(late, nil)
                    TestSupport.expect(events.isEmpty, "absorbing reports \(events)")
                    TestSupport.expect(gone != nil && gone! <= 1, "the bud is not absorbed at \(bar)")
                    // It slips back rather than vanishing: still out at first, inside the island's end before it goes.
                    TestSupport.expect(gone == nil || gone! >= 0.15, "the bud vanishes at once at \(bar)")
                    TestSupport.expect(inside, "the bud never slips inside the island at \(bar)")
                    TestSupport.expect(near(model.frame(at: 1.2).island, start.island), "the island does not settle at Start")
                    TestSupport.expect(!model.needsFrames(at: 1.2), "an absorbed bud still asks for frames")
                }
            }
        }
    }

    /// With Reduce Motion (or a change the bar does not animate: a turn of the phone, the hand) nothing travels: the
    /// island and the bud take their places at once, the bud is simply there beside the recording or the wait and simply
    /// gone after, and nothing asks for frames.
    private static func testReduceMotionMovesNothing() {
        for leftHanded in [false, true] {
            let start = layout(402, 38, .compact, leftHanded: leftHanded)
            let recording = layout(402, 38, .expanded, leftHanded: leftHanded)
            let waiting = layout(402, 38, .processing, leftHanded: leftHanded)
            let side = start.growsTowards
            var model = settled(402, 38, .compact, leftHanded: leftHanded)
            TestSupport.expectEqual(model.frame(at: 0).bud, nil)
            for (island, target) in [(recording.island, IslandBud.Target.cancel(.circle(recording.cancel!))),
                                     (waiting.island, .cancel(.circle(waiting.cancel!)))] {
                TestSupport.expectEqual(model.update(island: island, target: target, side: side, controlHeight: 38,
                                                     animated: false, now: 1), nil)
                let frame = model.frame(at: 1)
                TestSupport.expectEqual(frame.island, island)
                if case .cancel(let body) = target { TestSupport.expectEqual(frame.bud, body) }
                TestSupport.expectEqual(frame.glyphAlpha, 1)
                TestSupport.expect(!model.needsFrames(at: 1), "Reduce Motion asks for frames")
            }
            TestSupport.expectEqual(model.update(island: start.island, target: .undo(undo(start, height: 38)), side: side,
                                                 controlHeight: 38, animated: false, now: 2), nil)
            TestSupport.expectEqual(model.frame(at: 2).bud, nil)
            TestSupport.expectEqual(model.frame(at: 2).island, start.island)
            TestSupport.expect(!model.needsFrames(at: 2), "Reduce Motion asks for frames")
        }
    }

    /// The bud becomes Undo only for the dictation that just finished, when it put in text that can be undone. Undo
    /// still showing for an earlier dictation (a recording cancelled, nothing heard, an error) takes the bud back into
    /// the island; the earlier chip is left alone.
    private static func testOnlyANewDictationBecomesUndo() {
        let cancel = IslandBud.Body(minX: 189, maxX: 221, height: 32), chip = IslandBud.Body(minX: 54, maxX: 126, height: 30)
        TestSupport.expectEqual(IslandBud.target(cancel: cancel, undo: chip, dictationInserted: true), .cancel(cancel))
        TestSupport.expectEqual(IslandBud.target(cancel: cancel, undo: nil, dictationInserted: false), .cancel(cancel))
        TestSupport.expectEqual(IslandBud.target(cancel: nil, undo: chip, dictationInserted: true), .undo(chip))
        TestSupport.expectEqual(IslandBud.target(cancel: nil, undo: chip, dictationInserted: false), .home)
        TestSupport.expectEqual(IslandBud.target(cancel: nil, undo: nil, dictationInserted: true), .home)
    }

    /// The phone turns (or the bar otherwise changes size) while the bud is on its way to Undo: it lands on Undo's new
    /// place, not the old one; and one on its way back into an island that has moved is simply gone.
    private static func testATurnOnTheWayLandsOnUndosNewPlace() {
        for leftHanded in [false, true] {
            let start = layout(402, 38, .compact, leftHanded: leftHanded)
            let turned = layout(874, 32, .compact, leftHanded: leftHanded)
            let side = start.growsTowards
            var model = settled(402, 38, .processing, leftHanded: leftHanded)
            _ = model.update(island: start.island, target: .undo(undo(start, height: 38)), side: side, controlHeight: 38,
                             animated: true, now: 0)
            run(&model, to: 0.1)
            let chip = undo(turned, height: 32)
            TestSupport.expectEqual(model.update(island: turned.island, target: .undo(chip), side: side, controlHeight: 32,
                                                 animated: false, now: 0.1), nil)
            var frames: [(Double, IslandBud.Frame)] = []
            let events = run(&model, from: 0.1, to: 1) { t, frame in frames.append((t, frame)) }
            guard let landedAt = events.first(where: { $0.1 == .landed })?.0,
                  let landing = frames.first(where: { $0.0 >= landedAt })?.1 else {
                TestSupport.expect(false, "the bud never lands after the turn")
                continue
            }
            TestSupport.expect(near(landing.bud, chip, 0.25), "the bud lands at \(String(describing: landing.bud)), not \(chip)")
            TestSupport.expect(near(model.frame(at: 1).island, turned.island), "the island is not where the turn put it")

            // Left-handed the island keeps its place at the bar's left end, so the bud carries on into it.
            let wide = layout(874, 38, .compact, leftHanded: leftHanded).island
            var absorbing = settled(402, 38, .processing, leftHanded: leftHanded)
            _ = absorbing.update(island: start.island, target: .home, side: side, controlHeight: 38, animated: true, now: 0)
            _ = absorbing.update(island: wide, target: .home, side: side, controlHeight: 38, animated: false, now: 0.05)
            if wide != start.island {
                TestSupport.expectEqual(absorbing.frame(at: 0.05).bud, nil)
                TestSupport.expect(!absorbing.needsFrames(at: 0.05), "a bud whose island moved still asks for frames")
            } else {
                TestSupport.expect(absorbing.frame(at: 0.05).bud != nil, "a bud going into an island that stayed vanishes")
                run(&absorbing, from: 0.05, to: 1.2)
                TestSupport.expectEqual(absorbing.frame(at: 1.2).bud, nil)
            }
        }
    }

    /// Reduce Motion turned on while the bud is on its way (budding out, being taken back, going to Undo): everything
    /// takes its place at once, as the island's content does, and nothing more moves.
    private static func testReduceMotionTurnedOnMidwaySettlesAtOnce() {
        for leftHanded in [false, true] {
            let start = layout(402, 38, .compact, leftHanded: leftHanded)
            let recording = layout(402, 38, .expanded, leftHanded: leftHanded)
            let side = start.growsTowards
            // Budding out.
            var budding = settled(402, 38, .compact, leftHanded: leftHanded)
            let cancel = IslandBud.Body.circle(recording.cancel!)
            _ = budding.update(island: recording.island, target: .cancel(cancel), side: side, controlHeight: 38,
                               animated: true, now: 0)
            budding.settle(at: 0.05)
            TestSupport.expectEqual(budding.frame(at: 0.05).bud, cancel)
            TestSupport.expectEqual(budding.frame(at: 0.05).island, recording.island)
            TestSupport.expectEqual(budding.frame(at: 0.05).neck, nil)
            TestSupport.expect(!budding.needsFrames(at: 0.05), "a settled bud still asks for frames")
            // Taken back.
            var absorbing = settled(402, 38, .expanded, leftHanded: leftHanded)
            _ = absorbing.update(island: start.island, target: .home, side: side, controlHeight: 38, animated: true, now: 0)
            absorbing.settle(at: 0.05)
            TestSupport.expectEqual(absorbing.frame(at: 0.05).bud, nil)
            TestSupport.expectEqual(absorbing.frame(at: 0.05).island, start.island)
            TestSupport.expect(!absorbing.needsFrames(at: 0.05), "a settled island still asks for frames")
            // On its way to Undo: it is there, and lands at once.
            var flying = settled(402, 38, .processing, leftHanded: leftHanded)
            let chip = undo(start, height: 38)
            _ = flying.update(island: start.island, target: .undo(chip), side: side, controlHeight: 38, animated: true, now: 0)
            flying.settle(at: 0.05)
            TestSupport.expectEqual(flying.frame(at: 0.05).bud, chip)
            TestSupport.expectEqual(flying.advance(to: 0.05), .landed)
            TestSupport.expect(!flying.isFlying, "a settled bud is still flying")
        }
    }

    /// Which dictation the island shows, by its request (`IslandBud.Shown`), so the bud becomes Undo only when this
    /// keyboard put in that very dictation: from the start of a dictation, also when the bar first appears while one is
    /// already under way (back from LocalFlow); a new dictation forgets the last one at once, even before its request
    /// is known; going idle keeps it for the landing.
    private static func testTheBarKnowsWhichDictationItShows() {
        let a = UUID(), b = UUID()
        var shown = IslandBud.Shown()
        TestSupport.expect(!shown.isInserted(lastInserted: nil), "nothing shown is inserted")
        shown.observe(form: .compact, request: nil)
        shown.observe(form: .expanded, request: a)
        shown.observe(form: .processing, request: a)
        shown.observe(form: .compact, request: a)
        TestSupport.expect(shown.isInserted(lastInserted: a), "the dictation shown is not recognised")
        TestSupport.expect(!shown.isInserted(lastInserted: b), "another dictation is taken for the one shown")
        // The next dictation, its request not yet read: the last one is forgotten at once.
        shown.observe(form: .expanded, request: nil)
        TestSupport.expect(!shown.isInserted(lastInserted: a), "a new dictation keeps the last one's request")
        shown.observe(form: .expanded, request: b)
        shown.observe(form: .compact, request: nil)
        TestSupport.expect(shown.isInserted(lastInserted: b), "going idle forgets the dictation before it lands")
        // A bar that first appears mid-dictation.
        var appearing = IslandBud.Shown()
        appearing.observe(form: .processing, request: b)
        TestSupport.expect(appearing.isInserted(lastInserted: b), "a bar that appears mid-dictation never knows it")
    }
}
