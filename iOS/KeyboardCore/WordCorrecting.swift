import Foundation

/// A word corrector (ARCHITECTURE.md, "Word autocorrect"): given the normalized context before a just-typed
/// word (`TapPrior.normalizeContext`), the word lowercased, and the touch-down point of each of its
/// characters in key-area points (nil for a character typed without a letters-layer tap), the word to
/// commit: `word` itself or a lexicon form, lowercase. Deterministic: caches (of sentence contexts) never
/// change a result. `Autocorrector` implements it; the keyboard depends only on this.
protocol WordCorrecting: AnyObject {
    func correct(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                 params: AutocorrectParams) -> String
    /// The suggestion strip's words for the same inputs: up to `limit` lexicon forms other than `word`, lowercase,
    /// best first, ranked as `correct` ranks its candidates (channel plus weighted model log probability; ties to
    /// the higher frequency, then the first form) but with no margin: every form whose posterior odds against
    /// keeping the word are at least the suggestion floor, for a lexicon word too. None for a word typed as meant
    /// (no form near enough), or one `correct` keeps without looking (invalid inputs, a key shorter than
    /// `minLength`).
    func suggestions(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                     params: AutocorrectParams, limit: Int) -> [String]
    /// While a word is typed (ARCHITECTURE.md, "Word autocorrect", Suggestions): what a commit key would make of
    /// it, and up to `limit` other lexicon forms, best first. `word` is the word so far, as for `correct`.
    func predictions(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                     params: AutocorrectParams, limit: Int) -> WordPredictions
    /// Drops every cache that holds context or words (the keyboard calls it when it hides). Results after it
    /// are the same as before.
    func forgetContext()
}

/// The corrector's predictions for a word being typed (`WordCorrecting.predictions`), lowercase lexicon forms.
struct WordPredictions: Equatable, Sendable {
    /// What `correct` would commit instead of the word; nil when it keeps it.
    var correction: String?
    /// Forms other than the word, best first: its completions and its typo-tolerant matches.
    var words: [String]
    /// The word is a lexicon form.
    var isWord: Bool

    init(correction: String? = nil, words: [String], isWord: Bool) {
        self.correction = correction
        self.words = words
        self.isWord = isWord
    }
}
