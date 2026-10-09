import SwiftUI

enum HomeRoute: Hashable {
    case tryIt, keyboardSetup, diagnostics
}

struct HomeView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber
    @ObservedObject var settings: SharedSettingsModel
    @ObservedObject var preferences: AppPreferences
    @State var path: [HomeRoute]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    SessionCard()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    ModelStatusRow(transcriber: transcriber)
                }

                Section {
                    NavigationLink(value: HomeRoute.tryIt) {
                        RowLabel(title: "Try it", detail: "Dictate into two test fields", symbol: "text.cursor")
                    }
                    .accessibilityIdentifier("home.tryIt")
                    NavigationLink(value: HomeRoute.keyboardSetup) {
                        RowLabel(title: "Keyboard setup", detail: "Enable the keyboard and Full Access", symbol: "keyboard")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Session length").font(.body)
                        Picker("Session length", selection: $settings.sessionMinutes) {
                            ForEach(LocalFlowSettings.sessionMinuteOptions, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("settings.sessionLength")
                        Text("A session ends after this long without dictation.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    SettingToggle(title: "Spoken punctuation", detail: "Say “open paren … close paren” or “quote … end quote”.",
                                  isOn: $settings.spokenDelimitersEnabled)
                    SettingToggle(title: "Press enter", detail: "End a dictation with “press enter” to send it.",
                                  isOn: $settings.pressEnterEnabled)
                    SettingToggle(title: "Haptics", detail: "Feedback when recording starts and stops.",
                                  isOn: $settings.hapticsEnabled)
                    SettingToggle(title: "Use iPhone microphone",
                                  detail: "Keeps AirPods in high-quality audio and avoids Bluetooth delay, even with headphones connected.",
                                  isOn: Binding(get: { preferences.useBuiltInMicrophone }, set: { host.setUseBuiltInMicrophone($0) }))
                        .accessibilityIdentifier("settings.useBuiltInMicrophone")
                } header: {
                    Text("Dictation")
                }
                .tint(Theme.violet)

                Section {
                    NavigationLink(value: HomeRoute.diagnostics) {
                        RowLabel(title: "Diagnostics", detail: "Measurements and cursor tuning", symbol: "gauge.with.dots.needle.67percent")
                    }
                    .accessibilityIdentifier("home.diagnostics")
                } footer: {
                    Text("LocalFlow \(AppIdentity.version) · Nothing you say leaves this iPhone.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("LocalFlow")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .tryIt: TryItView()
                case .keyboardSetup: KeyboardSetupScreen()
                case .diagnostics: DiagnosticsView(transcriber: transcriber)
                }
            }
        }
        .tint(Theme.violet)
    }
}

/// Start or end the Flow session; while it runs, how long it stays and what the orange dot means.
private struct SessionCard: View {
    @EnvironmentObject private var host: HostSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                switch host.session {
                case .inactive:
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 10, height: 10)
                    Text("No session").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                case .active:
                    PulsingDot(color: Theme.live)
                    Text("Session on").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.live)
                }
                Spacer()
                if host.session == .active { remaining }
            }

            if host.session == .active, let input = host.currentInput {
                Label("Input: \(input.label)", systemImage: input == .builtInMic ? "iphone" : "headphones")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("session.input")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.bold()).fontDesign(.rounded)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }

            if host.dictation?.phase == .recording, host.session == .active {
                LevelBars(level: host.level).frame(maxWidth: .infinity)
            }

            if host.session == .active {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.live, in: Circle())
                    Text("iOS shows the orange microphone indicator while a session is on. Between dictations, audio is dropped the moment it arrives; nothing is kept or saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Theme.live.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let error = host.sessionError, host.session == .inactive {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }

            switch host.session {
            case .inactive:
                Button {
                    host.startSession()
                } label: {
                    Label("Start session", systemImage: "mic.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("session.start")
                if host.sessionError == .microphonePermissionDenied || host.microphonePermission == .denied {
                    Button("Open Settings") { AppIdentity.openSettings() }.buttonStyle(SecondaryButtonStyle())
                }
            case .starting:
                Button("Starting…") {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
            case .active:
                Button {
                    host.endSession()
                } label: {
                    Label("End session", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle(tint: .red))
                .accessibilityIdentifier("session.end")
            }
        }
        .padding(20)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy, value: host.session)
    }

    private var title: String {
        switch (host.session, host.dictation?.phase, host.isDictationInProgress) {
        case (_, .recording?, true): return "Listening…"
        case (_, .transcribing?, true): return "Transcribing…"
        case (.active, _, _): return "Ready when you are"
        case (.starting, _, _): return "Starting the microphone"
        default: return "Start a Flow session"
        }
    }

    private var detail: String {
        switch host.session {
        case .inactive:
            return "A session keeps the microphone ready, so you can dictate from the LocalFlow keyboard in any app without coming back here."
        case .starting:
            return "Getting the microphone ready…"
        case .active:
            return "Switch to any app, choose the LocalFlow keyboard and tap the microphone."
        }
    }

    private var remaining: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let expiresAt = host.sessionExpiresAt {
                    let seconds = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                    Text("Ends in \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))")
                } else {
                    Text("Dictating")
                }
            }
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

private struct RowLabel: View {
    var title: String
    var detail: String
    var symbol: String

    var body: some View {
        HStack(spacing: 14) {
            SymbolTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SettingToggle: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct KeyboardSetupScreen: View {
    @EnvironmentObject private var host: HostSessionController

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                KeyboardSetupSteps { host.keyboardHasFullAccess }
                Button("Open Settings") { AppIdentity.openSettings() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
        }
        .background(Theme.screenBackground.ignoresSafeArea())
        .navigationTitle("Keyboard setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}
