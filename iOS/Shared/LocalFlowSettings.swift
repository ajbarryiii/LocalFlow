import Foundation

/// Settings the keyboard also reads, stored in the App Group's UserDefaults suite. No transcript
/// history is stored here.
struct LocalFlowSettings {
    static let sessionMinuteOptions = [5, 15, 60]
    static let defaultSessionMinutes = 5

    /// Accepted values of the trackpad-mode multipliers; others read as the default, 1.
    static let cursorMultiplierRange: ClosedRange<Double> = 0.25...4

    private enum Key {
        static let sessionMinutes = "sessionMinutes"
        static let spokenDelimitersEnabled = "spokenDelimitersEnabled"
        static let pressEnterEnabled = "pressEnterEnabled"
        static let hapticsEnabled = "hapticsEnabled"
        static let cursorSensitivity = "cursorSensitivity"
        static let cursorAcceleration = "cursorAcceleration"
        static let cursorTouchRate = "cursorTouchRate"
        static let cursorEventStepScale = "cursorEventStepScale"
        static let fieldLayoutOverrides = "fieldLayoutOverrides"
    }

    /// Remembered field layout choices, at most this many.
    static let fieldLayoutOverrideLimit = 64
    /// The layouts the keyboard knows (`FieldLayout` raw values).
    static let fieldLayoutValues: Set<String> = ["messages", "fullWidth"]

    /// Accepted values of the keyboard's measured touch rate (events per second) and the step scale
    /// it derives (`TouchRateEstimator.scaleRange`).
    static let cursorTouchRateRange: ClosedRange<Double> = 1...1_000
    static let cursorEventStepScaleRange: ClosedRange<Double> = 0.5...2.5

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

    /// Scales the keyboard's trackpad-mode gain at every speed. Default 1.
    var cursorSensitivity: Double {
        get { multiplier(Key.cursorSensitivity) }
        nonmutating set { setMultiplier(newValue, forKey: Key.cursorSensitivity) }
    }

    /// Scales how far the trackpad-mode gain rises above 1 on fast drags. Default 1.
    var cursorAcceleration: Double {
        get { multiplier(Key.cursorAcceleration) }
        nonmutating set { setMultiplier(newValue, forKey: Key.cursorAcceleration) }
    }

    /// Diagnostics the keyboard writes, at most once per trackpad gesture: the rate at which it
    /// receives touch events and the step scale it uses. Numbers only; nil until measured.
    var cursorTouchRate: Double? { number(Key.cursorTouchRate, in: Self.cursorTouchRateRange) }

    var cursorEventStepScale: Double? { number(Key.cursorEventStepScale, in: Self.cursorEventStepScaleRange) }

    /// Records the keyboard's measurement; values outside the accepted ranges are ignored.
    func recordCursorTouchRate(_ rate: Double, eventStepScale scale: Double) {
        guard rate.isFinite, scale.isFinite, Self.cursorTouchRateRange.contains(rate),
              Self.cursorEventStepScaleRange.contains(scale) else { return }
        defaults.set(rate, forKey: Key.cursorTouchRate)
        defaults.set(scale, forKey: Key.cursorEventStepScale)
    }

    /// The keyboard's field layout choices: a field fingerprint key (16 hex digits, a hash of
    /// content-free input traits) to a layout name. Malformed entries are ignored.
    var fieldLayoutOverrides: [String: String] {
        guard let stored = defaults.dictionary(forKey: Key.fieldLayoutOverrides) else { return [:] }
        var valid: [String: String] = [:]
        for (key, value) in stored {
            guard let layout = value as? String, Self.isFingerprintKey(key), Self.fieldLayoutValues.contains(layout)
            else { continue }
            valid[key] = layout
        }
        return valid
    }

    /// Remembers (or, with nil, forgets) the layout for a fingerprint key. Bounded: past the limit,
    /// other entries are dropped.
    func setFieldLayout(_ layout: String?, forKey key: String) {
        guard Self.isFingerprintKey(key), layout.map(Self.fieldLayoutValues.contains) ?? true else { return }
        var stored = fieldLayoutOverrides
        stored[key] = layout
        while stored.count > Self.fieldLayoutOverrideLimit, let other = stored.keys.first(where: { $0 != key }) {
            stored[other] = nil
        }
        defaults.set(stored, forKey: Key.fieldLayoutOverrides)
    }

    private static func isFingerprintKey(_ key: String) -> Bool {
        key.count == 16 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // Every boolean setting defaults to on.
    private func bool(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    private func multiplier(_ key: String) -> Double {
        // A Bool also bridges to NSNumber; only a real number counts.
        guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return 1 }
        let value = number.doubleValue
        return value.isFinite && Self.cursorMultiplierRange.contains(value) ? value : 1
    }

    private func number(_ key: String, in range: ClosedRange<Double>) -> Double? {
        guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite && range.contains(value) ? value : nil
    }

    private func setMultiplier(_ value: Double, forKey key: String) {
        guard value.isFinite, Self.cursorMultiplierRange.contains(value) else { return }
        defaults.set(value, forKey: key)
    }
}
