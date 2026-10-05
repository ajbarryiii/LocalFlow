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
        print("LocalFlowTests passed")
    }
}
