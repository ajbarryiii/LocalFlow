import Foundation

/// The keyboard's model readiness texts (ARCHITECTURE.md, "Keyboard presentation" and "Top row").
enum KeyboardMessagesTests {
    static var tests: [TestCase] {
        [
            ("hintTellsWhenTheModelIsNotReady", testHintTellsWhenTheModelIsNotReady),
            ("hintNeedsALiveHost", testHintNeedsALiveHost),
            ("capsuleShowsOnlyASpinnerWhileWaiting", testCapsuleShowsOnlyASpinnerWhileWaiting),
            ("sessionReadyNeedsALiveSessionAndAUsableModel", testSessionReadyNeedsALiveSessionAndAUsableModel),
            ("preparingTitles", testPreparingTitles),
            ("statusTextNeverInvitesATap", testStatusTextNeverInvitesATap),
            ("barAndMenuNameTheIdleTimeoutAlike", testBarAndMenuNameTheIdleTimeoutAlike),
            ("recordingWhileTheModelLoadsFitsASmallPhone", testRecordingWhileTheModelLoadsFitsASmallPhone),
            ("theLargestTextSizesPutTheMenusActionsFirst", testTheLargestTextSizesPutTheMenusActionsFirst),
            ("theWidthTipSaysWhatLandsOnTheWrongLine", testTheWidthTipSaysWhatLandsOnTheWrongLine),
        ]
    }

    private static func status(model: HostStatus.Model, _ session: HostStatus.Session = .active,
                               heartbeatAt: Date = Fixture.now) -> HostStatus {
        var status = Fixture.status(session, heartbeatAt: heartbeatAt)
        status.model = model
        return status
    }

    /// The idle line (`ready` shows the hint) says the model is not ready: a released model loads when
    /// the user dictates, nothing is preparing it now. A ready model shows only the session.
    private static func testHintTellsWhenTheModelIsNotReady() {
        let now = Fixture.now
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .notPrepared), now: now),
                                KeyboardMessages.modelLoadsWhenDictating)
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .preparing), now: now), KeyboardMessages.preparingModel)
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .failed), now: now), "Model failed to load")
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .unavailable), now: now), "Model missing")
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .ready), now: now), "Session ends after 5 min idle")
        TestSupport.expect(KeyboardMessages.modelLoadsWhenDictating != KeyboardMessages.preparingModel,
                           "a released model claims to be preparing")
    }

    /// A dead host's last status says nothing, and a model that is merely not prepared before any session
    /// starts is not news.
    private static func testHintNeedsALiveHost() {
        let late = Fixture.now + DictationProtocol.livenessTimeout + 0.001
        for model in [HostStatus.Model.notPrepared, .preparing, .failed, .unavailable, .ready] {
            TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: model), now: late), nil)
        }
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .notPrepared, .inactive), now: Fixture.now), nil)
        TestSupport.expectEqual(KeyboardMessages.hint(for: nil, now: Fixture.now), nil)
    }

    /// Round 4 council (Opus finding 5): "Preparing model…" in the middle sat beside a "Preparing" capsule. Both waits
    /// for a transcript show only the spinner in the capsule, as transcription did; the middle names the wait and
    /// VoiceOver hears it from the capsule's label.
    private static func testCapsuleShowsOnlyASpinnerWhileWaiting() {
        TestSupport.expectEqual(CapsuleContent(mode: .waitingForModel), .spinner)
        TestSupport.expectEqual(CapsuleContent(mode: .transcribing), .spinner)
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .waitingForModel), "Preparing model")
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .transcribing), "Transcribing")
        TestSupport.expectEqual(BarStatus(mode: .waitingForModel, title: KeyboardMessages.title(for: .waitingForModel, launcherFailed: false),
                                          hint: nil, notice: nil, chipsShown: false),
                                .text(KeyboardMessages.preparingModel, attention: false))
        let others: [KeyboardMode] = [.needsFullAccess, .configurationError, .incompatible, .error(.modelFailed), .preparingModel, .ready,
                                      .hostUnavailable]
        for mode in others {
            TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: mode), "Start dictation")
        }
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .starting), "Stop dictation")
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .recording(level: 0, startedAt: Fixture.now)), "Stop dictation")
    }

    /// Round 4 council (Opus, visual 4): the idle bar shows that dictation is ready. Only a live host's active session
    /// counts, and only while its model can load (not failed or missing); a model that loads when the user dictates is
    /// ready enough.
    private static func testSessionReadyNeedsALiveSessionAndAUsableModel() {
        let now = Fixture.now
        for model in [HostStatus.Model.notPrepared, .preparing, .ready] {
            TestSupport.expect(KeyboardMessages.isSessionReady(status(model: model), now: now), "\(model) is not ready")
        }
        for model in [HostStatus.Model.failed, .unavailable] {
            TestSupport.expect(!KeyboardMessages.isSessionReady(status(model: model), now: now), "\(model) is ready")
        }
        TestSupport.expect(!KeyboardMessages.isSessionReady(status(model: .ready, .inactive), now: now), "no session is ready")
        TestSupport.expect(!KeyboardMessages.isSessionReady(status(model: .ready, .starting), now: now), "a starting session is ready")
        let late = now + DictationProtocol.livenessTimeout + 0.001
        TestSupport.expect(!KeyboardMessages.isSessionReady(status(model: .ready), now: late), "a dead host is ready")
        TestSupport.expect(!KeyboardMessages.isSessionReady(nil, now: now), "no status is ready")
    }

    private static func testPreparingTitles() {
        for mode in [KeyboardMode.waitingForModel, .preparingModel] {
            TestSupport.expectEqual(KeyboardMessages.title(for: mode, launcherFailed: false), KeyboardMessages.preparingModel)
        }
        TestSupport.expectEqual(KeyboardMessages.title(for: .transcribing, launcherFailed: false), "Transcribing…")
    }

    /// Owner decision 2: a tap on the bar's text types the top-row key under it, so no status line or title says
    /// "Tap"; it describes. The idle line without a session names what Start does.
    private static func testStatusTextNeverInvitesATap() {
        TestSupport.expectEqual(KeyboardMessages.title(for: .hostUnavailable, launcherFailed: false), "Start opens LocalFlow")
        let modes: [KeyboardMode] = [.needsFullAccess, .configurationError, .incompatible, .starting,
                                     .recording(level: 0, startedAt: Fixture.now), .transcribing, .waitingForModel, .preparingModel,
                                     .ready, .hostUnavailable, .error(.modelFailed), .error(.sessionInactive)]
        for mode in modes {
            for failed in [false, true] {
                let title = KeyboardMessages.title(for: mode, launcherFailed: failed)
                TestSupport.expect(!title.lowercased().hasPrefix("tap"), "\(mode) invites a tap: \(title)")
            }
        }
        for model in [HostStatus.Model.notPrepared, .preparing, .failed, .unavailable, .ready] {
            let hint = KeyboardMessages.hint(for: status(model: model), now: Fixture.now) ?? ""
            TestSupport.expect(!hint.lowercased().hasPrefix("tap"), "hint invites a tap: \(hint)")
        }
    }

    /// The session ends after its idle time, not at a fixed moment: the bar and the menu say so in the same words.
    private static func testBarAndMenuNameTheIdleTimeoutAlike() {
        let now = Fixture.now
        let live = status(model: .ready)
        let phrase = KeyboardMessages.idleTimeout(minutes: 5)
        TestSupport.expectEqual(phrase, "ends after 5 min idle")
        TestSupport.expect(KeyboardMessages.hint(for: live, now: now)?.hasSuffix(phrase) == true, "bar wording differs")
        TestSupport.expect(KeyboardMessages.sessionSummary(for: live, now: now).hasSuffix(phrase), "menu wording differs")
        // Round 1 council: the menu's line was long at the largest text sizes; it is now the bar's own line.
        TestSupport.expectEqual(KeyboardMessages.sessionSummary(for: live, now: now), "Session ends after 5 min idle")
        TestSupport.expect(!(KeyboardMessages.hint(for: live, now: now) ?? "").contains("left"), "bar reads as a countdown")
    }

    /// Round 1 council: on a 375-point phone "Listening · preparing model" truncated beside Cancel and the labelled
    /// Stop capsule, after 22 characters ("Listening · preparing…"). The line still says the model is loading.
    private static func testRecordingWhileTheModelLoadsFitsASmallPhone() {
        let line = KeyboardMessages.listeningWhilePreparing
        TestSupport.expect(line.count <= 23, "\(line) is longer than a 375-point phone shows")
        TestSupport.expect(line.hasPrefix("Listening"), "\(line) does not say it is listening")
        TestSupport.expect(line.contains("model"), "\(line) does not say the model is loading")
    }

    /// Round 2 council (Sol finding 1): at the largest text size the menu's first screen was all session status. At the
    /// accessibility sizes the actions ("Open LocalFlow" and the text width) come first, then the status and the tip
    /// (which then points above); otherwise the status leads and the width choice follows its tip.
    private static func testTheLargestTextSizesPutTheMenusActionsFirst() {
        TestSupport.expectEqual(KeyboardMessages.menuItems(accessibilitySize: false), [.session, .details, .open, .divider, .tip, .picker])
        TestSupport.expectEqual(KeyboardMessages.menuItems(accessibilitySize: true), [.open, .picker, .divider, .session, .details, .tip])
        TestSupport.expect(KeyboardMessages.layoutTipAbove.hasSuffix("above."), "the tip does not point above")
    }

    /// Round 6 council (Opus finding 7): "Wrong line? Switch this field to:" did not say what lands on the wrong line. The
    /// tip names it (the cursor the trackpad moves), says when to switch, and still ends at the choice it points to.
    private static func testTheWidthTipSaysWhatLandsOnTheWrongLine() {
        for (tip, end) in [(KeyboardMessages.layoutTipBelow, ":"), (KeyboardMessages.layoutTipAbove, "above.")] {
            let line = KeyboardMessages.trackpadTip + tip
            TestSupport.expect(line.hasPrefix("Hold space to move the cursor. "), "\(line)")
            TestSupport.expect(line.contains("If it lands on the wrong line, switch this field"), "\(line)")
            TestSupport.expect(line.hasSuffix(end), "\(line)")
            TestSupport.expect(line.count <= 90, "\(line) is long")
        }
    }
}
