import SwiftUI
import UIKit

@main
struct LocalFlowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var host = HostSessionController.shared

    init() {
        #if LOCALFLOW_SELFTEST
        SelfTest.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(host: host, preferences: host.preferences)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Run recovery happens here, before any URL or activation can reconcile.
        HostSessionController.shared.launch()
        return true
    }
}

/// How the UI starts. Always the defaults, except in self-test builds (see `SelfTest`).
struct LaunchOptions {
    var skipOnboarding = false
    var onboardingStep = OnboardingStep.welcome
    var homePath: [HomeRoute] = []
    var startSession = false

    static let current: LaunchOptions = {
        #if LOCALFLOW_SELFTEST
        return SelfTest.launchOptions
        #else
        return LaunchOptions()
        #endif
    }()
}

private struct RootView: View {
    @ObservedObject var host: HostSessionController
    @ObservedObject var preferences: AppPreferences
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedLaunchSession = false

    var body: some View {
        Group {
            if !host.isConfigured {
                ConfigurationErrorView()
            } else if preferences.onboardingComplete || LaunchOptions.current.skipOnboarding {
                HomeView(transcriber: host.transcriber, settings: host.settings, preferences: preferences,
                         path: LaunchOptions.current.homePath)
                    .transition(.opacity)
            } else {
                OnboardingView(transcriber: host.transcriber, step: LaunchOptions.current.onboardingStep) {
                    withAnimation(.easeInOut) { preferences.onboardingComplete = true }
                }
                .transition(.opacity)
            }
        }
        .environmentObject(host)
        .fullScreenCover(isPresented: $host.bounceVisible) {
            BounceView(transcriber: host.transcriber).environmentObject(host)
        }
        .onOpenURL { host.open($0) }
        .onChange(of: scenePhase, initial: true) {
            guard scenePhase == .active, LaunchOptions.current.startSession, !startedLaunchSession else { return }
            startedLaunchSession = true
            host.startSession()
        }
    }
}

private struct ConfigurationErrorView: View {
    var body: some View {
        VStack(spacing: 16) {
            HeroSymbol(systemName: "exclamationmark.triangle.fill", tint: AnyShapeStyle(Color.orange), size: 80)
            Text("This build is misconfigured").font(.title2.bold())
            Text("Its App Group or URL scheme is missing, so the app and the keyboard cannot talk to each other. Rebuild it with the Makefile.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
