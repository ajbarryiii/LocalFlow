import AppIntents

/// What the session control's intent does once the host has acted (ARCHITECTURE.md, "Session control").
enum SessionControlStep: Sendable {
    /// The session ended or started.
    case done
    /// The start needs the app in front.
    case continueInForeground
    /// The build cannot run a session (it is misconfigured).
    case unavailable
}

/// The host side of the session control: `HostSessionController`, in the app only.
@MainActor
protocol SessionControlHandling: AnyObject {
    func toggleSessionFromControl() async -> SessionControlStep
    /// The intent could not continue in the foreground.
    func controlForegroundDeclined()
}

/// The session control's action (ARCHITECTURE.md, "Session control"): starts a Flow session, or ends the one
/// running, without opening the app. An `AudioRecordingIntent` may start the microphone in the background, and as a
/// `LiveActivityIntent` iOS runs it in the app's process, where it may start the session's Live Activity. Compiled
/// into the app, which performs it, and the widget extension, whose control names it.
struct ToggleFlowSessionIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Flow Session"
    /// On a locked iPhone, iOS asks for Face ID or the passcode first: the control never starts a session while locked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    /// Set by the app as it launches; never in the extension, where `perform` throws.
    @MainActor static var handler: SessionControlHandling?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = Self.handler else { throw SessionControlUnavailable() }
        switch await handler.toggleSessionFromControl() {
        case .done:
            return .result()
        case .unavailable:
            throw SessionControlUnavailable()
        case .continueInForeground:
            do {
                try await continueInForeground(nil, alwaysConfirm: false)
            } catch {
                handler.controlForegroundDeclined()
                throw error
            }
            return .result()
        }
    }
}

/// The intent ran where no session can start: in the extension, or in a misconfigured build.
struct SessionControlUnavailable: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Open LocalFlow to start a session." }
}
