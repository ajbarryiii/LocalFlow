import Foundation

enum EditTrackerTests {
    static var tests: [TestCase] {
        [
            ("changesAdvanceTheGeneration", testChangesAdvanceTheGeneration),
            ("ownCallbacksDoNotAdvanceIt", testOwnCallbacksDoNotAdvanceIt),
            ("callbacksOutsideTheWindowOrUnexplainedDo", testCallbacksOutsideTheWindowOrUnexplainedDo),
        ]
    }

    private static func testChangesAdvanceTheGeneration() {
        var edits = EditTracker()
        TestSupport.expectEqual(edits.generation, 0)
        edits.change()
        edits.change()
        TestSupport.expectEqual(edits.generation, 2)
    }

    private static func testOwnCallbacksDoNotAdvanceIt() {
        // As measured: our adjustTextPosition causes textWillChange/textDidChange about 10 ms later.
        var edits = EditTracker()
        edits.ownOperation(at: 10)
        TestSupport.expect(!edits.hostCallback(at: 10.01, fitsOwnOperation: true), "own callback counted as outside")
        TestSupport.expect(!edits.hostCallback(at: 10 + EditTracker.ownCallbackWindow, fitsOwnOperation: true),
                           "own callback at the window's end")
        TestSupport.expectEqual(edits.generation, 0)
    }

    private static func testCallbacksOutsideTheWindowOrUnexplainedDo() {
        var edits = EditTracker()
        // No own operation at all: a caret move by the host app.
        TestSupport.expect(edits.hostCallback(at: 5, fitsOwnOperation: true), "callback without an operation")
        edits.ownOperation(at: 10)
        // Within the window, but the context does not fit what we did.
        TestSupport.expect(edits.hostCallback(at: 10.05, fitsOwnOperation: false), "unexplained callback")
        // Too late to be ours.
        TestSupport.expect(edits.hostCallback(at: 10.6, fitsOwnOperation: true), "late callback")
        // Before the operation (clock order matters).
        TestSupport.expect(edits.hostCallback(at: 9.9, fitsOwnOperation: true), "earlier callback")
        TestSupport.expectEqual(edits.generation, 4)
    }
}
