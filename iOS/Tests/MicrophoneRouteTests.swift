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
}
