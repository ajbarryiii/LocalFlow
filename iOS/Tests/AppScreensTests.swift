import Foundation

/// The app's screens (ARCHITECTURE.md, "Host app"): the session card's state, the model's dot, the start-session
/// screen's word and return cue, onboarding's spoken progress, the spoken countdown, the background cover and the
/// sheets' hand-off.
enum AppScreensTests {
    static var tests: [TestCase] {
        [
            ("swipeCueFollowsTheBottomInset", testSwipeCueFollowsTheBottomInset),
            ("swipeCueDemonstratesOnceUnlessReduceMotion", testSwipeCueDemonstratesOnceUnlessReduceMotion),
            ("onboardingProgressIsSpoken", testOnboardingProgressIsSpoken),
            ("sessionCardWithoutASession", testSessionCardWithoutASession),
            ("sessionCardDuringASession", testSessionCardDuringASession),
            ("sessionCardWordsMatchTheLiveActivity", testSessionCardWordsMatchTheLiveActivity),
            ("modelBadge", testModelBadge),
            ("bouncePhaseWordsAndCue", testBouncePhaseWordsAndCue),
            ("headphonesRouteInTwoWords", testHeadphonesRouteInTwoWords),
            ("sessionCardReservesALineOnlyDuringASession", testSessionCardReservesALineOnlyDuringASession),
            ("backgroundCoverShowsOnlyInTheBackground", testBackgroundCoverShowsOnlyInTheBackground),
            ("backgroundCoverStaysUnderTheBounce", testBackgroundCoverStaysUnderTheBounce),
            ("sheetsCloseWhenTheBounceIsRequested", testSheetsCloseWhenTheBounceIsRequested),
            ("countdownIsOneSpokenSentence", testCountdownIsOneSpokenSentence),
        ]
    }

    private static func testSwipeCueFollowsTheBottomInset() {
        // A Home-button iPhone (SE) has no bottom inset and no bottom-edge swipe.
        TestSupport.expectEqual(SwipeBackCue(bottomSafeAreaInset: 0), .statusBarLink)
        TestSupport.expectEqual(SwipeBackCue(bottomSafeAreaInset: 34), .bottomEdgeSwipe)
        TestSupport.expectEqual(SwipeBackCue(bottomSafeAreaInset: 21), .bottomEdgeSwipe)
    }

    private static func testSwipeCueDemonstratesOnceUnlessReduceMotion() {
        TestSupport.expectEqual(SwipeBackCue.demonstrations(reduceMotion: false), 1)
        TestSupport.expectEqual(SwipeBackCue.demonstrations(reduceMotion: true), 0)
    }

    private static func testOnboardingProgressIsSpoken() {
        TestSupport.expectEqual(OnboardingProgress.spoken(index: 0, count: 4), "Step 1 of 4")
        TestSupport.expectEqual(OnboardingProgress.spoken(index: 1, count: 4), "Step 2 of 4")
        TestSupport.expectEqual(OnboardingProgress.spoken(index: 3, count: 4), "Step 4 of 4")
        TestSupport.expectEqual(OnboardingProgress.spoken(index: 9, count: 4), "Step 4 of 4")
    }

    private static func card(_ session: HostStatus.Session, permission: CapturePermission = .granted,
                             error: HostErrorCode? = nil, dictation: DictationStatus.Phase? = nil,
                             inProgress: Bool = false, model: HostStatus.Model = .ready) -> SessionCardState {
        SessionCardState(session: session, permission: permission, sessionError: error, dictation: dictation,
                         dictationInProgress: inProgress, model: model)
    }

    private static func testSessionCardWithoutASession() {
        TestSupport.expectEqual(card(.inactive), .off)
        TestSupport.expectEqual(card(.inactive, permission: .undetermined), .off)
        TestSupport.expectEqual(card(.inactive, permission: .denied), .microphoneOff)
        TestSupport.expectEqual(card(.inactive, permission: .undetermined, error: .microphonePermissionDenied), .microphoneOff)
        // Allowed again in Settings: Start works, whatever the last error said.
        TestSupport.expectEqual(card(.inactive, permission: .granted, error: .microphonePermissionDenied), .off)
        TestSupport.expectEqual(card(.inactive, error: .audioSessionFailed), .off)
        TestSupport.expectEqual(card(.starting), .starting)
        for state in [card(.inactive), card(.inactive, permission: .denied), card(.starting)] {
            TestSupport.expect(!state.isSessionOn, "\(state) offers Start, not End")
        }
        TestSupport.expectEqual(card(.inactive).title, nil)
        TestSupport.expectEqual(card(.inactive, permission: .denied).title, "Microphone off")
        TestSupport.expectEqual(card(.inactive, permission: .denied).accent, nil)
    }

    private static func testSessionCardDuringASession() {
        TestSupport.expectEqual(card(.active), .ready)
        TestSupport.expectEqual(card(.active, dictation: .starting, inProgress: true), .listening)
        TestSupport.expectEqual(card(.active, dictation: .recording, inProgress: true), .listening)
        TestSupport.expectEqual(card(.active, dictation: .transcribing, inProgress: true), .transcribing)
        TestSupport.expectEqual(card(.active, dictation: .transcribing, inProgress: true, model: .preparing), .preparing)
        // An outcome that is over, or a phase no longer in progress, is a ready session again.
        TestSupport.expectEqual(card(.active, dictation: .completed), .ready)
        TestSupport.expectEqual(card(.active, dictation: .recording, inProgress: false), .ready)
        TestSupport.expectEqual(card(.active, permission: .denied), .ready)
        for state in [card(.active), card(.active, dictation: .recording, inProgress: true)] {
            TestSupport.expect(state.isSessionOn, "\(state) offers End")
        }
        TestSupport.expectEqual(card(.active).accent, .aurora)
        TestSupport.expectEqual(card(.active, dictation: .recording, inProgress: true).accent, .coral)
        TestSupport.expectEqual(card(.active, dictation: .transcribing, inProgress: true).accent, .glacier)
    }

    private static func testSessionCardWordsMatchTheLiveActivity() {
        TestSupport.expectEqual(SessionCardState.ready.title, "Ready to dictate")
        TestSupport.expectEqual(SessionCardState.listening.title, "Listening")
        TestSupport.expectEqual(SessionCardState.transcribing.title, "Transcribing")
        TestSupport.expectEqual(SessionCardState.preparing.title, "Preparing model")
    }

    private static func testModelBadge() {
        TestSupport.expectEqual(ModelBadge.accent(.ready), .aurora)
        TestSupport.expectEqual(ModelBadge.accent(.preparing), .glacier)
        TestSupport.expectEqual(ModelBadge.accent(.failed), .ember)
        TestSupport.expectEqual(ModelBadge.accent(.unavailable), .ember)
        TestSupport.expectEqual(ModelBadge.accent(.notPrepared), nil)
        TestSupport.expectEqual(ModelBadge.spoken(.ready), "Ready")
        TestSupport.expectEqual(ModelBadge.spoken(.notPrepared), "Not prepared yet")
        // Ready is a shape, not only a colour; the other states are dots.
        TestSupport.expectEqual(ModelBadge.symbol(.ready), "checkmark")
        for model in [HostStatus.Model.notPrepared, .preparing, .failed, .unavailable] {
            TestSupport.expectEqual(ModelBadge.symbol(model), nil)
        }
    }

    private static func testBouncePhaseWordsAndCue() {
        TestSupport.expectEqual(BouncePhase(nil), .starting)
        TestSupport.expectEqual(BouncePhase(.recording).word, "Listening")
        TestSupport.expectEqual(BouncePhase(.recording).accent, .coral)
        TestSupport.expectEqual(BouncePhase(.failed).word, "Stopped")
        // Cancelling is the person's own choice: a neutral dot. A failure keeps the warning colour.
        TestSupport.expectEqual(BouncePhase(.cancelled).accent, nil)
        TestSupport.expectEqual(BouncePhase(.failed).accent, .ember)
        TestSupport.expectEqual(BouncePhase(.completed).accent, .aurora)
        TestSupport.expect(BouncePhase(.recording).showsReturnCue, "Listening shows the way back")
        TestSupport.expect(BouncePhase(.transcribing).showsReturnCue, "Transcribing shows the way back")
        TestSupport.expect(BouncePhase(.completed).showsReturnCue, "Done shows the way back")
        TestSupport.expect(!BouncePhase(.starting).showsReturnCue, "Starting waits for the microphone")
        TestSupport.expect(!BouncePhase(.failed).showsReturnCue, "A failure has nothing to go back to")
    }

    private static func testHeadphonesRouteInTwoWords() {
        TestSupport.expectEqual(HeadphonesNotice.iPhoneMicrophone.shortLabel, "iPhone mic")
        TestSupport.expectEqual(HeadphonesNotice.iPhoneMicrophone.symbol, "iphone")
        TestSupport.expectEqual(HeadphonesNotice.headphonesMicrophone.shortLabel, "Headphones mic")
        TestSupport.expectEqual(HeadphonesNotice.headphonesMicrophone.symbol, "headphones")
    }

    private static func testSessionCardReservesALineOnlyDuringASession() {
        TestSupport.expect(!SessionCardState.off.reservesDetailLine, "No session: the Start pill alone")
        TestSupport.expect(!SessionCardState.microphoneOff.reservesDetailLine, "Microphone off has no empty line")
        for state in [SessionCardState.starting, .ready, .listening, .transcribing, .preparing] {
            TestSupport.expect(state.reservesDetailLine, "\(state) keeps the card's height")
        }
    }

    private static func testBackgroundCoverShowsOnlyInTheBackground() {
        for covered in [false, true] {
            TestSupport.expect(BackgroundCover.covers(scene: .background, bounceShown: false, covered: covered),
                               "The background raises the cover")
            TestSupport.expect(BackgroundCover.covers(scene: .background, bounceShown: true, covered: covered),
                               "The background raises the cover over the bounce too")
        }
        // iOS's prompts and Control Center make the app inactive: what is on screen stays.
        TestSupport.expect(!BackgroundCover.covers(scene: .inactive, bounceShown: false, covered: false),
                           "Inactive never blanks the app")
        TestSupport.expect(BackgroundCover.covers(scene: .inactive, bounceShown: false, covered: true),
                           "On the way back, inactive keeps the cover until active")
        TestSupport.expect(!BackgroundCover.covers(scene: .active, bounceShown: false, covered: true),
                           "Active lowers the cover")
        TestSupport.expect(!BackgroundCover.covers(scene: .active, bounceShown: false, covered: false),
                           "Active never raises it")
    }

    private static func testBackgroundCoverStaysUnderTheBounce() {
        // Back from the keyboard's Start: the start-session screen is up, so Home stays covered beneath it ...
        TestSupport.expect(BackgroundCover.covers(scene: .active, bounceShown: true, covered: true),
                           "The cover stays under the start-session screen")
        // ... until that screen goes.
        TestSupport.expect(!BackgroundCover.covers(scene: .active, bounceShown: false, covered: true),
                           "Closing the start-session screen shows Home")
        TestSupport.expect(!BackgroundCover.covers(scene: .active, bounceShown: true, covered: false),
                           "A start-session screen opened in the app raises no cover")
    }

    private static func testSheetsCloseWhenTheBounceIsRequested() {
        // Add word, Edit word or Find strength left open: the keyboard's Start closes it, so the screen shows at once.
        TestSupport.expect(StartSessionSheets.close(bounceWasShown: false, bounceShown: true),
                           "Requesting the start-session screen closes the app's sheets")
        TestSupport.expect(!StartSessionSheets.close(bounceWasShown: true, bounceShown: false),
                           "The start-session screen going closes nothing")
        TestSupport.expect(!StartSessionSheets.close(bounceWasShown: false, bounceShown: false),
                           "No start-session screen: a sheet stays open")
        TestSupport.expect(!StartSessionSheets.close(bounceWasShown: true, bounceShown: true),
                           "The screen already shown closes nothing more")
    }

    private static func testCountdownIsOneSpokenSentence() {
        TestSupport.expectEqual(SessionCountdown.spoken(secondsLeft: 296), "Session ends in 4 minutes 56 seconds if idle")
        TestSupport.expectEqual(SessionCountdown.spoken(secondsLeft: 61), "Session ends in 1 minute 1 second if idle")
        TestSupport.expectEqual(SessionCountdown.spoken(secondsLeft: 300), "Session ends in 5 minutes if idle")
        TestSupport.expectEqual(SessionCountdown.spoken(secondsLeft: 42), "Session ends in 42 seconds if idle")
        TestSupport.expectEqual(SessionCountdown.spoken(secondsLeft: 0), "Session ends in 0 seconds if idle")
        TestSupport.expectEqual(SessionCountdown.spoken(secondsLeft: -3), "Session ends in 0 seconds if idle")
    }
}
