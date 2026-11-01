import Foundation

/// ARCHITECTURE.md, "Keyboard look": the brand palette's contrast in both modes and with Increase Contrast, the ridge
/// mark's geometry, the recording wave, and which dictation state shows which colour and text.
enum KeyboardLookTests {
    static var tests: [TestCase] {
        [
            ("textOnEveryBrandFillReadsAtAA", testTextOnEveryBrandFillReadsAtAA),
            ("brandFillsStandOffTheBackdropOrHaveAnEdge", testBrandFillsStandOffTheBackdropOrHaveAnEdge),
            ("brandGlyphsAndStrokesReachThreeToOne", testBrandGlyphsAndStrokesReachThreeToOne),
            ("lightModeUsesDeeperHues", testLightModeUsesDeeperHues),
            ("theLightWaitingCapsuleIsCalmer", testTheLightWaitingCapsuleIsCalmer),
            ("highlightedCandidateStaysLegible", testHighlightedCandidateStaysLegible),
            ("swipeTrailRunsFromGlacierToAurora", testSwipeTrailRunsFromGlacierToAurora),
            ("menuLinkIsTheBrandAccent", testMenuLinkIsTheBrandAccent),
            ("ridgeMarkIsTheIconsLineAndDot", testRidgeMarkIsTheIconsLineAndDot),
            ("ridgeMarkFitsItsBoxCentred", testRidgeMarkFitsItsBoxCentred),
            ("waveFollowsTheLevelsNewestAtTheRight", testWaveFollowsTheLevelsNewestAtTheRight),
            ("waveFlowsLeftAndKeepsEachLevelsSide", testWaveFlowsLeftAndKeepsEachLevelsSide),
            ("waveStaysInsideItsBox", testWaveStaysInsideItsBox),
            ("capsuleStyleFollowsTheMode", testCapsuleStyleFollowsTheMode),
            ("barStatusShowsTheWaveWhileRecording", testBarStatusShowsTheWaveWhileRecording),
            ("capsuleHoldsItsWidthUntilTheTranscript", testCapsuleHoldsItsWidthUntilTheTranscript),
            ("idleLineShowsReadinessWithADot", testIdleLineShowsReadinessWithADot),
            ("statusLineReadsAtAAOnTheBackdrop", testStatusLineReadsAtAAOnTheBackdrop),
            ("loadingCaptionHasAShortForm", testLoadingCaptionHasAShortForm),
        ]
    }

    private typealias RGB = BrandPalette.RGB

    private static func ratio(_ a: RGB, _ b: RGB) -> Double { MenuPalette.contrast(a, b) }

    private static func variants(_ body: (BrandPalette, String) -> Void) {
        for dark in [false, true] {
            for high in [false, true] {
                body(BrandPalette(dark: dark, highContrast: high), "\(dark ? "dark" : "light")\(high ? " high" : "")")
            }
        }
    }

    private static func fills(_ palette: BrandPalette) -> [(String, BrandPalette.Fill)] {
        [("accent", palette.accent), ("stop", palette.stop), ("working", palette.working)]
    }

    // MARK: Palette

    /// Ink on Start, the action keys and caps lock (aurora), Stop (coral) and the preparing capsule (glacier), at both
    /// ends of each fill's gradient.
    private static func testTextOnEveryBrandFillReadsAtAA() {
        variants { palette, name in
            for (role, fill) in fills(palette) {
                for (end, color) in [("top", fill.top), ("bottom", fill.bottom)] {
                    let value = ratio(fill.ink, color)
                    TestSupport.expect(value >= 4.5, "\(role) ink on \(end), \(name): \(value)")
                }
            }
        }
    }

    /// A filled control reaches 3:1 against the keyboard's backdrop, or has an edge that does.
    private static func testBrandFillsStandOffTheBackdropOrHaveAnEdge() {
        variants { palette, name in
            for (role, fill) in fills(palette) {
                let fillRatio = min(ratio(fill.top, palette.backdrop), ratio(fill.bottom, palette.backdrop))
                let edgeRatio = fill.edge.map { ratio($0, palette.backdrop) } ?? 0
                TestSupport.expect(fillRatio >= 3 || edgeRatio >= 3, "\(role), \(name): fill \(fillRatio), edge \(edgeRatio)")
            }
            TestSupport.expect(palette.edgeWidth > 0 && palette.edgeWidth <= 1, "edge width \(palette.edgeWidth), \(name)")
        }
        // Round 4 council (Opus, visual 5): the light keyboard's 1-point edge read as a sticker outline beside the
        // edgeless keys. It is a hairline, in the same deep hue (so its contrast holds), and a full point again with
        // Increase Contrast.
        let light = BrandPalette(dark: false, highContrast: false), lightHigh = BrandPalette(dark: false, highContrast: true)
        TestSupport.expect(light.edgeWidth < 1, "light edge \(light.edgeWidth)")
        TestSupport.expectEqual(lightHigh.edgeWidth, 1)
    }

    /// The wave, the jump bar's category and an error's symbol on the backdrop, and accent glyphs on a key or chip
    /// (Undo's symbol).
    private static func testBrandGlyphsAndStrokesReachThreeToOne() {
        variants { palette, name in
            for (role, color) in [("aurora", palette.aurora), ("glacier", palette.glacier), ("coral", palette.coral),
                                  ("ember", palette.ember)] {
                let value = ratio(color, palette.backdrop)
                TestSupport.expect(value >= 3, "\(role) on the backdrop, \(name): \(value)")
            }
            let onKey = ratio(palette.keyGlyph, palette.keyFill)
            TestSupport.expect(onKey >= 3, "key glyph on the key fill, \(name): \(onKey)")
        }
    }

    /// The light keyboard's strokes are darker than the dark keyboard's, in the same hues: the bright brand colours are
    /// too pale on a light backdrop. The dark keyboard uses the app's colours as they are.
    private static func testLightModeUsesDeeperHues() {
        let dark = BrandPalette(dark: true, highContrast: false), light = BrandPalette(dark: false, highContrast: false)
        TestSupport.expectEqual(dark.aurora, BrandPalette.aurora)
        TestSupport.expectEqual(dark.glacier, BrandPalette.glacier)
        TestSupport.expectEqual(dark.coral, BrandPalette.coral)
        TestSupport.expectEqual(dark.ember, BrandPalette.ember)
        TestSupport.expectEqual(dark.accent.ink, BrandPalette.ink)
        for (role, deep, bright) in [("aurora", light.aurora, BrandPalette.aurora), ("glacier", light.glacier, BrandPalette.glacier),
                                     ("coral", light.coral, BrandPalette.coral), ("ember", light.ember, BrandPalette.ember)] {
            TestSupport.expect(deep.luminance < bright.luminance / 2, "\(role) is not deeper in light mode")
            TestSupport.expect(sameHue(deep, bright), "\(role) changes hue in light mode: \(hue(deep)) vs \(hue(bright))")
        }
        // Increase Contrast never lowers a stroke's contrast.
        for darkMode in [false, true] {
            let normal = BrandPalette(dark: darkMode, highContrast: false), high = BrandPalette(dark: darkMode, highContrast: true)
            for (a, b) in [(normal.aurora, high.aurora), (normal.glacier, high.glacier), (normal.coral, high.coral),
                           (normal.ember, high.ember)] {
                TestSupport.expect(ratio(b, high.backdrop) >= ratio(a, normal.backdrop) - 1e-9, "Increase Contrast lowered a stroke")
            }
        }
    }

    /// Round 6 council (Opus, visual): on the light keyboard the bright glacier capsule (preparing, transcribing) was the
    /// loudest thing on the bar while the user waits, louder than Stop, the action before it. There its fill is the glacier
    /// at about 85% of its saturation, the same hue and brightness; ink on it and its edge keep their contrast (the AA and
    /// edge tests above). The dark keyboard keeps the app's glacier.
    private static func testTheLightWaitingCapsuleIsCalmer() {
        func saturation(_ c: RGB) -> Double {
            let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue)
            return high > 0 ? (high - low) / high : 0
        }
        for high in [false, true] {
            let light = BrandPalette(dark: false, highContrast: high), dark = BrandPalette(dark: true, highContrast: high)
            TestSupport.expectEqual(dark.working.top, BrandPalette.glacier)
            TestSupport.expectEqual(dark.working.bottom, BrandPalette.glacier)
            for fill in [light.working.top, light.working.bottom] {
                let share = saturation(fill) / saturation(BrandPalette.glacier)
                TestSupport.expect(share >= 0.8 && share <= 0.9, "light working saturation \(share) of the glacier's")
                TestSupport.expect(sameHue(fill, BrandPalette.glacier), "light working hue \(hue(fill))")
                TestSupport.expect(abs(max(fill.red, fill.green, fill.blue) - max(BrandPalette.glacier.red, BrandPalette.glacier.green,
                                                                                  BrandPalette.glacier.blue)) < 0.01,
                                   "light working brightness")
                TestSupport.expect(ratio(light.working.ink, fill) >= 4.5, "ink on the light working fill")
            }
            TestSupport.expect(light.working.edge.map { ratio($0, light.backdrop) >= 3 } == true, "light working edge")
        }
    }

    /// The hue in degrees, 0 to 360; -1 for a grey.
    private static func hue(_ c: RGB) -> Double {
        let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue)
        guard high > low else { return -1 }
        var hue: Double
        if high == c.red { hue = (c.green - c.blue) / (high - low) } else if high == c.green {
            hue = 2 + (c.blue - c.red) / (high - low)
        } else { hue = 4 + (c.red - c.green) / (high - low) }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        return hue < 0 ? hue + 360 : hue
    }

    /// Two colours of the same hue family, within 20°.
    private static func sameHue(_ a: RGB, _ b: RGB) -> Bool {
        let d = abs(hue(a) - hue(b))
        return min(d, 360 - d) <= 20
    }

    /// The candidate Space puts in sits on a pill whose text reads at 4.5:1 on it over the backdrop, with an aurora edge.
    /// On the dark keyboard it is a soft aurora tint, visibly green, not grey. Round 6 council (Opus finding 3): on the light
    /// keyboard the mint pill with its green edge, beside the mint Start with its green edge, read as a second main button.
    /// There it is the keys' white fill with a thin deep-aurora edge: a choice, untinted, nothing like Start's fill.
    private static func testHighlightedCandidateStaysLegible() {
        variants { palette, name in
            TestSupport.expect(palette.pillAlpha > 0 && palette.pillAlpha <= 1, "pill alpha \(palette.pillAlpha)")
            let pill = BrandPalette.blend(palette.pill, alpha: palette.pillAlpha, over: palette.backdrop)
            let value = ratio(palette.text, pill)
            TestSupport.expect(value >= 4.5, "candidate on the pill, \(name): \(value)")
            TestSupport.expect(palette.pillEdgeAlpha > 0 && palette.pillEdgeAlpha < 1, "pill edge alpha, \(name)")
            TestSupport.expectEqual(palette.pillEdge, palette.aurora)
        }
        for high in [false, true] {
            let dark = BrandPalette(dark: true, highContrast: high), light = BrandPalette(dark: false, highContrast: high)
            // Dark: as before, a fifth of aurora with its edge.
            TestSupport.expectEqual(dark.pill, BrandPalette.aurora)
            TestSupport.expectEqual(dark.pillAlpha, 0.2)
            let tinted = BrandPalette.blend(dark.pill, alpha: dark.pillAlpha, over: dark.backdrop)
            TestSupport.expect(tinted.green > tinted.red + 0.04, "dark pill is not tinted green: \(tinted)")
            // Light: the key fill, opaque, so no hint of Start's mint; set off the backdrop as a key is, and by its edge.
            TestSupport.expectEqual(light.pill, light.keyFill)
            TestSupport.expectEqual(light.pillAlpha, 1)
            TestSupport.expect(hue(light.pill) == -1, "light pill is tinted")
            TestSupport.expect(light.pill != light.accent.top && light.pill != light.accent.bottom, "light pill is Start's fill")
            let edge = BrandPalette.blend(light.pillEdge, alpha: light.pillEdgeAlpha, over: light.pill)
            TestSupport.expect(ratio(edge, light.backdrop) >= 1.5, "light pill edge is invisible: \(ratio(edge, light.backdrop))")
        }
        // `blend`: alpha 0 is the backdrop, 1 the colour.
        let a = RGB(1, 0, 0), b = RGB(0, 0, 1)
        TestSupport.expectEqual(BrandPalette.blend(a, alpha: 0, over: b), b)
        TestSupport.expectEqual(BrandPalette.blend(a, alpha: 1, over: b), a)
        TestSupport.expectEqual(BrandPalette.blend(a, alpha: 0.5, over: b), RGB(0.5, 0, 0.5))
    }

    /// Round 6 council (Opus finding 4): the light keyboard's idle line ("Session ends after 5 min idle") measured about
    /// 3.1:1 (#7E7F85 on #E1E3E7): the system's secondary text is too faint on the light backdrop. There the status line
    /// takes `statusInk`, the menu's secondary ink, which reads at 4.5:1 or better on the palette's backdrop and on the one
    /// measured in round 5, deeper with Increase Contrast. It stays a grey well below the candidates' black, so it reads as
    /// information, not a word to tap (a tap there types the nearest top-row key). The dark keyboard keeps the system's
    /// secondary text (about 6:1).
    private static func testStatusLineReadsAtAAOnTheBackdrop() {
        let measured = RGB(225 / 255, 227 / 255, 231 / 255)
        for high in [false, true] {
            let light = BrandPalette(dark: false, highContrast: high)
            guard let ink = light.statusInk else {
                TestSupport.expect(false, "no light status ink")
                continue
            }
            for backdrop in [light.backdrop, measured] {
                let value = ratio(ink, backdrop)
                TestSupport.expect(value >= 4.5, "status line on \(backdrop), high \(high): \(value)")
            }
            TestSupport.expect(hue(ink) == -1 || abs(ink.red - ink.blue) < 0.03, "status ink is not a grey: \(ink)")
            TestSupport.expect(ratio(ink, light.backdrop) < ratio(light.text, light.backdrop) / 2, "status ink is as dark as text")
            TestSupport.expectEqual(ink, MenuPalette(dark: false, highContrast: high).secondary)
            TestSupport.expectEqual(BrandPalette(dark: true, highContrast: high).statusInk, nil)
        }
        let normal = BrandPalette(dark: false, highContrast: false).statusInk!, high = BrandPalette(dark: false, highContrast: true).statusInk!
        TestSupport.expect(ratio(high, measured) > ratio(normal, measured), "Increase Contrast does not deepen the status line")
    }

    /// Glacier at the tail, aurora at the finger, in between by the point's position along the trail; at the finger the
    /// trail reaches 3:1 against the backdrop.
    private static func testSwipeTrailRunsFromGlacierToAurora() {
        variants { palette, name in
            TestSupport.expectEqual(palette.trailColor(at: 0), palette.glacier)
            TestSupport.expectEqual(palette.trailColor(at: 1), palette.aurora)
            TestSupport.expectEqual(palette.trailColor(at: -1), palette.glacier)
            TestSupport.expectEqual(palette.trailColor(at: 2), palette.aurora)
            let middle = palette.trailColor(at: 0.5)
            TestSupport.expect(abs(middle.green - (palette.glacier.green + palette.aurora.green) / 2) < 1e-9, "trail midpoint")
            let finger = BrandPalette.blend(palette.aurora, alpha: palette.trailAlpha, over: palette.backdrop)
            let value = ratio(finger, palette.backdrop)
            TestSupport.expect(value >= 3, "trail at the finger, \(name): \(value)")
        }
        // The pure trail carries each point's place along it, for the colour: 0 at the tail, 1 at the finger.
        let samples = [0.0, 0.125, 0.25].enumerated().map { SwipeSample(x: Double($0.offset) * 10, y: 50, t: $0.element) }
        let trail = SwipeTrail.points(from: samples, window: 0.25)
        TestSupport.expectEqual(trail.map(\.fraction), [0, 0.5, 1])
    }

    /// "Open LocalFlow" is the brand's accent, and still reads at 4.5:1 on the card.
    private static func testMenuLinkIsTheBrandAccent() {
        variants { palette, name in
            let dark = name.hasPrefix("dark"), high = name.hasSuffix("high")
            let menu = MenuPalette(dark: dark, highContrast: high)
            TestSupport.expectEqual(menu.link, palette.link)
            let value = ratio(menu.link, menu.card)
            TestSupport.expect(value >= 4.5, "link on the card, \(name): \(value)")
            TestSupport.expect(sameHue(menu.link, BrandPalette.aurora), "link is not aurora's hue, \(name)")
        }
    }

    // MARK: Ridge mark

    /// The icon's mark (AppIcon.svg, the site's 32-unit favicon): a W-shaped ridge of five strokes, alternately down and
    /// up, and a dot centred below its lowest point.
    private static func testRidgeMarkIsTheIconsLineAndDot() {
        let line = RidgeMark.line
        TestSupport.expectEqual(line.count, 6)
        TestSupport.expectEqual(line.first, RidgeMark.Point(x: 5.4, y: 6.1))
        TestSupport.expectEqual(line.last, RidgeMark.Point(x: 26.6, y: 15.9))
        for index in line.indices.dropLast() {
            TestSupport.expect(line[index + 1].x > line[index].x, "the ridge runs left to right")
            let down = line[index + 1].y > line[index].y
            TestSupport.expect(down == (index % 2 == 0), "stroke \(index) is not alternately down and up")
        }
        TestSupport.expectEqual(RidgeMark.dot, RidgeMark.Point(x: 16, y: 26))
        TestSupport.expect(RidgeMark.dot.y - RidgeMark.dotRadius > line.map(\.y).max()! + RidgeMark.lineWidth / 2,
                           "the dot is below the ridge")
    }

    /// Fitted into a box, the mark keeps its shape (one scale), all its ink inside the box, centred, at any weight.
    private static func testRidgeMarkFitsItsBoxCentred() {
        for (box, weight) in [(KeyRect(x: 0, y: 0, width: 16, height: 16), 1.0), (KeyRect(x: 10, y: 4, width: 30, height: 20), 1),
                              (KeyRect(x: -3, y: 2, width: 12, height: 40), 1), (KeyRect(x: 0, y: 0, width: 19, height: 19), 1.3)] {
            let mark = RidgeMark.fitted(in: box, weight: weight)
            let half = mark.lineWidth / 2
            let xs = mark.line.map(\.x) + [mark.dot.x - mark.dotRadius, mark.dot.x + mark.dotRadius]
            let ys = mark.line.map(\.y) + [mark.dot.y - mark.dotRadius, mark.dot.y + mark.dotRadius]
            let minX = min(xs.min()!, mark.line.map(\.x).min()! - half), maxX = max(xs.max()!, mark.line.map(\.x).max()! + half)
            let minY = min(ys.min()!, mark.line.map(\.y).min()! - half), maxY = max(ys.max()!, mark.line.map(\.y).max()! + half)
            let tolerance = 1e-9
            TestSupport.expect(minX >= box.x - tolerance && maxX <= box.maxX + tolerance, "x outside \(box): \(minX)...\(maxX)")
            TestSupport.expect(minY >= box.y - tolerance && maxY <= box.maxY + tolerance, "y outside \(box): \(minY)...\(maxY)")
            TestSupport.expect(abs((minX + maxX) / 2 - box.midX) < 1e-6 && abs((minY + maxY) / 2 - box.midY) < 1e-6, "not centred in \(box)")
            // It fills the box's shorter side.
            TestSupport.expect(abs(maxX - minX - box.width) < 1e-6 || abs(maxY - minY - box.height) < 1e-6, "does not fill \(box)")
            // One scale: the first stroke keeps its direction and the dot its size relative to the line.
            let scale = mark.lineWidth / (RidgeMark.lineWidth * weight)
            TestSupport.expect(abs(mark.dotRadius - RidgeMark.dotRadius * weight * scale) < 1e-9, "dot scaled apart from the line")
            let dx = mark.line[1].x - mark.line[0].x, dy = mark.line[1].y - mark.line[0].y
            TestSupport.expect(abs(dx - (RidgeMark.line[1].x - RidgeMark.line[0].x) * scale) < 1e-9
                && abs(dy - (RidgeMark.line[1].y - RidgeMark.line[0].y) * scale) < 1e-9, "the mark is distorted")
        }
    }

    // MARK: Recording wave

    /// One corner per level, the newest at the right edge, each at least the quiet height from the middle line and at
    /// most the box's half height, louder levels further out; silence draws a gentle ridge, not a flat line.
    private static func testWaveFollowsTheLevelsNewestAtTheRight() {
        let width = 160.0, height = 30.0
        let wave = RidgeWave.corners(levels: [0, 0.5, 1], serial: 3, width: width, height: height, progress: 1)
        let mid = height / 2
        TestSupport.expectEqual(wave.last?.x, width - RidgeWave.inset(height: height))
        let offsets = wave.suffix(3).map { abs($0.y - mid) }
        TestSupport.expect(offsets[0] < offsets[1] && offsets[1] < offsets[2], "louder is not taller: \(offsets)")
        TestSupport.expect(abs(offsets[0] - RidgeWave.quietAmplitude(height: height)) < 1e-9, "silence \(offsets[0])")
        TestSupport.expect(RidgeWave.quietAmplitude(height: height) > 0, "silence is a flat line")
        // Older than the levels heard: quiet corners, out to the left edge.
        TestSupport.expect(wave.first!.x <= RidgeWave.inset(height: height) + 1e-9, "the wave does not reach the left: \(wave.first!)")
        for corner in wave.dropLast(3) {
            TestSupport.expect(abs(abs(corner.y - mid) - RidgeWave.quietAmplitude(height: height)) < 1e-9, "padding is not quiet")
        }
        // Corners are evenly spaced.
        let steps = zip(wave, wave.dropFirst()).map { $1.x - $0.x }
        TestSupport.expect(steps.allSatisfy { abs($0 - RidgeWave.step) < 1e-9 }, "uneven steps \(steps)")
        TestSupport.expect(RidgeWave.corners(levels: [], serial: 0, width: 0, height: height, progress: 1).isEmpty, "no width")
    }

    /// Between two levels the corners slide left by `progress` of a step, and every level stays on its side of the
    /// middle line as it travels (the side follows the level's serial number, not its place).
    private static func testWaveFlowsLeftAndKeepsEachLevelsSide() {
        let width = 120.0, height = 30.0, mid = height / 2
        let before = RidgeWave.corners(levels: [0.2, 0.9], serial: 2, width: width, height: height, progress: 1)
        let after = RidgeWave.corners(levels: [0.2, 0.9, 0.4], serial: 3, width: width, height: height, progress: 1)
        func side(_ y: Double) -> Bool { y < mid }
        // The 0.9 level was the newest corner; after the next level it is one step to the left, on the same side.
        let loud = before[before.count - 1], moved = after[after.count - 2]
        TestSupport.expect(abs(moved.x - (loud.x - RidgeWave.step)) < 1e-9, "the level did not move one step left")
        TestSupport.expectEqual(side(moved.y), side(loud.y))
        TestSupport.expect(side(after[after.count - 1].y) != side(moved.y), "neighbours are on the same side")
        // Just after a level arrives (progress 0) the wave sits one step to the right, at progress 1 in place.
        let start = RidgeWave.corners(levels: [0.2, 0.9, 0.4], serial: 3, width: width, height: height, progress: 0)
        let half = RidgeWave.corners(levels: [0.2, 0.9, 0.4], serial: 3, width: width, height: height, progress: 0.5)
        TestSupport.expect(abs(start.last!.x - (after.last!.x + RidgeWave.step)) < 1e-9, "start \(start.last!)")
        TestSupport.expect(abs(half.last!.x - (after.last!.x + RidgeWave.step / 2)) < 1e-9, "half \(half.last!)")
        // The same corners on the same sides; sliding right leaves room for one more quiet corner at the left.
        TestSupport.expectEqual(Array(start.map(\.y).suffix(after.count)), after.map(\.y))
        TestSupport.expect(start.count <= after.count + 1, "start \(start.count) corners")
    }

    /// Every corner stays inside the box with the stroke's room, at any progress; only the arriving corner may sit past
    /// the right edge for the fraction of a step it has yet to travel, and the view fades that edge.
    private static func testWaveStaysInsideItsBox() {
        let width = 90.0, height = 24.0
        let levels: [Float] = (0 ..< 40).map { Float($0 % 5) / 4 }
        for progress in [0.0, 0.3, 1.0] {
            let wave = RidgeWave.corners(levels: levels + [2, -1, .nan], serial: 43, width: width, height: height, progress: progress)
            for corner in wave {
                TestSupport.expect(corner.y >= RidgeWave.inset(height: height) - 1e-9
                    && corner.y <= height - RidgeWave.inset(height: height) + 1e-9, "y outside: \(corner)")
                TestSupport.expect(corner.x <= width - RidgeWave.inset(height: height) + (1 - progress) * RidgeWave.step + 1e-9,
                                   "x past the right edge: \(corner)")
            }
            TestSupport.expect(wave.first!.x <= RidgeWave.inset(height: height) + 1e-9, "the wave does not reach the left")
            TestSupport.expect(wave.first!.x > RidgeWave.inset(height: height) - RidgeWave.step - 1e-9, "more corners than needed")
        }
    }

    // MARK: Dictation states

    /// Start is aurora; starting and recording show coral Stop; the wait for a transcript glacier; a state where
    /// dictation cannot run here the dimmed Start.
    private static func testCapsuleStyleFollowsTheMode() {
        let cases: [(KeyboardMode, CapsuleStyle)] = [
            (.ready, .start), (.hostUnavailable, .start), (.preparingModel, .start), (.error(.transcriptionFailed), .start),
            (.starting, .stop), (.recording(level: 0.3, startedAt: Date()), .stop),
            (.transcribing, .working), (.waitingForModel, .working),
            (.needsFullAccess, .unavailable), (.configurationError, .unavailable), (.incompatible, .unavailable),
        ]
        for (mode, style) in cases {
            TestSupport.expectEqual(CapsuleStyle(mode: mode), style)
        }
    }

    /// Recording shows the live wave instead of "Listening", with a caption only while the model still loads; a notice
    /// always shows; otherwise the one-line status, and nothing beside a chip.
    private static func testBarStatusShowsTheWaveWhileRecording() {
        let recording = KeyboardMode.recording(level: 0.5, startedAt: Date())
        func status(_ mode: KeyboardMode, title: String = "", hint: String? = nil, notice: String? = nil, chips: Bool = false) -> BarStatus {
            BarStatus(mode: mode, title: title, hint: hint, notice: notice, chipsShown: chips)
        }
        TestSupport.expectEqual(status(recording, title: "Listening"), .wave(caption: nil))
        TestSupport.expectEqual(status(recording, title: KeyboardMessages.listeningWhilePreparing),
                                .wave(caption: KeyboardMessages.modelLoadingCaption))
        TestSupport.expectEqual(status(recording, title: "Listening", notice: "Couldn't reach LocalFlow"), .notice("Couldn't reach LocalFlow"))
        TestSupport.expectEqual(status(recording, title: "Listening", chips: true), .wave(caption: nil))
        TestSupport.expectEqual(status(.starting, title: "Starting…"), .text("Starting…", attention: false))
        TestSupport.expectEqual(status(.transcribing, title: "Transcribing…"), .text("Transcribing…", attention: false))
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: "Session on"), .text("Session on", attention: false))
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate"), .none)
        TestSupport.expectEqual(status(.error(.modelFailed), title: "The speech model failed to load"),
                                .text("The speech model failed to load", attention: true))
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: "Session on", chips: true), .none)
        TestSupport.expectEqual(status(.ready, title: "", notice: "No speech detected", chips: true), .notice("No speech detected"))
        // The caption is short enough for the SE beside Cancel and Stop.
        TestSupport.expect(KeyboardMessages.modelLoadingCaption.count <= 14, KeyboardMessages.modelLoadingCaption)
    }

    /// Round 4 council (Opus finding 3): on Stop the wide "Stop 0:03" capsule became a narrow spinner and Cancel slid
    /// about 22 points. From starting until the transcript arrives the capsule keeps the recording Stop's width; only
    /// Start (idle, errors, and where dictation cannot run) takes its own.
    private static func testCapsuleHoldsItsWidthUntilTheTranscript() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let cases: [(KeyboardMode, CapsuleContent)] = [
            (.starting, .starting), (.recording(level: 0.4, startedAt: startedAt), .stop(startedAt: startedAt)),
            (.transcribing, .spinner), (.waitingForModel, .spinner),
            (.ready, .start), (.preparingModel, .start), (.hostUnavailable, .start), (.error(.transcriptionFailed), .start),
            (.needsFullAccess, .start), (.configurationError, .start), (.incompatible, .start),
        ]
        for (mode, content) in cases {
            TestSupport.expectEqual(CapsuleContent(mode: mode), content)
            TestSupport.expectEqual(CapsuleContent(mode: mode).keepsStopWidth, content != .start)
        }
    }

    /// Round 4 council (Opus, visual 4): idle with a ready session, the status line is led by a glacier dot (the mark's
    /// dot). It shows only on the idle line, never on an error, a notice or another mode's line, and is information,
    /// not a control (a tap there still types the key under it).
    private static func testIdleLineShowsReadinessWithADot() {
        func status(_ mode: KeyboardMode, title: String = "", hint: String? = nil, notice: String? = nil, chips: Bool = false,
                    ready: Bool) -> BarStatus {
            BarStatus(mode: mode, title: title, hint: hint, notice: notice, chipsShown: chips, sessionReady: ready)
        }
        let line = "Session ends after 5 min idle"
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: line, ready: true), .text(line, attention: false, ready: true))
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: line, ready: false), .text(line, attention: false, ready: false))
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: line, chips: true, ready: true), .none)
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: line, notice: "No speech detected", ready: true),
                                .notice("No speech detected"))
        TestSupport.expectEqual(status(.preparingModel, title: KeyboardMessages.preparingModel, ready: true),
                                .text(KeyboardMessages.preparingModel, attention: false, ready: false))
        TestSupport.expectEqual(status(.hostUnavailable, title: "Start opens LocalFlow", ready: true),
                                .text("Start opens LocalFlow", attention: false, ready: false))
        TestSupport.expectEqual(status(.error(.modelFailed), title: "The speech model failed to load", ready: true),
                                .text("The speech model failed to load", attention: true, ready: false))
    }

    /// Sol, round 4: on a 375-point phone "Model loading" left the wave about 55 points. Where the full caption would
    /// leave the wave less than `captionedWaveWidth`, the caption is the short one, which still names the wait.
    private static func testLoadingCaptionHasAShortForm() {
        let short = KeyboardMessages.modelLoadingShortCaption, full = KeyboardMessages.modelLoadingCaption
        TestSupport.expect(short.count < full.count, "\(short) is not shorter than \(full)")
        TestSupport.expect(full.lowercased().contains(short.lowercased()), "\(short) says something else than \(full)")
        TestSupport.expect(BarStatus.captionedWaveWidth >= 2 * RidgeWave.step * 3, "the wave keeps too few corners")
    }
}
