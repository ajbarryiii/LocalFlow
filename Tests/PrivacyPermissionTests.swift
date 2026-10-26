import Foundation

enum PrivacyPermissionTests {
    static func run() {
        TestSupport.expectEqual(PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: 26), "Accessibility")
        TestSupport.expectEqual(PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: 27), "Device Control and Data Access")
        TestSupport.expectEqual(PrivacyPermission.microphone.settingsTitle(macOSMajorVersion: 27), "Microphone")
        TestSupport.expectEqual(
            PrivacyPermission.accessibility.enableInstructions(appName: "Synthetic Dictation", macOSMajorVersion: 27),
            "Go to System Settings > Privacy & Security > Device Control and Data Access and enable Synthetic Dictation."
        )
        TestSupport.expectEqual(
            PrivacyPermission.accessibility.enableInstructions(appName: "Synthetic Dictation", macOSMajorVersion: 26),
            "Go to System Settings > Privacy & Security > Accessibility and enable Synthetic Dictation."
        )
        for (permission, anchor) in [(PrivacyPermission.microphone, "Privacy_Microphone"), (.accessibility, "Privacy_Accessibility")] {
            TestSupport.expectEqual(permission.settingsURL.scheme, "x-apple.systempreferences")
            // Foundation versions differ in whether opaque custom-scheme URLs
            // expose a query. Settings receives the complete serialized URL.
            TestSupport.expectEqual(
                permission.settingsURL.absoluteString,
                "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            )
        }

        TestSupport.expectEqual(
            PrivacyPermission.microphone.alertText(appName: "Synthetic Dictation", macOSMajorVersion: 27),
            PermissionAlertText(
                title: "Microphone Permission Required",
                message: "Synthetic Dictation cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable Synthetic Dictation.",
                symbolName: "mic.fill"
            )
        )
        for (version, pane) in [(26, "Accessibility"), (27, "Device Control and Data Access")] {
            TestSupport.expectEqual(
                PrivacyPermission.accessibility.alertText(appName: "Synthetic Dictation", macOSMajorVersion: version),
                PermissionAlertText(
                    title: "\(pane) Permission Required",
                    message: "Synthetic Dictation needs this access for global shortcuts and pasting transcribed text.\n\nGo to System Settings > Privacy & Security > \(pane) and enable Synthetic Dictation.\n\nIf the app is already enabled but access is still missing, remove its entry with −, add this copy with +, and enable it again.",
                    symbolName: "exclamationmark.triangle.fill"
                )
            )
        }

        let steps = SetupFlowStep.allCases
        TestSupport.expectEqual(steps, [.welcome, .micPermission, .accessibility, .shortcuts, .testTranscription, .ready])
        for (index, step) in steps.enumerated() {
            TestSupport.expectEqual(step.next, steps[min(index + 1, steps.count - 1)])
            TestSupport.expectEqual(step.previous, steps[max(index - 1, 0)])
        }
    }
}
