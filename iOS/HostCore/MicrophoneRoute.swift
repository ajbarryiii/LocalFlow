import Foundation

/// The kind of audio input in use, mirrored from `AVAudioSession.Port` so the decisions stay
/// Foundation-only. Content-free: Home shows its label.
enum InputPortKind: String, CaseIterable, Sendable {
    case builtInMic, bluetooth, headset, usb, other

    var label: String {
        switch self {
        case .builtInMic: return "iPhone microphone"
        case .bluetooth: return "Bluetooth"
        case .headset: return "Headset"
        case .usb: return "USB"
        case .other: return "Other"
        }
    }
}

/// "Use iPhone microphone" (contract: "Microphone choice"). With it on, the session never enables the
/// Bluetooth hands-free profile, so headphones stay in high-quality A2DP playback without its added
/// latency, and the built-in microphone is preferred over any headset or USB microphone. With it off,
/// the system chooses the input, Bluetooth hands-free included. Pure.
enum MicrophoneRoute {
    /// `AVAudioSession.CategoryOptions` of the `.playAndRecord` session, mirrored.
    enum CategoryOption: String, CaseIterable, Sendable {
        case mixWithOthers, defaultToSpeaker, allowBluetoothA2DP, allowBluetoothHFP
    }

    static let defaultUseBuiltInMicrophone = true

    static func categoryOptions(useBuiltInMicrophone: Bool) -> Set<CategoryOption> {
        // `.defaultToSpeaker` keeps other apps' audio on the speaker instead of the earpiece either way.
        useBuiltInMicrophone
            ? [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            : [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
    }

    /// The input to prefer, or nil to clear any preference and let the system choose. Without a
    /// built-in microphone in `availableInputs`, the system chooses too.
    static func preferredInput(useBuiltInMicrophone: Bool, availableInputs: [InputPortKind]) -> InputPortKind? {
        useBuiltInMicrophone && availableInputs.contains(.builtInMic) ? .builtInMic : nil
    }

    /// After a route change (headphones plugged in or out, AirPods connecting): whether the preference
    /// must be set again because the system moved the input away from the built-in microphone. Asking
    /// only then keeps the re-assertion, which itself changes the route, from repeating.
    static func needsReassertion(useBuiltInMicrophone: Bool, currentInput: InputPortKind?,
                                 availableInputs: [InputPortKind]) -> Bool {
        guard preferredInput(useBuiltInMicrophone: useBuiltInMicrophone, availableInputs: availableInputs) != nil
        else { return false }
        return currentInput != .builtInMic
    }
}

/// The audio session as `MicrophoneRouter` needs it: `AVAudioSession` in the app, a fake in tests.
@MainActor
protocol AudioRouteSession: AnyObject {
    var availableInputs: [InputPortKind] { get }
    var currentInput: InputPortKind? { get }
    func setCategoryOptions(_ options: Set<MicrophoneRoute.CategoryOption>) throws
    /// Prefers an input of `kind`, or clears the preference when nil.
    func setPreferredInput(_ kind: InputPortKind?)
}

/// Keeps the user's desired microphone choice apart from the choice the active audio session was
/// configured with. Route changes re-assert only the applied choice, so a change that has not been
/// applied yet (one deferred because it arrived in the background) never mixes a new preferred input
/// with the old category options. The desired choice takes effect at the next session start or
/// foreground reconfiguration.
@MainActor
final class MicrophoneRouter {
    /// What the user asked for; stored, not yet necessarily in effect.
    private(set) var desired: Bool
    /// What the active session was configured with; nil while no session is configured.
    private(set) var applied: Bool?

    init(desired: Bool = MicrophoneRoute.defaultUseBuiltInMicrophone) {
        self.desired = desired
    }

    /// The active session was configured with another choice than the one now desired.
    var needsReconfiguration: Bool { applied.map { $0 != desired } ?? false }

    /// Records the choice only. Nothing about the session changes until `configure` runs.
    func setDesired(_ value: Bool) {
        desired = value
    }

    /// Session start or foreground reconfiguration: the desired choice becomes the applied one, category
    /// options first. Call `applyInput` once the session is active.
    func configureCategory(_ session: AudioRouteSession) throws {
        try session.setCategoryOptions(MicrophoneRoute.categoryOptions(useBuiltInMicrophone: desired))
        applied = desired
    }

    /// Prefers the built-in microphone under the applied choice, or clears any preference.
    func applyInput(_ session: AudioRouteSession) {
        guard let applied else { return }
        session.setPreferredInput(MicrophoneRoute.preferredInput(useBuiltInMicrophone: applied,
                                                                 availableInputs: session.availableInputs))
    }

    /// A route change: re-asserts the built-in microphone if the applied choice wants it and the system
    /// moved the input away. Returns whether it did.
    @discardableResult
    func routeChanged(_ session: AudioRouteSession) -> Bool {
        guard let applied, MicrophoneRoute.needsReassertion(useBuiltInMicrophone: applied, currentInput: session.currentInput,
                                                            availableInputs: session.availableInputs) else { return false }
        session.setPreferredInput(.builtInMic)
        return true
    }

    /// The session ended or was lost: nothing is applied any more.
    func sessionEnded() {
        applied = nil
    }
}
