import Foundation

/// The keyboard's model readiness texts (ARCHITECTURE.md, "Keyboard presentation" and "Top row").
enum KeyboardMessagesTests {
    static var tests: [TestCase] {
        [
            ("hintOnlyNamesAModelThatCannotLoad", testHintOnlyNamesAModelThatCannotLoad),
            ("hintNeedsALiveHost", testHintNeedsALiveHost),
            ("capsuleShowsOnlyAnIndicatorWhileWaiting", testCapsuleShowsOnlyAnIndicatorWhileWaiting),
            ("voiceOverReadsWhatTheIslandShows", testVoiceOverReadsWhatTheIslandShows),
            ("voiceOverSpeaksEveryStateInWords", testVoiceOverSpeaksEveryStateInWords),
            ("sessionReadyNeedsALiveSessionAndAUsableModel", testSessionReadyNeedsALiveSessionAndAUsableModel),
            ("preparingTitles", testPreparingTitles),
            ("statusTextNeverInvitesATap", testStatusTextNeverInvitesATap),
            ("menuKeepsTheTimeLeft", testMenuKeepsTheTimeLeft),
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

    /// The idle line's words are only for a model that cannot load, which the user needs to know; the session's state
    /// is the dot on Start (`SessionDot`), a model that loads when the user dictates or is preparing says so to
    /// VoiceOver only (`spokenStatus`).
    private static func testHintOnlyNamesAModelThatCannotLoad() {
        let now = Fixture.now
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .failed), now: now), "Model failed to load")
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .unavailable), now: now), "Model missing")
        for model in [HostStatus.Model.notPrepared, .preparing, .ready] {
            TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: model), now: now), nil)
        }
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

    /// Both waits for a transcript show only an indicator in the capsule (the processing island's shimmer), never
    /// "Preparing model…" beside a "Preparing" capsule; VoiceOver hears the wait from the capsule's label. VoiceOver
    /// hears the mode and the time while recording from Stop's value. The island holds none of dictation's text (a
    /// notice, "Open LocalFlow to start a session"); the middle does, as plain text VoiceOver reaches on its own, so
    /// the island's value does not repeat it. It is empty for the wait, and on Start without a `detail`.
    private static func testVoiceOverReadsWhatTheIslandShows() {
        let startedAt = Fixture.now, now = Fixture.now + 75
        let recording = KeyboardMode.recording(level: 0.4, startedAt: startedAt)
        let time = Duration.seconds(75).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: recording, detail: nil, now: now), "Recording, \(time)")
        TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: .starting, detail: nil, now: now), "Starting")
        // A recording that started in the future (a clock step) never reads a negative time.
        TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: .recording(level: 0, startedAt: now + 5), detail: nil, now: now),
                                "Recording, " + Duration.seconds(0).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
        for mode in [KeyboardMode.ready, .transcribing, .waitingForModel, .error(.modelFailed), .hostUnavailable, .needsFullAccess] {
            TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: mode, detail: nil, now: now), "")
        }
        // The words the bar does not show are the island's value: the cold start's caption after the time, the idle
        // status on Start. The wait names itself in the label.
        TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: recording, detail: KeyboardMessages.modelLoadingCaption, now: now),
                                "Recording, \(time). Model loading")
        TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: .ready, detail: "Session ends in 5 min if idle", now: now),
                                "Session ends in 5 min if idle")
        TestSupport.expectEqual(KeyboardMessages.islandAccessibilityValue(for: .transcribing, detail: "Session ends in 5 min if idle", now: now), "")
        // Text the middle still shows is the middle's, which VoiceOver reads on its own.
        func status(_ mode: KeyboardMode, _ title: String, notice: String? = nil) -> BarStatus {
            BarStatus(mode: mode, title: title, hint: nil, notice: notice, chipsShown: false)
        }
        TestSupport.expectEqual(status(recording, "Listening", notice: KeyboardMessages.storeWriteFailed),
                                .notice(KeyboardMessages.storeWriteFailed))
        TestSupport.expectEqual(status(.starting, KeyboardMessages.openLocalFlow), .text(KeyboardMessages.openLocalFlow, attention: false))
    }

    /// The bar shows marks rather than status words, but VoiceOver still speaks every state in words. What the bar does
    /// not show is Start's (or the recording's) value: the session's time left, a model that loads or is loading, Start
    /// opening LocalFlow; the wait is the island's label; an error, a notice and "Open LocalFlow to start a session"
    /// are the middle's words. Every state has words somewhere.
    private static func testVoiceOverSpeaksEveryStateInWords() {
        let now = Fixture.now
        func spoken(_ mode: KeyboardMode, _ model: HostStatus.Model = .ready, failed: Bool = false, host: Bool = true) -> String? {
            KeyboardMessages.spokenStatus(mode: mode, status: host ? status(model: model) : nil, launcherFailed: failed, now: now)
        }
        let session = "Session ends in 5 min if idle"
        TestSupport.expectEqual(spoken(.ready), session)
        TestSupport.expectEqual(spoken(.ready, .notPrepared), session + ". " + KeyboardMessages.modelLoadsWhenDictating)
        TestSupport.expectEqual(spoken(.preparingModel, .preparing), "Preparing model. " + session)
        TestSupport.expectEqual(spoken(.hostUnavailable, host: false), "No session. Start opens LocalFlow")
        TestSupport.expectEqual(spoken(.hostUnavailable, failed: true, host: false), nil)
        TestSupport.expectEqual(spoken(.recording(level: 0.3, startedAt: now), .preparing), KeyboardMessages.modelLoadingCaption)
        TestSupport.expectEqual(spoken(.recording(level: 0.3, startedAt: now)), nil)
        // A dead host's last status says nothing about a session.
        TestSupport.expectEqual(KeyboardMessages.spokenStatus(mode: .ready, status: status(model: .ready, heartbeatAt: now - 60),
                                                              launcherFailed: false, now: now), nil)
        // Every state: the middle's words, the island's label for the wait, or the spoken status.
        let modes: [(KeyboardMode, HostStatus.Model, Bool)] = [
            (.needsFullAccess, .ready, false), (.configurationError, .ready, false), (.incompatible, .ready, false),
            (.starting, .ready, false), (.recording(level: 0.2, startedAt: now), .preparing, false), (.transcribing, .ready, false),
            (.waitingForModel, .preparing, false), (.error(.modelFailed), .ready, false), (.preparingModel, .preparing, false),
            (.ready, .ready, false), (.ready, .notPrepared, false), (.ready, .failed, false), (.hostUnavailable, .ready, false),
            (.hostUnavailable, .ready, true),
        ]
        for (mode, model, failed) in modes {
            let title = KeyboardMessages.title(for: mode, launcherFailed: failed)
            let middle = BarStatus(mode: mode, title: title, hint: KeyboardMessages.hint(for: status(model: model), now: now),
                                   notice: nil, chipsShown: false)
            let shownWords: Bool
            if case .text = middle { shownWords = true } else { shownWords = false }
            let words = KeyboardMessages.islandAccessibilityValue(for: mode, detail: spoken(mode, model, failed: failed), now: now)
            let label = KeyboardMessages.capsuleAccessibilityLabel(for: mode)
            TestSupport.expect(shownWords || !words.isEmpty || label == "Transcribing" || label == "Preparing model",
                               "\(mode) has no words for VoiceOver")
        }
    }

    private static func testCapsuleShowsOnlyAnIndicatorWhileWaiting() {
        TestSupport.expectEqual(CapsuleContent(mode: .waitingForModel), .processing)
        TestSupport.expectEqual(CapsuleContent(mode: .transcribing), .processing)
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .waitingForModel), "Preparing model")
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .transcribing), "Transcribing")
        // The wait shows only the shimmer pill; its words are the label's.
        TestSupport.expectEqual(BarStatus(mode: .waitingForModel, title: KeyboardMessages.title(for: .waitingForModel, launcherFailed: false),
                                          hint: nil, notice: nil, chipsShown: false), .none)
        TestSupport.expectEqual(BarStatus(mode: .transcribing, title: KeyboardMessages.title(for: .transcribing, launcherFailed: false),
                                          hint: nil, notice: nil, chipsShown: false), .none)
        let others: [KeyboardMode] = [.needsFullAccess, .configurationError, .incompatible, .error(.modelFailed), .preparingModel, .ready,
                                      .hostUnavailable]
        for mode in others {
            TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: mode), "Start dictation")
        }
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .starting), "Stop dictation")
        TestSupport.expectEqual(KeyboardMessages.capsuleAccessibilityLabel(for: .recording(level: 0, startedAt: Fixture.now)), "Stop dictation")
    }

    /// The idle bar shows that dictation is ready. Only a live host's active session counts, and only while its model
    /// can load (not failed or missing); a model that loads when the user dictates is ready enough.
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

    /// A tap on the bar's text types the top-row key under it, so no status line or title says "Tap"; it describes.
    /// The idle line without a session names what Start does.
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

    /// The session ends after its idle time, not at a fixed moment, in the words of the Live Activity's countdown, "ends
    /// in", to the nearest minute (`SessionActivityTests.countdownSpeaksTheBarsWords`). The bar shows the session as
    /// the dot on Start; the menu keeps the time left, and VoiceOver hears the same words from Start.
    private static func testMenuKeepsTheTimeLeft() {
        let now = Fixture.now
        let live = status(model: .ready)
        let phrase = KeyboardMessages.idleTimeout(minutes: 5)
        TestSupport.expectEqual(phrase, "ends in 5 min if idle")
        TestSupport.expectEqual(KeyboardMessages.sessionSummary(for: live, now: now), "Session ends in 5 min if idle")
        TestSupport.expectEqual(KeyboardMessages.spokenStatus(mode: .ready, status: live, launcherFailed: false, now: now),
                                KeyboardMessages.sessionSummary(for: live, now: now))
        TestSupport.expectEqual(BarStatus(mode: .ready, title: "Ready to dictate", hint: KeyboardMessages.hint(for: live, now: now),
                                          notice: nil, chipsShown: false), .none)
    }

    /// The line fits a 375-point phone, where "Listening · preparing model" truncates after 22 characters beside Cancel
    /// and the labelled Stop capsule ("Listening · preparing…"), and still says the model is loading.
    private static func testRecordingWhileTheModelLoadsFitsASmallPhone() {
        let line = KeyboardMessages.listeningWhilePreparing
        TestSupport.expect(line.count <= 23, "\(line) is longer than a 375-point phone shows")
        TestSupport.expect(line.hasPrefix("Listening"), "\(line) does not say it is listening")
        TestSupport.expect(line.contains("model"), "\(line) does not say the model is loading")
    }

    /// At the largest text size the session status alone can fill the menu's first screen, so at the accessibility
    /// sizes the actions ("Open LocalFlow" and the text width) come first, then the status and the tip (which then
    /// points above); otherwise the status leads and the width choice follows its tip.
    private static func testTheLargestTextSizesPutTheMenusActionsFirst() {
        TestSupport.expectEqual(KeyboardMessages.menuItems(accessibilitySize: false), [.session, .details, .open, .divider, .tip, .picker])
        TestSupport.expectEqual(KeyboardMessages.menuItems(accessibilitySize: true), [.open, .picker, .divider, .session, .details, .tip])
        TestSupport.expect(KeyboardMessages.layoutTipAbove.hasSuffix("above."), "the tip does not point above")
    }

    /// "Wrong line? Switch this field to:" does not say what lands on the wrong line. The tip names it (the cursor the
    /// trackpad moves), says when to switch, and still ends at the choice it points to.
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
