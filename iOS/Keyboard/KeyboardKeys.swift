import UIKit

/// The basic keys: globe, space, delete with auto-repeat, and return. They work without Full Access
/// and never read the document.
@MainActor
final class KeyboardKeys: ObservableObject {
    @Published private(set) var showsGlobeKey = false
    @Published private(set) var returnKeyType = UIReturnKeyType.default

    /// The globe key's target for `handleInputModeList(from:with:)`.
    private(set) weak var controller: UIInputViewController?
    private var repeatTimer: Timer?
    private var repeatIndex = 0

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    // Assigned only on change: layout calls these, and publishing re-renders the pad.
    func update(showsGlobeKey: Bool) {
        if self.showsGlobeKey != showsGlobeKey { self.showsGlobeKey = showsGlobeKey }
    }

    func update(returnKeyType: UIReturnKeyType) {
        if self.returnKeyType != returnKeyType { self.returnKeyType = returnKeyType }
    }

    func insertSpace() { proxy?.insertText(" ") }

    func pressReturn() { proxy?.insertText("\n") }

    func deleteBackward() { proxy?.deleteBackward() }

    /// Deletes once, then repeats on `KeyRepeatSchedule` until `endDeleteRepeat()`.
    func beginDeleteRepeat() {
        endDeleteRepeat()
        deleteBackward()
        repeatIndex = 0
        scheduleRepeat()
    }

    func endDeleteRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func scheduleRepeat() {
        let timer = Timer(timeInterval: KeyRepeatSchedule.delay(beforeRepeat: repeatIndex), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.repeatTimer != nil else { return }
                self.repeatIndex += 1
                self.deleteBackward()
                self.scheduleRepeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
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
