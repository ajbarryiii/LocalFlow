import SwiftUI
import AppKit

// MARK: - State

final class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var audioLevel: Float = 0.0
    @Published var recordingTriggerMode: RecordingTriggerMode = .hold
    @Published var updateVersion: String = ""
    @Published var errorMessage: String?
    @Published var toastID: UUID?
    /// The only copy of a visible suggestion; cleared whenever it leaves the screen.
    @Published var suggestionGate = SuggestionPresentationGate()
    /// The app of the suggestion presented with this id (DESIGN §3.6). It applies
    /// only while that id is still `suggestionGate.activeID`.
    @Published var suggestionApp: (id: UUID, app: DictionaryApp?)?

    var visibleSuggestionApp: DictionaryApp? {
        guard let suggestionApp, suggestionApp.id == suggestionGate.activeID else { return nil }
        return suggestionApp.app
    }
}

enum OverlayPhase: Equatable {
    case initializing
    case recording
    case transcribing
    case feedback
    case updateAvailable
    /// A dictionary suggestion after a correction; timers and buttons are bound to `id`.
    /// The word itself lives only in `RecordingOverlayState.suggestionGate`.
    case dictionarySuggestion(id: UUID)

    var isDictionarySuggestion: Bool {
        if case .dictionarySuggestion = self { return true } else { return false }
    }
}

// MARK: - NSScreen Helpers

extension NSScreen {
    /// CoreGraphics display identifier for this screen, or nil if the
    /// device description is missing the key (vanishingly rare). Stable
    /// across screen-arrangement changes for as long as the display is
    /// connected, which is what the overlay picker stores in UserDefaults.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Panel Helpers

/// The overlay never becomes key or main, so typing stays in the destination app
/// even after a click on one of its buttons.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click without activating or focusing the overlay first.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private func makeOverlayPanel(width: CGFloat, height: CGFloat) -> NSPanel {
    let panel = OverlayPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

private func makeNotchContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    acceptsFirstMouse: Bool = false,
    rootView: V
) -> NSView {
    let shaped = rootView
        .frame(width: width, height: height)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))

    let hosting = acceptsFirstMouse ? FirstMouseHostingView(rootView: shaped) : NSHostingView(rootView: shaped)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

// MARK: - Manager

final class RecordingOverlayManager {
    private var overlayWindow: NSPanel?
    private let overlayState = RecordingOverlayState()
    private var lockedOverlayWidth: CGFloat?

    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    /// Called on the main thread at most once per suggestion, only for the one on screen.
    var onDictionarySuggestionAction: ((DictionarySuggestion, DictionaryApp?, DictionarySuggestionAction) -> Void)?

    /// The screen the overlay should drop down on. The user picks one of
    /// three modes in Settings, stored in UserDefaults under
    /// `overlay_display_id`:
    ///
    /// - `0` (default) — Active window: follows focus across monitors via
    ///   NSScreen.main. Default for backward compatibility — the original
    ///   behavior on a single-display setup is unchanged.
    /// - `-1` — Primary display: always NSScreen.screens.first (the display
    ///   designated as primary in System Settings → Displays).
    /// - any positive integer — specific NSScreen displayID. Falls back to
    ///   primary if that display is unplugged.
    private var targetScreen: NSScreen? {
        let savedID = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch savedID {
        case 0:
            return NSScreen.main ?? NSScreen.screens.first
        case -1:
            return NSScreen.screens.first ?? NSScreen.main
        default:
            if let match = NSScreen.screens.first(where: { Int($0.displayID ?? 0) == savedID }) {
                return match
            }
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private var screenHasNotch: Bool {
        guard let screen = targetScreen else { return false }
        return screen.safeAreaInsets.top > 0
    }

    private var notchWidth: CGFloat {
        guard let screen = targetScreen, screenHasNotch else { return 0 }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - leftArea.width - rightArea.width
    }

    private var notchOverlap: CGFloat {
        guard let screen = targetScreen else { return 0 }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    private var overlayAcceptsMouseEvents: Bool {
        (overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle)
            || overlayState.phase == .updateAvailable
            || overlayState.phase.isDictionarySuggestion
    }

    func showInitializing(mode: RecordingTriggerMode = .hold) {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.phase = .initializing
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: false)
        }
    }

    func showRecording(mode: RecordingTriggerMode = .hold) {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func transitionToRecording(mode: RecordingTriggerMode = .hold) {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.phase = .recording
            self.updateOverlayLayout(animated: true)
        }
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        DispatchQueue.main.async {
            self.overlayState.recordingTriggerMode = mode
            self.updateOverlayLayout(animated: animated)
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.overlayState.audioLevel = level
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.setTranscribingPhase()
        }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.showFeedbackPanel()
        }
    }

    /// Maximum length of an in-pill error message. Anything longer is
    /// truncated with an ellipsis to keep the pill from stretching across
    /// the menu bar; the full text remains available in `os_log` for
    /// forensic review.
    private static let maxToastMessageLength = 90

    /// Surface a transient error in the menu-bar pill. The pill resizes to
    /// fit the message (subject to the truncation cap), holds for a few
    /// seconds, then dismisses. Intended for non-fatal user-facing errors
    /// that previously only landed in `os_log` — rate limits, network
    /// failures, permission gaps, etc.
    func showError(_ message: String) {
        let truncated: String = {
            if message.count <= Self.maxToastMessageLength { return message }
            let cutoff = message.index(message.startIndex, offsetBy: Self.maxToastMessageLength - 1)
            return String(message[..<cutoff]) + "…"
        }()
        DispatchQueue.main.async { [self] in
            self.preemptSuggestion()
            let toastID = UUID()
            self.overlayState.errorMessage = truncated
            self.overlayState.toastID = toastID
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .feedback
            self.showOverlayPanel(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .feedback,
                      self.overlayState.errorMessage == truncated,
                      self.overlayState.toastID == toastID else {
                    return
                }
                self.overlayState.errorMessage = nil
                self.overlayState.toastID = nil
                self.dismissAll()
            }
        }
    }

    func showUpdateAvailable(version: String) {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.lockedOverlayWidth = nil
            self.overlayState.updateVersion = version
            self.overlayState.phase = .updateAvailable
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.preemptSuggestion()
            self.dismissAll()
        }
    }

    /// Shows a suggestion only when the panel is free (recording, transcribing,
    /// errors and other overlays take priority). It resolves as Not now after
    /// 12 s; a stale timer or click cannot act on a later phase.
    /// Main thread only. A withdrawal issued after this call (a recording press,
    /// a dictionary edit) voids it before it reaches the screen.
    func showDictionarySuggestion(_ suggestion: DictionarySuggestion, app: DictionaryApp?) {
        dispatchPrecondition(condition: .onQueue(.main))
        let requested = overlayState.suggestionGate.withdrawals
        DispatchQueue.main.async { [self] in
            guard self.overlayWindow == nil || self.overlayState.phase.isDictionarySuggestion,
                  let id = self.overlayState.suggestionGate.present(suggestion, requestedAt: requested) else { return }
            self.overlayState.suggestionApp = (id, app)
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .dictionarySuggestion(id: id)
            self.showOverlayPanel(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + SuggestionPresentationGate.lifetime) { [weak self] in
                self?.resolveSuggestion(id: id, action: .notNow)
            }
        }
    }

    /// Withdraws the visible suggestion, and any presentation already requested,
    /// without acting on it: a recording press or start, a dictionary edit, or
    /// the setting turned off. Main thread only; takes effect at once.
    func withdrawDictionarySuggestion() {
        dispatchPrecondition(condition: .onQueue(.main))
        overlayState.suggestionGate.withdraw()
        DispatchQueue.main.async {
            guard self.overlayState.phase.isDictionarySuggestion, self.overlayWindow != nil else { return }
            self.preemptSuggestion()
            self.dismissAll()
        }
    }

    private func resolveSuggestion(id: UUID, action: DictionarySuggestionAction) {
        let app = overlayState.visibleSuggestionApp
        guard let suggestion = overlayState.suggestionGate.resolve(id) else { return }
        dismissAll()
        onDictionarySuggestionAction?(suggestion, app, action)
    }

    private func preemptSuggestion() {
        overlayState.suggestionGate.preempt()
        overlayState.suggestionApp = nil
    }

    private func showOverlayPanel(animatedResize: Bool) {
        let frame = overlayFrame

        if let panel = overlayWindow {
            panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
            panel.becomesKeyOnlyIfNeeded = overlayState.phase.isDictionarySuggestion
            panel.contentView = makeOverlayContent(frame: frame)
            resize(panel: panel, to: frame, animated: animatedResize)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: frame.width, height: frame.height)
        panel.hasShadow = false
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.becomesKeyOnlyIfNeeded = overlayState.phase.isDictionarySuggestion
        panel.contentView = makeOverlayContent(frame: frame)

        guard let screen = targetScreen else { return }

        let hiddenFrame = NSRect(x: frame.origin.x, y: screen.frame.maxY, width: frame.width, height: frame.height)
        panel.setFrame(hiddenFrame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(frame, display: true)
        }

        overlayWindow = panel
    }

    private func updateOverlayLayout(animated: Bool) {
        guard let panel = overlayWindow else { return }
        let frame = overlayFrame
        panel.becomesKeyOnlyIfNeeded = overlayState.phase.isDictionarySuggestion
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)
        resize(panel: panel, to: frame, animated: animated)
    }

    private func setTranscribingPhase() {
        lockedOverlayWidth = overlayWindow?.frame.width ?? overlayWidth
        overlayState.phase = .transcribing
        showOverlayPanel(animatedResize: true)
    }

    private func makeOverlayContent(frame: NSRect) -> NSView {
        if useWingedLayout {
            // Winged layout: notch x-range stays solid black so the cutout masks it.
            let rootView = WingedRecordingView(
                state: overlayState,
                leftWingWidth: Self.leftWingWidth,
                notchWidth: notchWidth,
                rightWingWidth: Self.rightWingWidth,
                height: frame.height,
                onStopButtonPressed: { [weak self] in
                    self?.onStopButtonPressed?()
                }
            )
            return makeNotchContent(
                width: frame.width,
                height: frame.height,
                cornerRadius: 14,
                rootView: AnyView(rootView)
            )
        }

        return makeNotchContent(
            width: frame.width,
            height: frame.height,
            cornerRadius: screenHasNotch ? 18 : 12,
            acceptsFirstMouse: overlayState.phase.isDictionarySuggestion,
            rootView: AnyView(
                RecordingOverlayView(
                    state: overlayState,
                    onStopButtonPressed: { [weak self] in
                        self?.onStopButtonPressed?()
                    },
                    onUpdateOverlayPressed: { [weak self] in
                        self?.onUpdateOverlayPressed?()
                    },
                    onSuggestionAction: { [weak self] id, action in
                        self?.resolveSuggestion(id: id, action: action)
                    }
                )
                .padding(.top, screenHasNotch ? notchOverlap : 0)
            )
        )
    }

    private func resize(panel: NSPanel, to frame: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// True iff the overlay renders as wings flanking the notch (notched display
    /// + use_compact_overlay on). updateAvailable and error toasts still use
    /// the drop-down pill.
    private var useWingedLayout: Bool {
        guard screenHasNotch else { return false }
        let useCompact = (UserDefaults.standard.object(forKey: "use_compact_overlay") as? Bool) ?? true
        guard useCompact else { return false }
        switch overlayState.phase {
        case .recording, .initializing, .transcribing:
            return true
        case .feedback:
            return overlayState.errorMessage?.isEmpty ?? true
        case .updateAvailable, .dictionarySuggestion:
            return false
        }
    }

    /// Wing width — tight to the compact waveform / stop button so the
    /// panel stays clear of right-side menu-bar items.
    static let wingWidth: CGFloat = 36
    static let leftWingWidth: CGFloat = wingWidth
    static let rightWingWidth: CGFloat = wingWidth

    private var overlayFrame: NSRect {
        guard let screen = targetScreen else { return .zero }

        if useWingedLayout {
            // Anchor to the screen's auxiliary-area boundaries of the notch;
            // panel height matches the menu-bar overlap so nothing protrudes below.
            let nWidth = notchWidth
            let nLeftX = screen.auxiliaryTopLeftArea?.maxX
                ?? (screen.frame.midX - nWidth / 2)
            let leftWing = Self.leftWingWidth
            let rightWing = Self.rightWingWidth
            let panelHeight = notchOverlap
            let panelWidth = leftWing + nWidth + rightWing
            let panelX = nLeftX - leftWing
            let panelY = screen.frame.maxY - panelHeight
            return NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        }

        let width = overlayWidth
        let useCompact = (UserDefaults.standard.object(forKey: "use_compact_overlay") as? Bool) ?? true
        let forceDropDownPill = overlayState.phase == .feedback
            && !(overlayState.errorMessage?.isEmpty ?? true)
        if overlayState.phase.isDictionarySuggestion {
            // A taller drop-down with a prompt row and a button row.
            let height = DictionarySuggestionOverlayView.height + (screenHasNotch ? notchOverlap : 0)
            return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        }
        // Compact mode: overlay sits flush with the menu bar on every display.
        // notchOverlap equals the menu-bar height on non-notched screens too,
        // so zero protrusion is universal — not notch-only. The legacy
        // 38pt drop-down pill remains available when use_compact_overlay
        // is explicitly toggled off. Error toasts also force the drop-down
        // height so messages stay readable even when compact overlay is enabled.
        let height: CGFloat = (useCompact && !forceDropDownPill)
            ? notchOverlap
            : 38 + (screenHasNotch ? notchOverlap : 0)
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private var overlayWidth: CGFloat {
        if let lockedOverlayWidth, overlayState.phase == .transcribing {
            return lockedOverlayWidth
        }

        if overlayState.phase == .feedback {
            // Error toasts size to the message length so short messages do
            // not get the same wide pill as long ones. ~6.8pt per character
            // plus 60pt of icon and padding chrome, clamped to 180-420pt so
            // very short messages stay readable and very long ones do not
            // stretch the pill across the menu bar. Bare failure-X marker
            // (no message) keeps the original 92pt.
            let feedbackWidth: CGFloat = {
                guard let msg = overlayState.errorMessage, !msg.isEmpty else {
                    return 92
                }
                let estimated = CGFloat(msg.count) * 6.8 + 60
                return min(420, max(180, estimated))
            }()
            guard screenHasNotch else { return feedbackWidth }
            return max(notchWidth, feedbackWidth)
        }

        if overlayState.phase.isDictionarySuggestion {
            let suggestionWidth = DictionarySuggestionOverlayView.width(for: overlayState.suggestionGate.suggestion?.word ?? "",
                                                                         appName: overlayState.visibleSuggestionApp?.name)
            guard screenHasNotch else { return suggestionWidth }
            return max(notchWidth, suggestionWidth)
        }

        if overlayState.phase == .updateAvailable {
            let updateWidth: CGFloat = 190
            guard screenHasNotch else { return updateWidth }
            return max(notchWidth, updateWidth)
        }

        let toggleWidth: CGFloat = 150
        let defaultWidth: CGFloat = 92
        let baseWidth: CGFloat

        if overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle {
            baseWidth = toggleWidth
        } else {
            baseWidth = defaultWidth
        }

        guard screenHasNotch else { return baseWidth }
        return max(notchWidth, baseWidth)
    }

    private func showFeedbackPanel() {
        lockedOverlayWidth = nil
        overlayState.phase = .feedback
        showOverlayPanel(animatedResize: true)
    }

    private func dismissAll() {
        // Whatever closes the panel, no suggested word stays in memory.
        overlayState.suggestionGate.preempt()
        overlayState.suggestionApp = nil
        lockedOverlayWidth = nil
        overlayState.updateVersion = ""
        if let panel = overlayWindow {
            panel.orderOut(nil)
            // orderOut alone leaves the panel retained in NSApp.windows with its
            // SwiftUI hierarchy mounted — repeatForever animations keep flushing
            // Core Animation forever. Unmount and close so the panel deallocates.
            panel.contentView = nil
            panel.close()
            overlayWindow = nil
        }
    }
}

// MARK: - Winged Recording View

/// Wing layout: waveform left, stop button right, solid-black notch in the middle
/// (the camera cutout masks those pixels).
struct WingedRecordingView: View {
    @ObservedObject var state: RecordingOverlayState
    let leftWingWidth: CGFloat
    let notchWidth: CGFloat
    let rightWingWidth: CGFloat
    let height: CGFloat
    let onStopButtonPressed: () -> Void

    private var showsLiveRecordingContent: Bool {
        state.phase == .recording
    }

    private var showsStopButton: Bool {
        showsLiveRecordingContent && state.recordingTriggerMode == .toggle
    }

    var body: some View {
        wingsHStack
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
    }

    private var wingsHStack: some View {
        HStack(spacing: 0) {
            // Left wing — empty during feedback so the right-wing X reads as the sole signal.
            HStack {
                Spacer(minLength: 0)
                Group {
                    if state.phase == .feedback {
                        Color.clear
                    } else if state.phase == .initializing {
                        InitializingDotsView()
                            .transition(.opacity)
                    } else if showsLiveRecordingContent {
                        VStack(spacing: 1) {
                            WaveformView(
                                metrics: .compact,
                                audioLevel: state.audioLevel,
                                showsActivityPulse: state.phase == .recording
                            )
                        }
                        .transition(.opacity)
                    } else {
                        ProcessingIndicatorView(metrics: .compact)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: leftWingWidth, height: height)

            // Notch spacer — solid black; camera cutout hides it.
            Color.black
                .frame(width: notchWidth, height: height)

            // Right wing — stop button (recording) OR failure X (feedback),
            // horizontally centered.
            HStack {
                Spacer(minLength: 0)
                Group {
                    if state.phase == .feedback {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.red.opacity(0.92)))
                            .transition(.opacity)
                    } else if showsStopButton {
                        Button(action: onStopButtonPressed) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.red.opacity(0.92)))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: rightWingWidth, height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
    }
}

// MARK: - Waveform Views

struct WaveformBar: View {
    let amplitude: CGFloat
    let metrics: WaveformMetrics

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(
                width: metrics.barWidth,
                height: metrics.barMinHeight + (metrics.barMaxHeight - metrics.barMinHeight) * amplitude
            )
    }
}

struct WaveformView: View {
    let metrics: WaveformMetrics
    let audioLevel: Float
    var showsActivityPulse = false

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    waveformBars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                waveformBars(pulseTime: nil)
            }
        }
        .frame(height: metrics.frameHeight)
    }

    private func waveformBars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: metrics.barSpacing) {
            ForEach(0..<metrics.barCount, id: \.self) { index in
                WaveformBar(
                    amplitude: metrics.barAmplitude(for: index, audioLevel: audioLevel, pulseTime: pulseTime),
                    metrics: metrics
                )
                    .animation(barAnimation(for: index), value: audioLevel)
            }
        }
    }

    private func barAnimation(for index: Int) -> Animation {
        let spring = metrics.barSpring(for: index)
        let animation = Animation.spring(response: spring.response, dampingFraction: 0.88)
        guard let delay = spring.delay else { return animation }
        return animation.delay(delay)
    }
}

struct ProcessingWaveformView: View {
    let metrics: WaveformMetrics

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: metrics.processingPillSpacing) {
                ForEach(0..<WaveformMetrics.processingBarCount, id: \.self) { index in
                    ProcessingPill(
                        amplitude: WaveformMetrics.processingAmplitude(for: index, time: time),
                        opacity: WaveformMetrics.processingOpacity(for: index, time: time),
                        metrics: metrics
                    )
                }
            }
            .frame(height: metrics.processingFrameHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProcessingPill: View {
    let amplitude: CGFloat
    let opacity: CGFloat
    let metrics: WaveformMetrics

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(
                width: metrics.processingPillWidth,
                height: metrics.processingPillMinHeight
                    + (metrics.processingPillMaxHeight - metrics.processingPillMinHeight) * amplitude
            )
            .opacity(opacity)
    }
}

/// Pulsing pills that switch to a spinner after one second of processing.
struct ProcessingIndicatorView: View {
    let metrics: WaveformMetrics

    @State private var showsExtendedSpinner = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            if showsExtendedSpinner {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: metrics.spinnerLineWidth, lineCap: .round))
                    .frame(width: metrics.spinnerSize, height: metrics.spinnerSize)
                    .rotationEffect(.degrees(rotation))
                    .frame(height: metrics.processingFrameHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .onAppear {
                        rotation = 0
                        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            } else {
                ProcessingWaveformView(metrics: metrics)
                    .transition(.opacity)
            }
        }
        .task {
            showsExtendedSpinner = false
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsExtendedSpinner = true
                }
            } catch {}
        }
    }
}

struct InitializingDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(activeDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async {
                    activeDot = (activeDot + 1) % 3
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let onStopButtonPressed: () -> Void
    let onUpdateOverlayPressed: () -> Void
    let onSuggestionAction: (UUID, DictionarySuggestionAction) -> Void

    private let leadingAccessoryWidth: CGFloat = 24
    private let trailingAccessoryWidth: CGFloat = 32

    private var showsLiveRecordingContent: Bool {
        state.phase == .recording
    }

    private var showsStopButton: Bool {
        showsLiveRecordingContent && state.recordingTriggerMode == .toggle
    }

    var body: some View {
        Group {
            if state.phase == .feedback, let message = state.errorMessage {
                ErrorOverlayView(message: message)
            } else if state.phase == .feedback {
                FailureIndicatorView()
            } else if state.phase == .updateAvailable {
                UpdateAvailableOverlayView(onPress: onUpdateOverlayPressed)
            } else if case .dictionarySuggestion(let id) = state.phase, let suggestion = state.suggestionGate.suggestion {
                DictionarySuggestionOverlayView(word: suggestion.word, appName: state.visibleSuggestionApp?.name) {
                    onSuggestionAction(id, $0)
                }
            } else {
                ZStack {
                    Group {
                        if state.phase == .initializing {
                            InitializingDotsView()
                                .transition(.opacity)
                        } else if showsLiveRecordingContent {
                            WaveformView(
                                metrics: .regular,
                                audioLevel: state.audioLevel,
                                showsActivityPulse: state.phase == .recording
                            )
                                .transition(.opacity)
                        } else {
                            ProcessingIndicatorView(metrics: .regular)
                                .transition(.opacity)
                        }
                    }

                    HStack {
                        Group {
                        }
                        .frame(width: leadingAccessoryWidth, alignment: .center)
                        .frame(maxHeight: .infinity, alignment: .center)

                        Spacer(minLength: 0)

                        Group {
                            if showsStopButton {
                                Button(action: onStopButtonPressed) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 14, height: 14)
                                        .background(Circle().fill(Color.red.opacity(0.92)))
                                }
                                .buttonStyle(.plain)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .frame(width: trailingAccessoryWidth, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.recordingTriggerMode)
    }
}

// MARK: - Transcribing Indicator

struct FailureIndicatorView: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.red.opacity(0.92)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// In-pill error toast. Red exclamation icon plus the message text,
/// rendered inside the standard menu-bar pill. Sized by the manager's
/// `overlayWidth` based on message length.
struct ErrorOverlayView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.red.opacity(0.92))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct UpdateAvailableOverlayView: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// "Add “word” to your dictionary?" with Add, Not now and Don't suggest.
/// Fits a phrase of up to 40 characters; longer ones truncate in the middle.
struct DictionarySuggestionOverlayView: View {
    static let height: CGFloat = 62

    /// Longest app name shown in full on the Add to <App> button.
    static let maxAppNameCharacters = 18

    static func width(for word: String, appName: String?) -> CGFloat {
        let characters = min(word.count, 40)
        let title = CGFloat(characters) * 7 + 190
        // Add to <App>, Add everywhere, Not now and Don't suggest.
        let buttons = appName.map { CGFloat(min($0.count, maxAppNameCharacters)) * 7 + 380 } ?? 0
        return min(560, max(300, title, buttons))
    }

    let word: String
    /// The dictation's app; without one, Add puts the word everywhere (DESIGN §3.6).
    let appName: String?
    let onAction: (DictionarySuggestionAction) -> Void

    private var shortAppName: String? {
        guard let appName, appName.count > Self.maxAppNameCharacters else { return appName }
        return String(appName.prefix(Self.maxAppNameCharacters - 1)) + "…"
    }

    var body: some View {
        VStack(spacing: 7) {
            Text("Add “\(word)” to your dictionary?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                if let shortAppName {
                    button("Add to \(shortAppName)", prominent: true) { onAction(.add) }
                    button("Add everywhere", prominent: false) { onAction(.addEverywhere) }
                } else {
                    button("Add", prominent: true) { onAction(.add) }
                }
                button("Not now", prominent: false) { onAction(.notNow) }
                button("Don't suggest", prominent: false) { onAction(.dontSuggest) }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}
