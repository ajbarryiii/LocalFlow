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
/// ARCHITECTURE.md, "Typing model v2: immediate execution": a key edits through the proxy the moment it
/// is typed, ending any trackpad gesture on the spot; it is refused only in another identified field.
/// Context is read in memory only and never stored or logged; every copy is dropped on hiding and
/// expires on its own clock otherwise.
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
    /// The candidate strip opened, changed or closed (`swipeStrip`). Never called while it stays closed.
    var onSwipeStripChanged: (() -> Void)?
    /// The offer to never correct a reverted word appeared, changed or went (`neverCorrectOffer`).
    var onNeverCorrectOfferChanged: (() -> Void)?
    /// The swipe engine, once loaded (`loadSwipeEngine`); nil keeps swipe typing off.
    private var swipeEngine: SwipeEngine? {
        didSet { updateTouchModes() }
    }
    private var swipeEngineLoading = false
    /// The App Group settings, read on every tap soft key edges re-decide (the rule values) and when the
    /// typing counters are added; nil without Full Access.
    var sharedSettings: () -> LocalFlowSettings? = { nil }
    /// The TestFlight typing counters' pending counts while they are on (`configureTypingCounters`), and how
    /// many events they hold since they were last added to the App Group's.
    private var counters: TypingCounters?
    private var pendingCounterEvents = 0
    /// Pending counts are added to the App Group's after this many events, and when the keyboard hides.
    private static let countersFlushEvents = 50
    /// Soft key edges once their model has loaded (`configureSoftKeyEdges`): the bundle's `tap` section, the
    /// model's name and the prior with its cache. Nil keeps letter taps as they are.
    private var softKeys: (manifest: SoftKeyEdgesManifest, model: String)?
    private var tapPrior: TapPrior?
    /// Bumped by every configuration, so a load that finishes after a newer one is dropped.
    private var softKeysGeneration = 0
    /// Autocorrect once its model has loaded (`configureAutocorrect`): the bundle's `autocorrect` section, the
    /// model's name, the chosen preset's parameters and the corrector. Nil keeps words as typed.
    private var autocorrect: (manifest: AutocorrectManifest, model: String, preset: AutocorrectParams,
                              corrector: WordCorrecting)?
    /// Bumped by every configuration, so a load that finishes after a newer one is dropped.
    private var autocorrectGeneration = 0

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
        editor.onFieldChanged = { [weak self] field in self?.fieldChanged(to: field) }
        editor.onSwipeStripChanged = { [weak self] in self?.onSwipeStripChanged?() }
        editor.onNeverCorrectOfferChanged = { [weak self] in self?.onNeverCorrectOfferChanged?() }
        editor.autocorrect = { [weak self] in self?.autocorrectSetup() }
        editor.onAutocorrectEvent = { [weak self] event in self?.countAutocorrect(event) }
        keyArea.currentField = { [weak controller] in controller?.textDocumentProxy.documentIdentifierIfAvailable }
    }

    var trackpad: TrackpadController { editor.trackpad }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private var now: TimeInterval { CACurrentMediaTime() }

    /// A trackpad gesture is running: a dictated result stays unclaimed in the shared files.
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
        updateTouchModes()
    }

    /// The keyboard is hiding: end every gesture and held key and, synchronously, drop every copy of
    /// the field's context and identity (the trackpad snapshot and its layout, its unit, the undo text
    /// and anchors, the typing tail). A probe still out is rolled back first. Every key typed has already
    /// been applied.
    func stop() {
        cancelHeldActions()
        editor.hide(now: now)
        stopUndoTimers()
        tailExpiry?.invalidate()
        tailExpiry = nil
        serviceTimer?.invalidate()
        serviceTimer = nil
        tapPrior?.clear()
        autocorrect?.corrector.forgetContext()
        flushCounters()
    }

    // MARK: Typing counters (ARCHITECTURE.md, "Dropped taps: reach, skids and counters"; TestFlight only)

    /// The keyboard appeared with the counters on or off. Turning them off adds what is pending first.
    func configureTypingCounters(enabled: Bool) {
        if enabled {
            if counters == nil { counters = TypingCounters() }
        } else {
            flushCounters()
            counters = nil
        }
        keyArea?.countsEvents = enabled
    }

    /// Counts nothing while the counters are off.
    private func count(_ event: TypingCounters.Event, in regions: [TypingCounters.Region]) {
        guard counters != nil, !regions.isEmpty else { return }
        counters?.add(event, regions: regions)
        pendingCounterEvents += 1
        if pendingCounterEvents >= Self.countersFlushEvents { flushCounters() }
    }

    /// Adds the pending counts to the App Group's (dropped without Full Access).
    private func flushCounters() {
        pendingCounterEvents = 0
        guard let pending = counters, !pending.isEmpty else { return }
        counters = TypingCounters()
        sharedSettings()?.addTypingCounters(pending)
    }

    /// A `textDidChange` (`textChanged`) or `selectionDidChange` callback.
    func hostChanged(textChanged: Bool) {
        editor.hostChanged(textChanged: textChanged, now: now)
        // The field's traits may have changed with it (secure text entry).
        updateTouchModes()
    }

    /// Another field became current (a callback, or adopted for a key typed before it): held keys and a
    /// held delete pressed before any identity bind to it; those bound to a different identified field
    /// end without acting.
    private func fieldChanged(to field: UUID?) {
        if deleteKey.fieldChanged(to: field) { endDeleteRepeat() }
        keyArea?.fieldChanged(to: field)
        // The prior's cache holds the old field's text.
        tapPrior?.clear()
        updateTouchModes()
    }

    // MARK: Swipe typing

    /// Loads the swipe bundle from the keyboard extension off the main thread, once. Until it has loaded,
    /// and for good if it is missing or invalid, swipe typing stays off and long drags are taps.
    func loadSwipeEngine() {
        guard swipeEngine == nil, !swipeEngineLoading, let directory = SwipeEngine.bundledDirectory else { return }
        swipeEngineLoading = true
        Task { [weak self] in
            let engine = await Task.detached(priority: .userInitiated) { try? SwipeEngine.load(from: directory) }.value
            guard let self else { return }
            self.swipeEngineLoading = false
            self.swipeEngine = engine
        }
    }

    /// Swipe typing and soft taps are on only with their models loaded and outside secure text entry. Letter
    /// taps carry their touch-down point (soft taps) for soft key edges or autocorrect; without soft key edges
    /// they type their nearest key.
    private func updateTouchModes() {
        let secure = proxy?.isSecureTextEntry == true
        let swipe = swipeEngine != nil && !secure
        if keyArea?.swipeEnabled != swipe { keyArea?.swipeEnabled = swipe }
        let softTaps = (tapPrior != nil || autocorrect != nil) && !secure
        if keyArea?.softTapsEnabled != softTaps { keyArea?.softTapsEnabled = softTaps }
    }

    // MARK: Soft key edges

    /// The keyboard appeared with these settings (ARCHITECTURE.md, "Soft key edges"): off drops the model;
    /// on loads the chosen one (the bundle's default if the bundle lacks it) off the main thread, unless it
    /// is already loaded. Until it has loaded, and for good if the bundle has no `tap` section or a file is
    /// missing or invalid, letter taps type their nearest key.
    func configureSoftKeyEdges(enabled: Bool, model stored: String?) {
        if let softKeys, enabled, tapPrior != nil, softKeys.manifest.modelName(stored) == softKeys.model { return }
        softKeysGeneration += 1
        softKeys = nil
        tapPrior = nil
        updateTouchModes()
        guard enabled, let directory = SwipeEngine.bundledDirectory else { return }
        let generation = softKeysGeneration
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                try? Self.loadSoftKeyEdges(from: directory, model: stored)
            }.value
            guard let self, generation == self.softKeysGeneration, let loaded else { return }
            self.softKeys = (loaded.manifest, loaded.name)
            self.tapPrior = TapPrior(model: loaded.model, surpriseWindow: loaded.manifest.rule.surpriseWindow)
            self.updateTouchModes()
        }
    }

    /// The swipe bundle's `tap` section and the chosen model; nil without the section. Slow: off the main
    /// thread.
    private nonisolated static func loadSoftKeyEdges(from directory: URL, model stored: String?) throws
        -> (manifest: SoftKeyEdgesManifest, name: String, model: TapModel)? {
        let data = try Data(contentsOf: directory.appendingPathComponent("bundle.json"))
        guard let manifest = try SoftKeyEdgesManifest.decode(from: data) else { return nil }
        let name = manifest.modelName(stored)
        guard let path = manifest.models[name] else { return nil }
        return (manifest, name, try TapModel.load(from: directory.appendingPathComponent(path)))
    }

    /// The key a soft tap types: the nearest key, unless `TapDecoder` re-decides it from the prior. The
    /// context is the text before the cursor as the editor knows it, own edits the proxy has not shown yet
    /// included, plus the space owed after a swiped word (`KeyboardEditor.tapPriorContext`). The rule values
    /// are read from the settings now. The prior's cache is bound to the current field first, and a tap bound
    /// to another identified field (which the editor refuses) is not predicted. On the main thread; nothing
    /// here is logged or kept beyond the prior's in-memory cache, and, with the TestFlight counters on,
    /// counts of whether the tap changed, by row and edge.
    private func softTapKey(_ action: KeyAction, x: Double, y: Double, field: UUID?, keyArea: KeyAreaView) -> KeyAction {
        guard let softKeys, tapPrior != nil else { return action }
        // Bound first, even for a tap that is not predicted (a secure field, a refused stale tap).
        let current = proxy?.documentIdentifierIfAvailable
        tapPrior?.bind(to: current)
        guard proxy?.isSecureTextEntry != true else { return action }
        if let field, let current, field != current { return action }
        let context = editor.tapPriorContext(now: now)
        guard let prediction = tapPrior?.prediction(context: context) else { return action }
        let metrics = KeyboardMetrics(width: Double(keyArea.bounds.width), height: Double(keyArea.bounds.height))
        let keys = KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: keyArea.showsGlobe)
        let decoder = TapDecoder(touch: TapDecoder.TouchModel(softKeys.manifest.touch),
                                 rule: TapDecoder.Rule(defaults: softKeys.manifest.rule, settings: sharedSettings()))
        let typed = decoder.resolve(action, x: x, y: y, keys: keys, logPrior: prediction.logProbs, surprise: prediction.surprise)
        if counters != nil {
            let regions = TypingCounters.regions(x: x, y: y, keys: keys)
            count(.softTap, in: regions)
            if typed != action { count(typed == .space ? .softSpace : .softLetter, in: regions) }
        }
        return typed
    }

    // MARK: Word autocorrect

    /// The keyboard appeared with these settings (ARCHITECTURE.md, "Word autocorrect"): off drops the corrector;
    /// on loads the chosen model (the bundle's default if the bundle lacks it) off the main thread, unless it is
    /// already loaded, and takes the chosen preset. Until it has loaded, and for good if the bundle has no
    /// valid `autocorrect` section or a file is missing or invalid, words commit as typed.
    func configureAutocorrect(enabled: Bool, model stored: String?, preset storedPreset: String?) {
        if enabled, let loaded = autocorrect, loaded.manifest.modelName(stored) == loaded.model {
            autocorrect?.preset = loaded.manifest.params(model: loaded.model, preset: storedPreset)
            return
        }
        autocorrectGeneration += 1
        autocorrect = nil
        updateTouchModes()
        guard enabled, let directory = SwipeEngine.bundledDirectory else { return }
        let generation = autocorrectGeneration
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.loadAutocorrect(from: directory, model: stored)
            }.value
            guard let self, generation == self.autocorrectGeneration, let loaded else { return }
            self.autocorrect = (loaded.manifest, loaded.name, loaded.manifest.params(model: loaded.name, preset: storedPreset),
                                loaded.corrector)
            self.updateTouchModes()
        }
    }

    /// What a load hands back to the main thread. The corrector is immutable once built.
    private struct LoadedAutocorrect: @unchecked Sendable {
        var manifest: AutocorrectManifest
        var name: String
        var corrector: WordCorrecting
    }

    /// The swipe bundle's `autocorrect` section and the chosen model's corrector; nil without a valid section
    /// or when the model cannot be built. Slow: off the main thread.
    private nonisolated static func loadAutocorrect(from directory: URL, model stored: String?) -> LoadedAutocorrect? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")),
              let manifest = try? AutocorrectManifest.decode(from: data) else { return nil }
        let name = manifest.modelName(stored)
        guard let corrector = AutocorrectLoader.load(manifest: manifest, bundleURL: directory, model: name) else { return nil }
        return LoadedAutocorrect(manifest: manifest, name: name, corrector: corrector)
    }

    /// The keyboard appeared: the store of words never to correct (ARCHITECTURE.md, "Word autocorrect", Never
    /// correct), nil while autocorrect is off or without Full Access. Its words replace those in memory.
    func configureNeverCorrect(store: NeverCorrectStore?) {
        editor.useNeverCorrectStore(store)
    }

    /// The offer a revert made, nil when none.
    var neverCorrectOffer: NeverCorrectOffer? { editor.neverCorrectOffer }

    /// The user tapped the offer: its word is never corrected again.
    func acceptNeverCorrect() {
        editor.acceptNeverCorrect()
    }

    /// The corrector and its inputs at a commit key: only with the model loaded and the App Group's settings
    /// (Full Access); the parameter overrides are read now. The editor declines in a secure field.
    private func autocorrectSetup() -> AutocorrectSetup? {
        guard let autocorrect, let settings = sharedSettings(), let keyArea else { return nil }
        let metrics = KeyboardMetrics(width: Double(keyArea.bounds.width), height: Double(keyArea.bounds.height))
        return AutocorrectSetup(corrector: autocorrect.corrector,
                                keys: KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: keyArea.showsGlobe),
                                params: settings.autocorrectParams(over: autocorrect.preset),
                                secureTextEntry: proxy?.isSecureTextEntry == true,
                                autocorrectionDisabled: proxy?.autocorrectionType == .no)
    }

    /// With the TestFlight counters on: words checked, corrected and reverted, strip choices, and never-correct
    /// offers shown and accepted. Counts only; a word has no
    /// position, so each counts once in the bottom row (`TypingCounters.wordRegions`).
    private func countAutocorrect(_ event: WordAutocorrect.Event) {
        switch event {
        case .checked: count(.wordChecked, in: TypingCounters.wordRegions)
        case .corrected: count(.wordCorrected, in: TypingCounters.wordRegions)
        case .reverted: count(.wordReverted, in: TypingCounters.wordRegions)
        case .chosen: count(.wordChosen, in: TypingCounters.wordRegions)
        case .offered: count(.neverCorrectOffered, in: TypingCounters.wordRegions)
        case .neverCorrected: count(.neverCorrectAccepted, in: TypingCounters.wordRegions)
        }
    }

    /// The candidate strip after a swipe or an autocorrect commit, nil when closed.
    var swipeStrip: SwipeStrip? { editor.swipeStrip }

    /// A tap on the strip's candidate `index`.
    func chooseSwipeCandidate(at index: Int) {
        editor.chooseSwipeCandidate(at: index, now: now)
    }

    /// Ends every held key (characters, space, delete) without typing, and a pending delete without
    /// deleting. On hiding.
    private func cancelHeldActions() {
        deleteKey.cancel()
        endDeleteRepeat()
        keyArea?.cancelAllTouches()
    }

    // MARK: Editor state

    private func editorStateChanged() {
        keyArea?.apply(layer: editor.typing.layer, shift: editor.typing.shift)
        scheduleTailExpiry()
        if editor.needsService { scheduleService() }
    }

    /// After an own edit, the editor follows the proxy for the shift every frame for a while.
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

    func keyAreaTouchedDownKey(_ keyArea: KeyAreaView, timestamp: TimeInterval) {
        editor.keyTouchedDown(now: now)
    }

    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, field: UUID?, timestamp: TimeInterval) {
        editor.press(action, field: field, at: timestamp, now: now)
    }

    /// A letter tap decided at touch-down, typed now with its touch-down point (recorded for autocorrect).
    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval) {
        editor.press(action, field: field, at: timestamp, now: now, point: TapPoint(x: x, y: y))
    }

    /// A letter tap decided at touch-down, after earlier fingers have typed: its callout shows the key, which
    /// types at release or rollover.
    func keyArea(_ keyArea: KeyAreaView, decideTap action: KeyAction, x: Double, y: Double, field: UUID?) -> KeyAction? {
        softTapKey(action, x: x, y: y, field: field, keyArea: keyArea)
    }

    /// A letter tap with no decision at touch-down, re-decided at the moment it types, then typed like a key.
    func keyArea(_ keyArea: KeyAreaView, tapped action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval) {
        editor.press(softTapKey(action, x: x, y: y, field: field, keyArea: keyArea), field: field, at: timestamp, now: now,
                     point: TapPoint(x: x, y: y))
    }

    func keyAreaBeganDelete(_ keyArea: KeyAreaView, timestamp: TimeInterval) {
        endDeleteRepeat()
        // Measured on device: the first deletion comes 0.12 s after touch-down (or at release, if
        // sooner), and the repeats follow on the schedule from touch-down. The press is bound to this
        // field; every deletion it makes carries its token.
        let press = deleteKey.began(at: timestamp, documentID: proxy?.documentIdentifierIfAvailable)
        schedule(press.token, at: press.firstAt, pressedAt: timestamp)
    }

    /// A release before the first deletion deletes once, unless the press began in another identified
    /// field; a cancellation (the system's, the menu opening over the keys, hiding) deletes nothing.
    func keyAreaEndedDelete(_ keyArea: KeyAreaView, cancelled: Bool) {
        endDeleteRepeat()
        guard let ended = deleteKey.ended(cancelled: cancelled, documentID: proxy?.documentIdentifierIfAvailable),
              ended.deleteOnce else { return }
        editor.heldDelete(.character, field: ended.field, now: now)
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
        editor.heldDelete(fired.unit, field: fired.field, now: now)
        schedule(token, at: fired.nextAt, pressedAt: pressedAt)
    }

    private func endDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    /// A swipe was released: decoded on the spot, on the main thread, and its best word typed in the
    /// field it touched down in. Samples and words are never logged or kept beyond the strip.
    func keyArea(_ keyArea: KeyAreaView, swiped samples: [SwipeSample], field: UUID?, timestamp: TimeInterval) {
        guard let swipeEngine, proxy?.isSecureTextEntry != true else { return }
        let metrics = KeyboardMetrics(width: Double(keyArea.bounds.width), height: Double(keyArea.bounds.height))
        let keys = KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: keyArea.showsGlobe)
        let candidates = swipeEngine.candidates(for: samples, keys: keys)
        if counters != nil, !candidates.contains(where: { !$0.word.isEmpty }), let touchDown = samples.first {
            count(.swipeEmpty, in: TypingCounters.regions(x: touchDown.x, y: touchDown.y, keys: keys))
        }
        editor.insertSwipe(candidates, field: field, now: now)
    }

    /// Points recorded for autocorrect belong to the old keys (ARCHITECTURE.md, "Word autocorrect").
    func keyAreaChangedLetterGeometry(_ keyArea: KeyAreaView) {
        editor.layoutChanged()
    }

    func keyArea(_ keyArea: KeyAreaView, counted event: TypingCounters.Event, in regions: [TypingCounters.Region]) {
        count(event, in: regions)
    }

    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView) {
        // The strip closes even if the gesture cannot start here.
        editor.closeSwipeStrip()
        // A delete still held stops repeating (what it already did stands).
        deleteKey.cancel()
        endDeleteRepeat()
        let multipliers = trackpadMultipliers()
        trackpad.parameters = TrackpadParameters.standard.tuned(sensitivity: multipliers.sensitivity,
                                                                acceleration: multipliers.acceleration)
        if let profile = driver.layout(keyboardWidth: keyArea.bounds.width, profile: fieldLayout()),
           editor.beginTrackpad(layout: profile.layout, linePitch: profile.linePitch, layoutWidth: profile.width) {
            driver.run()
        }
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
