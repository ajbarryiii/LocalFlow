import Foundation

/// How the session's Live Activity moves when its phase changes (ARCHITECTURE.md, "Live Activity"): one quick spring, a
/// little give in what arrives (the trailing side growing out of the island's edge, the recording dot popping in, the
/// mark's dot swelling while recording, lit dots a touch larger). With Reduce Motion every change is opacity only:
/// nothing grows, shrinks or slides, and the strip's shape shows in brightness alone (Sol, round 8). Nothing animates in
/// Always On. Pure.
enum SessionActivityMotion {
    /// How a view arrives and leaves.
    enum Handover: Equatable, Sendable {
        case fade
        /// Pushed up from below as it fades in (words).
        case push
        /// Grown from `scale` of its size as it fades in.
        case scale(from: Double)
    }

    /// Changed words: pushed up, or a cross-fade.
    static func words(_ reduceMotion: Bool) -> Handover { reduceMotion ? .fade : .push }

    /// The compact island's trailing strip as the timer replaces it, and back.
    static func compactTrailing(_ reduceMotion: Bool) -> Handover { reduceMotion ? .fade : .scale(from: 0.8) }

    /// The minimal island's recording dot.
    static func minimalDot(_ reduceMotion: Bool) -> Handover { reduceMotion ? .fade : .scale(from: 0.4) }

    /// The mark's dot: a little larger while recording.
    static func markDotScale(phase: SessionActivityState.Phase, isStale: Bool, reduceMotion: Bool) -> Double {
        phase == .recording && !isStale && !reduceMotion ? 1.3 : 1
    }

    /// A strip dot's size, as a share of its place, for how lit it is (0 to 1): lit dots a touch larger.
    static func dotScale(lit: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : 0.5 + 0.5 * min(max(lit.isNaN ? 0 : lit, 0), 1)
    }

    /// The phase change's spring, in seconds; none in Always On.
    static func duration(luminanceReduced: Bool) -> Double? { luminanceReduced ? nil : 0.28 }
}

extension SessionActivityState {
    /// The words around a ready session's countdown, which the keyboard's bar and menu share
    /// ("Session ends in 2 min if idle"; on the Lock Screen "Session ends in 2:15 if idle").
    static let countdownLead = "ends in"
    static let countdownTail = "if idle"
}
