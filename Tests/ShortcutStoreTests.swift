import Foundation

/// Contract tests for saved shortcuts (`ShortcutStore`) and the rules that
/// decide which shortcut each role may use (`ShortcutSettings`). Every test
/// uses its own `UserDefaults` suite.
enum ShortcutStoreTests {
    static func run() {
        testStorageKeysNeverChange()
        testEmptyDefaultsWriteBackHoldAndToggle()
        testLegacyPresetMigration()
        testStoredBindingsWinOverLegacyPreset()
        testStoredCustomBindingIsRemembered()
        testUnreadableValues()
        testNormalizationIsWrittenBack()
        testSaveRoundTrips()
        testValidationRules()
        testSetRemembersCustomAndRejectsConflicts()
        testMenuChoicesFollowValidation()
    }

    private static let f6 = ShortcutBinding(keyCode: 97, keyDisplay: "F6", modifiers: [.control], kind: .key, preset: nil)
    private static let customF5 = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [], kind: .key, preset: nil)
    /// A stored value in the format saved by earlier versions.
    private static let storedF6JSON = #"{"keyCode":97,"keyDisplay":"F6","modifiers":2,"kind":"key"}"#

    private static func stored(_ key: String, in defaults: UserDefaults) -> ShortcutBinding? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ShortcutBinding.self, from: $0) }
    }

    private static func settings(hold: ShortcutBinding = .defaultHold, toggle: ShortcutBinding = .defaultToggle,
                                 copyAgain: ShortcutBinding = .disabled, prompt: ShortcutBinding = .disabled) -> ShortcutSettings {
        ShortcutSettings(configuration: ShortcutConfiguration(hold: hold, toggle: toggle, copyAgain: copyAgain, prompt: prompt))
    }

    private static func testStorageKeysNeverChange() {
        TestSupport.expectEqual(ShortcutRole.allCases, [.hold, .toggle, .copyAgain, .prompt])
        TestSupport.expectEqual(ShortcutRole.allCases.map(\.storageKey),
                                ["hold_shortcut", "toggle_shortcut", "copy_again_shortcut", "prompt_shortcut"])
        TestSupport.expectEqual(ShortcutRole.allCases.map(\.savedCustomStorageKey),
                                ["saved_hold_custom_shortcut", "saved_toggle_custom_shortcut",
                                 "saved_copy_again_custom_shortcut", "saved_prompt_custom_shortcut"])
        TestSupport.expectEqual(ShortcutStore.legacyPresetKey, "hotkey_option")
    }

    private static func testEmptyDefaultsWriteBackHoldAndToggle() {
        TestSupport.withDefaults { defaults in
            let loaded = ShortcutStore(defaults: defaults).load()
            TestSupport.expectEqual(loaded.configuration, ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle))
            TestSupport.expectEqual(loaded.savedCustom, [:])
            TestSupport.expectEqual(stored("hold_shortcut", in: defaults), .defaultHold)
            TestSupport.expectEqual(stored("toggle_shortcut", in: defaults), .defaultToggle)
            for key in ["copy_again_shortcut", "prompt_shortcut", "saved_hold_custom_shortcut", "saved_toggle_custom_shortcut",
                        "saved_copy_again_custom_shortcut", "saved_prompt_custom_shortcut"] {
                TestSupport.expect(defaults.object(forKey: key) == nil, "\(key) was written")
            }
        }
    }

    private static func testLegacyPresetMigration() {
        for (legacy, preset) in [("rightOption", ShortcutPreset.rightOption), ("f5", .f5), ("fn", .fnKey), ("unknown", .fnKey)] {
            TestSupport.withDefaults { defaults in
                defaults.set(legacy, forKey: "hotkey_option")
                let loaded = ShortcutStore(defaults: defaults).load()
                TestSupport.expectEqual(loaded.configuration.hold, preset.binding)
                TestSupport.expectEqual(loaded.configuration.toggle, preset.binding.withAddedModifiers(.command))
                TestSupport.expectEqual(loaded.configuration.copyAgain, .disabled)
                TestSupport.expectEqual(loaded.configuration.prompt, .disabled)
                TestSupport.expectEqual(stored("hold_shortcut", in: defaults), preset.binding)
                TestSupport.expectEqual(stored("toggle_shortcut", in: defaults), preset.binding.withAddedModifiers(.command))
                TestSupport.expectEqual(defaults.string(forKey: "hotkey_option"), legacy)
            }
        }
    }

    private static func testStoredBindingsWinOverLegacyPreset() {
        TestSupport.withDefaults { defaults in
            defaults.set("rightOption", forKey: "hotkey_option")
            defaults.set(Data(#"{"keyCode":63,"keyDisplay":"Fn","modifiers":0,"kind":"modifierKey","preset":"fn"}"#.utf8),
                         forKey: "hold_shortcut")
            defaults.set(Data(#"{"keyCode":0,"keyDisplay":"Disabled","modifiers":0,"kind":"disabled"}"#.utf8),
                         forKey: "toggle_shortcut")
            defaults.set(Data(#"{"keyCode":96,"keyDisplay":"F5","modifiers":0,"kind":"key","preset":"f5"}"#.utf8),
                         forKey: "prompt_shortcut")
            let loaded = ShortcutStore(defaults: defaults).load()
            TestSupport.expectEqual(loaded.configuration.hold, ShortcutPreset.fnKey.binding)
            TestSupport.expectEqual(loaded.configuration.toggle, .disabled)
            TestSupport.expectEqual(loaded.configuration.prompt, ShortcutPreset.f5.binding)
            TestSupport.expectEqual(loaded.savedCustom, [:])
        }
    }

    private static func testStoredCustomBindingIsRemembered() {
        TestSupport.withDefaults { defaults in
            // A custom binding without a remembered custom one: it becomes the remembered one.
            defaults.set(Data(storedF6JSON.utf8), forKey: "copy_again_shortcut")
            let loaded = ShortcutStore(defaults: defaults).load()
            TestSupport.expectEqual(loaded.configuration.copyAgain, f6)
            TestSupport.expectEqual(loaded.savedCustom, [.copyAgain: f6])
            TestSupport.expectEqual(stored("saved_copy_again_custom_shortcut", in: defaults), f6)
        }
        TestSupport.withDefaults { defaults in
            // A remembered custom binding stays while a preset is chosen.
            defaults.set(Data(storedF6JSON.utf8), forKey: "saved_hold_custom_shortcut")
            let loaded = ShortcutStore(defaults: defaults).load()
            TestSupport.expectEqual(loaded.configuration.hold, .defaultHold)
            TestSupport.expectEqual(loaded.savedCustom, [.hold: f6])
            TestSupport.expectEqual(loaded.savedCustom(for: .hold), f6)
            TestSupport.expectEqual(loaded.savedCustom(for: .toggle), nil)
        }
    }

    private static func testUnreadableValues() {
        TestSupport.withDefaults { defaults in
            let garbage = Data("not a shortcut".utf8)
            for key in ["hold_shortcut", "copy_again_shortcut", "saved_hold_custom_shortcut", "saved_prompt_custom_shortcut"] {
                defaults.set(garbage, forKey: key)
            }
            let loaded = ShortcutStore(defaults: defaults).load()
            // Hold falls back to its default and is rewritten; Paste Again stays disabled and untouched.
            TestSupport.expectEqual(loaded.configuration.hold, .defaultHold)
            TestSupport.expectEqual(stored("hold_shortcut", in: defaults), .defaultHold)
            TestSupport.expectEqual(loaded.configuration.copyAgain, .disabled)
            TestSupport.expectEqual(defaults.data(forKey: "copy_again_shortcut"), garbage)
            // Unreadable remembered custom bindings are removed.
            TestSupport.expectEqual(loaded.savedCustom, [:])
            TestSupport.expect(defaults.object(forKey: "saved_hold_custom_shortcut") == nil, "unreadable saved hold kept")
            TestSupport.expect(defaults.object(forKey: "saved_prompt_custom_shortcut") == nil, "unreadable saved prompt kept")
        }
    }

    private static func testNormalizationIsWrittenBack() {
        TestSupport.withDefaults { defaults in
            let unnormalized = #"{"keyCode":96,"keyDisplay":"F5","modifiers":0,"kind":"key","exactModifierKeyCodes":[999,61]}"#
            defaults.set(Data(unnormalized.utf8), forKey: "prompt_shortcut")
            defaults.set(Data(unnormalized.utf8), forKey: "saved_toggle_custom_shortcut")
            let expected = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [.option], kind: .key, preset: nil,
                                           exactModifierKeyCodes: [61])
            let loaded = ShortcutStore(defaults: defaults).load()
            TestSupport.expectEqual(loaded.configuration.prompt, expected)
            TestSupport.expectEqual(loaded.savedCustom, [.prompt: expected, .toggle: expected])
            TestSupport.expectEqual(stored("prompt_shortcut", in: defaults), expected)
            TestSupport.expectEqual(stored("saved_toggle_custom_shortcut", in: defaults), expected)
            TestSupport.expectEqual(stored("saved_prompt_custom_shortcut", in: defaults), expected)
        }
    }

    private static func testSaveRoundTrips() {
        TestSupport.withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            var settings = store.load()
            TestSupport.expectEqual(settings.set(f6, for: .prompt), nil)
            store.save(settings, for: .prompt)
            TestSupport.expectEqual(settings.set(ShortcutPreset.f5.binding, for: .prompt), nil)
            store.save(settings, for: .prompt)
            let reloaded = store.load()
            TestSupport.expectEqual(reloaded, settings)
            TestSupport.expectEqual(reloaded.configuration.prompt, ShortcutPreset.f5.binding)
            TestSupport.expectEqual(reloaded.savedCustom(for: .prompt), f6)
        }
    }

    private static func testValidationRules() {
        let rightOption = ShortcutPreset.rightOption.binding
        let f5 = ShortcutPreset.f5.binding
        let base = settings(hold: rightOption, toggle: f5, copyAgain: f6, prompt: .defaultHold)
        TestSupport.expectEqual(base.validate(f5, for: .hold), "Hold and tap shortcuts must be distinct.")
        TestSupport.expectEqual(base.validate(rightOption, for: .toggle), "Hold and tap shortcuts must be distinct.")
        TestSupport.expectEqual(base.validate(f6, for: .hold), "This shortcut is already used by Paste Again.")
        TestSupport.expectEqual(base.validate(f6, for: .prompt), "This shortcut is already used by Paste Again.")
        TestSupport.expectEqual(base.validate(rightOption, for: .copyAgain), "Paste Again cannot share a shortcut with Hold to Talk.")
        TestSupport.expectEqual(base.validate(f5, for: .copyAgain), "Paste Again cannot share a shortcut with Tap to Toggle.")
        TestSupport.expectEqual(base.validate(.defaultHold, for: .copyAgain), "This shortcut is already used by Hold to Prompt.")
        TestSupport.expectEqual(base.validate(.defaultHold, for: .toggle), "This shortcut is already used by Hold to Prompt.")
        TestSupport.expectEqual(base.validate(rightOption, for: .prompt), "Hold to Prompt cannot share a shortcut with Hold to Talk.")
        TestSupport.expectEqual(base.validate(f5, for: .prompt), "Hold to Prompt cannot share a shortcut with Tap to Toggle.")
        // A role may keep its own binding, and Disabled is always allowed.
        for role in ShortcutRole.allCases {
            TestSupport.expectEqual(base.validate(base.configuration[role], for: role), nil)
            TestSupport.expectEqual(base.validate(.disabled, for: role), nil)
        }
        // Conflicts are by input, not identity: a custom F5 conflicts with the F5 preset.
        TestSupport.expectEqual(base.validate(customF5, for: .hold), "Hold and tap shortcuts must be distinct.")
    }

    private static func testSetRemembersCustomAndRejectsConflicts() {
        var settings = settings()
        TestSupport.expectEqual(settings.set(f6, for: .copyAgain), nil)
        TestSupport.expectEqual(settings.configuration.copyAgain, f6)
        TestSupport.expectEqual(settings.savedCustom(for: .copyAgain), f6)
        TestSupport.expectEqual(settings.set(.disabled, for: .copyAgain), nil)
        TestSupport.expectEqual(settings.configuration.copyAgain, .disabled)
        TestSupport.expectEqual(settings.savedCustom(for: .copyAgain), f6)

        let before = settings
        TestSupport.expectEqual(settings.set(.defaultHold, for: .toggle), "Hold and tap shortcuts must be distinct.")
        TestSupport.expectEqual(settings, before)

        // Bindings are normalized before they are checked and kept.
        let unnormalized = ShortcutBinding(keyCode: 97, keyDisplay: "F6", modifiers: [], kind: .key, preset: nil,
                                           exactModifierKeyCodes: [999, 59])
        TestSupport.expectEqual(settings.set(unnormalized, for: .prompt), nil)
        TestSupport.expectEqual(settings.configuration.prompt, unnormalized.normalizedForStorageMigration())
        TestSupport.expectEqual(settings.configuration.prompt.exactModifierKeyCodes, [59])
    }

    /// Regression: the menu bar used its own `==` checks, so choices that conflict
    /// with Paste Again, Hold to Prompt or an equivalent custom binding stayed
    /// enabled and silently did nothing. Every enabled choice must now succeed.
    private static func testMenuChoicesFollowValidation() {
        let base = settings(prompt: ShortcutPreset.f5.binding)
        var withSaved = base
        TestSupport.expectEqual(withSaved.set(customF5, for: .copyAgain), "This shortcut is already used by Hold to Prompt.")
        TestSupport.expectEqual(withSaved.set(f6, for: .hold), nil)
        TestSupport.expectEqual(withSaved.set(.defaultHold, for: .hold), nil)

        let hold = withSaved.menuChoices(for: .hold)
        TestSupport.expectEqual(hold.map(\.title), ["Disabled", "Fn 🌐", "Right Option ⌥", "F5", "Custom: \(f6.displayName)"])
        TestSupport.expectEqual(hold.map(\.binding), [.disabled] + ShortcutPreset.allCases.map(\.binding) + [f6])
        TestSupport.expectEqual(hold.map(\.isSelected), [false, true, false, false, false])
        TestSupport.expectEqual(hold.map(\.isEnabled), [true, true, true, false, true])

        let copyAgain = withSaved.menuChoices(for: .copyAgain)
        TestSupport.expectEqual(copyAgain.map(\.isSelected), [true, false, false, false])
        TestSupport.expectEqual(copyAgain.map(\.isEnabled), [true, false, true, false])

        for role in ShortcutRole.allCases {
            for choice in withSaved.menuChoices(for: role) {
                var attempt = withSaved
                let message = attempt.set(choice.binding, for: role)
                TestSupport.expectEqual(message == nil, choice.isEnabled)
            }
        }
    }
}
