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

    /// True only if this call removed the file, so exactly one claimant wins a result.
    @discardableResult
    func deleteResult(requestID: UUID) -> Bool {
        (try? FileManager.default.removeItem(at: resultURL(for: requestID))) != nil
    }

    /// Deletes results whose age is outside `[-clockSkewTolerance, resultTTL]`. A result that cannot
    /// be decoded (for example while the device is locked) is judged by its file's modification date.
    func purgeExpiredResults(now: Date) {
        for (requestID, url) in resultFiles() {
            let timestamp: Date?
            if let result = readResult(requestID: requestID).value {
                timestamp = result.createdAt
            } else {
                timestamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            }
            guard let timestamp, !DictationProtocol.isFresh(timestamp, ttl: DictationProtocol.resultTTL, now: now)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes every result for which `shouldDelete` returns true. Used for run recovery and session end.
    func purgeResults(where shouldDelete: (UUID, StoreRead<DictationResult>) -> Bool) {
        for (requestID, url) in resultFiles() where shouldDelete(requestID, readResult(requestID: requestID)) {
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

    private func write<Record: Encodable>(_ record: Record, to url: URL, protection: Data.WritingOptions) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        try createDirectoryIfNeeded()
        try data.write(to: url, options: [.atomic, protection])
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
