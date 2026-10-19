import Foundation

/// Builds the word corrector from the swipe bundle (ARCHITECTURE.md, "Word autocorrect", Bundle): the
/// lexicon and the chosen word model, mapped from their files, and the touch model the bundle names (else
/// the standard one). The keyboard depends only on `WordCorrecting`; this is the one place that knows the
/// concrete types. Slow: call it off the main thread.
enum AutocorrectLoader {
    /// The corrector for `model` (a name the manifest has), or nil when a file is missing or invalid.
    static func load(manifest: AutocorrectManifest, bundleURL: URL, model: String) -> WordCorrecting? {
        guard let entry = manifest.models[model],
              let lexicon = try? WordLexicon.load(from: bundleURL.appendingPathComponent(manifest.lexicon)) else { return nil }
        let wordModel: WordModel
        switch entry.kind {
        case .unigram:
            wordModel = UnigramWordModel(lexicon: lexicon)
        case .ngram:
            guard let path = entry.path,
                  let loaded = try? NGramWordModel.load(from: bundleURL.appendingPathComponent(path), lexicon: lexicon) else { return nil }
            wordModel = loaded
        case .lstm:
            guard let path = entry.path,
                  let loaded = try? LSTMWordModel.load(from: bundleURL.appendingPathComponent(path), lexicon: lexicon) else { return nil }
            wordModel = loaded
        }
        let touch = manifest.touch.map(TapDecoder.TouchModel.init) ?? .standard
        return Autocorrector(lexicon: lexicon, model: wordModel, touch: touch)
    }
}
