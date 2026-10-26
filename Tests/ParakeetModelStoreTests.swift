import Foundation

/// Contract of the stable model location: one directory per bundle.json, kept
/// untouched across app updates, so Core ML's on-device specialization (keyed
/// by the weight file's path and inode) stays warm. Invented files only.
enum ParakeetModelStoreTests {
    private static let files = FileManager.default

    static func run() {
        testInstallCopiesBundle()
        testReuseKeepsWeightFileIdentity()
        testNewIdentityReplacesOld()
        testStaleStagingRemoved()
        testIncompleteDirectoryReplaced()
        testFailureReturnsBundle()
        testCollectionStaysInsideRoot()
        testTamperedCopyReplaced()
        testRejectedStoreFallsBackOnce()
        testFirstLoadFailureFallsBack()
        testConcurrentInstalls()
        testInstallKeepsOtherProcessCopy()
    }

    private static func testInstallCopiesBundle() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let store = ParakeetModelStore(root: scratch.root)
        let directory = store.directory(for: bundle)
        TestSupport.expectEqual(directory.standardizedFileURL.path,
                                scratch.root.appendingPathComponent(identity(bundle)).standardizedFileURL.path)
        TestSupport.expectEqual(contents(of: directory), contents(of: bundle))
        TestSupport.expectEqual(contents(of: bundle), Scratch.synthetic(manifest: "first"))
        TestSupport.expect((try? scratch.root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true,
                           "The store must be excluded from backups")
    }

    // The core contract: an installed copy is never rewritten, even when the
    // app bundle itself is replaced by an update with the same model.
    private static func testReuseKeepsWeightFileIdentity() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let first = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        let inode = fileNumber(first.appendingPathComponent(Scratch.weights))
        TestSupport.expectEqual(ParakeetModelStore(root: scratch.root).directory(for: bundle), first)
        TestSupport.expectEqual(fileNumber(first.appendingPathComponent(Scratch.weights)), inode)

        // An app update: the same files at the same bundle path, new inodes.
        try! files.removeItem(at: bundle)
        _ = scratch.bundle(manifest: "first")
        TestSupport.expectEqual(ParakeetModelStore(root: scratch.root).directory(for: bundle), first)
        TestSupport.expectEqual(fileNumber(first.appendingPathComponent(Scratch.weights)), inode)
        TestSupport.expectEqual(contents(of: first), contents(of: bundle))
    }

    private static func testNewIdentityReplacesOld() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let old = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        try! files.removeItem(at: bundle)
        _ = scratch.bundle(manifest: "second")
        let new = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        TestSupport.expectEqual(new.lastPathComponent, identity(bundle))
        TestSupport.expect(new != old, "A changed bundle.json must get its own directory")
        TestSupport.expectEqual(contents(of: new), Scratch.synthetic(manifest: "second"))
        TestSupport.expect(!files.fileExists(atPath: old.path), "The previous model must be removed")
        TestSupport.expectEqual(entries(scratch.root), [new.lastPathComponent])
    }

    private static func testStaleStagingRemoved() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let stale = scratch.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try! files.createDirectory(at: stale.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try! Data([1, 2, 3]).write(to: stale.appendingPathComponent("weights/weight.bin"))
        let directory = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        TestSupport.expect(!files.fileExists(atPath: stale.path), "A stale staging directory must be removed")
        TestSupport.expectEqual(entries(scratch.root), [directory.lastPathComponent])
    }

    // A directory with the right name but no completion marker (an interrupted
    // copy) is never trusted.
    private static func testIncompleteDirectoryReplaced() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let target = scratch.root.appendingPathComponent(identity(bundle), isDirectory: true)
        try! files.createDirectory(at: target.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try! Data("truncated".utf8).write(to: target.appendingPathComponent("bundle.json"))
        let directory = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        TestSupport.expectEqual(directory.standardizedFileURL.path, target.standardizedFileURL.path)
        TestSupport.expectEqual(contents(of: directory), contents(of: bundle))
    }

    private static func testFailureReturnsBundle() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        // The root cannot be created below a regular file.
        let blocker = scratch.base.appendingPathComponent("blocker")
        try! Data("file".utf8).write(to: blocker)
        TestSupport.expectEqual(ParakeetModelStore(root: blocker.appendingPathComponent("store")).directory(for: bundle), bundle)
        TestSupport.expectEqual(try! Data(contentsOf: blocker), Data("file".utf8))

        // Without bundle.json there is no identity to store under.
        let empty = scratch.base.appendingPathComponent("empty", isDirectory: true)
        try! files.createDirectory(at: empty, withIntermediateDirectories: true)
        TestSupport.expectEqual(ParakeetModelStore(root: scratch.root).directory(for: empty), empty)
        TestSupport.expect(entries(scratch.root).isEmpty, "A failed install must leave nothing behind")
    }

    private static func testCollectionStaysInsideRoot() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let sibling = scratch.base.appendingPathComponent("sibling", isDirectory: true)
        try! files.createDirectory(at: sibling, withIntermediateDirectories: true)
        try! Data("keep".utf8).write(to: sibling.appendingPathComponent("keep.txt"))
        try! files.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        try! files.createSymbolicLink(at: scratch.root.appendingPathComponent("link"), withDestinationURL: sibling)
        let directory = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        TestSupport.expectEqual(entries(scratch.root), [directory.lastPathComponent])
        TestSupport.expectEqual(try! Data(contentsOf: sibling.appendingPathComponent("keep.txt")), Data("keep".utf8))
        TestSupport.expectEqual(contents(of: bundle), Scratch.synthetic(manifest: "first"))

        // Discarding accepts only this store's model directories.
        let store = ParakeetModelStore(root: scratch.root)
        store.discard(sibling)
        store.discard(bundle)
        TestSupport.expect(files.fileExists(atPath: sibling.appendingPathComponent("keep.txt").path), "Discard must stay inside the root")
        TestSupport.expectEqual(contents(of: bundle), Scratch.synthetic(manifest: "first"))
        store.discard(directory)
        TestSupport.expect(!files.fileExists(atPath: directory.path), "Discard must remove a store directory")
    }

    // A store copy that fails verification is removed once and the bundle is
    // used instead; the store then stays out of the way for this process.
    private static func testRejectedStoreFallsBackOnce() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let store = ParakeetModelStore(root: scratch.root)
        let target = scratch.root.appendingPathComponent(identity(bundle)).standardizedFileURL.path

        var opened: [String] = []
        let accepted = try! store.open(bundle: bundle, make: { url -> URL in opened.append(url.standardizedFileURL.path); return url }, prepare: { _ in })
        TestSupport.expectEqual(opened, [target])
        TestSupport.expectEqual(accepted.standardizedFileURL.path, target)

        opened = []
        let fallback = try! store.open(bundle: bundle, make: { url -> URL in
            opened.append(url.standardizedFileURL.path)
            guard url == bundle else { throw LocalParakeetError.invalid("rejected") }
            return url
        }, prepare: { _ in })
        TestSupport.expectEqual(fallback, bundle)
        TestSupport.expectEqual(opened, [target, bundle.standardizedFileURL.path])
        TestSupport.expect(!files.fileExists(atPath: target), "A rejected store copy must be removed")

        opened = []
        _ = try! store.open(bundle: bundle, make: { url -> URL in opened.append(url.standardizedFileURL.path); return url }, prepare: { _ in })
        TestSupport.expectEqual(opened, [bundle.standardizedFileURL.path])
        TestSupport.expectEqual(store.directory(for: bundle).path, bundle.path)
        TestSupport.expect(!files.fileExists(atPath: target), "The store must not reinstall in the same process")

        // A broken bundle: each location is tried once, then the error surfaces.
        let other = Scratch(), broken = other.bundle(manifest: "first")
        var attempts = 0
        do {
            _ = try ParakeetModelStore(root: other.root).open(bundle: broken, make: { _ -> Int in
                attempts += 1
                throw LocalParakeetError.invalid("rejected")
            }, prepare: { _ in })
            TestSupport.expect(false, "A rejected bundle must throw")
        } catch {}
        TestSupport.expectEqual(attempts, 2)

        // The next launch (a new store) installs again.
        TestSupport.expectEqual(ParakeetModelStore(root: scratch.root).directory(for: bundle).standardizedFileURL.path, target)
    }

    // The copy is writable, so its manifest is trusted only if it is the bundle's
    // own: a file changed together with its hash in the copy's manifest is replaced.
    private static func testTamperedCopyReplaced() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let directory = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        let tampered = Data("{\"0\":\"▁tampered\"}".utf8)
        try! tampered.write(to: directory.appendingPathComponent("vocabulary.json"))
        try! Data("{\"model\":\"first\",\"files\":{\"vocabulary.json\":\"\(LocalParakeetCore.sha256(tampered))\"}}".utf8)
            .write(to: directory.appendingPathComponent("bundle.json"))
        let again = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        TestSupport.expectEqual(again.standardizedFileURL.path, directory.standardizedFileURL.path)
        TestSupport.expectEqual(contents(of: again), contents(of: bundle))
        TestSupport.expectEqual(entries(scratch.root), [identity(bundle)])
    }

    // Construction can succeed while Core ML's first load of the store copy
    // fails (files gone after the integrity check): the bundle is used instead.
    private static func testFirstLoadFailureFallsBack() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let store = ParakeetModelStore(root: scratch.root)
        let target = scratch.root.appendingPathComponent(identity(bundle)).standardizedFileURL.path
        let source = bundle.standardizedFileURL.path
        var made: [String] = [], loaded: [String] = []
        let opened = try! store.open(bundle: bundle, make: { url -> String in
            made.append(url.standardizedFileURL.path)
            return url.standardizedFileURL.path
        }, prepare: { path in
            loaded.append(path)
            guard path == source else { throw LocalParakeetError.invalid("load failed") }
        })
        TestSupport.expectEqual(opened, source)
        TestSupport.expectEqual(made, [target, source])
        TestSupport.expectEqual(loaded, [target, source])
        TestSupport.expect(!files.fileExists(atPath: target), "A store copy that cannot be loaded must be removed")
        TestSupport.expectEqual(store.directory(for: bundle).path, bundle.path)

        // A bundle that cannot be loaded either: each location once, then the error.
        let other = Scratch(), broken = other.bundle(manifest: "first")
        var loads = 0
        do {
            _ = try ParakeetModelStore(root: other.root).open(bundle: broken, make: { $0 }, prepare: { _ in
                loads += 1
                throw LocalParakeetError.invalid("load failed")
            })
            TestSupport.expect(false, "An unloadable bundle must throw")
        } catch {}
        TestSupport.expectEqual(loads, 2)
    }

    private static func testConcurrentInstalls() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let target = scratch.root.appendingPathComponent(identity(bundle)).standardizedFileURL.path
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            results.append(ParakeetModelStore(root: scratch.root).directory(for: bundle).standardizedFileURL.path)
        }
        TestSupport.expect(results.all.allSatisfy { $0 == target || $0 == bundle.standardizedFileURL.path },
                           "Every racing install must use the store copy or the bundle")
        let settled = ParakeetModelStore(root: scratch.root).directory(for: bundle)
        TestSupport.expectEqual(settled.standardizedFileURL.path, target)
        TestSupport.expectEqual(contents(of: settled), contents(of: bundle))
        TestSupport.expectEqual(entries(scratch.root), [identity(bundle)])
    }

    // Two app processes share the root (two stores here). One install finding no
    // complete copy must not remove the copy the other finished and handed out
    // meanwhile: removing it races the other's rename and can leave a partial
    // copy that passes the completeness check.
    private static func testInstallKeepsOtherProcessCopy() {
        let scratch = Scratch(), bundle = scratch.bundle(manifest: "first")
        let target = scratch.root.appendingPathComponent(identity(bundle)).standardizedFileURL.path
        let other = ParakeetModelStore(root: scratch.root)
        let handedOut = Results(), finished = DispatchGroup()
        let store = ParakeetModelStore(root: scratch.root, afterCheck: {
            // The other process installs inside this window if it can. A store
            // that keeps it out makes it wait, so its chance here is bounded.
            finished.enter()
            DispatchQueue.global().async {
                let directory = other.directory(for: bundle)
                handedOut.append(directory.standardizedFileURL.path)
                handedOut.append("\(fileNumber(directory.appendingPathComponent(Scratch.weights)) ?? 0)")
                finished.leave()
            }
            _ = finished.wait(timeout: .now() + 1)
        })
        TestSupport.expectEqual(store.directory(for: bundle).standardizedFileURL.path, target)
        finished.wait()
        let weights = scratch.root.appendingPathComponent(identity(bundle)).appendingPathComponent(Scratch.weights)
        TestSupport.expectEqual(handedOut.all, [target, "\(fileNumber(weights) ?? 0)"])

        let settled = try! ParakeetModelStore(root: scratch.root).open(bundle: bundle, make: { url -> URL in
            guard contents(of: url) == contents(of: bundle) else { throw LocalParakeetError.invalid("incomplete") }
            return url
        }, prepare: { _ in })
        TestSupport.expectEqual(settled.standardizedFileURL.path, target)
        TestSupport.expectEqual(entries(scratch.root), [identity(bundle)])
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func append(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    /// A temporary base holding a synthetic bundle and the store root, removed on deinit.
    private final class Scratch {
        static let weights = "Encoder.mlmodelc/weights/weight.bin"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ParakeetModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        var root: URL { base.appendingPathComponent("store", isDirectory: true) }
        var bundleURL: URL { base.appendingPathComponent("App.app/Parakeet", isDirectory: true) }

        /// Invented files; the manifest text alone changes the identity.
        static func synthetic(manifest: String) -> [String: Data] {
            ["bundle.json": Data("{\"model\":\"\(manifest)\"}".utf8),
             "vocabulary.json": Data("{\"0\":\"▁synthetic\"}".utf8),
             "Encoder.mlmodelc/model.mil": Data("program".utf8),
             weights: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })]
        }

        func bundle(manifest: String) -> URL {
            for (path, data) in Self.synthetic(manifest: manifest) {
                let url = bundleURL.appendingPathComponent(path)
                try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try! data.write(to: url)
            }
            return bundleURL
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    private static func identity(_ bundle: URL) -> String {
        LocalParakeetCore.sha256(try! Data(contentsOf: bundle.appendingPathComponent("bundle.json")))
    }

    private static func fileNumber(_ url: URL) -> UInt64? {
        ((try? files.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func entries(_ directory: URL) -> [String] {
        ((try? files.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Regular files by relative path, ignoring the store's hidden bookkeeping.
    private static func contents(of directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walker = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            result[String(path.dropFirst(base.count))] = try? Data(contentsOf: url)
        }
        return result
    }
}
