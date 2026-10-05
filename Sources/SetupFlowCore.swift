import Foundation

enum SetupFlowStep: Int, CaseIterable {
    case welcome, micPermission, accessibility, shortcuts, testTranscription, ready

    var next: Self { Self(rawValue: rawValue + 1) ?? .ready }
    var previous: Self { Self(rawValue: rawValue - 1) ?? .welcome }
}
