import Foundation

enum KeyboardResultLedgerTests {
    static var tests: [TestCase] {
        [
            ("unboundResultIsOfferedManually", testUnboundResultIsOfferedManually),
            ("finishBindsToCurrentField", testFinishBindsToCurrentField),
            ("displayingBindsForAutoFinish", testDisplayingBindsForAutoFinish),
            ("onlyRecordingOrTranscribingBinds", testOnlyRecordingOrTranscribingBinds),
            ("focusChangeInvalidatesBinding", testFocusChangeInvalidatesBinding),
            ("explicitFinishRebindsAfterInvalidation", testExplicitFinishRebindsAfterInvalidation),
            ("nilDocumentNeverAutoInserts", testNilDocumentNeverAutoInserts),
            ("resultTTLAndSkew", testResultTTLAndSkew),
            ("unknownSchemaIsIgnored", testUnknownSchemaIsIgnored),
            ("consumedIsNeverInsertedAgain", testConsumedIsNeverInsertedAgain),
            ("planOrdersAndPicksNewestForChip", testPlanOrdersAndPicksNewestForChip),
            ("claimByDeleteWinsOnce", testClaimByDeleteWinsOnce),
            ("fieldSwitchMidRequest", testFieldSwitchMidRequest),
        ]
    }

    private static func disposition(_ ledger: KeyboardResultLedger, _ result: DictationResult = Fixture.result(),
                                    documentID: UUID? = Fixture.documentA,
                                    now: Date = Fixture.now) -> KeyboardResultLedger.Disposition {
        ledger.disposition(of: result, documentID: documentID, now: now)
    }

    private static func withStore(_ body: (SharedDictationStore) -> Void) {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        body(SharedDictationStore(directory: directory))
    }

    private static func testUnboundResultIsOfferedManually() {
        // A newly created keyboard in another field never auto-inserts someone else's transcript.
        TestSupport.expectEqual(disposition(KeyboardResultLedger()), .offerManualInsert)
    }

    private static func testFinishBindsToCurrentField() {
        var ledger = KeyboardResultLedger()
        ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
        TestSupport.expectEqual(disposition(ledger), .autoInsert)
        TestSupport.expectEqual(disposition(ledger, documentID: Fixture.documentB), .offerManualInsert)
        TestSupport.expectEqual(disposition(ledger, Fixture.result(Fixture.otherRequestID)), .offerManualInsert)
    }

    private static func testDisplayingBindsForAutoFinish() {
        // The host auto-finished at the maximum duration, or another instance wrote the finish.
        for shown in [KeyboardMode.recording(level: 0.3, startedAt: Fixture.now), .transcribing] {
            var ledger = KeyboardResultLedger()
            ledger.noteDisplayed(shown, intent: .value(Fixture.intent(.record)), documentID: Fixture.documentA)
            TestSupport.expectEqual(ledger.bindings, [Fixture.requestID: Fixture.documentA])
            TestSupport.expectEqual(disposition(ledger), .autoInsert)
        }
    }

    private static func testOnlyRecordingOrTranscribingBinds() {
        let modes: [KeyboardMode] = [.needsFullAccess, .configurationError, .incompatible, .starting,
                                     .error(.tooLong), .ready, .hostUnavailable]
        for shown in modes {
            var ledger = KeyboardResultLedger()
            ledger.noteDisplayed(shown, intent: .value(Fixture.intent(.record)), documentID: Fixture.documentA)
            TestSupport.expectEqual(ledger.bindings, [:])
        }
        var ledger = KeyboardResultLedger()
        for read in [StoreRead<KeyboardIntent>.absent, .incompatible, .unreadable] {
            ledger.noteDisplayed(.transcribing, intent: read, documentID: Fixture.documentA)
        }
        TestSupport.expectEqual(ledger.bindings, [:])
    }

    private static func testFocusChangeInvalidatesBinding() {
        var ledger = KeyboardResultLedger()
        ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
        ledger.bindFinish(requestID: Fixture.otherRequestID, documentID: Fixture.documentB)
        ledger.documentChanged(to: Fixture.documentA)   // textDidChange in the same field
        TestSupport.expectEqual(ledger.bindings, [Fixture.requestID: Fixture.documentA])
        ledger.documentChanged(to: Fixture.documentB)
        TestSupport.expectEqual(ledger.bindings, [:])
        TestSupport.expectEqual(disposition(ledger, documentID: Fixture.documentB), .offerManualInsert)
        // Returning to the original field does not restore the binding.
        ledger.documentChanged(to: Fixture.documentA)
        TestSupport.expectEqual(disposition(ledger, documentID: Fixture.documentA), .offerManualInsert)
        // Still displaying the request in the new field does not rebind it there.
        ledger.noteDisplayed(.transcribing, intent: .value(Fixture.intent(.finish)), documentID: Fixture.documentA)
        TestSupport.expectEqual(disposition(ledger, documentID: Fixture.documentA), .offerManualInsert)
    }

    private static func testExplicitFinishRebindsAfterInvalidation() {
        var ledger = KeyboardResultLedger()
        ledger.noteDisplayed(.recording(level: 0, startedAt: Fixture.now), intent: .value(Fixture.intent(.record)),
                             documentID: Fixture.documentA)
        ledger.documentChanged(to: Fixture.documentB)
        // The user tapped stop while in field B: B is where they want the text.
        ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentB)
        TestSupport.expectEqual(disposition(ledger, documentID: Fixture.documentB), .autoInsert)
        TestSupport.expectEqual(ledger.invalidated, [])
    }

    private static func testNilDocumentNeverAutoInserts() {
        var ledger = KeyboardResultLedger()
        ledger.bindFinish(requestID: Fixture.requestID, documentID: nil)
        ledger.noteDisplayed(.transcribing, intent: .value(Fixture.intent(.finish)), documentID: nil)
        TestSupport.expectEqual(ledger.bindings, [:])
        TestSupport.expectEqual(disposition(ledger, documentID: nil), .offerManualInsert)
        ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
        TestSupport.expectEqual(disposition(ledger, documentID: nil), .offerManualInsert)
        ledger.documentChanged(to: nil)
        TestSupport.expectEqual(ledger.bindings, [:])
    }

    private static func testResultTTLAndSkew() {
        let ttl = DictationProtocol.resultTTL
        let tolerance = DictationProtocol.clockSkewTolerance
        var ledger = KeyboardResultLedger()
        ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
        TestSupport.expectEqual(disposition(ledger, now: Fixture.now + ttl), .autoInsert)
        TestSupport.expectEqual(disposition(ledger, now: Fixture.now + ttl + 0.001), .ignore)
        TestSupport.expectEqual(disposition(ledger, now: Fixture.now - tolerance), .autoInsert)
        TestSupport.expectEqual(disposition(ledger, now: Fixture.now - tolerance - 0.001), .ignore)
        // Expired results are not offered manually either.
        TestSupport.expectEqual(disposition(KeyboardResultLedger(), now: Fixture.now + ttl + 1), .ignore)
    }

    private static func testUnknownSchemaIsIgnored() {
        var ledger = KeyboardResultLedger()
        ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
        var result = Fixture.result()
        result.schema = 2
        TestSupport.expectEqual(disposition(ledger, result), .ignore)
    }

    private static func testConsumedIsNeverInsertedAgain() {
        withStore { store in
            var ledger = KeyboardResultLedger()
            ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            try! store.writeResult(Fixture.result())
            TestSupport.expect(ledger.claim(requestID: Fixture.requestID, in: store), "claim failed")
            TestSupport.expectEqual(ledger.consumed, [Fixture.requestID])
            TestSupport.expectEqual(ledger.bindings, [:])
            // Even if the host wrote the same result again, this instance never inserts it twice.
            try! store.writeResult(Fixture.result())
            TestSupport.expectEqual(disposition(ledger), .ignore)
            TestSupport.expect(!ledger.claim(requestID: Fixture.requestID, in: store), "claimed twice")
            ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            ledger.noteDisplayed(.transcribing, intent: .value(Fixture.intent(.finish)), documentID: Fixture.documentA)
            TestSupport.expectEqual(ledger.bindings, [:])
        }
    }

    private static func testPlanOrdersAndPicksNewestForChip() {
        let ids = (1...4).map { UUID(uuidString: "00000000-0000-4000-8000-00000000020\($0)")! }
        var ledger = KeyboardResultLedger()
        ledger.bindFinish(requestID: ids[0], documentID: Fixture.documentA)
        ledger.bindFinish(requestID: ids[1], documentID: Fixture.documentA)
        let results = [
            Fixture.result(ids[1], createdAt: Fixture.now - 1),
            Fixture.result(ids[0], createdAt: Fixture.now - 5),
            Fixture.result(ids[2], createdAt: Fixture.now - 10),
            Fixture.result(ids[3], createdAt: Fixture.now - 3),
            Fixture.result(Fixture.otherRequestID, createdAt: Fixture.now - 600),   // expired
        ]
        let plan = ledger.plan(for: results, documentID: Fixture.documentA, now: Fixture.now)
        TestSupport.expectEqual(plan.autoInsert.map(\.requestID), [ids[0], ids[1]])
        TestSupport.expectEqual(plan.manualInsert?.requestID, ids[3])

        let elsewhere = ledger.plan(for: results, documentID: Fixture.documentB, now: Fixture.now)
        TestSupport.expectEqual(elsewhere.autoInsert, [])
        TestSupport.expectEqual(elsewhere.manualInsert?.requestID, ids[1])
        TestSupport.expectEqual(ledger.plan(for: [], documentID: Fixture.documentA, now: Fixture.now), ResultPlan())
    }

    /// Two instances (or the keyboard and the host's expiry purge) race for one result file.
    private static func testClaimByDeleteWinsOnce() {
        withStore { store in
            try! store.writeResult(Fixture.result())
            var bound = KeyboardResultLedger()
            bound.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            var other = KeyboardResultLedger()
            let result = store.readResult(requestID: Fixture.requestID).value!
            TestSupport.expectEqual(other.disposition(of: result, documentID: Fixture.documentB, now: Fixture.now),
                                    .offerManualInsert)
            TestSupport.expect(bound.claim(requestID: Fixture.requestID, in: store), "first claimant lost")
            TestSupport.expect(!other.claim(requestID: Fixture.requestID, in: store), "second claimant also won")
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .absent)

            // A result the host already purged cannot be claimed, and is consumed so it is not retried.
            try! store.writeResult(Fixture.result(Fixture.otherRequestID))
            store.purgeResults { _, _ in true }
            var late = KeyboardResultLedger()
            TestSupport.expect(!late.claim(requestID: Fixture.otherRequestID, in: store), "claimed a purged result")
            TestSupport.expectEqual(late.consumed, [Fixture.otherRequestID])
        }
    }

    /// The verification-plan scenario: dictate into field A, switch to field B while transcribing.
    private static func testFieldSwitchMidRequest() {
        withStore { store in
            var ledger = KeyboardResultLedger()
            let record = Fixture.intent(.record)
            ledger.documentChanged(to: Fixture.documentA)
            ledger.noteDisplayed(.recording(level: 0.5, startedAt: Fixture.now), intent: .value(record),
                                 documentID: Fixture.documentA)
            TestSupport.expect(KeyboardPresenter.mayWrite(.finish, requestID: Fixture.requestID, currentIntent: .value(record)),
                               "guard refused the current request")
            let finish = Fixture.intent(.finish, at: Fixture.now + 3)
            try! store.writeIntent(finish)
            ledger.bindFinish(requestID: Fixture.requestID, documentID: Fixture.documentA)
            ledger.documentChanged(to: Fixture.documentB)
            ledger.noteDisplayed(.transcribing, intent: .value(finish), documentID: Fixture.documentB)
            try! store.writeResult(Fixture.result(createdAt: Fixture.now + 4))

            let results = store.resultRequestIDs().compactMap { store.readResult(requestID: $0).value }
            let plan = ledger.plan(for: results, documentID: Fixture.documentB, now: Fixture.now + 5)
            TestSupport.expectEqual(plan.autoInsert, [])
            TestSupport.expectEqual(plan.manualInsert?.requestID, Fixture.requestID)
            // Tapping the chip claims the result and inserts it into B.
            TestSupport.expect(ledger.claim(requestID: Fixture.requestID, in: store), "chip claim failed")
            TestSupport.expectEqual(store.resultRequestIDs(), [])
        }
    }
}
