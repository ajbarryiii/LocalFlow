import UIKit

@MainActor
protocol KeyAreaViewDelegate: AnyObject {
    /// A key acted: characters, space and return on touch-up; shift and layer keys on touch-down;
    /// delete here only from VoiceOver (a held delete uses the begin and end calls).
    func keyArea(_ keyArea: KeyAreaView, typed action: KeyAction, timestamp: TimeInterval)
    func keyAreaBeganDelete(_ keyArea: KeyAreaView, timestamp: TimeInterval)
    func keyAreaEndedDelete(_ keyArea: KeyAreaView)
    func keyAreaBeganTrackpad(_ keyArea: KeyAreaView)
    /// Finger movement in points, with the touch's own timestamp.
    func keyArea(_ keyArea: KeyAreaView, movedTrackpadBy dx: Double, dy: Double, timestamp: TimeInterval)
    func keyAreaEndedTrackpad(_ keyArea: KeyAreaView, timestamp: TimeInterval)
}

/// The key area: one view that tracks every touch itself, with nearest-key hit testing so gaps are
/// never dead. Keys highlight on touch-down and type on touch-up, so the slow path (the text proxy)
/// is touched once per keystroke and nothing re-renders but the keys involved. Touch and hold the
/// space bar for trackpad mode: the caps go blank and the whole area moves the cursor.
final class KeyAreaView: UIView {
    weak var delegate: KeyAreaViewDelegate?
    /// The target of the globe key's `handleInputModeList(from:with:)`.
    weak var inputModeController: UIInputViewController? {
        didSet { wireGlobe() }
    }
    var trackpadParameters = TrackpadParameters.standard

    private(set) var keyLayer = KeyboardLayer.letters
    private(set) var shift = ShiftMode.off
    var showsGlobe = false {
        didSet { if showsGlobe != oldValue { rebuildKeys() } }
    }
    var returnKeyType = UIReturnKeyType.default {
        didSet { if returnKeyType != oldValue { relabel() } }
    }

    private var placedKeys: [PlacedKey] = []
    private var keyViews: [KeyCapView] = []
    private var builtSize = CGSize.zero
    private let globeButton = UIButton(type: .system)
    private let callout = KeyCalloutView()
    private var tracked: [ObjectIdentifier: TrackedTouch] = [:]
    private var holdTimer: Timer?
    private var trackpad: (id: ObjectIdentifier, last: CGPoint)?

    private enum Role { case character, space, delete, returnKey, shift, layer, slide }

    private struct TrackedTouch {
        var touch: UITouch
        var keyIndex: Int
        var start: CGPoint
        var role: Role
        /// Typed already, because another finger came down first (rollover).
        var committed = false
    }

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
        placedKeys = KeyboardLayout.keys(for: keyLayer, metrics: metrics, showsGlobe: showsGlobe)
        while keyViews.count < placedKeys.count {
            let view = KeyCapView()
            insertSubview(view, belowSubview: callout)
            keyViews.append(view)
        }
        while keyViews.count > placedKeys.count { keyViews.removeLast().removeFromSuperview() }
        for (view, key) in zip(keyViews, placedKeys) {
            view.frame = CGRect(x: key.frame.x, y: key.frame.y, width: key.frame.width, height: key.frame.height)
            view.isPressed = false
            view.isBlank = trackpad != nil
        }
        if let globe = placedKeys.firstIndex(where: { $0.action == .nextKeyboard }) {
            globeButton.frame = keyViews[globe].frame
            if globeButton.superview == nil { insertSubview(globeButton, belowSubview: callout) }
        } else {
            globeButton.removeFromSuperview()
        }
        relabel()
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
                view.configure(title: key.label, symbol: nil, font: wordFont, prominent: false, secondary: true)
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

    private func nearestKey(to point: CGPoint) -> Int? {
        KeyboardLayout.nearestKey(toX: Double(point.x), y: Double(point.y), in: placedKeys)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard trackpad == nil else { continue }   // other fingers are ignored in trackpad mode
            let point = touch.location(in: self)
            guard let index = nearestKey(to: point) else { continue }
            commitPendingCharacters(timestamp: touch.timestamp)
            UIDevice.current.playInputClick()
            var entry = TrackedTouch(touch: touch, keyIndex: index, start: point, role: .character)
            switch placedKeys[index].action {
            case .character:
                showCallout(for: index)
            case .space:
                entry.role = .space
                keyViews[index].isPressed = true
                startHoldTimer(for: touch)
            case .delete:
                entry.role = .delete
                keyViews[index].isPressed = true
                delegate?.keyAreaBeganDelete(self, timestamp: touch.timestamp)
            case .returnKey:
                entry.role = .returnKey
                keyViews[index].isPressed = true
            case .shift:
                entry.role = .shift
                delegate?.keyArea(self, typed: .shift, timestamp: touch.timestamp)
                keyViews[index].isPressed = true
            case .layer(let layer):
                // Switch at once, so a slide onto a key in the new layer types it.
                entry.role = .layer
                delegate?.keyArea(self, typed: .layer(layer), timestamp: touch.timestamp)
                entry.keyIndex = nearestKey(to: point) ?? index
                keyViews[entry.keyIndex].isPressed = true
            case .nextKeyboard:
                continue
            }
            tracked[ObjectIdentifier(touch)] = entry
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let current = trackpad, current.id == id {
                // Coalesced samples carry each touch's own timestamp, so the speed is the finger's.
                var last = current.last
                for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                    let point = sample.location(in: self)
                    delegate?.keyArea(self, movedTrackpadBy: Double(point.x - last.x), dy: Double(point.y - last.y),
                                      timestamp: sample.timestamp)
                    last = point
                }
                trackpad = (id, last)
                continue
            }
            guard var entry = tracked[id] else { continue }
            let point = touch.location(in: self)
            switch entry.role {
            case .space:
                let dx = point.x - entry.start.x, dy = point.y - entry.start.y
                if abs(dx) >= CGFloat(trackpadParameters.dragActivationDistance) {
                    beginTrackpad(with: touch)
                    continue
                }
                if (dx * dx + dy * dy).squareRoot() > CGFloat(trackpadParameters.holdSlop) { cancelHoldTimer() }
            case .character, .slide, .layer:
                guard !entry.committed, let index = nearestKey(to: point), index != entry.keyIndex else { break }
                keyViews[entry.keyIndex].isPressed = false
                entry.keyIndex = index
                if case .character = placedKeys[index].action {
                    if entry.role == .layer { entry.role = .slide }
                    showCallout(for: index)
                } else {
                    callout.hide()
                }
            case .delete, .returnKey, .shift:
                break
            }
            tracked[id] = entry
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, typing: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, typing: false)
    }

    private func finish(_ touches: Set<UITouch>, typing: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let current = trackpad, current.id == id {
                endTrackpad(timestamp: touch.timestamp)
                continue
            }
            guard let entry = tracked.removeValue(forKey: id) else { continue }
            let point = touch.location(in: self)
            keyViews[safe: entry.keyIndex]?.isPressed = false
            switch entry.role {
            case .character, .slide:
                callout.hide()
                guard typing, !entry.committed, case .character(let character) = placedKeys[entry.keyIndex].action else { break }
                delegate?.keyArea(self, typed: .character(character), timestamp: touch.timestamp)
                // A number slid to from the layer key returns to letters, as on Apple's keyboard.
                if entry.role == .slide, keyLayer != .letters {
                    delegate?.keyArea(self, typed: .layer(.letters), timestamp: touch.timestamp)
                }
            case .layer:
                callout.hide()
            case .space:
                cancelHoldTimer()
                if typing, nearestKey(to: point).map({ placedKeys[$0].action == .space }) == true {
                    delegate?.keyArea(self, typed: .space, timestamp: touch.timestamp)
                }
            case .returnKey:
                if typing, nearestKey(to: point).map({ placedKeys[$0].action == .returnKey }) == true {
                    delegate?.keyArea(self, typed: .returnKey, timestamp: touch.timestamp)
                }
            case .delete:
                delegate?.keyAreaEndedDelete(self)
            case .shift:
                break
            }
        }
    }

    /// Rollover: a new finger commits the keys still held by earlier ones, so fast two-thumb
    /// typing keeps its order.
    private func commitPendingCharacters(timestamp: TimeInterval) {
        for (id, entry) in tracked where !entry.committed && (entry.role == .character || entry.role == .slide) {
            guard case .character(let character) = placedKeys[entry.keyIndex].action else { continue }
            delegate?.keyArea(self, typed: .character(character), timestamp: timestamp)
            tracked[id]?.committed = true
            callout.hide()
        }
    }

    private func showCallout(for index: Int) {
        guard case .character(let character) = placedKeys[index].action else { return }
        callout.show(displayed(character), over: keyViews[index].frame, within: bounds, compact: isCompact)
    }

    // MARK: Trackpad

    private func startHoldTimer(for touch: UITouch) {
        cancelHoldTimer()
        let id = ObjectIdentifier(touch)
        let timer = Timer(timeInterval: trackpadParameters.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let entry = self.tracked[id], entry.role == .space else { return }
                self.beginTrackpad(with: entry.touch)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func beginTrackpad(with touch: UITouch) {
        cancelHoldTimer()
        let id = ObjectIdentifier(touch)
        if let entry = tracked.removeValue(forKey: id) { keyViews[safe: entry.keyIndex]?.isPressed = false }
        callout.hide()
        trackpad = (id, touch.location(in: self))
        UIView.animate(withDuration: 0.15) {
            for view in self.keyViews {
                view.isBlank = true
                view.alpha = 0.55
            }
            self.globeButton.alpha = 0
        }
        delegate?.keyAreaBeganTrackpad(self)
    }

    private func endTrackpad(timestamp: TimeInterval) {
        trackpad = nil
        UIView.animate(withDuration: 0.15) {
            for view in self.keyViews {
                view.isBlank = false
                view.alpha = 1
            }
            self.globeButton.alpha = 1
        }
        delegate?.keyAreaEndedTrackpad(self, timestamp: timestamp)
    }

    /// Ends every touch, for example when the keyboard disappears mid-gesture.
    func cancelAllTouches() {
        cancelHoldTimer()
        callout.hide()
        if trackpad != nil { endTrackpad(timestamp: CACurrentMediaTime()) }
        for entry in tracked.values {
            keyViews[safe: entry.keyIndex]?.isPressed = false
            if entry.role == .delete { delegate?.keyAreaEndedDelete(self) }
        }
        tracked.removeAll()
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        var elements: [Any] = []
        for (index, key) in placedKeys.enumerated() {
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
                self.delegate?.keyArea(self, typed: action, timestamp: CACurrentMediaTime())
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
