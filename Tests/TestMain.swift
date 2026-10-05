import Foundation

@main
struct FreeFlowTests {
    static func main() {
        LocalParakeetTests.run()
        PrivacyPermissionTests.run()
        LocalDictationTests.run()
        PipelineHistoryStoreTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        print("FreeFlowTests passed")
    }
}
