import Foundation

/// A corrector parameter the user can override in Diagnostics (ARCHITECTURE.md, "Word autocorrect",
/// Settings): its name in the bundle and in the setting's key (`autocorrectParam.<name>`), and the values
/// an override may take. Values are in `AutocorrectParams` units: `logOOV` a natural log, margins posterior
/// odds, `shortLength` letters.
enum AutocorrectSetting: String, CaseIterable, Sendable {
    case logOOV = "log_oov"
    case marginOOV = "margin_oov"
    case marginKnown = "margin_known"
    case marginApostrophe = "margin_apostrophe"
    case lmWeight = "lm_weight"
    case pOmit = "p_omit"
    case pInsert = "p_insert"
    case pTranspose = "p_transpose"
    case wRepeat = "w_repeat"
    case wSlip = "w_slip"
    case shortLength = "short_length"

    /// The accepted finite values: `log_oov` from 1e-10 to 1e-1, `margin_oov` 1–30, the other margins
    /// 1–1000, `lm_weight` 0.25–2, the edit probabilities 0.001–0.1, the insertion weights 0–1 (summing to
    /// at most 1 once merged) and `short_length` 3–5.
    var range: ClosedRange<Double> {
        switch self {
        case .logOOV: return log(1e-10) ... log(1e-1)
        case .marginOOV: return 1 ... 30
        case .marginKnown, .marginApostrophe: return 1 ... 1000
        case .lmWeight: return 0.25 ... 2
        case .pOmit, .pInsert, .pTranspose: return 0.001 ... 0.1
        case .wRepeat, .wSlip: return 0 ... 1
        case .shortLength: return 3 ... 5
        }
    }

    /// Whether an override may be infinite (never replace): the known-word and apostrophe margins.
    var allowsInfinity: Bool { self == .marginKnown || self == .marginApostrophe }

    /// Whether only whole numbers are accepted.
    var isInteger: Bool { self == .shortLength }

    /// Whether `value` is an accepted override.
    func accepts(_ value: Double) -> Bool {
        if value == .infinity { return allowsInfinity }
        guard value.isFinite, range.contains(value) else { return false }
        return !isInteger || value == value.rounded()
    }

    func value(in params: AutocorrectParams) -> Double {
        switch self {
        case .logOOV: return params.logOOV
        case .marginOOV: return params.marginOOV
        case .marginKnown: return params.marginKnown
        case .marginApostrophe: return params.marginApostrophe
        case .lmWeight: return params.lmWeight
        case .pOmit: return params.pOmit
        case .pInsert: return params.pInsert
        case .pTranspose: return params.pTranspose
        case .wRepeat: return params.wRepeat
        case .wSlip: return params.wSlip
        case .shortLength: return Double(params.shortLength)
        }
    }

    /// Sets the value as given (callers check `accepts`); `shortLength` takes the nearest whole number.
    func set(_ value: Double, in params: inout AutocorrectParams) {
        switch self {
        case .logOOV: params.logOOV = value
        case .marginOOV: params.marginOOV = value
        case .marginKnown: params.marginKnown = value
        case .marginApostrophe: params.marginApostrophe = value
        case .lmWeight: params.lmWeight = value
        case .pOmit: params.pOmit = value
        case .pInsert: params.pInsert = value
        case .pTranspose: params.pTranspose = value
        case .wRepeat: params.wRepeat = value
        case .wSlip: params.wSlip = value
        case .shortLength: params.shortLength = Int(value.rounded())
        }
    }
}
