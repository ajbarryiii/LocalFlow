import Foundation

/// A stable copy of the bundled model, one directory per bundle.json digest.
/// Core ML's on-device specialization cache is keyed by the encoder weight
/// file's path and inode, so a copy that is never rewritten stays warm across
/// app updates that keep the model (Benchmarks/ParakeetStartup.md). Every
/// failure falls back to the bundle. Nothing is logged.
final class ParakeetModelStore: @unchecked Sendable {
    /// `<Application Support>/<bundle identifier>/Models`, so app variants never
    /// collect each other's models. Nil without a bundle identifier (scripts, tests).
    static let application: ParakeetModelStore? = {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ParakeetModelStore(root: support.appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true))
    }()

    let root: URL
    private static let marker = ".localflow-complete"
    private static let stagingPrefix = ".staging-"
    private let files = FileManager.default
    private let lock = NSLock()
    // Set once a store copy is rejected; the bundle is used until relaunch.
    private var disabled = false

    init(root: URL) {
        self.root = root
    }

    /// Opens the model from the store, installing it first when missing. If
    /// `open` rejects the store copy, that copy is removed, the store is off for
    /// this process and `bundle` is opened instead; the next launch installs again.
    func open<T>(bundle: URL, _ open: (URL) throws -> T) throws -> T {
        let directory = self.directory(for: bundle)
        guard directory != bundle else { return try open(bundle) }
        do {
            return try open(directory)
        } catch {
            lock.lock()
            disabled = true
            lock.unlock()
            discard(directory)
            return try open(bundle)
        }
    }

    /// `<root>/<SHA-256 of bundle.json>`, complete and untouched if present,
    /// otherwise installed from `bundle`; other entries under root are removed.
    /// Returns `bundle` on any failure or after a rejection.
    func directory(for bundle: URL) -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, let identity = try? identity(of: bundle) else { return bundle }
        let target = root.appendingPathComponent(identity, isDirectory: true)
        if !isComplete(target, identity: identity) {
            guard install(bundle, at: target, identity: identity) else { return bundle }
        }
        collectGarbage(keeping: identity)
        return target
    }

    /// Removes a model directory directly inside root; anything else is ignored.
    func discard(_ directory: URL) {
        guard directory.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path,
              !directory.lastPathComponent.hasPrefix(".") else { return }
        try? files.removeItem(at: directory)
    }

    private func identity(of bundle: URL) throws -> String {
        LocalParakeetCore.sha256(try Data(contentsOf: bundle.appendingPathComponent("bundle.json")))
    }

    // The marker is written last, before the rename, so a directory without it
    // is an interrupted or foreign copy.
    private func isComplete(_ directory: URL, identity: String) -> Bool {
        (try? Data(contentsOf: directory.appendingPathComponent(Self.marker))) == Data(identity.utf8)
    }

    // copyItem clones on APFS; the rename keeps every inode, so the first load
    // at the final path is the only cold one.
    private func install(_ bundle: URL, at target: URL, identity: String) -> Bool {
        let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = root
            try? excluded.setResourceValues(values)
            if isComplete(target, identity: identity) { return true }
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.copyItem(at: bundle, to: staging)
            try Data(identity.utf8).write(to: staging.appendingPathComponent(Self.marker))
            do {
                try files.moveItem(at: staging, to: target)
            } catch {
                // Another install won the race; use its copy.
                try? files.removeItem(at: staging)
                return isComplete(target, identity: identity)
            }
            return true
        } catch {
            try? files.removeItem(at: staging)
            return false
        }
    }

    // Removes only root's direct entries; a symbolic link is removed, not followed.
    private func collectGarbage(keeping identity: String) {
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name != identity {
            try? files.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
