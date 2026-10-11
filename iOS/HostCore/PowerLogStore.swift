import Foundation

/// The power log's one serialized owner (test builds only; ARCHITECTURE.md, "Power log"). Buffering,
/// encoding, rotation, writes, reads for the summary, export copies and Clear all run in order on one
/// utility queue, never on the caller's thread:
///
/// - A snapshot sees disk plus buffer at one point in that order, so no row is counted twice. An append
///   is all or nothing (`PowerLogFiles`); if one cannot even be undone, its rows are dropped and counted
///   rather than kept for a retry that would write them twice.
/// - Each snapshot carries the generation it was read at. A Clear that deleted anything advances the
///   generation, and `isCurrent` is false while a Clear is pending, so a read already in flight never
///   brings deleted data back. A Clear that deleted nothing reports `.failed` and changes nothing.
/// - After a failed write the rows stay buffered for the next flush, but only the newest
///   `maxBufferedSamples`; older rows are dropped and counted.
/// - An export copies disk plus buffer into a fresh directory that nothing writes again, then flushes;
///   whatever the flush does, the export is complete or refused.
final class PowerLogStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        /// Disk (oldest file first), then the buffer.
        var samples: [PowerSample]
        var bytesOnDisk: Int
        var fileCount: Int
        /// Rows dropped since launch because writes kept failing.
        var droppedSamples: Int
        var generation: UInt64
    }

    /// Immutable copies of the log for the share sheet. Remove them when sharing completes.
    struct Export: Sendable, Equatable {
        var directory: URL
        /// Oldest first.
        var files: [URL]
    }

    enum ExportOutcome: Sendable, Equatable {
        case exported(Export)
        /// Nothing logged yet.
        case empty
        /// The copies could not be written; nothing partial is left behind.
        case failed
    }

    let maxBufferedSamples: Int

    private let files: PowerLogFiles
    private let queue = DispatchQueue(label: "LocalFlow.PowerLogStore", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var generation: UInt64 = 0
    private var requestedClears = 0
    private var finishedClears = 0
    // Owned by `queue`.
    private var buffer: [PowerSample] = []
    private var dropped = 0

    init(files: PowerLogFiles, maxBufferedSamples: Int = 2_000) {
        self.files = files
        self.maxBufferedSamples = maxBufferedSamples
    }

    func append(_ sample: PowerSample) {
        queue.async {
            self.buffer.append(sample)
            self.trimBuffer()
        }
    }

    /// Writes the buffer. On failure it stays buffered (bounded) until the next flush.
    func flush() {
        queue.async { self.writeBuffer() }
    }

    /// `completion` runs on the owner's queue, so heavy work there (a summary) stays off the main thread.
    func snapshot(_ completion: @escaping @Sendable (Snapshot) -> Void) {
        queue.async {
            let samples = self.files.readSamples() + self.buffer
            completion(Snapshot(samples: samples, bytesOnDisk: self.files.totalBytes, fileCount: self.files.existingFiles.count,
                                droppedSamples: self.dropped, generation: self.locked { self.generation }))
        }
    }

    /// False while a Clear is pending, and once a Clear succeeded after the snapshot was read.
    func isCurrent(_ snapshot: Snapshot) -> Bool { isCurrent(generation: snapshot.generation) }

    func isCurrent(generation: UInt64) -> Bool {
        locked { requestedClears == finishedClears && generation == self.generation }
    }

    /// Deletes the log and the buffer; `completion` runs on the owner's queue. If any file was deleted, the
    /// buffer goes too and the generation advances, even when another file could not be deleted
    /// (`.partiallyCleared`). If none was, nothing changes (`.failed`).
    func clear(completion: (@Sendable (PowerLogClearOutcome) -> Void)? = nil) {
        locked { requestedClears += 1 }
        queue.async {
            let outcome = self.files.clear()
            let changed = outcome != .failed
            if changed {
                self.buffer.removeAll()
                self.dropped = 0
            }
            self.locked {
                if changed { self.generation += 1 }
                self.finishedClears += 1
            }
            completion?(outcome)
        }
    }

    /// Copies disk plus buffer into a new directory under `directory`, excluded from backup, then flushes.
    /// The copy is taken before the buffer is consumed, so a flush that fails (or loses rows it cannot
    /// roll back) never makes the export incomplete.
    func exportSnapshot(into directory: URL, completion: @escaping @Sendable (ExportOutcome) -> Void) {
        queue.async {
            let outcome = self.copy(into: directory)
            self.writeBuffer()
            completion(outcome)
        }
    }

    func removeExport(_ export: Export) {
        queue.async { try? FileManager.default.removeItem(at: export.directory) }
    }

    /// Removes every export left under `directory`, for example by an app that died while sharing.
    func removeExports(in directory: URL) {
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits up to `timeout` for the work queued so far, for termination. True when it finished.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Private (on `queue`)

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func trimBuffer() {
        let excess = buffer.count - maxBufferedSamples
        guard excess > 0 else { return }
        buffer.removeFirst(excess)
        dropped += excess
    }

    private func writeBuffer() {
        guard !buffer.isEmpty else { return }
        do {
            try files.append(buffer)
            buffer.removeAll()
        } catch let failure as PowerLogAppendFailure where !failure.rolledBack {
            // Some rows may be on disk: never write them again.
            dropped += buffer.count
            buffer.removeAll()
        } catch {
            trimBuffer()
        }
    }

    private func copy(into directory: URL) -> ExportOutcome {
        let sources = files.existingFiles
        guard !sources.isEmpty || !buffer.isEmpty else { return .empty }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try PowerLogFiles.Operations.standard.excludeFromBackup(directory)
            try PowerLogFiles.Operations.standard.excludeFromBackup(target)
            for source in sources {
                let copy = target.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                try fileManager.copyItem(at: source, to: copy)
                try PowerLogFiles.Operations.standard.excludeFromBackup(copy)
            }
            let copies = PowerLogFiles(directory: target, fileName: files.currentURL.lastPathComponent,
                                       rotatedFileName: files.rotatedURL.lastPathComponent, limitBytes: .max)
            guard !buffer.isEmpty, copies.currentHasOtherSchema else {
                try copies.append(buffer)
                return .exported(Export(directory: target, files: copies.existingFiles))
            }
            // The current copy has an older schema: appending would rotate it over the older copy. Both
            // source snapshots stay as they are, and the buffered rows get a file of their own.
            let current = files.currentURL
            let unflushedName = current.deletingPathExtension().lastPathComponent + "-unflushed." + current.pathExtension
            let unflushed = PowerLogFiles(directory: target, fileName: unflushedName,
                                          rotatedFileName: unflushedName + ".unused", limitBytes: .max)
            try unflushed.append(buffer)
            return .exported(Export(directory: target, files: copies.existingFiles + [unflushed.currentURL]))
        } catch {
            try? fileManager.removeItem(at: target)
            return .failed
        }
    }
}
