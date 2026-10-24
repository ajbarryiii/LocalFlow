import Foundation

/// The keyboard lists and decodes result files only when a result may have arrived or a known file
/// needs cleaning up; every other pass decides from the copy in memory.
enum KeyboardResultInboxTests {
    static var tests: [TestCase] {
        [
            ("firstPassReads", testFirstPassReads),
            ("statusPassesDoNotReadFiles", testStatusPassesDoNotReadFiles),
            ("resultPostedReadsEveryFile", testResultPostedReadsEveryFile),
            ("hidingDropsTranscriptsAndReadsOnAppearance", testHidingDropsTranscriptsAndReadsOnAppearance),
            ("reportedCompletionReadsOnce", testReportedCompletionReadsOnce),
            ("newHostRunReads", testNewHostRunReads),
            ("expiryPurgesOnTheReadPath", testExpiryPurgesOnTheReadPath),
            ("undecodedFilesAreRetriedAndPurged", testUndecodedFilesAreRetriedAndPurged),
            ("clockMovedBackReads", testClockMovedBackReads),
            ("deferredResultIsInsertedFromMemory", testDeferredResultIsInsertedFromMemory),
            ("oneResultPerPassFromMemory", testOneResultPerPassFromMemory),
            ("manualOfferSurvivesStatusPasses", testManualOfferSurvivesStatusPasses),
            ("discardedResultNoLongerSchedulesExpiry", testDiscardedResultNoLongerSchedulesExpiry),
        ]
    }

    private static let thirdRequestID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private static let recording = StoreRead<HostStatus>.value(Fixture.status(dictation: Fixture.dictation(.recording)))

    private static func withStore(_ body: (SharedDictationStore) -> Void) {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        body(SharedDictationStore(directory: directory))
    }

    private static func completed(_ requestID: UUID, hostRunID: UUID = Fixture.hostRunID) -> StoreRead<HostStatus> {
        var status = Fixture.status(dictation: Fixture.dictation(.completed, requestID, hostRunID: hostRunID))
        status.hostRunID = hostRunID
        return .value(status)
    }

    private static func testFirstPassReads() {
        // A new instance (or one that just appeared) has never looked, whatever the status says.
        TestSupport.expectEqual(KeyboardResultInbox().readReason(status: .absent, now: Fixture.now), .firstRead)
        TestSupport.expectEqual(KeyboardResultInbox().readReason(status: recording, now: Fixture.now), .firstRead)
        withStore { store in
            var inbox = KeyboardResultInbox()
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: Fixture.now), .firstRead)
            TestSupport.expectEqual(inbox.results, [])
            // Nothing on disk and nothing reported: later passes do not read.
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: Fixture.now + 30), nil)
        }
    }

    private static func testStatusPassesDoNotReadFiles() {
        withStore { store in
            let first = Fixture.result(Fixture.requestID, createdAt: Fixture.now)
            try! store.writeResult(first)
            var inbox = KeyboardResultInbox()
            TestSupport.expectEqual(inbox.update(from: store, status: recording, now: Fixture.now), .firstRead)
            TestSupport.expectEqual(inbox.results, [first])
            // A file written without a `.result` (or a reported completion) is not seen by status or
            // poll passes: they decide from memory.
            try! store.writeResult(Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now + 1))
            for tick in 1...50 {
                let now = Fixture.now + Double(tick) * 0.2
                TestSupport.expectEqual(inbox.update(from: store, status: recording, now: now), nil)
            }
            TestSupport.expectEqual(inbox.results, [first])
        }
    }

    private static func testResultPostedReadsEveryFile() {
        withStore { store in
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: recording, now: Fixture.now)
            // Darwin notifications coalesce: one delivery for two results still finds both.
            let first = Fixture.result(Fixture.requestID, createdAt: Fixture.now + 1)
            let second = Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now + 2)
            try! store.writeResult(first)
            try! store.writeResult(second)
            inbox.resultPosted()
            TestSupport.expectEqual(inbox.readReason(status: recording, now: Fixture.now + 3), .resultPosted)
            TestSupport.expectEqual(inbox.update(from: store, status: recording, now: Fixture.now + 3), .resultPosted)
            TestSupport.expectEqual(Set(inbox.results.map(\.requestID)), [Fixture.requestID, Fixture.otherRequestID])
            // The notification is consumed by that read.
            TestSupport.expectEqual(inbox.update(from: store, status: recording, now: Fixture.now + 3.2), nil)
            // A spurious post (any process can post) only costs a read.
            inbox.resultPosted()
            TestSupport.expectEqual(inbox.update(from: store, status: recording, now: Fixture.now + 3.4), .resultPosted)
            TestSupport.expectEqual(inbox.results.count, 2)
        }
    }

    private static func testHidingDropsTranscriptsAndReadsOnAppearance() {
        withStore { store in
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: .absent, now: Fixture.now)
            try! store.writeResult(Fixture.result())
            inbox.resultPosted()
            inbox.update(from: store, status: .absent, now: Fixture.now + 1)
            TestSupport.expectEqual(inbox.results.count, 1)
            // Hidden: no transcript stays in memory, and the next appearance reads again, since
            // notifications are not observed while hidden.
            inbox.reset()
            TestSupport.expectEqual(inbox, KeyboardResultInbox())
            TestSupport.expectEqual(inbox.results, [])
            let missed = Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now + 2)
            try! store.writeResult(missed)
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: Fixture.now + 3), .firstRead)
            TestSupport.expectEqual(Set(inbox.results.map(\.requestID)), [Fixture.requestID, Fixture.otherRequestID])
        }
    }

    /// The host writes `result-R.json` before it publishes R as completed, so a reported completion of
    /// a request the last read did not list means a result arrived, even if its `.result` was missed.
    private static func testReportedCompletionReadsOnce() {
        withStore { store in
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: recording, now: Fixture.now)
            let result = Fixture.result(createdAt: Fixture.now + 1)
            try! store.writeResult(result)
            TestSupport.expectEqual(inbox.readReason(status: completed(Fixture.requestID), now: Fixture.now + 1.2),
                                    .completionReported)
            TestSupport.expectEqual(inbox.update(from: store, status: completed(Fixture.requestID), now: Fixture.now + 1.2),
                                    .completionReported)
            TestSupport.expectEqual(inbox.results, [result])
            // The status keeps reporting R: no further reads, even once R's file is gone.
            _ = store.removeResult(requestID: Fixture.requestID)
            inbox.discard([Fixture.requestID])
            for tick in 1...20 {
                TestSupport.expectEqual(inbox.update(from: store, status: completed(Fixture.requestID),
                                                     now: Fixture.now + 1.2 + Double(tick) * 0.2), nil)
            }
            // A completion the triggering read already listed costs nothing extra.
            let next = Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now + 10)
            try! store.writeResult(next)
            inbox.resultPosted()
            inbox.update(from: store, status: recording, now: Fixture.now + 10)
            TestSupport.expectEqual(inbox.readReason(status: completed(Fixture.otherRequestID), now: Fixture.now + 10.2), nil)
            // A completion seen while its file was already claimed elsewhere is read for once.
            var other = KeyboardResultInbox()
            other.update(from: store, status: recording, now: Fixture.now + 10)
            _ = store.removeResult(requestID: Fixture.otherRequestID)
            TestSupport.expectEqual(other.readReason(status: completed(thirdRequestID), now: Fixture.now + 11),
                                    .completionReported)
            other.update(from: store, status: completed(thirdRequestID), now: Fixture.now + 11)
            TestSupport.expectEqual(other.readReason(status: completed(thirdRequestID), now: Fixture.now + 11.2), nil)
            // Other phases never trigger a read.
            for phase: DictationStatus.Phase in [.starting, .recording, .transcribing, .failed, .cancelled] {
                let status = StoreRead<HostStatus>.value(Fixture.status(dictation: Fixture.dictation(phase, thirdRequestID)))
                TestSupport.expectEqual(other.readReason(status: status, now: Fixture.now + 11.4), nil)
            }
        }
    }

    /// A new host run deletes the previous runs' results at launch, before it publishes its status.
    private static func testNewHostRunReads() {
        withStore { store in
            let old = Fixture.result(hostRunID: Fixture.hostRunID)
            try! store.writeResult(old)
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: recording, now: Fixture.now)
            TestSupport.expectEqual(inbox.results, [old])
            store.purgeResults { _, read in read.value?.hostRunID != Fixture.otherHostRunID }
            var relaunched = Fixture.status(.active)
            relaunched.hostRunID = Fixture.otherHostRunID
            TestSupport.expectEqual(inbox.update(from: store, status: .value(relaunched), now: Fixture.now + 1),
                                    .hostRunChanged)
            TestSupport.expectEqual(inbox.results, [])
            TestSupport.expectEqual(inbox.update(from: store, status: .value(relaunched), now: Fixture.now + 1.2), nil)
            // A status that cannot be read says nothing about the run.
            TestSupport.expectEqual(inbox.update(from: store, status: .unreadable, now: Fixture.now + 1.4), nil)
            TestSupport.expectEqual(inbox.update(from: store, status: .value(relaunched), now: Fixture.now + 1.6), nil)
            // The first status after a read that saw none names a run that may have purged.
            var fresh = KeyboardResultInbox()
            fresh.update(from: store, status: .absent, now: Fixture.now + 2)
            TestSupport.expectEqual(fresh.readReason(status: .value(relaunched), now: Fixture.now + 2.2), .hostRunChanged)
        }
    }

    /// Purging moves to the read path: a known file is purged right after it expires.
    private static func testExpiryPurgesOnTheReadPath() {
        withStore { store in
            let result = Fixture.result(createdAt: Fixture.now)
            try! store.writeResult(result)
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: .absent, now: Fixture.now)
            let ttl = DictationProtocol.resultTTL
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: Fixture.now + ttl), nil)
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: Fixture.now + ttl + 0.1), .expiry)
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: Fixture.now + ttl + 0.1), .expiry)
            TestSupport.expectEqual(store.resultRequestIDs(), [])
            TestSupport.expectEqual(inbox.results, [])
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: Fixture.now + ttl + 10), nil)
            // An expired file present at the first read is purged by that read and never cached.
            try! store.writeResult(Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now))
            var late = KeyboardResultInbox()
            late.update(from: store, status: .absent, now: Fixture.now + ttl + 20)
            TestSupport.expectEqual(store.resultRequestIDs(), [])
            TestSupport.expectEqual(late.results, [])
        }
    }

    private static func testUndecodedFilesAreRetriedAndPurged() {
        withStore { store in
            // Undecodable files are judged by their modification date, so this test follows the wall clock.
            let now = Date()
            try! store.writeResult(Fixture.result(createdAt: now))
            // A corrupt file (or one the device lock keeps unreadable) and a future-schema file.
            try! Data("{".utf8).write(to: store.resultURL(for: Fixture.otherRequestID))
            try! Data(#"{"schema":999}"#.utf8).write(to: store.resultURL(for: thirdRequestID))
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: .absent, now: now)
            TestSupport.expectEqual(inbox.results.map(\.requestID), [Fixture.requestID])
            // An unreadable file may become readable, so it is retried on a slow cadence, not per pass.
            let retry = KeyboardResultInbox.unreadableRetryInterval
            TestSupport.expect(retry >= 1, "retry cadence too fast")
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: now + retry - 0.1), nil)
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: now + retry), .unreadableRetry)
            let fixed = Fixture.result(Fixture.otherRequestID, createdAt: now)
            try! store.writeResult(fixed)
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: now + retry), .unreadableRetry)
            TestSupport.expectEqual(Set(inbox.results.map(\.requestID)), [Fixture.requestID, Fixture.otherRequestID])
            // A future-schema file is not retried, but is still purged once it can have expired.
            let ttl = DictationProtocol.resultTTL
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: now + retry * 3), nil)
            inbox.discard([Fixture.requestID, Fixture.otherRequestID])
            _ = store.removeResult(requestID: Fixture.requestID)
            _ = store.removeResult(requestID: Fixture.otherRequestID)
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: now + retry + ttl), nil)
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: now + retry + ttl + 0.1), .expiry)
        }
    }

    private static func testClockMovedBackReads() {
        withStore { store in
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: .absent, now: Fixture.now)
            let tolerance = DictationProtocol.clockSkewTolerance
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: Fixture.now - tolerance), nil)
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: Fixture.now - tolerance - 0.1), .clockMovedBack)
        }
    }

    /// A result that cannot be inserted on the pass that read it (a trackpad gesture is running) is
    /// inserted on a later pass from memory, without reading again.
    private static func testDeferredResultIsInsertedFromMemory() {
        withStore { store in
            var ledger = KeyboardResultLedger()
            ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: recording, now: Fixture.now)
            let result = Fixture.result(createdAt: Fixture.now + 1)
            try! store.writeResult(result)
            inbox.resultPosted()
            inbox.update(from: store, status: recording, now: Fixture.now + 1)
            // Busy: nothing is claimed on this pass.
            for tick in 1...10 {
                let now = Fixture.now + 1 + Double(tick) * 0.2
                TestSupport.expectEqual(inbox.update(from: store, status: completed(Fixture.requestID), now: now), nil)
                TestSupport.expectEqual(ledger.plan(for: inbox.results, documentID: Fixture.documentA, now: now).autoInsert,
                                        [result])
            }
            TestSupport.expect(ledger.claim(requestID: Fixture.requestID, in: store), "claim from memory failed")
            inbox.discard(ledger.consumed)
            TestSupport.expectEqual(inbox.results, [])
            TestSupport.expectEqual(ledger.plan(for: inbox.results, documentID: Fixture.documentA, now: Fixture.now + 4),
                                    ResultPlan())
        }
    }

    /// At most one result per pass, oldest first: the rest wait in memory for later passes, each bound
    /// again before it is claimed.
    private static func testOneResultPerPassFromMemory() {
        withStore { store in
            var ledger = KeyboardResultLedger()
            ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            ledger.bindFinish(requestID: Fixture.otherRequestID, documentID: Fixture.documentA)
            let older = Fixture.result(Fixture.requestID, createdAt: Fixture.now + 1)
            let newer = Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now + 2)
            try! store.writeResult(newer)
            try! store.writeResult(older)
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: .absent, now: Fixture.now + 3)
            var inserted: [UUID] = []
            for tick in 0..<4 {
                let now = Fixture.now + 3 + Double(tick) * 0.2
                TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: now), nil)
                if let next = ledger.plan(for: inbox.results, documentID: Fixture.documentA, now: now).autoInsert.first,
                   ledger.claim(requestID: next.requestID, in: store) {
                    inserted.append(next.requestID)
                }
                inbox.discard(ledger.consumed)
            }
            TestSupport.expectEqual(inserted, [Fixture.requestID, Fixture.otherRequestID])
            TestSupport.expectEqual(store.resultRequestIDs(), [])
            // A field change between passes leaves the remaining result for the chip, still from memory.
            var moved = KeyboardResultLedger()
            moved.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            moved.bindFinish(requestID: Fixture.otherRequestID, documentID: Fixture.documentA)
            try! store.writeResult(older)
            try! store.writeResult(newer)
            var again = KeyboardResultInbox()
            again.update(from: store, status: .absent, now: Fixture.now + 3)
            let first = moved.plan(for: again.results, documentID: Fixture.documentA, now: Fixture.now + 3).autoInsert.first
            TestSupport.expectEqual(first, older)
            TestSupport.expect(moved.claim(requestID: older.requestID, in: store), "claim")
            again.discard(moved.consumed)
            moved.documentChanged(to: Fixture.documentB)
            TestSupport.expectEqual(again.update(from: store, status: .absent, now: Fixture.now + 3.2), nil)
            let plan = moved.plan(for: again.results, documentID: Fixture.documentB, now: Fixture.now + 3.2)
            TestSupport.expectEqual(plan.autoInsert, [])
            TestSupport.expectEqual(plan.manualInsert, newer)
        }
    }

    private static func testManualOfferSurvivesStatusPasses() {
        withStore { store in
            let result = Fixture.result(createdAt: Fixture.now)
            try! store.writeResult(result)
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: recording, now: Fixture.now)
            let ledger = KeyboardResultLedger()
            for tick in 0..<20 {
                let now = Fixture.now + Double(tick) * 0.2
                TestSupport.expectEqual(inbox.update(from: store, status: recording, now: now), nil)
                TestSupport.expectEqual(ledger.plan(for: inbox.results, documentID: Fixture.documentB, now: now).manualInsert,
                                        result)
            }
            // Past the insertion window it is no longer offered, and the expiry read drops it.
            let ttl = DictationProtocol.resultTTL
            TestSupport.expectEqual(inbox.update(from: store, status: .absent, now: Fixture.now + ttl + 0.2), .expiry)
            TestSupport.expectEqual(ledger.plan(for: inbox.results, documentID: Fixture.documentB,
                                                now: Fixture.now + ttl + 0.2).manualInsert, nil)
        }
    }

    private static func testDiscardedResultNoLongerSchedulesExpiry() {
        withStore { store in
            try! store.writeResult(Fixture.result(createdAt: Fixture.now))
            var inbox = KeyboardResultInbox()
            inbox.update(from: store, status: .absent, now: Fixture.now)
            var ledger = KeyboardResultLedger()
            TestSupport.expect(ledger.claim(requestID: Fixture.requestID, in: store), "claim")
            inbox.discard(ledger.consumed)
            // Discarding something not cached is a no-op.
            inbox.discard([thirdRequestID])
            TestSupport.expectEqual(inbox.results, [])
            TestSupport.expectEqual(inbox.readReason(status: .absent, now: Fixture.now + DictationProtocol.resultTTL + 1), nil)
        }
    }
}
