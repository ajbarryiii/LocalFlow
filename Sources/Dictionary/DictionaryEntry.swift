// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
import Foundation

/// A word or phrase to boost (DESIGN §1.1). `text` is stored validated.
struct DictionaryEntry: Codable, Equatable {
    var text: String
    var strength: Float

    var key: DictionaryKey { DictionaryKey(text) }

    // Scalar equality: canonically equivalent spellings are different entries.
    static func == (lhs: DictionaryEntry, rhs: DictionaryEntry) -> Bool {
        DictionaryText.same(lhs.text, rhs.text) && lhs.strength.bitPattern == rhs.strength.bitPattern
    }
}

enum DictionaryEntryError: String, Error, Equatable {
    // Raw values are the shared vector names (DESIGN §1.7).
    case empty
    case tooManyWords = "too-many-words"
    case tooLong = "too-long"
    case noLetter = "no-letter"
    case unencodable
    case invalidStrength = "bad-strength"

    var message: String {
        switch self {
        case .empty: return "Enter a word or phrase."
        case .tooManyWords: return "Use at most \(DictionaryValidation.maxWords) words."
        case .tooLong: return "Use at most \(DictionaryValidation.maxScalars) characters."
        case .noLetter: return "Include at least one letter."
        case .unencodable: return "This text contains characters the speech model can't produce."
        case .invalidStrength: return "Choose a strength between ×0.25 and ×8."
        }
    }
}

enum DictionaryMutationError: Error, Equatable {
    case full
    /// The identity or ignore key fails pin P6; nothing is changed.
    case invalidKey
}

enum DictionaryValidation {
    static let maxWords = 8
    static let maxScalars = 100
    static let minStrength: Float = 0.25
    static let maxStrength: Float = 8
    static let defaultStrength: Float = 1
    static let capacity = 1000
    static let ignoreCapacity = 1000
    static let presets: [Float] = [0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8]

    /// Trim whitespace and collapse internal runs to one ASCII space.
    static func normalize(_ text: String) -> String {
        DictionaryText.words(text.unicodeScalars).map { DictionaryText.string($0) }.joined(separator: " ")
    }

    static func isValidStrength(_ strength: Float) -> Bool {
        strength.isFinite && strength >= minStrength && strength <= maxStrength
    }

    /// Without a vocabulary (no bundled model) the encodability check is skipped;
    /// graph building skips any unencodable surface anyway.
    static func validate(text: String, strength: Float, encoder: BPEEncoder?) -> Result<DictionaryEntry, DictionaryEntryError> {
        let words = DictionaryText.words(text.unicodeScalars)
        guard !words.isEmpty else { return .failure(.empty) }
        guard words.count <= maxWords else { return .failure(.tooManyWords) }
        let normalized = words.map { DictionaryText.string($0) }.joined(separator: " ")
        guard normalized.unicodeScalars.count <= maxScalars else { return .failure(.tooLong) }
        guard normalized.unicodeScalars.contains(where: DictionaryText.isLetter) else { return .failure(.noLetter) }
        // A control scalar is never a vocabulary piece, so it is unencodable even
        // when no vocabulary is loaded (and could never form a valid key, pin P6).
        if normalized.unicodeScalars.contains(where: DictionaryText.isControl) { return .failure(.unencodable) }
        if let encoder, !encoder.encodesWithoutUnknown(normalized) { return .failure(.unencodable) }
        guard isValidStrength(strength) else { return .failure(.invalidStrength) }
        return .success(DictionaryEntry(text: normalized, strength: strength))
    }

    /// Short display label for a strength, e.g. "×1.41".
    static func label(_ strength: Float) -> String {
        var text = String(format: "%.2f", Double(strength))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "×" + text
    }
}

/// Entries and the ignore list with the §1.1 rules. Mutations assume validated input.
struct CustomDictionary: Equatable {
    private(set) var entries: [DictionaryEntry] = []
    private(set) var ignore: [DictionaryKey] = []

    func contains(_ key: DictionaryKey) -> Bool { entries.contains { $0.key == key } }

    func isIgnored(_ key: DictionaryKey) -> Bool { ignore.contains(key) }

    /// Adds, or replaces the entry with the same identity key.
    mutating func upsert(_ entry: DictionaryEntry) -> DictionaryMutationError? {
        let key = entry.key
        guard key.isValid else { return .invalidKey }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index] = entry
            return nil
        }
        guard entries.count < DictionaryValidation.capacity else { return .full }
        entries.append(entry)
        return nil
    }

    @discardableResult
    mutating func remove(_ key: DictionaryKey) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func addIgnore(_ key: DictionaryKey) -> DictionaryMutationError? {
        guard key.isValid else { return .invalidKey }
        guard !ignore.contains(key) else { return nil }
        guard ignore.count < DictionaryValidation.ignoreCapacity else { return .full }
        ignore.append(key)
        return nil
    }

    @discardableResult
    mutating func removeIgnore(_ key: DictionaryKey) -> Bool {
        guard let index = ignore.firstIndex(of: key) else { return false }
        ignore.remove(at: index)
        return true
    }
}

enum DictionaryStorageError: Error, Equatable {
    /// Content-free on purpose: errors never quote stored text.
    case unreadable
}

/// UserDefaults payloads (DESIGN §3.2): `{"version":1,"entries":[…]}` and
/// `{"version":1,"ignore":[…]}`. Loading validates everything; any failure
/// rejects the whole dictionary so the caller can preserve the raw data.
enum DictionaryStorage {
    static let version = 1
    /// Above the largest payload `encode` can produce (DESIGN §3.2), so whatever was saved loads again.
    static let maxBytes = 2 << 20

    private struct EntriesFile: Codable {
        let version: Int
        let entries: [DictionaryEntry]
    }

    private struct IgnoreFile: Codable {
        let version: Int
        let ignore: [String]
    }

    static func load(entriesData: Data?, ignoreData: Data?, encoder: BPEEncoder?) -> Result<CustomDictionary, DictionaryStorageError> {
        var dictionary = CustomDictionary()
        if let entriesData {
            guard entriesData.count <= maxBytes,
                  let file = try? JSONDecoder().decode(EntriesFile.self, from: entriesData),
                  file.version == version, file.entries.count <= DictionaryValidation.capacity else {
                return .failure(.unreadable)
            }
            var keys = Set<DictionaryKey>()
            for stored in file.entries {
                guard case .success(let entry) = DictionaryValidation.validate(text: stored.text, strength: stored.strength,
                                                                              encoder: encoder),
                      DictionaryText.same(entry.text, stored.text),
                      keys.insert(entry.key).inserted,
                      dictionary.upsert(entry) == nil else {
                    return .failure(.unreadable)
                }
            }
        }
        if let ignoreData {
            guard ignoreData.count <= maxBytes,
                  let file = try? JSONDecoder().decode(IgnoreFile.self, from: ignoreData),
                  file.version == version, file.ignore.count <= DictionaryValidation.ignoreCapacity else {
                return .failure(.unreadable)
            }
            for stored in file.ignore {
                // Stored exactly as saved: valid per pin P6 (already folded), no duplicates.
                let key = DictionaryKey(folded: Array(stored.unicodeScalars))
                guard key.isValid, !dictionary.isIgnored(key), dictionary.addIgnore(key) == nil else {
                    return .failure(.unreadable)
                }
            }
        }
        return .success(dictionary)
    }

    static func encode(_ dictionary: CustomDictionary) -> (entries: Data, ignore: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries = (try? encoder.encode(EntriesFile(version: version, entries: dictionary.entries))) ?? Data()
        let ignore = (try? encoder.encode(IgnoreFile(version: version, ignore: dictionary.ignore.map(\.text)))) ?? Data()
        return (entries, ignore)
    }
}
