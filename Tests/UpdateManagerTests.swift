import Foundation

enum UpdateManagerTests {
    static func run() {
        MainActor.assumeIsolated {
            testFailedUpdateIsPresented()
            testUnreplaceableLocationStopsUpdateBeforeDownload()
        }
    }

    private static let replaceableLocation = UpdateInstallLocation(
        isOnReadOnlyVolume: { _ in false },
        isWritableDirectory: { _ in true }
    )

    private static func release(downloadingFrom url: URL) -> GitHubRelease {
        GitHubRelease(
            tagName: "9.9.9",
            name: nil,
            body: nil,
            htmlUrl: "https://example.com/release",
            publishedAt: "2026-01-01T00:00:00Z",
            assets: [GitHubReleaseAsset(name: "LocalFlow-Test.dmg", browserDownloadUrl: url.absoluteString, size: 1)]
        )
    }

    private static func missingDMG() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-missing-\(UUID().uuidString).dmg")
    }

    // The download runs after the menu closes, so a failure that only sets
    // updateStatus is invisible. A refused signature takes the same path.
    @MainActor
    private static func testFailedUpdateIsPresented() {
        let manager = UpdateManager.shared
        let originalPresenter = manager.presentUpdateFailure
        let originalLocation = manager.installLocation
        defer {
            manager.presentUpdateFailure = originalPresenter
            manager.installLocation = originalLocation
        }

        var presented: [String] = []
        manager.presentUpdateFailure = { presented.append($0) }
        manager.installLocation = replaceableLocation
        manager.downloadAndInstall(release: release(downloadingFrom: missingDMG()))

        let deadline = Date().addingTimeInterval(10)
        while presented.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        TestSupport.expectEqual(presented.count, 1)
        TestSupport.expect(presented.first?.hasPrefix("Download failed:") == true, "Expected a download failure, got \(presented)")
        TestSupport.expectEqual(manager.updateStatus, .error(presented.first ?? ""))
    }

    // An app on a disk image, a translocated path, or in a folder it cannot
    // write to must say so up front instead of quitting and never coming back.
    @MainActor
    private static func testUnreplaceableLocationStopsUpdateBeforeDownload() {
        let manager = UpdateManager.shared
        let originalPresenter = manager.presentUpdateFailure
        let originalLocation = manager.installLocation
        defer {
            manager.presentUpdateFailure = originalPresenter
            manager.installLocation = originalLocation
        }

        var presented: [String] = []
        manager.presentUpdateFailure = { presented.append($0) }
        manager.installLocation = UpdateInstallLocation(isOnReadOnlyVolume: { _ in true }, isWritableDirectory: { _ in false })
        manager.downloadAndInstall(release: release(downloadingFrom: missingDMG()))

        let expected = UpdateInstallLocation.message(for: .readOnlyVolume)
        TestSupport.expectEqual(presented, [expected])
        TestSupport.expectEqual(manager.updateStatus, .error(expected))
        TestSupport.expectEqual(manager.downloadProgress, nil)

        // No download may start: it would fail and present a second alert.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        TestSupport.expectEqual(presented, [expected])
    }
}
