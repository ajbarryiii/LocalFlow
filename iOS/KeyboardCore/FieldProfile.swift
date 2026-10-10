import Foundation

/// How the trackpad lays out the host's text (ARCHITECTURE.md, "Field width profiles"): the host's
/// real font and width are unknown to a keyboard, so the layout is emulated with one of two
/// profiles.
enum FieldLayout: String, CaseIterable, Codable, Sendable {
    /// Messages' compose bubble, measured: a narrower wrap width.
    case messages
    /// Near-full-width fields (Notes, Mail, T3 Code-style inputs): the tuning that already works.
    case fullWidth

    var title: String {
        switch self {
        case .messages: return "Messages-width"
        case .fullWidth: return "Full-width"
        }
    }

    var other: FieldLayout { self == .messages ? .fullWidth : .messages }
}

/// Every field-profile constant, in one place (ARCHITECTURE.md, "Field profile parameters";
/// measured in iOS 26.4 simulators, calibration report "Field geometry").
/// - Messages wraps at keyboard width − (2·m + 117.33), with m = 16 on keyboards narrower than
///   414 pt and 20 otherwise (243.7 pt on a 393 pt iPhone 15 Pro), body font at the current Dynamic
///   Type size, TextKit 1, line-fragment padding 0. That reproduced every observed line break.
/// - Full width keeps today's tuning: keyboard width − 40 on 16 pt-margin phones, − 48 on 20 pt
///   ones (a guess), the same font and layout.
/// - The line pitch in both is the layout's real line advance, lineHeight + leading (24.00 pt at the
///   default size), not `font.lineHeight` (22.29 pt), which made every vertical step 7.7 % short.
struct FieldLayoutParameters: Equatable, Sendable {
    /// The layout a field gets when nothing (an override, a recognized fingerprint) says otherwise.
    var defaultLayout = FieldLayout.fullWidth
    /// The screen margin: 16 pt on keyboards narrower than `wideKeyboardWidth`, else 20 pt.
    var narrowMargin = 16.0
    var wideMargin = 20.0
    var wideKeyboardWidth = 414.0
    /// Messages: the compose bubble's chrome inside both margins (avatar column, send button, insets).
    var messagesChrome = 117.33
    /// Full width: the total chrome on 16 pt- and 20 pt-margin phones.
    var fullWidthChromeNarrow = 40.0
    var fullWidthChromeWide = 48.0
    /// TextKit's line-fragment padding, in both profiles.
    var lineFragmentPadding = 0.0
    /// Never lay text out narrower than this.
    var minimumWidth = 40.0
    /// Keyboard widths (portrait iPhones, points) where the Messages geometry was measured or follows
    /// directly from measurement: 390 (17e), 402 (17, 17 Pro), 420 (Air), 440 (Pro Max), and 393 (the
    /// iPhone 15 Pro, between two measured widths with the same margin). Display Zoom changes the width
    /// in points, so a zoomed screen counts only if it lands on one of these.
    var messagesValidatedWidths: [Double] = [390, 393, 402, 420, 440]
    /// How close to a validated width counts as that width.
    var messagesWidthTolerance = 1.0
    /// Messages' compose field as it reports itself (iOS 26.4 simulator, 2026-10-09): default keyboard
    /// and return key, sentence capitalization, autocorrection and spell checking left at their
    /// defaults, smart quotes and dashes off, smart insert/delete on. No other field measured has
    /// smart quotes and dashes off with autocorrection at its default (see `FieldProfileTests`).
    var messagesSignature: FieldTraits = {
        var traits = FieldTraits()
        traits.autocapitalization = 2
        traits.smartQuotes = 1
        traits.smartDashes = 1
        traits.smartInsertDelete = 2
        return traits
    }()

    static let standard = FieldLayoutParameters()

    /// Whether the Messages geometry applies here on its own: portrait, at a validated width. Elsewhere
    /// (landscape, iPad, unmeasured widths) only a manual choice selects it.
    func messagesGeometryApplies(keyboardWidth: Double, isPortrait: Bool) -> Bool {
        isPortrait && messagesValidatedWidths.contains { abs($0 - keyboardWidth) <= messagesWidthTolerance }
    }

    func margin(keyboardWidth: Double) -> Double {
        keyboardWidth < wideKeyboardWidth ? narrowMargin : wideMargin
    }

    /// The emulated text width for a keyboard (in portrait, the screen) this wide.
    func wrapWidth(_ layout: FieldLayout, keyboardWidth: Double) -> Double {
        let width: Double
        switch layout {
        case .messages:
            width = keyboardWidth - (2 * margin(keyboardWidth: keyboardWidth) + messagesChrome)
        case .fullWidth:
            width = keyboardWidth - (keyboardWidth < wideKeyboardWidth ? fullWidthChromeNarrow : fullWidthChromeWide)
        }
        return max(width, minimumWidth)
    }

    /// A text view's line advance: the font's line height plus its leading.
    static func linePitch(lineHeight: Double, leading: Double) -> Double {
        max(lineHeight + max(leading, 0), 1)
    }
}

/// The traits a field reports to a keyboard (`UITextInputTraits`), content-free: enum raw values,
/// flags, and Apple's text content type identifiers. Never any text, and nothing that depends on it.
struct FieldTraits: Hashable, Codable, Sendable {
    var keyboardType = 0
    var returnKeyType = 0
    var autocapitalization = 0
    var autocorrection = 0
    var spellChecking = 0
    var smartQuotes = 0
    var smartDashes = 0
    var smartInsertDelete = 0
    var keyboardAppearance = 0
    var inlinePrediction = 0
    var mathExpressionCompletion = 0
    var writingToolsBehavior = 0
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false
    /// One of Apple's `UITextContentType` constants (its raw value), "custom" for any other, or nil.
    var textContentType: String?

    /// A field's content type as the fingerprint may hold it: an app can set any string here (a draft's
    /// name, an identifier), so only Apple's own constants (`known`, raw values) pass; anything else
    /// is "custom" before it is encoded, hashed or displayed.
    static func contentTypeLabel(_ raw: String?, known: Set<String>) -> String? {
        guard let raw else { return nil }
        return known.contains(raw) ? raw : "custom"
    }

    /// A stable, readable encoding, the input to the fingerprint's hash. The keyboard appearance is
    /// left out: Messages reports light or dark with the system appearance, and other fields switch it
    /// as focus moves (measured), so it would split one field into several.
    var canonical: String {
        let flags = [enablesReturnKeyAutomatically, isSecureTextEntry].map { $0 ? "1" : "0" }.joined()
        return "kb\(keyboardType) rt\(returnKeyType) ac\(autocapitalization) co\(autocorrection) sp\(spellChecking) "
            + "sq\(smartQuotes) sd\(smartDashes) si\(smartInsertDelete) ip\(inlinePrediction) "
            + "mx\(mathExpressionCompletion) wt\(writingToolsBehavior) f\(flags) ct\(textContentType ?? "-")"
    }

    /// The traits that identify a kind of field: everything but the appearance and the traits the
    /// proxy does not report today (inline prediction, math completion, Writing Tools).
    func matchesSignature(_ signature: FieldTraits) -> Bool {
        keyboardType == signature.keyboardType && returnKeyType == signature.returnKeyType
            && autocapitalization == signature.autocapitalization && autocorrection == signature.autocorrection
            && spellChecking == signature.spellChecking && smartQuotes == signature.smartQuotes
            && smartDashes == signature.smartDashes && smartInsertDelete == signature.smartInsertDelete
            && enablesReturnKeyAutomatically == signature.enablesReturnKeyAutomatically
            && isSecureTextEntry == signature.isSecureTextEntry && textContentType == signature.textContentType
    }
}

/// A field's content-free fingerprint: its traits, plus the offset unit the trackpad learned there
/// once it is known. Keys are stable across launches (FNV-1a), so a user's layout choice can be
/// remembered per fingerprint.
struct FieldFingerprint: Hashable, Sendable {
    var traits: FieldTraits
    var unit: CursorOffsetUnit?

    /// The key with the unit, once known; without it before.
    var key: String { Self.hash(traits.canonical + " u" + unitCode) }
    /// The key of the traits alone, for a choice made before the unit was known.
    var traitsKey: String { Self.hash(traits.canonical + " u?") }

    /// For the menu's debug readout: the short key, the traits and the appearance, content-free.
    var summary: String { "\(key.prefix(8)) \(traits.canonical) ap\(traits.keyboardAppearance) u\(unitCode)" }

    private var unitCode: String {
        switch unit {
        case .utf16?: return "16"
        case .grapheme?: return "g"
        case nil: return "?"
        }
    }

    /// 64-bit FNV-1a, as 16 hex digits.
    static func hash(_ string: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// Where the keyboard is: its width and whether the device is in portrait.
struct FieldGeometry: Equatable, Sendable {
    var keyboardWidth: Double
    var isPortrait: Bool
}

/// Picks a field's layout: the user's remembered choice for its fingerprint (with the unit, then
/// without), else Messages for a field that looks like Messages' compose field where the Messages
/// geometry was measured (portrait, validated widths), else the default. Pure.
enum FieldLayoutChooser {
    static func layout(for fingerprint: FieldFingerprint, overrides: [String: FieldLayout], geometry: FieldGeometry,
                       parameters: FieldLayoutParameters = .standard) -> FieldLayout {
        // A manual choice applies everywhere.
        if let chosen = overrides[fingerprint.key] ?? overrides[fingerprint.traitsKey] { return chosen }
        // The measured Messages geometry only where it was measured.
        if looksLikeMessages(fingerprint, parameters: parameters),
           parameters.messagesGeometryApplies(keyboardWidth: geometry.keyboardWidth, isPortrait: geometry.isPortrait) {
            return .messages
        }
        return parameters.defaultLayout
    }

    /// The overrides a manual choice writes: the fingerprint with each unit and with none, so the choice
    /// holds whether or not the trackpad has learned the unit (hiding forgets it) and a later choice
    /// replaces it whatever was known then.
    static func choiceEntries(for fingerprint: FieldFingerprint, layout: FieldLayout) -> [String: FieldLayout] {
        var entries: [String: FieldLayout] = [:]
        for unit in [nil, CursorOffsetUnit.utf16, .grapheme] {
            entries[FieldFingerprint(traits: fingerprint.traits, unit: unit).key] = layout
        }
        return entries
    }

    /// Messages' compose field: its measured trait signature, in a UIKit text view (a field where the
    /// trackpad learned grapheme units is WebKit, not Messages).
    static func looksLikeMessages(_ fingerprint: FieldFingerprint, parameters: FieldLayoutParameters = .standard) -> Bool {
        fingerprint.unit != .grapheme && fingerprint.traits.matchesSignature(parameters.messagesSignature)
    }
}

/// The current field's fingerprint as the keyboard reads it, and the layout each trackpad gesture uses.
/// Pure, in memory only.
/// - **Readings.** The proxy's traits are read at every host callback and at each gesture's start (raw
///   values, cheap). A reading without a field identity is a placeholder and is never used: measured
///   at the keyboard's first appearance (iOS 26.4 simulator, round 6), the proxy reports default
///   traits with no `documentIdentifier` until its first `textDidChange`.
/// - **Gestures.** A gesture's layout is chosen when it starts, from the latest reading, and holds
///   until it ends; a fingerprint that changes meanwhile (the trackpad learning the unit, the traits
///   arriving late) applies from the next gesture.
/// - **Choices.** A manual choice is remembered only for a real reading.
struct FieldProfileTracker: Equatable, Sendable {
    /// The latest reading taken with a field identity, and that identity.
    private(set) var fingerprint: FieldFingerprint?
    private(set) var documentID: UUID?
    /// The layout of the gesture running, fixed at its start.
    private(set) var gestureLayout: FieldLayout?

    /// A reading of the proxy. Returns whether the fingerprint the next gesture would use changed.
    @discardableResult
    mutating func read(_ reading: FieldFingerprint, documentID: UUID?) -> Bool {
        guard let documentID else { return false }
        guard reading != fingerprint || documentID != self.documentID else { return false }
        fingerprint = reading
        self.documentID = documentID
        return true
    }

    /// The keyboard is hiding: the field is forgotten.
    mutating func forget() {
        fingerprint = nil
        documentID = nil
        gestureLayout = nil
    }

    /// The layout for the field as last read; the default until a real reading.
    func layout(overrides: [String: FieldLayout], geometry: FieldGeometry,
                parameters: FieldLayoutParameters = .standard) -> FieldLayout {
        guard let fingerprint else { return parameters.defaultLayout }
        return FieldLayoutChooser.layout(for: fingerprint, overrides: overrides, geometry: geometry, parameters: parameters)
    }

    /// A gesture starts: its layout, fixed until it ends.
    mutating func gestureBegan(overrides: [String: FieldLayout], geometry: FieldGeometry,
                               parameters: FieldLayoutParameters = .standard) -> FieldLayout {
        let chosen = layout(overrides: overrides, geometry: geometry, parameters: parameters)
        gestureLayout = chosen
        return chosen
    }

    mutating func gestureEnded() {
        gestureLayout = nil
    }

    /// What the menu shows: the running gesture's layout, else the one the next gesture will use.
    func displayedLayout(overrides: [String: FieldLayout], geometry: FieldGeometry,
                         parameters: FieldLayoutParameters = .standard) -> FieldLayout {
        gestureLayout ?? layout(overrides: overrides, geometry: geometry, parameters: parameters)
    }

    /// The overrides a manual switch to `chosen` writes: none without a real reading.
    func choiceEntries(_ chosen: FieldLayout) -> [String: FieldLayout] {
        guard let fingerprint else { return [:] }
        return FieldLayoutChooser.choiceEntries(for: fingerprint, layout: chosen)
    }
}
