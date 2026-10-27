import Foundation

/// Contract tests for `SettingsKeys`: saved settings depend on every key name
/// and default, so they are pinned here.
enum SettingsKeysTests {
    static func run() {
        testKeyNamesAndDefaultsNeverChange()
        testReadsFallBackToDefaults()
        testWritesRoundTrip()
        testOptionalKeysRemoveOnNil()
        testCodableKeys()
    }

    private static func pin<Value: DefaultsValue & Equatable>(_ key: DefaultsKey<Value>, _ name: String, _ defaultValue: Value,
                                              file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expectEqual(key.name, name, file: file, line: line)
        TestSupport.expectEqual(key.defaultValue, defaultValue, file: file, line: line)
    }

    private static func testKeyNamesAndDefaultsNeverChange() {
        pin(SettingsKeys.hasCompletedSetup, "hasCompletedSetup", false)
        pin(SettingsKeys.promptTag, "prompt_tag", "[dictated]")
        pin(SettingsKeys.selectedMicrophoneID, "selected_microphone_id", "default")
        pin(SettingsKeys.shortcutStartDelay, "shortcut_start_delay", 0)
        pin(SettingsKeys.preserveClipboard, "preserve_clipboard", true)
        pin(SettingsKeys.keepDictationInClipboardHistory, "keep_dictation_in_clipboard_history", false)
        pin(SettingsKeys.pressEnterVoiceCommand, "press_enter_voice_command_enabled", true)
        pin(SettingsKeys.doubleTapPrompt, "double_tap_prompt_enabled", false)
        pin(SettingsKeys.spokenDelimiters, "spoken_delimiters_enabled", true)
        pin(SettingsKeys.spokenNumbers, "spoken_numbers_enabled", true)
        pin(SettingsKeys.alertSoundsEnabled, "alert_sounds_enabled", nil)
        pin(SettingsKeys.soundVolume, "sound_volume", 1)
        pin(SettingsKeys.dictationAudioInterruption, "dictation_audio_interruption_enabled", false)
        pin(SettingsKeys.correctionSuggestions, "correction_suggestions_enabled", true)
        pin(SettingsKeys.appleIntelligenceCleanup, "apple_intelligence_cleanup_enabled", false)
        pin(SettingsKeys.showMenuBarIcon, "show_menu_bar_icon", true)
        pin(SettingsKeys.useCompactOverlay, "use_compact_overlay", true)
        pin(SettingsKeys.overlayDisplayID, "overlay_display_id", 0)
        pin(SettingsKeys.updateLastCheckDate, "updateLastCheckDate", nil)
        pin(SettingsKeys.updateAutoCheckEnabled, "updateAutoCheckEnabled", true)
        pin(SettingsKeys.updateSkippedVersion, "updateSkippedVersion", nil)
        pin(SettingsKeys.updateLastPostTranscriptionReminderVersion, "updateLastPostTranscriptionReminderVersion", nil)
        pin(SettingsKeys.updateLastPostTranscriptionReminderDate, "updateLastPostTranscriptionReminderDate", nil)

        TestSupport.expectEqual(SettingsKeys.voiceMacros.name, "voice_macros")
        TestSupport.expectEqual(SettingsKeys.voiceMacros.defaultValue, [])
        TestSupport.expectEqual(SettingsKeys.dictationStats.name, "dictation_stats")
        TestSupport.expectEqual(SettingsKeys.dictationStats.defaultValue, DictationStats())
    }

    private static func testReadsFallBackToDefaults() {
        TestSupport.withDefaults { defaults in
            TestSupport.expectEqual(defaults[SettingsKeys.preserveClipboard], true)
            TestSupport.expectEqual(defaults[SettingsKeys.keepDictationInClipboardHistory], false)
            // The experimental cleanup pass is off until turned on.
            TestSupport.expectEqual(defaults[SettingsKeys.appleIntelligenceCleanup], false)
            TestSupport.expectEqual(defaults[SettingsKeys.soundVolume], 1)
            TestSupport.expectEqual(defaults[SettingsKeys.promptTag], "[dictated]")
            TestSupport.expectEqual(defaults[SettingsKeys.alertSoundsEnabled], nil)
            TestSupport.expectEqual(defaults[SettingsKeys.updateSkippedVersion], nil)
            // A stored false is not mistaken for a missing value.
            defaults.set(false, forKey: "preserve_clipboard")
            defaults.set(false, forKey: "alert_sounds_enabled")
            defaults.set(0, forKey: "sound_volume")
            TestSupport.expectEqual(defaults[SettingsKeys.preserveClipboard], false)
            TestSupport.expectEqual(defaults[SettingsKeys.alertSoundsEnabled], false)
            TestSupport.expectEqual(defaults[SettingsKeys.soundVolume], 0)
        }
    }

    private static func testWritesRoundTrip() {
        TestSupport.withDefaults { defaults in
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            defaults[SettingsKeys.spokenNumbers] = false
            defaults[SettingsKeys.shortcutStartDelay] = 0.25
            defaults[SettingsKeys.soundVolume] = 0.5
            defaults[SettingsKeys.selectedMicrophoneID] = "synthetic-mic"
            defaults[SettingsKeys.overlayDisplayID] = -1
            defaults[SettingsKeys.updateLastCheckDate] = date
            defaults[SettingsKeys.updateSkippedVersion] = "9.9.9"
            TestSupport.expectEqual(defaults.object(forKey: "spoken_numbers_enabled") as? Bool, false)
            TestSupport.expectEqual(defaults.double(forKey: "shortcut_start_delay"), 0.25)
            TestSupport.expectEqual(defaults.float(forKey: "sound_volume"), 0.5)
            TestSupport.expectEqual(defaults.string(forKey: "selected_microphone_id"), "synthetic-mic")
            TestSupport.expectEqual(defaults.integer(forKey: "overlay_display_id"), -1)
            TestSupport.expectEqual(defaults.object(forKey: "updateLastCheckDate") as? Date, date)
            TestSupport.expectEqual(defaults.string(forKey: "updateSkippedVersion"), "9.9.9")
            TestSupport.expectEqual(defaults[SettingsKeys.spokenNumbers], false)
            TestSupport.expectEqual(defaults[SettingsKeys.updateLastCheckDate], date)
        }
    }

    private static func testOptionalKeysRemoveOnNil() {
        TestSupport.withDefaults { defaults in
            defaults[SettingsKeys.updateSkippedVersion] = "9.9.9"
            defaults[SettingsKeys.updateSkippedVersion] = nil
            TestSupport.expect(defaults.object(forKey: "updateSkippedVersion") == nil, "nil did not remove the value")
        }
    }

    private static func testCodableKeys() {
        TestSupport.withDefaults { defaults in
            TestSupport.expectEqual(defaults[SettingsKeys.voiceMacros], [])
            let macros = [VoiceMacro(command: "synthetic sign off", payload: "Invented closing text")]
            defaults[SettingsKeys.voiceMacros] = macros
            TestSupport.expect(defaults.data(forKey: "voice_macros") != nil, "macros were not stored as data")
            TestSupport.expectEqual(defaults[SettingsKeys.voiceMacros], macros)
            // Undecodable data reads as the default.
            defaults.set(Data("not json".utf8), forKey: "voice_macros")
            TestSupport.expectEqual(defaults[SettingsKeys.voiceMacros], [])
        }
    }
}
