import Foundation

@main
struct LocalFlowIOSTests {
    static func main() {
        let suites: [(String, [TestCase])] = [
            ("BugReportEmail", BugReportEmailTests.tests),
            ("LocalFlowConfiguration", LocalFlowConfigurationTests.tests),
            ("DictationProtocol", DictationProtocolTests.tests),
            ("SharedDictationStore", SharedDictationStoreTests.tests),
            ("AtomicRecordFiles", AtomicRecordFilesTests.tests),
            ("HostReconciler", HostReconcilerTests.tests),
            ("HostRunRecovery", HostRunRecoveryTests.tests),
            ("HostWatchdog", HostWatchdogTests.tests),
            ("KeyboardPresenter", KeyboardPresenterTests.tests),
            ("KeyboardResultLedger", KeyboardResultLedgerTests.tests),
            ("KeyboardResultInbox", KeyboardResultInboxTests.tests),
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
            ("CapturePipeline", CapturePipelineTests.tests),
            ("CaptureTiming", CaptureTimingTests.tests),
            ("TranscriptionEngine", TranscriptionEngineTests.tests),
            ("DictionaryLibrary", DictionaryLibraryTests.tests),
            ("MicrophoneRoute", MicrophoneRouteTests.tests),
            ("CursorMotion", CursorMotionTests.tests),
            ("TextNavigator", TextNavigatorTests.tests),
            ("TrackpadSession", TrackpadSessionTests.tests),
            ("WordBoundaries", WordBoundariesTests.tests),
            ("DeleteRepeat", DeleteRepeatTests.tests),
            ("KeyboardLayout", KeyboardLayoutTests.tests),
            ("TypingRules", TypingRulesTests.tests),
            ("UndoTracker", UndoTrackerTests.tests),
            ("EditingCore", EditingCoreTests.tests),
            ("ExpectedDocument", ExpectedDocumentTests.tests),
            ("KeyboardEditor", KeyboardEditorTests.tests),
            ("SwipeEditor", SwipeEditorTests.tests),
            ("TouchRate", TouchRateTests.tests),
            ("FieldProfile", FieldProfileTests.tests),
            ("KeyTouchModel", KeyTouchModelTests.tests),
            ("BarControlRegions", BarControlRegionsTests.tests),
            ("SwipeCore", SwipeCoreTests.tests),
            ("TapCore", TapCoreTests.tests),
            ("AutocorrectSettings", AutocorrectSettingsTests.tests),
            ("AutocorrectEditor", AutocorrectEditorTests.tests),
            ("AutocorrectCore", AutocorrectCoreTests.tests),
            ("NeverCorrect", NeverCorrectTests.tests),
            ("ModelLoadSlot", ModelLoadSlotTests.tests),
            ("HostSessionLock", HostSessionLockTests.tests),
            ("HostSessionLockLatch", HostSessionLockLatchTests.tests),
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
