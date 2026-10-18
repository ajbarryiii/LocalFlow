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
}

extension KeyAreaViewDelegate {
    func keyArea(_ keyArea: KeyAreaView, swiped samples: [SwipeSample], field: UUID?, timestamp: TimeInterval) {}

    func keyArea(_ keyArea: KeyAreaView, tapped action: KeyAction, x: Double, y: Double, field: UUID?, timestamp: TimeInterval) {
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
    /// Whether letter taps come as `tapped` to be re-decided (`KeyTouchModel.softTapsEnabled`): only while
    /// soft key edges are on, their model has loaded, and the field is not secure text entry.
    var softTapsEnabled: Bool {
        get { model.softTapsEnabled }
        set { model.softTapsEnabled = newValue }
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
    private var keyHaptics: UIImpactFeedbackGenerator?
    /// Stable small IDs for the model, one per live `UITouch`.
    private var touchIDs: [ObjectIdentifier: KeyTouchModel.TouchID] = [:]
    private var nextTouchID = 1
    private var holdTimers: [KeyTouchModel.TouchID: Timer] = [:]
    private var trackpadLast: CGPoint?
    private var shownPressed: Set<KeyAction> = []
    private var shownCallout: (touch: KeyTouchModel.TouchID, action: KeyAction)?
    /// Each held character's callout caption, fixed when its key is first shown (at touch-down, with the
    /// shift it will type with): committing it (or another finger's character) may turn the shift off
    /// while it is still shown. A slide's caption follows its key.
    private var calloutTitles: [KeyTouchModel.TouchID: (action: KeyAction, title: String)] = [:]
    private var isBlank = false
    /// The running swipe's trace, above the keys and below the callout (a swipe has none).
    private let trail = SwipeTrailView()
    /// How many of the running swipe's samples the trace shows; nil while it shows no swipe.
    private var trailSampleCount: Int?

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
        addSubview(trail)
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
        trail.frame = bounds
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

    /// The click follows the system Keyboard Clicks setting; the haptic follows LocalFlow's.
    private func keyTouchedDown() {
        UIDevice.current.playInputClick()
        guard keyHapticsAllowed() else { return }
        let haptics = keyHaptics ?? UIImpactFeedbackGenerator(style: .light, view: self)
        keyHaptics = haptics
        haptics.impactOccurred()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let point = touch.location(in: self)
            let touchID = id(for: touch)
            let effects = model.began(touchID, x: Double(point.x), y: Double(point.y), t: touch.timestamp,
                                      field: currentField())
            if model.touches.last?.id == touchID { keyTouchedDown() }
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
            let point = touch.location(in: self)
            perform(model.ended(id, x: Double(point.x), y: Double(point.y), t: touch.timestamp), timestamp: touch.timestamp)
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

    /// Another field became current: fingers that touched down before any identity bind to it, those
    /// bound to a different identified field end without typing (held characters and a swipe included),
    /// the rest go on.
    func fieldChanged(to field: UUID?) {
        perform(model.fieldChanged(to: field), timestamp: CACurrentMediaTime())
        refreshPressed()
    }

    private func perform(_ effects: [KeyTouchModel.Effect], timestamp: TimeInterval) {
        for effect in effects {
            switch effect {
            case .keyDown:
                delegate?.keyAreaTouchedDownKey(self, timestamp: timestamp)
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
            case .swipe(let samples, let field):
                delegate?.keyArea(self, swiped: samples, field: field, timestamp: timestamp)
            case .tap(let action, let x, let y, let field):
                delegate?.keyArea(self, tapped: action, x: x, y: y, field: field, timestamp: timestamp)
            }
        }
    }

    /// Draws pressed keys and the callout from the model, touching only keys that changed.
    private func refreshPressed() {
        refreshTrail()
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
        let callout = target.flatMap { touch in touch.action.map { (touch: touch.id, action: $0) } }
        guard callout?.touch != shownCallout?.touch || callout?.action != shownCallout?.action else { return }
        shownCallout = callout
        if let callout, case .character(let character) = callout.action,
           let index = placedKeys.firstIndex(where: { $0.action == callout.action }), keyViews.indices.contains(index) {
            let title = calloutTitles[callout.touch].flatMap { $0.action == callout.action ? $0.title : nil }
                ?? displayed(character)
            calloutTitles[callout.touch] = (callout.action, title)
            self.callout.show(title, over: keyViews[index].frame, within: bounds, compact: isCompact)
        } else {
            self.callout.hide()
        }
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
