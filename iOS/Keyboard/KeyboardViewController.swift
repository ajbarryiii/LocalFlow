import SwiftUI
import UIKit

/// The primary view. Conforming to `UIInputViewAudioFeedback` lets key presses play the system
/// keyboard click, which follows the user's Keyboard Clicks setting.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// The extension's principal class (`LocalFlowKeyboard.KeyboardViewController`): the SwiftUI
/// dictation bar on top of the UIKit key area, the text proxy, and field changes.
final class KeyboardViewController: UIInputViewController, KeyboardTextTarget {
    private lazy var client = KeyboardDictationClient()
    private let keyArea = KeyAreaView()
    private lazy var input = KeyboardInput(controller: self, keyArea: keyArea)
    private var bar: UIHostingController<DictationBarView>?
    private var infoPanel: UIHostingController<InfoPanelView>?
    private var barHeight: NSLayoutConstraint?
    private var totalHeight: NSLayoutConstraint?
    private var trackpadHaptics: UIImpactFeedbackGenerator?

    /// Apple's portrait keys are 216 points tall without the predictive bar; the dictation bar
    /// takes the predictive bar's place, a little taller for the mic.
    private var heights: (bar: CGFloat, keys: CGFloat) {
        traitCollection.verticalSizeClass == .compact
            ? (44, CGFloat(KeyboardMetrics.compactHeight)) : (54, CGFloat(KeyboardMetrics.regularHeight))
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
        input.onTrackpadChange = { [weak self] active in self?.trackpadChanged(active) }
        input.onEdit = { [weak self] in self?.client.noteEdit() }
        input.trackpadMultipliers = { [weak self] in self?.cursorMultipliers ?? (1, 1) }

        let bar = UIHostingController(rootView: DictationBarView(client: client, onInfo: { [weak self] in
            self?.setInfoPanel(visible: true)
        }))
        bar.view.backgroundColor = .clear
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
        documentDidChange()
        input.reset()
        client.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        client.stop()
        input.stop()
        setInfoPanel(visible: false)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        documentDidChange()
        input.proxyChanged()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        input.proxyChanged()
    }

    private func documentDidChange() {
        let proxy = textDocumentProxy
        client.documentChanged(to: proxy.documentIdentifierIfAvailable)
        keyArea.returnKeyType = proxy.returnKeyType ?? .default
        // A field that asks for a dark keyboard gets one. Otherwise follow the system's appearance,
        // which also tracks a live switch; pinning `.light` here would not.
        let style: UIUserInterfaceStyle = proxy.keyboardAppearance == .dark ? .dark : .unspecified
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    // MARK: Trackpad and info

    private func trackpadChanged(_ active: Bool) {
        UIView.animate(withDuration: 0.15) { self.bar?.view.alpha = active ? 0.3 : 1 }
        guard active, client.hapticsAllowed else { return }
        let haptics = trackpadHaptics ?? UIImpactFeedbackGenerator(style: .light, view: view)
        trackpadHaptics = haptics
        haptics.impactOccurred()
    }

    /// The App Group settings are readable only with Full Access; without it the defaults apply.
    private var cursorMultipliers: (sensitivity: Double, acceleration: Double) {
        guard hasFullAccess, let configuration = LocalFlowConfiguration.main,
              let settings = LocalFlowSettings(configuration: configuration) else { return (1, 1) }
        return (settings.cursorSensitivity, settings.cursorAcceleration)
    }

    private func setInfoPanel(visible: Bool) {
        if visible, infoPanel == nil {
            let panel = UIHostingController(rootView: InfoPanelView(client: client, onClose: { [weak self] in
                self?.setInfoPanel(visible: false)
            }))
            panel.view.backgroundColor = .clear
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
            infoPanel = panel
        } else if !visible, let panel = infoPanel {
            panel.willMove(toParent: nil)
            panel.view.removeFromSuperview()
            panel.removeFromParent()
            infoPanel = nil
        }
    }

    // MARK: KeyboardTextTarget

    var documentID: UUID? { textDocumentProxy.documentIdentifierIfAvailable }

    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }

    var feedbackView: UIView? { viewIfLoaded }

    func insert(_ text: String) {
        input.insertDictation(text)
    }

    func deleteBackward(count: Int) {
        input.deleteForUndo(count)
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
