import Foundation

extension ShortcutRole {
    /// The role's binding in UserDefaults. Saved settings depend on these names.
    var storageKey: String {
        switch self {
        case .hold: return "hold_shortcut"
        case .toggle: return "toggle_shortcut"
        case .copyAgain: return "copy_again_shortcut"
        case .prompt: return "prompt_shortcut"
        }
    }

    /// The custom binding the role remembers while a preset or Disabled is chosen.
    var savedCustomStorageKey: String {
        switch self {
        case .hold: return "saved_hold_custom_shortcut"
        case .toggle: return "saved_toggle_custom_shortcut"
        case .copyAgain: return "saved_copy_again_custom_shortcut"
        case .prompt: return "saved_prompt_custom_shortcut"
        }
    }
}

extension ShortcutConfiguration {
    subscript(role: ShortcutRole) -> ShortcutBinding {
        switch role {
        case .hold: return hold
        case .toggle: return toggle
        case .copyAgain: return copyAgain
        case .prompt: return prompt
        }
    }

    func replacing(_ role: ShortcutRole, with binding: ShortcutBinding) -> ShortcutConfiguration {
        ShortcutConfiguration(
            hold: role == .hold ? binding : hold,
            toggle: role == .toggle ? binding : toggle,
            copyAgain: role == .copyAgain ? binding : copyAgain,
            prompt: role == .prompt ? binding : prompt,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
        )
    }
}

/// One entry of a role's shortcut menu: Disabled, each preset, then the remembered custom binding.
struct ShortcutMenuChoice: Equatable, Identifiable {
    let title: String
    let binding: ShortcutBinding
    let isSelected: Bool
    /// False when choosing it would be rejected by `ShortcutSettings.validate`.
    let isEnabled: Bool

    var id: String { binding.id }
}

/// Every role's binding and the custom binding each role remembers.
struct ShortcutSettings: Equatable {
    private(set) var configuration: ShortcutConfiguration
    private(set) var savedCustom: [ShortcutRole: ShortcutBinding]

    init(configuration: ShortcutConfiguration, savedCustom: [ShortcutRole: ShortcutBinding] = [:]) {
        self.configuration = configuration
        self.savedCustom = savedCustom
    }

    func savedCustom(for role: ShortcutRole) -> ShortcutBinding? {
        savedCustom[role]
    }

    /// Why `binding` cannot be used for `role`, or nil when it can.
    func validate(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()
        let current = configuration

        if role == .hold || role == .toggle {
            let otherDictationBinding = role == .hold ? current.toggle : current.hold
            guard !binding.conflicts(with: otherDictationBinding) else {
                return "Hold and tap shortcuts must be distinct."
            }
        }

        if role != .copyAgain, binding.conflicts(with: current.copyAgain) {
            return "This shortcut is already used by Paste Again."
        }
        if role == .copyAgain {
            if binding.conflicts(with: current.hold) {
                return "Paste Again cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: current.toggle) {
                return "Paste Again cannot share a shortcut with Tap to Toggle."
            }
        }

        if role != .prompt, binding.conflicts(with: current.prompt) {
            return "This shortcut is already used by Hold to Prompt."
        }
        if role == .prompt {
            for otherRole in [ShortcutRole.hold, .toggle, .copyAgain] where binding.conflicts(with: current[otherRole]) {
                return "Hold to Prompt cannot share a shortcut with \(otherRole.title)."
            }
        }
        return nil
    }

    /// Uses the normalized `binding` for `role` when `validate` allows it, and
    /// remembers it when custom. Otherwise changes nothing and returns the reason.
    mutating func set(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()
        if let message = validate(binding, for: role) { return message }
        if binding.isCustom {
            savedCustom[role] = binding
        }
        configuration = configuration.replacing(role, with: binding)
        return nil
    }

    func menuChoices(for role: ShortcutRole) -> [ShortcutMenuChoice] {
        let current = configuration[role]
        var choices = [(title: "Disabled", binding: ShortcutBinding.disabled, isSelected: current.isDisabled)]
        for preset in ShortcutPreset.allCases {
            choices.append((title: preset.title, binding: preset.binding, isSelected: current == preset.binding))
        }
        if let saved = savedCustom[role] {
            choices.append((title: "Custom: \(saved.displayName)", binding: saved, isSelected: current == saved))
        }
        return choices.map {
            ShortcutMenuChoice(title: $0.title, binding: $0.binding, isSelected: $0.isSelected,
                               isEnabled: validate($0.binding, for: role) == nil)
        }
    }
}

/// Reads and writes shortcuts in UserDefaults, as JSON-encoded `ShortcutBinding`s.
struct ShortcutStore {
    /// The single preset saved by early versions; it seeds Hold to Talk and Tap to Toggle.
    static let legacyPresetKey = "hotkey_option"

    let defaults: UserDefaults

    /// Loads every role. Missing Hold and Tap bindings come from the legacy
    /// preset and are written back, as are bindings that needed normalizing. A
    /// custom binding with nothing remembered becomes the remembered one, and
    /// unreadable remembered bindings are removed.
    func load() -> ShortcutSettings {
        let legacyPreset = ShortcutPreset(
            rawValue: defaults.string(forKey: Self.legacyPresetKey) ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let fallbacks: [ShortcutRole: ShortcutBinding] = [
            .hold: legacyPreset.binding,
            .toggle: legacyPreset.binding.withAddedModifiers(.command)
        ]

        var bindings: [ShortcutRole: ShortcutBinding] = [:]
        var savedCustom: [ShortcutRole: ShortcutBinding] = [:]
        for role in ShortcutRole.allCases {
            let stored = read(role.storageKey)
            let fallback = fallbacks[role]
            let binding = stored.binding ?? fallback ?? .disabled
            bindings[role] = binding
            if stored.didNormalize || (stored.binding == nil && fallback != nil) {
                write(binding, forKey: role.storageKey)
            }

            let storedCustom = read(role.savedCustomStorageKey)
            if let custom = storedCustom.binding {
                savedCustom[role] = custom
                if storedCustom.didNormalize {
                    write(custom, forKey: role.savedCustomStorageKey)
                }
            } else {
                let customFallback = binding.isCustom ? binding : nil
                savedCustom[role] = customFallback
                if storedCustom.hadStoredValue || customFallback != nil {
                    writeOptional(customFallback, forKey: role.savedCustomStorageKey)
                }
            }
        }

        let configuration = ShortcutConfiguration(hold: bindings[.hold]!, toggle: bindings[.toggle]!,
                                                  copyAgain: bindings[.copyAgain]!, prompt: bindings[.prompt]!)
        return ShortcutSettings(configuration: configuration, savedCustom: savedCustom)
    }

    /// Writes `role`'s binding and its remembered custom binding.
    func save(_ settings: ShortcutSettings, for role: ShortcutRole) {
        writeOptional(settings.savedCustom(for: role), forKey: role.savedCustomStorageKey)
        write(settings.configuration[role], forKey: role.storageKey)
    }

    private struct StoredValue {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private func read(_ key: String) -> StoredValue {
        guard let data = defaults.data(forKey: key) else {
            return StoredValue(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredValue(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredValue(binding: normalized, hadStoredValue: true, didNormalize: normalized != decoded)
    }

    private func write(_ binding: ShortcutBinding, forKey key: String) {
        guard let data = try? JSONEncoder().encode(binding.normalizedForStorageMigration()) else { return }
        defaults.set(data, forKey: key)
    }

    private func writeOptional(_ binding: ShortcutBinding?, forKey key: String) {
        guard let binding else {
            defaults.removeObject(forKey: key)
            return
        }
        write(binding, forKey: key)
    }
}
