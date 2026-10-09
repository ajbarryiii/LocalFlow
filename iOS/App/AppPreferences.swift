import Foundation
import SwiftUI

/// App-only preferences in the app's own `UserDefaults` (the keyboard never reads them). None holds
/// user content: onboarding progress, the Diagnostics compute policy, and how long the last model
/// preparation took, so the next one can show an estimate.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let computePolicy = "computePolicy"
        static let lastPreparationSeconds = "lastModelPreparationSeconds"
    }

    private let defaults: UserDefaults

    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }

    @Published var computePolicy: ComputePolicy {
        didSet { defaults.set(computePolicy.rawValue, forKey: Key.computePolicy) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        computePolicy = ComputePolicy(storedValue: defaults.string(forKey: Key.computePolicy))
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
