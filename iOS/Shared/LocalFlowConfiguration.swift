import Foundation

/// Identifiers injected into both Info.plists by the Makefile, so no Swift file hardcodes one.
struct LocalFlowConfiguration: Equatable, Sendable {
    static let appGroupIdentifierKey = "LocalFlowAppGroupIdentifier"
    static let urlSchemeKey = "LocalFlowURLScheme"
    static let universalLinkKey = "LocalFlowUniversalLink"
    static let dictateHost = "dictate"

    static let main = LocalFlowConfiguration(infoDictionary: Bundle.main.infoDictionary)

    var appGroupIdentifier: String
    var urlScheme: String
    /// The https URL the keyboard opens instead of the scheme (App Store builds), so iOS opens only
    /// the app verified for its domain; nil when the build sets none.
    var universalLink: URL?

    init(appGroupIdentifier: String, urlScheme: String, universalLink: URL? = nil) {
        self.appGroupIdentifier = appGroupIdentifier
        self.urlScheme = urlScheme
        self.universalLink = universalLink
    }

    /// A present but invalid universal link fails closed, like a bad scheme: it never falls back to it.
    init?(infoDictionary: [String: Any]?) {
        guard let appGroup = infoDictionary?[Self.appGroupIdentifierKey] as? String,
              let scheme = infoDictionary?[Self.urlSchemeKey] as? String,
              Self.isConcreteIdentifier(appGroup), Self.isValidScheme(scheme) else { return nil }
        var link: URL?
        if let value = infoDictionary?[Self.universalLinkKey] {
            guard let string = value as? String, let url = Self.universalLink(string) else { return nil }
            link = url
        }
        self.init(appGroupIdentifier: appGroup, urlScheme: scheme, universalLink: link)
    }

    /// What the keyboard opens to bounce to the host app: the universal link when the build sets one,
    /// else `<scheme>://dictate`.
    var dictateURL: URL? { universalLink ?? URL(string: "\(urlScheme)://\(Self.dictateHost)") }

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

    // https, a DNS host, a path below the root, and nothing else: no user, password, port, query or
    // fragment.
    private static func universalLink(_ value: String) -> URL? {
        guard isConcreteIdentifier(value), let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.percentEncodedHost, isHostName(host),
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              components.port == nil, components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
              components.percentEncodedPath.hasPrefix("/"), components.percentEncodedPath != "/" else { return nil }
        return URL(string: value)
    }

    // Letters, digits, "-" and "." only, as in an `applinks:` entitlement.
    private static func isHostName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "-.".unicodeScalars.contains($0))
        }
    }
}
