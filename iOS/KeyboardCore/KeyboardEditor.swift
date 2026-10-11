import Foundation

/// The keyboard's editing side without UIKit (ARCHITECTURE.md, "Typing model v2: immediate
/// execution"): keys, the held delete key's deletions, dictated text and its undo, the trackpad and
/// host callbacks. `KeyboardInput` adapts it to the key area, the text proxy and timers; tests drive it
/// with a fake document.
///
/// - **Immediate execution.** A key edits through the proxy the moment it is typed (released), as on
///   every other iOS keyboard, with the shift and layer in effect then. Nothing is queued, delayed or
///   batched; the proxy applies edits in the order they are issued, so hiding loses nothing typed.
/// - **The trackpad never delays a key.** Any key's touch-down ends any gesture on the spot
///   (`keyTouchedDown`, `TrackpadController.interrupt`): nothing more is adjusted, and a probe's outcome
///   is abandoned. A key typed exactly as a probe crosses a cluster may land inside it (the accepted
///   residual).
/// - **Field binding.** A key goes to the field current when it is typed. It is cancelled only when
///   the field it was pressed in and the current one are both identified and differ; a missing
///   identity never blocks it. A field the proxy serves before its first callback is adopted first, so
///   the key is cased from that field's text.
/// - **Shift and double space.** Every host callback that is not a recognized echo of our own edits (or
///   of the gesture's own adjustments) starts the space and shift timing over and derives the shift from
///   the text again.
/// - **Own edits** are recorded (`EditingCore.recordOwnEdit`), so their echoes never count as outside
///   changes, while Undo fails closed.
/// - **The text before the caret** is the proxy's, or the typing tail's while the proxy has not shown
///   our edits or the gesture's landing yet (`ContextTail`). The proxy can show an own edit late and
///   with no callback, so for `contextWatch` after each one the shift follows it every frame.
/// Context is read in memory only; the typing tail is dropped on hiding.
final class KeyboardEditor {
    /// How long after an own edit the shift keeps following the proxy, which may show the edit late and
    /// with no callback.
    static let contextWatch: TimeInterval = 0.5

    let core: EditingCore
    let trackpad: TrackpadController
    private(set) var typing = TypingState()
    private(set) var tail = ContextTail()
    /// Until then (after an own edit), each frame re-reads the text before the caret for the shift.
    private var contextWatchUntil: TimeInterval?
    /// A key ended a gesture whose last adjustment's outcome is unknown (a probe or a jump abandoned):
    /// the proxy's reading then, which may not show where the host has the caret. While the proxy still
    /// reads exactly that, an edit starts on that unverified reading (`ContextTail.typedOnUnverified`): a
    /// proxy showing what was typed supersedes it, and deleting into it leaves the proxy to answer. A
    /// callback, or any other reading, ends this.
    private var untrustedReading: String?? = nil
    /// The field's autocapitalization, read when the shift is updated.
    var autocapitalization: () -> AutocapitalizationMode = { .sentences }
    /// The layer, the shift or the typing tail may have changed.
    var onStateChanged: (() -> Void)?
    /// Whether Undo can be offered may have changed.
    var onUndoChanged: (() -> Void)?
    /// A trackpad session ended (true: completed).
    var onTrackpadFinished: ((Bool) -> Void)?
    /// Another field (its identity, nil if none) became current, by a callback or adopted for a key: held
    /// keys bind to it or end (`KeyTouchModel.fieldChanged`, `HeldDeleteKey.fieldChanged`).
    var onFieldChanged: ((UUID?) -> Void)?

    init(document: TextDocument, trackpad: TrackpadController) {
        core = EditingCore(document: document)
        self.trackpad = trackpad
        core.adjustments = trackpad
        trackpad.currentGeneration = { [weak self] in self?.core.generation ?? 0 }
        trackpad.onFinished = { [weak self] completed in self?.trackpadFinished(completed: completed) }
    }

    var document: TextDocument { core.document }

    /// The best estimate of the text before the caret: the proxy, or what this keyboard just typed.
    var currentBefore: String? { tail.current(proxyBefore: document.contextBefore) }

    /// A gesture is running or settling: a dictated result stays unclaimed in the shared files until it
    /// can be inserted at once.
    var isBusy: Bool { trackpad.isActive }

    /// `service` must be called every frame: the proxy may still show an own edit late.
    var needsService: Bool { contextWatchUntil != nil }

    /// The clock the typing tail is forgotten by.
    var tailExpiresAt: TimeInterval? { tail.expiresAt }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset(numeric: Bool) {
        // A cancelled jump still watched since the keyboard hid goes on in the same field; anything else
        // from before ends here.
        trackpad.appeared()
        core.reset()
        tail.forget()
        untrustedReading = nil
        contextWatchUntil = nil
        typing.resetTiming()
        typing.switchLayer(to: numeric ? .numbers : .letters)
        updateAutomaticShift()
        onUndoChanged?()
    }

    /// The keyboard is hiding: the trackpad stops (an outstanding probe rolled back) and every copy of
    /// the field's context goes. Everything typed has already been applied.
    func hide(now: TimeInterval) {
        trackpad.hide(at: now)
        core.hide()
        tail.forget()
        untrustedReading = nil
        contextWatchUntil = nil
        onStateChanged?()
        onUndoChanged?()
    }

    func expireTail(now: TimeInterval) {
        tail.expire(now: now)
        onStateChanged?()
    }

    // MARK: Host callbacks

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback.
    @discardableResult
    func hostChanged(textChanged: Bool, now: TimeInterval) -> EditingCore.CallbackOutcome {
        let outcome = core.hostChanged(textChanged: textChanged, now: now)
        // The proxy now shows the host's own context.
        untrustedReading = nil
        switch outcome {
        case .own, .ownEdit:
            break
        case .outside:
            // The field changed under the keyboard (a caret tap, the host app's own edit, or a report
            // nothing explains): the gesture ends, and the space and shift timing starts over.
            trackpad.abort()
            typing.resetTiming()
            tail.forget()
        case .newField:
            fieldChanged()
        }
        if outcome != .own { onUndoChanged?() }
        // Typing helpers keep their model only while the proxy agrees with it.
        let hadModel = tail.known != nil
        tail.proxyChanged(before: document.contextBefore)
        if hadModel, tail.known == nil { typing.resetTiming() }
        updateAutomaticShift()
        return outcome
    }

    /// Another field (or none): nothing from the old one applies here.
    private func fieldChanged() {
        trackpad.fieldChanged()
        tail.forget()
        untrustedReading = nil
        contextWatchUntil = nil
        typing.resetTiming()
        onFieldChanged?(document.documentID)
    }

    // MARK: Keys

    /// Any key touched down (characters, space, Return, delete, Shift, layer keys): trackpad settlement
    /// or verification ends on the spot (ARCHITECTURE.md, "Typing model v2"), so nothing the gesture
    /// still hears from can move the caret before the key acts. A character still inserts at its release.
    func keyTouchedDown(now: TimeInterval) {
        trackpad.interrupt(at: now)
    }

    /// A key acted: characters, space and return on release or rollover; shift and layer keys on
    /// touch-down; delete only from VoiceOver (the held delete key uses `heldDelete`). `field` is the
    /// field identified when the key was pressed (nil if none was).
    func press(_ action: KeyAction, field: UUID?, at timestamp: TimeInterval, now: TimeInterval) {
        switch action {
        case .shift:
            trackpad.interrupt(at: now)
            typing.tapShift(at: timestamp)
            onStateChanged?()
        case .layer(let layer):
            trackpad.interrupt(at: now)
            typing.switchLayer(to: layer)
            updateAutomaticShift()
        case .nextKeyboard:
            break
        case .character, .space, .returnKey, .delete:
            type(field: field, now: now) { [self] before in resolve(action, before: before, at: timestamp) }
        }
    }

    /// One deletion of the held delete key, pressed in `field` (nil if none was identified).
    func heldDelete(_ unit: DeleteRepeat.Unit, field: UUID?, now: TimeInterval) {
        type(field: field, now: now) { [self] before in
            var deleted = 0
            var text = before ?? ""
            switch unit {
            case .character:
                deleted = 1
            case .words(let count):
                for _ in 0 ..< max(count, 1) {
                    // One grapheme when nothing before the caret is visible (often a hidden line break).
                    let graphemes = max(WordBoundaries.previousWord(before: text).graphemes, 1)
                    deleted += graphemes
                    text = String(text.dropLast(graphemes))
                }
            }
            typing.didDelete()
            return (deleted, "")
        }
    }

    /// Inserts dictated text, undoable, at once, in the field the proxy serves now (the caller has bound
    /// the result to it, and claims it only for this). Ends any gesture on the spot, like a key.
    func insertDictation(_ text: String, now: TimeInterval) {
        guard !text.isEmpty else { return }
        adoptCurrentField()
        trackpad.interrupt(at: now)
        tail.forget()
        core.insertDictation(text, now: now)
        typing.resetTiming()
        contextWatchUntil = now + Self.contextWatch
        updateAutomaticShift()
        onUndoChanged?()
    }

    /// While `needsService`, every frame: the proxy may show an own edit only now, with no callback
    /// (measured: hosts never report our edits), so the shift follows the text it shows. The memo keeps a
    /// shift the user set while the text calls for the same.
    func service(now: TimeInterval) {
        guard let until = contextWatchUntil else { return }
        if now >= until { contextWatchUntil = nil }
        guard !trackpad.isActive else { return }
        let shift = typing.shift
        applyAutomaticShift()
        if typing.shift != shift { onStateChanged?() }
    }

    /// A key's edit, now: refused only when it was pressed in another identified field; any gesture
    /// ends first, so the key reads where the caret lands.
    private func type(field: UUID?, now: TimeInterval, resolve: (String?) -> (deletes: Int, text: String)) {
        if let field, let current = document.documentID, field != current { return }
        adoptCurrentField()
        trackpad.interrupt(at: now)
        let edit = resolve(currentBefore)
        userEdit()
        if edit.deletes > 0 { deleteGraphemes(edit.deletes, now: now) }
        if !edit.text.isEmpty { insert(edit.text, now: now) }
        contextWatchUntil = now + Self.contextWatch
        updateAutomaticShift()
    }

    /// A field the proxy serves before its first callback is the current one: what the old one left
    /// (the gesture, the typing tail, the space and shift timing) goes, and the shift follows its text.
    private func adoptCurrentField() {
        guard core.adoptCurrentField() else { return }
        fieldChanged()
        updateAutomaticShift()
        onUndoChanged?()
    }

    /// What a key does, decided as it is typed. Changes the typing state as the key does.
    private func resolve(_ action: KeyAction, before: String?, at timestamp: TimeInterval) -> (deletes: Int, text: String) {
        switch action {
        case .character(let character):
            let text = typing.text(for: character)
            typing.didTypeCharacter(text)
            return (0, text)
        case .space:
            switch typing.spaceEdit(before: before, at: timestamp) {
            case .space: return (0, " ")
            case .replaceSpaceWithPeriod: return (1, ". ")
            }
        case .returnKey:
            typing.didTypeReturn()
            return (0, "\n")
        case .delete:
            typing.didDelete()
            return (1, "")
        case .shift, .layer, .nextKeyboard:
            return (0, "")
        }
    }

    /// The trackpad session ended: the caret is where the gesture left it, or on its way there, so typing
    /// reads the text before it there until the proxy shows it.
    private func trackpadFinished(completed: Bool) {
        if let landing = trackpad.finishedLanding {
            tail.moved(before: landing, proxyBefore: document.contextBefore, at: trackpad.lastTimestamp)
        } else if trackpad.finishedByKey {
            untrustedReading = .some(document.contextBefore)
        }
        updateAutomaticShift()
        onTrackpadFinished?(completed)
    }

    // MARK: Trackpad mode

    /// A trackpad gesture starts with this layout. Moving the caret is an edit: a dictation's undo ends,
    /// and the gesture owns what follows. False without a field identity.
    @discardableResult
    func beginTrackpad(layout: any LineLayout, linePitch: Double, layoutWidth: Double) -> Bool {
        if trackpad.isActive { trackpad.stop() }
        userEdit()
        tail.forget()
        untrustedReading = nil
        typing.resetTiming()
        onStateChanged?()
        return trackpad.begin(layout: layout, linePitch: linePitch, layoutWidth: layoutWidth)
    }

    // MARK: Undo

    func canUndo(now: TimeInterval) -> Bool {
        core.canUndo(now: now)
    }

    func beginUndo(now: TimeInterval) -> UndoTracker.Step {
        guard !isBusy else { return .stopped }
        tail.forget()
        return finishUndoStep(core.beginUndo(now: now), now: now)
    }

    func continueUndo(now: TimeInterval) -> UndoTracker.Step {
        finishUndoStep(core.continueUndo(now: now), now: now)
    }

    private func finishUndoStep(_ step: UndoTracker.Step, now: TimeInterval) -> UndoTracker.Step {
        if step != .wait {
            contextWatchUntil = now + Self.contextWatch
            typing.resetTiming()
            updateAutomaticShift()
            onUndoChanged?()
        }
        return step
    }

    // MARK: Edits

    /// An edit by the user: it ends any undo that relied on the document as it was.
    private func userEdit() {
        let hadUndo = core.undo.insertion != nil
        core.userEdit()
        if hadUndo { onUndoChanged?() }
    }

    private func insert(_ text: String, now: TimeInterval) {
        let before = document.contextBefore
        document.insertText(text)
        core.recordOwnEdit(now: now)
        if untrusts(before), tail.known == nil {
            tail.typedOnUnverified(text, reading: before, at: now)
        } else {
            tail.inserted(text, proxyBefore: before, at: now)
        }
        tail.acknowledge(proxyBefore: document.contextBefore)
    }

    private func deleteGraphemes(_ count: Int, now: TimeInterval) {
        let before = document.contextBefore
        // With text selected, the first deletion removes only the selection: the text before stays.
        let deleted = document.hasSelection ? count - 1 : count
        for _ in 0 ..< count { document.deleteBackward() }
        core.recordOwnEdit(now: now)
        if untrusts(before), tail.known == nil {
            // Deleted into a start whose text is unknown: the proxy answers.
            tail.forget()
        } else {
            tail.deleted(graphemes: deleted, proxyBefore: before, at: now)
        }
        tail.acknowledge(proxyBefore: document.contextBefore)
    }

    /// Whether this proxy reading is the untrusted one (`untrustedReading`): an edit on it starts on an
    /// unverified reading (`ContextTail.typedOnUnverified`). Any other reading ends the distrust.
    private func untrusts(_ before: String?) -> Bool {
        guard case .some(let reading) = untrustedReading else { return false }
        guard reading == before else {
            untrustedReading = nil
            return false
        }
        return true
    }

    private func updateAutomaticShift() {
        applyAutomaticShift()
        onStateChanged?()
    }

    private func applyAutomaticShift() {
        typing.updateAutomaticShift(AutoCapitalization.shouldCapitalize(before: currentBefore, mode: autocapitalization()))
    }
}
