import Foundation

/// What the middle of the top row shows (ARCHITECTURE.md, "Top row"). Dictation's own UI wins: while a dictation is
/// starting, recording, transcribing or waiting for the model, while a notice is up, or while its Undo chip shows,
/// neither the candidate strip nor the "Never correct" offer covers it; hidden, they still end as usual. Otherwise
/// the offer goes over the strip, and the strip over the chips and status line. Pure.
enum BarMiddleContent: Equatable, Sendable {
    case neverCorrect
    case candidates
    case dictation

    static func resolve(neverCorrectOffer: Bool, candidates: Bool, dictationInProgress: Bool, notice: Bool,
                        dictationUndoShown: Bool) -> BarMiddleContent {
        guard !dictationInProgress, !notice, !dictationUndoShown else { return .dictation }
        if neverCorrectOffer { return .neverCorrect }
        return candidates ? .candidates : .dictation
    }
}

/// The return key and `enablesReturnKeyAutomatically` (ARCHITECTURE.md, "Layout and keys"): a field that asks for
/// it gets a return key that is disabled, drawn dimmed and typing nothing, while it has no text, and enabled as soon as
/// it has some. Pure.
enum ReturnKeyRule {
    static func isEnabled(enablesAutomatically: Bool, hasText: Bool) -> Bool {
        !enablesAutomatically || hasText
    }
}

/// How the candidate strip lays out its words (ARCHITECTURE.md, "Top row"): equal slots side by side, 1 pt dividers
/// between them, each word on one line inside `padding` on each side, all at one text size: the largest at which
/// every shown word fits its slot, never above full size and no less than `minimumScale` of it. Pure.
enum CandidateStripLayout {
    static let minimumScale = 0.8
    /// The floor when even the words that must stay do not fit at `minimumScale`.
    static let lastResortScale = 0.6
    static let padding = 6.0
    static let divider = 1.0

    struct Fit: Equatable, Sendable {
        /// The candidates shown, as indices into the strip, in order.
        var shown: [Int]
        /// The one scale every shown word is drawn at, 1 for full size.
        var scale: Double
    }

    /// The candidates shown when the strip is `available` points wide and its words need `widths` points at full size:
    /// all of them when each fits its share at `minimumScale`; otherwise the least useful go first (the last that is
    /// neither the emphasized nor the quoted word) until the rest fit or only those two are left, which then shrink to
    /// `lastResortScale` if they must. They share the scale the tightest of them needs, so no word shows smaller than
    /// its neighbours. Everything, at `minimumScale`, before the strip or its words are measured.
    static func fit(_ strip: SwipeStrip, widths: [Double], available: Double) -> Fit {
        var shown = Array(strip.candidates.indices)
        guard available > 0, widths.count == strip.candidates.count else { return Fit(shown: shown, scale: minimumScale) }
        func room(_ shown: [Int]) -> Double {
            (available - divider * Double(shown.count - 1)) / Double(shown.count) - 2 * padding
        }
        /// The largest scale at which every shown word fits its slot, at most full size.
        func scale(_ shown: [Int]) -> Double {
            let room = room(shown)
            return shown.reduce(1) { widths[$1] > 0 ? min($0, room / widths[$1]) : $0 }
        }
        let kept: Set<Int> = Set([strip.emphasized, strip.live?.quoted].compactMap { $0 })
        while scale(shown) < minimumScale, let drop = shown.last(where: { !kept.contains($0) }), shown.count > 1 {
            shown.removeAll { $0 == drop }
        }
        let floor = scale(shown) >= minimumScale ? minimumScale : lastResortScale
        return Fit(shown: shown, scale: max(scale(shown), floor))
    }

    /// Whether a divider goes between two shown neighbours: not beside the emphasized candidate, whose pill already
    /// sets it apart.
    static func showsDivider(between left: Int, and right: Int, emphasized: Int?) -> Bool {
        left != emphasized && right != emphasized
    }
}
