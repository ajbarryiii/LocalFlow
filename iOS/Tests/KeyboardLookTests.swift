import Foundation

/// ARCHITECTURE.md, "Keyboard look": the brand palette's contrast in both modes and with Increase Contrast, the ridge
/// mark's geometry, the recording wave, and which dictation state shows which colour and text.
enum KeyboardLookTests {
    static var tests: [TestCase] {
        [
            ("textOnEveryFillReadsAtAA", testTextOnEveryFillReadsAtAA),
            ("fillsStandOffTheBackdropOrHaveAnEdge", testFillsStandOffTheBackdropOrHaveAnEdge),
            ("brandColoursAreAccentsOnly", testBrandColoursAreAccentsOnly),
            ("theIslandIsDarkInBothModes", testTheIslandIsDarkInBothModes),
            ("accentsReachThreeToOne", testAccentsReachThreeToOne),
            ("lightModeUsesDeeperHues", testLightModeUsesDeeperHues),
            ("highlightedCandidateStaysLegible", testHighlightedCandidateStaysLegible),
            ("swipeTrailIsQuietAndNeutral", testSwipeTrailIsQuietAndNeutral),
            ("menuLinkIsTheBrandAccent", testMenuLinkIsTheBrandAccent),
            ("ridgeMarkIsTheIconsLineAndDot", testRidgeMarkIsTheIconsLineAndDot),
            ("ridgeMarkFitsItsBoxCentred", testRidgeMarkFitsItsBoxCentred),
            ("capsuleStyleFollowsTheMode", testCapsuleStyleFollowsTheMode),
            ("barStatusShowsTheWaveWhileRecording", testBarStatusShowsTheWaveWhileRecording),
            ("islandTakesItsFormFromTheMode", testIslandTakesItsFormFromTheMode),
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
        [("accent", palette.accent), ("island", palette.island)]
    }

    // MARK: Palette

    /// The caption on the action keys and caps lock (the accent fill), and the island's text (Start, Stop's time, the
    /// status inside it).
    private static func testTextOnEveryFillReadsAtAA() {
        variants { palette, name in
            for (role, fill) in fills(palette) {
                let value = ratio(fill.ink, fill.color)
                TestSupport.expect(value >= 4.5, "\(role) ink, \(name): \(value)")
            }
        }
    }

    /// A filled control reaches 3:1 against the keyboard's backdrop, or has an edge that does. Edges are hairlines (a
    /// full point with Increase Contrast): round 4 council (Opus, visual 5), a 1-point edge read as a sticker outline.
    private static func testFillsStandOffTheBackdropOrHaveAnEdge() {
        variants { palette, name in
            for (role, fill) in fills(palette) {
                let fillRatio = ratio(fill.color, palette.backdrop)
                let edgeRatio = fill.edge.map { ratio($0, palette.backdrop) } ?? 0
                TestSupport.expect(fillRatio >= 3 || edgeRatio >= 3, "\(role), \(name): fill \(fillRatio), edge \(edgeRatio)")
            }
            TestSupport.expect(palette.edgeWidth > 0 && palette.edgeWidth <= 1, "edge width \(palette.edgeWidth), \(name)")
        }
        for dark in [false, true] {
            TestSupport.expect(BrandPalette(dark: dark, highContrast: false).edgeWidth < 1, "edge is not a hairline")
            TestSupport.expectEqual(BrandPalette(dark: dark, highContrast: true).edgeWidth, 1)
        }
    }

    /// Round 8 (owner, on a phone): the aurora buttons were very bright and jarring; the brand colours are for accents.
    /// No control is filled with a brand hue: the accent keys and the island are greys with grey ink, in both modes and
    /// with Increase Contrast, as are the highlighted candidate's pill and the swipe trace.
    private static func testBrandColoursAreAccentsOnly() {
        variants { palette, name in
            for (role, fill) in fills(palette) {
                for (part, color) in [("fill", fill.color), ("ink", fill.ink)] + (fill.edge.map { [("edge", $0)] } ?? []) {
                    TestSupport.expect(isGrey(color), "\(role) \(part) is tinted, \(name): \(color)")
                }
            }
            TestSupport.expect(isGrey(palette.pill) && isGrey(palette.pillEdge), "the candidate pill is tinted, \(name)")
            TestSupport.expect(isGrey(palette.trail), "the swipe trace is tinted, \(name)")
            // The accent keys read as the primary action: their fill is the label colour's side, far off the keys'.
            TestSupport.expect(ratio(palette.accent.color, palette.keyFill) >= 3, "the accent key is not set off the keys, \(name)")
        }
    }

    /// The island (Start, the recording, the wait for the transcript) is a dark pill in both modes, in the spirit of the
    /// Dynamic Island, with white text: near-black on the dark keyboard, darker than the backdrop with a hairline edge to
    /// set it off; graphite on the light keyboard, where black across the bar was the heaviest thing on the keyboard.
    private static func testTheIslandIsDarkInBothModes() {
        variants { palette, name in
            TestSupport.expect(palette.island.color.luminance < 0.03, "island fill is not dark, \(name)")
            TestSupport.expect(palette.island.ink.luminance > 0.9, "island ink is not white, \(name)")
        }
        for high in [false, true] {
            let dark = BrandPalette(dark: true, highContrast: high), light = BrandPalette(dark: false, highContrast: high)
            TestSupport.expect(dark.island.color.luminance < dark.backdrop.luminance, "the dark island is not below the backdrop")
            TestSupport.expect(light.island.color.luminance > dark.island.color.luminance, "the light island is not softer")
        }
    }

    /// Accents on the backdrop (the readiness dot, an error's symbol, the menu's link) and on the island (the live dot
    /// the wave settles into, the wait's cool shimmer) reach 3:1, as do the island's lit dots. Round 9 (owner): the dim dot
    /// field is gone, so the resting row is the line itself, a calm 3:1 or better, and the swell still brightens past it.
    /// (Round 8 kept resting dots under 3:1, a texture behind the strands.)
    private static func testAccentsReachThreeToOne() {
        variants { palette, name in
            for (role, color) in [("aurora", palette.aurora), ("ember", palette.ember)] {
                let value = ratio(color, palette.backdrop)
                TestSupport.expect(value >= 3, "\(role) on the backdrop, \(name): \(value)")
            }
            let island = palette.island.color
            for (role, color) in [("live", palette.live), ("shimmer", palette.shimmer), ("lit dot", palette.island.ink)] {
                let value = ratio(color, island)
                TestSupport.expect(value >= 3, "\(role) on the island, \(name): \(value)")
            }
            let rest = BrandPalette.blend(palette.island.ink, alpha: DotWave.restBrightness, over: island)
            TestSupport.expect(ratio(rest, island) >= 3, "the resting row is faint, \(name): \(ratio(rest, island))")
            TestSupport.expect(ratio(palette.island.ink, island) > ratio(rest, island) * 1.5, "the swell does not brighten, \(name)")
        }
    }

    /// The light keyboard's strokes are darker than the dark keyboard's, in the same hues: the bright brand colours are
    /// too pale on a light backdrop. The dark keyboard uses the app's colours as they are. On the island, which is dark
    /// in both modes, the live dot is the app's aurora and the shimmer a cool glacier white.
    private static func testLightModeUsesDeeperHues() {
        let dark = BrandPalette(dark: true, highContrast: false), light = BrandPalette(dark: false, highContrast: false)
        TestSupport.expectEqual(dark.aurora, BrandPalette.aurora)
        TestSupport.expectEqual(dark.ember, BrandPalette.ember)
        for (role, deep, bright) in [("aurora", light.aurora, BrandPalette.aurora), ("ember", light.ember, BrandPalette.ember)] {
            TestSupport.expect(deep.luminance < bright.luminance / 2, "\(role) is not deeper in light mode")
            TestSupport.expect(sameHue(deep, bright), "\(role) changes hue in light mode: \(hue(deep)) vs \(hue(bright))")
        }
        variants { palette, name in
            TestSupport.expectEqual(palette.live, BrandPalette.aurora)
            TestSupport.expect(sameHue(palette.shimmer, BrandPalette.glacier), "shimmer is not glacier's hue, \(name)")
            TestSupport.expect(palette.shimmer.luminance > BrandPalette.glacier.luminance, "shimmer is not paler than glacier, \(name)")
        }
        // Increase Contrast never lowers a stroke's contrast.
        for darkMode in [false, true] {
            let normal = BrandPalette(dark: darkMode, highContrast: false), high = BrandPalette(dark: darkMode, highContrast: true)
            for (a, b) in [(normal.aurora, high.aurora), (normal.ember, high.ember)] {
                TestSupport.expect(ratio(b, high.backdrop) >= ratio(a, normal.backdrop) - 1e-9, "Increase Contrast lowered a stroke")
            }
            if let a = normal.island.edge, let b = high.island.edge {
                TestSupport.expect(ratio(b, high.backdrop) >= ratio(a, normal.backdrop), "Increase Contrast lowered the island's edge")
            }
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

    /// A neutral: no channel more than 2% from the others (Apple's greys lean a touch blue).
    private static func isGrey(_ c: RGB) -> Bool {
        max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue) <= 0.02
    }

    /// The candidate Space puts in sits on a pill whose text reads at 4.5:1 on it over the backdrop, with a visible
    /// edge. Round 8 (owner): no aurora tint or edge; the pill is neutral in both modes, a soft white veil on the dark
    /// keyboard and the keys' white on the light one, and never the accent keys' or the island's fill.
    private static func testHighlightedCandidateStaysLegible() {
        variants { palette, name in
            TestSupport.expect(palette.pillAlpha > 0 && palette.pillAlpha <= 1, "pill alpha \(palette.pillAlpha)")
            let pill = BrandPalette.blend(palette.pill, alpha: palette.pillAlpha, over: palette.backdrop)
            let value = ratio(palette.text, pill)
            TestSupport.expect(value >= 4.5, "candidate on the pill, \(name): \(value)")
            TestSupport.expect(palette.pillEdgeAlpha > 0 && palette.pillEdgeAlpha < 1, "pill edge alpha, \(name)")
            let edge = BrandPalette.blend(palette.pillEdge, alpha: palette.pillEdgeAlpha, over: pill)
            TestSupport.expect(ratio(edge, palette.backdrop) >= 1.5, "pill edge is invisible, \(name): \(ratio(edge, palette.backdrop))")
            TestSupport.expect(ratio(pill, palette.accent.color) > 1.5 && ratio(pill, palette.island.color) > 1.5,
                               "the pill looks like a primary control, \(name)")
        }
        for high in [false, true] {
            let light = BrandPalette(dark: false, highContrast: high)
            TestSupport.expectEqual(light.pill, light.keyFill)
            TestSupport.expectEqual(light.pillAlpha, 1)
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

    /// Round 8 (owner): quieter. The trace is the label colour's grey, fading towards its tail; at the finger it reaches
    /// 3:1 against the backdrop.
    /// Round 9 (Opus, round 8: a light grey trace on the grey keys was almost invisible mid-swipe): at the finger the trace
    /// stands 3:1 off the keys it crosses as well as off the backdrop, in both modes and with Increase Contrast; it stays
    /// neutral (a grey) and a little translucent, so it is quiet.
    private static func testSwipeTrailIsQuietAndNeutral() {
        variants { palette, name in
            TestSupport.expect(palette.trail.red == palette.trail.green && palette.trail.green == palette.trail.blue,
                               "the trail is not grey, \(name)")
            TestSupport.expect(palette.trailAlpha < 1, "the trail is opaque, \(name)")
            for (surface, label) in [(palette.backdrop, "backdrop"), (palette.keyFill, "keys")] {
                let finger = BrandPalette.blend(palette.trail, alpha: palette.trailAlpha, over: surface)
                let value = ratio(finger, surface)
                TestSupport.expect(value >= 3, "trail at the finger on the \(label), \(name): \(value)")
            }
        }
        // The pure trail carries each point's place along it: 0 at the tail, 1 at the finger.
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
            // Round 9 (Opus, round 8): the menu's mark is ink with the aurora dot, like every other mark, not all aurora.
            TestSupport.expectEqual(menu.markLine, menu.primary)
            TestSupport.expectEqual(menu.markDot, menu.link)
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

    // MARK: Dictation states

    /// The island's state for a mode: Start while idle (and after errors); starting and recording are Stop; the wait for
    /// a transcript is the working island; a state where dictation cannot run here the dimmed Start.
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
        // Round 9 (Opus, round 8: Cancel arrived over the outgoing line): while starting, the island's dimmed row says it
        // is starting, and the middle, now beside it, stays empty rather than flash "Starting…" for a moment; only a
        // line that says more shows.
        TestSupport.expectEqual(status(.starting, title: "Starting…"), .none)
        TestSupport.expectEqual(status(.starting, title: KeyboardMessages.openLocalFlow), .text(KeyboardMessages.openLocalFlow, attention: false))
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

    /// Round 8 (owner): the island. Start is the compact island, holding the mark and "Start"; starting and recording
    /// grow it across the bar into Stop (the whole island stops), holding the wave and the time; the wait for the
    /// transcript contracts it into the short processing island with only its shimmer (the middle names the wait).
    /// This replaces round 4's rule that the capsule keeps the recording Stop's width so Cancel never moves: Cancel now
    /// sits at the bar's left beside the menu, where no change of the island's width can move it (`IslandLayout`).
    private static func testIslandTakesItsFormFromTheMode() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let cases: [(KeyboardMode, CapsuleContent, IslandForm)] = [
            (.starting, .starting, .expanded), (.recording(level: 0.4, startedAt: startedAt), .stop(startedAt: startedAt), .expanded),
            (.transcribing, .processing, .processing), (.waitingForModel, .processing, .processing),
            (.ready, .start, .compact), (.preparingModel, .start, .compact), (.hostUnavailable, .start, .compact),
            (.error(.transcriptionFailed), .start, .compact),
            (.needsFullAccess, .start, .compact), (.configurationError, .start, .compact), (.incompatible, .start, .compact),
        ]
        for (mode, content, form) in cases {
            TestSupport.expectEqual(CapsuleContent(mode: mode), content)
            TestSupport.expectEqual(IslandForm(CapsuleStyle(mode: mode)), form)
        }
    }

    /// Round 4 council (Opus, visual 4): idle with a ready session, the status line is led by a dot (the mark's dot,
    /// aurora since round 8, when the glacier went to the wait's shimmer alone). It shows only on the idle line, never on an error, a notice or another mode's line, and is information,
    /// not a control (a tap there still types the key under it).
    private static func testIdleLineShowsReadinessWithADot() {
        func status(_ mode: KeyboardMode, title: String = "", hint: String? = nil, notice: String? = nil, chips: Bool = false,
                    ready: Bool) -> BarStatus {
            BarStatus(mode: mode, title: title, hint: hint, notice: notice, chipsShown: chips, sessionReady: ready)
        }
        let line = "Session ends in 5 min if idle"
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

    /// Sol, round 4: on a 375-point phone "Model loading" left the wave about 55 points. Round 9: the caption is the
    /// middle's, beside Cancel; where the full caption does not fit there (the largest bar text), it is the short one,
    /// which still names the wait. (Round 8's `captionedWaveWidth`, the wave's room beside the caption inside the island,
    /// went with the caption's move.)
    private static func testLoadingCaptionHasAShortForm() {
        let short = KeyboardMessages.modelLoadingShortCaption, full = KeyboardMessages.modelLoadingCaption
        TestSupport.expect(short.count < full.count, "\(short) is not shorter than \(full)")
        TestSupport.expect(full.lowercased().contains(short.lowercased()), "\(short) says something else than \(full)")
        TestSupport.expectEqual(KeyboardMessages.shortForm(of: full), short)
        // Round 9: the wait's words sit between Cancel and the short pill; "Preparing model…" has a short form there too.
        let preparing = KeyboardMessages.preparingModel
        TestSupport.expectEqual(KeyboardMessages.shortForm(of: preparing), KeyboardMessages.preparingShort)
        TestSupport.expect(preparing.hasPrefix(KeyboardMessages.preparingShort.dropLast()), "the short form says something else")
        TestSupport.expect(KeyboardMessages.preparingShort.count < preparing.count, "the short form is not shorter")
        TestSupport.expectEqual(KeyboardMessages.shortForm(of: "Transcribing…"), nil)
    }
}
