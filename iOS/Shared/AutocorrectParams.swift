import Foundation

/// The word corrector's parameters (ARCHITECTURE.md, "Word autocorrect"; reference: localflow-swipe
/// `tap/autocorrect.py` `Params`, the same names in snake case in the bundle's presets). Probabilities are
/// per letter; margins are posterior odds, `.infinity` never replaces; `logOOV` is a natural log.
struct AutocorrectParams: Equatable, Sendable {
    var pOmit = 0.01
    var pInsert = 0.01
    var pTranspose = 0.005
    var maxEdits = 2
    var maxEditsShort = 1
    var shortLength = 4
    var minLength = 2
    var lmWeight = 1.0
    var logOOV = log(1e-3)
    var marginOOV = 3.0
    var marginKnown = Double.infinity
    var marginApostrophe = Double.infinity
    var wRepeat = 0.5
    var wSlip = 0.3

    static let standard = AutocorrectParams()
}
