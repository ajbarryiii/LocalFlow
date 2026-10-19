import Foundation

/// ARCHITECTURE.md, "Dropped taps: reach, skids and counters": content-free counts by event and region.
enum TypingCountersTests {
    static var tests: [TestCase] {
        [
            ("namesAreTheContract", testNamesAreTheContract),
            ("countsByEventAndRegion", testCountsByEventAndRegion),
            ("storedFormRoundTripsAndRejectsJunk", testStoredFormRoundTripsAndRejectsJunk),
            ("regionsAreRowsAndEdges", testRegionsAreRowsAndEdges),
        ]
    }

    private static func testNamesAreTheContract() {
        TestSupport.expectEqual(TypingCounters.Event.allCases.map(\.rawValue),
                                ["touchDown", "aboveKeys", "late16", "late50", "late100", "cancelled", "ignored", "swipe",
                                 "skid", "swipeEmpty", "softTap", "softLetter", "softSpace", "wordChecked", "wordCorrected",
                                 "wordReverted"])
        // Word events (ARCHITECTURE.md, "Word autocorrect") have no position: one count each, in the bottom row.
        TestSupport.expectEqual(TypingCounters.wordRegions, [.row4])
        TestSupport.expectEqual(TypingCounters.Region.allCases.map(\.rawValue), ["row1", "row2", "row3", "row4", "left", "right"])
    }

    private static func testCountsByEventAndRegion() {
        var counters = TypingCounters()
        TestSupport.expect(counters.isEmpty, "new counters are not empty")
        counters.add(.touchDown, regions: [.row1, .left])
        counters.add(.touchDown, regions: [.row1])
        counters.add(.touchDown, regions: [.row4, .right])
        counters.add(.skid, regions: [.row2])
        TestSupport.expect(!counters.isEmpty, "counters with counts are empty")
        TestSupport.expectEqual(counters[.touchDown, .row1], 2)
        TestSupport.expectEqual(counters[.touchDown, .left], 1)
        TestSupport.expectEqual(counters[.touchDown, .right], 1)
        TestSupport.expectEqual(counters[.touchDown, .row2], 0)
        // The total is the sum of the rows; the edges are counted within them.
        TestSupport.expectEqual(counters.total(.touchDown), 3)
        TestSupport.expectEqual(counters.total(.skid), 1)
        TestSupport.expectEqual(counters.total(.cancelled), 0)
        // An event without a region (no keys laid out) is not counted.
        counters.add(.cancelled, regions: [])
        TestSupport.expectEqual(counters.total(.cancelled), 0)
        // Merging adds.
        var more = TypingCounters()
        more.add(.touchDown, regions: [.row1, .left])
        more.add(.softSpace, regions: [.row3])
        counters.merge(more)
        TestSupport.expectEqual(counters[.touchDown, .row1], 3)
        TestSupport.expectEqual(counters[.touchDown, .left], 2)
        TestSupport.expectEqual(counters.total(.softSpace), 1)
        // Stored as "event.region" to a count, zeros left out.
        TestSupport.expectEqual(counters.stored, ["touchDown.row1": 3, "touchDown.left": 2, "touchDown.row4": 1,
                                                  "touchDown.right": 1, "skid.row2": 1, "softSpace.row3": 1])
        // Counts stop at the maximum instead of overflowing.
        var full = TypingCounters(stored: ["swipe.row1": TypingCounters.maximumCount])
        full.add(.swipe, regions: [.row1])
        let copy = full
        full.merge(copy)
        TestSupport.expectEqual(full[.swipe, .row1], TypingCounters.maximumCount)
    }

    private static func testStoredFormRoundTripsAndRejectsJunk() {
        var counters = TypingCounters()
        counters.add(.late50, regions: [.row2, .right])
        counters.add(.softLetter, regions: [.row1])
        TestSupport.expectEqual(TypingCounters(stored: counters.stored), counters)
        TestSupport.expectEqual(TypingCounters(stored: nil), TypingCounters())
        // Only "event.region" keys with known names and whole counts from 0 to the maximum are read.
        let junk: [String: Any] = [
            "touchDown.row1": 4, "late16.left": 7, "touchDown.row9": 2, "typed.row1": 1, "touchDown": 3, "touchDown.row1.x": 1,
            "cancelled.row2": -1, "ignored.row3": "5", "swipe.row1": 2.5, "skid.row4": true,
            "softTap.row2": TypingCounters.maximumCount + 1, "softSpace.row1": 0,
        ]
        TestSupport.expectEqual(TypingCounters(stored: junk).stored, ["touchDown.row1": 4, "late16.left": 7])
    }

    private static func testRegionsAreRowsAndEdges() {
        let keys = KeyboardLayout.keys(for: .letters, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                                       showsGlobe: true)
        func regions(_ action: KeyAction, dx: Double = 0, dy: Double = 0) -> [TypingCounters.Region] {
            let key = keys.first { $0.action == action }!
            return TypingCounters.regions(x: key.frame.midX + dx, y: key.frame.midY + dy, keys: keys)
        }
        TestSupport.expectEqual(regions(.character("q")), [.row1, .left])
        TestSupport.expectEqual(regions(.character("e")), [.row1])
        TestSupport.expectEqual(regions(.character("t")), [.row1])
        TestSupport.expectEqual(regions(.character("p")), [.row1, .right])
        TestSupport.expectEqual(regions(.character("a")), [.row2, .left])
        TestSupport.expectEqual(regions(.character("g")), [.row2])
        TestSupport.expectEqual(regions(.character("l")), [.row2, .right])
        TestSupport.expectEqual(regions(.shift), [.row3, .left])
        TestSupport.expectEqual(regions(.character("n")), [.row3])
        TestSupport.expectEqual(regions(.delete), [.row3, .right])
        TestSupport.expectEqual(regions(.layer(.numbers)), [.row4, .left])
        TestSupport.expectEqual(regions(.nextKeyboard), [.row4])
        TestSupport.expectEqual(regions(.space), [.row4])
        TestSupport.expectEqual(regions(.returnKey), [.row4, .right])
        // By the key nearest the point: above the keys (the reach) is the top row, and the side margin is the
        // edge key.
        let e = keys.first { $0.action == .character("e") }!, q = keys.first { $0.action == .character("q") }!
        TestSupport.expectEqual(TypingCounters.regions(x: e.frame.midX, y: -6, keys: keys), [.row1])
        TestSupport.expectEqual(TypingCounters.regions(x: 1, y: q.frame.midY, keys: keys), [.row1, .left])
        TestSupport.expectEqual(TypingCounters.regions(x: 0, y: 0, keys: []), [])
        // Another layer has the same four rows.
        let numbers = KeyboardLayout.keys(for: .numbers, metrics: KeyboardMetrics(width: 402, height: KeyboardMetrics.regularHeight),
                                          showsGlobe: false)
        let five = numbers.first { $0.action == .character("5") }!, period = numbers.first { $0.action == .character(".") }!
        TestSupport.expectEqual(TypingCounters.regions(x: five.frame.midX, y: five.frame.midY, keys: numbers), [.row1])
        TestSupport.expectEqual(TypingCounters.regions(x: period.frame.midX, y: period.frame.midY, keys: numbers), [.row3])
    }
}
