import Foundation

/// An append that failed. With `rolledBack` the files hold exactly what they held before (a rotation may
/// have moved rows to the older file, never copied them), so the rows may be written again. Without it
/// some of them may be on disk, and writing them again would count them twice.
struct PowerLogAppendFailure: Error {
    var rolledBack: Bool
    var underlying: Error
}

/// What a Clear achieved. `partiallyCleared`: some files were deleted and others could not be.
enum PowerLogClearOutcome: Sendable, Equatable {
    case cleared, partiallyCleared, failed
}

/// The power log on disk (test builds only): a current file and at most one rotated, older file in a
/// directory excluded from backup. The caller chooses the directory and names, so nothing outside the
/// `LOCALFLOW_POWER_LOG` gate names a power-log file. Not thread-safe; one owner calls it.
final class PowerLogFiles {
    /// The file operations whose failure matters, injectable so tests can fail them deterministically.
    struct Operations {
        var appendData: (Data, URL) throws -> Void
        var truncate: (URL, UInt64) throws -> Void
        var removeItem: (URL) throws -> Void
        var excludeFromBackup: (URL) throws -> Void

        static let standard = Operations(
            appendData: { data, url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            },
            truncate: { url, length in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: length)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            excludeFromBackup: { url in
                var url = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            })
    }

    let directory: URL
    let currentURL: URL
    let rotatedURL: URL
    let limitBytes: Int
    private let operations: Operations

    init(directory: URL, fileName: String, rotatedFileName: String, limitBytes: Int = PowerLogRotation.limitBytes,
         operations: Operations = .standard) {
        self.directory = directory
        currentURL = directory.appendingPathComponent(fileName, isDirectory: false)
        rotatedURL = directory.appendingPathComponent(rotatedFileName, isDirectory: false)
        self.limitBytes = limitBytes
        self.operations = operations
    }

    /// Oldest first.
    var existingFiles: [URL] {
        [rotatedURL, currentURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var totalBytes: Int { existingFiles.reduce(0) { $0 + size(of: $1) } }

    /// The current file exists but was written with another schema (for example schema 1 after an upgrade):
    /// appending to it would first rotate it over the older file.
    var currentHasOtherSchema: Bool { size(of: currentURL) > 0 && !startsWithPreamble(currentURL) }

    /// Appends rows, all or nothing. A new file starts with the header and schema line. The current file
    /// is rotated first when the rows would take it past `limitBytes`, or when it was written with another
    /// header. On failure it throws `PowerLogAppendFailure` after undoing what it wrote: a new file is
    /// removed, an existing one truncated to its previous length.
    func append(_ samples: [PowerSample]) throws {
        guard !samples.isEmpty else { return }
        var rows = Data(samples.map { PowerLogCSV.line($0) + "\n" }.joined().utf8)
        let existing: Int
        do {
            try ensureDirectory()
            let length = size(of: currentURL)
            if length > 0, !startsWithPreamble(currentURL) ||
                PowerLogRotation.shouldRotate(existingBytes: length, appendingBytes: rows.count, limit: limitBytes) {
                try rotate()
            }
            existing = size(of: currentURL)
            if existing == 0 {
                try (Data(PowerLogCSV.preamble.utf8) + rows).write(to: currentURL, options: .atomic)
            }
        } catch {
            throw PowerLogAppendFailure(rolledBack: true, underlying: error)
        }
        if existing == 0 {
            do {
                try operations.excludeFromBackup(currentURL)
            } catch {
                let removed = (try? operations.removeItem(currentURL)) != nil
                throw PowerLogAppendFailure(rolledBack: removed, underlying: error)
            }
        } else {
            // After a failure that could not be undone the file may end mid-row; start a fresh line.
            if !endsWithNewline(currentURL) { rows = Data("\n".utf8) + rows }
            do {
                try operations.appendData(rows, currentURL)
            } catch {
                let restored = (try? operations.truncate(currentURL, UInt64(existing))) != nil
                throw PowerLogAppendFailure(rolledBack: restored, underlying: error)
            }
        }
    }

    /// Every readable sample, oldest file first.
    func readSamples() -> [PowerSample] {
        existingFiles.flatMap { url -> [PowerSample] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return PowerLogCSV.parse(String(decoding: data, as: UTF8.self))
        }
    }

    /// Deletes both files, older first, and says how far it got.
    func clear() -> PowerLogClearOutcome {
        let files = existingFiles
        let removed = files.filter { (try? operations.removeItem($0)) != nil }.count
        if removed == files.count { return .cleared }
        return removed == 0 ? .failed : .partiallyCleared
    }

    // MARK: Private

    private func rotate() throws {
        if FileManager.default.fileExists(atPath: rotatedURL.path) { try FileManager.default.removeItem(at: rotatedURL) }
        try FileManager.default.moveItem(at: currentURL, to: rotatedURL)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try operations.excludeFromBackup(directory)
    }

    private func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func startsWithPreamble(_ url: URL) -> Bool {
        let preamble = Data(PowerLogCSV.preamble.utf8)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: preamble.count)) == preamble
    }

    private func endsWithNewline(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return true }
        try? handle.seek(toOffset: end - 1)
        return (try? handle.read(upToCount: 1)) == Data("\n".utf8)
    }
}
