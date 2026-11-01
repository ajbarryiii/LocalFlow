import Foundation

/// The keyboard's LocalFlow colours (ARCHITECTURE.md, "Keyboard look"): the Wilderness Labs palette of the app's
/// `Theme` (aurora, glacier, coral, ember, and the ink drawn on them) where something happens, the keys' neutral fill
/// everywhere else. On the light keyboard the bright hues are too pale for glyphs or thin strokes, so strokes and
/// glyphs take deeper variants of the same hues, and filled controls keep their bright fill with a hairline edge in
/// the deep hue. As sRGB components so their contrast is testable (`MenuPalette`); the keyboard makes colours of them. Pure.
struct BrandPalette: Equatable {
    typealias RGB = MenuPalette.RGB

    /// A filled control: a gradient from `top` to `bottom`, the ink on it, and an edge where the fill alone stands too
    /// little off the backdrop.
    struct Fill: Equatable {
        var top: RGB
        var bottom: RGB
        var ink: RGB
        var edge: RGB?
    }

    // The app's colours (App/Components.swift, `Theme`).
    static let aurora = RGB(109 / 255, 255 / 255, 168 / 255)
    static let glacier = RGB(103 / 255, 232 / 255, 249 / 255)
    static let coral = RGB(255 / 255, 125 / 255, 94 / 255)
    static let ember = RGB(245 / 255, 198 / 255, 107 / 255)
    static let ink = RGB(4 / 255, 18 / 255, 10 / 255)
    /// The light keyboard's waiting capsule (round 7, Opus visual): the glacier at 85% of its saturation, the same hue and
    /// brightness, so it sits calmer than Stop beside the grey keys.
    static let calmGlacier = RGB(125 / 255, 235 / 255, 249 / 255)
    /// `Theme.gradient`'s leading stop: a hint of glacier in the aurora.
    static let auroraHighlight = RGB(107 / 255, 246 / 255, 200 / 255)

    /// Start, the action return keys and caps lock: the app's primary button.
    var accent: Fill
    /// Stop, while starting and recording.
    var stop: Fill
    /// The capsule while the recording waits for its transcript (preparing, transcribing).
    var working: Fill
    /// Strokes and glyphs on the backdrop: the recording wave, the swipe trail, the emoji category shown, links.
    var aurora: RGB
    var glacier: RGB
    var coral: RGB
    /// An error's symbol.
    var ember: RGB
    /// An accent glyph drawn on a key or chip fill (Undo's symbol).
    var keyGlyph: RGB
    /// "Open LocalFlow" in the menu.
    var link: RGB
    /// Primary text: the candidates.
    var text: RGB
    /// The candidate Space would put in: `pill` at `pillAlpha` over the backdrop, edged in `pillEdge` at `pillEdgeAlpha`. A
    /// soft aurora tint on the dark keyboard; on the light one the keys' white fill, so it never reads as a second Start.
    var pill: RGB
    var pillAlpha: Double
    var pillEdge: RGB
    var pillEdgeAlpha: Double
    /// The status line's ink (the idle line, the recording's caption) where the system's secondary text is too faint on
    /// the backdrop: the light keyboard, where it is the menu's secondary ink. Nil keeps the system's secondary text.
    var statusInk: RGB?
    /// The width of a fill's edge, in points: a hairline that only sets the bright fill off the light backdrop (the fill
    /// carries the colour), a full point with Increase Contrast.
    var edgeWidth: Double
    /// The swipe trail's opacity at the finger (`SwipeTrail`); its colour runs from glacier at the tail to aurora.
    var trailAlpha: Double
    /// The keys' fill (`KeyPalette.fill`).
    var keyFill: RGB
    /// The system's keyboard backdrop as measured (iOS 26.4 simulator, Messages): for the contrast contract only. The
    /// keyboard never draws a backdrop (ARCHITECTURE.md, "Touchable backgrounds").
    var backdrop: RGB

    /// `highContrast`: Increase Contrast, which deepens the light keyboard's strokes further and lightens the dark keys.
    init(dark: Bool, highContrast: Bool) {
        if dark {
            backdrop = RGB(33 / 255, 33 / 255, 33 / 255)
            keyFill = highContrast ? RGB(0.50, 0.50, 0.50) : RGB(0.42, 0.42, 0.42)
            text = RGB(1, 1, 1)
            aurora = Self.aurora
            glacier = Self.glacier
            coral = Self.coral
            ember = Self.ember
            accent = Fill(top: Self.auroraHighlight, bottom: Self.aurora, ink: Self.ink, edge: nil)
            stop = Fill(top: Self.coral, bottom: Self.coral, ink: Self.ink, edge: nil)
            working = Fill(top: Self.glacier, bottom: Self.glacier, ink: Self.ink, edge: nil)
            keyGlyph = Self.aurora
            pill = Self.aurora
            pillAlpha = 0.2
            pillEdgeAlpha = 0.45
            statusInk = nil
            trailAlpha = 0.7
            edgeWidth = 1
        } else {
            backdrop = RGB(230 / 255, 232 / 255, 234 / 255)
            keyFill = RGB(1, 1, 1)
            text = RGB(0, 0, 0)
            aurora = highContrast ? RGB(7 / 255, 102 / 255, 56 / 255) : RGB(10 / 255, 122 / 255, 64 / 255)
            glacier = highContrast ? RGB(11 / 255, 95 / 255, 119 / 255) : RGB(14 / 255, 116 / 255, 144 / 255)
            coral = highContrast ? RGB(163 / 255, 46 / 255, 21 / 255) : RGB(194 / 255, 58 / 255, 30 / 255)
            ember = highContrast ? RGB(122 / 255, 79 / 255, 5 / 255) : RGB(147 / 255, 96 / 255, 10 / 255)
            accent = Fill(top: Self.auroraHighlight, bottom: Self.aurora, ink: Self.ink, edge: aurora)
            stop = Fill(top: Self.coral, bottom: Self.coral, ink: Self.ink, edge: coral)
            working = Fill(top: Self.calmGlacier, bottom: Self.calmGlacier, ink: Self.ink, edge: glacier)
            keyGlyph = aurora
            pill = keyFill
            pillAlpha = 1
            pillEdgeAlpha = 0.5
            statusInk = MenuPalette.secondary(dark: false, highContrast: highContrast)
            trailAlpha = 0.85
            edgeWidth = highContrast ? 1 : 0.5
        }
        link = aurora
        pillEdge = aurora
    }

    /// `color` at `alpha` over `backdrop`, in sRGB components (as the screen composites it).
    static func blend(_ color: RGB, alpha: Double, over backdrop: RGB) -> RGB {
        func mix(_ a: Double, _ b: Double) -> Double { a * alpha + b * (1 - alpha) }
        return RGB(mix(color.red, backdrop.red), mix(color.green, backdrop.green), mix(color.blue, backdrop.blue))
    }

    /// The swipe trail's colour at `fraction` of the way from its tail (0, glacier) to the finger (1, aurora).
    func trailColor(at fraction: Double) -> RGB {
        Self.blend(aurora, alpha: min(max(fraction, 0), 1), over: glacier)
    }
}
