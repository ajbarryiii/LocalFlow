import Foundation

/// What the session's Live Activity shows (ARCHITECTURE.md, "Live Activity"): the Flow session's phase and the dates
/// its timers need, never any text or audio. It is the activity's content state, so it shows on the Lock Screen and
/// in the Dynamic Island. Compiled into the app, the activity extension and the host tests.
struct SessionActivityState: Codable, Hashable, Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        /// The session is listening for the keyboard; `endsAt` is its idle expiry.
        case ready
        /// A dictation is recording; `since` is when it was admitted.
        case recording
        /// The transcript is being made.
        case transcribing
        /// Stopped, and waiting for the model to finish preparing before transcribing.
        case preparing
    }

    var phase: Phase
    /// `ready`: when the session ends if nothing is dictated (the "ends in" countdown).
    var endsAt: Date?
    /// `recording`: when the recording started (the live timer).
    var since: Date?
}
