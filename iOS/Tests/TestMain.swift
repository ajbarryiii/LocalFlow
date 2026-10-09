import Foundation

@main
struct LocalFlowIOSTests {
    static func main() {
        let suites: [(String, [TestCase])] = [
            ("LocalFlowConfiguration", LocalFlowConfigurationTests.tests),
            ("DictationProtocol", DictationProtocolTests.tests),
            ("SharedDictationStore", SharedDictationStoreTests.tests),
            ("HostReconciler", HostReconcilerTests.tests),
            ("HostRunRecovery", HostRunRecoveryTests.tests),
            ("HostWatchdog", HostWatchdogTests.tests),
            ("KeyboardPresenter", KeyboardPresenterTests.tests),
            ("KeyboardResultLedger", KeyboardResultLedgerTests.tests),
            ("TextInsertionFormatter", TextInsertionFormatterTests.tests),
            ("LocalFlowSettings", LocalFlowSettingsTests.tests),
            ("DarwinNotifier", DarwinNotifierTests.tests),
            ("DictationSampleBuffer", DictationSampleBufferTests.tests),
            ("HostURLRoute", HostURLRouteTests.tests),
            ("RecentRequestIDs", RecentRequestIDsTests.tests),
            ("HostDictationSlot", HostDictationSlotTests.tests),
            ("HostSessionPolicy", HostSessionPolicyTests.tests),
            ("ComputePolicy", ComputePolicyTests.tests),
            ("HostSessionCore", HostSessionCoreTests.tests),
        ]
        var count = 0
        for (suite, tests) in suites {
            for test in tests {
                test.run()
                print("ok \(suite).\(test.name)")
                count += 1
            }
        }
        print("LocalFlowIOSTests passed (\(count) tests)")
    }
}
