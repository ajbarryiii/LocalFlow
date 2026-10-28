import SwiftUI
import UIKit

/// Top-row state that belongs to the UI, not the dictation protocol.
@MainActor
final class KeyboardChrome: ObservableObject {
    @Published var isMenuOpen = false
    /// The layout profile the trackpad uses in this field, and its content-free fingerprint (the
    /// short key and the input traits) for the menu's readout.
    @Published var layout = FieldLayoutParameters.standard.defaultLayout
    @Published var fieldSummary = ""
}

/// The candidate strip after a swipe (ARCHITECTURE.md, "Typing model v4 and swipe typing"), published
/// only when it opens, changes or closes, so ordinary typing never re-renders the bar. Its words stay
/// in memory and go when the strip closes.
@MainActor
final class SwipeStripModel: ObservableObject {
    @Published private(set) var strip: SwipeStrip?

    func show(_ strip: SwipeStrip?) {
        if self.strip != strip { self.strip = strip }
    }
}

/// The offer to never correct a reverted word (ARCHITECTURE.md, "Word autocorrect", Never correct), published only
/// when it appears, changes or goes. Its word stays in memory and goes with the offer.
@MainActor
final class NeverCorrectPromptModel: ObservableObject {
    @Published private(set) var offer: NeverCorrectOffer?

    func show(_ offer: NeverCorrectOffer?) {
        if self.offer != offer { self.offer = offer }
    }
}

/// Where the bar's controls are, in the bar's coordinates (`DictationBarView` reports them as they lay out and
/// forgets them as they go), so the key area can take every other touch in the bar (ARCHITECTURE.md, "Reach
/// above the keys"). Read on touches; never published, so it re-renders nothing.
@MainActor
final class BarControlFrames {
    // An immutable name, read from SwiftUI's Sendable geometry closure.
    nonisolated static let space = "lf.bar"
    private var regions = BarControlRegions()

    /// The controls' frames now, with those a control left while it may still be animating there.
    var rects: [KeyRect] { regions.rects(now: CACurrentMediaTime()) }

    /// The control `id`'s frame now, without any it left.
    func frame(of id: String) -> KeyRect? { regions.frame(of: id) }

    func set(_ id: String, _ rect: KeyRect?) {
        regions.set(id, rect, now: CACurrentMediaTime())
    }
}

private extension View {
    /// Reports this control's tap area in the bar to `controls` while it is shown: its frame, or `area` of it for
    /// a control whose tap area differs from its look.
    func barControl(_ id: String, in controls: BarControlFrames,
                    area: @escaping @Sendable (KeyRect) -> KeyRect = { $0 }) -> some View {
        onGeometryChange(for: KeyRect.self) {
            let frame = $0.frame(in: .named(BarControlFrames.space))
            return area(KeyRect(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)))
        } action: {
            controls.set(id, $0)
        }
            .onDisappear { controls.set(id, nil) }
    }
}

/// The top row, modeled on Wispr Flow's keyboard (ARCHITECTURE.md, "Top row"): a menu button on
/// the left, Undo / "Insert last dictation" chips or a one-line status in the middle (the swipe
/// candidate strip instead while it shows, and over both a revert's "Never correct" offer unless dictation's
/// own UI is up), and the Start capsule on the right, which becomes a red
/// Stop capsule with live level bars while recording. It renders `KeyboardDictationClient.state` and
/// the strip only, so typing never re-renders it.
struct DictationBarView: View {
    @ObservedObject var client: KeyboardDictationClient
    @ObservedObject var chrome: KeyboardChrome
    @ObservedObject var swipe: SwipeStripModel
    @ObservedObject var neverCorrect: NeverCorrectPromptModel
    /// Where its controls are, for the key area.
    let controls: BarControlFrames
    var onMenu: () -> Void
    /// Any other bar action also closes the menu.
    var onAction: () -> Void
    /// A candidate of the strip was tapped.
    var onCandidate: (Int) -> Void
    /// The "Never correct" offer was tapped.
    var onNeverCorrect: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let compact = verticalSizeClass == .compact
        let state = client.state
        // The key area takes the bar away from the controls (`KeyboardMetrics.barPointGoesToKeys`).
        let height = CGFloat(compact ? KeyboardMetrics.compactBarControlHeight : KeyboardMetrics.barControlHeight)
        let barHeight = compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight
        let capturing = state.mode.isActiveCapture
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
            .barControl("menu", in: controls)

            Group {
                if let offer = neverCorrect.offer,
                   NeverCorrectOffer.barShows(offer, dictationInProgress: state.mode.isInProgress, dictationUndoShown: state.canUndo) {
                    NeverCorrectChip(word: offer.typed, height: height - 8) {
                        onAction()
                        onNeverCorrect()
                    }
                    .barControl("neverCorrect", in: controls)
                } else if let strip = swipe.strip {
                    CandidateStrip(strip: strip, height: height - 8) { index in
                        onAction()
                        onCandidate(index)
                    }
                    .barControl("strip", in: controls)
                } else {
                    Middle(client: client, state: state, height: height - 8, controls: controls, onAction: onAction)
                }
            }
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Cancel dictation")
                .accessibilityIdentifier("lf.cancel")
                .barControl("cancel", in: controls)
            }
            StartCapsule(client: client, state: state, height: height, compact: compact, onAction: onAction, onUnavailable: onMenu)
                .barControl("start", in: controls) {
                    KeyboardMetrics.startTapArea(capsule: $0, barHeight: barHeight, compact: compact, capturing: capturing)
                }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(barHeight))
        // The hosting view also reaches down behind the top row for Stop's tap area; only the bar is drawn.
        .background(Color(uiColor: KeyAreaView.touchableBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(BarControlFrames.space))
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
    let controls: BarControlFrames
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
                .barControl("undo", in: controls)
            }
            if state.canInsertLast, !state.mode.isRecording {
                Chip(title: "Insert last", symbol: "text.insert", height: height) {
                    onAction()
                    client.insertLastDictation()
                }
                .accessibilityLabel("Insert last dictation")
                .accessibilityIdentifier("lf.insertLast")
                .barControl("insertLast", in: controls)
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

/// Up to three candidates side by side (a swipe's, or autocorrect's after a commit key), as on Apple's
/// predictive bar; the one in the field now is emphasized. A tap replaces the inserted word (the editor
/// decides whether it still can).
private struct CandidateStrip: View {
    let strip: SwipeStrip
    let height: CGFloat
    let onCandidate: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(strip.candidates.enumerated()), id: \.offset) { index, word in
                if index > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: height * 0.6)
                        .accessibilityHidden(true)
                }
                Button {
                    onCandidate(index)
                } label: {
                    Text(word)
                        .font(.subheadline.weight(index == strip.inserted ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                        .background(Capsule().fill(index == strip.inserted ? Color(uiColor: KeyPalette.fill) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(word)
                .accessibilityAddTraits(index == strip.inserted ? .isSelected : [])
                .accessibilityIdentifier("lf.swipe.candidate.\(index)")
            }
        }
    }
}

/// "Never correct “word”": the word in the field after a revert, shown in full where it fits and shortened in the
/// middle where it does not.
private struct NeverCorrectChip: View {
    let word: String
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Never correct \u{201C}\(word)\u{201D}", systemImage: "text.badge.checkmark")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(Capsule().fill(Color(uiColor: KeyPalette.fill)))
                .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Never correct \(word)")
        .accessibilityHint("Autocorrect leaves this word alone from now on")
        .accessibilityIdentifier("lf.neverCorrect")
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
                .contentShape(Rectangle())
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
    let compact: Bool
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
                .contentShape(StartTapShape(compact: compact, capturing: state.mode.isActiveCapture))
        }
        .buttonStyle(PressableStyle())
        // Not `.disabled`, which would dim the spinner; the client ignores taps it cannot act on.
        .allowsHitTesting(!state.mode.isWaitingForTranscript)
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
        case .transcribing, .waitingForModel:
            HStack(spacing: 7) {
                ProgressView().tint(foreground).controlSize(.small)
                if let caption = KeyboardMessages.capsuleCaption(for: state.mode) {
                    Text(caption).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(foreground)
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
        case .waitingForModel: return "Preparing model"
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

/// The capsule's tap area (`KeyboardMetrics.startTapArea`) in its own coordinates; it looks the same. The capsule is
/// centred in the bar, so its top is `reachAboveKeys` below the bar's.
private struct StartTapShape: Shape {
    let compact: Bool
    let capturing: Bool

    func path(in rect: CGRect) -> Path {
        let top = KeyboardMetrics.reachAboveKeys(compact: compact)
        let area = KeyboardMetrics.startTapArea(
            capsule: KeyRect(x: Double(rect.minX), y: Double(rect.minY) + top, width: Double(rect.width), height: Double(rect.height)),
            barHeight: compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight, compact: compact, capturing: capturing)
        return Path(CGRect(x: area.x, y: area.y - top, width: area.width, height: area.height))
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
    @ObservedObject var chrome: KeyboardChrome
    var onClose: () -> Void
    /// Switches this kind of field to the other layout, remembered for its fingerprint.
    var onToggleLayout: () -> Void
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
                Button(action: onToggleLayout) {
                    HStack(spacing: 8) {
                        Label("Layout: \(chrome.layout.title)", systemImage: "text.alignleft")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                        Spacer(minLength: 8)
                        Text("Switch")
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Layout: \(chrome.layout.title)")
                .accessibilityHint("Switches this kind of field to \(chrome.layout.other.title)")
                .accessibilityIdentifier("lf.layoutToggle")
                Label(KeyboardMessages.trackpadTip, systemImage: "hand.point.up.left")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !chrome.fieldSummary.isEmpty {
                    // Debug readout: the field's fingerprint, content-free (a hash and input traits).
                    Text("Field \(chrome.fieldSummary)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lf.fieldFingerprint")
                }
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
        case .starting, .recording, .transcribing, .waitingForModel: return true
        default: return false
        }
    }

    /// The recording ended: the capsule is a spinner that takes no taps.
    var isWaitingForTranscript: Bool { self == .transcribing || self == .waitingForModel }

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
