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
