import Foundation

/// How the open menu covers the keyboard (ARCHITECTURE.md, "Top row", menu): one calm layer. The keys and the bar's
/// controls other than the menu button fade alike to `dimmedAlpha` over the system's backdrop, which is never tinted
/// (a tint over the keyboard's area would show a seam under the band iOS draws above it, "Touchable backgrounds"),
/// and the card lies over the keys so that none peeks out at its edges or corners: it reaches `overhang` past the
/// keys' outer edges, its corners rounded to match theirs. Pure.
enum MenuCover {
    /// The keys' and the bar controls' opacity while the menu is open.
    static let dimmedAlpha = 0.35
    /// How far the card reaches past the outer edges of the keys it covers.
    static let overhang = 2.0
    /// The card's corner radius: the keys' own, grown by the overhang, so a corner key's rounded corner lies inside
    /// the card's.
    static let cornerRadius = KeyboardMetrics.keyCornerRadius + overhang

    /// The card's frame in a key area of `metrics`, for content `contentHeight` points tall: over the three rows above
    /// the bottom row when it fits there, so the bottom row shows whole below it; otherwise over all four rows, where
    /// content still taller scrolls inside it.
    static func card(metrics m: KeyboardMetrics, contentHeight: Double) -> KeyRect {
        let x = m.sideMargin - overhang, y = m.topPadding - overhang
        let threeRows = m.rowY(2) + m.rowHeight + overhang - y
        let fourRows = m.rowY(3) + m.rowHeight + overhang - y
        return KeyRect(x: x, y: y, width: max(m.width - 2 * x, 0), height: contentHeight <= threeRows ? threeRows : fourRows)
    }
}
