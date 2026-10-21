import Foundation

/// The contract of `ExpectedDocument`: what the keyboard's own edits are recorded as, how a proxy
/// reading is attributed to them (confirmed, contradicted, pending), in which order, and when they
/// expire. The editor's use of it is covered by `SwipeEditorTests`. Invented text only.
enum ExpectedDocumentTests {
    static var tests: [TestCase] {
        [
            ("recordsTheEditAndWhatItWasIssuedAgainst", testRecordsTheEditAndWhatItWasIssuedAgainst),
            ("aReadingShowingTheEditConfirmsIt", testAReadingShowingTheEditConfirmsIt),
            ("aWindowMustShowTheWitness", testAWindowMustShowTheWitness),
            ("anEmptyReadingConfirmsOnlyAnEmptyResult", testAnEmptyReadingConfirmsOnlyAnEmptyResult),
            ("exactMatchNeedsTheWholeReading", testExactMatchNeedsTheWholeReading),
            ("aLaggingReadingIsPendingUntilTheEditIsShown", testALaggingReadingIsPendingUntilTheEditIsShown),
            ("aDivergingReadingContradicts", testADivergingReadingContradicts),
            ("anotherFieldContradicts", testAnotherFieldContradicts),
            ("expiresByTime", testExpiresByTime),
            ("aClockThatWentBackExpires", testAClockThatWentBackExpires),
            ("anUnboundedLifetimeNeverExpiresByTime", testAnUnboundedLifetimeNeverExpiresByTime),
            ("capacityDropsTheOldest", testCapacityDropsTheOldest),
            ("aGenerationChangeContradictsEverything", testAGenerationChangeContradictsEverything),
            ("ownLaterEditsAccountForTheirGenerations", testOwnLaterEditsAccountForTheirGenerations),
            ("severalPendingEditsConfirmInIssueOrder", testSeveralPendingEditsConfirmInIssueOrder),
            ("aConfirmationSupersedesOlderEdits", testAConfirmationSupersedesOlderEdits),
            ("aContradictionPropagatesToNewerEdits", testAContradictionPropagatesToNewerEdits),
            ("removingForgetsOnlyWhatIsNotKept", testRemovingForgetsOnlyWhatIsNotKept),
        ]
    }

    private static let field = Fixture.documentA
    private static let otherField = Fixture.documentB

    private static func reading(_ before: String, _ after: String = "", field: UUID? = field) -> ExpectedDocument.Reading {
        ExpectedDocument.Reading(documentID: field, before: before, after: after)
    }

    /// " gamma" typed after "alpha beta" with "!" after the caret, at generation 4 and time 10.
    private static func typedGamma(into expected: inout ExpectedDocument, match: ExpectedDocument.Match = .window,
                                   at time: TimeInterval = 10) -> ExpectedDocument.ID {
        expected.record(inserting: " gamma", on: reading("alpha beta", "!"), leaving: ("alpha beta gamma", "!"),
                        witness: "gamma", match: match, generation: 4, at: time)
    }

    // MARK: Recording

    private static func testRecordsTheEditAndWhatItWasIssuedAgainst() {
        var expected = ExpectedDocument()
        TestSupport.expect(expected.expectations.isEmpty, "Starts empty")
        let id = expected.record(deleting: 2, inserting: "xy", on: reading("one two", "!"), leaving: ("one xy", "!"),
                                 generation: 9, at: 3)
        guard let recorded = expected[id] else { return TestSupport.expect(false, "The edit is recorded") }
        TestSupport.expectEqual(recorded.id, id)
        TestSupport.expectEqual(recorded.deleted, 2)
        TestSupport.expectEqual(recorded.inserted, "xy")
        // The witness defaults to the inserted text.
        TestSupport.expectEqual(recorded.witness, "xy")
        TestSupport.expectEqual(recorded.match, .window)
        TestSupport.expectEqual(recorded.documentID, field)
        TestSupport.expectEqual(recorded.readingBefore, reading("one two", "!"))
        TestSupport.expectEqual(recorded.expected, reading("one xy", "!"))
        TestSupport.expectEqual(recorded.generation, 9)
        TestSupport.expectEqual(recorded.issuedAt, 3)
        TestSupport.expect(!recorded.shown, "Not shown before any reading")
        // Each record gets its own identity; expectations are kept oldest first.
        let second = expected.record(inserting: "z", on: reading("one xy", "!"), leaving: ("one xyz", "!"),
                                     generation: 10, at: 4)
        TestSupport.expect(second != id, "Distinct identities")
        TestSupport.expectEqual(expected.expectations.map(\.id), [id, second])
        // A nil context reads as empty.
        TestSupport.expectEqual(ExpectedDocument.Reading(documentID: nil, before: nil, after: nil),
                                ExpectedDocument.Reading(documentID: nil, before: "", after: ""))
    }

    // MARK: Confirmation

    private static func testAReadingShowingTheEditConfirmsIt() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        // Exactly the text the edit left.
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4, now: 11),
                                .confirmed)
        // A host window that shows more before it, or less (a window starting at a line start).
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("zero alpha beta gamma", "!"), generation: 4, now: 11),
                                .confirmed)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("beta gamma", "!"), generation: 4, now: 11),
                                .confirmed)
        // The text after the caret must be exactly the one the edit left.
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!?"), generation: 4, now: 11),
                                .contradicted)
    }

    private static func testAWindowMustShowTheWitness() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        // A window too narrow to show the whole witness proves nothing.
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("mma", "!"), generation: 4, now: 11), .contradicted)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("gamma", "!"), generation: 4, now: 11), .confirmed)
        // Without an explicit witness, the inserted text (here with its space) must show.
        var plain = ExpectedDocument()
        let typed = plain.record(inserting: " gamma", on: reading("alpha beta", "!"), leaving: ("alpha beta gamma", "!"),
                                 generation: 4, at: 10)
        TestSupport.expectEqual(plain.verdict(of: typed, for: reading("gamma", "!"), generation: 4, now: 11), .contradicted)
        TestSupport.expectEqual(plain.verdict(of: typed, for: reading(" gamma", "!"), generation: 4, now: 11), .confirmed)
    }

    private static func testAnEmptyReadingConfirmsOnlyAnEmptyResult() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("", "!"), generation: 4, now: 11), .contradicted)
        // Deleting everything before the caret leaves an empty text, which only an empty reading shows.
        var cleared = ExpectedDocument()
        let deletion = cleared.record(deleting: 2, inserting: "", on: reading("ab"), leaving: ("", ""), generation: 1, at: 10)
        TestSupport.expectEqual(cleared.verdict(of: deletion, for: reading(""), generation: 1, now: 11), .confirmed)
        TestSupport.expectEqual(cleared.verdict(of: deletion, for: reading("b"), generation: 1, now: 11), .contradicted)
    }

    private static func testExactMatchNeedsTheWholeReading() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected, match: .exact)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4, now: 11),
                                .confirmed)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("beta gamma", "!"), generation: 4, now: 11),
                                .contradicted)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("zero alpha beta gamma", "!"), generation: 4, now: 11),
                                .contradicted)
    }

    // MARK: Pending and contradiction

    private static func testALaggingReadingIsPendingUntilTheEditIsShown() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        let lagging = reading("alpha beta", "!")
        // The proxy has not shown the edit yet: it still reads what it read before it.
        TestSupport.expectEqual(expected.verdict(of: id, for: lagging, generation: 4, now: 11), .pending)
        // Observing a lagging or diverging reading latches nothing.
        expected.observe(lagging, generation: 4, now: 11)
        expected.observe(reading("other", "!"), generation: 4, now: 11)
        TestSupport.expect(expected[id]?.shown == false, "Not shown yet")
        TestSupport.expectEqual(expected.verdict(of: id, for: lagging, generation: 4, now: 12), .pending)
        // Once the proxy has been seen showing it, the old reading is an older state of the field (the
        // host undid the edit), never a lag.
        expected.observe(reading("alpha beta gamma", "!"), generation: 4, now: 12)
        TestSupport.expect(expected[id]?.shown == true, "Shown")
        TestSupport.expectEqual(expected.verdict(of: id, for: lagging, generation: 4, now: 13), .contradicted)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4, now: 13),
                                .confirmed)
    }

    private static func testADivergingReadingContradicts() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        for diverging in [reading("alpha beta delta", "!"), reading("alpha beta", ""), reading("alpha", "!"),
                          reading("alpha beta gamma", "")] {
            TestSupport.expectEqual(expected.verdict(of: id, for: diverging, generation: 4, now: 11), .contradicted)
        }
        let attribution = expected.attribute(reading("alpha beta delta", "!"), generation: 4, now: 11)
        TestSupport.expectEqual(attribution, ExpectedDocument.Attribution(confirmed: [], contradicted: [id], pending: []))
    }

    private static func testAnotherFieldContradicts() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!", field: otherField),
                                                 generation: 4, now: 11), .contradicted)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta", "!", field: nil), generation: 4, now: 11),
                                .contradicted)
        // An edit recorded with no field identity is judged against readings with none.
        var unidentified = ExpectedDocument()
        let anonymous = unidentified.record(inserting: "x", on: reading("a", field: nil), leaving: ("ax", ""),
                                            generation: 1, at: 10)
        TestSupport.expectEqual(unidentified.verdict(of: anonymous, for: reading("ax", field: nil), generation: 1, now: 11),
                                .confirmed)
        TestSupport.expectEqual(unidentified.verdict(of: anonymous, for: reading("ax"), generation: 1, now: 11),
                                .contradicted)
    }

    // MARK: Lifetime

    private static func testExpiresByTime() {
        var expected = ExpectedDocument(capacity: 4, lifetime: 2)
        let id = typedGamma(into: &expected, at: 10)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4, now: 11.9),
                                .confirmed)
        // At the end of its lifetime it is gone from every query, before anything removes it.
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4, now: 12), nil)
        TestSupport.expectEqual(expected.attribute(reading("alpha beta gamma", "!"), generation: 4, now: 12),
                                ExpectedDocument.Attribution(confirmed: [], contradicted: [], pending: []))
        TestSupport.expectEqual(expected.expectations.count, 1)
        expected.expire(now: 11)
        TestSupport.expectEqual(expected.expectations.count, 1)
        expected.expire(now: 12)
        TestSupport.expect(expected.expectations.isEmpty, "Expired")
        // Recording drops what has expired by then.
        _ = typedGamma(into: &expected, at: 20)
        let later = typedGamma(into: &expected, at: 23)
        TestSupport.expectEqual(expected.expectations.map(\.id), [later])
    }

    private static func testAClockThatWentBackExpires() {
        var expected = ExpectedDocument(capacity: 4, lifetime: 2)
        let id = typedGamma(into: &expected, at: 10)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4, now: 9), nil)
        expected.expire(now: 9)
        TestSupport.expect(expected.expectations.isEmpty, "A clock that went back expires the edit")
    }

    private static func testAnUnboundedLifetimeNeverExpiresByTime() {
        var expected = ExpectedDocument(capacity: 2, lifetime: .infinity)
        let id = typedGamma(into: &expected, at: 10)
        expected.expire(now: 1_000_000)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 4,
                                                 now: 1_000_000), .confirmed)
    }

    private static func testCapacityDropsTheOldest() {
        var expected = ExpectedDocument(capacity: 2, lifetime: 30)
        let first = expected.record(inserting: "a", on: reading(""), leaving: ("a", ""), generation: 1, at: 10)
        let second = expected.record(inserting: "b", on: reading("a"), leaving: ("ab", ""), generation: 2, at: 11)
        let third = expected.record(inserting: "c", on: reading("ab"), leaving: ("abc", ""), generation: 3, at: 12)
        TestSupport.expectEqual(expected.expectations.map(\.id), [second, third])
        TestSupport.expect(expected[first] == nil, "The oldest is dropped")
        TestSupport.expectEqual(expected.verdict(of: first, for: reading("abc"), generation: 3, now: 12), nil)
    }

    // MARK: Generations

    private static func testAGenerationChangeContradictsEverything() {
        var expected = ExpectedDocument()
        let id = typedGamma(into: &expected)
        // Something not recorded here edited the field since: even a reading that shows the edit, or still
        // lags it, no longer proves anything.
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta gamma", "!"), generation: 5, now: 11),
                                .contradicted)
        TestSupport.expectEqual(expected.verdict(of: id, for: reading("alpha beta", "!"), generation: 5, now: 11),
                                .contradicted)
        // And it latches nothing.
        expected.observe(reading("alpha beta gamma", "!"), generation: 5, now: 11)
        TestSupport.expect(expected[id]?.shown == false, "A stale generation latches nothing")
    }

    private static func testOwnLaterEditsAccountForTheirGenerations() {
        var expected = ExpectedDocument()
        let first = expected.record(inserting: "a", on: reading("x"), leaving: ("xa", ""), generation: 3, at: 10)
        let second = expected.record(inserting: "b", on: reading("x"), leaving: ("xab", ""), generation: 4, at: 11)
        // The step from 3 to 4 is the second edit's own: the first is still judged on the reading.
        let attribution = expected.attribute(reading("x"), generation: 4, now: 12)
        TestSupport.expectEqual(attribution, ExpectedDocument.Attribution(confirmed: [], contradicted: [],
                                                                          pending: [first, second]))
        TestSupport.expectEqual(attribution.verdict(of: first), .pending)
        // Any other generation contradicts both.
        TestSupport.expectEqual(expected.attribute(reading("x"), generation: 3, now: 12),
                                ExpectedDocument.Attribution(confirmed: [], contradicted: [first, second], pending: []))
    }

    // MARK: Attribution order

    /// Three keys typed while the proxy lags: each was issued on the reading "x", and each left one
    /// more letter.
    private static func threeLaggingEdits(_ expected: inout ExpectedDocument) -> [ExpectedDocument.ID] {
        [
            expected.record(inserting: "a", on: reading("x"), leaving: ("xa", ""), generation: 1, at: 10),
            expected.record(inserting: "b", on: reading("x"), leaving: ("xab", ""), generation: 2, at: 10.1),
            expected.record(inserting: "c", on: reading("x"), leaving: ("xabc", ""), generation: 3, at: 10.2),
        ]
    }

    private static func testSeveralPendingEditsConfirmInIssueOrder() {
        var expected = ExpectedDocument()
        let ids = threeLaggingEdits(&expected)
        typealias Attribution = ExpectedDocument.Attribution
        // Nothing shown yet: all three pending, oldest first.
        TestSupport.expectEqual(expected.attribute(reading("x"), generation: 3, now: 11),
                                Attribution(confirmed: [], contradicted: [], pending: ids))
        // The proxy shows the first edit only: the later ones still lag behind it.
        TestSupport.expectEqual(expected.attribute(reading("xa"), generation: 3, now: 11),
                                Attribution(confirmed: [ids[0]], contradicted: [], pending: [ids[1], ids[2]]))
        TestSupport.expectEqual(expected.attribute(reading("xab"), generation: 3, now: 11),
                                Attribution(confirmed: [ids[0], ids[1]], contradicted: [], pending: [ids[2]]))
        TestSupport.expectEqual(expected.attribute(reading("xabc"), generation: 3, now: 11),
                                Attribution(confirmed: ids, contradicted: [], pending: []))
        // Observing a reading latches every edit it confirms.
        expected.observe(reading("xab"), generation: 3, now: 11)
        TestSupport.expectEqual(expected.expectations.map(\.shown), [true, true, false])
        // The third still lags while the proxy shows the second.
        TestSupport.expectEqual(expected.verdict(of: ids[2], for: reading("xab"), generation: 3, now: 12), .pending)
    }

    private static func testAConfirmationSupersedesOlderEdits() {
        var expected = ExpectedDocument()
        let ids = threeLaggingEdits(&expected)
        // A reading that shows the last edit has applied the earlier ones, though their own results
        // ("xa", "xab") are no longer what the proxy shows.
        TestSupport.expectEqual(expected.attribute(reading("xabc"), generation: 3, now: 11).confirmed, ids)
        expected.observe(reading("xabc"), generation: 3, now: 11)
        TestSupport.expectEqual(expected.expectations.map(\.shown), [true, true, true])
    }

    private static func testAContradictionPropagatesToNewerEdits() {
        var expected = ExpectedDocument()
        let ids = threeLaggingEdits(&expected)
        typealias Attribution = ExpectedDocument.Attribution
        // The field shows something none of them explains: each later edit was issued on top of an earlier
        // one, so all three are contradicted.
        TestSupport.expectEqual(expected.attribute(reading("xz"), generation: 3, now: 11),
                                Attribution(confirmed: [], contradicted: ids, pending: []))
        // The first was shown, then the field went back to before it (the host undid it): the first is
        // contradicted, and the later ones, though their reading before is "x" again, with it.
        expected.observe(reading("xa"), generation: 3, now: 11)
        TestSupport.expectEqual(expected.attribute(reading("x"), generation: 3, now: 12),
                                Attribution(confirmed: [], contradicted: ids, pending: []))
    }

    private static func testRemovingForgetsOnlyWhatIsNotKept() {
        var expected = ExpectedDocument()
        let ids = threeLaggingEdits(&expected)
        expected.remove(ids[1])
        TestSupport.expectEqual(expected.expectations.map(\.id), [ids[0], ids[2]])
        expected.removeAll(keeping: [ids[2]])
        TestSupport.expectEqual(expected.expectations.map(\.id), [ids[2]])
        expected.removeAll()
        TestSupport.expect(expected.expectations.isEmpty, "Nothing kept")
        // Identities are never reused after removal.
        let next = expected.record(inserting: "d", on: reading("x"), leaving: ("xd", ""), generation: 4, at: 11)
        TestSupport.expect(!ids.contains(next), "A fresh identity")
    }
}
