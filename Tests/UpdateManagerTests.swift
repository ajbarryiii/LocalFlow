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

    private static let release = GitHubRelease(
        tagName: "9.9.9",
        name: nil,
        body: nil,
        htmlUrl: "https://example.com/release",
        publishedAt: "2026-01-01T00:00:00Z",
        assets: [GitHubReleaseAsset(name: "LocalFlow-Test.dmg", browserDownloadUrl: "https://example.com/LocalFlow-Test.dmg", size: 1)]
    )

    /// Swaps in test doubles for the manager's shared state and restores it
    /// once any download the test started has finished.
    @MainActor
    private final class Harness {
        let manager = UpdateManager.shared
        var presented: [String] = []
        var downloads: [URL] = []
        private var taskFinished = false
        private let originalPresenter: (String) -> Void
        private let originalLocation: UpdateInstallLocation
        private let originalDownload: @MainActor (URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)

        init(location: UpdateInstallLocation) {
            originalPresenter = manager.presentUpdateFailure
            originalLocation = manager.installLocation
            originalDownload = manager.downloadBytes
            manager.cancelDownload()
            manager.presentUpdateFailure = { [unowned self] in self.presented.append($0) }
            manager.installLocation = location
            manager.downloadBytes = { [unowned self] request in
                self.downloads.append(request.url ?? URL(fileURLWithPath: "/"))
                throw URLError(.cannotConnectToHost)
            }
        }

        func finish() {
            if let task = manager.activeDownloadTask {
                Task { @MainActor [self] in
                    await task.value
                    self.taskFinished = true
                }
                let deadline = Date().addingTimeInterval(10)
                while !taskFinished && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                TestSupport.expect(taskFinished, "The update task must finish before the test ends")
            }
            manager.presentUpdateFailure = originalPresenter
            manager.installLocation = originalLocation
            manager.downloadBytes = originalDownload
        }
    }

    // The download runs after the menu closes, so a failure that only sets
    // updateStatus is invisible. A refused signature takes the same path.
    @MainActor
    private static func testFailedUpdateIsPresented() {
        let harness = Harness(location: replaceableLocation)
        harness.manager.downloadAndInstall(release: release)
        harness.finish()

        TestSupport.expectEqual(harness.downloads, [URL(string: "https://example.com/LocalFlow-Test.dmg")!])
        TestSupport.expectEqual(harness.presented.count, 1)
        TestSupport.expect(harness.presented.first?.hasPrefix("Download failed:") == true, "Expected a download failure, got \(harness.presented)")
        TestSupport.expectEqual(harness.manager.updateStatus, .error(harness.presented.first ?? ""))
    }

    // An app on a disk image, a translocated path, or in a folder it cannot
    // write to must say so up front instead of quitting and never coming back.
    @MainActor
    private static func testUnreplaceableLocationStopsUpdateBeforeDownload() {
        let harness = Harness(location: UpdateInstallLocation(isOnReadOnlyVolume: { _ in true }, isWritableDirectory: { _ in false }))
        harness.manager.downloadAndInstall(release: release)

        TestSupport.expect(harness.manager.activeDownloadTask == nil, "No update task may be started")
        harness.finish()

        let expected = UpdateInstallLocation.message(for: .readOnlyVolume)
        TestSupport.expectEqual(harness.downloads, [])
        TestSupport.expectEqual(harness.presented, [expected])
        TestSupport.expectEqual(harness.manager.updateStatus, .error(expected))
        TestSupport.expectEqual(harness.manager.downloadProgress, nil)
    }
}
