import Foundation

enum LocalFlowConfigurationTests {
    static var tests: [TestCase] {
        [
            ("readsBothIdentifiers", testReadsBothIdentifiers),
            ("rejectsMissingOrUnexpandedValues", testRejectsMissingOrUnexpandedValues),
            ("rejectsInvalidScheme", testRejectsInvalidScheme),
            ("buildsDictateURL", testBuildsDictateURL),
            ("readsUniversalLink", testReadsUniversalLink),
            ("rejectsInvalidUniversalLink", testRejectsInvalidUniversalLink),
            ("prefersUniversalLinkForDictateURL", testPrefersUniversalLinkForDictateURL),
        ]
    }

    private static var validInfo: [String: Any] {
        ["LocalFlowAppGroupIdentifier": "group.example.synthetic", "LocalFlowURLScheme": "synthetic-flow"]
    }

    private static let link = "https://links.example/synthetic-flow/dictate"

    private static func testReadsBothIdentifiers() {
        TestSupport.expectEqual(
            LocalFlowConfiguration(infoDictionary: validInfo),
            LocalFlowConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow"))
        TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: validInfo)?.universalLink, nil)
    }

    private static func testRejectsMissingOrUnexpandedValues() {
        TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: nil), nil)
        TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: [:]), nil)
        for key in validInfo.keys {
            var info = validInfo
            info[key] = nil
            TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: info), nil)
            info[key] = ""
            TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: info), nil)
            info[key] = 42
            TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: info), nil)
        }
        var info = validInfo
        info["LocalFlowAppGroupIdentifier"] = "$(APP_GROUP)"
        TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: info), nil)
        info["LocalFlowAppGroupIdentifier"] = "group.example synthetic"
        TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: info), nil)
    }

    private static func testRejectsInvalidScheme() {
        for scheme in ["$(URL_SCHEME)", "1flow", "synthetic flow", "synthetic://", "flów", "-flow"] {
            var info = validInfo
            info["LocalFlowURLScheme"] = scheme
            TestSupport.expect(LocalFlowConfiguration(infoDictionary: info) == nil, "accepted scheme \(scheme)")
        }
        var info = validInfo
        info["LocalFlowURLScheme"] = "Synthetic+flow.v2-dev"
        TestSupport.expect(LocalFlowConfiguration(infoDictionary: info) != nil, "rejected a valid scheme")
    }

    private static func testBuildsDictateURL() {
        let configuration = LocalFlowConfiguration(infoDictionary: validInfo)!
        TestSupport.expectEqual(configuration.dictateURL?.absoluteString, "synthetic-flow://dictate")
    }

    private static func testReadsUniversalLink() {
        var info = validInfo
        info["LocalFlowUniversalLink"] = link
        TestSupport.expectEqual(
            LocalFlowConfiguration(infoDictionary: info),
            LocalFlowConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow",
                                   universalLink: URL(string: link)!))
        for valid in ["https://links.example/d", "HTTPS://Links.Example/Flow/Dictate", "https://a.links.example/x/y/z/"] {
            info["LocalFlowUniversalLink"] = valid
            TestSupport.expectEqual(LocalFlowConfiguration(infoDictionary: info)?.universalLink?.absoluteString, valid)
        }
    }

    /// A present but invalid link fails the whole configuration closed, never falling back to the scheme.
    private static func testRejectsInvalidUniversalLink() {
        let invalid: [Any] = [
            "", " ", 42, ["https://links.example/dictate"], "$(UNIVERSAL_LINK)",
            "https://links.example/$(PATH)", "https://$(HOST)/dictate",
            "http://links.example/dictate", "synthetic-flow://dictate", "ftp://links.example/dictate",
            "links.example/dictate", "/synthetic-flow/dictate", "https:links.example/dictate",
            "https://links.example", "https://links.example/", "https:///dictate",
            "https://user@links.example/dictate", "https://user:pw@links.example/dictate",
            "https://links.example:443/dictate", "https://links.example:8443/dictate",
            "https://links.example/dictate?", "https://links.example/dictate?start=1",
            "https://links.example/dictate#", "https://links.example/dictate#start",
            "https://links example/dictate", "https://links.example/dic tate", " https://links.example/dictate",
            "https://links.example/dictate\n",
        ]
        for value in invalid {
            var info = validInfo
            info["LocalFlowUniversalLink"] = value
            TestSupport.expect(LocalFlowConfiguration(infoDictionary: info) == nil, "accepted universal link \(value)")
        }
    }

    private static func testPrefersUniversalLinkForDictateURL() {
        var info = validInfo
        info["LocalFlowUniversalLink"] = link
        let configuration = LocalFlowConfiguration(infoDictionary: info)!
        TestSupport.expectEqual(configuration.dictateURL?.absoluteString, link)
        TestSupport.expectEqual(configuration.urlScheme, "synthetic-flow")
        TestSupport.expectEqual(
            LocalFlowConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow")
                .dictateURL?.absoluteString,
            "synthetic-flow://dictate")
    }
}
