import Foundation

/// URLs the host app accepts. Any app can open them, so a route only brings the app forward and
/// triggers a reconciliation pass; it never starts recording by itself.
enum HostURLRoute: Equatable, Sendable {
    case dictate

    /// Accepts exactly `<scheme>://dictate`, ignoring any query.
    init?(url: URL, scheme: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme.lowercased(),
              components.percentEncodedHost?.lowercased() == LocalFlowConfiguration.dictateHost,
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              components.port == nil, components.percentEncodedPath.isEmpty,
              components.percentEncodedFragment == nil else { return nil }
        self = .dictate
    }
}
