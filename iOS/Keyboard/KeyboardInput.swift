import UIKit

/// The typing side of the keyboard: layers, shift, auto-capitalization, the double-space period,
/// the held delete key and trackpad mode. The rules live in KeyboardCore; this class applies them
/// to the text proxy. The context before the caret is read in memory only, before each edit, and
/// never stored or logged.
@MainActor
final class KeyboardInput: KeyAreaViewDelegate {
    private weak var controller: UIInputViewController?
    private weak var keyArea: KeyAreaView?
    private var typing = TypingState()
    private var tail = ContextTail()
    private let deleteRepeat = DeleteRepeat()
    private var deletePressedAt: TimeInterval?
    private var lastDeleteFire: TimeInterval?
    private var deleteTimer: Timer?
    let trackpad: TrackpadDriver
    /// Trackpad mode started (true) or ended (false), to dim the dictation bar and play a haptic.
    var onTrackpadChange: ((Bool) -> Void)?
    /// Typing, delete or trackpad movement happened (it ends the window for undoing a dictation).
    var onEdit: (() -> Void)?
    /// The user's trackpad multipliers, read when a gesture starts.
    var trackpadMultipliers: () -> (sensitivity: Double, acceleration: Double) = { (1, 1) }

    init(controller: UIInputViewController, keyArea: KeyAreaView) {
        self.controller = controller
        self.keyArea = keyArea
        trackpad = TrackpadDriver(controller: controller)
        trackpad.onSettled = { [weak self] in self?.updateAutomaticShift() }
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private var currentBefore: String? { tail.current(proxyBefore: proxy?.documentContextBeforeInput) }

    /// The keyboard appeared or the field changed: start fresh.
    func reset() {
        tail.forget()
        typing.resetTiming()
        let numeric: Set<UIKeyboardType> = [.numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad]
        typing.switchLayer(to: numeric.contains(proxy?.keyboardType ?? .default) ? .numbers : .letters)
        updateAutomaticShift()
    }

    /// The host changed the text or the selection.
    func proxyChanged() {
        let hadModel = tail.known != nil
        tail.proxyChanged(before: proxy?.documentContextBeforeInput)
        // Moved elsewhere: a space before the move does not pair with one after it.
        if hadModel, tail.known == nil { typing.resetTiming() }
        updateAutomaticShift()
    }

    /// Dictated text, so the model and shift follow it.
    func insertDictation(_ text: String) {
        insert(text)
        typing.resetTiming()
        updateAutomaticShift()
    }

    /// Undo of the last dictation: deletes exactly its graphemes.
    func deleteForUndo(_ count: Int) {
        deleteCharacters(count)
        typing.resetTiming()
        updateAutomaticShift()
    }

    func stop() {
        endDeleteRepeat()
        keyArea?.cancelAllTouches()
        trackpad.cancel()
    }

    // MARK: Editing

    private func insert(_ text: String) {
        guard let proxy, !text.isEmpty else { return }
        let before = proxy.documentContextBeforeInput
        proxy.insertText(text)
        tail.inserted(text, proxyBefore: before)
    }

    private func deleteCharacters(_ count: Int) {
        guard let proxy, count > 0 else { return }
        let before = proxy.documentContextBeforeInput
        for _ in 0 ..< count { proxy.deleteBackward() }
        tail.deleted(graphemes: count, proxyBefore: before)
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
        case .shift:
            typing.tapShift(at: timestamp)
            keyArea.apply(layer: typing.layer, shift: typing.shift)
            return
        case .layer(let layer):
            typing.switchLayer(to: layer)
        case .delete:
            deleteCharacters(1)
            typing.didDelete()
        case .nextKeyboard:
            return
        }
        if case .layer = action {} else { onEdit?() }
        updateAutomaticShift()
    }

    func keyAreaBeganDelete(_ keyArea: KeyAreaView, timestamp: TimeInterval) {
        endDeleteRepeat()
        onEdit?()
        // The press deletes at once; holding repeats on the schedule from touch-down.
        deleteCharacters(1)
        typing.didDelete()
        updateAutomaticShift()
        deletePressedAt = timestamp
        lastDeleteFire = nil
        scheduleDeleteRepeat()
    }

    func keyAreaEndedDelete(_ keyArea: KeyAreaView) {
        endDeleteRepeat()
    }

    private func scheduleDeleteRepeat() {
        guard let pressedAt = deletePressedAt else { return }
        let next = deleteRepeat.nextFire(afterRepeatAt: lastDeleteFire)
        // Touch timestamps and CACurrentMediaTime share the same clock.
        let delay = max(next - (CACurrentMediaTime() - pressedAt), 0)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDeleteRepeat(at: next) }
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
    }

    private func fireDeleteRepeat(at elapsed: TimeInterval) {
        guard deletePressedAt != nil else { return }
        switch deleteRepeat.unit(atElapsed: elapsed) {
        case .character: deleteCharacters(1)
        case .word: deleteWord()
        }
        lastDeleteFire = elapsed
        updateAutomaticShift()
        scheduleDeleteRepeat()
    }

    private func endDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deletePressedAt = nil
        lastDeleteFire = nil
    }

    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView) {
        endDeleteRepeat()
        let multipliers = trackpadMultipliers()
        trackpad.parameters = TrackpadParameters.standard.tuned(sensitivity: multipliers.sensitivity,
                                                                acceleration: multipliers.acceleration)
        trackpad.begin(fieldWidth: keyArea.bounds.width)
        onEdit?()
        // The caret moves; the model of the text before it no longer holds.
        tail.forget()
        typing.resetTiming()
        onTrackpadChange?(true)
    }

    func keyArea(_ keyArea: KeyAreaView, movedTrackpadBy dx: Double, dy: Double, timestamp: TimeInterval) {
        trackpad.move(dx: dx, dy: dy, timestamp: timestamp)
    }

    func keyAreaEndedTrackpad(_ keyArea: KeyAreaView, timestamp: TimeInterval) {
        trackpad.end(at: timestamp)
        onTrackpadChange?(false)
    }
}
