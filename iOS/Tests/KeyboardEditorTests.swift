import Foundation

/// The keyboard's editing side as `KeyboardInput` drives it (ARCHITECTURE.md, "Typing correctness is
/// paramount"): touches through `KeyTouchModel` (each key bound to the field at its touch-down), keys
/// through `KeyboardEditor` with the real `TypingState`, the held delete key's timer, the trackpad
/// through the real `TrackpadController` and `TrackpadSession` once per frame, and every host callback
/// (the trackpad's reports, focus changes, the host app's own edits) delivered between frames.
enum KeyboardEditorTests {
    static var tests: [TestCase] {
        [
            ("keysRunAtOnceWhileSettling", testKeysRunAtOnceWhileSettling),
            ("shiftNeverOvertakesWaitingLetters", testShiftNeverOvertakesWaitingLetters),
            ("ownTypingReportsNeverDropKeys", testOwnTypingReportsNeverDropKeys),
            ("ownTypingReportsNeverEndTheNextGesture", testOwnTypingReportsNeverEndTheNextGesture),
            ("keyReleasedAfterTheFieldChangedNeverLands", testKeyReleasedAfterTheFieldChangedNeverLands),
            ("keyTouchedDownInTheNewFieldSurvivesItsFirstCallback", testKeyTouchedDownInTheNewFieldSurvivesItsFirstCallback),
            ("unidentifiedKeysWaitForAnIdentity", testUnidentifiedKeysWaitForAnIdentity),
            ("returnPauseHoldsOnEveryPath", testReturnPauseHoldsOnEveryPath),
            ("abortWhileKeysWaitNeverReleasesThemInsideACluster", testAbortWhileKeysWaitNeverReleasesThemInsideACluster),
            ("abortedEdgeProbeNeverSplitsTheEmoji", testAbortedEdgeProbeNeverSplitsTheEmoji),
            ("keysWaitForTheWholeClusterRepair", testKeysWaitForTheWholeClusterRepair),
            ("typingWaitHasOneDeadline", testTypingWaitHasOneDeadline),
            ("lateReportsOfAFinishedGestureAreOurs", testLateReportsOfAFinishedGestureAreOurs),
            ("cancelledDeleteRevokesWhatWaits", testCancelledDeleteRevokesWhatWaits),
            ("dictationWaitsLikeAKey", testDictationWaitsLikeAKey),
            ("hidingRunsWaitingKeysInTheirField", testHidingRunsWaitingKeysInTheirField),
            ("shiftFollowsAnEditTheProxyShowsLate", testShiftFollowsAnEditTheProxyShowsLate),
            ("deletingASelectionKeepsTheTextBefore", testDeletingASelectionKeepsTheTextBefore),
            ("keyAtTheLiftIsCasedWhereTheCaretLands", testKeyAtTheLiftIsCasedWhereTheCaretLands),
            ("reportOfAMoveAsIssuedIsNotTakenForOurKey", testReportOfAMoveAsIssuedIsNotTakenForOurKey),
            ("keyWaitsForTheLateReportOfAJumpPastTheEdge", testKeyWaitsForTheLateReportOfAJumpPastTheEdge),
            ("bothReportsOfAMoveAreTheGesturesOwn", testBothReportsOfAMoveAreTheGesturesOwn),
            ("typingTorture", testTypingTorture),
        ]
    }

    /// A field whose context is all of it, and a probe across the emoji at its end that the host
    /// answers `callbackFrames` frames later.
    private static func emojiField(callbackFrames: Int = 3, unit: CursorOffsetUnit = .utf16) -> KeyboardHarness {
        KeyboardHarness(FakeTextHost(text: "Hi \u{1F44D}\u{1F3FD}", unit: unit, callbackFrames: callbackFrames))
    }

    private static func testKeysRunAtOnceWhileSettling() {
        // A gesture lifted while a move is still out and its reports are owed: a key settles it on the
        // spot and runs at once, where the move takes the caret.
        let harness = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, lagFrames: 3, callbackFrames: 3))
        harness.gesture(dx: -30, events: 1)
        TestSupport.expect(harness.trackpad.isActive, "settled before the key")
        TestSupport.expectEqual(harness.document.host.caret, 16)
        harness.press(.character("x"))
        TestSupport.expect(!harness.trackpad.isActive, "the gesture kept settling after a key")
        TestSupport.expect(harness.editor.pendingKeys.isEmpty, "the key waited")
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
    }

    private static func testShiftNeverOvertakesWaitingLetters() {
        // The round-6 review's P1: "a" queued behind settlement, Shift, "b" queued: the queue resolved its
        // closures after Shift had changed the state, and typed "Ab". Each key is resolved at its press.
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        harness.press(.character("a"))
        harness.press(.shift)
        harness.press(.character("b"))
        TestSupport.expectEqual(harness.editor.pendingKeys.map(\.text), ["a", "B"])
        TestSupport.expectEqual(harness.document.text, "Hi \u{1F44D}\u{1F3FD}")
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi aB\u{1F44D}\u{1F3FD}")
    }

    private static func testOwnTypingReportsNeverDropKeys() {
        // The round-6 review's P1: a, b, c queued; the host reported a's insertion between frames, the
        // report was an outside change, and b and c were discarded. Our own edits' reports, delayed or
        // coalesced, are never outside changes, and keys no longer wait in a queue they could be
        // discarded from.
        for delay in [1, 2, 3] {
            let waiting = emojiField()
            waiting.document.editCallbackDelay = delay
            waiting.gesture(dx: -10, events: 1)
            waiting.type("abc")
            waiting.settle()
            TestSupport.expectEqual(waiting.document.text, "Hi abc\u{1F44D}\u{1F3FD}")
            TestSupport.expect(!waiting.outcomes.contains(.outside), "an own report taken as outside at \(delay)")
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
        harness.editor.trackpadMoved(dx: -30, dy: 0, timestamp: harness.time)
        harness.frames(4)
        harness.editor.trackpadEnded(at: harness.time, cancelled: false)
        harness.settle()
        TestSupport.expect(!harness.outcomes.contains(.outside), "an own report ended the gesture")
        TestSupport.expectEqual(harness.document.host.caret, "One two three f".utf16.count)
    }

    private static func testKeyReleasedAfterTheFieldChangedNeverLands() {
        // The round-6 review's P1: a letter pressed in field A; the proxy served field B before any
        // callback said so; the release typed into B. Each key is bound to the field of its press.
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

    private static func testUnidentifiedKeysWaitForAnIdentity() {
        // The round-7 review's P1: while a field connects, both the key's field and the proxy's identity
        // were nil, and nil matched nil. A key is typed only into an identified field: one released
        // without an identity waits (within its deadline) for one, and runs only if it matches its press.
        // nil → nil: never typed.
        let unidentified = KeyboardHarness(FakeTextHost(text: "Connecting.", model: .uikit))
        unidentified.document.documentID = nil
        unidentified.tap(.character("x"))
        unidentified.frames(Int(KeyboardEditor.maximumWait * 120) + 4)
        TestSupport.expectEqual(unidentified.document.text, "Connecting.")
        TestSupport.expect(unidentified.editor.pendingKeys.isEmpty, "a key kept past its deadline")
        // nil → B: typed in B once it is identified.
        let connecting = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
        connecting.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: nil)
        connecting.document.report(after: 1)
        connecting.frame()
        connecting.tap(.character("x"))
        connecting.tap(.character("y"))
        connecting.frames(6)
        TestSupport.expectEqual(connecting.document.text, "Field B.")
        connecting.document.documentID = UUID()
        connecting.document.report(after: 1)
        connecting.settle()
        TestSupport.expectEqual(connecting.document.text, "Field B.xy")
        // Bound to A, released while nothing is identified: typed if A comes back, never into B.
        for comesBack in [true, false] {
            let harness = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
            let fieldA = harness.field
            let touch = harness.touchDown(.character("z"))
            harness.document.documentID = nil
            harness.touchUp(touch)
            harness.frames(6)
            if comesBack {
                harness.document.documentID = fieldA
            } else {
                harness.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
            }
            harness.document.report(after: 1)
            harness.settle()
            TestSupport.expectEqual(harness.document.text, comesBack ? "Field A.z" : "Field B.")
        }
    }

    private static func testReturnPauseHoldsOnEveryPath() {
        // The round-7 review's P2: keys after a Return waited one frame on one path and none on others
        // (a new gesture, hiding). The host moves focus over several frames, sending what is typed in the
        // meantime to the new field. Keys pressed in the old field wait out the pause and never land
        // there.
        for focusDelay in [1, 4, 8] {
            // Waiting on a probe, then run: x and the Return in A; y and z never reach B.
            let waiting = emojiField()
            waiting.document.returnMovesFocusTo = (FakeTextHost(text: "Field B.", model: .uikit), UUID())
            waiting.document.returnFocusDelay = focusDelay
            waiting.gesture(dx: -10, events: 1)
            waiting.type("x\nyz")
            waiting.settle()
            TestSupport.expectEqual(waiting.document.text, "Field B.")
            TestSupport.expectEqual(waiting.document.previousHosts.last?.text, "Hi x\n\u{1F44D}\u{1F3FD}")
            // Typed at once: the key after the Return waits too.
            let typed = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
            typed.document.returnMovesFocusTo = (FakeTextHost(text: "Field B.", model: .uikit), UUID())
            typed.document.returnFocusDelay = focusDelay
            typed.tap(.returnKey)
            typed.tap(.character("y"))
            typed.settle()
            TestSupport.expectEqual(typed.document.text, "Field B.")
            TestSupport.expectEqual(typed.document.previousHosts.last?.text, "Field A.\n")
            // Hiding during the pause: what is behind it is dropped, not typed into B.
            let hiding = KeyboardHarness(FakeTextHost(text: "Field A.", model: .uikit))
            hiding.document.returnMovesFocusTo = (FakeTextHost(text: "Field B.", model: .uikit), UUID())
            hiding.document.returnFocusDelay = focusDelay
            hiding.tap(.returnKey)
            hiding.tap(.character("y"))
            hiding.editor.hide(now: hiding.time)
            hiding.frames(focusDelay + 2)
            TestSupport.expectEqual(hiding.document.text, "Field B.")
        }
        // Without a focus change, the keys after the Return land in order once the pause is over.
        let staying = emojiField()
        staying.gesture(dx: -10, events: 1)
        staying.type("x\nyz")
        staying.settle()
        TestSupport.expectEqual(staying.document.text, "Hi x\nyz\u{1F44D}\u{1F3FD}")
        // A gesture begun during the pause starts once the keys have run, with the finger's movement.
        let deferred = KeyboardHarness(FakeTextHost(text: "One two", unit: .utf16))
        deferred.tap(.returnKey)
        deferred.tap(.character("a"))
        deferred.editor.beginTrackpad(layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000,
                                      now: deferred.time)
        TestSupport.expect(!deferred.trackpad.isActive, "the gesture started ahead of the waiting keys")
        deferred.editor.trackpadMoved(dx: 0, dy: -20, timestamp: deferred.time)
        deferred.editor.trackpadEnded(at: deferred.time, cancelled: false)
        deferred.settle()
        TestSupport.expectEqual(deferred.document.text, "One two\na")
        TestSupport.expectEqual(deferred.document.host.caret, 1)
    }

    private static func testAbortWhileKeysWaitNeverReleasesThemInsideACluster() {
        // A probe left a UTF-16 caret between "e" and its accent; the gesture ends before its outcome is
        // read (an outside change, say). The key waits until the caret is on a whole-cluster boundary,
        // and is never typed inside the cluster.
        let harness = KeyboardHarness(FakeTextHost(text: "e\u{301}", unit: .utf16, callbackFrames: 5))
        harness.gesture(dx: -10, events: 1)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        TestSupport.expectEqual(harness.document.host.caret, 1)
        harness.press(.character("x"))
        harness.trackpad.abort()
        TestSupport.expectEqual(harness.document.text, "e\u{301}")
        harness.settle()
        TestSupport.expect(harness.document.text == "e\u{301}x" || harness.document.text == "xe\u{301}",
                           "typed inside the cluster: \(harness.document.text.debugDescription)")
    }

    private static func testAbortedEdgeProbeNeverSplitsTheEmoji() {
        // The round-7 review's P1: a jump past the edge stopped between the halves of 👍's surrogate pair,
        // x waited, an unrelated change ended the gesture, and one repair step reached 👍|🏽: "👍x🏽". The
        // repair goes on through the abort until the field shows a whole-cluster boundary.
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
        harness.press(.character("Q"))
        TestSupport.expect(!harness.document.text.contains("Q"), "typed before the jump was resolved")
        // An unrelated change ends the gesture (what the editor does on an outside change).
        harness.trackpad.abort()
        TestSupport.expect(!harness.document.text.contains("Q"), "released before the boundary was verified")
        harness.settle()
        TestSupport.expect(harness.document.text.contains("\u{1F44D}\u{1F3FD}"), "the emoji was split: \(harness.document.text)")
        TestSupport.expectEqual(harness.document.text.replacingOccurrences(of: "Q", with: ""), "ab\u{1F44D}\u{1F3FD}cd\nnext line")
    }

    private static func testKeysWaitForTheWholeClusterRepair() {
        // Found by the typing torture test: a jump past the edge stopped between the halves of a surrogate
        // pair; its repair out of the pair reaches only the next scalar, still inside "👍🏽". A key pressed
        // then waits until the caret is on the cluster's edge.
        let harness = KeyboardHarness(FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16, window: 2))
        let touch = harness.beginGesture()
        var pressed = false
        for _ in 0 ..< 40 where !pressed {
            harness.drag(dx: 0, dy: 0.5)
            let host = harness.document.host
            if !host.caretIsOnBoundary, !host.caretSplitsSurrogatePair {
                harness.touchUp(touch)
                harness.press(.character("Q"))
                pressed = true
            }
        }
        TestSupport.expect(pressed, "the repair never stopped between the scalars")
        harness.settle()
        TestSupport.expect(harness.document.text.contains("\u{1F44D}\u{1F3FD}"), "the emoji was split: \(harness.document.text)")
        TestSupport.expectEqual(harness.document.text.replacingOccurrences(of: "Q", with: ""), "ab\u{1F44D}\u{1F3FD}cd\nnext line")
    }

    private static func testTypingWaitHasOneDeadline() {
        // The round-7 review's P2: an edge probe's wait and then a repair's could add up. One deadline,
        // from the earliest waiting key: then the trackpad ends with a safe boundary recovery and the
        // keys run, never inside a cluster.
        let harness = KeyboardHarness(FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16,
                                                   window: 2, lagFrames: 0, callbackFrames: nil))
        let touch = harness.beginGesture()
        var split = false
        for _ in 0 ..< 30 where !split {
            harness.drag(dx: 0, dy: 1)
            split = !harness.document.host.caretIsOnBoundary
        }
        TestSupport.expect(split, "the jump never stopped inside the emoji")
        harness.touchUp(touch)
        let pressedAt = harness.time
        harness.press(.character("Q"))
        while !harness.document.text.contains("Q"), harness.time < pressedAt + 2 { harness.frame() }
        TestSupport.expect(harness.time <= pressedAt + KeyboardEditor.maximumWait + 2.0 / 120,
                           "the key waited \(harness.time - pressedAt) s")
        harness.settle()
        TestSupport.expect(harness.document.text.contains("\u{1F44D}\u{1F3FD}"), "the emoji was split: \(harness.document.text)")
    }

    private static func testLateReportsOfAFinishedGestureAreOurs() {
        // A gesture a key settled at once was still owed its reports; arriving later (even after
        // `syncTimeout`), they are known as its own, not outside changes that would start the space or
        // shift timing over.
        let harness = KeyboardHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, callbackFrames: 45))
        harness.gesture(dx: -30, events: 1)
        harness.press(.character("x"))
        harness.settle()
        TestSupport.expect(!harness.outcomes.contains(.outside), "a late report taken as outside: \(harness.outcomes)")
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
    }

    private static func testCancelledDeleteRevokesWhatWaits() {
        // The fourth review's P1, now for deletions waiting on a probe: a cancelled press revokes them;
        // what was typed with them still runs.
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        harness.editor.heldDelete(.character, token: 7, field: harness.field, now: harness.time)
        harness.type("ab")
        harness.editor.revoke(token: 7)
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi ab\u{1F44D}\u{1F3FD}")
    }

    private static func testDictationWaitsLikeAKey() {
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        harness.press(.character("a"))
        harness.editor.insertDictation(" invented words", now: harness.time)
        harness.press(.character("b"))
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi a invented wordsb\u{1F44D}\u{1F3FD}")
    }

    private static func testHidingRunsWaitingKeysInTheirField() {
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        harness.type("ab")
        harness.editor.hide(now: harness.time)
        TestSupport.expect(harness.editor.pendingKeys.isEmpty, "keys kept after hiding")
        TestSupport.expect(harness.document.text.contains("ab"), "keys dropped on hiding: \(harness.document.text)")
        TestSupport.expectEqual(harness.document.text.replacingOccurrences(of: "ab", with: ""), "Hi \u{1F44D}\u{1F3FD}")
    }

    // MARK: Torture

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

    private static func testKeyWaitsForTheLateReportOfAJumpPastTheEdge() {
        // UIKit answers an adjustment at once, provisionally, with the caret clamped to the text it last
        // reported; only the report shows where it went. A jump one unit past the end of what the proxy
        // shows (the sentence) lands inside the emoji there, and its report comes after the session's
        // timeout. A key pressed meanwhile waits for it (within its deadline) and lands after the emoji.
        let harness = KeyboardHarness(FakeTextHost(text: "Ab. Cd. \u{1F44D} Ef", caret: 5, unit: .utf16, model: .uikit,
                                                   callbackFrames: 40, provisionalContext: true))
        harness.gesture(dy: 20, events: 1)
        // One jump past the end of the sentence, which lands one unit into the emoji.
        TestSupport.expectEqual(harness.document.host.adjustmentCount, 1)
        TestSupport.expectEqual(harness.document.host.caret, 9)
        harness.press(.character("x"))
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Ab. Cd. \u{1F44D}x Ef")
        TestSupport.expect(harness.document.host.caretIsOnBoundary, "the caret was left inside the emoji")
        TestSupport.expect(!harness.outcomes.contains(.outside), "the jump's own report taken as an outside change")
        // The key a while after the jump, its report later than the session's own settling time: the
        // key's deadline, not the session's, bounds the wait.
        let later = KeyboardHarness(FakeTextHost(text: "Ab. Cd. \u{1F44D} Ef", caret: 5, unit: .utf16, model: .uikit,
                                                 callbackFrames: 66, provisionalContext: true))
        later.gesture(dy: 20, events: 1)
        later.frames(24)
        later.press(.character("x"))
        later.settle()
        TestSupport.expectEqual(later.document.text, "Ab. Cd. \u{1F44D}x Ef")
    }

    private static func testBothReportsOfAMoveAreTheGesturesOwn() {
        // WebKit reports each adjustment twice. A key at the lift ends the gesture with its move's reports
        // still to come: both are the gesture's, so neither is an outside change that resets the typing
        // (two spaces still type ". "), though the proxy showed the key late and its own state with it.
        var host = FakeTextHost(text: "Alpha beta", unit: .grapheme, lagFrames: 2, callbackFrames: 2)
        host.reportsAsIssuedFirst = true
        host.editContextLagFrames = 2
        let harness = KeyboardHarness(host)
        harness.gesture(dx: -50, events: 1)
        harness.press(.space)
        harness.frames(6)
        harness.press(.space)
        harness.settle()
        TestSupport.expect(!harness.outcomes.contains(.outside), "a report of the gesture taken as an outside change")
        TestSupport.expectEqual(harness.document.text, "Alpha.  beta")
    }

    /// Seeds 1...60 and earlier failures by default; `TORTURE_SEEDS=first-last` runs others (a stress run
    /// on the Mac). Prints the failing seed and the smallest failing number of steps.
    private static func testTypingTorture() {
        // Seeds a stress run found failing in round 8, each a bug since fixed.
        var seeds = Array(UInt64(1) ... 60) + [75, 148, 161, 330, 521, 528, 566, 905, 940, 1001]
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
/// to the field at touch-down; a focus change ends only touches bound elsewhere), the held delete key's
/// timer, the space bar's hold, the trackpad's frames, and host callbacks between frames.
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
    /// A session ended (completed or not), before the keys waiting on it run.
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
        editor.reset(numeric: false)
    }

    var field: UUID? { document.documentID }

    /// Nothing is left to happen: no session, no waiting keys or gesture, no touches or timers, no
    /// callbacks to come, and the proxy shows the field as it is.
    var isQuiet: Bool {
        !trackpad.isActive && !editor.isWaiting && document.pendingCallbacks == 0 && !document.host.hasCallbacksToCome
            && !document.host.isContextStale && model.touches.isEmpty && model.trackpadTouch == nil && deleteDue == nil
    }

    // MARK: Frames

    /// One display frame: due host events and callbacks reach the editor (as `KeyboardInput` delivers
    /// them), timers fire, waiting keys get their look, then the trackpad's frame.
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
                editor.heldDelete(fired.unit, token: due.token, field: fired.field, now: time)
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

    private func deliver(textChanged: Bool) -> EditingCore.CallbackOutcome {
        let outcome = editor.hostChanged(textChanged: textChanged, now: time)
        if outcome == .newField {
            if let token = deleteKey.cancel(ifBoundElsewhereThan: document.documentID) {
                editor.revoke(token: token)
                deleteDue = nil
            }
            perform(model.cancelTouches(boundElsewhereThan: document.documentID))
        }
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

    func tap(_ action: KeyAction) {
        touchUp(touchDown(action))
    }

    private func applyLayer() {
        let layer = editor.typing.layer
        guard layer != model.layer else { return }
        perform(model.keysChanged(KeyboardLayout.keys(for: layer, metrics: Self.metrics, showsGlobe: false), layer: layer))
    }

    private func perform(_ effects: [KeyTouchModel.Effect]) {
        for effect in effects {
            switch effect {
            case .type(let action, let field):
                editor.press(action, field: field, at: time, now: time)
            case .beginDelete:
                let press = deleteKey.began(at: time, documentID: document.documentID)
                deleteDue = (press.token, time + press.firstAt, time)
            case .endDelete(let cancelled):
                deleteDue = nil
                guard let ended = deleteKey.ended(cancelled: cancelled, documentID: document.documentID) else { break }
                if cancelled {
                    editor.revoke(token: ended.token)
                } else if ended.deleteOnce {
                    editor.heldDelete(.character, token: ended.token, field: ended.field, now: time)
                }
            case .startHoldTimer(let id):
                holdDue[id] = time + model.parameters.holdDuration
            case .cancelHoldTimer(let id):
                holdDue[id] = nil
            case .beginTrackpad:
                editor.beginTrackpad(layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000, now: time)
            case .endTrackpad(let cancelled):
                editor.trackpadEnded(at: time, cancelled: cancelled)
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
        editor.trackpadMoved(dx: dx, dy: dy, timestamp: time)
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
