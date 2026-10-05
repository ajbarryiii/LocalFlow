import SwiftUI
import AppKit
import AVFoundation
import Combine

struct SetupView: View {
    var onComplete: () -> Void
    @EnvironmentObject var appState: AppState
    @State private var currentStep = SetupFlowStep.welcome
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    private let permissionRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum TestPhase: Equatable { case idle, recording, transcribing, done }
    @State private var testPhase = TestPhase.idle
    @State private var testAudioRecorder: AudioRecorder?
    @State private var testAudioLevel: Float = 0
    @State private var testTranscript = ""
    @State private var testError: String?
    @State private var testAudioLevelCancellable: AnyCancellable?
    @State private var testTranscriptionTask: Task<Void, Never>?
    @StateObject private var testHotkeyHarness = SetupTestHotkeyHarness()

    var body: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    currentStepView
                }.frame(maxWidth: .infinity).padding(32)
            }
            Divider()
            HStack {
                if currentStep != .welcome {
                    Button("Back") { currentStep = currentStep.previous }
                }
                Spacer()
                Text("\(currentStep.rawValue + 1) of \(SetupFlowStep.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if currentStep == .testTranscription {
                    Button("Skip") { currentStep = .ready }
                }
                if currentStep == .ready {
                    Button("Start Using LocalFlow", action: onComplete).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { currentStep = currentStep.next }
                        .keyboardShortcut(.defaultAction).disabled(!canContinue)
                }
            }.padding(20)
        }
        .onAppear { refreshPermissions() }
        .onReceive(permissionRefresh) { _ in refreshPermissions() }
        .onDisappear { stopTestHotkeyMonitoring() }
    }

    @ViewBuilder private var currentStepView: some View {
        switch currentStep {
        case .welcome:
            Image(systemName: "waveform").font(.system(size: 60)).foregroundStyle(.blue)
            Text("Welcome to \(AppName.displayName)").font(.title).fontWeight(.bold)
            LocalModelSettingsView()
            Text("No account or API key is needed. Set up microphone access and shortcuts to start dictating.")
                .foregroundStyle(.secondary)
        case .micPermission:
            permissionStep(.microphone, granted: micGranted) {
                appState.requestMicrophoneAccess { micGranted = $0 }
            }
        case .accessibility:
            permissionStep(.accessibility, granted: accessibilityGranted) { appState.openAccessibilitySettings() }
        case .shortcuts:
            Text("Dictation Shortcuts").font(.title).fontWeight(.bold)
            DictationShortcutEditor(onCaptureStateChange: { capturing in
                if capturing { appState.suspendHotkeyMonitoringForShortcutCapture() }
                else { appState.resumeHotkeyMonitoringAfterShortcutCapture() }
            })
        case .testTranscription:
            testStep
        case .ready:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(.green)
            Text("You're All Set!").font(.title).fontWeight(.bold)
            Text("LocalFlow lives in your menu bar. Dictation stays on this Mac.")
            Text(appState.shortcutStatusText).foregroundStyle(.secondary)
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .welcome: return LocalParakeetService.isAvailable
        case .micPermission: return micGranted
        case .accessibility: return accessibilityGranted
        case .testTranscription: return testPhase == .done && !testTranscript.isEmpty && testError == nil
        default: return true
        }
    }

    private func permissionStep(_ permission: PrivacyPermission, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            Image(systemName: permission == .microphone ? "mic.fill" : "hand.raised.fill")
                .font(.system(size: 60)).foregroundStyle(.blue)
            Text(permission.settingsTitle).font(.title).fontWeight(.bold)
            Text(permission == .microphone ? "Allow microphone access to record your speech." : "Allow this access for global shortcuts and pasting text into your apps.")
                .foregroundStyle(.secondary)
            if granted { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else {
                Button("Grant Access", action: action)
                Text(permission.enableInstructions(appName: AppName.displayName)).font(.caption).foregroundStyle(.secondary)
                if permission == .accessibility {
                    Text(PrivacyPermission.accessibilityRepairInstructions).font(.caption).foregroundStyle(.secondary)
                    Button("Show This App in Finder") { appState.revealAppForPermissionRepair() }
                        .accessibilityLabel("Show This App in Finder")
                }
            }
        }.multilineTextAlignment(.center)
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    private var testStep: some View {
        VStack(spacing: 20) {
            Text("Try Local Dictation").font(.title).fontWeight(.bold)
            Text(appState.shortcutStatusText).foregroundStyle(.secondary)
            Text(appState.localModelPreparationState.message).font(.caption)
            switch testPhase {
            case .idle: Text("Use your shortcut and say a short sentence. The result appears here without pasting into another app.")
            case .recording:
                Label("Recording…", systemImage: "mic.fill").foregroundStyle(.red)
                ProgressView(value: Double(testAudioLevel))
            case .transcribing: ProgressView("Transcribing locally…")
            case .done:
                if let testError { Text(testError).foregroundStyle(.red) }
                else { Text(testTranscript).textSelection(.enabled) }
                Button("Try Again") { resetTest() }
            }
        }
        .onAppear { startTestHotkeyMonitoring() }
        .onDisappear { stopTestHotkeyMonitoring() }
    }
    private func startTestHotkeyMonitoring() {
        testHotkeyHarness.onAction = { action in
            switch action {
            case .start:
                guard testPhase == .idle || testPhase == .done else { return }
                if testPhase == .done {
                    resetTest()
                }
                do {
                    let recorder = AudioRecorder()
                    recorder.onRecordingFailure = { [weak recorder] error in
                        guard let recorder else { return }
                        Task { @MainActor in
                            testAudioLevelCancellable?.cancel()
                            testAudioLevelCancellable = nil
                            testAudioLevel = 0.0
                            testHotkeyHarness.isTranscribing = false
                            testAudioRecorder = nil
                            testError = error.localizedDescription
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                testPhase = .done
                            }
                            recorder.cleanup()
                        }
                    }
                    try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
                    testAudioRecorder = recorder
                    testError = nil
                    testAudioLevelCancellable = recorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { level in
                            testAudioLevel = level
                        }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        testPhase = .recording
                    }
                } catch {
                    testHotkeyHarness.resetSession()
                    testError = error.localizedDescription
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        testPhase = .done
                    }
                }

            case .stop:
                guard testPhase == .recording, let recorder = testAudioRecorder else { return }
                testAudioLevelCancellable?.cancel()
                testAudioLevelCancellable = nil
                testAudioLevel = 0.0
                testHotkeyHarness.isTranscribing = true

                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    testPhase = .transcribing
                }
                recorder.stopRecording { url in
                    guard let url else {
                        Task { @MainActor in
                            testHotkeyHarness.isTranscribing = false
                            testAudioRecorder = nil
                            if testError == nil {
                                testError = "No audio file was created."
                            }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                testPhase = .done
                            }
                            recorder.cleanup()
                        }
                        return
                    }

                    testTranscriptionTask = Task {
                        do {
                            let transcript = try await LocalParakeetService.shared.transcribe(fileURL: url)
                            try Task.checkCancellation()
                            await MainActor.run {
                                testHotkeyHarness.isTranscribing = false
                                testAudioRecorder = nil
                                testTranscript = transcript
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    testPhase = .done
                                }
                            }
                        } catch is CancellationError {
                            // Leaving setup cancels local work without displaying a failure.
                        } catch {
                            await MainActor.run {
                                testHotkeyHarness.isTranscribing = false
                                testAudioRecorder = nil
                                testError = error.localizedDescription
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    testPhase = .done
                                }
                            }
                        }
                        await MainActor.run {
                            recorder.cleanup()
                        }
                    }
                }

            case .switchedToToggle:
                break
            }
        }

        do {
            try testHotkeyHarness.start(configuration: ShortcutConfiguration(
                hold: appState.holdShortcut,
                toggle: appState.toggleShortcut
            ), startDelay: appState.shortcutStartDelay)
        } catch {
            testError = error.localizedDescription
            testPhase = .done
        }
    }

    private func stopTestHotkeyMonitoring() {
        testTranscriptionTask?.cancel()
        testTranscriptionTask = nil
        testHotkeyHarness.stop()
        testAudioLevelCancellable?.cancel()
        testAudioLevelCancellable = nil
        if let recorder = testAudioRecorder, recorder.isRecording {
            recorder.cancelRecording()
        }
        testAudioRecorder = nil
    }

    private func resetTest() {
        testPhase = .idle
        testTranscript = ""
        testError = nil
        testAudioLevel = 0.0
        testHotkeyHarness.isTranscribing = false
        testHotkeyHarness.resetSession()
        if let recorder = testAudioRecorder {
            if recorder.isRecording {
                recorder.cancelRecording()
            }
            testAudioRecorder = nil
        }
    }

}
