import Foundation

enum HostDictationSlotTests {
    static var tests: [TestCase] {
        [
            ("recoveredRequestIsTerminal", testRecoveredRequestIsTerminal),
            ("lifecycleToCompleted", testLifecycleToCompleted),
            ("staleGenerationCannotMarkRecording", testStaleGenerationCannotMarkRecording),
            ("staleTicketCannotEnd", testStaleTicketCannotEnd),
            ("readmittedRequestGetsANewTicket", testReadmittedRequestGetsANewTicket),
            ("rejectionNeverHidesARequestInProgress", testRejectionNeverHidesARequestInProgress),
        ]
    }

    private static let now = Fixture.now

    private static func testRecoveredRequestIsTerminal() {
        let interrupted = Fixture.dictation(.failed, hostRunID: Fixture.otherHostRunID, error: .interrupted)
        let slot = HostDictationSlot(hostRunID: Fixture.hostRunID, recovered: interrupted)
        TestSupport.expectEqual(slot.current, interrupted)
        TestSupport.expect(!slot.isInProgress, "a recovered request is in progress")
        // Defensive: a non-terminal record is never adopted as in progress.
        let odd = HostDictationSlot(hostRunID: Fixture.hostRunID, recovered: Fixture.dictation(.recording))
        TestSupport.expectEqual(odd.current, nil)
    }

    private static func testLifecycleToCompleted() {
        var slot = HostDictationSlot(hostRunID: Fixture.hostRunID)
        let ticket = slot.admit(Fixture.requestID, generation: 4, now: now)
        TestSupport.expectEqual(ticket, DictationTicket(hostRunID: Fixture.hostRunID, requestID: Fixture.requestID, generation: 4))
        TestSupport.expectEqual(slot.current, Fixture.dictation(.starting, startedAt: now, updatedAt: now))
        TestSupport.expect(slot.isInProgress && slot.isCurrent(ticket), "admitted request is not current")
        TestSupport.expect(!slot.markTranscribing(ticket, now: now), "transcribing before recording")
        TestSupport.expect(slot.markRecording(generation: 4, now: now + 1), "first buffer ignored")
        TestSupport.expect(!slot.markRecording(generation: 4, now: now + 2), "recording marked twice")
        TestSupport.expect(slot.markTranscribing(ticket, now: now + 3), "finish ignored")
        TestSupport.expect(slot.end(ticket, .completed, now: now + 4), "completion ignored")
        TestSupport.expectEqual(slot.current, Fixture.dictation(.completed, startedAt: now, updatedAt: now + 4))
        TestSupport.expect(!slot.isInProgress && !slot.isCurrent(ticket), "completed request still in progress")
        TestSupport.expect(!slot.end(ticket, .failed, error: .transcriptionFailed, now: now + 5), "ended twice")
        TestSupport.expectEqual(slot.phase, .completed)
    }

    private static func testStaleGenerationCannotMarkRecording() {
        var slot = HostDictationSlot(hostRunID: Fixture.hostRunID)
        let first = slot.admit(Fixture.requestID, generation: 1, now: now)
        slot.end(first, .cancelled, error: .superseded, now: now)
        _ = slot.admit(Fixture.otherRequestID, generation: 2, now: now)
        // The superseded recording's first buffer arrives late.
        TestSupport.expect(!slot.markRecording(generation: 1, now: now + 1), "stale first buffer accepted")
        TestSupport.expectEqual(slot.phase, .starting)
        TestSupport.expect(slot.markRecording(generation: 2, now: now + 1), "current first buffer ignored")
    }

    private static func testStaleTicketCannotEnd() {
        var slot = HostDictationSlot(hostRunID: Fixture.hostRunID)
        let first = slot.admit(Fixture.requestID, generation: 1, now: now)
        _ = slot.markRecording(generation: 1, now: now)
        _ = slot.markTranscribing(first, now: now)
        slot.end(first, .cancelled, error: .superseded, now: now + 1)
        let second = slot.admit(Fixture.otherRequestID, generation: 2, now: now + 1)
        // The superseded transcription finishes afterwards: its outcome is discarded.
        TestSupport.expect(!slot.end(first, .completed, now: now + 2), "stale completion published")
        TestSupport.expectEqual(slot.current?.requestID, Fixture.otherRequestID)
        TestSupport.expectEqual(slot.phase, .starting)
        TestSupport.expect(slot.isCurrent(second), "current request lost")
    }

    private static func testReadmittedRequestGetsANewTicket() {
        // The reconciler never restarts a request, but the fence must not rely on that.
        var slot = HostDictationSlot(hostRunID: Fixture.hostRunID)
        let first = slot.admit(Fixture.requestID, generation: 1, now: now)
        slot.end(first, .cancelled, now: now)
        let second = slot.admit(Fixture.requestID, generation: 2, now: now)
        TestSupport.expect(first != second, "same ticket for two recordings")
        TestSupport.expect(!slot.end(first, .completed, now: now), "an older recording's ticket ended the newer one")
    }

    private static func testRejectionNeverHidesARequestInProgress() {
        var slot = HostDictationSlot(hostRunID: Fixture.hostRunID)
        TestSupport.expect(slot.reject(Fixture.requestID, error: .sessionInactive, now: now), "idle rejection unpublished")
        TestSupport.expectEqual(slot.current, Fixture.dictation(.failed, error: .sessionInactive, startedAt: now, updatedAt: now))
        TestSupport.expect(!slot.isInProgress, "rejection in progress")
        let ticket = slot.admit(Fixture.otherRequestID, generation: 1, now: now)
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing] {
            switch phase {
            case .recording: _ = slot.markRecording(generation: 1, now: now)
            case .transcribing: _ = slot.markTranscribing(ticket, now: now)
            default: break
            }
            TestSupport.expect(!slot.reject(Fixture.requestID, error: .notRecording, now: now), "rejection hid \(phase)")
            TestSupport.expectEqual(slot.current?.requestID, Fixture.otherRequestID)
            TestSupport.expectEqual(slot.phase, phase)
        }
        slot.end(ticket, .completed, now: now)
        TestSupport.expect(slot.reject(Fixture.requestID, error: .notRecording, now: now), "rejection after completion unpublished")
    }
}
