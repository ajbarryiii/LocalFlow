import UIKit

/// The editing side of the keyboard: typing, the held delete key, trackpad mode, dictated text and
/// its undo. The rules live in KeyboardCore; this class applies them to the text proxy.
///
/// It owns the edit generation (`EditTracker`). Typing, each delete (the first and every repeat),
/// entering trackpad mode, a dictated insertion, a focus change and any host callback our own
/// operation did not cause all advance it, which ends an undo and a trackpad gesture for good.
/// While a trackpad gesture runs or settles, text edits wait, so nothing is typed while the caret
/// may be mid-move. The context before the caret is read in memory only and never stored or
/// logged; the inserted text for undo and the typing tail are dropped on hiding.
@MainActor
final class KeyboardInput: KeyAreaViewDelegate {
    private weak var controller: UIInputViewController?
    private weak var keyArea: KeyAreaView?
    private var typing = TypingState()
    private var tail = ContextTail()
    private var edits = EditTracker()
    private var undo = UndoTracker()
    private var documentID: UUID?
    private let deleteRepeat = DeleteRepeat()
    private var deletePressedAt: TimeInterval?
    private var deleteRepeatIndex = 0
    private var deleteTimer: Timer?
    private var undoTimer: Timer?
    private var undoExpiry: Timer?
    /// Edits that arrived while a trackpad gesture was running or settling, in order.
    private var waitingEdits: [() -> Void] = []
    let trackpad: TrackpadDriver
    /// Trackpad mode started (true) or ended (false), to dim the dictation bar and play a haptic.
    var onTrackpadChange: ((Bool) -> Void)?
    /// Whether Undo can be offered may have changed. Only state is read in response; never results.
    var onUndoAvailabilityChanged: (() -> Void)?
    /// The user's trackpad multipliers, read when a gesture starts.
    var trackpadMultipliers: () -> (sensitivity: Double, acceleration: Double) = { (1, 1) }

    init(controller: UIInputViewController, keyArea: KeyAreaView) {
        self.controller = controller
        self.keyArea = keyArea
        trackpad = TrackpadDriver(controller: controller)
        trackpad.currentGeneration = { [weak self] in self?.edits.generation ?? 0 }
        trackpad.onAdjust = { [weak self] in self?.edits.ownOperation(at: CACurrentMediaTime()) }
        trackpad.onFinished = { [weak self] in self?.trackpadFinished() }
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private var currentBefore: String? { tail.current(proxyBefore: proxy?.documentContextBeforeInput) }

    private var now: TimeInterval { CACurrentMediaTime() }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset() {
        documentID = proxy?.documentIdentifierIfAvailable
        invalidate()
        typing.resetTiming()
        let numeric: Set<UIKeyboardType> = [.numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad]
        typing.switchLayer(to: numeric.contains(proxy?.keyboardType ?? .default) ? .numbers : .letters)
        updateAutomaticShift()
    }

    /// The keyboard is hiding: end every gesture and drop the undo text and the typing tail.
    func stop() {
        endDeleteRepeat()
        keyArea?.cancelAllTouches()
        trackpad.cancel(at: now)
        waitingEdits = []
        undo.invalidate()
        tail.forget()
        stopUndoTimers()
        onUndoAvailabilityChanged?()
    }

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback. Only `textDidChange` was
    /// measured to follow `adjustTextPosition`, so only it acknowledges a trackpad adjustment.
    func hostChanged(textChanged: Bool) {
        let before = proxy?.documentContextBeforeInput
        let currentDocument = proxy?.documentIdentifierIfAvailable
        if currentDocument != documentID {
            // Another field: nothing from the old one applies here.
            documentID = currentDocument
            invalidate()
            typing.resetTiming()
        } else {
            let fits: Bool
            if trackpad.isActive {
                fits = trackpad.explains(before: before, after: proxy?.documentContextAfterInput)
            } else if undo.isUndoing {
                fits = undo.explains(contextBefore: before)
            } else {
                fits = undo.insertion.map { UndoTracker.provenTail(of: $0.text, contextBefore: before) > 0 } ?? false
            }
            if edits.hostCallback(at: now, fitsOwnOperation: fits) {
                // An outside change ends the undo and the gesture for good.
                undo.invalidate()
                trackpad.terminate()
                stopUndoTimers()
                onUndoAvailabilityChanged?()
            } else if textChanged, trackpad.isActive {
                trackpad.hostDidChange()
            }
            // Typing helpers keep their model only while the proxy agrees with it.
            let hadModel = tail.known != nil
            tail.proxyChanged(before: before)
            if hadModel, tail.known == nil { typing.resetTiming() }
        }
        updateAutomaticShift()
    }

    /// Ends whatever depended on the old document state.
    private func invalidate() {
        edits.change()
        undo.invalidate()
        // Cleared before terminating: edits meant for the old field must not run in this one.
        waitingEdits = []
        trackpad.terminate()
        tail.forget()
        stopUndoTimers()
        onUndoAvailabilityChanged?()
    }

    // MARK: Dictation and undo

    /// Inserts dictated text and makes it undoable. Waits while a trackpad gesture settles.
    func insertDictation(_ text: String) {
        whenIdle { [weak self] in
            guard let self, !text.isEmpty else { return }
            self.edits.change()
            self.insert(text)
            let insertedAt = self.now
            // A host that reports the insertion back reports it within the own-operation window.
            self.edits.ownOperation(at: insertedAt)
            self.undo.recordInsertion(text, documentID: self.proxy?.documentIdentifierIfAvailable,
                                      generation: self.edits.generation, at: insertedAt)
            self.scheduleUndoExpiry()
            self.typing.resetTiming()
            self.updateAutomaticShift()
            self.onUndoAvailabilityChanged?()
        }
    }

    var canUndoLastDictation: Bool {
        guard undo.insertion != nil, !trackpad.isActive else { return false }
        return undo.isOffered(documentID: proxy?.documentIdentifierIfAvailable, generation: edits.generation,
                              contextBefore: proxy?.documentContextBeforeInput, now: now)
    }

    /// Removes the last dictation progressively: only what the context proves, then re-checks.
    func undoLastDictation() {
        guard !trackpad.isActive, !undo.isUndoing else { return }
        run(undo.begin(documentID: proxy?.documentIdentifierIfAvailable, generation: edits.generation,
                       contextBefore: proxy?.documentContextBeforeInput, now: now))
    }

    private func run(_ first: UndoTracker.Step) {
        var step = first
        while case .delete(let count) = step {
            edits.ownOperation(at: now)
            deleteCharacters(count)
            step = undo.step(documentID: proxy?.documentIdentifierIfAvailable, generation: edits.generation,
                             contextBefore: proxy?.documentContextBeforeInput, now: now)
        }
        if step == .wait {
            guard undoTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.run(self.undo.step(documentID: self.proxy?.documentIdentifierIfAvailable,
                                            generation: self.edits.generation,
                                            contextBefore: self.proxy?.documentContextBeforeInput, now: self.now))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            undoTimer = timer
            return
        }
        undoTimer?.invalidate()
        undoTimer = nil
        typing.resetTiming()
        updateAutomaticShift()
        onUndoAvailabilityChanged?()
    }

    private func scheduleUndoExpiry() {
        undoExpiry?.invalidate()
        let timer = Timer(timeInterval: UndoTracker.window, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undo.expire(now: self.now + 0.001)
                self.tail.forget()
                self.onUndoAvailabilityChanged?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        undoExpiry = timer
    }

    private func stopUndoTimers() {
        undoTimer?.invalidate()
        undoTimer = nil
        if undo.insertion == nil {
            undoExpiry?.invalidate()
            undoExpiry = nil
        }
    }

    // MARK: Editing

    /// Runs an edit now, or after the trackpad gesture has finished settling.
    private func whenIdle(_ edit: @escaping () -> Void) {
        guard trackpad.isActive else {
            edit()
            return
        }
        if waitingEdits.count < 64 { waitingEdits.append(edit) }
    }

    private func trackpadFinished() {
        let edits = waitingEdits
        waitingEdits = []
        for edit in edits { edit() }
        updateAutomaticShift()
    }

    /// An edit by the user: it ends any undo and gesture that relied on the document as it was.
    private func userEdit() {
        edits.change()
        if undo.insertion != nil {
            undo.invalidate()
            stopUndoTimers()
            onUndoAvailabilityChanged?()
        }
    }

    private func insert(_ text: String) {
        guard let proxy, !text.isEmpty else { return }
        let before = proxy.documentContextBeforeInput
        proxy.insertText(text)
        tail.inserted(text, proxyBefore: before)
        tail.acknowledge(proxyBefore: proxy.documentContextBeforeInput)
    }

    private func deleteCharacters(_ count: Int) {
        guard let proxy, count > 0 else { return }
        let before = proxy.documentContextBeforeInput
        for _ in 0 ..< count { proxy.deleteBackward() }
        tail.deleted(graphemes: count, proxyBefore: before)
        tail.acknowledge(proxyBefore: proxy.documentContextBeforeInput)
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
        // Measured: the first deletion comes 0.087 s after touch-down (or at lift, if sooner), and the
        // repeats follow on the schedule from touch-down.
        deletePressedAt = timestamp
        deleteRepeatIndex = 0
        schedule(at: deleteRepeat.firstDeletion, unit: .character)
    }

    func keyAreaEndedDelete(_ keyArea: KeyAreaView) {
        let releasedEarly = deletePressedAt != nil && deleteRepeatIndex == 0
        endDeleteRepeat()
        if releasedEarly { delete(.character) }
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
        tail.forget()
        typing.resetTiming()
        onTrackpadChange?(true)
    }

    func keyArea(_ keyArea: KeyAreaView, movedTrackpadBy dx: Double, dy: Double) {
        trackpad.move(dx: dx, dy: dy)
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
