import Foundation

enum TypingRulesTests {
    static var tests: [TestCase] {
        [
            ("shiftTapAndCapsLock", testShiftTapAndCapsLock),
            ("oneShotShiftClearsAfterALetter", testOneShotShiftClearsAfterALetter),
            ("automaticShiftNeverOverridesTheUser", testAutomaticShiftNeverOverridesTheUser),
            ("layersReturnToLetters", testLayersReturnToLetters),
            ("doubleSpaceInsertsPeriod", testDoubleSpaceInsertsPeriod),
            ("doubleSpaceNeedsAWordAndTime", testDoubleSpaceNeedsAWordAndTime),
            ("autoCapitalizationModes", testAutoCapitalizationModes),
            ("contextTailTracksOwnEdits", testContextTailTracksOwnEdits),
            ("contextTailYieldsToTheProxy", testContextTailYieldsToTheProxy),
        ]
    }

    private static func testShiftTapAndCapsLock() {
        var state = TypingState()
        state.tapShift(at: 10)
        TestSupport.expectEqual(state.shift, .once)
        state.tapShift(at: 11)
        TestSupport.expectEqual(state.shift, .off)
        // Two quick taps lock caps; one more tap unlocks.
        state.tapShift(at: 20)
        state.tapShift(at: 20.3)
        TestSupport.expectEqual(state.shift, .capsLock)
        TestSupport.expectEqual(state.text(for: "a"), "A")
        state.didTypeCharacter("a")
        TestSupport.expectEqual(state.shift, .capsLock)
        state.tapShift(at: 30)
        TestSupport.expectEqual(state.shift, .off)
        // Slower than the double-tap window is two single taps.
        state.tapShift(at: 40)
        state.tapShift(at: 40.5)
        TestSupport.expectEqual(state.shift, .off)
    }

    private static func testOneShotShiftClearsAfterALetter() {
        var state = TypingState()
        state.tapShift(at: 1)
        TestSupport.expectEqual(state.text(for: "q"), "Q")
        state.didTypeCharacter("Q")
        TestSupport.expectEqual(state.shift, .off)
        TestSupport.expectEqual(state.text(for: "q"), "q")
        TestSupport.expectEqual(state.text(for: "1"), "1")
    }

    private static func testAutomaticShiftNeverOverridesTheUser() {
        var state = TypingState()
        state.updateAutomaticShift(true)
        TestSupport.expectEqual(state.shift, .once)
        TestSupport.expect(state.shiftIsAutomatic, "automatic")
        state.updateAutomaticShift(false)
        TestSupport.expectEqual(state.shift, .off)
        // A shift the user turned on stays on when the context says not to capitalize.
        state.tapShift(at: 1)
        state.updateAutomaticShift(false)
        TestSupport.expectEqual(state.shift, .once)
        state.tapShift(at: 5)
        state.tapShift(at: 5.1)
        state.updateAutomaticShift(false)
        TestSupport.expectEqual(state.shift, .capsLock)
        // Tapping shift while it is automatically on turns it off; a quick second tap locks.
        var automatic = TypingState()
        automatic.updateAutomaticShift(true)
        automatic.tapShift(at: 1)
        TestSupport.expectEqual(automatic.shift, .off)
        automatic.tapShift(at: 1.2)
        TestSupport.expectEqual(automatic.shift, .capsLock)
    }

    private static func testLayersReturnToLetters() {
        var state = TypingState()
        state.switchLayer(to: .numbers)
        state.didTypeCharacter("4")
        TestSupport.expectEqual(state.layer, .numbers)
        _ = state.spaceEdit(before: "4", at: 1)
        TestSupport.expectEqual(state.layer, .letters)
        state.switchLayer(to: .symbols)
        state.didTypeCharacter("'")
        TestSupport.expectEqual(state.layer, .letters)
        state.switchLayer(to: .numbers)
        state.didTypeReturn()
        TestSupport.expectEqual(state.layer, .letters)
        // An apostrophe in the letter layer changes nothing.
        state.didTypeCharacter("'")
        TestSupport.expectEqual(state.layer, .letters)
    }

    private static func testDoubleSpaceInsertsPeriod() {
        var state = TypingState()
        TestSupport.expectEqual(state.spaceEdit(before: "Hello", at: 1), .space)
        TestSupport.expectEqual(state.spaceEdit(before: "Hello ", at: 1.4), .replaceSpaceWithPeriod)
        // A third space is a plain space.
        TestSupport.expectEqual(state.spaceEdit(before: "Hello. ", at: 1.6), .space)
        TestSupport.expectEqual(state.spaceEdit(before: "it (yes) ", at: 1.8), .replaceSpaceWithPeriod)
        TestSupport.expect(DoubleSpacePeriod.applies(before: "route 66 "), "after a number")
        TestSupport.expect(DoubleSpacePeriod.applies(before: "\u{201C}quote\u{201D} "), "after a closing quote")
    }

    private static func testDoubleSpaceNeedsAWordAndTime() {
        for before in ["Hello.  ", "Hello, ", "Hello", " ", "", "Hello  ", "line\n "] {
            TestSupport.expect(!DoubleSpacePeriod.applies(before: before), "applied after \(before.debugDescription)")
        }
        TestSupport.expect(!DoubleSpacePeriod.applies(before: nil), "nil context")
        var slow = TypingState()
        _ = slow.spaceEdit(before: "Hello", at: 1)
        TestSupport.expectEqual(slow.spaceEdit(before: "Hello ", at: 5), .space)
        // Any other key in between cancels it.
        var interrupted = TypingState()
        _ = interrupted.spaceEdit(before: "Hello", at: 1)
        interrupted.didTypeCharacter("a")
        TestSupport.expectEqual(interrupted.spaceEdit(before: "Hello a", at: 1.1), .space)
        var deleted = TypingState()
        _ = deleted.spaceEdit(before: "Hello", at: 1)
        deleted.didDelete()
        TestSupport.expectEqual(deleted.spaceEdit(before: "Hello ", at: 1.1), .space)
        var moved = TypingState()
        _ = moved.spaceEdit(before: "Hello", at: 1)
        moved.resetTiming()
        TestSupport.expectEqual(moved.spaceEdit(before: "Hello ", at: 1.1), .space)
    }

    private static func testAutoCapitalizationModes() {
        func cap(_ before: String?, _ mode: AutocapitalizationMode = .sentences) -> Bool {
            AutoCapitalization.shouldCapitalize(before: before, mode: mode)
        }
        TestSupport.expect(cap(nil) && cap(""), "start of field")
        TestSupport.expect(cap("Done. ") && cap("Really?  ") && cap("Wow! ") && cap("Wait\u{2026} "), "after a sentence")
        TestSupport.expect(cap("He said \"stop.\" ") && cap("(Quietly.) "), "after closing quotes and brackets")
        TestSupport.expect(cap("First line\n") && cap("First line\n  "), "after a line break")
        TestSupport.expect(!cap("Done.") && !cap("Hello ") && !cap("Hello, ") && !cap("Hello"), "mid-sentence")
        TestSupport.expect(cap("   "), "only spaces")
        TestSupport.expect(!cap(nil, .none) && !cap("Done. ", .none), "none")
        TestSupport.expect(cap("anything", .allCharacters), "all characters")
        TestSupport.expect(cap("two ", .words) && cap(nil, .words) && !cap("two", .words), "words")
    }

    private static func testContextTailTracksOwnEdits() {
        var tail = ContextTail()
        TestSupport.expectEqual(tail.current(proxyBefore: "From the proxy"), "From the proxy")
        tail.inserted("a", proxyBefore: "Hello")
        // The proxy has not caught up yet: the model wins.
        TestSupport.expectEqual(tail.current(proxyBefore: "Hello"), "Helloa")
        tail.inserted(" ", proxyBefore: "Hello")
        TestSupport.expectEqual(tail.current(proxyBefore: "Hello"), "Helloa ")
        tail.deleted(graphemes: 2, proxyBefore: "Helloa")
        TestSupport.expectEqual(tail.current(proxyBefore: "Helloa"), "Hello")
        // Deleting more than is known leaves the proxy to answer.
        tail.deleted(graphemes: 10, proxyBefore: nil)
        TestSupport.expectEqual(tail.known, nil)
        // Bounded, and nothing kept beyond the tail.
        tail.inserted(String(repeating: "x", count: 1_000), proxyBefore: nil)
        TestSupport.expectEqual(tail.known?.count, ContextTail.limit)
        tail.forget()
        TestSupport.expectEqual(tail.known, nil)
        // Emoji count as one grapheme each.
        tail.inserted("ok \u{1F44D}\u{1F3FD}", proxyBefore: nil)
        tail.deleted(graphemes: 1, proxyBefore: nil)
        TestSupport.expectEqual(tail.known, "ok ")
    }

    private static func testContextTailYieldsToTheProxy() {
        var tail = ContextTail()
        tail.inserted("b", proxyBefore: "a")
        // Once the proxy shows the edit, its longer view is used.
        TestSupport.expectEqual(tail.current(proxyBefore: "Earlier text ab"), "Earlier text ab")
        tail.proxyChanged(before: "Earlier text ab")
        TestSupport.expectEqual(tail.known, "ab")
        // An outside change (the user tapped elsewhere) drops the model.
        tail.proxyChanged(before: "Somewhere else")
        TestSupport.expectEqual(tail.known, nil)
    }
}
