import Foundation
import SwiftUI

/// App-only preferences in the app's own `UserDefaults` (the keyboard never reads them). None holds
/// user content: onboarding progress, the microphone choice, and how long the last model preparation took,
/// so the next one can show an estimate.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let lastPreparationSeconds = "lastModelPreparationSeconds"
        static let useBuiltInMicrophone = "useBuiltInMicrophone"
    }

    private let defaults: UserDefaults

    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }

    /// "Use iPhone microphone" (contract: "Microphone choice"), on by default.
    @Published var useBuiltInMicrophone: Bool {
        didSet { defaults.set(useBuiltInMicrophone, forKey: Key.useBuiltInMicrophone) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        useBuiltInMicrophone = defaults.object(forKey: Key.useBuiltInMicrophone) as? Bool ?? MicrophoneRoute.defaultUseBuiltInMicrophone
    }

    var lastPreparationSeconds: Double? {
        get { (defaults.object(forKey: Key.lastPreparationSeconds) as? Double).flatMap { $0 > 0 ? $0 : nil } }
        set { defaults.set(newValue, forKey: Key.lastPreparationSeconds) }
    }
}

/// `LocalFlowSettings` (App Group, shared with the keyboard) as SwiftUI state.
@MainActor
final class SharedSettingsModel: ObservableObject {
    let settings: LocalFlowSettings?

    @Published var sessionMinutes: Int { didSet { settings?.sessionMinutes = sessionMinutes } }
    @Published var spokenDelimitersEnabled: Bool { didSet { settings?.spokenDelimitersEnabled = spokenDelimitersEnabled } }
    @Published var pressEnterEnabled: Bool { didSet { settings?.pressEnterEnabled = pressEnterEnabled } }
    @Published var hapticsEnabled: Bool { didSet { settings?.hapticsEnabled = hapticsEnabled } }

    init(settings: LocalFlowSettings?) {
        self.settings = settings
        sessionMinutes = settings?.sessionMinutes ?? LocalFlowSettings.defaultSessionMinutes
        spokenDelimitersEnabled = settings?.spokenDelimitersEnabled ?? true
        pressEnterEnabled = settings?.pressEnterEnabled ?? true
        hapticsEnabled = settings?.hapticsEnabled ?? true
    }
}
