import UIKit

/// The text proxy as `EditingCore` sees it.
@MainActor
private final class ProxyDocument: TextDocument {
    weak var controller: UIInputViewController?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    nonisolated var documentID: UUID? { MainActor.assumeIsolated { proxy?.documentIdentifierIfAvailable } }
    nonisolated var contextBefore: String? { MainActor.assumeIsolated { proxy?.documentContextBeforeInput } }
    nonisolated var contextAfter: String? { MainActor.assumeIsolated { proxy?.documentContextAfterInput } }
    /// Only whether text is selected; the selection's text is not kept.
    nonisolated var hasSelection: Bool { MainActor.assumeIsolated { proxy?.selectedText?.isEmpty == false } }

    nonisolated func insertText(_ text: String) {
        MainActor.assumeIsolated { proxy?.insertText(text) }
    }

    nonisolated func deleteBackward() {
        MainActor.assumeIsolated { proxy?.deleteBackward() }
    }
}

/// The editing side of the keyboard: typing, the held delete key, trackpad mode, dictated text and
/// its undo. The rules live in KeyboardCore (`EditingCore`, `UndoTracker`, `TrackpadSession`, the
/// typing rules); this class applies them to the text proxy and owns the timers.
///
/// Ownership (ARCHITECTURE.md, "Undo ownership v2"): typing, each delete (the first and every
/// repeat), entering trackpad mode, a dictated insertion, a focus change, hiding and any host
/// callback that no pending operation of ours explains advance the edit generation, which ends an
/// undo and a trackpad gesture for good. While a gesture runs or settles, edits wait, bound to their
/// field; only a completed gesture flushes them. Context is read in memory only and never stored or
/// logged; every copy is dropped on hiding and expires on its own clock otherwise.
@MainActor
final class KeyboardInput: KeyAreaViewDelegate {
    private weak var controller: UIInputViewController?
    private weak var keyArea: KeyAreaView?
    private let core: EditingCore<() -> Void>
    private var typing = TypingState()
    private var tail = ContextTail()
    private var deleteKey = HeldDeleteKey()
    private var deleteTimer: Timer?
    private var drainTimer: Timer?
    private var undoTimer: Timer?
    private var undoExpiry: Timer?
    private var tailExpiry: Timer?
    let trackpad: TrackpadDriver
    /// Trackpad mode started (true) or ended (false), to dim the dictation bar and play a haptic.
    var onTrackpadChange: ((Bool) -> Void)?
    /// Whether Undo can be offered may have changed. Only state is read in response; never results.
    var onUndoAvailabilityChanged: (() -> Void)?
    /// The field's layout profile, read when a gesture starts.
    var fieldLayout: () -> FieldLayout = { FieldLayoutParameters.standard.defaultLayout }
    /// The user's trackpad multipliers, read when a gesture starts.
    var trackpadMultipliers: () -> (sensitivity: Double, acceleration: Double) = { (1, 1) }
    /// A trackpad gesture ended with this measured touch rate and step scale (numbers only), for
    /// Diagnostics. Called at most once per gesture.
    var onTouchRateMeasured: ((Double, Double) -> Void)?

    init(controller: UIInputViewController, keyArea: KeyAreaView) {
        self.controller = controller
        self.keyArea = keyArea
        core = EditingCore(document: ProxyDocument(controller: controller))
        trackpad = TrackpadDriver(controller: controller)
        core.adjustments = trackpad
        trackpad.currentGeneration = { [weak self] in self?.core.generation ?? 0 }
        trackpad.onFinished = { [weak self] completed in self?.trackpadFinished(completed: completed) }
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private var currentBefore: String? { tail.current(proxyBefore: proxy?.documentContextBeforeInput) }

    private var now: TimeInterval { CACurrentMediaTime() }

    /// The trackpad is busy: dictated text should wait in the shared files rather than in memory.
    var isBusy: Bool { trackpad.isActive || core.isDraining }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset() {
        // A cancelled jump still watched since the keyboard hid ends here: the new appearance starts with
        // no gesture, and what is typed now must not wait behind the old one.
        trackpad.abort()
        core.reset()
        forgetTail()
        typing.resetTiming()
        let numeric: Set<UIKeyboardType> = [.numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad]
        typing.switchLayer(to: numeric.contains(proxy?.keyboardType ?? .default) ? .numbers : .letters)
        stopUndoTimers()
        updateAutomaticShift()
        onUndoAvailabilityChanged?()
    }

    /// The keyboard is hiding: end every gesture and, synchronously, drop every copy of the field's
    /// context and identity (the trackpad snapshot, its unit, the undo text and anchors, the typing
    /// tail and queued edits). A probe still out is rolled back first.
    func stop() {
        cancelHeldActions()
        trackpad.hide()
        core.hide()
        forgetTail()
        stopUndoTimers()
        onUndoAvailabilityChanged?()
    }

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback.
    func hostChanged(textChanged: Bool) {
        switch core.hostChanged(textChanged: textChanged, now: now) {
        case .own:
            break
        case .outside:
            // An outside change ends the undo and the gesture for good, and what was queued with it.
            trackpad.abort()
            stopUndoTimers()
            onUndoAvailabilityChanged?()
        case .newField:
            // Another field: nothing from the old one applies here, held keys and a pending delete
            // included.
            cancelHeldActions()
            trackpad.fieldChanged()
            forgetTail()
            typing.resetTiming()
            stopUndoTimers()
            onUndoAvailabilityChanged?()
        }
        // Typing helpers keep their model only while the proxy agrees with it.
        let hadModel = tail.known != nil
        tail.proxyChanged(before: proxy?.documentContextBeforeInput)
        if hadModel, tail.known == nil {
            typing.resetTiming()
            scheduleTailExpiry()
        }
        updateAutomaticShift()
    }

    /// Ends every held key (characters, space, delete) without typing, and a pending delete without
    /// deleting; revokes what the delete press queued.
    private func cancelHeldActions() {
        if let token = deleteKey.cancel() { core.revoke(token: token) }
        endDeleteRepeat()
        keyArea?.cancelAllTouches()
    }

    // MARK: Dictation and undo

    /// Inserts dictated text and makes it undoable. Waits, bound to this field, while a trackpad
    /// gesture settles.
    func insertDictation(_ text: String) {
        whenIdle { [weak self] in
            guard let self, !text.isEmpty else { return }
            self.forgetTail()
            self.core.insertDictation(text, now: self.now)
            self.scheduleUndoExpiry()
            self.typing.resetTiming()
            self.updateAutomaticShift()
            self.onUndoAvailabilityChanged?()
        }
    }

    var canUndoLastDictation: Bool { core.canUndo(now: now) }

    /// Removes the last dictation progressively: only what the context proves, then re-checks.
    func undoLastDictation() {
        guard !trackpad.isActive, undoTimer == nil else { return }
        forgetTail()
        handle(core.beginUndo(now: now))
    }

    private func handle(_ step: UndoTracker.Step) {
        guard step == .wait else {
            undoTimer?.invalidate()
            undoTimer = nil
            typing.resetTiming()
            updateAutomaticShift()
            onUndoAvailabilityChanged?()
            return
        }
        guard undoTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // A repeating timer outlives its owner unless told otherwise.
                guard let self else { return timer.invalidate() }
                self.handle(self.core.continueUndo(now: self.now))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        undoTimer = timer
    }

    private func scheduleUndoExpiry() {
        undoExpiry?.invalidate()
        let timer = Timer(timeInterval: UndoTracker.window, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.core.expireUndo(now: self.now + 0.001)
                self.undoExpiry = nil
                self.onUndoAvailabilityChanged?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        undoExpiry = timer
    }

    private func stopUndoTimers() {
        undoTimer?.invalidate()
        undoTimer = nil
        if core.undo.insertion == nil {
            undoExpiry?.invalidate()
            undoExpiry = nil
        }
    }

    // MARK: The typing tail

    /// The tail's own clock: set when a model is first held, never moved by more typing.
    private func scheduleTailExpiry() {
        guard let expiresAt = tail.expiresAt else {
            tailExpiry?.invalidate()
            tailExpiry = nil
            return
        }
        guard tailExpiry == nil else { return }
        let timer = Timer(timeInterval: max(expiresAt - now, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tailExpiry = nil
                self.tail.expire(now: self.now)
                // A model held since then gets the rest of its own lifetime.
                self.scheduleTailExpiry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tailExpiry = timer
    }

    private func forgetTail() {
        tail.forget()
        tailExpiry?.invalidate()
        tailExpiry = nil
    }

    // MARK: Editing

    /// Runs an edit now, or, bound to this field, its generation and (for a held key) its press, after
    /// the trackpad gesture completes and the edits queued before it have run.
    private func whenIdle(token: Int? = nil, _ edit: @escaping () -> Void) {
        guard trackpad.isActive || core.isDraining else {
            edit()
            return
        }
        core.enqueue(edit, token: token)
    }

    private func trackpadFinished(completed: Bool) {
        if let measured = trackpad.measuredTouchRate { onTouchRateMeasured?(measured.rate, measured.scale) }
        if completed {
            core.beginDrain()
            drainNext()
        } else {
            core.discardQueue()
        }
        updateAutomaticShift()
        onUndoAvailabilityChanged?()
    }

    /// Runs the queue one edit per frame, so the callbacks an edit causes (a Return that moves focus to
    /// another field) arrive before the next one, which then runs only if still bound to this field.
    private func drainNext() {
        drainTimer?.invalidate()
        drainTimer = nil
        guard core.isDraining else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drainTimer = nil
                guard let edit = self.core.nextQueuedEdit() else { return }
                edit()
                self.core.queuedEditRan()
                self.updateAutomaticShift()
                self.drainNext()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    /// An edit by the user: it ends any undo that relied on the document as it was.
    private func userEdit() {
        let hadUndo = core.undo.insertion != nil
        core.userEdit()
        if hadUndo {
            stopUndoTimers()
            onUndoAvailabilityChanged?()
        }
    }

    private func insert(_ text: String) {
        guard let proxy, !text.isEmpty else { return }
        let before = proxy.documentContextBeforeInput
        proxy.insertText(text)
        tail.inserted(text, proxyBefore: before, at: now)
        tail.acknowledge(proxyBefore: proxy.documentContextBeforeInput)
        scheduleTailExpiry()
    }

    private func deleteCharacters(_ count: Int) {
        guard let proxy, count > 0 else { return }
        let before = proxy.documentContextBeforeInput
        for _ in 0 ..< count { proxy.deleteBackward() }
        tail.deleted(graphemes: count, proxyBefore: before, at: now)
        tail.acknowledge(proxyBefore: proxy.documentContextBeforeInput)
        scheduleTailExpiry()
    }

    private func deleteWord() {
        // One grapheme when nothing before the caret is visible (often a hidden line break).
        let count = WordBoundaries.previousWord(before: currentBefore ?? "").graphemes
        deleteCharacters(max(count, 1))
    }

    private func updateAutomaticShift() {
        let mode: AutocapitalizationMode
        switch proxy?.autocapitalizationType ?? .sentences {
        case .none: mode = .none
        case .words: mode = .words
        case .allCharacters: mode = .allCharacters
        default: mode = .sentences
        }
        typing.updateAutomaticShift(AutoCapitalization.shouldCapitalize(before: currentBefore, mode: mode))
        keyArea?.apply(layer: typing.layer, shift: typing.shift)
    }

    // MARK: KeyAreaViewDelegate

    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, timestamp: TimeInterval) {
        switch action {
        case .shift:
            typing.tapShift(at: timestamp)
            keyArea.apply(layer: typing.layer, shift: typing.shift)
        case .layer(let layer):
            typing.switchLayer(to: layer)
            updateAutomaticShift()
        case .nextKeyboard:
            break
        case .character, .space, .returnKey, .delete:
            whenIdle { [weak self] in self?.type(action, at: timestamp) }
        }
    }

    private func type(_ action: KeyAction, at timestamp: TimeInterval) {
        userEdit()
        switch action {
        case .character(let character):
            let text = typing.text(for: character)
            insert(text)
            typing.didTypeCharacter(text)
        case .space:
            switch typing.spaceEdit(before: currentBefore, at: timestamp) {
            case .space:
                insert(" ")
            case .replaceSpaceWithPeriod:
                deleteCharacters(1)
                insert(". ")
            }
        case .returnKey:
            insert("\n")
            typing.didTypeReturn()
        case .delete:
            deleteCharacters(1)
            typing.didDelete()
        case .shift, .layer, .nextKeyboard:
            return
        }
        updateAutomaticShift()
    }

    func keyAreaBeganDelete(_ keyArea: KeyAreaView, timestamp: TimeInterval) {
        endDeleteRepeat()
        // Measured on device: the first deletion comes 0.12 s after touch-down (or at release, if
        // sooner), and the repeats follow on the schedule from touch-down. The press is bound to this
        // field; every deletion it schedules or queues carries its token.
        guard let press = deleteKey.began(at: timestamp, documentID: proxy?.documentIdentifierIfAvailable) else { return }
        schedule(press.token, at: press.firstAt, pressedAt: timestamp)
    }

    /// A release before the first deletion deletes once, in the field the press began in; a
    /// cancellation (the system's, the menu opening over the keys, hiding) deletes nothing and revokes
    /// any deletion the press queued behind a trackpad gesture.
    func keyAreaEndedDelete(_ keyArea: KeyAreaView, cancelled: Bool) {
        endDeleteRepeat()
        guard let ended = deleteKey.ended(cancelled: cancelled, documentID: proxy?.documentIdentifierIfAvailable) else { return }
        if cancelled {
            core.revoke(token: ended.token)
        } else if ended.deleteOnce {
            delete(.character, token: ended.token)
        }
    }

    /// Schedules the press's next deletion `time` seconds after touch-down.
    private func schedule(_ token: Int, at time: TimeInterval, pressedAt: TimeInterval) {
        // Touch timestamps and CACurrentMediaTime share the same clock.
        let delay = max(time - (now - pressedAt), 0)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDelete(token, pressedAt: pressedAt) }
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
    }

    /// A scheduled deletion: only while its press is current and the field is the one it began in.
    private func fireDelete(_ token: Int, pressedAt: TimeInterval) {
        guard let fired = deleteKey.fire(token: token, documentID: proxy?.documentIdentifierIfAvailable) else {
            endDeleteRepeat()
            return
        }
        delete(fired.unit, token: token)
        schedule(token, at: fired.nextAt, pressedAt: pressedAt)
    }

    /// One deletion of the held key. Every one is a new edit: an undo offered since the last one ends
    /// here, before anything is deleted.
    private func delete(_ unit: DeleteRepeat.Unit, token: Int) {
        whenIdle(token: token) { [weak self] in
            guard let self else { return }
            self.userEdit()
            switch unit {
            case .character: self.deleteCharacters(1)
            case .words(let count): for _ in 0 ..< count { self.deleteWord() }
            }
            self.typing.didDelete()
            self.updateAutomaticShift()
        }
    }

    private func endDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView) {
        // A delete still held stops repeating (what it already did stands).
        _ = deleteKey.cancel()
        endDeleteRepeat()
        // Moving the caret is an edit: the undo for a dictation ends, and the gesture owns what follows.
        userEdit()
        let multipliers = trackpadMultipliers()
        trackpad.parameters = TrackpadParameters.standard.tuned(sensitivity: multipliers.sensitivity,
                                                                acceleration: multipliers.acceleration)
        trackpad.begin(keyboardWidth: keyArea.bounds.width, layout: fieldLayout())
        forgetTail()
        typing.resetTiming()
        onTrackpadChange?(true)
    }

    func keyArea(_ keyArea: KeyAreaView, movedTrackpadBy dx: Double, dy: Double, timestamp: TimeInterval) {
        trackpad.move(dx: dx, dy: dy, timestamp: timestamp)
    }

    func keyAreaEndedTrackpad(_ keyArea: KeyAreaView, timestamp: TimeInterval, cancelled: Bool) {
        if cancelled {
            trackpad.cancel(at: timestamp)
        } else {
            trackpad.end(at: timestamp)
        }
        onTrackpadChange?(false)
    }
}
