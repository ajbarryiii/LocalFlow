import Foundation

enum CapturePermission: Equatable, Sendable { case undetermined, denied, granted }

/// The session's audio input: `MicrophoneCapture` in the app, a synthetic source in self-test builds and
/// a fake in tests. It appends to the session's `DictationSampleBuffer` from its own thread and reports
/// the buffer's outcomes through `HostSessionCore.captureDelivered(_:)`.
@MainActor
protocol HostCapture: AnyObject {
    var permission: CapturePermission { get }
    /// Shows the system prompt; call only in the foreground.
    func requestPermission() async -> Bool
    /// Activates audio and starts delivering buffers; call only in the foreground.
    func start() throws
    /// Stops the engine and deactivates audio. Idempotent.
    func stop()
    var isRunning: Bool { get }
    /// When the latest input buffer arrived, whether or not it was kept.
    var lastBufferAt: Date? { get }
}

/// The host-owned model runtime.
@MainActor
protocol HostTranscriber: AnyObject {
    var modelState: HostStatus.Model { get }
    /// Starts preparing unless the model is ready or already preparing.
    func prepare()
    /// Waits for readiness, then transcribes 16 kHz mono samples. Throws `TranscriptionFailure` or
    /// `CancellationError`.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Releases the model runtime unless it is preparing or transcribing.
    func releaseIfIdle()
}

/// Platform hooks, injected so the core stays Foundation-only and testable.
struct HostEnvironment {
    var now: @MainActor () -> Date
    /// The app is in the foreground (active or inactive), where capture may start.
    var isForeground: @MainActor () -> Bool
    /// Begins a UIKit background task. `onExpiration` runs on main when time runs out; the returned
    /// closure ends the task, and the core calls it exactly once.
    var beginBackgroundTask: @MainActor (_ onExpiration: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    /// `LocalDictationCore.process`, which is compiled into the app only.
    var formatTranscript: @MainActor (_ text: String, _ pressEnterEnabled: Bool, _ spokenDelimitersEnabled: Bool)
        -> (text: String, pressEnter: Bool)
}

/// The host side of the protocol: session lifecycle, idle expiry, reconciliation, run recovery,
/// watchdog, transcription and status publishing. `HostSessionController` (App) drives it from timers,
/// Darwin notifications and UIKit events and mirrors its state into SwiftUI.
///
/// Every asynchronous completion carries a `DictationTicket` or session generation and is dropped
/// unless it is still current. Status is written after every change, and on the cadence of
/// `HostSessionPolicy` while live.
@MainActor
final class HostSessionCore {
    let hostRunID: UUID
    let store: SharedDictationStore
    let settings: LocalFlowSettings
    let buffer: DictationSampleBuffer
    let capture: HostCapture
    let transcriber: HostTranscriber
    private let notifier: DarwinNotifier?
    private let environment: HostEnvironment

    private(set) var isLaunched = false
    private(set) var session: HostStatus.Session = .inactive
    private(set) var sessionID: UUID?
    /// The most recent session-level error; cleared when a session starts.
    private(set) var sessionError: HostErrorCode?
    private(set) var slot: HostDictationSlot
    private(set) var knownRequestIDs = RecentRequestIDs()
    /// Idle expiry counts from here; nil while a dictation is in progress or no session is active.
    private(set) var idleSince: Date?
    private(set) var lastForegroundAt: Date?
    private(set) var hasBeenForeground = false

    private var sessionGeneration: UInt64 = 0
    /// A session start waiting for the app to reach the foreground (a URL open during launch).
    private var pendingStart: UInt64?
    private var transcription: Transcription?
    private var needsPublish = false
    private var lastStatusAt: Date?
    private var lastPurgeAt: Date?
    private var lastReconcileAt: Date?
    private var captureStoppedSince: Date?

    /// Runs after every status write, for the UI.
    var onChange: (@MainActor () -> Void)?
    /// Sees every status written, in order.
    var onPublish: (@MainActor (HostStatus) -> Void)?

    private struct Transcription {
        let ticket: DictationTicket
        let task: Task<Void, Never>
        let endBackgroundTask: OnceAction
    }

    init(hostRunID: UUID = UUID(), store: SharedDictationStore, settings: LocalFlowSettings,
         buffer: DictationSampleBuffer, capture: HostCapture, transcriber: HostTranscriber,
         notifier: DarwinNotifier?, environment: HostEnvironment) {
        self.hostRunID = hostRunID
        self.store = store
        self.settings = settings
        self.buffer = buffer
        self.capture = capture
        self.transcriber = transcriber
        self.notifier = notifier
        self.environment = environment
        slot = HostDictationSlot(hostRunID: hostRunID)
    }

    // MARK: State for the UI

    var current: DictationStatus? { slot.current }
    var isDictationInProgress: Bool { slot.isInProgress }
    var level: Float { slot.phase == .recording ? buffer.level : 0 }
    var sessionExpiresAt: Date? {
        HostSessionPolicy.sessionExpiresAt(session: session, idleSince: idleSince, duration: settings.sessionDuration)
    }

    // MARK: Inputs

    /// Run recovery, then the launch reconciliation. Call once, after UIKit has finished launching.
    func launch() {
        guard !isLaunched else { return }
        isLaunched = true
        let now = environment.now()
        // Before this run writes anything: a staging file left by a crash mid-write may hold a transcript.
        store.purgeStagingFiles(olderThan: 0, now: now)
        let recovery = HostRunRecovery(previous: store.readStatus(), hostRunID: hostRunID, now: now)
        slot = HostDictationSlot(hostRunID: hostRunID, recovered: recovery.current)
        for id in recovery.knownRequestIDs { knownRequestIDs.insert(id) }
        let run = hostRunID
        store.purgeResults { _, read in HostRunRecovery.isFromAnotherRun(read, hostRunID: run) }
        store.purgeExpiredResults(now: now)
        lastPurgeAt = now
        // The previous run's interrupted request is published before anything is reconciled.
        needsPublish = true
        flush(now)
        noteForeground(now)
        reconcilePass(.launch, now)
        flush(now)
    }

    func reconcile(_ trigger: ReconcileTrigger) {
        guard isLaunched else { return }
        let now = environment.now()
        noteForeground(now)
        if trigger == .urlOpen { hasBeenForeground = true }
        reconcilePass(trigger, now)
        flush(now)
    }

    /// The controller's timer, every `HostSessionPolicy.tickInterval`.
    func tick() {
        guard isLaunched else { return }
        let now = environment.now()
        let foreground = noteForeground(now)
        if let current = slot.current, current.phase == .starting || current.phase == .recording {
            if let reason = HostWatchdog.stopReason(current: current, presence: store.readPresence(),
                                                    isForeground: foreground, lastForegroundAt: lastForegroundAt, now: now) {
                endInProgress(HostSessionPolicy.watchdogOutcome(reason), now)
            } else if current.phase == .recording, buffer.hasReachedLimit {
                finish(current.requestID, now)   // normally reported by the tap; this is the backstop
            }
        }
        // A deferred start nobody is waiting for any more (its request timed out) is abandoned.
        if pendingStart != nil, !slot.isInProgress { endSession(.startFailed(.audioSessionFailed), now) }
        if session == .active, !capture.isRunning {
            let since = captureStoppedSince ?? now
            captureStoppedSince = since
            let stalled = now.timeIntervalSince(since)
            if stalled < 0 || stalled >= HostSessionPolicy.captureStallGrace { recoverCapture(now) }
        } else {
            captureStoppedSince = nil
        }
        if session == .active, !slot.isInProgress,
           HostSessionPolicy.isIdleExpired(idleSince: idleSince, duration: settings.sessionDuration, now: now) {
            endSession(.idleExpired, now)
        }
        let live = session != .inactive || foreground || slot.isInProgress
        if session != .inactive || foreground,
           HostSessionPolicy.isDue(last: lastReconcileAt, interval: HostSessionPolicy.reconcileInterval, now: now) {
            reconcilePass(.poll, now)
        }
        if live, HostSessionPolicy.isDue(last: lastPurgeAt, interval: DictationProtocol.heartbeatInterval, now: now) {
            store.purgeExpiredResults(now: now)
            lastPurgeAt = now
        }
        if live, HostSessionPolicy.isDue(last: lastStatusAt, interval: HostSessionPolicy.statusInterval(for: slot.current),
                                         now: now) {
            needsPublish = true
        }
        flush(now)
    }

    /// Scene or application state changed.
    func foregroundChanged() {
        guard isLaunched else { return }
        let now = environment.now()
        if noteForeground(now), let pending = pendingStart { continueSessionStart(pending, now) }
        needsPublish = true
        flush(now)
    }

    func userStartSession() {
        guard isLaunched, session == .inactive else { return }
        let now = environment.now()
        guard noteForeground(now) else { return }
        startSession(now)
        flush(now)
    }

    func userEndSession() {
        let now = environment.now()
        endSession(.user, now)
        flush(now)
    }

    /// The bounce screen's Stop: transcribe what was recorded.
    func userStopDictation() {
        guard let ticket = slot.ticket else { return }
        let now = environment.now()
        switch slot.phase {
        case .recording?: finish(ticket.requestID, now)
        case .starting?: endInProgress(.cancelled, now)
        default: break
        }
        flush(now)
    }

    func userCancelDictation() {
        let now = environment.now()
        endInProgress(.cancelled, now)
        flush(now)
    }

    /// `protectedDataWillBecomeUnavailable`: cancels everything in flight, including a transcription
    /// that outlived its session, and ends the session.
    func deviceWillLock() {
        let now = environment.now()
        if let phase = slot.phase, slot.isInProgress,
           let outcome = HostSessionPolicy.sessionEndOutcome(.deviceLocked, phase: phase) {
            endInProgress(outcome, now)
        }
        endSession(.deviceLocked, now)
        flush(now)
    }

    func captureInterrupted() {
        let now = environment.now()
        endSession(.interrupted, now)
        flush(now)
    }

    /// The engine stopped, its configuration changed, or media services were reset.
    func captureFailed() {
        let now = environment.now()
        recoverCapture(now)
        flush(now)
    }

    /// The transcriber's model state changed. Published on the next turn, so a change made in the middle
    /// of a transition (preparation starts inside `startSession`) never publishes a half-applied state.
    func modelStateChanged() {
        needsPublish = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flush(self.environment.now())
            }
        }
    }

    func memoryWarning() {
        guard !slot.isInProgress else { return }
        transcriber.releaseIfIdle()
        needsPublish = true
        flush(environment.now())
    }

    /// Called by the capture on its own thread with every `DictationSampleBuffer.append` outcome.
    nonisolated func captureDelivered(_ outcome: DictationSampleBuffer.AppendOutcome) {
        switch outcome {
        case .dropped, .accepted:
            return
        case .started(let generation):
            DispatchQueue.main.async { MainActor.assumeIsolated { self.recordingStarted(generation: generation) } }
        case .reachedLimit(let generation):
            DispatchQueue.main.async { MainActor.assumeIsolated { self.recordingReachedLimit(generation: generation) } }
        }
    }

    // MARK: Reconciliation

    private func reconcilePass(_ trigger: ReconcileTrigger, _ now: Date) {
        lastReconcileAt = now
        guard let isForeground = HostSessionPolicy.reconcileForeground(
            trigger: trigger, isForeground: environment.isForeground(), hasBeenForeground: hasBeenForeground) else { return }
        let intent = store.readIntent()
        switch HostReconciler.action(intent: intent, current: slot.current, knownRequestIDs: knownRequestIDs.set,
                                     isForeground: isForeground, sessionActive: session == .active, now: now) {
        case .none:
            break
        case .start(let requestID):
            admit(requestID, now)
        case .finish(let requestID):
            finish(requestID, now)
        case .cancel(let requestID):
            guard slot.ticket?.requestID == requestID else { break }
            endInProgress(HostSessionPolicy.cancelOutcome(intentAction: intent.value?.action), now)
        case .reject(let requestID, let code):
            knownRequestIDs.insert(requestID)
            if slot.reject(requestID, error: code, now: now) { needsPublish = true }
        }
    }

    private func admit(_ requestID: UUID, _ now: Date) {
        // The newest request wins; the old one's outcome is discarded by the fence.
        endInProgress(.cancelled(.superseded), now)
        knownRequestIDs.insert(requestID)
        let ticket = slot.admit(requestID, generation: buffer.begin(requestID: requestID), now: now)
        idleSince = nil
        needsPublish = true
        if transcriber.modelState == .unavailable {
            buffer.cancel(requestID: requestID)
            slot.end(ticket, .failed, error: .modelUnavailable, now: now)
            dictationEnded(now)
        } else if session == .inactive {
            startSession(now)
        }
    }

    private func finish(_ requestID: UUID, _ now: Date) {
        guard let ticket = slot.ticket, ticket.requestID == requestID, slot.phase == .recording else { return }
        guard let samples = buffer.finish(requestID: requestID), slot.markTranscribing(ticket, now: now) else {
            endInProgress(.failed(.notRecording), now)
            return
        }
        needsPublish = true
        transcribe(samples, ticket)
    }

    /// Ends the request in progress, if any: stops its recording or transcription and publishes `outcome`.
    @discardableResult
    private func endInProgress(_ outcome: DictationOutcome, _ now: Date) -> Bool {
        guard let ticket = slot.ticket else { return false }
        buffer.cancel(requestID: ticket.requestID)
        if let transcription, transcription.ticket == ticket {
            transcription.task.cancel()
            transcription.endBackgroundTask.run()
            self.transcription = nil
        }
        slot.end(ticket, outcome.phase, error: outcome.error, now: now)
        dictationEnded(now)
        return true
    }

    private func dictationEnded(_ now: Date) {
        idleSince = session == .active ? now : nil
        needsPublish = true
    }

    // MARK: Recording

    private func recordingStarted(generation: UInt64) {
        let now = environment.now()
        guard slot.markRecording(generation: generation, now: now) else { return }
        needsPublish = true
        flush(now)
    }

    private func recordingReachedLimit(generation: UInt64) {
        guard let ticket = slot.ticket, ticket.generation == generation else { return }
        let now = environment.now()
        _ = slot.markRecording(generation: generation, now: now)   // the limit can arrive with the first buffer
        finish(ticket.requestID, now)
        flush(now)
    }

    // MARK: Transcription

    private func transcribe(_ samples: [Float], _ ticket: DictationTicket) {
        let endBackgroundTask = OnceAction()
        endBackgroundTask.action = environment.beginBackgroundTask { [weak self] in
            self?.backgroundTimeExpired(ticket)
            endBackgroundTask.run()
        }
        let transcriber = self.transcriber
        let task = Task { [weak self] in
            let outcome: Result<String, Error>
            do { outcome = .success(try await transcriber.transcribe(samples)) } catch { outcome = .failure(error) }
            self?.transcriptionFinished(ticket, outcome)
            endBackgroundTask.run()
        }
        transcription = Transcription(ticket: ticket, task: task, endBackgroundTask: endBackgroundTask)
    }

    private func transcriptionFinished(_ ticket: DictationTicket, _ outcome: Result<String, Error>) {
        if transcription?.ticket == ticket { transcription = nil }
        // Superseded, cancelled or expired meanwhile: the outcome is discarded.
        guard slot.isCurrent(ticket), slot.phase == .transcribing else { return }
        let now = environment.now()
        switch outcome {
        case .success(let text):
            let formatted = environment.formatTranscript(text, settings.pressEnterEnabled, settings.spokenDelimitersEnabled)
            let result = DictationResult(requestID: ticket.requestID, hostRunID: hostRunID, text: formatted.text,
                                         pressEnter: formatted.pressEnter, createdAt: now)
            do {
                // Written before `completed` is published, so a keyboard that sees completed finds it.
                try store.writeResult(result)
                notifier?.post(.result)
                slot.end(ticket, .completed, now: now)
            } catch {
                slot.end(ticket, .failed, error: .transcriptionFailed, now: now)
            }
        case .failure(let error):
            slot.end(ticket, .failed, error: (error as? TranscriptionFailure)?.errorCode ?? .transcriptionFailed, now: now)
        }
        dictationEnded(now)
        flush(now)
    }

    private func backgroundTimeExpired(_ ticket: DictationTicket) {
        guard slot.isCurrent(ticket) else { return }
        let now = environment.now()
        endInProgress(.failed(.backgroundTimeExpired), now)
        flush(now)
    }

    // MARK: Session

    private func startSession(_ now: Date) {
        guard session == .inactive else { return }
        sessionGeneration &+= 1
        session = .starting
        sessionID = UUID()
        sessionError = nil
        needsPublish = true
        transcriber.prepare()   // in parallel with audio startup; transcription waits for it
        continueSessionStart(sessionGeneration, now)
    }

    private func continueSessionStart(_ generation: UInt64, _ now: Date) {
        guard generation == sessionGeneration, session == .starting else { return }
        // Capture and the permission prompt need the foreground. A URL open can arrive just before the
        // app gets there; the start resumes on the next foreground change.
        guard environment.isForeground() else {
            pendingStart = generation
            return
        }
        pendingStart = nil
        switch capture.permission {
        case .granted:
            activateCapture(now)
        case .denied:
            endSession(.startFailed(.microphonePermissionDenied), now)
        case .undetermined:
            let capture = self.capture
            Task { [weak self] in
                let granted = await capture.requestPermission()
                guard let self, generation == self.sessionGeneration, self.session == .starting else { return }
                let now = self.environment.now()
                if !granted {
                    self.endSession(.startFailed(.microphonePermissionDenied), now)
                } else if self.environment.isForeground() {
                    self.activateCapture(now)
                } else {
                    self.pendingStart = generation
                }
                self.flush(now)
            }
        }
    }

    private func activateCapture(_ now: Date) {
        do {
            try capture.start()
        } catch {
            endSession(.startFailed(.audioSessionFailed), now)
            return
        }
        session = .active
        if !slot.isInProgress { idleSince = now }
        needsPublish = true
    }

    /// Restarts the engine in the foreground. In the background, where capture cannot start, or if the
    /// restart fails, the session ends.
    private func recoverCapture(_ now: Date) {
        guard session == .active else { return }
        captureStoppedSince = nil
        if environment.isForeground() {
            capture.stop()
            if (try? capture.start()) != nil {
                needsPublish = true
                return
            }
        }
        endSession(.engineFailed, now)
    }

    private func endSession(_ reason: SessionEndReason, _ now: Date) {
        guard session != .inactive else { return }
        sessionGeneration &+= 1
        pendingStart = nil
        if let phase = slot.phase, slot.isInProgress,
           let outcome = HostSessionPolicy.sessionEndOutcome(reason, phase: phase) {
            endInProgress(outcome, now)
        }
        capture.stop()
        // Anything still held belongs to a request that just ended; a transcription has its own copy.
        buffer.cancelAll()
        captureStoppedSince = nil
        session = .inactive
        sessionID = nil
        sessionError = HostSessionPolicy.sessionError(after: reason)
        idleSince = nil
        store.purgeExpiredResults(now: now)
        needsPublish = true
    }

    // MARK: Publishing

    @discardableResult
    private func noteForeground(_ now: Date) -> Bool {
        let foreground = environment.isForeground()
        if foreground {
            hasBeenForeground = true
            lastForegroundAt = now
        }
        return foreground
    }

    private func flush(_ now: Date) {
        guard needsPublish else { return }
        needsPublish = false
        let status = HostSessionPolicy.status(
            hostRunID: hostRunID, sessionID: sessionID, session: session, captureRunning: capture.isRunning,
            lastBufferAt: capture.lastBufferAt, idleSince: idleSince, sessionDuration: settings.sessionDuration,
            model: transcriber.modelState, dictation: slot.current, level: buffer.level, error: sessionError, now: now)
        lastStatusAt = now
        // A failed write is retried by the next heartbeat; the reader treats a stale one as a dead host.
        if (try? store.writeStatus(status)) != nil { notifier?.post(.status) }
        onPublish?(status)
        onChange?()
    }
}

/// Runs its action at most once, however many paths reach it.
@MainActor
private final class OnceAction {
    var action: (@MainActor () -> Void)?

    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}
