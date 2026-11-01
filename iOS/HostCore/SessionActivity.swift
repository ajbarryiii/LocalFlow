import Foundation

/// The host state the session's Live Activity follows (ARCHITECTURE.md, "Live Activity"). Content-free.
struct SessionActivityInput: Equatable, Sendable {
    var sessionID: UUID?
    var session: HostStatus.Session
    var sessionExpiresAt: Date?
    var dictation: DictationStatus?
    var model: HostStatus.Model
}

/// One content update: the state and when the system should treat it as out of date.
struct SessionActivityContent: Equatable, Sendable {
    var state: SessionActivityState
    var staleDate: Date
}

/// ActivityKit, behind the thinnest seam: `LiveActivityBackend` (App) in the app, a fake in the tests.
@MainActor
protocol SessionActivityBackend: AnyObject {
    /// The user's Live Activities switch for the app.
    var areActivitiesEnabled: Bool { get }
    /// Ends, at once, every activity an earlier run left behind.
    func endLeftovers()
    /// Requests the activity; false when the system refuses.
    func start(_ content: SessionActivityContent) -> Bool
    /// Updates the activity this run started, without an alert.
    func update(_ content: SessionActivityContent)
    /// Ends the activity this run started and removes it at once.
    func end()
}

/// Which state the activity shows for the host's state, and when that state goes stale. Pure.
enum SessionActivityPolicy {
    /// How long after the session would have ended, or a recording been cut off, a killed app's activity turns stale.
    static let staleGrace: TimeInterval = 30
    /// When a wait (transcribing, preparing) or a ready state without an expiry turns stale.
    static let waitStaleInterval: TimeInterval = 300
    /// A wait shows at least this long before it gives way to anything but a recording, so a fast transcription reads
    /// as a beat rather than a flicker.
    static let minimumWaitDisplay: TimeInterval = 0.5

    /// Nil: no activity. Only an active session shows: a starting one has no capture yet and may still fail.
    static func state(for input: SessionActivityInput) -> SessionActivityState? {
        guard input.session == .active else { return nil }
        switch input.dictation?.phase {
        case .starting?, .recording?:
            return SessionActivityState(phase: .recording, endsAt: nil, since: input.dictation?.startedAt)
        case .transcribing?:
            return SessionActivityState(phase: input.model == .preparing ? .preparing : .transcribing, endsAt: nil, since: nil)
        case .completed?, .failed?, .cancelled?, nil:
            return SessionActivityState(phase: .ready, endsAt: input.sessionExpiresAt, since: nil)
        }
    }

    static func staleDate(for state: SessionActivityState, now: Date) -> Date {
        switch state.phase {
        case .ready:
            return state.endsAt.map { $0 + staleGrace } ?? now + waitStaleInterval
        case .recording:
            return (state.since ?? now) + DictationProtocol.maxDictationDuration + staleGrace
        case .transcribing, .preparing:
            return now + waitStaleInterval
        }
    }

    static func isWait(_ phase: SessionActivityState.Phase) -> Bool { phase == .transcribing || phase == .preparing }
}

/// Starts, updates and ends the session's Live Activity (ARCHITECTURE.md, "Live Activity"). The controller calls
/// `sync` after every status change and on its tick; the driver touches the backend only when what the activity
/// shows changes: never for levels or heartbeats.
@MainActor
final class SessionActivityDriver {
    private let backend: SessionActivityBackend
    private var launched = false
    /// The session whose activity this run shows, and what it shows.
    private var shown: (sessionID: UUID?, content: SessionActivityContent, at: Date)?
    /// A session whose start the system refused: not asked again.
    private var refusedSessionID: UUID?

    init(backend: SessionActivityBackend) {
        self.backend = backend
    }

    /// Once, at launch, before any session can start.
    func launch() {
        guard !launched else { return }
        launched = true
        backend.endLeftovers()
    }

    func sync(_ input: SessionActivityInput, isForeground: Bool, now: Date) {
        let desired = SessionActivityPolicy.state(for: input)
        if let current = shown, desired == nil || current.sessionID != input.sessionID {
            backend.end()
            shown = nil
        }
        guard let desired else { return }
        if let current = shown {
            guard current.content.state != desired else { return }
            if SessionActivityPolicy.isWait(current.content.state.phase), desired.phase != .recording,
               now < current.at + SessionActivityPolicy.minimumWaitDisplay {
                return   // held; a later tick applies it
            }
            let content = SessionActivityContent(state: desired, staleDate: SessionActivityPolicy.staleDate(for: desired, now: now))
            backend.update(content)
            shown = (input.sessionID, content, now)
            return
        }
        // ActivityKit starts an activity only in the foreground. Switched off or refused: nothing, and no prompt.
        guard isForeground, refusedSessionID != input.sessionID, backend.areActivitiesEnabled else { return }
        let content = SessionActivityContent(state: desired, staleDate: SessionActivityPolicy.staleDate(for: desired, now: now))
        if backend.start(content) {
            shown = (input.sessionID, content, now)
        } else {
            refusedSessionID = input.sessionID
        }
    }
}
