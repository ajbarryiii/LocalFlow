import Foundation

/// The keyboard's model readiness texts (ARCHITECTURE.md, "Keyboard presentation" and "Top row").
enum KeyboardMessagesTests {
    static var tests: [TestCase] {
        [
            ("hintTellsWhenTheModelIsNotReady", testHintTellsWhenTheModelIsNotReady),
            ("hintNeedsALiveHost", testHintNeedsALiveHost),
            ("capsuleNamesTheWaitForTheModel", testCapsuleNamesTheWaitForTheModel),
            ("preparingTitles", testPreparingTitles),
            ("statusTextNeverInvitesATap", testStatusTextNeverInvitesATap),
            ("barAndMenuNameTheIdleTimeoutAlike", testBarAndMenuNameTheIdleTimeoutAlike),
            ("recordingWhileTheModelLoadsFitsASmallPhone", testRecordingWhileTheModelLoadsFitsASmallPhone),
            ("theLargestTextSizesPutTheMenusActionsFirst", testTheLargestTextSizesPutTheMenusActionsFirst),
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

    /// The Start capsule is never replaced by the candidate strip, the chips or a notice, so it names the
    /// wait for the model itself; transcription keeps the bare spinner.
    private static func testCapsuleNamesTheWaitForTheModel() {
        TestSupport.expectEqual(KeyboardMessages.capsuleCaption(for: .waitingForModel), KeyboardMessages.preparingCaption)
        let others: [KeyboardMode] = [.needsFullAccess, .configurationError, .incompatible, .starting,
                                      .recording(level: 0.2, startedAt: Fixture.now), .transcribing, .error(.modelFailed),
                                      .preparingModel, .ready, .hostUnavailable]
        for mode in others {
            TestSupport.expectEqual(KeyboardMessages.capsuleCaption(for: mode), nil)
        }
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
}
