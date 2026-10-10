import SwiftUI

enum Theme {
    static let violet = Color(red: 0.45, green: 0.33, blue: 0.96)
    static let blue = Color(red: 0.25, green: 0.47, blue: 0.98)
    /// Matches the system's microphone-in-use indicator.
    static let live = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let gradient = LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
}

/// The app's name as installed ("LocalFlow Dev" for development builds), for setup instructions.
enum AppIdentity {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalFlow"
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.gradient)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.violet

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
    }
}

/// A rounded symbol tile used for headers and list rows.
struct SymbolTile: View {
    var systemName: String
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.gradient)
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// A large glowing symbol for hero areas.
struct HeroSymbol: View {
    var systemName: String
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.gradient)
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle().fill(tint).opacity(0.18).frame(width: size * 1.45, height: size * 1.45).blur(radius: 18)
            Circle().fill(tint).frame(width: size, height: size)
                .shadow(color: Theme.violet.opacity(0.35), radius: 16, y: 8)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

/// Live input level as rounded bars, the shape the keyboard also uses.
struct LevelBars: View {
    var level: Float
    var count = 9
    var color: Color = Theme.live

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 6, height: height(for: index))
            }
        }
        .frame(height: 56)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel("Input level")
    }

    private func height(for index: Int) -> CGFloat {
        // A centered envelope, so the bars read as a voice rather than an equalizer.
        let center = Double(count - 1) / 2
        let envelope = 1 - abs(Double(index) - center) / (center + 1)
        let value = max(0.12, Double(min(max(level, 0), 1)) * envelope)
        return CGFloat(8 + value * 48)
    }
}

/// A softly pulsing dot for "live" states.
struct PulsingDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

/// Model state with honest preparation progress: elapsed time, and an estimate only when this device
/// has prepared the model before.
struct ModelStatusRow: View {
    @ObservedObject var transcriber: ParakeetTranscriber
    var showsPrepareButton = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SymbolTile(systemName: symbol, tint: AnyShapeStyle(tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speech model").font(.subheadline.weight(.semibold))
                    Text(title).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if showsPrepareButton, transcriber.modelState == .notPrepared || transcriber.modelState == .failed {
                    Button(transcriber.modelState == .failed ? "Retry" : "Prepare") { transcriber.prepare() }
                        .buttonStyle(.bordered)
                        .tint(Theme.violet)
                        .accessibilityIdentifier("model.prepare")
                }
            }
            if transcriber.modelState == .preparing, let started = transcriber.preparationStartedAt {
                PreparationProgress(startedAt: started, estimate: transcriber.estimatedPreparationSeconds)
            }
            if let hint = transcriber.lastFailureHint {
                Label(hint.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var title: String {
        switch transcriber.modelState {
        case .unavailable: return "Not included in this build"
        case .notPrepared: return "Not prepared yet"
        case .preparing: return "Preparing on this iPhone…"
        case .ready: return "Ready · runs on this iPhone"
        case .failed: return "Preparation failed"
        }
    }

    private var symbol: String {
        switch transcriber.modelState {
        case .unavailable: return "shippingbox"
        case .notPrepared: return "cpu"
        case .preparing: return "hourglass"
        case .ready: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch transcriber.modelState {
        case .ready: return .green
        case .failed, .unavailable: return .orange
        default: return Theme.violet
        }
    }
}

struct PreparationProgress: View {
    var startedAt: Date
    var estimate: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            VStack(alignment: .leading, spacing: 6) {
                if let estimate {
                    ProgressView(value: min(elapsed / estimate, 0.95))
                        .tint(Theme.violet)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.violet)
                }
                Text(caption(elapsed: elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func caption(elapsed: Double) -> String {
        let elapsedText = Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond))
        if let estimate {
            let estimateText = Duration.seconds(Int(estimate.rounded())).formatted(.time(pattern: .minuteSecond))
            return "\(elapsedText) elapsed · last time took \(estimateText)"
        }
        return "\(elapsedText) elapsed · this can take a few minutes"
    }
}

extension HostErrorCode {
    /// Short, content-free explanations for the UI.
    var message: String {
        switch self {
        case .microphonePermissionDenied: return "Microphone access is off. Turn it on in Settings."
        case .audioSessionFailed: return "The microphone could not start."
        case .startupTimeout: return "The microphone took too long to start."
        case .interrupted: return "Another app or a call interrupted the microphone."
        case .deviceLocked: return "The iPhone was locked."
        case .keyboardDismissed: return "The keyboard was closed, so recording stopped."
        case .sessionInactive: return "The session ended."
        case .modelUnavailable: return "This build has no speech model."
        case .modelFailed: return "The speech model could not be prepared."
        case .transcriptionFailed: return "Transcription failed."
        case .backgroundTimeExpired: return "iOS stopped the transcription in the background."
        case .notRecording: return "Nothing was recorded."
        case .tooLong: return "The dictation was too long."
        case .superseded: return "A newer dictation replaced this one."
        }
    }
}
