import Foundation

/// The host app's custom dictionary (contract: "Custom dictionary"). Entries live in the app's own
/// `UserDefaults` in the macOS app's format, never in the App Group, and are never logged. Every edit is
/// validated, persisted, then published, and raises `revision`. Saved data that fails validation is kept
/// untouched: the dictionary is empty for decoding and refuses edits until an explicit `reset()`.
@MainActor
final class DictionaryLibrary {
    /// The macOS keys and payloads (`DictionaryStorage`).
    static let entriesKey = "custom_dictionary"
    static let ignoreKey = "custom_dictionary_ignore"

    private let defaults: UserDefaults
    private let editor: DictionaryEditor
    private(set) var dictionary: CustomDictionary
    private(set) var loadFailed: Bool
    /// Rises with every change, so a decoding snapshot can be told apart from a newer one.
    private(set) var revision: UInt64 = 1
    /// Called after every change.
    var onChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults, encoder: BPEEncoder?) {
        self.defaults = defaults
        editor = DictionaryEditor(encoder: encoder)
        let entries = defaults.object(forKey: Self.entriesKey)
        let ignore = defaults.object(forKey: Self.ignoreKey)
        // A value of the wrong type is unreadable, never "missing".
        if (entries != nil && !(entries is Data)) || (ignore != nil && !(ignore is Data)) {
            dictionary = CustomDictionary()
            loadFailed = true
            return
        }
        switch DictionaryStorage.load(entriesData: entries as? Data, ignoreData: ignore as? Data, encoder: encoder) {
        case .success(let loaded):
            dictionary = loaded
            loadFailed = false
        case .failure:
            dictionary = CustomDictionary()
            loadFailed = true
        }
    }

    var entries: [DictionaryEntry] { dictionary.entries }

    /// What a transcription decodes with: nothing while the saved data is unreadable.
    var snapshotEntries: [DictionaryEntry] { loadFailed ? [] : dictionary.entries }

    /// False without a speech-model vocabulary or while the saved data is unreadable.
    var canEdit: Bool { editor.canEdit && !loadFailed }

    var isFull: Bool { dictionary.entries.count >= DictionaryValidation.capacity }

    /// Adds, or edits the entry `original`. Returns a content-free message, or nil on success.
    func save(text: String, strength: Float, replacing original: DictionaryKey?) -> String? {
        apply(editor.saving(text: text, strength: strength, replacing: original, in: dictionary))
    }

    /// The ▲/▼ arrows and "Use ×n": the same text at a new strength.
    func setStrength(_ strength: Float, for key: DictionaryKey) -> String? {
        guard !loadFailed else { return Self.resetFirstMessage }
        guard let entry = dictionary.entries.first(where: { $0.key == key }) else {
            return "This word is no longer in the dictionary."
        }
        return save(text: entry.text, strength: strength, replacing: key)
    }

    func remove(_ key: DictionaryKey) {
        if let result = editor.removing(key, in: dictionary) { _ = apply(result) }
    }

    /// The only recovery from unreadable saved data: removes it and starts empty.
    func reset() {
        defaults.removeObject(forKey: Self.entriesKey)
        defaults.removeObject(forKey: Self.ignoreKey)
        loadFailed = false
        dictionary = CustomDictionary()
        changed()
    }

    /// ▲: the next preset above `strength`, nil at the top.
    static func strength(above strength: Float) -> Float? {
        DictionaryValidation.presets.first { $0 > strength }
    }

    /// ▼: the next preset below `strength`, nil at the bottom.
    static func strength(below strength: Float) -> Float? {
        DictionaryValidation.presets.last { $0 < strength }
    }

    private static let resetFirstMessage = "Reset the saved dictionary first."

    private func apply(_ result: Result<CustomDictionary, DictionaryEditError>) -> String? {
        guard !loadFailed else { return Self.resetFirstMessage }
        switch result {
        case .success(let updated):
            let encoded = DictionaryStorage.encode(updated)
            defaults.set(encoded.entries, forKey: Self.entriesKey)
            defaults.set(encoded.ignore, forKey: Self.ignoreKey)
            dictionary = updated
            changed()
            return nil
        case .failure(let error):
            return error.message
        }
    }

    private func changed() {
        revision += 1
        onChange?()
    }
}
