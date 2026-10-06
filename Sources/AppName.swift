import Foundation

enum AppName {
    static let displayName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "LocalFlow"

    static var supportDirectoryName: String {
        supportDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier, bundleName: displayName)
    }

    // Storage follows the bundle identifier so a display-name change never moves history,
    // audio, or the recording-state flag, and never shares them with upstream FreeFlow.
    static func supportDirectoryName(bundleIdentifier: String?, bundleName: String) -> String {
        switch bundleIdentifier {
        case "com.ajbarryiii.localflow.dev": return "LocalFlow Dev"
        case "com.ajbarryiii.localflow": return "LocalFlow"
        default: return bundleName
        }
    }

    static let releasesURL = URL(string: "https://api.github.com/repos/ajbarryiii/LocalFlow/releases?per_page=100")!
}
