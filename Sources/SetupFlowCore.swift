import Foundation

enum SetupFlowStep: Int, CaseIterable {
    case welcome = 0
    case apiKey
    case micPermission
    case accessibility
    case screenRecording
    case holdShortcut
    case toggleShortcut
    case copyAgainShortcut
    case commandMode
    case vocabulary
    case launchAtLogin
    case overlayStyle
    case testTranscription
    case ready

    static func steps(usesLocalTranscription: Bool) -> [Self] {
        allCases.filter { !usesLocalTranscription || $0 != .screenRecording }
    }

    func next(usesLocalTranscription: Bool) -> Self {
        Self.steps(usesLocalTranscription: usesLocalTranscription).first { $0.rawValue > rawValue } ?? .ready
    }

    func previous(usesLocalTranscription: Bool) -> Self {
        Self.steps(usesLocalTranscription: usesLocalTranscription).last { $0.rawValue < rawValue } ?? .welcome
    }
}
