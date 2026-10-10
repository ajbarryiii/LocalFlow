import CoreFoundation
import Foundation

/// Uses a unique invented group identifier per test, so these signals reach no other process.
enum DarwinNotifierTests {
    static var tests: [TestCase] {
        [
            ("namesSignalsUnderAppGroup", testNamesSignalsUnderAppGroup),
            ("deliversOnMainQueue", testDeliversOnMainQueue),
            ("onlyObservedSignalIsDelivered", testOnlyObservedSignalIsDelivered),
            ("cancelAndDeinitSuppressHandlers", testCancelAndDeinitSuppressHandlers),
            ("cancelAndDeinitUnregisterFromCF", testCancelAndDeinitUnregisterFromCF),
            ("orphanCounterSeesLeftoverCFRegistration", testOrphanCounterSeesLeftoverCFRegistration),
            ("releasingAnotherObservationDoesNotDeadlock", testReleasingAnotherObservationDoesNotDeadlock),
        ]
    }

    private static func makeNotifier() -> DarwinNotifier {
        DarwinNotifier(appGroupIdentifier: "group.localflow.tests.\(UUID().uuidString)")
    }

    /// Lets in-flight deliveries land, so a check for "nothing more arrived" is meaningful.
    private static func settle() {
        _ = TestSupport.waitUntil(timeout: 0.3) { false }
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
        settle()
        TestSupport.expectEqual(intents, 0)
        // A different app group's signal is a different name.
        makeNotifier().post(.result)
        let seen = results
        settle()
        TestSupport.expectEqual(results, seen)
        resultObservation.cancel()
        intentObservation.cancel()
    }

    private static func testCancelAndDeinitSuppressHandlers() {
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
        settle()
        TestSupport.expectEqual(cancelledCount, 0)
        TestSupport.expectEqual(releasedCount, 0)
        kept.cancel()
    }

    /// Handler suppression alone would hide a missing CF unregistration; the orphan counter does not.
    private static func testCancelAndDeinitUnregisterFromCF() {
        let notifier = makeNotifier()
        let before = DarwinNotifier.diagnostics
        var keptCount = 0
        let cancelled = notifier.observe(.intent) {}
        var released: DarwinNotifier.Observation? = notifier.observe(.intent) {}
        let kept = notifier.observe(.intent) { keptCount += 1 }
        TestSupport.expectEqual(DarwinNotifier.diagnostics.registeredObservers, before.registeredObservers + 3)
        TestSupport.expect(released != nil, "observation not created")
        cancelled.cancel()
        cancelled.cancel()
        released = nil
        TestSupport.expectEqual(DarwinNotifier.diagnostics.registeredObservers, before.registeredObservers + 1)
        for _ in 0..<3 { notifier.post(.intent) }
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { keptCount > 0 }, "remaining observer not delivered")
        settle()
        TestSupport.expectEqual(DarwinNotifier.diagnostics.orphanDeliveries, before.orphanDeliveries)
        kept.cancel()
        TestSupport.expectEqual(DarwinNotifier.diagnostics, before)
    }

    /// Control for the test above: a CF registration that outlives its handler is counted.
    private static func testOrphanCounterSeesLeftoverCFRegistration() {
        let notifier = makeNotifier()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = notifier.name(for: .status)
        let leftover = UnsafeRawPointer(bitPattern: Int.max - 7)   // never a registry ID
        let before = DarwinNotifier.diagnostics.orphanDeliveries
        CFNotificationCenterAddObserver(center, leftover, DarwinNotifier.callback, name as CFString, nil,
                                        .deliverImmediately)
        defer { CFNotificationCenterRemoveObserver(center, leftover, CFNotificationName(name as CFString), nil) }
        notifier.post(.status)
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { DarwinNotifier.diagnostics.orphanDeliveries > before },
                           "an orphan delivery was not counted")
    }

    /// A handler may hold the last reference to another observation. Releasing that handler on
    /// cancel runs the other observation's deinit, which cancels it and takes the registry lock.
    private static func testReleasingAnotherObservationDoesNotDeadlock() {
        let notifier = makeNotifier()
        let before = DarwinNotifier.diagnostics
        func observationOwningAnother() -> DarwinNotifier.Observation {
            let inner = notifier.observe(.status) {}
            return notifier.observe(.result) { withExtendedLifetime(inner) {} }
        }

        let cancelled = observationOwningAnother()
        TestSupport.expectEqual(DarwinNotifier.diagnostics.registeredObservers, before.registeredObservers + 2)
        Concurrently.withTimeout(5, "cancel deadlocked") { cancelled.cancel() }
        TestSupport.expectEqual(DarwinNotifier.diagnostics.registeredObservers, before.registeredObservers)

        let holder = Locked<DarwinNotifier.Observation?>(observationOwningAnother())
        TestSupport.expectEqual(DarwinNotifier.diagnostics.registeredObservers, before.registeredObservers + 2)
        Concurrently.withTimeout(5, "deinit deadlocked") {
            let last = holder.update { observation -> DarwinNotifier.Observation? in
                defer { observation = nil }
                return observation
            }
            _ = last   // released here, outside the holder's lock
        }
        TestSupport.expectEqual(DarwinNotifier.diagnostics.registeredObservers, before.registeredObservers)

        // Both inner observations are gone from CF too.
        notifier.post(.status)
        notifier.post(.result)
        settle()
        TestSupport.expectEqual(DarwinNotifier.diagnostics, before)
    }
}
