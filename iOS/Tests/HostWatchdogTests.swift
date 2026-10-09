import Foundation

enum HostWatchdogTests {
    static var tests: [TestCase] {
        [
            ("onlyStartingOrRecordingIsWatched", testOnlyStartingOrRecordingIsWatched),
            ("startupTimeout", testStartupTimeout),
            ("foregroundKeepsRecording", testForegroundKeepsRecording),
            ("visibleKeyboardKeepsRecording", testVisibleKeyboardKeepsRecording),
            ("dismissedKeyboardCancels", testDismissedKeyboardCancels),
            ("swipeBackAfterLongBounceIsNotDismissal", testSwipeBackAfterLongBounceIsNotDismissal),
            ("presenceFromTheFutureIsStale", testPresenceFromTheFutureIsStale),
        ]
    }

    private static let timeout = DictationProtocol.keyboardPresenceTimeout

    private static func reason(_ current: DictationStatus?, presence: StoreRead<KeyboardPresence> = .absent,
                               isForeground: Bool = false, lastForegroundAt: Date? = nil,
                               now: Date = Fixture.now) -> HostErrorCode? {
        HostWatchdog.stopReason(current: current, presence: presence, isForeground: isForeground,
                                lastForegroundAt: lastForegroundAt, now: now)
    }

    private static func testOnlyStartingOrRecordingIsWatched() {
        TestSupport.expectEqual(reason(nil), nil)
        for phase in [DictationStatus.Phase.transcribing, .completed, .failed, .cancelled] {
            TestSupport.expectEqual(reason(Fixture.dictation(phase, startedAt: Fixture.now - 3_600)), nil)
        }
    }

    private static func testStartupTimeout() {
        let startup = DictationProtocol.startupTimeout
        let starting = Fixture.dictation(.starting, startedAt: Fixture.now)
        let presence = StoreRead.value(Fixture.presence())
        TestSupport.expectEqual(reason(starting, presence: presence, isForeground: true, now: Fixture.now + startup), nil)
        TestSupport.expectEqual(reason(starting, presence: presence, isForeground: true, now: Fixture.now + startup + 0.001),
                                .startupTimeout)
        // An admission stamped beyond the skew tolerance ahead of now fails closed.
        TestSupport.expectEqual(reason(starting, presence: presence, isForeground: true, now: Fixture.now - 3), .startupTimeout)
        // Recording has no startup deadline.
        TestSupport.expectEqual(reason(Fixture.dictation(.recording, startedAt: Fixture.now - 200), presence: presence,
                                       isForeground: true), nil)
    }

    private static func testForegroundKeepsRecording() {
        for phase in [DictationStatus.Phase.starting, .recording] {
            TestSupport.expectEqual(reason(Fixture.dictation(phase, startedAt: Fixture.now - 1), isForeground: true), nil)
        }
    }

    private static func testVisibleKeyboardKeepsRecording() {
        let recording = Fixture.dictation(.recording, startedAt: Fixture.now - 100)
        TestSupport.expectEqual(reason(recording, presence: .value(Fixture.presence(seenAt: Fixture.now - timeout))), nil)
        TestSupport.expectEqual(reason(recording, presence: .value(Fixture.presence(seenAt: Fixture.now))), nil)
    }

    private static func testDismissedKeyboardCancels() {
        let recording = Fixture.dictation(.recording, startedAt: Fixture.now - 100)
        let stale = StoreRead.value(Fixture.presence(seenAt: Fixture.now - timeout - 0.001))
        TestSupport.expectEqual(reason(recording, presence: stale), .keyboardDismissed)
        for missing in [StoreRead<KeyboardPresence>.absent, .incompatible, .unreadable] {
            TestSupport.expectEqual(reason(recording, presence: missing), .keyboardDismissed)
        }
        TestSupport.expectEqual(reason(Fixture.dictation(.starting, startedAt: Fixture.now - 1), presence: stale),
                                .keyboardDismissed)
        TestSupport.expectEqual(reason(recording, presence: stale, lastForegroundAt: Fixture.now - timeout - 1),
                                .keyboardDismissed)
    }

    private static func testSwipeBackAfterLongBounceIsNotDismissal() {
        // The user spent 40 s in the app; the keyboard's last presence predates the bounce.
        let recording = Fixture.dictation(.recording, startedAt: Fixture.now - 40)
        let beforeBounce = StoreRead.value(Fixture.presence(seenAt: Fixture.now - 41))
        TestSupport.expectEqual(reason(recording, presence: beforeBounce, lastForegroundAt: Fixture.now - 0.5), nil)
        TestSupport.expectEqual(reason(recording, presence: beforeBounce, lastForegroundAt: Fixture.now - timeout), nil)
        TestSupport.expectEqual(reason(recording, presence: beforeBounce, lastForegroundAt: Fixture.now - timeout - 0.001),
                                .keyboardDismissed)
    }

    private static func testPresenceFromTheFutureIsStale() {
        let recording = Fixture.dictation(.recording, startedAt: Fixture.now - 10)
        let tolerance = DictationProtocol.clockSkewTolerance
        TestSupport.expectEqual(reason(recording, presence: .value(Fixture.presence(seenAt: Fixture.now + tolerance))), nil)
        TestSupport.expectEqual(reason(recording, presence: .value(Fixture.presence(seenAt: Fixture.now + tolerance + 1))),
                                .keyboardDismissed)
    }
}
