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
        testBoundariesAtNonZeroOrigins()
        testMatcherReportsReleaseOrigin()
        testOnlyGenuineReleasesArm()
        testStampsKeepEventTimeState()
        testQueuedRecordingWork()
        testDiscardedAudioIsDeleted()
        testDelayedTapStillEndsCorrections()
        testCaptureStateIsPerAttempt()
        testCancelBeforeBackgroundStartEnters()
        testStaleFailureCannotHitNextCapture()
        testNormalStopKeepsQueuedBuffers()
        testIdleResetClearsPendingTap()
        testQueuedDeliveryBeforeReplacementIsAdmitted()
        testFailedSetupLeavesNextStartAlone()
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

    // MARK: - Review round 1

    /// #6: exact boundaries hold at non-zero origins (absolute deadlines).
    private static func testBoundariesAtNonZeroOrigins() {
        var detector = enabled()
        _ = detector.holdStarted(at: 100.0, fromIdle: true)
        TestSupport.expect(!detector.holdReleased(at: 100.3), "100.0 → 100.3 is exactly the minimum, not too short")
        detector = enabled()
        _ = detector.holdStarted(at: 10.0, fromIdle: true)
        TestSupport.expect(detector.holdReleased(at: 10.1), "Too short")
        TestSupport.expect(detector.holdStarted(at: 10.5, fromIdle: true), "10.1 → 10.5 is exactly the window, inclusive")
        detector = enabled()
        _ = detector.holdStarted(at: 1000.0, fromIdle: true)
        TestSupport.expect(detector.holdReleased(at: 1000.2999), "Just under the minimum is too short")
        TestSupport.expect(!detector.holdStarted(at: 1000.7000001, fromIdle: true), "Just past the window is a normal hold")
    }

    private static let commandF5 = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [.command], kind: .key,
                                                   preset: nil, exactModifierKeyCodes: [55])

    /// #3: the matcher reports how a Hold to Talk deactivation came about,
    /// without changing what it matches or emits.
    private static func testMatcherReportsReleaseOrigin() {
        let configuration = ShortcutConfiguration(hold: commandF5, toggle: .disabled)
        func reduce(_ state: ShortcutInputState, _ event: ShortcutInputEvent) -> ShortcutMatchResult {
            ShortcutMatcher.reduce(state: state, event: event, configuration: configuration)
        }
        let command = reduce(ShortcutInputState(), .modifierChanged(keyCode: 55, isDown: true))
        let held = reduce(command.state, .keyChanged(keyCode: 96, isDown: true, isRepeat: false))
        TestSupport.expectEqual(held.emittedEvents, [.holdActivated])
        TestSupport.expectEqual(held.holdReleaseOrigin, nil)

        let released = reduce(held.state, .keyChanged(keyCode: 96, isDown: false, isRepeat: false))
        TestSupport.expectEqual(released.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(released.holdReleaseOrigin, .keyReleased)

        let shifted = reduce(held.state, .modifierChanged(keyCode: 56, isDown: true))
        TestSupport.expectEqual(shifted.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(shifted.holdReleaseOrigin, .matchLost)

        let commandUp = reduce(held.state, .modifierChanged(keyCode: 55, isDown: false))
        TestSupport.expectEqual(commandUp.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(commandUp.holdReleaseOrigin, .matchLost)

        let reset = reduce(held.state, .backendReset)
        TestSupport.expectEqual(reset.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(reset.holdReleaseOrigin, .reset)

        let fn = ShortcutConfiguration(hold: .defaultHold, toggle: .disabled)
        let fnDown = ShortcutMatcher.reduce(state: ShortcutInputState(), event: .modifierChanged(keyCode: 63, isDown: true),
                                            configuration: fn)
        let fnUp = ShortcutMatcher.reduce(state: fnDown.state, event: .modifierChanged(keyCode: 63, isDown: false),
                                          configuration: fn)
        TestSupport.expectEqual(fnUp.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(fnUp.holdReleaseOrigin, .keyReleased)
    }

    /// Matcher, session controller and detector in the app's order: every event
    /// of an input is stamped on arrival, then routed.
    private final class Pipeline {
        let configuration: ShortcutConfiguration
        var state = ShortcutInputState()
        let controller = DictationShortcutSessionController()
        var detector = DoubleTapPromptDetector()
        var prompts: [Bool] = []
        var discards: [Bool] = []

        init(_ hold: ShortcutBinding) {
            configuration = ShortcutConfiguration(hold: hold, toggle: .disabled)
            detector.isEnabled = true
        }

        func feed(_ input: ShortcutInputEvent, at time: TimeInterval) {
            let result = ShortcutMatcher.reduce(state: state, event: input, configuration: configuration)
            state = result.state
            let idle = controller.activeMode == nil
            // Stamped on arrival, as the app does; an invalidation is queued in order.
            let arrived = result.deliveries(for: input).map { delivery -> (ShortcutDelivery, DoubleTapPromptDetector.Stamp?) in
                guard case .event(_, let origin) = delivery else { return (delivery, nil) }
                return (delivery, detector.stamp(at: time, appIdle: idle, releaseOrigin: origin))
            }
            for (delivery, stamp) in arrived {
                guard case .event(let event, _) = delivery, let stamp else {
                    detector.interrupt()
                    continue
                }
                let decision = detector.route(event, stamp: stamp, controller: controller, isTranscribing: false)
                if case .start? = decision.action { prompts.append(decision.markedPrompt) }
                if case .stop? = decision.action { discards.append(decision.discardTooShort) }
            }
        }
    }

    /// #3: only a genuine release of the shortcut's own key arms a double-tap.
    private static func testOnlyGenuineReleasesArm() {
        // A real double-tap of F5 while holding Command.
        let genuine = Pipeline(commandF5)
        genuine.feed(.modifierChanged(keyCode: 55, isDown: true), at: 0)
        genuine.feed(.keyChanged(keyCode: 96, isDown: true, isRepeat: false), at: 1.0)
        genuine.feed(.keyChanged(keyCode: 96, isDown: false, isRepeat: false), at: 1.1)
        genuine.feed(.keyChanged(keyCode: 96, isDown: true, isRepeat: false), at: 1.3)
        TestSupport.expectEqual(genuine.prompts, [false, true])
        TestSupport.expectEqual(genuine.discards, [true])

        // The review's case: Shift pressed and released while Command-F5 stays held.
        let shifted = Pipeline(commandF5)
        shifted.feed(.modifierChanged(keyCode: 55, isDown: true), at: 0)
        shifted.feed(.keyChanged(keyCode: 96, isDown: true, isRepeat: false), at: 1.0)
        shifted.feed(.modifierChanged(keyCode: 56, isDown: true), at: 1.1)
        shifted.feed(.modifierChanged(keyCode: 56, isDown: false), at: 1.2)
        TestSupport.expectEqual(shifted.discards, [true])  // still too short, so discarded
        TestSupport.expectEqual(shifted.prompts, [false, false])  // but never prompt mode

        // Command released first while F5 stays down, then pressed again.
        let commandFirst = Pipeline(commandF5)
        commandFirst.feed(.modifierChanged(keyCode: 55, isDown: true), at: 0)
        commandFirst.feed(.keyChanged(keyCode: 96, isDown: true, isRepeat: false), at: 1.0)
        commandFirst.feed(.modifierChanged(keyCode: 55, isDown: false), at: 1.1)
        commandFirst.feed(.modifierChanged(keyCode: 55, isDown: true), at: 1.2)
        TestSupport.expectEqual(commandFirst.prompts, [false, false])

        // Fn double-tap works; a backend reset in between is not a release.
        let fn = Pipeline(.defaultHold)
        fn.feed(.modifierChanged(keyCode: 63, isDown: true), at: 1.0)
        fn.feed(.modifierChanged(keyCode: 63, isDown: false), at: 1.1)
        fn.feed(.modifierChanged(keyCode: 63, isDown: true), at: 1.3)
        TestSupport.expectEqual(fn.prompts, [false, true])
        let reset = Pipeline(.defaultHold)
        reset.feed(.modifierChanged(keyCode: 63, isDown: true), at: 1.0)
        reset.feed(.backendReset, at: 1.1)
        reset.feed(.modifierChanged(keyCode: 63, isDown: true), at: 1.2)
        TestSupport.expectEqual(reset.prompts, [false, false])
    }

    /// #4: eligibility is the state when the event arrived, and a cancellation
    /// handled between arrival and handling clears the tap.
    private static func testStampsKeepEventTimeState() {
        // A press that arrives while transcribing, handled after the app went idle.
        var detector = enabled()
        let controller = DictationShortcutSessionController()
        let busyPress = detector.stamp(at: 10.0, appIdle: false)
        let started = detector.route(.holdActivated, stamp: busyPress, controller: controller, isTranscribing: false)
        TestSupport.expect(started.action == .start(.hold) && !started.markedPrompt, "It still starts a normal hold")
        let release = detector.stamp(at: 10.1, appIdle: false, releaseOrigin: .keyReleased)
        TestSupport.expect(detector.route(.holdDeactivated, stamp: release, controller: controller, isTranscribing: false)
                           .discardTooShort, "Too short")
        let next = detector.stamp(at: 10.2, appIdle: true)
        TestSupport.expect(!detector.route(.holdActivated, stamp: next, controller: controller, isTranscribing: false)
                           .markedPrompt, "A busy-time tap never arms")

        // A cancellation handled between a release's arrival and its handling.
        detector = enabled()
        let fresh = DictationShortcutSessionController()
        _ = detector.route(.holdActivated, stamp: detector.stamp(at: 20.0, appIdle: true), controller: fresh, isTranscribing: false)
        let lateRelease = detector.stamp(at: 20.1, appIdle: false, releaseOrigin: .keyReleased)
        detector.interrupt()  // Escape, queued ahead of the release
        _ = detector.route(.holdDeactivated, stamp: lateRelease, controller: fresh, isTranscribing: false)
        TestSupport.expect(!detector.route(.holdActivated, stamp: detector.stamp(at: 20.2, appIdle: true), controller: fresh,
                                           isTranscribing: false).markedPrompt, "The cancelled tap does not arm")

        // A cancellation between the second press's arrival and its handling.
        detector = enabled()
        let third = DictationShortcutSessionController()
        _ = detector.route(.holdActivated, stamp: detector.stamp(at: 30.0, appIdle: true), controller: third, isTranscribing: false)
        _ = detector.route(.holdDeactivated, stamp: detector.stamp(at: 30.1, appIdle: false, releaseOrigin: .keyReleased),
                           controller: third, isTranscribing: false)
        let secondPress = detector.stamp(at: 30.2, appIdle: true)
        detector.interrupt()
        TestSupport.expect(!detector.route(.holdActivated, stamp: secondPress, controller: third, isTranscribing: false)
                           .markedPrompt, "A stale press does not trigger prompt mode")
    }

    /// #2: work queued for a discarded recording is ignored, and a capture
    /// start that reaches the queue after the cancel creates no session, while
    /// the next recording's start is unaffected.
    private static func testQueuedRecordingWork() {
        var attempts = RecordingAttempts()
        let tap = attempts.begin()
        var queued: [() -> Void] = []
        var state = "Starting..."
        // The readiness callback has already queued its main-queue block.
        queued.append { if attempts.isCurrent(tap) { state = "Recording..." } }
        attempts.invalidate()  // the tap is discarded
        state = "Ready"
        queued.forEach { $0() }
        TestSupport.expectEqual(state, "Ready")
        let next = attempts.begin()  // the double-tap's second press
        TestSupport.expect(attempts.isCurrent(next) && !attempts.isCurrent(tap), "Only the new attempt is current")

        // A ticket reserved before the discard is void, wherever its start then is.
        let lifecycle = CaptureLifecycle()
        let lateStart = lifecycle.reserve()  // reserved on the main thread before dispatching
        lifecycle.cancel()                   // the discard
        let secondStart = lifecycle.reserve()
        TestSupport.expect(lifecycle.admit(ticket: lateStart, at: 1) == nil, "The discarded tap's late start creates no session")
        TestSupport.expect(lifecycle.admit(ticket: secondStart, at: 2) != nil, "The next recording starts normally")

        // Concurrent ordering: cancels from many threads void every earlier ticket.
        let concurrent = CaptureLifecycle()
        let tickets = (0..<200).map { _ in concurrent.reserve() }
        DispatchQueue.concurrentPerform(iterations: 50) { _ in concurrent.cancel() }
        TestSupport.expect(tickets.allSatisfy { concurrent.admit(ticket: $0, at: 0) == nil }, "Every earlier ticket is void")
        TestSupport.expect(concurrent.admit(ticket: concurrent.reserve(), at: 0) != nil, "A new ticket is valid")
    }

    /// Review 2 #1: the ticket is taken before dispatch, so a cancel that lands
    /// before the background block even enters the recorder still voids it.
    private static func testCancelBeforeBackgroundStartEnters() {
        let lifecycle = CaptureLifecycle()
        let sessionQueue = DispatchQueue(label: "test.session")
        let entered = DispatchSemaphore(value: 0)
        var admitted: UInt64?? = .none
        // beginRecording: reserve on the main thread, then dispatch the start.
        let ticket = lifecycle.reserve()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            entered.wait()  // the background block has not reached the recorder yet
            admitted = .some(sessionQueue.sync { lifecycle.admit(ticket: ticket, at: 1) })
            done.signal()
        }
        lifecycle.cancel()  // the tap is discarded first
        entered.signal()
        done.wait()
        TestSupport.expect(admitted != nil && admitted! == nil, "The cancelled start creates no session")
        TestSupport.expectEqual(lifecycle.currentCapture, nil)
    }

    /// Review 2 #2: on the session queue, cancel A, then start B, then A's queued
    /// failure. A's failure claims, tears down and calls back for nothing.
    private static func testStaleFailureCannotHitNextCapture() {
        let outputs = [NSObject(), NSObject()]
        defer { withExtendedLifetime(outputs) {} }
        let outputA = ObjectIdentifier(outputs[0]), outputB = ObjectIdentifier(outputs[1])
        let lifecycle = CaptureLifecycle()
        let sessionQueue = DispatchQueue(label: "test.session")
        let captureA = sessionQueue.sync { lifecycle.admit(ticket: lifecycle.reserve(), at: 1)! }
        lifecycle.attach(outputA, to: captureA)

        var teardowns: [UInt64] = [], deliveries: [UInt64] = []
        func reportFailure(_ capture: UInt64) {  // as AudioRecorder.reportRecordingFailure
            sessionQueue.async {
                guard lifecycle.claimFailure(capture) else { return }
                lifecycle.stop(capture) {}
                teardowns.append(capture)
                if lifecycle.mayDeliver(capture) { deliveries.append(capture) }
            }
        }
        lifecycle.cancel()
        sessionQueue.async { lifecycle.stop(lifecycle.currentCapture) {} }  // cancel A
        let ticketB = lifecycle.reserve()
        var captureB: UInt64?
        sessionQueue.async {  // start B
            captureB = lifecycle.admit(ticket: ticketB, at: 2)
            lifecycle.attach(outputB, to: captureB!)
        }
        reportFailure(captureA)  // A's failure, queued last
        sessionQueue.sync {}
        TestSupport.expect(teardowns.isEmpty && deliveries.isEmpty, "A's failure does nothing to B")
        TestSupport.expect(lifecycle.isCurrent(captureB!) && lifecycle.capture(for: outputB) == captureB, "B keeps recording")
        TestSupport.expectEqual(lifecycle.capture(for: outputA), nil)
        reportFailure(captureB!)  // B's own failure still works
        sessionQueue.sync {}
        TestSupport.expect(teardowns == [captureB!] && deliveries == [captureB!], "B's failure is handled once")
    }

    /// Review 2 #3: a normal stop keeps the stopping capture's output eligible
    /// until the buffers already queued have been written, then detaches it.
    private static func testNormalStopKeepsQueuedBuffers() {
        let outputs = [NSObject()]
        defer { withExtendedLifetime(outputs) {} }
        let output = ObjectIdentifier(outputs[0])
        let lifecycle = CaptureLifecycle()
        let capture = lifecycle.admit(ticket: lifecycle.reserve(), at: 1)!
        lifecycle.attach(output, to: capture)
        let sampleQueue = DispatchQueue(label: "test.samples")
        let held = DispatchSemaphore(value: 0)
        var written = 0
        sampleQueue.async { held.wait() }  // the sample queue is behind
        for _ in 0..<5 {
            sampleQueue.async { if lifecycle.capture(for: output) == capture { written += 1 } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { held.signal() }
        // stopRecording: the drain (sample queue and writer) runs before the detach.
        lifecycle.stop(capture) { sampleQueue.sync {} }
        TestSupport.expectEqual(written, 5)
        TestSupport.expectEqual(lifecycle.capture(for: output), nil)
        TestSupport.expectEqual(lifecycle.currentCapture, nil)
    }

    /// #1: the discarded file is deleted after the writer drains; only a
    /// complete, non-empty, error-free recording is kept.
    private static func testDiscardedAudioIsDeleted() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file() -> URL {
            let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
            try! Data("synthetic".utf8).write(to: url)
            return url
        }
        let cancelled = file()
        let discard = AudioFileDisposition.decide(url: cancelled, discard: true, recordedFrames: 4800, writeFailed: false)
        TestSupport.expect(discard.keep == nil && discard.delete == cancelled, "A cancelled recording is deleted")
        discard.removeDiscarded()
        TestSupport.expect(!FileManager.default.fileExists(atPath: cancelled.path), "and its file is gone")

        let kept = file()
        let stop = AudioFileDisposition.decide(url: kept, discard: false, recordedFrames: 4800, writeFailed: false)
        stop.removeDiscarded()
        TestSupport.expect(stop.keep == kept && FileManager.default.fileExists(atPath: kept.path), "A finished recording is kept")

        for (frames, failed) in [(Int64(0), false), (Int64(4800), true)] {
            let url = file()
            let empty = AudioFileDisposition.decide(url: url, discard: false, recordedFrames: frames, writeFailed: failed)
            empty.removeDiscarded()
            TestSupport.expect(empty.keep == nil && !FileManager.default.fileExists(atPath: url.path),
                               "An empty or failed recording is deleted")
        }
        TestSupport.expectEqual(AudioFileDisposition.decide(url: nil, discard: true, recordedFrames: 0, writeFailed: false),
                                AudioFileDisposition(keep: nil, delete: nil))
    }

    /// #5: a tap released before the shortcut start delay never started a
    /// recording, but its discard still ends any correction watch and releases
    /// retained audio, as starting would have.
    private static func testDelayedTapStillEndsCorrections() {
        let delayed = TooShortHoldDiscard.steps(isRecording: false)
        TestSupport.expect(delayed.stopCorrectionSuggestions && delayed.invalidateAttempt && !delayed.cancelCapture,
                           "Corrections end even without a recording")
        TestSupport.expectEqual(TooShortHoldDiscard.steps(isRecording: true),
                                TooShortHoldDiscard(stopCorrectionSuggestions: true, invalidateAttempt: true, cancelCapture: true))

        // With a live correction watch and retained audio from the previous dictation.
        let reader = FakeTextFieldReader("Note: ")
        reader.paste("cart")
        let watcher = CorrectionWatcher(reader: reader)
        var captured: CorrectionCapture?
        watcher.capture(expecting: watcher.currentGeneration) { captured = $0 }
        spin(timeout: 1) { captured != nil }
        watcher.start(captured!, pasted: "cart", dictationID: 7)
        spin(timeout: 1) { !reader.rangeReads.isEmpty }
        let store = CorrectionSessionStore<String>()
        let retained = store.retain("synthetic audio", bytes: 1, now: 0)!

        // What stopCorrectionSuggestions does: cancel the watch, discard the session.
        if delayed.stopCorrectionSuggestions {
            watcher.cancel()
            store.discard()
        }
        let reads = reader.rangeReads.count
        spin(timeout: 1.3)
        TestSupport.expectEqual(reader.rangeReads.count, reads)
        TestSupport.expectEqual(store.session(id: retained, now: 1), nil)
    }

    /// Recorder state is per admitted start: a late buffer or failure from a
    /// discarded tap never marks the next capture ready or failed.
    private static func testCaptureStateIsPerAttempt() {
        // Both outputs stay alive, as in a buffer callback (which retains its output).
        let outputs = [NSObject(), NSObject()]
        let tapOutput = ObjectIdentifier(outputs[0]), nextOutput = ObjectIdentifier(outputs[1])
        defer { withExtendedLifetime(outputs) {} }
        let lifecycle = CaptureLifecycle()
        let tap = lifecycle.admit(ticket: lifecycle.reserve(), at: 10)!
        lifecycle.attach(tapOutput, to: tap)
        TestSupport.expectEqual(lifecycle.capture(for: tapOutput), tap)
        TestSupport.expect(!lifecycle.claimReady(tap, rms: 0), "Silence is not ready")

        // The tap is discarded and the second press is admitted.
        lifecycle.cancel()
        lifecycle.stop(tap) {}
        let next = lifecycle.admit(ticket: lifecycle.reserve(), at: 10.4)!
        TestSupport.expectEqual(lifecycle.capture(for: tapOutput), nil)
        lifecycle.attach(nextOutput, to: next)
        TestSupport.expect(lifecycle.capture(for: nextOutput) == next && lifecycle.startTime == 10.4, "The new capture is current")
        TestSupport.expect(!lifecycle.claimReady(tap, rms: 0.3), "A late buffer from the tap never marks readiness")
        TestSupport.expect(lifecycle.claimReady(next, rms: 0.2), "Its own first sound marks it ready")
        TestSupport.expect(!lifecycle.claimReady(next, rms: 0.5), "Only once")
        TestSupport.expect(lifecycle.claimFailure(next) && !lifecycle.claimFailure(next), "One failure report per capture")
        TestSupport.expect(!lifecycle.mayDeliver(tap) && lifecycle.mayDeliver(next), "Deliveries only for the latest capture")

        // A new admitted start re-arms both.
        let third = lifecycle.admit(ticket: lifecycle.reserve(), at: 20)!
        TestSupport.expect(lifecycle.claimFailure(third), "Failure can be reported again")
    }

    /// Review 2 #4: tap, release, an idle backend reset, then a press within
    /// 0.4 s: the reset voids the pending tap.
    private static func testIdleResetClearsPendingTap() {
        let reset = Pipeline(.defaultHold)
        reset.feed(.modifierChanged(keyCode: 63, isDown: true), at: 1.0)
        reset.feed(.modifierChanged(keyCode: 63, isDown: false), at: 1.1)
        reset.feed(.backendReset, at: 1.2)  // no shortcut active, so no shortcut event
        reset.feed(.modifierChanged(keyCode: 63, isDown: true), at: 1.3)
        TestSupport.expectEqual(reset.prompts, [false, false])
        let matched = ShortcutMatcher.reduce(state: ShortcutInputState(), event: .backendReset,
                                             configuration: ShortcutConfiguration(hold: .defaultHold, toggle: .disabled))
        TestSupport.expect(matched.emittedEvents.isEmpty && matched.deliveries(for: .backendReset) == [.inputInvalidated],
                           "An idle reset is delivered as an invalidation")
    }

    /// Review 3 #1: a main-thread delivery queued by capture A runs after A was
    /// discarded and B reserved, but before B is admitted: it is a no-op.
    private static func testQueuedDeliveryBeforeReplacementIsAdmitted() {
        for cancelFirst in [true, false] {
            let lifecycle = CaptureLifecycle()
            let captureA = lifecycle.admit(ticket: lifecycle.reserve(), at: 1)!
            var delivered = 0
            // A's failure (or readiness) delivery is already on the main queue.
            DispatchQueue.main.async { if lifecycle.mayDeliver(captureA) { delivered += 1 } }
            if cancelFirst { lifecycle.cancel() }   // A is discarded
            let ticketB = lifecycle.reserve()       // B installs its callbacks and reserves
            spin(timeout: 0.1)                      // A's delivery runs; B is not admitted yet
            TestSupport.expectEqual(delivered, 0)
            let captureB = lifecycle.admit(ticket: ticketB, at: 2)
            TestSupport.expect(captureB.map(lifecycle.mayDeliver) == true, "B's own deliveries run once admitted")
            TestSupport.expect(!lifecycle.mayDeliver(captureA), "A's never do")
        }
        // Without a replacement, the current capture's deliveries still run.
        let lifecycle = CaptureLifecycle()
        let capture = lifecycle.admit(ticket: lifecycle.reserve(), at: 1)!
        TestSupport.expect(lifecycle.mayDeliver(capture), "The admitted capture delivers")
    }

    /// Review 3 #2: A's setup fails while the tap is discarded and B queues
    /// its start; A's cleanup happens inside A's own queue operation, so B's
    /// file URL survives.
    private static func testFailedSetupLeavesNextStartAlone() {
        struct SetupFailed: Error {}
        let lifecycle = CaptureLifecycle()
        let sessionQueue = DispatchQueue(label: "test.session")
        var fileURL: String?  // AudioRecorder.tempFileURL, session-queue only
        let inSetup = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finishedA = DispatchSemaphore(value: 0)
        let ticketA = lifecycle.reserve()
        var resultA: Result<UInt64, Error>?
        var cleanedUpA = false
        DispatchQueue.global().async {  // A's background start
            resultA = Result { try sessionQueue.sync {
                try lifecycle.start(ticket: ticketA, at: 1, setup: { _ in
                    inSetup.signal()
                    release.wait()  // setup still running
                    throw SetupFailed()
                }, cleanUp: { fileURL = nil; cleanedUpA = true }, cancelled: CancellationError())
            } }
            finishedA.signal()
        }
        inSetup.wait()
        lifecycle.cancel()  // the tap is discarded
        let ticketB = lifecycle.reserve()
        var captureB: UInt64?
        sessionQueue.async {  // B's start, queued behind A
            captureB = try? lifecycle.start(ticket: ticketB, at: 2, setup: { _ in fileURL = "B.wav" },
                                            cleanUp: { fileURL = nil }, cancelled: CancellationError())
        }
        release.signal()
        sessionQueue.sync {}
        finishedA.wait()
        if case .success = resultA! { TestSupport.expect(false, "A's setup failed") }
        TestSupport.expect(sessionQueue.sync { cleanedUpA }, "A cleaned up within its own start")
        TestSupport.expectEqual(sessionQueue.sync { fileURL }, "B.wav")
        TestSupport.expect(captureB.map(lifecycle.isCurrent) == true, "B is the current capture")
        TestSupport.expect(captureB.map(lifecycle.mayDeliver) == true, "and delivers")
    }

    private static func spin(timeout: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}
