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
            ("ignoredProbesAreBounded", testIgnoredProbesAreBounded),
            ("learnsUTF16UnitsWithoutSplittingClusters", testLearnsUTF16UnitsWithoutSplittingClusters),
            ("learnsGraphemeUnits", testLearnsGraphemeUnits),
            ("knownUnitSkipsTheProbe", testKnownUnitSkipsTheProbe),
            ("combiningMarksStayWhole", testCombiningMarksStayWhole),
            ("mixedTextNeverEndsInsideACluster", testMixedTextNeverEndsInsideACluster),
            ("laggingHostConverges", testLaggingHostConverges),
            ("fastDragsGoFarther", testFastDragsGoFarther),
            ("sensitivityScalesTravel", testSensitivityScalesTravel),
            ("oneAdjustmentPerFrame", testOneAdjustmentPerFrame),
            ("pendingMovesLandAfterLift", testPendingMovesLandAfterLift),
            ("staleContextTeachesNoUnit", testStaleContextTeachesNoUnit),
            ("unitNeedsDiscriminatingEvidence", testUnitNeedsDiscriminatingEvidence),
            ("probeWaitsForTheHostsOwnContext", testProbeWaitsForTheHostsOwnContext),
            ("unanswerableProbeTeachesNothing", testUnanswerableProbeTeachesNothing),
            ("probesNeverStopInsideASurrogatePair", testProbesNeverStopInsideASurrogatePair),
            ("cancellationRollsBackAProbe", testCancellationRollsBackAProbe),
            ("liftFinishesAProbedCluster", testLiftFinishesAProbedCluster),
            ("explainsOnlyItsOwnAdjustments", testExplainsOnlyItsOwnAdjustments),
        ]
    }

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
        // Far left: x is held at 1.5, and the caret answers the first reversal.
        time = runGesture(&session, host: &host, samples: slowDrag(dx: -2, samples: 300), start: time, end: false)
        TestSupport.expectEqual(session.point.x, 1.5)
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

    private static func testHiddenParagraphBreakIsReachedVertically() {
        // UIKit's context stops at the line break, so the next paragraph is reached by one jump past it,
        // straight from the caret's column to the same column below.
        let text = "first para line\nsecond para here"
        var host = FakeTextHost(text: text, caret: 5, windowStopsAtLineBreaks: true)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 21)
        TestSupport.expectEqual(host.adjustmentCount, 2)
        var back = FakeTextHost(text: text, caret: 21, windowStopsAtLineBreaks: true)
        var backSession = makeSession(back)
        runGesture(&backSession, host: &back, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(back.caret, 5)
    }

    private static func testUpFromAParagraphStart() {
        // From "se|cond", one line up: the column in "first line".
        var host = FakeTextHost(text: "first line\nsecond", caret: 13, windowStopsAtLineBreaks: true)
        var session = makeSession(host)
        TestSupport.expectEqual(host.context.before, "se")
        runGesture(&session, host: &host, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 2)
    }

    private static func testUpFromALineStartKeepsTheColumn() {
        // Right after a line break UIKit shows just "\n" before the caret: the line it ends is hidden, so
        // up from there is a jump to the line above, which then takes the point's column. Regression:
        // the "\n" once counted as a visible empty line and the caret went to the end of the line above.
        var host = FakeTextHost(text: "first line\nsecond", caret: 11, windowStopsAtLineBreaks: true)
        TestSupport.expectEqual(host.context.before, "\n")
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 0)
        var moved = FakeTextHost(text: "first line\nsecond", caret: 11, windowStopsAtLineBreaks: true)
        var movedSession = makeSession(moved)
        runGesture(&movedSession, host: &moved, samples: slowDrag(dx: 0.5, samples: 60) + slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(moved.caret, 3)
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
        var host = FakeTextHost(text: text, caret: 8, windowStopsAtLineBreaks: true, provisionalContext: true)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 26)   // "Short li|ne."
        TestSupport.expectEqual(host.adjustmentCount, 2)
        TestSupport.expect(session.isSettled, "not settled")
        var back = FakeTextHost(text: text, caret: 26, windowStopsAtLineBreaks: true, provisionalContext: true)
        var backSession = makeSession(back)
        runGesture(&backSession, host: &back, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(back.caret, 8)
        var down = FakeTextHost(text: text, caret: 8, windowStopsAtLineBreaks: true, provisionalContext: true)
        var downSession = makeSession(down)
        runGesture(&downSession, host: &down, samples: slowDrag(dy: 0.5, samples: 80))
        TestSupport.expectEqual(down.caret, 38)   // "Last one|." keeps column 8
    }

    private static func testCaretAtTheWindowEdgeIsNotACrossing() {
        // Even once acknowledged, a context that shows the caret exactly at the snapshot's edge with
        // nothing beyond is not a crossing (the proxy's provisional answer, or a host that clamps).
        var session = TrackpadSession(before: "Alpha be", after: "ta gamma.", unit: nil, parameters: .flat,
                                      layout: FixedWidthLayout(columns: 1_000), lineHeight: 20, layoutWidth: 10_000)
        session.drag(dx: 0, dy: 20)
        TestSupport.expectEqual(session.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1), 10)
        session.hostDidChange()
        TestSupport.expectEqual(session.frame(before: "Alpha beta gamma.", after: nil, timestamp: 1.01), nil)
        // The host's own context after the jump: the start of the next paragraph, then the column.
        TestSupport.expectEqual(session.frame(before: "\n", after: "Short line.", timestamp: 1.02), 8)
        // Still the edge at the timeout: the jump was ignored and the caret is where it was.
        var ignored = TrackpadSession(before: "Alpha be", after: "ta gamma.", unit: nil, parameters: .flat,
                                      layout: FixedWidthLayout(columns: 1_000), lineHeight: 20, layoutWidth: 10_000)
        ignored.drag(dx: 0, dy: 20)
        _ = ignored.frame(before: "Alpha be", after: "ta gamma.", timestamp: 1)
        ignored.hostDidChange()
        TestSupport.expectEqual(ignored.frame(before: "Alpha beta gamma.", after: nil, timestamp: 1.31), nil)
        TestSupport.expectEqual(ignored.committed, 8)
        TestSupport.expectEqual(ignored.ambiguousProbes[.end], 1)
    }

    private static func testCrossingWithoutCallbacksWaitsForTheTimeout() {
        // A host that never sends `textDidChange` for an adjustment: each crossing is read after the
        // timeout instead.
        let text = "first para line\nsecond para here"
        var host = FakeTextHost(text: text, caret: 5, windowStopsAtLineBreaks: true, callbackFrames: nil)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 21)
        TestSupport.expectEqual(host.adjustmentCount, 2)
    }

    private static func testLastLineKeepsItsColumnDespiteTheProvisionalEdge() {
        // Down on the document's last line the jump is ignored, but the proxy first shows the caret at
        // the line's end. The caret keeps its column and later moves are relative to where it is.
        var host = FakeTextHost(text: "Alpha.\nLast line here.", caret: 14, windowStopsAtLineBreaks: true,
                                provisionalContext: true)
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
        // Regression: between "\n" and "\n" UIKit reports the same context ("\n" before, nothing after)
        // at every blank line, which once read as the end of the document.
        var host = FakeTextHost(text: "a\n\n\nb", caret: 1, windowStopsAtLineBreaks: true)
        var session = makeSession(host)
        // Three lines down, slowly enough for each ambiguous probe to time out.
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.1, samples: 600))
        TestSupport.expectEqual(host.caret, 5)
    }

    private static func testIgnoredProbesAreBounded() {
        var host = FakeTextHost(text: "abc", caret: 3)
        var session = makeSession(host)
        let time = runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 1_200), end: false)
        TestSupport.expectEqual(host.caret, 3)
        TestSupport.expect(session.isSoftEdge(.end), "not held after repeated ignored probes")
        TestSupport.expectEqual(host.adjustmentCount, TrackpadParameters.standard.maximumAmbiguousProbes)
        // Held like Apple's last line: 8 points below its center, and a reversal responds at once.
        TestSupport.expectEqual(session.point.y, 10 + TrackpadParameters.standard.bottomOvershoot)
        runGesture(&session, host: &host, samples: [(0, -1)], start: time, end: false)
        TestSupport.expectEqual(session.point.y, 10 + TrackpadParameters.standard.bottomOvershoot - 1)
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
                                      layout: FixedWidthLayout(columns: 1_000), lineHeight: 20, layoutWidth: 10_000)
        session.drag(dx: -10, dy: 0)
        let offset = session.frame(before: before, after: "", timestamp: 1)
        return (session, before, offset)
    }

    private static func testStaleContextTeachesNoUnit() {
        // Regression: with "e\u{301}e\u{301}" the context before the caret ends the same way whether or
        // not the host moved, so a changed context (here, a wider window) once taught UTF-16.
        var (session, _, offset) = probedSession()
        TestSupport.expectEqual(offset, -2)
        session.hostDidChange()
        _ = session.frame(before: "Earlier text. Hi e\u{301}e\u{301}", after: "", timestamp: 1.01)
        TestSupport.expectEqual(session.unit, nil)
    }

    private static func testUnitNeedsDiscriminatingEvidence() {
        // A UTF-16 host moved two code units: across exactly one é.
        var utf16 = probedSession().session
        utf16.hostDidChange()
        _ = utf16.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.01)
        TestSupport.expectEqual(utf16.unit, .utf16)
        TestSupport.expect(utf16.isSettled, "UTF-16: no correction needed")
        // A grapheme host moved two clusters; the next adjustment comes back one.
        var grapheme = probedSession().session
        grapheme.hostDidChange()
        let correction = grapheme.frame(before: "Hi ", after: "e\u{301}e\u{301}", timestamp: 1.01)
        TestSupport.expectEqual(grapheme.unit, .grapheme)
        TestSupport.expectEqual(correction, 1)
        // Contexts that fit neither, or fit a move by the wrong amount, teach nothing.
        for (before, after) in [("Hi e\u{301}e", "\u{301}"), ("Hi", "e\u{301}e\u{301}"), ("Other", "text")] {
            var session = probedSession().session
            session.hostDidChange()
            _ = session.frame(before: before, after: after, timestamp: 1.01)
            TestSupport.expectEqual(session.unit, nil)
        }
    }

    private static func testProbeWaitsForTheHostsOwnContext() {
        // Until the host's `textDidChange`, a changed context may be the proxy's provisional answer, so
        // a probe is not read; once acknowledged, the same context teaches the unit.
        var session = probedSession().session
        TestSupport.expectEqual(session.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.01), nil)
        TestSupport.expectEqual(session.unit, nil)
        TestSupport.expect(session.hasOutstandingProbe, "probe read before the host acknowledged it")
        session.hostDidChange()
        _ = session.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.02)
        TestSupport.expectEqual(session.unit, .utf16)
        // Without any callback the probe is read after the timeout.
        var late = probedSession().session
        _ = late.frame(before: "Hi e\u{301}", after: "e\u{301}", timestamp: 1.3)
        TestSupport.expectEqual(late.unit, .utf16)
    }

    private static func testUnanswerableProbeTeachesNothing() {
        var (session, before, _) = probedSession()
        // The context never changes: wait, then give up without learning or re-probing at once.
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.1), nil)
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.4), nil)
        TestSupport.expectEqual(session.unit, nil)
        TestSupport.expectEqual(session.frame(before: before, after: "", timestamp: 1.41), nil)
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

    private static func testCancellationRollsBackAProbe() {
        // UTF-16: the probe stopped inside the cluster; cancellation moves back to where it started.
        var host = FakeTextHost(text: "a\u{1F44D}\u{1F3FD}", unit: .utf16)
        var session = makeSession(host)
        session.drag(dx: -10, dy: 0)
        let offset = session.frame(before: host.context.before, after: host.context.after, timestamp: 1)
        TestSupport.expectEqual(offset, -2)
        host.adjust(by: offset!)
        TestSupport.expectEqual(host.caret, 3)
        session.cancel(at: 1.001)
        settle(&session, &host, from: 1.01)
        TestSupport.expectEqual(host.caret, 5)
        TestSupport.expect(host.caretIsOnBoundary, "left inside the cluster")
        // Grapheme: the probe overshot by a cluster; cancellation also returns to the start.
        var graphemeHost = FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}", unit: .grapheme)
        var graphemeSession = makeSession(graphemeHost)
        graphemeSession.drag(dx: -10, dy: 0)
        let probe = graphemeSession.frame(before: graphemeHost.context.before, after: graphemeHost.context.after,
                                          timestamp: 1)
        graphemeHost.adjust(by: probe!)
        TestSupport.expectEqual(graphemeHost.caret, 1)
        graphemeSession.cancel(at: 1.001)
        settle(&graphemeSession, &graphemeHost, from: 1.01)
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

    private static func testExplainsOnlyItsOwnAdjustments() {
        var host = FakeTextHost(text: "abcdef")
        var session = makeSession(host, unit: .utf16)
        session.drag(dx: -20, dy: 0)
        let before = host.context
        let offset = session.frame(before: before.before, after: before.after, timestamp: 1)
        TestSupport.expectEqual(offset, -2)
        // Before and after the adjustment lands, the callbacks it causes fit the session.
        TestSupport.expect(session.explains(before: before.before, after: before.after), "before landing")
        host.adjust(by: offset!)
        TestSupport.expect(session.explains(before: host.context.before, after: host.context.after), "after landing")
        // Anything else is an outside change.
        TestSupport.expect(!session.explains(before: "Other", after: " text"), "outside change")
        TestSupport.expect(!session.explains(before: "a", after: "bcdef"), "a different caret")
    }
}
