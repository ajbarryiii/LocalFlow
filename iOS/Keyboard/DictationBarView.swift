import SwiftUI
import UIKit

/// The dictation bar above the keys: status, Undo, "Insert last dictation", cancel, and the mic
/// that morphs into a stop capsule with live level bars. It renders `KeyboardDictationClient.state`
/// only, so typing never re-renders it.
struct DictationBarView: View {
    @ObservedObject var client: KeyboardDictationClient
    var onInfo: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let compact = verticalSizeClass == .compact
        let state = client.state
        let control: CGFloat = compact ? 34 : 40
        HStack(spacing: 8) {
            StatusBlock(state: state, onInfo: onInfo)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.canUndo, !state.mode.isInProgress {
                BarPill(title: "Undo", symbol: "arrow.uturn.backward", height: control - 8) { client.undoLastDictation() }
                    .accessibilityLabel("Undo last dictation")
                    .accessibilityIdentifier("lf.undo")
            }
            if state.canInsertLast, !state.mode.isRecording {
                BarPill(title: "Insert last", symbol: "text.insert", height: control - 8) { client.insertLastDictation() }
                    .accessibilityLabel("Insert last dictation")
                    .accessibilityIdentifier("lf.insertLast")
            }
            if state.mode.isInProgress {
                Button { client.cancelTapped() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: control * 0.36, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: control - 6, height: control - 6)
                        .background(Circle().fill(Color(uiColor: KeyPalette.fill)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Cancel dictation")
                .accessibilityIdentifier("lf.cancel")
            }
            if state.mode.allowsDictation {
                MicButton(client: client, state: state, size: control)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: state.canUndo)
        .animation(.easeOut(duration: 0.2), value: state.canInsertLast)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

private struct StatusBlock: View {
    let state: KeyboardViewState
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let hint = state.hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !state.mode.allowsDictation {
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                }
                .accessibilityLabel("How to fix this")
                .accessibilityIdentifier("lf.info")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        switch state.mode {
        case .ready: return .green
        case .recording: return .red
        case .starting, .transcribing: return .blue
        case .error, .needsFullAccess, .configurationError, .incompatible: return .orange
        case .hostUnavailable: return .gray
        }
    }
}

private struct BarPill: View {
    let title: String
    let symbol: String
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(Capsule().fill(Color(uiColor: KeyPalette.fill)))
                .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
        }
        .buttonStyle(PressableStyle())
        .fixedSize()
    }
}

/// A mic that morphs into a stop capsule with live level bars and the elapsed time.
private struct MicButton: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let size: CGFloat

    var body: some View {
        Button { client.micTapped() } label: {
            content
                .foregroundStyle(.white)
                .frame(minWidth: size, minHeight: size, maxHeight: size)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        // Not `.disabled`, which would dim the spinner; the client ignores taps it cannot act on.
        .allowsHitTesting(isEnabled)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.mode.isRecording)
        .accessibilityRemoveTraits(isEnabled ? [] : .isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(state.mode == .hostUnavailable ? "Opens LocalFlow to start a session" : "")
        .accessibilityIdentifier("lf.mic")
    }

    @ViewBuilder private var content: some View {
        switch state.mode {
        case .recording(_, let startedAt):
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .font(.system(size: size * 0.3, weight: .bold))
                LevelBars(levels: state.levels, height: size * 0.5)
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, size * 0.35)
        case .starting, .transcribing:
            ProgressView()
                .tint(.white)
        default:
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
        }
    }

    private var fill: Color {
        switch state.mode {
        case .recording: return .red
        case .starting, .transcribing: return Color.accentColor.opacity(0.75)
        default: return .accentColor
        }
    }

    private var isEnabled: Bool {
        switch state.mode {
        case .ready, .hostUnavailable, .error, .starting, .recording: return true
        case .transcribing, .needsFullAccess, .configurationError, .incompatible: return false
        }
    }

    private var accessibilityLabel: String {
        switch state.mode {
        case .starting, .recording: return "Stop dictation"
        case .transcribing: return "Transcribing"
        default: return "Start dictation"
        }
    }

    private var accessibilityValue: String {
        switch state.mode {
        case .starting: return "Starting"
        case .recording(_, let startedAt):
            let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            return "Recording, " + Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        default: return ""
        }
    }
}

private struct LevelBars: View {
    static let count = 12
    let levels: [Float]
    let height: CGFloat

    var body: some View {
        let recent = levels.suffix(Self.count)
        let padded = Array(repeating: Float(0), count: Self.count - recent.count) + recent
        HStack(spacing: 2) {
            ForEach(0 ..< padded.count, id: \.self) { index in
                Capsule().frame(width: 2.5, height: max(2.5, height * CGFloat(padded[index])))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

/// Explains, over the keys, why dictation is unavailable and how to fix it. Typing still works.
struct InfoPanelView: View {
    @ObservedObject var client: KeyboardDictationClient
    var onClose: () -> Void
    private let keyboardName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalFlow"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(client.state.title).font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch client.state.mode {
                    case .needsFullAccess:
                        Text(KeyboardMessages.fullAccessExplanation)
                        Text(KeyboardMessages.fullAccessSteps(keyboardName: keyboardName)).foregroundStyle(.secondary)
                    case .configurationError:
                        Text(KeyboardMessages.configurationErrorDetail)
                    case .incompatible:
                        Text(KeyboardMessages.incompatibleDetail)
                    default:
                        Text(client.state.title)
                    }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("lf.info.done")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: KeyPalette.fill)))
        .padding(6)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension KeyboardMode {
    var isInProgress: Bool {
        switch self {
        case .starting, .recording, .transcribing: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Dictation can run, or at least be explained by the mic; otherwise the bar shows an info button.
    var allowsDictation: Bool {
        switch self {
        case .needsFullAccess, .configurationError, .incompatible: return false
        default: return true
        }
    }
}
