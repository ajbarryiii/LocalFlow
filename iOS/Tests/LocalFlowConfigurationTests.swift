import Foundation

enum LocalFlowConfigurationTests {
    static var tests: [TestCase] {
        [
            ("readsBothIdentifiers", testReadsBothIdentifiers),
            ("rejectsMissingOrUnexpandedValues", testRejectsMissingOrUnexpandedValues),
            ("rejectsInvalidScheme", testRejectsInvalidScheme),
            ("buildsDictateURL", testBuildsDictateURL),
        ]
    }

    private static var validInfo: [String: Any] {
        ["LocalFlowAppGroupIdentifier": "group.example.synthetic", "LocalFlowURLScheme": "synthetic-flow"]
    }

    private static func testReadsBothIdentifiers() {
        TestSupport.expectEqual(
            LocalFlowConfiguration(infoDictionary: validInfo),
            LocalFlowConfiguration(appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow"))
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
}
