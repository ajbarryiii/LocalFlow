import Foundation

/// Names one admitted recording. Asynchronous work (startup, first buffer, transcription,
/// background-task expiry) captures the ticket and may publish only while it is still current.
struct DictationTicket: Hashable, Sendable {
    let hostRunID: UUID
    let requestID: UUID
    /// `DictationSampleBuffer.begin`'s generation, so a re-admitted or superseded request differs.
    let generation: UInt64
}

/// The host's single `dictation` slot in `status.json`, with the generation fence. Pure: the session
/// core applies every transition here, and an outcome whose ticket is no longer current is dropped.
struct HostDictationSlot: Equatable, Sendable {
    let hostRunID: UUID
    /// The latest dictation, in any phase; published as `HostStatus.dictation`.
    private(set) var current: DictationStatus?
    /// Set exactly while `current` is starting, recording or transcribing.
    private(set) var ticket: DictationTicket?

    /// `recovered` comes from `HostRunRecovery` and is terminal, so nothing is in progress.
    init(hostRunID: UUID, recovered: DictationStatus? = nil) {
        self.hostRunID = hostRunID
        current = recovered.flatMap { $0.phase.isTerminal ? $0 : nil }
    }

    var isInProgress: Bool { ticket != nil }

    var phase: DictationStatus.Phase? { current?.phase }

    func isCurrent(_ ticket: DictationTicket) -> Bool { self.ticket == ticket }

    /// The request is `starting`. The caller has already ended any request in progress (as superseded).
    mutating func admit(_ requestID: UUID, generation: UInt64, now: Date) -> DictationTicket {
        let ticket = DictationTicket(hostRunID: hostRunID, requestID: requestID, generation: generation)
        current = DictationStatus(requestID: requestID, hostRunID: hostRunID, phase: .starting, error: nil,
                                  startedAt: now, updatedAt: now)
        self.ticket = ticket
        return ticket
    }

    /// The first buffer of recording `generation` arrived. False when that recording is no longer starting.
    mutating func markRecording(generation: UInt64, now: Date) -> Bool {
        guard let ticket, ticket.generation == generation, current?.phase == .starting else { return false }
        set(.recording, error: nil, now: now)
        return true
    }

    mutating func markTranscribing(_ ticket: DictationTicket, now: Date) -> Bool {
        guard isCurrent(ticket), current?.phase == .recording else { return false }
        set(.transcribing, error: nil, now: now)
        return true
    }

    /// Moves the request to a terminal phase only if `ticket` is still current, so a late outcome of a
    /// superseded, cancelled or recovered request never overwrites the slot.
    @discardableResult
    mutating func end(_ ticket: DictationTicket, _ phase: DictationStatus.Phase, error: HostErrorCode? = nil,
                      now: Date) -> Bool {
        precondition(phase.isTerminal, "end needs a terminal phase")
        guard isCurrent(ticket) else { return false }
        set(phase, error: error, now: now)
        self.ticket = nil
        return true
    }

    /// Publishes a rejected request as failed, but only when nothing is in progress: the single slot
    /// must not hide a request that is starting, recording or transcribing. The caller marks the
    /// request known either way.
    @discardableResult
    mutating func reject(_ requestID: UUID, error: HostErrorCode, now: Date) -> Bool {
        guard ticket == nil else { return false }
        current = DictationStatus(requestID: requestID, hostRunID: hostRunID, phase: .failed, error: error,
                                  startedAt: now, updatedAt: now)
        return true
    }

    private mutating func set(_ phase: DictationStatus.Phase, error: HostErrorCode?, now: Date) {
        current?.phase = phase
        current?.error = error
        current?.updatedAt = now
    }
}
