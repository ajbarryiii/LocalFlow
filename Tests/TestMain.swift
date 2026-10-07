import Foundation

@main
struct LocalFlowTests {
    static func main() {
        AppNameTests.run()
        LocalParakeetTests.run()
        PrivacyPermissionTests.run()
        LocalDictationTests.run()
        PipelineHistoryStoreTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        UpdateSignatureVerifierTests.run()
        UpdateManagerTests.run()
        DictationStatsTests.run()
        print("LocalFlowTests passed")
    }
}
