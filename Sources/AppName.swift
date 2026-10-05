import Foundation

enum AppName {
    static let displayName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "LocalFlow"

    static var supportDirectoryName: String {
        supportDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier, bundleName: displayName)
    }

    // Branding must not move existing history, audio, or the recording-state flag.
    static func supportDirectoryName(bundleIdentifier: String?, bundleName: String) -> String {
        switch bundleIdentifier {
        case "com.zachlatta.freeflow.dev": return "FreeFlow Dev"
        case "com.zachlatta.freeflow": return "FreeFlow"
        default: return bundleName
        }
    }

    static let releasesURL = URL(string: "https://api.github.com/repos/ajbarryiii/LocalFlow/releases?per_page=100")!
}
