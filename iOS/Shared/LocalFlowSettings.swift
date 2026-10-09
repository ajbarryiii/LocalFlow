import Foundation

/// Settings the keyboard also reads, stored in the App Group's UserDefaults suite. No transcript
/// history is stored here.
struct LocalFlowSettings {
    static let sessionMinuteOptions = [5, 15, 60]
    static let defaultSessionMinutes = 5

    private enum Key {
        static let sessionMinutes = "sessionMinutes"
        static let spokenDelimitersEnabled = "spokenDelimitersEnabled"
        static let pressEnterEnabled = "pressEnterEnabled"
        static let hapticsEnabled = "hapticsEnabled"
    }

    let defaults: UserDefaults

    init?(configuration: LocalFlowConfiguration) {
        guard let defaults = UserDefaults(suiteName: configuration.appGroupIdentifier) else { return nil }
        self.init(defaults: defaults)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// One of `sessionMinuteOptions`; other values are ignored when written and read as the default.
    var sessionMinutes: Int {
        get {
            let stored = defaults.object(forKey: Key.sessionMinutes) as? Int
            return stored.flatMap { Self.sessionMinuteOptions.contains($0) ? $0 : nil } ?? Self.defaultSessionMinutes
        }
        nonmutating set {
            guard Self.sessionMinuteOptions.contains(newValue) else { return }
            defaults.set(newValue, forKey: Key.sessionMinutes)
        }
    }

    var sessionDuration: TimeInterval { TimeInterval(sessionMinutes) * 60 }

    var spokenDelimitersEnabled: Bool {
        get { bool(Key.spokenDelimitersEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.spokenDelimitersEnabled) }
    }

    var pressEnterEnabled: Bool {
        get { bool(Key.pressEnterEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.pressEnterEnabled) }
    }

    var hapticsEnabled: Bool {
        get { bool(Key.hapticsEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.hapticsEnabled) }
    }

    // Every boolean setting defaults to on.
    private func bool(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
