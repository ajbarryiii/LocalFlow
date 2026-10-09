import CoreFoundation
import Foundation

/// Wake-up signals between the host app and the keyboard. Darwin notifications carry no payload
/// and any process can post one, so a handler must re-read the shared files and trust nothing else.
struct DarwinNotifier: Sendable {
    enum Signal: String, CaseIterable, Sendable { case intent, presence, status, result }

    let appGroupIdentifier: String

    init(appGroupIdentifier: String) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    init(configuration: LocalFlowConfiguration) {
        self.init(appGroupIdentifier: configuration.appGroupIdentifier)
    }

    func name(for signal: Signal) -> String {
        "\(appGroupIdentifier).\(signal.rawValue)"
    }

    func post(_ signal: Signal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name(for: signal) as CFString), nil, nil, true)
    }

    /// Delivers `handler` on the main queue until the observation is cancelled or deallocated.
    /// Coalesced or spurious deliveries are possible, so handlers must be idempotent.
    func observe(_ signal: Signal, handler: @escaping @MainActor () -> Void) -> Observation {
        Observation(name: name(for: signal), handler: handler)
    }

    final class Observation: Sendable {
        private let id: Int
        private let name: String

        fileprivate init(name: String, handler: @escaping @MainActor () -> Void) {
            self.name = name
            id = DarwinObservationRegistry.shared.add(handler)
            // The observer pointer is only an opaque key into the registry and is never
            // dereferenced, so a late callback can never touch freed memory.
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), UnsafeRawPointer(bitPattern: id),
                { _, observer, _, _, _ in
                    let id = Int(bitPattern: observer)
                    DispatchQueue.main.async {
                        // Looked up on main, so nothing runs after cancel() returns on main.
                        MainActor.assumeIsolated { DarwinObservationRegistry.shared.handler(for: id)?() }
                    }
                },
                name as CFString, nil, .deliverImmediately)
        }

        func cancel() {
            guard DarwinObservationRegistry.shared.remove(id) else { return }
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), UnsafeRawPointer(bitPattern: id),
                CFNotificationName(name as CFString), nil)
        }

        deinit { cancel() }
    }
}

private final class DarwinObservationRegistry: @unchecked Sendable {
    static let shared = DarwinObservationRegistry()

    private let lock = NSLock()
    private var nextID = 1
    private var handlers: [Int: @MainActor () -> Void] = [:]

    func add(_ handler: @escaping @MainActor () -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return id
    }

    func remove(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: id) != nil
    }

    func handler(for id: Int) -> (@MainActor () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[id]
    }
}
