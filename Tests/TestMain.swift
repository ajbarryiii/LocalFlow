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
        LocalDictationTests.run()
        DictationVectorTests.run()
        SpokenNumberTests.run()
        PipelineHistoryStoreTests.run()
        ShortcutCoreTests.run()
        DoubleTapPromptTests.run()
        DictationCleanupStepsTests.run()
        SemanticVersionTests.run()
        UpdateSignatureVerifierTests.run()
        UpdateManagerTests.run()
        DictationStatsTests.run()
        DictionaryTests.run()
        StrengthProbeTests.run()
        print("LocalFlowTests passed")
    }
}
