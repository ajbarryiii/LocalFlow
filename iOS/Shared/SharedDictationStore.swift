import Foundation

/// File-backed state shared by the host app and the keyboard. Each file has one writer process and
/// every write is atomic, so a reader sees either the previous or the new record. Reads never throw
/// and never log content.
struct SharedDictationStore: Sendable {
    let directory: URL

    /// Returns nil when the App Group container is unavailable (a missing entitlement or group).
    init?(configuration: LocalFlowConfiguration) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier) else { return nil }
        self.init(directory: Self.directory(inContainer: container))
    }

    init(directory: URL) {
        self.directory = directory
    }

    static func directory(inContainer container: URL) -> URL {
        container.appendingPathComponent("Library/Caches/LocalFlowDictation", isDirectory: true)
    }

    // MARK: Reads

    func readIntent() -> StoreRead<KeyboardIntent> { read(at: intentURL) }

    func readPresence() -> StoreRead<KeyboardPresence> { read(at: presenceURL) }

    func readStatus() -> StoreRead<HostStatus> { read(at: statusURL) }

    func readResult(requestID: UUID) -> StoreRead<DictationResult> {
        let outcome: StoreRead<DictationResult> = read(at: resultURL(for: requestID))
        // A record under another request's name is corrupt, not a result for this request.
        if let result = outcome.value, result.requestID != requestID { return .unreadable }
        return outcome
    }

    /// The request IDs of every result file present, whether or not it is readable.
    func resultRequestIDs() -> [UUID] {
        resultFiles().map(\.requestID)
    }

    // MARK: Writes

    func writeIntent(_ intent: KeyboardIntent) throws {
        try write(intent, to: intentURL, protection: Self.completeProtection)
    }

    func writePresence(_ presence: KeyboardPresence) throws {
        try write(presence, to: presenceURL, protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    func writeStatus(_ status: HostStatus) throws {
        // JSONEncoder throws on NaN, and a failed heartbeat would make the host look dead.
        var status = status
        status.level = status.level.isFinite ? min(max(status.level, 0), 1) : 0
        try write(status, to: statusURL, protection: .completeFileProtectionUntilFirstUserAuthentication)
    }

    func writeResult(_ result: DictationResult) throws {
        try write(result, to: resultURL(for: result.requestID), protection: Self.completeProtection)
    }

    // MARK: Deletes

    enum ResultRemoval: Equatable, Sendable {
        /// This call removed the file, so this caller won the claim.
        case removed
        /// Another claimant or a purge removed it first.
        case alreadyAbsent
        /// The file may still be there (for example a transient I/O error); a later attempt may succeed.
        case failed
    }

    /// Removes `result-R.json` so that exactly one caller, across threads and processes, sees `.removed`.
    func removeResult(requestID: UUID) -> ResultRemoval {
        removeResultFile(at: resultURL(for: requestID))
    }

    /// True only if this call removed the file, so exactly one claimant wins a result.
    @discardableResult
    func deleteResult(requestID: UUID) -> Bool {
        removeResult(requestID: requestID) == .removed
    }

    /// Deletes results whose age is outside `[-clockSkewTolerance, resultTTL]`. A result that cannot
    /// be decoded (for example while the device is locked) is judged by its file's modification date.
    /// Also sweeps staging files abandoned for as long, so either process cleans up after a crash.
    func purgeExpiredResults(now: Date) {
        defer { purgeStagingFiles(olderThan: DictationProtocol.resultTTL, now: now) }
        for (requestID, url) in resultFiles() {
            let timestamp: Date?
            if let result = readResult(requestID: requestID).value {
                timestamp = result.createdAt
            } else {
                timestamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            }
            guard let timestamp, !DictationProtocol.isFresh(timestamp, ttl: DictationProtocol.resultTTL, now: now)
            else { continue }
            _ = removeResultFile(at: url)
        }
    }

    /// Deletes every result for which `shouldDelete` returns true. Used for run recovery and session end.
    func purgeResults(where shouldDelete: (UUID, StoreRead<DictationResult>) -> Bool) {
        for (requestID, url) in resultFiles() where shouldDelete(requestID, readResult(requestID: requestID)) {
            _ = removeResultFile(at: url)
        }
    }

    /// Deletes staging files whose modification date is outside `[-clockSkewTolerance, age]`. A writer
    /// that dies between writing and renaming leaves one behind, and a result's may hold a transcript.
    /// The host passes 0 during run recovery, before it writes anything, to remove them at any age.
    /// Other callers keep a long age so they never pull an in-flight write from under the other process.
    func purgeStagingFiles(olderThan age: TimeInterval, now: Date) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix) && name.hasSuffix(Self.stagingSuffix) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, DictationProtocol.isFresh(modified, ttl: age, now: now) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Files

    var intentURL: URL { directory.appendingPathComponent("intent.json", isDirectory: false) }
    var presenceURL: URL { directory.appendingPathComponent("presence.json", isDirectory: false) }
    var statusURL: URL { directory.appendingPathComponent("status.json", isDirectory: false) }

    func resultURL(for requestID: UUID) -> URL {
        directory.appendingPathComponent("result-\(requestID.uuidString).json", isDirectory: false)
    }

    private func resultFiles() -> [(requestID: UUID, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasPrefix("result-"), name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropFirst("result-".count).dropLast(".json".count)))
            else { return nil }
            return (id, directory.appendingPathComponent(name, isDirectory: false))
        }
    }

    /// Class A (`.complete`) on devices. macOS, where the host tests run, refuses class A to
    /// unentitled processes, and the simulator does not enforce data protection, so both use class C.
    private static var completeProtection: Data.WritingOptions {
        #if os(iOS) && !targetEnvironment(simulator)
        return .completeFileProtection
        #else
        return .completeFileProtectionUntilFirstUserAuthentication
        #endif
    }

    private struct SchemaProbe: Decodable {
        var schema: Int
    }

    private func read<Record: Decodable>(at url: URL) -> StoreRead<Record> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Check the schema first: a future version may change the other fields entirely.
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else { return .unreadable }
        guard probe.schema == DictationProtocol.schema else { return .incompatible }
        guard let record = try? decoder.decode(Record.self, from: data) else { return .unreadable }
        return .value(record)
    }

    static let stagingPrefix = ".staging-"
    static let stagingSuffix = ".tmp"

    private func makeStagingURL() -> URL {
        directory.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)\(Self.stagingSuffix)", isDirectory: false)
    }

    /// Every result removal, claim or purge, goes through here. On APFS, concurrent unlinks of one
    /// name can all succeed, but only one rename of it can, so the file is first moved to a private
    /// staging name and deleted from there. A crash in between leaves a staging file for the sweeps.
    private func removeResultFile(at url: URL) -> ResultRemoval {
        let claimed = makeStagingURL()
        guard rename(url.path, claimed.path) == 0 else { return errno == ENOENT ? .alreadyAbsent : .failed }
        _ = unlink(claimed.path)
        return .removed
    }

    /// Writes a uniquely named staging file next to the destination, then renames it over the
    /// destination: a reader sees the old or the new record, never part of one. Foundation's
    /// `.atomic` is avoided because its temporary file, abandoned by a crash, escapes every sweep.
    private func write<Record: Encodable>(_ record: Record, to url: URL, protection: Data.WritingOptions) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        try createDirectoryIfNeeded()
        let staging = makeStagingURL()
        do {
            try data.write(to: staging, options: [.withoutOverwriting, protection])
            guard rename(staging.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func createDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)   // best effort, per the contract
    }
}
