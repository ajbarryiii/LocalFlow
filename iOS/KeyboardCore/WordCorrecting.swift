import Foundation

/// A word corrector (ARCHITECTURE.md, "Word autocorrect"): given the normalized context before a just-typed
/// word (`TapPrior.normalizeContext`), the word lowercased, and the touch-down point of each of its
/// characters in key-area points (nil for a character typed without a letters-layer tap), the word to
/// commit: `word` itself or a lexicon form, lowercase. Deterministic: caches (of sentence contexts) never
/// change a result. `Autocorrector` implements it; the keyboard depends only on this.
protocol WordCorrecting: AnyObject {
    func correct(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                 params: AutocorrectParams) -> String
    /// Drops every cache that holds context or words (the keyboard calls it when it hides). Results after it
    /// are the same as before.
    func forgetContext()
}
