import Foundation

enum LocalFlowSettingsTests {
    static var tests: [TestCase] {
        [
            ("defaults", testDefaults),
            ("storesValues", testStoresValues),
            ("keyHapticsAreSeparateFromDictationHaptics", testKeyHapticsAreSeparateFromDictationHaptics),
            ("sessionMinutesAcceptsOnlyOptions", testSessionMinutesAcceptsOnlyOptions),
            ("cursorMultipliersDefaultToOne", testCursorMultipliersDefaultToOne),
            ("cursorMultipliersAcceptOnlyTheRange", testCursorMultipliersAcceptOnlyTheRange),
            ("cursorTouchRateIsRecordedAsNumbersOnly", testCursorTouchRateIsRecordedAsNumbersOnly),
            ("fieldLayoutChoicesAreContentFreeAndBounded", testFieldLayoutChoicesAreContentFreeAndBounded),
            ("softKeyEdgesAreOffAndUnsetByDefault", testSoftKeyEdgesAreOffAndUnsetByDefault),
            ("softKeyEdgesAcceptOnlyTheirRanges", testSoftKeyEdgesAcceptOnlyTheirRanges),
            ("softKeyEdgesResetKeepsTheSwitch", testSoftKeyEdgesResetKeepsTheSwitch),
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
            TestSupport.expect(reread.keyHapticsEnabled, "key haptics untouched")
        }
    }

    private static func testFieldLayoutChoicesAreContentFreeAndBounded() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(settings.fieldLayoutOverrides, [:])
            let key = "0123456789abcdef"
            settings.setFieldLayout("messages", forKey: key)
            TestSupport.expectEqual(LocalFlowSettings(defaults: defaults).fieldLayoutOverrides, [key: "messages"])
            // Only fingerprint keys and known layouts are stored.
            settings.setFieldLayout("messages", forKey: "Some field text")
            settings.setFieldLayout("sideways", forKey: "fedcba9876543210")
            TestSupport.expectEqual(settings.fieldLayoutOverrides, [key: "messages"])
            settings.setFieldLayout(nil, forKey: key)
            TestSupport.expectEqual(settings.fieldLayoutOverrides, [:])
            // Bounded, keeping the newest choice.
            for index in 0 ..< LocalFlowSettings.fieldLayoutOverrideLimit + 5 {
                settings.setFieldLayout("fullWidth", forKey: String(format: "%016x", index))
            }
            TestSupport.expectEqual(settings.fieldLayoutOverrides.count, LocalFlowSettings.fieldLayoutOverrideLimit)
            TestSupport.expectEqual(settings.fieldLayoutOverrides[String(format: "%016x", LocalFlowSettings.fieldLayoutOverrideLimit + 4)],
                                    "fullWidth")
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
            TestSupport.expect(settings.spokenNumbersEnabled, "spoken numbers default")
            TestSupport.expect(settings.pressEnterEnabled, "press enter default")
            TestSupport.expect(settings.hapticsEnabled, "haptics default")
            TestSupport.expect(settings.keyHapticsEnabled, "key haptics default")
        }
    }

    private static func testStoresValues() {
        withSettings { settings, defaults in
            settings.sessionMinutes = 60
            settings.spokenDelimitersEnabled = false
            settings.spokenNumbersEnabled = false
            settings.pressEnterEnabled = false
            settings.hapticsEnabled = false
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expectEqual(reread.sessionMinutes, 60)
            TestSupport.expectEqual(reread.sessionDuration, 3_600)
            TestSupport.expect(!reread.spokenDelimitersEnabled, "spoken delimiters stored")
            TestSupport.expect(!reread.spokenNumbersEnabled, "spoken numbers stored")
            TestSupport.expect(!reread.pressEnterEnabled, "press enter stored")
            TestSupport.expect(!reread.hapticsEnabled, "haptics stored")
            settings.hapticsEnabled = true
            TestSupport.expect(reread.hapticsEnabled, "haptics restored")
        }
    }

    private static func testKeyHapticsAreSeparateFromDictationHaptics() {
        withSettings { settings, defaults in
            settings.keyHapticsEnabled = false
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expect(!reread.keyHapticsEnabled, "key haptics stored")
            TestSupport.expect(reread.hapticsEnabled, "dictation haptics untouched")
            settings.hapticsEnabled = false
            settings.keyHapticsEnabled = true
            TestSupport.expect(reread.keyHapticsEnabled, "key haptics restored")
            TestSupport.expect(!reread.hapticsEnabled, "dictation haptics stored")
            // A stored value that is not a Bool reads as the default.
            defaults.set("off", forKey: "keyHapticsEnabled")
            TestSupport.expect(settings.keyHapticsEnabled, "key haptics invalid value")
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

    // MARK: Soft key edges

    private static func testSoftKeyEdgesAreOffAndUnsetByDefault() {
        // Off by default, unlike the other booleans; the model and the rule values are unset, so the
        // bundle's defaults apply; the gate is on.
        withSettings { settings, defaults in
            TestSupport.expect(!settings.softKeyEdgesEnabled, "off by default")
            TestSupport.expectEqual(settings.softKeyEdgesModel, nil)
            TestSupport.expectEqual(settings.softKeyEdgesCentre, nil)
            TestSupport.expectEqual(settings.softKeyEdgesMargin, nil)
            TestSupport.expect(settings.softKeyEdgesSurpriseGate, "gate on by default")
            TestSupport.expectEqual(settings.softKeyEdgesMaxSurprise, nil)
            settings.softKeyEdgesEnabled = true
            settings.softKeyEdgesModel = "232k"
            settings.softKeyEdgesCentre = 0.45
            settings.softKeyEdgesMargin = 5
            settings.softKeyEdgesSurpriseGate = false
            settings.softKeyEdgesMaxSurprise = 6.5
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expect(reread.softKeyEdgesEnabled, "enabled stored")
            TestSupport.expectEqual(reread.softKeyEdgesModel, "232k")
            TestSupport.expectEqual(reread.softKeyEdgesCentre, 0.45)
            TestSupport.expectEqual(reread.softKeyEdgesMargin, 5)
            TestSupport.expect(!reread.softKeyEdgesSurpriseGate, "gate stored")
            TestSupport.expectEqual(reread.softKeyEdgesMaxSurprise, 6.5)
            // Independent of the other settings.
            TestSupport.expect(reread.keyHapticsEnabled, "key haptics untouched")
            TestSupport.expectEqual(reread.cursorSensitivity, 1)
            // A stored value that is not a Bool reads as the default.
            defaults.set("on", forKey: "softKeyEdgesEnabled")
            TestSupport.expect(!settings.softKeyEdgesEnabled, "enabled invalid value")
        }
    }

    private static func testSoftKeyEdgesAcceptOnlyTheirRanges() {
        withSettings { settings, defaults in
            TestSupport.expectEqual(LocalFlowSettings.softKeyEdgesCentreRange, 0.3...0.9)
            TestSupport.expectEqual(LocalFlowSettings.softKeyEdgesMarginRange, 1...10)
            TestSupport.expectEqual(LocalFlowSettings.softKeyEdgesMaxSurpriseRange, 2...8)
            settings.softKeyEdgesCentre = 0.5
            settings.softKeyEdgesMargin = 2
            settings.softKeyEdgesMaxSurprise = 4
            for rejected in [0.2, 0.95, -1, Double.nan, .infinity] {
                settings.softKeyEdgesCentre = rejected
                TestSupport.expectEqual(settings.softKeyEdgesCentre, 0.5)
            }
            for rejected in [0.5, 11, Double.nan] {
                settings.softKeyEdgesMargin = rejected
                TestSupport.expectEqual(settings.softKeyEdgesMargin, 2)
            }
            for rejected in [1.5, 9, -Double.infinity] {
                settings.softKeyEdgesMaxSurprise = rejected
                TestSupport.expectEqual(settings.softKeyEdgesMaxSurprise, 4)
            }
            // The ends are accepted; nil forgets the value.
            settings.softKeyEdgesCentre = 0.3
            TestSupport.expectEqual(settings.softKeyEdgesCentre, 0.3)
            settings.softKeyEdgesMargin = 10
            TestSupport.expectEqual(settings.softKeyEdgesMargin, 10)
            settings.softKeyEdgesMaxSurprise = 2
            TestSupport.expectEqual(settings.softKeyEdgesMaxSurprise, 2)
            settings.softKeyEdgesCentre = nil
            TestSupport.expectEqual(settings.softKeyEdgesCentre, nil)
            // Stored values written by something else read as unset when invalid.
            let invalid: [Any] = [0.1, 1.0, "0.5", true]
            for stored in invalid {
                defaults.set(stored, forKey: "softKeyEdgesCentre")
                TestSupport.expectEqual(settings.softKeyEdgesCentre, nil)
            }
            defaults.set(0.7, forKey: "softKeyEdgesCentre")
            TestSupport.expectEqual(settings.softKeyEdgesCentre, 0.7)
            // Model names: any non-empty name up to the limit; the bundle decides which exist.
            settings.softKeyEdgesModel = "18k"
            settings.softKeyEdgesModel = ""
            TestSupport.expectEqual(settings.softKeyEdgesModel, nil)
            settings.softKeyEdgesModel = "18k"
            settings.softKeyEdgesModel = String(repeating: "m", count: LocalFlowSettings.softKeyEdgesModelNameLimit + 1)
            TestSupport.expectEqual(settings.softKeyEdgesModel, nil)
            defaults.set(18, forKey: "softKeyEdgesModel")
            TestSupport.expectEqual(settings.softKeyEdgesModel, nil)
        }
    }

    private static func testSoftKeyEdgesResetKeepsTheSwitch() {
        withSettings { settings, defaults in
            settings.softKeyEdgesEnabled = true
            settings.softKeyEdgesModel = "18k"
            settings.softKeyEdgesCentre = 0.8
            settings.softKeyEdgesMargin = 7
            settings.softKeyEdgesSurpriseGate = false
            settings.softKeyEdgesMaxSurprise = 5
            settings.resetSoftKeyEdgesTuning()
            let reread = LocalFlowSettings(defaults: defaults)
            TestSupport.expect(reread.softKeyEdgesEnabled, "switch kept")
            TestSupport.expectEqual(reread.softKeyEdgesModel, nil)
            TestSupport.expectEqual(reread.softKeyEdgesCentre, nil)
            TestSupport.expectEqual(reread.softKeyEdgesMargin, nil)
            TestSupport.expect(reread.softKeyEdgesSurpriseGate, "gate back on")
            TestSupport.expectEqual(reread.softKeyEdgesMaxSurprise, nil)
        }
    }
}
