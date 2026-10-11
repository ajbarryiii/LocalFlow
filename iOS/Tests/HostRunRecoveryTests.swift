import Foundation

enum HostRunRecoveryTests {
    static var tests: [TestCase] {
        [
            ("nothingToRecover", testNothingToRecover),
            ("inProgressRequestIsInterrupted", testInProgressRequestIsInterrupted),
            ("terminalRequestIsKnownButUnchanged", testTerminalRequestIsKnownButUnchanged),
            ("recoveredRequestIsNeverRestarted", testRecoveredRequestIsNeverRestarted),
            ("resultsFromOtherRunsArePurged", testResultsFromOtherRunsArePurged),
        ]
    }

    private static let newRun = UUID(uuidString: "00000000-0000-4000-8000-0000000000C9")!

    private static func testNothingToRecover() {
        for previous in [StoreRead<HostStatus>.absent, .incompatible, .unreadable, .value(Fixture.status())] {
            let recovery = HostRunRecovery(previous: previous, hostRunID: newRun, now: Fixture.now)
            TestSupport.expectEqual(recovery, HostRunRecovery(current: nil, knownRequestIDs: []))
        }
    }

    private static func testInProgressRequestIsInterrupted() {
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing] {
            let previous = Fixture.status(dictation: Fixture.dictation(phase, updatedAt: Fixture.now - 30))
            let recovery = HostRunRecovery(previous: .value(previous), hostRunID: newRun, now: Fixture.now)
            TestSupport.expectEqual(recovery.current, Fixture.dictation(.failed, error: .interrupted, updatedAt: Fixture.now))
            TestSupport.expectEqual(recovery.current?.hostRunID, Fixture.hostRunID)   // still names the run that admitted it
            TestSupport.expectEqual(recovery.knownRequestIDs, [Fixture.requestID])
        }
    }

    private static func testTerminalRequestIsKnownButUnchanged() {
        for phase in [DictationStatus.Phase.completed, .failed, .cancelled] {
            let dictation = Fixture.dictation(phase, error: phase == .completed ? nil : .superseded, updatedAt: Fixture.now - 30)
            let recovery = HostRunRecovery(previous: .value(Fixture.status(.inactive, dictation: dictation)),
                                           hostRunID: newRun, now: Fixture.now)
            TestSupport.expectEqual(recovery.current, dictation)
            TestSupport.expectEqual(recovery.knownRequestIDs, [Fixture.requestID])
        }
    }

    /// The host died while recording; the record intent is still fresh when it relaunches.
    private static func testRecoveredRequestIsNeverRestarted() {
        let previous = Fixture.status(dictation: Fixture.dictation(.recording))
        let recovery = HostRunRecovery(previous: .value(previous), hostRunID: newRun, now: Fixture.now + 1)
        for current in [recovery.current, nil] {
            for intent in [Fixture.intent(.record), Fixture.intent(.finish), Fixture.intent(.cancel)] {
                TestSupport.expectEqual(
                    HostReconciler.action(intent: .value(intent), current: current, knownRequestIDs: recovery.knownRequestIDs,
                                          isForeground: true, sessionActive: true, now: Fixture.now + 1), .none)
            }
        }
    }

    private static func testResultsFromOtherRunsArePurged() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedDictationStore(directory: directory)
        let mine = UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!
        let corrupt = UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!
        try! store.writeResult(Fixture.result(hostRunID: Fixture.hostRunID))
        try! store.writeResult(Fixture.result(mine, hostRunID: newRun))
        try! Data("{".utf8).write(to: store.resultURL(for: corrupt))
        store.purgeResults { _, read in HostRunRecovery.isFromAnotherRun(read, hostRunID: newRun) }
        TestSupport.expectEqual(store.resultRequestIDs(), [mine])
    }
}
