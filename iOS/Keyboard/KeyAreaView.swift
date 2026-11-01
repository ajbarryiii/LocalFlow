import UIKit

@MainActor
protocol KeyAreaViewDelegate: AnyObject {
    /// A key touched down (any key but the globe), before anything it does: trackpad settlement ends. The
    /// click, the haptic and a character's callout come with it; a character types only later.
    func keyAreaTouchedDownKey(_ keyArea: KeyAreaView, timestamp: TimeInterval)
    /// A key acted (ARCHITECTURE.md, "Typing model v4 and swipe typing"): characters on touch-up or
    /// rollover (the key under the touch-down point); shift and layer keys on touch-down; space and return
    /// on touch-up or rollover; delete here only from VoiceOver (a held delete uses the begin and end
    /// calls). A cancelled touch types nothing. `field`: the field the keyboard served when the finger
    /// touched down (`currentField`).
    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, field: UUID?, timestamp: TimeInterval)
    func keyAreaBeganDelete(_ keyArea: KeyAreaView, timestamp: TimeInterval)
    /// `cancelled`: the system cancelled the touch, or the key area dropped it (the menu opening, the
    /// keyboard hiding), which is not a release.
    func keyAreaEndedDelete(_ keyArea: KeyAreaView, cancelled: Bool)
    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView)
    /// Finger movement in points for one delivered touch event (Apple's gain is per event), at the
    /// touch's timestamp (for the delivery rate).
    func keyArea(_ keyArea: KeyAreaView, movedTrackpadBy dx: Double, dy: Double, timestamp: TimeInterval)
    /// `cancelled`: the system cancelled the touch, which is not a lift.
    func keyAreaEndedTrackpad(_ keyArea: KeyAreaView, timestamp: TimeInterval, cancelled: Bool)
    /// A swipe was released (only while `swipeEnabled`): its samples in key-area points with touch
    /// timestamps, from the touch-down point through the lift, and the field it touched down in. A
    /// cancelled swipe never arrives.
    func keyArea(_ keyArea: KeyAreaView, swiped samples: [SwipeSample], field: UUID?, timestamp: TimeInterval)
    /// A letter tap to re-decide (only while `softTapsEnabled`; ARCHITECTURE.md, "Soft key edges"), where it
    /// would otherwise be `typed`: the key nearest the touch-down point, that point in key-area points, and
    /// the field it touched down in. The delegate types the key it decides on.
    func keyArea(_ keyArea: KeyAreaView, tapped action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval)
    /// A letter tap to decide at touch-down (only while `softTapsEnabled`; ARCHITECTURE.md, "Soft key edges"):
    /// its nearest key, the touch-down point and its field. The key returned shows in its callout and types
    /// at release or rollover; nil leaves it to `tapped`.
    func keyArea(_ keyArea: KeyAreaView, decideTap action: KeyAction, x: Double, y: Double, field: UUID?) -> KeyAction?
    /// A letter tap decided at touch-down, typed now (only while `softTapsEnabled`): the decided key, the
    /// touch-down point and the field, for autocorrect to record (ARCHITECTURE.md, "Word autocorrect").
    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval)
    /// The letters layer's geometry changed (a resize, a rotation or the globe key shown or hidden), not merely
    /// the layer shown: touch-down points recorded before no longer match the keys.
    func keyAreaChangedLetterGeometry(_ keyArea: KeyAreaView)
}

extension KeyAreaViewDelegate {
    func keyAreaChangedLetterGeometry(_ keyArea: KeyAreaView) {}

    func keyArea(_ keyArea: KeyAreaView, decideTap action: KeyAction, x: Double, y: Double, field: UUID?) -> KeyAction? {
        nil
    }

    func keyArea(_ keyArea: KeyAreaView, swiped samples: [SwipeSample], field: UUID?, timestamp: TimeInterval) {}

    func keyArea(_ keyArea: KeyAreaView, tapped action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval) {
        self.keyArea(keyArea, typed: action, field: field, timestamp: timestamp)
    }

    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval) {
        self.keyArea(keyArea, typed: action, field: field, timestamp: timestamp)
    }
}

/// The key area: one view that tracks every touch itself, with nearest-key hit testing so gaps are
/// never dead. The decisions live in `KeyTouchModel`; this view feeds it touches, applies its
/// effects, and draws pressed keys and callouts from its state, so only the keys involved redraw.
/// Touch and hold the space bar for trackpad mode: the caps go blank and the whole area moves the
/// cursor. With `swipeEnabled`, a drag across the letters is a swipe, delivered with its samples at the
/// lift.
final class KeyAreaView: UIView {
    weak var delegate: KeyAreaViewDelegate?
    /// The field the keyboard serves now, read at each touch-down so a key stays bound to it.
    var currentField: () -> UUID? = { nil }
    /// Whether a key touch-down plays a light haptic (Full Access and the typing haptics setting).
    var keyHapticsAllowed: () -> Bool = { false }
    /// The target of the globe key's `handleInputModeList(from:with:)`.
    weak var inputModeController: UIInputViewController? {
        didSet { wireGlobe() }
    }
    var trackpadParameters: TrackpadParameters {
        get { model.parameters }
        set { model.parameters = newValue }
    }
    /// Whether a drag on a letter may become a swipe (`KeyTouchModel.swipeEnabled`): only while the swipe
    /// engine is loaded and the field is not secure text entry. A swipe already running goes on.
    var swipeEnabled: Bool {
        get { model.swipeEnabled }
        set { model.swipeEnabled = newValue }
    }
    /// Whether letter taps come with their touch-down point, `tapped` to be re-decided or `typed` as decided
    /// (`KeyTouchModel.softTapsEnabled`): only while soft key edges have loaded or autocorrect is on, and the
    /// field is not secure text entry.
    var softTapsEnabled: Bool {
        get { model.softTapsEnabled }
        set { model.softTapsEnabled = newValue }
    }
    /// Whether the view takes a touch at this point above its top (in its own coordinates): one in the bar
    /// away from the bar's controls (`KeyboardMetrics.barPointGoesToKeys`). Such a touch is an ordinary key
    /// touch, on the top row. Never while the menu is open.
    var takesTouchAbove: (CGPoint) -> Bool = { _ in false }
    /// Whether the view leaves a touch at this point inside it to the bar's Stop capsule below it, whose tap area
    /// reaches into the top row while dictation is starting or recording (`KeyboardMetrics.keyPointGoesToStart`).
    var yieldsTouch: (CGPoint) -> Bool = { _ in false }
    /// The space bar's caption, as on Apple's keyboard (the keyboard's name).
    var spaceTitle = "LocalFlow" {
        didSet { if spaceTitle != oldValue { relabel() } }
    }

    private(set) var keyLayer = KeyboardLayer.letters
    private(set) var shift = ShiftMode.off
    var showsGlobe = false {
        didSet { if showsGlobe != oldValue { rebuildKeys() } }
    }
    var returnKeyType = UIReturnKeyType.default {
        didSet { if returnKeyType != oldValue { relabel() } }
    }
    /// The kind of field: its own keys on the letters layer's bottom row (`KeyboardLayout.keys`).
    var field = KeyboardField.standard {
        didSet { if field != oldValue { rebuildKeys() } }
    }
    /// Whether Return acts (`ReturnKeyRule`): drawn dimmed, it types nothing.
    var returnKeyEnabled = true {
        didSet { if returnKeyEnabled != oldValue { relabel() } }
    }

    private var model = KeyTouchModel()
    private var keyViews: [KeyCapView] = []
    private var builtSize = CGSize.zero
    /// The size and globe the letters layer was last laid out for (any layer's rebuild lays out the same
    /// letters for them), to tell the delegate when that geometry changes.
    private var letterGeometry: (size: CGSize, showsGlobe: Bool)?
    private let globeButton = GlobeButton(type: .system)
    private let callout = KeyCalloutView()
    private var keyHaptics: UIImpactFeedbackGenerator?
    /// Stable small IDs for the model, one per live `UITouch`.
    private var touchIDs: [ObjectIdentifier: KeyTouchModel.TouchID] = [:]
    private var nextTouchID = 1
    private var holdTimers: [KeyTouchModel.TouchID: Timer] = [:]
    private var trackpadLast: CGPoint?
    private var shownPressed: Set<KeyAction> = []
    private var calloutTracker = CalloutTracker()
    /// Each held character's callout caption, fixed when its key is first shown (at touch-down, with the
    /// shift it will type with): committing it (or another finger's character) may turn the shift off
    /// while it is still shown. A slide's caption follows its key.
    private var calloutTitles: [KeyTouchModel.TouchID: (action: KeyAction, title: String)] = [:]
    private var isBlank = false
    /// The running swipe's trace, above the keys and below the callout (a swipe has none).
    private let trail = SwipeTrailView()
    /// How many of the running swipe's samples the trace shows; nil while it shows no swipe.
    private var trailSampleCount: Int?
    /// The open alternates row (`KeyTouchModel.alternatesTouch`) and the timers that open one.
    private let alternatesView = KeyAlternatesView()
    private var alternatesTimers: [KeyTouchModel.TouchID: Timer] = [:]
    /// The emoji press under way, like a held key's: the field it touched down in (or, touched down before any
    /// identity, the first one identified after), and whether it was dropped (the menu, hiding, another field).
    private var emojiPress: (emoji: String, field: UUID?, cancelled: Bool)?
    /// The emoji panel, shown on the emoji layer over the area above its bottom keys.
    private lazy var emojiPanel: EmojiPanelView = {
        let panel = EmojiPanelView()
        panel.onEmojiPressBegan = { [weak self] emoji in self?.emojiPressBegan(emoji) }
        panel.onEmojiPressCancelled = { [weak self] in self?.emojiPress = nil }
        panel.onEmoji = { [weak self] emoji in self?.typeEmoji(emoji) }
        panel.isHidden = true
        insertSubview(panel, belowSubview: trail)
        return panel
    }()

    private var placedKeys: [PlacedKey] { model.keys }

    /// In a keyboard extension iOS ignores touches on fully transparent points, so taps in the gaps between keys,
    /// the padding and the bar would never arrive. Not transparent, at 2% alpha (about 5 of 255), and not
    /// noticeable over the keyboard's backdrop (ARCHITECTURE.md, "Touchable backgrounds").
    static let touchableBackground = UIColor(white: 0.5, alpha: 0.02)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        backgroundColor = Self.touchableBackground
        globeButton.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)),
                             for: .normal)
        globeButton.tintColor = .label
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.accessibilityIdentifier = "lf.globe"
        // Its whole nearest-key region, so no point beside it is dead (ARCHITECTURE.md, "A stricter space bar").
        globeButton.claims = { [weak self] point in
            guard let self, self.keyLayer != .emoji else { return false }
            let keys = placedKeys
            return KeyboardLayout.nearestKey(toX: Double(point.x), y: Double(point.y), in: keys)
                .map { keys[$0].action == .nextKeyboard } ?? false
        }
        addSubview(trail)
        addSubview(callout)
        addSubview(alternatesView)
        // Bold Text and Increase Contrast redraw the keys.
        registerForTraitChanges([UITraitLegibilityWeight.self, UITraitAccessibilityContrast.self]) { (view: KeyAreaView, _: UITraitCollection) in
            view.relabel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: State

    func apply(layer: KeyboardLayer, shift: ShiftMode) {
        let layerChanged = layer != keyLayer
        keyLayer = layer
        let shiftChanged = shift != self.shift
        self.shift = shift
        if layerChanged {
            rebuildKeys()
        } else if shiftChanged {
            relabel()
        }
    }

    private var isCompact: Bool { bounds.height < 190 }

    private var metrics: KeyboardMetrics { KeyboardMetrics(width: Double(bounds.width), height: Double(bounds.height)) }

    /// The letters layer at the current size, whichever layer shows: the keys soft taps, autocorrect and swipes are
    /// decided against. Built afresh each time (a few dozen keys), so it always matches the current bounds.
    var letterKeys: [PlacedKey] { KeyboardLayout.keys(for: .letters, metrics: metrics, showsGlobe: showsGlobe, field: field) }

    override func layoutSubviews() {
        super.layoutSubviews()
        trail.frame = bounds
        if bounds.size != builtSize { rebuildKeys() }
    }

    private func rebuildKeys() {
        builtSize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let keys = KeyboardLayout.keys(for: keyLayer, metrics: metrics, showsGlobe: showsGlobe, field: field)
        if let previous = letterGeometry, previous.size != bounds.size || previous.showsGlobe != showsGlobe {
            delegate?.keyAreaChangedLetterGeometry(self)
        }
        letterGeometry = (bounds.size, showsGlobe)
        // Held fingers follow the new keys before anything is drawn or typed from them.
        let effects = model.keysChanged(keys, layer: keyLayer, field: field)
        while keyViews.count < keys.count {
            let view = KeyCapView()
            insertSubview(view, belowSubview: trail)
            keyViews.append(view)
        }
        while keyViews.count > keys.count { keyViews.removeLast().removeFromSuperview() }
        for (view, key) in zip(keyViews, keys) {
            view.frame = CGRect(x: key.frame.x, y: key.frame.y, width: key.frame.width, height: key.frame.height)
            view.isBlank = isBlank
            view.isPressed = false
        }
        if let globe = keys.firstIndex(where: { $0.action == .nextKeyboard }) {
            globeButton.frame = keyViews[globe].frame
            if globeButton.superview == nil { insertSubview(globeButton, belowSubview: trail) }
        } else {
            globeButton.removeFromSuperview()
        }
        shownPressed = []
        calloutTracker.keysChanged()
        layoutEmojiPanel()
        relabel()
        perform(effects, timestamp: CACurrentMediaTime())
        refreshPressed()
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    private func relabel() {
        let compact = isCompact
        // Bold Text makes the captions bold, as on Apple's keyboard.
        let bold = traitCollection.legibilityWeight == .bold
        let weight: UIFont.Weight = bold ? .semibold : .regular
        let letterFont = UIFont.systemFont(ofSize: compact ? 21 : 24, weight: weight)
        let symbolFont = UIFont.systemFont(ofSize: compact ? 19 : 22, weight: weight)
        let wordFont = UIFont.systemFont(ofSize: compact ? 15 : 16, weight: weight)
        let symbolWeight: UIImage.SymbolWeight = bold ? .semibold : .regular
        for (view, key) in zip(keyViews, placedKeys) {
            switch key.action {
            case .character(let character):
                // The URL field's ".com" is a word, not a character.
                let font = character.count > 1 ? wordFont : (keyLayer == .letters && key.action.letterIndex != nil ? letterFont : symbolFont)
                view.configure(title: displayed(character), symbol: nil, font: font, weight: symbolWeight)
            case .shift:
                let symbol = shift == .capsLock ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift")
                view.configure(title: nil, symbol: symbol, font: wordFont, weight: symbolWeight)
            case .delete:
                view.configure(title: nil, symbol: "delete.left", font: wordFont, weight: symbolWeight)
            case .space:
                view.configure(title: spaceTitle, symbol: nil, font: wordFont, weight: symbolWeight, secondary: true)
            case .returnKey:
                view.configure(title: returnKeyType.keyTitle, symbol: returnKeyType.keyTitle == nil ? "return" : nil,
                               font: wordFont, weight: symbolWeight, prominent: returnKeyType.isProminent, enabled: returnKeyEnabled)
            case .layer(.emoji):
                view.configure(title: nil, symbol: "face.smiling", font: wordFont, weight: symbolWeight)
            case .layer:
                view.configure(title: key.label, symbol: nil, font: wordFont, weight: symbolWeight)
            case .nextKeyboard:
                view.configure(title: nil, symbol: nil, font: wordFont, weight: symbolWeight)
            }
        }
        emojiPanel.bold = bold
        rebuildAccessibility()
    }

    /// A letter's caption follows the shift; other characters (the email field's "@", ".com") never change.
    private func displayed(_ character: String) -> String {
        keyLayer == .letters && shift != .off && character.count == 1 && character.first?.isLetter == true
            ? character.uppercased() : character
    }

    private func wireGlobe() {
        globeButton.removeTarget(nil, action: nil, for: .allEvents)
        guard let inputModeController else { return }
        // A tap switches keyboards and touch-and-hold lists them, as on the system globe key.
        globeButton.addTarget(inputModeController, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                              for: .allTouchEvents)
    }

    // MARK: Touches

    private func id(for touch: UITouch) -> KeyTouchModel.TouchID {
        let key = ObjectIdentifier(touch)
        if let id = touchIDs[key] { return id }
        let id = nextTouchID
        nextTouchID += 1
        touchIDs[key] = id
        return id
    }

    /// The click follows the system Keyboard Clicks setting; the haptic follows LocalFlow's.
    private func keyTouchedDown() {
        UIDevice.current.playInputClick()
        guard keyHapticsAllowed() else { return }
        let haptics = keyHaptics ?? UIImpactFeedbackGenerator(style: .light, view: self)
        keyHaptics = haptics
        haptics.impactOccurred()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.contains(point) { return !yieldsTouch(point) }
        // The emoji panel has no top row for a high tap to reach.
        return keyLayer != .emoji && point.y < bounds.minY && point.x >= bounds.minX && point.x <= bounds.maxX && takesTouchAbove(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if keyLayer == .emoji { commitHeldEmoji() }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let point = touch.location(in: self)
            let touchID = id(for: touch)
            let effects = model.began(touchID, x: Double(point.x), y: Double(point.y), t: touch.timestamp,
                                      field: currentField())
            if model.touches.last?.id == touchID { keyTouchedDown() }
            perform(effects, timestamp: touch.timestamp)
            // Decided after earlier fingers have typed, before the callout shows (ARCHITECTURE.md, "Soft key edges").
            if model.needsTapDecision(touchID), let held = model.touches.first(where: { $0.id == touchID }),
               let action = held.action,
               let decided = delegate?.keyArea(self, decideTap: action, x: held.startX, y: held.startY, field: held.field) {
                model.decideTap(touchID, as: decided)
            }
            // The key the callout shows, decided or not, chooses the alternates.
            if model.wantsAlternates(touchID) { startAlternatesTimer(touchID) }
        }
        refreshPressed()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            if id == model.trackpadTouch, let last = trackpadLast {
                // One step per delivered event, not per coalesced sample: Apple's gain was measured
                // per event (ARCHITECTURE.md, "Measured Apple keyboard behavior").
                let point = touch.location(in: self)
                delegate?.keyArea(self, movedTrackpadBy: Double(point.x - last.x), dy: Double(point.y - last.y),
                                  timestamp: touch.timestamp)
                trackpadLast = point
                continue
            }
            let point = touch.location(in: self)
            // A swipe, or a letter that may become one, keeps every coalesced sample of the move, in order
            // (ARCHITECTURE.md, "Typing model v4 and swipe typing"); other touches only where they are now.
            let samples = model.collectsSamples(id) ? swipeSamples(of: touch, with: event) : []
            let effects = model.moved(id, x: Double(point.x), y: Double(point.y), t: touch.timestamp, coalesced: samples)
            if id == model.trackpadTouch { trackpadLast = point }
            perform(effects, timestamp: touch.timestamp)
        }
        refreshPressed()
    }

    /// Every coalesced touch of this move, in order, in key-area points with its timestamp; the touch
    /// itself when the event has none.
    private func swipeSamples(of touch: UITouch, with event: UIEvent?) -> [SwipeSample] {
        let coalesced = event?.coalescedTouches(for: touch) ?? []
        return (coalesced.isEmpty ? [touch] : coalesced).map { sample in
            let point = sample.location(in: self)
            return SwipeSample(x: Double(point.x), y: Double(point.y), t: sample.timestamp)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            alternatesTimers.removeValue(forKey: id)?.invalidate()
            let point = touch.location(in: self)
            perform(model.ended(id, x: Double(point.x), y: Double(point.y), t: touch.timestamp), timestamp: touch.timestamp)
        }
        refreshPressed()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            alternatesTimers.removeValue(forKey: id)?.invalidate()
            perform(model.cancelled(id), timestamp: touch.timestamp)
        }
        refreshPressed()
    }

    /// Ends every touch, for example when the keyboard disappears mid-gesture.
    func cancelAllTouches() {
        emojiPress?.cancelled = true
        for timer in alternatesTimers.values { timer.invalidate() }
        alternatesTimers.removeAll()
        perform(model.cancelAll(), timestamp: CACurrentMediaTime())
        touchIDs.removeAll()
        refreshPressed()
    }

    /// Another field became current: fingers that touched down before any identity bind to it, those
    /// bound to a different identified field end without typing (held characters and a swipe included),
    /// the rest go on.
    func fieldChanged(to field: UUID?) {
        if let field, let press = emojiPress {
            if press.field == nil { emojiPress?.field = field } else if press.field != field { emojiPress?.cancelled = true }
        }
        perform(model.fieldChanged(to: field), timestamp: CACurrentMediaTime())
        refreshPressed()
    }

    private func perform(_ effects: [KeyTouchModel.Effect], timestamp: TimeInterval) {
        for effect in effects {
            switch effect {
            case .keyDown:
                delegate?.keyAreaTouchedDownKey(self, timestamp: timestamp)
            case .type(let action, let field):
                // A disabled Return (`returnKeyEnabled`) types nothing.
                if action == .returnKey, !returnKeyEnabled { continue }
                delegate?.keyArea(self, typed: action, field: field, timestamp: timestamp)
            case .beginDelete:
                delegate?.keyAreaBeganDelete(self, timestamp: timestamp)
            case .endDelete(let cancelled):
                delegate?.keyAreaEndedDelete(self, cancelled: cancelled)
            case .startHoldTimer(let id):
                startHoldTimer(id)
            case .cancelHoldTimer(let id):
                holdTimers.removeValue(forKey: id)?.invalidate()
            case .beginTrackpad:
                setBlank(true)
                delegate?.keyAreaBeganTrackpad(self)
            case .endTrackpad(let cancelled):
                trackpadLast = nil
                setBlank(false)
                delegate?.keyAreaEndedTrackpad(self, timestamp: timestamp, cancelled: cancelled)
            case .swipe(let samples, let field):
                delegate?.keyArea(self, swiped: samples, field: field, timestamp: timestamp)
            case .tap(let action, let x, let y, let field):
                delegate?.keyArea(self, tapped: action, x: x, y: y, field: field, timestamp: timestamp)
            case .typeDecided(let action, let x, let y, let field):
                delegate?.keyArea(self, typed: action, x: x, y: y, field: field, timestamp: timestamp)
            }
        }
    }

    /// Draws pressed keys, the callout and the alternates row from the model, touching only keys that changed.
    private func refreshPressed() {
        refreshTrail()
        refreshAlternates()
        let pressed = model.pressedActions
        if pressed != shownPressed {
            for (view, key) in zip(keyViews, placedKeys) where pressed.contains(key.action) != shownPressed.contains(key.action) {
                view.isPressed = pressed.contains(key.action)
            }
            shownPressed = pressed
        }
        if !calloutTitles.isEmpty {
            calloutTitles = calloutTitles.filter { entry in model.touches.contains { $0.id == entry.key } }
        }
        // A swipe has no callout: the model no longer counts it as a held character.
        let target = isBlank ? nil : model.calloutTouch
        let wanted = target.flatMap { touch in
            model.shownAction(touch).map { CalloutTracker.Callout(touch: touch.id, action: $0) }
        }
        guard let change = calloutTracker.update(to: wanted) else { return }
        if case .show(let callout) = change, case .character(let character) = callout.action,
           let index = placedKeys.firstIndex(where: { $0.action == callout.action }), keyViews.indices.contains(index) {
            let title = calloutTitles[callout.touch].flatMap { $0.action == callout.action ? $0.title : nil }
                ?? displayed(character)
            calloutTitles[callout.touch] = (callout.action, title)
            self.callout.show(title, over: keyViews[index].frame, within: bounds, compact: isCompact)
        } else {
            self.callout.hide()
        }
    }

    // MARK: Alternates

    private func startAlternatesTimer(_ id: KeyTouchModel.TouchID) {
        alternatesTimers.removeValue(forKey: id)?.invalidate()
        alternatesTimers[id] = Timer.mainLoop(after: KeyAlternates.holdDelay) { [weak self] _ in
            guard let self else { return }
            self.alternatesTimers[id] = nil
            if self.model.alternatesElapsed(id) {
                self.refreshPressed()
                if self.keyHapticsAllowed() { UISelectionFeedbackGenerator(view: self).selectionChanged() }
            }
        }
    }

    /// Shows the open row, its pick highlighted, with each option cased as its key's caption is.
    private func refreshAlternates() {
        guard !isBlank, let touch = model.alternatesTouch else {
            alternatesView.hide()
            return
        }
        alternatesView.show(touch.alternates.map(displayed), cells: touch.alternateFrames.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }, selected: touch.selectedAlternate, compact: isCompact)
    }

    // MARK: Emoji panel

    private func layoutEmojiPanel() {
        guard keyLayer == .emoji else {
            if !emojiPanel.isHidden { emojiPanel.isHidden = true }
            return
        }
        let grid = KeyboardLayout.emojiGridFrame(metrics: metrics)
        let jump = KeyboardLayout.emojiJumpBarFrame(metrics: metrics, showsGlobe: showsGlobe)
        emojiPanel.frame = bounds
        emojiPanel.layout(grid: CGRect(x: grid.x, y: grid.y, width: grid.width, height: grid.height),
                          jumpBar: CGRect(x: jump.x, y: jump.y, width: jump.width, height: jump.height))
        // Above the keys and the globe (whose wide claims would take the grid), below the callout and trace.
        insertSubview(emojiPanel, belowSubview: trail)
        if emojiPanel.isHidden {
            emojiPanel.reload()
            emojiPanel.isHidden = false
        }
    }

    private func emojiPressBegan(_ emoji: String) {
        emojiPress = (emoji, currentField(), false)
    }

    /// An emoji tapped in the panel types like a key, in the field its press is bound to (the editor refuses it in
    /// another identified one), unless the press was dropped; settlement ends first, with the click and haptic.
    /// A selection with no press (VoiceOver activates without a touch) types in the field served now.
    private func typeEmoji(_ emoji: String) {
        guard let press = emojiPress else { return commitEmoji(emoji, field: currentField()) }
        emojiPress = nil
        guard !press.cancelled, press.emoji == emoji else { return }
        commitEmoji(press.emoji, field: press.field)
    }

    /// Rollover: a key touched down while an emoji is held types the emoji first, as a held character would; its
    /// release then types nothing more.
    private func commitHeldEmoji() {
        guard let press = emojiPress, !press.cancelled else { return }
        emojiPress?.cancelled = true
        commitEmoji(press.emoji, field: press.field)
    }

    private func commitEmoji(_ emoji: String, field: UUID?) {
        keyTouchedDown()
        let now = CACurrentMediaTime()
        delegate?.keyAreaTouchedDownKey(self, timestamp: now)
        delegate?.keyArea(self, typed: .character(emoji), field: field ?? currentField(), timestamp: now)
        emojiPanel.emojiTyped(emoji)
    }

    // MARK: Swipe trace

    /// Follows the running swipe: the trace appears when a touch becomes one and updates on every move;
    /// when the swipe ends or is cancelled it fades out (or, with Reduce Motion, disappears at once)
    /// (ARCHITECTURE.md, "Swipe trace").
    private func refreshTrail() {
        if model.isSwipeActive {
            let samples = model.swipeSamples
            guard samples.count != trailSampleCount else { return }
            if trailSampleCount == nil {
                trail.layer.removeAllAnimations()
                trail.alpha = 1
            }
            trailSampleCount = samples.count
            trail.points = SwipeTrail.points(from: samples)
        } else if trailSampleCount != nil {
            trailSampleCount = nil
            if UIAccessibility.isReduceMotionEnabled {
                trail.points = []
                return
            }
            UIView.animate(withDuration: SwipeTrail.duration, delay: 0, options: [.beginFromCurrentState]) {
                self.trail.alpha = 0
            } completion: { [weak self] finished in
                guard finished, let self, self.trailSampleCount == nil else { return }
                self.trail.points = []
                self.trail.alpha = 1
            }
        }
    }

    // MARK: Trackpad

    private func startHoldTimer(_ id: KeyTouchModel.TouchID) {
        holdTimers.removeValue(forKey: id)?.invalidate()
        holdTimers[id] = Timer.mainLoop(after: trackpadParameters.holdDuration) { [weak self] _ in
            guard let self else { return }
            self.holdTimers[id] = nil
            let point = self.model.touches.first { $0.id == id }.map { CGPoint(x: $0.x, y: $0.y) }
            let effects = self.model.holdElapsed(id)
            if self.model.trackpadTouch == id, let point { self.trackpadLast = point }
            self.perform(effects, timestamp: CACurrentMediaTime())
            self.refreshPressed()
        }
    }

    private func setBlank(_ blank: Bool) {
        guard blank != isBlank else { return }
        isBlank = blank
        UIView.animate(withDuration: 0.15) {
            for view in self.keyViews {
                view.isBlank = blank
                view.alpha = blank ? 0.55 : 1
            }
            self.globeButton.alpha = blank ? 0 : 1
        }
        if blank {
            callout.hide()
            alternatesView.hide()
        }
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        var elements: [Any] = []
        for (index, key) in placedKeys.enumerated() where keyViews.indices.contains(index) {
            if key.action == .nextKeyboard {
                elements.append(globeButton)
                continue
            }
            let element = KeyAccessibilityElement(accessibilityContainer: self)
            element.accessibilityFrameInContainerSpace = keyViews[index].frame
            element.accessibilityTraits = .keyboardKey
            let action = key.action
            switch action {
            case .character(let character):
                element.accessibilityLabel = displayed(character)
                element.accessibilityIdentifier = "lf.key.\(character)"
                // The press-and-hold alternates, each typed as the row would type it.
                element.accessibilityCustomActions = KeyAlternates.accessibilityActions(for: character, layer: keyLayer, field: field)
                    .map { alternate in
                        UIAccessibilityCustomAction(name: displayed(alternate)) { [weak self] _ in
                            guard let self else { return false }
                            self.delegate?.keyArea(self, typed: .character(alternate), field: self.currentField(),
                                                   timestamp: CACurrentMediaTime())
                            return true
                        }
                    }
            case .shift:
                element.accessibilityLabel = "Shift"
                element.accessibilityValue = shift == .capsLock ? "Caps lock" : (shift == .once ? "On" : nil)
                element.accessibilityIdentifier = "lf.shift"
            case .delete:
                element.accessibilityLabel = "Delete"
                element.accessibilityIdentifier = "lf.delete"
            case .space:
                element.accessibilityLabel = "Space"
                element.accessibilityHint = "Touch and hold to move the cursor"
                element.accessibilityIdentifier = "lf.space"
            case .returnKey:
                element.accessibilityLabel = returnKeyType.keyTitle?.capitalized ?? "Return"
                if !returnKeyEnabled { element.accessibilityTraits.insert(.notEnabled) }
                element.accessibilityIdentifier = "lf.return"
            case .layer(let layer):
                switch layer {
                case .letters: element.accessibilityLabel = "Letters"
                case .numbers: element.accessibilityLabel = "Numbers"
                case .symbols: element.accessibilityLabel = "More symbols"
                case .emoji: element.accessibilityLabel = "Emoji"
                }
                element.accessibilityIdentifier = "lf.layer.\(layer)"
            case .nextKeyboard:
                break
            }
            element.onActivate = { [weak self] in
                guard let self, action != .returnKey || self.returnKeyEnabled else { return }
                self.delegate?.keyArea(self, typed: action, field: self.currentField(), timestamp: CACurrentMediaTime())
            }
            elements.append(element)
        }
        if keyLayer == .emoji { elements.insert(emojiPanel, at: 0) }
        accessibilityElements = elements
    }
}

/// The globe key: a system button, so the system's input-mode list works. It also takes touches outside its
/// frame whose nearest key is the globe (`claims`, given a point in its superview), which the key area would
/// otherwise ignore.
private final class GlobeButton: UIButton {
    var claims: (CGPoint) -> Bool = { _ in false }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard let superview else { return false }
        return claims(convert(point, to: superview))
    }
}

private final class KeyAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }
}

extension UIReturnKeyType {
    /// The key's caption; nil for the plain return key, which shows a symbol.
    var keyTitle: String? {
        switch self {
        case .default: return nil
        case .go: return "go"
        case .google: return "Google"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .search: return "search"
        case .send: return "send"
        case .yahoo: return "Yahoo"
        case .done: return "done"
        case .emergencyCall: return "Emergency"
        case .continue: return "continue"
        @unknown default: return nil
        }
    }

    /// Action keys are tinted like the system keyboard's.
    var isProminent: Bool { self != .default && self != .next && self != .continue }
}

/// Draws a `SwipeTrail`: a stroke through its points whose width and opacity follow each point, round at
/// the finger, in the tint color. It takes no touches.
private final class SwipeTrailView: UIView {
    var points: [SwipeTrail.Point] = [] {
        didSet {
            guard points != oldValue else { return }
            // Only where the trace was and is now: a full redraw per move would cost the whole key area.
            let dirty = Self.bounds(of: oldValue).union(Self.bounds(of: points))
            if !dirty.isNull { setNeedsDisplay(dirty) }
        }
    }

    /// The area a trail covers, with room for its widest point and antialiasing.
    private static func bounds(of points: [SwipeTrail.Point]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y, width = 0.0
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
            width = max(width, point.width)
        }
        let margin = width / 2 + 2
        return CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    /// Each segment is a quadrilateral between its ends' widths, edged along the normals shared with the
    /// next segment so neighbors meet without gaps or overlaps; a disc rounds the finger's end.
    override func draw(_ rect: CGRect) {
        guard points.count >= 2, let context = UIGraphicsGetCurrentContext() else { return }
        let normals = points.indices.map(normal(at:))
        for index in points.indices.dropLast() {
            let a = points[index], b = points[index + 1]
            let alpha = (a.alpha + b.alpha) / 2
            guard alpha > 0, a.width + b.width > 0 else { continue }
            let na = normals[index], nb = normals[index + 1]
            let ha = a.width / 2, hb = b.width / 2
            context.beginPath()
            context.move(to: CGPoint(x: a.x + na.x * ha, y: a.y + na.y * ha))
            context.addLine(to: CGPoint(x: b.x + nb.x * hb, y: b.y + nb.y * hb))
            context.addLine(to: CGPoint(x: b.x - nb.x * hb, y: b.y - nb.y * hb))
            context.addLine(to: CGPoint(x: a.x - na.x * ha, y: a.y - na.y * ha))
            context.closePath()
            context.setFillColor(tintColor.withAlphaComponent(alpha).cgColor)
            context.fillPath()
        }
        if let finger = points.last, finger.width > 0, finger.alpha > 0 {
            let radius = finger.width / 2
            context.setFillColor(tintColor.withAlphaComponent(finger.alpha).cgColor)
            context.fillEllipse(in: CGRect(x: finger.x - radius, y: finger.y - radius, width: finger.width, height: finger.width))
        }
    }

    /// The unit normal at a point: perpendicular to the average direction of its segments.
    private func normal(at index: Int) -> (x: Double, y: Double) {
        func direction(_ from: Int, _ to: Int) -> (x: Double, y: Double) {
            guard points.indices.contains(from), points.indices.contains(to) else { return (0, 0) }
            let dx = points[to].x - points[from].x, dy = points[to].y - points[from].y
            let length = (dx * dx + dy * dy).squareRoot()
            return length > 0 ? (dx / length, dy / length) : (0, 0)
        }
        let before = direction(index - 1, index), after = direction(index, index + 1)
        var dx = before.x + after.x, dy = before.y + after.y
        var length = (dx * dx + dy * dy).squareRoot()
        if length == 0 {
            let fallback = after.x != 0 || after.y != 0 ? after : before
            dx = fallback.x
            dy = fallback.y
            length = (dx * dx + dy * dy).squareRoot()
        }
        return length > 0 ? (-dy / length, dx / length) : (0, 0)
    }
}
