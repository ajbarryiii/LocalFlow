import SwiftUI

/// Shown when the keyboard opened the app to start a dictation. "Starting…" until input buffers flow
/// (the dictation is `recording`), then "Listening — swipe back to your app".
struct BounceView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 56)
            content
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .id(phaseKey)
            Spacer(minLength: 12)

            if transcriber.modelState == .preparing, let started = transcriber.preparationStartedAt, inProgress {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Preparing the speech model", systemImage: "cpu").font(.subheadline.weight(.semibold))
                    Text(phase == .transcribing ? "Your dictation will be transcribed as soon as it is ready."
                         : "Your dictation will be transcribed as soon as it is ready. You can keep talking.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PreparationProgress(startedAt: started, estimate: transcriber.estimatedPreparationSeconds)
                }
                .padding(16)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            buttons
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(background.ignoresSafeArea())
        .animation(.snappy, value: phaseKey)
        .accessibilityIdentifier("bounce")
    }

    private var phase: DictationStatus.Phase? { host.dictation?.phase }
    private var inProgress: Bool { host.isDictationInProgress }
    private var phaseKey: String { phase?.rawValue ?? "none" }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .recording?:
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Theme.live.opacity(0.12)).frame(width: 150, height: 150)
                        .scaleEffect(1 + CGFloat(host.level) * 0.18)
                        .animation(.easeOut(duration: 0.15), value: host.level)
                    LevelBars(level: host.level)
                }
                VStack(spacing: 8) {
                    Text("Listening").font(.largeTitle.bold()).fontDesign(.rounded)
                    subtitle("Swipe back to your app and keep talking.")
                }
                SwipeBackHint()
            }
        case .transcribing?:
            VStack(spacing: 22) {
                HeroSymbol(systemName: "text.bubble.fill", size: 88)
                ProgressView().controlSize(.large)
                Text("Transcribing…").font(.title.bold()).fontDesign(.rounded)
                subtitle("Swipe back to your app; the text is inserted there.")
            }
        case .completed?:
            VStack(spacing: 18) {
                HeroSymbol(systemName: "checkmark", tint: AnyShapeStyle(Color.green), size: 88)
                Text("Done").font(.largeTitle.bold()).fontDesign(.rounded)
                subtitle("Swipe back to your app to insert the text.")
                SwipeBackHint()
            }
        case .failed?, .cancelled?:
            VStack(spacing: 18) {
                HeroSymbol(systemName: phase == .cancelled && host.dictation?.error == nil ? "xmark" : "exclamationmark",
                           tint: AnyShapeStyle(Color.orange), size: 88)
                Text(phase == .cancelled ? "Dictation cancelled" : "Dictation stopped")
                    .font(.title.bold()).fontDesign(.rounded)
                if let error = host.dictation?.error {
                    subtitle(error.message)
                }
            }
        case .starting?, nil:
            VStack(spacing: 22) {
                HeroSymbol(systemName: "mic.fill", size: 88)
                ProgressView().controlSize(.large)
                Text("Starting…").font(.largeTitle.bold()).fontDesign(.rounded)
                subtitle(host.session == .starting && host.microphonePermission == .undetermined
                         ? "Allow the microphone to start dictating." : "Getting the microphone ready.")
            }
        }
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .recording?:
            HStack(spacing: 12) {
                Button("Cancel") { host.cancelDictation() }
                    .buttonStyle(SecondaryButtonStyle(tint: .secondary))
                    .accessibilityIdentifier("bounce.cancel")
                Button {
                    host.stopDictation()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("bounce.stop")
            }
        case .starting?, .transcribing?:
            Button("Cancel") { host.cancelDictation() }
                .buttonStyle(SecondaryButtonStyle(tint: .secondary))
                .accessibilityIdentifier("bounce.cancel")
        default:
            Button("Close") { host.bounceVisible = false }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("bounce.close")
        }
    }

    private var background: some View {
        ZStack {
            Theme.screenBackground
            RadialGradient(colors: [(phase == .recording ? Theme.live : Theme.violet).opacity(0.16), .clear],
                           center: .top, startRadius: 20, endRadius: 520)
        }
    }
}

/// Where to swipe: the system "◀ App" control at the top left, or the home indicator.
struct SwipeBackHint: View {
    @State private var animate = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 2)
                VStack {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Your app")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.blue.opacity(0.12), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    ZStack {
                        Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 70, height: 5)
                        Circle()
                            .fill(Theme.violet.opacity(0.45))
                            .frame(width: 24, height: 24)
                            .offset(x: animate ? 48 : -48)
                            .opacity(animate ? 0.2 : 1)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.violet)
                            .offset(x: 52, y: -16)
                    }
                }
                .padding(12)
            }
            .frame(width: 150, height: 100)
            Text("Tap \(Image(systemName: "chevron.left")) at the top left, or swipe right along the bottom edge.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { animate = true }
        }
        .accessibilityElement(children: .combine)
    }
}
