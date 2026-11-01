import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity extension (ARCHITECTURE.md, "Live Activity"): the session in the Dynamic Island and on the Lock
/// Screen. It draws only `SessionActivityState`, the phase and its timers, and reads nothing else.
@main
struct LocalFlowActivityBundle: WidgetBundle {
    var body: some Widget {
        SessionActivityWidget()
    }
}

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(ActivityLook.pill)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state, stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(state: state, isStale: stale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: state, isStale: stale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(state: state, isStale: stale)
                }
            } compactLeading: {
                MarkView(state: state, isStale: stale, width: 20, height: 18)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("LocalFlow")
            } compactTrailing: {
                CompactTrailing(state: state, isStale: stale)
            } minimal: {
                MinimalView(state: state, isStale: stale)
            }
            .keylineTint(ActivityLook.keyline)
        }
    }
}

// MARK: Look

/// Monochrome, like the keyboard's island: white ink on a near-black pill, the brand colours only in the mark's dot,
/// the recording dot and the transcript's glint.
enum ActivityLook {
    static let pill = Color(red: 10 / 255, green: 11 / 255, blue: 12 / 255)
    static let keyline = Color.white.opacity(0.12)
    static let aurora = Color(red: 109 / 255, green: 255 / 255, blue: 168 / 255)
    static let glacier = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    static let coral = Color(red: 255 / 255, green: 125 / 255, blue: 94 / 255)
    static let secondary = Color.white.opacity(0.6)

    /// The mark's dot: aurora while ready, coral while recording, glacier while the transcript is made.
    static func accent(_ phase: SessionActivityState.Phase, isStale: Bool) -> Color {
        if isStale { return Color.white.opacity(0.35) }
        switch phase {
        case .ready: return aurora
        case .recording: return coral
        case .transcribing, .preparing: return glacier
        }
    }

    static func title(_ phase: SessionActivityState.Phase, isStale: Bool) -> String {
        if isStale { return "Session ended" }
        switch phase {
        case .ready: return "Ready to dictate"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing model"
        }
    }
}

/// State changes: quick and settled, never a slow fade (the owner: smooth, but snappy). None in Always On, where the
/// system draws no animation anyway (`SessionActivityMotion`).
private struct PhaseMotion: ViewModifier {
    let value: SessionActivityState.Phase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content.animation(SessionActivityMotion.duration(luminanceReduced: isLuminanceReduced).map { .snappy(duration: $0) },
                          value: value)
    }
}

/// A view arriving or leaving as `SessionActivityMotion` says: with Reduce Motion always a cross-fade.
private struct Handover: ViewModifier {
    let kind: (Bool) -> SessionActivityMotion.Handover
    var anchor: UnitPoint = .center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        switch kind(reduceMotion) {
        case .fade: content.transition(.opacity)
        case .push: content.transition(.push(from: .bottom).combined(with: .opacity))
        case .scale(let from): content.transition(.opacity.combined(with: .scale(scale: from, anchor: anchor)))
        }
    }
}

private extension View {
    func phaseMotion(_ phase: SessionActivityState.Phase) -> some View { modifier(PhaseMotion(value: phase)) }
}

/// A change of words slides up a little as it blurs in; with Reduce Motion it only cross-fades.
private struct WordsTransition: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(Handover(kind: SessionActivityMotion.words))
    }
}

// MARK: The ridge mark

/// The LocalFlow ridge mark (`RidgeMark`, KeyboardCore): the W line in white, the dot in the phase's accent.
struct MarkView: View {
    let state: SessionActivityState
    let isStale: Bool
    /// Drawn at this size, not whatever the region proposes: island regions can propose odd sizes, and the mark must
    /// never be squeezed or clipped.
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fitted = RidgeMark.fitted(in: KeyRect(x: 0, y: 0, width: width, height: height), weight: height < 24 ? 1.35 : 1.1)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addLines(fitted.line.map { CGPoint(x: $0.x, y: $0.y) })
            }
            .stroke(Color.white.opacity(isStale ? 0.45 : 1),
                    style: StrokeStyle(lineWidth: fitted.lineWidth, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(ActivityLook.accent(state.phase, isStale: isStale))
                .frame(width: fitted.dotRadius * 2, height: fitted.dotRadius * 2)
                // The dot grows a touch while recording: the one sign of life the mark gives (not with Reduce Motion).
                .scaleEffect(SessionActivityMotion.markDotScale(phase: state.phase, isStale: isStale, reduceMotion: reduceMotion))
                .position(x: fitted.dot.x, y: fitted.dot.y)
        }
        .frame(width: width, height: height)
        .fixedSize()
        .phaseMotion(state.phase)
        .accessibilityHidden(true)
    }
}

// MARK: The dot strip

/// A row of dots, as the keyboard's island draws its wave (`DotWave`): one calm row of equal dots when ready, the voice's
/// swell while recording, and a cool glint of light where the wait's shimmer is (the middle while transcribing, the left
/// third while the model prepares). Every dot is its own view, so a phase change moves each dot's size and brightness
/// rather than swapping pictures: the row swells as recording starts and settles back as it stops. With Reduce Motion
/// the dots keep their size and only their brightness changes (`SessionActivityMotion.dotScale`).
struct DotStrip: View {
    let phase: SessionActivityState.Phase
    let isStale: Bool
    let columns: Int
    let dot: CGFloat
    let gap: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0 ..< columns, id: \.self) { column in
                let u = columns > 1 ? Double(column) / Double(columns - 1) : 0.5
                let lit = StripPattern.lit(phase: isStale ? .ready : phase, u: u)
                Circle()
                    .fill(StripPattern.color(phase: phase, u: u, isStale: isStale))
                    .opacity((isStale ? 0.6 : 1) * (DotWave.restBrightness + (1 - DotWave.restBrightness) * lit))
                    .scaleEffect(SessionActivityMotion.dotScale(lit: lit, reduceMotion: reduceMotion))
                    .frame(width: dot, height: dot)
            }
        }
        .phaseMotion(phase)
        .accessibilityHidden(true)
    }
}

/// How much a phase lifts the strip's dot `u` of the way along it, from 0 (at rest) to 1, and its colour, with the
/// keyboard's own shapes (`DotWave.lift`, `DotWave.glow`). Live Activities draw no continuous animation, so each phase is
/// one still moment of the keyboard's motion.
enum StripPattern {
    static func lit(phase: SessionActivityState.Phase, u: Double) -> Double {
        switch phase {
        case .ready: return 0
        case .recording: return DotWave.lift(at: u, level: 1, phase: 0.6)
        case .transcribing, .preparing: return DotWave.glow(at: u, sweep: glint(phase))
        }
    }

    static func color(phase: SessionActivityState.Phase, u: Double, isStale: Bool) -> Color {
        guard !isStale, phase == .transcribing || phase == .preparing else { return .white }
        // The wait's glint: a little glacier where the light gathers.
        return DotWave.glow(at: u, sweep: glint(phase)) > 0.45 ? ActivityLook.glacier : .white
    }

    /// Where the light gathers while the transcript is made: the middle, or the left third while the model prepares.
    private static func glint(_ phase: SessionActivityState.Phase) -> Double { phase == .preparing ? 0.3 : 0.5 }
}

// MARK: Timers

/// The recording's elapsed time, counting up from its start; or a ready session's time left. Live timers are the only
/// thing that moves between updates. The host cuts a recording off at five minutes and the activity is stale soon
/// after, so the hour's bound is never reached.
private struct PhaseTimer: View {
    let state: SessionActivityState

    var body: some View {
        switch state.phase {
        case .recording:
            let since = state.since ?? .now
            Text(timerInterval: since ... since.addingTimeInterval(3600), countsDown: false, showsHours: false)
        case .ready:
            if let endsAt = state.endsAt {
                Text(timerInterval: min(Date.now, endsAt) ... endsAt, countsDown: true, showsHours: false)
            }
        case .transcribing, .preparing:
            EmptyView()
        }
    }
}

// MARK: Dynamic Island

private struct CompactTrailing: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if state.phase == .recording && !isStale {
                HStack(spacing: 4) {
                    Circle().fill(ActivityLook.coral).frame(width: 6, height: 6)
                        .accessibilityLabel(ActivityLook.title(state.phase, isStale: isStale))
                    PhaseTimer(state: state)
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 34, alignment: .trailing)
                }
                .modifier(WordsTransition())
            } else {
                DotStrip(phase: state.phase, isStale: isStale, columns: 6, dot: 4, gap: 1.6)
                    .frame(width: 34)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ActivityLook.title(state.phase, isStale: isStale))
                    .modifier(Handover(kind: SessionActivityMotion.compactTrailing, anchor: .trailing))
            }
        }
        .phaseMotion(state.phase)
    }
}

private struct MinimalView: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        ZStack {
            if state.phase == .recording && !isStale {
                Circle().fill(ActivityLook.coral).frame(width: 9, height: 9)
                    .modifier(Handover(kind: SessionActivityMotion.minimalDot))
            } else {
                MarkView(state: state, isStale: isStale, width: 18, height: 16)
                    .transition(.opacity)
            }
        }
        .phaseMotion(state.phase)
        // The one element VoiceOver reads here: what the session is doing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LocalFlow, \(ActivityLook.title(state.phase, isStale: isStale))")
    }
}

private struct ExpandedLeading: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 7) {
            MarkView(state: state, isStale: isStale, width: 24, height: 22)
            Text("LocalFlow")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.leading, 4)
    }
}

private struct ExpandedTrailing: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if !isStale, state.phase == .recording || (state.phase == .ready && state.endsAt != nil) {
                HStack(spacing: 5) {
                    if state.phase == .recording {
                        Circle().fill(ActivityLook.coral).frame(width: 7, height: 7)
                    } else {
                        Text(SessionActivityState.countdownLead).foregroundStyle(ActivityLook.secondary)
                    }
                    PhaseTimer(state: state)
                        .foregroundStyle(.white)
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .id(state.phase)
                .modifier(WordsTransition())
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.trailing, 4)
        .phaseMotion(state.phase)
    }
}

private struct ExpandedBottom: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 10) {
            DotStrip(phase: state.phase, isStale: isStale, columns: 25, dot: 7, gap: 5)
                .frame(maxWidth: .infinity, minHeight: 14)
            Text(ActivityLook.title(state.phase, isStale: isStale))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(ActivityLook.secondary)
                .id(isStale ? "stale" : state.phase.rawValue)
                .modifier(WordsTransition())
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .phaseMotion(state.phase)
    }
}

// MARK: Lock Screen

struct LockScreenView: View {
    let state: SessionActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                MarkView(state: state, isStale: isStale, width: 30, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityLook.title(state.phase, isStale: isStale))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .id(isStale ? "stale" : state.phase.rawValue)
                        .modifier(WordsTransition())
                    // One line in every phase, so the panel keeps its height as the phase changes.
                    subtitle
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .font(.system(size: 14, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(ActivityLook.secondary)
                }
                Spacer(minLength: 0)
                if state.phase == .recording && !isStale {
                    HStack(spacing: 6) {
                        Circle().fill(ActivityLook.coral).frame(width: 8, height: 8)
                        PhaseTimer(state: state)
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .modifier(WordsTransition())
                }
            }
            DotStrip(phase: state.phase, isStale: isStale, columns: 27, dot: 7, gap: 5)
                .frame(maxWidth: .infinity, minHeight: 14)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .phaseMotion(state.phase)
    }

    @ViewBuilder private var subtitle: some View {
        if isStale {
            Text("Open LocalFlow to start a new one")
        } else {
            switch state.phase {
            case .ready:
                if let endsAt = state.endsAt {
                    Text("Session \(SessionActivityState.countdownLead) \(Text(timerInterval: min(Date.now, endsAt) ... endsAt, countsDown: true, showsHours: false)) \(SessionActivityState.countdownTail)")
                } else {
                    Text("Flow session")
                }
            case .recording: Text("Tap Stop on the keyboard when done")
            case .transcribing: Text("Your words land in a moment")
            case .preparing: Text("The first dictation takes a little longer")
            }
        }
    }
}
