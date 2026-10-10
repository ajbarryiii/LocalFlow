import Foundation

/// The keyboard's editing side without UIKit (ARCHITECTURE.md, "Typing correctness is paramount"):
/// keys, the held delete key's deletions, dictated text and its undo, the trackpad's settlement and
/// host callbacks. `KeyboardInput` adapts it to the key area, the text proxy and timers; tests drive
/// it with a fake document.
///
/// - **Press order.** Every key is resolved when it is pressed: its text (with the shift and layer in
///   effect then), what it deletes, and the shift state it leaves. It runs at once, after the trackpad
///   settles on the spot (`TrackpadController.settleNow`), unless it must wait: for the trackpad (a
///   probe out, a split cluster to repair, a boundary to verify after an outside change), for a
///   Return's pause, or for the field's identity. Waiting keys run in press order as soon as they
///   may (`service`, every frame while any wait).
/// - **One deadline.** No key waits longer than `maximumWait` from the earliest waiting key's press:
///   then the trackpad ends with a safe boundary recovery (`TrackpadController.forceRelease`), and a
///   key whose field still has no identity is dropped, never typed unidentified.
/// - **Field binding.** A key runs only in the field it was pressed in, identified (non-nil). One
///   pressed while the field had no identity binds to the first identity that appears.
/// - **Return's pause.** After a Return (or dictated text that presses it) runs, the keys after it wait
///   `returnBarrier`, or until the host reports another field, on every path, since a Return can move
///   the host to another field over several frames; a key pressed in the old field never lands in the
///   new one.
/// - **Gestures** begun while keys wait start once they have run, with the finger's movement so far.
/// - **Own edits** are recorded (`EditingCore.recordOwnEdit`), so their reports never count as outside
///   changes, while Undo fails closed.
/// - **The text before the caret** is the proxy's, or the typing tail's while the proxy has not shown
///   our edits or the gesture's landing yet (`ContextTail`). The proxy can show an own edit late and
///   with no callback, so for `contextWatch` after each one the shift follows it every frame.
/// Context is read in memory only; the waiting keys and the typing tail are dropped on hiding.
final class KeyboardEditor {
    /// How long a key may wait, from the earliest waiting key's press.
    static let maximumWait: TimeInterval = 0.4
    /// How long keys after a Return wait for the host to move to another field.
    static let returnBarrier: TimeInterval = 0.1
    /// How long after an own edit the shift keeps following the proxy, which may show the edit late and
    /// with no callback.
    static let contextWatch: TimeInterval = 0.5

    /// A key's effect, resolved when it was pressed.
    struct ResolvedKey: Equatable {
        enum Kind: Equatable { case typed, dictation }
        var kind = Kind.typed
        /// Graphemes deleted before the caret, then the text inserted.
        var deletes = 0
        var text = ""
        /// The field it was pressed in; nil until one has been identified.
        var field: UUID?
        /// A held delete key's press, so cancelling the press revokes deletions not yet made.
        var token: Int?
        var pressedAt: TimeInterval = 0
    }

    /// A gesture begun while keys waited: started once they have run.
    private struct DeferredGesture {
        var layout: any LineLayout
        var linePitch: Double
        var layoutWidth: Double
        var moves: [(dx: Double, dy: Double, timestamp: TimeInterval)] = []
        var ended: (at: TimeInterval, cancelled: Bool)?
    }

    let core: EditingCore
    let trackpad: TrackpadController
    private(set) var typing = TypingState()
    private(set) var tail = ContextTail()
    /// Keys that must wait, in press order, already resolved.
    private(set) var pendingKeys: [ResolvedKey] = []
    /// The text before the caret when keys started waiting (and whether text was selected then), and as
    /// it will be once they have run.
    private var pendingBase: String?
    private var pendingBaseSelected = false
    private var pendingBefore: String?
    /// Keys wait until then after a Return ran.
    private(set) var barrierUntil: TimeInterval?
    /// Until then (after an own edit), each frame re-reads the text before the caret for the shift.
    private var contextWatchUntil: TimeInterval?
    private var deferredGesture: DeferredGesture?
    /// The field's autocapitalization, read when the shift is updated.
    var autocapitalization: () -> AutocapitalizationMode = { .sentences }
    /// The layer, the shift or the typing tail may have changed.
    var onStateChanged: (() -> Void)?
    /// Whether Undo can be offered may have changed.
    var onUndoChanged: (() -> Void)?
    /// A trackpad session started (a deferred gesture included): frames are needed.
    var onTrackpadStarted: (() -> Void)?
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
    var isBusy: Bool { trackpad.isActive || isWaiting }

    /// Keys or a gesture wait.
    var isWaiting: Bool { !pendingKeys.isEmpty || deferredGesture != nil }

    /// `service` must be called every frame: keys or a gesture wait, or the proxy may still show an own
    /// edit late.
    var needsService: Bool { isWaiting || contextWatchUntil != nil }

    /// The clock the typing tail is forgotten by.
    var tailExpiresAt: TimeInterval? { tail.expiresAt }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset(numeric: Bool) {
        // A cancelled jump still watched since the keyboard hid ends here: the new appearance starts with
        // no gesture and no keys from before.
        dropPendingKeys()
        deferredGesture = nil
        trackpad.stop()
        core.reset()
        tail.forget()
        typing.resetTiming()
        typing.switchLayer(to: numeric ? .numbers : .letters)
        updateAutomaticShift()
        onUndoChanged?()
    }

    /// The keyboard is hiding: the trackpad stops (an outstanding probe rolled back), keys that may still
    /// run in their field do, and every copy of the field's context goes. Keys still behind a Return's
    /// pause, or without an identified field, are dropped: the field may be gone, and nothing typed
    /// after this could be verified.
    func hide(now: TimeInterval) {
        lastNow = now
        trackpad.hide(at: now)
        if !pendingKeys.isEmpty, trackpad.isActive { trackpad.forceRelease(at: now) }
        service(now: now)
        dropPendingKeys()
        deferredGesture = nil
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
            // An outside change ends the gesture; keys waiting on it still run once the caret is on a
            // whole-cluster boundary. The field changed under the keyboard: the space and shift timing
            // starts over.
            trackpad.abort()
            typing.resetTiming()
            tail.forget()
        case .newField:
            // Another field: nothing from the old one applies here. Keys pressed there never run here;
            // keys pressed here (or before any identity) still do, now that the field is known.
            trackpad.fieldChanged()
            barrierUntil = nil
            tail.forget()
            typing.resetTiming()
            service(now: now)
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
    /// field identified when the key was pressed (nil if none was).
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
        pendingBefore = Self.before(pendingBase, selected: pendingBaseSelected, after: pendingKeys)
        updateAutomaticShift()
    }

    /// Inserts dictated text, undoable, in the field identified now; settles the trackpad first, like a
    /// key.
    func insertDictation(_ text: String, now: TimeInterval) {
        guard !text.isEmpty else { return }
        submit(field: document.documentID, token: nil, now: now) { _ in ResolvedKey(kind: .dictation, text: text) }
    }

    /// Runs the keys that may run now, in press order, and enforces their deadline. Call every frame
    /// while `isWaiting`, and on any change that may let them run.
    func service(now: TimeInterval) {
        lastNow = now
        defer { startDeferredGesture(now: now) }
        if let until = contextWatchUntil, pendingKeys.isEmpty {
            // The proxy may show an own edit only now, with no callback (measured: hosts never report
            // our edits): the shift follows the text it shows. The memo keeps a shift the user set while
            // the text calls for the same.
            if now >= until { contextWatchUntil = nil }
            let shift = typing.shift
            if !trackpad.isActive { applyAutomaticShift() }
            if typing.shift != shift { onStateChanged?() }
        }
        guard let head = pendingKeys.first else { return }
        if trackpad.isActive {
            // Waiting on the trackpad, at most until the deadline; then it ends with a safe recovery, and
            // its end runs the keys.
            if now >= head.pressedAt + Self.maximumWait { trackpad.forceRelease(at: now) }
            return
        }
        while let key = pendingKeys.first {
            let expired = now >= key.pressedAt + Self.maximumWait
            if let barrier = barrierUntil, now < barrier, !expired { break }
            barrierUntil = nil
            guard let current = document.documentID else {
                // Still no identity: the key waits for one until its deadline, and is never typed into an
                // unidentified field.
                guard expired else { break }
                pendingKeys.removeFirst()
                continue
            }
            pendingKeys.removeFirst()
            // Pressed in another field: never typed here.
            guard (key.field ?? current) == current else { continue }
            execute(key, now: now)
        }
        if pendingKeys.isEmpty {
            pendingBase = nil
            pendingBefore = nil
        }
        updateAutomaticShift()
    }

    /// The trackpad session ended. Keys that waited on it run now, in press order, as far as they may.
    private func trackpadFinished(completed: Bool) {
        // The caret is where the gesture left it, or on its way there: typing reads the text before it
        // there until the proxy shows it.
        if let landing = trackpad.finishedLanding {
            tail.moved(before: landing, proxyBefore: document.contextBefore, at: max(lastNow, trackpad.lastTimestamp))
        }
        service(now: max(lastNow, trackpad.lastTimestamp))
        // The caret settled somewhere new: the shift follows what the text there calls for, before any
        // key is resolved.
        updateAutomaticShift()
        onTrackpadFinished?(completed)
    }

    // MARK: Trackpad mode

    /// A trackpad gesture starts with this layout. Moving the caret is an edit: a dictation's undo ends,
    /// and the gesture owns what follows. While keys wait, it starts once they have run (at most their
    /// deadline). False without a field identity.
    @discardableResult
    func beginTrackpad(layout: any LineLayout, linePitch: Double, layoutWidth: Double, now: TimeInterval) -> Bool {
        lastNow = now
        service(now: now)
        guard pendingKeys.isEmpty else {
            deferredGesture = DeferredGesture(layout: layout, linePitch: linePitch, layoutWidth: layoutWidth)
            return true
        }
        return startGesture(layout: layout, linePitch: linePitch, layoutWidth: layoutWidth)
    }

    /// One touch event of the trackpad's finger.
    func trackpadMoved(dx: Double, dy: Double, timestamp: TimeInterval) {
        if deferredGesture != nil {
            deferredGesture?.moves.append((dx, dy, timestamp))
        } else {
            trackpad.move(dx: dx, dy: dy, timestamp: timestamp)
        }
    }

    /// The trackpad's finger lifted (or the system cancelled it).
    func trackpadEnded(at timestamp: TimeInterval, cancelled: Bool) {
        if deferredGesture != nil {
            deferredGesture?.ended = (timestamp, cancelled)
        } else if cancelled {
            trackpad.cancel(at: timestamp)
        } else {
            trackpad.end(at: timestamp)
        }
    }

    private func startGesture(layout: any LineLayout, linePitch: Double, layoutWidth: Double) -> Bool {
        if trackpad.isActive { trackpad.stop() }
        userEdit()
        tail.forget()
        typing.resetTiming()
        onStateChanged?()
        guard trackpad.begin(layout: layout, linePitch: linePitch, layoutWidth: layoutWidth) else { return false }
        onTrackpadStarted?()
        return true
    }

    private func startDeferredGesture(now: TimeInterval) {
        guard let gesture = deferredGesture, pendingKeys.isEmpty, !trackpad.isActive else { return }
        deferredGesture = nil
        guard startGesture(layout: gesture.layout, linePitch: gesture.linePitch, layoutWidth: gesture.layoutWidth) else {
            return
        }
        for move in gesture.moves { trackpad.move(dx: move.dx, dy: move.dy, timestamp: move.timestamp) }
        if let ended = gesture.ended {
            if ended.cancelled { trackpad.cancel(at: max(ended.at, now)) } else { trackpad.end(at: max(ended.at, now)) }
        }
    }

    // MARK: Undo

    func canUndo(now: TimeInterval) -> Bool {
        !isWaiting && core.canUndo(now: now)
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
            lastNow = now
            contextWatchUntil = now + Self.contextWatch
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
        let current = document.documentID
        // Pressed in another identified field: never typed into this one.
        if let field, let current, field != current { return }
        // The trackpad settles on the spot; a key waits on it only while it must.
        if pendingKeys.isEmpty, deferredGesture == nil, trackpad.isActive { _ = trackpad.settleNow(at: now) }
        let waits = !pendingKeys.isEmpty || deferredGesture != nil || trackpad.isActive || current == nil
            || barrierUntil.map { now < $0 } == true
        if waits, pendingKeys.isEmpty {
            pendingBase = currentBefore
            pendingBaseSelected = document.hasSelection
            pendingBefore = pendingBase
        }
        var key = resolve(waits ? pendingBefore : currentBefore)
        key.field = field ?? current
        key.token = token
        key.pressedAt = now
        if waits {
            pendingKeys.append(key)
            pendingBefore = Self.before(pendingBase, selected: pendingBaseSelected, after: pendingKeys)
            service(now: now)
        } else {
            execute(key, now: now)
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

    /// The text before the caret once `keys` have run from `base`. A selection goes with the first edit:
    /// the first deletion removes only the selection, and inserted text replaces it.
    private static func before(_ base: String?, selected: Bool, after keys: [ResolvedKey]) -> String? {
        var before = base
        var selected = selected
        for key in keys where key.deletes > 0 || !key.text.isEmpty {
            let deletes = selected ? max(key.deletes - 1, 0) : key.deletes
            selected = false
            before = String((before ?? "").dropLast(deletes)) + key.text
        }
        return before
    }

    private func dropPendingKeys() {
        pendingKeys = []
        pendingBase = nil
        pendingBefore = nil
        barrierUntil = nil
        contextWatchUntil = nil
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
        // A Return can move the host to another field: what follows waits for it to.
        if key.text.contains("\n") { barrierUntil = now + Self.returnBarrier }
        contextWatchUntil = now + Self.contextWatch
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
        // With text selected, the first deletion removes only the selection: the text before stays.
        let selected = document.hasSelection
        let deleted = selected ? count - 1 : count
        for _ in 0 ..< count { document.deleteBackward() }
        core.recordOwnEdit(now: now)
        tail.deleted(graphemes: deleted, proxyBefore: before, at: now)
        tail.acknowledge(proxyBefore: document.contextBefore)
    }

    /// Auto-capitalization from the text before the caret as it will be once waiting keys have run.
    private func updateAutomaticShift() {
        applyAutomaticShift()
        onStateChanged?()
    }

    private func applyAutomaticShift() {
        let before = pendingKeys.isEmpty ? currentBefore : pendingBefore
        typing.updateAutomaticShift(AutoCapitalization.shouldCapitalize(before: before, mode: autocapitalization()))
    }
}
