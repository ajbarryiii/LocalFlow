import Foundation

enum CalloutTrackerTests {
    static var tests: [TestCase] {
        [
            ("drawsOnlyChanges", testDrawsOnlyChanges),
            ("apostropheFromTheNumbersLayerLeavesNoCallout", testApostropheFromTheNumbersLayerLeavesNoCallout),
            ("heldCharacterIsRedrawnAfterARebuild", testHeldCharacterIsRedrawnAfterARebuild),
        ]
    }

    private static let metrics = KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight)

    private static func keys(_ layer: KeyboardLayer) -> [PlacedKey] {
        KeyboardLayout.keys(for: layer, metrics: metrics, showsGlobe: false)
    }

    private static func center(_ action: KeyAction, _ layer: KeyboardLayer) -> (x: Double, y: Double) {
        let key = keys(layer).first { $0.action == action }!
        return (key.frame.midX, key.frame.midY)
    }

    /// The callout the key area asks for: the model's callout touch and what it shows.
    private static func wanted(_ model: KeyTouchModel) -> CalloutTracker.Callout? {
        model.calloutTouch.flatMap { touch in model.shownAction(touch).map { .init(touch: touch.id, action: $0) } }
    }

    private static func testDrawsOnlyChanges() {
        var tracker = CalloutTracker()
        let a = CalloutTracker.Callout(touch: 1, action: .character("a"))
        let s = CalloutTracker.Callout(touch: 1, action: .character("s"))
        TestSupport.expectEqual(tracker.update(to: nil), nil)
        TestSupport.expectEqual(tracker.update(to: a), .show(a))
        TestSupport.expectEqual(tracker.update(to: a), nil)
        TestSupport.expectEqual(tracker.update(to: s), .show(s))
        TestSupport.expectEqual(tracker.update(to: nil), .hide)
        TestSupport.expectEqual(tracker.update(to: nil), nil)
    }

    /// An apostrophe typed from the numbers layer returns to letters at its release: the rebuilt letter keys
    /// must not keep its callout (it stayed over the letters until the next key press).
    private static func testApostropheFromTheNumbersLayerLeavesNoCallout() {
        var model = KeyTouchModel()
        _ = model.keysChanged(keys(.numbers), layer: .numbers)
        var tracker = CalloutTracker()
        let apostrophe = center(.character("'"), .numbers)
        _ = model.began(1, x: apostrophe.x, y: apostrophe.y)
        TestSupport.expectEqual(tracker.update(to: wanted(model)),
                                .show(.init(touch: 1, action: .character("'"))))
        TestSupport.expectEqual(model.ended(1, x: apostrophe.x, y: apostrophe.y), [.type(.character("'"))])
        // Typing it returns to letters before the key area draws the release.
        _ = model.keysChanged(keys(.letters), layer: .letters)
        tracker.keysChanged()
        TestSupport.expectEqual(tracker.update(to: wanted(model)), .hide)
        TestSupport.expectEqual(tracker.update(to: wanted(model)), nil)
    }

    /// A character held through a rebuild (a shift change) is drawn again, over its key as now laid out.
    private static func testHeldCharacterIsRedrawnAfterARebuild() {
        var model = KeyTouchModel()
        _ = model.keysChanged(keys(.letters), layer: .letters)
        var tracker = CalloutTracker()
        let a = center(.character("a"), .letters)
        _ = model.began(1, x: a.x, y: a.y)
        let callout = CalloutTracker.Callout(touch: 1, action: .character("a"))
        TestSupport.expectEqual(tracker.update(to: wanted(model)), .show(callout))
        _ = model.keysChanged(keys(.letters), layer: .letters)
        tracker.keysChanged()
        TestSupport.expectEqual(tracker.update(to: wanted(model)), .show(callout))
        TestSupport.expectEqual(tracker.update(to: wanted(model)), nil)
    }
}
