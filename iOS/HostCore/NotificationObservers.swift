import Foundation

/// Block observers registered on one `NotificationCenter`, removed together by `removeAll()` and, at
/// the latest, when this object is released, so an owner never leaves its handlers registered after it
/// is gone. Use it from one thread (its owner's).
final class NotificationObservers {
    let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    var isEmpty: Bool { tokens.isEmpty }

    func observe(_ name: Notification.Name, object: Any? = nil, queue: OperationQueue? = nil,
                 using block: @escaping @Sendable (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: object, queue: queue, using: block))
    }

    func removeAll() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    deinit { removeAll() }
}
