import SwiftUI

/// Shown when the keyboard opened the app to start a dictation: the keyboard's island, large, with the phase in one word
/// and the way back to the app the person came from. "Starting" until input buffers flow (the dictation is
/// `recording`), then "Listening" with the voice's wave, the recording dot and the time (`BouncePhase`).
struct BounceView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let cue = SwipeBackCue(bottomSafeAreaInset: Double(proxy.safeAreaInsets.bottom))
            VStack(spacing: 0) {
                if cue == .statusBarLink {
                    StatusBarLinkCue(visible: phase.showsReturnCue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
                // Anchored at the top, so what arrives below (the preparing line, the route) never moves the island or
                // the word. Scrolls only when it does not fit (large text on a small iPhone).
                ScrollView {
                    VStack(spacing: 22) {
                        island(width: min(proxy.size.width - 56, 340))
                        word
                        details(width: min(proxy.size.width - 56, 340))
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, max(16, proxy.size.height * (cue == .statusBarLink ? 0.14 : 0.24)))
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                buttons
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, cue == .bottomEdgeSwipe ? 14 : 16)
                if cue == .bottomEdgeSwipe {
                    BottomSwipeCue(visible: phase.showsReturnCue)
                        .padding(.bottom, 2)
                }
            }
        }
        .background(Theme.screenBackground.ignoresSafeArea())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28), value: phase)
        .accessibilityIdentifier("bounce")
    }

    private var phase: BouncePhase { BouncePhase(host.dictation?.phase) }
    private var preparing: Bool { transcriber.modelState == .preparing && host.isDictationInProgress }

    // MARK: Island

    private func island(width: CGFloat) -> some View {
        ZStack {
            switch phase {
            case .starting, .listening:
                // One view from starting to listening: the dimmed row brightens and the time arrives, nothing blinks.
                HStack(spacing: 12) {
                    IslandWave(level: host.level, live: phase == .listening, accent: Theme.coral)
                        .frame(height: 26)
                    Group {
                        if phase == .listening, let startedAt = host.dictation?.startedAt {
                            Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                        } else {
                            Text(verbatim: "0:00").hidden()
                        }
                    }
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                }
                .padding(.horizontal, 22)
                .transition(.opacity)
            case .transcribing:
                IslandShimmer()
                    .frame(height: 26)
                    .padding(.horizontal, 22)
                    .transition(.opacity)
            case .done, .cancelled, .stopped:
                RidgeMarkView(dot: Theme.color(phase.accent), side: 34)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        // A fixed size, as the keyboard's island: the time stays at one size at large text.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(width: width, height: 64)
        .islandSurface()
        .accessibilityHidden(true)
    }

    private var word: some View {
        Text(phase.word)
            .font(.display(.largeTitle))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .id(phase)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("bounce.phase")
    }

    /// At most a short line under the word: why it stopped, the microphone prompt, the model preparing, the route.
    @ViewBuilder
    private func details(width: CGFloat) -> some View {
        VStack(spacing: 14) {
            if phase == .starting, host.session == .starting, host.microphonePermission == .undetermined {
                note("Allow the microphone to start.")
            }
            if phase == .cancelled || phase == .stopped, let error = host.dictation?.error {
                note(error.message)
            }
            if preparing, let started = transcriber.preparationStartedAt {
                PreparingLine(startedAt: started, estimate: transcriber.estimatedPreparationSeconds)
                    .frame(width: width)
                    .transition(.opacity)
            }
            if let notice = host.headphonesNotice, phase == .starting || phase == .listening {
                Label(notice.shortLabel, systemImage: notice.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .transition(.opacity)
                    .accessibilityLabel(notice.message)
                    .accessibilityIdentifier("bounce.headphones")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Theme.secondaryInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .starting, .listening, .transcribing:
            // Cancel keeps its place from start to finish; Stop shows only while there is something to stop.
            HStack(spacing: 14) {
                Button {
                    host.cancelDictation()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(RoundIslandButtonStyle())
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("bounce.cancel")
                Button {
                    host.stopDictation()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(phase != .listening)
                .opacity(phase == .transcribing ? 0 : 1)
                .accessibilityHidden(phase == .transcribing)
                .accessibilityIdentifier("bounce.stop")
            }
        case .done, .cancelled, .stopped:
            Button("Close") { host.bounceVisible = false }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("bounce.close")
        }
    }
}

/// The model preparing while a dictation waits: the CPU glyph, a glacier progress line and the time so far.
private struct PreparingLine: View {
    var startedAt: Date
    var estimate: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            HStack(spacing: 10) {
                Image(systemName: "cpu").foregroundStyle(Theme.secondaryInk)
                GlacierBar(fraction: estimate.map { min(elapsed / $0, 0.95) })
                Text(Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond)))
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preparing the speech model")
            .accessibilityValue(Duration.seconds(Int(elapsed)).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
        }
        .accessibilityIdentifier("bounce.preparing")
    }
}

/// Where to swipe on an iPhone without a Home button: right along the bottom edge, just above it. A dot shows the
/// swipe once, then rests at the right (`SwipeBackCue.demonstrations`); with Reduce Motion it is still.
private struct BottomSwipeCue: View {
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelled = false

    var body: some View {
        VStack(spacing: 6) {
            Text("Swipe back")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 84, height: 4)
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                        .offset(x: travelled ? 77 : -2)
                }
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .frame(height: 12)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SwipeBackCue.bottomEdgeSwipe.spoken)
        .accessibilityHidden(!visible)
        .accessibilityIdentifier("bounce.swipeCue")
        .onAppear { if visible { demonstrate() } }
        .onChange(of: visible) { _, now in if now { demonstrate() } }
    }

    private func demonstrate() {
        guard SwipeBackCue.demonstrations(reduceMotion: reduceMotion) > 0, !travelled else {
            travelled = true
            return
        }
        withAnimation(.snappy(duration: 0.55).delay(0.3)) { travelled = true }
    }
}

/// Where to tap on an iPhone with a Home button: the status bar's "◀ App" link above. Its arrow nudges up once, then
/// rests; with Reduce Motion it is still.
private struct StatusBarLinkCue: View {
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the nudges to show: each change plays one.
    @State private var nudges = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.footnote.weight(.bold))
                .keyframeAnimator(initialValue: 0.0, trigger: nudges) { content, lift in
                    content.offset(y: lift)
                } keyframes: { _ in
                    LinearKeyframe(0, duration: 0.3)
                    SpringKeyframe(-5, duration: 0.2, spring: .snappy)
                    SpringKeyframe(0, duration: 0.3, spring: .snappy)
                }
            Text("\(Image(systemName: "chevron.left")) Back to your app")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SwipeBackCue.statusBarLink.spoken)
        .accessibilityHidden(!visible)
        .accessibilityIdentifier("bounce.swipeCue")
        .onAppear { if visible { nudge() } }
        .onChange(of: visible) { _, now in if now { nudge() } }
    }

    private func nudge() {
        guard SwipeBackCue.demonstrations(reduceMotion: reduceMotion) > 0, nudges == 0 else { return }
        nudges += 1
    }
}
