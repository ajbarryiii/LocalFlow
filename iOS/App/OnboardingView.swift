import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, keyboard, model
}

/// First run: the privacy promise, microphone permission, enabling the keyboard, and preparing the model.
struct OnboardingView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber
    @State var step: OnboardingStep
    var onFinish: () -> Void

    @State private var permission = CapturePermission.undetermined
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Theme.screenBackground.ignoresSafeArea())
        .onAppear(perform: refreshSetupState)
        .onChange(of: scenePhase) { refreshSetupState() }   // back from Settings
    }

    private var header: some View {
        HStack {
            Button {
                go(to: OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome)
            } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)
            .accessibilityLabel("Back")
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                        .frame(width: item == step ? 28 : 8, height: 8)
                }
            }
            .animation(.snappy, value: step)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .tint(Theme.violet)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .microphone: microphone
        case .keyboard: keyboard
        case .model: model
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            HeroSymbol(systemName: "waveform").padding(.top, 16)
            VStack(spacing: 8) {
                Text("LocalFlow").font(.largeTitle.bold()).fontDesign(.rounded)
                Text("Dictate into any app with your voice, from the LocalFlow keyboard.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PrivacyPromiseCard()
        }
    }

    private var microphone: some View {
        VStack(spacing: 22) {
            HeroSymbol(systemName: "mic.fill").padding(.top, 16)
            StepTitle(title: "Allow the microphone",
                      detail: "LocalFlow listens only during a session you start, and keeps audio only while you dictate. It is transcribed on this iPhone and then discarded.")
            HStack(spacing: 12) {
                SymbolTile(systemName: permissionSymbol, tint: AnyShapeStyle(permissionTint))
                Text(permissionText).font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(16)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var keyboard: some View {
        VStack(spacing: 22) {
            HeroSymbol(systemName: "keyboard.fill").padding(.top, 16)
            StepTitle(title: "Add the LocalFlow keyboard",
                      detail: "Dictate anywhere you type: switch to the LocalFlow keyboard with the globe key and tap the microphone.")
            KeyboardSetupSteps { host.keyboardHasFullAccess }
        }
    }

    private var model: some View {
        VStack(spacing: 22) {
            HeroSymbol(systemName: "cpu").padding(.top, 16)
            StepTitle(title: "Prepare the speech model",
                      detail: "The speech model runs entirely on this iPhone. Preparing it optimizes it for this device: the first time after installing can take a few minutes, and later it is usually quick.")
            ModelStatusRow(transcriber: transcriber, showsPrepareButton: false)
                .padding(16)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 10) {
            switch step {
            case .welcome:
                Button("Get started") { go(to: .microphone) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.start")
            case .microphone:
                switch permission {
                case .undetermined:
                    Button("Allow microphone") {
                        Task {
                            _ = await host.requestMicrophonePermission()
                            refreshSetupState()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.allowMicrophone")
                    Button("Not now") { go(to: .keyboard) }.buttonStyle(SecondaryButtonStyle())
                case .granted:
                    Button("Continue") { go(to: .keyboard) }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.continue")
                case .denied:
                    Button("Open Settings") { AppIdentity.openSettings() }.buttonStyle(PrimaryButtonStyle())
                    Button("Continue") { go(to: .keyboard) }.buttonStyle(SecondaryButtonStyle())
                }
            case .keyboard:
                Button("Open Settings") { AppIdentity.openSettings() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.openSettings")
                Button("Continue") { go(to: .model) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("onboarding.continue")
            case .model:
                switch transcriber.modelState {
                case .notPrepared, .failed:
                    Button(transcriber.modelState == .failed ? "Try again" : "Prepare now") { host.prepareModel() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.prepare")
                    Button("Later") { onFinish() }.buttonStyle(SecondaryButtonStyle())
                case .preparing:
                    Button("Continue while it prepares") { onFinish() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("onboarding.finish")
                case .ready, .unavailable:
                    Button("Done") { onFinish() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.finish")
                }
            }
        }
    }

    private func go(to next: OnboardingStep) {
        withAnimation(.snappy) { step = next }
        refreshSetupState()
    }

    private func refreshSetupState() {
        permission = host.microphonePermission
    }

    private var permissionText: String {
        switch permission {
        case .granted: return "Microphone allowed"
        case .denied: return "Microphone is off for LocalFlow in Settings"
        case .undetermined: return "Not allowed yet"
        }
    }

    private var permissionSymbol: String {
        switch permission {
        case .granted: return "checkmark"
        case .denied: return "mic.slash.fill"
        case .undetermined: return "mic"
        }
    }

    private var permissionTint: Color {
        switch permission {
        case .granted: return .green
        case .denied: return .orange
        case .undetermined: return Theme.violet
        }
    }
}

private struct StepTitle: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.title.bold()).fontDesign(.rounded).multilineTextAlignment(.center)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

struct PrivacyPromiseCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Everything stays on this iPhone").font(.headline)
            } icon: {
                Image(systemName: "lock.shield.fill").foregroundStyle(Theme.gradient)
            }
            PromiseRow(symbol: "waveform", text: "Speech is recognized on this iPhone, never on a server.")
            PromiseRow(symbol: "trash", text: "Audio is never saved; it is discarded as soon as it is transcribed.")
            PromiseRow(symbol: "network.slash", text: "No account, no analytics, no network access.")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct PromiseRow: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.violet).frame(width: 22)
            Text(text).font(.subheadline).foregroundStyle(.primary.opacity(0.85))
        }
    }
}

/// The Settings path to enable the keyboard and Full Access, shared by onboarding and Home.
struct KeyboardSetupSteps: View {
    /// Re-evaluated every second: it depends on how recently the keyboard was visible.
    var isConnected: @MainActor () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupStep(number: 1, text: "Tap **Open Settings** to open \(AppIdentity.displayName) in Settings.")
            SetupStep(number: 2, text: "Tap **Keyboards**.")
            SetupStep(number: 3, text: "Turn on **\(AppIdentity.displayName)**.")
            SetupStep(number: 4, text: "Turn on **Allow Full Access**.")
            Divider()
            Text("Full Access lets the keyboard talk to this app on your iPhone, to start dictation and pick up the text. LocalFlow has no network code; nothing leaves the device. Passwords and phone-number fields always use the system keyboard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if isConnected() {
                    Label("Keyboard active with Full Access", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SetupStep: View {
    var number: Int
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.gradient, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
