import Foundation

enum HostURLRouteTests {
    static var tests: [TestCase] {
        [
            ("acceptsDictate", testAcceptsDictate),
            ("ignoresQuery", testIgnoresQuery),
            ("rejectsEverythingElse", testRejectsEverythingElse),
            ("roundTripsConfigurationURL", testRoundTripsConfigurationURL),
        ]
    }

    private static let scheme = "synthetic-flow"

    private static func route(_ string: String) -> HostURLRoute? {
        HostURLRoute(url: URL(string: string)!, scheme: scheme)
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
}
