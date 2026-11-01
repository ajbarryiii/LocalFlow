import SwiftUI
import UIKit

/// Top-row state that belongs to the UI, not the dictation protocol.
@MainActor
final class KeyboardChrome: ObservableObject {
    @Published var isMenuOpen = false
    /// The layout profile the trackpad uses in this field, for the menu's text-width choice.
    @Published var layout = FieldLayoutParameters.standard.defaultLayout
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
/// candidate strip instead while it shows, and over both a revert's "Never correct" offer, unless dictation's
/// own UI is up: `BarMiddleContent`), and the Start capsule on the right, which becomes a red
/// "Stop" capsule with live level bars and the elapsed time while recording. It renders `KeyboardDictationClient.state` and
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                let middle = BarMiddleContent.resolve(neverCorrectOffer: neverCorrect.offer != nil, candidates: swipe.strip != nil,
                                                      dictationInProgress: state.mode.isInProgress, notice: state.notice != nil,
                                                      dictationUndoShown: state.canUndo && !state.mode.isInProgress)
                if middle == .neverCorrect, let offer = neverCorrect.offer {
                    NeverCorrectChip(word: offer.typed, height: height - 8) {
                        onAction()
                        onNeverCorrect()
                    }
                    .barControl("neverCorrect", in: controls)
                } else if middle == .candidates, let strip = swipe.strip {
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.canUndo)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.canInsertLast)
        // The bar's height is fixed: its text grows to what one line holds there.
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
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("lf.notice")
            } else if !(state.canUndo && !state.mode.isInProgress), !(state.canInsertLast && !state.mode.isRecording),
                      let status = statusLine {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(state.mode.needsAttention ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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

/// Up to three candidates side by side, as on Apple's predictive bar: a swipe's or autocorrect's after a commit key
/// (the one in the field now emphasized), or the suggestions while a word is typed (the word as typed in quotes and
/// the correction a space would make emphasized, while one is pending). A tap replaces the word (the editor decides
/// whether it still can). Words that would shrink below `CandidateStripLayout.minimumScale` make room by dropping the
/// least useful candidate; no divider shows beside the emphasized one's pill.
private struct CandidateStrip: View {
    let strip: SwipeStrip
    let height: CGFloat
    let onCandidate: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    var body: some View {
        let fit = CandidateStripLayout.fit(strip, widths: strip.candidates.indices.map(textWidth), available: Double(width))
        HStack(spacing: 0) {
            ForEach(Array(fit.shown.enumerated()), id: \.element) { position, index in
                let word = strip.candidates[index]
                let emphasized = index == strip.emphasized
                let quoted = index == strip.live?.quoted
                if position > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: CGFloat(CandidateStripLayout.divider), height: height * 0.6)
                        .opacity(CandidateStripLayout.showsDivider(between: fit.shown[position - 1], and: index,
                                                                   emphasized: strip.emphasized) ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Button {
                    onCandidate(index)
                } label: {
                    Text(label(index))
                        .font(.subheadline.weight(emphasized ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(CGFloat(fit.minimumScale))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, CGFloat(CandidateStripLayout.padding))
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                        .background(Capsule().fill(emphasized ? Color(uiColor: KeyPalette.fill) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(quoted ? "Keep \(word)" : word)
                .accessibilityHint(strip.live != nil && emphasized ? "Space puts this in" : "")
                .accessibilityAddTraits(emphasized ? .isSelected : [])
                .accessibilityIdentifier("lf.swipe.candidate.\(index)")
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func label(_ index: Int) -> String {
        index == strip.live?.quoted ? "\u{201C}\(strip.candidates[index])\u{201D}" : strip.candidates[index]
    }

    /// The candidate's width at full size, in the bar's text size.
    private func textWidth(_ index: Int) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let base = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: index == strip.emphasized ? .semibold : .regular)
        return Double(ceil((label(index) as NSString).size(withAttributes: [.font: font]).width))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: state.mode.isActiveCapture)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(state.mode == .hostUnavailable ? "Opens LocalFlow to start a session" : "")
        .accessibilityIdentifier("lf.mic")
    }

    @ViewBuilder private var content: some View {
        switch state.mode {
        case .recording(_, let startedAt):
            // "Stop" in words, as while starting; four level bars and the time beside it fit a 375 pt phone with the
            // menu button and Cancel.
            HStack(spacing: 6) {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                Text("Stop").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                LevelBars(levels: state.levels, height: height * 0.4)
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().tint(.white).controlSize(.small)
                Text("Stop").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
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
    static let count = 4
    let levels: [Float]
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let recent = levels.suffix(Self.count)
        let padded = Array(repeating: Float(0), count: Self.count - recent.count) + recent
        HStack(spacing: 2) {
            ForEach(0 ..< padded.count, id: \.self) { index in
                Capsule().frame(width: 2.5, height: max(2.5, height * CGFloat(padded[index])))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

/// The menu: session status, "Open LocalFlow", the trackpad tip with the field's text width, and details of anything
/// that keeps dictation from working (the actions first at the accessibility sizes). A tap outside the card closes it. The card spans the key area with the same
/// margin on each side, and scrolls inside its rounded corners when it does not fit (landscape, the largest text
/// sizes); its text follows Dynamic Type and reads at 4.5:1 or better (`MenuPalette`).
struct MenuPanelView: View {
    @ObservedObject var client: KeyboardDictationClient
    @ObservedObject var chrome: KeyboardChrome
    var onClose: () -> Void
    /// Switches this kind of field to the other text width, remembered for it.
    var onToggleLayout: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let keyboardName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalFlow"

    private static let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            ViewThatFits(in: .vertical) {
                card(content)
                // Too tall: the card keeps its rounded corners and its content scrolls inside them.
                card(ScrollView { content }.scrollBounceBehavior(.basedOnSize))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityAddTraits(.isModal)
    }

    private var palette: MenuPalette {
        MenuPalette(dark: colorScheme == .dark, highContrast: contrast == .increased)
    }

    private func color(_ rgb: MenuPalette.RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func card<Content: View>(_ content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.cardShape.fill(color(palette.card)))
            .clipShape(Self.cardShape)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(8)
    }

    private var content: some View {
        // At the accessibility sizes the menu is a long read: the actions come first (`KeyboardMessages.menuItems`).
        let largeText = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(KeyboardMessages.menuItems(accessibilitySize: largeText), id: \.self) { item in
                switch item {
                case .session:
                    Label(client.state.sessionSummary, systemImage: "waveform.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color(palette.primary))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lf.menu.session")
                case .details:
                    if let details {
                        Text(details)
                            .font(.footnote)
                            .foregroundStyle(color(palette.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .open:
                    Button {
                        onClose()
                        client.openLocalFlow()
                    } label: {
                        Label("Open LocalFlow", systemImage: "arrow.up.forward.app")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(color(palette.link))
                    }
                    .accessibilityIdentifier("lf.menu.open")
                case .divider:
                    Divider()
                case .tip:
                    // The trackpad's text width for this kind of field (ARCHITECTURE.md, "Field profiles"), in words.
                    Label(KeyboardMessages.trackpadTip + (largeText ? KeyboardMessages.layoutTipAbove : KeyboardMessages.layoutTipBelow),
                          systemImage: "hand.point.up.left")
                        .font(.footnote)
                        .foregroundStyle(color(palette.primary))
                        .fixedSize(horizontal: false, vertical: true)
                case .picker:
                    layoutPicker
                }
            }
        }
        .padding(12)
    }

    private var layoutPicker: some View {
        Picker("Text width", selection: Binding(get: { chrome.layout }, set: { if $0 != chrome.layout { onToggleLayout() } })) {
            Text("Full width").tag(FieldLayout.fullWidth)
            Text("Chat bubble").tag(FieldLayout.messages)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Text width for moving the cursor")
        .accessibilityIdentifier("lf.layoutToggle")
    }

    /// The full explanation for the states the top row condenses to one line.
    private var details: String? {
        switch client.state.mode {
        case .needsFullAccess:
            return KeyboardMessages.fullAccessExplanation + " "
                + KeyboardMessages.fullAccessSteps(keyboardName: keyboardName)
        case .configurationError: return KeyboardMessages.configurationErrorDetail
        case .incompatible: return KeyboardMessages.incompatibleDetail
        // The top row already says what Start does without a session; an error's line is repeated in full here.
        case .error: return client.state.title
        default: return nil
        }
    }
}

/// A press dims the control; it also shrinks it a little, unless Reduce Motion is on.
private struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
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
