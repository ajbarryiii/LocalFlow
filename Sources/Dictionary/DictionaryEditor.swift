import Foundation

enum DictionaryEditError: Error, Equatable {
    /// No speech-model vocabulary: §1.1's encodability check cannot run, so
    /// nothing may change (an unchecked entry could make storage unreadable
    /// once a vocabulary is back).
    case noVocabulary
    case invalid(DictionaryEntryError)
    case full
    /// The ignore list, which has its own capacity.
    case ignoreFull
    case invalidKey

    /// Content-free: never quotes the entry.
    var message: String {
        switch self {
        case .noVocabulary: return DictionaryEditor.unavailableMessage
        case .invalid(let error): return error.message
        case .full: return "The dictionary is full (\(DictionaryValidation.capacity) entries)."
        case .ignoreFull: return "The ignored-words list is full (\(DictionaryValidation.ignoreCapacity) words)."
        case .invalidKey: return DictionaryEntryError.unencodable.message
        }
    }
}

/// Every production change to the dictionary and ignore list goes through
/// here. Each call returns the proposed state; the caller persists it before
/// publishing it. Loading never needs this (it preserves saved data as is).
struct DictionaryEditor {
    static let unavailableMessage = "The dictionary needs the speech model, which isn't available."

    let encoder: BPEEncoder?

    var canEdit: Bool { encoder != nil }

    /// Adds, or edits the entry `original` (its key may change).
    func saving(text: String, strength: Float, replacing original: DictionaryKey?,
                in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryEditError> {
        guard let encoder else { return .failure(.noVocabulary) }
        switch DictionaryValidation.validate(text: text, strength: strength, encoder: encoder) {
        case .failure(let error):
            return .failure(.invalid(error))
        case .success(let entry):
            var updated = dictionary
            if let original, original != entry.key { updated.remove(original) }
            switch updated.upsert(entry) {
            case .full?: return .failure(.full)
            case .invalidKey?: return .failure(.invalidKey)
            case nil: return .success(updated)
            }
        }
    }

    /// nil when there is nothing to remove.
    func removing(_ key: DictionaryKey, in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryEditError>? {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        return updated.remove(key) ? .success(updated) : nil
    }

    func ignoring(_ key: DictionaryKey, in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryEditError> {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        switch updated.addIgnore(key) {
        case .full?: return .failure(.ignoreFull)
        case .invalidKey?: return .failure(.invalidKey)
        case nil: return .success(updated)
        }
    }

    /// nil when the key is not ignored.
    func unignoring(_ key: DictionaryKey, in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryEditError>? {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        return updated.removeIgnore(key) ? .success(updated) : nil
    }
}
