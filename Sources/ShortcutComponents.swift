import SwiftUI
import AppKit

struct DictationShortcutEditor: View {
    @EnvironmentObject var appState: AppState

    let showsIntroText: Bool
    let showsPromptShortcut: Bool
    let onCaptureStateChange: ((Bool) -> Void)?

    @State private var activeCaptureRole: ShortcutRole?
    @State private var holdValidationMessage: String?
    @State private var toggleValidationMessage: String?
    @State private var copyAgainValidationMessage: String?
    @State private var promptValidationMessage: String?

    init(showsIntroText: Bool = true, showsPromptShortcut: Bool = false,
         onCaptureStateChange: ((Bool) -> Void)? = nil) {
        self.showsIntroText = showsIntroText
        self.showsPromptShortcut = showsPromptShortcut
        self.onCaptureStateChange = onCaptureStateChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsIntroText {
                Text("Hold to record, tap to start and stop, and press the toggle shortcut while holding to latch into tap mode. You can disable either workflow or turn both shortcuts off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.holdShortcut.isDisabled && appState.toggleShortcut.isDisabled {
                Label("Both dictation shortcuts are disabled.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ShortcutRoleSection(
                role: .hold,
                selection: appState.holdShortcut,
                validationMessage: holdValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .hold },
                    set: { activeCaptureRole = $0 ? .hold : nil }
                ),
                onSelect: { binding in
                    holdValidationMessage = appState.setShortcut(binding, for: .hold)
                }
            )

            ShortcutRoleSection(
                role: .toggle,
                selection: appState.toggleShortcut,
                validationMessage: toggleValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .toggle },
                    set: { activeCaptureRole = $0 ? .toggle : nil }
                ),
                onSelect: { binding in
                    toggleValidationMessage = appState.setShortcut(binding, for: .toggle)
                }
            )

            ShortcutRoleSection(
                role: .copyAgain,
                selection: appState.copyAgainShortcut,
                validationMessage: copyAgainValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .copyAgain },
                    set: { activeCaptureRole = $0 ? .copyAgain : nil }
                ),
                onSelect: { binding in
                    copyAgainValidationMessage = appState.setShortcut(binding, for: .copyAgain)
                }
            )

            if showsPromptShortcut {
                ShortcutRoleSection(
                    role: .prompt,
                    selection: appState.promptShortcut,
                    validationMessage: promptValidationMessage,
                    isCapturing: Binding(
                        get: { activeCaptureRole == .prompt },
                        set: { activeCaptureRole = $0 ? .prompt : nil }
                    ),
                    onSelect: { binding in
                        promptValidationMessage = appState.setShortcut(binding, for: .prompt)
                    }
                )
                PromptTagField()
            }

            Text("Custom shortcuts can use regular keys, modifier-only shortcuts, or modifier combinations.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.usesFnShortcut {
                Text("Tip: If Fn opens the Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: activeCaptureRole) { role in
            onCaptureStateChange?(role != nil)
        }
        .onDisappear {
            onCaptureStateChange?(false)
        }
    }
}

struct ShortcutRoleSection: View {
    @EnvironmentObject var appState: AppState
    let role: ShortcutRole
    let selection: ShortcutBinding
    let validationMessage: String?
    @Binding var isCapturing: Bool
    let onSelect: (ShortcutBinding) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role.title)
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 6) {
                ShortcutPresetRow(
                    title: "Disabled",
                    isSelected: selection.isDisabled,
                    action: { onSelect(.disabled) }
                )

                ForEach(ShortcutPreset.allCases) { preset in
                    ShortcutPresetRow(
                        title: preset.title,
                        isSelected: selection == preset.binding,
                        action: { onSelect(preset.binding) }
                    )
                }

                ShortcutCaptureRow(
                    savedBinding: appState.savedCustomShortcut(for: role),
                    isSelected: selection.isCustom,
                    isCapturing: $isCapturing,
                    onSelectSaved: onSelect,
                    onCapture: onSelect
                )
            }

            if let validationMessage, !validationMessage.isEmpty {
                Label(validationMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Edits the tag placed before prompt dictations. Commits on Return or focus loss, not per keystroke,
/// so typing does not republish app state. An empty tag restores the default.
private struct PromptTagField: View {
    @EnvironmentObject var appState: AppState
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt tag")
                TextField(AppState.defaultPromptTag, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit(commit)
            }
            Text("Hold to dictate a prompt for an AI agent: \(appState.promptTag) is added before the text so the agent knows it came from speech-to-text. Pressing it during any recording tags that recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tell agents how to read \(appState.promptTag) messages, such as expecting misheard words and following self-corrections, in your global AGENTS.md or CLAUDE.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { text = appState.promptTag }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = trimmed.isEmpty ? AppState.defaultPromptTag : trimmed
        text = tag
        if appState.promptTag != tag {
            appState.promptTag = tag
        }
    }
}

private struct ShortcutPresetRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutCaptureRow: View {
    let savedBinding: ShortcutBinding?
    let isSelected: Bool
    @Binding var isCapturing: Bool
    let onSelectSaved: (ShortcutBinding) -> Void
    let onCapture: (ShortcutBinding) -> Void

    @State private var captureBackend: LocalShortcutCaptureBackend?
    @State private var captureInputState = ShortcutInputState()
    @State private var currentBinding: ShortcutBinding?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    if let savedBinding {
                        onSelectSaved(savedBinding)
                    } else if !isCapturing {
                        startCapture()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : (savedBinding == nil ? "plus.circle" : "circle"))
                            .foregroundStyle(isSelected ? .blue : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayedBindingName)
                                .font(displayedBindingUsesMonospace ? .system(.body, design: .monospaced).weight(.semibold) : .body)
                                .foregroundStyle(.primary)
                            Text(displayedBindingSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)

                Button(isCapturing ? "Done" : "Record…") {
                    if isCapturing {
                        finishCapture()
                    } else {
                        startCapture()
                    }
                }
                .buttonStyle(.bordered)

                if isCapturing {
                    Button("Cancel") {
                        cancelCapture()
                    }
                    .buttonStyle(.plain)
                }
            }

            if isCapturing {
                Label(
                    currentBinding == nil
                        ? "Press and hold the shortcut you want."
                        : "Press Esc or Enter to save.",
                    systemImage: "keyboard"
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .onDisappear {
            stopCapture(clearCaptureState: true)
        }
    }

    private func startCapture() {
        stopCapture(clearCaptureState: false)
        isCapturing = true
        captureInputState = ShortcutInputState()
        currentBinding = nil

        let backend = LocalShortcutCaptureBackend()
        backend.onInputEvent = { inputEvent in
            let result = ShortcutMatcher.reduce(
                state: captureInputState,
                event: inputEvent,
                configuration: .disabled
            )
            captureInputState = result.state

            guard case .modifierChanged(let keyCode, _) = inputEvent else { return }
            if let binding = ShortcutBinding.fromModifierKeyCode(
                keyCode,
                pressedModifierKeyCodes: captureInputState.pressedModifierKeyCodes,
                allowBareModifier: true
            ) {
                currentBinding = binding
            }
        }
        backend.onKeyDownEvent = { event in
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            let hasPendingCapture = currentBinding != nil

            if isReturnKey && hasPendingCapture {
                finishCapture()
                return
            }
            if event.keyCode == 53 && hasPendingCapture {
                finishCapture()
                return
            }

            guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else {
                return
            }

            guard let binding = ShortcutBinding.from(
                event: event,
                pressedModifierKeyCodes: captureInputState.pressedModifierKeyCodes
            ) else {
                return
            }

            currentBinding = binding
        }
        backend.start()
        captureBackend = backend
    }

    private func finishCapture() {
        guard let currentBinding else {
            cancelCapture()
            return
        }
        onCapture(currentBinding)
        stopCapture(clearCaptureState: true)
    }

    private func cancelCapture() {
        stopCapture(clearCaptureState: true)
    }

    private func stopCapture(clearCaptureState: Bool) {
        captureBackend?.stop()
        captureBackend = nil
        captureInputState = ShortcutInputState()
        currentBinding = nil
        if clearCaptureState {
            isCapturing = false
        }
    }

    private var displayedBindingName: String {
        if let currentBinding {
            currentBinding.displayName
        } else if let savedBinding {
            savedBinding.displayName
        } else {
            "Custom Shortcut"
        }
    }

    private var displayedBindingSubtitle: String {
        if isCapturing {
            return currentBinding == nil ? "Recording shortcut…" : "Recorded shortcut"
        }
        return savedBinding == nil ? "Record any key combo." : "Saved custom shortcut"
    }

    private var displayedBindingUsesMonospace: Bool {
        currentBinding != nil || savedBinding != nil
    }
}
