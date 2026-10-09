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
    private let deleteRepeat = DeleteRepeat()
    private var deletePressedAt: TimeInterval?
    private var deleteRepeatIndex = 0
    private var deleteTimer: Timer?
    private var undoTimer: Timer?
    private var undoExpiry: Timer?
    private var tailExpiry: Timer?
    let trackpad: TrackpadDriver
    /// Trackpad mode started (true) or ended (false), to dim the dictation bar and play a haptic.
    var onTrackpadChange: ((Bool) -> Void)?
    /// Whether Undo can be offered may have changed. Only state is read in response; never results.
    var onUndoAvailabilityChanged: (() -> Void)?
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
    var isBusy: Bool { trackpad.isActive }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset() {
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
        endDeleteRepeat()
        keyArea?.cancelAllTouches()
        trackpad.hide()
        core.hide()
        forgetTail()
        stopUndoTimers()
        onUndoAvailabilityChanged?()
    }

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback.
    func hostChanged(textChanged: Bool) {
        switch core.hostChanged(textChanged: textChanged) {
        case .own:
            break
        case .outside:
            // An outside change ends the undo and the gesture for good, and what was queued with it.
            trackpad.abort()
            stopUndoTimers()
            onUndoAvailabilityChanged?()
        case .newField:
            // Another field: nothing from the old one applies here.
            trackpad.abort()
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

    /// Runs an edit now, or, bound to this field and generation, after the trackpad gesture completes.
    private func whenIdle(_ edit: @escaping () -> Void) {
        guard trackpad.isActive else {
            edit()
            return
        }
        core.enqueue(edit)
    }

    private func trackpadFinished(completed: Bool) {
        if let measured = trackpad.measuredTouchRate { onTouchRateMeasured?(measured.rate, measured.scale) }
        if completed {
            for edit in core.takeQueueForCompletion() { edit() }
        } else {
            core.discardQueue()
        }
        updateAutomaticShift()
        onUndoAvailabilityChanged?()
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
        // sooner), and the repeats follow on the schedule from touch-down.
        deletePressedAt = timestamp
        deleteRepeatIndex = 0
        schedule(at: deleteRepeat.firstDeletion, unit: .character)
    }

    /// A release before the first deletion deletes once; a cancellation (the system's, or the menu
    /// opening over the keys) deletes nothing.
    func keyAreaEndedDelete(_ keyArea: KeyAreaView, cancelled: Bool) {
        let releasedEarly = deletePressedAt != nil && deleteRepeatIndex == 0
        endDeleteRepeat()
        if releasedEarly, !cancelled { delete(.character) }
    }

    /// Schedules the next deletion `time` seconds after touch-down.
    private func schedule(at time: TimeInterval, unit: DeleteRepeat.Unit) {
        guard let pressedAt = deletePressedAt else { return }
        // Touch timestamps and CACurrentMediaTime share the same clock.
        let delay = max(time - (now - pressedAt), 0)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDelete(unit) }
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
    }

    private func fireDelete(_ unit: DeleteRepeat.Unit) {
        guard deletePressedAt != nil else { return }
        delete(unit)
        deleteRepeatIndex += 1
        let next = deleteRepeat.repeatAt(deleteRepeatIndex)
        schedule(at: next.time, unit: next.unit)
    }

    /// One deletion of the held key. Every one is a new edit: an undo offered since the last one ends
    /// here, before anything is deleted.
    private func delete(_ unit: DeleteRepeat.Unit) {
        whenIdle { [weak self] in
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
        deletePressedAt = nil
        deleteRepeatIndex = 0
    }

    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView) {
        endDeleteRepeat()
        // Moving the caret is an edit: the undo for a dictation ends, and the gesture owns what follows.
        userEdit()
        let multipliers = trackpadMultipliers()
        trackpad.parameters = TrackpadParameters.standard.tuned(sensitivity: multipliers.sensitivity,
                                                                acceleration: multipliers.acceleration)
        trackpad.begin(fieldWidth: keyArea.bounds.width)
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
