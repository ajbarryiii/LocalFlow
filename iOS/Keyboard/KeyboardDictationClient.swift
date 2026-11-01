import UIKit

/// What the dictation client needs from the input view controller. Document identifiers and text
/// context pass through and live no longer than this keyboard instance's memory.
@MainActor
protocol KeyboardTextTarget: AnyObject {
    var hasFullAccess: Bool { get }
    var documentID: UUID? { get }
    var contextBeforeInput: String? { get }
    var contextAfterInput: String? { get }
    /// The view haptics attach to; nil before it loads.
    var feedbackView: UIView? { get }
    func insert(_ text: String)
    /// The editing side is busy (a trackpad gesture is running or settling): results stay in the
    /// shared files until it is done, rather than waiting in memory.
    var isEditingBusy: Bool { get }
    /// "Undo last dictation" is owned by the editing side (`KeyboardInput`), which sees every edit.
    var canUndoLastDictation: Bool { get }
    func undoLastDictation()
    /// Tries to open the containing app (see `HostAppLauncher`); false if no attempt was made.
    func openContainingApp(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool
}

/// What the pad renders. It never holds transcript text.
struct KeyboardViewState: Equatable {
    var mode: KeyboardMode = .hostUnavailable
    var title = ""
    var hint: String?
    /// A short-lived notice (a failed write, no speech, open LocalFlow). Shown before any idle hint.
    var notice: String?
    var canInsertLast = false
    /// The last inserted dictation can still be removed (see `UndoTracker`).
    var canUndo = false
    /// For the menu panel: whether a session runs and how long it stays idle.
    var sessionSummary = ""
    /// A live session can take a dictation now (`KeyboardMessages.isSessionReady`): the idle bar shows its dot.
    var sessionReady = false
    /// Recent input levels while recording, oldest first.
    var levels: [Float] = []
    /// How many levels this recording has heard, the newest's number (the wave keeps each level on its side by it).
    var levelSerial = 0
}

/// The keyboard side of the protocol in ARCHITECTURE.md. While visible it polls and observes the
/// shared files, writes presence and intents, and claims and inserts results. The decisions come
/// from `KeyboardPresenter` and `KeyboardResultLedger`; this class only sequences them.
@MainActor
final class KeyboardDictationClient: ObservableObject {
    static let pollInterval: TimeInterval = 0.2
    /// Enough for the recording wave to span a landscape bar.
    static let levelHistoryCount = 72
    private static let noticeDuration: TimeInterval = 4

    @Published private(set) var state = KeyboardViewState()

    /// Names this `UIInputViewController` instance in the intents and presence it writes.
    let instanceID = UUID()
    weak var target: KeyboardTextTarget?

    private let configuration = LocalFlowConfiguration.main
    private var store: SharedDictationStore?
    private var ledger = KeyboardResultLedger()
    /// The result files as last read; most passes decide from it without touching the files.
    private var resultInbox = KeyboardResultInbox()
    private var isVisible = false
    private var hapticsEnabled = false
    private var keyHapticsEnabled = false
    private var generators: (impact: UIImpactFeedbackGenerator, notification: UINotificationFeedbackGenerator)?
    private var timers: [Timer] = []
    private var observations: [DarwinNotifier.Observation] = []
    /// The records behind `state`, so a tap acts on the request the user saw.
    private var shownIntent = StoreRead<KeyboardIntent>.absent
    private var shownStatus = StoreRead<HostStatus>.absent
    private var manualInsertID: UUID?
    private var launcherFailed = false
    /// A record request whose bounce failed; it waits for the user to open LocalFlow.
    private var unlaunchedRequestID: UUID?
    private var notice: (text: String, until: Date)?
    private var levels: [Float] = []
    private var levelSerial = 0
    private var levelSampledAt: Date?

    private var notifier: DarwinNotifier? { configuration.map(DarwinNotifier.init(configuration:)) }

    /// Haptics need Full Access and the user's setting; the keys use the same rule with their own setting.
    var hapticsAllowed: Bool { hapticsEnabled }
    var keyHapticsAllowed: Bool { keyHapticsEnabled }

    private var access: KeyboardAccess {
        guard target?.hasFullAccess == true else { return .noFullAccess }
        return store == nil ? .containerUnavailable : .fullAccess
    }

    // MARK: Lifecycle

    /// Call from `viewWillAppear`. Polling, presence and observations run only while visible.
    func start() {
        guard !isVisible else { return }
        isVisible = true
        if store == nil, let configuration { store = SharedDictationStore(configuration: configuration) }
        hapticsEnabled = false
        keyHapticsEnabled = false
        // Without Full Access the mode cannot change while visible, so nothing needs polling.
        if access == .fullAccess, let configuration, let notifier {
            let settings = LocalFlowSettings(configuration: configuration)
            hapticsEnabled = settings?.hapticsEnabled ?? false
            keyHapticsEnabled = settings?.keyHapticsEnabled ?? false
            observations = [notifier.observe(.status) { [weak self] in self?.refresh() },
                            notifier.observe(.result) { [weak self] in self?.resultPosted() }]
            let poll = Timer.mainLoop(after: Self.pollInterval, repeats: true, tolerance: 0.05) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.refresh()
            }
            let presence = Timer.mainLoop(after: DictationProtocol.keyboardPresenceInterval, repeats: true,
                                          tolerance: 0.05) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.writePresence()
            }
            timers = [poll, presence]
            writePresence()
        }
        refresh()
    }

    /// Call from `viewDidDisappear`.
    func stop() {
        isVisible = false
        timers.forEach { $0.invalidate() }
        timers = []
        observations.forEach { $0.cancel() }
        observations = []
        levels = []
        levelSerial = 0
        levelSampledAt = nil
        // No field identity outlives the keyboard being visible: a request bound to a field is never
        // auto-inserted after hiding (it stays available as "Insert last dictation").
        ledger.forgetFieldBindings()
        manualInsertID = nil
        // No transcript stays in memory while hidden; the next appearance reads the files again.
        resultInbox.reset()
    }

    /// Call from `viewWillAppear` and `textDidChange`: a new field invalidates bindings to others.
    func documentChanged(to documentID: UUID?) {
        ledger.documentChanged(to: documentID)
    }

    // MARK: Actions

    func micTapped() {
        notice = nil
        switch state.mode {
        case .ready, .preparingModel: startDictation(openingHost: false)
        case .hostUnavailable: startDictation(openingHost: true)
        case .error:
            // The error is informational; start the way the host's current state allows.
            switch KeyboardPresenter.mode(access: access, status: shownStatus, intent: .absent, now: Date()) {
            case .ready, .preparingModel: startDictation(openingHost: false)
            case .hostUnavailable: startDictation(openingHost: true)
            default: break
            }
        case .starting, .recording: send(.finish)
        case .transcribing, .waitingForModel, .needsFullAccess, .configurationError, .incompatible: break
        }
        refresh()
    }

    func cancelTapped() {
        notice = nil
        switch state.mode {
        case .starting, .recording, .transcribing, .waitingForModel: send(.cancel)
        default: break
        }
        refresh()
    }

    /// The "Insert last dictation" chip: claims the offered result and inserts it into this field.
    func insertLastDictation() {
        notice = nil
        if let store, let target, !target.isEditingBusy, let requestID = manualInsertID {
            let read = store.readResult(requestID: requestID)
            if let result = read.value,
               ledger.disposition(of: result, documentID: target.documentID, now: Date()) != .ignore {
                var context = target.contextBeforeInput
                insert(result, context: &context)
            } else if read == .absent {
                // Removed elsewhere: stop offering it, so the pass below offers the next result.
                resultInbox.discard([requestID])
            }
        }
        refresh()
    }

    /// "Undo": removes the last inserted dictation, progressively, while it is still owned.
    func undoLastDictation() {
        notice = nil
        guard target?.canUndoLastDictation == true else { return publishUndoState() }
        target?.undoLastDictation()
        playHaptic(.press)
        publishUndoState()
    }

    /// Whether Undo can be offered changed. Updates only that, without reading the shared files or
    /// delivering a result, so an invalidation inside an edit can never insert text before the edit
    /// runs.
    func publishUndoState() {
        let canUndo = target?.canUndoLastDictation == true
        guard canUndo != state.canUndo else { return }
        state.canUndo = canUndo
    }

    /// "Open LocalFlow" in the menu: the same launcher as the bounce, without a dictation request.
    func openLocalFlow() {
        notice = nil
        var attempted = false
        if let url = configuration?.dictateURL, let target {
            attempted = target.openContainingApp(url) { [weak self] opened in
                guard let self, !opened else { return }
                self.launcherFailed = true
                self.show(KeyboardMessages.openLocalFlow)
                self.refresh()
            }
        }
        if !attempted {
            launcherFailed = true
            show(KeyboardMessages.openLocalFlow)
        }
        refresh()
    }

    private func startDictation(openingHost: Bool) {
        guard let store else { return }
        let requestID = UUID()
        guard write(KeyboardIntent(requestID: requestID, action: .record, keyboardInstanceID: instanceID,
                                   issuedAt: Date()), to: store) else { return }
        // Started in this field, so bound to it: a host auto-finish lands here if the keyboard stays
        // visible in this field.
        ledger.bindRecord(requestID: requestID, documentID: target?.documentID)
        unlaunchedRequestID = nil
        playHaptic(.press)
        guard openingHost else {
            // After the frame that starts the island's grow: the host's start (capture, the Live Activity) then runs
            // beside the spring rather than ahead of its first frames (round 8 council, Opus finding 2).
            DispatchQueue.main.async { [notifier] in notifier?.post(.intent) }
            return
        }
        // No `.intent` post: a background host without a session would reject the request before
        // the app reaches the foreground and admits it.
        var attempted = false
        if let url = configuration?.dictateURL, let target {
            attempted = target.openContainingApp(url) { [weak self] opened in
                if !opened { self?.launchFailed(requestID) }
            }
        }
        if !attempted { launchFailed(requestID) }
    }

    private func launchFailed(_ requestID: UUID) {
        launcherFailed = true
        unlaunchedRequestID = requestID
        playHaptic(.failure)
        refresh()
    }

    /// `finish` or `cancel` for the request on screen, under the stale-writer guard.
    private func send(_ action: KeyboardIntent.Action) {
        guard let store, let requestID = shownIntent.value?.requestID,
              KeyboardPresenter.mayWrite(action, requestID: requestID, currentIntent: store.readIntent()),
              write(KeyboardIntent(requestID: requestID, action: action, keyboardInstanceID: instanceID,
                                   issuedAt: Date()), to: store)
        else { return }
        if action == .finish { ledger.bindFinish(requestID: requestID, documentID: target?.documentID) }
        if unlaunchedRequestID == requestID { unlaunchedRequestID = nil }
        notifier?.post(.intent)
        playHaptic(.press)
    }

    private func write(_ intent: KeyboardIntent, to store: SharedDictationStore) -> Bool {
        do {
            try store.writeIntent(intent)
            return true
        } catch {
            show(KeyboardMessages.storeWriteFailed)
            playHaptic(.failure)
            return false
        }
    }

    private func writePresence() {
        guard isVisible, access == .fullAccess, let store else { return }
        try? store.writePresence(KeyboardPresence(keyboardInstanceID: instanceID, seenAt: Date()))
    }

    // MARK: Passes

    /// `.result` arrived: the next pass reads the result files.
    private func resultPosted() {
        resultInbox.resultPosted()
        refresh()
    }

    /// One pass: read the status and intent, compute the mode, deliver results and publish. The
    /// result files are read only when `KeyboardResultInbox` says one may have arrived or expired.
    func refresh() {
        guard isVisible, let target else { return }
        let now = Date()
        let access = self.access
        let documentID = target.documentID
        // Also catches a focus change whose `textDidChange` has not arrived yet.
        ledger.documentChanged(to: documentID)
        var status = StoreRead<HostStatus>.absent
        var intent = StoreRead<KeyboardIntent>.absent
        if access == .fullAccess, let store {
            status = store.readStatus()
            intent = store.readIntent()
        }
        // Displaying a request never binds it, so a new instance in another app cannot auto-insert it.
        let mode = KeyboardPresenter.mode(access: access, status: status, intent: intent, now: now)
        ledger.prune(now: now, keeping: Set([intent.value?.requestID, shownIntent.value?.requestID].compactMap { $0 }))
        if access == .fullAccess { deliverResults(status: status, documentID: documentID, now: now) }
        shownIntent = intent
        shownStatus = status
        sampleLevel(of: mode, status: status)
        publish(mode, intent: intent, status: status, now: now)
    }

    private func deliverResults(status: StoreRead<HostStatus>, documentID: UUID?, now: Date) {
        guard let store else { return }
        // Purges, lists and decodes the result files only when a read is due; otherwise the results
        // read earlier stand in for them, so a deferred one is still delivered on a later pass.
        resultInbox.update(from: store, status: status, now: now)
        let plan = ledger.plan(for: resultInbox.results, documentID: documentID, now: now)
        // At most one result per pass, oldest first: what it inserts (a Return) can move the host to
        // another field, so each one is bound again right before it is claimed, on a later pass. A result
        // is claimed only to be inserted at once: while a trackpad gesture runs, it stays in the shared
        // files.
        if let next = plan.autoInsert.first, let target, !target.isEditingBusy,
           ledger.disposition(of: next, documentID: target.documentID, now: Date()) == .autoInsert {
            var context = target.contextBeforeInput
            insert(next, context: &context)
        }
        // A consumed request's file is gone, whoever removed it.
        resultInbox.discard(ledger.consumed)
        // The ledger never offers a result that would insert nothing.
        manualInsertID = plan.manualInsert?.requestID
    }

    /// Claim before insert: the result is inserted only if this call deleted its file, so it lands
    /// at most once across keyboard instances and processes.
    private func insert(_ result: DictationResult, context: inout String?) {
        guard let store, let target, ledger.claim(requestID: result.requestID, in: store) else { return }
        // Already ends in "\n" when the result presses Enter, even for an empty transcript.
        let text = TextInsertionFormatter.text(for: result, contextBefore: context, contextAfter: target.contextAfterInput)
        guard !text.isEmpty else {
            show(KeyboardMessages.noSpeech)
            return
        }
        target.insert(text)
        // The proxy may not reflect the insertion yet, and a following result's spacing needs it.
        context = (context ?? "") + text
        playHaptic(.success)
    }

    private func sampleLevel(of mode: KeyboardMode, status: StoreRead<HostStatus>) {
        guard case .recording(let level, _) = mode else {
            levels = []
            levelSerial = 0
            levelSampledAt = nil
            return
        }
        // One bar per status the host publishes, not per read.
        let sampledAt = status.value?.heartbeatAt
        guard sampledAt != levelSampledAt else { return }
        levelSampledAt = sampledAt
        levels.append(level)
        levelSerial += 1
        levels.removeFirst(max(0, levels.count - Self.levelHistoryCount))
    }

    private func publish(_ mode: KeyboardMode, intent: StoreRead<KeyboardIntent>, status: StoreRead<HostStatus>,
                         now: Date) {
        var title = KeyboardMessages.title(for: mode, launcherFailed: launcherFailed)
        if mode == .starting, let pending = unlaunchedRequestID, intent.value?.requestID == pending {
            title = KeyboardMessages.openLocalFlow
        }
        if case .recording = mode, KeyboardPresenter.isModelPreparing(status: status, now: now) {
            title = KeyboardMessages.listeningWhilePreparing
        }
        // A notice is rendered on its own, so no mode (ready included) can hide it.
        if let current = notice, current.until <= now { notice = nil }
        let next = KeyboardViewState(mode: mode, title: title, hint: KeyboardMessages.hint(for: status.value, now: now),
                                     notice: notice?.text,
                                     canInsertLast: manualInsertID != nil,
                                     canUndo: target?.canUndoLastDictation == true,
                                     sessionSummary: KeyboardMessages.sessionSummary(for: status.value, now: now),
                                     sessionReady: KeyboardMessages.isSessionReady(status.value, now: now),
                                     levels: levels, levelSerial: levelSerial)
        guard next != state else { return }
        if mode.phase != state.mode.phase {
            if case .recording = mode { playHaptic(.listening) }
            if case .error = mode { playHaptic(.failure) }
        }
        if UIAccessibility.isVoiceOverRunning {
            if let notice = next.notice, notice != state.notice {
                UIAccessibility.post(notification: .announcement, argument: notice)
            } else if title != state.title {
                UIAccessibility.post(notification: .announcement, argument: title)
            }
        }
        state = next
    }

    private func show(_ text: String) {
        notice = (text, Date().addingTimeInterval(Self.noticeDuration))
    }

    // MARK: Haptics

    private enum Haptic { case press, listening, success, failure }

    private func playHaptic(_ haptic: Haptic) {
        // iOS plays keyboard haptics only with Full Access, and the user can turn them off in LocalFlow.
        guard hapticsEnabled, let view = target?.feedbackView else { return }
        let generators = self.generators ?? (impact: UIImpactFeedbackGenerator(style: .medium, view: view),
                                             notification: UINotificationFeedbackGenerator(view: view))
        self.generators = generators
        switch haptic {
        case .press: generators.impact.impactOccurred(intensity: 0.6)
        case .listening: generators.impact.impactOccurred()
        case .success: generators.notification.notificationOccurred(.success)
        case .failure: generators.notification.notificationOccurred(.error)
        }
    }
}

private extension KeyboardMode {
    /// The mode with recording details dropped, to compare phases.
    var phase: KeyboardMode {
        if case .recording = self { return .recording(level: 0, startedAt: .distantPast) }
        return self
    }
}
