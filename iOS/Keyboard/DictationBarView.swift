import SwiftUI
import UIKit

/// Top-row state that belongs to the UI, not the dictation protocol.
@MainActor
final class KeyboardChrome: ObservableObject {
    @Published var isMenuOpen = false
    /// The layout profile the trackpad uses in this field, for the menu's text-width choice.
    @Published var layout = FieldLayoutParameters.standard.defaultLayout
    /// Left-handed (`LocalFlowSettings.leftHanded`): the dictation controls mirrored to the bar's left. Read when the
    /// keyboard appears.
    @Published var leftHanded = false
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
/// grows the island leftwards into the recording, under half the bar, which holds the wave and the time and is Stop;
/// Stop contracts it into the short wait for the transcript, which opens back into Start. Its parts go where
/// `IslandLayout` puts them, so Cancel, beside the recording island, never moves while a dictation runs. It renders
/// `KeyboardDictationClient.state` and the strip only, so typing never re-renders it.
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
    static let islandSpring = Animation.spring(response: 0.26, dampingFraction: 0.88)
    /// What leaves at a change of form goes first, this quickly; what arrives waits as long (Opus, round 8: Undo arrived
    /// over the outgoing × and "Transcribing…").
    static let handover = 0.06
    /// Leaving: a quick fade. Arriving: a fade after `handover`, from a little smaller where `scaleFrom` is under 1.
    static func handing(over reduceMotion: Bool, scaleFrom: CGFloat = 1, anchor: UnitPoint = .center,
                        after delay: Double = handover) -> AnyTransition {
        let leave = AnyTransition.opacity.animation(.easeOut(duration: reduceMotion ? 0.15 : handover))
        guard !reduceMotion else { return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15)), removal: leave) }
        let arrive = scaleFrom < 1 ? AnyTransition.opacity.combined(with: .scale(scale: scaleFrom, anchor: anchor)) : .opacity
        return .asymmetric(insertion: arrive.animation(.spring(response: 0.24, dampingFraction: 0.82).delay(delay)), removal: leave)
    }

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
                                      startWidth: startWidth(height: Double(height)), form: form, leftHanded: chrome.leftHanded)
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
                    } else {
                        // While a dictation runs this is plain text: the cold start's caption, a notice, the wait's words.
                        Middle(client: client, state: state, height: height - 8, controls: controls, onAction: onAction)
                    }
                }
                .frame(width: CGFloat(layout.middle.width), height: height, alignment: .leading)
                // The middle cross-fades when what it holds changes (the strip coming or going), never as its words change.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: middle)
                .opacity(menuOpen || layout.middle.width < 1 ? 0 : 1)
                .allowsHitTesting(!menuOpen && layout.middle.width >= 1)
                .position(x: CGFloat(layout.middle.x + layout.middle.width / 2), y: centreY)
                // The middle moves with the island's form (beside Start, then left of Cancel, then between Cancel and the
                // wait): what it held leaves where it was, first, and what it holds next arrives in its new place.
                .id(form)
                // The wait's words take the room the contracting island leaves: they wait until most of it is free.
                .transition(Self.handing(over: reduceMotion, after: form == .processing ? 0.14 : Self.handover))

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
                            .contentShape(CancelTapShape(compact: compact))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Cancel dictation")
                    .accessibilityIdentifier("lf.cancel")
                    .barControl("cancel", in: controls) {
                        KeyboardMetrics.cancelTapArea(circle: $0, barHeight: barHeight, compact: compact)
                    }
                    .opacity(menuOpen ? MenuCover.dimmedAlpha : 1)
                    .position(x: CGFloat(cancel.x + cancel.width / 2), y: centreY)
                    // It pops in where it stays, after what leaves has gone: the scale is about its own centre.
                    .transition(Self.handing(over: reduceMotion, scaleFrom: 0.6, anchor: UnitPoint(
                        x: (cancel.x + cancel.width / 2) / max(Double(geometry.size.width), 1), y: 0.5)))
                }

                DictationIsland(client: client, state: state, height: height, compact: compact, leftHanded: chrome.leftHanded,
                                onAction: onAction, onUnavailable: onMenu)
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
/// (`BarStatus`). While a dictation runs its room is narrow (beside Cancel), so its words may take two lines; while
/// recording it shows only the cold start's caption, plain, never a control.
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
    /// Not while a dictation is in progress: the middle is dictation's then (a notice, "Open LocalFlow to start a
    /// session").
    private var insertLastShown: Bool { state.canInsertLast && !state.mode.isInProgress }

    var body: some View {
        let status = BarStatus(mode: state.mode, title: state.title, hint: state.hint, notice: state.notice,
                               chipsShown: undoShown || insertLastShown)
        // A chip settles in from a little smaller once what it replaces has gone: a short spring, with Reduce Motion a fade.
        let arrival = DictationBarView.handing(over: reduceMotion, scaleFrom: 0.88, anchor: .leading)
        // Beside Cancel the room is narrow: two short lines rather than a truncated one.
        let lines = state.mode.isInProgress ? 2 : 1
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
                    .lineLimit(lines)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("lf.notice")
            case .text(let line, let attention):
                HStack(spacing: 5) {
                    if attention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(palette.ember))
                            .accessibilityHidden(true)
                    }
                    if lines > 1 {
                        // Beside Cancel: the line whole where it fits, else two lines.
                        ViewThatFits(in: .horizontal) {
                            statusText(line, ink: attention ? AnyShapeStyle(.primary) : statusInk)
                            Text(line)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(attention ? AnyShapeStyle(.primary) : statusInk)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .accessibilityIdentifier("lf.status")
                        }
                    } else {
                        Text(line)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(attention ? AnyShapeStyle(.primary) : statusInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .accessibilityIdentifier("lf.status")
                    }
                }
                // A line that goes (an error's as Undo arrives) gets out of the way at once, first.
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12).delay(DictationBarView.handover)),
                                        removal: .opacity.animation(.easeOut(duration: DictationBarView.handover))))
            case .none:
                EmptyView()
            }
        }
    }

    private var palette: BrandPalette { BrandPalette(colorScheme: colorScheme, contrast: contrast) }

    private func statusText(_ text: String, ink: AnyShapeStyle) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("lf.status")
    }

    /// The status line's ink: the palette's where the system's secondary text is too faint (the light keyboard).
    private var statusInk: AnyShapeStyle {
        palette.statusInk.map { AnyShapeStyle(Color($0)) } ?? AnyShapeStyle(.secondary)
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
/// the Dynamic Island. Idle it is Start, the ridge mark beside "Start", the mark's dot the session's state (`SessionDot`).
/// Starting and recording it is grown towards the bar's middle, under half the bar, and is Stop as a whole: the wave
/// (`DotFieldRepresentable`), the time and a stop glyph, mirrored left-handed so the stop glyph stays at the bar's edge.
/// Waiting for the transcript it is the short shimmer, which takes no taps; VoiceOver hears the wait from the label.
private struct DictationIsland: View {
    let client: KeyboardDictationClient
    let state: KeyboardViewState
    let height: CGFloat
    let compact: Bool
    let leftHanded: Bool
    let onAction: () -> Void
    /// Dictation cannot run here (no Full Access, configuration, versions): show why instead.
    let onUnavailable: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// Counts taps on Start without a session: each pops its dot once, the light acknowledgement while iOS asks to open
    /// LocalFlow.
    @State private var bounces = 0

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let island = palette.island
        Button {
            if state.mode.allowsDictation {
                onAction()
                if state.mode == .hostUnavailable { bounces += 1 }
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

    /// What it holds hands over as it changes form: what leaves goes first, quickly, and what arrives in the grown
    /// island follows once there is room, so it never shows squeezed (taps work throughout).
    private var arrival: AnyTransition { DictationBarView.handing(over: reduceMotion) }

    @ViewBuilder private func content(_ palette: BrandPalette) -> some View {
        let ink = Color(palette.island.ink)
        switch CapsuleContent(mode: state.mode) {
        case .start:
            HStack(spacing: 6) {
                let dot = SessionDot(mode: state.mode, sessionReady: state.sessionReady)
                IslandMark(line: ink, dot: Color(dot.color(palette)), side: 19, breathes: dot.breathes && !reduceMotion,
                           pops: reduceMotion ? 0 : bounces)
                    // The dot changes colour with a small, quick cross-fade.
                    .animation(.easeOut(duration: 0.2), value: dot)
                Text("Start").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            }
            // A process's first live timer text takes about 55 ms to resolve (round 9: Foundation's attribute-scope
            // reflection, profiled on the simulator); resolved here while idle, it no longer stalls Start's first frames
            // (round 8 council, Opus finding 2). A timer that has ended: it never ticks.
            .background {
                Text(timerInterval: Date.distantPast...Date.distantPast, countsDown: false)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .hidden()
                    .accessibilityHidden(true)
            }
            .transition(arrival)
        case .starting, .stop:
            // One view from starting to recording: the dimmed row brightens and the time arrives, nothing blinks.
            recording(palette, startedAt: recordingStartedAt).transition(arrival)
        case .processing:
            DotFieldRepresentable(kind: .shimmer, level: 0, ink: palette.shimmer, mark: nil, reduceMotion: reduceMotion)
                .padding(.horizontal, CGFloat(DotWave.shimmerInset))
                .frame(height: waveHeight)
                .accessibilityHidden(true)
                .transition(arrival)
        }
    }

    /// When the recording began; nil while it is still starting.
    private var recordingStartedAt: Date? {
        if case .stop(let startedAt) = CapsuleContent(mode: state.mode) { return startedAt }
        return nil
    }

    /// The recording's height for the wave's dots, inside the island's rounded ends.
    private var waveHeight: CGFloat { min(24, height - 12) }

    /// Starting and recording: the wave (its calm row, dimmed, until the recording begins), the time while recording, and
    /// the stop glyph. Left-handed the order is mirrored, so the stop glyph is at the bar's edge, under the thumb and far
    /// from Cancel, and the wave settles into the mark's dot beside the time.
    private func recording(_ palette: BrandPalette, startedAt: Date?) -> some View {
        let ink = Color(palette.island.ink)
        let mirrored = leftHanded
        let wave = DotFieldRepresentable(kind: .wave(live: startedAt != nil), level: Double(state.levels.last ?? 0),
                                         ink: palette.island.ink, mark: palette.live, reduceMotion: reduceMotion, mirrored: mirrored)
            .frame(maxWidth: .infinity)
            .frame(height: waveHeight)
            .opacity(startedAt == nil ? 0.55 : 1)
            .animation(.easeOut(duration: 0.15), value: startedAt == nil)
            // VoiceOver hears the mode from Stop's value; the wave is decoration.
            .accessibilityHidden(true)
        // The time's room is kept from the start, so nothing in the island moves when the recording begins.
        let time = Group {
            if let startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                Text(verbatim: "0:00").hidden()
            }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(ink.opacity(0.75))
        .lineLimit(1)
        .fixedSize()
        let stop = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(ink)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
        return HStack(spacing: 8) {
            if mirrored {
                stop
                time
                wave
            } else {
                wave
                time
                stop
            }
        }
        .padding(.leading, mirrored ? 14 : 12)
        .padding(.trailing, mirrored ? 12 : 14)
    }

    /// The mode and the time while recording; on Start, the status its dot shows, in words.
    private var accessibilityValue: String {
        KeyboardMessages.islandAccessibilityValue(for: state.mode, detail: state.spokenStatus, now: Date())
    }

    private var accessibilityHint: String {
        switch state.mode {
        case .hostUnavailable: return "Opens LocalFlow to start a session"
        case .starting, .recording: return "Stops listening and inserts what you said"
        default: return ""
        }
    }
}

/// The ridge mark on the island: its line in the island's ink, its dot the session's colour (`SessionDot`), `side` points
/// across, a little larger and heavier than the icon's proportions so the W reads at this size. While the model prepares
/// the dot breathes; each change of `pops` (a tap on Start without a session) swells it once, quickly.
private struct IslandMark: View {
    let line: Color
    let dot: Color
    let side: CGFloat
    var breathes = false
    var pops = 0
    @State private var dim = false

    var body: some View {
        ZStack {
            RidgeMarkShape(weight: 1.3).stroke(line, style: RidgeMarkShape.style(side: side, weight: 1.3))
            RidgeMarkShape(dot: true, weight: 1.3).fill(dot)
                .opacity(breathes && dim ? 0.35 : 1)
                .keyframeAnimator(initialValue: 1.0, trigger: pops) { content, scale in
                    content.scaleEffect(scale, anchor: RidgeMarkShape.dotAnchor(weight: 1.3))
                } keyframes: { _ in
                    SpringKeyframe(1.6, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1, duration: 0.3, spring: .smooth)
                }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .onAppear { if breathes { breathe() } }
        .onChange(of: breathes) { _, now in
            if now { breathe() } else { withAnimation(.easeOut(duration: 0.2)) { dim = false } }
        }
    }

    /// A slow pulse, out and back every 1.2 s, for as long as it breathes.
    private func breathe() {
        dim = false
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
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

/// Cancel's tap area (`KeyboardMetrics.cancelTapArea`) in its circle's coordinates; it looks the same. The circle is
/// centred in the bar.
private struct CancelTapShape: Shape {
    let compact: Bool

    func path(in rect: CGRect) -> Path {
        let barHeight = compact ? KeyboardMetrics.compactBarHeight : KeyboardMetrics.barHeight
        let top = (barHeight - Double(rect.height)) / 2
        let area = KeyboardMetrics.cancelTapArea(
            circle: KeyRect(x: Double(rect.minX), y: Double(rect.minY) + top, width: Double(rect.width), height: Double(rect.height)),
            barHeight: barHeight, compact: compact)
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
                        RidgeMarkGlyph(color: color(palette.markLine), dot: color(palette.markDot), side: 18)
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
