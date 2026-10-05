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

        let steps = SetupFlowStep.allCases
        TestSupport.expectEqual(steps, [.welcome, .micPermission, .accessibility, .shortcuts, .testTranscription, .ready])
        for (index, step) in steps.enumerated() {
            TestSupport.expectEqual(step.next, steps[min(index + 1, steps.count - 1)])
            TestSupport.expectEqual(step.previous, steps[max(index - 1, 0)])
        }
    }
}
