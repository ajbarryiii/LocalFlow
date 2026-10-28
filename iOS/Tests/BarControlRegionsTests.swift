import Foundation

/// ARCHITECTURE.md, "Reach above the keys": the bar's control frames, a moved or gone control keeping its
/// previous frame while it may still be animating there.
enum BarControlRegionsTests {
    static var tests: [TestCase] {
        [
            ("currentFramesAreTheControls", testCurrentFramesAreTheControls),
            ("aMovedControlKeepsItsOldFrameForALinger", testAMovedControlKeepsItsOldFrameForALinger),
            ("aGoneControlKeepsItsFrameForALinger", testAGoneControlKeepsItsFrameForALinger),
            ("aControlsCurrentFrameNeverLingers", testAControlsCurrentFrameNeverLingers),
        ]
    }

    private static let undo = KeyRect(x: 54, y: 12, width: 70, height: 30)
    private static let insert = KeyRect(x: 130, y: 12, width: 100, height: 30)
    private static let slid = KeyRect(x: 54, y: 12, width: 100, height: 30)

    private static func testCurrentFramesAreTheControls() {
        TestSupport.expectEqual(BarControlRegions.linger, 0.6)
        var regions = BarControlRegions()
        TestSupport.expectEqual(regions.rects(now: 0), [])
        regions.set("undo", undo, now: 0)
        regions.set("insert", insert, now: 0)
        TestSupport.expectEqual(Set(regions.rects(now: 1).map(\.x)), [54, 130])
        // Reporting the same frame again changes nothing.
        regions.set("undo", undo, now: 5)
        TestSupport.expectEqual(regions.rects(now: 5).count, 2)
    }

    private static func testAMovedControlKeepsItsOldFrameForALinger() {
        // "Insert last" slides left when Undo goes: both its frames are the bar's until the slide is over.
        var regions = BarControlRegions()
        regions.set("insert", insert, now: 0)
        regions.set("insert", slid, now: 10)
        TestSupport.expectEqual(Set(regions.rects(now: 10.3).map(\.x)), [54, 130])
        TestSupport.expectEqual(regions.rects(now: 10 + BarControlRegions.linger), [slid])
        // Moved again during the linger: the frame it just left lingers instead.
        regions.set("insert", insert, now: 20)
        regions.set("insert", slid, now: 20.1)
        TestSupport.expectEqual(Set(regions.rects(now: 20.2).map(\.x)), [54, 130])
    }

    private static func testAGoneControlKeepsItsFrameForALinger() {
        var regions = BarControlRegions()
        regions.set("undo", undo, now: 0)
        regions.set("undo", nil, now: 3)
        TestSupport.expectEqual(regions.rects(now: 3.5), [undo])
        TestSupport.expectEqual(regions.rects(now: 3 + BarControlRegions.linger), [])
        // Forgetting a control that was never reported changes nothing.
        regions.set("cancel", nil, now: 4)
        TestSupport.expectEqual(regions.rects(now: 4), [])
    }

    private static func testAControlsCurrentFrameNeverLingers() {
        // Stop's reach into the keys follows only where Start is now: a frame it left is not a key point's.
        var regions = BarControlRegions()
        TestSupport.expectEqual(regions.frame(of: "start"), nil)
        regions.set("start", insert, now: 0)
        regions.set("start", slid, now: 1)
        TestSupport.expectEqual(regions.frame(of: "start"), slid)
        regions.set("start", nil, now: 2)
        TestSupport.expectEqual(regions.frame(of: "start"), nil)
        TestSupport.expectEqual(regions.rects(now: 2.1), [slid])
    }
}
