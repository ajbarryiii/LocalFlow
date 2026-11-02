import SwiftUI

/// The custom dictionary (contract: "Custom dictionary"): words with their strength, ▲/▼ arrows that save
/// at once, and "Find strength" from one spoken sentence. Entries are never logged.
struct DictionaryView: View {
    @ObservedObject var dictionary: DictionaryModel
    @State private var editor: EditorTarget?
    @State private var probe: ProbeTarget?
    @State private var confirmingReset = false
    @State private var errorMessage: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        List {
            if dictionary.loadFailed {
                recoverySection
            } else {
                entriesSection
            }
        }
        .listStyle(.insetGrouped)
        .themedListBackground()
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
        .alert("Couldn’t change the word", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .tint(.white)
    }

    private var entriesSection: some View {
        Section {
            if dictionary.entries.isEmpty {
                Button {
                    editor = EditorTarget(original: nil)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "plus").accessibilityHidden(true)
                        Text("Add names and terms that get misheard.")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!dictionary.canEdit || dictionary.isFull)
            }
            ForEach(dictionary.entries, id: \.key) { entry in
                row(entry)
            }
        } footer: {
            if !dictionary.hasVocabulary {
                Text(DictionaryEditor.unavailableMessage).foregroundStyle(Theme.coral)
            } else if !dictionary.entries.isEmpty {
                // A legend for the row's glyphs, a few words each.
                let up = Text(Image(systemName: "arrow.up")).fontWeight(.bold).foregroundStyle(Theme.aurora)
                let down = Text(Image(systemName: "arrow.down")).fontWeight(.bold).foregroundStyle(Theme.coral)
                let mic = Text(Image(systemName: "mic"))
                Text("\(up)\u{00A0}still\u{00A0}misheard   \(down)\u{00A0}shows\u{00A0}up\u{00A0}wrongly   \(mic)\u{00A0}find\u{00A0}by\u{00A0}voice")
            }
        }
        .listRowBackground(Theme.cardBackground)
    }

    /// The word, then its strength and "Find strength"; at accessibility sizes the word has its own line.
    private func row(_ entry: DictionaryEntry) -> some View {
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Button {
                editor = EditorTarget(original: entry)
            } label: {
                Text(entry.text)
                    .lineLimit(large ? 3 : 1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!dictionary.canEdit)
            HStack(spacing: 4) {
                StrengthArrows(strength: entry.strength, isEnabled: dictionary.canEdit) { strength in
                    errorMessage = dictionary.setStrength(strength, for: entry.key)
                }
                Divider().frame(height: 22)
                Button {
                    probe = ProbeTarget(key: entry.key, word: entry.text, strength: entry.strength)
                } label: {
                    Image(systemName: "mic")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!dictionary.canEdit)
                .opacity(dictionary.canEdit ? 1 : 0.3)
                .accessibilityLabel("Find strength with my voice")
            }
            .fixedSize()
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
                Label("The saved dictionary couldn’t be read", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ember)
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
        .listRowBackground(Theme.cardBackground)
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
            arrow("arrow.down", tint: Theme.coral, to: DictionaryLibrary.strength(below: strength), label: "Lower strength")
            Text(DictionaryValidation.label(strength))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 40)
                .accessibilityLabel("Strength \(DictionaryValidation.label(strength))")
            arrow("arrow.up", tint: Theme.aurora, to: DictionaryLibrary.strength(above: strength), label: "Raise strength")
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
                .frame(minWidth: 44, minHeight: 44)
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
    private var canProbe: Bool { !isBlank && validationError == nil && dictionary.canEdit }

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
                        Text(message).foregroundStyle(Theme.coral)
                    } else {
                        Text("Type it exactly as it should appear, up to \(DictionaryValidation.maxWords) words.")
                    }
                }
                .listRowBackground(Theme.cardBackground)

                Section {
                    HStack {
                        Text("Strength")
                        Spacer()
                        StrengthArrows(strength: strength) { strength = $0 }
                    }
                    Button {
                        probeWord = ProbeWord(text: DictionaryValidation.normalize(text))
                    } label: {
                        Label("Find strength with my voice", systemImage: "mic")
                            .foregroundStyle(canProbe ? Color.white : Color.white.opacity(0.3))
                    }
                    .disabled(!canProbe)
                } header: {
                    Text("Strength")
                } footer: {
                    Text("Say a sentence with the word; LocalFlow keeps the lowest strength that gets it right. The recording is discarded right after.")
                }
                .listRowBackground(Theme.cardBackground)
            }
            .themedListBackground()
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
        .tint(.white)
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
/// Nothing changes until "Use ×n". Its words scroll at large text; its actions stay at the bottom.
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
            ScrollView {
                info
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    sessionNote
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .actionBarBackground()
            }
            .background(Theme.screenBackground.ignoresSafeArea())
            .navigationTitle("Find Strength")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(.white)
        .onAppear { model.start(host: host) }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) {
            // Only leaving the screen: iOS's microphone prompt makes the scene inactive, not backgrounded.
            if scenePhase == .background { model.leftForeground() }
        }
    }

    // MARK: Words

    @ViewBuilder
    private var info: some View {
        switch model.phase {
        case .starting:
            waiting("Starting the microphone…")
        case .recording:
            recording
        case .checking:
            waiting(host.transcriber.modelState == .ready ? "Checking…" : "Preparing the model…")
        case .finished(let result):
            finished(result)
        case .failed(let message):
            outcomeHeader(symbol: "exclamationmark.triangle", tint: Theme.ember, title: "Couldn’t check", subtitle: message)
        case .microphoneDenied:
            outcomeHeader(symbol: "mic.slash", tint: Theme.ember, title: "Microphone access is off",
                          subtitle: "Allow the microphone in Settings.")
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(Theme.secondaryInk)
        }
        .padding(.top, 60)
    }

    private var recording: some View {
        VStack(spacing: 0) {
            Text("Say a sentence with").font(.subheadline).foregroundStyle(Theme.secondaryInk).padding(.top, 20)
            Text(model.word)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 4)
            IslandWave(level: model.level, live: true, accent: Theme.coral)
                .frame(height: 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: 300, minHeight: 56)
                .islandSurface()
                .padding(.top, 32)
            Text("For example: “I use \(model.word) every day.”")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening. Say a sentence with \(model.word), up to \(Int(VoiceSampleRecorder.maxDuration)) seconds.")
    }

    @ViewBuilder
    private var sessionNote: some View {
        if model.pausedSession, model.phase == .starting || model.phase == .recording || model.phase == .checking {
            Label("Session paused", systemImage: "pause.circle")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
                .accessibilityLabel("Your Flow session is paused while you record and starts again when you close this.")
        }
    }

    @ViewBuilder
    private func finished(_ result: StrengthProbe.Result) -> some View {
        switch result.outcome {
        case .recognized(let strength):
            VStack(spacing: 0) {
                outcomeHeader(symbol: "checkmark", tint: Theme.aurora, title: "Recognized at \(DictionaryValidation.label(strength))",
                              subtitle: "The lowest strength that got it right")
                comparison(base: result.base, boosted: result.boosted, strength: strength)
                if strength != current {
                    HStack(spacing: 10) {
                        Text(DictionaryValidation.label(current)).foregroundStyle(Theme.secondaryInk)
                        Image(systemName: "arrow.right").foregroundStyle(Theme.secondaryInk)
                        Text(DictionaryValidation.label(strength)).fontWeight(.bold)
                    }
                    .font(.title3.monospacedDigit())
                    .padding(.top, 16)
                }
            }
        case .alreadyRecognized:
            VStack(spacing: 0) {
                outcomeHeader(symbol: "checkmark", tint: Theme.aurora, title: "Already recognized",
                              subtitle: "LocalFlow heard it without a boost, so \(DictionaryValidation.label(current)) is fine.")
                comparison(base: result.base, boosted: nil, strength: nil)
            }
        case .notRecognized where result.base.isEmpty:
            outcomeHeader(symbol: "waveform.slash", tint: Theme.ember, title: "Nothing was heard",
                          subtitle: "Try again and say the sentence aloud.")
        case .notRecognized:
            VStack(spacing: 0) {
                outcomeHeader(symbol: "xmark", tint: Theme.ember,
                              title: "Not recognized, even at \(DictionaryValidation.label(DictionaryValidation.maxStrength))",
                              subtitle: "Check the spelling, or try a sentence where the word is clearer.")
                comparison(base: result.base, boosted: nil, strength: nil)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .starting, .checking:
            EmptyView()
        case .recording:
            Button("Done") { model.done() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("dictionary.probe.done")
        case .failed:
            Button("Try again") { model.retry() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        case .microphoneDenied:
            Button("Open Settings") { AppIdentity.openSettings() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        case .finished(let result):
            switch result.outcome {
            case .recognized(let strength) where strength != current:
                Button("Use \(DictionaryValidation.label(strength))") {
                    onUse(strength)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Keep \(DictionaryValidation.label(current))") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                tryAnother
            case .recognized, .alreadyRecognized:
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                tryAnother
            case .notRecognized where result.base.isEmpty:
                Button("Try again") { model.retry() }.buttonStyle(PrimaryButtonStyle())
                Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            case .notRecognized:
                Button("Try another sentence") { model.retry() }.buttonStyle(PrimaryButtonStyle())
                Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var tryAnother: some View {
        Button("Try another sentence") { model.retry() }
            .buttonStyle(SecondaryButtonStyle())
    }

    private func outcomeHeader(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondaryInk).multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    /// What was heard without the word and, when found, at the chosen strength with the word highlighted.
    private func comparison(base: String, boosted: String?, strength: Float?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Without boost").font(.caption).foregroundStyle(Theme.secondaryInk).textCase(.uppercase)
            Text(base.isEmpty ? "—" : base).font(.body)
            if let boosted, let strength {
                Text("At \(DictionaryValidation.label(strength))").font(.caption).foregroundStyle(Theme.secondaryInk)
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
            attributed[range].foregroundColor = Theme.aurora
            attributed[range].font = .body.bold()
            searchStart = range.upperBound
        }
        return attributed
    }
}
