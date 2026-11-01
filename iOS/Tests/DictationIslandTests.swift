import Foundation

/// ARCHITECTURE.md, "Top row" and "Keyboard look": the dictation island's layout in the bar (Start, the recording, the
/// wait for the transcript) and the dot wave it holds while recording.
enum DictationIslandTests {
    static var tests: [TestCase] {
        [
            ("silenceIsAFlatRowOfDots", testSilenceIsAFlatRowOfDots),
            ("louderIsTaller", testLouderIsTaller),
            ("strandsSettleIntoTheMarksDot", testStrandsSettleIntoTheMarksDot),
            ("waveStaysInsideThePill", testWaveStaysInsideThePill),
            ("waveIsDeterministicAndDriftsSlowly", testWaveIsDeterministicAndDriftsSlowly),
            ("levelRisesQuicklyAndFallsSlowly", testLevelRisesQuicklyAndFallsSlowly),
            ("shimmerSweepsAcrossOneCalmRow", testShimmerSweepsAcrossOneCalmRow),
            ("islandIsAnchoredAtTheRight", testIslandIsAnchoredAtTheRight),
            ("cancelNeverMovesOnceShown", testCancelNeverMovesOnceShown),
            ("recordingIslandSpansTheBar", testRecordingIslandSpansTheBar),
            ("processingIslandIsShort", testProcessingIslandIsShort),
            ("barPartsNeverOverlap", testBarPartsNeverOverlap),
        ]
    }

    // MARK: Dot wave

    private static let width = 180.0, height = 24.0

    private static func lit(_ dots: [DotWave.Dot]) -> [DotWave.Dot] {
        dots.filter { $0.brightness >= DotWave.litThreshold }
    }

    /// How far from the middle line the wave's lit dots reach, at its widest over a cycle of the drift.
    private static func spread(level: Double) -> Double {
        (0 ..< 16).map { step in
            lit(DotWave.dots(level: level, phase: Double(step) * .pi / 8, width: width, height: height))
                .map { abs($0.y - height / 2) }.max() ?? 0
        }.max()!
    }

    /// In silence the lit dots are one straight row across the middle, at any phase of the drift; every other dot rests
    /// dim. The row runs the field's whole width: a calm line, not nothing.
    private static func testSilenceIsAFlatRowOfDots() {
        for phase in [0, 1.3, 4.0] {
            let dots = DotWave.dots(level: 0, phase: phase, width: width, height: height)
            TestSupport.expect(!dots.isEmpty, "no dots")
            let row = lit(dots)
            TestSupport.expect(row.allSatisfy { abs($0.y - height / 2) < 1e-9 }, "silence is not flat at phase \(phase)")
            let columns = Set(dots.map { ($0.x * 1000).rounded() }).count
            TestSupport.expect(Double(row.count) >= Double(columns) * 0.4, "the row is broken: \(row.count) of \(columns) columns")
            let brightness = Set(row.map { ($0.brightness * 1e6).rounded() })
            TestSupport.expectEqual(brightness.count, 1)
            for dot in dots where dot.brightness < DotWave.litThreshold {
                TestSupport.expect(abs(dot.brightness - DotWave.restBrightness) < 1e-9, "a resting dot is lit: \(dot)")
            }
        }
    }

    /// A louder level lifts the strands further from the middle line: never less spread for more level, and clearly
    /// more at full level than at half. Levels outside 0...1 count as their nearest end, not a number as silence.
    private static func testLouderIsTaller() {
        let levels = [0, 0.25, 0.5, 0.75, 1.0]
        let spreads = levels.map(spread(level:))
        for (a, b) in zip(spreads, spreads.dropFirst()) {
            TestSupport.expect(b >= a - 1e-9, "louder is lower: \(spreads)")
        }
        TestSupport.expectEqual(spreads[0], 0)
        TestSupport.expect(spreads[2] > 0, "half level is flat: \(spreads)")
        TestSupport.expect(spreads[4] > spreads[2], "full level is no taller than half: \(spreads)")
        TestSupport.expectEqual(spread(level: 3), spreads[4])
        TestSupport.expectEqual(spread(level: -2), 0)
        TestSupport.expectEqual(spread(level: .nan), 0)
        // The lit dots brighten a little with the voice.
        let quiet = lit(DotWave.dots(level: 0, phase: 0, width: width, height: height)).map(\.brightness).max()!
        let loud = lit(DotWave.dots(level: 1, phase: 0, width: width, height: height)).map(\.brightness).max()!
        TestSupport.expect(loud > quiet, "the voice does not brighten the strands")
    }

    /// The strands come to rest in the mark's dot at the right: near it every lit dot is on the middle line, whatever the
    /// level, and the dot sits on that line past the field, inside the pill.
    private static func testStrandsSettleIntoTheMarksDot() {
        for level in [0, 0.6, 1.0] {
            let mark = DotWave.markDot(level: level, width: width, height: height)
            TestSupport.expect(abs(mark.y - height / 2) < 1e-9, "the mark's dot is off the middle line")
            TestSupport.expect(mark.x + mark.radius <= width + 1e-9 && mark.x - mark.radius >= 0, "the mark's dot is outside")
            for phase in [0, 2.0, 5.0] {
                let dots = DotWave.dots(level: level, phase: phase, width: width, height: height)
                let field = dots.map(\.x).max()!
                TestSupport.expect(mark.x - mark.radius > field, "the mark's dot overlaps the field")
                for dot in lit(dots) where dot.x > field - DotWave.pitch {
                    TestSupport.expect(abs(dot.y - height / 2) < 1e-9, "a strand does not settle at the right: \(dot)")
                }
            }
        }
        // The voice swells the dot a little.
        TestSupport.expect(DotWave.markDot(level: 1, width: width, height: height).radius
            > DotWave.markDot(level: 0, width: width, height: height).radius, "the mark's dot ignores the voice")
    }

    /// Every dot, lit or resting, and the mark's dot lie wholly inside the box, for any level and phase, in boxes from the
    /// landscape bar's to a narrow phone's; a box with no room draws nothing.
    private static func testWaveStaysInsideThePill() {
        for (w, h) in [(180.0, 24.0), (90, 18), (420, 20), (40, 12)] {
            for level in [0, 0.4, 1, 7, -1, .nan, .infinity] {
                for phase in [0, 0.9, 3.3, -12] {
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

    /// The same level, phase and size draw the same dots. The drift is slow: well under a cycle a second.
    private static func testWaveIsDeterministicAndDriftsSlowly() {
        TestSupport.expectEqual(DotWave.dots(level: 0.7, phase: 2.2, width: width, height: height),
                                DotWave.dots(level: 0.7, phase: 2.2, width: width, height: height))
        TestSupport.expect(DotWave.dots(level: 0.7, phase: 2.2, width: width, height: height)
            != DotWave.dots(level: 0.7, phase: 2.6, width: width, height: height), "the phase moves nothing")
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

    /// The wait's shimmer: a few rows of dots, the middle one brightest, with a bright spot that moves left to right as
    /// the sweep runs; inside the pill.
    private static func testShimmerSweepsAcrossOneCalmRow() {
        let w = 70.0, h = 24.0
        var previous = -Double.infinity
        for sweep in [0.3, 0.5, 0.7] {
            let dots = DotWave.shimmer(sweep: sweep, width: w, height: h)
            TestSupport.expect(!dots.isEmpty, "no shimmer")
            let rows = Set(dots.map { ($0.y * 1000).rounded() })
            TestSupport.expect(rows.count <= 3, "\(rows.count) rows")
            let brightest = dots.max { $0.brightness < $1.brightness }!
            TestSupport.expect(abs(brightest.y - h / 2) < 1e-9, "the spot is off the middle row")
            TestSupport.expect(brightest.x > previous, "the spot does not move right")
            previous = brightest.x
            for dot in dots {
                TestSupport.expect(dot.x - dot.radius >= -1e-9 && dot.x + dot.radius <= w + 1e-9
                    && dot.y - dot.radius >= -1e-9 && dot.y + dot.radius <= h + 1e-9, "outside: \(dot)")
            }
        }
        TestSupport.expect(DotWave.shimmer(sweep: 0.5, width: 2, height: h).isEmpty, "shimmer in no room")
    }

    // MARK: Island layout

    private static let barWidths = [375.0, 402, 440, 874]
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

    /// Round 5: Cancel must not move once it is shown. It appears with the recording beside the menu button and stays at
    /// the same place through starting, recording and the wait for the transcript, whatever the island does; Start has
    /// no Cancel.
    private static func testCancelNeverMovesOnceShown() {
        for bar in barWidths {
            for height in controlHeights {
                TestSupport.expectEqual(layout(bar, height, .compact).cancel, nil)
                let recording = layout(bar, height, .expanded).cancel, waiting = layout(bar, height, .processing).cancel
                TestSupport.expect(recording != nil, "no Cancel while recording")
                TestSupport.expectEqual(recording, waiting)
                TestSupport.expectEqual(recording?.x, IslandLayout.padding + height + IslandLayout.spacing)
                TestSupport.expectEqual(recording?.width, IslandLayout.cancelWidth(controlHeight: height))
            }
        }
    }

    /// While recording the island fills the bar from Cancel to its right end and the middle gives it all its room; on the
    /// smallest phone the wave inside still keeps room for its caption.
    private static func testRecordingIslandSpansTheBar() {
        for bar in barWidths {
            for height in controlHeights {
                let frames = layout(bar, height, .expanded)
                TestSupport.expectEqual(frames.island.x, frames.cancel!.maxX + IslandLayout.spacing)
                TestSupport.expectEqual(frames.middle.width, 0)
            }
        }
        TestSupport.expect(layout(375, 38, .expanded).island.width >= 250, "the SE's recording island is too narrow")
    }

    /// The wait contracts the island to a short pill that holds only its shimmer, much shorter than the recording and no
    /// wider than Start, so it reads as the recording winding down; the middle gets the room back for the wait's words.
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
            }
        }
    }

    /// Menu, Cancel, middle and island lie left to right inside the bar's padding, the spacing apart, without overlap; the
    /// middle takes what is left, never a negative width, even in a bar too narrow for everything.
    private static func testBarPartsNeverOverlap() {
        for bar in barWidths + [120] {
            for height in controlHeights {
                for form in forms {
                    let frames = layout(bar, height, form)
                    let parts = [frames.menu] + (frames.cancel.map { [$0] } ?? []) + (frames.middle.width > 0 ? [frames.middle] : [])
                        + [frames.island]
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
