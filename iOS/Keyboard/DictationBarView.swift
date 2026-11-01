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

/// The top row (ARCHITECTURE.md, "Top row"): a menu button on the left, Undo / "Insert last dictation" chips or a
/// one-line status in the middle (the candidate strip instead while it shows, and over both a revert's "Never correct"
/// offer, unless dictation's own UI is up: `BarMiddleContent`), and the dictation island on the right. Tapping Start
/// grows the island across the bar into the recording, which holds the wave and the time and is Stop; Stop contracts it
/// into the short wait for the transcript, which collapses back into Start. Its parts go where `IslandLayout` puts them,
/// so Cancel, beside the menu, never moves while a dictation runs. It renders `KeyboardDictationClient.state` and the
/// strip only, so typing never re-renders it.
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    /// The island's grow and shrink: quick and firm, a touch of give and no wobble (owner, round 8: smooth, never slow).
    static let islandSpring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        let compact = verticalSizeClass == .compact
        let state = client.state
        // The key area takes the bar away from the controls (`KeyboardMetrics.barPointGoesToKeys`).
        let height = CGFloat(compact ? KeyboardMetrics.compactBarControlHeight : KeyboardMetrics.barControlHeight)
        let barHeight = compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight
        let style = CapsuleStyle(mode: state.mode)
        let form = IslandForm(style)
        let capturing = form == .expanded
        // Under the open menu the bar's controls fade as the keys do, and its middle goes: the card says the same.
        let menuOpen = chrome.isMenuOpen
        let middle = BarMiddleContent.resolve(neverCorrectOffer: neverCorrect.offer != nil, candidates: swipe.strip != nil,
                                              dictationInProgress: state.mode.isInProgress, notice: state.notice != nil,
                                              dictationUndoShown: state.canUndo && !state.mode.isInProgress)
        GeometryReader { geometry in
            let layout = IslandLayout(barWidth: Double(geometry.size.width), controlHeight: Double(height),
                                      startWidth: startWidth(height: Double(height)), form: form)
            let centreY = CGFloat(barHeight) / 2
            ZStack(alignment: .topLeading) {
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
                .position(x: CGFloat(layout.menu.x) + height / 2, y: centreY)

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
                    } else if !capturing {
                        // While the island records it holds dictation's status itself.
                        Middle(client: client, state: state, height: height - 8, controls: controls, onAction: onAction)
                    }
                }
                .frame(width: CGFloat(layout.middle.width), height: height, alignment: .leading)
                // The middle cross-fades when what it holds changes (the strip coming or going), never as its words change.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: middle)
                .opacity(menuOpen || layout.middle.width < 1 ? 0 : 1)
                .allowsHitTesting(!menuOpen && layout.middle.width >= 1)
                .position(x: CGFloat(layout.middle.x + layout.middle.width / 2), y: centreY)

                if let cancel = layout.cancel {
                    Button {
                        onAction()
                        client.cancelTapped()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: CGFloat(cancel.width), height: CGFloat(cancel.width))
                            .background(Circle().fill(Color(uiColor: KeyPalette.fill)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Cancel dictation")
                    .accessibilityIdentifier("lf.cancel")
                    .barControl("cancel", in: controls)
                    .opacity(menuOpen ? MenuCover.dimmedAlpha : 1)
                    .position(x: CGFloat(cancel.x + cancel.width / 2), y: centreY)
                    // It pops in where it stays: the scale is about its own centre, not the bar's.
                    .transition(reduceMotion ? .opacity.animation(.easeOut(duration: 0.15))
                        : .opacity.combined(with: .scale(scale: 0.6, anchor: UnitPoint(
                            x: (cancel.x + cancel.width / 2) / max(Double(geometry.size.width), 1), y: 0.5))))
                }

                DictationIsland(client: client, state: state, height: height, compact: compact, onAction: onAction,
                                onUnavailable: onMenu)
                    .frame(width: CGFloat(layout.island.width), height: height)
                    // With Reduce Motion the island never resizes in view: each form is its own island, cross-faded.
                    .id(reduceMotion ? AnyHashable(form) : AnyHashable(0))
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    .barControl("start", in: controls) {
                        KeyboardMetrics.startTapArea(capsule: $0, barHeight: barHeight, compact: compact, capturing: capturing)
                    }
                    .opacity(menuOpen ? MenuCover.dimmedAlpha : 1)
                    .position(x: CGFloat(layout.island.x + layout.island.width / 2), y: centreY)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(barHeight))
        // The hosting view also reaches down behind the top row for Stop's tap area; only the bar is drawn.
        .background(Color(uiColor: KeyAreaView.touchableBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(BarControlFrames.space))
        // The island grows and shrinks with a short spring, and its contents hand over with it; with Reduce Motion
        // nothing moves or resizes: the parts take their places at once and the island cross-fades.
        .animation(reduceMotion ? nil : Self.islandSpring, value: form)
        // Undo and "Insert last" arrive with a soft, quick spring (`Middle`), and leave as quickly.
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8), value: state.canUndo)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8), value: state.canInsertLast)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: menuOpen)
        // The bar's height is fixed: its text grows to what one line holds there.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Start's width at the bar's text size: its label's width, the mark and the padding (`IslandLayout.startWidth`).
    private func startWidth(height: Double) -> Double {
        let size = min(dynamicTypeSize, .xxLarge)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let points = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
        let font = UIFont.systemFont(ofSize: points, weight: legibilityWeight == .bold ? .bold : .semibold)
        let label = ceil(("Start" as NSString).size(withAttributes: [.font: font]).width)
        return IslandLayout.startWidth(labelWidth: Double(label) + 2, controlHeight: height)
    }
}

/// Chips when there is something to act on, and a notice whenever one is up; otherwise one line of status
/// (`BarStatus`). While the island records, it holds the status instead.
private struct Middle: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let height: CGFloat
    let controls: BarControlFrames
    let onAction: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var undoShown: Bool { state.canUndo && !state.mode.isInProgress }
    /// Not while a dictation is in progress: the chip would hide the line that names the wait, which the island's
    /// shimmer does not say.
    private var insertLastShown: Bool { state.canInsertLast && !state.mode.isInProgress }

    var body: some View {
        let status = BarStatus(mode: state.mode, title: state.title, hint: state.hint, notice: state.notice,
                               chipsShown: undoShown || insertLastShown, sessionReady: state.sessionReady)
        // A chip settles in from a little smaller: a short spring, with Reduce Motion a fade.
        let arrival: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.88, anchor: .leading))
        HStack(spacing: 6) {
            if undoShown {
                Chip(title: "Undo", symbol: "arrow.uturn.backward", height: height) {
                    onAction()
                    client.undoLastDictation()
                }
                .accessibilityLabel("Undo last dictation")
                .accessibilityIdentifier("lf.undo")
                .barControl("undo", in: controls)
                .transition(arrival)
            }
            if insertLastShown {
                Chip(title: "Insert last", symbol: "text.insert", height: height) {
                    onAction()
                    client.insertLastDictation()
                }
                .accessibilityLabel("Insert last dictation")
                .accessibilityIdentifier("lf.insertLast")
                .barControl("insertLast", in: controls)
                .transition(arrival)
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
            case .wave:
                // Only while recording, when the island holds the wave.
                EmptyView()
            case .text(let line, let attention, let ready):
                HStack(spacing: 5) {
                    if ready {
                        // Dictation is ready: the mark's dot. Information, not a control.
                        Circle()
                            .fill(Color(palette.aurora))
                            .frame(width: 6, height: 6)
                            .padding(.trailing, 1)
                            .accessibilityHidden(true)
                    }
                    if attention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(palette.ember))
                            .accessibilityHidden(true)
                    }
                    Text(line)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(attention ? AnyShapeStyle(.primary) : statusInk)
                        .lineLimit(1)
                        // Beside the dot the session line may shrink a little further, so at the largest bar text on
                        // a 375-point phone it still shows whole (never below the default size there).
                        .minimumScaleFactor(ready ? 0.8 : 0.85)
                        .accessibilityIdentifier("lf.status")
                }
                // A line that goes ("Transcribing…" as Undo arrives) gets out of the way at once.
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.08))))
            case .none:
                EmptyView()
            }
        }
    }

    private var palette: BrandPalette { BrandPalette(colorScheme: colorScheme, contrast: contrast) }

    /// The status line's ink: the palette's where the system's secondary text is too faint (the light keyboard).
    private var statusInk: AnyShapeStyle {
        palette.statusInk.map { AnyShapeStyle(Color($0)) } ?? AnyShapeStyle(.secondary)
    }
}

/// The recording wave (`DotWave`) in the island: dim dots through which two strands of lit dots braid and swell with the
/// voice and settle into the mark's aurora dot at the right; a flat row in silence. The level it draws follows the
/// latest the keyboard read, quickly up and slowly down, and the strands drift, on the display's clock only while
/// `live` (recording); otherwise, and with Reduce Motion, it stands still at the latest level.
private struct DotWaveView: View {
    let level: Float
    let live: Bool
    let ink: Color
    let mark: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = WaveMotion()

    var body: some View {
        if reduceMotion || !live {
            canvas(level: live ? Double(level) : 0, phase: 0)
        } else {
            TimelineView(.animation(minimumInterval: DotWave.frameInterval)) { context in
                let frame = motion.advance(to: context.date, level: Double(level))
                canvas(level: frame.level, phase: frame.phase)
            }
        }
    }

    private func canvas(level: Double, phase: Double) -> some View {
        Canvas { context, size in
            let width = Double(size.width), height = Double(size.height)
            context.fillDots(DotWave.dots(level: level, phase: phase, width: width, height: height), color: ink)
            let dot = DotWave.markDot(level: level, width: width, height: height)
            context.fill(Path(ellipseIn: dot.rect), with: .color(mark))
        }
    }
}

private extension DotWave.Dot {
    var rect: CGRect { CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius) }
}

private extension GraphicsContext {
    /// Fills dots in `color` at their brightness, a few fills a frame: one path for each of eight brightness steps.
    func fillDots(_ dots: [DotWave.Dot], color: Color) {
        let steps = 8
        var paths = [Path](repeating: Path(), count: steps + 1)
        for dot in dots {
            paths[min(max(Int((dot.brightness * Double(steps)).rounded()), 0), steps)].addEllipse(in: dot.rect)
        }
        for (step, path) in paths.enumerated() where step > 0 && !path.isEmpty {
            fill(path, with: .color(color.opacity(Double(step) / Double(steps))))
        }
    }
}

/// The wave's clock between frames: the smoothed level and the drift since recording began. A reference, so the frames
/// advance it without re-rendering anything.
private final class WaveMotion {
    private var follower = DotWave.LevelFollower()
    private var start: Date?
    private var last: Date?

    func advance(to date: Date, level: Double) -> (level: Double, phase: Double) {
        let start = self.start ?? date
        self.start = start
        follower.follow(level, over: min(date.timeIntervalSince(last ?? date), 0.1))
        last = date
        return (follower.value, DotWave.phase(elapsed: date.timeIntervalSince(start)))
    }
}

/// The wait's shimmer (`DotWave.shimmer`) in the short island: a calm row of cool dots with a bright spot sweeping
/// across, on the display's clock while it shows; with Reduce Motion the row stands still.
private struct ShimmerView: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One sweep, in seconds, entering at the left and leaving at the right.
    private static let period = 1.1

    var body: some View {
        if reduceMotion {
            canvas(sweep: -1)
        } else {
            TimelineView(.animation(minimumInterval: DotWave.frameInterval)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                canvas(sweep: t * 1.6 - 0.3)
            }
        }
    }

    private func canvas(sweep: Double) -> some View {
        Canvas { context, size in
            context.fillDots(DotWave.shimmer(sweep: sweep, width: Double(size.width), height: Double(size.height)), color: color)
        }
    }
}

/// Up to three candidates side by side, as on Apple's predictive bar: a swipe's or autocorrect's after a commit key
/// (the one in the field now emphasized), or the suggestions while a word is typed (the word as typed in quotes and
/// the correction a space would make emphasized, while one is pending). A tap replaces the word (the editor decides
/// whether it still can). The words share one text size (`CandidateStripLayout`); words that would shrink below
/// `CandidateStripLayout.minimumScale` make room by dropping the least useful candidate; no divider shows beside the
/// emphasized one's pill, which glides to a new pick in the same strip instead of jumping.
private struct CandidateStrip: View {
    let strip: SwipeStrip
    let height: CGFloat
    let onCandidate: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .background(alignment: .leading) {
            // One pill under the emphasized slot (the slots are equal), so a new pick slides it over in a short, firm
            // move; only the pill animates, never the words.
            if let position = strip.emphasized.flatMap(fit.shown.firstIndex(of:)), width > 0 {
                let divider = CGFloat(CandidateStripLayout.divider), count = CGFloat(fit.shown.count)
                let slot = (width - divider * (count - 1)) / count
                pill
                    .frame(width: slot, height: height)
                    .offset(x: CGFloat(position) * (slot + divider))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: position)
                    .accessibilityHidden(true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The candidate Space would put in sits on a pill (`BrandPalette.pill`), neutral: a soft white veil on the dark
    /// keyboard, the keys' white on the light one, with a thin grey edge.
    private var pill: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        return Capsule()
            .fill(Color(palette.pill).opacity(palette.pillAlpha))
            .overlay(Capsule().strokeBorder(Color(palette.pillEdge).opacity(palette.pillEdgeAlpha), lineWidth: 0.75))
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

/// A bar chip: a key-coloured capsule with the key's shadow, its symbol a little heavier than its words.
private struct ChipLabel: View {
    let title: String
    let symbol: String
    let height: CGFloat

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .fontWeight(.semibold)
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

/// The dictation island (ARCHITECTURE.md, "Top row", "Keyboard look"): a near-black pill in both modes, in the spirit of
/// the Dynamic Island. Idle it is Start, the ridge mark (its dot aurora) beside "Start". Starting and recording it is
/// grown across the bar and is Stop as a whole: the wave (`DotWaveView`), the time and a stop glyph, or what dictation
/// has to say (a notice, the cold start's caption, "Open LocalFlow to start a session"). Waiting for the transcript it
/// is the short shimmer, which takes no taps; the middle names the wait and VoiceOver hears it from the label.
private struct DictationIsland: View {
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
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let island = palette.island
        Button {
            if state.mode.allowsDictation {
                onAction()
                client.micTapped()
            } else {
                onUnavailable()
            }
        } label: {
            content(palette)
                .foregroundStyle(Color(island.ink))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(StartTapShape(compact: compact, capturing: state.mode.isActiveCapture))
        }
        .buttonStyle(IslandPressStyle())
        // The pill itself is drawn outside the button's label, so its grow and shrink follow the bar's spring.
        .background {
            Capsule()
                .fill(Color(island.color))
                .overlay {
                    if let edge = island.edge { Capsule().strokeBorder(Color(edge), lineWidth: CGFloat(palette.edgeWidth)) }
                }
        }
        // While the island grows, what it will hold stays inside it.
        .clipShape(Capsule())
        // Not `.disabled`, which would dim the shimmer; the client ignores taps it cannot act on.
        .allowsHitTesting(!state.mode.isWaitingForTranscript)
        .opacity(CapsuleStyle(mode: state.mode) == .unavailable ? 0.45 : 1)
        .accessibilityLabel(KeyboardMessages.capsuleAccessibilityLabel(for: state.mode))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("lf.mic")
    }

    /// What it holds hands over in a quick fade as it changes form; what arrives in the grown island waits a moment
    /// for the room, so it never shows squeezed (taps work throughout).
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.07)),
                                              removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    @ViewBuilder private func content(_ palette: BrandPalette) -> some View {
        let ink = Color(palette.island.ink)
        switch CapsuleContent(mode: state.mode) {
        case .start:
            HStack(spacing: 6) {
                IslandMark(line: ink, dot: Color(palette.live), side: 19)
                Text("Start").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .transition(arrival)
        case .starting:
            recording(palette, startedAt: nil).transition(arrival)
        case .stop(let startedAt):
            recording(palette, startedAt: startedAt).transition(arrival)
        case .processing:
            ShimmerView(color: Color(palette.shimmer))
                .padding(.horizontal, 12)
                .frame(height: waveHeight)
                .transition(arrival)
        }
    }

    /// The recording's height for the wave's dots, inside the island's rounded ends.
    private var waveHeight: CGFloat { min(24, height - 12) }

    /// Starting and recording: dictation's status or the wave, then the time while recording, then the stop glyph.
    private func recording(_ palette: BrandPalette, startedAt: Date?) -> some View {
        let ink = Color(palette.island.ink)
        let status = BarStatus(mode: state.mode, title: state.title, hint: state.hint, notice: state.notice, chipsShown: false)
        return HStack(spacing: 10) {
            Group {
                switch status {
                case .notice(let text):
                    line(text, ink: ink, identifier: "lf.notice")
                case .wave(let caption):
                    if let caption {
                        // The full caption while it leaves the wave room; on a narrow bar the short one.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                waveCaption(caption, ink: ink)
                                wave(palette, live: true).frame(minWidth: CGFloat(BarStatus.captionedWaveWidth))
                            }
                            HStack(spacing: 8) {
                                waveCaption(KeyboardMessages.modelLoadingShortCaption, ink: ink)
                                wave(palette, live: true)
                            }
                        }
                    } else {
                        wave(palette, live: true)
                    }
                case .text(let text, _, _) where text != KeyboardMessages.starting:
                    // "Open LocalFlow to start a session" while the host has not come up.
                    line(text, ink: ink, identifier: "lf.status")
                default:
                    // Starting: the calm row, dimmed until the recording begins.
                    wave(palette, live: false).opacity(0.55)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize()
            }
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(ink)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 15)
    }

    private func wave(_ palette: BrandPalette, live: Bool) -> some View {
        DotWaveView(level: state.levels.last ?? 0, live: live, ink: Color(palette.island.ink), mark: Color(palette.live))
            .frame(height: waveHeight)
            // VoiceOver hears the mode from Stop's value; the wave is decoration.
            .accessibilityHidden(true)
    }

    private func line(_ text: String, ink: Color, identifier: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityIdentifier(identifier)
    }

    private func waveCaption(_ caption: String, ink: Color) -> some View {
        Text(caption)
            .font(.footnote.weight(.medium))
            .foregroundStyle(ink.opacity(0.7))
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("lf.status")
    }

    /// The mode, the time, and whatever text the grown island shows instead of the middle.
    private var accessibilityValue: String {
        KeyboardMessages.islandAccessibilityValue(
            for: state.mode, status: BarStatus(mode: state.mode, title: state.title, hint: state.hint, notice: state.notice, chipsShown: false),
            now: Date())
    }

    private var accessibilityHint: String {
        switch state.mode {
        case .hostUnavailable: return "Opens LocalFlow to start a session"
        case .starting, .recording: return "Stops listening and inserts what you said"
        default: return ""
        }
    }
}

/// The ridge mark on the island: its line in the island's ink, its dot in aurora, `side` points across, a little larger
/// and heavier than the icon's proportions so the W reads at this size.
private struct IslandMark: View {
    let line: Color
    let dot: Color
    let side: CGFloat

    var body: some View {
        ZStack {
            RidgeMarkShape(weight: 1.3).stroke(line, style: RidgeMarkShape.style(side: side, weight: 1.3))
            RidgeMarkShape(dot: true, weight: 1.3).fill(dot)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// A press on the island dims what it holds a little, quickly both ways; the pill itself stays still, as the Dynamic
/// Island does under a finger.
private struct IslandPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
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
    /// The content's parts above and below the divider, whose heights (without the space that spreads them) pick the card's
    /// (`MenuCover.card`).
    @State private var headHeight: CGFloat = 0
    @State private var tailHeight: CGFloat = 0
    private static let padding: CGFloat = 12
    private static let spacing: CGFloat = 8

    /// The content's own height: both parts, the divider with its spacing, and the padding.
    private var contentHeight: Double {
        let parts: CGFloat = headHeight + tailHeight
        let around: CGFloat = 1 + 2 * Self.spacing + 2 * Self.padding
        return Double(parts + around)
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = MenuCover.card(metrics: KeyboardMetrics(width: Double(geometry.size.width), height: Double(geometry.size.height)),
                                       contentHeight: contentHeight)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)
                ScrollView {
                    content(spread: CGFloat(MenuCover.dividerSpace(card: frame, contentHeight: contentHeight)))
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The menu's items in two parts, above and below the divider, `spread` added on each side of it so short content
    /// fills the card (`MenuCover.dividerSpace`).
    private func content(spread: CGFloat) -> some View {
        // At the accessibility sizes the menu is a long read: the actions come first (`KeyboardMessages.menuItems`).
        let items = KeyboardMessages.menuItems(accessibilitySize: dynamicTypeSize.isAccessibilitySize)
        let divider = items.firstIndex(of: .divider) ?? items.count
        return VStack(alignment: .leading, spacing: 0) {
            part(Array(items[..<divider]))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }
            Divider()
                .padding(.vertical, Self.spacing + spread)
            part(Array(items[min(divider + 1, items.count)...]))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tailHeight = $0 }
        }
        .padding(Self.padding)
    }

    private func part(_ items: [KeyboardMessages.MenuItem]) -> some View {
        let largeText = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(items, id: \.self) { item in
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

    /// The recording ended: the island is the shimmer, which takes no taps.
    var isWaitingForTranscript: Bool { self == .transcribing || self == .waitingForModel }

    /// Starting or recording: the island is Stop.
    var isActiveCapture: Bool {
        switch self {
        case .starting, .recording: return true
        default: return false
        }
    }

    /// Dictation can be started or explained by Start.
    var allowsDictation: Bool {
        switch self {
        case .needsFullAccess, .configurationError, .incompatible: return false
        default: return true
        }
    }
}
