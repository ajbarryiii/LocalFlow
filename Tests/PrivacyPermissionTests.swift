import Foundation

enum PrivacyPermissionTests {
    static func run() {
        TestSupport.expectEqual(PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: 26), "Accessibility")
        TestSupport.expectEqual(PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: 27), "Device Control and Data Access")
        TestSupport.expectEqual(PrivacyPermission.screenRecording.settingsTitle(macOSMajorVersion: 13), "Screen Recording")
        TestSupport.expectEqual(PrivacyPermission.screenRecording.settingsTitle(macOSMajorVersion: 14), "Screen & System Audio Recording")
        TestSupport.expectEqual(PrivacyPermission.screenRecording.settingsTitle(macOSMajorVersion: 27), "Screen & System Audio Recording")
        TestSupport.expectEqual(PrivacyPermission.microphone.settingsTitle(macOSMajorVersion: 27), "Microphone")
        TestSupport.expectEqual(
            PrivacyPermission.accessibility.enableInstructions(appName: "Synthetic Dictation", macOSMajorVersion: 27),
            "Go to System Settings > Privacy & Security > Device Control and Data Access and enable Synthetic Dictation."
        )
        TestSupport.expectEqual(
            PrivacyPermission.accessibility.enableInstructions(appName: "Synthetic Dictation", macOSMajorVersion: 26),
            "Go to System Settings > Privacy & Security > Accessibility and enable Synthetic Dictation."
        )
        for (permission, anchor) in [(PrivacyPermission.microphone, "Privacy_Microphone"), (.accessibility, "Privacy_Accessibility"), (.screenRecording, "Privacy_ScreenCapture")] {
            TestSupport.expectEqual(permission.settingsURL.scheme, "x-apple.systempreferences")
            TestSupport.expectEqual(permission.settingsURL.query, anchor)
        }

        // Hosted onboarding keeps its existing order and screen permission.
        let hosted = SetupFlowStep.steps(usesLocalTranscription: false)
        TestSupport.expectEqual(hosted, SetupFlowStep.allCases)
        TestSupport.expectEqual(SetupFlowStep.accessibility.next(usesLocalTranscription: false), .screenRecording)
        TestSupport.expectEqual(SetupFlowStep.holdShortcut.previous(usesLocalTranscription: false), .screenRecording)

        // Local onboarding must not ask for unused screen access in either direction.
        let local = SetupFlowStep.steps(usesLocalTranscription: true)
        TestSupport.expect(!local.contains(.screenRecording), "Local setup must not require screen capture")
        TestSupport.expect(local.contains(.micPermission) && local.contains(.accessibility), "Local setup still needs audio and paste permissions")
        TestSupport.expectEqual(SetupFlowStep.accessibility.next(usesLocalTranscription: true), .holdShortcut)
        TestSupport.expectEqual(SetupFlowStep.holdShortcut.previous(usesLocalTranscription: true), .accessibility)
        for steps in [local, hosted] {
            let isLocal = steps == local
            for (index, step) in steps.enumerated() {
                TestSupport.expectEqual(step.next(usesLocalTranscription: isLocal), steps[min(index + 1, steps.count - 1)])
                TestSupport.expectEqual(step.previous(usesLocalTranscription: isLocal), steps[max(index - 1, 0)])
            }
        }
    }
}
