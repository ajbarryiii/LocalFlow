import Foundation

enum KeyTouchModelTests {
    static var tests: [TestCase] {
        [
            ("charactersTypeAtReleaseWithTheTouchDownKey", testCharactersTypeAtReleaseWithTheTouchDownKey),
            ("tapRollingOntoAFunctionKeyStillTypesTheLetter", testTapRollingOntoAFunctionKeyStillTypesTheLetter),
            ("heldTouchSurvivesALayerChange", testHeldTouchSurvivesALayerChange),
            ("heldCharacterKeepsItsKeyThroughARebuild", testHeldCharacterKeepsItsKeyThroughARebuild),
            ("spaceRolloverKeepsPressOrder", testSpaceRolloverKeepsPressOrder),
            ("returnRolloverKeepsPressOrder", testReturnRolloverKeepsPressOrder),
            ("characterRolloverCommitsOnce", testCharacterRolloverCommitsOnce),
            ("cancelledCharacterTypesNothing", testCancelledCharacterTypesNothing),
            ("holdTurnsSpaceIntoTheTrackpad", testHoldTurnsSpaceIntoTheTrackpad),
            ("holdSlopIsAStraightLine", testHoldSlopIsAStraightLine),
            ("draggedSpaceStillTypesASpace", testDraggedSpaceStillTypesASpace),
            ("slideFromTheLayerKeyTypesAndReturns", testSlideFromTheLayerKeyTypesAndReturns),
            ("deleteSurvivesALayerChange", testDeleteSurvivesALayerChange),
            ("vanishedFunctionKeysAreDropped", testVanishedFunctionKeysAreDropped),
            ("pressedKeysAndCallout", testPressedKeysAndCallout),
            ("cancelAllEndsEverything", testCancelAllEndsEverything),
            ("cancelledDeleteIsNotARelease", testCancelledDeleteIsNotARelease),
            ("keysCarryTheFieldOfTheirPress", testKeysCarryTheFieldOfTheirPress),
            ("fieldChangeBindsOrEndsFingers", testFieldChangeBindsOrEndsFingers),
            ("fieldChangeDropsHeldCharacters", testFieldChangeDropsHeldCharacters),
            ("swipeThresholdIsHalfALetterPitch", testSwipeThresholdIsHalfALetterPitch),
            ("dragPastTheThresholdBecomesASwipe", testDragPastTheThresholdBecomesASwipe),
            ("swipeNeedsEveryCondition", testSwipeNeedsEveryCondition),
            ("swipeThresholdBoundary", testSwipeThresholdBoundary),
            ("anyCoalescedSamplePastTheThresholdSwipes", testAnyCoalescedSamplePastTheThresholdSwipes),
            ("flickPastTheThresholdAtTheLiftSwipes", testFlickPastTheThresholdAtTheLiftSwipes),
            ("swipeSamplesStartAtTouchDownAndKeepEveryCoalescedTouch", testSwipeSamplesStartAtTouchDownAndKeepEveryCoalescedTouch),
            ("cancelledSwipeEmitsNothing", testCancelledSwipeEmitsNothing),
            ("touchesAreIgnoredDuringASwipe", testTouchesAreIgnoredDuringASwipe),
            ("swipeKeepsTheFieldOfItsPress", testSwipeKeepsTheFieldOfItsPress),
            ("withoutSwipeTypingALongDragTypesTheTouchDownLetter", testWithoutSwipeTypingALongDragTypesTheTouchDownLetter),
            ("swipeTrailKeepsTheLastWindowOfSamples", testSwipeTrailKeepsTheLastWindowOfSamples),
            ("swipeTrailKeepsAtLeastTwoPoints", testSwipeTrailKeepsAtLeastTwoPoints),
            ("swipeTrailToleratesDisorderedTimestamps", testSwipeTrailToleratesDisorderedTimestamps),
            ("swipeTrailTapersAndFadesTowardsItsTail", testSwipeTrailTapersAndFadesTowardsItsTail),
        ]
    }

    private static let metrics = KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight)

    private static func keys(_ layer: KeyboardLayer) -> [PlacedKey] {
        KeyboardLayout.keys(for: layer, metrics: metrics, showsGlobe: false)
    }

    private static func model(_ layer: KeyboardLayer = .letters, swipe: Bool = false) -> KeyTouchModel {
        var model = KeyTouchModel()
        model.swipeEnabled = swipe
        _ = model.keysChanged(keys(layer), layer: layer)
        return model
    }

    private static func center(_ action: KeyAction, _ layer: KeyboardLayer = .letters) -> (x: Double, y: Double) {
        let key = keys(layer).first { $0.action == action }!
        return (key.frame.midX, key.frame.midY)
    }

    private static func frame(_ action: KeyAction, _ layer: KeyboardLayer = .letters) -> KeyRect {
        keys(layer).first { $0.action == action }!.frame
    }

    /// Half a letter-key pitch in the portrait layout under test: (letterWidth + keyGap) / 2.
    private static var threshold: Double { (metrics.letterWidth + metrics.keyGap) / 2 }

    private static func testCharactersTypeAtReleaseWithTheTouchDownKey() {
        // Typing model v4: a character's touch-down only signals the key (`.keyDown`); it types at release,
        // and the key is the one under the touch-down point however far the finger moved.
        var model = model()
        let a = center(.character("a")), s = center(.character("s"))
        TestSupport.expectEqual(model.began(1, x: a.x, y: a.y), [.keyDown])
        TestSupport.expectEqual(model.calloutAction, .character("a"))
        TestSupport.expectEqual(model.moved(1, x: s.x, y: s.y), [])
        TestSupport.expectEqual(model.calloutAction, .character("a"))
        TestSupport.expectEqual(model.ended(1, x: s.x, y: s.y), [.type(.character("a"))])
        TestSupport.expect(model.touches.isEmpty, "touch kept")
        // Unknown touches do nothing.
        TestSupport.expectEqual(model.ended(9, x: a.x, y: a.y), [])
        TestSupport.expectEqual(model.moved(9, x: a.x, y: a.y), [])
    }

    private static func testTapRollingOntoAFunctionKeyStillTypesTheLetter() {
        // Regression (device, 2026-10-13): a tap near a letter's edge that rolled a few points onto space,
        // delete or Shift before lifting typed nothing. The letter is chosen at touch-down and typed at the
        // lift (v4); the function key under the lift does nothing.
        let cases: [(KeyAction, KeyAction)] = [
            (.character("v"), .space), (.character("m"), .delete), (.character("z"), .shift),
            (.character("l"), .returnKey),
        ]
        for (letter, function) in cases {
            var model = model()
            let start = frame(letter), end = center(function)
            let x = start.midX, y = start.maxY - 1
            TestSupport.expectEqual(model.began(1, x: x, y: y), [.keyDown])
            TestSupport.expectEqual(model.moved(1, x: end.x, y: end.y), [])
            TestSupport.expectEqual(model.pressedActions, [])
            TestSupport.expectEqual(model.ended(1, x: end.x, y: end.y), [.type(letter)])
        }
    }

    private static func testHeldTouchSurvivesALayerChange() {
        // Regression: a finger slid from a letter onto Return (index 30 of 31 letter-layer keys), a
        // second finger pressed 123, and the first finger's lift read index 30 of the 30 number keys.
        // Held fingers follow keys by action, never by index; the held letter commits at the second
        // finger's touch-down, before the layer key acts.
        var model = model()
        let q = center(.character("q")), returnKey = center(.returnKey), numbers = center(.layer(.numbers))
        _ = model.began(1, x: q.x, y: q.y)
        _ = model.moved(1, x: returnKey.x, y: returnKey.y)
        TestSupport.expectEqual(model.began(2, x: numbers.x, y: numbers.y),
                                [.keyDown, .type(.character("q")), .type(.layer(.numbers))])
        TestSupport.expectEqual(model.keysChanged(keys(.numbers), layer: .numbers), [])
        TestSupport.expectEqual(keys(.numbers).count, 30)
        TestSupport.expectEqual(model.touches.first { $0.id == 1 }?.action, .character("q"))
        TestSupport.expectEqual(model.touches.first { $0.id == 2 }?.action, .layer(.letters))
        TestSupport.expectEqual(model.ended(1, x: returnKey.x, y: returnKey.y), [])
        TestSupport.expectEqual(model.ended(2, x: numbers.x, y: numbers.y), [])
    }

    private static func testHeldCharacterKeepsItsKeyThroughARebuild() {
        // v4: a held character is never hit-tested again, not even when the keys are rebuilt under it (the
        // keyboard returning to letters, say): it types the key it touched down on.
        var model = model(.numbers)
        let one = center(.character("1"), .numbers)
        TestSupport.expectEqual(model.began(1, x: one.x, y: one.y), [.keyDown])
        TestSupport.expectEqual(model.keysChanged(keys(.letters), layer: .letters), [])
        TestSupport.expectEqual(model.touches.first?.action, .character("1"))
        TestSupport.expectEqual(model.ended(1, x: one.x, y: one.y), [.type(.character("1"))])
    }

    private static func testSpaceRolloverKeepsPressOrder() {
        // Regression: space down, x down and up, space up before the hold gave "hellox " instead of
        // "hello x". The space commits first, in press order, and its hold timer stops.
        var model = model()
        let space = center(.space), x = center(.character("x"))
        TestSupport.expectEqual(model.began(1, x: space.x, y: space.y), [.keyDown, .startHoldTimer(1)])
        TestSupport.expectEqual(model.began(2, x: x.x, y: x.y), [.keyDown, .cancelHoldTimer(1), .type(.space)])
        TestSupport.expectEqual(model.ended(2, x: x.x, y: x.y), [.type(.character("x"))])
        TestSupport.expectEqual(model.ended(1, x: space.x, y: space.y), [.cancelHoldTimer(1)])
        // A committed space can no longer become the trackpad.
        var held = self.model()
        _ = held.began(1, x: space.x, y: space.y)
        _ = held.began(2, x: x.x, y: x.y)
        TestSupport.expectEqual(held.holdElapsed(1), [])
        TestSupport.expect(!held.isTrackpadActive, "committed space became the trackpad")
    }

    private static func testReturnRolloverKeepsPressOrder() {
        var model = model()
        let returnKey = center(.returnKey), a = center(.character("a"))
        TestSupport.expectEqual(model.began(1, x: returnKey.x, y: returnKey.y), [.keyDown])
        TestSupport.expectEqual(model.began(2, x: a.x, y: a.y), [.keyDown, .type(.returnKey)])
        TestSupport.expectEqual(model.ended(2, x: a.x, y: a.y), [.type(.character("a"))])
        TestSupport.expectEqual(model.ended(1, x: returnKey.x, y: returnKey.y), [])
    }

    private static func testCharacterRolloverCommitsOnce() {
        // v4 rollover: each new finger commits the held letters first, in press order; a committed letter
        // types nothing more at its lift, and moves change nothing.
        var model = model()
        let h = center(.character("h")), i = center(.character("i")), space = center(.space)
        TestSupport.expectEqual(model.began(1, x: h.x, y: h.y), [.keyDown])
        TestSupport.expectEqual(model.began(2, x: i.x, y: i.y), [.keyDown, .type(.character("h"))])
        TestSupport.expectEqual(model.began(3, x: space.x, y: space.y), [.keyDown, .type(.character("i")), .startHoldTimer(3)])
        TestSupport.expectEqual(model.moved(1, x: i.x, y: i.y), [])
        TestSupport.expectEqual(model.ended(1, x: i.x, y: i.y), [])
        TestSupport.expectEqual(model.ended(2, x: i.x, y: i.y), [])
        TestSupport.expectEqual(model.ended(3, x: space.x, y: space.y), [.cancelHoldTimer(3), .type(.space)])
    }

    private static func testCancelledCharacterTypesNothing() {
        // v4: a system-cancelled character touch is not a release: it types nothing.
        var model = model()
        let a = center(.character("a"))
        _ = model.began(1, x: a.x, y: a.y)
        TestSupport.expectEqual(model.cancelled(1), [])
        TestSupport.expect(model.touches.isEmpty, "touch kept")
        TestSupport.expectEqual(model.ended(1, x: a.x, y: a.y), [])
        // Nor when the key area drops every touch.
        _ = model.began(2, x: a.x, y: a.y)
        TestSupport.expectEqual(model.cancelAll(), [])
        TestSupport.expectEqual(model.ended(2, x: a.x, y: a.y), [])
    }

    private static func testHoldTurnsSpaceIntoTheTrackpad() {
        var model = model()
        let space = center(.space), a = center(.character("a"))
        _ = model.began(1, x: space.x, y: space.y)
        TestSupport.expectEqual(model.holdElapsed(1), [.cancelHoldTimer(1), .beginTrackpad])
        TestSupport.expect(model.isTrackpadActive, "not in trackpad mode")
        TestSupport.expectEqual(model.trackpadTouch, 1)
        // Other fingers are ignored while the trackpad runs; the trackpad finger's moves are the view's.
        TestSupport.expectEqual(model.began(2, x: a.x, y: a.y), [])
        TestSupport.expectEqual(model.moved(1, x: a.x, y: a.y), [])
        TestSupport.expectEqual(model.ended(2, x: a.x, y: a.y), [])
        // A lift and a system cancellation end it differently.
        TestSupport.expectEqual(model.ended(1, x: a.x, y: a.y), [.endTrackpad(cancelled: false)])
        var cancelled = self.model()
        _ = cancelled.began(1, x: space.x, y: space.y)
        _ = cancelled.holdElapsed(1)
        TestSupport.expectEqual(cancelled.cancelled(1), [.endTrackpad(cancelled: true)])
        // A hold timer for a finger already lifted does nothing.
        TestSupport.expectEqual(cancelled.holdElapsed(1), [])
    }

    private static func testHoldSlopIsAStraightLine() {
        // Measured: 16.0 pt from the touch-down point still activates at the timer; 16.33 pt does not.
        var model = model()
        let space = center(.space)
        _ = model.began(1, x: space.x, y: space.y)
        TestSupport.expectEqual(model.moved(1, x: space.x + 16, y: space.y), [])
        TestSupport.expectEqual(model.moved(1, x: space.x, y: space.y - 16), [])
        TestSupport.expectEqual(model.moved(1, x: space.x + 11.3, y: space.y + 11.3), [])
        TestSupport.expectEqual(model.moved(1, x: space.x + 12, y: space.y + 12), [.cancelHoldTimer(1)])
        // A late timer cannot start the trackpad, and lifting over space still types a space.
        TestSupport.expectEqual(model.holdElapsed(1), [])
        TestSupport.expectEqual(model.moved(1, x: space.x, y: space.y), [])
        TestSupport.expectEqual(model.ended(1, x: space.x, y: space.y), [.cancelHoldTimer(1), .type(.space)])
    }

    private static func testDraggedSpaceStillTypesASpace() {
        // Measured: a fast drag with no hold does not start the trackpad and types a space, even where
        // the finger lifts over another key.
        var model = model()
        let space = center(.space), n = center(.character("n"))
        _ = model.began(1, x: space.x, y: space.y)
        TestSupport.expectEqual(model.moved(1, x: n.x, y: n.y), [.cancelHoldTimer(1)])
        TestSupport.expectEqual(model.ended(1, x: n.x, y: n.y), [.cancelHoldTimer(1), .type(.space)])
    }

    private static func testSlideFromTheLayerKeyTypesAndReturns() {
        var model = model()
        let numbersKey = center(.layer(.numbers)), one = center(.character("1"), .numbers)
        TestSupport.expectEqual(model.began(1, x: numbersKey.x, y: numbersKey.y), [.keyDown, .type(.layer(.numbers))])
        _ = model.keysChanged(keys(.numbers), layer: .numbers)
        _ = model.moved(1, x: one.x, y: one.y)
        TestSupport.expectEqual(model.ended(1, x: one.x, y: one.y), [.type(.character("1")), .type(.layer(.letters))])
        // A plain tap on 123 only switches.
        var tap = self.model()
        _ = tap.began(1, x: numbersKey.x, y: numbersKey.y)
        _ = tap.keysChanged(keys(.numbers), layer: .numbers)
        TestSupport.expectEqual(tap.ended(1, x: numbersKey.x, y: numbersKey.y), [])
    }

    private static func testDeleteSurvivesALayerChange() {
        var model = model()
        let delete = center(.delete), numbersKey = center(.layer(.numbers))
        TestSupport.expectEqual(model.began(1, x: delete.x, y: delete.y), [.keyDown, .beginDelete])
        TestSupport.expectEqual(model.began(2, x: numbersKey.x, y: numbersKey.y), [.keyDown, .type(.layer(.numbers))])
        TestSupport.expectEqual(model.keysChanged(keys(.numbers), layer: .numbers), [])
        TestSupport.expectEqual(model.ended(1, x: delete.x, y: delete.y), [.endDelete(cancelled: false)])
    }

    private static func testVanishedFunctionKeysAreDropped() {
        var model = model()
        let shift = center(.shift)
        TestSupport.expectEqual(model.began(1, x: shift.x, y: shift.y), [.keyDown, .type(.shift)])
        // The numbers layer has no shift key: the finger is dropped without effect.
        TestSupport.expectEqual(model.keysChanged(keys(.numbers), layer: .numbers), [])
        TestSupport.expect(model.touches.isEmpty, "a finger on a vanished key")
        TestSupport.expectEqual(model.ended(1, x: shift.x, y: shift.y), [])
    }

    private static func testPressedKeysAndCallout() {
        var model = model()
        let a = center(.character("a")), space = center(.space), delete = center(.delete)
        _ = model.began(1, x: a.x, y: a.y)
        // The callout shows from touch-down, while the finger is down, before and after the letter commits.
        TestSupport.expectEqual(model.calloutAction, .character("a"))
        TestSupport.expectEqual(model.pressedActions, [])
        _ = model.began(2, x: space.x, y: space.y)
        TestSupport.expectEqual(model.calloutAction, .character("a"))
        TestSupport.expectEqual(model.pressedActions, [.space])
        _ = model.ended(1, x: a.x, y: a.y)
        TestSupport.expectEqual(model.calloutAction, nil)
        _ = model.began(3, x: delete.x, y: delete.y)
        TestSupport.expectEqual(model.pressedActions, [.delete])
        _ = model.ended(3, x: delete.x, y: delete.y)
        TestSupport.expectEqual(model.pressedActions, [])
        // A slide from the layer key shows the character under the finger.
        var slide = self.model()
        let numbersKey = center(.layer(.numbers)), one = center(.character("1"), .numbers)
        _ = slide.began(1, x: numbersKey.x, y: numbersKey.y)
        _ = slide.keysChanged(keys(.numbers), layer: .numbers)
        _ = slide.moved(1, x: one.x, y: one.y)
        TestSupport.expectEqual(slide.calloutAction, .character("1"))
    }

    private static func testCancelledDeleteIsNotARelease() {
        // Regression: a delete touch the system cancels (or the menu opening over the keys) ended like a
        // release, and a release before the first deletion deletes once.
        var model = model()
        let delete = center(.delete)
        TestSupport.expectEqual(model.began(1, x: delete.x, y: delete.y), [.keyDown, .beginDelete])
        TestSupport.expectEqual(model.cancelled(1), [.endDelete(cancelled: true)])
        var released = self.model()
        _ = released.began(1, x: delete.x, y: delete.y)
        TestSupport.expectEqual(released.ended(1, x: delete.x, y: delete.y), [.endDelete(cancelled: false)])
    }

    private static func testCancelAllEndsEverything() {
        var model = model()
        let space = center(.space), delete = center(.delete)
        _ = model.began(1, x: delete.x, y: delete.y)
        _ = model.began(2, x: space.x, y: space.y)
        // Cancelled, not released: a cancelled tap on delete deletes nothing.
        TestSupport.expectEqual(model.cancelAll(), [.endDelete(cancelled: true), .cancelHoldTimer(2)])
        TestSupport.expect(model.touches.isEmpty, "touches kept")
        var trackpad = self.model()
        _ = trackpad.began(1, x: space.x, y: space.y)
        _ = trackpad.holdElapsed(1)
        TestSupport.expectEqual(trackpad.cancelAll(), [.endTrackpad(cancelled: true)])
        TestSupport.expect(!trackpad.isTrackpadActive, "trackpad kept")
    }
}

extension KeyTouchModelTests {
    fileprivate static func testKeysCarryTheFieldOfTheirPress() {
        // The round-6 review's P1: a letter pressed in field A was typed into field B on release. Each
        // finger keeps the field of its touch-down, and what it types carries it to its release or rollover.
        let fieldA = UUID(), fieldB = UUID()
        var model = model()
        let a = center(.character("a")), s = center(.character("s"))
        let space = center(.space), enter = center(.returnKey)
        TestSupport.expectEqual(model.began(1, x: a.x, y: a.y, field: fieldA), [.keyDown])
        TestSupport.expectEqual(model.began(2, x: s.x, y: s.y, field: fieldB), [.keyDown, .type(.character("a"), field: fieldA)])
        TestSupport.expectEqual(model.ended(2, x: s.x, y: s.y), [.type(.character("s"), field: fieldB)])
        TestSupport.expectEqual(model.ended(1, x: a.x, y: a.y), [])
        _ = model.began(3, x: space.x, y: space.y, field: fieldA)
        TestSupport.expectEqual(model.ended(3, x: space.x, y: space.y), [.cancelHoldTimer(3), .type(.space, field: fieldA)])
        _ = model.began(4, x: enter.x, y: enter.y, field: fieldA)
        TestSupport.expectEqual(model.began(5, x: a.x, y: a.y, field: fieldB), [.keyDown, .type(.returnKey, field: fieldA)])
        TestSupport.expectEqual(model.ended(5, x: a.x, y: a.y), [.type(.character("a"), field: fieldB)])
    }

    fileprivate static func testFieldChangeBindsOrEndsFingers() {
        // The round-8 review's P1 (ARCHITECTURE.md, "Typing model v2"): a finger that touched down before
        // any identity kept none, and through nil → A → B released into B. A field change binds such
        // fingers to it, and ends without acting those bound to another identified field. Letters already
        // committed by rollover are never ended.
        let fieldA = UUID(), fieldB = UUID()
        var model = model()
        let a = center(.character("a")), s = center(.character("s")), delete = center(.delete)
        let space = center(.space)
        _ = model.began(1, x: a.x, y: a.y, field: nil)
        TestSupport.expectEqual(model.began(2, x: delete.x, y: delete.y, field: nil),
                                [.keyDown, .type(.character("a")), .beginDelete])
        TestSupport.expectEqual(model.fieldChanged(to: nil), [])
        TestSupport.expectEqual(model.fieldChanged(to: fieldA), [])
        TestSupport.expectEqual(model.touches.map(\.field), [fieldA, fieldA])
        _ = model.began(3, x: s.x, y: s.y, field: fieldA)
        TestSupport.expectEqual(model.began(4, x: space.x, y: space.y, field: fieldA),
                                [.keyDown, .type(.character("s"), field: fieldA), .startHoldTimer(4)])
        TestSupport.expectEqual(model.fieldChanged(to: fieldB), [.endDelete(cancelled: true), .cancelHoldTimer(4)])
        TestSupport.expectEqual(model.touches.map(\.id), [1, 3])
        TestSupport.expect(model.touches.allSatisfy(\.committed), "a committed letter was ended")
        // Bound to A and released in A: typed, carrying A.
        var staying = Self.model()
        _ = staying.began(1, x: space.x, y: space.y, field: nil)
        _ = staying.fieldChanged(to: fieldA)
        TestSupport.expectEqual(staying.ended(1, x: space.x, y: space.y), [.cancelHoldTimer(1), .type(.space, field: fieldA)])
    }

    fileprivate static func testFieldChangeDropsHeldCharacters() {
        // v4: a held letter has typed nothing yet; a change to another identified field drops it, so its
        // lift types nothing. Bound to the new field (or to none yet), it types there at its lift.
        let fieldA = UUID(), fieldB = UUID()
        let a = center(.character("a"))
        var model = model()
        _ = model.began(1, x: a.x, y: a.y, field: fieldA)
        TestSupport.expectEqual(model.fieldChanged(to: fieldB), [])
        TestSupport.expect(model.touches.isEmpty, "a held letter survived the field change")
        TestSupport.expectEqual(model.calloutAction, nil)
        TestSupport.expectEqual(model.ended(1, x: a.x, y: a.y), [])
        var same = self.model()
        _ = same.began(1, x: a.x, y: a.y, field: fieldA)
        TestSupport.expectEqual(same.fieldChanged(to: fieldA), [])
        TestSupport.expectEqual(same.ended(1, x: a.x, y: a.y), [.type(.character("a"), field: fieldA)])
        var unbound = self.model()
        _ = unbound.began(1, x: a.x, y: a.y, field: nil)
        TestSupport.expectEqual(unbound.fieldChanged(to: fieldB), [])
        TestSupport.expectEqual(unbound.ended(1, x: a.x, y: a.y), [.type(.character("a"), field: fieldB)])
    }
}

// MARK: Swipe gesture (ARCHITECTURE.md, "Typing model v4 and swipe typing")

extension KeyTouchModelTests {
    fileprivate static func testSwipeThresholdIsHalfALetterPitch() {
        // Half the pitch between adjacent letter keys: about 20 pt in portrait.
        let model = model()
        let q = center(.character("q")), w = center(.character("w"))
        TestSupport.expect(abs(model.swipeThreshold - threshold) < 1e-9, "threshold \(model.swipeThreshold) != \(threshold)")
        TestSupport.expect(abs(model.swipeThreshold - (w.x - q.x) / 2) < 1e-9, "threshold is not half the q–w pitch")
        TestSupport.expect(model.swipeThreshold > 19 && model.swipeThreshold < 21, "threshold \(model.swipeThreshold)")
        // Derived from the letter keys, wherever they were laid out (a compact landscape keyboard here).
        var landscape = KeyTouchModel()
        let compact = KeyboardMetrics(width: 852, height: KeyboardMetrics.compactHeight)
        _ = landscape.keysChanged(KeyboardLayout.keys(for: .letters, metrics: compact, showsGlobe: true), layer: .letters)
        TestSupport.expect(abs(landscape.swipeThreshold - (compact.letterWidth + compact.keyGap) / 2) < 1e-9,
                           "landscape threshold \(landscape.swipeThreshold)")
    }

    fileprivate static func testDragPastTheThresholdBecomesASwipe() {
        let field = UUID()
        var model = model(swipe: true)
        let d = center(.character("d")), k = center(.character("k"))
        TestSupport.expectEqual(model.began(1, x: d.x, y: d.y, t: 5, field: field), [.keyDown])
        TestSupport.expectEqual(model.calloutAction, .character("d"))
        TestSupport.expectEqual(model.moved(1, x: k.x, y: k.y, t: 5.1), [])
        TestSupport.expect(model.isSwipeActive, "a long drag on a letter did not become a swipe")
        TestSupport.expectEqual(model.swipeTouch, 1)
        // It types nothing, its callout ends, and no key is drawn pressed.
        TestSupport.expect(model.touches.isEmpty, "the swipe is still a key touch")
        TestSupport.expectEqual(model.calloutAction, nil)
        TestSupport.expectEqual(model.pressedActions, [])
                // The lift where and when the last move was is not counted twice.
        TestSupport.expectEqual(model.ended(1, x: k.x, y: k.y, t: 5.1),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 5), SwipeSample(x: k.x, y: k.y, t: 5.1)], field: field)])
        TestSupport.expect(!model.isSwipeActive, "the swipe outlived its lift")
        TestSupport.expectEqual(model.swipeTouch, nil)
    }

    fileprivate static func testSwipeNeedsEveryCondition() {
        let far = 3 * threshold
        // Swipe typing off: a tap, typing the touch-down letter.
        var disabled = model(swipe: false)
        let d = center(.character("d"))
        _ = disabled.began(1, x: d.x, y: d.y)
        TestSupport.expectEqual(disabled.moved(1, x: d.x + far, y: d.y), [])
        TestSupport.expect(!disabled.isSwipeActive, "a swipe with swipe typing off")
        TestSupport.expectEqual(disabled.ended(1, x: d.x + far, y: d.y), [.type(.character("d"))])
        // Another layer: the number keys are taps.
        var numbers = model(.numbers, swipe: true)
        let five = center(.character("5"), .numbers)
        _ = numbers.began(1, x: five.x, y: five.y)
        TestSupport.expectEqual(numbers.moved(1, x: five.x + far, y: five.y), [])
        TestSupport.expect(!numbers.isSwipeActive, "a swipe on the numbers layer")
        TestSupport.expectEqual(numbers.ended(1, x: five.x + far, y: five.y), [.type(.character("5"))])
        // Started on a function key: space drags type a space, a delete is a delete, 123 slides.
        var space = model(swipe: true)
        let spaceKey = center(.space)
        _ = space.began(1, x: spaceKey.x, y: spaceKey.y)
        _ = space.moved(1, x: spaceKey.x + far, y: spaceKey.y)
        TestSupport.expect(!space.isSwipeActive, "a swipe from the space bar")
        TestSupport.expectEqual(space.ended(1, x: spaceKey.x + far, y: spaceKey.y), [.cancelHoldTimer(1), .type(.space)])
        for function in [KeyAction.delete, .shift, .returnKey, .layer(.numbers)] {
            var model = model(swipe: true)
            let start = center(function), a = center(.character("a"))
            _ = model.began(1, x: start.x, y: start.y)
            _ = model.moved(1, x: a.x, y: a.y)
            TestSupport.expect(!model.isSwipeActive, "a swipe from \(function)")
        }
        // Committed by rollover: the letter typed, so the drag is no swipe even once it is the only finger.
        var committed = model(swipe: true)
        let s = center(.character("s"))
        _ = committed.began(1, x: d.x, y: d.y)
        TestSupport.expectEqual(committed.began(2, x: s.x, y: s.y), [.keyDown, .type(.character("d"))])
        TestSupport.expectEqual(committed.ended(2, x: s.x, y: s.y), [.type(.character("s"))])
        TestSupport.expectEqual(committed.moved(1, x: d.x + far, y: d.y), [])
        TestSupport.expect(!committed.isSwipeActive, "a swipe from a committed letter")
        TestSupport.expectEqual(committed.ended(1, x: d.x + far, y: d.y), [])
        // Another finger held: the newest letter is uncommitted, but it is not alone.
        var twoFingers = model(swipe: true)
        _ = twoFingers.began(1, x: d.x, y: d.y)
        _ = twoFingers.began(2, x: s.x, y: s.y)
        TestSupport.expectEqual(twoFingers.moved(2, x: s.x + far, y: s.y), [])
        TestSupport.expect(!twoFingers.isSwipeActive, "a swipe beside another finger")
        TestSupport.expectEqual(twoFingers.ended(2, x: s.x + far, y: s.y), [.type(.character("s"))])
        // A held Shift (never committed by rollover) also counts as another finger.
        var shifted = model(swipe: true)
        let shift = center(.shift)
        _ = shifted.began(1, x: shift.x, y: shift.y)
        TestSupport.expectEqual(shifted.began(2, x: d.x, y: d.y), [.keyDown])
        TestSupport.expectEqual(shifted.moved(2, x: d.x + far, y: d.y), [])
        TestSupport.expect(!shifted.isSwipeActive, "a swipe while Shift is held")
        TestSupport.expectEqual(shifted.ended(2, x: d.x + far, y: d.y), [.type(.character("d"))])
        // Once the other finger has lifted, the drag of an uncommitted letter may become one.
        var lifted = model(swipe: true)
        _ = lifted.began(1, x: shift.x, y: shift.y)
        _ = lifted.began(2, x: d.x, y: d.y)
        _ = lifted.ended(1, x: shift.x, y: shift.y)
        TestSupport.expectEqual(lifted.moved(2, x: d.x + far, y: d.y), [])
        TestSupport.expect(lifted.isSwipeActive, "no swipe once the letter was the only finger")
    }

    fileprivate static func testSwipeThresholdBoundary() {
        let d = center(.character("d"))
        var model = model(swipe: true)
        let threshold = model.swipeThreshold
        // The first position at least `threshold` from the touch-down point, and the one just before it.
        var at = d.x + threshold
        while at - d.x < threshold { at = at.nextUp }
        let below = at.nextDown
        TestSupport.expect(below - d.x < threshold, "the boundary is not tight")
        _ = model.began(1, x: d.x, y: d.y)
        TestSupport.expectEqual(model.moved(1, x: below, y: d.y), [])
        TestSupport.expect(!model.isSwipeActive, "a swipe short of the threshold")
        TestSupport.expectEqual(model.moved(1, x: d.x - threshold + 0.01, y: d.y), [])
        TestSupport.expect(!model.isSwipeActive, "a swipe short of the threshold, leftwards")
        TestSupport.expectEqual(model.moved(1, x: at, y: d.y), [])
        TestSupport.expect(model.isSwipeActive, "no swipe at the threshold")
        // The distance is a straight line from the touch-down point: each axis short of it, together past it.
        var diagonal = self.model(swipe: true)
        _ = diagonal.began(1, x: d.x, y: d.y)
        _ = diagonal.moved(1, x: d.x + 0.7 * threshold, y: d.y - 0.7 * threshold)
        TestSupport.expect(!diagonal.isSwipeActive, "a swipe short of the threshold, diagonally")
        _ = diagonal.moved(1, x: d.x + 0.75 * threshold, y: d.y - 0.75 * threshold)
        TestSupport.expect(diagonal.isSwipeActive, "no swipe past the threshold, diagonally")
        // A finger that wandered and came back is measured where it is now, from where it touched down.
        var back = self.model(swipe: true)
        _ = back.began(1, x: d.x, y: d.y)
        _ = back.moved(1, x: d.x + 0.9 * threshold, y: d.y)
        _ = back.moved(1, x: d.x, y: d.y)
        TestSupport.expect(!back.isSwipeActive, "a swipe that never went far enough")
        TestSupport.expectEqual(back.ended(1, x: d.x, y: d.y), [.type(.character("d"))])
    }

    fileprivate static func testSwipeSamplesStartAtTouchDownAndKeepEveryCoalescedTouch() {
        let d = center(.character("d"))
        var model = model(swipe: true)
        let touchDown = SwipeSample(x: d.x, y: d.y, t: 10)
        _ = model.began(1, x: d.x, y: d.y, t: 10)
        TestSupport.expect(model.collectsSamples(1), "a letter that may become a swipe collects no samples")
        // Before it is a swipe: every coalesced touch of the move, in order.
        let first = [SwipeSample(x: d.x + 1, y: d.y, t: 10.004), SwipeSample(x: d.x + 3, y: d.y + 1, t: 10.008)]
        TestSupport.expectEqual(model.moved(1, x: d.x + 3, y: d.y + 1, t: 10.008, coalesced: first), [])
        TestSupport.expect(!model.isSwipeActive, "a swipe short of the threshold")
        // The move that crosses the threshold.
        let second = [SwipeSample(x: d.x + 12, y: d.y + 2, t: 10.012), SwipeSample(x: d.x + 25, y: d.y + 2, t: 10.016)]
        TestSupport.expectEqual(model.moved(1, x: d.x + 25, y: d.y + 2, t: 10.016, coalesced: second), [])
        TestSupport.expect(model.isSwipeActive, "no swipe")
        TestSupport.expect(model.collectsSamples(1), "a swipe collects no samples")
        // During the swipe; a move without coalesced touches counts its own position.
        let third = [SwipeSample(x: d.x + 40, y: d.y, t: 10.02), SwipeSample(x: d.x + 50, y: d.y - 3, t: 10.024),
                     SwipeSample(x: d.x + 61, y: d.y - 4, t: 10.028)]
        TestSupport.expectEqual(model.moved(1, x: d.x + 61, y: d.y - 4, t: 10.028, coalesced: third), [])
        TestSupport.expectEqual(model.moved(1, x: d.x + 70, y: d.y - 4, t: 10.032), [])
        // The trajectory runs through the release: the lift is the last sample.
        let lift = SwipeSample(x: d.x + 72, y: d.y - 5, t: 10.036)
        TestSupport.expectEqual(model.ended(1, x: lift.x, y: lift.y, t: lift.t),
                                [.swipe([touchDown] + first + second + third + [SwipeSample(x: d.x + 70, y: d.y - 4, t: 10.032), lift],
                                        field: nil)])
        TestSupport.expect(!model.collectsSamples(1), "an ended swipe collects samples")
        // Only an exact repeat of the last sample is skipped: a lift where the finger last was, but later,
        // still counts.
        var still = self.model(swipe: true)
        _ = still.began(1, x: d.x, y: d.y, t: 20)
        _ = still.moved(1, x: d.x + 30, y: d.y, t: 20.05)
        TestSupport.expectEqual(still.ended(1, x: d.x + 30, y: d.y, t: 20.05),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 20), SwipeSample(x: d.x + 30, y: d.y, t: 20.05)], field: nil)])
        var later = self.model(swipe: true)
        _ = later.began(1, x: d.x, y: d.y, t: 20)
        _ = later.moved(1, x: d.x + 30, y: d.y, t: 20.05)
        TestSupport.expectEqual(later.ended(1, x: d.x + 30, y: d.y, t: 20.1),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 20), SwipeSample(x: d.x + 30, y: d.y, t: 20.05),
                                         SwipeSample(x: d.x + 30, y: d.y, t: 20.1)], field: nil)])
        // Only touches that are or may become a swipe collect samples.
        var other = self.model(swipe: true)
        let space = center(.space), s = center(.character("s"))
        _ = other.began(1, x: space.x, y: space.y)
        TestSupport.expect(!other.collectsSamples(1), "the space bar collects samples")
        _ = other.began(2, x: d.x, y: d.y)
        TestSupport.expect(other.collectsSamples(2), "an uncommitted letter collects no samples")
        _ = other.began(3, x: s.x, y: s.y)
        TestSupport.expect(!other.collectsSamples(2), "a committed letter collects samples")
        var off = self.model(swipe: false)
        _ = off.began(1, x: d.x, y: d.y)
        TestSupport.expect(!off.collectsSamples(1), "samples with swipe typing off")
    }

    fileprivate static func testCancelledSwipeEmitsNothing() {
        let d = center(.character("d")), far = 3 * threshold
        var model = model(swipe: true)
        _ = model.began(1, x: d.x, y: d.y, t: 1)
        _ = model.moved(1, x: d.x + far, y: d.y, t: 1.1)
        TestSupport.expectEqual(model.cancelled(1), [])
        TestSupport.expect(!model.isSwipeActive, "a cancelled swipe kept running")
        TestSupport.expectEqual(model.ended(1, x: d.x + far, y: d.y), [])
        // Nor when the key area drops every touch.
        var dropped = self.model(swipe: true)
        _ = dropped.began(1, x: d.x, y: d.y, t: 1)
        _ = dropped.moved(1, x: d.x + far, y: d.y, t: 1.1)
        TestSupport.expectEqual(dropped.cancelAll(), [])
        TestSupport.expect(!dropped.isSwipeActive, "a dropped swipe kept running")
        TestSupport.expectEqual(dropped.ended(1, x: d.x + far, y: d.y), [])
    }

    fileprivate static func testTouchesAreIgnoredDuringASwipe() {
        let d = center(.character("d")), a = center(.character("a")), space = center(.space)
        let delete = center(.delete), far = 3 * threshold
        var model = model(swipe: true)
        _ = model.began(1, x: d.x, y: d.y, t: 1)
        _ = model.moved(1, x: d.x + far, y: d.y, t: 1.1)
        for (id, point) in [(2, a), (3, space), (4, delete)] {
            TestSupport.expectEqual(model.began(id, x: point.x, y: point.y, t: 1.2), [])
            TestSupport.expectEqual(model.moved(id, x: point.x + far, y: point.y, t: 1.3), [])
            TestSupport.expectEqual(model.ended(id, x: point.x, y: point.y), [])
        }
        _ = model.began(5, x: a.x, y: a.y, t: 1.4)
        TestSupport.expect(model.touches.isEmpty, "a touch during a swipe was tracked")
        TestSupport.expectEqual(model.ended(1, x: d.x + far, y: d.y, t: 1.1),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 1), SwipeSample(x: d.x + far, y: d.y, t: 1.1)], field: nil)])
        // The finger that touched down during the swipe stays ignored; new ones type again.
        TestSupport.expectEqual(model.ended(5, x: a.x, y: a.y), [])
        TestSupport.expectEqual(model.began(6, x: a.x, y: a.y), [.keyDown])
        TestSupport.expectEqual(model.ended(6, x: a.x, y: a.y), [.type(.character("a"))])
    }

    fileprivate static func testSwipeKeepsTheFieldOfItsPress() {
        // A swipe carries its touch-down field like a held letter: bound on the first identity, dropped
        // (emitting nothing) when another identified field becomes current.
        let fieldA = UUID(), fieldB = UUID(), far = 3 * threshold
        let d = center(.character("d"))
        var unbound = model(swipe: true)
        _ = unbound.began(1, x: d.x, y: d.y, t: 1, field: nil)
        _ = unbound.moved(1, x: d.x + far, y: d.y, t: 1.1)
        TestSupport.expectEqual(unbound.fieldChanged(to: fieldA), [])
        TestSupport.expectEqual(unbound.ended(1, x: d.x + far, y: d.y, t: 1.1),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 1), SwipeSample(x: d.x + far, y: d.y, t: 1.1)], field: fieldA)])
        var moved = model(swipe: true)
        _ = moved.began(1, x: d.x, y: d.y, t: 1, field: fieldA)
        _ = moved.moved(1, x: d.x + far, y: d.y, t: 1.1)
        TestSupport.expectEqual(moved.fieldChanged(to: fieldA), [])
        TestSupport.expect(moved.isSwipeActive, "the swipe ended in its own field")
        TestSupport.expectEqual(moved.fieldChanged(to: fieldB), [])
        TestSupport.expect(!moved.isSwipeActive, "the swipe survived a change to another field")
        TestSupport.expectEqual(moved.ended(1, x: d.x + far, y: d.y), [])
    }

    fileprivate static func testWithoutSwipeTypingALongDragTypesTheTouchDownLetter() {
        // With swipe typing off (no engine loaded, or a secure field), a drag across the whole keyboard is a
        // tap of the key it touched down on.
        var model = model(swipe: false)
        let q = center(.character("q")), p = center(.character("p")), m = center(.character("m"))
        _ = model.began(1, x: q.x, y: q.y, t: 1)
        TestSupport.expectEqual(model.moved(1, x: p.x, y: p.y, t: 1.2), [])
        TestSupport.expectEqual(model.moved(1, x: m.x, y: m.y, t: 1.4), [])
        TestSupport.expectEqual(model.calloutAction, .character("q"))
        TestSupport.expectEqual(model.ended(1, x: m.x, y: m.y), [.type(.character("q"))])
    }
}

// MARK: Threshold crossings between reported positions (code review, 2026-10-15)

extension KeyTouchModelTests {
    fileprivate static func testAnyCoalescedSamplePastTheThresholdSwipes() {
        // Regression: promotion looked only at the event's last position, so a move whose coalesced touches
        // went 25 pt out and came back to 5 pt stayed a tap.
        let d = center(.character("d"))
        var model = model(swipe: true)
        _ = model.began(1, x: d.x, y: d.y, t: 1)
        let outAndBack = [SwipeSample(x: d.x + 10, y: d.y, t: 1.004), SwipeSample(x: d.x + 25, y: d.y, t: 1.008),
                          SwipeSample(x: d.x + 5, y: d.y, t: 1.012)]
        TestSupport.expectEqual(model.moved(1, x: d.x + 5, y: d.y, t: 1.012, coalesced: outAndBack), [])
        TestSupport.expect(model.isSwipeActive, "a coalesced touch past the threshold did not make a swipe")
        TestSupport.expectEqual(model.ended(1, x: d.x + 5, y: d.y, t: 1.012),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 1)] + outAndBack, field: nil)])
        // Ineligible touches are unaffected: with another finger held, the same move stays a tap.
        var held = self.model(swipe: true)
        let s = center(.character("s"))
        _ = held.began(1, x: s.x, y: s.y, t: 1)
        _ = held.began(2, x: d.x, y: d.y, t: 1)
        TestSupport.expectEqual(held.moved(2, x: d.x + 5, y: d.y, t: 1.012, coalesced: outAndBack), [])
        TestSupport.expect(!held.isSwipeActive, "a swipe beside another finger")
        TestSupport.expectEqual(held.ended(2, x: d.x + 5, y: d.y, t: 1.012), [.type(.character("d"))])
    }

    fileprivate static func testFlickPastTheThresholdAtTheLiftSwipes() {
        // Regression: a quick flick first reported past the threshold at its release typed the touch-down
        // letter. The lift counts as a sample of the path: the touch swipes, through the lift.
        let d = center(.character("d")), far = 2 * threshold
        let field = UUID()
        var flick = model(swipe: true)
        _ = flick.began(1, x: d.x, y: d.y, t: 1, field: field)
        TestSupport.expectEqual(flick.moved(1, x: d.x + 5, y: d.y, t: 1.008), [])
        TestSupport.expect(!flick.isSwipeActive, "a swipe short of the threshold")
        TestSupport.expectEqual(flick.ended(1, x: d.x + far, y: d.y, t: 1.016),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 1), SwipeSample(x: d.x + 5, y: d.y, t: 1.008),
                                         SwipeSample(x: d.x + far, y: d.y, t: 1.016)], field: field)])
        TestSupport.expect(!flick.isSwipeActive && flick.touches.isEmpty, "the flick outlived its lift")
        // With no move at all.
        var bare = model(swipe: true)
        _ = bare.began(1, x: d.x, y: d.y, t: 1)
        TestSupport.expectEqual(bare.ended(1, x: d.x + far, y: d.y, t: 1.01),
                                [.swipe([SwipeSample(x: d.x, y: d.y, t: 1), SwipeSample(x: d.x + far, y: d.y, t: 1.01)], field: nil)])
        // A lift within the threshold is still a tap.
        var tap = model(swipe: true)
        _ = tap.began(1, x: d.x, y: d.y, t: 1)
        TestSupport.expectEqual(tap.ended(1, x: d.x + threshold - 0.01, y: d.y, t: 1.01), [.type(.character("d"))])
        // Ineligible touches type at a far lift as before: swipe typing off, another layer, another finger
        // held (Shift), and a letter committed by rollover.
        var off = model(swipe: false)
        _ = off.began(1, x: d.x, y: d.y, t: 1)
        TestSupport.expectEqual(off.ended(1, x: d.x + far, y: d.y, t: 1.01), [.type(.character("d"))])
        var numbers = model(.numbers, swipe: true)
        let five = center(.character("5"), .numbers)
        _ = numbers.began(1, x: five.x, y: five.y, t: 1)
        TestSupport.expectEqual(numbers.ended(1, x: five.x + far, y: five.y, t: 1.01), [.type(.character("5"))])
        var shifted = model(swipe: true)
        let shift = center(.shift)
        _ = shifted.began(1, x: shift.x, y: shift.y, t: 1)
        _ = shifted.began(2, x: d.x, y: d.y, t: 1)
        TestSupport.expectEqual(shifted.ended(2, x: d.x + far, y: d.y, t: 1.01), [.type(.character("d"))])
        var committed = model(swipe: true)
        let s = center(.character("s"))
        _ = committed.began(1, x: d.x, y: d.y, t: 1)
        _ = committed.began(2, x: s.x, y: s.y, t: 1)
        _ = committed.ended(2, x: s.x, y: s.y, t: 1.005)
        TestSupport.expectEqual(committed.ended(1, x: d.x + far, y: d.y, t: 1.01), [])
    }
}

// MARK: Swipe trace (ARCHITECTURE.md, "Typing model v4 and swipe typing", "Swipe trace")

extension KeyTouchModelTests {
    private static func samples(_ times: [TimeInterval]) -> [SwipeSample] {
        times.enumerated().map { SwipeSample(x: Double($0.offset) * 10, y: 50, t: $0.element) }
    }

    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    fileprivate static func testSwipeTrailKeepsTheLastWindowOfSamples() {
        // Only the last 0.15 s before the newest sample (the finger), oldest first, the finger last.
        TestSupport.expect(close(SwipeTrail.duration, 0.15), "trail duration \(SwipeTrail.duration)")
        let path = samples([1.0, 1.05, 1.1, 1.16, 1.2, 1.25, 1.3])
        let trail = SwipeTrail.points(from: path)
        TestSupport.expectEqual(trail.map(\.x), [30, 40, 50, 60])
        TestSupport.expectEqual(trail.last?.y, 50)
        // The boundary is inclusive: a sample exactly 0.15 s old stays (binary-exact times).
        let exact = SwipeTrail.points(from: samples([0, 0.125, 0.25, 0.375]), window: 0.25)
        TestSupport.expectEqual(exact.map(\.x), [10, 20, 30])
        TestSupport.expectEqual(SwipeTrail.points(from: []), [])
        // A single sample (a swipe promoted on its first move has two): nothing to draw yet.
        TestSupport.expectEqual(SwipeTrail.points(from: samples([1])), [])
    }

    fileprivate static func testSwipeTrailKeepsAtLeastTwoPoints() {
        // A slow finger whose previous sample is older than the window still draws a stroke to it.
        let slow = SwipeTrail.points(from: samples([1, 2, 3]))
        TestSupport.expectEqual(slow.map(\.x), [10, 20])
        // Equal timestamps all fall inside the window.
        let equal = SwipeTrail.points(from: samples([5, 5, 5, 5]))
        TestSupport.expectEqual(equal.map(\.x), [0, 10, 20, 30])
    }

    fileprivate static func testSwipeTrailToleratesDisorderedTimestamps() {
        // A sample stamped later than the one after it counts as no newer than that one, so an
        // out-of-order timestamp never cuts the trail short or pulls in older samples.
        let disordered = SwipeTrail.points(from: samples([1.0, 1.2, 1.25, 1.3, 1.28]))
        TestSupport.expectEqual(disordered.map(\.x), [10, 20, 30, 40])
        // The walk stops at the first sample past the window: an older sample with a stray recent
        // timestamp before it is not drawn.
        let stray = SwipeTrail.points(from: samples([1.29, 1.0, 1.2, 1.3]))
        TestSupport.expectEqual(stray.map(\.x), [20, 30])
        // Widths and opacities stay ordered: never wider or stronger towards the tail.
        for trail in [disordered, stray] {
            for (older, newer) in zip(trail, trail.dropFirst()) {
                TestSupport.expect(older.width <= newer.width && older.alpha <= newer.alpha, "trail not tapering: \(trail)")
            }
        }
    }

    fileprivate static func testSwipeTrailTapersAndFadesTowardsItsTail() {
        // About 8 pt and 45% opacity at the finger, nothing at the oldest point, in proportion to age between.
        TestSupport.expect(close(SwipeTrail.maximumWidth, 8) && close(SwipeTrail.maximumAlpha, 0.45),
                           "trail \(SwipeTrail.maximumWidth) pt, \(SwipeTrail.maximumAlpha)")
        let trail = SwipeTrail.points(from: samples([0, 0.125, 0.25]), window: 0.25)
        TestSupport.expectEqual(trail.count, 3)
        TestSupport.expect(close(trail[2].width, 8) && close(trail[2].alpha, 0.45), "finger \(trail[2])")
        TestSupport.expect(close(trail[1].width, 4) && close(trail[1].alpha, 0.225), "middle \(trail[1])")
        TestSupport.expect(close(trail[0].width, 0) && close(trail[0].alpha, 0), "tail \(trail[0])")
        // The same at a slow finger's two points (the tail older than the window).
        let slow = SwipeTrail.points(from: samples([1, 2]))
        TestSupport.expect(close(slow[0].width, 0) && close(slow[1].width, 8), "slow \(slow)")
        // Equal timestamps taper by position along the trail instead.
        let equal = SwipeTrail.points(from: samples([5, 5, 5]))
        TestSupport.expectEqual(equal.map(\.width), [0, 4, 8])
        TestSupport.expect(close(equal[1].alpha, 0.225), "equal \(equal)")
    }
}
