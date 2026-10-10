import Foundation

/// "Use iPhone microphone": category options, the preferred input and when to re-assert it.
enum MicrophoneRouteTests {
    static var tests: [TestCase] {
        [
            ("onByDefault", testOnByDefault),
            ("builtInChoiceNeverEnablesHandsFree", testBuiltInChoiceNeverEnablesHandsFree),
            ("systemChoiceKeepsHandsFree", testSystemChoiceKeepsHandsFree),
            ("builtInMicrophoneIsPreferredOverHeadsets", testBuiltInMicrophoneIsPreferredOverHeadsets),
            ("systemChoiceClearsThePreference", testSystemChoiceClearsThePreference),
            ("reassertOnlyWhenMovedOffTheBuiltInMicrophone", isolated(testReassertOnlyWhenMovedOffTheBuiltInMicrophone)),
            ("labelsAreContentFree", testLabelsAreContentFree),
            ("deferredChoiceKeepsRoutingOnTheAppliedOne", isolated(testDeferredChoiceKeepsRoutingOnTheAppliedOne)),
            ("deferredBuiltInChoiceDoesNotOverrideTheSystem", isolated(testDeferredBuiltInChoiceDoesNotOverrideTheSystem)),
            ("noRoutingWithoutAConfiguredSession", isolated(testNoRoutingWithoutAConfiguredSession)),
            ("delayedRequestResolvesAtTheRouteChange", isolated(testDelayedRequestResolvesAtTheRouteChange)),
            ("unsatisfiedRequestIsUnresolvedAndRetriedLater", isolated(testUnsatisfiedRequestIsUnresolvedAndRetriedLater)),
            ("failedRequestIsUnresolvedAtOnce", isolated(testFailedRequestIsUnresolvedAtOnce)),
            ("silentRequestIsJudgedAfterTheSettleTime", isolated(testSilentRequestIsJudgedAfterTheSettleTime)),
            ("problemsAreContentFree", testProblemsAreContentFree),
        ]
    }

    private static func testOnByDefault() {
        TestSupport.expect(MicrophoneRoute.defaultUseBuiltInMicrophone, "the built-in microphone is not the default")
    }

    private static func testBuiltInChoiceNeverEnablesHandsFree() {
        TestSupport.expectEqual(MicrophoneRoute.categoryOptions(useBuiltInMicrophone: true),
                                [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
    }

    private static func testSystemChoiceKeepsHandsFree() {
        TestSupport.expectEqual(MicrophoneRoute.categoryOptions(useBuiltInMicrophone: false),
                                [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
    }

    private static func testBuiltInMicrophoneIsPreferredOverHeadsets() {
        for others in [[], [InputPortKind.headset], [.usb], [.bluetooth], [.headset, .usb, .other]] {
            TestSupport.expectEqual(MicrophoneRoute.preferredInput(useBuiltInMicrophone: true,
                                                                   availableInputs: others + [.builtInMic]), .builtInMic)
        }
        // No built-in microphone to choose (for example an iPad without one): the system chooses.
        TestSupport.expectEqual(MicrophoneRoute.preferredInput(useBuiltInMicrophone: true, availableInputs: [.usb]), nil)
        TestSupport.expectEqual(MicrophoneRoute.preferredInput(useBuiltInMicrophone: true, availableInputs: []), nil)
    }

    private static func testSystemChoiceClearsThePreference() {
        for available in [[InputPortKind.builtInMic], [.builtInMic, .headset], [.bluetooth]] {
            TestSupport.expectEqual(MicrophoneRoute.preferredInput(useBuiltInMicrophone: false, availableInputs: available), nil)
        }
    }

    /// The router re-asserts only when the system moved the input off the built-in microphone, never
    /// with the choice off, and not without a built-in microphone.
    @MainActor
    private static func testReassertOnlyWhenMovedOffTheBuiltInMicrophone() {
        for moved in [InputPortKind.headset, .usb, .bluetooth, .other] {
            let (session, router) = configured(available: [.builtInMic, moved])
            session.current = moved   // headphones plugged in
            router.routeChanged(session)
            TestSupport.expectEqual(session.preferences, [.builtInMic, .builtInMic])
            TestSupport.expectEqual(router.routing, .builtInMicrophone)
        }
        let (session, router) = configured(available: [.builtInMic, .headset])
        let requests = session.preferences.count
        TestSupport.expect(!router.routeChanged(session), "re-asserted on the built-in microphone")
        TestSupport.expectEqual(session.preferences.count, requests)
        let (offSession, off) = configured(available: [.builtInMic, .headset], useBuiltIn: false)
        offSession.current = .headset
        TestSupport.expect(!off.routeChanged(offSession), "overrode the system choice")
        TestSupport.expectEqual(off.routing, .systemChoice)
        let (usbSession, noBuiltIn) = configured(available: [.usb])
        TestSupport.expect(!noBuiltIn.routeChanged(usbSession), "re-asserted without a built-in microphone")
        TestSupport.expectEqual(noBuiltIn.routing, .unresolved(.usb))
    }

    private static func testLabelsAreContentFree() {
        TestSupport.expectEqual(InputPortKind.allCases.map(\.label), ["iPhone microphone", "Bluetooth", "Headset", "USB", "Other"])
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    /// P1: a change deferred from the background must not move the input while the category options
    /// still belong to the applied choice. Route changes re-assert only the applied choice; the next
    /// configuration applies the desired one.
    @MainActor
    private static func testDeferredChoiceKeepsRoutingOnTheAppliedOne() {
        let session = FakeRouteSession(available: [.builtInMic, .headset])
        let router = MicrophoneRouter(desired: true)
        try! router.configureCategory(session)
        router.applyInput(session)
        TestSupport.expectEqual(session.categories, [MicrophoneRoute.categoryOptions(useBuiltInMicrophone: true)])
        TestSupport.expectEqual(session.preferences, [.builtInMic])
        TestSupport.expect(!router.needsReconfiguration, "fresh session needs reconfiguration")

        router.setDesired(false)   // changed while the app could not apply it
        TestSupport.expect(router.needsReconfiguration, "deferred change not pending")
        TestSupport.expectEqual(session.categories.count, 1)
        TestSupport.expectEqual(session.preferences, [.builtInMic])
        // Headphones plugged in: the applied choice (built-in) is re-asserted, the old category kept.
        session.current = .headset
        router.routeChanged(session)
        TestSupport.expectEqual(session.preferences, [.builtInMic, .builtInMic])
        TestSupport.expectEqual(session.categories.count, 1)

        // The foreground reconfiguration applies the desired choice: hands-free category, preference cleared.
        try! router.configureCategory(session)
        router.applyInput(session)
        TestSupport.expectEqual(session.categories.last, MicrophoneRoute.categoryOptions(useBuiltInMicrophone: false))
        TestSupport.expectEqual(session.preferences.last, .some(nil))
        TestSupport.expect(!router.needsReconfiguration, "still pending after applying")
        session.current = .headset
        let count = session.preferences.count
        TestSupport.expect(!router.routeChanged(session), "overrode the system choice")
        TestSupport.expectEqual(session.preferences.count, count)
    }

    @MainActor
    private static func testDeferredBuiltInChoiceDoesNotOverrideTheSystem() {
        let session = FakeRouteSession(available: [.builtInMic, .headset])
        let router = MicrophoneRouter(desired: false)
        try! router.configureCategory(session)
        router.applyInput(session)
        router.setDesired(true)
        session.current = .headset
        TestSupport.expect(!router.routeChanged(session), "a deferred choice moved the input")
        TestSupport.expectEqual(session.preferences, [nil])
        // A configuration that fails keeps the applied choice.
        session.failCategory = true
        TestSupport.expect((try? router.configureCategory(session)) == nil, "failure not reported")
        TestSupport.expectEqual(router.applied, false)
        session.failCategory = false
        try! router.configureCategory(session)
        TestSupport.expectEqual(router.applied, true)
        router.routeChanged(session)
        TestSupport.expectEqual(session.preferences.last, .builtInMic)
    }

    @MainActor
    private static func testNoRoutingWithoutAConfiguredSession() {
        let session = FakeRouteSession(available: [.builtInMic, .headset])
        session.current = .headset
        let router = MicrophoneRouter()
        router.applyInput(session)
        TestSupport.expect(!router.routeChanged(session), "routed without a session")
        try! router.configureCategory(session)
        router.sessionEnded()
        TestSupport.expect(!router.routeChanged(session), "routed after the session ended")
        TestSupport.expect(!router.needsReconfiguration, "an ended session needs reconfiguration")
        TestSupport.expectEqual(session.preferences, [])
    }


    /// A router with a session configured and its input applied.
    @MainActor
    private static func configured(available: [InputPortKind], useBuiltIn: Bool = true,
                                   answer: FakeRouteSession.Answer = .immediately) -> (FakeRouteSession, MicrophoneRouter) {
        let session = FakeRouteSession(available: available)
        session.answer = answer
        let router = MicrophoneRouter(desired: useBuiltIn)
        try! router.configureCategory(session)
        router.applyInput(session)
        return (session, router)
    }

    /// iOS takes the request but reports the new route only later, through a route change.
    @MainActor
    private static func testDelayedRequestResolvesAtTheRouteChange() {
        let session = FakeRouteSession(available: [.headset, .builtInMic])
        session.answer = .later
        let router = MicrophoneRouter()
        try! router.configureCategory(session)
        TestSupport.expect(router.applyInput(session), "no check scheduled for a pending request")
        TestSupport.expectEqual(router.routing, .awaitingRoute)
        TestSupport.expectEqual(router.routing.problem, nil)
        session.deliverPendingRoute()
        TestSupport.expect(!router.routeChanged(session), "requested again on its own answer")
        TestSupport.expectEqual(router.routing, .builtInMicrophone)
        TestSupport.expectEqual(session.preferences, [.builtInMic])
        router.verify(session, requestID: router.requestID)   // the delayed check finds it settled
        TestSupport.expectEqual(router.routing, .builtInMicrophone)
    }

    /// iOS accepts the request but keeps the headset. The answering route change marks it unresolved
    /// without asking again (no loop); a later change from elsewhere retries, and a satisfiable retry
    /// resolves it.
    @MainActor
    private static func testUnsatisfiedRequestIsUnresolvedAndRetriedLater() {
        let session = FakeRouteSession(available: [.headset, .builtInMic])
        session.answer = .never
        let router = MicrophoneRouter()
        try! router.configureCategory(session)
        TestSupport.expect(router.applyInput(session), "no check scheduled")
        TestSupport.expectEqual(router.routing, .awaitingRoute)
        TestSupport.expect(!router.routeChanged(session), "requested again on its own answer")
        TestSupport.expectEqual(router.routing, .unresolved(.headset))
        TestSupport.expectEqual(router.routing.problem, "Using headset microphone: couldn't switch to iPhone microphone")
        TestSupport.expectEqual(session.preferences.count, 1)
        // Something else changes the route (AirPods connect and disconnect): one retry.
        TestSupport.expect(router.routeChanged(session), "not retried at the next route change")
        TestSupport.expectEqual(session.preferences.count, 2)
        TestSupport.expectEqual(router.routing, .awaitingRoute)
        TestSupport.expect(!router.routeChanged(session), "retried on its own answer")
        TestSupport.expectEqual(router.routing, .unresolved(.headset))
        // The headset is unplugged and iOS honors the next request.
        session.answer = .immediately
        router.routeChanged(session)
        TestSupport.expectEqual(session.preferences.count, 3)
        TestSupport.expectEqual(router.routing, .builtInMicrophone)
        TestSupport.expectEqual(router.routing.problem, nil)
    }

    /// A request that throws is unresolved at once and retried at the next route change.
    @MainActor
    private static func testFailedRequestIsUnresolvedAtOnce() {
        let session = FakeRouteSession(available: [.usb, .builtInMic])
        session.answer = .fail
        let router = MicrophoneRouter()
        try! router.configureCategory(session)
        TestSupport.expect(!router.applyInput(session), "a failed request awaits a route")
        TestSupport.expectEqual(router.routing, .unresolved(.usb))
        TestSupport.expectEqual(router.routing.problem, "Using USB microphone: couldn't switch to iPhone microphone")
        session.answer = .immediately
        router.routeChanged(session)
        TestSupport.expectEqual(session.preferences.count, 2)
        TestSupport.expectEqual(router.routing, .builtInMicrophone)
        // Ending the session clears the status.
        router.sessionEnded()
        TestSupport.expectEqual(router.routing, .systemChoice)
    }

    /// iOS posts no route change at all: the delayed check judges the request, and only the latest one.
    @MainActor
    private static func testSilentRequestIsJudgedAfterTheSettleTime() {
        let session = FakeRouteSession(available: [.bluetooth, .builtInMic])
        session.answer = .never
        let router = MicrophoneRouter()
        try! router.configureCategory(session)
        router.applyInput(session)
        let first = router.requestID
        router.verify(session, requestID: first - 1)   // a stale check changes nothing
        TestSupport.expectEqual(router.routing, .awaitingRoute)
        router.verify(session, requestID: first)
        TestSupport.expectEqual(router.routing, .unresolved(.bluetooth))
        // A later request that iOS delays is not cut short by an older check.
        session.answer = .later
        router.routeChanged(session)
        router.verify(session, requestID: first)
        TestSupport.expectEqual(router.routing, .awaitingRoute)
        session.deliverPendingRoute()
        router.verify(session, requestID: router.requestID)
        TestSupport.expectEqual(router.routing, .builtInMicrophone)
    }

    private static func testProblemsAreContentFree() {
        let suffix = ": couldn't switch to iPhone microphone"
        TestSupport.expectEqual(MicrophoneRouting.unresolved(.bluetooth).problem, "Using Bluetooth microphone" + suffix)
        TestSupport.expectEqual(MicrophoneRouting.unresolved(.other).problem, "Using another microphone" + suffix)
        TestSupport.expectEqual(MicrophoneRouting.unresolved(nil).problem, "No microphone available" + suffix)
        for settled in [MicrophoneRouting.systemChoice, .builtInMicrophone, .awaitingRoute] {
            TestSupport.expectEqual(settled.problem, nil)
        }
    }
}

/// Records what the router asked of the audio session, and answers preferred-input requests like iOS
/// might: at once, later (at `deliverPendingRoute`), never, or by failing.
@MainActor
final class FakeRouteSession: AudioRouteSession {
    enum Answer { case immediately, later, never, fail }

    struct Refused: Error {}

    var availableInputs: [InputPortKind]
    var currentInput: InputPortKind?
    var answer = Answer.immediately
    var failCategory = false
    private(set) var categories: [Set<MicrophoneRoute.CategoryOption>] = []
    /// Every request, including failed ones.
    private(set) var preferences: [InputPortKind?] = []
    private var pending: InputPortKind?

    init(available: [InputPortKind]) {
        availableInputs = available
        currentInput = available.first
    }

    var current: InputPortKind? {
        get { currentInput }
        set { currentInput = newValue }
    }

    func setCategoryOptions(_ options: Set<MicrophoneRoute.CategoryOption>) throws {
        guard !failCategory else { throw CocoaError(.featureUnsupported) }
        categories.append(options)
    }

    func setPreferredInput(_ kind: InputPortKind?) throws {
        preferences.append(kind)
        guard let kind else { return }
        switch answer {
        case .immediately: currentInput = kind
        case .later: pending = kind
        case .never: break
        case .fail: throw Refused()
        }
    }

    /// iOS switches to the requested input; the caller then delivers the route change.
    func deliverPendingRoute() {
        if let pending { currentInput = pending }
        pending = nil
    }
}
