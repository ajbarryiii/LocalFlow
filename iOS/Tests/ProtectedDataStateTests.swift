import Foundation

/// The power log's effective protected-data state (schema 2): from the lock notification until the
/// unlock notification every sample reads `unavailable`, although UIKit's property still reads available
/// at first, whichever of the recorder's and the host's lock observers runs first.
enum ProtectedDataStateTests {
    static var tests: [TestCase] {
        [
            ("recorderObserverFirst", testRecorderObserverFirst),
            ("hostObserverFirst", testHostObserverFirst),
            ("unlockRestoresTheReading", testUnlockRestoresTheReading),
            ("readingAloneCountsOutsideTheLatch", testReadingAloneCountsOutsideTheLatch),
            ("activationWithDataAvailableClearsTheLatch", testActivationWithDataAvailableClearsTheLatch),
        ]
    }

    /// The recorder hears the lock first, then the host cancels a dictation and publishes a state change,
    /// whose sample is taken while UIKit still reads available.
    private static func testRecorderObserverFirst() {
        var state = ProtectedDataState()
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .available)
        state.willBecomeUnavailable()
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .unavailable)   // the notification's own sample
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: true), .unavailable)    // the host's state sample
        TestSupport.expectEqual(state.effective(reading: false, hostLocked: true), .unavailable)   // later periodic samples
    }

    /// The host hears the lock first: its cancelled dictation publishes before the recorder's observer ran.
    private static func testHostObserverFirst() {
        var state = ProtectedDataState()
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: true), .unavailable)
        state.willBecomeUnavailable()
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: true), .unavailable)
        TestSupport.expectEqual(state.effective(reading: false, hostLocked: true), .unavailable)
    }

    private static func testUnlockRestoresTheReading() {
        var state = ProtectedDataState()
        state.willBecomeUnavailable()
        state.didBecomeAvailable()
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .available)
        // Either observer may run first at unlock too; the host's latch alone still means locked.
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: true), .unavailable)
        state.willBecomeUnavailable()
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .unavailable)
    }

    /// A suspended app can miss the unlock notification: arriving in front with protected data available
    /// clears the latch too, as the host core does. Arriving while it is unavailable keeps it.
    private static func testActivationWithDataAvailableClearsTheLatch() {
        var state = ProtectedDataState()
        state.willBecomeUnavailable()
        state.activated(protectedDataAvailable: false)
        TestSupport.expectEqual(state.effective(reading: false, hostLocked: false), .unavailable)
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .unavailable)
        state.activated(protectedDataAvailable: true)
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .available)
    }

    /// Without any notification (locked at launch), UIKit's reading decides.
    private static func testReadingAloneCountsOutsideTheLatch() {
        let state = ProtectedDataState()
        TestSupport.expectEqual(state.effective(reading: false, hostLocked: false), .unavailable)
        TestSupport.expectEqual(state.effective(reading: true, hostLocked: false), .available)
    }
}
