import AppKit
import SwiftUI

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.appState)
        }
    }
}

@MainActor
struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    private var iconName: String {
        if appState.isRecording { return "record.circle" }
        if appState.isTranscribing { return "ellipsis.circle" }
        return "waveform"
    }

    var body: some View {
        HStack(spacing: 4) {
            if !appState.isRecording && !appState.isTranscribing {
                Image(nsImage: LocalFlowMenuBarIcon.image(isDevelopmentBuild: AppBuild.isDevBundle))
                    .renderingMode(.template)
                    .accessibilityLabel(AppName.displayName)
            } else {
                Image(systemName: iconName)
            }
        }
    }
}
