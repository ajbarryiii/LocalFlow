#if LOCALFLOW_POWER_LOG
import SwiftUI

/// The always-on microphone test mode's switch (power test builds only; ARCHITECTURE.md, "Always-on
/// microphone test mode"). Off by default, in the app's own UserDefaults, never the App Group.
enum AlwaysOnPreference {
    private static let key = "powerTestAlwaysOnMicrophone"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Home, while the mode is on: the microphone stays open, even when locked, until it is turned off.
struct AlwaysOnBanner: View {
    @EnvironmentObject private var host: HostSessionController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.title3)
                .foregroundStyle(Theme.live)
                .accessibilityHidden(true)
            Text("Always-on test mode: the microphone stays open, even when locked")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Turn off") { host.setAlwaysOnMicrophone(false) }
                .buttonStyle(.bordered)
                .tint(Theme.live)
                .accessibilityIdentifier("home.alwaysOn.turnOff")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("home.alwaysOn")
    }
}
#endif
