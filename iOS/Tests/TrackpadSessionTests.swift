import Foundation

enum TrackpadSessionTests {
    static var tests: [TestCase] {
        [
            ("slowDragMovesByCharacters", testSlowDragMovesByCharacters),
            ("wideCharactersTakeMoreTravel", testWideCharactersTakeMoreTravel),
            ("learnsUTF16UnitsWithoutSplittingClusters", testLearnsUTF16UnitsWithoutSplittingClusters),
            ("learnsGraphemeUnits", testLearnsGraphemeUnits),
            ("knownUnitSkipsTheProbe", testKnownUnitSkipsTheProbe),
            ("combiningMarksStayWhole", testCombiningMarksStayWhole),
            ("mixedTextNeverEndsInsideACluster", testMixedTextNeverEndsInsideACluster),
            ("windowIsReSnapshotted", testWindowIsReSnapshotted),
            ("hiddenLineBreakIsCrossed", testHiddenLineBreakIsCrossed),
            ("documentEndIsConfirmedAndReversesAtOnce", testDocumentEndIsConfirmedAndReversesAtOnce),
            ("verticalKeepsTheGoalColumn", testVerticalKeepsTheGoalColumn),
            ("verticalCrossesAHiddenParagraphBreak", testVerticalCrossesAHiddenParagraphBreak),
            ("upOnTheFirstLineStopsAtTheStart", testUpOnTheFirstLineStopsAtTheStart),
            ("leftAcrossAParagraphStart", testLeftAcrossAParagraphStart),
            ("laggingHostConverges", testLaggingHostConverges),
            ("fastDragsGoFarther", testFastDragsGoFarther),
            ("sensitivityScalesTravel", testSensitivityScalesTravel),
            ("oneAdjustmentPerFrame", testOneAdjustmentPerFrame),
            ("pendingMovesLandAfterLift", testPendingMovesLandAfterLift),
        ]
    }

    private static func testSlowDragMovesByCharacters() {
        var host = FakeTextHost(text: "abcdefghij")
        var session = makeSession(host)
        // 30 points at gain 1 over 10-point characters crosses at 6, 16 and 26.
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 60))
        TestSupport.expectEqual(host.caret, 7)
        TestSupport.expect(session.isSettled, "not settled")
        TestSupport.expectEqual(session.unit, nil)
    }

    private static func testWideCharactersTakeMoreTravel() {
        var wide = FakeTextHost(text: String(repeating: "m", count: 10))
        var wideSession = makeSession(wide)
        runGesture(&wideSession, host: &wide, samples: slowDrag(dx: -0.5, samples: 80))
        var narrow = FakeTextHost(text: String(repeating: "i", count: 10))
        var narrowSession = makeSession(narrow)
        runGesture(&narrowSession, host: &narrow, samples: slowDrag(dx: -0.5, samples: 80))
        // 40 points: two 16-point "m"s, eight 5-point "i"s.
        TestSupport.expectEqual(wide.caret, 8)
        TestSupport.expectEqual(narrow.caret, 2)
    }

    private static let mixed = "ab\u{1F44D}\u{1F3FD}cd"

    private static func testLearnsUTF16UnitsWithoutSplittingClusters() {
        var host = FakeTextHost(text: mixed, unit: .utf16)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 60))
        // Crossed d, c and the 4-unit emoji: the caret is after "b", not inside the emoji.
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

    private static func testWindowIsReSnapshotted() {
        let text = String(repeating: "abcdefghij", count: 6)
        var host = FakeTextHost(text: text, caret: 0, window: 8)
        var session = makeSession(host)
        // 300 points: 31 characters (each 95-point block of ten has a narrow "i"), far beyond the
        // 8-character window.
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 600))
        TestSupport.expectEqual(host.caret, 31)
    }

    private static func testHiddenLineBreakIsCrossed() {
        var host = FakeTextHost(text: "first line\nsecond", caret: 5, windowStopsAtLineBreaks: true)
        var session = makeSession(host)
        TestSupport.expectEqual(host.context.after, " line")
        // 98 points: " line" (45, with a narrow "i"), the line break (9), then 4 characters of "second".
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 196))
        TestSupport.expectEqual(host.caret, 15)
    }

    private static func testDocumentEndIsConfirmedAndReversesAtOnce() {
        var host = FakeTextHost(text: "abc", caret: 1)
        var session = makeSession(host)
        let time = runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 200), end: false)
        TestSupport.expectEqual(host.caret, 3)
        TestSupport.expect(session.confirmedEdges.contains(.end), "end not confirmed")
        // The 80 points pushed past the end were discarded: 7 points back crosses "c" at once.
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 14), start: time)
        TestSupport.expectEqual(host.caret, 2)
    }

    private static let lines = "abcdefghij" + "klmnopqrst" + "uv\n" + "wxyzabcdefgh"

    private static func testVerticalKeepsTheGoalColumn() {
        // Columns of 10: "abcdefghij|klmnopqrst|uv\n|wxyzabcdef|gh"; the caret is after "klm".
        var oneLine = FakeTextHost(text: lines, caret: 13)
        var session = makeSession(oneLine, columns: 10)
        runGesture(&session, host: &oneLine, samples: slowDrag(dy: 0.5, samples: 40))
        // The short line "uv": as close to column 3 as it goes, before its line break.
        TestSupport.expectEqual(oneLine.caret, 22)
        var twoLines = FakeTextHost(text: lines, caret: 13)
        var twoSession = makeSession(twoLines, columns: 10)
        runGesture(&twoSession, host: &twoLines, samples: slowDrag(dy: 0.5, samples: 80))
        // Back at column 3 on the next long line.
        TestSupport.expectEqual(twoLines.caret, 26)
        var up = FakeTextHost(text: lines, caret: 26)
        var upSession = makeSession(up, columns: 10)
        runGesture(&upSession, host: &up, samples: slowDrag(dy: -0.5, samples: 80))
        TestSupport.expectEqual(up.caret, 13)
    }

    private static func testVerticalCrossesAHiddenParagraphBreak() {
        var host = FakeTextHost(text: "first para line\nsecond para here", caret: 5, windowStopsAtLineBreaks: true)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: 0.5, samples: 40))
        // Column 5 of the next paragraph: "secon|d".
        TestSupport.expectEqual(host.caret, 21)
        var back = FakeTextHost(text: "first para line\nsecond para here", caret: 21, windowStopsAtLineBreaks: true)
        var backSession = makeSession(back)
        runGesture(&backSession, host: &back, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(back.caret, 5)
    }

    private static func testUpOnTheFirstLineStopsAtTheStart() {
        var host = FakeTextHost(text: "abcdef", caret: 3)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dy: -0.5, samples: 40))
        TestSupport.expectEqual(host.caret, 0)
        TestSupport.expect(session.confirmedEdges.contains(.start), "start not confirmed")
    }

    private static func testLeftAcrossAParagraphStart() {
        // From "se|cond", left past the paragraph start: UIKit then shows only "\n" before the caret.
        var host = FakeTextHost(text: "first line\nsecond", caret: 13, windowStopsAtLineBreaks: true)
        var session = makeSession(host)
        TestSupport.expectEqual(host.context.before, "se")
        // 40 points: "e" and "s" (crossed at 6 and 16), the line break (a 9-point advance, crossed at
        // 25.4), then the "e" of "line" (at 35).
        runGesture(&session, host: &host, samples: slowDrag(dx: -0.5, samples: 80))
        TestSupport.expectEqual(host.caret, 9)
    }

    private static func testLaggingHostConverges() {
        var host = FakeTextHost(text: "abcdefghij\u{1F44D}\u{1F3FD}klmnop", caret: 0, lagFrames: 3)
        var session = makeSession(host)
        runGesture(&session, host: &host, samples: slowDrag(dx: 0.5, samples: 260))
        // 130 points: 13 characters, the emoji among them.
        TestSupport.expectEqual(host.caret, 16)
        TestSupport.expect(host.caretIsOnBoundary, "split a cluster")
    }

    private static func travel(samples: [(dx: Double, dy: Double)], parameters: TrackpadParameters = .standard) -> Int {
        var host = FakeTextHost(text: String(repeating: "x", count: 400), caret: 0)
        var session = makeSession(host, parameters: parameters)
        runGesture(&session, host: &host, samples: samples)
        return host.caret
    }

    private static func testFastDragsGoFarther() {
        // The same 120 points of finger travel, slowly and in a fast flick.
        let slow = travel(samples: slowDrag(dx: 0.5, samples: 240))
        let fast = travel(samples: slowDrag(dx: 12, samples: 10))
        TestSupport.expectEqual(slow, 12)
        TestSupport.expect(Double(fast) > Double(slow) * 1.8, "fast \(fast) vs slow \(slow)")
        TestSupport.expect(Double(fast) <= Double(slow) * TrackpadParameters.standard.maximumGain + 1, "fast beyond the cap")
    }

    private static func testSensitivityScalesTravel() {
        let doubled = TrackpadParameters.standard.tuned(sensitivity: 2, acceleration: 1)
        TestSupport.expectEqual(travel(samples: slowDrag(dx: 0.25, samples: 240), parameters: doubled), 12)
        let flat = TrackpadParameters.standard.tuned(sensitivity: 1, acceleration: 0.25)
        let fastFlat = travel(samples: slowDrag(dx: 12, samples: 10), parameters: flat)
        let fastDefault = travel(samples: slowDrag(dx: 12, samples: 10))
        TestSupport.expect(fastFlat < fastDefault, "acceleration multiplier ignored")
    }

    private static func testOneAdjustmentPerFrame() {
        var host = FakeTextHost(text: "abcdefghij")
        var session = makeSession(host, unit: .utf16)
        // Three touch samples arrive between two frames.
        session.drag(dx: -7, dy: 0, timestamp: 1)
        session.drag(dx: -7, dy: 0, timestamp: 1.1)
        session.drag(dx: -7, dy: 0, timestamp: 1.2)
        let context = host.context
        // j, the narrow i, then h: three characters in one adjustment.
        TestSupport.expectEqual(session.frame(before: context.before, after: context.after, timestamp: 1.21), -3)
        // Nothing more until the host has caught up.
        TestSupport.expectEqual(session.frame(before: context.before, after: context.after, timestamp: 1.22), nil)
        host.adjust(by: -3)
        TestSupport.expectEqual(host.caret, 7)
        TestSupport.expectEqual(session.frame(before: host.context.before, after: host.context.after, timestamp: 1.23), nil)
        TestSupport.expect(session.isSettled, "not settled")
    }

    private static func testPendingMovesLandAfterLift() {
        var host = FakeTextHost(text: "abcdefghij", lagFrames: 2)
        var session = makeSession(host)
        session.drag(dx: -30, dy: 0, timestamp: 1)
        session.end(at: 1.01)
        TestSupport.expect(!session.isFinished(at: 1.01), "finished before landing")
        var time = 1.01
        while !session.isFinished(at: time) {
            host.advanceFrame()
            if let offset = session.frame(before: host.context.before, after: host.context.after, timestamp: time) {
                host.adjust(by: offset)
            }
            time += 1.0 / 120
        }
        TestSupport.expectEqual(host.caret, 7)
        TestSupport.expect(time - 1.01 < TrackpadParameters.standard.settleTimeout, "took the whole timeout")
        // Dragging after the lift does nothing.
        session.drag(dx: 50, dy: 0, timestamp: 2)
        TestSupport.expect(session.isSettled, "moved after the lift")
    }
}
