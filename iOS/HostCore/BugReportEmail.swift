import Foundation

/// A user-reviewed support draft. Accepts only the recipient and non-identifying version/device
/// metadata; it has no access to dictation, settings, logs, files, or user content.
struct BugReportEmail {
    let recipient: String
    let appVersion: String
    let systemVersion: String
    let deviceModel: String

    let subject = "LocalFlow bug report"

    var body: String {
        """
        Steps to reproduce:
        1.

        Expected:

        What happened:

        App: LocalFlow \(appVersion)
        iOS: \(systemVersion)
        Device: \(deviceModel)
        """
    }

    var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "body", value: body)]
        // Some email handlers decode query strings as form data, where a literal '+' means space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
