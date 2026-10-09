import CoreML
import SwiftUI

/// Device experiments: the compute policy and content-free measurements of recent dictations, held
/// in memory only.
struct DiagnosticsView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber

    var body: some View {
        List {
            Section {
                Picker("Compute policy", selection: Binding(get: { transcriber.policy }, set: { host.setComputePolicy($0) })) {
                    ForEach(ComputePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("diagnostics.computePolicy")
                Text(transcriber.policy.explanation).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Compute policy")
            } footer: {
                Text("Changing the compute units releases the model; it is prepared again for the next dictation.")
            }

            Section("Runtime") {
                LabeledContent("Model", value: modelText)
                LabeledContent("Compute units", value: transcriber.activeUnits?.label ?? "—")
                LabeledContent("Available devices", value: availableDevices)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Memory footprint", value: footprintText(ProcessMemory.footprint()))
                }
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                Button("Release model now") { host.releaseModel() }
                    .disabled(transcriber.modelState != .ready && transcriber.modelState != .failed || host.isDictationInProgress)
            }

            Section("Last preparation") {
                if let preparation = transcriber.lastPreparation {
                    LabeledContent("Result", value: preparation.succeeded ? "Ready" : "Failed")
                    LabeledContent("Duration", value: String(format: "%.1f s", preparation.seconds))
                    LabeledContent("Compute units", value: preparation.computeUnits)
                    LabeledContent("Ran in", value: preparation.inBackground ? "Background" : "Foreground")
                    LabeledContent("Footprint after", value: footprintText(preparation.footprint))
                } else {
                    Text("None in this run").foregroundStyle(.secondary)
                }
            }

            Section {
                if transcriber.measurements.isEmpty {
                    Text("No dictations in this run").foregroundStyle(.secondary)
                }
                ForEach(transcriber.measurements) { measurement in
                    MeasurementRow(measurement: measurement)
                }
            } header: {
                Text("Recent dictations")
            } footer: {
                Text("Timings and memory only, never audio or text. Kept in memory and gone when LocalFlow quits.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modelText: String {
        switch transcriber.modelState {
        case .unavailable: return "Not in this build"
        case .notPrepared: return "Not prepared"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var availableDevices: String {
        let names = MLModel.availableComputeDevices.map { device -> String in
            switch device {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .neuralEngine: return "Neural Engine"
            @unknown default: return "Other"
            }
        }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }
}

private func footprintText(_ footprint: ProcessMemory.Footprint?) -> String {
    guard let footprint else { return "—" }
    return String(format: "%.0f MB · peak %.0f MB", footprint.currentMB, footprint.peakMB)
}

private struct MeasurementRow: View {
    var measurement: DictationMeasurement

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "%.1f s of audio", measurement.audioSeconds)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(measurement.outcome.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(measurement.outcome == .transcribed ? .green : .orange)
            }
            Text(String(format: "wait %.0f ms · transcribe %.0f ms", measurement.waitMilliseconds,
                        measurement.transcriptionMilliseconds))
                .font(.caption).monospacedDigit()
            Text("\(measurement.computeUnits) · \(measurement.inBackground ? "background" : "foreground") · \(footprintText(measurement.footprint))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
