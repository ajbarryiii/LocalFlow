import Foundation

/// The keyboard's colours (ARCHITECTURE.md, "Keyboard look"). The controls are monochrome: the action keys and caps lock
/// take the label colour's side (a light key on the dark keyboard, a graphite one on the light), and dictation lives in
/// a dark island in both modes, in the spirit of the Dynamic Island: near-black on the dark keyboard, graphite on the
/// light one, where a black slab across the bar was the heaviest thing on the keyboard. The Wilderness Labs colours of the app's
/// `Theme` are accents only, in small things that mark a state: aurora for the mark's dot (on Start, the readiness dot,
/// the dot the recording wave settles into) and the menu's link, glacier for the wait's shimmer alone, ember for an
/// error's symbol. On the light keyboard the bright hues are too pale for glyphs on the backdrop, so those take deeper
/// variants of the same hues; on the island, which is dark in both modes, they stay bright. As sRGB components so
/// their contrast is testable (`MenuPalette`); the keyboard makes colours of them. Pure.
struct BrandPalette: Equatable {
    typealias RGB = MenuPalette.RGB

    /// A filled control: its fill, the ink on it, and an edge where the fill alone stands too little off the backdrop.
    struct Fill: Equatable {
        var color: RGB
        var ink: RGB
        var edge: RGB?
    }

    // The app's colours (App/Components.swift, `Theme`).
    static let aurora = RGB(109 / 255, 255 / 255, 168 / 255)
    static let glacier = RGB(103 / 255, 232 / 255, 249 / 255)
    static let ember = RGB(245 / 255, 198 / 255, 107 / 255)

    /// The action return keys (go, send, search, ...), caps lock and the press-and-hold pick: the primary action, in
    /// the label colour's side.
    var accent: Fill
    /// The dictation island: Start, the recording (Stop) and the wait for the transcript. Its lit dots are its ink.
    var island: Fill
    /// The mark's dot on the island (Start's mark, the dot the recording wave settles into): the app's aurora.
    var live: RGB
    /// The wait's shimmer on the island: a cool glacier white, the keyboard's only glacier.
    var shimmer: RGB
    /// Accents on the backdrop: the readiness dot (aurora) and an error's symbol (ember).
    var aurora: RGB
    var ember: RGB
    /// "Open LocalFlow" in the menu.
    var link: RGB
    /// Primary text: the candidates.
    var text: RGB
    /// The candidate Space would put in: `pill` at `pillAlpha` over the backdrop, edged in `pillEdge` at `pillEdgeAlpha`.
    /// Neutral: a soft white veil on the dark keyboard, the keys' white on the light one.
    var pill: RGB
    var pillAlpha: Double
    var pillEdge: RGB
    var pillEdgeAlpha: Double
    /// The status line's ink (the idle line, the wait's words) where the system's secondary text is too faint on the
    /// backdrop: the light keyboard, where it is the menu's secondary ink. Nil keeps the system's secondary text.
    var statusInk: RGB?
    /// The width of a fill's edge, in points: a hairline, a full point with Increase Contrast.
    var edgeWidth: Double
    /// The swipe trail's colour, the label colour's, and its opacity at the finger (`SwipeTrail`): 3:1 at the finger
    /// against the keys it crosses and the backdrop, still translucent.
    var trail: RGB
    var trailAlpha: Double
    /// The keys' fill (`KeyPalette.fill`).
    var keyFill: RGB
    /// The system's keyboard backdrop as measured (iOS 26.4 simulator, Messages): for the contrast contract only. The
    /// keyboard never draws a backdrop (ARCHITECTURE.md, "Touchable backgrounds").
    var backdrop: RGB

    /// `highContrast`: Increase Contrast, which deepens the light keyboard's accents and the dark island's edge, and
    /// lightens the dark keys.
    init(dark: Bool, highContrast: Bool) {
        if dark {
            backdrop = RGB(33 / 255, 33 / 255, 33 / 255)
            keyFill = highContrast ? RGB(0.50, 0.50, 0.50) : RGB(0.42, 0.42, 0.42)
            text = RGB(1, 1, 1)
            aurora = Self.aurora
            ember = Self.ember
            accent = Fill(color: RGB(0.9, 0.9, 0.91), ink: RGB(0.07, 0.07, 0.08), edge: nil)
            // Darker than the backdrop, as the Dynamic Island is on a dark screen: its hairline sets it off.
            island = Fill(color: RGB(0.035, 0.035, 0.04), ink: RGB(1, 1, 1),
                          edge: highContrast ? RGB(0.56, 0.56, 0.57) : RGB(0.43, 0.43, 0.44))
            pill = RGB(1, 1, 1)
            pillAlpha = 0.14
            pillEdge = RGB(1, 1, 1)
            pillEdgeAlpha = 0.22
            statusInk = nil
            // Light enough to show on the grey keys it crosses (3:1 at the finger), not only on the backdrop.
            trail = RGB(1, 1, 1)
            trailAlpha = highContrast ? 0.8 : 0.72
        } else {
            backdrop = RGB(230 / 255, 232 / 255, 234 / 255)
            keyFill = RGB(1, 1, 1)
            text = RGB(0, 0, 0)
            aurora = highContrast ? RGB(7 / 255, 102 / 255, 56 / 255) : RGB(10 / 255, 122 / 255, 64 / 255)
            ember = highContrast ? RGB(122 / 255, 79 / 255, 5 / 255) : RGB(147 / 255, 96 / 255, 10 / 255)
            accent = Fill(color: RGB(0.17, 0.17, 0.18), ink: RGB(1, 1, 1), edge: nil)
            island = Fill(color: RGB(0.17, 0.17, 0.18), ink: RGB(1, 1, 1), edge: nil)
            pill = keyFill
            pillAlpha = 1
            pillEdge = RGB(0, 0, 0)
            pillEdgeAlpha = 0.3
            statusInk = MenuPalette.secondary(dark: false, highContrast: highContrast)
            trail = RGB(0, 0, 0)
            trailAlpha = 0.5
        }
        live = Self.aurora
        shimmer = Self.blend(Self.glacier, alpha: 0.55, over: RGB(1, 1, 1))
        link = aurora
        edgeWidth = highContrast ? 1 : 0.5
    }

    /// `color` at `alpha` over `backdrop`, in sRGB components (as the screen composites it).
    static func blend(_ color: RGB, alpha: Double, over backdrop: RGB) -> RGB {
        func mix(_ a: Double, _ b: Double) -> Double { a * alpha + b * (1 - alpha) }
        return RGB(mix(color.red, backdrop.red), mix(color.green, backdrop.green), mix(color.blue, backdrop.blue))
    }
}
