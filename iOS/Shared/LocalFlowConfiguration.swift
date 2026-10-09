import Foundation

/// Identifiers injected into both Info.plists by the Makefile, so no Swift file hardcodes one.
struct LocalFlowConfiguration: Equatable, Sendable {
    static let appGroupIdentifierKey = "LocalFlowAppGroupIdentifier"
    static let urlSchemeKey = "LocalFlowURLScheme"
    static let dictateHost = "dictate"

    static let main = LocalFlowConfiguration(infoDictionary: Bundle.main.infoDictionary)

    var appGroupIdentifier: String
    var urlScheme: String

    init(appGroupIdentifier: String, urlScheme: String) {
        self.appGroupIdentifier = appGroupIdentifier
        self.urlScheme = urlScheme
    }

    init?(infoDictionary: [String: Any]?) {
        guard let appGroup = infoDictionary?[Self.appGroupIdentifierKey] as? String,
              let scheme = infoDictionary?[Self.urlSchemeKey] as? String,
              Self.isConcreteIdentifier(appGroup), Self.isValidScheme(scheme) else { return nil }
        self.init(appGroupIdentifier: appGroup, urlScheme: scheme)
    }

    /// `<scheme>://dictate`, which the keyboard opens to bounce to the host app.
    var dictateURL: URL? { URL(string: "\(urlScheme)://\(Self.dictateHost)") }

    // Rejects an empty value or an unexpanded `$(VARIABLE)` left by a broken build.
    private static func isConcreteIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("$(") && !value.contains { $0.isWhitespace }
    }

    // RFC 3986: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    private static func isValidScheme(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0))
        }
    }
}
