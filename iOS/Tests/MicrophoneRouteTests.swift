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
            ("reassertOnlyWhenMovedOffTheBuiltInMicrophone", testReassertOnlyWhenMovedOffTheBuiltInMicrophone),
            ("labelsAreContentFree", testLabelsAreContentFree),
            ("deferredChoiceKeepsRoutingOnTheAppliedOne", isolated(testDeferredChoiceKeepsRoutingOnTheAppliedOne)),
            ("deferredBuiltInChoiceDoesNotOverrideTheSystem", isolated(testDeferredBuiltInChoiceDoesNotOverrideTheSystem)),
            ("noRoutingWithoutAConfiguredSession", isolated(testNoRoutingWithoutAConfiguredSession)),
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

    private static func testReassertOnlyWhenMovedOffTheBuiltInMicrophone() {
        typealias Route = MicrophoneRoute
        // Headphones plugged in: the system switched to their microphone.
        for moved in [InputPortKind.headset, .usb, .bluetooth, .other] {
            TestSupport.expect(Route.needsReassertion(useBuiltInMicrophone: true, currentInput: moved,
                                                      availableInputs: [.builtInMic, moved]), "\(moved) kept")
        }
        TestSupport.expect(Route.needsReassertion(useBuiltInMicrophone: true, currentInput: nil, availableInputs: [.builtInMic]),
                           "no input kept")
        // Already on the built-in microphone, including after our own re-assertion: no loop.
        TestSupport.expect(!Route.needsReassertion(useBuiltInMicrophone: true, currentInput: .builtInMic,
                                                   availableInputs: [.builtInMic, .headset]), "re-asserted needlessly")
        // Nothing to re-assert with the choice off, or without a built-in microphone.
        TestSupport.expect(!Route.needsReassertion(useBuiltInMicrophone: false, currentInput: .headset,
                                                   availableInputs: [.builtInMic, .headset]), "overrode the system choice")
        TestSupport.expect(!Route.needsReassertion(useBuiltInMicrophone: true, currentInput: .usb, availableInputs: [.usb]),
                           "re-asserted without a built-in microphone")
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
        TestSupport.expect(router.routeChanged(session), "applied choice not re-asserted")
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
        TestSupport.expect(router.routeChanged(session), "applied built-in choice not re-asserted")
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
}

/// Records what the router asked of the audio session.
@MainActor
final class FakeRouteSession: AudioRouteSession {
    var availableInputs: [InputPortKind]
    var currentInput: InputPortKind?
    var failCategory = false
    private(set) var categories: [Set<MicrophoneRoute.CategoryOption>] = []
    private(set) var preferences: [InputPortKind?] = []

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

    func setPreferredInput(_ kind: InputPortKind?) {
        preferences.append(kind)
        if let kind { currentInput = kind }
    }
}
