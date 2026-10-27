import Foundation

/// A UserDefaults setting: its key and the value read when nothing usable is stored.
struct DefaultsKey<Value: DefaultsValue> {
    let name: String
    let defaultValue: Value
}

/// A UserDefaults setting stored as JSON data.
struct CodableDefaultsKey<Value: Codable> {
    let name: String
    let defaultValue: Value
}

extension DefaultsKey: Sendable where Value: Sendable {}
extension CodableDefaultsKey: Sendable where Value: Sendable {}

/// A value UserDefaults stores directly. `read` returns nil when nothing is stored.
protocol DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Self?
    /// What `UserDefaults.set(_:forKey:)` receives; nil removes the value.
    var storedObject: Any? { get }
}

extension DefaultsValue {
    var storedObject: Any? { self }
}

extension Bool: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }
}

extension Int: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }
}

extension Float: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Float? {
        defaults.object(forKey: key) == nil ? nil : defaults.float(forKey: key)
    }
}

extension Double: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }
}

extension String: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> String? {
        defaults.string(forKey: key)
    }
}

extension Date: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }
}

extension Optional: DefaultsValue where Wrapped: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Wrapped?? {
        Wrapped.read(from: defaults, key: key).map { .some($0) }
    }

    var storedObject: Any? {
        switch self {
        case .some(let value): return value.storedObject
        case .none: return nil
        }
    }
}

extension UserDefaults {
    subscript<Value>(key: DefaultsKey<Value>) -> Value {
        get { Value.read(from: self, key: key.name) ?? key.defaultValue }
        set { set(newValue.storedObject, forKey: key.name) }
    }

    /// Undecodable data reads as the default; a value that fails to encode is not written.
    subscript<Value>(key: CodableDefaultsKey<Value>) -> Value {
        get {
            guard let data = data(forKey: key.name),
                  let value = try? JSONDecoder().decode(Value.self, from: data) else { return key.defaultValue }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                set(data, forKey: key.name)
            }
        }
    }
}

/// Every macOS setting kept in UserDefaults. Saved settings depend on these
/// names and defaults, so they never change. Shortcuts (`ShortcutStore`) and
/// the custom dictionary (`DictionaryStorage`, `DictionaryAppStorage`) keep
/// their own keys.
enum SettingsKeys {
    static let hasCompletedSetup = DefaultsKey(name: "hasCompletedSetup", defaultValue: false)

    // Dictation
    /// Placed before dictations started with the prompt shortcut.
    static let promptTag = DefaultsKey(name: "prompt_tag", defaultValue: "[dictated]")
    static let selectedMicrophoneID = DefaultsKey(name: "selected_microphone_id", defaultValue: "default")
    static let shortcutStartDelay = DefaultsKey(name: "shortcut_start_delay", defaultValue: TimeInterval(0))
    static let doubleTapPrompt = DefaultsKey(name: "double_tap_prompt_enabled", defaultValue: false)
    static let dictationAudioInterruption = DefaultsKey(name: "dictation_audio_interruption_enabled", defaultValue: false)
    static let voiceMacros = CodableDefaultsKey(name: "voice_macros", defaultValue: [VoiceMacro]())
    static let dictationStats = CodableDefaultsKey(name: "dictation_stats", defaultValue: DictationStats())

    // Output
    static let preserveClipboard = DefaultsKey(name: "preserve_clipboard", defaultValue: true)
    static let keepDictationInClipboardHistory = DefaultsKey(name: "keep_dictation_in_clipboard_history", defaultValue: false)
    static let pressEnterVoiceCommand = DefaultsKey(name: "press_enter_voice_command_enabled", defaultValue: true)
    static let spokenDelimiters = DefaultsKey(name: "spoken_delimiters_enabled", defaultValue: true)
    static let spokenNumbers = DefaultsKey(name: "spoken_numbers_enabled", defaultValue: true)
    /// On by default; turning it off is remembered.
    static let correctionSuggestions = DefaultsKey(name: "correction_suggestions_enabled", defaultValue: true)
    /// Experimental on-device cleanup pass (TranscriptPolish); off by default.
    static let appleIntelligenceCleanup = DefaultsKey(name: "apple_intelligence_cleanup_enabled", defaultValue: false)

    // Sounds
    /// Unset: on unless the sound volume is zero.
    static let alertSoundsEnabled = DefaultsKey<Bool?>(name: "alert_sounds_enabled", defaultValue: nil)
    static let soundVolume = DefaultsKey(name: "sound_volume", defaultValue: Float(1))

    // Appearance
    static let showMenuBarIcon = DefaultsKey(name: "show_menu_bar_icon", defaultValue: true)
    static let useCompactOverlay = DefaultsKey(name: "use_compact_overlay", defaultValue: true)
    /// 0: the active window's display; -1: the primary display; otherwise a display ID.
    static let overlayDisplayID = DefaultsKey(name: "overlay_display_id", defaultValue: 0)

    // Updates
    static let updateLastCheckDate = DefaultsKey<Date?>(name: "updateLastCheckDate", defaultValue: nil)
    static let updateAutoCheckEnabled = DefaultsKey(name: "updateAutoCheckEnabled", defaultValue: true)
    static let updateSkippedVersion = DefaultsKey<String?>(name: "updateSkippedVersion", defaultValue: nil)
    static let updateLastPostTranscriptionReminderVersion = DefaultsKey<String?>(
        name: "updateLastPostTranscriptionReminderVersion", defaultValue: nil)
    static let updateLastPostTranscriptionReminderDate = DefaultsKey<Date?>(
        name: "updateLastPostTranscriptionReminderDate", defaultValue: nil)
}
