import Foundation

/// User-facing pane names change across macOS versions, while the Settings
/// URL anchors remain compatible (including Accessibility on macOS 27).
enum PrivacyPermission: CaseIterable {
    case microphone, accessibility

    func settingsTitle(macOSMajorVersion: Int) -> String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return macOSMajorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
        }
    }

    var settingsTitle: String {
        settingsTitle(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    func enableInstructions(appName: String, macOSMajorVersion: Int) -> String {
        "Go to System Settings > Privacy & Security > \(settingsTitle(macOSMajorVersion: macOSMajorVersion)) and enable \(appName)."
    }

    func enableInstructions(appName: String) -> String {
        enableInstructions(appName: appName, macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    static let accessibilityRepairInstructions = "If the app is already enabled but access is still missing, remove its entry with −, add this copy with +, and enable it again."

    /// The alert shown when dictation needs this permission and it is missing.
    func alertText(appName: String, macOSMajorVersion: Int) -> PermissionAlertText {
        let instructions = enableInstructions(appName: appName, macOSMajorVersion: macOSMajorVersion)
        let title = "\(settingsTitle(macOSMajorVersion: macOSMajorVersion)) Permission Required"
        switch self {
        case .microphone:
            return PermissionAlertText(
                title: title,
                message: "\(appName) cannot record audio without Microphone access.\n\n\(instructions)",
                symbolName: "mic.fill"
            )
        case .accessibility:
            return PermissionAlertText(
                title: title,
                message: "\(appName) needs this access for global shortcuts and pasting transcribed text.\n\n\(instructions)\n\n\(Self.accessibilityRepairInstructions)",
                symbolName: "exclamationmark.triangle.fill"
            )
        }
    }

    func alertText(appName: String) -> PermissionAlertText {
        alertText(appName: appName, macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

struct PermissionAlertText: Equatable {
    let title: String
    let message: String
    /// SF Symbol for the alert icon.
    let symbolName: String
}
