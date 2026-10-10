import UIKit

/// The text proxy as `EditingCore` and `TrackpadController` see it.
@MainActor
private final class ProxyDocument: TextDocument, TrackpadHost {
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

    nonisolated func adjust(by offset: Int) {
        MainActor.assumeIsolated { proxy?.adjustTextPosition(byCharacterOffset: offset) }
    }
}

/// The editing side of the keyboard in UIKit: the key area's events, the text proxy, the held delete
/// key's timers, the display link and the timers of undo and the typing tail. The rules live in
/// KeyboardCore (`KeyboardEditor`, `EditingCore`, `UndoTracker`, `TrackpadController`, the typing
/// rules), where they are tested.
///
/// ARCHITECTURE.md, "Typing correctness is paramount": a key runs at once, after the trackpad settles
/// on the spot, in the field it was pressed in; only while a probe is out does it wait, resolved at its
/// press. Context is read in memory only and never stored or logged; every copy is dropped on hiding
/// and expires on its own clock otherwise.
@MainActor
final class KeyboardInput: KeyAreaViewDelegate {
    private weak var controller: UIInputViewController?
    private weak var keyArea: KeyAreaView?
    private let document: ProxyDocument
    private let editor: KeyboardEditor
    private let driver: TrackpadDriver
    private var deleteKey = HeldDeleteKey()
    private var deleteTimer: Timer?
    private var serviceTimer: Timer?
    private var undoTimer: Timer?
    private var undoExpiry: (timer: Timer, insertedAt: TimeInterval)?
    private var tailExpiry: Timer?
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
        document = ProxyDocument(controller: controller)
        let trackpad = TrackpadController(host: document)
        editor = KeyboardEditor(document: document, trackpad: trackpad)
        driver = TrackpadDriver(controller: controller, trackpad: trackpad)
        editor.autocapitalization = { [weak self] in self?.autocapitalization ?? .sentences }
        editor.onStateChanged = { [weak self] in self?.editorStateChanged() }
        editor.onUndoChanged = { [weak self] in self?.undoChanged() }
        editor.onTrackpadFinished = { [weak self] _ in self?.trackpadFinished() }
        editor.onTrackpadStarted = { [weak self] in self?.driver.run() }
        keyArea.currentField = { [weak controller] in controller?.textDocumentProxy.documentIdentifierIfAvailable }
    }

    var trackpad: TrackpadController { editor.trackpad }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private var now: TimeInterval { CACurrentMediaTime() }

    /// The trackpad is busy or keys are waiting: dictated text should wait in the shared files.
    var isBusy: Bool { editor.isBusy }

    private var autocapitalization: AutocapitalizationMode {
        switch proxy?.autocapitalizationType ?? .sentences {
        case .none: return .none
        case .words: return .words
        case .allCharacters: return .allCharacters
        default: return .sentences
        }
    }

    // MARK: Lifecycle

    /// The keyboard appeared: start fresh in whatever field it serves.
    func reset() {
        let numeric: Set<UIKeyboardType> = [.numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad]
        editor.reset(numeric: numeric.contains(proxy?.keyboardType ?? .default))
        stopUndoTimers()
    }

    /// The keyboard is hiding: end every gesture and held key and, synchronously, drop every copy of
    /// the field's context and identity (the trackpad snapshot and its layout, its unit, the undo text
    /// and anchors, the typing tail). A probe still out is rolled back first; keys waiting on it run in
    /// their field if it is still there.
    func stop() {
        cancelHeldActions()
        editor.hide(now: now)
        stopUndoTimers()
        tailExpiry?.invalidate()
        tailExpiry = nil
        serviceTimer?.invalidate()
        serviceTimer = nil
    }

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback.
    func hostChanged(textChanged: Bool) {
        // Another field: held keys and a held delete pressed in a different identified field end without
        // acting; those pressed in this one (before its first callback) or before any identity go on.
        guard editor.hostChanged(textChanged: textChanged, now: now) == .newField else { return }
        let field = proxy?.documentIdentifierIfAvailable
        if let token = deleteKey.cancel(ifBoundElsewhereThan: field) {
            editor.revoke(token: token)
            endDeleteRepeat()
        }
        keyArea?.cancelTouches(boundElsewhereThan: field)
    }

    /// Ends every held key (characters, space, delete) without typing, and a pending delete without
    /// deleting; revokes deletions the delete press has waiting. On hiding.
    private func cancelHeldActions() {
        if let token = deleteKey.cancel() { editor.revoke(token: token) }
        endDeleteRepeat()
        keyArea?.cancelAllTouches()
    }

    // MARK: Editor state

    private func editorStateChanged() {
        keyArea?.apply(layer: editor.typing.layer, shift: editor.typing.shift)
        scheduleTailExpiry()
        if editor.needsService { scheduleService() }
    }

    /// While keys (or a gesture) wait, the editor looks every frame whether they may run, and enforces
    /// their deadline; after an own edit, it follows the proxy for the shift.
    private func scheduleService() {
        guard serviceTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.serviceTimer = nil
                self.editor.service(now: self.now)
                if self.editor.needsService { self.scheduleService() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        serviceTimer = timer
    }

    private func trackpadFinished() {
        if let measured = trackpad.measuredTouchRate { onTouchRateMeasured?(measured.rate, measured.scale) }
        onUndoAvailabilityChanged?()
    }

    // MARK: Dictation and undo

    /// Inserts dictated text and makes it undoable, after the trackpad settles on the spot.
    func insertDictation(_ text: String) {
        editor.insertDictation(text, now: now)
    }

    var canUndoLastDictation: Bool { editor.canUndo(now: now) }

    /// Removes the last dictation progressively: only what the context proves, then re-checks.
    func undoLastDictation() {
        guard undoTimer == nil else { return }
        handle(editor.beginUndo(now: now))
    }

    private func handle(_ step: UndoTracker.Step) {
        guard step == .wait else {
            undoTimer?.invalidate()
            undoTimer = nil
            return
        }
        guard undoTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // A repeating timer outlives its owner unless told otherwise.
                guard let self else { return timer.invalidate() }
                self.handle(self.editor.continueUndo(now: self.now))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        undoTimer = timer
    }

    /// The undo was made, used or ended: its timers follow, and Undo's availability is published.
    private func undoChanged() {
        if let insertion = editor.core.undo.insertion {
            if undoExpiry?.insertedAt != insertion.insertedAt { scheduleUndoExpiry(insertedAt: insertion.insertedAt) }
        } else {
            stopUndoTimers()
        }
        onUndoAvailabilityChanged?()
    }

    private func scheduleUndoExpiry(insertedAt: TimeInterval) {
        undoExpiry?.timer.invalidate()
        let timer = Timer(timeInterval: max(insertedAt + UndoTracker.window - now, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undoExpiry = nil
                self.editor.core.expireUndo(now: self.now + 0.001)
                self.onUndoAvailabilityChanged?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        undoExpiry = (timer, insertedAt)
    }

    private func stopUndoTimers() {
        undoTimer?.invalidate()
        undoTimer = nil
        if editor.core.undo.insertion == nil {
            undoExpiry?.timer.invalidate()
            undoExpiry = nil
        }
    }

    // MARK: The typing tail

    /// The tail's own clock: set when a model is first held, never moved by more typing.
    private func scheduleTailExpiry() {
        guard let expiresAt = editor.tailExpiresAt else {
            tailExpiry?.invalidate()
            tailExpiry = nil
            return
        }
        guard tailExpiry == nil else { return }
        let timer = Timer(timeInterval: max(expiresAt - now, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tailExpiry = nil
                // A model held since then gets the rest of its own lifetime.
                self.editor.expireTail(now: self.now)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tailExpiry = timer
    }

    // MARK: KeyAreaViewDelegate

    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, field: UUID?, timestamp: TimeInterval) {
        editor.press(action, field: field, at: timestamp, now: now)
    }

    func keyAreaBeganDelete(_ keyArea: KeyAreaView, timestamp: TimeInterval) {
        endDeleteRepeat()
        // Measured on device: the first deletion comes 0.12 s after touch-down (or at release, if
        // sooner), and the repeats follow on the schedule from touch-down. The press is bound to this
        // field; every deletion it makes carries its token.
        let press = deleteKey.began(at: timestamp, documentID: proxy?.documentIdentifierIfAvailable)
        schedule(press.token, at: press.firstAt, pressedAt: timestamp)
    }

    /// A release before the first deletion deletes once, in the field the press began in; a
    /// cancellation (the system's, the menu opening over the keys, hiding) deletes nothing and revokes
    /// any deletion of the press still waiting on the trackpad.
    func keyAreaEndedDelete(_ keyArea: KeyAreaView, cancelled: Bool) {
        endDeleteRepeat()
        guard let ended = deleteKey.ended(cancelled: cancelled, documentID: proxy?.documentIdentifierIfAvailable) else { return }
        if cancelled {
            editor.revoke(token: ended.token)
        } else if ended.deleteOnce {
            editor.heldDelete(.character, token: ended.token, field: ended.field, now: now)
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
        editor.heldDelete(fired.unit, token: token, field: fired.field, now: now)
        schedule(token, at: fired.nextAt, pressedAt: pressedAt)
    }

    private func endDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView) {
        // A delete still held stops repeating (what it already did stands).
        _ = deleteKey.cancel()
        endDeleteRepeat()
        let multipliers = trackpadMultipliers()
        trackpad.parameters = TrackpadParameters.standard.tuned(sensitivity: multipliers.sensitivity,
                                                                acceleration: multipliers.acceleration)
        if let profile = driver.layout(keyboardWidth: keyArea.bounds.width, profile: fieldLayout()) {
            editor.beginTrackpad(layout: profile.layout, linePitch: profile.linePitch, layoutWidth: profile.width, now: now)
        }
        onTrackpadChange?(true)
    }

    func keyArea(_ keyArea: KeyAreaView, movedTrackpadBy dx: Double, dy: Double, timestamp: TimeInterval) {
        editor.trackpadMoved(dx: dx, dy: dy, timestamp: timestamp)
    }

    func keyAreaEndedTrackpad(_ keyArea: KeyAreaView, timestamp: TimeInterval, cancelled: Bool) {
        editor.trackpadEnded(at: timestamp, cancelled: cancelled)
        onTrackpadChange?(false)
    }
}
