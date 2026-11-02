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
        DisplayFace.styleLargeTitles()
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var startedLaunchSession = false
    /// Right after onboarding, Home pushes Try it once it is on screen, so the first dictation comes next and Back
    /// leads to Home with its large title.
    @State private var opensTryIt = false
    /// The start-session screen, mirrored from `host.bounceVisible` so it can appear without sliding up over Home.
    @State private var bounceShown = false

    var body: some View {
        Group {
            if !host.isConfigured {
                ConfigurationErrorView()
            } else if preferences.onboardingComplete || LaunchOptions.current.skipOnboarding {
                HomeView(transcriber: host.transcriber, settings: host.settings, preferences: preferences,
                         path: LaunchOptions.current.homePath, opensTryIt: opensTryIt)
                    .transition(.opacity)
            } else {
                OnboardingView(transcriber: host.transcriber, step: LaunchOptions.current.onboardingStep) {
                    opensTryIt = true
                    withAnimation(.snappy(duration: 0.3)) { preferences.onboardingComplete = true }
                }
                .transition(.opacity)
            }
        }
        .environmentObject(host)
        // In the background the app is the start-session screen's empty surface, so iOS's snapshot never shows Home.
        .backgroundCover(bounceShown: bounceShown)
        .fullScreenCover(isPresented: Binding(get: { bounceShown }, set: { if !$0 { host.bounceVisible = false } })) {
            BounceView(transcriber: host.transcriber)
                .environmentObject(host)
                .backgroundCover()
                // Opaque from the first frame, before the screen's own background is laid out.
                .presentationBackground(Theme.screenBackground)
        }
        // The keyboard opened the app to dictate: the screen is there at once, rather than sliding up over Home.
        .onChange(of: host.bounceVisible, initial: true) { _, visible in
            var transaction = Transaction()
            transaction.disablesAnimations = visible
            withTransaction(transaction) { bounceShown = visible }
        }
        .onChange(of: typeSize) { DisplayFace.styleLargeTitles() }
        // SwiftUI delivers universal links here as URLs, not as `NSUserActivity` (onOpenURL's docs).
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
            HeroSymbol(systemName: "exclamationmark.triangle", tint: Theme.ember)
            Text("This build is misconfigured").font(.title2.bold())
            Text("Its App Group, URL scheme or universal link is missing or invalid, so the app and the keyboard can’t talk to each other. Rebuild it with the Makefile.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
