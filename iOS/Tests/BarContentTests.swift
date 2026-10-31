import Foundation

/// ARCHITECTURE.md, "Top row" and "Layout and keys": what the bar's middle shows, and the return key's enabling.
enum BarContentTests {
    static var tests: [TestCase] {
        [
            ("dictationIsNeverHiddenByTheStripOrTheOffer", testDictationIsNeverHiddenByTheStripOrTheOffer),
            ("returnKeyFollowsEnablesReturnKeyAutomatically", testReturnKeyFollowsEnablesReturnKeyAutomatically),
            ("emojiRecentsAreNewestFirstAndBounded", testEmojiRecentsAreNewestFirstAndBounded),
        ]
    }

    /// Dictation in progress, a notice, or dictation's Undo chip keep the middle, whatever the strip or offer.
    private static func testDictationIsNeverHiddenByTheStripOrTheOffer() {
        func content(offer: Bool = false, strip: Bool = false, inProgress: Bool = false, notice: Bool = false, undo: Bool = false)
            -> BarMiddleContent {
            BarMiddleContent.resolve(neverCorrectOffer: offer, candidates: strip, dictationInProgress: inProgress, notice: notice,
                                     dictationUndoShown: undo)
        }
        TestSupport.expectEqual(content(), .dictation)
        TestSupport.expectEqual(content(strip: true), .candidates)
        TestSupport.expectEqual(content(offer: true, strip: true), .neverCorrect)
        TestSupport.expectEqual(content(offer: true), .neverCorrect)
        for offer in [false, true] {
            for strip in [false, true] {
                TestSupport.expectEqual(content(offer: offer, strip: strip, inProgress: true), .dictation)
                TestSupport.expectEqual(content(offer: offer, strip: strip, notice: true), .dictation)
                TestSupport.expectEqual(content(offer: offer, strip: strip, undo: true), .dictation)
            }
        }
    }

    private static func testReturnKeyFollowsEnablesReturnKeyAutomatically() {
        TestSupport.expect(!ReturnKeyRule.isEnabled(enablesAutomatically: true, hasText: false), "enabled in an empty field")
        TestSupport.expect(ReturnKeyRule.isEnabled(enablesAutomatically: true, hasText: true), "disabled with text")
        TestSupport.expect(ReturnKeyRule.isEnabled(enablesAutomatically: false, hasText: false), "disabled without the trait")
        TestSupport.expect(ReturnKeyRule.isEnabled(enablesAutomatically: false, hasText: true), "disabled without the trait")
    }

    /// ARCHITECTURE.md, "Emoji panel": newest first, each once, at most `limit`, only emoji from the catalog.
    private static func testEmojiRecentsAreNewestFirstAndBounded() {
        let all = EmojiCatalog.categories.flatMap(\.emoji)
        TestSupport.expect(all.count > 1000, "catalog too small: \(all.count)")
        TestSupport.expectEqual(Set(all).count, all.count)
        TestSupport.expect(!all.contains { $0.unicodeScalars.contains { (0x1F3FB ... 0x1F3FF).contains($0.value) } }, "a skin tone")
        var recents = EmojiRecents()
        recents.use(all[0])
        recents.use(all[1])
        recents.use(all[0])
        TestSupport.expectEqual(recents.emoji, [all[0], all[1]])
        recents.use("not an emoji")
        TestSupport.expectEqual(recents.emoji, [all[0], all[1]])
        for item in all.prefix(EmojiRecents.limit + 5) { recents.use(item) }
        TestSupport.expectEqual(recents.emoji.count, EmojiRecents.limit)
        TestSupport.expectEqual(recents.emoji.first, all[EmojiRecents.limit + 4])
        // A stored list keeps only catalog emoji, once each, up to the limit.
        let stored = EmojiRecents(stored: [all[2], "typed text", all[2], all[3]] + Array(all.prefix(40)))
        TestSupport.expectEqual(Array(stored.emoji.prefix(2)), [all[2], all[3]])
        TestSupport.expectEqual(stored.emoji.count, EmojiRecents.limit)
        TestSupport.expect(!stored.emoji.contains("typed text"), "stored text kept")
    }
}
