import AppIntents
import SwiftUI
import WidgetKit

/// The session control (ARCHITECTURE.md, "Session control"): one button for the Action button, Control Center and
/// the Lock Screen. A button, not a toggle: a toggle's state would be read here, and the extension reads no files,
/// settings or App Group; the Live Activity and the microphone indicator show the session.
struct SessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SessionControl") {
            ControlWidgetButton(action: ToggleFlowSessionIntent()) {
                Label("Flow Session", systemImage: "waveform")
            }
        }
        .displayName("Flow Session")
    }
}
