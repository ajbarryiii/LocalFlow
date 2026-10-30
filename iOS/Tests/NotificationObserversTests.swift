import Foundation

enum NotificationObserversTests {
    static var tests: [TestCase] {
        [
            ("removeAllStopsDelivery", testRemoveAllStopsDelivery),
            ("releaseStopsDelivery", testReleaseStopsDelivery),
        ]
    }

    private static let name = Notification.Name("LocalFlowTests.syntheticNotification")
    private static let otherName = Notification.Name("LocalFlowTests.otherSyntheticNotification")

    private static func testRemoveAllStopsDelivery() {
        let center = NotificationCenter()
        let calls = Locked(0)
        let observers = NotificationObservers(center: center)
        TestSupport.expect(observers.isEmpty, "starts empty")
        observers.observe(name) { _ in calls.update { $0 += 1 } }
        observers.observe(otherName) { _ in calls.update { $0 += 10 } }
        center.post(name: name, object: nil)
        center.post(name: otherName, object: nil)
        TestSupport.expectEqual(calls.current, 11)
        observers.removeAll()
        TestSupport.expect(observers.isEmpty, "tokens kept after removeAll")
        center.post(name: name, object: nil)
        center.post(name: otherName, object: nil)
        TestSupport.expectEqual(calls.current, 11)
        // Still usable afterwards, as an engine restart needs.
        observers.observe(name) { _ in calls.update { $0 += 100 } }
        center.post(name: name, object: nil)
        TestSupport.expectEqual(calls.current, 111)
        observers.removeAll()
        center.post(name: name, object: nil)
        TestSupport.expectEqual(calls.current, 111)
    }

    /// An owner that never calls `removeAll` (a capture made per recording) leaves nothing registered
    /// once it is released.
    private static func testReleaseStopsDelivery() {
        let center = NotificationCenter()
        let calls = Locked(0)
        weak var released: NotificationObservers?
        do {
            let observers = NotificationObservers(center: center)
            released = observers
            observers.observe(name, object: nil, queue: nil) { _ in calls.update { $0 += 1 } }
            center.post(name: name, object: nil)
            TestSupport.expectEqual(calls.current, 1)
        }
        TestSupport.expect(released == nil, "observers outlived their owner")
        center.post(name: name, object: nil)
        TestSupport.expectEqual(calls.current, 1)
    }
}
