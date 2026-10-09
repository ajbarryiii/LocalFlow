import Foundation

enum DictationShortcutAction: Equatable {
    case start(RecordingTriggerMode)
    case stop
    case switchedToToggle
}

final class DictationShortcutSessionController {
    private(set) var activeMode: RecordingTriggerMode?
    private(set) var toggleStopArmed = false
    /// Whether the latest session should be tagged as a prompt. It survives `reset()` so the
    /// session can still be read while it is being transcribed; the next session start replaces it.
    private(set) var isPromptSession = false
    /// A hold session started by the prompt shortcut stops when that shortcut is released.
    private var promptStartedHold = false

    func handle(event: ShortcutEvent, isTranscribing: Bool) -> DictationShortcutAction? {
        // Paste Again is handled before this controller runs; if it ever
        // reaches here, treat as a no-op so dictation state is unaffected.
        if event == .copyAgainTriggered { return nil }

        if activeMode == nil {
            guard !isTranscribing else { return nil }
            switch event {
            case .toggleActivated:
                begin(.toggle, prompt: false)
                return .start(.toggle)
            case .holdActivated:
                begin(.hold, prompt: false)
                return .start(.hold)
            case .promptActivated:
                begin(.hold, prompt: true)
                promptStartedHold = true
                return .start(.hold)
            case .holdDeactivated, .toggleDeactivated, .promptDeactivated:
                return nil
            case .copyAgainTriggered:
                return nil
            }
        }

        guard let mode = activeMode else { return nil }

        // Pressing the prompt shortcut during any recording tags that recording.
        if event == .promptActivated {
            isPromptSession = true
            return nil
        }

        switch mode {
        case .hold:
            switch event {
            case .toggleActivated:
                activeMode = .toggle
                toggleStopArmed = false
                return .switchedToToggle
            case .holdDeactivated where !promptStartedHold, .promptDeactivated where promptStartedHold:
                reset()
                return .stop
            case .holdActivated, .holdDeactivated, .toggleDeactivated, .promptActivated, .promptDeactivated:
                return nil
            case .copyAgainTriggered:
                return nil
            }

        case .toggle:
            switch event {
            case .toggleDeactivated:
                toggleStopArmed = true
                return nil
            case .toggleActivated:
                guard toggleStopArmed else { return nil }
                reset()
                return .stop
            case .holdActivated, .holdDeactivated, .promptActivated, .promptDeactivated:
                return nil
            case .copyAgainTriggered:
                return nil
            }
        }
    }

    func beginManual(mode: RecordingTriggerMode) {
        begin(mode, prompt: false)
    }

    func forceToggleMode() {
        activeMode = .toggle
        toggleStopArmed = false
    }

    func reset() {
        activeMode = nil
        toggleStopArmed = false
        promptStartedHold = false
    }

    private func begin(_ mode: RecordingTriggerMode, prompt: Bool) {
        activeMode = mode
        toggleStopArmed = false
        isPromptSession = prompt
        promptStartedHold = false
    }
}
