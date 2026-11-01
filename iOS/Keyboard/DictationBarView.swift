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
/// own UI is up: `BarMiddleContent`), and the Start capsule on the right, which becomes a coral
/// "Stop" capsule with the elapsed time while recording, the live wave across the middle. It renders `KeyboardDictationClient.state` and
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
        // Under the open menu the bar's controls fade as the keys do, and its middle goes: the card says the same.
        let menuOpen = chrome.isMenuOpen
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

            let middle = BarMiddleContent.resolve(neverCorrectOffer: neverCorrect.offer != nil, candidates: swipe.strip != nil,
                                                  dictationInProgress: state.mode.isInProgress, notice: state.notice != nil,
                                                  dictationUndoShown: state.canUndo && !state.mode.isInProgress)
            Group {
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
            // The middle cross-fades when what it holds changes (the strip coming or going), never as its words change.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: middle)
            .opacity(menuOpen ? 0 : 1)
            .allowsHitTesting(!menuOpen)

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
                .opacity(menuOpen ? MenuCover.dimmedAlpha : 1)
            }
            StartCapsule(client: client, state: state, height: height, compact: compact, onAction: onAction, onUnavailable: onMenu)
                .barControl("start", in: controls) {
                    KeyboardMetrics.startTapArea(capsule: $0, barHeight: barHeight, compact: compact, capturing: capturing)
                }
                .opacity(menuOpen ? MenuCover.dimmedAlpha : 1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(barHeight))
        // The hosting view also reaches down behind the top row for Stop's tap area; only the bar is drawn.
        .background(Color(uiColor: KeyAreaView.touchableBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(BarControlFrames.space))
        // Start, Stop, the wait for the transcript and Undo hand over in a short cross-fade (none with Reduce Motion).
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: CapsuleStyle(mode: state.mode))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.canUndo)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.canInsertLast)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: menuOpen)
        // The bar's height is fixed: its text grows to what one line holds there.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// Chips when there is something to act on, and a notice whenever one is up; while recording the live wave;
/// otherwise one line of status (`BarStatus`).
private struct Middle: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let height: CGFloat
    let controls: BarControlFrames
    let onAction: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var undoShown: Bool { state.canUndo && !state.mode.isInProgress }
    /// Not while a dictation is in progress: the chip would hide the line that names the wait, which the capsule's
    /// spinner no longer says.
    private var insertLastShown: Bool { state.canInsertLast && !state.mode.isInProgress }

    var body: some View {
        let status = BarStatus(mode: state.mode, title: state.title, hint: state.hint, notice: state.notice,
                               chipsShown: undoShown || insertLastShown, sessionReady: state.sessionReady)
        HStack(spacing: 6) {
            if undoShown {
                Chip(title: "Undo", symbol: "arrow.uturn.backward", height: height) {
                    onAction()
                    client.undoLastDictation()
                }
                .accessibilityLabel("Undo last dictation")
                .accessibilityIdentifier("lf.undo")
                .barControl("undo", in: controls)
            }
            if insertLastShown {
                Chip(title: "Insert last", symbol: "text.insert", height: height) {
                    onAction()
                    client.insertLastDictation()
                }
                .accessibilityLabel("Insert last dictation")
                .accessibilityIdentifier("lf.insertLast")
                .barControl("insertLast", in: controls)
            }
            switch status {
            case .notice(let notice):
                // Notices render on their own, ahead of any idle hint or status, in every mode.
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("lf.notice")
            case .wave(let caption):
                if let caption {
                    // The full caption while it leaves the wave room; on a narrow bar the short one.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            waveCaption(caption)
                            wave.frame(minWidth: CGFloat(BarStatus.captionedWaveWidth))
                        }
                        HStack(spacing: 6) {
                            waveCaption(KeyboardMessages.modelLoadingShortCaption)
                            wave
                        }
                    }
                } else {
                    wave
                }
            case .text(let line, let attention, let ready):
                HStack(spacing: 5) {
                    if ready {
                        // Dictation is ready: the mark's glacier dot. Information, not a control.
                        Circle()
                            .fill(Color(BrandPalette(colorScheme: colorScheme, contrast: contrast).glacier))
                            .frame(width: 6, height: 6)
                            .padding(.trailing, 1)
                            .accessibilityHidden(true)
                    }
                    if attention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(BrandPalette(colorScheme: colorScheme, contrast: contrast).ember))
                            .accessibilityHidden(true)
                    }
                    Text(line)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(attention ? .primary : .secondary)
                        .lineLimit(1)
                        // Beside the dot the session line may shrink a little further, so at the largest bar text on
                        // a 375-point phone it still shows whole (never below the default size there).
                        .minimumScaleFactor(ready ? 0.8 : 0.85)
                        .accessibilityIdentifier("lf.status")
                }
            case .none:
                EmptyView()
            }
        }
    }

    private func waveCaption(_ caption: String) -> some View {
        Text(caption)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("lf.status")
    }

    private var wave: some View {
        RecordingWave(levels: state.levels, serial: state.levelSerial)
            .frame(height: height)
            // VoiceOver hears the mode from Stop's value; the wave is decoration.
            .accessibilityHidden(true)
    }
}

/// The recording wave (`RidgeWave`): the ridge mark's line across the bar's middle, glacier fading in at the left to
/// aurora at the right, where the newest level arrives beside a glacier dot, as in the mark. It flows left between
/// levels on the display's own clock, only while it shows; with Reduce Motion it stands still at each level.
private struct RecordingWave: View {
    let levels: [Float]
    let serial: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// When the newest level arrived, and the time the previous one took, which the flow spreads the step over.
    @State private var arrival = (serial: 0, at: Date.distantPast, interval: 0.15)

    var body: some View {
        Group {
            if reduceMotion {
                wave(progress: 1)
            } else {
                TimelineView(.animation) { context in
                    wave(progress: arrival.serial == serial ? context.date.timeIntervalSince(arrival.at) / arrival.interval : 0)
                }
            }
        }
        .onChange(of: serial, initial: true) { _, newSerial in
            let now = Date()
            // The host publishes about ten levels a second; the keyboard reads them every 0.1–0.2 s.
            let interval = min(max(now.timeIntervalSince(arrival.at), 0.08), 0.3)
            arrival = (newSerial, now, interval)
        }
    }

    private func wave(progress: Double) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let glacier = Color(palette.glacier), aurora = Color(palette.aurora)
        return GeometryReader { geometry in
            let lineWidth = CGFloat(RidgeWave.lineWidth(height: Double(geometry.size.height)))
            // The mark's dot at the right, on the middle line, where the newest level comes out of it.
            let radius = lineWidth * 1.1
            HStack(spacing: 3) {
                RidgeWaveShape(levels: levels, serial: serial, progress: progress)
                    .stroke(LinearGradient(colors: [glacier, aurora, aurora], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    // Old levels fade out at the left; the arriving one fades in beside the dot.
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3),
                                                 .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                Circle().fill(glacier).frame(width: 2 * radius, height: 2 * radius)
            }
        }
    }
}

/// `RidgeWave`'s corners as a line, in the shape's frame.
private struct RidgeWaveShape: Shape {
    let levels: [Float]
    let serial: Int
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let corners = RidgeWave.corners(levels: levels, serial: serial, width: Double(rect.width), height: Double(rect.height),
                                        progress: progress)
        var path = Path()
        path.addLines(corners.map { CGPoint(x: Double(rect.minX) + $0.x, y: Double(rect.minY) + $0.y) })
        return path
    }
}

/// Up to three candidates side by side, as on Apple's predictive bar: a swipe's or autocorrect's after a commit key
/// (the one in the field now emphasized), or the suggestions while a word is typed (the word as typed in quotes and
/// the correction a space would make emphasized, while one is pending). A tap replaces the word (the editor decides
/// whether it still can). The words share one text size (`CandidateStripLayout`); words that would shrink below
/// `CandidateStripLayout.minimumScale` make room by dropping the least useful candidate; no divider shows beside the
/// emphasized one's pill.
private struct CandidateStrip: View {
    let strip: SwipeStrip
    let height: CGFloat
    let onCandidate: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var width: CGFloat = 0

    var body: some View {
        let fit = CandidateStripLayout.fit(strip, widths: strip.candidates.indices.map(textWidth), available: Double(width))
        let size = baseFont.pointSize * CGFloat(fit.scale)
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
                        .font(.system(size: size, weight: emphasized ? .semibold : .regular))
                        .lineLimit(1)
                        // The shared size is worked out from the full-size widths; a smaller size sets its letters a
                        // touch looser, which tightening absorbs before the tightest word would truncate.
                        .allowsTightening(true)
                        .minimumScaleFactor(0.95)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, CGFloat(CandidateStripLayout.padding))
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                        .background { if emphasized { pill } }
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

    /// The candidate Space would put in sits on a soft aurora pill (`BrandPalette.pill`).
    private var pill: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        return Capsule()
            .fill(Color(palette.pill).opacity(palette.pillAlpha))
            .overlay(Capsule().strokeBorder(Color(palette.aurora).opacity(colorScheme == .dark ? 0.45 : 0.3), lineWidth: 0.75))
    }

    private func label(_ index: Int) -> String {
        index == strip.live?.quoted ? "\u{201C}\(strip.candidates[index])\u{201D}" : strip.candidates[index]
    }

    /// The bar's text size for candidates at full size.
    private var baseFont: UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
    }

    /// The candidate's width at full size, in the bar's text size.
    private func textWidth(_ index: Int) -> Double {
        let font = UIFont.systemFont(ofSize: baseFont.pointSize, weight: index == strip.emphasized ? .semibold : .regular)
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
            ChipLabel(title: "Never correct \u{201C}\(word)\u{201D}", symbol: "text.badge.checkmark", height: height)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
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
            ChipLabel(title: title, symbol: symbol, height: height)
        }
        .buttonStyle(PressableStyle())
        .fixedSize()
    }
}

/// A bar chip: a key-coloured capsule with the key's shadow, its symbol in the accent (`BrandPalette.keyGlyph`).
private struct ChipLabel: View {
    let title: String
    let symbol: String
    let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .fontWeight(.semibold)
                .foregroundStyle(Color(BrandPalette(colorScheme: colorScheme, contrast: contrast).keyGlyph))
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(Capsule().fill(Color(uiColor: KeyPalette.fill)))
        .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
        .contentShape(Rectangle())
    }
}

/// The primary control (ARCHITECTURE.md, "Keyboard look"): "Start" with the ridge mark, in the app's primary-button
/// aurora; a coral "Stop" with the elapsed time while starting or recording (the wave in the middle shows the levels);
/// glacier with only a spinner while the recording waits for its transcript; ink on every fill. From starting until the
/// transcript it keeps the recording Stop's width (`CapsuleContent`), so Cancel beside it stays put.
private struct StartCapsule: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let height: CGFloat
    let compact: Bool
    let onAction: () -> Void
    /// Dictation cannot run here (no Full Access, configuration, versions): show why instead.
    let onUnavailable: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let style = CapsuleStyle(mode: state.mode)
        let fill = fill(style)
        let edgeWidth = CGFloat(BrandPalette(colorScheme: colorScheme, contrast: contrast).edgeWidth)
        Button {
            if state.mode.allowsDictation {
                onAction()
                client.micTapped()
            } else {
                onUnavailable()
            }
        } label: {
            content
                .foregroundStyle(Color(fill.ink))
                .padding(.horizontal, 14)
                .frame(minWidth: height * 2.4, minHeight: height, maxHeight: height)
                .background {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(fill.top), Color(fill.bottom)], startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .overlay { if let edge = fill.edge { Capsule().strokeBorder(Color(edge), lineWidth: edgeWidth) } }
                        // The keys' shadow; an edged fill needs none.
                        .shadow(color: .black.opacity(fill.edge == nil ? 0.35 : 0), radius: 0, y: 1)
                }
                .contentShape(StartTapShape(compact: compact, capturing: state.mode.isActiveCapture))
        }
        .buttonStyle(PressableStyle())
        // Not `.disabled`, which would dim the spinner; the client ignores taps it cannot act on.
        .allowsHitTesting(!state.mode.isWaitingForTranscript)
        .opacity(style == .unavailable ? 0.45 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: style)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(state.mode == .hostUnavailable ? "Opens LocalFlow to start a session" : "")
        .accessibilityIdentifier("lf.mic")
    }

    private func fill(_ style: CapsuleStyle) -> BrandPalette.Fill {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        switch style {
        case .start, .unavailable: return palette.accent
        case .stop: return palette.stop
        case .working: return palette.working
        }
    }

    @ViewBuilder private var content: some View {
        let content = CapsuleContent(mode: state.mode)
        if content.keepsStopWidth {
            ZStack {
                // The recording Stop's width, held through starting and the wait for the transcript.
                stop(time: Text(verbatim: "0:00")).hidden().accessibilityHidden(true)
                switch content {
                case .stop(let startedAt):
                    // "Stop" in words, as while starting, and the time: with the wave beside it, it fits a 375 pt
                    // phone with the menu button and Cancel.
                    stop(time: Text(timerInterval: startedAt...Date.distantFuture, countsDown: false))
                case .starting:
                    HStack(spacing: 6) {
                        ProgressView().tint(Color(fill(.stop).ink)).controlSize(.small)
                        Text("Stop").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                    }
                case .spinner:
                    // The middle says what the recording waits for; VoiceOver hears it from the label.
                    ProgressView().tint(Color(fill(.working).ink)).controlSize(.small)
                case .start:
                    EmptyView()
                }
            }
        } else {
            HStack(spacing: 6) {
                // A little larger and heavier than the icon's proportions, so the W reads at this size.
                RidgeMarkGlyph(color: Color(fill(.start).ink), side: 19, weight: 1.3)
                Text("Start").font(.subheadline.weight(.semibold))
            }
        }
    }

    private func stop(time: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
            Text("Stop").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            time
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var accessibilityLabel: String { KeyboardMessages.capsuleAccessibilityLabel(for: state.mode) }

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

/// The menu: session status, "Open LocalFlow", the trackpad tip with the field's text width, and details of anything
/// that keeps dictation from working (the actions first at the accessibility sizes). A tap outside the card closes it. The
/// card lies over the keys with none peeking out (`MenuCover`): over the three rows above the bottom row, or all four
/// when its content needs more, and scrolls inside its rounded corners when even that is too little (landscape, the
/// largest text sizes); its text, the text-width choice included, follows Dynamic Type and reads at 4.5:1 or better
/// (`MenuPalette`).
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

    private static let cardShape = RoundedRectangle(cornerRadius: CGFloat(MenuCover.cornerRadius), style: .continuous)
    /// The content's own height, which picks the card's (`MenuCover.card`).
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let frame = MenuCover.card(metrics: KeyboardMetrics(width: Double(geometry.size.width), height: Double(geometry.size.height)),
                                       contentHeight: Double(contentHeight))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height), alignment: .top)
                .background(Self.cardShape.fill(color(palette.card)))
                .clipShape(Self.cardShape)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .offset(x: CGFloat(frame.x), y: CGFloat(frame.y))
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var palette: MenuPalette {
        MenuPalette(dark: colorScheme == .dark, highContrast: contrast == .increased)
    }

    private func color(_ rgb: MenuPalette.RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private var content: some View {
        // At the accessibility sizes the menu is a long read: the actions come first (`KeyboardMessages.menuItems`).
        let largeText = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(KeyboardMessages.menuItems(accessibilitySize: largeText), id: \.self) { item in
                switch item {
                case .session:
                    Label {
                        Text(client.state.sessionSummary)
                    } icon: {
                        RidgeMarkGlyph(color: color(palette.link), side: 18)
                    }
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

    /// The field's text width, as two segments whose text follows Dynamic Type like the rest of the card (a segmented
    /// `Picker` keeps its default size), side by side or, when they do not fit so, stacked.
    private var layoutPicker: some View {
        let options: [(layout: FieldLayout, title: String)] = [(.fullWidth, "Full width"), (.messages, "Chat bubble")]
        let segments = ForEach(options, id: \.layout) { option in
            segment(option.title, selected: option.layout == chrome.layout) {
                if option.layout != chrome.layout { onToggleLayout() }
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { segments }
            VStack(spacing: 2) { segments }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color(palette.track)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text width for moving the cursor")
        .accessibilityIdentifier("lf.layoutToggle")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(color(palette.primary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(color(palette.selectedSegment))
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// Starting or recording: the capsule is the coral Stop.
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
}
