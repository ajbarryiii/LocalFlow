import Foundation

/// ARCHITECTURE.md, "Top row" and "Layout and keys": what the bar's middle shows, and the return key's enabling.
enum BarContentTests {
    static var tests: [TestCase] {
        [
            ("dictationIsNeverHiddenByTheStripOrTheOffer", testDictationIsNeverHiddenByTheStripOrTheOffer),
            ("returnKeyFollowsEnablesReturnKeyAutomatically", testReturnKeyFollowsEnablesReturnKeyAutomatically),
            ("emojiRecentsAreNewestFirstAndBounded", testEmojiRecentsAreNewestFirstAndBounded),
            ("noDividerBesideTheHighlightedCandidate", testNoDividerBesideTheHighlightedCandidate),
            ("longCandidatesAreDroppedRatherThanShrunk", testLongCandidatesAreDroppedRatherThanShrunk),
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

    /// Round 2 council (Opus finding 2): the dividers showed just outside the highlighted pill's rounded ends. A divider
    /// goes between two shown neighbours only when neither is the emphasized candidate.
    private static func testNoDividerBesideTheHighlightedCandidate() {
        func dividers(_ shown: [Int], emphasized: Int?) -> [Bool] {
            zip(shown, shown.dropFirst()).map { CandidateStripLayout.showsDivider(between: $0, and: $1, emphasized: emphasized) }
        }
        TestSupport.expectEqual(dividers([0, 1, 2], emphasized: nil), [true, true])
        TestSupport.expectEqual(dividers([0, 1, 2], emphasized: 0), [false, true])
        TestSupport.expectEqual(dividers([0, 1, 2], emphasized: 1), [false, false])
        TestSupport.expectEqual(dividers([0, 1, 2], emphasized: 2), [true, false])
        // Between the shown ones, when one was dropped.
        TestSupport.expectEqual(dividers([0, 2], emphasized: 1), [true])
        TestSupport.expectEqual(dividers([0, 2], emphasized: 2), [false])
    }

    /// Round 2 council (Opus finding 2): long words shrank to the 0.6 floor (about 9 pt beside 15 pt neighbours). The
    /// slots are equal; a word shrinks to at most `minimumScale` (0.8) of its size, and when the words do not all fit so,
    /// the least useful go: the last that is neither the emphasized nor the quoted word, until the rest fit.
    private static func testLongCandidatesAreDroppedRatherThanShrunk() {
        TestSupport.expectEqual(CandidateStripLayout.minimumScale, 0.8)
        let strip = SwipeStrip(candidates: ["meeting", "meetings", "meetinghouse"], inserted: 0, live: SwipeStrip.Live(quoted: nil, marked: nil))
        // Three slots of (257 − 2) / 3 = 85 points: 85 − 12 of padding holds 91 points of text at 0.8.
        func shown(_ strip: SwipeStrip, _ widths: [Double], _ available: Double = 257) -> CandidateStripLayout.Fit {
            CandidateStripLayout.fit(strip, widths: widths, available: available)
        }
        TestSupport.expectEqual(shown(strip, [55, 62, 91]), CandidateStripLayout.Fit(shown: [0, 1, 2], minimumScale: 0.8))
        TestSupport.expectEqual(shown(strip, [55, 62, 102]).shown, [0, 1])
        // The least useful goes, not the long one: the third, whatever its length.
        TestSupport.expectEqual(shown(strip, [55, 102, 40]).shown, [0, 1])
        // Never the emphasized or the quoted word: a pending correction keeps both.
        let pending = SwipeStrip(candidates: ["defenately", "definitely", "defiantly"], inserted: 1,
                                 live: SwipeStrip.Live(quoted: 0, marked: 1))
        TestSupport.expectEqual(shown(pending, [110, 70, 70]).shown, [0, 1])
        // After a commit key, the word in the field stays.
        let committed = SwipeStrip(candidates: ["accommodations", "accommodation", "accommodating"], inserted: 2)
        TestSupport.expectEqual(shown(committed, [130, 120, 125]).shown, [0, 2])
        TestSupport.expectEqual(shown(committed, [150, 120, 145]).shown, [2])
        // What is left shrinks below 0.8 only when it must.
        TestSupport.expectEqual(shown(committed, [150, 120, 320]), CandidateStripLayout.Fit(shown: [2], minimumScale: 0.6))
        // Unmeasured (no width yet): everything, as before.
        TestSupport.expectEqual(shown(strip, [55, 62, 102], 0).shown, [0, 1, 2])
        TestSupport.expectEqual(shown(strip, [], 257).shown, [0, 1, 2])
    }
}
