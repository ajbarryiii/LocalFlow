import SwiftUI

enum HomeRoute: Hashable {
    case tryIt, keyboardSetup, dictionary, diagnostics, reportBug
}

struct HomeView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber
    @ObservedObject var settings: SharedSettingsModel
    @ObservedObject var preferences: AppPreferences
    @State var path: [HomeRoute]
    /// Push Try it once Home is on screen (right after onboarding), so Home's large title is there to go back to.
    var opensTryIt = false
    @State private var openedTryIt = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    SessionCard(transcriber: transcriber)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    ModelStatusRow(transcriber: transcriber)
                }
                .listRowBackground(Theme.cardBackground)

                Section {
                    NavigationLink(value: HomeRoute.tryIt) {
                        RowLabel(title: "Try it", symbol: "text.cursor")
                    }
                    .accessibilityIdentifier("home.tryIt")
                    NavigationLink(value: HomeRoute.keyboardSetup) {
                        RowLabel(title: "Keyboard setup", symbol: "keyboard")
                    }
                    NavigationLink(value: HomeRoute.dictionary) {
                        RowLabel(title: "Dictionary", symbol: "character.book.closed")
                    }
                    .accessibilityIdentifier("home.dictionary")
                }
                .listRowBackground(Theme.cardBackground)

                Section {
                    Picker("Session length", selection: $settings.sessionMinutes) {
                        ForEach(LocalFlowSettings.sessionMinuteOptions, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .accessibilityHint("A session ends after this long without dictation")
                    .accessibilityIdentifier("settings.sessionLength")
                    Toggle("Spoken quotes and brackets", isOn: $settings.spokenDelimitersEnabled)
                    Toggle("Numbers as digits", isOn: $settings.spokenNumbersEnabled)
                    Toggle("Say “press enter” to send", isOn: $settings.pressEnterEnabled)
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                    Toggle("Use iPhone microphone",
                           isOn: Binding(get: { preferences.useBuiltInMicrophone }, set: { host.setUseBuiltInMicrophone($0) }))
                        .accessibilityIdentifier("settings.useBuiltInMicrophone")
                } header: {
                    Text("Dictation")
                }
                .listRowBackground(Theme.cardBackground)
                .tint(Theme.toggle)

                Section {
                    // The keyboard reads these when it next appears.
                    FullAccessToggle(title: "Autocorrect", isOn: $settings.autocorrectEnabled)
                        .accessibilityIdentifier("settings.autocorrect")
                    FullAccessToggle(title: "Soft key edges", isOn: $settings.softKeyEdgesEnabled)
                        .accessibilityIdentifier("settings.softKeyEdges")
                    FullAccessToggle(title: "Typing haptics", isOn: $settings.keyHapticsEnabled)
                        .accessibilityIdentifier("settings.keyHaptics")
                    Toggle("Left-handed", isOn: $settings.leftHanded)
                        .accessibilityIdentifier("settings.leftHanded")
                } header: {
                    Text("Keyboard")
                } footer: {
                    // The app cannot tell whether Full Access is off, so the lock marks what needs it.
                    Label("Needs Full Access", systemImage: "lock.fill")
                        .labelStyle(FootnoteLabelStyle())
                }
                .listRowBackground(Theme.cardBackground)
                .tint(Theme.toggle)

                Section {
                    NavigationLink(value: HomeRoute.diagnostics) {
                        RowLabel(title: "Diagnostics", symbol: "gauge.with.dots.needle.67percent")
                    }
                    .accessibilityIdentifier("home.diagnostics")
                    NavigationLink(value: HomeRoute.reportBug) {
                        RowLabel(title: "Report a bug", symbol: "envelope")
                    }
                    .accessibilityIdentifier("home.reportBug")
                    Link(destination: URL(string: "https://ajbarryiii.github.io/LocalFlow/privacy.html")!) {
                        HStack {
                            RowLabel(title: "Privacy policy", symbol: "hand.raised")
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.secondaryInk)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.white)
                    }
                    .accessibilityHint("Opens in your browser")
                    .accessibilityIdentifier("home.privacyPolicy")
                } footer: {
                    // No lock here: on Home the lock means "needs Full Access".
                    Text("LocalFlow \(AppIdentity.version)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityLabel("LocalFlow \(AppIdentity.version). Nothing you say leaves this iPhone.")
                }
                .listRowBackground(Theme.cardBackground)
            }
            .listStyle(.insetGrouped)
            .themedListBackground()
            .navigationTitle("LocalFlow")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .tryIt: TryItView()
                case .keyboardSetup: KeyboardSetupScreen()
                case .dictionary: DictionaryView(dictionary: host.dictionary)
                case .diagnostics: DiagnosticsView(transcriber: transcriber)
                case .reportBug: ReportBugView(recipient: "localflow@wildernesslabs.ai")
                }
            }
        }
        .tint(.white)
        .task {
            guard opensTryIt, !openedTryIt else { return }
            openedTryIt = true
            // After onboarding's cross-fade to Home, so the push reads as one.
            try? await Task.sleep(for: .seconds(0.3))
            path.append(.tryIt)
        }
    }
}

/// The Flow session, as the Live Activity's Lock Screen shows it (`SessionCardState`): with no session, the Start pill
/// with the mark, on the background; during one, a card with the mark and the state's dot, the state, the time left or
/// recorded, the input's glyph and End. With the microphone off, Open Settings is the only action. At accessibility
/// sizes the glyphs share one line and the words get the card's full width.
private struct SessionCard: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber
    /// Read so the card looks at the microphone permission again on the way back from Settings.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var markSide: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var pillMarkSide: CGFloat = 22

    private var state: SessionCardState {
        SessionCardState(session: host.session, permission: host.microphonePermission, sessionError: host.sessionError,
                         dictation: host.dictation?.phase, dictationInProgress: host.isDictationInProgress,
                         model: transcriber.modelState)
    }

    var body: some View {
        let state = state
        let isCard = state.title != nil
        VStack(alignment: .leading, spacing: 16) {
            if let title = state.title {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            mark(state)
                            input(state)
                        }
                        words(title, state)
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        mark(state)
                        words(title, state)
                        Spacer(minLength: 0)
                        input(state)
                    }
                }
            }

            if state.isSessionOn, let problem = host.microphoneRouting.problem {
                // The choice could not be honored; dictation goes on with the other input.
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ember)
                    .accessibilityIdentifier("session.inputProblem")
            }

            if state == .off, let error = host.sessionError {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ember)
            }

            action(state)
        }
        // No session: the pill sits on the background, as the keyboard's Start sits on its bar.
        .padding(isCard ? 16 : 0)
        .background(isCard ? Theme.cardBackground : .clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// The mark with the state's dot, or the microphone-off glyph; it stops growing at the largest sizes.
    @ViewBuilder
    private func mark(_ state: SessionCardState) -> some View {
        let side = min(markSide, 40)
        if let accent = state.accent {
            RidgeMarkView(dot: Theme.color(accent), side: side)
                .animation(.snappy(duration: 0.28), value: accent)
        } else {
            Image(systemName: "mic.slash.fill")
                .font(.title3)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Theme.ember)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }

    private func words(_ title: String, _ state: SessionCardState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if state.reservesDetailLine {
                detail(state)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.state")
    }

    @ViewBuilder
    private func input(_ state: SessionCardState) -> some View {
        if state.isSessionOn, let input = host.currentInput {
            Image(systemName: input == .builtInMic ? "iphone" : "headphones")
                .font(.body)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Theme.secondaryInk)
                .accessibilityLabel("Input: \(input.label)")
                .accessibilityIdentifier("session.input")
        }
    }

    /// One line under the state, kept while a session runs so the card keeps its height (`reservesDetailLine`).
    @ViewBuilder
    private func detail(_ state: SessionCardState) -> some View {
        switch state {
        case .ready:
            if let expiresAt = host.sessionExpiresAt {
                HStack(spacing: 5) {
                    Image(systemName: SessionActivityState.countdownSymbol)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityLabel(SessionActivityState.countdownSpokenLead)
                    Text("\(Text(timerInterval: min(Date.now, expiresAt) ... expiresAt, countsDown: true, showsHours: false)) \(SessionActivityState.lockScreenCountdownTail)")
                }
            } else {
                Text(verbatim: " ")
            }
        case .listening:
            if host.dictation?.phase == .recording, let startedAt = host.dictation?.startedAt {
                HStack(spacing: 6) {
                    Circle().fill(Theme.coral).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                }
            } else {
                Text(verbatim: " ")
            }
        default:
            Text(verbatim: " ").accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func action(_ state: SessionCardState) -> some View {
        switch state {
        case .off, .starting:
            Button {
                host.startSession()
            } label: {
                HStack(spacing: 10) {
                    RidgeMarkView(dot: Theme.aurora, side: min(pillMarkSide, 30))
                    Text("Start session")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state == .starting)
            .accessibilityIdentifier("session.start")
        case .microphoneOff:
            Button {
                AppIdentity.openSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("session.openSettings")
        case .ready, .listening, .transcribing, .preparing:
            Button {
                host.endSession()
            } label: {
                Label("End session", systemImage: "stop.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("session.end")
        }
    }
}

/// A row's glyph and title. At accessibility sizes the glyph stops growing beside the wrapping title.
private struct RowLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: 14) {
            SymbolTile(systemName: symbol)
            Text(title)
        }
        .padding(.vertical, 2)
    }
}

/// A keyboard setting that works only with Full Access: a small lock after its title.
private struct FullAccessToggle: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint("Needs Full Access")
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
