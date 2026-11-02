import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, keyboard, model
}

/// First run: the privacy promise, microphone permission, enabling the keyboard, and preparing the model. It ends on
/// Try it, so the first dictation is the next thing a person does.
struct OnboardingView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber
    @State var step: OnboardingStep
    var onFinish: () -> Void

    @State private var permission = CapturePermission.undetermined
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { proxy in
            // A small iPhone (the SE) or large text: no step glyph, so the instructions and the action fit.
            let compact = proxy.size.height < 700 || typeSize.isAccessibilitySize
            ScrollView {
                content(compact: compact)
                    .padding(.horizontal, 24)
                    .padding(.top, compact ? 8 : 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .id(step)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .top, spacing: 0) { header.background(Theme.screenBackground) }
            // What scrolls under the buttons fades out above them.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                buttons
                    // Pinned under the step: at the largest sizes it stops growing, so the step keeps room on a small iPhone.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .actionBarBackground()
            }
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
            .accessibilityHidden(step == .welcome)
            .accessibilityLabel("Back")
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    Capsule()
                        .fill(Color.white.opacity(item == step ? 1 : item.rawValue < step.rawValue ? 0.5 : 0.2))
                        .frame(width: item == step ? 22 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup")
            .accessibilityValue(OnboardingProgress.spoken(index: step.rawValue, count: OnboardingStep.allCases.count))
            .accessibilityIdentifier("onboarding.progress")
            Spacer()
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        switch step {
        case .welcome: welcome(compact: compact)
        case .microphone: microphone(compact: compact)
        case .keyboard: keyboard(compact: compact)
        case .model: model(compact: compact)
        }
    }

    // MARK: Steps

    private func welcome(compact: Bool) -> some View {
        VStack(spacing: compact ? 18 : 24) {
            RidgeMarkView(dot: Theme.aurora, side: compact ? 52 : 84)
                .padding(.top, compact ? 4 : 64)
            VStack(spacing: 8) {
                Text("LocalFlow")
                    .font(.display(.largeTitle))
                    .accessibilityAddTraits(.isHeader)
                StepLine("Dictate into any app.")
            }
            PrivacyPromiseCard()
                .padding(.top, compact ? 0 : 12)
        }
    }

    private func microphone(compact: Bool) -> some View {
        VStack(spacing: 22) {
            if !compact { HeroSymbol(systemName: "mic") }
            StepTitle(title: "Allow the microphone", line: "Only during a session you start.")
            HStack(spacing: 12) {
                SymbolTile(systemName: permissionSymbol, tint: permission == .denied ? Theme.ember : .white)
                Text(permissionText).font(.body.weight(.medium))
                Spacer(minLength: 0)
                StateDot(accent: permissionAccent)
            }
            .padding(16)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding.permission")
        }
    }

    private func keyboard(compact: Bool) -> some View {
        VStack(spacing: 22) {
            if !compact { HeroSymbol(systemName: "keyboard") }
            StepTitle(title: "Add the keyboard", line: "Then switch to it with \(Image(systemName: "globe")) in any app.")
            KeyboardSetupSteps { host.keyboardHasFullAccess }
        }
    }

    private func model(compact: Bool) -> some View {
        VStack(spacing: 22) {
            if !compact { HeroSymbol(systemName: "cpu") }
            StepTitle(title: "Prepare the speech model", line: "On this iPhone. A few minutes the first time.")
            ModelStatusRow(transcriber: transcriber, showsPrepareButton: false)
                .padding(16)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 6) {
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
                    Button("Try it") { onFinish() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.finish")
                }
            }
        }
    }

    private func go(to next: OnboardingStep) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { step = next }
        refreshSetupState()
    }

    private func refreshSetupState() {
        permission = host.microphonePermission
    }

    private var permissionText: String {
        switch permission {
        case .granted: return "Allowed"
        case .denied: return "Off in Settings"
        case .undetermined: return "Not allowed yet"
        }
    }

    private var permissionSymbol: String {
        switch permission {
        case .granted: return "mic"
        case .denied: return "mic.slash"
        case .undetermined: return "mic"
        }
    }

    private var permissionAccent: AppAccent? {
        switch permission {
        case .granted: return .aurora
        case .denied: return .ember
        case .undetermined: return nil
        }
    }
}

private struct StepTitle: View {
    var title: String
    var line: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.display(.title))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            StepLine(line)
        }
    }
}

/// A step's one line under its headline.
private struct StepLine: View {
    var text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Theme.secondaryInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The privacy promise as three glyphs with a few words each; side by side, or stacked at large text.
struct PrivacyPromiseCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            PromiseItem(symbol: "iphone", text: "On this iPhone")
            PromiseItem(symbol: "trash", text: "Audio discarded")
            PromiseItem(symbol: "network.slash", text: "No network")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PromiseItem: View {
    var symbol: String
    var text: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(height: 26)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
        }
        .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
    }
}

/// The Settings path to enable the keyboard and Full Access, shared by onboarding and Home.
struct KeyboardSetupSteps: View {
    /// Re-evaluated every second: it depends on how recently the keyboard was visible.
    var isConnected: @MainActor () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStep(number: 1, text: "Tap **Open Settings**")
            SetupStep(number: 2, text: "**Keyboards**")
            SetupStep(number: 3, text: "Turn on **\(AppIdentity.displayName)**")
            SetupStep(number: 4, text: "Turn on **Allow Full Access**")
            Divider().overlay(Color.white.opacity(0.08))
            Label("Full Access lets the keyboard reach this app. Nothing leaves your iPhone.", systemImage: "lock.fill")
                .labelStyle(LeadingGlyphLabelStyle())
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if isConnected() {
                    Label("Keyboard connected", systemImage: "checkmark")
                        .labelStyle(LeadingGlyphLabelStyle(tint: Theme.aurora))
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("setup.connected")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A glyph before wrapping words, aligned to their first line; the glyph may take an accent.
private struct LeadingGlyphLabelStyle: LabelStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(tint ?? Theme.secondaryInk).accessibilityHidden(true)
            configuration.title
        }
    }
}

private struct SetupStep: View {
    var number: Int
    var text: LocalizedStringKey
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .islandSurface(Circle())
                .accessibilityHidden(true)
            Text(text).font(.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): \(Text(text))"))
    }
}
