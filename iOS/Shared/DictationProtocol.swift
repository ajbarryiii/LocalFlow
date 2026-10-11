import Foundation

enum DictationProtocol {
    static let schema = 1
    static let heartbeatInterval: TimeInterval = 1          // host rewrites status at least this often while running a session
    static let livenessTimeout: TimeInterval = 3            // keyboard treats an older heartbeat as "host not running"
    static let clockSkewTolerance: TimeInterval = 2
    static let pendingRecordTTL: TimeInterval = 20          // admission window for a record intent (covers launch/bounce)
    static let startupTimeout: TimeInterval = 10            // admission -> first audio buffer, else failed(.startupTimeout)
    static let captureFreshness: TimeInterval = 1           // captureReady requires an input buffer this recent
    static let keyboardPresenceInterval: TimeInterval = 1   // keyboard rewrites presence this often while visible
    static let keyboardPresenceTimeout: TimeInterval = 15   // see "Keyboard presence"
    static let maxDictationDuration: TimeInterval = 300     // host auto-finishes a recording after this
    static let resultTTL: TimeInterval = 60                 // insertion window; expired results are deleted by either process

    /// Whether a record stamped `timestamp` is still fresh: `-clockSkewTolerance <= age <= ttl`.
    /// A backward clock jump makes records stale rather than fresh.
    static func isFresh(_ timestamp: Date, ttl: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -clockSkewTolerance && age <= ttl
    }
}

/// The outcome of reading one shared record.
enum StoreRead<Value> {
    case value(Value)
    /// The file does not exist.
    case absent
    /// The record decodes, but its schema is unknown: the other process is a different version.
    case incompatible
    /// Corrupt, protected while the device is locked, or an I/O error. Treat as absent.
    case unreadable

    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    var isIncompatible: Bool {
        if case .incompatible = self { return true }
        return false
    }
}

extension StoreRead: Equatable where Value: Equatable {}
extension StoreRead: Sendable where Value: Sendable {}

struct KeyboardIntent: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case record, finish, cancel }
    var schema: Int = DictationProtocol.schema
    var requestID: UUID
    var action: Action
    var keyboardInstanceID: UUID   // the UIInputViewController instance that wrote this action
    var issuedAt: Date
}

struct KeyboardPresence: Codable, Equatable, Sendable {
    var schema: Int = DictationProtocol.schema
    var keyboardInstanceID: UUID
    var seenAt: Date
}

struct HostStatus: Codable, Equatable, Sendable {
    enum Session: String, Codable, Sendable { case inactive, starting, active }
    enum Model: String, Codable, Sendable { case unavailable, notPrepared, preparing, ready, failed }
    var schema: Int = DictationProtocol.schema
    var hostRunID: UUID            // new for every host process launch
    var sessionID: UUID?
    var session: Session
    var captureReady: Bool         // engine running and an input buffer within captureFreshness
    var heartbeatAt: Date
    var sessionExpiresAt: Date?    // idle expiry; nil while a dictation is in progress
    var model: Model
    var dictation: DictationStatus?
    var level: Float = 0           // 0...1, meaningful only while recording
    var error: HostErrorCode?      // content-free, most recent session-level error
}

struct DictationStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case starting, recording, transcribing, completed, failed, cancelled

        var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    }
    var requestID: UUID
    var hostRunID: UUID            // the run that admitted this request
    var phase: Phase
    var error: HostErrorCode?      // set when phase == .failed (or .cancelled by the host)
    var startedAt: Date
    var updatedAt: Date
}

enum HostErrorCode: String, Codable, Sendable {
    case microphonePermissionDenied, audioSessionFailed, startupTimeout, interrupted, deviceLocked,
         keyboardDismissed, sessionInactive, modelUnavailable, modelFailed, transcriptionFailed,
         backgroundTimeExpired, notRecording, tooLong, superseded
}

struct DictationResult: Codable, Equatable, Sendable {
    var schema: Int = DictationProtocol.schema
    var requestID: UUID
    var hostRunID: UUID
    var text: String               // already post-processed by LocalDictationCore
    var pressEnter: Bool
    var createdAt: Date
}
