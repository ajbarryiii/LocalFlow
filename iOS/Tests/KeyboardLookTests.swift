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
            ("barStatusKeepsWordsWhereTheyEarnTheirSpace", testBarStatusKeepsWordsWhereTheyEarnTheirSpace),
            ("islandTakesItsFormFromTheMode", testIslandTakesItsFormFromTheMode),
            ("theSessionShowsInTheDotsMotion", testTheSessionShowsInTheDotsMotion),
            ("menusDotMatchesStartsDot", testMenusDotMatchesStartsDot),
            ("statusLineReadsAtAAOnTheBackdrop", testStatusLineReadsAtAAOnTheBackdrop),
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

    /// Round 10 (owner: "prefer intuitive icons to textual descriptions ... balance between these two poles"): the middle
    /// keeps words only where they earn their space: what the user must act on (Full Access, the microphone, a broken
    /// install or versions, "Open LocalFlow to start a session" after the launcher failed), an error that says why a
    /// dictation was lost, a model that cannot load, and a notice. Everything the island's own motion says, or Start's
    /// dot, goes: the cold start's "Model loading" (round 9 showed it while recording), "Transcribing…" and "Preparing
    /// model…" in the wait, "Preparing model…" idle, the session line and "Session on", "Model loads when you dictate", and
    /// "Start opens LocalFlow". Nothing shows beside a chip but a notice.
    private static func testBarStatusKeepsWordsWhereTheyEarnTheirSpace() {
        let recording = KeyboardMode.recording(level: 0.5, startedAt: Date())
        func status(_ mode: KeyboardMode, title: String = "", hint: String? = nil, notice: String? = nil, chips: Bool = false) -> BarStatus {
            BarStatus(mode: mode, title: title, hint: hint, notice: notice, chipsShown: chips)
        }
        // Words.
        TestSupport.expectEqual(status(.needsFullAccess, title: "Allow Full Access to dictate"), .text("Allow Full Access to dictate", attention: true))
        TestSupport.expectEqual(status(.configurationError, title: "LocalFlow is not installed correctly"),
                                .text("LocalFlow is not installed correctly", attention: true))
        TestSupport.expectEqual(status(.incompatible, title: "Update LocalFlow"), .text("Update LocalFlow", attention: true))
        TestSupport.expectEqual(status(.error(.microphonePermissionDenied), title: "Allow microphone access in LocalFlow"),
                                .text("Allow microphone access in LocalFlow", attention: true))
        TestSupport.expectEqual(status(.error(.modelFailed), title: "The speech model failed to load"),
                                .text("The speech model failed to load", attention: true))
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: "Model failed to load"), .text("Model failed to load", attention: true))
        TestSupport.expectEqual(status(.hostUnavailable, title: KeyboardMessages.openLocalFlow), .text(KeyboardMessages.openLocalFlow, attention: false))
        TestSupport.expectEqual(status(.starting, title: KeyboardMessages.openLocalFlow), .text(KeyboardMessages.openLocalFlow, attention: false))
        TestSupport.expectEqual(status(recording, title: "Listening", notice: "Couldn't reach LocalFlow"), .notice("Couldn't reach LocalFlow"))
        TestSupport.expectEqual(status(.ready, title: "", notice: "No speech detected", chips: true), .notice("No speech detected"))
        // Nothing: the island's motion or Start's dot says it.
        TestSupport.expectEqual(status(recording, title: "Listening"), .none)
        TestSupport.expectEqual(status(recording, title: KeyboardMessages.listeningWhilePreparing), .none)
        TestSupport.expectEqual(status(.starting, title: "Starting…"), .none)
        TestSupport.expectEqual(status(.transcribing, title: "Transcribing…"), .none)
        TestSupport.expectEqual(status(.waitingForModel, title: KeyboardMessages.preparingModel), .none)
        TestSupport.expectEqual(status(.preparingModel, title: KeyboardMessages.preparingModel), .none)
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate"), .none)
        TestSupport.expectEqual(status(.hostUnavailable, title: "Start opens LocalFlow"), .none)
        TestSupport.expectEqual(status(.ready, title: "Ready to dictate", hint: "Model failed to load", chips: true), .none)
        TestSupport.expectEqual(status(.error(.modelFailed), title: "The speech model failed to load", chips: true), .none)
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

    /// The session cases Start's dot covers, as (mode, a session is ready).
    private static let sessionCases: [(KeyboardMode, Bool)] = [
        (.ready, true), (.ready, false), (.preparingModel, true), (.preparingModel, false), (.hostUnavailable, false),
        (.hostUnavailable, true), (.error(.transcriptionFailed), true), (.error(.sessionInactive), false),
        (.needsFullAccess, false), (.configurationError, false), (.incompatible, false),
    ]

    /// Round 11 (owner, after trying round 10's green and amber dots: amber made the logo look worse, and iOS's own
    /// orange microphone dot means a session is on): the mark's dot is always the brand's aurora, and the session shows in
    /// its motion. A session ready: a heartbeat, a soft ring rippling out from the dot every few seconds. Its model
    /// preparing: round 10's breathing. No session, or dictation cannot run here: the same dot, still. With Reduce
    /// Motion nothing moves, so the dot is lit while a session is on (ready or preparing) and unlit, a neutral grey of the
    /// same size and place, while none is. Colour never carries the state alone, so Differentiate Without Colour needs no
    /// case of its own (this replaces round 10's ember dot and the round 11 ember ring). No state draws the dot in ember.
    private static func testTheSessionShowsInTheDotsMotion() {
        let looks: [(SessionDot, SessionDot.Look, SessionDot.Look)] = [
            (.ready, .heartbeat, .lit), (.preparing, .breathing, .lit), (.off, .lit, .unlit),
        ]
        for (dot, moving, still) in looks {
            TestSupport.expectEqual(dot.look(reduceMotion: false), moving)
            TestSupport.expectEqual(dot.look(reduceMotion: true), still)
        }
        let cases: [(KeyboardMode, Bool, SessionDot)] = [
            (.ready, true, .ready), (.preparingModel, true, .preparing), (.preparingModel, false, .preparing),
            (.ready, false, .off), (.hostUnavailable, false, .off), (.hostUnavailable, true, .off),
            (.error(.transcriptionFailed), true, .ready), (.error(.sessionInactive), false, .off),
            (.needsFullAccess, false, .off), (.configurationError, false, .off), (.incompatible, false, .off),
        ]
        for (mode, ready, dot) in cases {
            TestSupport.expectEqual(SessionDot(mode: mode, sessionReady: ready), dot)
        }
        variants { palette, name in
            for (dot, _, _) in looks {
                for reduceMotion in [false, true] {
                    let color = dot.color(palette, reduceMotion: reduceMotion)
                    TestSupport.expect(!sameHue(color, BrandPalette.ember) || isGrey(color), "\(dot) is ember, \(name)")
                    if dot.look(reduceMotion: reduceMotion) == .unlit {
                        TestSupport.expectEqual(color, palette.unlitDot)
                    } else {
                        TestSupport.expectEqual(color, palette.live)
                    }
                }
            }
            // Unlit: a neutral grey that still shows on the island, well short of the lit dot and the mark's line.
            let unlit = palette.unlitDot, island = palette.island.color
            TestSupport.expect(isGrey(unlit), "the unlit dot has a hue, \(name)")
            TestSupport.expect(ratio(unlit, island) >= 1.6, "the unlit dot vanishes on the island, \(name): \(ratio(unlit, island))")
            TestSupport.expect(ratio(unlit, island) < 0.6 * ratio(palette.live, island), "the unlit dot looks lit, \(name)")
            TestSupport.expect(ratio(unlit, island) < 0.6 * ratio(palette.island.ink, island), "the unlit dot looks like the line")
        }
        // The heartbeat: subtle, slow and one place to tune it (owner: judged on a phone).
        let beat = SessionDot.Heartbeat.self
        TestSupport.expectEqual(beat.period, 3)
        TestSupport.expect(beat.ripple >= 0.8 && beat.ripple <= 1.2 && beat.ripple < beat.period, "the ripple takes \(beat.ripple) s")
        TestSupport.expect(beat.reach >= 3.5 && beat.reach <= 5, "the ripple reaches \(beat.reach) pt")
        TestSupport.expect(beat.opacity > 0.3 && beat.opacity <= 0.6, "the ripple starts at \(beat.opacity)")
        TestSupport.expect(beat.firstDelay >= 0.2 && beat.firstDelay <= 0.6, "the first ripple waits \(beat.firstDelay) s")
        // Its widest ring stays inside Start's pill, unclipped: the mark's box starts at Start's padding (14 pt) and is
        // centred on the bar's control height.
        for height in [KeyboardMetrics.barControlHeight, KeyboardMetrics.compactBarControlHeight] {
            let box = KeyRect(x: 14, y: (height - 19) / 2, width: 19, height: 19)
            let mark = RidgeMark.fitted(in: box, weight: 1.3)
            let widest = mark.dotRadius + beat.reach
            let r = height / 2
            let centre = (x: max(r, mark.dot.x), y: r)
            let distance = ((mark.dot.x - centre.x) * (mark.dot.x - centre.x) + (mark.dot.y - centre.y) * (mark.dot.y - centre.y)).squareRoot()
            TestSupport.expect(distance + widest <= r - 0.5, "the ripple leaves Start's pill at \(height): \(distance + widest) of \(r)")
        }
    }

    /// Round 11 (Opus, round 10: "No session running" sat beside a green mark under Start's amber dot; the owner: the
    /// same rule in the menu): the menu's session mark is Start's, the same look from the same state in every case, in
    /// the card's variant of each colour: the lit dot reads at 3:1 on the card, the unlit one is the card's neutral grey.
    private static func testMenusDotMatchesStartsDot() {
        variants { palette, name in
            let menu = MenuPalette(dark: name.hasPrefix("dark"), highContrast: name.hasSuffix("high"))
            for (mode, ready) in sessionCases {
                let dot = SessionDot(mode: mode, sessionReady: ready)
                for reduceMotion in [false, true] {
                    let onMenu = dot.menuColor(menu, reduceMotion: reduceMotion), onStart = dot.color(palette, reduceMotion: reduceMotion)
                    if dot.look(reduceMotion: reduceMotion) == .unlit {
                        TestSupport.expectEqual(onMenu, menu.unlitDot)
                        TestSupport.expect(isGrey(onMenu) && isGrey(onStart), "an unlit dot has a hue, \(name)")
                    } else {
                        TestSupport.expectEqual(onMenu, menu.markDot)
                        TestSupport.expect(sameHue(onMenu, onStart), "the menu's dot is not Start's for \(mode), \(ready), \(name)")
                        TestSupport.expect(ratio(onMenu, menu.card) >= 3, "the menu's dot is faint on the card, \(name)")
                    }
                }
            }
            let unlit = menu.unlitDot
            TestSupport.expect(isGrey(unlit) && ratio(unlit, menu.card) >= 1.6, "the menu's unlit dot vanishes, \(name)")
            TestSupport.expect(ratio(unlit, menu.card) < 0.75 * ratio(menu.markDot, menu.card), "the menu's unlit dot looks lit, \(name)")
        }
    }
}
