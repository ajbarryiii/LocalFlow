import Foundation

/// The optional `autocorrect` section of the swipe bundle's `bundle.json` (ARCHITECTURE.md, "Word
/// autocorrect"): the lexicon, the word models by name, their tuned presets, the touch model the
/// corrector assumes and, optionally, the spelling channel's tables.
///
///     "autocorrect": {"format": 1, "lexicon": "autocorrect/lexicon.lfwl",
///                     "models": {"unigram": {"kind": "unigram"}, "ngram": {"kind": "ngram", "path": ...}, ...},
///                     "default_model": "ngram",
///                     "presets": {"ngram": {"balanced": {p_omit, ..., margin_known: null, ...}, ...}, ...},
///                     "default_preset": "balanced",
///                     "touch": {sigma, ratio, offset_y, tail_weight, tail_scale, space_spread},
///                     "spelling": "autocorrect/spelling.lfwe"}
///
/// Shared so the app can list the models and presets; the keyboard runs them. A bundle without the section
/// has no autocorrect; an invalid section rejects autocorrect, never the swipe bundle or soft key edges.
struct AutocorrectManifest: Equatable, Sendable {
    static let format = 1
    /// Accepted edit distances and word lengths in a preset: bounds that keep a correction cheap.
    static let maxEditsRange = 0 ... 3
    static let lengthRange = 1 ... 32
    /// Rounding allowed when insertion weights must sum to at most 1.
    static let weightSumTolerance = 1e-9

    enum ModelKind: String, CaseIterable, Decodable, Sendable {
        case unigram, ngram, lstm
    }

    struct Model: Equatable, Sendable {
        var kind: ModelKind
        /// The model's file relative to the bundle; nil for `unigram`, which needs none.
        var path: String?
    }

    enum ManifestError: Error, Equatable {
        case unsupportedFormat
        /// A lexicon path that is empty, absolute or leaves the bundle.
        case invalidLexicon
        /// No models, a default that is not one of them, a path missing (or given for `unigram`), or a path
        /// outside the bundle.
        case invalidModels
        /// A model without presets, without the default preset, presets for a model not listed, or a value out
        /// of its domain.
        case invalidPresets
        case invalidTouch
        /// A spelling path that is empty, absolute or leaves the bundle, or a preset with `w_spelling` > 0 in a
        /// section without one (the exporter refuses to write such a section).
        case invalidSpelling
    }

    var lexicon: String
    var models: [String: Model]
    var defaultModel: String
    /// Model name to preset name to parameters.
    var presets: [String: [String: AutocorrectParams]]
    var defaultPreset: String
    /// The touch model the corrector assumes: the section's own, else the `tap` section's; nil when neither
    /// has one (the keyboard then uses `TapDecoder.TouchModel.standard`).
    var touch: SoftKeyEdgesManifest.Touch?
    /// The LFWE spelling tables' file relative to the bundle (`SpellingTables`); nil when the bundle has none,
    /// and then every preset's `wSpelling` is 0.
    var spelling: String?

    /// The section of a `bundle.json`; nil when it has none. Throws for a malformed manifest or an invalid
    /// section. The `tap` section is read only for its touch model, and its being invalid never rejects this.
    static func decode(from data: Data) throws -> AutocorrectManifest? {
        guard let section = try JSONDecoder().decode(Wrapper.self, from: data).autocorrect else { return nil }
        guard section.format == format else { throw ManifestError.unsupportedFormat }
        guard isBundlePath(section.lexicon) else { throw ManifestError.invalidLexicon }
        guard !section.models.isEmpty, section.models[section.defaultModel] != nil,
              section.models.allSatisfy({ name, model in
                  guard !name.isEmpty else { return false }
                  switch model.kind {
                  case .unigram: return model.path == nil
                  case .ngram, .lstm: return model.path.map(isBundlePath) ?? false
                  }
              }) else {
            throw ManifestError.invalidModels
        }
        guard Set(section.presets.keys) == Set(section.models.keys),
              section.presets.values.allSatisfy({ presets in
                  presets[section.defaultPreset] != nil && presets.allSatisfy { !$0.key.isEmpty && $0.value.isValid }
              }) else {
            throw ManifestError.invalidPresets
        }
        if let touch = section.touch, !touch.isValid { throw ManifestError.invalidTouch }
        if let spelling = section.spelling, !isBundlePath(spelling) { throw ManifestError.invalidSpelling }
        guard section.spelling != nil || section.presets.values.allSatisfy({ $0.values.allSatisfy { $0.params.wSpelling == 0 } })
        else { throw ManifestError.invalidSpelling }
        let tapTouch = (try? SoftKeyEdgesManifest.decode(from: data))??.touch
        return AutocorrectManifest(
            lexicon: section.lexicon,
            models: section.models.mapValues { Model(kind: $0.kind, path: $0.path) },
            defaultModel: section.defaultModel,
            presets: section.presets.mapValues { $0.mapValues(\.params) },
            defaultPreset: section.defaultPreset,
            touch: section.touch ?? tapTouch,
            spelling: section.spelling)
    }

    /// The model names: unigram, then n-gram, then LSTM models, each by name.
    var modelNames: [String] {
        models.keys.sorted { a, b in
            let ka = Self.kindOrder(models[a]?.kind), kb = Self.kindOrder(models[b]?.kind)
            return ka != kb ? ka < kb : a < b
        }
    }

    /// The stored model when the bundle has it, otherwise the bundle's default.
    func modelName(_ stored: String?) -> String {
        stored.flatMap { models[$0] == nil ? nil : $0 } ?? defaultModel
    }

    /// The model's preset names: the default first, then by name.
    func presetNames(model: String) -> [String] {
        (presets[model] ?? [:]).keys.sorted { a, b in
            if a == defaultPreset { return b != defaultPreset }
            return b == defaultPreset ? false : a < b
        }
    }

    /// The stored preset when the model has it, otherwise the bundle's default.
    func presetName(_ stored: String?, model: String) -> String {
        stored.flatMap { presets[model]?[$0] == nil ? nil : $0 } ?? defaultPreset
    }

    /// The parameters of a model's preset (both resolved as `modelName` and `presetName` do).
    func params(model stored: String?, preset storedPreset: String?) -> AutocorrectParams {
        let model = modelName(stored)
        return presets[model]?[presetName(storedPreset, model: model)] ?? .standard
    }

    private static func kindOrder(_ kind: ModelKind?) -> Int {
        kind.flatMap { ModelKind.allCases.firstIndex(of: $0) } ?? ModelKind.allCases.count
    }

    /// A relative path of plain components: never absolute, never "." or "..".
    private static func isBundlePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    private struct Wrapper: Decodable {
        var autocorrect: Section?
    }

    private struct Section: Decodable {
        var format: Int
        var lexicon: String
        var models: [String: ModelSection]
        var defaultModel: String
        var presets: [String: [String: ParamsSection]]
        var defaultPreset: String
        var touch: SoftKeyEdgesManifest.Touch?
        var spelling: String?

        enum CodingKeys: String, CodingKey {
            case format, lexicon, models, presets, touch, spelling
            case defaultModel = "default_model"
            case defaultPreset = "default_preset"
        }
    }

    private struct ModelSection: Decodable {
        var kind: ModelKind
        var path: String?
    }

    /// A preset as the bundle has it: every name required but `w_spelling` (missing in bundles from before the
    /// spelling channel: 0), `null` margins infinite.
    private struct ParamsSection: Decodable {
        var params: AutocorrectParams

        enum CodingKeys: String, CodingKey {
            case pOmit = "p_omit", pInsert = "p_insert", pTranspose = "p_transpose", maxEdits = "max_edits"
            case maxEditsShort = "max_edits_short", shortLength = "short_length", minLength = "min_length"
            case lmWeight = "lm_weight", logOOV = "log_oov", marginOOV = "margin_oov", marginKnown = "margin_known"
            case marginApostrophe = "margin_apostrophe", wRepeat = "w_repeat", wSlip = "w_slip", wSpelling = "w_spelling"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func margin(_ key: CodingKeys) throws -> Double { try c.decode(Double?.self, forKey: key) ?? .infinity }
            params = AutocorrectParams(
                pOmit: try c.decode(Double.self, forKey: .pOmit), pInsert: try c.decode(Double.self, forKey: .pInsert),
                pTranspose: try c.decode(Double.self, forKey: .pTranspose), maxEdits: try c.decode(Int.self, forKey: .maxEdits),
                maxEditsShort: try c.decode(Int.self, forKey: .maxEditsShort),
                shortLength: try c.decode(Int.self, forKey: .shortLength), minLength: try c.decode(Int.self, forKey: .minLength),
                lmWeight: try c.decode(Double.self, forKey: .lmWeight), logOOV: try c.decode(Double.self, forKey: .logOOV),
                marginOOV: try margin(.marginOOV), marginKnown: try margin(.marginKnown),
                marginApostrophe: try margin(.marginApostrophe), wRepeat: try c.decode(Double.self, forKey: .wRepeat),
                wSlip: try c.decode(Double.self, forKey: .wSlip),
                wSpelling: try c.decodeIfPresent(Double.self, forKey: .wSpelling) ?? 0)
        }

        /// Each value in its domain: probabilities strictly between 0 and 1, bounded edits and lengths, a
        /// non-negative LM weight, a negative `log_oov`, margins of at least 1 (or infinite), insertion
        /// weights in 0–1 summing to at most 1, and a finite, non-negative `w_spelling`. The sliders' narrower
        /// ranges are not required here.
        var isValid: Bool {
            let p = params
            let probabilities = [p.pOmit, p.pInsert, p.pTranspose].allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 }
            let margins = [p.marginOOV, p.marginKnown, p.marginApostrophe].allSatisfy { $0 == .infinity || ($0.isFinite && $0 >= 1) }
            let weights = [p.wRepeat, p.wSlip].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
                && p.wRepeat + p.wSlip <= 1 + AutocorrectManifest.weightSumTolerance
            return probabilities && margins && weights
                && AutocorrectManifest.maxEditsRange.contains(p.maxEdits) && AutocorrectManifest.maxEditsRange.contains(p.maxEditsShort)
                && AutocorrectManifest.lengthRange.contains(p.shortLength) && AutocorrectManifest.lengthRange.contains(p.minLength)
                && p.lmWeight.isFinite && p.lmWeight >= 0 && p.logOOV.isFinite && p.logOOV < 0
                && p.wSpelling.isFinite && p.wSpelling >= 0
        }
    }
}

extension SoftKeyEdgesManifest.Touch: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sigma, ratio
        case offsetY = "offset_y"
        case tailWeight = "tail_weight"
        case tailScale = "tail_scale"
        case spaceSpread = "space_spread"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sigma: try c.decode(Double.self, forKey: .sigma), ratio: try c.decode(Double.self, forKey: .ratio),
                  offsetY: try c.decode(Double.self, forKey: .offsetY), tailWeight: try c.decode(Double.self, forKey: .tailWeight),
                  tailScale: try c.decode(Double.self, forKey: .tailScale),
                  spaceSpread: try c.decode(Double.self, forKey: .spaceSpread))
    }

    /// The domain `SoftKeyEdgesManifest` checks for the `tap` section's touch model.
    var isValid: Bool {
        [sigma, ratio, offsetY, tailWeight, tailScale, spaceSpread].allSatisfy(\.isFinite) && sigma > 0 && ratio > 0
            && tailScale > 0 && (0 ..< 1).contains(tailWeight) && spaceSpread > 0 && spaceSpread <= 1
    }
}
