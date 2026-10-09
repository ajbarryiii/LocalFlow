import Foundation
import SwiftUI
import UIKit

/// Owns the host side for the app's lifetime: the session core (HostCore), the microphone, the model
/// runtime, the timer, the `.intent` observation and the UIKit lifecycle events. It mirrors the core's
/// state into SwiftUI and decides when the bounce screen shows.
@MainActor
final class HostSessionController: ObservableObject {
    static let shared = HostSessionController()

    @Published private(set) var session: HostStatus.Session = .inactive
    @Published private(set) var sessionExpiresAt: Date?
    @Published private(set) var sessionError: HostErrorCode?
    @Published private(set) var dictation: DictationStatus?
    @Published private(set) var level: Float = 0
    @Published private(set) var isDictationInProgress = false
    /// The current capture configuration, requested against granted, for Diagnostics. Content-free.
    @Published private(set) var captureConfiguration: CaptureConfiguration?
    /// The input in use while capturing, nil otherwise. Content-free; Home shows `currentInput?.label`.
    @Published private(set) var currentInput: InputPortKind?
    /// The bounce screen: a dictation was admitted while the app was in front (outside "Try it").
    @Published var bounceVisible = false
    /// "Try it" has the keyboard in this app, so an admission there must not cover it.
    var tryItVisible = false

    let configuration: LocalFlowConfiguration?
    let preferences = AppPreferences()
    let settings: SharedSettingsModel
    let transcriber: ParakeetTranscriber
    /// Nil when the build is misconfigured (missing identifiers or App Group).
    let core: HostSessionCore?
    private let store: SharedDictationStore?
    private var timer: Timer?
    private var intentObservation: DarwinNotifier.Observation?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastAdmittedRequestID: UUID?
    private var hapticRequestID: UUID?

    private init() {
        configuration = LocalFlowConfiguration.main
        transcriber = ParakeetTranscriber(preferences: preferences)
        let store = configuration.flatMap(SharedDictationStore.init(configuration:))
        let sharedSettings = configuration.flatMap(LocalFlowSettings.init(configuration:))
        self.store = store
        settings = SharedSettingsModel(settings: sharedSettings)
        guard let configuration, let store, let sharedSettings else {
            core = nil
            return
        }
        let buffer = DictationSampleBuffer()
        let relay = CaptureRelay()
        let deliver: @Sendable (CaptureEvent) -> Void = { relay.deliver($0) }
        #if LOCALFLOW_SELFTEST
        let synthetic = SelfTest.syntheticInput(buffer: buffer, deliver: deliver)
        #else
        let synthetic = SyntheticInputRequest.notRequested
        #endif
        // A requested synthetic input that cannot be used never falls back to the microphone.
        let capture = synthetic.capture { MicrophoneCapture(buffer: buffer, deliver: deliver) }
        let core = HostSessionCore(store: store, settings: sharedSettings, buffer: buffer, capture: capture,
                                   transcriber: transcriber.engine, notifier: DarwinNotifier(configuration: configuration),
                                   environment: Self.environment)
        self.core = core
        relay.core = core
        if let microphone = capture as? MicrophoneCapture {
            microphone.onInterruption = { [weak core] in core?.captureInterrupted() }
            microphone.onFailure = { [weak core] generation in core?.captureFailed(generation: generation) }
            microphone.onMediaServicesReset = { [weak core] in core?.captureMediaServicesReset() }
            microphone.onConfigured = { [weak self] in self?.configured($0) }
            microphone.onInputChanged = { [weak self] in self?.inputChanged($0) }
            microphone.useBuiltInMicrophone = preferences.useBuiltInMicrophone
        }
        #if LOCALFLOW_SELFTEST
        (capture as? SyntheticCapture)?.onConfigured = { [weak self] in self?.configured($0) }
        #endif
        transcriber.onStateChange = { [weak core] in core?.modelStateChanged() }
        core.onChange = { [weak self] in self?.refresh() }
    }

    /// Call once UIKit has finished launching: run recovery, the launch reconciliation, then the timer
    /// and observers.
    func launch() {
        guard let core, !core.isLaunched else { return }
        core.launch()
        let timer = Timer(timeInterval: HostSessionPolicy.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        intentObservation = configuration.map(DarwinNotifier.init(configuration:))?.observe(.intent) { [weak self] in
            self?.core?.reconcile(.intentSignal)
        }
        observeLifecycle()
        refresh()
    }

    var isConfigured: Bool { core != nil }

    // MARK: User actions

    func startSession() {
        core?.userStartSession()
    }

    func endSession() {
        core?.userEndSession()
    }

    func stopDictation() {
        core?.userStopDictation()
    }

    func cancelDictation() {
        core?.userCancelDictation()
    }

    func prepareModel() {
        transcriber.prepare()
    }

    /// Diagnostics: frees the runtime now, to measure a cold preparation.
    func releaseModel() {
        guard core?.isDictationInProgress != true else { return }
        _ = transcriber.releaseIfIdle()
    }

    /// "Use iPhone microphone". Stored now; applied at the next session start, or at once when changed in
    /// the foreground during a session (never in the background).
    func setUseBuiltInMicrophone(_ value: Bool) {
        guard value != preferences.useBuiltInMicrophone else { return }
        preferences.useBuiltInMicrophone = value
        (core?.capture as? MicrophoneCapture)?.useBuiltInMicrophone = value
        core?.captureSettingsChanged()
    }

    /// `<scheme>://dictate` is only a hint. In the foreground it runs one reconciliation pass; before the
    /// app gets there it does nothing, and the arrival reconciles. It never starts capture by itself:
    /// only a fresh record intent admitted in the foreground can.
    func open(_ url: URL) {
        guard let configuration, HostURLRoute(url: url, scheme: configuration.urlScheme) != nil else { return }
        core?.reconcile(.urlOpen)
    }

    var microphonePermission: CapturePermission { core?.capture.permission ?? .undetermined }

    /// Onboarding's request, made in the foreground only.
    func requestMicrophonePermission() async -> Bool {
        guard let capture = core?.capture, UIApplication.shared.applicationState != .background else { return false }
        return await capture.requestPermission()
    }

    /// A keyboard with Full Access was visible within `keyboardPresenceTimeout`, so setup can show it as
    /// working. A presence file that merely exists proves nothing.
    var keyboardHasFullAccess: Bool {
        store.map { HostSessionPolicy.isKeyboardConnected(presence: $0.readPresence(), now: Date()) } ?? false
    }

    // MARK: Private

    private static var environment: HostEnvironment {
        HostEnvironment(
            now: { Date() },
            isForeground: { UIApplication.shared.applicationState != .background },
            beginBackgroundTask: { onExpiration in
                let task = BackgroundTask()
                task.identifier = UIApplication.shared.beginBackgroundTask(withName: "LocalFlow transcription") {
                    MainActor.assumeIsolated { onExpiration() }
                }
                return { task.end() }
            },
            formatTranscript: { text, pressEnterEnabled, spokenDelimitersEnabled in
                let processed = LocalDictationCore.process(text, macros: [], pressEnterEnabled: pressEnterEnabled,
                                                           spokenDelimitersEnabled: spokenDelimitersEnabled)
                return (processed.output, processed.shouldPressEnter)
            })
    }

    private func inputChanged(_ input: InputPortKind?) {
        if currentInput != input { currentInput = input }
    }

    private func configured(_ configuration: CaptureConfiguration) {
        captureConfiguration = configuration
        #if LOCALFLOW_SELFTEST
        SelfTest.report(configuration)
        #endif
    }

    private func tick() {
        core?.tick()
        if dictation?.phase == .recording { refresh() }   // the level meter
    }

    private func refresh() {
        guard let core else { return }
        set(\.session, core.session)
        set(\.sessionExpiresAt, core.sessionExpiresAt)
        set(\.sessionError, core.sessionError)
        set(\.dictation, core.current)
        set(\.level, core.level)
        set(\.isDictationInProgress, core.isDictationInProgress)
        // A request admitted while the app is in front came from the bounce (the keyboard opened the
        // app), unless the keyboard is in "Try it", where a cover would hide the text field.
        if let current = core.current, core.isDictationInProgress, current.requestID != lastAdmittedRequestID {
            lastAdmittedRequestID = current.requestID
            if UIApplication.shared.applicationState != .background, !tryItVisible { bounceVisible = true }
        }
        if let current = core.current, current.phase == .recording, current.requestID != hapticRequestID {
            hapticRequestID = current.requestID
            if bounceVisible, settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HostSessionController, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (HostSessionController) -> Void) {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            })
        }
        on(UIApplication.willEnterForegroundNotification) { $0.core?.foregroundChanged() }
        // Arriving in the foreground reconciles; that is what admits a request after a URL open.
        on(UIApplication.didBecomeActiveNotification) { $0.core?.foregroundChanged() }
        on(UIApplication.didEnterBackgroundNotification) {
            $0.core?.foregroundChanged()
            if $0.core?.isDictationInProgress != true { $0.bounceVisible = false }
        }
        on(UIApplication.protectedDataWillBecomeUnavailableNotification) { $0.core?.deviceWillLock() }
        on(UIApplication.didReceiveMemoryWarningNotification) { $0.core?.memoryWarning() }
    }
}

/// Forwards the capture thread's buffer outcomes to the core, which hops to main itself.
private final class CaptureRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: HostSessionCore?

    var core: HostSessionCore? {
        get { lock.lock(); defer { lock.unlock() }; return target }
        set { lock.lock(); target = newValue; lock.unlock() }
    }

    func deliver(_ event: CaptureEvent) {
        core?.captureDelivered(event)
    }
}

/// Ends a UIKit background task exactly once.
@MainActor
private final class BackgroundTask {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
