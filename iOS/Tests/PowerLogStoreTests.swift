import Foundation

/// The power log's serialized owner (ARCHITECTURE.md, "Power log" → "When" and "Diagnostics"): one
/// consistent disk-plus-buffer snapshot, Clear generations, bounded buffering after write failures and
/// immutable export copies. All samples are invented.
enum PowerLogStoreTests {
    static var tests: [TestCase] {
        [
            ("snapshotsNeverDoubleCount", testSnapshotsNeverDoubleCount),
            ("clearWinsOverReadsInFlight", testClearWinsOverReadsInFlight),
            ("writeFailuresKeepTheNewestRowsUpToACap", testWriteFailuresKeepTheNewestRowsUpToACap),
            ("exportsAreFlushedImmutableCopies", testExportsAreFlushedImmutableCopies),
            ("exportsIncludeTheRotatedFile", testExportsIncludeTheRotatedFile),
            ("leftoverExportsAreRemoved", testLeftoverExportsAreRemoved),
            ("partialAppendIsRolledBack", testPartialAppendIsRolledBack),
            ("newFileIsRemovedWhenBackupExclusionFails", testNewFileIsRemovedWhenBackupExclusionFails),
            ("failedAppendsNeverDoubleCount", testFailedAppendsNeverDoubleCount),
            ("unrecoverableAppendDropsRatherThanDuplicates", testUnrecoverableAppendDropsRatherThanDuplicates),
            ("clearFailureKeepsTheLogAndSaysSo", testClearFailureKeepsTheLogAndSaysSo),
            ("exportIncludesRowsThatCouldNotBeFlushed", testExportIncludesRowsThatCouldNotBeFlushed),
            ("partialClearAdvancesAndSaysSo", testPartialClearAdvancesAndSaysSo),
            ("exportIsCompleteWhenTheFlushLosesRows", testExportIsCompleteWhenTheFlushLosesRows),
            ("exportKeepsBothFilesDuringSchemaMigration", testExportKeepsBothFilesDuringSchemaMigration),
        ]
    }

    private static func makeStore(_ directory: URL, limitBytes: Int = PowerLogRotation.limitBytes,
                                  maxBuffered: Int = 2_000, faults: Faults? = nil) -> (PowerLogStore, PowerLogFiles) {
        let files = PowerLogFiles(directory: directory.appendingPathComponent("PowerLog", isDirectory: true),
                                  fileName: "log.csv", rotatedFileName: "log.1.csv", limitBytes: limitBytes,
                                  operations: faults?.operations ?? .standard)
        return (PowerLogStore(files: files, maxBufferedSamples: maxBuffered), files)
    }

    private static func exportOutcome(_ store: PowerLogStore, into directory: URL) -> PowerLogStore.ExportOutcome {
        let box = ResultBox<PowerLogStore.ExportOutcome>()
        store.exportSnapshot(into: directory) { box.set($0) }
        return box.wait()
    }

    private static func clearOutcome(_ store: PowerLogStore) -> PowerLogClearOutcome {
        let box = ResultBox<PowerLogClearOutcome>()
        store.clear { box.set($0) }
        return box.wait()
    }

    private static func fileData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    private static func snapshot(_ store: PowerLogStore) -> PowerLogStore.Snapshot {
        let box = ResultBox<PowerLogStore.Snapshot>()
        store.snapshot { box.set($0) }
        return box.wait()
    }

    private static func samples(_ range: Range<Int>) -> [PowerSample] {
        range.map { PowerSynthetic.sample(Double($0) * 60) }
    }

    /// Rows move from the buffer to disk inside the owner, so a snapshot sees each row exactly once.
    private static func testSnapshotsNeverDoubleCount() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        for sample in samples(0 ..< 3) { store.append(sample) }
        var current = snapshot(store)
        TestSupport.expectEqual(current.samples, samples(0 ..< 3))
        TestSupport.expectEqual(current.bytesOnDisk, 0)

        store.flush()
        current = snapshot(store)
        TestSupport.expectEqual(current.samples, samples(0 ..< 3))
        TestSupport.expect(current.bytesOnDisk > 0 && current.fileCount == 1, "written")

        // Requests interleaved with flushes and appends, answered in order.
        let boxes = (0 ..< 4).map { _ in ResultBox<PowerLogStore.Snapshot>() }
        store.append(samples(3 ..< 4)[0])
        store.snapshot { boxes[0].set($0) }
        store.flush()
        store.snapshot { boxes[1].set($0) }
        store.append(samples(4 ..< 5)[0])
        store.snapshot { boxes[2].set($0) }
        store.flush()
        store.snapshot { boxes[3].set($0) }
        TestSupport.expectEqual(boxes.map { $0.wait().samples.count }, [4, 4, 5, 5])
        TestSupport.expectEqual(boxes[3].wait().samples, samples(0 ..< 5))
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 5))
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
    }

    /// A snapshot requested before a Clear is stale whenever it arrives; the Clear empties buffer and disk.
    private static func testClearWinsOverReadsInFlight() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        for sample in samples(0 ..< 3) { store.append(sample) }
        store.flush()
        store.append(samples(3 ..< 4)[0])
        let before = ResultBox<PowerLogStore.Snapshot>()
        store.snapshot { before.set($0) }
        store.clear()
        let old = before.wait()
        TestSupport.expect(!store.isCurrent(old), "a read begun before Clear is discarded")
        let after = snapshot(store)
        TestSupport.expect(store.isCurrent(after), "a read begun after Clear is current")
        TestSupport.expectEqual(after.samples, [])
        TestSupport.expectEqual(after.bytesOnDisk, 0)
        TestSupport.expectEqual(files.existingFiles, [])
        store.flush()   // nothing buffered survives the Clear
        TestSupport.expectEqual(snapshot(store).samples, [])
    }

    /// While writes fail, the buffer keeps only the newest rows; the next successful flush writes them.
    private static func testWriteFailuresKeepTheNewestRowsUpToACap() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("PowerLog")
        try! Data().write(to: blocker)   // a file where the log directory belongs: every write fails
        let (store, files) = makeStore(directory, maxBuffered: 4)
        for (index, sample) in samples(0 ..< 10).enumerated() {
            store.append(sample)
            if index % 3 == 0 { store.flush() }
        }
        store.flush()
        var current = snapshot(store)
        TestSupport.expectEqual(current.samples, samples(6 ..< 10))
        TestSupport.expectEqual(current.droppedSamples, 6)
        TestSupport.expectEqual(current.bytesOnDisk, 0)

        try! FileManager.default.removeItem(at: blocker)
        store.flush()
        current = snapshot(store)
        TestSupport.expectEqual(files.readSamples(), samples(6 ..< 10))
        TestSupport.expectEqual(current.samples, samples(6 ..< 10))
        TestSupport.expect(current.bytesOnDisk > 0, "written once the directory can be created")
    }

    /// Export flushes first, then copies into a fresh directory; later appends never change the copies.
    private static func testExportsAreFlushedImmutableCopies() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        for sample in samples(0 ..< 2) { store.append(sample) }   // buffered only
        guard case .exported(let export) = exportOutcome(store, into: exports) else {
            return TestSupport.expect(false, "an export")
        }
        TestSupport.expectEqual(export.files.map(\.lastPathComponent), ["log.csv"])
        TestSupport.expect(export.directory.deletingLastPathComponent().standardizedFileURL.path == exports.standardizedFileURL.path,
                           "a fresh directory under the exports directory")
        TestSupport.expect(export.files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == export.directory.standardizedFileURL.path }, "inside it")
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 2))   // flushed
        let copied = try! Data(contentsOf: export.files[0])
        TestSupport.expectEqual(PowerLogCSV.parse(String(decoding: copied, as: UTF8.self)), samples(0 ..< 2))
        for url in [export.directory] + export.files {
            let excluded = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            TestSupport.expect(excluded == true, "\(url.lastPathComponent) is excluded from backup")
        }

        for sample in samples(2 ..< 5) { store.append(sample) }
        store.flush()
        store.clear()
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        TestSupport.expectEqual(try! Data(contentsOf: export.files[0]), copied)   // immutable

        store.removeExport(export)
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        TestSupport.expect(!FileManager.default.fileExists(atPath: export.directory.path), "removed after sharing")

        TestSupport.expectEqual(exportOutcome(store, into: exports), .empty)   // nothing to export after Clear
    }

    private static func testExportsIncludeTheRotatedFile() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory, limitBytes: 400)
        store.append(samples(0 ..< 1)[0])
        store.flush()
        store.append(samples(1 ..< 2)[0])
        store.flush()   // past 400 bytes: rotates
        guard case .exported(let export) = exportOutcome(store, into: directory.appendingPathComponent("Exports")) else {
            return TestSupport.expect(false, "an export")
        }
        TestSupport.expectEqual(files.existingFiles.count, 2)
        TestSupport.expectEqual(export.files.map(\.lastPathComponent), ["log.1.csv", "log.csv"])   // oldest first
        let exported = export.files.flatMap { PowerLogCSV.parse(String(decoding: try! Data(contentsOf: $0), as: UTF8.self)) }
        TestSupport.expectEqual(exported, samples(0 ..< 2))
    }

    /// Copies left by an app that died with the share sheet open are removed at the next launch.
    private static func testLeftoverExportsAreRemoved() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory)
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        store.append(samples(0 ..< 1)[0])
        guard case .exported = exportOutcome(store, into: exports) else { return TestSupport.expect(false, "an export") }
        store.removeExports(in: exports)
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        TestSupport.expect(!FileManager.default.fileExists(atPath: exports.path), "leftovers removed")
        store.removeExports(in: exports)   // nothing to remove is fine
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
    }
}

extension PowerLogStoreTests {
    /// Bytes were committed before the append failed: the file goes back to its previous length.
    fileprivate static func testPartialAppendIsRolledBack() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let files = PowerLogFiles(directory: directory, fileName: "log.csv", rotatedFileName: "log.1.csv",
                                  operations: faults.operations)
        try! files.append(samples(0 ..< 2))
        let before = fileData(files.currentURL)
        faults.partialAppend = true
        do {
            try files.append(samples(2 ..< 5))
            TestSupport.expect(false, "the append fails")
        } catch let failure as PowerLogAppendFailure {
            TestSupport.expect(failure.rolledBack, "rolled back")
        } catch {
            TestSupport.expect(false, "unexpected \(error)")
        }
        TestSupport.expectEqual(fileData(files.currentURL), before)
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 2))
    }

    /// A new file written in full but not excluded from backup is removed, so a retry cannot duplicate it.
    fileprivate static func testNewFileIsRemovedWhenBackupExclusionFails() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        faults.failFileBackupExclusion = true
        let files = PowerLogFiles(directory: directory, fileName: "log.csv", rotatedFileName: "log.1.csv",
                                  operations: faults.operations)
        do {
            try files.append(samples(0 ..< 2))
            TestSupport.expect(false, "the append fails")
        } catch let failure as PowerLogAppendFailure {
            TestSupport.expect(failure.rolledBack, "rolled back")
        } catch {
            TestSupport.expect(false, "unexpected \(error)")
        }
        TestSupport.expectEqual(files.existingFiles, [])
        faults.failFileBackupExclusion = false
        try! files.append(samples(0 ..< 2))
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 2))
    }

    /// Snapshots after a failed append, and the retry, see every row exactly once.
    fileprivate static func testFailedAppendsNeverDoubleCount() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let (store, files) = makeStore(directory, faults: faults)
        for sample in samples(0 ..< 2) { store.append(sample) }
        store.flush()
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        faults.partialAppend = true
        for sample in samples(2 ..< 5) { store.append(sample) }
        store.flush()
        TestSupport.expectEqual(snapshot(store).samples, samples(0 ..< 5))
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 2))
        faults.partialAppend = false
        store.flush()
        TestSupport.expectEqual(snapshot(store).samples, samples(0 ..< 5))
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 5))
    }

    /// When even the rollback fails, the buffered rows are dropped (counted), never written twice, and the
    /// next append starts on a fresh line.
    fileprivate static func testUnrecoverableAppendDropsRatherThanDuplicates() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let (store, files) = makeStore(directory, faults: faults)
        for sample in samples(0 ..< 2) { store.append(sample) }
        store.flush()
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        faults.partialAppend = true
        faults.failTruncate = true
        for sample in samples(2 ..< 5) { store.append(sample) }
        store.flush()
        let current = snapshot(store)
        TestSupport.expectEqual(current.droppedSamples, 3)
        TestSupport.expect(Array(samples(0 ..< 5).prefix(current.samples.count)) == current.samples,
                           "each row at most once, in order")
        faults.partialAppend = false
        faults.failTruncate = false
        for sample in samples(5 ..< 7) { store.append(sample) }
        store.flush()
        TestSupport.expectEqual(Array(snapshot(store).samples.suffix(2)), samples(5 ..< 7))
        TestSupport.expectEqual(Array(files.readSamples().suffix(2)), samples(5 ..< 7))
    }

    /// A Clear that cannot delete reports failure, keeps the log and the buffer, and fences nothing.
    fileprivate static func testClearFailureKeepsTheLogAndSaysSo() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let (store, files) = makeStore(directory, faults: faults)
        for sample in samples(0 ..< 3) { store.append(sample) }
        store.flush()
        store.append(samples(3 ..< 4)[0])
        let before = snapshot(store)
        faults.failRemove = true
        TestSupport.expectEqual(clearOutcome(store), .failed)   // Clear reports the failure
        TestSupport.expect(store.isCurrent(before), "nothing was cleared, so earlier reads stay valid")
        let after = snapshot(store)
        TestSupport.expectEqual(after.samples, samples(0 ..< 4))
        TestSupport.expect(store.isCurrent(after), "current")
        TestSupport.expectEqual(files.existingFiles.count, 1)

        faults.failRemove = false
        TestSupport.expectEqual(clearOutcome(store), .cleared)
        TestSupport.expect(!store.isCurrent(before) && !store.isCurrent(after), "older reads are stale")
        TestSupport.expectEqual(snapshot(store).samples, [])
    }

    /// Rows that cannot be written to the log still reach the export, exactly once.
    fileprivate static func testExportIncludesRowsThatCouldNotBeFlushed() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let (store, files) = makeStore(directory, faults: faults)
        for sample in samples(0 ..< 2) { store.append(sample) }
        store.flush()
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        faults.partialAppend = true
        for sample in samples(2 ..< 4) { store.append(sample) }
        guard case .exported(let export) = exportOutcome(store, into: directory.appendingPathComponent("Exports")) else {
            return TestSupport.expect(false, "an export")
        }
        let exported = export.files.flatMap { PowerLogCSV.parse(String(decoding: fileData($0), as: UTF8.self)) }
        TestSupport.expectEqual(exported, samples(0 ..< 4))
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 2))
        TestSupport.expectEqual(snapshot(store).samples, samples(0 ..< 4))

        // An export that cannot be written is refused, not partial.
        let blocked = directory.appendingPathComponent("Blocked")
        try! Data().write(to: blocked)
        TestSupport.expectEqual(exportOutcome(store, into: blocked), .failed)
    }
    /// The older file is deleted, then deleting the current one fails: what was removed is gone, so the
    /// generation advances, and Clear says it was partial.
    fileprivate static func testPartialClearAdvancesAndSaysSo() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let (store, files) = makeStore(directory, limitBytes: 400, faults: faults)
        store.append(samples(0 ..< 1)[0])
        store.flush()
        store.append(samples(1 ..< 2)[0])
        store.flush()   // rotates: two files
        store.append(samples(2 ..< 3)[0])   // buffered
        let before = snapshot(store)
        TestSupport.expectEqual(before.fileCount, 2)
        faults.removalsBeforeFailure = 1
        TestSupport.expectEqual(clearOutcome(store), .partiallyCleared)
        TestSupport.expect(!store.isCurrent(before), "deleted rows never come back")
        let after = snapshot(store)
        TestSupport.expect(store.isCurrent(after), "current")
        TestSupport.expectEqual(files.existingFiles, [files.currentURL])
        TestSupport.expectEqual(after.samples, samples(1 ..< 2))   // what survived; the buffer is gone too
        faults.removalsBeforeFailure = nil
        TestSupport.expectEqual(clearOutcome(store), .cleared)
        TestSupport.expectEqual(snapshot(store).samples, [])
    }

    /// The flush during an export writes part of the rows and cannot undo it, so it drops them; the export
    /// was copied from disk plus buffer before that, so it is still complete, with each row once.
    fileprivate static func testExportIsCompleteWhenTheFlushLosesRows() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = Faults()
        let (store, _) = makeStore(directory, faults: faults)
        for sample in samples(0 ..< 2) { store.append(sample) }
        store.flush()
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        faults.partialAppend = true
        faults.failTruncate = true
        for sample in samples(2 ..< 4) { store.append(sample) }
        guard case .exported(let export) = exportOutcome(store, into: directory.appendingPathComponent("Exports")) else {
            return TestSupport.expect(false, "an export")
        }
        let exported = export.files.flatMap { PowerLogCSV.parse(String(decoding: fileData($0), as: UTF8.self)) }
        TestSupport.expectEqual(exported, samples(0 ..< 4))
        TestSupport.expectEqual(snapshot(store).droppedSamples, 2)   // the flush after the copy lost them
    }

    /// After the schema 2 upgrade both files on disk are schema 1 and new rows are buffered. The export keeps
    /// both source files exactly and puts the buffered rows in a third file, instead of rotating the
    /// current copy over the older one.
    fileprivate static func testExportKeepsBothFilesDuringSchemaMigration() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        try! FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        func schema1(_ times: Range<Int>) -> String {
            PowerLogTests.schema1Header + "\n# schema=1\n" + times.map { t in
                "2027-01-15T08:0\(t):00.000Z,\(1_000 + t * 60).000,periodic,idle,foreground,0.800,unplugged,false,nominal,0.000,0.000,120.5,166.0,,1,\"iPhone16,1\"\n"
            }.joined()
        }
        let older = schema1(0 ..< 2), current = schema1(2 ..< 4)
        try! older.write(to: files.rotatedURL, atomically: true, encoding: .utf8)
        try! current.write(to: files.currentURL, atomically: true, encoding: .utf8)
        let buffered = samples(10 ..< 12)
        for sample in buffered { store.append(sample) }
        guard case .exported(let export) = exportOutcome(store, into: directory.appendingPathComponent("Exports")) else {
            return TestSupport.expect(false, "an export")
        }
        TestSupport.expectEqual(export.files.map(\.lastPathComponent), ["log.1.csv", "log.csv", "log-unflushed.csv"])
        TestSupport.expectEqual(String(decoding: fileData(export.files[0]), as: UTF8.self), older)
        TestSupport.expectEqual(String(decoding: fileData(export.files[1]), as: UTF8.self), current)
        let exported = export.files.flatMap { PowerLogCSV.parse(String(decoding: fileData($0), as: UTF8.self)) }
        TestSupport.expectEqual(exported.count, 6)
        TestSupport.expectEqual(Array(exported.suffix(2)), buffered)
        TestSupport.expectEqual(exported.prefix(4).map(\.alwaysOn), [false, false, false, false])
        TestSupport.expectEqual(exported.prefix(4).map(\.protectedData), [nil, nil, nil, nil])
    }
}

private struct TestFault: Error {}

/// Injectable failures for `PowerLogFiles.Operations`, switched from the test thread between waits.
private final class Faults: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [String: Bool] = [:]

    private func get(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return flags[key] ?? false }
    private func set(_ key: String, _ value: Bool) { lock.lock(); flags[key] = value; lock.unlock() }

    /// Removals after this many successful ones fail (nil: never).
    var removalsBeforeFailure: Int? {
        get { lock.lock(); defer { lock.unlock() }; return removalBudget }
        set { lock.lock(); removalBudget = newValue; lock.unlock() }
    }
    private var removalBudget: Int?

    /// Appends write half of the bytes, then throw.
    var partialAppend: Bool { get { get("partialAppend") } set { set("partialAppend", newValue) } }
    var failTruncate: Bool { get { get("failTruncate") } set { set("failTruncate", newValue) } }
    var failRemove: Bool { get { get("failRemove") } set { set("failRemove", newValue) } }
    /// Backup exclusion fails for files (the directory still succeeds).
    var failFileBackupExclusion: Bool {
        get { get("failFileBackupExclusion") } set { set("failFileBackupExclusion", newValue) }
    }

    /// True when this removal must fail.
    private func spendRemoval() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let budget = removalBudget else { return false }
        if budget == 0 { return true }
        removalBudget = budget - 1
        return false
    }

    var operations: PowerLogFiles.Operations {
        let standard = PowerLogFiles.Operations.standard
        var operations = standard
        operations.appendData = { [self] data, url in
            guard partialAppend else { return try standard.appendData(data, url) }
            try standard.appendData(data.prefix(data.count / 2), url)
            throw TestFault()
        }
        operations.truncate = { [self] url, length in
            if failTruncate { throw TestFault() }
            try standard.truncate(url, length)
        }
        operations.removeItem = { [self] url in
            if failRemove || spendRemoval() { throw TestFault() }
            try standard.removeItem(url)
        }
        operations.excludeFromBackup = { [self] url in
            if failFileBackupExclusion, url.pathExtension == "csv" { throw TestFault() }
            try standard.excludeFromBackup(url)
        }
        return operations
    }
}

/// A value delivered once from another thread.
private final class ResultBox<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Value?

    func set(_ value: Value) {
        self.value = value
        semaphore.signal()
    }

    func wait() -> Value {
        if semaphore.wait(timeout: .now() + 10) == .timedOut { fatalError("no result within 10 s") }
        semaphore.signal()   // later waits return at once
        return value!
    }
}
