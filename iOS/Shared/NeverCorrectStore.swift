import Foundation

/// The words the user asked autocorrect never to correct (ARCHITECTURE.md, "Word autocorrect", Never correct;
/// requested by the owner 2026-10-20: persisted only on the user's explicit tap of the prompt a revert offers).
/// Bounded, in the order they were added, least recent first. Only words as the corrector sees them are kept
/// (`isStorable`). In memory this is a value; `NeverCorrectStore` keeps it on the device.
struct NeverCorrectWords: Equatable, Sendable {
    /// At most this many words; past it, the least recently added go first.
    static let limit = 1_000
    /// A word longer than this many characters is never stored.
    static let maximumLength = 48

    /// Least recently added first. Every word is storable, and none appears twice.
    private(set) var words: [String]

    init() { words = [] }

    /// The storable words of `words` (least recent first): a repeated word keeps its last place, others are
    /// dropped, and past `limit` only the most recent are kept.
    init(_ words: [String]) {
        // From the most recent back, so each word keeps its last place and the scan stops at the limit.
        var seen = Set<String>()
        var kept: [String] = []
        for word in words.reversed() where kept.count < Self.limit && Self.isStorable(word) && seen.insert(word).inserted {
            kept.append(word)
        }
        self.words = kept.reversed()
    }

    var count: Int { words.count }
    var isEmpty: Bool { words.isEmpty }

    func contains(_ word: String) -> Bool { words.contains(word) }

    /// A word the corrector sees (`WordAutocorrect.correctorWord` of a word without outer apostrophes): 1 to
    /// `maximumLength` characters, each a lowercase a–z or "'", starting and ending with a letter.
    static func isStorable(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= maximumLength,
              let first = scalars.first, let last = scalars.last, isLetter(first), isLetter(last) else { return false }
        return scalars.allSatisfy { isLetter($0) || $0 == "'" }
    }

    /// Makes `word` the most recently added (moving it if present), dropping the least recent past `limit`.
    /// False, and nothing changes, for a word that is not storable.
    @discardableResult
    mutating func insert(_ word: String) -> Bool {
        guard Self.isStorable(word) else { return false }
        words.removeAll { $0 == word }
        words.append(word)
        if words.count > Self.limit { words.removeFirst(words.count - Self.limit) }
        return true
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool { ("a" ... "z").contains(scalar) }
}

/// The never-correct words on the device, in the App Group container (ARCHITECTURE.md, "Word autocorrect",
/// Never correct). One JSON file, `{"schema": 1, "words": [...]}`, least recently added first, in a directory
/// excluded from backup. The keyboard is its only writer, and writes only when the user taps "Never correct"
/// (autocorrect, and so the prompt, needs Full Access, which the App Group needs too); the app reads its count and
/// clears it, which removes the file.
///
/// - **Never fails loudly.** A missing, unreadable, oversized or corrupt file, or one of another schema, reads as
///   no words; the next write replaces it. Invalid entries in a valid file are dropped as `NeverCorrectWords` does.
/// - **Atomic.** A write goes to a staging file that is renamed over the file, so a reader sees the old or the
///   new list, never part of one. A failed write leaves the file as it was.
/// - **Read, change, write.** `add` reads the file before changing it, so a clear made in the app since the
///   keyboard last loaded it is kept.
/// - **Serialized across processes.** `add` (its read, change and write) and `clear` each hold an exclusive
///   advisory `flock` on `lockURL`, a file beside the store's directory (so a clear, which removes the directory,
///   keeps it). The app and the keyboard extension open the same file in the App Group, so a clear never runs
///   between an add's read and its write: a cleared word comes back only with a new tap. The lock is held for one
///   small read and write, never across a suspension. If the lock file cannot be opened, the operation runs
///   unlocked (best effort) rather than failing. `load` takes no lock: a reader sees a whole file either way.
/// - **Content-free.** Nothing here logs; the words never leave the file, the keyboard's memory and its prompt.
struct NeverCorrectStore: Sendable {
    static let schema = 1
    static let fileName = "never-correct-words.json"
    /// A file larger than this is not read (corrupt): a full list is about 50 KB.
    static let maximumFileSize = 256 * 1024

    let directory: URL
    /// Tests only: called inside `add`, after its read and before its write, with the lock held.
    var beforeWrite: (@Sendable () -> Void)?

    /// Nil when the App Group container is unavailable (a missing entitlement or group).
    init?(configuration: LocalFlowConfiguration) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier) else { return nil }
        self.init(directory: Self.directory(inContainer: container))
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// `Library/Application Support` (never purged by the system, unlike `Caches`), excluded from backup.
    static func directory(inContainer container: URL) -> URL {
        container.appendingPathComponent("Library/Application Support/LocalFlowAutocorrect", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }
    /// The lock `add` and `clear` hold, beside the directory (in `Library/Application Support`).
    var lockURL: URL { directory.deletingLastPathComponent().appendingPathComponent(".never-correct.lock", isDirectory: false) }

    /// The stored words; none when the file is missing or cannot be read.
    func load() -> NeverCorrectWords {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileSize,
              let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data),
              file.schema == Self.schema else { return NeverCorrectWords() }
        return NeverCorrectWords(file.words)
    }

    /// Adds `word` as the most recent and returns the words now stored. A word that is not storable writes
    /// nothing. A failed write leaves the file as it was; the result is then what it would hold.
    @discardableResult
    func add(_ word: String) -> NeverCorrectWords {
        guard NeverCorrectWords.isStorable(word) else { return load() }
        return locked {
            var words = load()
            words.insert(word)
            beforeWrite?()
            try? write(words)
            return words
        }
    }

    /// Forgets every word: removes the file and any staging file a crashed write left. True when nothing is
    /// left (also when there was nothing).
    @discardableResult
    func clear() -> Bool {
        locked {
            do {
                try FileManager.default.removeItem(at: directory)
                return true
            } catch {
                return !FileManager.default.fileExists(atPath: directory.path)
            }
        }
    }

    /// Runs `body` holding the exclusive lock on `lockURL`, waiting for another holder (in either process) to
    /// finish; unlocked if the lock file cannot be opened.
    private func locked<Result>(_ body: () -> Result) -> Result {
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    // MARK: Files

    private struct StoredFile: Codable {
        var schema: Int
        var words: [String]
    }

    static let stagingPrefix = AtomicRecordFiles.stagingPrefix

    /// Staging files are `.staging-<UUID>`, with no suffix.
    private var files: AtomicRecordFiles { AtomicRecordFiles(directory: directory, stagingSuffix: "") }

    /// Replaces the file (`AtomicRecordFiles`). Class A (`.complete`) on devices: the file is read and written only
    /// while the iPhone is unlocked; while locked a read gives no words and a write fails, leaving the file alone.
    private func write(_ words: NeverCorrectWords) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(StoredFile(schema: Self.schema, words: words.words))
        // Staging files a crashed write left behind. The keyboard is the only writer and writes on its main
        // thread, so any staging file older than a minute is abandoned. (With no directory yet there are none.)
        files.sweepStagingFiles { abs($0.timeIntervalSinceNow) < 60 }
        try files.write(data, to: fileURL, protection: AtomicRecordFiles.completeProtection)
    }
}
