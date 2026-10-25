import Foundation

/// The staged writes the App Group stores share (ARCHITECTURE.md, "Shared store and protocol", Staged writes):
/// the record files of one directory, each replaced whole. A write goes to a uniquely named staging file beside
/// its destination, written with the destination's protection class, then renamed over it, so a reader sees the
/// old or the new file, never part of one. A failed write removes its staging file and leaves the destination as
/// it was. Foundation's `.atomic` is avoided because its temporary file, abandoned by a crash, escapes every sweep.
///
/// Each store passes its own staging suffix, protection classes and sweep rule. Nothing here logs.
struct AtomicRecordFiles: Sendable {
    static let stagingPrefix = ".staging-"

    let directory: URL
    /// Ends every staging name, and a staging file is swept only if its name ends with it. Empty for none.
    let stagingSuffix: String

    /// Class A (`.complete`) on devices. macOS, where the host tests run, refuses class A to
    /// unentitled processes, and the simulator does not enforce data protection, so both use class C.
    static var completeProtection: Data.WritingOptions {
        #if os(iOS) && !targetEnvironment(simulator)
        return .completeFileProtection
        #else
        return .completeFileProtectionUntilFirstUserAuthentication
        #endif
    }

    /// A new staging name in `directory`: `.staging-<UUID>` followed by `stagingSuffix`.
    func makeStagingURL() -> URL {
        directory.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)\(stagingSuffix)", isDirectory: false)
    }

    /// Replaces the file at `url`, in `directory`, with `data`: creates the directory if needed, writes a new
    /// staging file with `protection` and renames it over `url`. On failure the staging file is removed and the
    /// error rethrown.
    func write(_ data: Data, to url: URL, protection: Data.WritingOptions) throws {
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

    /// Removes the staging files in `directory` that `isInFlight` does not keep, judged by their modification
    /// date. One whose date cannot be read is removed. Other files are never touched.
    func sweepStagingFiles(keeping isInFlight: (_ modified: Date) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix) && name.hasSuffix(stagingSuffix) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, isInFlight(modified) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Creates `directory`, excluded from backup, unless it exists.
    private func createDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)   // best effort, per the contract
    }
}
