import SwiftUI

/// How to grant a missing permission, shown under its Grant Access button in
/// Settings and Setup. For Accessibility it also explains how to repair a
/// stale entry and offers to reveal this copy of the app.
struct PermissionRepairHint: View {
    @EnvironmentObject var appState: AppState
    let permission: PrivacyPermission

    var body: some View {
        Text(permission.enableInstructions(appName: AppName.displayName)).font(.caption).foregroundStyle(.secondary)
        if permission == .accessibility {
            Text(PrivacyPermission.accessibilityRepairInstructions).font(.caption).foregroundStyle(.secondary)
            Button("Show This App in Finder") { appState.revealAppForPermissionRepair() }
                .accessibilityLabel("Show This App in Finder")
        }
    }
}
