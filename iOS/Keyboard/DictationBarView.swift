import SwiftUI
import UIKit

/// Top-row state that belongs to the UI, not the dictation protocol.
@MainActor
final class KeyboardChrome: ObservableObject {
    @Published var isMenuOpen = false
}

/// The top row, modeled on Wispr Flow's keyboard (ARCHITECTURE.md, "Top row"): a menu button on
/// the left, Undo / "Insert last dictation" chips or a one-line status in the middle, and the
/// Start capsule on the right, which becomes a red Stop capsule with live level bars while
/// recording. It renders `KeyboardDictationClient.state` only, so typing never re-renders it.
struct DictationBarView: View {
    @ObservedObject var client: KeyboardDictationClient
    @ObservedObject var chrome: KeyboardChrome
    var onMenu: () -> Void
    /// Any other bar action also closes the menu.
    var onAction: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let compact = verticalSizeClass == .compact
        let state = client.state
        let height: CGFloat = compact ? 32 : 38
        HStack(spacing: 8) {
            Button(action: onMenu) {
                Image(systemName: chrome.isMenuOpen ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: height, height: height)
                    .background(Circle().fill(chrome.isMenuOpen ? Color(uiColor: KeyPalette.fill) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(chrome.isMenuOpen ? "Close menu" : "LocalFlow menu")
            .accessibilityIdentifier("lf.menu")

            Middle(client: client, state: state, height: height - 8, onAction: onAction)
                .frame(maxWidth: .infinity, alignment: .leading)

            if state.mode.isInProgress {
                Button {
                    onAction()
                    client.cancelTapped()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: height - 6, height: height - 6)
                        .background(Circle().fill(Color(uiColor: KeyPalette.fill)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Cancel dictation")
                .accessibilityIdentifier("lf.cancel")
            }
            StartCapsule(client: client, state: state, height: height, onAction: onAction, onUnavailable: onMenu)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: state.canUndo)
        .animation(.easeOut(duration: 0.2), value: state.canInsertLast)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// Chips when there is something to act on, and a notice whenever one is up; otherwise one line of
/// status.
private struct Middle: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let height: CGFloat
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if state.canUndo, !state.mode.isInProgress {
                Chip(title: "Undo", symbol: "arrow.uturn.backward", height: height) {
                    onAction()
                    client.undoLastDictation()
                }
                .accessibilityLabel("Undo last dictation")
                .accessibilityIdentifier("lf.undo")
            }
            if state.canInsertLast, !state.mode.isRecording {
                Chip(title: "Insert last", symbol: "text.insert", height: height) {
                    onAction()
                    client.insertLastDictation()
                }
                .accessibilityLabel("Insert last dictation")
                .accessibilityIdentifier("lf.insertLast")
            }
            if let notice = state.notice {
                // Notices render on their own, ahead of any idle hint or status, in every mode.
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("lf.notice")
            } else if !(state.canUndo && !state.mode.isInProgress), !(state.canInsertLast && !state.mode.isRecording),
                      let status = statusLine {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(state.mode.needsAttention ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("lf.status")
            }
        }
    }

    /// Ready and idle show only the model or session hint; everything else its one-line title.
    private var statusLine: String? {
        switch state.mode {
        case .ready: return state.hint
        default: return state.title.isEmpty ? nil : state.title
        }
    }
}

private struct Chip: View {
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

/// The primary control: "Start" with a waveform glyph, a red "Stop" with live levels and the elapsed
/// time while starting or recording, and a spinner while transcribing.
private struct StartCapsule: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let height: CGFloat
    let onAction: () -> Void
    /// Dictation cannot run here (no Full Access, configuration, versions): show why instead.
    let onUnavailable: () -> Void

    var body: some View {
        Button {
            if state.mode.allowsDictation {
                onAction()
                client.micTapped()
            } else {
                onUnavailable()
            }
        } label: {
            content
                .padding(.horizontal, 14)
                .frame(minWidth: height * 2.4, minHeight: height, maxHeight: height)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        // Not `.disabled`, which would dim the spinner; the client ignores taps it cannot act on.
        .allowsHitTesting(state.mode != .transcribing)
        .opacity(state.mode.allowsDictation ? 1 : 0.45)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.mode.isActiveCapture)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(state.mode == .hostUnavailable ? "Opens LocalFlow to start a session" : "")
        .accessibilityIdentifier("lf.mic")
    }

    @ViewBuilder private var content: some View {
        switch state.mode {
        case .recording(_, let startedAt):
            HStack(spacing: 7) {
                Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                LevelBars(levels: state.levels, height: height * 0.45)
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
        case .starting:
            HStack(spacing: 7) {
                ProgressView().tint(.white).controlSize(.small)
                Text("Stop").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
        case .transcribing:
            ProgressView().tint(foreground).controlSize(.small)
        default:
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
                Text("Start").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(foreground)
        }
    }

    /// A white capsule on the dark keyboard and a black one on the light keyboard, like Wispr's.
    private var fill: Color {
        state.mode.isActiveCapture ? .red : .primary
    }

    private var foreground: Color { Color(uiColor: .systemBackground) }

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
    static let count = 8
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

/// The menu: session status, "Open LocalFlow", the trackpad tip, and details of anything that keeps
/// dictation from working. A tap outside the card closes it.
struct MenuPanelView: View {
    @ObservedObject var client: KeyboardDictationClient
    var onClose: () -> Void
    private let keyboardName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalFlow"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Label(client.state.sessionSummary, systemImage: "waveform.circle")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("lf.menu.session")
                if let details {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    onClose()
                    client.openLocalFlow()
                } label: {
                    Label("Open LocalFlow", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("lf.menu.open")
                Label(KeyboardMessages.trackpadTip, systemImage: "hand.point.up.left")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: KeyPalette.fill)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityAddTraits(.isModal)
    }

    /// The full explanation for the states the top row condenses to one line.
    private var details: String? {
        switch client.state.mode {
        case .needsFullAccess:
            return KeyboardMessages.fullAccessExplanation + " "
                + KeyboardMessages.fullAccessSteps(keyboardName: keyboardName)
        case .configurationError: return KeyboardMessages.configurationErrorDetail
        case .incompatible: return KeyboardMessages.incompatibleDetail
        case .error, .hostUnavailable: return client.state.title
        default: return nil
        }
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

    /// Starting or recording: the capsule is the red Stop.
    var isActiveCapture: Bool {
        switch self {
        case .starting, .recording: return true
        default: return false
        }
    }

    /// Dictation can be started or explained by the Start capsule.
    var allowsDictation: Bool {
        switch self {
        case .needsFullAccess, .configurationError, .incompatible: return false
        default: return true
        }
    }

    var needsAttention: Bool {
        switch self {
        case .error, .needsFullAccess, .configurationError, .incompatible: return true
        default: return false
        }
    }
}
