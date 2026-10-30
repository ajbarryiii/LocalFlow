import Foundation

enum HostURLRouteTests {
    static var tests: [TestCase] {
        [
            ("acceptsDictate", testAcceptsDictate),
            ("ignoresQuery", testIgnoresQuery),
            ("rejectsEverythingElse", testRejectsEverythingElse),
            ("roundTripsConfigurationURL", testRoundTripsConfigurationURL),
            ("acceptsUniversalLink", testAcceptsUniversalLink),
            ("universalLinkIgnoresQuery", testUniversalLinkIgnoresQuery),
            ("rejectsOtherWebURLs", testRejectsOtherWebURLs),
            ("keepsSchemeWithUniversalLink", testKeepsSchemeWithUniversalLink),
            ("roundTripsUniversalLink", testRoundTripsUniversalLink),
        ]
    }

    private static let scheme = "synthetic-flow"
    private static let link = URL(string: "https://links.example/synthetic-flow/dictate")!

    private static func route(_ string: String) -> HostURLRoute? {
        HostURLRoute(url: URL(string: string)!, scheme: scheme)
    }

    private static func linkRoute(_ string: String) -> HostURLRoute? {
        HostURLRoute(url: URL(string: string)!, scheme: scheme, universalLink: link)
    }

    private static func testAcceptsDictate() {
        TestSupport.expectEqual(route("synthetic-flow://dictate"), .dictate)
        // Schemes and hosts are case-insensitive (RFC 3986).
        TestSupport.expectEqual(route("Synthetic-Flow://DICTATE"), .dictate)
    }

    private static func testIgnoresQuery() {
        TestSupport.expectEqual(route("synthetic-flow://dictate?"), .dictate)
        TestSupport.expectEqual(route("synthetic-flow://dictate?start=1&text=ignored"), .dictate)
    }

    private static func testRejectsEverythingElse() {
        let rejected = [
            "other-flow://dictate", "https://dictate", "synthetic-flow-x://dictate", "synthetic-flow://record",
            "synthetic-flow://dictate/", "synthetic-flow://dictate/now", "synthetic-flow:///dictate",
            "synthetic-flow:dictate", "synthetic-flow://user@dictate", "synthetic-flow://user:pw@dictate",
            "synthetic-flow://dictate:80", "synthetic-flow://dictate#start", "synthetic-flow://dict%61te",
            "synthetic-flow://dictate.example", "synthetic-flow://",
            // Without a configured universal link, no web URL is a route.
            "https://links.example/synthetic-flow/dictate",
        ]
        for string in rejected {
            TestSupport.expect(route(string) == nil, "accepted \(string)")
        }
        TestSupport.expectEqual(HostURLRoute(url: URL(string: "synthetic-flow://dictate")!, scheme: ""), nil)
    }

    private static func testRoundTripsConfigurationURL() {
        let configuration = LocalFlowConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: scheme)
        TestSupport.expectEqual(HostURLRoute(url: configuration.dictateURL!, scheme: configuration.urlScheme), .dictate)
    }

    private static func testAcceptsUniversalLink() {
        TestSupport.expectEqual(linkRoute("https://links.example/synthetic-flow/dictate"), .dictate)
        // The scheme and host are case-insensitive; the path is not.
        TestSupport.expectEqual(linkRoute("HTTPS://Links.EXAMPLE/synthetic-flow/dictate"), .dictate)
    }

    /// As for the scheme, a query carries nothing and is ignored, never read.
    private static func testUniversalLinkIgnoresQuery() {
        TestSupport.expectEqual(linkRoute("https://links.example/synthetic-flow/dictate?"), .dictate)
        TestSupport.expectEqual(linkRoute("https://links.example/synthetic-flow/dictate?start=1&text=ignored"), .dictate)
    }

    private static func testRejectsOtherWebURLs() {
        let rejected = [
            // Not https.
            "http://links.example/synthetic-flow/dictate", "ftp://links.example/synthetic-flow/dictate",
            "synthetic-flow://links.example/synthetic-flow/dictate",
            // Lookalike hosts.
            "https://links.example.evil.example/synthetic-flow/dictate", "https://evil-links.example/synthetic-flow/dictate",
            "https://www.links.example/synthetic-flow/dictate", "https://links.example./synthetic-flow/dictate",
            "https://links-example/synthetic-flow/dictate", "https://links.exampl/synthetic-flow/dictate",
            "https://evil.example/links.example/synthetic-flow/dictate", "https://links.example@evil.example/synthetic-flow/dictate",
            // Other paths: exact match only, so no trailing slash, case change, escape or extra segment.
            "https://links.example/synthetic-flow/dictate/", "https://links.example/synthetic-flow/Dictate",
            "https://links.example/synthetic-flow/dict%61te", "https://links.example/synthetic-flow/dictate/now",
            "https://links.example/synthetic-flow/dictatex", "https://links.example/synthetic-flow-dev/dictate",
            "https://links.example/synthetic-flow", "https://links.example/dictate", "https://links.example/",
            "https://links.example", "https://links.example//synthetic-flow/dictate",
            "https://links.example/x/../synthetic-flow/dictate",
            // Credentials, ports and fragments.
            "https://user@links.example/synthetic-flow/dictate", "https://user:pw@links.example/synthetic-flow/dictate",
            "https://links.example:443/synthetic-flow/dictate", "https://links.example:8443/synthetic-flow/dictate",
            "https://links.example/synthetic-flow/dictate#", "https://links.example/synthetic-flow/dictate#start",
        ]
        for string in rejected {
            TestSupport.expect(linkRoute(string) == nil, "accepted \(string)")
        }
    }

    private static func testKeepsSchemeWithUniversalLink() {
        TestSupport.expectEqual(linkRoute("synthetic-flow://dictate"), .dictate)
        TestSupport.expectEqual(linkRoute("other-flow://dictate"), nil)
        TestSupport.expectEqual(linkRoute("synthetic-flow://links.example/synthetic-flow/dictate"), nil)
    }

    private static func testRoundTripsUniversalLink() {
        let configuration = LocalFlowConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: scheme,
                                                   universalLink: link)
        TestSupport.expectEqual(
            HostURLRoute(url: configuration.dictateURL!, scheme: configuration.urlScheme,
                         universalLink: configuration.universalLink),
            .dictate)
    }
}
