import Foundation

/// Double-tap Hold to Talk for prompt mode (DOUBLE-TAP.md). Times are
/// injected event timestamps in seconds; no clock is read.
enum DoubleTapPromptTests {
    static func run() {
        testTapThenPressStartsPrompt()
        testLatePressIsNormal()
        testLongFirstHoldNeitherArmsNorDiscards()
        testBoundaries()
        testSettingOffIsUnchanged()
        testOtherShortcutClears()
        testBusyDoesNotArm()
        testPromptHoldDoesNotArm()
        testTurningOffClears()
        testSessionControllerPromptHold()
    }

    private static func enabled() -> DoubleTapPromptDetector {
        var detector = DoubleTapPromptDetector()
        detector.isEnabled = true
        return detector
    }

    private static func testTapThenPressStartsPrompt() {
        var detector = enabled()
        TestSupport.expect(!detector.holdStarted(at: 10, fromIdle: true), "A first press is a normal hold")
        TestSupport.expect(detector.holdReleased(at: 10.1), "A 0.1 s hold is too short and discarded")
        TestSupport.expect(detector.holdStarted(at: 10.4, fromIdle: true), "A press 0.3 s later starts prompt mode")
        TestSupport.expect(!detector.holdReleased(at: 12), "The prompt dictation is long enough to transcribe")
    }

    private static func testLatePressIsNormal() {
        var detector = enabled()
        _ = detector.holdStarted(at: 10, fromIdle: true)
        TestSupport.expect(detector.holdReleased(at: 10.1), "Too short")
        TestSupport.expect(!detector.holdStarted(at: 10.51, fromIdle: true), "0.41 s after the release is a normal hold")
        // The pending tap expired; the late press does not leave one behind.
        TestSupport.expect(!detector.holdReleased(at: 11), "A normal hold")
        TestSupport.expect(!detector.holdStarted(at: 11.1, fromIdle: true), "Nothing pending")
    }

    private static func testLongFirstHoldNeitherArmsNorDiscards() {
        var detector = enabled()
        _ = detector.holdStarted(at: 10, fromIdle: true)
        TestSupport.expect(!detector.holdReleased(at: 10.5), "A 0.5 s hold is transcribed")
        TestSupport.expect(!detector.holdStarted(at: 10.6, fromIdle: true), "and does not arm a double-tap")
    }

    private static func testBoundaries() {
        // Exactly the minimum hold is not too short, and does not arm.
        var detector = enabled()
        _ = detector.holdStarted(at: 0, fromIdle: true)
        TestSupport.expect(!detector.holdReleased(at: DoubleTapPromptDetector.minimumHold), "Exactly 0.3 s is not too short")
        TestSupport.expect(!detector.holdStarted(at: 0.4, fromIdle: true), "and arms nothing")
        // A press exactly 0.4 s after the release still counts (inclusive).
        detector = enabled()
        _ = detector.holdStarted(at: -0.1, fromIdle: true)
        TestSupport.expect(detector.holdReleased(at: 0), "Too short")
        TestSupport.expect(detector.holdStarted(at: DoubleTapPromptDetector.window, fromIdle: true), "Exactly 0.4 s counts")
        TestSupport.expectEqual(DoubleTapPromptDetector.minimumHold, 0.3)
        TestSupport.expectEqual(DoubleTapPromptDetector.window, 0.4)
    }

    private static func testSettingOffIsUnchanged() {
        var detector = DoubleTapPromptDetector()
        TestSupport.expect(!detector.isEnabled, "Off by default")
        _ = detector.holdStarted(at: 10, fromIdle: true)
        TestSupport.expect(!detector.holdReleased(at: 10.05), "No minimum hold when off")
        TestSupport.expect(!detector.holdStarted(at: 10.1, fromIdle: true), "No prompt mode when off")
    }

    private static func testOtherShortcutClears() {
        var detector = enabled()
        _ = detector.holdStarted(at: 10, fromIdle: true)
        _ = detector.holdReleased(at: 10.1)
        detector.interrupt()  // toggle, Paste Again or Hold to Prompt between the tap and the press
        TestSupport.expect(!detector.holdStarted(at: 10.3, fromIdle: true), "Another shortcut clears the pending tap")

        // Another shortcut during the first hold: it never arms.
        detector = enabled()
        _ = detector.holdStarted(at: 20, fromIdle: true)
        detector.interrupt()
        TestSupport.expect(detector.holdReleased(at: 20.1), "Still too short")
        TestSupport.expect(!detector.holdStarted(at: 20.2, fromIdle: true), "but it does not arm")
    }

    private static func testBusyDoesNotArm() {
        // A hold that did not start from idle never arms.
        var detector = enabled()
        _ = detector.holdStarted(at: 10, fromIdle: false)
        _ = detector.holdReleased(at: 10.1)
        TestSupport.expect(!detector.holdStarted(at: 10.2, fromIdle: true), "Not from idle, no double-tap")
        // Busy at the second press: no prompt, and the pending tap is gone.
        detector = enabled()
        _ = detector.holdStarted(at: 20, fromIdle: true)
        _ = detector.holdReleased(at: 20.1)
        TestSupport.expect(!detector.holdStarted(at: 20.2, fromIdle: false), "Busy: no prompt")
        // Cancellation clears too.
        detector = enabled()
        _ = detector.holdStarted(at: 30, fromIdle: true)
        _ = detector.holdReleased(at: 30.1)
        detector.interrupt()
        TestSupport.expect(!detector.holdStarted(at: 30.2, fromIdle: true), "Cancelled")
    }

    private static func testPromptHoldDoesNotArm() {
        var detector = enabled()
        _ = detector.holdStarted(at: 10, fromIdle: true)
        _ = detector.holdReleased(at: 10.1)
        TestSupport.expect(detector.holdStarted(at: 10.2, fromIdle: true), "Prompt mode")
        TestSupport.expect(detector.holdReleased(at: 10.25), "A too-short prompt hold is discarded")
        TestSupport.expect(!detector.holdStarted(at: 10.3, fromIdle: true), "and never arms another tap")
    }

    private static func testTurningOffClears() {
        var detector = enabled()
        _ = detector.holdStarted(at: 10, fromIdle: true)
        _ = detector.holdReleased(at: 10.1)
        detector.isEnabled = false
        detector.isEnabled = true
        TestSupport.expect(!detector.holdStarted(at: 10.2, fromIdle: true), "Turning the setting off clears it")
    }

    /// The session controller still decides start and stop; a double-tap only
    /// tags the Hold to Talk session as a prompt, which stops on its own release.
    private static func testSessionControllerPromptHold() {
        let controller = DictationShortcutSessionController()
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expect(!controller.isPromptSession, "A normal hold")
        controller.markPromptSession()
        TestSupport.expect(controller.isPromptSession, "Tagged as a prompt")
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), .stop)
        TestSupport.expect(controller.isPromptSession, "The tag survives the stop for transcription")
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expect(!controller.isPromptSession, "The next session starts untagged")
    }
}
