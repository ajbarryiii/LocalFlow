import CoreML
import SwiftUI

/// Device experiments: cursor tuning, the runtime (compute units read-only, as the policy is fixed)
/// and content-free measurements of recent dictations, held in memory only.
struct DiagnosticsView: View {
    @EnvironmentObject private var host: HostSessionController
    @ObservedObject var transcriber: ParakeetTranscriber

    var body: some View {
        List {
            CursorTuningSection(settings: host.settings.settings)

            SoftKeyEdgesSection(settings: host.settings.settings)

            AutocorrectSection(settings: host.settings.settings)

            TypingCountersSection(settings: host.settings.settings)

            Section("Runtime") {
                LabeledContent("Model", value: modelText)
                LabeledContent("Compute units", value: transcriber.activeUnits?.label ?? "Not loaded")
                    .accessibilityIdentifier("diagnostics.computeUnits")
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

/// The keyboard's trackpad-mode multipliers (App Group settings, read when a gesture starts), for
/// tuning on a device side by side with Apple's keyboard.
private struct CursorTuningSection: View {
    let settings: LocalFlowSettings?
    @State private var sensitivity = 1.0
    @State private var acceleration = 1.0
    @State private var touchRate: Double?
    @State private var stepScale: Double?

    var body: some View {
        Section {
            slider("Sensitivity", value: $sensitivity, range: 0.5 ... 2, identifier: "diagnostics.cursorSensitivity")
            slider("Acceleration", value: $acceleration, range: 0.25 ... 3, identifier: "diagnostics.cursorAcceleration")
            Button("Reset to 1×") {
                sensitivity = 1
                acceleration = 1
            }
            .disabled(sensitivity == 1 && acceleration == 1)
            // Measured by the keyboard from its own touch events, written once per gesture; read-only.
            LabeledContent("Touch rate", value: touchRate.map { String(format: "%.0f Hz", $0) } ?? "Not measured yet")
                .accessibilityIdentifier("diagnostics.cursorTouchRate")
            LabeledContent("Step scale", value: stepScale.map { String(format: "%.2f×", $0) } ?? "Not measured yet")
                .accessibilityIdentifier("diagnostics.cursorStepScale")
        } header: {
            Text("Cursor")
        } footer: {
            Text("Sensitivity scales cursor travel at every speed; acceleration scales how much faster swipes go. Compare with Apple's keyboard in Try it's practice field: touch and hold the space bar with each and match the feel. Changes apply to the next gesture. The step scale makes each touch event count as a 60 Hz one would (2× at 120 Hz).")
        }
        .onAppear {
            sensitivity = settings?.cursorSensitivity ?? 1
            acceleration = settings?.cursorAcceleration ?? 1
            touchRate = settings?.cursorTouchRate
            stepScale = settings?.cursorEventStepScale
        }
        .onChange(of: sensitivity) { _, value in settings?.cursorSensitivity = value }
        .onChange(of: acceleration) { _, value in settings?.cursorAcceleration = value }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: String(format: "%.2f×", value.wrappedValue))
            Slider(value: value, in: range, step: 0.05)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.2f times", value.wrappedValue))
                .accessibilityIdentifier(identifier)
        }
    }
}

/// Soft key edges (App Group settings; ARCHITECTURE.md, "Soft key edges"), for tuning on a device. The
/// keyboard reads the rule values on every tap it re-decides, and the toggle and model when it appears.
/// Models and defaults come from the keyboard's bundle; a value equal to what the keyboard already reads
/// is not written, so the defaults stay the bundle's until a slider moves.
private struct SoftKeyEdgesSection: View {
    let settings: LocalFlowSettings?
    /// The keyboard's bundle section, or nil when this build has no models. Read once per launch.
    private static let bundled = bundledManifest()
    private var manifest: SoftKeyEdgesManifest? { Self.bundled }
    @State private var enabled = false
    @State private var model = ""
    @State private var centre = 0.6
    @State private var margin = 3.0
    @State private var gate = true
    @State private var maxSurprise = 3.0

    /// The bundle's defaults, or the reference ones when this build has no models.
    private var defaults: SoftKeyEdgesManifest.Rule {
        manifest?.rule ?? SoftKeyEdgesManifest.Rule(centre: 0.6, margin: 3, maxSurprise: 3, surpriseWindow: 8)
    }

    private var modelNames: [String] { manifest?.modelNames ?? ["18k", "67k", "232k"] }

    private var resolvedModel: String {
        manifest?.modelName(settings?.softKeyEdgesModel) ?? settings?.softKeyEdgesModel ?? "67k"
    }

    var body: some View {
        Section {
            Toggle("Soft key edges", isOn: $enabled)
                .accessibilityIdentifier("diagnostics.softKeyEdgesEnabled")
            if manifest == nil {
                Text("This build has no tap models; the keyboard types as before.").foregroundStyle(.secondary)
            }
            Picker("Model", selection: $model) {
                ForEach(modelNames, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("diagnostics.softKeyEdgesModel")
            slider("Guaranteed press region", value: $centre, range: LocalFlowSettings.softKeyEdgesCentreRange, step: 0.05,
                   text: String(format: "%.0f%%", centre * 100), spoken: String(format: "%.0f percent", centre * 100),
                   identifier: "diagnostics.softKeyEdgesCentre")
            slider("Margin", value: $margin, range: LocalFlowSettings.softKeyEdgesMarginRange, step: 0.5,
                   text: String(format: "%g:1", margin), spoken: String(format: "%g to 1", margin),
                   identifier: "diagnostics.softKeyEdgesMargin")
            Toggle("Surprise gate", isOn: $gate)
                .accessibilityIdentifier("diagnostics.softKeyEdgesSurpriseGate")
            slider("Maximum surprise", value: $maxSurprise, range: LocalFlowSettings.softKeyEdgesMaxSurpriseRange, step: 0.25,
                   text: String(format: "%.2f bits", maxSurprise), spoken: String(format: "%.2f bits", maxSurprise),
                   identifier: "diagnostics.softKeyEdgesMaxSurprise")
                .disabled(!gate)
            Button("Reset to bundle defaults") {
                settings?.resetSoftKeyEdgesTuning()
                load()
            }
            .disabled(model == (manifest?.defaultModel ?? "67k") && centre == defaults.centre && margin == defaults.margin
                && gate && maxSurprise == defaults.maxSurprise)
            .accessibilityIdentifier("diagnostics.softKeyEdgesReset")
        } header: {
            Text("Soft key edges (experimental)")
        } footer: {
            Text("A tap near a key's edge may type the likelier neighbour, predicted from the text before the cursor; a tap inside the guaranteed press region (a share of the key's width and height) always types its key. The margin is the odds a neighbour needs. With the gate on, nothing is overridden while the recent text is more surprising than the maximum. Slider changes apply to the next tap; the switch and the model apply the next time the keyboard appears.")
        }
        .onAppear(perform: load)
        .onChange(of: enabled) { _, value in
            if value != settings?.softKeyEdgesEnabled { settings?.softKeyEdgesEnabled = value }
        }
        .onChange(of: model) { _, value in
            if value != resolvedModel { settings?.softKeyEdgesModel = value }
        }
        .onChange(of: centre) { _, value in
            if value != (settings?.softKeyEdgesCentre ?? defaults.centre) { settings?.softKeyEdgesCentre = value }
        }
        .onChange(of: margin) { _, value in
            if value != (settings?.softKeyEdgesMargin ?? defaults.margin) { settings?.softKeyEdgesMargin = value }
        }
        .onChange(of: gate) { _, value in
            if value != settings?.softKeyEdgesSurpriseGate { settings?.softKeyEdgesSurpriseGate = value }
        }
        .onChange(of: maxSurprise) { _, value in
            if value != (settings?.softKeyEdgesMaxSurprise ?? defaults.maxSurprise) { settings?.softKeyEdgesMaxSurprise = value }
        }
    }

    /// The settings as the keyboard reads them, over the bundle's defaults.
    private func load() {
        enabled = settings?.softKeyEdgesEnabled ?? false
        model = resolvedModel
        centre = settings?.softKeyEdgesCentre ?? defaults.centre
        margin = settings?.softKeyEdgesMargin ?? defaults.margin
        gate = settings?.softKeyEdgesSurpriseGate ?? true
        maxSurprise = settings?.softKeyEdgesMaxSurprise ?? defaults.maxSurprise
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String,
                        spoken: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: text)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(spoken)
                .accessibilityIdentifier(identifier)
        }
    }

    /// The `tap` section of the keyboard extension's swipe bundle (`Swipe/bundle.json` in the `.appex`).
    private static func bundledManifest() -> SoftKeyEdgesManifest? {
        bundledSwipeManifest { try? SoftKeyEdgesManifest.decode(from: $0) }
    }
}

/// The first section `decode` reads from a keyboard extension's swipe bundle (`Swipe/bundle.json` in the
/// `.appex`), or nil when this build has none.
private func bundledSwipeManifest<Section>(_ decode: (Data) -> Section??) -> Section? {
    guard let plugIns = Bundle.main.builtInPlugInsURL,
          let extensions = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
    else { return nil }
    for appex in extensions where appex.pathExtension == "appex" {
        let url = appex.appendingPathComponent("Swipe").appendingPathComponent("bundle.json")
        if let data = try? Data(contentsOf: url), let section = decode(data) ?? nil { return section }
    }
    return nil
}

/// Word autocorrect (App Group settings; ARCHITECTURE.md, "Word autocorrect"), for tuning on a device. The
/// keyboard reads the switch, model and preset when it appears, and the parameters at every word it commits.
/// Models, presets and their values come from the keyboard's bundle. Each slider shows the selected preset's
/// value merged with the user's overrides, as the keyboard reads it; only a slider that moves writes its
/// override, and the reset clears them all.
private struct AutocorrectSection: View {
    let settings: LocalFlowSettings?
    /// The keyboard's bundle section, or nil when this build has no word models. Read once per launch.
    private static let bundled = bundledSwipeManifest { try? AutocorrectManifest.decode(from: $0) }
    private var manifest: AutocorrectManifest? { Self.bundled }
    @State private var enabled = false
    @State private var model = ""
    @State private var preset = ""
    @State private var params = AutocorrectParams.standard
    @State private var hasOverrides = false
    /// Where the known-word and apostrophe margins' sliders return when their ∞ switch turns off.
    @State private var finiteKnown = 100.0
    @State private var finiteApostrophe = 100.0

    private static let fallbackModels = ["unigram", "ngram", "lstm"]
    private static let fallbackPresets = ["balanced", "conservative"]

    private var modelNames: [String] { manifest?.modelNames ?? Self.fallbackModels }

    private func presetNames(_ model: String) -> [String] { manifest?.presetNames(model: model) ?? Self.fallbackPresets }

    private var resolvedModel: String {
        manifest?.modelName(settings?.autocorrectModel) ?? settings?.autocorrectModel ?? Self.fallbackModels[1]
    }

    private func resolvedPreset(model: String) -> String {
        manifest?.presetName(settings?.autocorrectPreset, model: model) ?? settings?.autocorrectPreset ?? Self.fallbackPresets[0]
    }

    /// The selected preset's values, before the overrides.
    private var presetParams: AutocorrectParams {
        manifest?.params(model: model, preset: preset) ?? .standard
    }

    /// What the keyboard reads now: the overrides merged over the preset.
    private var merged: AutocorrectParams {
        settings?.autocorrectParams(over: presetParams) ?? presetParams
    }

    var body: some View {
        Section {
            Toggle("Autocorrect", isOn: $enabled)
                .accessibilityIdentifier("diagnostics.autocorrectEnabled")
            if manifest == nil {
                Text("This build has no word models; the keyboard types as before.").foregroundStyle(.secondary)
            }
            Picker("Model", selection: $model) {
                ForEach(modelNames, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("diagnostics.autocorrectModel")
            Picker("Preset", selection: $preset) {
                ForEach(presetNames(model), id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("diagnostics.autocorrectPreset")
            sliders
            Button("Reset to preset") {
                settings?.resetAutocorrectParams()
                load()
            }
            .disabled(!hasOverrides)
            .accessibilityIdentifier("diagnostics.autocorrectReset")
        } header: {
            Text("Autocorrect (experimental)")
        } footer: {
            Text("At space, Return or . , ! ? ; : the word before it may be replaced by a likelier one, from where your taps landed and the words before it. Delete right after a correction puts your word back, and it is not corrected again until the keyboard restarts. A margin is the odds a correction needs; at ∞ that kind is never replaced. The unknown-word probability is how likely a word outside the lexicon is. Repeat and slip weights split a stray letter between a doubled letter and a neighbour key. Sliders apply to the next word; the switch, model and preset the next time the keyboard appears. Needs Full Access. Words and taps stay in the keyboard's memory and are never stored or sent.")
        }
        .onAppear(perform: load)
        .onChange(of: enabled) { _, value in
            if value != settings?.autocorrectEnabled { settings?.autocorrectEnabled = value }
        }
        .onChange(of: model) { _, value in
            if value != resolvedModel { settings?.autocorrectModel = value }
            preset = resolvedPreset(model: value)
            showMerged()
        }
        .onChange(of: preset) { _, value in
            if value != resolvedPreset(model: model) { settings?.autocorrectPreset = value }
            showMerged()
        }
        .onChange(of: params) { _, value in write(value) }
    }

    @ViewBuilder private var sliders: some View {
        let ln10 = log(10.0)
        slider("Unknown word probability", value: binding(.logOOV, toSlider: { $0 / ln10 }, fromSlider: { $0 * ln10 }),
               range: -10 ... -1, step: 1, text: Self.powerOfTen(params.logOOV / ln10),
               identifier: "diagnostics.autocorrectLogOOV")
        slider("Margin, unknown word", value: binding(.marginOOV), range: AutocorrectSetting.marginOOV.range, step: 0.5,
               text: Self.odds(params.marginOOV), identifier: "diagnostics.autocorrectMarginOOV")
        infiniteMargin("Margin, known word", .marginKnown, finite: $finiteKnown, identifier: "diagnostics.autocorrectMarginKnown")
        infiniteMargin("Margin, apostrophe", .marginApostrophe, finite: $finiteApostrophe,
                       identifier: "diagnostics.autocorrectMarginApostrophe")
        slider("Word model weight", value: binding(.lmWeight), range: AutocorrectSetting.lmWeight.range, step: 0.05,
               text: String(format: "%.2f", params.lmWeight), identifier: "diagnostics.autocorrectLMWeight")
        logSlider("Omitted letter", .pOmit, identifier: "diagnostics.autocorrectPOmit")
        logSlider("Stray letter", .pInsert, identifier: "diagnostics.autocorrectPInsert")
        logSlider("Swapped letters", .pTranspose, identifier: "diagnostics.autocorrectPTranspose")
        slider("Repeat weight", value: weight(.wRepeat, other: .wSlip), range: 0 ... 1, step: 0.05,
               text: String(format: "%.2f", params.wRepeat), identifier: "diagnostics.autocorrectWRepeat")
        slider("Slip weight", value: weight(.wSlip, other: .wRepeat), range: 0 ... 1, step: 0.05,
               text: String(format: "%.2f", params.wSlip), identifier: "diagnostics.autocorrectWSlip")
        slider("Short word length", value: binding(.shortLength), range: AutocorrectSetting.shortLength.range, step: 1,
               text: "\(params.shortLength) letters", identifier: "diagnostics.autocorrectShortLength")
    }

    /// The settings as the keyboard reads them, over the bundle's presets.
    private func load() {
        enabled = settings?.autocorrectEnabled ?? false
        model = resolvedModel
        preset = resolvedPreset(model: model)
        showMerged()
    }

    /// Shows what the keyboard reads now; writes nothing (`write` finds no difference).
    private func showMerged() {
        let current = merged
        if current.marginKnown.isFinite { finiteKnown = current.marginKnown }
        if current.marginApostrophe.isFinite { finiteApostrophe = current.marginApostrophe }
        params = current
        hasOverrides = AutocorrectSetting.allCases.contains { settings?.autocorrectOverride($0) != nil }
    }

    /// Writes an override for each value a control moved away from what the keyboard reads.
    private func write(_ shown: AutocorrectParams) {
        guard let settings else { return }
        let current = merged
        for setting in AutocorrectSetting.allCases where setting.value(in: shown) != setting.value(in: current) {
            settings.setAutocorrectOverride(setting, setting.value(in: shown))
        }
        hasOverrides = AutocorrectSetting.allCases.contains { settings.autocorrectOverride($0) != nil }
    }

    /// A parameter on a slider: `toSlider` maps its value to the slider's scale (clamped into it for a preset
    /// outside the range), `fromSlider` back, clamped into the accepted range.
    private func binding(_ setting: AutocorrectSetting, toSlider: @escaping (Double) -> Double = { $0 },
                         fromSlider: @escaping (Double) -> Double = { $0 }) -> Binding<Double> {
        Binding(get: { toSlider(min(max(setting.value(in: params), setting.range.lowerBound), setting.range.upperBound)) },
                set: { value in
                    let range = setting.range
                    setting.set(min(max(fromSlider(value), range.lowerBound), range.upperBound), in: &params)
                })
    }

    /// One of the insertion weights; the other gives way so their sum stays at most 1.
    private func weight(_ setting: AutocorrectSetting, other: AutocorrectSetting) -> Binding<Double> {
        Binding(get: { setting.value(in: params) },
                set: { value in
                    let clamped = min(max(value, 0), 1)
                    setting.set(clamped, in: &params)
                    if clamped + other.value(in: params) > 1 { other.set(max(1 - clamped, 0), in: &params) }
                })
    }

    /// An edit probability on a log scale, 0.001 to 0.1.
    private func logSlider(_ title: String, _ setting: AutocorrectSetting, identifier: String) -> some View {
        slider(title, value: binding(setting, toSlider: { log10(max($0, 1e-300)) }, fromSlider: { pow(10, $0) }),
               range: log10(setting.range.lowerBound) ... log10(setting.range.upperBound), step: 0.05,
               text: String(format: "%.3g", setting.value(in: params)), identifier: identifier)
    }

    /// A margin from 1 to 1000 on a log scale, with an ∞ switch (never replace).
    @ViewBuilder
    private func infiniteMargin(_ title: String, _ setting: AutocorrectSetting, finite: Binding<Double>,
                                identifier: String) -> some View {
        let infinite = setting.value(in: params) == .infinity
        slider(title, value: Binding(get: { log10(min(max(infinite ? finite.wrappedValue : setting.value(in: params), 1), 1000)) },
                                     set: { value in
                                         let odds = min(max(pow(10, value), setting.range.lowerBound), setting.range.upperBound)
                                         finite.wrappedValue = odds
                                         setting.set(odds, in: &params)
                                     }),
               range: 0 ... 3, step: 0.05, text: Self.odds(setting.value(in: params)), identifier: identifier)
            .disabled(infinite)
        Toggle("\(title): ∞", isOn: Binding(get: { setting.value(in: params) == .infinity },
                                             set: { on in setting.set(on ? .infinity : finite.wrappedValue, in: &params) }))
            .accessibilityIdentifier(identifier + "Infinite")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String,
                        identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: text)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityIdentifier(identifier)
        }
    }

    /// Posterior odds, e.g. "3:1", "250:1" or "∞".
    private static func odds(_ value: Double) -> String {
        value.isFinite ? String(format: value < 10 ? "%.3g:1" : "%.0f:1", value) : "∞"
    }

    /// A power of ten, e.g. "1e-5" (one decimal for a preset between whole powers).
    private static func powerOfTen(_ exponent: Double) -> String {
        String(format: "1e%g", (exponent * 10).rounded() / 10)
    }
}

/// The TestFlight typing counters (ARCHITECTURE.md, "Dropped taps: reach, skids and counters"): the
/// keyboard counts while the switch is on and adds its counts when it hides. Counts only. Remove before
/// the first production release.
private struct TypingCountersSection: View {
    let settings: LocalFlowSettings?
    @State private var enabled = false
    @State private var counters = TypingCounters()

    private static let titles: [(TypingCounters.Event, String)] = [
        (.touchDown, "Touch-downs"), (.aboveKeys, "Above the keys"), (.late16, "Late ≥ 16 ms"), (.late50, "Late ≥ 50 ms"),
        (.late100, "Late ≥ 100 ms"), (.cancelled, "Cancelled by iOS"), (.ignored, "Ignored during a swipe"),
        (.swipe, "Became a swipe"), (.skid, "Skid typed as a tap"), (.swipeEmpty, "Swipe typed nothing"),
        (.softTap, "Soft taps"), (.softLetter, "Soft tap: other letter"), (.softSpace, "Soft tap: space"),
        (.wordChecked, "Words checked"), (.wordCorrected, "Words corrected"), (.wordReverted, "Corrections reverted"),
    ]
    /// Events without a position (`TypingCounters.wordRegions`): only their total is shown.
    private static let unplaced: Set<TypingCounters.Event> = [.wordChecked, .wordCorrected, .wordReverted]
    private static let regions: [(TypingCounters.Region, String)] = [
        (.row1, "Top"), (.row2, "2nd"), (.row3, "3rd"), (.row4, "Bottom"), (.left, "Left"), (.right, "Right"),
    ]

    var body: some View {
        Section {
            Toggle("Count typing events", isOn: $enabled)
                .accessibilityIdentifier("diagnostics.typingCountersEnabled")
            NavigationLink("Typing test") { TypingTestView(settings: settings) }
                .accessibilityIdentifier("diagnostics.typingTest")
            ForEach(Self.titles, id: \.0) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(entry.1, value: "\(counters.total(entry.0))")
                    if !Self.unplaced.contains(entry.0) {
                        Text(Self.regions.map { "\($0.1) \(counters[entry.0, $0.0])" }.joined(separator: " · "))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button("Refresh", action: load)
                .accessibilityIdentifier("diagnostics.typingCountersRefresh")
            Button("Reset counts", role: .destructive) {
                settings?.resetTypingCounters()
                load()
            }
            .disabled(counters.isEmpty)
            .accessibilityIdentifier("diagnostics.typingCountersReset")
        } header: {
            Text("Typing counters (TestFlight)")
        } footer: {
            Text("Counts only, by the row and edge of the nearest key: never text, keys, positions or times. They stay on this iPhone until reset. The switch applies the next time the keyboard appears; the keyboard adds its counts when it hides and every 50 events. Needs Full Access.")
        }
        .onAppear(perform: load)
        .onChange(of: enabled) { _, value in
            if value != settings?.typingCountersEnabled { settings?.typingCountersEnabled = value }
        }
    }

    private func load() {
        enabled = settings?.typingCountersEnabled ?? false
        counters = settings?.typingCounters ?? TypingCounters()
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
