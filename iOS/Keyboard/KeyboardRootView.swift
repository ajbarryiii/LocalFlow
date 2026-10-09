import SwiftUI
import UIKit

/// The dictation pad. It renders `KeyboardDictationClient.state` and forwards taps; the decisions
/// live in the client and in Shared.
struct KeyboardRootView: View {
    @ObservedObject var client: KeyboardDictationClient
    @ObservedObject var keys: KeyboardKeys
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let compact = verticalSizeClass == .compact
        VStack(spacing: compact ? 4 : 8) {
            StatusLine(state: client.state)
            Group {
                switch client.state.mode {
                case .needsFullAccess:
                    FullAccessBanner()
                case .configurationError:
                    Banner(symbol: "exclamationmark.triangle", text: KeyboardMessages.configurationErrorDetail)
                case .incompatible:
                    Banner(symbol: "arrow.triangle.2.circlepath", text: KeyboardMessages.incompatibleDetail)
                default:
                    DictationPad(client: client, state: client.state, compact: compact)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            KeyRow(keys: keys, compact: compact)
        }
        .padding(.horizontal, 4)
        .padding(.top, compact ? 4 : 8)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

// MARK: Dictation

private struct StatusLine: View {
    let state: KeyboardViewState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(state.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            if let hint = state.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
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

private struct DictationPad: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let compact: Bool

    var body: some View {
        let micSize: CGFloat = compact ? 56 : 80
        let sideSize: CGFloat = compact ? 36 : 44
        let inProgress = state.mode.isInProgress
        VStack(spacing: compact ? 4 : 8) {
            HStack(spacing: 20) {
                Button { client.cancelTapped() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: sideSize * 0.36, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: sideSize, height: sideSize)
                        .background(Circle().fill(KeyPalette.function))
                }
                .buttonStyle(PressableStyle())
                .opacity(inProgress ? 1 : 0)
                .disabled(!inProgress)
                .accessibilityHidden(!inProgress)
                .accessibilityLabel("Cancel dictation")
                MicButton(client: client, state: state, size: micSize)
                // Balances the cancel button so the mic stays centered.
                Color.clear.frame(width: sideSize, height: sideSize)
            }
            .frame(maxHeight: .infinity)
            Button { client.insertLastDictation() } label: {
                Label("Insert last dictation", systemImage: "text.insert")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .background(Capsule().fill(KeyPalette.character).shadow(color: KeyPalette.shadow, radius: 0, y: 1))
            }
            .buttonStyle(PressableStyle())
            .frame(height: compact ? 26 : 30)
            .opacity(state.canInsertLast ? 1 : 0)
            .disabled(!state.canInsertLast)
            .accessibilityHidden(!state.canInsertLast)
            .animation(.easeOut(duration: 0.2), value: state.canInsertLast)
        }
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
    }

    @ViewBuilder private var content: some View {
        switch state.mode {
        case .recording(_, let startedAt):
            HStack(spacing: 10) {
                Image(systemName: "stop.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                LevelBars(levels: state.levels, height: size * 0.42)
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, size * 0.28)
        case .starting, .transcribing:
            ProgressView()
                .tint(.white)
        default:
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
        }
    }

    private var fill: Color {
        switch state.mode {
        case .recording: return .red
        case .starting, .transcribing: return Color.accentColor.opacity(0.75)
        case .ready, .hostUnavailable, .error: return .accentColor
        case .needsFullAccess, .configurationError, .incompatible: return .gray
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
    let levels: [Float]
    let height: CGFloat

    var body: some View {
        let count = KeyboardDictationClient.levelHistoryCount
        let recent = levels.suffix(count)
        let padded = Array(repeating: Float(0), count: count - recent.count) + recent
        HStack(spacing: 2.5) {
            ForEach(0..<padded.count, id: \.self) { index in
                Capsule().frame(width: 3, height: max(3, height * CGFloat(padded[index])))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

private struct FullAccessBanner: View {
    private let keyboardName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalFlow"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(KeyboardMessages.fullAccessExplanation)
                Text(KeyboardMessages.fullAccessSteps(keyboardName: keyboardName))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KeyPalette.character.opacity(0.7)))
        .padding(.horizontal, 4)
    }
}

private struct Banner: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KeyPalette.character.opacity(0.7)))
        .padding(.horizontal, 4)
    }
}

// MARK: Keys

private struct KeyRow: View {
    @ObservedObject var keys: KeyboardKeys
    let compact: Bool

    var body: some View {
        let returnType = keys.returnKeyType
        HStack(spacing: 6) {
            if keys.showsGlobeKey {
                GlobeKey(controller: keys.controller)
                    .frame(width: 46)
                    .frame(maxHeight: .infinity)
                    .background(KeyCap(fill: KeyPalette.function))
            }
            Button { keys.insertSpace() } label: { Text("space") }
                .buttonStyle(KeyStyle(fill: KeyPalette.character))
                .accessibilityLabel("Space")
            DeleteKey(keys: keys)
                .frame(width: 56)
            Button { keys.pressReturn() } label: {
                if let title = returnType.keyTitle {
                    Text(title)
                } else {
                    Image(systemName: "return")
                }
            }
            .buttonStyle(KeyStyle(fill: returnType.isProminent ? .accentColor : KeyPalette.function,
                                  foreground: returnType.isProminent ? .white : .primary))
            .frame(width: 92)
            .accessibilityLabel(returnType.keyTitle ?? "Return")
        }
        .frame(height: compact ? 36 : 44)
    }
}

/// Deletes on touch-down, then auto-repeats while held. `@GestureState` resets when the gesture
/// ends or is cancelled, so the repeat always stops.
private struct DeleteKey: View {
    let keys: KeyboardKeys
    @GestureState private var isPressed = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyCap(fill: KeyPalette.function, isPressed: isPressed))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in pressed = true })
            .onChange(of: isPressed) { _, pressed in
                if pressed { keys.beginDeleteRepeat() } else { keys.endDeleteRepeat() }
            }
            .onDisappear { keys.endDeleteRepeat() }
            .accessibilityElement()
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { keys.deleteBackward() }
    }
}

/// UIKit, because `handleInputModeList(from:with:)` needs the touch events: a tap switches to the
/// next keyboard and touch-and-hold shows the list, as on the system globe key.
private struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)),
                        for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Next keyboard"
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}

private struct KeyStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyCap(fill: fill, isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }
}

private struct KeyCap: View {
    var fill: Color
    var isPressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
            .fill(fill)
            .overlay(shape.fill(Color.primary.opacity(isPressed ? 0.15 : 0)))
            .shadow(color: KeyPalette.shadow, radius: 0, y: 1)
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

private enum KeyPalette {
    static let character = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    })
    static let function = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    })
    static let shadow = Color.black.opacity(0.3)
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
}
