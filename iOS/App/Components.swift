import SwiftUI
import UIKit

/// The Wilderness Labs palette (wilderness-labs-site, `public/css/style.css`): forest night, aurora green,
/// glacier cyan, coral and ember. The app is always dark, as the site is (`UIUserInterfaceStyle`). As on the keyboard
/// and the Live Activity, the controls are monochrome: white ink on a near-black pill with a hairline edge, and the
/// brand colours only on small dots and glyphs that mark a state (ARCHITECTURE.md, "Keyboard look").
enum Theme {
    static let aurora = Color(red: 109 / 255, green: 255 / 255, blue: 168 / 255)
    /// Loading and preparing states, as on the site.
    static let glacier = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    /// Warnings and failures.
    static let ember = Color(red: 245 / 255, green: 198 / 255, blue: 107 / 255)
    /// Recording, as the Live Activity's recording dot, and destructive actions.
    static let coral = Color(red: 255 / 255, green: 125 / 255, blue: 94 / 255)
    static let cardBackground = Color(red: 15 / 255, green: 26 / 255, blue: 28 / 255)
    static let screenBackground = Color(red: 5 / 255, green: 8 / 255, blue: 10 / 255)
    /// The island's near-black pill (#09090A) and its grey hairline, as on the keyboard.
    static let pill = Color(red: 9 / 255, green: 9 / 255, blue: 10 / 255)
    static let edge = Color(red: 0.43, green: 0.43, blue: 0.44)
    /// Secondary ink, as the Live Activity's.
    static let secondaryInk = Color.white.opacity(0.6)
    /// A switch that is on: neutral, so the only colour in a list is state.
    static let toggle = Color(white: 0.62)
    /// A state's dot without an accent: not prepared yet, or cancelled.
    static let neutralDot = Color.white.opacity(0.4)

    static func color(_ accent: AppAccent) -> Color {
        switch accent {
        case .aurora: return aurora
        case .glacier: return glacier
        case .coral: return coral
        case .ember: return ember
        }
    }
}

extension View {
    /// The screen background behind a List or Form, whose sections set `Theme.cardBackground` rows.
    func themedListBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.screenBackground.ignoresSafeArea())
    }

    /// The island's surface: the near-black pill with its hairline, a full point with Increase Contrast.
    func islandSurface() -> some View { islandSurface(Capsule()) }

    func islandSurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(IslandSurface(shape: shape))
    }

    /// Actions pinned under scrolling content: the screen's background behind them, and a short fade above, so what
    /// scrolls under them never shows through their words.
    func actionBarBackground() -> some View {
        background(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.screenBackground.opacity(0), Theme.screenBackground],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                Theme.screenBackground
            }
            .padding(.top, -20)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

private struct IslandSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Theme.pill, in: shape)
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

// MARK: Display face

/// Geist Serif Regular (Vercel, SIL OFL 1.1; `Resources/Fonts`), the display face: large titles and hero headlines
/// only. Everything else stays in the system font. It has one weight, so it is never bolded. Without the font (a build
/// that failed to bundle it) the display text falls back to the system font.
enum DisplayFace {
    static let name = "GeistSerif-Regular"
    static let isAvailable = UIFont(name: name, size: 17) != nil

    /// The size at the default text size; Dynamic Type scales it with `style`. A touch larger than SF's own sizes:
    /// a regular serif reads smaller than a bold sans.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 36
        case .title: return 30
        case .title2: return 25
        default: return 22
        }
    }

    /// The navigation bar's large titles (Home's "LocalFlow", Dictionary's) in the display face; inline titles stay in
    /// the system font. Called at launch and again when the text size changes.
    @MainActor
    static func styleLargeTitles() {
        guard let font = UIFont(name: name, size: size(.largeTitle)) else { return }
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: font),
            .foregroundColor: UIColor.white,
        ]
    }
}

extension Font {
    /// The display face at `style`'s size, scaled with Dynamic Type.
    static func display(_ style: Font.TextStyle) -> Font {
        DisplayFace.isAvailable ? .custom(DisplayFace.name, size: DisplayFace.size(style), relativeTo: style) : .system(style)
    }
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

// MARK: Buttons

/// The main action: the island's pill, white ink, the accent only on its glyph (`accent`). A press dims what it holds,
/// quickly, as on the keyboard; disabled, it dims to 45%. At large text its words wrap to a second line rather than
/// shrink or truncate.
struct PrimaryButtonStyle: ButtonStyle {
    var accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, accent: accent)
    }
}

private struct PillLabel: View {
    let configuration: ButtonStyleConfiguration
    let accent: Color?
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 50
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .labelStyle(AccentGlyphLabelStyle(accent: accent))
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Capsule())
            .islandSurface()
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A quieter action beside the main one: secondary ink, no surface, still a 44 pt target.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.secondaryInk

    func makeBody(configuration: Configuration) -> some View {
        TextActionLabel(configuration: configuration, tint: tint)
    }
}

private struct TextActionLabel: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : (isEnabled ? 1 : 0.45))
    }
}

/// The island's round ✕ (and other glyph-only controls): a near-black disc with a hairline, at least 44 pt.
struct RoundIslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundIslandLabel(configuration: configuration)
    }
}

private struct RoundIslandLabel: View {
    let configuration: ButtonStyleConfiguration
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 50
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(width: side, height: side)
            .contentShape(Circle())
            .islandSurface(Circle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A footer's glyph and words, in the footer's own ink.
struct FootnoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.accessibilityHidden(true)
            configuration.title
        }
    }
}

/// A label whose icon takes the accent (a small glyph) and whose title stays white.
struct AccentGlyphLabelStyle: LabelStyle {
    var accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            // The glyph stops growing at the largest sizes, so the words keep the pill's width.
            configuration.icon.foregroundStyle(accent ?? .white).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            configuration.title
        }
    }
}

// MARK: Glyphs and marks

/// A row's glyph: plain, in secondary ink (or a state's accent), no tile. It stops growing at the largest text sizes,
/// so the title beside it keeps the width.
struct SymbolTile: View {
    var systemName: String
    var tint: Color = Theme.secondaryInk
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.body)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(tint)
            .frame(width: min(width, 34))
            .accessibilityHidden(true)
    }
}

/// A step's number on a small island disc. The disc and its numeral stop growing at large text, so the words beside
/// it keep the width. Decorative: the step's own label says its number.
struct NumberBadge: View {
    var number: Int
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 24

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.footnote.weight(.bold))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(.white)
            .frame(width: min(side, 30), height: min(side, 30))
            .islandSurface(Circle())
            .accessibilityHidden(true)
    }
}

/// A step's glyph in hero areas: monochrome white, no disc or glow. Decorative.
struct HeroSymbol: View {
    var systemName: String
    var tint: Color = .white
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

/// A state's dot: the accent, or a neutral grey without one.
struct StateDot: View {
    var accent: AppAccent?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 8

    var body: some View {
        Circle()
            .fill(accent.map(Theme.color) ?? Theme.neutralDot)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// LocalFlow's ridge mark (`RidgeMark`, shared with the keyboard and the Live Activity): the W line or its dot.
struct RidgeMarkShape: Shape {
    var dot = false
    var weight = 1.0

    func path(in rect: CGRect) -> Path {
        let mark = RidgeMark.fitted(in: KeyRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width),
                                                height: Double(rect.height)), weight: weight)
        var path = Path()
        if dot {
            path.addEllipse(in: CGRect(x: mark.dot.x - mark.dotRadius, y: mark.dot.y - mark.dotRadius,
                                       width: 2 * mark.dotRadius, height: 2 * mark.dotRadius))
        } else {
            path.addLines(mark.line.map { CGPoint(x: $0.x, y: $0.y) })
        }
        return path
    }
}

/// The ridge mark in white with its dot in a state's accent, `side` points across. Decorative.
struct RidgeMarkView: View {
    var dot: Color = Theme.aurora
    var side: CGFloat
    /// The keyboard draws the small mark heavier, so the W reads (1.3 at 19 pt).
    var weight: Double?

    var body: some View {
        let weight = weight ?? (side < 32 ? 1.3 : 1.05)
        let fitted = RidgeMark.fitted(in: KeyRect(x: 0, y: 0, width: Double(side), height: Double(side)), weight: weight)
        ZStack {
            RidgeMarkShape(weight: weight)
                .stroke(Color.white, style: StrokeStyle(lineWidth: CGFloat(fitted.lineWidth), lineCap: .round, lineJoin: .round))
            RidgeMarkShape(dot: true, weight: weight).fill(dot)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The keyboard island's recording wave (`DotWave`): one row of white dots that shows the voice, settling into a dot in
/// `accent` at the right (the recording dot). `live` false is the calm row, dimmed, while the microphone starts. With
/// Reduce Motion the row stands still at each level.
struct IslandWave: View {
    var level: Float
    var live: Bool
    var accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder = WaveRecorder()

    var body: some View {
        Group {
            if live && !reduceMotion {
                TimelineView(.animation(minimumInterval: DotWave.frameInterval)) { timeline in
                    Canvas { context, size in
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        recorder.record(Double(level), at: now)
                        let dots = DotWave.dots(trace: recorder.trace, now: now, width: size.width, height: size.height)
                        draw(context, dots: dots, mark: DotWave.markDot(level: recorder.follower.value, width: size.width, height: size.height))
                    }
                }
            } else {
                Canvas { context, size in
                    let held = live ? Double(level) : 0
                    draw(context, dots: DotWave.dots(level: held, width: size.width, height: size.height),
                         mark: DotWave.markDot(level: held, width: size.width, height: size.height))
                }
                .opacity(live ? 1 : 0.55)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, dots: [DotWave.Dot], mark: DotWave.Dot) {
        for dot in dots {
            context.fill(Path(ellipseIn: rect(dot)), with: .color(.white.opacity(dot.brightness)))
        }
        context.fill(Path(ellipseIn: rect(mark)), with: .color(accent))
    }

    private func rect(_ dot: DotWave.Dot) -> CGRect {
        CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: 2 * dot.radius, height: 2 * dot.radius)
    }
}

/// The wave's level, followed and recorded once per frame, as the keyboard records it.
private final class WaveRecorder {
    var trace = DotWave.Trace()
    var follower = DotWave.LevelFollower()
    private var last: Double?

    func record(_ level: Double, at now: Double) {
        if let last { follower.follow(level, over: now - last) }
        last = now
        trace.record(follower.value, at: now)
    }
}

/// The wait's shimmer (`DotWave.shimmer`): the row at rest with a glacier glint sweeping along it every
/// `DotWave.shimmerPeriod`; with Reduce Motion the glint stands still in the middle.
struct IslandShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, size in draw(context, size: size, sweep: 0.5) }
            } else {
                TimelineView(.animation(minimumInterval: DotWave.frameInterval)) { timeline in
                    Canvas { context, size in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: DotWave.shimmerPeriod)
                        draw(context, size: size, sweep: -0.2 + 1.4 * phase / DotWave.shimmerPeriod)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, sweep: Double) {
        for dot in DotWave.shimmer(sweep: sweep, width: size.width, height: size.height) {
            let glint = dot.brightness > 0.75
            context.fill(Path(ellipseIn: CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: 2 * dot.radius,
                                                height: 2 * dot.radius)),
                         with: .color((glint ? Theme.glacier : .white).opacity(dot.brightness)))
        }
    }
}

// MARK: Model

/// "Speech model" and its state: a dot, or a check once ready. While it prepares, a glacier line and the time so far sit
/// in the row (beside the title, or under it at accessibility sizes), so the row keeps its height from preparing to
/// ready; the line fills toward an estimate only when this device has prepared the model before. At accessibility sizes
/// the glyphs share a line above the title.
struct ModelStatusRow: View {
    @ObservedObject var transcriber: ParakeetTranscriber
    var showsPrepareButton = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let large = typeSize.isAccessibilitySize
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Group {
                    if large {
                        // As the session card: the glyphs share a line, the title has the full width.
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                SymbolTile(systemName: "cpu")
                                badge
                            }
                            Text("Speech model")
                        }
                    } else {
                        HStack(spacing: 10) {
                            SymbolTile(systemName: "cpu")
                            Text("Speech model").layoutPriority(1)
                            badge
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speech model")
                .accessibilityValue(ModelBadge.spoken(transcriber.modelState))
                if !large { Spacer(minLength: 0) }
                if transcriber.modelState == .preparing, let started = transcriber.preparationStartedAt {
                    PreparationProgress(startedAt: started, estimate: transcriber.estimatedPreparationSeconds)
                        .frame(maxWidth: large ? .infinity : 96)
                        .transition(.opacity)
                }
                if showsPrepareButton, transcriber.modelState == .notPrepared || transcriber.modelState == .failed {
                    Button(transcriber.modelState == .failed ? "Retry" : "Prepare") { transcriber.prepare() }
                        .buttonStyle(CompactPillStyle())
                        .accessibilityIdentifier("model.prepare")
                }
            }
            if let hint = transcriber.lastFailureHint {
                Label(hint.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.ember)
            }
            if transcriber.modelState == .unavailable {
                Text(ModelBadge.spoken(.unavailable)).font(.footnote).foregroundStyle(Theme.secondaryInk)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: transcriber.modelState)
    }

    @ViewBuilder
    private var badge: some View {
        if let symbol = ModelBadge.symbol(transcriber.modelState) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Theme.aurora)
                .accessibilityHidden(true)
        } else {
            StateDot(accent: ModelBadge.accent(transcriber.modelState))
        }
    }
}

/// A small pill for an action inside a row (Prepare).
struct CompactPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactPillLabel(configuration: configuration)
    }
}

private struct CompactPillLabel: View {
    let configuration: ButtonStyleConfiguration
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.horizontal, 16)
            .frame(minHeight: height)
            .islandSurface()
            // The row's target reaches 44 pt even where the pill is drawn smaller.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The model preparing, in a row: a glacier line and the time so far.
struct PreparationProgress: View {
    var startedAt: Date
    var estimate: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            HStack(spacing: 8) {
                GlacierBar(fraction: estimate.map { min(elapsed / $0, 0.95) })
                Text(Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preparing")
            .accessibilityValue(Duration.seconds(Int(elapsed)).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
        }
    }
}

/// A thin glacier progress line; without a fraction (no estimate yet) a short segment travels along it, standing still
/// in the middle with Reduce Motion.
struct GlacierBar: View {
    var fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let fraction {
                    Capsule().fill(Theme.glacier)
                        .frame(width: max(4, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
                        .animation(.easeOut(duration: 0.4), value: fraction)
                } else if reduceMotion {
                    Capsule().fill(Theme.glacier).frame(width: proxy.size.width * 0.25)
                        .offset(x: proxy.size.width * 0.375)
                } else {
                    TimelineView(.animation(minimumInterval: DotWave.frameInterval)) { timeline in
                        let period = 1.6
                        let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        Capsule().fill(Theme.glacier).frame(width: proxy.size.width * 0.25)
                            .offset(x: proxy.size.width * (-0.25 + 1.25 * t))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

extension HostErrorCode {
    /// Short, content-free explanations for the UI.
    var message: String {
        switch self {
        case .microphonePermissionDenied: return "Microphone access is off. Turn it on in Settings."
        case .audioSessionFailed: return "The microphone couldn’t start."
        case .startupTimeout: return "The microphone took too long to start."
        case .interrupted: return "Another app or a call interrupted the microphone."
        case .deviceLocked: return "The iPhone was locked."
        case .keyboardDismissed: return "The keyboard was closed, so recording stopped."
        case .sessionInactive: return "The session ended."
        case .modelUnavailable: return "This build has no speech model."
        case .modelFailed: return "The speech model couldn’t be prepared."
        case .transcriptionFailed: return "Transcription failed."
        case .backgroundTimeExpired: return "iOS stopped the transcription in the background."
        case .notRecording: return "Nothing was recorded."
        case .tooLong: return "The dictation was too long."
        case .superseded: return "A newer dictation replaced this one."
        }
    }
}
