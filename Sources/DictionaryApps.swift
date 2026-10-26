// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
import Foundation

/// An app a word can be limited to (DESIGN §3.6), macOS only. The name is the
/// last one seen, so a deleted app's words stay listed under it.
struct DictionaryApp: Hashable {
    static let maxIDLength = 155
    static let maxNameScalars = 100

    let id: String
    let name: String

    /// nil unless `id` is a bundle identifier. The name is trimmed, loses its
    /// control characters and is cut to 100 scalars; empty, it is the id.
    init?(id: String, name: String?) {
        guard Self.isBundleIdentifier(id) else { return nil }
        self.id = id
        self.name = Self.normalizedName(name, id: id)
    }

    static func isBundleIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxIDLength
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }

    static func normalizedName(_ name: String?, id: String) -> String {
        let visible = String(String.UnicodeScalarView((name ?? "").unicodeScalars.filter { !DictionaryText.isControl($0) }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxNameScalars)))
    }
}

enum DictionaryAppError: Error, Equatable {
    /// 32 apps are known already.
    case appsFull
    /// A word was limited to an app that is not known.
    case unknownApp
}

/// The known apps and which words are limited to them. A word without apps
/// applies everywhere; the entries themselves stay in `CustomDictionary`.
struct DictionaryAppScopes: Equatable {
    static let appCapacity = 32

    /// In the order they became known.
    private(set) var apps: [DictionaryApp] = []
    /// By identity key; never an empty set.
    private(set) var limits: [DictionaryKey: Set<String>] = [:]

    func app(id: String) -> DictionaryApp? { apps.first { $0.id == id } }

    /// Empty: the word applies everywhere.
    func apps(for key: DictionaryKey) -> Set<String> { limits[key] ?? [] }

    func wordCount(in appID: String) -> Int { limits.values.filter { $0.contains(appID) }.count }

    /// Adds an app, or updates the name of a known one in place.
    mutating func register(_ app: DictionaryApp) -> DictionaryAppError? {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index] = app
            return nil
        }
        guard apps.count < Self.appCapacity else { return .appsFull }
        apps.append(app)
        return nil
    }

    /// No apps: everywhere.
    mutating func setApps(_ ids: Set<String>, for key: DictionaryKey) -> DictionaryAppError? {
        guard ids.allSatisfy({ app(id: $0) != nil }) else { return .unknownApp }
        limits[key] = ids.isEmpty ? nil : ids
        return nil
    }

    /// Forgets the app. Returns the words whose only app it was, which the
    /// caller removes: they must never become global. nil if it was not known.
    mutating func removeApp(id: String) -> [DictionaryKey]? {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return nil }
        apps.remove(at: index)
        var orphaned: [DictionaryKey] = []
        for (key, ids) in limits where ids.contains(id) {
            let remaining = ids.subtracting([id])
            limits[key] = remaining.isEmpty ? nil : remaining
            if remaining.isEmpty { orphaned.append(key) }
        }
        return orphaned
    }
}

/// The macOS dictionary: entries and the global ignore list, plus app limits.
/// Edits keep every limited word an entry.
struct ScopedDictionary: Equatable {
    var dictionary = CustomDictionary()
    var scopes = DictionaryAppScopes()

    func applies(_ key: DictionaryKey, in appID: String?) -> Bool {
        guard dictionary.contains(key) else { return false }
        let ids = scopes.apps(for: key)
        return ids.isEmpty || appID.map(ids.contains) == true
    }

    /// The entries a dictation into `appID` decodes with, in entry order. The
    /// app is kept only if it has limited words, so other apps share the
    /// global graph (DESIGN §3.6).
    func decodingWords(for appID: String?) -> (entries: [DictionaryEntry], appID: String?) {
        let entries = dictionary.entries.filter { applies($0.key, in: appID) }
        guard let appID, scopes.wordCount(in: appID) > 0 else { return (entries, nil) }
        return (entries, appID)
    }
}

enum ScopedDictionaryEditError: Error, Equatable {
    case edit(DictionaryEditError)
    case app(DictionaryAppError)

    /// Content-free: never quotes a word or an app.
    var message: String {
        switch self {
        case .edit(let error): return error.message
        case .app(.appsFull): return "LocalFlow can keep words for at most \(DictionaryAppScopes.appCapacity) apps."
        case .app(.unknownApp): return "Add the app before limiting words to it."
        }
    }
}

/// Every production change to the macOS dictionary goes through here
/// (DESIGN §3.3, §3.6). Each call returns the proposed state.
struct ScopedDictionaryEditor {
    let editor: DictionaryEditor

    init(encoder: BPEEncoder?) { editor = DictionaryEditor(encoder: encoder) }

    var canEdit: Bool { editor.canEdit }

    /// Adds, or edits `original`, limited to `apps` (none: everywhere).
    func saving(text: String, strength: Float, apps: Set<String>, replacing original: DictionaryKey?,
                in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError> {
        switch editor.saving(text: text, strength: strength, replacing: original, in: current.dictionary) {
        case .failure(let error):
            return .failure(.edit(error))
        case .success(let dictionary):
            var updated = ScopedDictionary(dictionary: dictionary, scopes: current.scopes)
            if let original { _ = updated.scopes.setApps([], for: original) }
            let key = DictionaryKey(DictionaryValidation.normalize(text))
            if let error = updated.scopes.setApps(apps, for: key) { return .failure(.app(error)) }
            return .success(updated)
        }
    }

    /// nil when there is nothing to remove.
    func removing(_ key: DictionaryKey, in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError>? {
        switch editor.removing(key, in: current.dictionary) {
        case nil: return nil
        case .failure(let error)?: return .failure(.edit(error))
        case .success(let dictionary)?:
            var updated = ScopedDictionary(dictionary: dictionary, scopes: current.scopes)
            _ = updated.scopes.setApps([], for: key)
            return .success(updated)
        }
    }

    /// A suggestion's Add to <App> (`app`) or Add everywhere (nil). An existing
    /// word keeps its text, takes the higher strength, and gains the app
    /// unless it already applies everywhere.
    func adding(_ word: String, strength: Float, to app: DictionaryApp?,
                in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError> {
        guard canEdit else { return .failure(.edit(.noVocabulary)) }
        var base = current
        if let app, let error = base.scopes.register(app) { return .failure(.app(error)) }
        let key = DictionaryKey(DictionaryValidation.normalize(word))
        let existing = base.dictionary.entries.first { $0.key == key }
        let saved = saving(text: existing?.text ?? word, strength: max(existing?.strength ?? strength, strength),
                           apps: [], replacing: existing?.key, in: base)
        guard case .success(var updated) = saved else { return saved }
        let previous = base.scopes.apps(for: key)
        let apps: Set<String>
        if let app {
            apps = existing != nil && previous.isEmpty ? [] : previous.union([app.id])
        } else {
            apps = []
        }
        if let error = updated.scopes.setApps(apps, for: key) { return .failure(.app(error)) }
        return .success(updated)
    }

    /// Adds an app, or updates a known app's name.
    func registering(_ app: DictionaryApp, in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError> {
        guard canEdit else { return .failure(.edit(.noVocabulary)) }
        var updated = current
        if let error = updated.scopes.register(app) { return .failure(.app(error)) }
        return .success(updated)
    }

    /// Forgets the app and removes the words only it had. nil if it is not known.
    func removingApp(_ id: String, in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError>? {
        guard canEdit else { return .failure(.edit(.noVocabulary)) }
        var updated = current
        guard let orphaned = updated.scopes.removeApp(id: id) else { return nil }
        for key in orphaned { updated.dictionary.remove(key) }
        return .success(updated)
    }

    func ignoring(_ key: DictionaryKey, in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError> {
        switch editor.ignoring(key, in: current.dictionary) {
        case .failure(let error): return .failure(.edit(error))
        case .success(let dictionary): return .success(ScopedDictionary(dictionary: dictionary, scopes: current.scopes))
        }
    }

    /// nil when the key is not ignored.
    func unignoring(_ key: DictionaryKey, in current: ScopedDictionary) -> Result<ScopedDictionary, ScopedDictionaryEditError>? {
        switch editor.unignoring(key, in: current.dictionary) {
        case nil: return nil
        case .failure(let error)?: return .failure(.edit(error))
        case .success(let dictionary)?: return .success(ScopedDictionary(dictionary: dictionary, scopes: current.scopes))
        }
    }
}

/// The `custom_dictionary_apps` payload (DESIGN §3.6):
/// `{"apps":[{"id":…,"name":…}],"version":1,"words":[{"apps":[…],"key":…}]}`.
/// Loading validates everything; any failure rejects the whole dictionary.
enum DictionaryAppStorage {
    /// macOS only; iOS has no per-app words.
    static let storageKey = "custom_dictionary_apps"
    static let version = 1
    /// Above the largest payload `encode` can produce: 32 apps and 1000
    /// words of 300-scalar keys, each in every app.
    static let maxBytes = 8 << 20

    private struct AppRecord: Codable {
        let id: String
        let name: String
    }

    private struct WordRecord: Codable {
        let apps: [String]
        let key: String
    }

    private struct File: Codable {
        let apps: [AppRecord]
        let version: Int
        let words: [WordRecord]
    }

    /// Words whose key is not among `entries` are dropped: a build from before
    /// app limits can remove or rename entries without touching this payload.
    static func load(_ data: Data?, entries: [DictionaryEntry]) -> Result<DictionaryAppScopes, DictionaryStorageError> {
        var scopes = DictionaryAppScopes()
        guard let data else { return .success(scopes) }
        guard data.count <= maxBytes, let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == version, file.apps.count <= DictionaryAppScopes.appCapacity,
              file.words.count <= DictionaryValidation.capacity else {
            return .failure(.unreadable)
        }
        for record in file.apps {
            guard let app = DictionaryApp(id: record.id, name: record.name), DictionaryText.same(app.name, record.name),
                  scopes.app(id: app.id) == nil, scopes.register(app) == nil else {
                return .failure(.unreadable)
            }
        }
        let entryKeys = Set(entries.map(\.key))
        var seen = Set<DictionaryKey>()
        for record in file.words {
            // Stored exactly as saved: valid per pin P6, so already folded.
            let key = DictionaryKey(folded: Array(record.key.unicodeScalars))
            let ids = Set(record.apps)
            guard key.isValid, seen.insert(key).inserted, !ids.isEmpty, ids.count == record.apps.count,
                  ids.allSatisfy({ scopes.app(id: $0) != nil }) else {
                return .failure(.unreadable)
            }
            if entryKeys.contains(key) { _ = scopes.setApps(ids, for: key) }
        }
        return .success(scopes)
    }

    static func encode(_ scopes: DictionaryAppScopes) -> Data {
        func precedes(_ a: String, _ b: String) -> Bool {
            a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
        }
        let words = scopes.limits
            .map { WordRecord(apps: $0.value.sorted(by: precedes), key: $0.key.text) }
            .sorted { precedes($0.key, $1.key) }
        let file = File(apps: scopes.apps.map { AppRecord(id: $0.id, name: $0.name) }, version: version, words: words)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(file)) ?? Data()
    }
}
