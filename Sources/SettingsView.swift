import SwiftUI
import AppKit
import AVFoundation

struct LocalModelSettingsView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LocalFlow").font(.headline)
            Text("Ternary speech model derived from NVIDIA Parakeet v2.")
                .font(.caption).foregroundStyle(.secondary)
            Text("English dictation processed entirely on this Mac. Audio and transcripts are never sent to a model provider.")
                .foregroundStyle(.secondary)
            Text(appState.localModelPreparationState.message).font(.caption)
            if !LocalParakeetService.isAvailable {
                Text("The bundled model requires Apple Silicon and macOS 26 or later.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if appState.localModelPreparationState == .failed {
                Button("Retry Model Preparation") { appState.prepareLocalTranscriptionIfNeeded() }
            }
            Text("Recordings longer than 15 seconds are transcribed in separate chunks. The model stays in memory while the app is open.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @AppStorage("use_compact_overlay") private var useCompactOverlay = true
    @AppStorage("overlay_display_id") private var overlayDisplayID = 0
    @State private var micGranted = false
    private let permissionRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Local Model", icon: "waveform") { LocalModelSettingsView() }
                SettingsCard("App", icon: "power") {
                    Toggle("Launch \(AppName.displayName) at login", isOn: $appState.launchAtLogin)
                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                }
                SettingsCard("Updates", icon: "arrow.triangle.2.circlepath") {
                    Toggle("Automatically check for updates", isOn: $updateManager.autoCheckEnabled)
                    Button(updateManager.isChecking ? "Checking…" : "Check for Updates Now") {
                        Task { await updateManager.checkForUpdates(userInitiated: true) }
                    }.disabled(updateManager.isChecking)
                    if updateManager.updateAvailable {
                        Button("View Available Update") { updateManager.showUpdateAlert() }
                    }
                }
                SettingsCard("Dictation Shortcuts", icon: "keyboard.fill") {
                    DictationShortcutEditor(onCaptureStateChange: { capturing in
                        if capturing { appState.suspendHotkeyMonitoringForShortcutCapture() }
                        else { appState.resumeHotkeyMonitoringAfterShortcutCapture() }
                    })
                    Text("Shortcut Start Delay: \(appState.shortcutStartDelayMilliseconds) ms").font(.caption)
                    Slider(value: $appState.shortcutStartDelay, in: 0...1, step: 0.05)
                }
                SettingsCard("Audio", icon: "mic.fill") {
                    Picker("Microphone", selection: $appState.selectedMicrophoneID) {
                        Text("System Default").tag("default")
                        ForEach(appState.availableMicrophones) { device in Text(device.name).tag(device.uid) }
                    }
                    Toggle("Mute audio during dictation", isOn: $appState.dictationAudioInterruptionEnabled)
                    Toggle("Play alert sounds", isOn: $appState.alertSoundsEnabled)
                    Slider(value: $appState.soundVolume, in: 0...1) { Text("Sound Volume") }
                }
                SettingsCard("Recording Overlay", icon: "rectangle.dashed") {
                    Toggle("Use compact menu-bar overlay", isOn: $useCompactOverlay)
                    Text("Turn off for a larger pill below the menu bar.").font(.caption).foregroundStyle(.secondary)
                    Picker("Show on", selection: $overlayDisplayID) {
                        Text("Active window (default)").tag(0)
                        Text("Primary display").tag(-1)
                        ForEach(NSScreen.screens, id: \.self) { screen in
                            if let displayID = screen.displayID {
                                Text(screen.localizedName).tag(Int(displayID))
                            }
                        }
                    }
                }
                SettingsCard("Clipboard", icon: "doc.on.clipboard") {
                    Toggle("Preserve clipboard after paste", isOn: $appState.preserveClipboard)
                    Text("LocalFlow restores the previous clipboard unless you copy something else before restoration.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep dictations in clipboard history", isOn: $appState.keepDictationInClipboardHistory)
                    Toggle("Say ‘press enter’ to submit after paste", isOn: $appState.isPressEnterVoiceCommandEnabled)
                    Text("A trailing ‘press enter’ is removed from the transcript and presses Return after pasting.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Convert spoken quotes, brackets, code marks, and caps", isOn: $appState.isSpokenDelimitersEnabled)
                    Text("Say ‘quote … end quote’, ‘paren … close paren’, ‘open bracket/brace … close bracket/brace’, ‘backtick … end backtick’, ‘double asterisk … close double asterisk’, or ‘all caps on … all caps off’ / ‘all lowercase … end lowercase’. Start with ‘all caps’ or ‘all lowercase’ to change a whole dictation. Unpaired words stay as spoken.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingsCard("Permissions", icon: "lock.shield.fill") {
                    permissionRow(.microphone, granted: micGranted) {
                        appState.requestMicrophoneAccess { micGranted = $0 }
                    }
                    permissionRow(.accessibility, granted: appState.hasAccessibility) { appState.openAccessibilitySettings() }
                    Text("Screen Recording is not needed for local dictation.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsCard("Build", icon: "info.circle.fill") {
                    Text("\(AppName.displayName) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)").font(.caption).foregroundStyle(.secondary)
                    Link("Based on FreeFlow by Zach Latta and contributors · MIT license", destination: URL(string: "https://github.com/zachlatta/freeflow")!)
                        .font(.caption)
                }
            }.padding(24)
        }
        .onAppear {
            refreshPermissions()
            appState.refreshAvailableMicrophones()
            appState.refreshLaunchAtLoginStatus()
        }
        .onReceive(permissionRefresh) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        appState.hasAccessibility = AXIsProcessTrusted()
    }

    private func permissionRow(_ permission: PrivacyPermission, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(permission.settingsTitle)
                Spacer()
                if granted { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Grant Access", action: action) }
            }
            if !granted {
                Text(permission.enableInstructions(appName: AppName.displayName)).font(.caption).foregroundStyle(.secondary)
                if permission == .accessibility {
                    Text(PrivacyPermission.accessibilityRepairInstructions).font(.caption).foregroundStyle(.secondary)
                    Button("Show This App in Finder") { appState.revealAppForPermissionRepair() }
                        .accessibilityLabel("Show This App in Finder")
                }
            }
        }
    }
}

struct DebugSettingsView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Local Model", icon: "waveform") { LocalModelSettingsView() }
                SettingsCard("Overlay", icon: "wrench.and.screwdriver") {
                    Button(appState.isDebugOverlayActive ? "Stop Overlay Preview" : "Preview Overlay") { appState.toggleDebugOverlay() }
                    Toggle("Preview update reminder after dictation", isOn: $appState.debugShowsUpdateReminderAfterDictation)
                    Button("Preview Update Reminder") { appState.showDebugUpdateAvailableOverlay() }
                }
                SettingsCard("Last Dictation", icon: "clock") {
                    Text(appState.debugStatusMessage)
                    Text(appState.lastTranscriptionStatus).font(.caption)
                    Text(appState.lastRawTranscript).textSelection(.enabled)
                    if appState.lastOutputTranscript != appState.lastRawTranscript {
                        Text("Macro output").font(.caption)
                        Text(appState.lastOutputTranscript).textSelection(.enabled)
                    }
                }
            }.padding(24)
        }
    }
}

struct RunLogView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Local Dictation History").font(.title2)
                    Spacer()
                    Button("Clear History") { appState.clearPipelineHistory() }.disabled(appState.pipelineHistory.isEmpty)
                }
                Text("The latest \(appState.maxPipelineHistoryCount) recordings and transcripts are stored on this Mac for replay and retry.")
                    .font(.caption).foregroundStyle(.secondary)
                if appState.pipelineHistory.isEmpty { Text("No dictations yet.").foregroundStyle(.secondary) }
                ForEach(appState.pipelineHistory) { item in
                    SettingsCard(item.timestamp.formatted(), icon: "waveform") {
                        Text(item.displayTranscript.isEmpty ? "No transcript" : item.displayTranscript).textSelection(.enabled)
                        Text(item.status).font(.caption).foregroundStyle(.secondary)
                        if let name = item.audioFileName {
                            AudioPlayerView(audioURL: AppState.audioStorageDirectory().appendingPathComponent(name))
                            Button(appState.retryingItemIDs.contains(item.id) ? "Retrying Locally…" : "Retry Locally") {
                                appState.retryTranscription(item: item)
                            }.disabled(appState.retryingItemIDs.contains(item.id))
                        }
                        HStack {
                            Button("Copy Transcript") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.displayTranscript, forType: .string)
                            }.disabled(item.displayTranscript.isEmpty)
                            Button("Delete") { appState.deleteHistoryEntry(id: item.id) }
                        }
                    }
                }
            }.padding(24)
        }
    }
}
private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private let iso8601DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.visibleCases) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        SettingsSidebarRow(title: tab.title, icon: tab.icon)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.selectedSettingsTab == tab
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .macros:
                    VoiceMacrosSettingsView()
                case .runLog:
                    RunLogView()
                case .debug:
                    DebugSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 16, height: 16, alignment: .center)
                .foregroundStyle(.primary)

            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
}

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * progress), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            loadDuration()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func loadDuration() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        if let p = try? AVAudioPlayer(contentsOf: audioURL) {
            duration = p.duration
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = {
                    self.stopPlayback()
                }
                p.delegate = delegate
                p.play()
                player = p
                isPlaying = true
                elapsed = 0
                startProgressTimer()
            } catch {}
        }
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let p = player, p.isPlaying {
                elapsed = p.currentTime
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct VoiceMacrosSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddMacro = false
    @State private var editingMacro: VoiceMacro?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Voice Macros", icon: "music.mic") {
                    macrosSection
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingAddMacro, onDismiss: { editingMacro = nil }) {
            VoiceMacroEditorView(isPresented: $showingAddMacro, macro: $editingMacro)
        }
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Say a command to paste its predefined text. Matching happens entirely on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingAddMacro = true }) {
                    Text("Add Macro")
                }
            }

            if appState.voiceMacros.isEmpty {
                VStack {
                    Image(systemName: "music.mic")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                    Text("No Voice Macros Yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Click 'Add Macro' to define your first voice macro.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(appState.voiceMacros.enumerated()), id: \.element.id) { index, macro in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(macro.command)
                                    .font(.headline)
                                Spacer()
                                Button("Edit") {
                                    editingMacro = macro
                                    showingAddMacro = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                
                                Button("Delete") {
                                    appState.voiceMacros.removeAll { $0.id == macro.id }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Text(macro.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    }
                }
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }
}

struct VoiceMacroEditorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @Binding var macro: VoiceMacro?

    @State private var command: String = ""
    @State private var payload: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(macro == nil ? "Add Macro" : "Edit Macro")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Voice Command (What you say)")
                    .font(.caption.weight(.semibold))
                TextField("e.g. debugging prompt", text: $command)
                    .textFieldStyle(.roundedBorder)

                Text("Text (What gets pasted)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 8)
                TextEditor(text: $payload)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                    macro = nil
                }
                Spacer()
                Button("Save") {
                    let newMacro = VoiceMacro(
                        id: macro?.id ?? UUID(),
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                        payload: payload
                    )
                    
                    if let existingIndex = appState.voiceMacros.firstIndex(where: { $0.id == newMacro.id }) {
                        appState.voiceMacros[existingIndex] = newMacro
                    } else {
                        appState.voiceMacros.append(newMacro)
                    }
                    isPresented = false
                    macro = nil
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || payload.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let m = macro {
                command = m.command
                payload = m.payload
            }
        }
    }
}
