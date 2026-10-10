import Foundation

enum KeyTouchModelTests {
    static var tests: [TestCase] {
        [
            ("charactersTypeOnLift", testCharactersTypeOnLift),
            ("heldTouchSurvivesALayerChange", testHeldTouchSurvivesALayerChange),
            ("spaceRolloverKeepsPressOrder", testSpaceRolloverKeepsPressOrder),
            ("returnRolloverKeepsPressOrder", testReturnRolloverKeepsPressOrder),
            ("characterRolloverCommitsOnce", testCharacterRolloverCommitsOnce),
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
        ]
    }

    private static func keys(_ layer: KeyboardLayer) -> [PlacedKey] {
        KeyboardLayout.keys(for: layer, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                            showsGlobe: false)
    }

    private static func model(_ layer: KeyboardLayer = .letters) -> KeyTouchModel {
        var model = KeyTouchModel()
        _ = model.keysChanged(keys(layer), layer: layer)
        return model
    }

    private static func center(_ action: KeyAction, _ layer: KeyboardLayer = .letters) -> (x: Double, y: Double) {
        let key = keys(layer).first { $0.action == action }!
        return (key.frame.midX, key.frame.midY)
    }

    private static func testCharactersTypeOnLift() {
        var model = model()
        let a = center(.character("a")), s = center(.character("s"))
        TestSupport.expectEqual(model.began(1, x: a.x, y: a.y), [])
        // Sliding to another key types the key under the finger at lift.
        TestSupport.expectEqual(model.moved(1, x: s.x, y: s.y), [])
        TestSupport.expectEqual(model.ended(1, x: s.x, y: s.y), [.type(.character("s"))])
        TestSupport.expect(model.touches.isEmpty, "touch kept")
        // Unknown touches do nothing.
        TestSupport.expectEqual(model.ended(9, x: a.x, y: a.y), [])
        TestSupport.expectEqual(model.moved(9, x: a.x, y: a.y), [])
    }

    private static func testHeldTouchSurvivesALayerChange() {
        // Regression: a finger slid from a letter onto Return (index 30 of 31 letter-layer keys), a
        // second finger pressed 123, and the first finger's lift read index 30 of the 30 number keys.
        var model = model()
        let q = center(.character("q")), returnKey = center(.returnKey), numbers = center(.layer(.numbers))
        _ = model.began(1, x: q.x, y: q.y)
        _ = model.moved(1, x: returnKey.x, y: returnKey.y)
        TestSupport.expectEqual(model.began(2, x: numbers.x, y: numbers.y), [.type(.layer(.numbers))])
        // The view rebuilds the keys for the new layer; held fingers follow by action, not index.
        TestSupport.expectEqual(model.keysChanged(keys(.numbers), layer: .numbers), [])
        TestSupport.expectEqual(keys(.numbers).count, 30)
        TestSupport.expectEqual(model.touches.first { $0.id == 1 }?.action, .returnKey)
        TestSupport.expectEqual(model.touches.first { $0.id == 2 }?.action, .layer(.letters))
        TestSupport.expectEqual(model.ended(1, x: returnKey.x, y: returnKey.y), [])
        TestSupport.expectEqual(model.ended(2, x: numbers.x, y: numbers.y), [])
    }

    private static func testSpaceRolloverKeepsPressOrder() {
        // Regression: space down, x down and up, space up before the hold gave "hellox " instead of
        // "hello x". The space commits first, in press order, and its hold timer stops.
        var model = model()
        let space = center(.space), x = center(.character("x"))
        TestSupport.expectEqual(model.began(1, x: space.x, y: space.y), [.startHoldTimer(1)])
        TestSupport.expectEqual(model.began(2, x: x.x, y: x.y), [.cancelHoldTimer(1), .type(.space)])
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
        TestSupport.expectEqual(model.began(1, x: returnKey.x, y: returnKey.y), [])
        TestSupport.expectEqual(model.began(2, x: a.x, y: a.y), [.type(.returnKey)])
        TestSupport.expectEqual(model.ended(2, x: a.x, y: a.y), [.type(.character("a"))])
        TestSupport.expectEqual(model.ended(1, x: returnKey.x, y: returnKey.y), [])
    }

    private static func testCharacterRolloverCommitsOnce() {
        var model = model()
        let h = center(.character("h")), i = center(.character("i")), space = center(.space)
        _ = model.began(1, x: h.x, y: h.y)
        TestSupport.expectEqual(model.began(2, x: i.x, y: i.y), [.type(.character("h"))])
        TestSupport.expectEqual(model.began(3, x: space.x, y: space.y), [.type(.character("i")), .startHoldTimer(3)])
        // Lifts after a commit type nothing more; moves after it change nothing.
        TestSupport.expectEqual(model.moved(1, x: i.x, y: i.y), [])
        TestSupport.expectEqual(model.ended(1, x: i.x, y: i.y), [])
        TestSupport.expectEqual(model.ended(2, x: i.x, y: i.y), [])
        TestSupport.expectEqual(model.ended(3, x: space.x, y: space.y), [.cancelHoldTimer(3), .type(.space)])
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
        TestSupport.expectEqual(model.began(1, x: numbersKey.x, y: numbersKey.y), [.type(.layer(.numbers))])
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
        TestSupport.expectEqual(model.began(1, x: delete.x, y: delete.y), [.beginDelete])
        TestSupport.expectEqual(model.began(2, x: numbersKey.x, y: numbersKey.y), [.type(.layer(.numbers))])
        TestSupport.expectEqual(model.keysChanged(keys(.numbers), layer: .numbers), [])
        TestSupport.expectEqual(model.ended(1, x: delete.x, y: delete.y), [.endDelete(cancelled: false)])
    }

    private static func testVanishedFunctionKeysAreDropped() {
        var model = model()
        let shift = center(.shift)
        TestSupport.expectEqual(model.began(1, x: shift.x, y: shift.y), [.type(.shift)])
        // The numbers layer has no shift key: the finger is dropped without effect.
        TestSupport.expectEqual(model.keysChanged(keys(.numbers), layer: .numbers), [])
        TestSupport.expect(model.touches.isEmpty, "a finger on a vanished key")
        TestSupport.expectEqual(model.ended(1, x: shift.x, y: shift.y), [])
    }

    private static func testPressedKeysAndCallout() {
        var model = model()
        let a = center(.character("a")), space = center(.space), delete = center(.delete)
        _ = model.began(1, x: a.x, y: a.y)
        TestSupport.expectEqual(model.calloutAction, .character("a"))
        TestSupport.expectEqual(model.pressedActions, [])
        _ = model.began(2, x: space.x, y: space.y)
        // The rollover committed "a": no callout for it any more.
        TestSupport.expectEqual(model.calloutAction, nil)
        TestSupport.expectEqual(model.pressedActions, [.space])
        _ = model.began(3, x: delete.x, y: delete.y)
        TestSupport.expectEqual(model.pressedActions, [.delete])
        _ = model.ended(3, x: delete.x, y: delete.y)
        TestSupport.expectEqual(model.pressedActions, [])
    }

    private static func testCancelledDeleteIsNotARelease() {
        // Regression: a delete touch the system cancels (or the menu opening over the keys) ended like a
        // release, and a release before the first deletion deletes once.
        var model = model()
        let delete = center(.delete)
        TestSupport.expectEqual(model.began(1, x: delete.x, y: delete.y), [.beginDelete])
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
        // finger keeps the field of its touch-down, on release and on rollover alike.
        let fieldA = UUID(), fieldB = UUID()
        var model = model()
        let a = center(.character("a")), s = center(.character("s"))
        let space = center(.space), enter = center(.returnKey)
        _ = model.began(1, x: a.x, y: a.y, field: fieldA)
        TestSupport.expectEqual(model.began(2, x: s.x, y: s.y, field: fieldB), [.type(.character("a"), field: fieldA)])
        TestSupport.expectEqual(model.ended(2, x: s.x, y: s.y), [.type(.character("s"), field: fieldB)])
        TestSupport.expectEqual(model.ended(1, x: a.x, y: a.y), [])
        _ = model.began(3, x: space.x, y: space.y, field: fieldA)
        TestSupport.expectEqual(model.ended(3, x: space.x, y: space.y), [.cancelHoldTimer(3), .type(.space, field: fieldA)])
        _ = model.began(4, x: enter.x, y: enter.y, field: fieldA)
        TestSupport.expectEqual(model.began(5, x: a.x, y: a.y, field: fieldB), [.type(.returnKey, field: fieldA)])
        TestSupport.expectEqual(model.ended(5, x: a.x, y: a.y), [.type(.character("a"), field: fieldB)])
    }
}
