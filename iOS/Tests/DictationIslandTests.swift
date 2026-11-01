import Foundation

/// ARCHITECTURE.md, "Top row" and "Keyboard look": the dictation island's layout in the bar (Start, the recording, the
/// wait for the transcript, Cancel) and the dot wave it holds while recording.
enum DictationIslandTests {
    static var tests: [TestCase] {
        [
            ("waveIsOneRowOfDots", testWaveIsOneRowOfDots),
            ("waveIsATinyBitBigger", testWaveIsATinyBitBigger),
            ("silenceIsAFlatRowOfDots", testSilenceIsAFlatRowOfDots),
            ("louderSwellsTheRow", testLouderSwellsTheRow),
            ("theRowIsTheVoiceMovingLeft", testTheRowIsTheVoiceMovingLeft),
            ("syllablesAreDistinctPulses", testSyllablesAreDistinctPulses),
            ("tenLevelsASecondLookContinuous", testTenLevelsASecondLookContinuous),
            ("strandsSettleIntoTheMarksDot", testStrandsSettleIntoTheMarksDot),
            ("waveStaysInsideThePill", testWaveStaysInsideThePill),
            ("shimmerSweepsAlongTheRow", testShimmerSweepsAlongTheRow),
            ("islandIsAnchoredAtTheRight", testIslandIsAnchoredAtTheRight),
            ("recordingIslandIsUnderHalfTheBar", testRecordingIslandIsUnderHalfTheBar),
            ("cancelSitsBesideTheIslandAndNeverMoves", testCancelSitsBesideTheIslandAndNeverMoves),
            ("cancelHasA44PointTargetApartFromStop", testCancelHasA44PointTargetApartFromStop),
            ("processingIslandIsShort", testProcessingIslandIsShort),
            ("recordingKeepsTheMiddleForItsWords", testRecordingKeepsTheMiddleForItsWords),
            ("barPartsNeverOverlap", testBarPartsNeverOverlap),
            ("leftHandedMirrorsTheDictationControls", testLeftHandedMirrorsTheDictationControls),
            ("leftHandedKeepsEveryContractMirrored", testLeftHandedKeepsEveryContractMirrored),
            ("leftHandedStopReachesTheKeysUnderItsIsland", testLeftHandedStopReachesTheKeysUnderItsIsland),
        ]
    }

    // MARK: Dot wave

    private static let width = 90.0, height = 24.0

    /// A voice held at `level` for the whole row.
    private static func held(_ level: Double, width: Double = width, height: Double = height) -> [DotWave.Dot] {
        DotWave.dots(level: level, width: width, height: height)
    }

    /// A trace of the voice as the view records it, one level a frame at 60 frames a second: `level(t)` for t seconds
    /// from 0 to `until`, read through the view's follower.
    private static func trace(until: Double, _ level: (Double) -> Double) -> DotWave.Trace {
        var trace = DotWave.Trace(), follower = DotWave.LevelFollower()
        for frame in 0 ... Int((until * 60).rounded()) {
            let t = Double(frame) / 60
            follower.follow(level(t), over: 1.0 / 60)
            trace.record(follower.value, at: t)
        }
        return trace
    }

    /// Round 9 (owner: the braid over a dim dot field read as the reference video): the wave is one row of dots along the
    /// middle line, evenly spaced, with no dim field around it: every dot is at least the resting brightness.
    private static func testWaveIsOneRowOfDots() {
        let speech = trace(until: 2) { 0.5 + 0.5 * sin($0 * 9) }
        for dots in [held(0), held(0.5), held(1), DotWave.dots(trace: speech, now: 2, width: width, height: height)] {
            TestSupport.expect(dots.count >= 10, "only \(dots.count) dots")
            TestSupport.expect(dots.allSatisfy { abs($0.y - height / 2) < 1e-9 }, "a dot leaves the row")
            TestSupport.expect(dots.allSatisfy { $0.brightness >= DotWave.restBrightness - 1e-9 }, "a dim field dot")
            TestSupport.expect(DotWave.restBrightness >= 0.4, "the resting row is a texture, not a line")
            let xs = dots.map(\.x)
            for (a, b) in zip(xs, xs.dropFirst()) {
                TestSupport.expect(abs(b - a - DotWave.pitch) < 1e-9, "uneven spacing \(b - a)")
            }
            // Dots stay dots: neighbours never touch, however loud.
            for (a, b) in zip(dots, dots.dropFirst()) {
                TestSupport.expect(b.x - a.x > a.radius + b.radius + 0.3, "dots touch")
            }
        }
    }

    /// Round 10 (owner: "make it a tiny bit bigger"): the dots, the swell's height and the mark's dot are each about 15 to
    /// 20 percent larger than round 9's (rest 1.2, full 2.45, mark 2.2 pt), the dots still a dot's gap apart.
    private static func testWaveIsATinyBitBigger() {
        for (now, before) in [(DotWave.restRadius, 1.2), (DotWave.fullRadius, 2.45), (DotWave.markRadius, 2.2)] {
            TestSupport.expect(now >= before * 1.12 && now <= before * 1.25, "\(now) is not a tiny bit bigger than \(before)")
        }
        TestSupport.expect(DotWave.pitch > 2 * DotWave.fullRadius + 0.3, "full dots touch at pitch \(DotWave.pitch)")
        TestSupport.expect(DotWave.pitch <= 5.4 * 1.2, "the row spreads out: pitch \(DotWave.pitch)")
        // The swell's height: a full dot is more than twice a resting one.
        TestSupport.expect(DotWave.fullRadius >= DotWave.restRadius * 2, "the swell is slight")
    }

    /// In silence the row rests: every dot the same size and brightness. A calm line, not nothing. A row that has heard
    /// nothing for its whole span is silent again, however loud it was before.
    private static func testSilenceIsAFlatRowOfDots() {
        for level in [0, -2, .nan] {
            let dots = held(level)
            TestSupport.expect(!dots.isEmpty, "no dots")
            TestSupport.expect(dots.allSatisfy { abs($0.radius - DotWave.restRadius) < 1e-9 }, "silence swells")
            TestSupport.expect(dots.allSatisfy { abs($0.brightness - DotWave.restBrightness) < 1e-9 }, "silence glows")
        }
        let afterwards = trace(until: 3) { $0 < 1 ? 1 : 0 }
        let dots = DotWave.dots(trace: afterwards, now: 3, width: width, height: height)
        TestSupport.expect(dots.allSatisfy { abs($0.radius - DotWave.restRadius) < 0.01 }, "the row never settles: \(dots.map(\.radius))")
        TestSupport.expect(DotWave.dots(trace: DotWave.Trace(), now: 5, width: width, height: height)
            .allSatisfy { abs($0.radius - DotWave.restRadius) < 1e-9 }, "an empty trace swells")
    }

    /// Round 10 (owner: "move more with your voice"): loud and quiet look clearly different. A voice held loud swells the
    /// row at least twice as much as one held at half, and full level is the whole swell; levels outside 0...1 count as
    /// their nearest end. Bigger is brighter: the swell is one shape, not two. The Live Activity's strip draws the same
    /// lift (`DotWave.lift`).
    private static func testLouderSwellsTheRow() {
        func growth(_ dots: [DotWave.Dot]) -> Double { dots.map { $0.radius - DotWave.restRadius }.reduce(0, +) }
        let levels = [0, 0.25, 0.5, 0.75, 1.0].map { growth(held($0)) }
        for (a, b) in zip(levels, levels.dropFirst()) {
            TestSupport.expect(b >= a - 1e-9, "louder is smaller: \(levels)")
        }
        TestSupport.expect(levels[4] >= 2 * levels[2], "loud and half look alike: \(levels)")
        TestSupport.expect(levels[2] > 0, "half a level shows nothing")
        TestSupport.expect(abs(held(1).map(\.radius).max()! - DotWave.fullRadius) < 0.05, "full level is not the whole swell")
        TestSupport.expectEqual(held(3), held(1))
        // The same word said quietly and loudly, at the same place in the row: the loud one's dots are clearly larger.
        func word(_ level: Double) -> [DotWave.Dot] {
            DotWave.dots(trace: trace(until: 1) { $0 >= 0.6 && $0 < 0.8 ? level : 0 }, now: 1, width: width, height: height)
        }
        let quiet = word(0.5), loudWord = word(1), row = loudWord
        TestSupport.expect(growth(loudWord) > 2 * growth(quiet) && growth(quiet) > 0,
                           "loud and quiet words look alike: \(quiet.map(\.radius)) vs \(loudWord.map(\.radius))")
        for dots in [held(1), row] {
            for (index, dot) in dots.enumerated() {
                let largest = dots.max { $0.radius < $1.radius }!
                TestSupport.expectEqual(largest.brightness, dots.map(\.brightness).max()!)
                TestSupport.expect(dot.brightness <= 1 && dot.radius <= DotWave.fullRadius + 1e-9, "dot \(index) overflows")
            }
        }
        // The Live Activity's still strip has the wave's lift: a few pulses, resting at the left end.
        let strip = (0 ... 24).map { DotWave.stillLift(at: Double($0) / 24) }
        TestSupport.expect(strip.first! < 0.05, "the strip's left end swells")
        let peaks = zip(zip(strip, strip.dropFirst()), strip.dropFirst(2)).filter { $0.0.1 > $0.0.0 && $0.0.1 >= $0.1 && $0.0.1 > 0.2 }
        TestSupport.expect(peaks.count >= 2, "the still strip is one smooth hump, not a voice: \(strip)")
    }

    /// Round 10 (owner: "slow, consistent and wavelike"): the row's shape is the voice's own, not a fixed sine. It shows
    /// the last `DotWave.span` seconds of the voice, the newest beside the mark's dot at the right; what was said moves
    /// left as it ages and leaves the row after `span`, so a syllable crosses the row at the wait shimmer's pace. The row
    /// rises out of the line at the left.
    private static func testTheRowIsTheVoiceMovingLeft() {
        TestSupport.expect(abs(DotWave.span - DotWave.shimmerPeriod) <= 0.25, "the wave's pace \(DotWave.span) s is not the shimmer's")
        TestSupport.expectEqual(DotWave.shimmerPeriod, 1.1)
        // One syllable at 0.2 s, then silence.
        let syllable = trace(until: 1.6) { $0 >= 0.2 && $0 < 0.32 ? 1 : 0 }
        func peak(at now: Double) -> Double {
            let dots = DotWave.dots(trace: syllable, now: now, width: width, height: height)
            let largest = dots.max { $0.radius < $1.radius }!
            return largest.radius > DotWave.restRadius + 0.3 ? largest.x : -1
        }
        let early = peak(at: 0.45), later = peak(at: 0.8)
        TestSupport.expect(early > 0 && later > 0, "the syllable does not show: \(early), \(later)")
        TestSupport.expect(early > later + 10, "the syllable does not move left: \(early) then \(later)")
        // Its speed: across the row in `span`.
        let rowLength = DotWave.dots(level: 0, width: width, height: height).map(\.x).max()!
            - DotWave.dots(level: 0, width: width, height: height).map(\.x).min()!
        let speed = (early - later) / 0.35
        TestSupport.expect(abs(speed - rowLength / DotWave.span) < rowLength / DotWave.span * 0.35, "speed \(speed) pt/s")
        TestSupport.expect(peak(at: 0.26 + DotWave.span + 0.25) < 0, "the syllable never leaves the row")
        // The left end rises out of the line: it never takes the voice's full height.
        let loud = held(1)
        TestSupport.expect(loud.first!.radius - DotWave.restRadius < (DotWave.fullRadius - DotWave.restRadius) / 2, "the left end swells")
        // The same trace and moment draw the same dots.
        TestSupport.expectEqual(DotWave.dots(trace: syllable, now: 0.5, width: width, height: height),
                                DotWave.dots(trace: syllable, now: 0.5, width: width, height: height))
    }

    /// Round 10 (owner): syllables read as distinct pulses. The level follows the input quickly up (most of a jump within
    /// 50 ms) and quickly down (under a fifth within 0.2 s; round 9 kept half after 0.1 s, a 0.4 s fall), never
    /// overshooting; two syllables 0.25 s apart show as two pulses with a dip between them.
    private static func testSyllablesAreDistinctPulses() {
        var follower = DotWave.LevelFollower()
        TestSupport.expectEqual(follower.value, 0)
        for _ in 0 ..< 3 { follower.follow(1, over: 1.0 / 60) }
        TestSupport.expect(follower.value >= 0.8 && follower.value <= 1, "rise \(follower.value)")
        for _ in 0 ..< 60 { follower.follow(1, over: 1.0 / 60) }
        for _ in 0 ..< 12 { follower.follow(0, over: 1.0 / 60) }
        TestSupport.expect(follower.value <= 0.2 && follower.value >= 0, "fall \(follower.value)")
        TestSupport.expect(DotWave.LevelFollower.fall <= 0.15, "the fall is slow: \(DotWave.LevelFollower.fall)")
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
        // Two syllables, as the host reports them: a level every 0.1 s.
        let twoSyllables = trace(until: 1) { t in
            let sample = (t * 10).rounded(.down) / 10
            return (sample >= 0.2 && sample < 0.3) || (sample >= 0.5 && sample < 0.6) ? 1 : 0.05
        }
        let lifts = (0 ... 40).map { DotWave.lift(at: 1 - Double($0) / 40 * 0.9, trace: twoSyllables, now: 0.75) }
        let first = lifts.firstIndex { $0 > 0.35 }, dips = lifts.indices.filter { index in
            index > 0 && index < lifts.count - 1 && lifts[index] < lifts[index - 1] && lifts[index] <= lifts[index + 1]
        }
        TestSupport.expect(first != nil, "no pulse: \(lifts)")
        TestSupport.expect(dips.contains { lifts[$0] < 0.6 * (lifts.max() ?? 0) }, "two syllables blur into one: \(lifts)")
    }

    /// No jaggedness or flicker: levels that arrive ten times a second (a step each 0.1 s) draw a row whose neighbours
    /// differ by less than half the swell, and no dot changes size by more than a tenth of the swell from one 60 Hz frame
    /// to the next.
    private static func testTenLevelsASecondLookContinuous() {
        let steps = trace(until: 2.5) { t in
            let sample = (t * 10).rounded(.down)
            return sample.truncatingRemainder(dividingBy: 3) == 0 ? 1 : 0.2
        }
        let swell = DotWave.fullRadius - DotWave.restRadius
        var previous: [DotWave.Dot]?
        for frame in 0 ..< 60 {
            let now = 1.2 + Double(frame) / 60
            let dots = DotWave.dots(trace: steps, now: now, width: width, height: height)
            for (a, b) in zip(dots, dots.dropFirst()) {
                TestSupport.expect(abs(a.radius - b.radius) < swell / 2, "a jagged step at \(now)")
            }
            if let previous {
                for (a, b) in zip(previous, dots) {
                    TestSupport.expect(abs(a.radius - b.radius) <= swell / 10 + 1e-9, "a dot jumps at \(now): \(a.radius) to \(b.radius)")
                }
            }
            previous = dots
        }
    }

    /// The row comes to rest in the mark's dot at the right: on the middle line past the row, inside the pill, swelling a
    /// little with the voice.
    private static func testStrandsSettleIntoTheMarksDot() {
        for level in [0, 0.6, 1.0] {
            let mark = DotWave.markDot(level: level, width: width, height: height)
            TestSupport.expect(abs(mark.y - height / 2) < 1e-9, "the mark's dot is off the middle line")
            TestSupport.expect(mark.x + mark.radius <= width + 1e-9 && mark.x - mark.radius >= 0, "the mark's dot is outside")
            let last = held(level).max { $0.x < $1.x }!
            TestSupport.expect(mark.x - mark.radius > last.x + last.radius + 1, "the mark's dot overlaps the row")
        }
        TestSupport.expect(DotWave.markDot(level: 1, width: width, height: height).radius
            > DotWave.markDot(level: 0, width: width, height: height).radius, "the mark's dot ignores the voice")
    }

    /// Every dot and the mark's dot lie wholly inside the box, for any level, in boxes from the landscape bar's to the SE's;
    /// a box with no room draws nothing.
    private static func testWaveStaysInsideThePill() {
        let loud = trace(until: 1) { _ in 1 }
        for (w, h) in [(180.0, 24.0), (90, 20), (56, 24), (40, 12)] {
            for level in [0, 0.4, 1, 7, -1, .nan, .infinity] {
                let dots = held(level, width: w, height: h) + DotWave.dots(trace: loud, now: 1, width: w, height: h)
                    + [DotWave.markDot(level: level, width: w, height: h)]
                for dot in dots {
                    TestSupport.expect(dot.x - dot.radius >= -1e-9 && dot.x + dot.radius <= w + 1e-9
                        && dot.y - dot.radius >= -1e-9 && dot.y + dot.radius <= h + 1e-9, "outside \(w)x\(h): \(dot)")
                    TestSupport.expect(dot.radius > 0 && dot.brightness >= 0 && dot.brightness <= 1, "bad dot \(dot)")
                }
            }
        }
        TestSupport.expect(held(1, width: 4, height: 24).isEmpty, "dots in no room")
        TestSupport.expect(held(1, width: 100, height: 2).isEmpty, "dots in no room")
        // Odd clocks and levels never break the trace.
        var odd = DotWave.Trace()
        for (level, time) in [(0.5, 0.0), (.nan, 0.1), (2, 0.05), (0.5, .nan), (1, 0.2)] { odd.record(level, at: time) }
        for now in [0.2, -1, .nan, 1e9] {
            let lift = DotWave.lift(at: 0.9, trace: odd, now: now)
            TestSupport.expect(lift.isFinite && lift >= 0 && lift <= 1, "a bad trace lifts \(lift) at \(now)")
        }
    }

    /// The wait's shimmer matches the wave: one row of dots on the middle line with a brighter, larger spot that moves
    /// left to right as the sweep runs; inside the pill, and nothing in no room. Round 10 (Opus, round 9: 6 dots): the
    /// wait's pill holds 8 or 9 of them on a phone.
    private static func testShimmerSweepsAlongTheRow() {
        let w = IslandLayout.processingWidth(controlHeight: KeyboardMetrics.barControlHeight) - 2 * DotWave.shimmerInset, h = 24.0
        var previous = -Double.infinity
        for sweep in [0.3, 0.5, 0.7] {
            let dots = DotWave.shimmer(sweep: sweep, width: w, height: h)
            TestSupport.expect((8 ... 9).contains(dots.count), "\(dots.count) shimmer dots")
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
        let landscape = IslandLayout.processingWidth(controlHeight: KeyboardMetrics.compactBarControlHeight) - 2 * DotWave.shimmerInset
        TestSupport.expect(DotWave.shimmer(sweep: 0.5, width: landscape, height: 20).count >= 6, "landscape's shimmer is short")
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

    private static func layout(_ bar: Double, _ height: Double, _ form: IslandForm, leftHanded: Bool = false) -> IslandLayout {
        IslandLayout(barWidth: bar, controlHeight: height, startWidth: IslandLayout.startWidth(labelWidth: 36, controlHeight: height),
                     form: form, leftHanded: leftHanded)
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
    /// wider than Start, so it reads as the recording winding down. Round 10 (Opus, round 9: 1.5 times its height held 6
    /// dots beside a wide gap; the owner: the wait's words go): about 1.9 times its height, room for 8 or 9 dots
    /// (`testShimmerSweepsAlongTheRow`). The middle, between Cancel and the pill, keeps room for a notice in two lines
    /// (round 9 kept 80 points there for "Transcribing…", which no longer shows).
    private static func testProcessingIslandIsShort() {
        for bar in barWidths {
            for height in controlHeights {
                let waiting = layout(bar, height, .processing), recording = layout(bar, height, .expanded)
                TestSupport.expectEqual(waiting.island.width, IslandLayout.processingWidth(controlHeight: height))
                TestSupport.expect(waiting.island.width < recording.island.width / 2, "the wait is not short")
                TestSupport.expect(waiting.island.width <= layout(bar, height, .compact).island.width, "the wait is wider than Start")
                TestSupport.expect(waiting.island.width >= height * 1.85 && waiting.island.width <= height * 2,
                                   "the wait's pill is \(waiting.island.width / height) times its height")
                TestSupport.expectEqual(waiting.middle.x, waiting.cancel!.maxX + IslandLayout.spacing)
                TestSupport.expectEqual(waiting.middle.maxX + IslandLayout.spacing, waiting.island.x)
                TestSupport.expect(waiting.middle.width >= 60, "no room for a notice at \(bar): \(waiting.middle)")
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

    // MARK: Left-handed (round 10, owner)

    /// The span reflected across the bar's middle.
    private static func mirrored(_ span: IslandLayout.Span, in bar: Double) -> IslandLayout.Span {
        IslandLayout.Span(x: bar - span.maxX, width: span.width)
    }

    /// Left-handed, the bar's parts are the right-handed ones reflected across its middle: Start and the island at the
    /// left end, growing rightwards, Cancel on the island's right, the menu button at the right end, the middle between.
    /// Off, the layout is exactly today's.
    private static func testLeftHandedMirrorsTheDictationControls() {
        for bar in barWidths + [120] {
            for height in controlHeights {
                for form in forms {
                    let right = layout(bar, height, form), left = layout(bar, height, form, leftHanded: true)
                    TestSupport.expectEqual(IslandLayout(barWidth: bar, controlHeight: height,
                                                         startWidth: IslandLayout.startWidth(labelWidth: 36, controlHeight: height),
                                                         form: form), right)
                    TestSupport.expectEqual(left.menu, mirrored(right.menu, in: bar))
                    TestSupport.expectEqual(left.island, mirrored(right.island, in: bar))
                    TestSupport.expectEqual(left.middle, mirrored(right.middle, in: bar))
                    TestSupport.expectEqual(left.cancel, right.cancel.map { mirrored($0, in: bar) })
                    TestSupport.expectEqual(left.island.x, IslandLayout.padding)
                    TestSupport.expectEqual(left.menu.maxX, bar - IslandLayout.padding)
                }
            }
        }
    }

    /// Every round 9 contract holds mirrored: the recording island under half the bar, Cancel beside it in the bar's left
    /// half (a left thumb's), a clear gap from Stop, in one place from starting through the wait, with its 44-point target
    /// apart from Stop's and the menu's.
    private static func testLeftHandedKeepsEveryContractMirrored() {
        for bar in barWidths {
            for compact in [false, true] {
                let barHeight = compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight
                let height = compact ? KeyboardMetrics.compactBarControlHeight : KeyboardMetrics.barControlHeight
                let top = (barHeight - height) / 2
                let recording = layout(bar, height, .expanded, leftHanded: true)
                let waiting = layout(bar, height, .processing, leftHanded: true)
                TestSupport.expectEqual(layout(bar, height, .compact, leftHanded: true).cancel, nil)
                guard let cancel = recording.cancel else {
                    TestSupport.expect(false, "no Cancel while recording at \(bar)")
                    continue
                }
                TestSupport.expect(recording.island.width < bar / 2, "the island is half the bar or more at \(bar)")
                TestSupport.expectEqual(waiting.cancel, cancel)
                TestSupport.expect(cancel.x + cancel.width / 2 < bar / 2, "Cancel is not in the left half at \(bar): \(cancel)")
                TestSupport.expectEqual(cancel.x - recording.island.maxX, IslandLayout.cancelGap)
                TestSupport.expect(cancel.x - waiting.island.maxX >= IslandLayout.cancelGap, "Cancel crowds the wait at \(bar)")
                let circle = KeyRect(x: cancel.x, y: top + (height - cancel.width) / 2, width: cancel.width, height: cancel.width)
                let area = KeyboardMetrics.cancelTapArea(circle: circle, barHeight: barHeight, compact: compact)
                TestSupport.expectEqual(area.width, 44)
                let island = KeyRect(x: recording.island.x, y: top, width: recording.island.width, height: height)
                let stop = KeyboardMetrics.startTapArea(capsule: island, barHeight: barHeight, compact: compact, capturing: true)
                TestSupport.expect(area.x - stop.maxX >= 8, "Cancel and Stop are \(area.x - stop.maxX) pt apart at \(bar)")
                TestSupport.expect(stop.width < bar / 2, "Stop reaches across half the top row at \(bar)")
                TestSupport.expect(area.maxX <= recording.menu.x - IslandLayout.spacing, "Cancel's area reaches the menu at \(bar)")
                TestSupport.expect(recording.middle.width >= 100, "no room in the middle at \(bar)")
            }
        }
    }

    /// Left-handed, Stop's reach into the top row covers the keys under the mirrored island, at the bar's left, and no
    /// others: the top row's right-hand keys type while recording.
    private static func testLeftHandedStopReachesTheKeysUnderItsIsland() {
        let width = 402.0, barHeight = KeyboardMetrics.barHeight, height = KeyboardMetrics.barControlHeight
        let recording = layout(width, height, .expanded, leftHanded: true)
        let island = KeyRect(x: recording.island.x, y: (barHeight - height) / 2, width: recording.island.width, height: height)
        let stop = KeyboardMetrics.startTapArea(capsule: island, barHeight: barHeight, compact: false, capturing: true)
        let metrics = KeyboardMetrics(width: width, height: KeyboardMetrics.regularHeight)
        let keys = KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: false)
        let topRow = keys.filter { $0.frame.y == metrics.rowY(0) }
        let reached = topRow.filter { KeyboardMetrics.keyPointGoesToStart(x: $0.frame.midX, y: $0.frame.midY, barHeight: barHeight, start: stop) }
        TestSupport.expect(reached.contains { $0.label == "q" } && reached.contains { $0.label == "w" }, "Stop misses q and w: \(reached.map(\.label))")
        TestSupport.expect(!reached.contains { $0.label == "p" } && !reached.contains { $0.label == "o" }, "Stop takes p or o")
        TestSupport.expect(reached.allSatisfy { $0.frame.midX < width / 2 }, "Stop reaches the right half")
    }
}
