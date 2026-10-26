import AppKit
import ApplicationServices
import AVFoundation

extension PrivacyPermission {
    /// Whether the permission is granted now. Only reads the state; never prompts.
    var isGranted: Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Opens the permission's pane in System Settings, or Privacy & Security when that fails.
    @MainActor
    func openSettings() {
        if !NSWorkspace.shared.open(settingsURL) {
            NSWorkspace.shared.open(Self.privacySettingsURL)
        }
    }
}
