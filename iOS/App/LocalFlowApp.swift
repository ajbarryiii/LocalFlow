import SwiftUI

// Phase 1 placeholder so the bundle builds, installs and runs the self-test.
@main
struct LocalFlowApp: App {
    init() {
        #if LOCALFLOW_SELFTEST
        SelfTest.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup { PlaceholderView() }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("LocalFlow")
                .font(.title.bold())
            Text("Prototype build")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
