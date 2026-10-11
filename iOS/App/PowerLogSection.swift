#if LOCALFLOW_POWER_LOG
import SwiftUI
import UIKit

/// Diagnostics → Power, in test builds only (ARCHITECTURE.md, "Power log"): two observed drain rates
/// (never a projection), per-state totals, the log's size and span, Export, Clear, and the always-on
/// microphone test mode's switch.
struct PowerLogSection: View {
    @EnvironmentObject private var host: HostSessionController
    @State private var status: PowerRecorder.Status?
    /// The share sheet's binding; SwiftUI may clear it before any cleanup runs.
    @State private var export: PowerLogStore.Export?
    /// The copies on screen, kept apart from the binding so they are always deleted.
    @State private var presented: PowerLogStore.Export?
    @State private var message: String?
    @State private var exporting = false
    @State private var confirmingClear = false

    var body: some View {
        Section {
            Toggle("Always-on microphone (test)",
                   isOn: Binding(get: { host.alwaysOnMicrophone }, set: { host.setAlwaysOnMicrophone($0) }))
                .tint(Theme.live)
                .accessibilityIdentifier("diagnostics.power.alwaysOn")
            if let status {
                let summary = status.summary
                LabeledContent("Logged", value: "\(spanText(summary.span)) · \(sizeText(status.bytesOnDisk))")
                    .accessibilityIdentifier("diagnostics.power.logged")
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Mic open, background, unlocked", value: drainText(summary.micOpenBackground))
                        .accessibilityIdentifier("diagnostics.power.micOpen")
                    LabeledContent("Mic open, locked (always-on)", value: drainText(summary.micOpenLockedAlwaysOn))
                        .accessibilityIdentifier("diagnostics.power.micOpenLocked")
                    LabeledContent("LocalFlow inactive (gaps)", value: drainText(summary.baseline))
                        .accessibilityIdentifier("diagnostics.power.baseline")
                    Text(PowerLogSummary.observedDrainNote)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics.power.observedNote")
                    Text(PowerLogSummary.gapNote)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("CPU per transcription", value: transcriptionText(summary))
                ForEach(PowerHostState.allCases, id: \.self) { state in
                    if let totals = summary.states[state] {
                        LabeledContent(stateLabel(state), value: totalsText(totals))
                            .font(.subheadline)
                    }
                }
                LabeledContent("Suspended or closed", value: hoursText(summary.inactive.seconds)).font(.subheadline)
                if summary.pluggedInSeconds > 0 {
                    LabeledContent("Charging (not in drain)", value: hoursText(summary.pluggedInSeconds)).font(.subheadline)
                }
                if summary.unknownSeconds > 0 {
                    LabeledContent("Unaccounted", value: hoursText(summary.unknownSeconds)).font(.subheadline)
                }
                if status.droppedSamples > 0 {
                    LabeledContent("Dropped (write failures)", value: "\(status.droppedSamples)").font(.subheadline)
                }
            } else {
                ProgressView()
            }
            if let message {
                Text(message).foregroundStyle(.red)
                    .accessibilityIdentifier("diagnostics.power.message")
            }
            Button("Export log") {
                exporting = true
                Task {
                    switch await PowerRecorder.shared.exportSnapshot() {
                    case .exported(let copies):
                        message = nil
                        presented = copies
                        export = copies
                    case .empty: message = "Nothing logged yet"
                    case .failed: message = "Couldn't export the log"
                    }
                    exporting = false
                    await reload()
                }
            }
            .disabled(exporting)
            .accessibilityIdentifier("diagnostics.power.export")
            Button("Clear log", role: .destructive) { confirmingClear = true }
                .accessibilityIdentifier("diagnostics.power.clear")
        } header: {
            Text("Power (test build)")
        } footer: {
            Text("Battery level, charging, thermal state, Low Power Mode, CPU time and memory, sampled each minute and at every change while LocalFlow runs; never audio or text. Stored on this iPhone only. Rates need at least 1 h and 3 % of drop, unplugged. LocalFlow's true share of total battery use is in Settings → Battery, which apps cannot read.")
        }
        .task { await reload() }
        .sheet(item: $export, onDismiss: { finishSharing() }) { copies in
            ActivityView(items: copies.files) { finishSharing(copies) }
        }
        .confirmationDialog("Delete the power log?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    switch await PowerRecorder.shared.clear() {
                    case .cleared:
                        message = nil
                        status = nil
                    case .partiallyCleared:
                        message = "Couldn't fully clear the log"
                        status = nil
                    case .failed:
                        message = "Couldn't clear the log"
                    }
                    await reload()
                }
            }
        }
    }

    /// A reload that started before a Clear is dropped, so cleared data never reappears.
    private func reload() async {
        guard let latest = await PowerRecorder.shared.status(), PowerRecorder.shared.isCurrent(latest) else { return }
        status = latest
    }

    /// Runs on share completion and on dismissal, whichever comes first, and again for the other: the
    /// copies it was handed and the ones recorded as presented are deleted (deleting twice is harmless).
    /// Copies left by a crash are deleted at the next launch.
    private func finishSharing(_ copies: PowerLogStore.Export? = nil) {
        if let copies { PowerRecorder.shared.discard(copies) }
        if let presented, presented != copies { PowerRecorder.shared.discard(presented) }
        presented = nil
        export = nil
    }

    private func stateLabel(_ state: PowerHostState) -> String {
        switch state {
        case .idle: return "Open, no session"
        case .micOpen: return "Mic open"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing model"
        }
    }

    private func drainText(_ drain: PowerLogSummary.Drain) -> String {
        let basis = String(format: "%.1f h, %.0f %%", drain.seconds / 3_600, drain.percent)
        guard let rate = drain.percentPerHour else { return "Not enough data (\(basis))" }
        return String(format: "%.2f %%/h", rate) + " (\(basis))"
    }

    private func transcriptionText(_ summary: PowerLogSummary) -> String {
        guard let seconds = summary.cpuSecondsPerTranscription else { return "No transcriptions yet" }
        return String(format: "%.2f s · %d", seconds, summary.transcriptions)
    }

    private func totalsText(_ totals: PowerLogSummary.Totals) -> String {
        "\(hoursText(totals.seconds)) · CPU " + String(format: "%.0f s · %.0f %%", totals.cpuSeconds, totals.drainPercent)
    }

    private func hoursText(_ seconds: Double) -> String {
        seconds < 3_600 ? String(format: "%.0f min", seconds / 60) : String(format: "%.1f h", seconds / 3_600)
    }

    private func spanText(_ span: DateInterval?) -> String {
        guard let span else { return "Nothing yet" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: span.duration) ?? "—"
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension PowerLogStore.Export: Identifiable {
    var id: URL { directory }
}

/// The system share sheet for the snapshot copies (AirDrop, Files, Mail…). Nothing is sent unless the
/// user picks a destination. `onComplete` runs when the user finishes or cancels.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
