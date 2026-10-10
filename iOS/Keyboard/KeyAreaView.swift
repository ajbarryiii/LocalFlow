import UIKit

@MainActor
protocol KeyAreaViewDelegate: AnyObject {
    /// A key acted: characters, space and return on touch-up or rollover; shift and layer keys on
    /// touch-down; delete here only from VoiceOver (a held delete uses the begin and end calls).
    /// `field`: the field the keyboard served when the finger touched down (`currentField`).
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
}

/// The key area: one view that tracks every touch itself, with nearest-key hit testing so gaps are
/// never dead. The decisions live in `KeyTouchModel`; this view feeds it touches, applies its
/// effects, and draws pressed keys and callouts from its state, so only the keys involved redraw.
/// Touch and hold the space bar for trackpad mode: the caps go blank and the whole area moves the
/// cursor.
final class KeyAreaView: UIView {
    weak var delegate: KeyAreaViewDelegate?
    /// The field the keyboard serves now, read at each touch-down so a key stays bound to it.
    var currentField: () -> UUID? = { nil }
    /// The target of the globe key's `handleInputModeList(from:with:)`.
    weak var inputModeController: UIInputViewController? {
        didSet { wireGlobe() }
    }
    var trackpadParameters: TrackpadParameters {
        get { model.parameters }
        set { model.parameters = newValue }
    }
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

    private var model = KeyTouchModel()
    private var keyViews: [KeyCapView] = []
    private var builtSize = CGSize.zero
    private let globeButton = UIButton(type: .system)
    private let callout = KeyCalloutView()
    /// Stable small IDs for the model, one per live `UITouch`.
    private var touchIDs: [ObjectIdentifier: KeyTouchModel.TouchID] = [:]
    private var nextTouchID = 1
    private var holdTimers: [KeyTouchModel.TouchID: Timer] = [:]
    private var trackpadLast: CGPoint?
    private var shownPressed: Set<KeyAction> = []
    private var shownCallout: KeyAction?
    private var isBlank = false

    private var placedKeys: [PlacedKey] { model.keys }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        backgroundColor = .clear
        globeButton.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)),
                             for: .normal)
        globeButton.tintColor = .label
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.accessibilityIdentifier = "lf.globe"
        addSubview(callout)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != builtSize { rebuildKeys() }
    }

    private func rebuildKeys() {
        builtSize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let metrics = KeyboardMetrics(width: Double(bounds.width), height: Double(bounds.height))
        let keys = KeyboardLayout.keys(for: keyLayer, metrics: metrics, showsGlobe: showsGlobe)
        // Held fingers follow the new keys before anything is drawn or typed from them.
        let effects = model.keysChanged(keys, layer: keyLayer)
        while keyViews.count < keys.count {
            let view = KeyCapView()
            insertSubview(view, belowSubview: callout)
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
            if globeButton.superview == nil { insertSubview(globeButton, belowSubview: callout) }
        } else {
            globeButton.removeFromSuperview()
        }
        shownPressed = []
        shownCallout = nil
        relabel()
        perform(effects, timestamp: CACurrentMediaTime())
        refreshPressed()
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    private func relabel() {
        let compact = isCompact
        let letterFont = UIFont.systemFont(ofSize: compact ? 21 : 24, weight: .regular)
        let symbolFont = UIFont.systemFont(ofSize: compact ? 19 : 22, weight: .regular)
        let wordFont = UIFont.systemFont(ofSize: compact ? 15 : 16, weight: .regular)
        for (view, key) in zip(keyViews, placedKeys) {
            switch key.action {
            case .character(let character):
                view.configure(title: displayed(character), symbol: nil, font: keyLayer == .letters ? letterFont : symbolFont,
                               prominent: false, secondary: false)
            case .shift:
                let symbol = shift == .capsLock ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift")
                view.configure(title: nil, symbol: symbol, font: wordFont, prominent: false, secondary: false)
            case .delete:
                view.configure(title: nil, symbol: "delete.left", font: wordFont, prominent: false, secondary: false)
            case .space:
                view.configure(title: spaceTitle, symbol: nil, font: wordFont, prominent: false, secondary: true)
            case .returnKey:
                view.configure(title: returnKeyType.keyTitle, symbol: returnKeyType.keyTitle == nil ? "return" : nil,
                               font: wordFont, prominent: returnKeyType.isProminent, secondary: false)
            case .layer:
                view.configure(title: key.label, symbol: nil, font: wordFont, prominent: false, secondary: false)
            case .nextKeyboard:
                view.configure(title: nil, symbol: nil, font: wordFont, prominent: false, secondary: false)
            }
        }
        rebuildAccessibility()
    }

    private func displayed(_ character: String) -> String {
        keyLayer == .letters && shift != .off ? character.uppercased() : character
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let point = touch.location(in: self)
            let touchID = id(for: touch)
            let effects = model.began(touchID, x: Double(point.x), y: Double(point.y), field: currentField())
            if model.touches.last?.id == touchID { UIDevice.current.playInputClick() }
            perform(effects, timestamp: touch.timestamp)
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
            let effects = model.moved(id, x: Double(point.x), y: Double(point.y))
            if id == model.trackpadTouch { trackpadLast = point }
            perform(effects, timestamp: touch.timestamp)
        }
        refreshPressed()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let point = touch.location(in: self)
            perform(model.ended(id, x: Double(point.x), y: Double(point.y)), timestamp: touch.timestamp)
        }
        refreshPressed()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            perform(model.cancelled(id), timestamp: touch.timestamp)
        }
        refreshPressed()
    }

    /// Ends every touch, for example when the keyboard disappears mid-gesture.
    func cancelAllTouches() {
        perform(model.cancelAll(), timestamp: CACurrentMediaTime())
        touchIDs.removeAll()
        refreshPressed()
    }

    private func perform(_ effects: [KeyTouchModel.Effect], timestamp: TimeInterval) {
        for effect in effects {
            switch effect {
            case .type(let action, let field):
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
            }
        }
    }

    /// Draws pressed keys and the callout from the model, touching only keys that changed.
    private func refreshPressed() {
        let pressed = model.pressedActions
        if pressed != shownPressed {
            for (view, key) in zip(keyViews, placedKeys) where pressed.contains(key.action) != shownPressed.contains(key.action) {
                view.isPressed = pressed.contains(key.action)
            }
            shownPressed = pressed
        }
        let callout = isBlank ? nil : model.calloutAction
        guard callout != shownCallout else { return }
        shownCallout = callout
        if let callout, case .character(let character) = callout,
           let index = placedKeys.firstIndex(where: { $0.action == callout }), keyViews.indices.contains(index) {
            self.callout.show(displayed(character), over: keyViews[index].frame, within: bounds, compact: isCompact)
        } else {
            self.callout.hide()
        }
    }

    // MARK: Trackpad

    private func startHoldTimer(_ id: KeyTouchModel.TouchID) {
        holdTimers.removeValue(forKey: id)?.invalidate()
        let timer = Timer(timeInterval: trackpadParameters.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimers[id] = nil
                let point = self.model.touches.first { $0.id == id }.map { CGPoint(x: $0.x, y: $0.y) }
                let effects = self.model.holdElapsed(id)
                if self.model.trackpadTouch == id, let point { self.trackpadLast = point }
                self.perform(effects, timestamp: CACurrentMediaTime())
                self.refreshPressed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimers[id] = timer
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
        if blank { callout.hide() }
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
                element.accessibilityIdentifier = "lf.return"
            case .layer(let layer):
                switch layer {
                case .letters: element.accessibilityLabel = "Letters"
                case .numbers: element.accessibilityLabel = "Numbers"
                case .symbols: element.accessibilityLabel = "More symbols"
                }
                element.accessibilityIdentifier = "lf.layer.\(layer)"
            case .nextKeyboard:
                break
            }
            element.onActivate = { [weak self] in
                guard let self else { return }
                self.delegate?.keyArea(self, typed: action, field: self.currentField(), timestamp: CACurrentMediaTime())
            }
            elements.append(element)
        }
        accessibilityElements = elements
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
