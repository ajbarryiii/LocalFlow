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
    case error(HostErrorCode)
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
        let isHostAlive = status.map {
            $0.session == .active && DictationProtocol.isFresh($0.heartbeatAt, ttl: DictationProtocol.livenessTimeout, now: now)
        } ?? false
        // The intent, not the keyboard instance, names the request, so a keyboard created after the
        // bounce adopts the request its predecessor started.
        let dictation = intent.flatMap { intent in status?.dictation.flatMap { $0.requestID == intent.requestID ? $0 : nil } }

        if let dictation, isHostAlive {
            switch dictation.phase {
            case .starting: return .starting
            case .recording:
                let level = status?.level ?? 0
                return .recording(level: level.isFinite ? min(max(level, 0), 1) : 0, startedAt: dictation.startedAt)
            case .transcribing: return .transcribing
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
        if isHostAlive, status?.captureReady == true { return .ready }
        return .hostUnavailable
    }

    /// The stale-writer guard: re-read the intent right before writing `finish` or `cancel`, and
    /// write only if it still names the request the keyboard is showing. `record` starts a new
    /// request and is always allowed.
    static func mayWrite(_ action: KeyboardIntent.Action, requestID: UUID, currentIntent: StoreRead<KeyboardIntent>) -> Bool {
        action == .record || currentIntent.value?.requestID == requestID
    }
}
