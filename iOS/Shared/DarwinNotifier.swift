import CoreFoundation
import Foundation

/// Wake-up signals between the host app and the keyboard. Darwin notifications carry no payload
/// and any process can post one, so a handler must re-read the shared files and trust nothing else.
struct DarwinNotifier: Sendable {
    enum Signal: String, CaseIterable, Sendable { case intent, presence, status, result }

    /// Content-free counters, so tests can check CF unregistration separately from handler suppression.
    struct Diagnostics: Equatable, Sendable {
        /// Observations registered with the Darwin center and not yet removed.
        var registeredObservers = 0
        /// Callbacks CF delivered for an observation that was already cancelled. Stays put while
        /// every cancel also unregisters from CF.
        var orphanDeliveries = 0
    }

    static var diagnostics: Diagnostics { DarwinObservationRegistry.shared.diagnostics }

    /// The callback CF invokes. The observer pointer is only an opaque key into the registry and is
    /// never dereferenced, so a late callback can never touch freed memory.
    static let callback: CFNotificationCallback = { _, observer, _, _, _ in
        let id = Int(bitPattern: observer)
        guard DarwinObservationRegistry.shared.noteDelivery(to: id) else { return }
        DispatchQueue.main.async {
            // Looked up again on main, so nothing runs after cancel() returns on main.
            MainActor.assumeIsolated { DarwinObservationRegistry.shared.handler(for: id)?() }
        }
    }

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
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), UnsafeRawPointer(bitPattern: id),
                DarwinNotifier.callback, name as CFString, nil, .deliverImmediately)
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
    private var counters = DarwinNotifier.Diagnostics()

    var diagnostics: DarwinNotifier.Diagnostics { locked { counters } }

    func add(_ handler: @escaping @MainActor () -> Void) -> Int {
        locked {
            let id = nextID
            nextID += 1
            handlers[id] = handler
            counters.registeredObservers += 1
            return id
        }
    }

    func remove(_ id: Int) -> Bool {
        // The handler leaves the critical section before it is released: it may hold the last
        // reference to another Observation, whose deinit cancels and takes this lock again.
        let removed = locked {
            let handler = handlers.removeValue(forKey: id)
            if handler != nil { counters.registeredObservers -= 1 }
            return handler
        }
        return removed != nil
    }

    func handler(for id: Int) -> (@MainActor () -> Void)? {
        locked { handlers[id] }
    }

    /// Whether `id` is still registered; counts the delivery as an orphan if not.
    func noteDelivery(to id: Int) -> Bool {
        locked {
            if handlers[id] != nil { return true }
            counters.orphanDeliveries += 1
            return false
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
