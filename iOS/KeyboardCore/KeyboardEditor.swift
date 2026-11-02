import Foundation

/// The candidate strip after a swipe (ARCHITECTURE.md, "Typing model v4 and swipe typing"): up to three
/// candidates, cased as the inserted word was, best first, and which one is in the field now. Autocorrect's
/// suggestions after a commit key use it too (ARCHITECTURE.md, "Word autocorrect"). In memory only; never
/// logged or stored.
struct SwipeStrip: Equatable, Sendable {
    var candidates: [String]
    var inserted: Int
    /// While a word is typed (`WordAutocorrect.typingStrip`), what the bar marks; nil after a swipe or a commit key,
    /// where `inserted` is the word in the field.
    var live: Live?

    /// The marks of a strip shown while a word is typed: the word as typed in quotes (a tap keeps it) and the
    /// correction a commit key would make, each only while a correction is pending.
    struct Live: Equatable, Sendable {
        var quoted: Int?
        var marked: Int?
    }

    static let limit = 3

    init(candidates: [String], inserted: Int, live: Live? = nil) {
        self.candidates = candidates
        self.inserted = inserted
        self.live = live
    }

    var insertedWord: String { candidates[inserted] }

    /// The candidate the bar emphasizes: the word in the field after a swipe or a commit key, the pending correction
    /// while a word is typed (none without one).
    var emphasized: Int? { live.map(\.marked) ?? inserted }
}

/// A reverted word the user may ask autocorrect never to correct again (ARCHITECTURE.md, "Word autocorrect", Never
/// correct): the top row offers it right after a revert, and only a tap on that offer stores it. In memory only
/// until then.
struct NeverCorrectOffer: Equatable, Sendable {
    /// As the corrector saw it (lowercased): what the store keeps.
    var word: String
    /// As typed, without trailing apostrophes: what the prompt shows.
    var typed: String

    /// Whether the top row shows the offer: dictation's own top-row UI wins, so not while a dictation is
    /// starting, recording or transcribing, nor while its Undo chip shows. Hidden, the offer still ends as usual.
    static func barShows(_ offer: NeverCorrectOffer?, dictationInProgress: Bool, dictationUndoShown: Bool) -> Bool {
        offer != nil && !dictationInProgress && !dictationUndoShown
    }
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
/// - **Autocorrect** (ARCHITECTURE.md, "Word autocorrect"): the current word's taps are recorded
///   (`wordTaps`); a commit key may first replace the word before the caret (`WordAutocorrect`), in the same
///   edit, and a Delete right after puts the typed word back (`revertedWords`). The strip then offers the
///   typed word, the correction and suggestions; a choice replaces the word before the commit key's text,
///   under the same conditions as a swiped word's, and the commit's edit is recorded the same way. A revert
///   offers to never correct the word (`neverCorrectOffer`); only accepting it stores the word, in the store
///   the keyboard binds.
/// - **Next words** after the keyboard's own space (`nextWords`), and the word being typed kept across hiding
///   (`parkedWord`), ARCHITECTURE.md, "Word autocorrect".
/// Context is read in memory only; the typing tail, the strip and the word's taps are dropped on hiding, except the
/// word being typed (its characters, without points, the field's identity and a digest of the text around it) until
/// the keyboard appears again.
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

    /// The strip shown after a swipe or a commit key, else while a word is typed, else the next words after a space; nil
    /// when closed.
    var swipeStrip: SwipeStrip? { swipe?.strip ?? typingSuggestions?.strip ?? nextWords?.strip }
    /// Whether a letter or digit typed now would get the space owed after a swiped word first ("Space
    /// before a tapped word"), as `press` would decide. For the soft-key-edge prior's context (ARCHITECTURE.md,
    /// "Soft key edges"); it only reads whether the proxy now shows the word.
    func tappedLetterGetsSpace(now: TimeInterval) -> Bool { pendingSpaceApplies(now: now) }
    /// The text a tapped letter would follow, for the soft-key-edge prior: the text before the caret as this
    /// keyboard knows it (`currentBefore`, which includes own edits the proxy has not shown yet), plus the
    /// space a swiped word is owed (ARCHITECTURE.md, "Soft key edges", context). The typing tail belongs to the
    /// field our edits went to: in another one the proxy serves, before a callback reports it, only the proxy
    /// knows. Fields without an identity cannot be told apart, as elsewhere in the keyboard.
    func tapPriorContext(now: TimeInterval) -> String {
        let before = core.documentID == document.documentID ? currentBefore : document.contextBefore
        return (before ?? "") + (tappedLetterGetsSpace(now: now) ? " " : "")
    }
    /// The strip, the edit that put its word in (`swipeEdits`), and for autocorrect's strip the commit it
    /// follows. Held in memory only while the strip shows.
    private var swipe: (strip: SwipeStrip, edit: ExpectedDocument.ID, commit: StripCommit?)? {
        didSet {
            releaseSwipeEdits()
            reportStrip()
        }
    }
    /// The strip while the owned word is typed (ARCHITECTURE.md, "Word autocorrect", Suggestions), shown when no
    /// other strip is. Derived from the word's record after every key; in memory only.
    private var typingSuggestions: WordAutocorrect.Typing? {
        didSet { reportStrip() }
    }
    /// Where the word being typed is: its field (nil if none was identified) and the text after the caret when the
    /// strip first looked at it (own typing never changes that text). The strip shows, and a choice applies, only
    /// there. Kept while the word is typed, dropped with it (it is the field's content).
    private var typingAnchor: (field: UUID?, after: String?)?
    /// The strip waits for the proxy to show the word (it still showed something else, perhaps our own edit late):
    /// the next reading that does brings it back, without another key.
    private var typingSuggestionsAwaitProxy = false
    /// The next words after this keyboard's own space (ARCHITECTURE.md, "Word autocorrect", Next words), shown when no
    /// other strip is, and where they were made: the field, the text before the caret as the editor knew it and after it,
    /// and the edit generation. In memory only.
    private var nextWords: (strip: SwipeStrip, field: UUID?, before: String, after: String?, generation: Int)? {
        didSet { reportStrip() }
    }
    /// The keyboard typed a space after a word (Space, or a tapped word's own space), and since then only Shift and layer
    /// keys: the strip may predict the next word.
    private var predictsNextWord = false {
        didSet { nextWordsAfterBreak = false }
    }
    /// The next words follow a Return typed right after text (set after `predictsNextWord`, which clears it): they show
    /// once the proxy itself shows the line break.
    private var nextWordsAfterBreak = false
    /// The next words after a Return wait for the proxy to show the line break (late, with no callback): the next reading
    /// that does brings them, without another key.
    private var nextWordsAwaitBreak = false
    /// The word this keyboard was typing when it hid (ARCHITECTURE.md, "Word autocorrect", Owned words), in the slot this
    /// editor shares with the next one in the process: its own again only where it appeared again in that field,
    /// unchanged; dropped on any mismatch and at the first key, swipe, dictation or gesture after appearing.
    let parking: ParkedWordSlot
    private var parkedWord: ParkedWordSlot.Word? {
        get { parking.word }
        set { parking.word = newValue }
    }
    /// Between `reset` (the keyboard appeared) and `hide`: only then may a host callback give the kept word back, so a
    /// late callback to a hidden editor never takes it from the next one.
    private var appeared = false

    /// The strip last reported through `onSwipeStripChanged`.
    private var reportedStrip: SwipeStrip?

    private func reportStrip() {
        guard swipeStrip != reportedStrip else { return }
        reportedStrip = swipeStrip
        onSwipeStripChanged?()
    }
    /// The space owed before the next tapped letter or digit after a swiped word ("Space before a tapped
    /// word"), and the edit that put the word in. Separate from the strip, which Shift and layer keys close
    /// while this survives them. In memory only.
    private var pendingSpace: ExpectedDocument.ID? {
        didSet { releaseSwipeEdits() }
    }
    /// The space a strip choice added after its word ("A tapped word ends with one space"), and the edit that put it
    /// there: punctuation typed right after takes the space's place and is followed by it ("word, "), as on Apple's
    /// keyboard. Shift and layer keys keep it; every other key ends it. In memory only.
    private var autoSpace: ExpectedDocument.ID? {
        didSet { releaseSwipeEdits() }
    }

    /// Autocorrect's corrector and inputs, read at each commit key (ARCHITECTURE.md, "Word autocorrect"); nil
    /// while autocorrect is off, without Full Access, or before its model has loaded.
    var autocorrect: () -> AutocorrectSetup? = { nil }
    /// The current word's characters with their taps' touch-down points. In memory only; dropped on hiding.
    private(set) var wordTaps = WordTapRecord()
    /// A digest of the text after the caret when the space after the record's finished word was typed (own typing never
    /// changes it; an in-process hash, the text itself is not kept): a Delete takes that word back only with the same text
    /// after the caret, not at another copy of it the host moved the caret to without a report yet. Dropped with the
    /// finished word.
    private var finishedWordAfter: Int?
    /// Typed words a Delete put back after their autocorrection, lowercased: never corrected again while this
    /// keyboard instance lives. In memory only; kept across hiding, gone with the instance.
    private(set) var revertedWords: Set<String> = []
    /// The words the user asked never to correct (ARCHITECTURE.md, "Word autocorrect", Never correct), as the
    /// bound store holds them: never corrected or offered, like `revertedWords`. None without a store.
    private(set) var neverCorrectWords: Set<String> = []
    /// Where accepted offers are stored; nil (autocorrect off or no Full Access when the keyboard appeared)
    /// offers nothing.
    private var neverCorrectStore: NeverCorrectStore?
    /// The word a revert just offered to never correct, until it is accepted or anything else happens: any key
    /// action (a Delete after the revert included), a strip choice, a swipe, dictation or its undo, the trackpad,
    /// a caret move, an outside edit, another field, or hiding. No timeout.
    private(set) var neverCorrectOffer: NeverCorrectOffer? {
        didSet { if neverCorrectOffer != oldValue { onNeverCorrectOfferChanged?() } }
    }
    /// The offer appeared, changed or went. Never called while there is none, so typing re-renders nothing.
    var onNeverCorrectOfferChanged: (() -> Void)?
    /// The last autocorrection while a Delete can still revert it: its edit (the replacement and the commit
    /// key; the record its strip refers to too, witnessed by both), and the text it replaced with the record to
    /// restore.
    private var pendingRevert: (edit: ExpectedDocument.ID, correction: WordAutocorrect.Correction)? {
        didSet { releaseSwipeEdits() }
    }

    /// What autocorrect's strip follows: the commit key's text after the word (the edit's witness is the strip's
    /// word, then this), and when the commit corrected the word, the typed word as the corrector saw it.
    private struct StripCommit {
        var keyText: String
        var corrected: String?
        /// The key text ends with a space a choice added (`autoSpace`), not one the user typed.
        var addedSpace = false
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

    /// `parking`: where the word being typed is kept across hiding; the keyboard shares one for the process, as iOS may
    /// make a new view controller (and editor) when the keyboard comes back.
    init(document: TextDocument, trackpad: TrackpadController, parking: ParkedWordSlot = ParkedWordSlot()) {
        self.parking = parking
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

    /// The keyboard appeared: start fresh in whatever field it serves, where a word it was typing when it hid may be its
    /// own again (`restoreParkedWord`).
    func reset(numeric: Bool) {
        // A cancelled jump still watched since the keyboard hid goes on in the same field; anything else
        // from before ends here.
        trackpad.appeared()
        appeared = true
        core.reset()
        swipe = nil
        pendingSpace = nil
        autoSpace = nil
        forgetWord()
        ownWordIfFieldEmpty()
        tail.forget()
        untrustedReading = nil
        contextWatchUntil = nil
        typing.resetTiming()
        typing.switchLayer(to: numeric ? .numbers : .letters)
        updateAutomaticShift()
        restoreParkedWord()
        onUndoChanged?()
    }

    /// The keyboard is hiding: the trackpad stops (an outstanding probe rolled back) and every copy of
    /// the field's context goes, but the word being typed (`parkedWord`). Everything typed has already been applied.
    func hide(now: TimeInterval) {
        trackpad.hide(at: now)
        if appeared { parkedWord = parkableWord() }
        appeared = false
        core.hide()
        swipe = nil
        pendingSpace = nil
        autoSpace = nil
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
            autoSpace = nil
            forgetWord()
            ownWordIfFieldEmpty()
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
        restoreParkedWord()
        retryTypingSuggestions()
        retryNextWords()
        return outcome
    }

    /// Another field (or none): nothing from the old one applies here.
    private func fieldChanged() {
        trackpad.fieldChanged()
        swipe = nil
        pendingSpace = nil
        autoSpace = nil
        forgetWord()
        ownWordIfFieldEmpty()
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
        // Whatever the key did, the strip then follows the word being typed, or predicts the next.
        defer {
            refreshTypingSuggestions()
            refreshNextWords()
        }
        parkedWord = nil
        // Only Shift and layer keys keep the next words (recased).
        switch action {
        case .shift, .layer: break
        default: predictsNextWord = false
        }
        // Every key sees whether the proxy now shows a swiped word, before anything changes.
        observeShownSwipeEdits(now: now)
        // Any key action ends the offer to never correct a word (a revert by this key offers anew).
        neverCorrectOffer = nil
        // VoiceOver's delete reverts an autocorrection, or is the strip's first deletion, like the held delete
        // key's.
        if action == .delete, revertCorrection(field: field, now: now) { return }
        if action == .delete, deleteSwipedWord(field: field, now: now) { return }
        // Punctuation right after a tapped word's own space goes before the space.
        if case .character(let mark) = action, WordAutocorrect.commitCharacters.contains(mark), let space = autoSpace,
           holds(space, now: now) {
            pendingRevert = nil
            swipe = nil
            pendingSpace = nil
            autoSpace = nil
            predictsNextWord = type(field: field, now: now, recordEachDeletion: true) { [self] _ in
                let text = typing.text(for: mark)
                typing.didTypeCharacter(text)
                // The space after it is a space: back to letters.
                typing.switchLayer(to: .letters)
                return (1, text + " ")
            }
            return
        }
        // Any other key forgets the pending revert, and any other key action closes the strip, typed or refused.
        pendingRevert = nil
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
        default:
            pendingSpace = nil
            autoSpace = nil
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
                // A Return typed right after text (not whitespace, not an empty field) predicts the next line's first words,
                // read in the field the Return went to (`commit` adopts one the proxy serves before its first callback).
                let afterBreak = action == .returnKey && currentBefore.map(Self.followsTextAndBreak) == true
                predictsNextWord = action == .space || afterBreak
                nextWordsAfterBreak = afterBreak
            } else {
                type(field: field, now: now, point: point) { [self] before in resolve(action, before: before, at: timestamp) }
            }
        }
    }

    /// One deletion of the held delete key, pressed in `field` (nil if none was identified).
    /// While the strip shows, the first deletion (a tap, or a held delete's first) removes the whole
    /// swiped word instead; the strip closes, so repeats are the usual ones.
    func heldDelete(_ unit: DeleteRepeat.Unit, field: UUID?, now: TimeInterval) {
        defer { refreshTypingSuggestions() }
        parkedWord = nil
        predictsNextWord = false
        nextWords = nil
        pendingSpace = nil
        autoSpace = nil
        neverCorrectOffer = nil
        observeShownSwipeEdits(now: now)
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
        parkedWord = nil
        swipe = nil
        pendingSpace = nil
        autoSpace = nil
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
        observeShownSwipeEdits(now: now)
        retryTypingSuggestions()
        retryNextWords()
        guard !trackpad.isActive else { return }
        let shift = typing.shift
        applyAutomaticShift()
        if typing.shift != shift { onStateChanged?() }
    }

    /// A key's edit, now: refused only when it was pressed in another identified field; any gesture
    /// ends first, so the key reads where the caret lands. False if refused. `recordEachDeletion`: every
    /// deletion is recorded as an own edit, for a host that reports each one (a whole word goes at once).
    /// The word's tap record follows the edit: `point` is the tap that typed it.
    @discardableResult
    private func type(field: UUID?, now: TimeInterval, recordEachDeletion: Bool = false, point: TapPoint? = nil,
                      resolve: (String?) -> (deletes: Int, text: String)) -> Bool {
        typeInParts(field: field, now: now, recordEachDeletion: recordEachDeletion, point: point) { before in
            let edit = resolve(before)
            return (edit.deletes, [edit.text])
        }
    }

    /// `type`, with the text inserted in parts, each its own `insertText` (an autocorrection, then its commit
    /// key: hosts act on a Return inserted alone).
    @discardableResult
    private func typeInParts(field: UUID?, now: TimeInterval, recordEachDeletion: Bool = false, point: TapPoint? = nil,
                             resolve: (String?) -> (deletes: Int, texts: [String])) -> Bool {
        if let field, let current = document.documentID, field != current { return false }
        adoptCurrentField()
        trackpad.interrupt(at: now)
        // Typing over a selection replaces text the record does not know.
        if document.hasSelection { wordTaps.clear() }
        let edit = resolve(currentBefore)
        userEdit()
        if edit.deletes > 0 { deleteGraphemes(edit.deletes, now: now, recordEach: recordEachDeletion) }
        for text in edit.texts where !text.isEmpty { insert(text, now: now) }
        // A Delete of the space typed right after the word before: that word is the keyboard's own again only where the proxy
        // shows exactly it before the caret, and the text after the caret it was finished at (ARCHITECTURE.md, "Word
        // autocorrect", Owned words, Deletion).
        let finished = wordTaps.finished
        if wordTaps.edited(deleted: edit.deletes, inserted: edit.texts.joined(), point: point),
           !wordTaps.isShown(before: document.contextBefore)
            || Self.digest(before: nil, after: document.contextAfter) != finishedWordAfter {
            wordTaps.clear()
        }
        if wordTaps.finished == nil {
            finishedWordAfter = nil
        } else if wordTaps.finished != finished {
            finishedWordAfter = Self.digest(before: nil, after: document.contextAfter)
        }
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
        parkedWord = nil
        predictsNextWord = false
        nextWords = nil
        neverCorrectOffer = nil
        // A swipe forgets a pending revert and a choice's space, as any other key does.
        pendingRevert = nil
        autoSpace = nil
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
        // A swiped word is never this keyboard's own typing for autocorrect: the decoder chose it.
        wordTaps.clear()
        typingSuggestions = nil
        guard typed, let strip, let context else {
            // A refused swipe is still a key action: the strip closes, and no space is pending.
            swipe = nil
            pendingSpace = nil
            autoSpace = nil
            return
        }
        let placed = recordSwipeEdit(of: strip.insertedWord, context, now: now)
        // The pending space first, so the old word's edit is let go before the strip is reported changed.
        pendingSpace = placed
        swipe = (strip, placed, nil)
        observeShownSwipeEdits(now: now)
    }

    /// A tap on the strip's candidate `index`: it replaces the inserted word (and after a commit key, puts the
    /// key's text back after it), but only while nothing else has edited the field and the text before the caret
    /// still ends with the word (and the key's text). Otherwise the tap does nothing and the strip closes. After a
    /// commit key, choosing the typed word over a correction reverts it as a Delete would, and choosing the
    /// correction back undoes that.
    func chooseSwipeCandidate(at index: Int, now: TimeInterval) {
        guard let shown = swipe else { return chooseTypingSuggestion(at: index, now: now) }
        neverCorrectOffer = nil
        guard let strip = currentSwipe(now: now) else {
            swipe = nil
            pendingSpace = nil
            autoSpace = nil
            return
        }
        guard strip.candidates.indices.contains(index) else { return }
        // The word ends with one space: the commit key's, or one added after it (or after a swiped word).
        let keyText = shown.commit?.keyText ?? ""
        let spaced = keyText.last?.isWhitespace == true || document.contextAfter?.first == " " ? keyText : keyText + " "
        guard index != strip.inserted || spaced != keyText else {
            // The word already in the field, confirmed after a commit key: a Delete after it is a plain Delete.
            if shown.commit != nil { pendingRevert = nil }
            return
        }
        let old = (strip.insertedWord + keyText).count
        let new = strip.candidates[index] + spaced
        var context: SwipeEditContext?
        let replaced = type(field: swipeEdits[shown.edit]?.documentID, now: now, recordEachDeletion: true) { [self] before in
            context = SwipeEditContext(reading: proxyReading, deleted: old, inserted: new,
                                       before: String((before ?? "").dropLast(old)) + new)
            // A space the choice adds is a space: back to letters, as after the space key.
            if spaced != keyText { typing.switchLayer(to: .letters) }
            return (old, new)
        }
        // The record follows the edit: after the space the choice ends with, the next word is this keyboard's own. A
        // swiped word chosen before a space already there stays the decoder's.
        if shown.commit == nil, spaced.isEmpty { wordTaps.clear() }
        pendingRevert = nil
        guard replaced, let context else {
            swipe = nil
            return
        }
        // Ending with the keyboard's own space, the next words follow once this strip closes (Shift, a layer key).
        predictsNextWord = spaced.last?.isWhitespace == true
        let placed = recordSwipeEdit(of: new, context, now: now)
        // The space the choice added: punctuation typed next goes before it.
        let added = spaced != keyText || shown.commit?.addedSpace == true
        // Every reference to the new edit is made before any to the old one goes, so it is never let go.
        if added { autoSpace = placed }
        defer { if !added { autoSpace = nil } }
        if let commit = shown.commit {
            // Before a space already there after a mark: a letter typed next gets a space of its own first. Set first, so
            // the old word's edit is let go before the strip is reported changed.
            if spaced.last?.isWhitespace != true { pendingSpace = placed }
            swipe = (SwipeStrip(candidates: strip.candidates, inserted: index), placed,
                     StripCommit(keyText: spaced, corrected: commit.corrected, addedSpace: added))
            if let typed = commit.corrected, index == 0 {
                revertedWords.insert(typed)
                offerNeverCorrect(typed, typed: strip.candidates[index])
            } else {
                // The correction chosen back undoes its revert.
                if let typed = commit.corrected, index == 1 { revertedWords.remove(typed) }
            }
        } else if spaced.isEmpty {
            // Before a space already there, still the swiped word: the pending space first, so the old word's edit is
            // let go before the strip is reported changed.
            pendingSpace = placed
            swipe = (SwipeStrip(candidates: strip.candidates, inserted: index), placed, nil)
        } else {
            // The word has its space now: none is owed, and later choices replace it with the word.
            pendingSpace = nil
            swipe = (SwipeStrip(candidates: strip.candidates, inserted: index), placed,
                     StripCommit(keyText: spaced, corrected: nil, addedSpace: true))
        }
        observeShownSwipeEdits(now: now)
    }

    /// Closes the strip and ends a pending space (the trackpad began, even without a gesture).
    func closeSwipeStrip() {
        swipe = nil
        pendingSpace = nil
        autoSpace = nil
        forgetWord()
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

    /// Forgets every recorded edit that neither the strip, the pending space nor the pending revert refers to.
    private func releaseSwipeEdits() {
        swipeEdits.removeAll(keeping: Set([swipe?.edit, pendingSpace, pendingRevert?.edit, autoSpace].compactMap { $0 }))
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
        assert(swipeEditCount <= 1, "The strip, the pending space and the pending revert refer to at most one recorded edit")
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

    /// The strip's first deletion after a swipe: the whole swiped word, not the space before it. False (nothing
    /// deleted) when the word can no longer be deleted whole, the strip follows a commit key, or the press is
    /// refused.
    private func deleteSwipedWord(field: UUID?, now: TimeInterval) -> Bool {
        guard swipe?.commit == nil, let strip = currentSwipe(now: now) else { return false }
        let count = strip.insertedWord.count
        let deleted = type(field: field, now: now, recordEachDeletion: true) { [self] _ in
            typing.didDelete()
            return (count, "")
        }
        guard deleted else { return false }
        swipe = nil
        // What is left may be a word and a space: the next words show as after that space (`refreshNextWords` checks).
        predictsNextWord = true
        refreshNextWords()
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

    /// A commit key (`WordAutocorrect.isCommitKey`): the owned word before it (`wordTaps`) may first be replaced
    /// by its correction, in the same edit as the key: exactly the word's characters this keyboard typed are
    /// deleted, the correction is inserted, and then the key's text as its own insertion. A Delete right after
    /// can revert it. The strip then shows the review's choices, except after Return (which may move focus).
    private func commit(_ action: KeyAction, field: UUID?, at timestamp: TimeInterval, now: TimeInterval) {
        var made: (correction: WordAutocorrect.Correction, context: SwipeEditContext)?
        var offered: (review: WordAutocorrect.Review, keyText: String, context: SwipeEditContext)?
        typeInParts(field: field, now: now, recordEachDeletion: true) { [self] before in
            let text = before ?? ""
            // Owned AND shown by the host: the proxy must show exactly the word after its separator (a host may
            // have rejected characters, or not show our edits yet). A veto only: the deletions still come from
            // the record. Not over a selection either, which the first deletion would remove instead.
            let shown = wordTaps.isShown(before: document.contextBefore)
            if !shown { wordTaps.clear() }
            let setup = document.hasSelection || !shown ? nil : autocorrect()
            let review = WordAutocorrect.review(before: text, record: wordTaps, reverted: revertedWords,
                                                neverCorrect: neverCorrectWords, setup: setup)
            guard let review, let correction = review.correction else {
                let edit = resolve(action, before: before, at: timestamp)
                // A key that deletes (a double space's period) follows a space, never a word; kept for safety.
                if let review, edit.deletes == 0, text.hasSuffix(review.typed) {
                    offered = (review, edit.text, SwipeEditContext(reading: proxyReading, deleted: 0, inserted: edit.text,
                                                                   before: text + edit.text))
                }
                return (edit.deletes, [edit.text])
            }
            let corrected = String(text.dropLast(correction.typed.count)) + correction.replacement
            let edit = resolve(action, before: corrected, at: timestamp)
            guard edit.deletes == 0 else { return (edit.deletes, [edit.text]) }
            let context = SwipeEditContext(reading: proxyReading, deleted: correction.typed.count,
                                           inserted: correction.replacement + edit.text, before: corrected + edit.text)
            made = (correction, context)
            offered = (review, edit.text, context)
            return (correction.typed.count, [correction.replacement, edit.text])
        }
        guard let offered else { return }
        let review = offered.review
        let showsStrip = action != .returnKey && !review.choices.isEmpty
        // Return can move focus before the proxy reports the next field, where a revert's deletions would land:
        // it never arms one. Nor does a field without an identity, which cannot be told from the next.
        let armsRevert = made != nil && action != .returnKey && document.documentID != nil
        guard showsStrip || armsRevert else { return }
        // One record for both: with a correction, the strip's word (the review's inserted choice) is the
        // replacement.
        let witness = (made?.correction.replacement ?? review.choices[review.inserted]) + offered.keyText
        let placed = recordSwipeEdit(of: witness, offered.context, now: now)
        if showsStrip {
            swipe = (SwipeStrip(candidates: review.choices, inserted: review.inserted), placed,
                     StripCommit(keyText: offered.keyText, corrected: review.correction?.word))
        }
        if armsRevert, let made { pendingRevert = (placed, made.correction) }
        observeShownSwipeEdits(now: now)
    }

    /// A Delete right after an autocorrection, while the field still ends with it and nothing else has edited
    /// it: the replacement and its commit key give way to the typed word, the caret right after it, and the word
    /// is never corrected again in this keyboard instance. False (nothing done) otherwise; the pending revert
    /// is gone either way.
    private func revertCorrection(field: UUID?, now: TimeInterval) -> Bool {
        guard let pending = pendingRevert, let witness = swipeEdits[pending.edit]?.witness else {
            pendingRevert = nil
            return false
        }
        // Provably the same field: identified, the same identity the correction was made in, and the edit holds.
        // Checked before the revert is let go, which may release its record.
        let applies = document.documentID != nil && document.documentID == swipeEdits[pending.edit]?.documentID
            && holds(pending.edit, now: now)
        pendingRevert = nil
        guard applies else { return false }
        let reverted = type(field: field, now: now, recordEachDeletion: true) { [self] _ in
            typing.didDelete()
            return (witness.count, pending.correction.typed)
        }
        guard reverted else { return false }
        swipe = nil
        wordTaps = pending.correction.record
        // The field is as the correction left it (`holds`), and own typing never changes the text after the caret: the word
        // before the typed one may still be taken back.
        finishedWordAfter = wordTaps.finished == nil ? nil : Self.digest(before: nil, after: document.contextAfter)
        revertedWords.insert(pending.correction.word)
        offerNeverCorrect(pending.correction.word, typed: pending.correction.typed)
        return true
    }

    // MARK: Never correct (ARCHITECTURE.md, "Word autocorrect", Never correct)

    /// Binds the store of words never to correct and loads them, replacing those in memory, so a clear made in the
    /// app applies from the keyboard's next appearance. The keyboard binds it each time it appears with
    /// autocorrect on (which needs Full Access); nil there drops the words from memory and offers nothing.
    func useNeverCorrectStore(_ store: NeverCorrectStore?) {
        neverCorrectStore = store
        neverCorrectWords = Set(store?.load().words ?? [])
        if store == nil { neverCorrectOffer = nil }
    }

    /// The user tapped the offer: its word is added to the store (and to the words in memory, as the store now
    /// holds them), the offer goes, and the strip closes, its choice made. Nothing without an offer or a store.
    func acceptNeverCorrect() {
        guard let offer = neverCorrectOffer, let neverCorrectStore else { return }
        neverCorrectOffer = nil
        // What the store holds, or would if the write failed: the word is not corrected in this instance either way.
        neverCorrectWords = Set(neverCorrectStore.add(offer.word).words)
        swipe = nil
        typingSuggestions = nil
    }

    /// A revert offers to never correct its word, with a store bound and a word the store can keep.
    private func offerNeverCorrect(_ word: String, typed: String) {
        guard neverCorrectStore != nil, NeverCorrectWords.isStorable(word), !neverCorrectWords.contains(word) else { return }
        var shown = typed
        while let last = shown.last, WordTapRecord.apostrophes.contains(last) { shown.removeLast() }
        neverCorrectOffer = NeverCorrectOffer(word: word, typed: shown)
    }

    /// The letters layer was laid out anew (a resize or rotation): the current word's recorded points belong to
    /// the old geometry, so they become none; its characters stay.
    func layoutChanged() {
        wordTaps.forgetPoints()
        // So for the record a revert would restore.
        pendingRevert?.correction.record.forgetPoints()
    }

    /// The caret moved, the field changed or something else edited it: no word is this keyboard's own any more,
    /// and a pending revert no longer applies. The reverted words stay.
    private func forgetWord() {
        wordTaps.clear()
        finishedWordAfter = nil
        typingSuggestions = nil
        typingAnchor = nil
        typingSuggestionsAwaitProxy = false
        nextWords = nil
        predictsNextWord = false
        nextWordsAwaitBreak = false
        pendingRevert = nil
        neverCorrectOffer = nil
    }

    // MARK: Suggestions while typing (ARCHITECTURE.md, "Word autocorrect", Suggestions)

    /// After every key: the strip for the owned word being typed, where autocorrect runs and no other strip shows.
    private func refreshTypingSuggestions() {
        // The editor's copy shows the word, and the proxy does too, or an earlier state of it while it lags: a field
        // switched without a report shows something else.
        typingSuggestionsAwaitProxy = false
        guard swipe == nil, !document.hasSelection, let before = currentBefore, wordTaps.isShown(before: before),
              WordAutocorrect.word(before: wordTaps.text) != nil else {
            typingSuggestions = nil
            typingAnchor = nil
            return
        }
        guard wordTaps.mayBeShown(before: document.contextBefore) else {
            typingSuggestions = nil
            typingSuggestionsAwaitProxy = true
            return
        }
        // The caret the word began at: a host that moved it without a report yet (a Shift or layer key refreshes too)
        // has other text after it.
        let anchor = typingAnchor ?? (core.documentID, document.contextAfter)
        typingAnchor = anchor
        guard anchor.field == core.documentID, anchor.after == document.contextAfter else {
            typingSuggestions = nil
            return
        }
        // Caps lock, or a field that capitalizes every character: one capital letter is already all capitals.
        let allCapitals = typing.shift == .capsLock || autocapitalization() == .allCharacters
        typingSuggestions = WordAutocorrect.typingStrip(before: before, record: wordTaps, reverted: revertedWords,
                                                        neverCorrect: neverCorrectWords, allCapitals: allCapitals,
                                                        setup: autocorrect())
    }

    /// The strip waited for the proxy, which now shows the word: it comes back.
    private func retryTypingSuggestions() {
        guard typingSuggestionsAwaitProxy, wordTaps.mayBeShown(before: document.contextBefore) else { return }
        refreshTypingSuggestions()
    }

    /// A tap on the typing strip's word `index`: it replaces the word being typed and ends with one space, the caret
    /// after it (the space already after the caret, if there is one). The word as typed keeps it; kept over a pending
    /// correction, it is never corrected again in this keyboard instance, as a revert would leave it. Only while the
    /// word is still the keyboard's own and the proxy shows it, as at a commit key; otherwise the strip closes.
    private func chooseTypingSuggestion(at index: Int, now: TimeInterval) {
        guard let typing = typingSuggestions else { return chooseNextWord(at: index, now: now) }
        guard typing.strip.candidates.indices.contains(index) else { return }
        parkedWord = nil
        neverCorrectOffer = nil
        pendingRevert = nil
        pendingSpace = nil
        autoSpace = nil
        // The field the word was typed in, still current (a proxy that switched fields before reporting it serves
        // another), with the word shown before the caret, as at a commit key, and the same text after it (a caret the
        // host moved after another copy of the word, not reported yet, has other text after it).
        guard let anchor = typingAnchor, anchor.field == core.documentID, core.documentID == document.documentID,
              !document.hasSelection, wordTaps.isShown(before: document.contextBefore), document.contextAfter == anchor.after
        else {
            typingSuggestions = nil
            return
        }
        let chosen = typing.strip.candidates[index]
        let space = document.contextAfter?.first == " " ? "" : " "
        let edit = chosen == typing.typed ? (deletes: 0, text: space) : (deletes: typing.deletes, text: chosen + space)
        var context: SwipeEditContext?
        let typed = type(field: anchor.field, now: now, recordEachDeletion: true) { [self] before in
            context = SwipeEditContext(reading: proxyReading, deleted: edit.deletes, inserted: edit.text,
                                       before: String((before ?? "").dropLast(edit.deletes)) + edit.text)
            // The space it adds is a space: back to letters, as after the space key.
            if !space.isEmpty { self.typing.switchLayer(to: .letters) }
            return edit
        }
        if typed, let context {
            let placed = recordSwipeEdit(of: chosen + space, context, now: now)
            if space.isEmpty {
                // Before a space already there the caret stays put: the word ends here all the same, and a letter typed
                // next gets a space of its own first, as after a swiped word.
                wordTaps.clear()
                pendingSpace = placed
            } else {
                autoSpace = placed
                // The word is finished and spaced: the strip predicts the next.
                predictsNextWord = true
            }
        }
        if typing.strip.live?.quoted == index {
            revertedWords.insert(typing.word)
            offerNeverCorrect(typing.word, typed: typing.typed)
        }
        typingSuggestions = nil
        typingAnchor = nil
        refreshNextWords()
    }

    // MARK: Next words (ARCHITECTURE.md, "Word autocorrect", Next words)

    /// After every key and tapped word: the next words, while the keyboard's own space after a word is the last thing it
    /// typed (Shift and layer keys aside), where autocorrect predicts (`AutocorrectSetup.predictsNextWords`), no other
    /// strip shows, nothing is selected and the field is the one the editor knows. Cased as a letter typed there would be
    /// (`swipeShift`), the pronoun I and day names with their capital. Never a single letter alone ("I" read as a stray bar
    /// or a second caret): the status line stays instead.
    private func refreshNextWords() {
        nextWordsAwaitBreak = false
        guard predictsNextWord, swipe == nil, typingSuggestions == nil, !document.hasSelection,
              core.documentID == document.documentID, let before = currentBefore,
              nextWordsAfterBreak || Self.followsWordAndSpace(before),
              let setup = autocorrect(), setup.predictsNextWords else {
            nextWords = nil
            return
        }
        // After a Return, only once the proxy itself shows the line break (perhaps alone, in a window of the line): the host
        // took it as one (a field whose Return acts takes none) and the field is still the one it went to.
        guard !nextWordsAfterBreak || document.contextBefore?.last == "\n" else {
            nextWords = nil
            nextWordsAwaitBreak = true
            return
        }
        let found = setup.corrector.nextWords(context: TapPrior.normalizeContext(before), limit: SwipeStrip.limit)
        let shift = swipeShift(after: before)
        var cased: [String] = []
        for word in found {
            let named = WordAutocorrect.takesCapital(word) ? word.prefix(1).uppercased() + word.dropFirst() : word
            let candidate = Self.swipeCased(named, shift: shift)
            if cased.count < SwipeStrip.limit, !cased.contains(candidate) { cased.append(candidate) }
        }
        guard !cased.isEmpty, cased.count > 1 || cased[0].count > 1 else {
            nextWords = nil
            return
        }
        nextWords = (SwipeStrip(candidates: cased, inserted: 0, live: SwipeStrip.Live(quoted: nil, marked: nil)),
                     core.documentID, before, document.contextAfter, core.generation)
    }

    /// Whether the text before the caret ends with one space after something other than whitespace: a finished word
    /// (or its punctuation) and a space.
    static func followsWordAndSpace(_ before: String) -> Bool {
        guard before.last == " ", let previous = before.dropLast().last else { return false }
        return !previous.isWhitespace
    }

    /// Whether the text before the caret ends with a line break right after something other than whitespace: a Return
    /// typed after text (round 7).
    static func followsTextAndBreak(_ before: String) -> Bool {
        guard before.last == "\n", let previous = before.dropLast().last else { return false }
        return !previous.isWhitespace
    }

    /// The next words after a Return waited for the proxy, which now shows the line break: they come. Like the typing
    /// strip's wait, only at a callback or while the context watch runs after the Return (`service`).
    private func retryNextWords() {
        guard nextWordsAwaitBreak, document.contextBefore?.last == "\n" else { return }
        refreshNextWords()
    }

    /// A tap on a next word: it goes in with one space after it (none before a space already after the caret), the caret
    /// after it, like a tapped suggestion; the strip then predicts the word after it. Only in the field the words were
    /// made for, nothing edited since, the proxy showing the space and the same text before (its window and the editor's
    /// may each be the longer) and after the caret, nothing selected; otherwise the strip closes and nothing is typed.
    private func chooseNextWord(at index: Int, now: TimeInterval) {
        guard let shown = nextWords, shown.strip.candidates.indices.contains(index) else { return }
        parkedWord = nil
        neverCorrectOffer = nil
        pendingRevert = nil
        pendingSpace = nil
        autoSpace = nil
        nextWords = nil
        predictsNextWord = false
        // The proxy itself must show the space there, nothing edited since: its window of the text before the caret and
        // the editor's (a bounded tail) may each be the longer one. A proxy that lags or lost the space misses the tap.
        guard shown.field == core.documentID, core.documentID == document.documentID, !document.hasSelection,
              core.generation == shown.generation, let proxyBefore = document.contextBefore,
              Self.followsWordAndSpace(proxyBefore) || proxyBefore.last == "\n",
              proxyBefore.hasSuffix(shown.before) || shown.before.hasSuffix(proxyBefore),
              document.contextAfter == shown.after else { return }
        let chosen = shown.strip.candidates[index]
        let space = document.contextAfter?.first == " " ? "" : " "
        var context: SwipeEditContext?
        let typed = type(field: shown.field, now: now) { [self] before in
            context = SwipeEditContext(reading: proxyReading, deleted: 0, inserted: chosen + space,
                                       before: (before ?? "") + chosen + space)
            // A one-shot shift is consumed as by a typed letter; the space it adds is a space: back to letters.
            typing.didTypeCharacter(chosen)
            if !space.isEmpty { typing.switchLayer(to: .letters) }
            return (0, chosen + space)
        }
        guard typed, let context else { return }
        let placed = recordSwipeEdit(of: chosen + space, context, now: now)
        if space.isEmpty {
            // Before a space already there the caret stays put: a letter typed next gets a space of its own first.
            wordTaps.clear()
            pendingSpace = placed
        } else {
            autoSpace = placed
            predictsNextWord = true
        }
        updateAutomaticShift()
        refreshNextWords()
    }

    // MARK: The word across hiding (ARCHITECTURE.md, "Word autocorrect", Owned words)

    /// The word to keep as the keyboard hides: the keyboard's own word being typed, in an identified field, shown by the
    /// proxy before the caret, nothing selected. Its points go (the keys may move before it is typed on); the text around
    /// the caret is kept only as a digest, to tell it is unchanged.
    private func parkableWord() -> ParkedWordSlot.Word? {
        guard wordTaps.owned, WordAutocorrect.word(before: wordTaps.text) != nil, let field = core.documentID,
              field == document.documentID, !document.hasSelection, let before = document.contextBefore,
              wordTaps.isShown(before: before) else { return nil }
        // Not the word before it: hiding ends deleting back into that one.
        var record = WordTapRecord(entries: wordTaps.entries, owned: true, boundary: wordTaps.boundary)
        record.forgetPoints()
        return ParkedWordSlot.Word(record: record, around: Self.digest(before: before, after: document.contextAfter))
    }

    private static func digest(before: String?, after: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(before)
        hasher.combine(after)
        return hasher.finalize()
    }

    /// The keyboard appeared, or the host reported something since: the kept word is its own again where the proxy
    /// serves an identified field the editor knows, nothing is selected and the text around the caret is as it was.
    /// The identifier itself is not compared: after an app switch Messages and Reminders give the same field a new one.
    /// Other text or a selection drops it; a proxy that does not identify the field yet decides nothing. Kept until the
    /// first key or gesture, because a host reports the field unchanged after appearing, a callback the editor cannot
    /// tell from an outside edit, which forgets the word: the next restore takes it back.
    private func restoreParkedWord() {
        guard appeared, let parked = parkedWord, let field = document.documentID else { return }
        guard core.documentID == field, !document.hasSelection,
              Self.digest(before: document.contextBefore, after: document.contextAfter) == parked.around else {
            parkedWord = nil
            return
        }
        guard WordAutocorrect.word(before: wordTaps.text) == nil else { return }
        wordTaps = parked.record
        typingAnchor = nil
        refreshTypingSuggestions()
    }

    /// The start of a field this keyboard sees empty (nothing before or after the caret, nothing selected) is a
    /// boundary: a word typed there is its own.
    private func ownWordIfFieldEmpty() {
        guard (document.contextBefore ?? "").isEmpty, (document.contextAfter ?? "").isEmpty, !document.hasSelection else { return }
        wordTaps.startOwned()
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

    /// Autocorrect's model loaded (or went): the strip follows the word being typed, or the next words, with it. A word
    /// the keyboard took back as it appeared (`restoreParkedWord`) gets its strip once the model is there.
    func autocorrectChanged() {
        refreshTypingSuggestions()
        refreshNextWords()
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
        parkedWord = nil
        swipe = nil
        pendingSpace = nil
        autoSpace = nil
        forgetWord()
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
        parkedWord = nil
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

/// The word the keyboard was typing when it hid (ARCHITECTURE.md, "Word autocorrect", Owned words), kept for the next
/// editor: iOS makes a new view controller when the keyboard comes back after an app switch, in the same process. Its
/// record without points and a digest of the text around the caret (the text itself is not kept).
/// In memory only, gone with the process; never stored, logged or sent. Main thread only.
final class ParkedWordSlot {
    struct Word {
        var record: WordTapRecord
        var around: Int
    }

    var word: Word?

    init() {}
}
