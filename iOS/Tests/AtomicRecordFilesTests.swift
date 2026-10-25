import Foundation

/// The staged writes the App Group stores share (ARCHITECTURE.md, "Shared store and protocol", Staged writes): a
/// write replaces its file whole and leaves no staging file, a failed write removes its own, and the sweep removes
/// only the staging files the caller's rule does not keep. Every file is invented and lives in a temporary
/// directory.
enum AtomicRecordFilesTests {
    static var tests: [TestCase] {
        [
            ("writeReplacesTheFileWhole", testWriteReplacesTheFileWhole),
            ("createsDirectoryExcludedFromBackup", testCreatesDirectoryExcludedFromBackup),
            ("successfulWritesLeaveNoStagingFile", testSuccessfulWritesLeaveNoStagingFile),
            ("failedWriteRemovesItsStagingFile", testFailedWriteRemovesItsStagingFile),
            ("stagingNamesAreUniqueAndCarryTheSuffix", testStagingNamesAreUniqueAndCarryTheSuffix),
            ("sweepKeepsWhatTheRuleKeeps", testSweepKeepsWhatTheRuleKeeps),
            ("sweepMatchesTheSuffix", testSweepMatchesTheSuffix),
        ]
    }

    private static let protection = AtomicRecordFiles.completeProtection

    /// Files in a directory that does not exist yet, under a fresh temporary root.
    private static func withFiles(stagingSuffix: String = ".tmp", _ body: (AtomicRecordFiles) -> Void) {
        let root = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        body(AtomicRecordFiles(directory: root.appendingPathComponent("Records", isDirectory: true), stagingSuffix: stagingSuffix))
    }

    private static func fileNames(in files: AtomicRecordFiles) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []).sorted()
    }

    private static func stagingNames(in files: AtomicRecordFiles) -> [String] {
        fileNames(in: files).filter { $0.hasPrefix(AtomicRecordFiles.stagingPrefix) }
    }

    private static func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Puts an invented staging (or other) file named `name` in the directory, last modified at `modified`.
    private static func put(_ name: String, in files: AtomicRecordFiles, modified: Date) {
        try! FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let url = files.directory.appendingPathComponent(name, isDirectory: false)
        try! Data("synthetic".utf8).write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func testWriteReplacesTheFileWhole() {
        withFiles { files in
            let url = files.directory.appendingPathComponent("record.json", isDirectory: false)
            try! files.write(Data(#"{"value": "a much longer first synthetic record"}"#.utf8), to: url, protection: protection)
            TestSupport.expectEqual(contents(of: url), #"{"value": "a much longer first synthetic record"}"#)
            // A shorter record replaces the file whole: nothing of the longer one is left.
            try! files.write(Data(#"{"value": "second"}"#.utf8), to: url, protection: protection)
            TestSupport.expectEqual(contents(of: url), #"{"value": "second"}"#)
            TestSupport.expectEqual(fileNames(in: files), ["record.json"])
        }
    }

    private static func testCreatesDirectoryExcludedFromBackup() {
        withFiles { files in
            TestSupport.expect(!FileManager.default.fileExists(atPath: files.directory.path), "directory made early")
            try! files.write(Data("{}".utf8), to: files.directory.appendingPathComponent("record.json"), protection: protection)
            let values = try! files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            TestSupport.expectEqual(values.isExcludedFromBackup, true)
        }
    }

    private static func testSuccessfulWritesLeaveNoStagingFile() {
        for suffix in ["", ".tmp"] {
            withFiles(stagingSuffix: suffix) { files in
                for index in 0 ..< 20 {
                    let url = files.directory.appendingPathComponent("record-\(index % 3).json", isDirectory: false)
                    try! files.write(Data("{\"index\": \(index)}".utf8), to: url, protection: protection)
                }
                TestSupport.expectEqual(fileNames(in: files), ["record-0.json", "record-1.json", "record-2.json"])
            }
        }
    }

    private static func testFailedWriteRemovesItsStagingFile() {
        withFiles { files in
            let url = files.directory.appendingPathComponent("record.json", isDirectory: false)
            try! files.write(Data("old".utf8), to: url, protection: protection)
            // A non-empty directory where the destination belongs makes the rename fail after the staging write.
            let occupied = files.directory.appendingPathComponent("occupied.json", isDirectory: true)
            try! FileManager.default.createDirectory(at: occupied.appendingPathComponent("inside"), withIntermediateDirectories: true)
            TestSupport.expect((try? files.write(Data("new".utf8), to: occupied, protection: protection)) == nil,
                               "renamed over a directory")
            TestSupport.expectEqual(fileNames(in: files), ["occupied.json", "record.json"])
            // A write that cannot create its staging file fails too, leaving the old file and no staging file.
            let path = files.directory.path
            try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
            defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
            TestSupport.expect((try? files.write(Data("new".utf8), to: url, protection: protection)) == nil,
                               "wrote into a read-only directory")
            TestSupport.expectEqual(contents(of: url), "old")
            TestSupport.expectEqual(stagingNames(in: files), [])
        }
    }

    private static func testStagingNamesAreUniqueAndCarryTheSuffix() {
        for suffix in ["", ".tmp"] {
            withFiles(stagingSuffix: suffix) { files in
                let urls = (0 ..< 3).map { _ in files.makeStagingURL() }
                TestSupport.expectEqual(Set(urls).count, 3)
                for url in urls {
                    TestSupport.expectEqual(url.deletingLastPathComponent().standardizedFileURL, files.directory.standardizedFileURL)
                    let name = url.lastPathComponent
                    let middle = name.dropFirst(AtomicRecordFiles.stagingPrefix.count).dropLast(suffix.count)
                    TestSupport.expect(name.hasPrefix(AtomicRecordFiles.stagingPrefix) && name.hasSuffix(suffix)
                                       && UUID(uuidString: String(middle)) != nil, "unexpected staging name \(name)")
                }
                // Naming a staging file creates nothing.
                TestSupport.expect(!FileManager.default.fileExists(atPath: files.directory.path), "naming created files")
            }
        }
    }

    private static func testSweepKeepsWhatTheRuleKeeps() {
        withFiles { files in
            // Sweeping a directory that does not exist does nothing, and creates nothing.
            files.sweepStagingFiles { _ in false }
            TestSupport.expect(!FileManager.default.fileExists(atPath: files.directory.path), "sweep created the directory")

            let prefix = AtomicRecordFiles.stagingPrefix
            put("\(prefix)old.tmp", in: files, modified: Fixture.now - 3_600)
            put("\(prefix)recent.tmp", in: files, modified: Fixture.now - 10)
            put("\(prefix)future.tmp", in: files, modified: Fixture.now + 3_600)
            put("record.json", in: files, modified: Fixture.now - 3_600)
            // The rule sees each staging file's modification date, and keeps those within a minute of now.
            var seen: [TimeInterval] = []
            files.sweepStagingFiles { modified in
                seen.append(modified.timeIntervalSince(Fixture.now).rounded())
                return abs(modified.timeIntervalSince(Fixture.now)) < 60
            }
            TestSupport.expectEqual(seen.sorted(), [-3_600, -10, 3_600])
            TestSupport.expectEqual(fileNames(in: files), ["\(prefix)recent.tmp", "record.json"])
            // A rule that keeps nothing removes every staging file, and only those.
            files.sweepStagingFiles { _ in false }
            TestSupport.expectEqual(fileNames(in: files), ["record.json"])
        }
    }

    private static func testSweepMatchesTheSuffix() {
        let prefix = AtomicRecordFiles.stagingPrefix
        let names = ["\(prefix)a", "\(prefix)b.tmp", "c.tmp", "record.json"]
        // With ".tmp", only staging names that end with it are swept.
        withFiles(stagingSuffix: ".tmp") { files in
            for name in names { put(name, in: files, modified: Fixture.now - 3_600) }
            files.sweepStagingFiles { _ in false }
            TestSupport.expectEqual(fileNames(in: files), ["\(prefix)a", "c.tmp", "record.json"])
        }
        // With no suffix, every staging name is swept.
        withFiles(stagingSuffix: "") { files in
            for name in names { put(name, in: files, modified: Fixture.now - 3_600) }
            files.sweepStagingFiles { _ in false }
            TestSupport.expectEqual(fileNames(in: files), ["c.tmp", "record.json"])
        }
    }
}
