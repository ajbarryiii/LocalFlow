import Foundation

/// The optional `tap` section of the swipe bundle's `bundle.json` (ARCHITECTURE.md, "Soft key edges"):
/// the tap models by size name, and the touch model and rule the keyboard uses.
///
///     "tap": {"format": 1, "models": {"67k": "tap/gru-e32-h128.bin", ...}, "default_model": "67k",
///             "touch": {sigma, ratio, offset_y, tail_weight, tail_scale, space_spread},
///             "rule": {centre, margin, max_surprise, surprise_window}}
///
/// The keyboard runs the default model with this rule; `AutocorrectManifest` also reads the touch model.
/// A bundle without the section has no soft key edges; an invalid section rejects the feature, never the
/// swipe bundle.
struct SoftKeyEdgesManifest: Equatable, Sendable {
    static let format = 1
    /// Accepted surprise windows (letters and spaces).
    static let surpriseWindowRange = 1 ... 64

    /// Lengths in letter pitches (`TapDecoder.TouchModel`).
    struct Touch: Equatable, Sendable {
        var sigma: Double
        var ratio: Double
        var offsetY: Double
        var tailWeight: Double
        var tailScale: Double
        var spaceSpread: Double
    }

    /// The rule the keyboard applies (`TapDecoder.Rule`), and the surprise window of the prior.
    struct Rule: Equatable, Sendable {
        /// Accepted values: the centre box as a fraction of a key's width and height, the margin as
        /// posterior odds, and the surprise gate in bits.
        static let centreRange: ClosedRange<Double> = 0.3...0.9
        static let marginRange: ClosedRange<Double> = 1...10
        static let maxSurpriseRange: ClosedRange<Double> = 2...8

        var centre: Double
        var margin: Double
        var maxSurprise: Double
        var surpriseWindow: Int
    }

    enum ManifestError: Error, Equatable {
        case unsupportedFormat
        /// No models, a default that is not one of them, or a path outside the bundle.
        case invalidModels
        case invalidSettings
    }

    /// Size name (e.g. "67k") to the model's path relative to the bundle.
    var models: [String: String]
    var defaultModel: String
    var touch: Touch
    var rule: Rule

    /// The section of a `bundle.json`; nil when it has none. Throws for a malformed manifest or an
    /// invalid section: values out of range (the rule's must be within `Rule`'s ranges), or a model
    /// path that is absolute or leaves the bundle.
    static func decode(from data: Data) throws -> SoftKeyEdgesManifest? {
        guard let section = try JSONDecoder().decode(Wrapper.self, from: data).tap else { return nil }
        guard section.format == format else { throw ManifestError.unsupportedFormat }
        guard !section.models.isEmpty, section.models[section.defaultModel] != nil,
              section.models.allSatisfy({ !$0.key.isEmpty && isBundlePath($0.value) }) else {
            throw ManifestError.invalidModels
        }
        let t = section.touch, r = section.rule
        guard [t.sigma, t.ratio, t.offsetY, t.tailWeight, t.tailScale, t.spaceSpread].allSatisfy(\.isFinite),
              t.sigma > 0, t.ratio > 0, t.tailScale > 0, (0 ..< 1).contains(t.tailWeight), t.spaceSpread > 0,
              t.spaceSpread <= 1,
              Rule.centreRange.contains(r.centre),
              Rule.marginRange.contains(r.margin),
              Rule.maxSurpriseRange.contains(r.maxSurprise),
              surpriseWindowRange.contains(r.surpriseWindow) else {
            throw ManifestError.invalidSettings
        }
        return SoftKeyEdgesManifest(
            models: section.models, defaultModel: section.defaultModel,
            touch: Touch(sigma: t.sigma, ratio: t.ratio, offsetY: t.offsetY, tailWeight: t.tailWeight,
                         tailScale: t.tailScale, spaceSpread: t.spaceSpread),
            rule: Rule(centre: r.centre, margin: r.margin, maxSurprise: r.maxSurprise, surpriseWindow: r.surpriseWindow))
    }

    /// A relative path of plain components: never absolute, never "." or "..".
    private static func isBundlePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    private struct Wrapper: Decodable {
        var tap: Section?
    }

    private struct Section: Decodable {
        var format: Int
        var models: [String: String]
        var defaultModel: String
        var touch: TouchSection
        var rule: RuleSection

        enum CodingKeys: String, CodingKey {
            case format, models, touch, rule
            case defaultModel = "default_model"
        }
    }

    private struct TouchSection: Decodable {
        var sigma: Double
        var ratio: Double
        var offsetY: Double
        var tailWeight: Double
        var tailScale: Double
        var spaceSpread: Double

        enum CodingKeys: String, CodingKey {
            case sigma, ratio
            case offsetY = "offset_y"
            case tailWeight = "tail_weight"
            case tailScale = "tail_scale"
            case spaceSpread = "space_spread"
        }
    }

    private struct RuleSection: Decodable {
        var centre: Double
        var margin: Double
        var maxSurprise: Double
        var surpriseWindow: Int

        enum CodingKeys: String, CodingKey {
            case centre, margin
            case maxSurprise = "max_surprise"
            case surpriseWindow = "surprise_window"
        }
    }
}
