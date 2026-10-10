import Foundation

/// Platform hooks, injected so the core stays Foundation-only and testable.
struct HostEnvironment {
    var now: @MainActor () -> Date
    /// The application state is not `.background` (active or inactive): capture may start, and a fresh
    /// record intent may be admitted without a session.
    var isForeground: @MainActor () -> Bool
    /// Begins a UIKit background task. `onExpiration` runs on main when time runs out; the returned
    /// closure ends the task, and the core calls it exactly once.
    var beginBackgroundTask: @MainActor (_ onExpiration: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    /// `LocalDictationCore.process`, which is compiled into the app only.
    var formatTranscript: @MainActor (_ text: String, _ pressEnterEnabled: Bool, _ spokenDelimitersEnabled: Bool)
        -> (text: String, pressEnter: Bool)
}

/// The host side of the protocol: session lifecycle, idle expiry, reconciliation, run recovery,
/// watchdog, capture supervision, transcription and status publishing. `HostSessionController` (App)
/// drives it from timers, Darwin notifications and UIKit events and mirrors its state into SwiftUI.
///
/// Every asynchronous completion carries a `DictationTicket`, a session generation or an engine
/// generation and is dropped unless it is still current. Status is written after every change, and on
/// the cadence of `HostSessionPolicy` while live.
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
    /// A session start waiting for the foreground (the permission prompt was answered elsewhere).
    private var pendingStart: UInt64?
    private var transcription: Transcription?
    private var needsPublish = false
    private var lastStatusAt: Date?
    private var lastPurgeAt: Date?
    private var lastReconcileAt: Date?
    /// Capture supervision: a reported or observed failure waits out `captureStallGrace` here.
    private var captureFailingSince: Date?
    /// When the current engine started, the baseline for starvation before its first buffer.
    private var captureStartedAt: Date?
    private var recoveriesWithoutInput = 0
    /// Sample growth of the recording, to detect a recording that stopped receiving audio.
    private var recordingProgress: (generation: UInt64, duration: TimeInterval, since: Date)?
    /// A memory warning not yet acted on: the model is released once nothing uses it.
    private var pendingModelRelease = false
    /// A finished recording waiting for its tail: frames captured before the finish but not yet
    /// delivered. It is drained when the capture reports the tail complete, or after `tailTimeout`.
    private var closing: (ticket: DictationTicket, since: Date)?

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

    /// A URL open is passed as `.urlOpen`: only a hint, acted on once the app is actually in front.
    func reconcile(_ trigger: ReconcileTrigger) {
        guard isLaunched else { return }
        let now = environment.now()
        noteForeground(now)
        reconcilePass(trigger, now)
        flush(now)
    }

    /// The controller's timer, every `HostSessionPolicy.tickInterval`.
    func tick() {
        guard isLaunched else { return }
        let now = environment.now()
        let foreground = noteForeground(now)
        superviseDictation(now, foreground: foreground)
        superviseCapture(now)
        // A deferred start nobody is waiting for any more (its request timed out) is abandoned.
        if let closing, HostSessionPolicy.isDue(last: closing.since, interval: HostSessionPolicy.tailTimeout, now: now) {
            drainClosing(now)   // the tail never arrived (a stalled engine): transcribe what did
        }
        if pendingStart != nil, !slot.isInProgress { endSession(.startFailed(.audioSessionFailed), now) }
        if session == .active, !slot.isInProgress,
           HostSessionPolicy.isIdleExpired(idleSince: idleSince, duration: settings.sessionDuration, now: now) {
            endSession(.idleExpired, now)
        }
        releaseModelIfPending()
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

    /// Scene or application state changed. Arriving in the foreground re-reads the intent and
    /// reconciles, with freshness judged at that moment: this is what admits a request after a URL open.
    func foregroundChanged() {
        guard isLaunched else { return }
        let now = environment.now()
        if noteForeground(now) {
            if let pending = pendingStart { continueSessionStart(pending, now) }
            // A choice made while the app could not apply it takes effect now that it is in front.
            if session == .active, capture.needsReconfiguration { reconfigureCapture(now) }
            reconcilePass(.activation, now)
        }
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

    /// Media services were reset: the audio session this app activated is gone (contract: "Media services
    /// reset ends the session"). A recording fails with `.audioSessionFailed`, since the microphone, not
    /// another app, failed; a finished recording is still transcribed. Capturing again needs a new
    /// foreground start.
    func captureMediaServicesReset() {
        let now = environment.now()
        endSession(.mediaServicesReset, now)
        flush(now)
    }

    /// Capture settings changed (the microphone choice). In the foreground during an active session the
    /// capture is reconfigured now; otherwise the change applies at the next session start. Never in the
    /// background, where nothing may be reconfigured on the user's behalf.
    func captureSettingsChanged() {
        guard isLaunched, session == .active else { return }
        let now = environment.now()
        guard noteForeground(now) else { return }
        reconfigureCapture(now)
        flush(now)
    }

    /// The engine of `generation` stopped or its configuration changed, within a surviving audio session
    /// (a route change, or the microphone choice re-asserted). The failure waits out `captureStallGrace`
    /// (an interruption arriving meanwhile wins), then the engine is restarted, in the background too. A
    /// report for an engine that has since been replaced is ignored.
    func captureFailed(generation: UInt64) {
        guard session == .active, generation == capture.engineGeneration else { return }
        noteCaptureFailure(environment.now())
    }

    /// The transcriber's model state changed. Acted on in the next turn, so a change made in the middle
    /// of a transition (preparation starts inside `startSession`) never publishes a half-applied state
    /// or re-enters the transcriber.
    func modelStateChanged() {
        needsPublish = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.releaseModelIfPending()
                self.flush(self.environment.now())
            }
        }
    }

    /// Releases the model now if nothing uses it; otherwise as soon as nothing does.
    func memoryWarning() {
        pendingModelRelease = true
        releaseModelIfPending()
        flush(environment.now())
    }

    /// Called on the capture thread with every event of the capture pipeline.
    nonisolated func captureDelivered(_ event: CaptureEvent) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(event) } }
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
        capture.recordingBoundary()
        idleSince = nil
        needsPublish = true
        if transcriber.modelState == .unavailable {
            buffer.cancel(requestID: requestID)
            capture.recordingBoundary()
            slot.end(ticket, .failed, error: .modelUnavailable, now: now)
            dictationEnded(now)
        } else if session == .inactive {
            startSession(now)
        }
    }

    /// Stops the recording at the current capture time and shows it as transcribing. The samples are
    /// drained once the tail (frames captured before now, still in flight) has arrived.
    private func finish(_ requestID: UUID, _ now: Date) {
        guard let ticket = slot.ticket, ticket.requestID == requestID, slot.phase == .recording else { return }
        guard buffer.close(requestID: requestID), slot.markTranscribing(ticket, now: now) else {
            endInProgress(.failed(.notRecording), now)
            return
        }
        recordingProgress = nil
        closing = (ticket, now)
        needsPublish = true
        // Nothing more can arrive at the cap or from a stopped engine.
        if buffer.hasReachedLimit || !capture.isRunning { drainClosing(now) }
    }

    private func drainClosing(_ now: Date) {
        guard let closing else { return }
        self.closing = nil
        guard slot.isCurrent(closing.ticket), slot.phase == .transcribing else { return }
        guard let samples = buffer.finish(requestID: closing.ticket.requestID) else {
            endInProgress(.failed(.notRecording), now)
            return
        }
        capture.recordingBoundary()
        needsPublish = true
        transcribe(RecordedAudio(samples: samples), closing.ticket)
    }

    /// Ends the request in progress, if any: stops its recording or transcription, so its samples are
    /// released, and publishes `outcome`.
    @discardableResult
    private func endInProgress(_ outcome: DictationOutcome, _ now: Date) -> Bool {
        guard let ticket = slot.ticket else { return false }
        buffer.cancel(requestID: ticket.requestID)
        capture.recordingBoundary()
        if closing?.ticket == ticket { closing = nil }
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
        recordingProgress = nil
        needsPublish = true
        releaseModelIfPending()
    }

    // MARK: Recording

    private func handle(_ event: CaptureEvent) {
        let now = environment.now()
        switch event {
        case .started(let generation):
            if slot.markRecording(generation: generation, now: now) { needsPublish = true }
        case .reachedLimit(let generation):
            guard let ticket = slot.ticket, ticket.generation == generation else { break }
            _ = slot.markRecording(generation: generation, now: now)   // the limit can arrive with the first buffer
            finish(ticket.requestID, now)
        case .tailComplete(let generation):
            if closing?.ticket.generation == generation { drainClosing(now) }
        case .conversionFailed(let generation, let engine):
            // A pipeline of an engine since replaced (a live reconfiguration or restart) no longer converts.
            guard engine == capture.engineGeneration, let ticket = slot.ticket, ticket.generation == generation,
                  slot.phase == .starting || slot.phase == .recording else { break }
            endInProgress(.failed(.audioSessionFailed), now)
            noteCaptureFailure(now)   // a rebuilt engine gets a fresh converter
        }
        flush(now)
    }

    /// Watchdog, the duration cap by samples and by elapsed time, and a recording that stopped growing.
    private func superviseDictation(_ now: Date, foreground: Bool) {
        guard let current = slot.current, let ticket = slot.ticket,
              current.phase == .starting || current.phase == .recording else {
            recordingProgress = nil
            return
        }
        if let reason = HostWatchdog.stopReason(current: current, presence: store.readPresence(),
                                                isForeground: foreground, lastForegroundAt: lastForegroundAt, now: now) {
            endInProgress(HostSessionPolicy.watchdogOutcome(reason), now)
            return
        }
        guard current.phase == .recording else { return }
        if buffer.hasReachedLimit || HostSessionPolicy.hasExceededMaxDuration(startedAt: current.startedAt, now: now) {
            finish(current.requestID, now)
            return
        }
        let duration = buffer.recordedDuration
        if let progress = recordingProgress, progress.generation == ticket.generation, progress.duration == duration,
           progress.since <= now {
            guard HostSessionPolicy.isStarved(lastInputAt: progress.since, now: now) else { return }
            // Running but starved, or every buffer failing to convert: the recording cannot go on.
            endInProgress(.failed(.audioSessionFailed), now)
            noteCaptureFailure(now)
        } else {
            recordingProgress = (ticket.generation, duration, now)
        }
    }

    // MARK: Capture supervision

    private func noteCaptureFailure(_ now: Date) {
        if captureFailingSince == nil { captureFailingSince = now }
    }

    /// A stopped or starved engine, or a reported failure, is restarted once `captureStallGrace` has
    /// passed without an interruption ending the session first.
    private func superviseCapture(_ now: Date) {
        guard session == .active else {
            captureFailingSince = nil
            return
        }
        let lastInput = [capture.lastBufferAt, captureStartedAt].compactMap { $0 }.max()
        if let lastBuffer = capture.lastBufferAt, let started = captureStartedAt, lastBuffer > started {
            recoveriesWithoutInput = 0
        }
        if !capture.isRunning || lastInput.map({ HostSessionPolicy.isStarved(lastInputAt: $0, now: now) }) == true {
            noteCaptureFailure(now)
        }
        guard let since = captureFailingSince else { return }
        let pending = now.timeIntervalSince(since)
        if pending < 0 || pending >= HostSessionPolicy.captureStallGrace { recoverCapture(now) }
    }

    /// Applies changed capture settings in the foreground; the session ends if that fails.
    private func reconfigureCapture(_ now: Date) {
        do {
            try capture.reconfigure()
        } catch {
            endSession(.engineFailed, now)
            return
        }
        captureStartedAt = now
        captureFailingSince = nil
        needsPublish = true
    }

    /// While the audio session is active the engine may be rebuilt even in the background: `restart()`
    /// never activates anything. In the foreground a full start also reconfigures the audio session. The
    /// session ends if that fails, or if recoveries keep producing no input.
    private func recoverCapture(_ now: Date) {
        guard session == .active else { return }
        captureFailingSince = nil
        guard recoveriesWithoutInput < HostSessionPolicy.maxRecoveriesWithoutInput else {
            endSession(.engineFailed, now)
            return
        }
        do {
            if environment.isForeground() {
                capture.stop()
                try capture.start()
            } else {
                try capture.restart()
            }
        } catch {
            endSession(.engineFailed, now)
            return
        }
        recoveriesWithoutInput += 1
        captureStartedAt = now
        needsPublish = true
    }

    // MARK: Transcription

    private func transcribe(_ audio: RecordedAudio, _ ticket: DictationTicket) {
        let endBackgroundTask = OnceAction()
        endBackgroundTask.action = environment.beginBackgroundTask { [weak self] in
            self?.backgroundTimeExpired(ticket)
            endBackgroundTask.run()
        }
        let transcriber = self.transcriber
        let task = Task { [weak self] in
            let outcome: Result<String, Error>
            do { outcome = .success(try await transcriber.transcribe(audio)) } catch { outcome = .failure(error) }
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

    private func releaseModelIfPending() {
        guard pendingModelRelease, !slot.isInProgress else { return }
        if transcriber.releaseIfIdle() {
            pendingModelRelease = false
            needsPublish = true
        }
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
        // A session never starts in the background: capture and the permission prompt need the front.
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
        captureStartedAt = now
        captureFailingSince = nil
        recoveriesWithoutInput = 0
        if !slot.isInProgress { idleSince = now }
        needsPublish = true
    }

    private func endSession(_ reason: SessionEndReason, _ now: Date) {
        guard session != .inactive else { return }
        sessionGeneration &+= 1
        pendingStart = nil
        if let phase = slot.phase, slot.isInProgress,
           let outcome = HostSessionPolicy.sessionEndOutcome(reason, phase: phase) {
            endInProgress(outcome, now)
        }
        // A finished recording that survives the session end is transcribed with the tail it has; no more
        // input will arrive.
        drainClosing(now)
        capture.stop()
        // Anything still held belongs to a request that just ended; a transcription has its own copy.
        buffer.cancelAll()
        capture.recordingBoundary()
        session = .inactive
        sessionID = nil
        sessionError = HostSessionPolicy.sessionError(after: reason)
        idleSince = nil
        captureFailingSince = nil
        captureStartedAt = nil
        recoveriesWithoutInput = 0
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
