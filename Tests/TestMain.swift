import Foundation

@main
struct LocalFlowTests {
    static func main() {
        AppNameTests.run()
        LocalParakeetTests.run()
        ParakeetModelStoreTests.run()
        ParakeetStreamingTests.run()
        ParakeetSilenceCompactorTests.run()
        PrivacyPermissionTests.run()
        PermissionPanelTests.run()
        LocalDictationTests.run()
        DictationVectorTests.run()
        SpokenNumberTests.run()
        PipelineHistoryStoreTests.run()
        ShortcutCoreTests.run()
        ShortcutStoreTests.run()
        SettingsKeysTests.run()
        ClipboardTransactionTests.run()
        DoubleTapPromptTests.run()
        DictationCleanupStepsTests.run()
        SemanticVersionTests.run()
        UpdateSignatureVerifierTests.run()
        UpdateInstallerTests.run()
        UpdateManagerTests.run()
        DictationStatsTests.run()
        DictionaryTests.run()
        DictionaryAppTests.run()
        StrengthProbeTests.run()
        OverlayWaveformMetricsTests.run()
        print("LocalFlowTests passed")
    }
}
