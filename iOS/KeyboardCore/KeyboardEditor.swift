import Foundation

/// The candidate strip after a swipe (ARCHITECTURE.md, "Typing model v4 and swipe typing"): up to three
/// candidates, cased as the inserted word was, best first, and which one is in the field now. In memory
/// only; never logged or stored.
struct SwipeStrip: Equatable, Sendable {
    var candidates: [String]
    var inserted: Int

    static let limit = 3

    var insertedWord: String { candidates[inserted] }
}

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
/// - **Swiped words** (`insertSwipe`) go in like a key, with a leading space and the shift's case; the
///   candidate strip that follows (`swipeStrip`) can replace the word only while nothing else has
///   edited the field (`EditingCore.generation`) and the text before the caret still ends with it. The
///   swiped word's edit is recorded in an `ExpectedDocument`, which tells a lagging proxy from a changed
///   field.
/// Context is read in memory only; the typing tail and the strip are dropped on hiding.
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
    /// The candidate strip opened, changed or closed. Never called while it stays closed, so ordinary
    /// typing re-renders nothing.
    var onSwipeStripChanged: (() -> Void)?

    /// The strip shown after a swipe, nil when closed.
    var swipeStrip: SwipeStrip? { swipe?.strip }
    /// The strip, and the edit that put its word in (`swipeEdits`). Held in memory only while the strip
    /// shows.
    private var swipe: (strip: SwipeStrip, edit: ExpectedDocument.ID)? {
        didSet {
            releaseSwipeEdits()
            if swipe?.strip != oldValue?.strip { onSwipeStripChanged?() }
        }
    }
    /// The space owed before the next tapped letter or digit after a swiped word ("Space before a tapped
    /// word"), and the edit that put the word in. Separate from the strip, which Shift and layer keys close
    /// while this survives them. In memory only.
    private var pendingSpace: ExpectedDocument.ID? {
        didSet { releaseSwipeEdits() }
    }
    /// Each swiped word's own edit (an insertion or a replacement) and where it left the caret, as this
    /// keyboard knows it, with the word as its witness. The proxy may show the edit late and with no
    /// callback, so a reading may confirm it or still lag it (`holds`). Kept only while the strip or the
    /// pending space refers to it, with no time limit (neither has one). Whenever it is consulted (and when
    /// the strip is reported changed) it holds at most one record, the one both refer to; two exist only
    /// for the moment a new word's edit is recorded and the old one is not yet let go.
    private var swipeEdits = ExpectedDocument(capacity: 2, lifetime: .infinity)

    /// How many swiped words' edits are recorded now: at most one between calls. For tests.
    var swipeEditCount: Int { swipeEdits.expectations.count }

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
        swipe = nil
        pendingSpace = nil
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
        swipe = nil
        pendingSpace = nil
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
            // nothing explains): the gesture ends, the strip closes, and the space and shift timing
            // starts over.
            swipe = nil
            pendingSpace = nil
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
        observeShownSwipeEdits(now: now)
        return outcome
    }

    /// Another field (or none): nothing from the old one applies here.
    private func fieldChanged() {
        trackpad.fieldChanged()
        swipe = nil
        pendingSpace = nil
        tail.forget()
        untrustedReading = nil
        contextWatchUntil = nil
        typing.resetTiming()
        onFieldChanged?(document.documentID)
    }

    // MARK: Keys

    /// Any key touched down (characters, space, Return, delete, Shift, layer keys): trackpad settlement
    /// or verification ends on the spot (ARCHITECTURE.md, "Typing model v2"), so nothing the gesture
    /// still hears from can move the caret before the key acts. A character inserts right after.
    func keyTouchedDown(now: TimeInterval) {
        trackpad.interrupt(at: now)
    }

    /// A key acted: characters, shift and layer keys on touch-down; space and return on release or
    /// rollover; delete only from VoiceOver (the held delete key uses `heldDelete`). `field` is the
    /// field identified when the key was pressed (nil if none was).
    func press(_ action: KeyAction, field: UUID?, at timestamp: TimeInterval, now: TimeInterval) {
        // Every key sees whether the proxy now shows a swiped word, before anything changes.
        observeShownSwipeEdits(now: now)
        // VoiceOver's delete is the strip's first deletion like the held delete key's.
        if action == .delete, deleteSwipedWord(field: field, now: now) { return }
        // Any other key action closes the strip, typed or refused.
        swipe = nil
        // A letter or digit tapped right after a swiped word goes in after a space. Shift and layer keys
        // keep that space pending; every other key ends it.
        let spaced: Bool
        if case .character(let character) = action, let first = character.first, first.isLetter || first.isNumber {
            spaced = pendingSpaceApplies(now: now)
        } else {
            spaced = false
        }
        switch action {
        case .shift, .layer: break
        default: pendingSpace = nil
        }
        if spaced, case .character(let character) = action {
            type(field: field, now: now) { [self] before in
                // Cased as if the space had been typed: a shift the user set still decides.
                let text = Self.swipeCased(character, shift: swipeShift(after: (before ?? "") + " "))
                typing.didTypeCharacter(text)
                return (0, " " + text)
            }
            return
        }
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
    /// While the strip shows, the first deletion (a tap, or a held delete's first) removes the whole
    /// swiped word instead; the strip closes, so repeats are the usual ones.
    func heldDelete(_ unit: DeleteRepeat.Unit, field: UUID?, now: TimeInterval) {
        pendingSpace = nil
        if deleteSwipedWord(field: field, now: now) { return }
        swipe = nil
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
        swipe = nil
        pendingSpace = nil
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
        observeShownSwipeEdits(now: now)
        guard !trackpad.isActive else { return }
        let shift = typing.shift
        applyAutomaticShift()
        if typing.shift != shift { onStateChanged?() }
    }

    /// A key's edit, now: refused only when it was pressed in another identified field; any gesture
    /// ends first, so the key reads where the caret lands. False if refused. `recordEachDeletion`: every
    /// deletion is recorded as an own edit, for a host that reports each one (a whole word goes at once).
    @discardableResult
    private func type(field: UUID?, now: TimeInterval, recordEachDeletion: Bool = false,
                      resolve: (String?) -> (deletes: Int, text: String)) -> Bool {
        if let field, let current = document.documentID, field != current { return false }
        adoptCurrentField()
        trackpad.interrupt(at: now)
        let edit = resolve(currentBefore)
        userEdit()
        if edit.deletes > 0 { deleteGraphemes(edit.deletes, now: now, recordEach: recordEachDeletion) }
        if !edit.text.isEmpty { insert(edit.text, now: now) }
        contextWatchUntil = now + Self.contextWatch
        updateAutomaticShift()
        return true
    }

    // MARK: Swipe typing

    /// Characters after which a swiped word gets no leading space (besides whitespace and the start).
    private static let swipeSpaceOpeners: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "/", "-", "@", "#"]

    /// Inserts the best of a swipe's decoded candidates (best first) like a key pressed in `field`:
    /// refused in another identified field, nothing at all without a candidate. A space goes before it
    /// unless the text before the caret is empty or ends with whitespace or an opener; none after. Caps
    /// lock uppercases it, a one-shot or automatic shift its first letter (and is consumed); case only
    /// rises. The strip then shows up to three candidates cased the same way.
    func insertSwipe(_ candidates: [SwipeCandidate], field: UUID?, now: TimeInterval) {
        let words = candidates.map(\.word).filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        var strip: SwipeStrip?
        var context: SwipeEditContext?
        let typed = type(field: field, now: now) { [self] before in
            let space = Self.swipeNeedsSpace(before: before) ? " " : ""
            let shift = swipeShift(after: (before ?? "") + space)
            var cased: [String] = []
            for word in words where cased.count < SwipeStrip.limit {
                let candidate = Self.swipeCased(word, shift: shift)
                if !cased.contains(candidate) { cased.append(candidate) }
            }
            // A one-shot shift is consumed as by a typed letter.
            typing.didTypeCharacter(cased[0])
            strip = SwipeStrip(candidates: cased, inserted: 0)
            context = SwipeEditContext(reading: proxyReading, deleted: 0, inserted: space + cased[0],
                                       before: (before ?? "") + space + cased[0])
            return (0, space + cased[0])
        }
        guard typed, let strip, let context else {
            // A refused swipe is still a key action: the strip closes, and no space is pending.
            swipe = nil
            pendingSpace = nil
            return
        }
        let placed = recordSwipeEdit(of: strip.insertedWord, context, now: now)
        // The pending space first, so the old word's edit is let go before the strip is reported changed.
        pendingSpace = placed
        swipe = (strip, placed)
        observeShownSwipeEdits(now: now)
    }

    /// A tap on the strip's candidate `index`: it replaces the inserted word, but only while nothing else
    /// has edited the field and the text before the caret still ends with the word. Otherwise the tap
    /// does nothing and the strip closes.
    func chooseSwipeCandidate(at index: Int, now: TimeInterval) {
        guard let shown = swipe else { return }
        guard let strip = currentSwipe(now: now) else {
            swipe = nil
            pendingSpace = nil
            return
        }
        guard strip.candidates.indices.contains(index), index != strip.inserted else { return }
        let old = strip.insertedWord.count
        let new = strip.candidates[index]
        var context: SwipeEditContext?
        let replaced = type(field: swipeEdits[shown.edit]?.documentID, now: now, recordEachDeletion: true) { [self] before in
            context = SwipeEditContext(reading: proxyReading, deleted: old, inserted: new,
                                       before: String((before ?? "").dropLast(old)) + new)
            return (old, new)
        }
        guard replaced, let context else {
            swipe = nil
            return
        }
        let placed = recordSwipeEdit(of: new, context, now: now)
        pendingSpace = placed
        swipe = (SwipeStrip(candidates: strip.candidates, inserted: index), placed)
        observeShownSwipeEdits(now: now)
    }

    /// Closes the strip and ends a pending space (the trackpad began, even without a gesture).
    func closeSwipeStrip() {
        swipe = nil
        pendingSpace = nil
    }

    /// A swiped word's edit as it is typed: the proxy's reading before it, the graphemes it deletes and the
    /// text it inserts, and the text before the caret it leaves (the text before it, then the word).
    private struct SwipeEditContext {
        var reading: ExpectedDocument.Reading
        var deleted: Int
        var inserted: String
        var before: String
    }

    /// What the proxy reads now.
    private var proxyReading: ExpectedDocument.Reading {
        ExpectedDocument.Reading(documentID: document.documentID, before: document.contextBefore,
                                 after: document.contextAfter)
    }

    /// Records the edit that just typed `word` on `context` (the text after the caret unchanged).
    private func recordSwipeEdit(of word: String, _ context: SwipeEditContext, now: TimeInterval) -> ExpectedDocument.ID {
        swipeEdits.record(deleting: context.deleted, inserting: context.inserted, on: context.reading,
                          leaving: (context.before, context.reading.after), witness: word,
                          generation: core.generation, at: now)
    }

    /// Forgets every swiped word's edit that neither the strip nor the pending space refers to.
    private func releaseSwipeEdits() {
        swipeEdits.removeAll(keeping: Set([swipe?.edit, pendingSpace].compactMap { $0 }))
    }

    /// Whether the caret is still where the recorded edit left it: the same field, no edit by anything
    /// else since (an own edit's report never counts; `EditingCore.generation`), nothing selected, the text
    /// before the caret ending with the word, and the proxy showing the text after the caret the edit left,
    /// and before it either the text the edit left (confirmed) or, only until the proxy has been seen
    /// showing the edit, exactly its reading before the edit (pending: it lags). A caret moved without a
    /// report yet (perhaps after another copy of the word), or the edit undone by the host before its
    /// report, fails (contradicted).
    ///
    /// Confirmation uses `ExpectedDocument`'s window rule: before the caret, the text the proxy shows and
    /// the text the edit left may each be the longer one, since hosts show a window of the field (often
    /// from a line or sentence start), and the editor's own copy is bounded. Accepted residual risk (strict
    /// equality would turn the strip and the pending space off after any line break in such hosts): two
    /// caret positions with identical visible context, and a caret moved between them in the moment before
    /// the host reports it, pass; the worst outcome is an undoable edit to an identical word at a line end.
    private func holds(_ edit: ExpectedDocument.ID, now: TimeInterval) -> Bool {
        assert(swipeEditCount <= 1, "The strip and the pending space refer to at most one recorded edit")
        guard core.documentID == document.documentID, !document.hasSelection, let word = swipeEdits[edit]?.witness,
              currentBefore?.hasSuffix(word) == true else { return false }
        switch swipeEdits.verdict(of: edit, for: proxyReading, generation: core.generation, now: now) {
        case .pending, .confirmed: return true
        case .contradicted, nil: return false
        }
    }

    /// Marks each recorded edit the proxy now shows: its reading before the edit is retired for good.
    private func observeShownSwipeEdits(now: TimeInterval) {
        assert(swipeEditCount <= 1, "The strip and the pending space refer to at most one recorded edit")
        guard swipeEdits.expectations.contains(where: { !$0.shown }) else { return }
        swipeEdits.observe(proxyReading, generation: core.generation, now: now)
    }

    /// Whether the pending space still applies, checked as the strip's word is.
    private func pendingSpaceApplies(now: TimeInterval) -> Bool {
        observeShownSwipeEdits(now: now)
        guard let pendingSpace else { return false }
        return holds(pendingSpace, now: now)
    }

    /// The strip, while its word can still be replaced or deleted whole (`holds`).
    private func currentSwipe(now: TimeInterval) -> SwipeStrip? {
        observeShownSwipeEdits(now: now)
        guard let swipe, holds(swipe.edit, now: now) else { return nil }
        return swipe.strip
    }

    /// The strip's first deletion: the whole swiped word, not the space before it. False (nothing
    /// deleted) when the word can no longer be deleted whole or the press is refused.
    private func deleteSwipedWord(field: UUID?, now: TimeInterval) -> Bool {
        guard let strip = currentSwipe(now: now) else { return false }
        let count = strip.insertedWord.count
        let deleted = type(field: field, now: now, recordEachDeletion: true) { [self] _ in
            typing.didDelete()
            return (count, "")
        }
        guard deleted else { return false }
        swipe = nil
        return true
    }

    /// How a swiped word is cased when it lands after `text` (the text before the caret with the leading
    /// space it brings). A shift the user set (caps lock, a one-shot shift, or an automatic shift turned
    /// off) decides as before. Otherwise automatic capitalization decides for that text, as for a letter
    /// typed there: all characters uppercases the whole word, like caps lock.
    private func swipeShift(after text: String) -> ShiftMode {
        if typing.shift == .capsLock || (typing.shift == .once && !typing.shiftIsAutomatic) { return typing.shift }
        if typing.automaticShiftDeclined { return .off }
        let mode = autocapitalization()
        guard AutoCapitalization.shouldCapitalize(before: text, mode: mode) else { return .off }
        return mode == .allCharacters ? .capsLock : .once
    }

    static func swipeCased(_ word: String, shift: ShiftMode) -> String {
        switch shift {
        case .off: return word
        case .capsLock: return word.uppercased()
        case .once:
            guard let first = word.first else { return word }
            return first.uppercased() + word.dropFirst()
        }
    }

    static func swipeNeedsSpace(before: String?) -> Bool {
        guard let last = before?.last else { return false }
        return !last.isWhitespace && !swipeSpaceOpeners.contains(last)
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
        swipe = nil
        pendingSpace = nil
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

    private func deleteGraphemes(_ count: Int, now: TimeInterval, recordEach: Bool = false) {
        let before = document.contextBefore
        // With text selected, the first deletion removes only the selection: the text before stays.
        let deleted = document.hasSelection ? count - 1 : count
        for _ in 0 ..< count {
            document.deleteBackward()
            if recordEach { core.recordOwnEdit(now: now) }
        }
        if !recordEach { core.recordOwnEdit(now: now) }
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
