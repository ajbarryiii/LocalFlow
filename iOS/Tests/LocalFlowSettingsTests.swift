import Foundation

enum LocalFlowSettingsTests {
    static var tests: [TestCase] {
        [
            ("defaults", testDefaults),
            ("storesValues", testStoresValues),
            ("sessionMinutesAcceptsOnlyOptions", testSessionMinutesAcceptsOnlyOptions),
            ("cursorMultipliersDefaultToOne", testCursorMultipliersDefaultToOne),
            ("cursorMultipliersAcceptOnlyTheRange", testCursorMultipliersAcceptOnlyTheRange),
            ("cursorTouchRateIsRecordedAsNumbersOnly", testCursorTouchRateIsRecordedAsNumbersOnly),
        ]
    }

    private static func testCursorMultipliersDefaultToOne() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(settings.cursorSensitivity, 1)
            TestSupport.expectEqual(settings.cursorAcceleration, 1)
            settings.cursorSensitivity = 1.6
            settings.cursorAcceleration = 0.5
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expectEqual(reread.cursorSensitivity, 1.6)
            TestSupport.expectEqual(reread.cursorAcceleration, 0.5)
            // Independent of the other settings.
            TestSupport.expectEqual(reread.sessionMinutes, 5)
            TestSupport.expect(reread.hapticsEnabled, "haptics untouched")
        }
    }

    private static func testCursorTouchRateIsRecordedAsNumbersOnly() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(settings.cursorTouchRate, nil)
            TestSupport.expectEqual(settings.cursorEventStepScale, nil)
            settings.recordCursorTouchRate(120, eventStepScale: 2)
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expectEqual(reread.cursorTouchRate, 120)
            TestSupport.expectEqual(reread.cursorEventStepScale, 2)
            // Out-of-range or broken values are ignored, and a stray Bool reads as nothing.
            settings.recordCursorTouchRate(.nan, eventStepScale: 1)
            settings.recordCursorTouchRate(60, eventStepScale: 9)
            TestSupport.expectEqual(settings.cursorTouchRate, 120)
            defaults.set(true, forKey: "cursorTouchRate")
            TestSupport.expectEqual(settings.cursorTouchRate, nil)
        }
    }

    private static func testCursorMultipliersAcceptOnlyTheRange() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(LocalFlowSettings.cursorMultiplierRange, 0.25...4)
            settings.cursorSensitivity = 2
            for rejected in [0, 0.1, 4.5, -1, Double.nan, .infinity] {
                settings.cursorSensitivity = rejected
                TestSupport.expectEqual(settings.cursorSensitivity, 2)
            }
            settings.cursorSensitivity = 0.25
            TestSupport.expectEqual(settings.cursorSensitivity, 0.25)
            settings.cursorSensitivity = 4
            TestSupport.expectEqual(settings.cursorSensitivity, 4)
            // Stored values written by something else read as the default when invalid.
            let invalid: [Any] = [9.0, 0.0, "1.5", true]
            for stored in invalid {
                defaults.set(stored, forKey: "cursorAcceleration")
                TestSupport.expectEqual(settings.cursorAcceleration, 1)
            }
            defaults.set(3, forKey: "cursorAcceleration")
            TestSupport.expectEqual(settings.cursorAcceleration, 3)
        }
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
