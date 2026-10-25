import Foundation

/// The keyboard's model readiness texts (ARCHITECTURE.md, "Keyboard presentation" and "Top row").
enum KeyboardMessagesTests {
    static var tests: [TestCase] {
        [
            ("hintTellsWhenTheModelIsNotReady", testHintTellsWhenTheModelIsNotReady),
            ("hintNeedsALiveHost", testHintNeedsALiveHost),
            ("capsuleNamesTheWaitForTheModel", testCapsuleNamesTheWaitForTheModel),
            ("preparingTitles", testPreparingTitles),
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
        TestSupport.expectEqual(KeyboardMessages.hint(for: status(model: .ready), now: now), "Session · 5 min left")
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
}
