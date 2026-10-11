import Foundation

/// The keyboard's editing side as `KeyboardInput` drives it (ARCHITECTURE.md, "Typing model v2:
/// immediate execution"): touches through `KeyTouchModel` (each key bound to the field it touched down
/// in, or the first one identified after), keys through `KeyboardEditor` with the real `TypingState`,
/// the held delete key's timer, the trackpad through the real `TrackpadController` and
/// `TrackpadSession` once per frame, and every host callback (the trackpad's reports, focus changes,
/// the host app's own edits) delivered between frames.
enum KeyboardEditorTests {
    static var tests: [TestCase] {
        [
            ("keyRunsAtOnceAndEndsTheGesture", testKeyRunsAtOnceAndEndsTheGesture),
            ("lettersDuringAProbeRunAtOnceInOrder", testLettersDuringAProbeRunAtOnceInOrder),
            ("anyKeyTouchDownEndsSettlement", testAnyKeyTouchDownEndsSettlement),
            ("lateGestureReportIsNeverAnEcho", testLateGestureReportIsNeverAnEcho),
            ("lateReportShowingAnEarlierEditsStateIsNoEcho", testLateReportShowingAnEarlierEditsStateIsNoEcho),
            ("lateReportOfARetiredAdjustmentIsNoEcho", testLateReportOfARetiredAdjustmentIsNoEcho),
            ("cancelledProbeOwesEveryReport", testCancelledProbeOwesEveryReport),
            ("reportOfAnIgnoredJumpIsNoEchoOfTheKeyBefore", testReportOfAnIgnoredJumpIsNoEchoOfTheKeyBefore),
            ("slowHostLeavesAJumpInsideAnEmoji", testSlowHostLeavesAJumpInsideAnEmoji),
            ("jumpWatchOutlastsHidingAndReappearing", testJumpWatchOutlastsHidingAndReappearing),
            ("gestureFromInsideAClusterCasesFromTheField", testGestureFromInsideAClusterCasesFromTheField),
            ("completedGestureLeavesNoCopyOfTheText", testCompletedGestureLeavesNoCopyOfTheText),
            ("keyInsideAClusterIsUndoneByOneDelete", testKeyInsideAClusterIsUndoneByOneDelete),
            ("keysAfterReturnFollowTheFocus", testKeysAfterReturnFollowTheFocus),
            ("hidingLosesNothingTyped", testHidingLosesNothingTyped),
            ("dictationIsInsertedAtOnce", testDictationIsInsertedAtOnce),
            ("outsideCaretTapResetsDoubleSpace", testOutsideCaretTapResetsDoubleSpace),
            ("newFieldsFirstLetterIsCasedFromItsText", testNewFieldsFirstLetterIsCasedFromItsText),
            ("heldTouchesBindToTheFirstIdentifiedField", testHeldTouchesBindToTheFirstIdentifiedField),
            ("keysWithoutAnIdentityRunAtOnce", testKeysWithoutAnIdentityRunAtOnce),
            ("ownTypingReportsNeverDropKeys", testOwnTypingReportsNeverDropKeys),
            ("ownTypingReportsNeverEndTheNextGesture", testOwnTypingReportsNeverEndTheNextGesture),
            ("keyReleasedAfterTheFieldChangedNeverLands", testKeyReleasedAfterTheFieldChangedNeverLands),
            ("keyTouchedDownInTheNewFieldSurvivesItsFirstCallback", testKeyTouchedDownInTheNewFieldSurvivesItsFirstCallback),
            ("abortedJumpIsRepairedToABoundary", testAbortedJumpIsRepairedToABoundary),
            ("shiftFollowsAnEditTheProxyShowsLate", testShiftFollowsAnEditTheProxyShowsLate),
            ("deletingPastTheFieldStartKeepsItsCasing", testDeletingPastTheFieldStartKeepsItsCasing),
            ("deletingASelectionKeepsTheTextBefore", testDeletingASelectionKeepsTheTextBefore),
            ("keyAtTheLiftIsCasedWhereTheCaretLands", testKeyAtTheLiftIsCasedWhereTheCaretLands),
            ("keyDuringAProbeIsCasedWhereTheHostHasTheCaret", testKeyDuringAProbeIsCasedWhereTheHostHasTheCaret),
            ("reportOfAMoveAsIssuedIsNotTakenForOurKey", testReportOfAMoveAsIssuedIsNotTakenForOurKey),
            ("typingTorture", testTypingTorture),
        ]
    }

    /// A field whose context is all of it, and a probe across the emoji at its end that the host
    /// answers `callbackFrames` frames later.
    private static func emojiField(callbackFrames: Int = 3, unit: CursorOffsetUnit = .utf16) -> KeyboardHarness {
        KeyboardHarness(FakeTextHost(text: "Hi \u{1F44D}\u{1F3FD}", unit: unit, callbackFrames: callbackFrames))
    }

    // MARK: Immediate execution

    private static func testKeyRunsAtOnceAndEndsTheGesture() {
        // A key during settlement edits at once where the caret is now: after the move already issued
        // (the proxy applies adjustments and edits in order). The gesture ends on the spot: nothing more is
        // adjusted, however far its target was.
        let harness = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, lagFrames: 3, callbackFrames: 3))
        harness.gesture(dx: -30, events: 1)
        TestSupport.expect(harness.trackpad.isActive, "settled before the key")
        TestSupport.expectEqual(harness.document.host.caret, 16)
        let adjustments = harness.document.host.adjustmentCount
        harness.press(.character("x"))
        TestSupport.expect(!harness.trackpad.isActive, "the gesture kept settling after a key")
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
        TestSupport.expectEqual(harness.document.host.adjustmentCount, adjustments)
        // With the finger still down, too.
        let dragging = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16))
        dragging.gesture(dx: -30, events: 1, lift: false)
        dragging.press(.character("y"))
        TestSupport.expect(!dragging.trackpad.isActive, "the gesture went on after a key")
        let after = dragging.document.host.adjustmentCount
        dragging.drag(dx: -50, dy: 0)
        dragging.settle()
        TestSupport.expectEqual(dragging.document.host.adjustmentCount, after)
        TestSupport.expectEqual(dragging.document.text, "Alpha beta gaymma")
    }

    private static func testLettersDuringAProbeRunAtOnceInOrder() {
        // The round-6 review's P1 was Shift overtaking letters queued behind a probe. Nothing is queued:
        // each key edits as it is typed, cased by the shift of that moment, and the probe's outcome is
        // abandoned. Where a key typed as a probe crosses a cluster lands is the host's (it may be inside
        // the cluster: the accepted residual), but every key is there, once, in order, together.
        for unit in [CursorOffsetUnit.utf16, .grapheme] {
            let harness = emojiField(unit: unit)
            harness.gesture(dx: -10, events: 1)
            TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
            harness.press(.character("a"))
            TestSupport.expect(!harness.trackpad.isActive, "the probe kept the gesture going")
            harness.press(.shift)
            harness.press(.character("b"))
            TestSupport.expect(harness.document.text.contains("aB"), "keys not typed at once: \(harness.document.text)")
            let adjustments = harness.document.host.adjustmentCount
            harness.settle()
            TestSupport.expectEqual(harness.document.host.adjustmentCount, adjustments)
            TestSupport.expectEqual(harness.document.text.replacingOccurrences(of: "aB", with: ""), "Hi \u{1F44D}\u{1F3FD}")
        }
    }

    /// A gesture whose target lies past an emoji in a field whose unit is not known yet, with lagging
    /// adjustments and reports: its first move is in flight at the lift, and it has more to do after it
    /// (a probe across the emoji, then the rest).
    private static func settlingGesture() -> KeyboardHarness {
        let harness = KeyboardHarness(FakeTextHost(text: "ab\u{1F44D}cdef", unit: .utf16, lagFrames: 3, callbackFrames: 3))
        harness.gesture(dx: -60, events: 1)
        TestSupport.expect(harness.trackpad.isActive, "settled before the key")
        return harness
    }

    private static func testAnyKeyTouchDownEndsSettlement() {
        // The round-9 review's P1: Shift and layer keys never ended settlement, and a character only at its
        // release, so a gesture report arriving after Shift moved the caret on before the letter. Any
        // key's touch-down ends the gesture; nothing is adjusted after it, and the letter lands where the
        // caret was once what was already issued landed.
        let untouched = settlingGesture()
        let issuedAtLift = untouched.document.host.adjustmentCount
        untouched.settle()
        TestSupport.expect(untouched.document.host.adjustmentCount > issuedAtLift, "the gesture had nothing left to do")
        let cases: [(name: String, before: [KeyAction], letter: KeyAction, typed: String)] = [
            ("shift", [.shift], .character("x"), "X"),
            ("layer", [.layer(.numbers)], .character("1"), "1"),
        ]
        for testCase in cases {
            let harness = settlingGesture()
            for key in testCase.before { harness.tap(key) }
            TestSupport.expect(!harness.trackpad.isActive, "\(testCase.name) did not end the gesture")
            let adjustments = harness.document.host.adjustmentCount
            // The gesture's reports arrive after the key.
            harness.frames(12)
            TestSupport.expectEqual(harness.document.host.adjustmentCount, adjustments)
            let caret = harness.document.host.caret
            harness.tap(testCase.letter)
            harness.settle()
            TestSupport.expectEqual(harness.document.host.adjustmentCount, adjustments)
            var expected = Array("ab\u{1F44D}cdef".utf16)
            expected.insert(contentsOf: Array(testCase.typed.utf16), at: caret)
            TestSupport.expectEqual(harness.document.text, String(decoding: expected, as: UTF16.self))
        }
        // A character held across several frames of settlement: the gesture ends at its touch-down, and
        // it inserts at its release where the caret was.
        let held = settlingGesture()
        let finger = held.touchDown(.character("q"))
        TestSupport.expect(!held.trackpad.isActive, "a character's touch-down did not end the gesture")
        let adjustments = held.document.host.adjustmentCount
        held.frames(12)
        TestSupport.expectEqual(held.document.text, "ab\u{1F44D}cdef")
        let caret = held.document.host.caret
        held.touchUp(finger)
        held.settle()
        TestSupport.expectEqual(held.document.host.adjustmentCount, adjustments)
        var expected = Array("ab\u{1F44D}cdef".utf16)
        expected.insert(contentsOf: Array("q".utf16), at: caret)
        TestSupport.expectEqual(held.document.text, String(decoding: expected, as: UTF16.self))
        // Shift and a layer key pressed without a touch (VoiceOver) end it too.
        for key in [KeyAction.shift, .layer(.numbers)] {
            let direct = settlingGesture()
            direct.press(key)
            TestSupport.expect(!direct.trackpad.isActive, "\(key) without a touch did not end the gesture")
        }
        // Delete and Return too.
        for key in [KeyAction.delete, .returnKey] {
            let harness = settlingGesture()
            let finger = harness.touchDown(key)
            TestSupport.expect(!harness.trackpad.isActive, "\(key) did not end the gesture at its touch-down")
            harness.touchUp(finger)
        }
    }

    private static func testLateGestureReportIsNeverAnEcho() {
        // The round-9 review's P2: move to "One|Two", Space; the gesture's delayed report showed "One |Two",
        // which is exactly what the space left, and was taken for its echo, so the second Space typed
        // "One. Two". A report a gesture still owes is never an echo: it resets the timing.
        let harness = KeyboardHarness(FakeTextHost(text: "OneTwo", unit: .utf16, callbackFrames: 6))
        harness.gesture(dx: -30, events: 1)
        TestSupport.expectEqual(harness.document.host.caret, 3)
        harness.tap(.space)
        let outcomes = harness.outcomes.count
        harness.frames(10)
        TestSupport.expectEqual(Array(harness.outcomes.dropFirst(outcomes)), [.outside])
        harness.tap(.space)
        TestSupport.expectEqual(harness.document.text, "One  Two")
        // WebKit reports an adjustment twice; the second report, after more typing, is no echo either.
        var webKit = FakeTextHost(text: "OneTwo", unit: .grapheme, callbackFrames: 6)
        webKit.reportsAsIssuedFirst = true
        let twice = KeyboardHarness(webKit)
        twice.gesture(dx: -30, events: 1)
        twice.tap(.space)
        let before = twice.outcomes.count
        for _ in 0 ..< 20 where twice.outcomes.count == before { twice.frame() }
        twice.tap(.character("a"))
        twice.tap(.space)
        let afterFirst = twice.outcomes.count
        for _ in 0 ..< 20 where twice.outcomes.count == afterFirst { twice.frame() }
        TestSupport.expectEqual(Array(twice.outcomes.dropFirst(before)), [.outside, .outside])
        twice.tap(.space)
        TestSupport.expectEqual(twice.document.text, "One a  Two")
        // Once the report has come, an edit made after it is echoed as before (a host that echoes, known
        // from an earlier gesture to report each adjustment once; one not known yet may owe a second
        // report, and until then a matching echo counts as an outside change).
        let echoing = KeyboardHarness(FakeTextHost(text: "OneTwo", unit: .utf16, callbackFrames: 6), editCallbackDelay: 12)
        echoing.gesture(dx: -10, events: 1)
        echoing.settle()
        echoing.gesture(dx: -20, events: 1)
        echoing.tap(.space)
        let start = echoing.outcomes.count
        echoing.settle()
        TestSupport.expectEqual(Array(echoing.outcomes.dropFirst(start)), [.outside, .ownEdit])
    }

    private static func testLateReportShowingAnEarlierEditsStateIsNoEcho() {
        // Found by the typing torture (seed 315): "a", "l", a gesture out and back, then a delete, which
        // brought the field back to exactly what "a" had left. The gesture's late reports showed that, and
        // the first was taken for the echo of "a", made before the gesture. Once a gesture has finished,
        // nothing is an echo until its reports have come.
        let harness = KeyboardHarness(FakeTextHost(text: "One", unit: .utf16, callbackFrames: 20))
        harness.type("al")
        let finger = harness.beginGesture()
        harness.drag(dx: -10, dy: 0)
        harness.frames(2)
        harness.drag(dx: 10, dy: 0)
        harness.touchUp(finger)
        TestSupport.expectEqual(harness.document.host.caret, 5)
        harness.tap(.delete)
        TestSupport.expectEqual(harness.document.text, "Onea")
        let start = harness.outcomes.count
        harness.settle()
        let outcomes = Array(harness.outcomes.dropFirst(start))
        TestSupport.expect(!outcomes.isEmpty && outcomes.allSatisfy { $0 == .outside }, "a late report taken as ours: \(outcomes)")
    }

    private static func testLateReportOfARetiredAdjustmentIsNoEcho() {
        // A report later than `syncTimeout`: its expectation is retired and the gesture settles without it,
        // but the host still sends it, showing exactly what the space typed meanwhile left. It is no echo.
        let harness = KeyboardHarness(FakeTextHost(text: "OneTwo", unit: .utf16, callbackFrames: 45))
        harness.gesture(dx: -30, events: 1)
        harness.frames(40)
        TestSupport.expect(!harness.trackpad.isActive, "the gesture waited past its time")
        TestSupport.expectEqual(harness.document.host.caret, 3)
        harness.tap(.space)
        let start = harness.outcomes.count
        harness.frames(10)
        TestSupport.expectEqual(Array(harness.outcomes.dropFirst(start)), [.outside])
        harness.tap(.space)
        TestSupport.expectEqual(harness.document.text, "One  Two")
    }

    private static func testCancelledProbeOwesEveryReport() {
        // The round-10 review's P2: a probe and the rollback its cancellation issued owe four WebKit reports,
        // but only two were counted. After two had come, the third, showing what the Space typed meanwhile
        // left, was taken for its echo, and the next Space typed a period. Every report is counted, per
        // adjustment and per report the host sends, whatever settles.
        var host = FakeTextHost(text: "Hi \u{1F44D}\u{1F3FD}", unit: .grapheme, callbackFrames: 3)
        host.reportsAsIssuedFirst = true
        let harness = KeyboardHarness(host)
        let finger = harness.beginGesture()
        harness.drag(dx: -10, dy: 0)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        harness.cancelTouch(finger)
        TestSupport.expectEqual(harness.document.host.adjustmentCount, 2)
        let start = harness.outcomes.count
        func nextReport() {
            let count = harness.outcomes.count
            for _ in 0 ..< 20 where harness.outcomes.count == count { harness.frame() }
        }
        harness.tap(.character("a"))
        nextReport()
        nextReport()
        harness.tap(.space)
        nextReport()
        harness.tap(.space)
        nextReport()
        harness.settle()
        TestSupport.expectEqual(Array(harness.outcomes.dropFirst(start)), [.outside, .outside, .outside, .outside])
        TestSupport.expectEqual(harness.document.text, "Hi \u{1F44D}\u{1F3FD}a  ")
    }

    private static func testReportOfAnIgnoredJumpIsNoEchoOfTheKeyBefore() {
        // Found by the typing torture (seed 8527): Space, then a gesture whose jump past the last line the
        // host ignored, ended by Shift. Its report showed the field unchanged, exactly as the Space left it,
        // and was taken for the Space's echo, so the shift the user turned off stayed off. While a finished
        // gesture owes reports, nothing is an echo: the report resets the timing and the shift follows the
        // text again.
        let harness = KeyboardHarness(FakeTextHost(text: "One", unit: .utf16, callbackFrames: 6), autocapitalization: .words)
        harness.tap(.space)
        TestSupport.expectEqual(harness.editor.typing.shift, .once)
        harness.gesture(dy: 40, events: 1)
        TestSupport.expect(harness.document.host.adjustmentCount > 0, "nothing issued")
        harness.tap(.shift)
        TestSupport.expectEqual(harness.editor.typing.shift, .off)
        let start = harness.outcomes.count
        harness.settle()
        let outcomes = Array(harness.outcomes.dropFirst(start))
        TestSupport.expect(!outcomes.isEmpty && !outcomes.contains(.ownEdit), "a report taken for the Space's echo: \(outcomes)")
        TestSupport.expectEqual(harness.editor.typing.shift, .once)
    }

    /// A UIKit-like field whose reports come after the trackpad's `syncTimeout` (outside its guarantees),
    /// where one jump past the end of the sentence the proxy shows lands one unit into the emoji after it.
    private static func slowJumpIntoAnEmoji() -> KeyboardHarness {
        KeyboardHarness(FakeTextHost(text: "Ab. Cd. \u{1F44D} Ef", caret: 5, unit: .utf16, model: .uikit,
                                     callbackFrames: 40, provisionalContext: true))
    }

    private static func testSlowHostLeavesAJumpInsideAnEmoji() {
        // Expected risk, pinned (ARCHITECTURE.md: reports later than `syncTimeout` are outside the trackpad's
        // guarantees). The jump's report comes after the session gave up on it, from a provisional answer
        // showing the caret at the window's edge, so the gesture settles with the caret between the halves
        // of 👍. A letter typed then lands there, visibly, and one delete restores the field.
        let original = Array("Ab. Cd. \u{1F44D} Ef".utf16)
        let harness = slowJumpIntoAnEmoji()
        harness.gesture(dy: 20, events: 1)
        harness.settle()
        TestSupport.expectEqual(harness.document.host.caret, 9)
        TestSupport.expect(harness.document.host.caretSplitsSurrogatePair, "the accepted risk changed: the caret is not inside the emoji")
        harness.tap(.character("x"))
        var inside = original
        inside.insert(contentsOf: Array("x".utf16), at: 9)
        TestSupport.expectEqual(harness.document.host.units, inside)
        harness.tap(.delete)
        harness.settle()
        TestSupport.expectEqual(harness.document.host.units, original)
        // A letter at the lift, the jump's outcome still unknown: typed at once where the host has the caret,
        // inside the emoji, and one delete restores the field.
        let atLift = slowJumpIntoAnEmoji()
        atLift.gesture(dy: 20, events: 1)
        atLift.tap(.character("x"))
        TestSupport.expect(!atLift.trackpad.isActive, "the key did not end the gesture")
        TestSupport.expectEqual(atLift.document.host.units, inside)
        atLift.tap(.delete)
        atLift.settle()
        TestSupport.expectEqual(atLift.document.host.units, original)
    }

    private static func testJumpWatchOutlastsHidingAndReappearing() {
        // Found by the typing torture (seeds 6961, 9549): a jump past the window's edge stopped inside a
        // hidden emoji, the keyboard hid, and it reappeared before the jump's report; the reappearance ended
        // the watch, and the caret stayed inside the emoji. In the same field the text-free watch goes on.
        var host = FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16, window: 2, callbackFrames: 30)
        host.provisionalContext = true
        let harness = KeyboardHarness(host)
        let finger = harness.beginGesture()
        var split = false
        for _ in 0 ..< 30 where !split {
            harness.drag(dx: 0, dy: 1)
            split = !harness.document.host.caretIsOnBoundary
        }
        TestSupport.expect(split, "the jump never stopped inside the emoji")
        harness.touchUp(finger)
        harness.hide()
        harness.frames(4)
        harness.show()
        harness.settle()
        TestSupport.expect(harness.document.host.caretIsOnBoundary, "left inside the emoji at \(harness.document.host.caret)")
        TestSupport.expectEqual(harness.document.text, "ab\u{1F44D}\u{1F3FD}cd\nnext line")
    }

    private static func testGestureFromInsideAClusterCasesFromTheField() {
        // Found by the typing torture (seed 2083): a key the accepted residual left between "e" and its
        // accent; a gesture began there and the host ignored its adjustments from inside the cluster, so the
        // boundary the gesture assumed was not where the caret was. A key at the lift is cased from the
        // field's own text before the caret, not from that assumed landing.
        let harness = KeyboardHarness(FakeTextHost(text: "Done. e\u{301}", caret: 7, unit: .grapheme, callbackFrames: 3),
                                      autocapitalization: .sentences)
        harness.gesture(dx: -10, events: 1)
        TestSupport.expect(harness.trackpad.isActive, "settled before the key")
        harness.tap(.character("x"))
        harness.settle()
        TestSupport.expectEqual(harness.document.host.units, Array("Done. ex\u{301}".utf16))
    }

    private static func testCompletedGestureLeavesNoCopyOfTheText() {
        // Only a key that ends a gesture needs its landing, which the proxy may not show yet. A gesture that
        // settles on its own has been heard from: the typing tail keeps no copy of the field's text.
        let harness = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, callbackFrames: 2))
        harness.gesture(dx: -30, events: 1)
        harness.settle()
        TestSupport.expectEqual(harness.document.host.caret, 13)
        TestSupport.expectEqual(harness.editor.tail.known, nil)
    }

    private static func testKeyInsideAClusterIsUndoneByOneDelete() {
        // ARCHITECTURE.md, "Typing model v2", accepted residual: a key typed as a probe crosses a cluster
        // may land inside it (placed there directly here). It is visible, and one delete restores the
        // cluster exactly: the host keeps the halves of a split surrogate pair, as UIKit's storage does.
        for (text, caret) in [("Hi \u{1F44D} there", 4), ("Hi \u{1F44D}\u{1F3FD} there", 5)] {
            let harness = KeyboardHarness(FakeTextHost(text: text, caret: caret, unit: .utf16))
            let original = harness.document.host.units
            harness.tap(.character("x"))
            var inside = original
            inside.insert(contentsOf: Array("x".utf16), at: caret)
            TestSupport.expectEqual(harness.document.host.units, inside)
            harness.tap(.delete)
            harness.settle()
            TestSupport.expectEqual(harness.document.host.units, original)
            TestSupport.expectEqual(harness.document.host.caret, caret)
        }
    }

    private static func testKeysAfterReturnFollowTheFocus() {
        // A Return can move the host to another field over several frames (a search field's submit, a
        // form's next field). Keys typed after it go where the host sends them, at once, like on every
        // other keyboard; nothing waits and nothing is lost.
        for focusDelay in [1, 4, 8] {
            let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
            harness.document.returnMovesFocusTo = (FakeTextHost(text: "Field B.", model: .uikit), UUID())
            harness.document.returnFocusDelay = focusDelay
            harness.type("x\nyz")
            harness.settle()
            harness.type("w")
            TestSupport.expectEqual(harness.document.previousHosts.last?.text, "Field A.x\n")
            TestSupport.expectEqual(harness.document.text, "Field B.yzw")
        }
        // Without a focus change, in order where the caret is.
        let staying = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        staying.type("x\nyz")
        TestSupport.expectEqual(staying.document.text, "Field A.x\nyz")
    }

    private static func testHidingLosesNothingTyped() {
        // The round-8 review's P1: keys behind a Return's pause were dropped on hiding. Every key has
        // been applied by the time the keyboard hides, during a gesture's settling too.
        let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        harness.type("a\nb")
        harness.hide()
        TestSupport.expectEqual(harness.document.text, "Field A.a\nb")
        let settling = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, lagFrames: 3, callbackFrames: 3))
        settling.gesture(dx: -30, events: 1)
        settling.type("xy\nz")
        settling.hide()
        settling.frames(10)
        TestSupport.expectEqual(settling.document.text, "Alpha beta gaxy\nzmma")
    }

    private static func testDictationIsInsertedAtOnce() {
        // The round-8 review's P1: a claimed result could queue behind a Return and be dropped. A result is
        // claimed only while it can be inserted at once (`isBusy` is only a running gesture), and the
        // insertion is immediate: after a Return, with no identity, ending a gesture.
        let harness = KeyboardHarness(FakeTextHost(text: "Notes:", model: .uikit))
        TestSupport.expect(!harness.editor.isBusy, "busy with nothing running")
        harness.press(.returnKey)
        TestSupport.expect(!harness.editor.isBusy, "busy after a Return")
        harness.editor.insertDictation("invented words", now: harness.time)
        TestSupport.expectEqual(harness.document.text, "Notes:\ninvented words")
        harness.document.documentID = nil
        harness.editor.insertDictation(" more", now: harness.time)
        TestSupport.expectEqual(harness.document.text, "Notes:\ninvented words more")
        let gesture = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, lagFrames: 3, callbackFrames: 3))
        gesture.gesture(dx: -30, events: 1)
        TestSupport.expect(gesture.editor.isBusy, "a running gesture is not busy")
        gesture.editor.insertDictation(" said", now: gesture.time)
        TestSupport.expect(!gesture.trackpad.isActive, "the gesture went on after the insertion")
        TestSupport.expectEqual(gesture.document.text, "Alpha beta ga saidmma")
        gesture.hide()
        TestSupport.expectEqual(gesture.document.text, "Alpha beta ga saidmma")
    }

    // MARK: Shift and double space

    private static func testOutsideCaretTapResetsDoubleSpace() {
        // The round-8 review's P1: after a gesture and a space, a tap after another word's space within
        // a second, then Space, replaced that space with ". ". Any callback that is not an echo of our own
        // edits starts the space timing over.
        let harness = KeyboardHarness(FakeTextHost(text: "One two three", unit: .utf16, callbackFrames: 2))
        harness.gesture(dx: -100, events: 1)
        harness.press(.space)
        TestSupport.expectEqual(harness.document.text, "One  two three")
        harness.document.moveCaret(to: 9)
        harness.frame()
        harness.press(.space)
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "One  two  three")
        // Plain typing, then a tap: the same.
        let typed = KeyboardHarness(FakeTextHost(text: "One two", unit: .utf16))
        typed.press(.space)
        typed.document.moveCaret(to: 4, reportedAsTextChange: true)
        typed.frame()
        typed.press(.space)
        TestSupport.expectEqual(typed.document.text, "One  two ")
        // With no callback between them, two spaces still type ". ".
        let quick = KeyboardHarness(FakeTextHost(text: "One", unit: .utf16))
        quick.press(.space)
        quick.frame()
        quick.press(.space)
        TestSupport.expectEqual(quick.document.text, "One. ")
    }

    private static func testNewFieldsFirstLetterIsCasedFromItsText() {
        // The round-8 review's P1: the first letter typed in a newly focused field before its first
        // callback took the old field's casing. The field the proxy serves is adopted first.
        let toEmpty = KeyboardHarness(FakeTextHost(text: "Field A has wor", model: .uikit), autocapitalization: .sentences)
        TestSupport.expectEqual(toEmpty.editor.typing.shift, .off)
        toEmpty.document.switchField(to: FakeTextHost(text: "", model: .uikit), id: UUID())
        toEmpty.press(.character("x"), field: .some(nil))
        TestSupport.expectEqual(toEmpty.document.text, "X")
        let toMidSentence = KeyboardHarness(FakeTextHost(text: "Done. ", model: .uikit), autocapitalization: .sentences)
        TestSupport.expectEqual(toMidSentence.editor.typing.shift, .once)
        toMidSentence.document.switchField(to: FakeTextHost(text: "In the mid", model: .uikit), id: UUID())
        toMidSentence.press(.character("x"), field: .some(nil))
        TestSupport.expectEqual(toMidSentence.document.text, "In the midx")
        // Its double-space timing does not carry over either.
        let spacing = KeyboardHarness(FakeTextHost(text: "One", model: .uikit))
        spacing.press(.space)
        spacing.document.switchField(to: FakeTextHost(text: "Two ", model: .uikit), id: UUID())
        spacing.press(.space, field: .some(nil))
        TestSupport.expectEqual(spacing.document.text, "Two  ")
    }

    // MARK: Field binding

    private static func testHeldTouchesBindToTheFirstIdentifiedField() {
        // The round-8 review's P1: a finger that touched down while no field was identified kept no
        // binding, and released into B after first becoming identified in A. It binds to the first field
        // identified, A, so it ends without typing in B (both known, different).
        let fieldA = UUID()
        let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit), documentID: nil)
        let delete = harness.touchDown(.delete)
        let letter = harness.touchDown(.character("q"))
        harness.document.documentID = fieldA
        harness.document.report(after: 1)
        harness.frame()
        TestSupport.expect(harness.model.touches.contains { $0.id == letter }, "a key held before any identity ended in A")
        harness.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
        harness.document.report(after: 1)
        harness.frame()
        harness.touchUp(letter)
        harness.touchUp(delete)
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Field B.")
        TestSupport.expectEqual(harness.document.previousHosts.last?.text, "Field A.")
        // Released in A, it types in A.
        let staying = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit), documentID: nil)
        let touch = staying.touchDown(.character("q"))
        staying.document.documentID = UUID()
        staying.document.report(after: 1)
        staying.frame()
        staying.touchUp(touch)
        TestSupport.expectEqual(staying.document.text, "Field A.q")
    }

    private static func testKeysWithoutAnIdentityRunAtOnce() {
        // A missing identity never blocks a key: while a field connects (nil → nil), and for a key bound
        // to A released while nothing is identified, it goes to the field the proxy serves, at once.
        let unidentified = KeyboardHarness(FakeTextHost(text: "Connecting.", model: .uikit), documentID: nil)
        unidentified.tap(.character("x"))
        TestSupport.expectEqual(unidentified.document.text, "Connecting.x")
        let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        let touch = harness.touchDown(.character("z"))
        harness.document.documentID = nil
        harness.touchUp(touch)
        TestSupport.expectEqual(harness.document.text, "Field A.z")
    }

    private static func testOwnTypingReportsNeverDropKeys() {
        // The round-6 review's P1: a host that reports our own edits had them taken as outside changes.
        // Delayed or coalesced, they are echoes: never outside changes.
        for delay in [1, 2, 3] {
            let typed = KeyboardHarness(FakeTextHost(text: "Notes: ", model: .uikit), editCallbackDelay: delay)
            for character in "abc" {
                typed.press(.character(String(character)))
                typed.frame()
            }
            typed.press(.delete)
            typed.type(" d")
            typed.settle()
            TestSupport.expectEqual(typed.document.text, "Notes: ab d")
            TestSupport.expect(!typed.outcomes.contains(.outside), "an own report taken as outside at \(delay)")
            TestSupport.expect(typed.outcomes.contains(.ownEdit), "no own report delivered at \(delay)")
        }
    }

    private static func testOwnTypingReportsNeverEndTheNextGesture() {
        // Typing, then a gesture before the host's reports of it arrive: they are our own edits, not an
        // outside change that would end the gesture.
        let harness = KeyboardHarness(FakeTextHost(text: "One two three", unit: .utf16), editCallbackDelay: 50)
        harness.type(" four")
        harness.gesture(dx: 0, events: 2, lift: false)
        TestSupport.expect(harness.trackpad.isActive, "the gesture ended")
        harness.drag(dx: -30, dy: 0)
        harness.frames(2)
        harness.trackpad.end(at: harness.time)
        harness.settle()
        TestSupport.expect(!harness.outcomes.contains(.outside), "an own report ended the gesture")
        TestSupport.expectEqual(harness.document.host.caret, "One two three f".utf16.count)
    }

    private static func testKeyReleasedAfterTheFieldChangedNeverLands() {
        // The round-6 review's P1: a letter pressed in field A; the proxy served field B before any
        // callback said so; the release typed into B. Both identities are known and differ: cancelled.
        let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        let fieldA = harness.field
        let touch = harness.touchDown(.character("x"))
        harness.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
        harness.touchUp(touch)
        for action in [KeyAction.space, .returnKey, .delete] { harness.press(action, field: fieldA) }
        TestSupport.expectEqual(harness.document.text, "Field B.")
        TestSupport.expectEqual(harness.document.previousHosts.last?.text, "Field A.")
        // Touched down in B, it types in B.
        harness.tap(.character("y"))
        TestSupport.expectEqual(harness.document.text, "Field B.y")
    }

    private static func testKeyTouchedDownInTheNewFieldSurvivesItsFirstCallback() {
        // The round-7 review's P1: focus moved A→B; a character touched down in B before B's first
        // callback; that callback cancelled every held touch, B's valid key included. Only touches and a
        // delete bound to another field end.
        let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        let deleteInA = harness.touchDown(.delete)
        let inA = harness.touchDown(.character("q"))
        harness.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
        harness.document.report(after: 1)
        harness.frame()
        TestSupport.expectEqual(harness.outcomes.last, .newField)
        TestSupport.expect(!harness.model.touches.contains { $0.id == inA }, "a key held in A survived the focus change")
        let inB = harness.touchDown(.character("w"))
        let early = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        early.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
        let touchedEarly = early.touchDown(.character("e"))
        early.document.report(after: 1)
        early.frame()
        TestSupport.expect(early.model.touches.contains { $0.id == touchedEarly }, "a key held in B ended by B's first callback")
        early.touchUp(touchedEarly)
        TestSupport.expectEqual(early.document.text, "Field B.e")
        harness.touchUp(inB)
        harness.touchUp(inA)
        harness.touchUp(deleteInA)
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Field B.w")
        TestSupport.expectEqual(harness.document.previousHosts.last?.text, "Field A.")
        // A delete held in B, touched down before B's first callback, still deletes in B.
        let second = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        second.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
        let held = second.touchDown(.delete)
        second.document.report(after: 1)
        second.frame()
        second.touchUp(held)
        second.settle()
        TestSupport.expectEqual(second.document.text, "Field B")
    }


    private static func testAbortedJumpIsRepairedToABoundary() {
        // The round-7 review's P1, now with no key involved: a jump past the edge stopped between the
        // halves of 👍's surrogate pair and an unrelated change ended the gesture. The gesture's own
        // safety goes on through the abort until the field shows a whole-cluster boundary.
        let harness = KeyboardHarness(FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16,
                                                   window: 2, callbackFrames: 6))
        let touch = harness.beginGesture()
        var split = false
        for _ in 0 ..< 30 where !split {
            harness.drag(dx: 0, dy: 1)
            split = harness.document.host.caretSplitsSurrogatePair
        }
        TestSupport.expect(split, "the jump never stopped inside the pair")
        harness.touchUp(touch)
        harness.trackpad.abort()
        TestSupport.expect(harness.trackpad.isActive, "the gesture ended with the caret inside the emoji")
        harness.settle()
        TestSupport.expect(harness.document.host.caretIsOnBoundary, "left inside the emoji")
        TestSupport.expectEqual(harness.document.text, "ab\u{1F44D}\u{1F3FD}cd\nnext line")
        // A key during that watch ends it at once, wherever the caret is.
        let typing = KeyboardHarness(FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16,
                                                  window: 2, callbackFrames: 6))
        let finger = typing.beginGesture()
        split = false
        for _ in 0 ..< 30 where !split {
            typing.drag(dx: 0, dy: 1)
            split = typing.document.host.caretSplitsSurrogatePair
        }
        typing.touchUp(finger)
        typing.trackpad.abort()
        typing.press(.character("Q"))
        TestSupport.expect(!typing.trackpad.isActive, "the watch went on after a key")
        TestSupport.expect(typing.document.text.contains("Q"), "the key waited")
    }

    private static func testShiftFollowsAnEditTheProxyShowsLate() {
        // The proxy shows the keyboard's own deletion a few frames late, and no host reports it (measured).
        // Deleting the line break a host shows alone at a line's start joins the line to one it never
        // showed: what precedes is unknown until the proxy shows the field (meanwhile the stale break
        // calls for a capital, a residual); then the shift follows it, with no callback.
        var host = FakeTextHost(text: "Cp\n", model: .lineBreakOnly)
        host.editContextLagFrames = 3
        let harness = KeyboardHarness(host, autocapitalization: .sentences)
        TestSupport.expectEqual(harness.editor.typing.shift, .once)
        harness.press(.delete)
        TestSupport.expectEqual(harness.document.text, "Cp")
        harness.frames(4)
        TestSupport.expectEqual(harness.editor.typing.shift, .off)
        // Deleting all else the proxy showed leaves the caret where its window starts, a line here.
        var line = FakeTextHost(text: "Done.\nx", model: .lineBreakOnly)
        line.editContextLagFrames = 3
        let deleting = KeyboardHarness(line, autocapitalization: .sentences)
        TestSupport.expectEqual(deleting.editor.typing.shift, .off)
        deleting.press(.delete)
        TestSupport.expectEqual(deleting.editor.typing.shift, .once)
        // Where what remains is known, the shift follows it at once.
        var known = FakeTextHost(text: "Done. x", model: .whole)
        known.editContextLagFrames = 3
        let typed = KeyboardHarness(known, autocapitalization: .sentences)
        typed.press(.delete)
        TestSupport.expectEqual(typed.editor.typing.shift, .once)
    }

    private static func testDeletingPastTheFieldStartKeepsItsCasing() {
        // Found by the typing torture (seed 6990): the proxy showed our deletions a frame late; deleting
        // everything known, then once more at the field's start, fell back to the stale reading, which
        // still showed the deleted text, so the next letter came out lowercase.
        var host = FakeTextHost(text: "Ab", model: .whole)
        host.editContextLagFrames = 3
        let harness = KeyboardHarness(host, autocapitalization: .sentences)
        TestSupport.expectEqual(harness.editor.typing.shift, .off)
        for _ in 0 ..< 3 { harness.tap(.delete) }
        TestSupport.expectEqual(harness.editor.typing.shift, .once)
        harness.tap(.character("c"))
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "C")
        TestSupport.expectEqual(harness.editor.typing.shift, .off)
    }

    private static func testDeletingASelectionKeepsTheTextBefore() {
        // Delete with text selected removes only the selection: the text before the caret decides the
        // shift, not that text one character shorter.
        let harness = KeyboardHarness(FakeTextHost(text: "One. two"), autocapitalization: .sentences)
        harness.document.select(from: 5, length: 3)
        harness.settle()
        harness.press(.delete)
        TestSupport.expectEqual(harness.document.text, "One. ")
        TestSupport.expectEqual(harness.editor.typing.shift, .once)
    }

    private static func testKeyAtTheLiftIsCasedWhereTheCaretLands() {
        // A key at the lift settles the gesture where its move in flight lands, and is cased for the text
        // there, though the proxy still shows the caret where it was.
        let harness = KeyboardHarness(FakeTextHost(text: "One. Two", unit: .utf16, lagFrames: 3, callbackFrames: 3),
                                      autocapitalization: .sentences)
        harness.gesture(dx: -30, events: 1)
        TestSupport.expectEqual(harness.document.host.caret, 8)
        harness.press(.character("t"))
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "One. TTwo")
        // To the start of the field, where nothing is before the caret.
        let start = KeyboardHarness(FakeTextHost(text: "Alpha beta", unit: .utf16, lagFrames: 3, callbackFrames: 3),
                                    autocapitalization: .sentences)
        start.gesture(dx: -100, events: 1)
        start.press(.character("x"))
        start.settle()
        TestSupport.expectEqual(start.document.text, "XAlpha beta")
    }

    private static func testKeyDuringAProbeIsCasedWhereTheHostHasTheCaret() {
        // A key abandons a probe's outcome: it is cased from the text the proxy shows before the caret,
        // where the probe already took it, never from the text before the probe's starting point.
        let harness = KeyboardHarness(FakeTextHost(text: "Hi. \u{1F44D}", unit: .utf16, callbackFrames: 3),
                                      autocapitalization: .sentences)
        TestSupport.expectEqual(harness.editor.typing.shift, .off)
        harness.gesture(dx: -10, events: 1)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        harness.press(.character("x"))
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi. X\u{1F44D}")
    }

    private static func testReportOfAMoveAsIssuedIsNotTakenForOurKey() {
        // WebKit reports each adjustment first as issued, showing the context the last key left. Taken for
        // that key's report, the gesture never learned that the proxy showed a caret from before its move.
        var host = FakeTextHost(text: "Alpha beta", unit: .grapheme, callbackFrames: 2)
        host.reportsAsIssuedFirst = true
        let harness = KeyboardHarness(host)
        harness.type(" x")
        harness.gesture(dx: -30, events: 1)
        harness.settle()
        TestSupport.expect(!harness.outcomes.contains(.ownEdit), "the gesture's report was taken for the key's")
        TestSupport.expectEqual(harness.document.host.caret, "Alpha beta x".utf16.count - 3)
    }

    /// Seeds 1...60 and earlier failures by default; `TORTURE_SEEDS=first-last` runs others (a stress run
    /// on the Mac). Prints the failing seed and the smallest failing number of steps.
    private static func testTypingTorture() {
        // Seeds a stress run found failing in rounds 9 and 10, each a bug since fixed or a limit the oracle
        // now states.
        var seeds = Array(UInt64(1) ... 60) + [63, 107, 114, 156, 315, 419, 439, 469, 470, 556, 1240, 1284, 1402, 1850, 2083, 2105,
                                              4026, 5329, 5392, 6822, 6961, 6990, 8527, 9549, 11942]
        if let range = ProcessInfo.processInfo.environment["TORTURE_SEEDS"]?.split(separator: "-"), range.count == 2,
           let first = UInt64(range[0]), let last = UInt64(range[1]), first <= last {
            seeds = Array(first ... last)
        }
        for seed in seeds {
            let result = TypingTorture(seed: seed).run(steps: 250)
            guard let failure = result else { continue }
            // The smallest prefix of the script that fails, for the report.
            var smallest = failure.step
            for steps in stride(from: failure.step, through: 1, by: -1) {
                guard TypingTorture(seed: seed).run(steps: steps) != nil else { break }
                smallest = steps
            }
            TestSupport.expect(false, "typing torture seed \(seed), step \(failure.step) (fails from \(smallest) steps): \(failure.message)")
        }
    }
}

/// The keyboard as `KeyboardInput` wires it, without UIKit: touches through `KeyTouchModel` (keys bound
/// to the field at touch-down, or the first identified after; a focus change ends only touches bound
/// elsewhere), the held delete key's timer, the space bar's hold, the trackpad's frames, hiding, and
/// host callbacks between frames.
final class KeyboardHarness {
    static let frameInterval = 1.0 / 120
    static let metrics = KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight)

    let document: FakeDocument
    let trackpad: TrackpadController
    let editor: KeyboardEditor
    private(set) var model = KeyTouchModel()
    private(set) var time: TimeInterval = 100
    private(set) var outcomes: [EditingCore.CallbackOutcome] = []
    var autocapitalization: AutocapitalizationMode
    /// A session ended (completed or not).
    var onSessionEnd: ((Bool) -> Void)?
    private var deleteKey = HeldDeleteKey()
    private var deleteDue: (token: Int, at: TimeInterval, pressedAt: TimeInterval)?
    private var holdDue: [KeyTouchModel.TouchID: TimeInterval] = [:]
    private var nextTouch = 1

    init(_ host: FakeTextHost, autocapitalization: AutocapitalizationMode = .none, editCallbackDelay: Int? = nil,
         documentID: UUID? = UUID()) {
        document = FakeDocument(host, documentID: documentID)
        document.editCallbackDelay = editCallbackDelay
        trackpad = TrackpadController(host: document)
        trackpad.parameters = .flat
        editor = KeyboardEditor(document: document, trackpad: trackpad)
        self.autocapitalization = autocapitalization
        editor.autocapitalization = { [unowned self] in self.autocapitalization }
        let finished = trackpad.onFinished
        trackpad.onFinished = { [unowned self] completed in
            self.onSessionEnd?(completed)
            finished?(completed)
        }
        _ = model.keysChanged(KeyboardLayout.keys(for: .letters, metrics: Self.metrics, showsGlobe: false), layer: .letters)
        editor.onStateChanged = { [unowned self] in self.applyLayer() }
        editor.onFieldChanged = { [unowned self] field in
            if self.deleteKey.fieldChanged(to: field) { self.deleteDue = nil }
            self.perform(self.model.fieldChanged(to: field))
        }
        editor.reset(numeric: false)
    }

    var field: UUID? { document.documentID }

    /// Nothing is left to happen: no session, no touches or timers, no callbacks to come, and the proxy
    /// shows the field as it is.
    var isQuiet: Bool {
        !trackpad.isActive && document.pendingCallbacks == 0 && !document.host.hasCallbacksToCome
            && !document.host.isContextStale && model.touches.isEmpty && model.trackpadTouch == nil && deleteDue == nil
    }

    // MARK: Frames

    /// One display frame: due host events and callbacks reach the editor (as `KeyboardInput` delivers
    /// them), timers fire, the editor follows the proxy, then the trackpad's frame.
    func frame() {
        time += Self.frameInterval
        document.host.advanceFrame()
        while document.host.takeCallback() != nil { _ = deliver(textChanged: true) }
        _ = document.pump { [unowned self] textChanged in self.deliver(textChanged: textChanged) }
        for (id, due) in holdDue where due <= time {
            holdDue[id] = nil
            perform(model.holdElapsed(id))
        }
        if let due = deleteDue, due.at <= time {
            if let fired = deleteKey.fire(token: due.token, documentID: document.documentID) {
                editor.heldDelete(fired.unit, field: fired.field, now: time)
                deleteDue = (due.token, due.pressedAt + fired.nextAt, due.pressedAt)
            } else {
                deleteDue = nil
            }
        }
        editor.service(now: time)
        trackpad.tick(at: time)
        onFrame?()
    }

    /// Called after every frame (the typing torture's trace).
    var onFrame: (() -> Void)?

    func frames(_ count: Int) {
        for _ in 0 ..< count { frame() }
    }

    /// Frames until nothing is left to happen.
    func settle(maxFrames: Int = 1_200) {
        for _ in 0 ..< maxFrames where !isQuiet { frame() }
    }

    /// Called before every host callback reaches the editor, with whether a gesture is running (the typing
    /// torture's oracle).
    var onDeliver: ((Bool) -> Void)?

    private func deliver(textChanged: Bool) -> EditingCore.CallbackOutcome {
        onDeliver?(trackpad.isActive)
        let outcome = editor.hostChanged(textChanged: textChanged, now: time)
        outcomes.append(outcome)
        return outcome
    }

    // MARK: Keys

    /// A key straight to the editor, as pressed in `field` (the current one unless given).
    func press(_ action: KeyAction, field: UUID?? = .none) {
        editor.press(action, field: field ?? document.documentID, at: time, now: time)
    }

    func type(_ text: String) {
        for character in text {
            switch character {
            case " ": press(.space)
            case "\n": press(.returnKey)
            default: press(.character(String(character)))
            }
        }
    }

    /// The center of a key on the layer shown now.
    func center(_ action: KeyAction) -> (x: Double, y: Double)? {
        model.keys.first { $0.action == action }.map { ($0.frame.midX, $0.frame.midY) }
    }

    /// A finger touches down on a key, in the field the keyboard serves now.
    @discardableResult
    func touchDown(_ action: KeyAction) -> KeyTouchModel.TouchID {
        let id = nextTouch
        nextTouch += 1
        guard let point = center(action) else { return id }
        perform(model.began(id, x: point.x, y: point.y, field: document.documentID))
        return id
    }

    func touchUp(_ id: KeyTouchModel.TouchID) {
        let touch = model.touches.first { $0.id == id }
        perform(model.ended(id, x: touch?.x ?? 0, y: touch?.y ?? 0))
    }

    /// The system cancels a touch (not a lift).
    func cancelTouch(_ id: KeyTouchModel.TouchID) {
        perform(model.cancelled(id))
    }

    func tap(_ action: KeyAction) {
        touchUp(touchDown(action))
    }

    /// The keyboard hides, as `KeyboardInput.stop` does: every held key and the delete repeat end without
    /// acting, then the editor drops its copies of the field.
    func hide() {
        deleteKey.cancel()
        deleteDue = nil
        holdDue = [:]
        perform(model.cancelAll())
        editor.hide(now: time)
    }

    /// The keyboard appears again (`KeyboardInput.reset`).
    func show() {
        editor.reset(numeric: false)
    }

    private func applyLayer() {
        let layer = editor.typing.layer
        guard layer != model.layer else { return }
        perform(model.keysChanged(KeyboardLayout.keys(for: layer, metrics: Self.metrics, showsGlobe: false), layer: layer))
    }

    private func perform(_ effects: [KeyTouchModel.Effect]) {
        for effect in effects {
            switch effect {
            case .keyDown:
                editor.keyTouchedDown(now: time)
            case .type(let action, let field):
                editor.press(action, field: field, at: time, now: time)
            case .beginDelete:
                let press = deleteKey.began(at: time, documentID: document.documentID)
                deleteDue = (press.token, time + press.firstAt, time)
            case .endDelete(let cancelled):
                deleteDue = nil
                guard let ended = deleteKey.ended(cancelled: cancelled, documentID: document.documentID),
                      ended.deleteOnce else { break }
                editor.heldDelete(.character, field: ended.field, now: time)
            case .startHoldTimer(let id):
                holdDue[id] = time + model.parameters.holdDuration
            case .cancelHoldTimer(let id):
                holdDue[id] = nil
            case .beginTrackpad:
                editor.beginTrackpad(layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
            case .endTrackpad(let cancelled):
                if cancelled { trackpad.cancel(at: time) } else { trackpad.end(at: time) }
            }
        }
    }

    // MARK: Trackpad

    /// The space bar held until the trackpad starts. Returns the finger.
    @discardableResult
    func beginGesture() -> KeyTouchModel.TouchID {
        let id = touchDown(.space)
        for _ in 0 ..< 120 where model.trackpadTouch != id { frame() }
        return id
    }

    /// One touch event of the trackpad's finger, then two frames (events at 60 Hz, the gain's reference).
    func drag(dx: Double, dy: Double) {
        trackpad.move(dx: dx, dy: dy, timestamp: time)
        frames(2)
    }

    /// A whole gesture: the hold, `events` touch events, then the lift (unless `lift` is false). Keys may
    /// follow at once.
    func gesture(dx: Double = 0, dy: Double = 0, events: Int, lift: Bool = true) {
        let id = beginGesture()
        for _ in 0 ..< events { drag(dx: dx, dy: dy) }
        if lift { touchUp(id) }
    }
}
