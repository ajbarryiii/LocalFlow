import Foundation

enum AppNameTests {
    static func run() {
        TestSupport.expectEqual(AppName.supportDirectoryName(bundleIdentifier: "com.ajbarryiii.localflow.dev", bundleName: "Renamed Dev"), "LocalFlow Dev")
        TestSupport.expectEqual(AppName.supportDirectoryName(bundleIdentifier: "com.ajbarryiii.localflow", bundleName: "Renamed"), "LocalFlow")
        TestSupport.expectEqual(AppName.supportDirectoryName(bundleIdentifier: "org.example.synthetic", bundleName: "Synthetic App"), "Synthetic App")
        TestSupport.expectEqual(AppName.supportDirectoryName(bundleIdentifier: nil, bundleName: "Synthetic App"), "Synthetic App")
        TestSupport.expectEqual(AppName.releasesURL.host, "api.github.com")
        TestSupport.expectEqual(AppName.releasesURL.path, "/repos/ajbarryiii/LocalFlow/releases")
        TestSupport.expectEqual(AppName.releasesURL.query, "per_page=100")
        TestSupport.expectEqual(LocalParakeetCore.modelID, "localflow")
    }
}
