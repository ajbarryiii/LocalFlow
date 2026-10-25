import SwiftUI
import UIKit

/// The primary view. Conforming to `UIInputViewAudioFeedback` lets key presses play the system
/// keyboard click, which follows the user's Keyboard Clicks setting.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// The extension's principal class (`LocalFlowKeyboard.KeyboardViewController`): the SwiftUI top row
/// above the UIKit key area, the menu panel, the text proxy, and field changes.
final class KeyboardViewController: UIInputViewController, KeyboardTextTarget {
    private lazy var client = KeyboardDictationClient()
    private let keyArea = KeyAreaView()
    private lazy var input = KeyboardInput(controller: self, keyArea: keyArea)
    private let chrome = KeyboardChrome()
    private let swipeStrip = SwipeStripModel()
    private let neverCorrect = NeverCorrectPromptModel()
    private let barControls = BarControlFrames()
    private var bar: UIHostingController<DictationBarView>?
    private var menuPanel: UIHostingController<MenuPanelView>?
    private var barHeight: NSLayoutConstraint?
    private var totalHeight: NSLayoutConstraint?
    private var trackpadHaptics: UIImpactFeedbackGenerator?

    /// Apple's portrait keys are 216 points tall without the predictive bar; the top row takes the
    /// predictive bar's place, a little taller for the Start capsule, as on Wispr Flow's keyboard.
    private var heights: (bar: CGFloat, keys: CGFloat) {
        traitCollection.verticalSizeClass == .compact
            ? (CGFloat(KeyboardMetrics.compactBarHeight), CGFloat(KeyboardMetrics.compactHeight))
            : (CGFloat(KeyboardMetrics.barHeight), CGFloat(KeyboardMetrics.regularHeight))
    }

    /// Whether a touch above the key area (in its coordinates) goes to the keys: one in the bar away from its
    /// controls (ARCHITECTURE.md, "Reach above the keys"), never while the menu panel is open.
    private func keysTakeTouch(above point: CGPoint) -> Bool {
        guard !chrome.isMenuOpen, let barView = bar?.view else { return false }
        let inBar = keyArea.convert(point, to: barView)
        return KeyboardMetrics.barPointGoesToKeys(x: Double(inBar.x), y: Double(inBar.y), barHeight: Double(barView.bounds.height),
                                                  compact: traitCollection.verticalSizeClass == .compact,
                                                  controls: barControls.rects)
    }

    override func loadView() {
        let keyboardView = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView = keyboardView
        if viewIfLoaded !== keyboardView { view = keyboardView }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        client.target = self
        keyArea.delegate = input
        keyArea.inputModeController = self
        keyArea.keyHapticsAllowed = { [weak self] in self?.client.keyHapticsAllowed ?? false }
        input.onTrackpadChange = { [weak self] active in self?.trackpadChanged(active) }
        input.onUndoAvailabilityChanged = { [weak self] in self?.client.publishUndoState() }
        input.trackpadMultipliers = { [weak self] in self?.cursorMultipliers ?? (1, 1) }
        input.onTouchRateMeasured = { [weak self] rate, scale in self?.recordTouchRate(rate, scale: scale) }
        input.fieldLayout = { [weak self] in self?.layoutForGesture() ?? FieldLayoutParameters.standard.defaultLayout }
        // Read at each commit key: autocorrect needs the App Group (Full Access).
        input.sharedSettings = { [weak self] in self?.fieldSettings }
        input.onSwipeStripChanged = { [weak self] in
            guard let self else { return }
            swipeStrip.show(input.swipeStrip)
        }
        input.onNeverCorrectOfferChanged = { [weak self] in
            guard let self else { return }
            neverCorrect.show(input.neverCorrectOffer)
        }
        // Swipe typing comes on once its bundle has loaded off the main thread.
        input.loadSwipeEngine()

        let bar = UIHostingController(rootView: DictationBarView(
            client: client, chrome: chrome, swipe: swipeStrip, neverCorrect: neverCorrect, controls: barControls,
            onMenu: { [weak self] in self?.setMenu(visible: self?.chrome.isMenuOpen != true) },
            onAction: { [weak self] in self?.setMenu(visible: false) },
            onCandidate: { [weak self] index in self?.input.chooseSwipeCandidate(at: index) },
            onNeverCorrect: { [weak self] in self?.input.acceptNeverCorrect() }))
        bar.view.backgroundColor = KeyAreaView.touchableBackground
        bar.safeAreaRegions = []
        bar.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(bar)
        view.addSubview(bar.view)
        bar.didMove(toParent: self)
        self.bar = bar

        // Added after the bar, so key callouts on the top row draw over it.
        keyArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyArea)

        let heights = self.heights
        let barHeight = bar.view.heightAnchor.constraint(equalToConstant: heights.bar)
        // Just below required, so the system's own height wins while it animates a rotation.
        let totalHeight = view.heightAnchor.constraint(equalToConstant: heights.bar + heights.keys)
        totalHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.view.topAnchor.constraint(equalTo: view.topAnchor),
            barHeight,
            keyArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyArea.topAnchor.constraint(equalTo: bar.view.bottomAnchor),
            keyArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            totalHeight,
        ])
        self.barHeight = barHeight
        self.totalHeight = totalHeight
        keyArea.takesTouchAbove = { [weak self] point in self?.keysTakeTouch(above: point) ?? false }
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            let heights = controller.heights
            controller.barHeight?.constant = heights.bar
            controller.totalHeight?.constant = heights.bar + heights.keys
        }
    }

    override func viewWillLayoutSubviews() {
        keyArea.showsGlobe = needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Settings changed in the app while the keyboard was hidden apply from here.
        refreshSharedSettings()
        documentDidChange()
        input.reset()
        // Soft key edges and autocorrect (ARCHITECTURE.md, "Soft key edges" and "Word autocorrect") are read when
        // the keyboard appears, each on or off with the bundle's defaults; both stay off without Full Access.
        let settings = fieldSettings
        input.configureSoftKeyEdges(enabled: settings?.softKeyEdgesEnabled ?? false)
        input.configureAutocorrect(enabled: settings?.autocorrectEnabled ?? false)
        // The words never to correct, from the App Group (which `fieldSettings` already needs Full Access for).
        input.configureNeverCorrect(store: settings?.autocorrectEnabled == true
                                    ? LocalFlowConfiguration.main.flatMap(NeverCorrectStore.init(configuration:)) : nil)
        client.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Our Start button is the dictation key, so iOS drops its own microphone from
        // the bar under the keyboard on Face ID iPhones. iOS ignores this until the
        // keyboard is connected to the text field, so it is set here, not in viewDidLoad.
        hasDictationKey = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        client.stop()
        input.stop()
        fieldProfile.forget()
        setMenu(visible: false)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        documentDidChange()
        input.hostChanged(textChanged: true)
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        readField()
        input.hostChanged(textChanged: false)
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        readField()
    }

    private func documentDidChange() {
        let proxy = textDocumentProxy
        client.documentChanged(to: proxy.documentIdentifierIfAvailable)
        keyArea.returnKeyType = proxy.returnKeyType ?? .default
        // A field that asks for a dark keyboard gets one. Otherwise follow the system's appearance,
        // which also tracks a live switch; pinning `.light` here would not.
        let style: UIUserInterfaceStyle = proxy.keyboardAppearance == .dark ? .dark : .unspecified
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        readField()
    }

    // MARK: Field layout

    /// Layout choices made in this keyboard instance; they also apply when the App Group cannot be
    /// written (no Full Access).
    private var layoutChoices: [String: FieldLayout] = [:]

    /// Remembered choices, the soft-key-edge and autocorrect switches and the trackpad multipliers live in the
    /// App Group, which needs Full Access. One handle is kept, renewed each time the keyboard appears; its
    /// values are read from the suite at each use.
    private var fieldSettings: LocalFlowSettings? {
        guard hasFullAccess else { return nil }
        if appGroupSettings == nil, let configuration = LocalFlowConfiguration.main {
            appGroupSettings = LocalFlowSettings(configuration: configuration)
        }
        return appGroupSettings
    }

    private var appGroupSettings: LocalFlowSettings?

    /// The remembered choices, read once per appearance: the field is read at every cursor move and keystroke.
    private var storedLayouts = FieldLayoutOverrideCache()

    /// The keyboard appears: the next uses read the App Group again.
    private func refreshSharedSettings() {
        appGroupSettings = nil
        storedLayouts.invalidate()
    }

    /// The field's fingerprint as last read with a field identity, and the layout of the gesture
    /// running (`FieldProfileTracker`). In memory; forgotten on hiding.
    private var fieldProfile = FieldProfileTracker()

    /// Reads the field's content-free fingerprint (its input traits as raw values, and the unit the
    /// trackpad learned here) and updates the menu's readout. A reading without a field identity is
    /// the proxy's placeholder and is ignored.
    private func readField() {
        let proxy = textDocumentProxy
        let documentID = proxy.documentIdentifierIfAvailable
        fieldProfile.read(FieldFingerprint(traits: FieldTraits(proxy: proxy), unit: input.trackpad.learnedUnit(for: documentID)),
                          documentID: documentID)
        updateLayoutReadout()
    }

    private var layoutOverrides: [String: FieldLayout] {
        let stored = storedLayouts.overrides { fieldSettings?.fieldLayoutOverrides }
        return stored.merging(layoutChoices) { _, chosenHere in chosenHere }
    }

    private func updateLayoutReadout() {
        let layout = fieldProfile.displayedLayout(overrides: layoutOverrides, geometry: fieldGeometry)
        if chrome.layout != layout { chrome.layout = layout }
        let summary = fieldProfile.fingerprint?.summary ?? ""
        if chrome.fieldSummary != summary { chrome.fieldSummary = summary }
    }

    /// A trackpad gesture starts: the field is read again, and its layout holds until the finger lifts.
    private func layoutForGesture() -> FieldLayout {
        readField()
        let layout = fieldProfile.gestureBegan(overrides: layoutOverrides, geometry: fieldGeometry)
        updateLayoutReadout()
        return layout
    }

    /// The keyboard's width and orientation: the Messages geometry applies on its own only where it was
    /// measured (portrait iPhones at validated widths).
    private var fieldGeometry: FieldGeometry {
        let width = view.bounds.width > 0 ? view.bounds.width : (view.window?.windowScene?.screen.bounds.width ?? 0)
        let isPortrait = traitCollection.verticalSizeClass == .regular && traitCollection.horizontalSizeClass == .compact
        return FieldGeometry(keyboardWidth: Double(width), isPortrait: isPortrait)
    }

    /// The menu's one-tap switch: the other layout, remembered for this fingerprint with each unit and
    /// with none, so it holds after hiding forgets the learned unit.
    /// Nothing is remembered before the field has been read with its identity.
    private func toggleFieldLayout() {
        readField()
        let layout = fieldProfile.layout(overrides: layoutOverrides, geometry: fieldGeometry).other
        for (key, chosen) in fieldProfile.choiceEntries(layout) {
            layoutChoices[key] = chosen
            fieldSettings?.setFieldLayout(chosen.rawValue, forKey: key)
        }
        // The suite now holds the choice (and may have dropped others past the limit).
        storedLayouts.invalidate()
        updateLayoutReadout()
    }

    // MARK: Trackpad and menu

    private func trackpadChanged(_ active: Bool) {
        if !active {
            // The finger lifted: a fingerprint read meanwhile applies from the next gesture.
            fieldProfile.gestureEnded()
            updateLayoutReadout()
        }
        if active { setMenu(visible: false) }
        UIView.animate(withDuration: 0.15) { self.bar?.view.alpha = active ? 0.3 : 1 }
        guard active, client.hapticsAllowed else { return }
        let haptics = trackpadHaptics ?? UIImpactFeedbackGenerator(style: .light, view: view)
        trackpadHaptics = haptics
        haptics.impactOccurred()
    }

    /// The App Group settings are readable only with Full Access; without it the defaults apply.
    private var cursorMultipliers: (sensitivity: Double, acceleration: Double) {
        guard let settings = fieldSettings else { return (1, 1) }
        return (settings.cursorSensitivity, settings.cursorAcceleration)
    }

    /// Diagnostics: the measured touch rate and step scale, numbers only, at most once per gesture.
    /// Written only with Full Access, when the App Group is reachable.
    private func recordTouchRate(_ rate: Double, scale: Double) {
        guard let settings = fieldSettings else { return }
        settings.recordCursorTouchRate(rate, eventStepScale: scale)
    }

    /// The menu panel covers the key area; a tap outside its card, or on the menu button, closes it.
    private func setMenu(visible: Bool) {
        if chrome.isMenuOpen != visible { chrome.isMenuOpen = visible }
        if visible, menuPanel == nil {
            keyArea.cancelAllTouches()
            readField()
            let panel = UIHostingController(rootView: MenuPanelView(
                client: client, chrome: chrome,
                onClose: { [weak self] in self?.setMenu(visible: false) },
                onToggleLayout: { [weak self] in self?.toggleFieldLayout() }))
            panel.view.backgroundColor = KeyAreaView.touchableBackground
            panel.safeAreaRegions = []
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(panel)
            view.addSubview(panel.view)
            NSLayoutConstraint.activate([
                panel.view.leadingAnchor.constraint(equalTo: keyArea.leadingAnchor),
                panel.view.trailingAnchor.constraint(equalTo: keyArea.trailingAnchor),
                panel.view.topAnchor.constraint(equalTo: keyArea.topAnchor),
                panel.view.bottomAnchor.constraint(equalTo: keyArea.bottomAnchor),
            ])
            panel.didMove(toParent: self)
            menuPanel = panel
        } else if !visible, let panel = menuPanel {
            panel.willMove(toParent: nil)
            panel.view.removeFromSuperview()
            panel.removeFromParent()
            menuPanel = nil
        }
    }

    // MARK: KeyboardTextTarget

    var documentID: UUID? { textDocumentProxy.documentIdentifierIfAvailable }

    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }

    var feedbackView: UIView? { viewIfLoaded }

    func insert(_ text: String) {
        input.insertDictation(text)
    }

    var isEditingBusy: Bool { input.isBusy }

    var canUndoLastDictation: Bool { input.canUndoLastDictation }

    func undoLastDictation() {
        input.undoLastDictation()
    }

    func openContainingApp(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        HostAppLauncher.open(url, from: self, completion: completion)
    }
}

extension UITextDocumentProxy {
    /// `documentIdentifier` is imported as a non-optional `UUID`, but the proxy returns nil while a
    /// field connects or goes away, and bridging that nil traps (seen in the simulator). Reading it
    /// through Objective-C yields an optional instead; nil never matches a binding or an undo.
    var documentIdentifierIfAvailable: UUID? {
        guard let object = self as? NSObject, object.responds(to: NSSelectorFromString("documentIdentifier")) else {
            return nil
        }
        return object.value(forKey: "documentIdentifier") as? UUID
    }
}
