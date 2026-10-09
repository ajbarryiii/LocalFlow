import SwiftUI
import UIKit

/// The extension's principal class (`LocalFlowKeyboard.KeyboardViewController`). It hosts the
/// SwiftUI pad, owns the text proxy, and tells the dictation client when the field changes.
final class KeyboardViewController: UIInputViewController, KeyboardTextTarget {
    private lazy var client = KeyboardDictationClient()
    private lazy var keys = KeyboardKeys(controller: self)
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        client.target = self
        let host = UIHostingController(rootView: KeyboardRootView(client: client, keys: keys))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: preferredHeight)
        // Just below required, so the system's own height constraint wins while it animates a
        // rotation instead of logging a conflict.
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitPreferredContentSizeCategory.self]) {
            (controller: KeyboardViewController, _: UITraitCollection) in
            controller.heightConstraint?.constant = controller.preferredHeight
        }
    }

    override func viewWillLayoutSubviews() {
        keys.update(showsGlobeKey: needsInputModeSwitchKey)
        super.viewWillLayoutSubviews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        documentDidChange()
        client.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        client.stop()
        keys.endDeleteRepeat()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        documentDidChange()
    }

    private func documentDidChange() {
        let proxy = textDocumentProxy
        client.documentChanged(to: proxy.documentIdentifier)
        keys.update(returnKeyType: proxy.returnKeyType ?? .default)
        let style: UIUserInterfaceStyle
        switch proxy.keyboardAppearance {
        case .dark: style = .dark
        case .light: style = .light
        default: style = .unspecified
        }
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    /// About 260 pt in portrait, shorter in landscape, taller for accessibility text sizes.
    private var preferredHeight: CGFloat {
        let base: CGFloat = traitCollection.verticalSizeClass == .compact ? 190 : 260
        return traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? base + 40 : base
    }

    // MARK: KeyboardTextTarget

    var documentID: UUID? { textDocumentProxy.documentIdentifier }

    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }

    var feedbackView: UIView? { viewIfLoaded }

    func insert(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    func openContainingApp(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        HostAppLauncher.open(url, from: self, completion: completion)
    }
}
