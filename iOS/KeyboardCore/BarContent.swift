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
