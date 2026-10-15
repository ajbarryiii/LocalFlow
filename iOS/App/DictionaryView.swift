import SwiftUI

/// The custom dictionary (contract: "Custom dictionary"): words with their strength, ▲/▼ arrows that save
/// at once, and "Find strength" from one spoken sentence. Entries are never logged.
struct DictionaryView: View {
    @ObservedObject var dictionary: DictionaryModel
    @State private var editor: EditorTarget?
    @State private var probe: ProbeTarget?
    @State private var confirmingReset = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if dictionary.loadFailed {
                recoverySection
            } else {
                entriesSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = EditorTarget(original: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!dictionary.canEdit || dictionary.isFull)
                .accessibilityLabel("Add word")
                .accessibilityIdentifier("dictionary.add")
            }
        }
        .sheet(item: $editor) { target in
            DictionaryEntryEditor(dictionary: dictionary, original: target.original)
        }
        .sheet(item: $probe) { target in
            StrengthProbeSheet(word: target.word, current: target.strength) { strength in
                errorMessage = dictionary.setStrength(strength, for: target.key)
            }
        }
        .alert("Couldn't change the word", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .tint(Theme.violet)
    }

    private var entriesSection: some View {
        Section {
            if dictionary.entries.isEmpty {
                Text("No words yet. Add names, jargon or product terms that are often misheard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(dictionary.entries, id: \.key) { entry in
                row(entry)
            }
        } header: {
            Text("Names and terms LocalFlow should recognize. Boosting happens entirely on this iPhone.")
                .textCase(nil)
                .font(.footnote)
        } footer: {
            if !dictionary.hasVocabulary {
                Text(DictionaryEditor.unavailableMessage).foregroundStyle(.red)
            } else {
                let up = Text(Image(systemName: "arrow.up")).fontWeight(.bold).foregroundStyle(.green)
                let down = Text(Image(systemName: "arrow.down")).fontWeight(.bold).foregroundStyle(.red)
                let mic = Text(Image(systemName: "mic.fill")).foregroundStyle(Theme.violet)
                Text("\(up) if a word is still misheard, \(down) if it appears where it shouldn't. \(mic) Say a sentence with the word and LocalFlow picks the strength. Tap a word to edit it; swipe to delete.")
            }
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                editor = EditorTarget(original: entry)
            } label: {
                Text(entry.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!dictionary.canEdit)
            StrengthArrows(strength: entry.strength, isEnabled: dictionary.canEdit) { strength in
                errorMessage = dictionary.setStrength(strength, for: entry.key)
            }
            Divider().frame(height: 22)
            Button {
                probe = ProbeTarget(key: entry.key, word: entry.text, strength: entry.strength)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.violet)
                    .frame(width: 32, height: 32)
                    .background(Theme.violet.opacity(0.15), in: Circle())
            }
            .buttonStyle(.borderless)
            .disabled(!dictionary.canEdit)
            .accessibilityLabel("Find strength with my voice")
        }
        .swipeActions {
            Button(role: .destructive) {
                dictionary.remove(entry.key)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!dictionary.canEdit)
        }
    }

    private var recoverySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("The saved dictionary couldn't be read", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Boosting is off until it is reset. The saved data is kept unchanged until you choose Reset.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button("Reset Dictionary…", role: .destructive) { confirmingReset = true }
                .confirmationDialog("Reset the saved dictionary?", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { dictionary.reset() }
                } message: {
                    Text("This removes the saved words.")
                }
        }
    }

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let original: DictionaryEntry?
    }

    private struct ProbeTarget: Identifiable {
        let id = UUID()
        let key: DictionaryKey
        let word: String
        let strength: Float
    }
}

/// ▼ strength ▲: one preset down or up (`DictionaryLibrary.strength(below:)`/`(above:)`), disabled at
/// either end.
struct StrengthArrows: View {
    let strength: Float
    var isEnabled = true
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 2) {
            arrow("arrow.down", tint: .red, to: DictionaryLibrary.strength(below: strength), label: "Lower strength")
            Text(DictionaryValidation.label(strength))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
                .accessibilityLabel("Strength \(DictionaryValidation.label(strength))")
            arrow("arrow.up", tint: .green, to: DictionaryLibrary.strength(above: strength), label: "Raise strength")
        }
    }

    private func arrow(_ symbol: String, tint: Color, to target: Float?, label: String) -> some View {
        let enabled = isEnabled && target != nil
        return Button {
            if let target { onChange(target) }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}

/// Add or edit a word: its text and strength, saved together.
struct DictionaryEntryEditor: View {
    @ObservedObject var dictionary: DictionaryModel
    let original: DictionaryEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var strength = DictionaryValidation.defaultStrength
    @State private var saveError: String?
    @State private var probeWord: ProbeWord?

    private var isBlank: Bool { text.unicodeScalars.allSatisfy(DictionaryText.isWhitespace) }
    private var validationError: String? { dictionary.validationMessage(text: text, strength: strength) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Kubernetes", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("dictionary.word")
                } header: {
                    Text("Word or phrase")
                } footer: {
                    if let message = saveError ?? validationError {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Type it exactly as it should appear, up to \(DictionaryValidation.maxWords) words.")
                    }
                }

                Section {
                    HStack {
                        Text("Strength")
                        Spacer()
                        StrengthArrows(strength: strength) { strength = $0 }
                    }
                    Button {
                        probeWord = ProbeWord(text: DictionaryValidation.normalize(text))
                    } label: {
                        Label("Find strength with my voice", systemImage: "mic.fill")
                    }
                    .disabled(isBlank || validationError != nil || !dictionary.canEdit)
                } header: {
                    Text("Strength")
                } footer: {
                    Text("Say a sentence that uses the word. LocalFlow tries each strength and keeps the lowest one that gets it right. The recording stays in memory and is discarded right after.")
                }
            }
            .navigationTitle(original == nil ? "Add Word" : "Edit Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveError = dictionary.save(text: text, strength: strength, replacing: original?.key)
                        if saveError == nil { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isBlank || validationError != nil || !dictionary.canEdit)
                }
            }
            .sheet(item: $probeWord) { word in
                StrengthProbeSheet(word: word.text, current: strength) { strength = $0 }
            }
        }
        .tint(Theme.violet)
        .onAppear {
            if let original {
                text = original.text
                strength = original.strength
            }
        }
        .onChange(of: text) { saveError = nil }
    }

    private struct ProbeWord: Identifiable {
        let id = UUID()
        let text: String
    }
}

/// "Find strength": record one sentence with the word, then offer the lowest strength that produced it.
/// Nothing changes until "Use ×n".
struct StrengthProbeSheet: View {
    @EnvironmentObject private var host: HostSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: StrengthProbeModel
    let current: Float
    let onUse: (Float) -> Void

    init(word: String, current: Float, onUse: @escaping (Float) -> Void) {
        _model = StateObject(wrappedValue: StrengthProbeModel(word: word))
        self.current = current
        self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Find Strength")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Theme.violet)
        .onAppear { model.start(host: host) }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) {
            if scenePhase != .active { model.leftForeground() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting:
            Spacer()
            ProgressView()
            Text("Starting the microphone…").font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
            Spacer()
            sessionNote
        case .recording:
            recording
        case .checking:
            Spacer()
            ProgressView()
            Text(host.transcriber.modelState == .ready ? "Checking…" : "Preparing the model…")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
            Spacer()
            sessionNote
        case .finished(let result):
            finished(result)
        case .failed(let message):
            Spacer()
            outcomeHeader(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't check", subtitle: message)
            Spacer()
            Button("Try again") { model.retry() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 10)
        case .microphoneDenied:
            Spacer()
            outcomeHeader(symbol: "mic.slash.fill", tint: .orange, title: "Microphone access is off",
                          subtitle: "Allow LocalFlow to use the microphone in Settings to find a strength with your voice.")
            Spacer()
            Button("Open Settings") { AppIdentity.openSettings() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 10)
        }
    }

    private var recording: some View {
        VStack(spacing: 0) {
            Text("Say a sentence with").font(.subheadline).foregroundStyle(.secondary).padding(.top, 28)
            Text(model.word)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 4)
            LevelBars(level: model.level).padding(.top, 40)
            Label("Listening", systemImage: "circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.live)
                .labelStyle(DotLabelStyle())
                .padding(.top, 10)
            Text("Up to \(Int(VoiceSampleRecorder.maxDuration)) seconds. For example: “I use \(model.word) every day.”")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            sessionNote
            Button("Done") { model.done() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("dictionary.probe.done")
        }
    }

    @ViewBuilder
    private var sessionNote: some View {
        if model.pausedSession {
            Text("Your Flow session is paused while you record and starts again when you close this.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func finished(_ result: StrengthProbe.Result) -> some View {
        switch result.outcome {
        case .recognized(let strength):
            outcomeHeader(symbol: "checkmark", tint: .green, title: "Recognized at \(DictionaryValidation.label(strength))",
                          subtitle: "The lowest strength that got it right")
            comparison(base: result.base, boosted: result.boosted, strength: strength)
            if strength != current {
                HStack(spacing: 10) {
                    Text(DictionaryValidation.label(current)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(DictionaryValidation.label(strength)).fontWeight(.bold).foregroundStyle(.green)
                }
                .font(.title3.monospacedDigit())
                .padding(.top, 16)
            }
            Spacer()
            if strength != current {
                Button("Use \(DictionaryValidation.label(strength))") {
                    onUse(strength)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Keep \(DictionaryValidation.label(current))") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 10)
            } else {
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
            tryAnother
        case .alreadyRecognized:
            outcomeHeader(symbol: "checkmark", tint: .green, title: "Already recognized",
                          subtitle: "LocalFlow heard it without a boost, so \(DictionaryValidation.label(current)) is fine.")
            comparison(base: result.base, boosted: nil, strength: nil)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            tryAnother
        case .notRecognized where result.base.isEmpty:
            outcomeHeader(symbol: "waveform.slash", tint: .orange, title: "Nothing was heard",
                          subtitle: "Try again and say the sentence aloud.")
            Spacer()
            Button("Try again") { model.retry() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 10)
        case .notRecognized:
            outcomeHeader(symbol: "xmark", tint: .orange,
                          title: "Not recognized, even at \(DictionaryValidation.label(DictionaryValidation.maxStrength))",
                          subtitle: "Check the spelling, or try a sentence where the word is clearer.")
            comparison(base: result.base, boosted: nil, strength: nil)
            Spacer()
            Button("Try another sentence") { model.retry() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 10)
        }
    }

    private var tryAnother: some View {
        Button("Try another sentence") { model.retry() }
            .font(.subheadline)
            .padding(.top, 14)
    }

    private func outcomeHeader(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
                .background(tint.opacity(0.18), in: Circle())
                .padding(.bottom, 6)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    /// What was heard without the word and, when found, at the chosen strength with the word highlighted.
    private func comparison(base: String, boosted: String?, strength: Float?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Without boost").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(base.isEmpty ? "—" : base).font(.body)
            if let boosted, let strength {
                Text("At \(DictionaryValidation.label(strength))").font(.caption).foregroundStyle(.secondary)
                    .textCase(.uppercase).padding(.top, 8)
                Text(highlighted(boosted)).font(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 18)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: model.word, options: .caseInsensitive) {
            attributed[range].foregroundColor = .green
            attributed[range].font = .body.bold()
            searchStart = range.upperBound
        }
        return attributed
    }
}

/// A small dot before the title, as the recording indicator elsewhere in the app.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}
