import Foundation

enum HostReconcilerTests {
    static var tests: [TestCase] {
        [
            ("onlyReadableIntentsAct", testOnlyReadableIntentsAct),
            ("freshRecordStarts", testFreshRecordStarts),
            ("recordIsNeverRestarted", testRecordIsNeverRestarted),
            ("knownRequestsAreNeverRestarted", testKnownRequestsAreNeverRestarted),
            ("recordFreshnessWindowAndSkew", testRecordFreshnessWindowAndSkew),
            ("backgroundWithoutSessionRejects", testBackgroundWithoutSessionRejects),
            ("newestRecordWins", testNewestRecordWins),
            ("finishByPhase", testFinishByPhase),
            ("unknownFinishIsRejectedUnlessKnown", testUnknownFinishIsRejectedUnlessKnown),
            ("cancelByPhase", testCancelByPhase),
            ("unknownCancelDoesNothing", testUnknownCancelDoesNothing),
            ("instanceIDDoesNotMatter", testInstanceIDDoesNotMatter),
            ("reEvaluationAfterApplyingIsIdempotent", testReEvaluationAfterApplyingIsIdempotent),
        ]
    }

    private static let allPhases: [DictationStatus.Phase] = [
        .starting, .recording, .transcribing, .completed, .failed, .cancelled,
    ]

    private static func action(_ intent: KeyboardIntent?, _ current: DictationStatus?, known: Set<UUID> = [],
                               isForeground: Bool = false, sessionActive: Bool = true,
                               now: Date = Fixture.now) -> HostAction {
        HostReconciler.action(intent: intent.map { .value($0) } ?? .absent, current: current, knownRequestIDs: known,
                              isForeground: isForeground, sessionActive: sessionActive, now: now)
    }

    private static func testOnlyReadableIntentsAct() {
        for read in [StoreRead<KeyboardIntent>.absent, .incompatible, .unreadable] {
            for current in [nil] + allPhases.map({ Optional(Fixture.dictation($0)) }) {
                TestSupport.expectEqual(
                    HostReconciler.action(intent: read, current: current, knownRequestIDs: [], isForeground: true,
                                          sessionActive: true, now: Fixture.now), .none)
            }
        }
        // A caller-built value with a foreign schema is ignored too.
        var intent = Fixture.intent(.record)
        intent.schema = 2
        TestSupport.expectEqual(action(intent, nil, isForeground: true), .none)
    }

    private static func testFreshRecordStarts() {
        let start = HostAction.start(Fixture.requestID)
        TestSupport.expectEqual(action(Fixture.intent(.record), nil, sessionActive: true), start)
        TestSupport.expectEqual(action(Fixture.intent(.record), nil, isForeground: true, sessionActive: false), start)
        TestSupport.expectEqual(action(Fixture.intent(.record), nil, isForeground: true, sessionActive: true), start)
        // Earlier requests in a final phase do not block a new one.
        for phase in [DictationStatus.Phase.completed, .failed, .cancelled] {
            TestSupport.expectEqual(action(Fixture.intent(.record), Fixture.dictation(phase, Fixture.otherRequestID),
                                           known: [Fixture.otherRequestID]), start)
        }
    }

    private static func testRecordIsNeverRestarted() {
        for phase in allPhases {
            TestSupport.expectEqual(action(Fixture.intent(.record), Fixture.dictation(phase), isForeground: true), .none)
        }
    }

    private static func testKnownRequestsAreNeverRestarted() {
        // After host death, the recovered request is known even though `current` is another one or nil.
        let known: Set<UUID> = [Fixture.requestID]
        TestSupport.expectEqual(action(Fixture.intent(.record), nil, known: known, isForeground: true), .none)
        TestSupport.expectEqual(action(Fixture.intent(.record), Fixture.dictation(.completed, Fixture.otherRequestID),
                                       known: known, isForeground: true), .none)
        // A known request is not rejected either, even from the background.
        TestSupport.expectEqual(action(Fixture.intent(.record), nil, known: known, sessionActive: false), .none)
    }

    private static func testRecordFreshnessWindowAndSkew() {
        let ttl = DictationProtocol.pendingRecordTTL
        let tolerance = DictationProtocol.clockSkewTolerance
        let intent = Fixture.intent(.record)
        let start = HostAction.start(Fixture.requestID)
        TestSupport.expectEqual(action(intent, nil, now: Fixture.now + ttl), start)
        TestSupport.expectEqual(action(intent, nil, now: Fixture.now + ttl + 0.001), .none)
        TestSupport.expectEqual(action(intent, nil, now: Fixture.now + 3_600), .none)
        TestSupport.expectEqual(action(intent, nil, now: Fixture.now - tolerance), start)
        // A backward clock jump makes the intent stale, so it can never start capture later.
        TestSupport.expectEqual(action(intent, nil, now: Fixture.now - tolerance - 0.001), .none)
        // A stale intent is ignored, not rejected, even when capture could not start anyway.
        TestSupport.expectEqual(action(intent, nil, sessionActive: false, now: Fixture.now + ttl + 1), .none)
    }

    private static func testBackgroundWithoutSessionRejects() {
        TestSupport.expectEqual(action(Fixture.intent(.record), nil, isForeground: false, sessionActive: false),
                                .reject(Fixture.requestID, .sessionInactive))
        TestSupport.expectEqual(action(Fixture.intent(.record), Fixture.dictation(.completed, Fixture.otherRequestID),
                                       isForeground: false, sessionActive: false),
                                .reject(Fixture.requestID, .sessionInactive))
    }

    private static func testNewestRecordWins() {
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing] {
            TestSupport.expectEqual(action(Fixture.intent(.record), Fixture.dictation(phase, Fixture.otherRequestID),
                                           known: [Fixture.otherRequestID]), .start(Fixture.requestID))
        }
    }

    private static func testFinishByPhase() {
        let intent = Fixture.intent(.finish)
        TestSupport.expectEqual(action(intent, Fixture.dictation(.recording)), .finish(Fixture.requestID))
        // Nothing was captured yet; the controller reports failed(.notRecording).
        TestSupport.expectEqual(action(intent, Fixture.dictation(.starting)), .cancel(Fixture.requestID))
        for phase in [DictationStatus.Phase.transcribing, .completed, .failed, .cancelled] {
            TestSupport.expectEqual(action(intent, Fixture.dictation(phase), known: [Fixture.requestID]), .none)
        }
        // A finish is honored however old it is, in the foreground or not.
        TestSupport.expectEqual(action(intent, Fixture.dictation(.recording), isForeground: true, sessionActive: true,
                                       now: Fixture.now + 299), .finish(Fixture.requestID))
    }

    private static func testUnknownFinishIsRejectedUnlessKnown() {
        let intent = Fixture.intent(.finish)
        let rejected = HostAction.reject(Fixture.requestID, .notRecording)
        TestSupport.expectEqual(action(intent, nil), rejected)
        for phase in allPhases {
            TestSupport.expectEqual(action(intent, Fixture.dictation(phase, Fixture.otherRequestID)), rejected)
            TestSupport.expectEqual(action(intent, Fixture.dictation(phase, Fixture.otherRequestID),
                                           known: [Fixture.requestID]), .none)
        }
        TestSupport.expectEqual(action(intent, nil, known: [Fixture.requestID]), .none)
    }

    private static func testCancelByPhase() {
        let intent = Fixture.intent(.cancel)
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing] {
            TestSupport.expectEqual(action(intent, Fixture.dictation(phase)), .cancel(Fixture.requestID))
        }
        for phase in [DictationStatus.Phase.completed, .failed, .cancelled] {
            TestSupport.expectEqual(action(intent, Fixture.dictation(phase)), .none)
        }
    }

    private static func testUnknownCancelDoesNothing() {
        TestSupport.expectEqual(action(Fixture.intent(.cancel), nil), .none)
        TestSupport.expectEqual(action(Fixture.intent(.cancel), nil, known: [Fixture.requestID]), .none)
        for phase in allPhases {
            TestSupport.expectEqual(action(Fixture.intent(.cancel), Fixture.dictation(phase, Fixture.otherRequestID)), .none)
        }
    }

    private static func testInstanceIDDoesNotMatter() {
        // A keyboard created after the bounce stops the request its predecessor started.
        let finish = Fixture.intent(.finish, instance: Fixture.otherInstanceID)
        TestSupport.expectEqual(action(finish, Fixture.dictation(.recording)), .finish(Fixture.requestID))
    }

    /// Simulates a controller that applies each action and records the request as known.
    private static func testReEvaluationAfterApplyingIsIdempotent() {
        var current: DictationStatus? = Fixture.dictation(.recording, Fixture.otherRequestID)
        var known: Set<UUID> = [Fixture.otherRequestID]
        var now = Fixture.now
        func step(_ intent: KeyboardIntent, isForeground: Bool = true) -> HostAction {
            let result = action(intent, current, known: known, isForeground: isForeground, now: now)
            switch result {
            case .none: break
            case .start(let id): current = Fixture.dictation(.starting, id, updatedAt: now)
            case .finish(let id): current = Fixture.dictation(.transcribing, id, updatedAt: now)
            case .cancel(let id): current = Fixture.dictation(.cancelled, id, updatedAt: now)
            case .reject(let id, let code): current = Fixture.dictation(.failed, id, error: code, updatedAt: now)
            }
            if let id = current?.requestID { known.insert(id) }
            return result
        }

        let record = Fixture.intent(.record)
        TestSupport.expectEqual(step(record), .start(Fixture.requestID))
        for _ in 0..<3 { TestSupport.expectEqual(step(record), .none) }
        current?.phase = .recording   // the first buffer arrived

        now += 5
        let finish = Fixture.intent(.finish, at: now)
        TestSupport.expectEqual(step(finish), .finish(Fixture.requestID))
        TestSupport.expectEqual(step(finish), .none)
        current?.phase = .completed
        TestSupport.expectEqual(step(finish), .none)
        TestSupport.expectEqual(step(record), .none)

        let unknown = Fixture.intent(.finish, Fixture.otherRequestID, at: now)
        TestSupport.expectEqual(step(unknown), .none)   // known from before
        let stranger = UUID(uuidString: "00000000-0000-4000-8000-0000000000F1")!
        TestSupport.expectEqual(step(Fixture.intent(.finish, stranger, at: now)), .reject(stranger, .notRecording))
        TestSupport.expectEqual(step(Fixture.intent(.finish, stranger, at: now)), .none)

        let backgroundRecord = UUID(uuidString: "00000000-0000-4000-8000-0000000000F2")!
        let intent = Fixture.intent(.record, backgroundRecord, at: now)
        current = nil
        known.remove(backgroundRecord)
        let rejection = HostReconciler.action(intent: .value(intent), current: current, knownRequestIDs: known,
                                              isForeground: false, sessionActive: false, now: now)
        TestSupport.expectEqual(rejection, .reject(backgroundRecord, .sessionInactive))
        known.insert(backgroundRecord)
        // Once rejected and known, bringing the app forward does not resurrect the request.
        TestSupport.expectEqual(step(intent, isForeground: true), .none)
    }
}
