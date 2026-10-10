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
}

/// The audio session as `MicrophoneRouter` needs it: `AVAudioSession` in the app, a fake in tests.
@MainActor
protocol AudioRouteSession: AnyObject {
    var availableInputs: [InputPortKind] { get }
    var currentInput: InputPortKind? { get }
    func setCategoryOptions(_ options: Set<MicrophoneRoute.CategoryOption>) throws
    /// Requests an input of `kind`, or clears the preference when nil. Only a request: iOS may change the
    /// route later (reported by a route change) or not at all, so the effect is read from `currentInput`.
    func setPreferredInput(_ kind: InputPortKind?) throws
}

/// Whether the built-in microphone choice is in effect. Content-free; Home shows `problem`.
enum MicrophoneRouting: Equatable, Sendable {
    /// No session, or the system chooses the input (the choice is off): nothing to resolve.
    case systemChoice
    /// The built-in microphone is the input.
    case builtInMicrophone
    /// The built-in microphone was requested and iOS has not answered yet.
    case awaitingRoute
    /// The built-in microphone could not be selected; `input` is in use instead (nil: no input).
    case unresolved(InputPortKind?)

    /// A status for Home when the choice could not be honored. Dictation goes on with the other input.
    var problem: String? {
        guard case .unresolved(let input) = self else { return nil }
        let using: String
        switch input {
        case .headset?: using = "Using headset microphone"
        case .bluetooth?: using = "Using Bluetooth microphone"
        case .usb?: using = "Using USB microphone"
        case .other?, .builtInMic?: using = "Using another microphone"
        case nil: using = "No microphone available"
        }
        return "\(using): couldn't switch to iPhone microphone"
    }
}

/// Keeps the user's desired microphone choice apart from the choice the active audio session was
/// configured with, and tracks whether the built-in microphone actually became the input.
///
/// Route changes act only on the applied choice, so a change that has not been applied yet (one
/// deferred because it arrived in the background) never mixes a new preferred input with the old
/// category options. The desired choice takes effect at the next session start or foreground
/// reconfiguration.
///
/// `setPreferredInput` is a request: it can fail, take effect later, or silently not take effect. The
/// route is therefore read back after each request (at once, at the next route change, and at
/// `verify` after `requestSettleTime`); a request that does not take is `unresolved`, shown in Home, and
/// retried at the next route change from elsewhere. The route change that answers the router's own
/// request never triggers another one, so an unsatisfiable request cannot loop.
@MainActor
final class MicrophoneRouter {
    /// How long to wait for iOS to report the route after a request before calling it unresolved.
    static let requestSettleTime: TimeInterval = 1

    /// What the user asked for; stored, not yet necessarily in effect.
    private(set) var desired: Bool
    /// What the active session was configured with; nil while no session is configured.
    private(set) var applied: Bool?
    private(set) var routing = MicrophoneRouting.systemChoice
    /// Increases with every request, so a delayed `verify` checks only the request it was made for.
    private(set) var requestID = 0
    private var outstanding = false

    init(desired: Bool = MicrophoneRoute.defaultUseBuiltInMicrophone) {
        self.desired = desired
    }

    /// The active session was configured with another choice than the one now desired.
    var needsReconfiguration: Bool { applied.map { $0 != desired } ?? false }

    /// Records the choice only. Nothing about the session changes until `configureCategory` runs.
    func setDesired(_ value: Bool) {
        desired = value
    }

    /// Session start or foreground reconfiguration: the desired choice becomes the applied one, category
    /// options first. Call `applyInput` once the session is active.
    func configureCategory(_ session: AudioRouteSession) throws {
        try session.setCategoryOptions(MicrophoneRoute.categoryOptions(useBuiltInMicrophone: desired))
        applied = desired
    }

    /// Requests the built-in microphone under the applied choice, or clears any preference. Returns
    /// whether a request now awaits the route (schedule `verify` after `requestSettleTime`).
    @discardableResult
    func applyInput(_ session: AudioRouteSession) -> Bool {
        guard let applied else { return false }
        guard applied else {
            // With the choice off the system chooses. A clearing that fails leaves at most the built-in
            // preference behind, the safe default, so it does not count as unresolved.
            try? session.setPreferredInput(nil)
            outstanding = false
            routing = .systemChoice
            return false
        }
        return request(session)
    }

    /// A route change. On the built-in microphone, the choice is satisfied. Otherwise, the answer to the
    /// router's own request means it did not take (unresolved, no new request); any other change
    /// (headphones plugged in, AirPods connecting, a later change after an unresolved request) requests
    /// the built-in microphone again. Returns whether a request now awaits iOS (schedule `verify`).
    @discardableResult
    func routeChanged(_ session: AudioRouteSession) -> Bool {
        guard let applied else { return false }
        guard applied else {
            routing = .systemChoice
            return false
        }
        let current = session.currentInput
        if current == .builtInMic {
            outstanding = false
            routing = .builtInMicrophone
            return false
        }
        if outstanding {
            outstanding = false
            routing = .unresolved(current)
            return false
        }
        return request(session)
    }

    /// The delayed check after request `requestID`, for when iOS reports no route change at all.
    func verify(_ session: AudioRouteSession, requestID: Int) {
        guard applied == true, outstanding, requestID == self.requestID else { return }
        outstanding = false
        routing = session.currentInput == .builtInMic ? .builtInMicrophone : .unresolved(session.currentInput)
    }

    /// The session ended or was lost: nothing is applied any more.
    func sessionEnded() {
        applied = nil
        outstanding = false
        routing = .systemChoice
    }

    private func request(_ session: AudioRouteSession) -> Bool {
        let current = session.currentInput
        guard MicrophoneRoute.preferredInput(useBuiltInMicrophone: true, availableInputs: session.availableInputs) != nil else {
            outstanding = false
            routing = current == .builtInMic ? .builtInMicrophone : .unresolved(current)
            return false
        }
        requestID += 1
        do {
            try session.setPreferredInput(.builtInMic)
        } catch {
            outstanding = false
            routing = .unresolved(current)
            return false
        }
        if session.currentInput == .builtInMic {
            outstanding = false
            routing = .builtInMicrophone
            return false
        }
        outstanding = true
        routing = .awaitingRoute
        return true
    }
}
