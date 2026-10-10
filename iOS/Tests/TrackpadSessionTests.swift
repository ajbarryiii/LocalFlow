import Foundation

enum TrackpadSessionTests {
    static var tests: [TestCase] {
        [
            ("pointStartsAtTheCaret", testPointStartsAtTheCaret),
            ("caretGoesToTheNearestBoundary", testCaretGoesToTheNearestBoundary),
            ("wideCharactersTakeMoreTravel", testWideCharactersTakeMoreTravel),
            ("noWrapAtLineEnds", testNoWrapAtLineEnds),
            ("columnKeptAcrossShortAndLongLines", testColumnKeptAcrossShortAndLongLines),
            ("nearestLineSnapsAtHalfALine", testNearestLineSnapsAtHalfALine),
            ("clampAndImmediateReversal", testClampAndImmediateReversal),
            ("windowIsReSnapshotted", testWindowIsReSnapshotted),
            ("fakeHostMatchesTheMeasuredContext", testFakeHostMatchesTheMeasuredContext),
            ("hiddenParagraphBreakIsReachedVertically", testHiddenParagraphBreakIsReachedVertically),
            ("upFromAParagraphStart", testUpFromAParagraphStart),
            ("upFromALineStartKeepsTheColumn", testUpFromALineStartKeepsTheColumn),
            ("columnIsKeptOnALineWhoseStartWasHidden", testColumnIsKeptOnALineWhoseStartWasHidden),
            ("provisionalEdgeIsNotACrossing", testProvisionalEdgeIsNotACrossing),
            ("caretAtTheWindowEdgeIsNotACrossing", testCaretAtTheWindowEdgeIsNotACrossing),
            ("crossingWithoutCallbacksWaitsForTheTimeout", testCrossingWithoutCallbacksWaitsForTheTimeout),
            ("lastLineKeepsItsColumnDespiteTheProvisionalEdge", testLastLineKeepsItsColumnDespiteTheProvisionalEdge),
            ("firstLineKeepsItsColumn", testFirstLineKeepsItsColumn),
            ("blankLinesAreNotABoundary", testBlankLinesAreNotABoundary),
            ("ignoredProbesAreBoundedUntilNewTravel", testIgnoredProbesAreBoundedUntilNewTravel),
            ("longAmbiguousBlankRunsStayPassable", testLongAmbiguousBlankRunsStayPassable),
            ("liftDuringAnEdgeProbeStillReachesTheColumn", testLiftDuringAnEdgeProbeStillReachesTheColumn),
            ("unknownUnitVerticalFlick", testUnknownUnitVerticalFlick),
            ("liftBeforeAProbeResolves", testLiftBeforeAProbeResolves),
            ("learnsUTF16UnitsWithoutSplittingClusters", testLearnsUTF16UnitsWithoutSplittingClusters),
            ("learnsGraphemeUnits", testLearnsGraphemeUnits),
            ("knownUnitSkipsTheProbe", testKnownUnitSkipsTheProbe),
            ("noProbeAcrossSingleCodeUnits", testNoProbeAcrossSingleCodeUnits),
            ("combiningMarksStayWhole", testCombiningMarksStayWhole),
            ("mixedTextNeverEndsInsideACluster", testMixedTextNeverEndsInsideACluster),
            ("windowedHostsNeverLeaveTheCaretInsideACluster", testWindowedHostsNeverLeaveTheCaretInsideACluster),
            ("laggingHostConverges", testLaggingHostConverges),
            ("fastDragsGoFarther", testFastDragsGoFarther),
            ("sensitivityScalesTravel", testSensitivityScalesTravel),
            ("eventStepScaleNormalizesSteps", testEventStepScaleNormalizesSteps),
            ("oneAdjustmentPerFrame", testOneAdjustmentPerFrame),
            ("pendingMovesLandAfterLift", testPendingMovesLandAfterLift),
            ("staleContextTeachesNoUnit", testStaleContextTeachesNoUnit),
            ("unitNeedsDiscriminatingEvidence", testUnitNeedsDiscriminatingEvidence),
            ("outcomeInsideAClusterIsCompleted", testOutcomeInsideAClusterIsCompleted),
            ("unplacedOutcomeIsRolledBack", testUnplacedOutcomeIsRolledBack),
            ("probeWaitsForTheHostsOwnContext", testProbeWaitsForTheHostsOwnContext),
            ("unanswerableProbesAreRetriedWithinBudget", testUnanswerableProbesAreRetriedWithinBudget),
            ("probesNeverStopInsideASurrogatePair", testProbesNeverStopInsideASurrogatePair),
            ("cancellationRollsBackAtOnce", testCancellationRollsBackAtOnce),
            ("liftFinishesAProbedCluster", testLiftFinishesAProbedCluster),
            ("hiddenClusterPastTheEdgeIsRepaired", testHiddenClusterPastTheEdgeIsRepaired),
            ("callbacksMustMatchAnExpectedOutcome", testCallbacksMustMatchAnExpectedOutcome),
            ("probeCallbacksAreValidated", testProbeCallbacksAreValidated),
            ("finishesOnlyAfterItsCallbacks", testFinishesOnlyAfterItsCallbacks),
            ("cancelledJumpIntoAHiddenClusterIsRepaired", testCancelledJumpIntoAHiddenClusterIsRepaired),
            ("emptiedFieldIsNotACrossing", testEmptiedFieldIsNotACrossing),
            ("singleEmojiFieldIsReachedInEitherUnit", testSingleEmojiFieldIsReachedInEitherUnit),
            ("webKitReportsEachAdjustmentTwice", testWebKitReportsEachAdjustmentTwice),
        ]
    }

    // MARK: The floating point

    // MARK: The floating point

    private static func testPointStartsAtTheCaret() {
        let host = FakeTextHost(text: "abc\ndefgh", caret: 6)
        let session = makeSession(host)
        // "de|fgh": line 1 (center 30 at a 20-point line height), column 20.
        TestSupport.expectEqual(session.point.x, 20)
        TestSupport.expectEqual(session.point.y, 30)
    }

    private static func testCaretGoesToTheNearestBoundary() {
        var host = FakeTextHost(text: "abcdefghij")
        var session = makeSession(host)
        // From x = 100: 32 points left is x = 68, nearest the boundary at 70.
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 64))
        TestSupport.expectEqual(host.caret, 7)
        TestSupport.expect(session.isSettled, "not settled")
        TestSupport.expectEqual(session.unit, nil)
        var further = FakeTextHost(text: "abcdefghij")
        var furtherSession = makeSession(further)
        runGesture(&furtherSession, host: &further, samples: slowDrag(dx: -0.5, samples: 72))
        TestSupport.expectEqual(further.caret, 6)
    }

    private static func testWideCharactersTakeMoreTravel() {
        // The same 38 points of travel cross two 16-point "m"s and eight 5-point "i"s.
        var wide = FakeTextHost(text: String(repeating: "m", count: 10))
        var wideSession = makeSession(wide, advance: testAdvance)
        runGesture(&wideSession, host: &wide, samples: slowDrag(dx: -0.5, samples: 76))
        var narrow = FakeTextHost(text: String(repeating: "i", count: 10))
        var narrowSession = makeSession(narrow, advance: testAdvance)
        runGesture(&narrowSession, host: &narrow, samples: slowDrag(dx: -0.5, samples: 76))
        TestSupport.expectEqual(wide.caret, 8)
        TestSupport.expectEqual(narrow.caret, 2)
    }

    private static func testNoWrapAtLineEnds() {
        // Past a line's end or start the caret stays at that end of the same line.
        var right = FakeTextHost(text: "abc\ndefgh", caret: 2)
        var rightSession = makeSession(right)
        runGesture(&rightSession, host: &right, samples: slowDrag(dx: 0.5, samples: 200))
        TestSupport.expectEqual(right.caret, 3)
        var left = FakeTextHost(text: "abc\ndefgh", caret: 6)
        var leftSession = makeSession(left)
        runGesture(&leftSession, host: &left, samples: slowDrag(dx: -0.5, samples: 200))
        TestSupport.expectEqual(left.caret, 4)
        // Soft wraps too: "abcde|fghij" in columns of 5. The end of the first line is reachable.
        var soft = FakeTextHost(text: "abcdefghij", caret: 7)
        var softSession = makeSession(soft, columns: 5)
        runGesture(&softSession, host: &soft, samples: slowDrag(dx: -0.5, samples: 200))
        TestSupport.expectEqual(soft.caret, 5)
        var softRight = FakeTextHost(text: "abcdefghij", caret: 2)
        var softRightSession = makeSession(softRight, columns: 5)
        runGesture(&softRightSession, host: &softRight, samples: slowDrag(dx: 0.5, samples: 200))
        TestSupport.expectEqual(softRight.caret, 5)
        TestSupport.expectEqual(softRightSession.point.y, 10)
    }

    private static let lines = "abcdefghij" + "klmnopqrst" + "uv\n" + "wxyzabcdef" + "gh"

    private static func testColumnKeptAcrossShortAndLongLines() {
        // Columns of 10: "abcdefghij|klmnopqrst|uv\n|wxyzabcdef|gh"; the caret is after "klm" (x = 30).
        var oneLine = FakeTextHost(text: lines, caret: 13)
        var session = makeSession(oneLine, columns: 10)
        runGesture(&session, host: &oneLine, samples: slowDrag(dy: 0.5, samples: 40))
        // The short line "uv": as close to x = 30 as it goes, before its line break.
        TestSupport.expectEqual(oneLine.caret, 22)
        var twoLines = FakeTextHost(text: lines, caret: 13)
        var twoSession = makeSession(twoLines, columns: 10)
        runGesture(&twoSession, host: &twoLines, samples: slowDrag(dy: 0.5, samples: 80))
        // Back at x = 30 on the next long line: the column is kept in points, not drifted to 20.
        TestSupport.expectEqual(twoLines.caret, 26)
        TestSupport.expectEqual(twoSession.point.x, 30)
        var up = FakeTextHost(text: lines, caret: 26)
        var upSession = makeSession(up, columns: 10)
        runGesture(&upSession, host: &up, samples: slowDrag(dy: -0.5, samples: 80))
        TestSupport.expectEqual(up.caret, 13)
    }

    private static func testNearestLineSnapsAtHalfALine() {
        let text = "abcdefghij" + "klmnopqrst"
        var host = FakeTextHost(text: text, caret: 3)
        var session = makeSession(host, columns: 10)
        // 9.9 points down is still nearer line 0's center; 10.1 is nearer line 1's.
        var time = runGesture(&session, host: &host, samples: [(0, 9.9)], end: false)
        TestSupport.expectEqual(host.caret, 3)
        time = runGesture(&session, host: &host, samples: [(0, 0.2)], start: time, end: false)
        TestSupport.expectEqual(host.caret, 13)
        // And straight back: no hysteresis.
        runGesture(&session, host: &host, samples: [(0, -0.3)], start: time)
        TestSupport.expectEqual(host.caret, 3)
    }

    private static func testClampAndImmediateReversal() {
        let width = 100.0
        var host = FakeTextHost(text: "abc", caret: 3)
        var session = makeSession(host, layoutWidth: width)
        // Far right: x is held at width - 1.5, and the overshoot is not remembered.
        var time = runGesture(&session, host: &host, samples: slowDrag(dx: 2, samples: 300), end: false)
        TestSupport.expectEqual(session.point.x, width - 1.5)
        TestSupport.expectEqual(host.caret, 3)
        time = runGesture(&session, host: &host, samples: [(-1, 0)], start: time, end: false)
        TestSupport.expectEqual(session.point.x, width - 2.5)
        // Far left: x is held at 1.0 (measured on device), and the caret answers the first reversal.
        time = runGesture(&session, host: &host, samples: slowDrag(dx: -2, samples: 300), start: time, end: false)
        TestSupport.expectEqual(session.point.x, 1.0)
        TestSupport.expectEqual(host.caret, 0)
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 14), start: time)
        TestSupport.expectEqual(host.caret, 1)
    }

    private static func testWindowIsReSnapshotted() {
        // A field the proxy shows 8 characters of at a time: the point keeps its offset from the
        // caret each time the snapshot moves, so 300 points still reach the 30th character.
        let text = String(repeating: "abcdefghij", count: 6)
        var host = FakeTextHost(text: text, caret: 0, window: 8)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 600))
        TestSupport.expectEqual(host.caret, 30)
    }

    // MARK: The measured context and vertical moves

    /// The text of the simulator run behind the measured context (iOS 26.4, a UITextView).
    private static let measuredText = "First line of a long invented paragraph that wraps across several visual lines in this text view, so vertical moves cross soft wraps while the column stays put. It keeps going for a while longer.\nShort line.\nLast paragraph here."

    private static func testFakeHostMatchesTheMeasuredContext() {
        // Context lengths the keyboard logged at these carets (before, after), content-free.
        let measured: [(caret: Int, before: Int, after: Int)] = [
            (150, 150, 11), (169, 169, 26), (172, 172, 23), (196, 196, 11), (204, 204, 3), (207, 207, 0),
            (208, 208, 20), (215, 54, 13), (228, 67, 0),
        ]
        for sample in measured {
            let context = FakeTextHost(text: measuredText, caret: sample.caret, model: .uikit).context
            TestSupport.expectEqual(context.before.utf16.count, sample.before)
            TestSupport.expectEqual(context.after.utf16.count, sample.after)
        }
    }

    private static func testHiddenParagraphBreakIsReachedVertically() {
        // UIKit's after-context stops at the line break, so the next paragraph is reached by one jump past
        // it, straight from the caret's column to the same column below.
        let text = "first para line\nsecond para here"
        var host = FakeTextHost(text: text, caret: 5, model: .uikit)
        TestSupport.expectEqual(host.context.after, " para line")
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 21)
        TestSupport.expectEqual(host.adjustmentCount, 2)
        // Back up: the before-context spans the line break, so the line above is already known.
        var back = FakeTextHost(text: text, caret: 21, model: .uikit)
        TestSupport.expectEqual(back.context.before, "first para line\nsecon")
        var backSession = makeSession(back)
        runGesture(&backSession, host: &back, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(back.caret, 5)
        TestSupport.expectEqual(back.adjustmentCount, 1)
    }

    private static func testUpFromAParagraphStart() {
        // From "se|cond", one line up: the column in "first line". With the measured context the line
        // above is in the snapshot; with a context that stops at the line break it takes a jump.
        for model in [FakeContextModel.uikit, .lineBreakOnly] {
            var host = FakeTextHost(text: "first line\nsecond", caret: 13, model: model)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: slowDrag(dy: -0.5, samples: 40))
            TestSupport.expectEqual(host.caret, 2)
        }
    }

    private static func testUpFromALineStartKeepsTheColumn() {
        // Right after a line break a context may show just "\n" before the caret: the line it ends is
        // hidden, so up from there is a jump to the line above, which then takes the point's column.
        // Regression: the "\n" once counted as a visible empty line and the caret went to the end of the
        // line above.
        for model in [FakeContextModel.lineBreakOnly, .uikit] {
            var host = FakeTextHost(text: "first line\nsecond", caret: 11, model: model)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: slowDrag(dy: -0.5, samples: 40))
            TestSupport.expectEqual(host.caret, 0)
            var moved = FakeTextHost(text: "first line\nsecond", caret: 11, model: model)
            var movedSession = makeSession(moved)
            runGesture(&movedSession, host: &moved, samples: slowDrag(dx: 0.5, samples: 60) + slowDrag(dy: -0.5, samples: 40))
            TestSupport.expectEqual(moved.caret, 3)
        }
        TestSupport.expectEqual(FakeTextHost(text: "first line\nsecond", caret: 11, model: .lineBreakOnly).context.before, "\n")
    }

    private static func testColumnIsKeptOnALineWhoseStartWasHidden() {
        // The window starts mid-line ("ld.\nShort."), so the line above has no real columns. Up from
        // "Short.|" (column 6) lands on it; as the host reveals more of the line, the snapshot is
        // refreshed and the point keeps its column: "Hello |there". Regression: the caret stayed at the
        // line's end, measured from the window's start.
        var host = FakeTextHost(text: "Hello there world.\nShort.", window: 10)
        TestSupport.expectEqual(host.context.before, "ld.\nShort.")
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 6)
        // Along that line, x is relative to the caret as before: the caret moves by the finger's travel.
        var along = FakeTextHost(text: "Hello there world.", caret: 15, window: 5)
        var alongSession = makeSession(along)
        runGesture(&alongSession, host: &along, samples: slowDrag(dx: -0.5, samples: 160))
        TestSupport.expectEqual(along.caret, 7)
    }

    private static func testProvisionalEdgeIsNotACrossing() {
        // Measured in UIKit: the proxy first answers a jump past its window from the text it last
        // reported, so the caret reads as sitting at that window's edge; the host's own context follows
        // with `textDidChange`. Regression: the provisional answer was taken as the crossing, the caret
        // was sent back into the old paragraph and the gesture ended.
        let text = "Alpha beta gamma.\nShort line.\nLast one."
        var host = FakeTextHost(text: text, caret: 8, model: .uikit, provisionalContext: true)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 26)   // "Short li|ne."
        TestSupport.expectEqual(host.adjustmentCount, 2)
        TestSupport.expect(session.isSettled, "not settled")
        var back = FakeTextHost(text: text, caret: 26, model: .uikit, provisionalContext: true)
        var backSession = makeSession(back)
        runGesture(&backSession, host: &back, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(back.caret, 8)
        var down = FakeTextHost(text: text, caret: 8, model: .uikit, provisionalContext: true)
        var downSession = makeSession(down)
        runGesture(&downSession, host: &down, samples: slowDrag(dy: 0.5, samples: 80))
        TestSupport.expectEqual(down.caret, 38)   // "Last one|." keeps column 8
    }

    private static func testCaretAtTheWindowEdgeIsNotACrossing() {
        // Even once acknowledged, a context that shows the caret exactly at the snapshot's edge with
        // nothing beyond is not a crossing (the proxy's provisional answer, or a host that clamps).
        func makeDown() -> TrackpadSession {
            var session = TrackpadSession(before: "Alpha be", after: "ta gamma.", unit: nil, parameters: .flat,
                                          layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
            session.drag(dx: 0, dy: 20)
            TestSupport.expectEqual(session.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1), 10)
            return session
        }
        var session = makeDown()
        TestSupport.expect(session.acknowledge(before: "Alpha beta gamma.\n", after: "Short line."), "crossing not expected")
        TestSupport.expectEqual(session.frame(before: "Alpha beta gamma.", after: nil, timestamp: 1.01), nil)
        // The host's own context after the jump: the start of the next paragraph, then the column.
        TestSupport.expectEqual(session.frame(before: "Alpha beta gamma.\n", after: "Short line.", timestamp: 1.02), 8)
        // Reported unchanged: the jump was ignored (the document's end) and the caret is where it was, or
        // this is WebKit's first report of it (as issued). WebKit's second report confirms it.
        var ignored = makeDown()
        TestSupport.expect(ignored.acknowledge(before: "Alpha be", after: "ta gamma."), "ignored jump not expected")
        TestSupport.expectEqual(ignored.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1.02), nil)
        TestSupport.expectEqual(ignored.ambiguousProbes[.end], nil)
        TestSupport.expect(ignored.acknowledge(before: "Alpha be", after: "ta gamma."), "second report not expected")
        TestSupport.expectEqual(ignored.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1.03), nil)
        TestSupport.expectEqual(ignored.committed, 8)
        TestSupport.expectEqual(ignored.ambiguousProbes[.end], 1)
        // A host that reports once: with nothing else known, the timeout tells.
        var once = makeDown()
        TestSupport.expect(once.acknowledge(before: "Alpha be", after: "ta gamma."), "ignored jump not expected")
        TestSupport.expectEqual(once.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1.31), nil)
        TestSupport.expectEqual(once.committed, 8)
        TestSupport.expectEqual(once.ambiguousProbes[.end], 1)
        // Known to report once (a move reported only as it landed): confirmed at once.
        var known = TrackpadSession(before: "Alpha be", after: "ta gamma.", unit: nil, parameters: .flat,
                                    layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
        known.drag(dx: -10, dy: 0)
        TestSupport.expectEqual(known.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1), -1)
        TestSupport.expect(known.acknowledge(before: "Alpha b", after: "eta gamma."), "move not expected")
        TestSupport.expectEqual(known.frame(before: "Alpha b", after: "eta gamma.", timestamp: 1.01), nil)
        known.drag(dx: 0, dy: 20)
        TestSupport.expect(known.frame(before: "Alpha b", after: "eta gamma.", timestamp: 1.02) != nil, "no jump")
        TestSupport.expect(known.acknowledge(before: "Alpha b", after: "eta gamma."), "ignored jump not expected")
        TestSupport.expectEqual(known.frame(before: "Alpha b", after: "eta gamma.", timestamp: 1.03), nil)
        TestSupport.expectEqual(known.committed, 7)
        TestSupport.expectEqual(known.ambiguousProbes[.end], 1)
        // Still the provisional edge at the timeout: the same.
        var late = makeDown()
        TestSupport.expectEqual(late.frame(before: "Alpha beta gamma.", after: nil, timestamp: 1.31), nil)
        TestSupport.expectEqual(late.committed, 8)
        TestSupport.expectEqual(late.ambiguousProbes[.end], 1)
    }

    private static func testCrossingWithoutCallbacksWaitsForTheTimeout() {
        // A host that never sends `textDidChange` for an adjustment: each crossing is read after the
        // timeout instead.
        let text = "first para line\nsecond para here"
        var host = FakeTextHost(text: text, caret: 5, model: .uikit, callbackFrames: nil)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 21)
        TestSupport.expectEqual(host.adjustmentCount, 2)
    }

    private static func testLastLineKeepsItsColumnDespiteTheProvisionalEdge() {
        // Down on the document's last line the jump is ignored, but the proxy first shows the caret at
        // the line's end. The caret keeps its column and later moves are relative to where it is.
        var host = FakeTextHost(text: "Alpha.\nLast line here.", caret: 14, model: .uikit, provisionalContext: true)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40) + slowDrag(dx: 0.5, samples: 40),
                   restFrames: 120)
        TestSupport.expectEqual(host.caret, 16)   // "Last line| here.", two columns right
        TestSupport.expect(session.ambiguousProbes[.end, default: 0] >= 1, "no ambiguous probe")
    }

    private static func testFirstLineKeepsItsColumn() {
        // Up on the document's first line: the caret stays on it at its column, as on Apple's keyboard,
        // and never visits the line's start.
        var host = FakeTextHost(text: "abcdef", caret: 3)
        var session = makeSession(host)
        var visited: Set<Int> = []
        var time: TimeInterval = 100
        for _ in 0 ..< 200 {
            session.drag(dx: 0, dy: -0.5)
            runFrame(&session, host: &host, at: time)
            visited.insert(host.caret)
            time += 1.0 / 120
        }
        TestSupport.expectEqual(visited, [3])
        TestSupport.expect(session.ambiguousProbes[.start, default: 0] >= 1, "no ambiguous probe")
    }

    private static func testBlankLinesAreNotABoundary() {
        // Three lines down across blank lines, with the measured context and with one that shows the same
        // context ("\n" before, nothing after) at every blank line.
        for model in [FakeContextModel.uikit, .lineBreakOnly] {
            var host = FakeTextHost(text: "a\n\n\nb", caret: 1, model: model)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: slowDrag(dy: 0.1, samples: 600))
            TestSupport.expectEqual(host.caret, 5)
        }
    }

    private static func testIgnoredProbesAreBoundedUntilNewTravel() {
        let parameters = TrackpadParameters.standard
        var host = FakeTextHost(text: "abc", caret: 3)
        // A field an earlier gesture showed to report each adjustment once (UIKit): an unchanged report is
        // an ignored jump at once.
        var session = makeSession(host, reportsTwice: false)
        // Each ignored jump drops the overshoot, so the next one needs new travel; after eight the edge
        // holds like Apple's last line, 8 points below its center.
        var time = runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 60), end: false, restFrames: 2)
        TestSupport.expect(session.isSoftEdge(.end), "not held after repeated ignored probes")
        TestSupport.expectEqual(host.adjustmentCount, parameters.maximumAmbiguousProbes)
        TestSupport.expectEqual(session.point.y, 10 + parameters.bottomOvershoot)
        // Less than half a line of new travel past the held edge allows nothing more.
        time = runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 10), start: time, end: false,
                          restFrames: 2)
        TestSupport.expectEqual(host.adjustmentCount, parameters.maximumAmbiguousProbes)
        // Half a line allows one more probe; then it holds again.
        time = runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 20), start: time, end: false,
                          restFrames: 2)
        TestSupport.expectEqual(host.adjustmentCount, parameters.maximumAmbiguousProbes + 1)
        TestSupport.expect(session.isSoftEdge(.end), "not held again")
        // A reversal responds at once.
        runGesture(&session, host: &host, samples: [(0, -1)], start: time, end: false, restFrames: 0)
        TestSupport.expectEqual(session.point.y, 10 + parameters.bottomOvershoot - 1)
        TestSupport.expectEqual(host.caret, 3)
    }

    private static func testLongAmbiguousBlankRunsStayPassable() {
        // Regression: between blank lines a context that shows the same thing everywhere makes every
        // jump ambiguous, and after eight the run became impassable. New travel keeps it passable.
        let text = "a" + String(repeating: "\n", count: 12) + "b"
        var host = FakeTextHost(text: text, caret: 1, model: .lineBreakOnly)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 1_200))
        TestSupport.expectEqual(host.caret, 14)
        TestSupport.expect(host.adjustmentCount > TrackpadParameters.standard.maximumAmbiguousProbes + 2,
                           "too few jumps to have crossed the run")
    }

    // MARK: Lift before settlement

    private static func testLiftDuringAnEdgeProbeStillReachesTheColumn() {
        // A quick flick a line down; the finger lifts while the jump past the window is in flight. The
        // target stays where the point was: when the jump lands, the caret goes on to the column.
        let text = "Alpha beta gamma.\nShort line.\nLast one."
        for (provisional, callbacks) in [(false, Optional(1)), (true, 1), (false, nil)] {
            var host = FakeTextHost(text: text, caret: 8, model: .uikit, callbackFrames: callbacks,
                                    provisionalContext: provisional)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: [(0, 22)], restFrames: 0)
            TestSupport.expectEqual(host.caret, 26)
        }
    }

    private static func testUnknownUnitVerticalFlick() {
        // A flick a line down with the unit unknown, lifted at once: the jump, then a walk across the
        // emoji with a probe, all after the lift, to the column below ("x👍🏽yz more t|ext.").
        let text = "Alpha beta.\nx\u{1F44D}\u{1F3FD}yz more text."
        for unit in [CursorOffsetUnit.utf16, .grapheme] {
            var host = FakeTextHost(text: text, caret: 11, unit: unit, model: .uikit, provisionalContext: unit == .utf16)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: [(0, 15), (0, 10)], restFrames: 0)
            TestSupport.expectEqual(host.caret, 26)
            TestSupport.expect(host.caretIsOnBoundary, "inside a cluster in \(unit)")
            TestSupport.expectEqual(session.unit, unit)
        }
    }

    private static func testLiftBeforeAProbeResolves() {
        for unit in [CursorOffsetUnit.utf16, .grapheme] {
            var host = FakeTextHost(text: mixed, unit: unit, lagFrames: 2)
            var session = makeSession(host)
            // x 50 → 20 in one event, lifted at once: d and c, then the emoji's probe, after the lift.
            runGesture(&session, host: &host, samples: [(-30, 0)], restFrames: 0)
            TestSupport.expectEqual(host.caret, 2)
            TestSupport.expectEqual(session.unit, unit)
        }
    }

    // MARK: Units

    private static let mixed = "ab\u{1F44D}\u{1F3FD}cd"

    private static func testLearnsUTF16UnitsWithoutSplittingClusters() {
        var host = FakeTextHost(text: mixed, unit: .utf16)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 60))
        // x 50 → 20: crossed d, c and the 4-unit emoji; the caret is after "b", not inside the emoji.
        TestSupport.expectEqual(host.caret, 2)
        TestSupport.expectEqual(session.unit, .utf16)
        TestSupport.expect(host.caretIsOnBoundary, "split a cluster")
    }

    private static func testLearnsGraphemeUnits() {
        var host = FakeTextHost(text: mixed, unit: .grapheme)
        var session = makeSession(host)
        let time = runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 60), end: false)
        TestSupport.expectEqual(host.caret, 2)
        TestSupport.expectEqual(session.unit, .grapheme)
        // And back to the right across the emoji, now in known units.
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 20), start: time)
        TestSupport.expectEqual(host.caret, 6)
    }

    private static func testKnownUnitSkipsTheProbe() {
        var host = FakeTextHost(text: mixed, caret: 6, unit: .utf16)
        var session = makeSession(host, unit: .utf16)
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 20))
        TestSupport.expectEqual(host.caret, 2)
        TestSupport.expectEqual(host.adjustmentCount, 1)
    }

    private static func testNoProbeAcrossSingleCodeUnits() {
        // Precomposed accents and CJK are single BMP code points: both units count them alike, so the
        // unit stays unknown and every adjustment is a plain move.
        for unit in [CursorOffsetUnit.utf16, .grapheme] {
            var host = FakeTextHost(text: "h\u{E9}llo w\u{F6}rld \u{65E5}\u{672C}\u{8A9E}", unit: unit)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 200))
            TestSupport.expectEqual(host.caret, 5)
            TestSupport.expectEqual(session.unit, nil)
        }
    }

    private static func testCombiningMarksStayWhole() {
        for unit in [CursorOffsetUnit.utf16, .grapheme] {
            var host = FakeTextHost(text: "cafe\u{301}", unit: unit)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 20))
            TestSupport.expectEqual(host.caret, 3)
            TestSupport.expectEqual(session.unit, unit)
        }
    }

    private static func testMixedTextNeverEndsInsideACluster() {
        let text = "a\u{1F44D}\u{1F3FD}b e\u{301}\u{1F1EB}\u{1F1F7}c\u{1F469}\u{200D}\u{1F4BB}d"
        for unit in [CursorOffsetUnit.utf16, .grapheme] {
            var host = FakeTextHost(text: text, caret: 0, unit: unit)
            var session = makeSession(host)
            var time: TimeInterval = 100
            for (index, dx) in [0.5, -0.5, 0.5, 0.5, -0.5].enumerated() {
                time = runGesture(&session, host: &host, samples: slowDrag(dx: dx, samples: 25 + 10 * index), start: time,
                                  end: false)
                TestSupport.expect(host.caretIsOnBoundary, "inside a cluster after pass \(index) in \(unit)")
            }
            session.end(at: time)
            _ = runGesture(&session, host: &host, samples: [], start: time)
            TestSupport.expect(host.caretIsOnBoundary, "inside a cluster at the end in \(unit)")
        }
    }

    private static func testWindowedHostsNeverLeaveTheCaretInsideACluster() {
        // Regression: a probe whose outcome could not be placed (a narrow or repetitive window) was
        // discarded with the caret inside 👍🏽 or between e and its accent. Across windows, units, lag,
        // provisional answers, lifts and cancellations at every point, the caret ends on a boundary
        // and never stops between the halves of a surrogate pair of its own doing.
        let text = "a\u{1F44D}\u{1F3FD}b e\u{301}e\u{301}e\u{301} \u{1F44D}\u{1F3FD}\u{1F44D}\u{1F3FD}c. "
            + "Next \u{1F469}\u{200D}\u{1F4BB}d"
        let models: [(FakeContextModel, Int?)] = [(.whole, nil), (.uikit, nil), (.whole, 1), (.whole, 2), (.whole, 3)]
        for (model, window) in models {
            for unit in [CursorOffsetUnit.utf16, .grapheme] {
                for lag in [0, 2] {
                    for stop in [1, 2, 3, 5, 8, 13, 400] {
                        var host = FakeTextHost(text: text, caret: 0, unit: unit, model: model, window: window,
                                                lagFrames: lag, provisionalContext: unit == .utf16)
                        var session = makeSession(host)
                        var time: TimeInterval = 100
                        let drags = slowDrag(dx: 1.5, samples: 60) + slowDrag(dx: -1, samples: 40) + slowDrag(dx: 1, samples: 60)
                        for (index, drag) in drags.enumerated() where index < stop {
                            session.drag(dx: drag.dx, dy: drag.dy)
                            runFrame(&session, host: &host, at: time)
                            time += 1.0 / 120
                        }
                        if stop % 2 == 0, let rollback = session.cancel(at: time) {
                            host.adjust(by: rollback)
                        } else {
                            session.end(at: time)
                        }
                        for _ in 0 ..< 240 where !session.isFinished(at: time) {
                            runFrame(&session, host: &host, at: time)
                            time += 1.0 / 120
                        }
                        for _ in 0 ..< 10 { host.advanceFrame() }
                        TestSupport.expect(host.caretIsOnBoundary,
                                           "inside a cluster at \(host.caret): \(model) window "
                                               + "\(String(describing: window)) \(unit) lag \(lag) stop \(stop)")
                    }
                }
            }
        }
    }

    private static func testLaggingHostConverges() {
        var host = FakeTextHost(text: "abcdefghij\u{1F44D}\u{1F3FD}klmnop", caret: 0, lagFrames: 3)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 260))
        // 130 points: 13 characters, the emoji among them.
        TestSupport.expectEqual(host.caret, 16)
        TestSupport.expect(host.caretIsOnBoundary, "split a cluster")
    }

    // MARK: Gain

    private static func travel(samples: [(dx: Double, dy: Double)], parameters: TrackpadParameters = .standard) -> Int {
        // The measured curve, unlike the flat positional tests.
        var host = FakeTextHost(text: String(repeating: "x", count: 400), caret: 0)
        var session = makeSession(host, parameters: parameters)
        runGesture(&session, host: &host, samples: samples)
        return host.caret
    }

    private static func testFastDragsGoFarther() {
        // The same 120 points of finger travel in 0.5-point events (gain 1.01) and in 12-point events
        // (gain 2.35): 121.2 and 282.3 points of travel, to the nearest 10-point boundary.
        TestSupport.expectEqual(travel(samples: slowDrag(dx: 0.5, samples: 240)), 12)
        TestSupport.expectEqual(travel(samples: slowDrag(dx: 12, samples: 10)), 28)
    }

    private static func testSensitivityScalesTravel() {
        let doubled = TrackpadParameters.standard.tuned(sensitivity: 2, acceleration: 1)
        TestSupport.expectEqual(travel(samples: slowDrag(dx: 0.25, samples: 240), parameters: doubled), 12)
        let flatter = TrackpadParameters.standard.tuned(sensitivity: 1, acceleration: 0.25)
        TestSupport.expectEqual(travel(samples: slowDrag(dx: 12, samples: 10), parameters: flatter), 16)
    }

    private static func testEventStepScaleNormalizesSteps() {
        // At 120 Hz each event carries half the step; scale 2 gives it the gain of the 60 Hz step it is
        // half of, so the travel per second matches.
        var session = makeSession(FakeTextHost(text: String(repeating: "x", count: 100), caret: 0), parameters: .standard)
        session.setEventStepScale(2)
        let start = session.point.x
        session.drag(dx: 3, dy: 0)
        var at60 = TrackpadParameters.standard
        at60.eventStepScale = 1
        TestSupport.expectEqual(session.point.x - start, 3 * at60.travelFactor(forStep: 6))
        TestSupport.expectEqual(session.parameters.eventStepScale, 2)
    }

    // MARK: Host

    private static func testOneAdjustmentPerFrame() {
        var host = FakeTextHost(text: "abcdefghij")
        var session = makeSession(host, unit: .utf16)
        // Three touch events arrive between two frames: x 100 → 79, nearest 80.
        session.drag(dx: -7, dy: 0)
        session.drag(dx: -7, dy: 0)
        session.drag(dx: -7, dy: 0)
        let context = host.context
        TestSupport.expectEqual(session.frame(before: context.before, after: context.after, timestamp: 1.21), -2)
        // Nothing more until the host has caught up.
        TestSupport.expectEqual(session.frame(before: context.before, after: context.after, timestamp: 1.22), nil)
        host.adjust(by: -2)
        TestSupport.expectEqual(host.caret, 8)
        TestSupport.expectEqual(session.frame(before: host.context.before, after: host.context.after, timestamp: 1.23), nil)
        TestSupport.expect(session.isSettled, "not settled")
    }

    private static func testPendingMovesLandAfterLift() {
        var host = FakeTextHost(text: "abcdefghij", lagFrames: 2)
        var session = makeSession(host)
        session.drag(dx: -30, dy: 0)
        session.end(at: 1.01)
        TestSupport.expect(!session.isFinished(at: 1.01), "finished before landing")
        settle(&session, &host, from: 1.01)
        TestSupport.expectEqual(host.caret, 7)
        // Dragging after the lift does nothing: lift stops dead.
        session.drag(dx: 50, dy: 0)
        TestSupport.expect(session.isSettled, "moved after the lift")
    }

    // MARK: Safety (ARCHITECTURE.md, "Trackpad safety")

    /// Runs frames until the session finishes, returning the time after.
    @discardableResult
    private static func settle(_ session: inout TrackpadSession, _ host: inout FakeTextHost, from start: TimeInterval) -> TimeInterval {
        var time = start
        for _ in 0 ..< 240 where !session.isFinished(at: time) {
            runFrame(&session, host: &host, at: time)
            time += 1.0 / 120
        }
        return time
    }

    /// A session over "Hi é|é" (decomposed accents) that has just issued a probe one cluster back.
    private static func probedSession() -> (session: TrackpadSession, before: String, offset: Int?) {
        let before = "Hi e\u{301}e\u{301}"
        var session = TrackpadSession(before: before, after: "", unit: nil, parameters: .flat,
                                      layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
        session.drag(dx: -10, dy: 0)
        let offset = session.frame(before: before, after: "", timestamp: 1)
        return (session, before, offset)
    }

    private static func testStaleContextTeachesNoUnit() {
        // Regression: with "e\u{301}e\u{301}" the context before the caret ends the same way whether or
        // not the host moved, so a changed context (here, a wider window) once taught UTF-16.
        var (session, _, offset) = probedSession()
        TestSupport.expectEqual(offset, -2)
        // It shows the caret where it was: the probe's "ignored" outcome. It teaches nothing, and the
        // next probe from there takes the smallest step.
        TestSupport.expect(session.acknowledge(before: "Earlier text. Hi e\u{301}e\u{301}", after: ""), "ignored outcome")
        TestSupport.expectEqual(session.frame(before: "Earlier text. Hi e\u{301}e\u{301}", after: "", timestamp: 1.01), -1)
        TestSupport.expectEqual(session.unit, nil)
        TestSupport.expectEqual(session.retriesLeft, TrackpadParameters.standard.automaticProbeRetries - 1)
        // A context that is no outcome of the probe is an outside change.
        TestSupport.expect(!session.acknowledge(before: "Other text", after: ""), "unrelated context accepted")
    }

    private static func testUnitNeedsDiscriminatingEvidence() {
        // A UTF-16 host moved two code units: across exactly one é.
        var utf16 = probedSession().session
        TestSupport.expect(utf16.acknowledge(before: "Hi e\u{301}", after: "e\u{301}"), "UTF-16 outcome")
        _ = utf16.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.01)
        TestSupport.expectEqual(utf16.unit, .utf16)
        TestSupport.expect(utf16.isSettled, "UTF-16: no correction needed")
        // A grapheme host moved two clusters; the next adjustment comes back one.
        var grapheme = probedSession().session
        TestSupport.expect(grapheme.acknowledge(before: "Hi ", after: "e\u{301}e\u{301}"), "grapheme outcome")
        let correction = grapheme.frame(before: "Hi ", after: "e\u{301}e\u{301}", timestamp: 1.01)
        TestSupport.expectEqual(grapheme.unit, .grapheme)
        TestSupport.expectEqual(correction, 1)
        // A window too narrow to tell (one é each side fits both outcomes): nothing is learned, and the
        // probe is rolled back to where it started.
        var narrow = probedSession().session
        TestSupport.expect(narrow.acknowledge(before: "e\u{301}", after: "e\u{301}"), "narrow outcome")
        TestSupport.expectEqual(narrow.frame(before: "e\u{301}", after: "e\u{301}", timestamp: 1.01), 2)
        TestSupport.expectEqual(narrow.unit, nil)
        TestSupport.expectEqual(narrow.committed, 5)
    }

    private static func testOutcomeInsideAClusterIsCompleted() {
        // The context places the caret between e and its accent, or between 👍 and 🏽: only a UTF-16 host
        // stops there. The caret goes on to the cluster's edge in the direction of travel.
        var accent = probedSession().session
        TestSupport.expectEqual(accent.frame(before: "Hi e\u{301}e", after: "\u{301}", timestamp: 1.31), -1)
        TestSupport.expectEqual(accent.unit, .utf16)
        TestSupport.expectEqual(accent.committed, 4)
        var thumbs = TrackpadSession(before: "a\u{1F44D}\u{1F3FD}", after: "", unit: nil, parameters: .flat,
                                     layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
        thumbs.drag(dx: -10, dy: 0)
        TestSupport.expectEqual(thumbs.frame(before: "a\u{1F44D}\u{1F3FD}", after: "", timestamp: 1), -2)
        TestSupport.expect(thumbs.acknowledge(before: "a\u{1F44D}", after: "\u{1F3FD}"), "UTF-16 outcome")
        TestSupport.expectEqual(thumbs.frame(before: "a\u{1F44D}", after: "\u{1F3FD}", timestamp: 1.01), -2)
        TestSupport.expectEqual(thumbs.unit, .utf16)
        TestSupport.expectEqual(thumbs.committed, 1)
    }

    private static func testUnplacedOutcomeIsRolledBack() {
        // Read at the timeout, a context that fits nowhere in the snapshot: back to where the probe
        // started (the same count back returns there in either unit), learning nothing.
        var session = probedSession().session
        TestSupport.expectEqual(session.frame(before: "Other", after: "text", timestamp: 1.31), 2)
        TestSupport.expectEqual(session.unit, nil)
        TestSupport.expectEqual(session.committed, 5)
        TestSupport.expectEqual(session.retriesLeft, TrackpadParameters.standard.automaticProbeRetries - 1)
    }

    private static func testProbeWaitsForTheHostsOwnContext() {
        // Until the host's `textDidChange`, a changed context may be the proxy's provisional answer, so
        // a probe is not read; once its callback matched, the same context teaches the unit.
        var session = probedSession().session
        TestSupport.expectEqual(session.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.01), nil)
        TestSupport.expectEqual(session.unit, nil)
        TestSupport.expect(session.hasOutstandingProbe, "probe read before the host confirmed it")
        TestSupport.expect(session.acknowledge(before: "Hi e\u{301}", after: "e\u{301}"), "outcome not expected")
        _ = session.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.02)
        TestSupport.expectEqual(session.unit, .utf16)
        // Without any callback the probe is read after the timeout.
        var late = probedSession().session
        _ = late.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.3)
        TestSupport.expectEqual(late.unit, .utf16)
    }

    private static func testUnanswerableProbesAreRetriedWithinBudget() {
        var (session, before, _) = probedSession()
        // The context never changes: wait, then take the probe as ignored and retry with the smallest
        // step within the budget, then stall until the finger moves.
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.1), nil)
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.31), -1)
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.62), nil)
        TestSupport.expectEqual(session.unit, nil)
        TestSupport.expect(session.isStalled, "not stalled")
        TestSupport.expect(session.isSettled, "a stalled session is not settled")
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.7), nil)
        // Half a line of new travel allows one more.
        session.drag(dx: -5, dy: 0)
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.71), nil)
        session.drag(dx: 5, dy: 0)
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.72), -1)
    }

    private static func testProbesNeverStopInsideASurrogatePair() {
        // Only one cluster to cross, ending in a skin-tone modifier (a surrogate pair): the probe steps
        // by that scalar's two units, so a UTF-16 host stops between scalars, never mid-pair.
        var host = FakeTextHost(text: "a\u{1F44D}\u{1F3FD}", unit: .utf16)
        var session = makeSession(host)
        session.drag(dx: -10, dy: 0)
        var time: TimeInterval = 1
        for _ in 0 ..< 60 {
            runFrame(&session, host: &host, at: time)
            TestSupport.expect(!host.caretSplitsSurrogatePair, "caret inside a surrogate pair at \(host.caret)")
            time += 1.0 / 120
        }
        TestSupport.expectEqual(host.caret, 1)
        TestSupport.expectEqual(session.unit, .utf16)
    }

    private static func testCancellationRollsBackAtOnce() {
        // UTF-16: the probe stopped inside the cluster; cancellation returns the way back at once.
        var host = FakeTextHost(text: "a\u{1F44D}\u{1F3FD}", unit: .utf16)
        var session = makeSession(host)
        session.drag(dx: -10, dy: 0)
        let offset = session.frame(before: host.context.before, after: host.context.after, timestamp: 1)
        TestSupport.expectEqual(offset, -2)
        host.adjust(by: offset!)
        TestSupport.expectEqual(host.caret, 3)
        TestSupport.expectEqual(session.cancel(at: 1.001), 2)
        host.adjust(by: 2)
        TestSupport.expectEqual(host.caret, 5)
        // Nothing follows a cancellation.
        TestSupport.expectEqual(session.frame(before: host.context.before, after: host.context.after, timestamp: 1.01), nil)
        TestSupport.expect(session.isFinished(at: 1.001 + TrackpadParameters.standard.syncTimeout), "not finished")
        // Before the outcome is known (a lagging host): the way back follows the probe in order.
        var lagging = FakeTextHost(text: "a\u{1F44D}\u{1F3FD}", unit: .utf16, lagFrames: 3)
        var laggingSession = makeSession(lagging)
        laggingSession.drag(dx: -10, dy: 0)
        lagging.adjust(by: laggingSession.frame(before: lagging.context.before, after: lagging.context.after, timestamp: 1)!)
        lagging.adjust(by: laggingSession.cancel(at: 1.001)!)
        for _ in 0 ..< 5 { lagging.advanceFrame() }
        TestSupport.expectEqual(lagging.caret, 5)
        // Grapheme: the probe overshot by a cluster; the same count back returns to the start.
        var graphemeHost = FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}", unit: .grapheme)
        var graphemeSession = makeSession(graphemeHost)
        graphemeSession.drag(dx: -10, dy: 0)
        graphemeHost.adjust(by: graphemeSession.frame(before: graphemeHost.context.before,
                                                      after: graphemeHost.context.after, timestamp: 1)!)
        TestSupport.expectEqual(graphemeHost.caret, 1)
        graphemeHost.adjust(by: graphemeSession.cancel(at: 1.001)!)
        TestSupport.expectEqual(graphemeHost.caret, 6)
    }

    private static func testLiftFinishesAProbedCluster() {
        var host = FakeTextHost(text: "a\u{1F44D}\u{1F3FD}", unit: .utf16)
        var session = makeSession(host)
        session.drag(dx: -10, dy: 0)
        host.adjust(by: session.frame(before: host.context.before, after: host.context.after, timestamp: 1)!)
        session.end(at: 1.001)
        settle(&session, &host, from: 1.01)
        TestSupport.expectEqual(host.caret, 1)
        TestSupport.expect(host.caretIsOnBoundary, "left inside the cluster")
    }

    private static func testHiddenClusterPastTheEdgeIsRepaired() {
        // A window that ends right before an emoji: the jump past the snapshot's end crosses one unit of
        // hidden text and a UTF-16 host stops between the halves of a surrogate pair (the context shows
        // two U+FFFD). The caret is repaired to the cluster's edge, one step at a time.
        var host = FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16, window: 2)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 30), restFrames: 60)
        TestSupport.expect(host.caretIsOnBoundary, "left inside a cluster at \(host.caret)")
        TestSupport.expectEqual(session.unit, .utf16)
    }

    private static func testCallbacksMustMatchAnExpectedOutcome() {
        var host = FakeTextHost(text: "abcdef")
        var session = makeSession(host, unit: .utf16)
        // Nothing is owed a callback yet: any callback is an outside change.
        TestSupport.expect(!session.acknowledge(before: host.context.before, after: host.context.after), "nothing owed")
        session.drag(dx: -20, dy: 0)
        let before = host.context
        TestSupport.expectEqual(session.frame(before: before.before, after: before.after, timestamp: 1), -2)
        // A selection callback fits only an outcome of an adjustment still owed one: not the old state.
        TestSupport.expect(!session.fits(before: before.before, after: before.after), "the old state fits")
        host.adjust(by: -2)
        let landed = host.context
        TestSupport.expect(session.fits(before: landed.before, after: landed.after), "own outcome, selection")
        TestSupport.expect(session.acknowledge(before: landed.before, after: landed.after), "own outcome")
        // One callback per adjustment: a second one is an outside change, and so is a selection callback
        // once nothing is owed (the fourth review: the caret where the session has it is not proof).
        TestSupport.expect(!session.acknowledge(before: landed.before, after: landed.after), "consumed twice")
        TestSupport.expect(!session.fits(before: landed.before, after: landed.after), "selection fits after consumption")
        // Anything else is an outside change.
        TestSupport.expect(!session.fits(before: "Other", after: " text"), "outside change")
        TestSupport.expect(!session.fits(before: "a", after: "bcdef"), "a different caret")
        // Two adjustments reported at once, then the same state again: both are this session's.
        var twice = FakeTextHost(text: "abcdefghij")
        var twiceSession = makeSession(twice, unit: .utf16)
        twiceSession.drag(dx: -20, dy: 0)
        twice.adjust(by: twiceSession.frame(before: twice.context.before, after: twice.context.after, timestamp: 1)!)
        _ = twiceSession.frame(before: twice.context.before, after: twice.context.after, timestamp: 1.01)
        twiceSession.drag(dx: -20, dy: 0)
        twice.adjust(by: twiceSession.frame(before: twice.context.before, after: twice.context.after, timestamp: 1.02)!)
        TestSupport.expect(twiceSession.acknowledge(before: twice.context.before, after: twice.context.after), "coalesced")
        TestSupport.expect(twiceSession.acknowledge(before: twice.context.before, after: twice.context.after), "repeated state")
        TestSupport.expect(!twiceSession.acknowledge(before: twice.context.before, after: twice.context.after), "too many")
    }

    private static func testProbeCallbacksAreValidated() {
        // During a probe, only its two possible outcomes count as its callback.
        var session = probedSession().session
        TestSupport.expect(!session.acknowledge(before: "Other", after: "text"), "unrelated context")
        TestSupport.expect(!session.acknowledge(before: "Hi e\u{301}e\u{301}x", after: ""), "edited text")
        TestSupport.expect(session.hasOutstandingProbe, "probe read without a matching callback")
        TestSupport.expect(session.acknowledge(before: "Hi ", after: "e\u{301}e\u{301}"), "grapheme outcome")
        // During a jump past the snapshot's edge: unchanged, or one character past the edge.
        var jump = TrackpadSession(before: "Alpha be", after: "ta gamma.", unit: nil, parameters: .flat,
                                   layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
        jump.drag(dx: 0, dy: 20)
        TestSupport.expectEqual(jump.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1), 10)
        TestSupport.expect(!jump.acknowledge(before: "Something else entirely.\n", after: "Short line."), "unrelated text")
        TestSupport.expect(jump.acknowledge(before: "Alpha beta gamma.\n", after: "Short line."), "crossed")
    }

    private static func testFinishesOnlyAfterItsCallbacks() {
        // A callback that arrives after the session finished would read as an outside change, so a
        // lifted session waits for its callbacks (or the timeout) before it finishes.
        var host = FakeTextHost(text: "abcdef", callbackFrames: 3)
        var session = makeSession(host, unit: .utf16)
        session.drag(dx: -20, dy: 0)
        host.adjust(by: session.frame(before: host.context.before, after: host.context.after, timestamp: 1)!)
        session.end(at: 1.001)
        TestSupport.expectEqual(session.frame(before: host.context.before, after: host.context.after, timestamp: 1.01), nil)
        TestSupport.expect(session.isSettled, "not settled")
        TestSupport.expect(!session.isFinished(at: 1.01), "finished before its callback")
        settle(&session, &host, from: 1.02)
        TestSupport.expectEqual(session.unconfirmedAdjustments, 0)
        // A host without callbacks: finished after the timeout.
        var silent = FakeTextHost(text: "abcdef", callbackFrames: nil)
        var silentSession = makeSession(silent, unit: .utf16)
        silentSession.drag(dx: -20, dy: 0)
        silent.adjust(by: silentSession.frame(before: silent.context.before, after: silent.context.after, timestamp: 1)!)
        silentSession.end(at: 1.001)
        _ = silentSession.frame(before: silent.context.before, after: silent.context.after, timestamp: 1.01)
        TestSupport.expect(!silentSession.isFinished(at: 1.2), "finished before the timeout")
        TestSupport.expect(silentSession.isFinished(at: 1.31), "not finished after the timeout")
    }

    private static func testCancelledJumpIntoAHiddenClusterIsRepaired() {
        // The fourth review's P1: "ab" shows before a hidden "👍🏽"; the jump past the snapshot's end (+3)
        // stops between the halves of a surrogate pair, and cancelling handled only unit probes.
        var host = FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16, window: 2)
        var session = makeSession(host)
        session.drag(dx: 0, dy: 20)
        let jump = session.frame(before: host.context.before, after: host.context.after, timestamp: 1)
        TestSupport.expectEqual(jump, 3)
        host.adjust(by: jump!)
        TestSupport.expect(host.caretSplitsSurrogatePair, "the jump did not stop inside the pair")
        TestSupport.expectEqual(session.cancel(at: 1.001), nil)
        var time = 1.01
        for _ in 0 ..< 120 where !session.isFinished(at: time) {
            runFrame(&session, host: &host, at: time)
            time += 1.0 / 120
        }
        TestSupport.expect(session.isFinished(at: time), "not finished")
        TestSupport.expect(host.caretIsOnBoundary, "left inside a cluster at \(host.caret)")
        TestSupport.expectEqual(host.caret, 2)
        // A jump that crossed a line break cleanly, or that the host ignored, is left where it is.
        for (text, caret, landing) in [("first\nsecond", 2, 6), ("only line", 4, 4)] {
            var clean = FakeTextHost(text: text, caret: caret, model: .lineBreakOnly)
            var cleanSession = makeSession(clean)
            cleanSession.drag(dx: 0, dy: 20)
            clean.adjust(by: cleanSession.frame(before: clean.context.before, after: clean.context.after, timestamp: 1)!)
            _ = cleanSession.cancel(at: 1.001)
            var t = 1.01
            for _ in 0 ..< 120 where !cleanSession.isFinished(at: t) {
                runFrame(&cleanSession, host: &clean, at: t)
                t += 1.0 / 120
            }
            TestSupport.expectEqual(clean.caret, landing)
            TestSupport.expectEqual(clean.adjustmentCount, 1)
        }
    }

    private static func testEmptiedFieldIsNotACrossing() {
        // The fourth review's P1: while a jump past the snapshot's edge was pending, the host cleared the
        // field and reported empty contexts, which matched the crossing with nothing compared.
        func makeJump() -> TrackpadSession {
            var jump = TrackpadSession(before: "Alpha be", after: "ta gamma.", unit: nil, parameters: .flat,
                                       layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
            jump.drag(dx: 0, dy: 20)
            TestSupport.expectEqual(jump.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1), 10)
            return jump
        }
        var emptied = makeJump()
        TestSupport.expect(!emptied.acknowledge(before: nil, after: nil), "an emptied field taken for the crossing")
        TestSupport.expect(!emptied.acknowledge(before: "", after: ""), "an emptied field taken for the crossing")
        TestSupport.expect(!emptied.fits(before: nil, after: nil), "an emptied field fits")
        // Affirmative evidence: the text before the edge, then the hidden line break.
        var blank = makeJump()
        TestSupport.expect(blank.acknowledge(before: "Alpha beta gamma.\n", after: nil), "a crossing onto a blank line")
        var next = makeJump()
        TestSupport.expect(next.acknowledge(before: "\n", after: "Short line."), "a crossing with text after")
    }

    private static func testSingleEmojiFieldIsReachedInEitherUnit() {
        // The fourth review's P2: in a grapheme field holding only "👍🏽", a left probe of two units asks
        // for two clusters, the host ignores it, and the probe was retried that way forever.
        for unit in [CursorOffsetUnit.grapheme, .utf16] {
            var host = FakeTextHost(text: "\u{1F44D}\u{1F3FD}", unit: unit)
            var session = makeSession(host)
            runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 20))
            TestSupport.expectEqual(host.caret, 0)
            TestSupport.expect(host.caretIsOnBoundary, "inside the emoji in \(unit)")
            TestSupport.expectEqual(session.unit, unit)
        }
        // As a WKWebView reports it (measured): each adjustment twice, the ignored probe included.
        var webKit = FakeTextHost(text: "\u{1F44D}\u{1F3FD}", unit: .grapheme, provisionalContext: true)
        webKit.reportsAsIssuedFirst = true
        var session = makeSession(webKit)
        runGesture(&session, host: &webKit, samples: slowDrag(dx: -0.5, samples: 20))
        TestSupport.expectEqual(webKit.caret, 0)
        TestSupport.expectEqual(session.unit, .grapheme)
    }

    private static func testWebKitReportsEachAdjustmentTwice() {
        // Measured in a WKWebView (round 6): after adjustTextPosition the proxy answers provisionally,
        // then textDidChange shows the context the adjustment was issued in, then the one it landed in.
        // The first report was an unexplained callback, which ended every gesture after one step.
        let text = "Invented ab\u{1F44D}\u{1F3FD}cd words and more text"
        let caret = 23
        var plain = FakeTextHost(text: text, caret: caret, unit: .grapheme, model: .uikit)
        var plainSession = makeSession(plain)
        runGesture(&plainSession, host: &plain, samples: slowDrag(dx: -1, samples: 140))
        var webKit = FakeTextHost(text: text, caret: caret, unit: .grapheme, model: .uikit, provisionalContext: true)
        webKit.reportsAsIssuedFirst = true
        var session = makeSession(webKit)
        runGesture(&session, host: &webKit, samples: slowDrag(dx: -1, samples: 140))
        TestSupport.expect(plain.caret < caret - 8, "the gesture did not get far")
        TestSupport.expectEqual(webKit.caret, plain.caret)
        TestSupport.expectEqual(session.unit, .grapheme)
        // The report as issued confirms nothing and is accepted once per adjustment.
        var direct = TrackpadSession(before: "Alpha beta", after: " gamma.", unit: .utf16, parameters: .flat,
                                     layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000)
        direct.drag(dx: -30, dy: 0)
        TestSupport.expectEqual(direct.frame(before: "Alpha beta", after: " gamma.", timestamp: 1), -3)
        TestSupport.expect(direct.acknowledge(before: "Alpha beta", after: " gamma."), "the report as issued")
        TestSupport.expectEqual(direct.frame(before: "Alpha beta", after: " gamma.", timestamp: 1.01), nil)
        TestSupport.expectEqual(direct.unconfirmedAdjustments, 1)
        TestSupport.expect(!direct.acknowledge(before: "Alpha beta", after: " gamma."), "reported as issued twice")
        TestSupport.expect(direct.acknowledge(before: "Alpha b", after: "eta gamma."), "the report as landed")
        TestSupport.expectEqual(direct.unconfirmedAdjustments, 0)
        TestSupport.expectEqual(direct.reportsTwice, true)
        // In a field known to report once (UIKit), the same report is no adjustment of this session's.
        var single = TrackpadSession(before: "Alpha beta", after: " gamma.", unit: .utf16, reportsTwice: false,
                                     parameters: .flat, layout: FixedWidthLayout(columns: 1_000), linePitch: 20,
                                     layoutWidth: 10_000)
        single.drag(dx: -30, dy: 0)
        TestSupport.expectEqual(single.frame(before: "Alpha beta", after: " gamma.", timestamp: 1), -3)
        TestSupport.expect(!single.acknowledge(before: "Alpha beta", after: " gamma."), "an unmoved report taken as issued")
    }
}
