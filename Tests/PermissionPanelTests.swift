import CoreGraphics
import Foundation

enum PermissionPanelTests {
    static func run() {
        draggablePermissions()
        layout()
        dockPlacement()
        coordinates()
        spring()
        flightArc()
        dropRace()
    }

    /// Only Accessibility's list takes a dragged app; Microphone uses Apple's prompt.
    private static func draggablePermissions() {
        TestSupport.expect(PrivacyPermission.accessibility.acceptsDraggedApp, "Accessibility takes a dragged app")
        TestSupport.expect(!PrivacyPermission.microphone.acceptsDraggedApp, "Microphone has no drag panel")
    }

    private static func layout() {
        // The app row matches the Privacy list's column, within 320–640 pt.
        TestSupport.expectEqual(PermissionPanel.Layout(settingsWidth: 740).rowWidth, 468)
        TestSupport.expectEqual(PermissionPanel.Layout(settingsWidth: 500).rowWidth, 320)
        TestSupport.expectEqual(PermissionPanel.Layout(settingsWidth: 1200).rowWidth, 640)
        TestSupport.expectEqual(PermissionPanel.Layout(settingsWidth: 740).cardSize, CGSize(width: 532, height: 95))
    }

    /// AppKit coordinates (origin bottom-left) on a 2560×1440 screen with a 30 pt menu bar.
    private static func dockPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        let cases: [(String, CGRect, CGRect, PermissionPanel.Dock)] = [
            ("room below", CGRect(x: 1640, y: 320, width: 740, height: 820), screen, .below),
            ("no room below", CGRect(x: 1640, y: 100, width: 740, height: 820), screen, .inside),
            ("short window, no room", CGRect(x: 1000, y: 60, width: 740, height: 300), screen, .right),
            ("short, at the right edge", CGRect(x: 1820, y: 60, width: 740, height: 300), screen, .left),
            ("lower 30% off the screen", CGRect(x: 1640, y: -200, width: 740, height: 820), screen, .left),
            ("small screen", CGRect(x: 0, y: 0, width: 740, height: 600), CGRect(x: 0, y: 0, width: 740, height: 600), .inside),
            ("window fills a tiny screen", CGRect(x: 0, y: 0, width: 740, height: 300), CGRect(x: 0, y: 0, width: 740, height: 300), .clamped),
        ]
        for (name, settings, visible, expected) in cases {
            let layout = PermissionPanel.Layout(settingsWidth: settings.width)
            let plan = PermissionPanel.dock(settings: settings, visible: visible, layout: layout)
            TestSupport.expect(plan.dock == expected, "\(name): expected \(expected), got \(plan.dock)")
            TestSupport.expectEqual(plan.frame.size, layout.cardSize)
        }

        // Below: 10 pt under the window, the app row under the list's column.
        let settings = CGRect(x: 1640, y: 320, width: 740, height: 820)
        let below = PermissionPanel.dock(settings: settings, visible: screen, layout: PermissionPanel.Layout(settingsWidth: 740))
        TestSupport.expectEqual(below.frame, CGRect(x: 1840, y: 215, width: 532, height: 95))

        // Inside: 20 pt above the window's bottom edge, on the same column.
        let low = CGRect(x: 1640, y: 100, width: 740, height: 820)
        let inside = PermissionPanel.dock(settings: low, visible: screen, layout: PermissionPanel.Layout(settingsWidth: 740))
        TestSupport.expectEqual(inside.frame, CGRect(x: 1840, y: 120, width: 532, height: 95))
    }

    private static func coordinates() {
        let quartz = CGRect(x: 10, y: 20, width: 100, height: 50)
        let appKit = PermissionPanel.appKit(fromQuartz: quartz, primaryHeight: 1000)
        TestSupport.expectEqual(appKit, CGRect(x: 10, y: 930, width: 100, height: 50))
        TestSupport.expectEqual(PermissionPanel.quartz(fromAppKit: appKit, primaryHeight: 1000), quartz)
    }

    private static func spring() {
        let spring = PermissionPanel.Spring(duration: 0.85, bounce: 0)
        TestSupport.expectEqual(spring.value(0), 0)
        TestSupport.expectEqual(spring.value(-1), 0)
        TestSupport.expectApproximatelyEqual(spring.value(spring.settleTime), 1, accuracy: 0.001)
        // Critically damped: it never overshoots or turns back.
        var previous = 0.0
        for step in 1...100 {
            let value = spring.value(spring.settleTime * Double(step) / 100)
            TestSupport.expect(value >= previous && value <= 1, "spring is monotonic and stays at or below 1")
            previous = value
        }
        // With bounce it overshoots and settles.
        let bouncy = PermissionPanel.Spring(duration: 0.5, bounce: 0.3)
        TestSupport.expect((1...100).contains { bouncy.value(bouncy.settleTime * Double($0) / 100) > 1 }, "a bouncy spring overshoots")
    }

    private static func flightArc() {
        let source = CGRect(x: 100, y: 500, width: 120, height: 30)
        // A long hop rises the full 160 pt above the higher end, midway across.
        let farTarget = CGRect(x: 1500, y: 200, width: 532, height: 95)
        let far = PermissionPanel.flightControl(source: source, target: farTarget, ceiling: 10_000)
        TestSupport.expectEqual(far.x, (source.midX + farTarget.midX) / 2)
        TestSupport.expectEqual(far.y, source.midY + 160)
        // A short hop rises 35% of its length.
        let nearTarget = CGRect(x: 160, y: 500, width: 120, height: 30)
        let near = PermissionPanel.flightControl(source: source, target: nearTarget, ceiling: 10_000)
        TestSupport.expectApproximatelyEqual(Double(near.y), Double(source.midY + 60 * 0.35))
        // It never rises past the ceiling, nor drops below the higher end.
        TestSupport.expectEqual(PermissionPanel.flightControl(source: source, target: farTarget, ceiling: 550).y, 550)
        TestSupport.expectEqual(PermissionPanel.flightControl(source: source, target: farTarget, ceiling: 0).y, source.midY)
    }

    /// After a drop the card steps aside until Settings' authentication sheet is dismissed, or 10 s.
    private static func dropRace() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var race = PermissionPanel.DropRace(droppedAt: start, settingsWindowCount: 1)
        TestSupport.expect(!race.observe(settingsWindowCount: 1, at: start.addingTimeInterval(1)), "nothing has happened yet")
        TestSupport.expect(!race.observe(settingsWindowCount: 2, at: start.addingTimeInterval(2)), "a sheet opened")
        TestSupport.expect(!race.observe(settingsWindowCount: 2, at: start.addingTimeInterval(5)), "the sheet is still open")
        TestSupport.expect(race.observe(settingsWindowCount: 1, at: start.addingTimeInterval(6)), "the sheet was dismissed")

        var quiet = PermissionPanel.DropRace(droppedAt: start, settingsWindowCount: 1)
        TestSupport.expect(!quiet.observe(settingsWindowCount: 1, at: start.addingTimeInterval(9.9)), "within the deadline")
        TestSupport.expect(quiet.observe(settingsWindowCount: 1, at: start.addingTimeInterval(10.1)), "past the deadline")

        // A window closing without a sheet having opened also ends it.
        var closed = PermissionPanel.DropRace(droppedAt: start, settingsWindowCount: 2)
        TestSupport.expect(closed.observe(settingsWindowCount: 1, at: start.addingTimeInterval(1)), "a Settings window closed")
    }
}
