import Foundation

/// URLs the host app accepts. Any app can open them, so a route only brings the app forward and
/// triggers a reconciliation pass; it never starts recording by itself.
enum HostURLRoute: Equatable, Sendable {
    case dictate

    /// Accepts exactly `<scheme>://dictate`, and, when the build sets one, the universal link: https,
    /// its host in any case, exactly its path (no trailing slash). Any query is ignored.
    init?(url: URL, scheme: String, universalLink: URL? = nil) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              components.port == nil, components.percentEncodedFragment == nil else { return nil }
        if components.scheme?.lowercased() == scheme.lowercased(),
           components.percentEncodedHost?.lowercased() == LocalFlowConfiguration.dictateHost,
           components.percentEncodedPath.isEmpty {
            self = .dictate
        } else if let universalLink,
                  let expected = URLComponents(url: universalLink, resolvingAgainstBaseURL: false),
                  expected.scheme?.lowercased() == "https", components.scheme?.lowercased() == "https",
                  let host = expected.percentEncodedHost, !host.isEmpty, !expected.percentEncodedPath.isEmpty,
                  components.percentEncodedHost?.lowercased() == host.lowercased(),
                  components.percentEncodedPath == expected.percentEncodedPath {
            self = .dictate
        } else {
            return nil
        }
    }
}
