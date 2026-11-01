import Foundation

/// ARCHITECTURE.md, "Top row" and "Keyboard look": the dictation island's layout in the bar (Start, the recording, the
/// wait for the transcript, Cancel) and the dot wave it holds while recording.
enum DictationIslandTests {
    static var tests: [TestCase] {
        [
            ("waveIsOneRowOfDots", testWaveIsOneRowOfDots),
            ("silenceIsAFlatRowOfDots", testSilenceIsAFlatRowOfDots),
            ("louderSwellsTheRow", testLouderSwellsTheRow),
            ("strandsSettleIntoTheMarksDot", testStrandsSettleIntoTheMarksDot),
            ("waveStaysInsideThePill", testWaveStaysInsideThePill),
            ("waveIsDeterministicAndDriftsSlowly", testWaveIsDeterministicAndDriftsSlowly),
            ("levelRisesQuicklyAndFallsSlowly", testLevelRisesQuicklyAndFallsSlowly),
            ("shimmerSweepsAlongTheRow", testShimmerSweepsAlongTheRow),
            ("islandIsAnchoredAtTheRight", testIslandIsAnchoredAtTheRight),
            ("recordingIslandIsUnderHalfTheBar", testRecordingIslandIsUnderHalfTheBar),
            ("cancelSitsBesideTheIslandAndNeverMoves", testCancelSitsBesideTheIslandAndNeverMoves),
            ("cancelHasA44PointTargetApartFromStop", testCancelHasA44PointTargetApartFromStop),
            ("processingIslandIsShort", testProcessingIslandIsShort),
            ("recordingKeepsTheMiddleForItsWords", testRecordingKeepsTheMiddleForItsWords),
            ("barPartsNeverOverlap", testBarPartsNeverOverlap),
        ]
    }

    // MARK: Dot wave

    private static let width = 90.0, height = 24.0

    /// Round 9 (owner: the braid over a dim dot field read as the reference video): the wave is one row of dots along the
    /// middle line, evenly spaced, with no dim field around it: every dot is at least the resting brightness.
    private static func testWaveIsOneRowOfDots() {
        for level in [0, 0.5, 1.0] {
            for phase in [0, 1.3, 4.0] {
                let dots = DotWave.dots(level: level, phase: phase, width: width, height: height)
                TestSupport.expect(dots.count >= 10, "only \(dots.count) dots")
                TestSupport.expect(dots.allSatisfy { abs($0.y - height / 2) < 1e-9 }, "a dot leaves the row at \(level), \(phase)")
                TestSupport.expect(dots.allSatisfy { $0.brightness >= DotWave.restBrightness - 1e-9 }, "a dim field dot at \(level)")
                TestSupport.expect(DotWave.restBrightness >= 0.4, "the resting row is a texture, not a line")
                let xs = dots.map(\.x)
                for (a, b) in zip(xs, xs.dropFirst()) {
                    TestSupport.expect(abs(b - a - DotWave.pitch) < 1e-9, "uneven spacing \(b - a)")
                }
                // Dots stay dots: neighbours never touch, however loud.
                for (a, b) in zip(dots, dots.dropFirst()) {
                    TestSupport.expect(b.x - a.x > a.radius + b.radius + 0.3, "dots touch at \(level)")
                }
            }
        }
    }

    /// In silence the row rests: every dot the same size and brightness, at any phase of the drift. A calm line, not
    /// nothing.
    private static func testSilenceIsAFlatRowOfDots() {
        for phase in [0, 1.3, 4.0] {
            for level in [0, -2, .nan] {
                let dots = DotWave.dots(level: level, phase: phase, width: width, height: height)
                TestSupport.expect(!dots.isEmpty, "no dots")
                TestSupport.expect(dots.allSatisfy { abs($0.radius - DotWave.restRadius) < 1e-9 }, "silence swells at \(phase)")
                TestSupport.expect(dots.allSatisfy { abs($0.brightness - DotWave.restBrightness) < 1e-9 }, "silence glows")
            }
        }
    }

    /// A louder level swells the row: its largest dot and its total size never shrink for more level, and full level is
    /// clearly more than half. Levels outside 0...1 count as their nearest end. The swell is a smooth hump: neighbours
    /// differ little, and the row's ends stay near rest, so it rises out of the line at the left and settles into the
    /// mark's dot at the right.
    private static func testLouderSwellsTheRow() {
        func swell(_ level: Double) -> (largest: Double, total: Double) {
            (0 ..< 16).map { step -> (Double, Double) in
                let dots = DotWave.dots(level: level, phase: Double(step) * .pi / 8, width: width, height: height)
                return (dots.map(\.radius).max()!, dots.map(\.radius).reduce(0, +))
            }.reduce((0.0, 0.0)) { (max($0.0, $1.0), max($0.1, $1.1)) }
        }
        let levels = [0, 0.25, 0.5, 0.75, 1.0].map(swell)
        for (a, b) in zip(levels, levels.dropFirst()) {
            TestSupport.expect(b.largest >= a.largest - 1e-9 && b.total >= a.total - 1e-9, "louder is smaller: \(levels)")
        }
        TestSupport.expectEqual(levels[0].largest, DotWave.restRadius)
        TestSupport.expect(levels[4].largest > levels[2].largest && levels[2].largest > DotWave.restRadius, "no swell: \(levels)")
        TestSupport.expect(levels[4].largest >= DotWave.restRadius * 1.8, "the swell is too slight: \(levels)")
        TestSupport.expectEqual(swell(3).largest, levels[4].largest)
        for phase in [0, 0.7, 2.5] {
            let dots = DotWave.dots(level: 1, phase: phase, width: width, height: height)
            let growth = DotWave.restRadius * 1.0
            TestSupport.expect(dots.first!.radius - DotWave.restRadius < growth / 2 && dots.last!.radius - DotWave.restRadius < growth / 2,
                               "the row's ends swell at \(phase)")
            for (a, b) in zip(dots, dots.dropFirst()) {
                TestSupport.expect(abs(a.radius - b.radius) < 0.6, "a jagged step at \(phase)")
            }
            // The Live Activity's strip draws the same swell (`DotWave.lift`).
            for (index, dot) in dots.enumerated() {
                let lift = DotWave.lift(at: Double(index) / Double(dots.count - 1), level: 1, phase: phase)
                TestSupport.expect(abs(dot.radius - (DotWave.restRadius + (DotWave.fullRadius - DotWave.restRadius) * lift)) < 1e-9,
                                   "the strip's swell differs from the wave's")
            }
            // Bigger is brighter: the swell is one shape, not two.
            let largest = dots.max { $0.radius < $1.radius }!
            TestSupport.expectEqual(largest.brightness, dots.map(\.brightness).max()!)
        }
    }

    /// The row comes to rest in the mark's dot at the right: on the middle line past the row, inside the pill, swelling a
    /// little with the voice.
    private static func testStrandsSettleIntoTheMarksDot() {
        for level in [0, 0.6, 1.0] {
            let mark = DotWave.markDot(level: level, width: width, height: height)
            TestSupport.expect(abs(mark.y - height / 2) < 1e-9, "the mark's dot is off the middle line")
            TestSupport.expect(mark.x + mark.radius <= width + 1e-9 && mark.x - mark.radius >= 0, "the mark's dot is outside")
            for phase in [0, 2.0, 5.0] {
                let dots = DotWave.dots(level: level, phase: phase, width: width, height: height)
                let last = dots.max { $0.x < $1.x }!
                TestSupport.expect(mark.x - mark.radius > last.x + last.radius + 1, "the mark's dot overlaps the row")
            }
        }
        TestSupport.expect(DotWave.markDot(level: 1, width: width, height: height).radius
            > DotWave.markDot(level: 0, width: width, height: height).radius, "the mark's dot ignores the voice")
    }

    /// Every dot and the mark's dot lie wholly inside the box, for any level and phase, in boxes from the landscape bar's
    /// to the SE's; a box with no room draws nothing.
    private static func testWaveStaysInsideThePill() {
        for (w, h) in [(180.0, 24.0), (90, 20), (56, 24), (40, 12)] {
            for level in [0, 0.4, 1, 7, -1, .nan, .infinity] {
                for phase in [0, 0.9, 3.3, -12, .nan] {
                    let dots = DotWave.dots(level: level, phase: phase, width: w, height: h)
                        + [DotWave.markDot(level: level, width: w, height: h)]
                    for dot in dots {
                        TestSupport.expect(dot.x - dot.radius >= -1e-9 && dot.x + dot.radius <= w + 1e-9
                            && dot.y - dot.radius >= -1e-9 && dot.y + dot.radius <= h + 1e-9, "outside \(w)x\(h): \(dot)")
                        TestSupport.expect(dot.radius > 0 && dot.brightness >= 0 && dot.brightness <= 1, "bad dot \(dot)")
                    }
                }
            }
        }
        TestSupport.expect(DotWave.dots(level: 1, phase: 0, width: 4, height: 24).isEmpty, "dots in no room")
        TestSupport.expect(DotWave.dots(level: 1, phase: 0, width: 100, height: 2).isEmpty, "dots in no room")
    }

    /// The same level, phase and size draw the same dots. The swell drifts along the row slowly: well under a cycle a
    /// second.
    private static func testWaveIsDeterministicAndDriftsSlowly() {
        TestSupport.expectEqual(DotWave.dots(level: 0.7, phase: 2.2, width: width, height: height),
                                DotWave.dots(level: 0.7, phase: 2.2, width: width, height: height))
        TestSupport.expect(DotWave.dots(level: 0.7, phase: 2.2, width: width, height: height)
            != DotWave.dots(level: 0.7, phase: 2.9, width: width, height: height), "the phase moves nothing")
        let perSecond = DotWave.phase(elapsed: 1) - DotWave.phase(elapsed: 0)
        TestSupport.expect(perSecond > 0.3 && perSecond < .pi, "drift \(perSecond) rad/s")
        TestSupport.expectEqual(DotWave.phase(elapsed: 0), 0)
    }

    /// The level the wave draws follows the input quickly up (most of a jump within a tenth of a second) and slowly down
    /// (still more than half a tenth of a second after silence, nearly gone after a second), never overshooting.
    private static func testLevelRisesQuicklyAndFallsSlowly() {
        var follower = DotWave.LevelFollower()
        TestSupport.expectEqual(follower.value, 0)
        for _ in 0 ..< 6 { follower.follow(1, over: 1.0 / 60) }
        TestSupport.expect(follower.value >= 0.8 && follower.value <= 1, "rise \(follower.value)")
        for _ in 0 ..< 60 { follower.follow(1, over: 1.0 / 60) }
        let top = follower.value
        for _ in 0 ..< 6 { follower.follow(0, over: 1.0 / 60) }
        TestSupport.expect(follower.value >= 0.5 * top, "fall \(follower.value)")
        for _ in 0 ..< 54 { follower.follow(0, over: 1.0 / 60) }
        TestSupport.expect(follower.value <= 0.1 && follower.value >= 0, "after a second \(follower.value)")
        // Out-of-range and missing levels, and odd clocks.
        follower.follow(5, over: 10)
        TestSupport.expect(follower.value <= 1, "overshoot \(follower.value)")
        let held = follower.value
        follower.follow(0, over: 0)
        follower.follow(0, over: -1)
        TestSupport.expectEqual(follower.value, held)
        follower.follow(.nan, over: 10)
        TestSupport.expect(follower.value >= 0 && follower.value < 0.01, "not a number is not silence: \(follower.value)")
        follower.follow(0.5, over: .nan)
        TestSupport.expect(follower.value.isFinite, "a bad clock broke the level")
    }

    /// The wait's shimmer matches the wave: one row of dots on the middle line with a brighter, larger spot that moves
    /// left to right as the sweep runs; inside the pill, and nothing in no room.
    private static func testShimmerSweepsAlongTheRow() {
        let w = 34.0, h = 24.0
        var previous = -Double.infinity
        for sweep in [0.3, 0.5, 0.7] {
            let dots = DotWave.shimmer(sweep: sweep, width: w, height: h)
            TestSupport.expect(dots.count >= 4, "no shimmer")
            TestSupport.expect(dots.allSatisfy { abs($0.y - h / 2) < 1e-9 }, "the shimmer leaves the row")
            let brightest = dots.max { $0.brightness < $1.brightness }!
            TestSupport.expect(brightest.x > previous, "the spot does not move right")
            TestSupport.expectEqual(brightest.radius, dots.map(\.radius).max()!)
            previous = brightest.x
            for dot in dots {
                TestSupport.expect(dot.x - dot.radius >= -1e-9 && dot.x + dot.radius <= w + 1e-9
                    && dot.y - dot.radius >= -1e-9 && dot.y + dot.radius <= h + 1e-9, "outside: \(dot)")
            }
        }
        // Before the spot enters, the row rests evenly.
        let resting = DotWave.shimmer(sweep: -1, width: w, height: h)
        TestSupport.expectEqual(Set(resting.map(\.brightness)).count, 1)
        TestSupport.expect(DotWave.shimmer(sweep: 0.5, width: 2, height: h).isEmpty, "shimmer in no room")
    }

    // MARK: Island layout

    /// Portrait phones (the SE and mini, the 6.1-inch, the Pro, the Plus and Pro Max) and landscape bars.
    private static let barWidths = [375.0, 393, 402, 430, 440, 667, 874, 956]
    private static let controlHeights = [38.0, 32]
    private static let forms: [IslandForm] = [.compact, .expanded, .processing]

    private static func layout(_ bar: Double, _ height: Double, _ form: IslandForm) -> IslandLayout {
        IslandLayout(barWidth: bar, controlHeight: height, startWidth: IslandLayout.startWidth(labelWidth: 36, controlHeight: height),
                     form: form)
    }

    /// The island's right end never moves: Start, Stop and the wait all end at the bar's trailing padding, where the
    /// thumb that tapped Start already is. The menu button keeps the left.
    private static func testIslandIsAnchoredAtTheRight() {
        for bar in barWidths {
            for height in controlHeights {
                for form in forms {
                    let frames = layout(bar, height, form)
                    TestSupport.expectEqual(frames.island.maxX, bar - IslandLayout.padding)
                    TestSupport.expectEqual(frames.menu.x, IslandLayout.padding)
                    TestSupport.expectEqual(frames.menu.width, height)
                }
                TestSupport.expectEqual(layout(bar, height, .compact).island.width,
                                        IslandLayout.startWidth(labelWidth: 36, controlHeight: height))
            }
        }
        // Start is never narrower than before the island (2.4 times its height), and grows with its label.
        TestSupport.expectEqual(IslandLayout.startWidth(labelWidth: 0, controlHeight: 38), 38 * 2.4)
        TestSupport.expect(IslandLayout.startWidth(labelWidth: 80, controlHeight: 38) > 38 * 2.4, "Start does not fit its label")
    }

    /// Round 9 (owner): the speaking pill was too wide; it stays under half the keyboard's width on every phone and in
    /// both orientations, anchored where Start is, and still has room for the wave, the time and the stop glyph. This
    /// replaces round 8's contract that the recording island spans the bar from Cancel to its right end.
    private static func testRecordingIslandIsUnderHalfTheBar() {
        for bar in barWidths {
            for height in controlHeights {
                let recording = layout(bar, height, .expanded)
                TestSupport.expect(recording.island.width < bar / 2, "the island is half the bar or more at \(bar): \(recording.island)")
                TestSupport.expectEqual(recording.island.width, IslandLayout.expandedWidth(barWidth: bar, controlHeight: height))
                TestSupport.expect(recording.island.width >= 140, "no room for the wave, the time and Stop at \(bar): \(recording.island)")
                // It still grows out of Start.
                TestSupport.expect(recording.island.width > layout(bar, height, .compact).island.width * 1.4,
                                   "the island barely grows at \(bar)")
                // Starting and recording are one form: the island never resizes when the recording begins.
                TestSupport.expectEqual(recording.island.width, layout(bar, height, .expanded).island.width)
            }
        }
    }

    /// Round 9 (owner): Cancel within a right thumb's reach, beside the island, while keeping round 5's rule that it never
    /// moves once a dictation starts: the same place while starting, recording and waiting, whatever the island does. Its
    /// centre is in the bar's right half, a clear gap from the island (Cancel discards the dictation, so a near miss for
    /// Stop must not hit it). Start has no Cancel. This replaces round 8's place beside the menu button.
    private static func testCancelSitsBesideTheIslandAndNeverMoves() {
        for bar in barWidths {
            for height in controlHeights {
                TestSupport.expectEqual(layout(bar, height, .compact).cancel, nil)
                let recording = layout(bar, height, .expanded), waiting = layout(bar, height, .processing)
                guard let cancel = recording.cancel else {
                    TestSupport.expect(false, "no Cancel while recording at \(bar)")
                    continue
                }
                TestSupport.expectEqual(waiting.cancel, cancel)
                TestSupport.expectEqual(cancel.width, IslandLayout.cancelWidth(controlHeight: height))
                TestSupport.expect(cancel.x + cancel.width / 2 > bar / 2, "Cancel is not in the right half at \(bar): \(cancel)")
                TestSupport.expectEqual(recording.island.x - cancel.maxX, IslandLayout.cancelGap)
                TestSupport.expect(IslandLayout.cancelGap >= 12, "Cancel crowds Stop")
                // The wait's short pill leaves Cancel where it was: further from the island, never closer.
                TestSupport.expect(waiting.island.x - cancel.maxX >= IslandLayout.cancelGap, "Cancel crowds the wait at \(bar)")
            }
        }
    }

    /// Cancel's tap area is 44 points wide around its circle (Opus, round 8: a tap 2 points beside its 32-point circle
    /// typed "w"), as tall as fits in the bar above the strip below the controls, so it never reaches down into the keys or
    /// the strip that goes to them. Between it and Stop's tap area the keys keep a clear strip, and Stop's reach into the
    /// top row covers only the keys under the island.
    private static func testCancelHasA44PointTargetApartFromStop() {
        TestSupport.expectEqual(KeyboardMetrics.cancelHitSize, 44)
        for bar in barWidths {
            for compact in [false, true] {
                let barHeight = compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight
                let height = compact ? KeyboardMetrics.compactBarControlHeight : KeyboardMetrics.barControlHeight
                let top = (barHeight - height) / 2
                let frames = layout(bar, height, .expanded)
                guard let cancel = frames.cancel else { continue }
                let circle = KeyRect(x: cancel.x, y: top + (height - cancel.width) / 2, width: cancel.width, height: cancel.width)
                let area = KeyboardMetrics.cancelTapArea(circle: circle, barHeight: barHeight, compact: compact)
                TestSupport.expectEqual(area.width, 44)
                TestSupport.expectEqual(area.midX, circle.midX)
                TestSupport.expect(area.x <= circle.x && area.maxX >= circle.maxX && area.y <= circle.y && area.maxY >= circle.maxY,
                                   "Cancel's area does not cover its circle: \(area)")
                // Above the strip below the controls, which the keys take: never into the keys.
                TestSupport.expectEqual(area.maxY, barHeight - KeyboardMetrics.reachAboveKeys(compact: compact))
                TestSupport.expect(area.y >= 0, "Cancel's area leaves the bar: \(area)")
                TestSupport.expectEqual(area.height, compact ? area.maxY : 44)
                let island = KeyRect(x: frames.island.x, y: top, width: frames.island.width, height: height)
                let stop = KeyboardMetrics.startTapArea(capsule: island, barHeight: barHeight, compact: compact, capturing: true)
                TestSupport.expect(stop.x - area.maxX >= 8, "Cancel and Stop are \(stop.x - area.maxX) pt apart at \(bar)")
                TestSupport.expect(stop.width < bar / 2, "Stop reaches across half the top row at \(bar)")
                // The middle holds only words while recording; the menu button keeps its own target.
                TestSupport.expect(area.x >= frames.menu.maxX + IslandLayout.spacing, "Cancel's area reaches the menu at \(bar)")
            }
        }
    }

    /// The wait contracts the island to a short pill that holds only its shimmer, much shorter than the recording and no
    /// wider than Start, so it reads as the recording winding down. The middle, between Cancel and the pill, names the
    /// wait where the recording was.
    private static func testProcessingIslandIsShort() {
        for bar in barWidths {
            for height in controlHeights {
                let waiting = layout(bar, height, .processing), recording = layout(bar, height, .expanded)
                TestSupport.expectEqual(waiting.island.width, IslandLayout.processingWidth(controlHeight: height))
                TestSupport.expect(waiting.island.width < recording.island.width / 2, "the wait is not short")
                TestSupport.expect(waiting.island.width <= layout(bar, height, .compact).island.width, "the wait is wider than Start")
                TestSupport.expect(waiting.island.width >= height * 1.5, "the wait has no room for its shimmer")
                TestSupport.expectEqual(waiting.middle.x, waiting.cancel!.maxX + IslandLayout.spacing)
                TestSupport.expectEqual(waiting.middle.maxX + IslandLayout.spacing, waiting.island.x)
                TestSupport.expect(waiting.middle.width >= 80, "no room to name the wait at \(bar): \(waiting.middle)")
            }
        }
    }

    /// While recording, the middle (the cold start's caption, a notice, "Open LocalFlow to start a session") lies between
    /// the menu and Cancel: plain text, with room for a short line.
    private static func testRecordingKeepsTheMiddleForItsWords() {
        for bar in barWidths {
            for height in controlHeights {
                let recording = layout(bar, height, .expanded)
                TestSupport.expectEqual(recording.middle.x, recording.menu.maxX + IslandLayout.spacing)
                TestSupport.expectEqual(recording.middle.maxX + IslandLayout.spacing, recording.cancel!.x)
                TestSupport.expect(recording.middle.width >= 100, "no room for the caption at \(bar): \(recording.middle)")
            }
        }
    }

    /// Menu, middle, Cancel and island lie left to right inside the bar's padding (Cancel before the middle while waiting),
    /// the spacing apart, without overlap; the middle takes what is left, never a negative width, even in a bar too narrow
    /// for everything.
    private static func testBarPartsNeverOverlap() {
        for bar in barWidths + [120] {
            for height in controlHeights {
                for form in forms {
                    let frames = layout(bar, height, form)
                    let middle = frames.middle.width > 0 ? [frames.middle] : []
                    let cancel = frames.cancel.map { [$0] } ?? []
                    let parts = [frames.menu] + (form == .processing ? cancel + middle : middle + cancel) + [frames.island]
                    for part in parts {
                        TestSupport.expect(part.width >= 0, "negative width in \(bar), \(form): \(frames)")
                        TestSupport.expect(part.x >= IslandLayout.padding - 1e-9 && part.maxX <= bar - IslandLayout.padding + 1e-9,
                                           "outside the bar \(bar), \(form): \(frames)")
                    }
                    for (a, b) in zip(parts, parts.dropFirst()) {
                        TestSupport.expect(b.x >= a.maxX + IslandLayout.spacing - 1e-9, "overlap in \(bar), \(form): \(frames)")
                    }
                    if form == .compact {
                        TestSupport.expectEqual(frames.middle.x, frames.menu.maxX + IslandLayout.spacing)
                    }
                }
            }
        }
    }
}
