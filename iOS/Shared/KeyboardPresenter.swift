import Foundation

enum KeyboardAccess: Equatable, Sendable {
    case fullAccess
    case noFullAccess
    /// `SharedDictationStore(configuration:)` returned nil: a missing entitlement or App Group.
    case containerUnavailable
}

enum KeyboardMode: Equatable, Sendable {
    case needsFullAccess
    case configurationError
    case incompatible              // the app and keyboard are different versions: "Update LocalFlow"
    case starting
    case recording(level: Float, startedAt: Date)
    case transcribing
    case waitingForModel           // the recording ended and waits for the host to prepare the model
    case error(HostErrorCode)
    case preparingModel            // as `ready`, but the model is preparing: a recording waits for it
    case ready
    case hostUnavailable           // a mic tap bounces, or shows instructions
}

/// Maps the shared files to what the keyboard shows. Pure: the keyboard calls it on every poll and
/// notification.
enum KeyboardPresenter {
    /// How long a failed request is reported; the view shows it once.
    static let errorDisplayDuration: TimeInterval = 5

    static func mode(access: KeyboardAccess, status: StoreRead<HostStatus>, intent: StoreRead<KeyboardIntent>,
                     now: Date) -> KeyboardMode {
        switch access {
        case .noFullAccess: return .needsFullAccess
        case .containerUnavailable: return .configurationError
        case .fullAccess: break
        }
        if status.isIncompatible || intent.isIncompatible { return .incompatible }

        let status = status.value.flatMap { $0.schema == DictationProtocol.schema ? $0 : nil }
        let intent = intent.value.flatMap { $0.schema == DictationProtocol.schema ? $0 : nil }
        let isHostAlive = status.map { isAlive($0, now: now) } ?? false
        // The intent, not the keyboard instance, names the request, so a keyboard created after the
        // bounce adopts the request its predecessor started.
        let dictation = intent.flatMap { intent in status?.dictation.flatMap { $0.requestID == intent.requestID ? $0 : nil } }

        if let dictation, isHostAlive {
            switch dictation.phase {
            case .starting: return .starting
            case .recording:
                let level = status?.level ?? 0
                return .recording(level: level.isFinite ? min(max(level, 0), 1) : 0, startedAt: dictation.startedAt)
            case .transcribing:
                // The model is not ready yet: the recording waits for its preparation.
                switch status?.model {
                case .preparing?, .notPrepared?: return .waitingForModel
                default: return .transcribing
                }
            case .completed, .failed, .cancelled: break
            }
        }
        if let dictation, dictation.phase == .failed || (dictation.phase == .cancelled && dictation.error != nil),
           DictationProtocol.isFresh(dictation.updatedAt, ttl: errorDisplayDuration, now: now) {
            return .error(dictation.error ?? .transcriptionFailed)
        }
        if let intent, intent.action == .record, dictation == nil,
           DictationProtocol.isFresh(intent.issuedAt, ttl: DictationProtocol.pendingRecordTTL, now: now) {
            return .starting
        }
        if isHostAlive, let status, status.captureReady {
            return status.model == .preparing ? .preparingModel : .ready
        }
        return .hostUnavailable
    }

    /// The mode the keyboard shows for `mode`: Start without a session stays Start (round 10, Opus round 9 finding 2:
    /// it grew into the dimmed recording form, with the stop square and Cancel, while iOS asked to open LocalFlow, and
    /// stayed so about 15 s when the user declined). While the request this keyboard instance bounced to LocalFlow,
    /// `bouncedRequestID`, is the pending intent and the host has not picked it up, the keyboard shows `hostUnavailable`,
    /// so a decline leaves Start as it was and a second tap bounces again. Every other mode shows as it is, a request
    /// another instance bounced included.
    static func shownMode(_ mode: KeyboardMode, bouncedRequestID: UUID?, intent: StoreRead<KeyboardIntent>,
                          status: StoreRead<HostStatus>) -> KeyboardMode {
        guard mode == .starting, let bouncedRequestID, intent.value?.requestID == bouncedRequestID,
              status.value?.dictation?.requestID != bouncedRequestID else { return mode }
        return .hostUnavailable
    }

    /// A live host is preparing the model: the keyboard says so while recording too. Only a live host's
    /// status counts, so a dead host's last status never claims preparation.
    static func isModelPreparing(status: StoreRead<HostStatus>, now: Date) -> Bool {
        guard let status = status.value, status.schema == DictationProtocol.schema else { return false }
        return isAlive(status, now: now) && status.model == .preparing
    }

    /// An active session with a heartbeat fresh within `livenessTimeout`.
    private static func isAlive(_ status: HostStatus, now: Date) -> Bool {
        status.session == .active && DictationProtocol.isFresh(status.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
    }

    /// The stale-writer guard: re-read the intent right before writing `finish` or `cancel`, and
    /// write only if it still names the request the keyboard is showing. `record` starts a new
    /// request and is always allowed.
    static func mayWrite(_ action: KeyboardIntent.Action, requestID: UUID, currentIntent: StoreRead<KeyboardIntent>) -> Bool {
        action == .record || currentIntent.value?.requestID == requestID
    }
}
