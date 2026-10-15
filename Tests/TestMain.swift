import Foundation

@main
struct LocalFlowTests {
    static func main() {
        AppNameTests.run()
        LocalParakeetTests.run()
        PrivacyPermissionTests.run()
        LocalDictationTests.run()
        SpokenNumberTests.run()
        PipelineHistoryStoreTests.run()
        ShortcutCoreTests.run()
        DoubleTapPromptTests.run()
        SemanticVersionTests.run()
        UpdateSignatureVerifierTests.run()
        UpdateManagerTests.run()
        DictationStatsTests.run()
        DictionaryTests.run()
        print("LocalFlowTests passed")
    }
}
