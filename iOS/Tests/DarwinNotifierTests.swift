import Foundation

/// Uses a unique invented group identifier per run, so these signals reach no other process.
enum DarwinNotifierTests {
    static var tests: [TestCase] {
        [
            ("namesSignalsUnderAppGroup", testNamesSignalsUnderAppGroup),
            ("deliversOnMainQueue", testDeliversOnMainQueue),
            ("onlyObservedSignalIsDelivered", testOnlyObservedSignalIsDelivered),
            ("cancelAndDeinitUnregister", testCancelAndDeinitUnregister),
        ]
    }

    private static func makeNotifier() -> DarwinNotifier {
        DarwinNotifier(appGroupIdentifier: "group.localflow.tests.\(UUID().uuidString)")
    }

    private static func testNamesSignalsUnderAppGroup() {
        let notifier = DarwinNotifier(configuration: LocalFlowConfiguration(
            appGroupIdentifier: "group.example.synthetic", urlScheme: "synthetic-flow"))
        TestSupport.expectEqual(DarwinNotifier.Signal.allCases.map(notifier.name(for:)), [
            "group.example.synthetic.intent", "group.example.synthetic.presence",
            "group.example.synthetic.status", "group.example.synthetic.result",
        ])
    }

    private static func testDeliversOnMainQueue() {
        let notifier = makeNotifier()
        var deliveries = 0
        var onMain = true
        let observation = notifier.observe(.status) {
            deliveries += 1
            onMain = onMain && Thread.isMainThread
        }
        notifier.post(.status)
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { deliveries > 0 }, "status signal not delivered")
        TestSupport.expect(onMain, "handler ran off the main thread")
        // Posting from a background thread still delivers on main.
        let before = deliveries
        DispatchQueue.global().async { notifier.post(.status) }
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { deliveries > before }, "background post not delivered")
        TestSupport.expect(onMain, "handler ran off the main thread")
        observation.cancel()
    }

    private static func testOnlyObservedSignalIsDelivered() {
        let notifier = makeNotifier()
        var results = 0
        var intents = 0
        let resultObservation = notifier.observe(.result) { results += 1 }
        let intentObservation = notifier.observe(.intent) { intents += 1 }
        notifier.post(.result)
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { results > 0 }, "result signal not delivered")
        _ = TestSupport.waitUntil(timeout: 0.3) { false }
        TestSupport.expectEqual(intents, 0)
        // A different app group's signal is a different name.
        makeNotifier().post(.result)
        let seen = results
        _ = TestSupport.waitUntil(timeout: 0.3) { false }
        TestSupport.expectEqual(results, seen)
        resultObservation.cancel()
        intentObservation.cancel()
    }

    private static func testCancelAndDeinitUnregister() {
        let notifier = makeNotifier()
        var cancelledCount = 0
        var releasedCount = 0
        var keptCount = 0
        let cancelled = notifier.observe(.intent) { cancelledCount += 1 }
        var released: DarwinNotifier.Observation? = notifier.observe(.intent) { releasedCount += 1 }
        let kept = notifier.observe(.intent) { keptCount += 1 }
        TestSupport.expect(released != nil, "observation not created")
        cancelled.cancel()
        cancelled.cancel()   // idempotent
        released = nil
        notifier.post(.intent)
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { keptCount > 0 }, "remaining observer not delivered")
        _ = TestSupport.waitUntil(timeout: 0.3) { false }
        TestSupport.expectEqual(cancelledCount, 0)
        TestSupport.expectEqual(releasedCount, 0)
        kept.cancel()
    }
}
