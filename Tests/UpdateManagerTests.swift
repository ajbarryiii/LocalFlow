import Foundation

enum UpdateManagerTests {
    static func run() {
        MainActor.assumeIsolated {
            testFailedUpdateIsPresented()
        }
    }

    // The download runs after the menu closes, so a failure that only sets
    // updateStatus is invisible. A refused signature takes the same path.
    @MainActor
    private static func testFailedUpdateIsPresented() {
        let missingDMG = FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-missing-\(UUID().uuidString).dmg")
        let release = GitHubRelease(
            tagName: "9.9.9",
            name: nil,
            body: nil,
            htmlUrl: "https://example.com/release",
            publishedAt: "2026-01-01T00:00:00Z",
            assets: [GitHubReleaseAsset(name: "LocalFlow-Test.dmg", browserDownloadUrl: missingDMG.absoluteString, size: 1)]
        )

        let manager = UpdateManager.shared
        let originalPresenter = manager.presentUpdateFailure
        defer { manager.presentUpdateFailure = originalPresenter }

        var presented: [String] = []
        manager.presentUpdateFailure = { presented.append($0) }
        manager.downloadAndInstall(release: release)

        let deadline = Date().addingTimeInterval(10)
        while presented.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        TestSupport.expectEqual(presented.count, 1)
        TestSupport.expect(presented.first?.hasPrefix("Download failed:") == true, "Expected a download failure, got \(presented)")
        TestSupport.expectEqual(manager.updateStatus, .error(presented.first ?? ""))
    }
}
