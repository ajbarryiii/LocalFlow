import Foundation

/// Runs the real replacement script with /bin/bash against throwaway app
/// directories, with a fake `open` that records what it was asked to launch.
enum UpdateInstallerTests {
    static func run() {
        testBackupIsAFreshSiblingOfTheApp()
        testSwapInstallsAndOpensNewApp()
        testFailedOpenAfterSwapKeepsNewApp()
        testFailedCleanupAfterSwapKeepsNewApp()
        testUnwritableFolderKeepsAndRelaunchesOldApp()
        testFailedMoveOfNewAppRestoresAndRelaunchesOldApp()
        testExistingBackupPathIsNeitherReplacedNorEntered()
        testWaitsForTheAppToQuit()
        testWritableFolderHasNoLocationProblem()
        testUnwritableFolderIsALocationProblem()
        testTranslocatedAppIsALocationProblem()
        testReadOnlyVolumeIsALocationProblem()
        testLocationMessagesPointToApplications()
    }

    // MARK: - Replacement script

    private static func testBackupIsAFreshSiblingOfTheApp() {
        let app = URL(fileURLWithPath: "/Applications/LocalFlow.app")
        let first = UpdateReplacement.backupURL(for: app)
        let second = UpdateReplacement.backupURL(for: app)
        TestSupport.expectEqual(first.deletingLastPathComponent().path, "/Applications")
        TestSupport.expect(first != app, "The backup must not be the app itself")
        TestSupport.expect(first != second, "Each update needs its own backup path")
        TestSupport.expect(first.pathExtension != "app", "The backup must not look like an app to Finder or Launch Services")
    }

    private static func testSwapInstallsAndOpensNewApp() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }

        let status = sandbox.runReplacement(openExitStatus: 0)

        TestSupport.expectEqual(status, 0)
        TestSupport.expectEqual(sandbox.appMarker, "new")
        TestSupport.expectEqual(sandbox.appEntries, ["Contents"])
        TestSupport.expect(!sandbox.exists(sandbox.backup), "The backup must be removed after a successful install")
        TestSupport.expect(!sandbox.exists(sandbox.staging), "The staging folder must be removed after a successful install")
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    // Regression: `a && b && open && rm || rollback` ran the rollback when
    // `open` failed, moving the backup inside the newly installed bundle.
    private static func testFailedOpenAfterSwapKeepsNewApp() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }

        let status = sandbox.runReplacement(openExitStatus: 1)

        TestSupport.expectEqual(status, 0)
        TestSupport.expectEqual(sandbox.appMarker, "new")
        TestSupport.expectEqual(sandbox.appEntries, ["Contents"])
        TestSupport.expect(!sandbox.exists(sandbox.backup), "The backup must still be removed when opening fails")
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    private static func testFailedCleanupAfterSwapKeepsNewApp() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.lockInsideStaging()

        let status = sandbox.runReplacement(openExitStatus: 0)

        TestSupport.expectEqual(status, 0)
        TestSupport.expectEqual(sandbox.appMarker, "new")
        TestSupport.expectEqual(sandbox.appEntries, ["Contents"])
        TestSupport.expect(!sandbox.exists(sandbox.backup), "The backup must be removed even if staging cleanup fails")
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    // Regression: when the first `mv` failed nothing was relaunched, so the
    // app simply disappeared.
    private static func testUnwritableFolderKeepsAndRelaunchesOldApp() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.setPermissions(0o555, sandbox.applications)

        let status = sandbox.runReplacement(openExitStatus: 0)

        TestSupport.expect(status != 0, "A failed install must report failure")
        TestSupport.expectEqual(sandbox.appMarker, "old")
        TestSupport.expectEqual(sandbox.appEntries, ["Contents"])
        TestSupport.expectEqual(sandbox.applicationsEntries, ["LocalFlow.app"])
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    private static func testFailedMoveOfNewAppRestoresAndRelaunchesOldApp() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        // The staged app cannot be renamed out of a read-only folder.
        sandbox.setPermissions(0o555, sandbox.staging)

        let status = sandbox.runReplacement(openExitStatus: 0)

        TestSupport.expect(status != 0, "A failed install must report failure")
        TestSupport.expectEqual(sandbox.appMarker, "old")
        TestSupport.expectEqual(sandbox.appEntries, ["Contents"])
        TestSupport.expectEqual(sandbox.applicationsEntries, ["LocalFlow.app"])
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    // `mv src dir` moves src into an existing dir, so an occupied backup path
    // must stop the install rather than nest the current app inside it.
    private static func testExistingBackupPathIsNeitherReplacedNorEntered() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.write("other", to: sandbox.backup.appendingPathComponent("marker"))

        let status = sandbox.runReplacement(openExitStatus: 0)

        TestSupport.expect(status != 0, "An occupied backup path must stop the install")
        TestSupport.expectEqual(sandbox.appMarker, "old")
        TestSupport.expectEqual(sandbox.appEntries, ["Contents"])
        TestSupport.expectEqual(sandbox.entries(of: sandbox.backup), ["marker"])
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    private static func testWaitsForTheAppToQuit() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }

        let runningApp = Process()
        runningApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        runningApp.arguments = ["30"]
        do {
            try runningApp.run()
        } catch {
            fatalError("Failed to start stand-in app process: \(error)")
        }

        let replacement = sandbox.startReplacement(openExitStatus: 0, waitingFor: runningApp.processIdentifier)
        Thread.sleep(forTimeInterval: 0.6)
        TestSupport.expect(replacement.isRunning, "The script must wait while the app is still running")
        TestSupport.expectEqual(sandbox.appMarker, "old")
        TestSupport.expectEqual(sandbox.opened, [])

        runningApp.terminate()
        runningApp.waitUntilExit()
        let status = Sandbox.wait(for: replacement)

        TestSupport.expectEqual(status, 0)
        TestSupport.expectEqual(sandbox.appMarker, "new")
        TestSupport.expectEqual(sandbox.opened, [sandbox.app.path])
    }

    // MARK: - Install location

    private static func testWritableFolderHasNoLocationProblem() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        TestSupport.expectEqual(UpdateInstallLocation.live.problem(forAppAt: sandbox.app), nil)
    }

    private static func testUnwritableFolderIsALocationProblem() {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.setPermissions(0o555, sandbox.applications)
        TestSupport.expectEqual(UpdateInstallLocation.live.problem(forAppAt: sandbox.app), .folderNotWritable)
    }

    private static func testTranslocatedAppIsALocationProblem() {
        let writable = UpdateInstallLocation(isOnReadOnlyVolume: { _ in false }, isWritableDirectory: { _ in true })
        let translocated = URL(fileURLWithPath: "/private/var/folders/zz/abc/T/AppTranslocation/0000-1111/d/LocalFlow.app")
        TestSupport.expectEqual(writable.problem(forAppAt: translocated), .translocated)
        TestSupport.expectEqual(UpdateInstallLocation.live.problem(forAppAt: translocated), .translocated)
    }

    private static func testReadOnlyVolumeIsALocationProblem() {
        let mountedDiskImage = UpdateInstallLocation(isOnReadOnlyVolume: { _ in true }, isWritableDirectory: { _ in false })
        let app = URL(fileURLWithPath: "/Volumes/LocalFlow/LocalFlow.app")
        TestSupport.expectEqual(mountedDiskImage.problem(forAppAt: app), .readOnlyVolume)
    }

    private static func testLocationMessagesPointToApplications() {
        let problems: [UpdateInstallLocationProblem] = [.translocated, .readOnlyVolume, .folderNotWritable]
        for problem in problems {
            let message = UpdateInstallLocation.message(for: problem)
            TestSupport.expect(message.contains("Applications"), "Message must tell the user to move the app to Applications: \(message)")
            TestSupport.expect(!message.contains("/"), "Message must not contain a path: \(message)")
        }
        TestSupport.expectEqual(Set(problems.map(UpdateInstallLocation.message(for:))).count, problems.count)
    }
}

/// Temporary `Applications` folder with an old app, a staged new app, and a
/// fake `open`.
private final class Sandbox {
    let root: URL
    let applications: URL
    let app: URL
    let backup: URL
    let staging: URL
    let stagedApp: URL
    private let openLog: URL
    private let fakeOpenDirectory: URL
    private var lockedDirectories: [URL] = []

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        app = applications.appendingPathComponent("LocalFlow.app", isDirectory: true)
        backup = UpdateReplacement.backupURL(for: app)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        stagedApp = staging.appendingPathComponent("LocalFlow.app", isDirectory: true)
        openLog = root.appendingPathComponent("open.log")
        fakeOpenDirectory = root.appendingPathComponent("bin", isDirectory: true)

        write("old", to: app.appendingPathComponent("Contents/marker"))
        write("new", to: stagedApp.appendingPathComponent("Contents/marker"))
    }

    var appMarker: String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    var appEntries: [String] { entries(of: app) }
    var applicationsEntries: [String] { entries(of: applications) }

    var opened: [String] {
        guard let log = try? String(contentsOf: openLog, encoding: .utf8) else { return [] }
        return log.split(separator: "\n").map(String.init)
    }

    func entries(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func write(_ text: String, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        } catch {
            fatalError("Failed to write test fixture: \(error)")
        }
    }

    func setPermissions(_ mode: Int, _ directory: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
        } catch {
            fatalError("Failed to change test fixture permissions: \(error)")
        }
        lockedDirectories.append(directory)
    }

    /// Leaves a file in staging that `rm -rf` cannot delete.
    func lockInsideStaging() {
        let locked = staging.appendingPathComponent("locked", isDirectory: true)
        write("stuck", to: locked.appendingPathComponent("file"))
        setPermissions(0o555, locked)
    }

    func runReplacement(openExitStatus: Int32) -> Int32 {
        Self.wait(for: startReplacement(openExitStatus: openExitStatus, waitingFor: Self.exitedProcessID()))
    }

    func startReplacement(openExitStatus: Int32, waitingFor processID: Int32) -> Process {
        let fakeOpen = fakeOpenDirectory.appendingPathComponent("open")
        write("#!/bin/bash\nprintf '%s\\n' \"$1\" >> '\(openLog.path)'\nexit \(openExitStatus)\n", to: fakeOpen)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        } catch {
            fatalError("Failed to make fake open executable: \(error)")
        }

        let replacement = UpdateReplacement(
            waitingForProcessID: processID,
            currentApp: app,
            stagedApp: stagedApp,
            stagingDirectory: staging,
            backup: backup,
            openCommand: fakeOpen.path
        )
        let process = Process()
        process.executableURL = UpdateReplacement.shellURL
        process.arguments = replacement.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            fatalError("Failed to start replacement script: \(error)")
        }
        return process
    }

    static func wait(for process: Process) -> Int32 {
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            fatalError("Replacement script did not finish")
        }
        return process.terminationStatus
    }

    /// The process ID of a process that has already exited and been reaped.
    static func exitedProcessID() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        do {
            try process.run()
        } catch {
            fatalError("Failed to start /usr/bin/true: \(error)")
        }
        process.waitUntilExit()
        return process.processIdentifier
    }

    func remove() {
        for directory in lockedDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        try? FileManager.default.removeItem(at: root)
    }
}
