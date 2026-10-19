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
///   edited the field (`EditingCore.generation`) and the text before the caret still ends with it.
/// - **Autocorrect** (ARCHITECTURE.md, "Word autocorrect"): the current word's taps are recorded
///   (`wordTaps`); a commit key may first replace the word before the caret (`WordAutocorrect`), in the same
///   edit, and a Delete right after puts the typed word back (`revertedWords`).
/// Context is read in memory only; the typing tail, the strip and the word's taps are dropped on hiding.
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
    /// Whether a letter or digit typed now would get the space owed after a swiped word first ("Space
    /// before a tapped word"), as `press` would decide. For the soft-key-edge prior's context (ARCHITECTURE.md,
    /// "Soft key edges"); it only reads whether the proxy now shows the word.
    var tappedLetterGetsSpace: Bool { pendingSpaceApplies() }
    /// The text a tapped letter would follow, for the soft-key-edge prior: the text before the caret as this
    /// keyboard knows it (`currentBefore`, which includes own edits the proxy has not shown yet), plus the
    /// space a swiped word is owed (ARCHITECTURE.md, "Soft key edges", context). The typing tail belongs to the
    /// field our edits went to: in another one the proxy serves, before a callback reports it, only the proxy
    /// knows. Fields without an identity cannot be told apart, as elsewhere in the keyboard.
    var tapPriorContext: String {
        let before = core.documentID == document.documentID ? currentBefore : document.contextBefore
        return (before ?? "") + (tappedLetterGetsSpace ? " " : "")
    }
    /// The strip, and where its word left the caret. Held in memory only while the strip shows.
    private var swipe: (strip: SwipeStrip, anchor: SwipeAnchor)? {
        didSet { if swipe?.strip != oldValue?.strip { onSwipeStripChanged?() } }
    }
    /// The space owed before the next tapped letter or digit after a swiped word ("Space before a tapped
    /// word"), and where the word left the caret. Separate from the strip, which Shift and layer keys close
    /// while this survives them. In memory only.
    private var pendingSpace: SwipeAnchor?

    /// Autocorrect's corrector and inputs, read at each commit key (ARCHITECTURE.md, "Word autocorrect"); nil
    /// while autocorrect is off, without Full Access, or before its model has loaded.
    var autocorrect: () -> AutocorrectSetup? = { nil }
    /// An autocorrect event, for the TestFlight counters (counts only).
    var onAutocorrectEvent: ((WordAutocorrect.Event) -> Void)?
    /// The current word's characters with their taps' touch-down points. In memory only; dropped on hiding.
    private(set) var wordTaps = WordTapRecord()
    /// Typed words a Delete put back after their autocorrection, lowercased: never corrected again while this
    /// keyboard instance lives. In memory only; kept across hiding, gone with the instance.
    private(set) var revertedWords: Set<String> = []
    /// The last autocorrection while a Delete can still revert it: where its edit (the replacement and the
    /// commit key) left the caret, the text it replaced, and the record to restore.
    private var pendingRevert: (anchor: SwipeAnchor, correction: WordAutocorrect.Correction)?
    /// A trackpad gesture has moved (or may have moved) the caret since the keyboard appeared in this field,
    /// and nothing has confirmed where the host has it. From then on only a word this keyboard typed whole,
    /// after a separator it also typed, is corrected (`WordTapRecord.startsAtOwnBoundary`).
    private var caretUnconfirmed = false

    /// Where a swiped word's own edit (an insertion or a replacement), or an autocorrection's, left the caret,
    /// as this keyboard knows it. The proxy may show the edit late and with no callback, so it is checked against both the
    /// reading before the edit and the text the edit left (`holds`).
    private struct SwipeAnchor {
        var word: String
        var documentID: UUID?
        var generation: Int
        /// What the proxy read before the edit: one that has not shown the edit yet still reads this.
        var readingBefore: String
        /// The text before the caret the edit left (the text before it, then the word) and after it.
        var expectedBefore: String
        var expectedAfter: String
        /// The proxy has been seen showing the edit: from then on the reading before it is an older state of
        /// the field (the host may have undone the edit without a report yet), never a lagging proxy.
        var shown = false
    }

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
        caretUnconfirmed = false
        swipe = nil
        pendingSpace = nil
        forgetWord()
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
        caretUnconfirmed = false
        swipe = nil
        pendingSpace = nil
        forgetWord()
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
            forgetWord()
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
        observeShownSwipeEdits()
        return outcome
    }

    /// Another field (or none): nothing from the old one applies here.
    private func fieldChanged() {
        trackpad.fieldChanged()
        caretUnconfirmed = false
        swipe = nil
        pendingSpace = nil
        forgetWord()
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
    /// field identified when the key was pressed (nil if none was). `point`: a letters-layer tap's
    /// touch-down point, recorded with the character it types for autocorrect.
    func press(_ action: KeyAction, field: UUID?, at timestamp: TimeInterval, now: TimeInterval, point: TapPoint? = nil) {
        // Every key sees whether the proxy now shows a swiped word, before anything changes.
        observeShownSwipeEdits()
        // VoiceOver's delete reverts an autocorrection, or is the strip's first deletion, like the held delete
        // key's.
        if action == .delete, revertCorrection(field: field, now: now) { return }
        if action == .delete, deleteSwipedWord(field: field, now: now) { return }
        // Any other key forgets the pending revert, and any other key action closes the strip, typed or refused.
        pendingRevert = nil
        swipe = nil
        // A letter or digit tapped right after a swiped word goes in after a space. Shift and layer keys
        // keep that space pending; every other key ends it.
        let spaced: Bool
        if case .character(let character) = action, let first = character.first, first.isLetter || first.isNumber {
            spaced = pendingSpaceApplies()
        } else {
            spaced = false
        }
        switch action {
        case .shift, .layer: break
        default: pendingSpace = nil
        }
        if spaced, case .character(let character) = action {
            type(field: field, now: now, point: point) { [self] before in
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
            if WordAutocorrect.isCommitKey(action) {
                commit(action, field: field, at: timestamp, now: now)
            } else {
                type(field: field, now: now, point: point) { [self] before in resolve(action, before: before, at: timestamp) }
            }
        }
    }

    /// One deletion of the held delete key, pressed in `field` (nil if none was identified).
    /// While the strip shows, the first deletion (a tap, or a held delete's first) removes the whole
    /// swiped word instead; the strip closes, so repeats are the usual ones.
    func heldDelete(_ unit: DeleteRepeat.Unit, field: UUID?, now: TimeInterval) {
        pendingSpace = nil
        observeShownSwipeEdits()
        if revertCorrection(field: field, now: now) { return }
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
        forgetWord()
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
        observeShownSwipeEdits()
        guard !trackpad.isActive else { return }
        let shift = typing.shift
        applyAutomaticShift()
        if typing.shift != shift { onStateChanged?() }
    }

    /// A key's edit, now: refused only when it was pressed in another identified field; any gesture
    /// ends first, so the key reads where the caret lands. False if refused. `recordEachDeletion`: every
    /// deletion is recorded as an own edit, for a host that reports each one (a whole word goes at once).
    /// The word's tap record follows the edit: `point` is the tap that typed it, `swiped` a swipe's.
    @discardableResult
    private func type(field: UUID?, now: TimeInterval, recordEachDeletion: Bool = false, point: TapPoint? = nil,
                      swiped: Bool = false, resolve: (String?) -> (deletes: Int, text: String)) -> Bool {
        if let field, let current = document.documentID, field != current { return false }
        adoptCurrentField()
        trackpad.interrupt(at: now)
        // Typing over a selection replaces text the record does not know.
        if document.hasSelection { wordTaps.clear() }
        let edit = resolve(currentBefore)
        userEdit()
        if edit.deletes > 0 { deleteGraphemes(edit.deletes, now: now, recordEach: recordEachDeletion) }
        if !edit.text.isEmpty { insert(edit.text, now: now) }
        wordTaps.edited(deleted: edit.deletes, inserted: edit.text, point: point, swiped: swiped)
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
        var context: (reading: String, before: String, after: String)?
        let typed = type(field: field, now: now, swiped: true) { [self] before in
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
            context = (document.contextBefore ?? "", (before ?? "") + space + cased[0], document.contextAfter ?? "")
            return (0, space + cased[0])
        }
        guard typed, let strip, let context else {
            // A refused swipe is still a key action: the strip closes, and no space is pending.
            swipe = nil
            pendingSpace = nil
            return
        }
        let placed = anchor(strip.insertedWord, context)
        swipe = (strip, placed)
        pendingSpace = placed
        observeShownSwipeEdits()
    }

    /// A tap on the strip's candidate `index`: it replaces the inserted word, but only while nothing else
    /// has edited the field and the text before the caret still ends with the word. Otherwise the tap
    /// does nothing and the strip closes.
    func chooseSwipeCandidate(at index: Int, now: TimeInterval) {
        guard let shown = swipe else { return }
        guard let strip = currentSwipe() else {
            swipe = nil
            pendingSpace = nil
            return
        }
        guard strip.candidates.indices.contains(index), index != strip.inserted else { return }
        let old = strip.insertedWord.count
        let new = strip.candidates[index]
        var context: (reading: String, before: String, after: String)?
        let replaced = type(field: shown.anchor.documentID, now: now, recordEachDeletion: true, swiped: true) { [self] before in
            context = (document.contextBefore ?? "", String((before ?? "").dropLast(old)) + new, document.contextAfter ?? "")
            return (old, new)
        }
        guard replaced, let context else {
            swipe = nil
            return
        }
        let placed = anchor(new, context)
        swipe = (SwipeStrip(candidates: strip.candidates, inserted: index), placed)
        pendingSpace = placed
        observeShownSwipeEdits()
    }

    /// Closes the strip and ends a pending space (the trackpad began, even without a gesture).
    func closeSwipeStrip() {
        swipe = nil
        pendingSpace = nil
        forgetWord()
    }

    /// The anchor of `word`, just typed by an edit made on `context` (the proxy's reading before it, and
    /// the text before and after the caret it left).
    private func anchor(_ word: String, _ context: (reading: String, before: String, after: String)) -> SwipeAnchor {
        SwipeAnchor(word: word, documentID: document.documentID, generation: core.generation,
                    readingBefore: context.reading, expectedBefore: context.before, expectedAfter: context.after)
    }

    /// Whether the caret is still where the anchored edit left it: the same field, no edit by anything else
    /// since (an own edit's report never counts), nothing selected, the text before the caret ending with
    /// the word, and the proxy showing the text after the caret the edit left, and before it either the
    /// text the edit left (`showsEdit`) or, only until the proxy has been seen showing the edit, exactly its
    /// reading before the edit (it lags). A caret moved without a report yet (perhaps after another copy of
    /// the word), or the edit undone by the host before its report, fails.
    private func holds(_ anchor: SwipeAnchor) -> Bool {
        guard document.documentID == anchor.documentID, core.documentID == anchor.documentID,
              core.generation == anchor.generation, !document.hasSelection,
              (document.contextAfter ?? "") == anchor.expectedAfter,
              currentBefore?.hasSuffix(anchor.word) == true else { return false }
        if !anchor.shown, (document.contextBefore ?? "") == anchor.readingBefore { return true }
        return showsEdit(anchor)
    }

    /// The proxy shows the text the anchored edit left around the caret. Before the caret, the text it
    /// shows and the text the edit left may each be the longer one: hosts show a window of the field (often
    /// from a line or sentence start), and the editor's own copy is bounded. Accepted residual risk (strict
    /// equality would turn the strip and the pending space off after any line break in such hosts): two
    /// caret positions with identical visible context, and a caret moved between them in the moment before
    /// the host reports it, pass; the worst outcome is an undoable edit to an identical word at a line end.
    private func showsEdit(_ anchor: SwipeAnchor) -> Bool {
        guard document.documentID == anchor.documentID, (document.contextAfter ?? "") == anchor.expectedAfter else {
            return false
        }
        let before = document.contextBefore ?? ""
        guard !before.isEmpty, before.hasSuffix(anchor.word) else { return false }
        return before.hasSuffix(anchor.expectedBefore) || anchor.expectedBefore.hasSuffix(before)
    }

    /// Marks each anchored edit the proxy now shows: its reading before the edit is retired for good.
    private func observeShownSwipeEdits() {
        if var current = swipe, !current.anchor.shown, showsEdit(current.anchor) {
            current.anchor.shown = true
            swipe = current
        }
        if var pending = pendingSpace, !pending.shown, showsEdit(pending) {
            pending.shown = true
            pendingSpace = pending
        }
        if var revert = pendingRevert, !revert.anchor.shown, showsEdit(revert.anchor) {
            revert.anchor.shown = true
            pendingRevert = revert
        }
    }

    /// Whether the pending space still applies, checked as the strip's word is.
    private func pendingSpaceApplies() -> Bool {
        observeShownSwipeEdits()
        guard let pendingSpace else { return false }
        return holds(pendingSpace)
    }

    /// The strip, while its word can still be replaced or deleted whole (`holds`).
    private func currentSwipe() -> SwipeStrip? {
        observeShownSwipeEdits()
        guard let swipe, holds(swipe.anchor) else { return nil }
        return swipe.strip
    }

    /// The strip's first deletion: the whole swiped word, not the space before it. False (nothing
    /// deleted) when the word can no longer be deleted whole or the press is refused.
    private func deleteSwipedWord(field: UUID?, now: TimeInterval) -> Bool {
        guard let strip = currentSwipe() else { return false }
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

    // MARK: Autocorrect

    /// A commit key (`WordAutocorrect.isCommitKey`): the word before the caret may first be replaced by its
    /// correction, in the same edit as the key (the word's characters deleted, the correction and the key's
    /// text inserted), and the key is typed as usual after it. A Delete right after can revert it.
    private func commit(_ action: KeyAction, field: UUID?, at timestamp: TimeInterval, now: TimeInterval) {
        var made: (correction: WordAutocorrect.Correction, inserted: String,
                   context: (reading: String, before: String, after: String))?
        type(field: field, now: now, recordEachDeletion: true) { [self] before in
            let text = before ?? ""
            // Not over a selection, which the first deletion would remove instead, nor where the text before the
            // caret is uncertain: the deletions would run wherever the host really has the caret.
            let setup = document.hasSelection || !runIsVerified(before: text) || !runIsOurs(before: text) ? nil : autocorrect()
            guard let correction = WordAutocorrect.correction(before: text, record: wordTaps, reverted: revertedWords,
                                                              setup: setup, checked: { onAutocorrectEvent?(.checked) })
            else { return resolve(action, before: before, at: timestamp) }
            let corrected = String(text.dropLast(correction.typed.count)) + correction.replacement
            let edit = resolve(action, before: corrected, at: timestamp)
            // A key that deletes (a double space's period) follows a space, never a word; kept for safety.
            guard edit.deletes == 0 else { return edit }
            let inserted = correction.replacement + edit.text
            made = (correction, inserted, (document.contextBefore ?? "", corrected + edit.text, document.contextAfter ?? ""))
            return (correction.typed.count, inserted)
        }
        guard let made else { return }
        onAutocorrectEvent?(.corrected)
        // Return can move focus before the proxy reports the next field, where a revert's deletions would land:
        // it never arms one. Nor does a field without an identity, which cannot be told from the next.
        guard action != .returnKey, document.documentID != nil else { return }
        pendingRevert = (anchor(made.inserted, made.context), made.correction)
    }

    /// Whether the run of letters and apostrophes before the caret (as `before`, the editor's text, has it) is
    /// verified: the proxy itself shows that same run now, and its reading is not one a key left unverified by
    /// ending a gesture whose last adjustment's outcome is unknown (an abandoned probe or jump). A proxy that
    /// has not shown our edits yet, or shows a landing the trackpad only predicted, does not verify it.
    private func runIsVerified(before: String) -> Bool {
        guard !trackpad.isActive else { return false }
        let proxy = document.contextBefore
        if case .some(let reading) = untrustedReading, reading == proxy { return false }
        guard let run = WordAutocorrect.word(before: before)?.run else { return true }
        return WordAutocorrect.word(before: proxy ?? "")?.run == run
    }

    /// After a gesture whose landing nothing has confirmed (`caretUnconfirmed`; a report that arrives in the
    /// meantime, such as WebKit's report of an adjustment as issued, confirms nothing), whether the run before
    /// the caret is wholly characters this keyboard typed after a separator it also typed: deleting it then
    /// removes exactly those characters, wherever the host has the caret. Always true otherwise.
    private func runIsOurs(before: String) -> Bool {
        guard caretUnconfirmed else { return true }
        guard let run = WordAutocorrect.word(before: before)?.run else { return true }
        return wordTaps.startsAtOwnBoundary && wordTaps.entries(matching: run) != nil
    }

    /// A Delete right after an autocorrection, while the field still ends with it and nothing else has edited
    /// it: the replacement and its commit key give way to the typed word, the caret right after it, and the word
    /// is never corrected again in this keyboard instance. False (nothing done) otherwise; the pending revert
    /// is gone either way.
    private func revertCorrection(field: UUID?, now: TimeInterval) -> Bool {
        guard let pending = pendingRevert else { return false }
        pendingRevert = nil
        // Provably the same field: identified, the same identity the correction was made in, and the anchor holds.
        guard let current = document.documentID, current == pending.anchor.documentID, holds(pending.anchor) else { return false }
        let reverted = type(field: field, now: now, recordEachDeletion: true) { [self] _ in
            typing.didDelete()
            return (pending.anchor.word.count, pending.correction.typed)
        }
        guard reverted else { return false }
        swipe = nil
        wordTaps = WordTapRecord(entries: pending.correction.record,
                                 startsAtOwnBoundary: pending.correction.recordStartsAtOwnBoundary)
        revertedWords.insert(pending.correction.word)
        onAutocorrectEvent?(.reverted)
        return true
    }

    /// The letters layer was laid out anew (a resize or rotation): the current word's recorded points belong to
    /// the old geometry, so they become none; its characters stay.
    func layoutChanged() {
        wordTaps.forgetPoints()
        // So for the record a revert would restore.
        if var pending = pendingRevert {
            var record = WordTapRecord(entries: pending.correction.record)
            record.forgetPoints()
            pending.correction.record = record.entries
            pendingRevert = pending
        }
    }

    /// The caret moved, the field changed or something else edited it: the word's taps and a pending revert
    /// no longer apply. The reverted words stay.
    private func forgetWord() {
        wordTaps.clear()
        pendingRevert = nil
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
        // The caret moved.
        forgetWord()
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
        forgetWord()
        caretUnconfirmed = true
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
        forgetWord()
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
