import Foundation

enum HostAction: Equatable, Sendable {
    case none
    case start(UUID)
    case finish(UUID)
    case cancel(UUID)
    case reject(UUID, HostErrorCode)
}

/// Decides how the host moves toward the keyboard's latest intent. Pure, so it can run on every
/// notification, poll, launch, URL open and activation: once the host has applied an action and
/// recorded the request in `knownRequestIDs` (or `current`), re-evaluating yields `none`.
enum HostReconciler {
    /// - Parameters:
    ///   - current: the host's latest dictation, in any phase.
    ///   - knownRequestIDs: every request this host admitted or rejected, plus those recovered
    ///     from the previous run's status.
    ///   - isForeground: the app is in the foreground, so capture may start. Pass true while
    ///     launching or activating from the bounce too: a fresh `record` evaluated with neither this
    ///     nor `sessionActive` is rejected for good.
    ///   - sessionActive: a session is running, so capture can start from the background.
    static func action(intent: StoreRead<KeyboardIntent>, current: DictationStatus?, knownRequestIDs: Set<UUID>,
                       isForeground: Bool, sessionActive: Bool, now: Date) -> HostAction {
        guard let intent = intent.value, intent.schema == DictationProtocol.schema else { return .none }
        let request = intent.requestID
        let currentPhase = current?.requestID == request ? current?.phase : nil
        switch intent.action {
        case .record:
            // Never restart a request, whatever phase it reached and even after host death.
            if currentPhase != nil || knownRequestIDs.contains(request) { return .none }
            guard DictationProtocol.isFresh(intent.issuedAt, ttl: DictationProtocol.pendingRecordTTL, now: now)
            else { return .none }
            guard sessionActive || isForeground else { return .reject(request, .sessionInactive) }
            // The controller first cancels any other in-progress request with `.superseded`.
            return .start(request)
        case .finish:
            switch currentPhase {
            case .recording?: return .finish(request)
            case .starting?: return .cancel(request)   // nothing captured yet; reported as failed(.notRecording)
            case .some: return .none
            case nil: return knownRequestIDs.contains(request) ? .none : .reject(request, .notRecording)
            }
        case .cancel:
            switch currentPhase {
            case .starting?, .recording?, .transcribing?: return .cancel(request)
            default: return .none
            }
        }
    }
}
