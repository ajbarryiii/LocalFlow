import Foundation

enum LocalFlowSettingsTests {
    static var tests: [TestCase] {
        [
            ("defaults", testDefaults),
            ("storesValues", testStoresValues),
            ("sessionMinutesAcceptsOnlyOptions", testSessionMinutesAcceptsOnlyOptions),
        ]
    }

    /// A throwaway suite with an invented name, removed afterwards.
    private static func withSettings(_ body: (LocalFlowSettings, UserDefaults) -> Void) {
        let suite = "LocalFlowIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(LocalFlowSettings(defaults: defaults), defaults)
    }

    private static func testDefaults() {
        withSettings { settings, _ in
            TestSupport.expectEqual(settings.sessionMinutes, 5)
            TestSupport.expectEqual(settings.sessionDuration, 300)
            TestSupport.expect(settings.spokenDelimitersEnabled, "spoken delimiters default")
            TestSupport.expect(settings.pressEnterEnabled, "press enter default")
            TestSupport.expect(settings.hapticsEnabled, "haptics default")
        }
    }

    private static func testStoresValues() {
        withSettings { settings, defaults in
            settings.sessionMinutes = 60
            settings.spokenDelimitersEnabled = false
            settings.pressEnterEnabled = false
            settings.hapticsEnabled = false
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expectEqual(reread.sessionMinutes, 60)
            TestSupport.expectEqual(reread.sessionDuration, 3_600)
            TestSupport.expect(!reread.spokenDelimitersEnabled, "spoken delimiters stored")
            TestSupport.expect(!reread.pressEnterEnabled, "press enter stored")
            TestSupport.expect(!reread.hapticsEnabled, "haptics stored")
            settings.hapticsEnabled = true
            TestSupport.expect(reread.hapticsEnabled, "haptics restored")
        }
    }

    private static func testSessionMinutesAcceptsOnlyOptions() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(LocalFlowSettings.sessionMinuteOptions, [5, 15, 60])
            settings.sessionMinutes = 15
            settings.sessionMinutes = 7
            settings.sessionMinutes = 0
            TestSupport.expectEqual(settings.sessionMinutes, 15)
            let invalid: [Any] = [7, -5, 0, "15", 15.5, true]
            for stored in invalid {
                defaults.set(stored, forKey: "sessionMinutes")
                TestSupport.expectEqual(settings.sessionMinutes, 5)
            }
        }
    }
}
