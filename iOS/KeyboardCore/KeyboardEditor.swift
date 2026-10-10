import Foundation

/// The keyboard's editing side without UIKit (ARCHITECTURE.md, "Typing correctness is paramount"):
/// keys, the held delete key's deletions, dictated text and its undo, the trackpad's settlement and
/// host callbacks. `KeyboardInput` adapts it to the key area, the text proxy and timers; tests drive
/// it with a fake document.
///
/// - **Press order.** Every key is resolved when it is pressed: its text (with the shift and layer in
///   effect then), what it deletes, and the shift state it leaves. It runs at once, after the trackpad
///   settles on the spot (`TrackpadController.settleNow`). Only while the trackpad has a probe out,
///   whose outcome may leave the caret inside a cluster (at most `syncTimeout`), do keys wait, already
///   resolved; then they run in press order. A Return ends such a run: the keys after it go on the
///   next frame (`continuePendingKeys`), since a Return can move the host to another field.
/// - **Field binding.** A key runs only in the field it was pressed in.
/// - **Nothing is dropped** because of the trackpad's bookkeeping: an aborted or ambiguous gesture
///   still lets waiting keys run, at the caret as it is (a split cluster is repaired first).
/// - **Own edits** are recorded (`EditingCore.recordOwnEdit`), so their reports never count as outside
///   changes, while Undo fails closed.
/// Context is read in memory only; the waiting keys and the typing tail are dropped on hiding.
final class KeyboardEditor {
    /// A key's effect, resolved when it was pressed.
    struct ResolvedKey: Equatable {
        enum Kind: Equatable { case typed, dictation }
        var kind = Kind.typed
        /// Graphemes deleted before the caret, then the text inserted.
        var deletes = 0
        var text = ""
        /// The field it was pressed in.
        var field: UUID?
        /// A held delete key's press, so cancelling the press revokes deletions not yet made.
        var token: Int?
    }

    let core: EditingCore
    let trackpad: TrackpadController
    private(set) var typing = TypingState()
    private(set) var tail = ContextTail()
    /// Keys pressed while the trackpad resolves a probe, in press order, already resolved.
    private(set) var pendingKeys: [ResolvedKey] = []
    /// The text before the caret when keys started waiting, and as it will be once they have run.
    private var pendingBase: String?
    private var pendingBefore: String?
    /// Waiting keys stopped after a Return; the rest run on the next frame.
    private(set) var needsContinuation = false
    /// The field's autocapitalization, read when the shift is updated.
    var autocapitalization: () -> AutocapitalizationMode = { .sentences }
    /// The layer, the shift or the typing tail may have changed.
    var onStateChanged: (() -> Void)?
    /// Whether Undo can be offered may have changed.
    var onUndoChanged: (() -> Void)?
    /// A trackpad session ended (true: completed), after the keys waiting on it ran.
    var onTrackpadFinished: ((Bool) -> Void)?

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

    /// Dictated text should wait in the shared files rather than in memory.
    var isBusy: Bool { trackpad.isActive || !pendingKeys.isEmpty }

    /// The clock the typing tail is forgotten by.
    var tailExpiresAt: TimeInterval? { tail.expiresAt }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset(numeric: Bool) {
        // A cancelled jump still watched since the keyboard hid ends here: the new appearance starts with
        // no gesture.
        trackpad.abort()
        dropPendingKeys()
        core.reset()
        tail.forget()
        typing.resetTiming()
        typing.switchLayer(to: numeric ? .numbers : .letters)
        updateAutomaticShift()
        onUndoChanged?()
    }

    /// The keyboard is hiding: the trackpad stops (an outstanding probe rolled back), keys still waiting
    /// run in their field if it is still there, and every copy of the field's context goes.
    func hide(now: TimeInterval) {
        lastNow = now
        trackpad.hide(at: now)
        runPendingKeys(now: now, untilReturn: false)
        dropPendingKeys()
        core.hide()
        tail.forget()
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
        lastNow = now
        let outcome = core.hostChanged(textChanged: textChanged, now: now)
        switch outcome {
        case .own, .ownEdit:
            break
        case .outside:
            // An outside change ends the gesture; keys waiting on it still run, where the caret is.
            trackpad.abort()
        case .newField:
            // Another field: nothing from the old one applies here. Keys pressed there never run here.
            trackpad.fieldChanged()
            runPendingKeys(now: now, untilReturn: false)
            dropPendingKeys()
            tail.forget()
            typing.resetTiming()
        }
        if outcome != .own { onUndoChanged?() }
        // Typing helpers keep their model only while the proxy agrees with it.
        let hadModel = tail.known != nil
        tail.proxyChanged(before: document.contextBefore)
        if hadModel, tail.known == nil { typing.resetTiming() }
        updateAutomaticShift()
        return outcome
    }

    // MARK: Keys

    /// A key acted: characters, space and return on release or rollover; shift and layer keys on
    /// touch-down; delete only from VoiceOver (the held delete key uses `heldDelete`). `field` is the
    /// field the key was pressed in.
    func press(_ action: KeyAction, field: UUID?, at timestamp: TimeInterval, now: TimeInterval) {
        switch action {
        case .shift:
            typing.tapShift(at: timestamp)
            onStateChanged?()
        case .layer(let layer):
            typing.switchLayer(to: layer)
            updateAutomaticShift()
        case .nextKeyboard:
            break
        case .character, .space, .returnKey, .delete:
            submit(field: field, token: nil, now: now) { [self] before in resolve(action, before: before, at: timestamp) }
        }
    }

    /// One deletion of the held delete key, bound to its press (`token`) and the field it began in.
    func heldDelete(_ unit: DeleteRepeat.Unit, token: Int, field: UUID?, now: TimeInterval) {
        submit(field: field, token: token, now: now) { [self] before in
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
            return ResolvedKey(deletes: deleted)
        }
    }

    /// The held delete key's press was cancelled: deletions it made stand, those still waiting never run.
    func revoke(token: Int) {
        guard pendingKeys.contains(where: { $0.token == token }) else { return }
        pendingKeys.removeAll { $0.token == token }
        pendingBefore = pendingKeys.reduce(pendingBase) { Self.applying($1, to: $0) }
        updateAutomaticShift()
    }

    /// Inserts dictated text, undoable; settles the trackpad first, like a key.
    func insertDictation(_ text: String, now: TimeInterval) {
        guard !text.isEmpty else { return }
        submit(field: document.documentID, token: nil, now: now) { _ in ResolvedKey(kind: .dictation, text: text) }
    }

    /// Waiting keys stopped after a Return: the next frame runs the rest.
    func continuePendingKeys(now: TimeInterval) {
        lastNow = now
        guard needsContinuation, !trackpad.isActive else { return }
        runPendingKeys(now: now, untilReturn: true)
        updateAutomaticShift()
    }

    /// The trackpad session ended. Keys that waited on it run now, in press order.
    private func trackpadFinished(completed: Bool) {
        runPendingKeys(now: max(lastNow, trackpad.lastTimestamp), untilReturn: true)
        updateAutomaticShift()
        onTrackpadFinished?(completed)
    }

    // MARK: Trackpad mode

    /// A trackpad gesture starts with this layout. Moving the caret is an edit: a dictation's undo ends,
    /// and the gesture owns what follows. False without a field identity.
    @discardableResult
    func beginTrackpad(layout: any LineLayout, linePitch: Double, layoutWidth: Double, now: TimeInterval) -> Bool {
        lastNow = now
        // Keys still waiting on an older session run first, so the new snapshot includes them.
        if trackpad.isActive { trackpad.abort() }
        runPendingKeys(now: now, untilReturn: false)
        userEdit()
        tail.forget()
        typing.resetTiming()
        onStateChanged?()
        return trackpad.begin(layout: layout, linePitch: linePitch, layoutWidth: layoutWidth)
    }

    // MARK: Undo

    func canUndo(now: TimeInterval) -> Bool {
        pendingKeys.isEmpty && core.canUndo(now: now)
    }

    func beginUndo(now: TimeInterval) -> UndoTracker.Step {
        guard !isBusy else { return .stopped }
        tail.forget()
        return finishUndoStep(core.beginUndo(now: now))
    }

    func continueUndo(now: TimeInterval) -> UndoTracker.Step {
        finishUndoStep(core.continueUndo(now: now))
    }

    private func finishUndoStep(_ step: UndoTracker.Step) -> UndoTracker.Step {
        if step != .wait {
            typing.resetTiming()
            updateAutomaticShift()
            onUndoChanged?()
        }
        return step
    }

    // MARK: Running keys

    /// The last time a caller passed in, for edits run from a trackpad callback.
    private var lastNow: TimeInterval = 0

    private func submit(field: UUID?, token: Int?, now: TimeInterval, resolve: (String?) -> ResolvedKey) {
        lastNow = now
        // Bound to the field it was pressed in: never typed into another one.
        guard field == document.documentID else { return }
        if pendingKeys.isEmpty, trackpad.isActive, !trackpad.settleNow(at: now) {
            // A probe is out: the keys wait for it, resolved now, in press order.
            pendingBase = currentBefore
            pendingBefore = pendingBase
        } else if !pendingKeys.isEmpty, !trackpad.isActive, !needsContinuation {
            runPendingKeys(now: now, untilReturn: false)
        }
        var key = resolve(pendingKeys.isEmpty && !trackpad.isSettlingForTyping ? currentBefore : pendingBefore)
        key.field = field
        key.token = token
        if pendingKeys.isEmpty, !trackpad.isSettlingForTyping {
            execute(key, now: now)
        } else {
            pendingKeys.append(key)
            pendingBefore = Self.applying(key, to: pendingBefore)
        }
        updateAutomaticShift()
    }

    /// What a key does, decided at its press. Changes the typing state as the press does.
    private func resolve(_ action: KeyAction, before: String?, at timestamp: TimeInterval) -> ResolvedKey {
        switch action {
        case .character(let character):
            let text = typing.text(for: character)
            typing.didTypeCharacter(text)
            return ResolvedKey(text: text)
        case .space:
            switch typing.spaceEdit(before: before, at: timestamp) {
            case .space: return ResolvedKey(text: " ")
            case .replaceSpaceWithPeriod: return ResolvedKey(deletes: 1, text: ". ")
            }
        case .returnKey:
            typing.didTypeReturn()
            return ResolvedKey(text: "\n")
        case .delete:
            typing.didDelete()
            return ResolvedKey(deletes: 1)
        case .shift, .layer, .nextKeyboard:
            return ResolvedKey()
        }
    }

    private static func applying(_ key: ResolvedKey, to before: String?) -> String? {
        guard key.deletes > 0 || !key.text.isEmpty else { return before }
        return String((before ?? "").dropLast(key.deletes)) + key.text
    }

    /// Runs the waiting keys in press order, each only in the field it was pressed in. With
    /// `untilReturn`, stops after a Return that ran (the host may move to another field).
    private func runPendingKeys(now: TimeInterval, untilReturn: Bool) {
        needsContinuation = false
        while !pendingKeys.isEmpty {
            let key = pendingKeys.removeFirst()
            guard key.field == document.documentID else { continue }
            execute(key, now: now)
            if untilReturn, key.text.contains("\n"), !pendingKeys.isEmpty {
                needsContinuation = true
                return
            }
        }
        pendingBase = nil
        pendingBefore = nil
    }

    private func dropPendingKeys() {
        pendingKeys = []
        pendingBase = nil
        pendingBefore = nil
        needsContinuation = false
    }

    private func execute(_ key: ResolvedKey, now: TimeInterval) {
        switch key.kind {
        case .dictation:
            tail.forget()
            core.insertDictation(key.text, now: now)
            typing.resetTiming()
            onUndoChanged?()
        case .typed:
            userEdit()
            if key.deletes > 0 { deleteGraphemes(key.deletes, now: now) }
            if !key.text.isEmpty { insert(key.text, now: now) }
        }
    }

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
        tail.inserted(text, proxyBefore: before, at: now)
        tail.acknowledge(proxyBefore: document.contextBefore)
    }

    private func deleteGraphemes(_ count: Int, now: TimeInterval) {
        let before = document.contextBefore
        for _ in 0 ..< count { document.deleteBackward() }
        core.recordOwnEdit(now: now)
        tail.deleted(graphemes: count, proxyBefore: before, at: now)
        tail.acknowledge(proxyBefore: document.contextBefore)
    }

    /// Auto-capitalization from the text before the caret as it will be once waiting keys have run.
    private func updateAutomaticShift() {
        let before = pendingKeys.isEmpty ? currentBefore : pendingBefore
        typing.updateAutomaticShift(AutoCapitalization.shouldCapitalize(before: before, mode: autocapitalization()))
        onStateChanged?()
    }
}
