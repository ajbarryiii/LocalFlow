// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import Carbon
import os.log
private let recordingLog = OSLog(subsystem: "com.ajbarryiii.localflow", category: "Recording")

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case macros
    case dictionary
    case runLog
    case debug

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        allCases.filter { tab in
            tab != .debug || AppBuild.isDevBundle
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .macros: return "Voice Macros"
        case .dictionary: return "Dictionary"
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .macros: return "music.mic"
        case .dictionary: return "character.book.closed"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        Bundle.main.bundleIdentifier == "com.ajbarryiii.localflow.dev" ||
        ["LocalFlow Dev", "FreeFlow Dev"].contains(AppName.displayName)
    }
}

private struct PreservedPasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let value: Value

    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        self.entries = item.types.compactMap { type in
            if let string = item.string(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .string(string))
            }
            if let propertyList = item.propertyList(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .propertyList(propertyList))
            }
            if let data = item.data(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .data(data))
            }
            return nil
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map(PreservedPasteboardItem.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}

@MainActor
final class AppState: ObservableObject, DictationCleanupActions {
    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let promptShortcutStorageKey = "prompt_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let savedPromptCustomShortcutStorageKey = "saved_prompt_custom_shortcut"
    private let promptTagStorageKey = "prompt_tag"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let doubleTapPromptStorageKey = "double_tap_prompt_enabled"
    private let spokenDelimitersStorageKey = "spoken_delimiters_enabled"
    private let spokenNumbersStorageKey = "spoken_numbers_enabled"
    private let alertSoundsEnabledStorageKey = "alert_sounds_enabled"
    private let soundVolumeStorageKey = "sound_volume"
    private let voiceMacrosStorageKey = "voice_macros"
    private let dictationAudioInterruptionEnabledStorageKey = "dictation_audio_interruption_enabled"
    private let pasteAfterShortcutReleaseDelay: TimeInterval = 0.03
    private let pressEnterAfterPasteDelay: TimeInterval = 0.08
    private let clipboardRestoreDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = 20
    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var copyAgainShortcut: ShortcutBinding {
        didSet {
            persistShortcut(copyAgainShortcut, key: copyAgainShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var promptShortcut: ShortcutBinding {
        didSet {
            persistShortcut(promptShortcut, key: promptShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedCopyAgainCustomShortcut, key: savedCopyAgainCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedPromptCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedPromptCustomShortcut, key: savedPromptCustomShortcutStorageKey)
        }
    }

    /// Placed before dictations started with the prompt shortcut.
    @Published var promptTag: String {
        didSet {
            UserDefaults.standard.set(promptTag, forKey: promptTagStorageKey)
        }
    }

    static let defaultPromptTag = "[dictated]"

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                dictationAudioInterruptionEnabled,
                forKey: dictationAudioInterruptionEnabledStorageKey
            )
        }
    }

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory, forKey: keepDictationInClipboardHistoryStorageKey)
        }
    }

    /// Double-tap Hold to Talk for prompt mode; off by default. While on, a Hold to
    /// Talk recording shorter than 0.3 s is discarded untranscribed.
    @Published var isDoubleTapPromptEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDoubleTapPromptEnabled, forKey: doubleTapPromptStorageKey)
            doubleTapPrompt.isEnabled = isDoubleTapPromptEnabled
        }
    }
    private var doubleTapPrompt = DoubleTapPromptDetector()
    private var recordingAttempts = RecordingAttempts()
    /// Hold to Talk releases that have arrived but are not yet handled.
    private var holdReleasesInFlight = 0

    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled, forKey: pressEnterVoiceCommandStorageKey)
        }
    }

    @Published var isSpokenDelimitersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSpokenDelimitersEnabled, forKey: spokenDelimitersStorageKey)
        }
    }

    @Published var isSpokenNumbersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSpokenNumbersEnabled, forKey: spokenNumbersStorageKey)
        }
    }

    @Published var alertSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertSoundsEnabled, forKey: alertSoundsEnabledStorageKey)
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    @Published var voiceMacros: [VoiceMacro] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: voiceMacrosStorageKey)
            }
        }
    }

    // MARK: Custom dictionary (DESIGN §3.2). Entries and corrections are never logged.

    private static let dictionaryStorageKey = "custom_dictionary"
    private static let dictionaryIgnoreStorageKey = "custom_dictionary_ignore"
    private static let correctionSuggestionsStorageKey = "correction_suggestions_enabled"

    /// The bundled model's vocabulary, so Settings can reject unencodable entries.
    static let dictionaryEncoder: BPEEncoder? = LocalParakeetService.bundleDirectory.flatMap {
        try? BPEEncoder(vocabularyFile: $0.appendingPathComponent("vocabulary.json"))
    }

    @Published private(set) var customDictionary = CustomDictionary()
    /// Saved data failed validation. It stays untouched, the dictionary is
    /// empty in memory, and editing waits for an explicit reset.
    @Published private(set) var dictionaryLoadFailed = false
    /// Watch pasted dictations for corrections. On by default; turning it off is remembered.
    @Published var isCorrectionSuggestionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCorrectionSuggestionsEnabled, forKey: Self.correctionSuggestionsStorageKey)
            if !isCorrectionSuggestionsEnabled {
                stopCorrectionSuggestions()
                overlayManager.withdrawDictionarySuggestion()
            }
        }
    }
    private var dictionaryRevision: UInt64 = 1
    private let correctionWatcher = CorrectionWatcher(reader: AccessibilityTextFieldReader())
    private var correctionSuggestionTask: Task<Void, Never>?

    var dictionaryEntries: [DictionaryEntry] { customDictionary.entries }
    var dictionaryIgnore: [DictionaryKey] { customDictionary.ignore }

    /// The immutable dictionary a transcription decodes with.
    var dictionarySnapshot: DictionarySnapshot {
        DictionarySnapshot(revision: dictionaryRevision, entries: dictionaryLoadFailed ? [] : customDictionary.entries)
    }

    private static let dictationStatsStorageKey = "dictation_stats"
    @Published private(set) var dictationStats = AppState.loadDictationStats() {
        didSet {
            if let data = try? JSONEncoder().encode(dictationStats) {
                UserDefaults.standard.set(data, forKey: Self.dictationStatsStorageKey)
            }
        }
    }

    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppState.writeRecordingStateFlag(isRecording)
        }
    }
    @Published var isTranscribing = false
    @Published private(set) var localModelPreparationState: LocalParakeetPreparationState = .idle
    private var localModelPreparationTask: Task<Void, Never>?
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var debugShowsUpdateReminderAfterDictation = false
    @Published var lastRawTranscript = ""
    @Published var lastOutputTranscript = ""
    @Published var lastTranscriptionStatus = ""
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var transcriptionTask: Task<Void, Never>?
    /// The recording's transcription while it is recorded, with the dictionary
    /// revision and retention it began with. Nil: the file is transcribed after.
    private var streamingDictation: (session: ParakeetStreamingSession, dictionaryRevision: UInt64, retainForCorrection: Bool)?
    private var transcribingAudioFileName: String?
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var needsMicrophoneRefreshAfterRecording = false
    private let pipelineHistoryStore = PipelineHistoryStore()
    private let shortcutSessionController = DictationShortcutSessionController()
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var automaticTerminationDisabled = false
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    private var shouldMonitorHotkeys = false
    private var isCapturingShortcut = false
    private var isAwaitingMicrophonePermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let shortcuts = Self.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey,
            copyAgainKey: copyAgainShortcutStorageKey,
            promptKey: promptShortcutStorageKey
        )
        let savedHoldCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedHoldCustomShortcutStorageKey,
            fallback: shortcuts.hold.isCustom ? shortcuts.hold : nil
        )
        let savedToggleCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedToggleCustomShortcutStorageKey,
            fallback: shortcuts.toggle.isCustom ? shortcuts.toggle : nil
        )
        let savedCopyAgainCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedCopyAgainCustomShortcutStorageKey,
            fallback: shortcuts.copyAgain.isCustom ? shortcuts.copyAgain : nil
        )
        let savedPromptCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedPromptCustomShortcutStorageKey,
            fallback: shortcuts.prompt.isCustom ? shortcuts.prompt : nil
        )
        let promptTag = UserDefaults.standard.string(forKey: promptTagStorageKey) ?? Self.defaultPromptTag
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let isDoubleTapPromptEnabled = UserDefaults.standard.bool(forKey: doubleTapPromptStorageKey)
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let isSpokenDelimitersEnabled = UserDefaults.standard.object(forKey: spokenDelimitersStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: spokenDelimitersStorageKey)
        let isSpokenNumbersEnabled = UserDefaults.standard.object(forKey: spokenNumbersStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: spokenNumbersStorageKey)
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let alertSoundsEnabled = UserDefaults.standard.object(forKey: alertSoundsEnabledStorageKey) != nil
            ? UserDefaults.standard.bool(forKey: alertSoundsEnabledStorageKey)
            : soundVolume > 0

        let initialMacros: [VoiceMacro]
        if let data = UserDefaults.standard.data(forKey: "voice_macros"),
           let decoded = try? JSONDecoder().decode([VoiceMacro].self, from: data) {
            initialMacros = decoded
        } else {
            initialMacros = []
        }

        let dictionaryLoad = Self.loadCustomDictionary()
        // On unless the user turned it off.
        let isCorrectionSuggestionsEnabled = UserDefaults.standard.object(forKey: Self.correctionSuggestionsStorageKey) as? Bool ?? true

        let initialAccessibility = AXIsProcessTrusted()
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.hasCompletedSetup = hasCompletedSetup
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.copyAgainShortcut = shortcuts.copyAgain
        self.promptShortcut = shortcuts.prompt
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.savedPromptCustomShortcut = savedPromptCustomShortcut.binding
        self.promptTag = promptTag
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.isDoubleTapPromptEnabled = isDoubleTapPromptEnabled
        self.doubleTapPrompt.isEnabled = isDoubleTapPromptEnabled
        self.isSpokenDelimitersEnabled = isSpokenDelimitersEnabled
        self.isSpokenNumbersEnabled = isSpokenNumbersEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.customDictionary = dictionaryLoad.dictionary
        self.dictionaryLoadFailed = dictionaryLoad.failed
        self.isCorrectionSuggestionsEnabled = isCorrectionSuggestionsEnabled
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID

        refreshAvailableMicrophones()
        installAudioDeviceObservers()

        if shortcuts.didUpdateHoldStoredValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
        }
        if shortcuts.didUpdateToggleStoredValue {
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        if shortcuts.didUpdateCopyAgainStoredValue {
            persistShortcut(shortcuts.copyAgain, key: copyAgainShortcutStorageKey)
        }
        if shortcuts.didUpdatePromptStoredValue {
            persistShortcut(shortcuts.prompt, key: promptShortcutStorageKey)
        }
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
        }
        if savedPromptCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedPromptCustomShortcut.binding, key: savedPromptCustomShortcutStorageKey)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onUpdateOverlayPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleUpdateOverlayPressed()
            }
        }
        overlayManager.onDictionarySuggestionAction = { [weak self] suggestion, action in
            // Sent from the overlay's suggestion buttons, on the main thread.
            MainActor.assumeIsolated {
                self?.handleDictionarySuggestionAction(suggestion, action)
            }
        }
        // CorrectionWatcher delivers both callbacks on the main queue.
        correctionWatcher.onEdit = { [weak self] edit, isLast, watch in
            MainActor.assumeIsolated {
                self?.handleCorrectionEdit(edit, isLast: isLast, watch: watch)
            }
        }
        correctionWatcher.onAbandon = { [weak self] in
            MainActor.assumeIsolated {
                self?.stopCorrectionSuggestions()
            }
        }

        // Clear any stale recording flag left over from an unclean exit.
        AppState.writeRecordingStateFlag(false)
        prepareLocalTranscriptionIfNeeded()
    }

    func prepareLocalTranscriptionIfNeeded() {
        guard localModelPreparationTask == nil, localModelPreparationState != .ready else { return }
        localModelPreparationState = .preparing
        localModelPreparationTask = Task { @MainActor [weak self] in
            do {
                try await LocalParakeetService.shared.prepare()
                self?.localModelPreparationState = .ready
            } catch {
                self?.localModelPreparationState = .failed
            }
            self?.localModelPreparationTask = nil
        }
    }

    deinit {
        // Nonisolated, but the last reference is gone: nothing else touches the observers.
        for observer in audioDeviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        AppState.writeRecordingStateFlag(false)
    }

    private func removeAudioDeviceObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in audioDeviceObservers {
            notificationCenter.removeObserver(observer)
        }
        audioDeviceObservers.removeAll()
    }

    private struct StoredShortcutConfiguration {
        let hold: ShortcutBinding
        let toggle: ShortcutBinding
        let copyAgain: ShortcutBinding
        let prompt: ShortcutBinding
        let didUpdateHoldStoredValue: Bool
        let didUpdateToggleStoredValue: Bool
        let didUpdateCopyAgainStoredValue: Bool
        let didUpdatePromptStoredValue: Bool
    }

    private struct StoredOptionalShortcut {
        let binding: ShortcutBinding?
        let didUpdateStoredValue: Bool
    }

    private struct StoredShortcutLoadResult {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private static func loadShortcutConfiguration(
        holdKey: String,
        toggleKey: String,
        copyAgainKey: String,
        promptKey: String
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        let storedHold = loadShortcut(forKey: holdKey)
        let storedToggle = loadShortcut(forKey: toggleKey)
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        let storedPrompt = loadShortcut(forKey: promptKey)
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            prompt: storedPrompt.binding ?? .disabled,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize,
            didUpdatePromptStoredValue: storedPrompt.didNormalize
        )
    }

    private static func loadShortcut(forKey key: String) -> StoredShortcutLoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredShortcutLoadResult(
            binding: normalized,
            hadStoredValue: true,
            didNormalize: normalized != decoded
        )
    }

    private static func loadSavedCustomShortcut(
        forKey key: String,
        fallback: ShortcutBinding?
    ) -> StoredOptionalShortcut {
        let stored = loadShortcut(forKey: key)
        if let binding = stored.binding {
            return StoredOptionalShortcut(binding: binding, didUpdateStoredValue: stored.didNormalize)
        }

        return StoredOptionalShortcut(
            binding: fallback,
            didUpdateStoredValue: stored.hadStoredValue || fallback != nil
        )
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        let normalizedBinding = binding.normalizedForStorageMigration()
        guard let data = try? JSONEncoder().encode(normalizedBinding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = AppName.supportDirectoryName
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    /// URL of the flag file written while LocalFlow is actively recording.
    ///
    /// External tools (voice assistants, TTS barge-in pipelines, conversation
    /// apps) can poll this file to know when the user is dictating. The file
    /// exists while `isRecording` is true and is removed when it flips false.
    /// Contents are the UNIX timestamp (seconds, float) of when recording
    /// started — useful for stale-flag detection after an unclean exit.
    ///
    /// Path: `~/Library/Application Support/LocalFlow/is-recording`
    /// (or `LocalFlow Dev/is-recording` when running the dev bundle).
    nonisolated static func recordingStateFlagURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = AppName.supportDirectoryName
        return appSupport.appendingPathComponent("\(appName)/is-recording")
    }

    /// Serial queue that owns every flag-file I/O so the recording
    /// start/stop hot path never blocks on disk.
    private nonisolated static let recordingStateFlagQueue = DispatchQueue(
        label: "com.ajbarryiii.localflow.recording-state-flag"
    )

    /// Write or clear the `is-recording` flag file. Called from the
    /// `isRecording` didSet. Dispatches to a background queue so disk
    /// I/O never adds latency to recording start/stop. Failures are
    /// swallowed — this is advisory IPC and must never interrupt the
    /// recording pipeline.
    nonisolated static func writeRecordingStateFlag(_ recording: Bool) {
        let timestamp = recording ? String(Date().timeIntervalSince1970) : nil
        recordingStateFlagQueue.async {
            let url = recordingStateFlagURL()
            if let timestamp {
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? timestamp.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let fileName = UUID().uuidString + ".wav"
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to persist audio file %{public}@ from %{public}@ to %{public}@ : %{public}@",
                fileName,
                tempURL.path,
                destURL.path,
                error.localizedDescription
            )
            return nil
        }
    }

    private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func retryTranscription(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName, !retryingItemIDs.contains(item.id) else { return }
        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            errorMessage = "Audio file not found for retry."
            return
        }
        retryingItemIDs.insert(item.id)
        Task { @MainActor in
            defer { retryingItemIDs.remove(item.id) }
            var updated = item
            do {
                // Casing restoration runs inside, before LocalDictationCore.
                let raw = try await LocalParakeetService.shared.transcribe(fileURL: audioURL, dictionary: dictionarySnapshot,
                                                                           retainForCorrection: false).text
                let result = LocalDictationCore.process(raw, macros: voiceMacros,
                                                       pressEnterEnabled: isPressEnterVoiceCommandEnabled,
                                                       spokenDelimitersEnabled: isSpokenDelimitersEnabled,
                                                       spokenNumbersEnabled: isSpokenNumbersEnabled)
                updated.rawTranscript = result.rawTranscript
                updated.transcript = result.output
                updated.status = "\(result.status) (retried)"
                if !result.output.isEmpty {
                    lastTranscript = result.output
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.output, forType: .string)
                }
            } catch {
                updated.status = "Error: \(error.localizedDescription)"
                errorMessage = error.localizedDescription
            }
            do {
                try pipelineHistoryStore.update(updated)
                pipelineHistory = pipelineHistoryStore.loadAllHistory()
            } catch {
                errorMessage = "Failed to save retry result."
            }
        }
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility {
            return
        }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasAccessibility = AXIsProcessTrusted()
                if self.hasAccessibility {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openPrivacySettingsPane(.accessibility)
        }
    }

    func openMicrophoneSettings() {
        openPrivacySettingsPane(.microphone)
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshAvailableMicrophones()
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    if granted {
                        self?.refreshAvailableMicrophones()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        @unknown default:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    private func openPrivacySettingsPane(_ permission: PrivacyPermission) {
        if !NSWorkspace.shared.open(permission.settingsURL) {
            NSWorkspace.shared.open(PrivacyPermission.privacySettingsURL)
        }
    }

    func revealAppForPermissionRepair() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure without re-triggering didSet
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        guard !isRecording, !audioRecorder.isRecording else {
            needsMicrophoneRefreshAfterRecording = true
            return
        }

        needsMicrophoneRefreshAfterRecording = false
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        refreshAvailableMicrophones()
    }

    private func installAudioDeviceObservers() {
        removeAudioDeviceObservers()

        let notificationCenter = NotificationCenter.default
        let refreshOnAudioDeviceChange: @Sendable (Notification) -> Void = { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else {
                return
            }
            // Delivered on the main queue (queue: .main below), so already on the main actor.
            MainActor.assumeIsolated {
                self?.refreshAvailableMicrophones()
            }
        }

        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey || copyAgainShortcut.usesFnKey || promptShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool {
        !holdShortcut.isDisabled
    }

    var hasEnabledToggleShortcut: Bool {
        !toggleShortcut.isDisabled
    }

    var shortcutStatusText: String {
        if hotkeyMonitoringErrorMessage != nil {
            return "Global shortcuts unavailable"
        }

        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(holdShortcut.displayName) or tap \(toggleShortcut.displayName) to dictate"
        case (true, false):
            return "Hold \(holdShortcut.displayName) to dictate"
        case (false, true):
            return "Tap \(toggleShortcut.displayName) to dictate"
        case (false, false):
            return "No dictation shortcut enabled"
        }
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold:
            return savedHoldCustomShortcut
        case .toggle:
            return savedToggleCustomShortcut
        case .copyAgain:
            return savedCopyAgainCustomShortcut
        case .prompt:
            return savedPromptCustomShortcut
        }
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()

        if role == .hold || role == .toggle {
            let otherDictationBinding = role == .hold ? toggleShortcut : holdShortcut
            guard !binding.conflicts(with: otherDictationBinding) else {
                return "Hold and tap shortcuts must be distinct."
            }
        }

        if role != .copyAgain, binding.conflicts(with: copyAgainShortcut) {
            return "This shortcut is already used by Paste Again."
        }
        if role == .copyAgain {
            if binding.conflicts(with: holdShortcut) {
                return "Paste Again cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "Paste Again cannot share a shortcut with Tap to Toggle."
            }
        }

        if role != .prompt, binding.conflicts(with: promptShortcut) {
            return "This shortcut is already used by Hold to Prompt."
        }
        if role == .prompt {
            let others: [(ShortcutRole, ShortcutBinding)] = [(.hold, holdShortcut), (.toggle, toggleShortcut),
                                                             (.copyAgain, copyAgainShortcut)]
            for (otherRole, other) in others where binding.conflicts(with: other) {
                return "Hold to Prompt cannot share a shortcut with \(otherRole.title)."
            }
        }

        switch role {
        case .hold:
            if binding.isCustom {
                savedHoldCustomShortcut = binding
            }
            holdShortcut = binding
        case .toggle:
            if binding.isCustom {
                savedToggleCustomShortcut = binding
            }
            toggleShortcut = binding
        case .copyAgain:
            if binding.isCustom {
                savedCopyAgainCustomShortcut = binding
            }
            copyAgainShortcut = binding
        case .prompt:
            if binding.isCustom {
                savedPromptCustomShortcut = binding
            }
            promptShortcut = binding
        }

        return nil
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEventDetail = { [weak self] event, releaseOrigin in
            // Stamp the event as it arrives, before the hop to the main queue:
            // monotonic time, whether the app was idle, and the interruption count,
            // so later state changes or cancellations are not mistaken for the state
            // at the event.
            let time = ProcessInfo.processInfo.systemUptime
            // The event tap's run-loop source is on the main run loop
            // (GlobalShortcutBackend adds it to CFRunLoopGetMain), and HotkeyManager
            // calls back synchronously from it, so this runs on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Idle by event order: a hold whose release already arrived counts as ended.
                let appIdle = DoubleTapPromptDetector.appIdleAtArrival(
                    transcribing: self.isTranscribing, sessionMode: self.shortcutSessionController.activeMode,
                    recordingOrStarting: self.isRecording || self.pendingShortcutStartMode != nil,
                    holdReleasesInFlight: self.holdReleasesInFlight)
                if event == .holdDeactivated { self.holdReleasesInFlight += 1 }
                let stamp = self.doubleTapPrompt.stamp(at: time, appIdle: appIdle, releaseOrigin: releaseOrigin)
                DispatchQueue.main.async { [weak self] in
                    self?.handleShortcutEvent(event, stamp: stamp)
                }
            }
        }
        // A backend reset or a monitoring restart voids a pending double-tap even
        // when no shortcut was active (so no shortcut event carries it). Queued
        // like the events, so it lands between the ones around it.
        hotkeyManager.onInputInvalidated = { [weak self] in
            DispatchQueue.main.async { self?.doubleTapPrompt.interruptInput() }
        }
        hotkeyManager.onEscapeKeyPressed = { [weak self] in
            // Called synchronously from the event tap on the main run loop, as above.
            MainActor.assumeIsolated {
                self?.handleEscapeKeyPress() ?? false
            }
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyMonitoringErrorMessage = nil
        hotkeyManager.onShortcutEvent = nil
        hotkeyManager.onShortcutEventDetail = nil
        hotkeyManager.onInputInvalidated = nil
        doubleTapPrompt.interrupt()
        hotkeyManager.onEscapeKeyPressed = nil
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        restartHotkeyMonitoring()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private var activeShortcutConfiguration: ShortcutConfiguration {
        ShortcutConfiguration(hold: holdShortcut, toggle: toggleShortcut, copyAgain: copyAgainShortcut,
                              prompt: promptShortcut)
    }

    private func restartHotkeyMonitoring() {
        guard shouldMonitorHotkeys, !isCapturingShortcut, !isAwaitingMicrophonePermission else {
            hotkeyManager.stop()
            return
        }

        do {
            try hotkeyManager.start(configuration: activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
        } catch {
            hotkeyMonitoringErrorMessage = error.localizedDescription
            os_log(.error, log: recordingLog, "Hotkey monitoring failed to start: %{public}@", error.localizedDescription)
        }
    }

    private func handleShortcutEvent(_ event: ShortcutEvent, stamp: DoubleTapPromptDetector.Stamp) {
        if event == .holdDeactivated { holdReleasesInFlight = max(0, holdReleasesInFlight - 1) }
        if event == .copyAgainTriggered {
            doubleTapPrompt.interruptInput()
            copyLastTranscriptToPasteboard()
            return
        }

        // The controller decides start and stop as always; double-tap prompt mode
        // only reads Hold to Talk starts and stops (see DoubleTapPromptDetector.route).
        let decision = doubleTapPrompt.route(event, stamp: stamp, controller: shortcutSessionController,
                                             isTranscribing: isTranscribing, recordingsBegun: recordingAttempts.begun)
        guard let action = decision.action else { return }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            // Correction work ends and a visible suggestion is withdrawn (see the step list).
            DictationCleanupSteps.acceptedPress(self)
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            if decision.discardTooShort {
                discardTooShortHold()
                return
            }
            guard isRecording else {
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
                return
            }
            stopAndTranscribe()
        case .switchedToToggle:
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    private func handleEscapeKeyPress() -> Bool {
        doubleTapPrompt.interrupt()
        if isTranscribing {
            cancelTranscription()
            return true
        }

        if pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle {
            cancelToggleShortcutSession()
            return true
        }

        return false
    }

    /// Copies the last transcript to the pasteboard and pastes it into the
    /// focused app — Wispr Flow style. Reuses the dictation paste pipeline so
    /// preserveClipboard is honored and the synthetic Cmd+V waits for the
    /// trigger shortcut to be fully released.
    func copyLastTranscriptToPasteboard() {
        guard !lastTranscript.isEmpty else { return }
        let pendingClipboardRestore = writeTranscriptToPasteboard(lastTranscript)
        pasteAtCursorWhenShortcutReleased { [weak self] in
            self?.restoreClipboardIfNeeded(pendingClipboardRestore)
        }
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        // A manual start or stop is independent dictation activity: no pending double-tap survives it.
        doubleTapPrompt.interrupt()
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    /// A Hold to Talk recording under the double-tap minimum (0.3 s): stop and
    /// throw it away. No model run, paste, history entry or error toast.
    private func discardTooShortHold() {
        let wasRecording = isRecording
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        DictationCleanupSteps.discardTooShortHold(isRecording: wasRecording, self)
    }

    func withdrawDictionarySuggestion() {
        overlayManager.withdrawDictionarySuggestion()
    }

    /// Work already queued for this recording (readiness, the background start)
    /// must not bring it back.
    func invalidateRecordingAttempt() {
        recordingAttempts.invalidate()
    }

    func cancelDiscardedCapture() {
        guard isRecording else { return }
        DictationCleanupSteps.discardCapture(self)
    }

    private func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }
        DictationCleanupSteps.cancelToggleSession(self)
    }

    private func cancelTranscription() {
        guard isTranscribing else { return }
        doubleTapPrompt.interrupt()
        DictationCleanupSteps.cancelTranscription(self)
    }

    // MARK: Dictation cleanup actions (run by DictationCleanupSteps)

    func endShortcutSession() {
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
    }

    func stopShortcutMonitor() {
        hotkeyManager.stop()
    }

    func detachRecorderCallbacks() {
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
    }

    func markNotRecording() {
        isRecording = false
    }

    func cancelRecorderCapture() {
        audioRecorder.cancelRecording()
    }

    func cleanUpRecorderFiles() {
        audioRecorder.cleanup()
    }

    func cancelTranscriptionTask() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    func finishTranscriptionTask() {
        transcriptionTask = nil
    }

    func markNotTranscribing() {
        isTranscribing = false
    }

    func deleteTranscribingAudio() {
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
    }

    func forgetTranscribingAudio() {
        transcribingAudioFileName = nil
    }

    func showStatus(_ status: DictationCleanupStatus) {
        switch status {
        case .ready:
            errorMessage = nil
            debugStatusMessage = "Idle"
            statusText = "Ready"
        case .cancelled:
            errorMessage = nil
            debugStatusMessage = "Cancelled"
            statusText = "Cancelled"
        case .failed(let message):
            errorMessage = message
            statusText = "Error"
        }
    }

    func dismissOverlay() {
        overlayManager.dismiss()
    }

    func scheduleReadyStatusAfterCancel() {
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart(resetMode: false)
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingShortcutStartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
            self.pendingShortcutStartTask = nil
            self.pendingShortcutStartMode = nil
            self.startRecording(triggerMode: pendingMode)
        }
    }

    func cancelPendingShortcutStart() {
        cancelPendingShortcutStart(resetMode: true)
    }

    private func cancelPendingShortcutStart(resetMode: Bool) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        guard !isRecording && !isTranscribing else { return }
        // A new dictation ends any correction watch and verification without a suggestion.
        stopCorrectionSuggestions()
        overlayManager.withdrawDictionarySuggestion()
        cancelPendingShortcutStart()
        guard prepareRecordingStart(triggerMode: triggerMode), ensureMicrophoneAccess() else { return }
        applyAudioInterruptionIfNeeded()
        beginRecording(triggerMode: triggerMode)
    }

    private func prepareRecordingStart(triggerMode: RecordingTriggerMode) -> Bool {
        activeRecordingTriggerMode = triggerMode
        hasAccessibility = AXIsProcessTrusted()
        guard hasAccessibility else {
            errorMessage = "\(PrivacyPermission.accessibility.settingsTitle) permission required. \(PrivacyPermission.accessibility.enableInstructions(appName: AppName.displayName))"
            statusText = "No Accessibility"
            activeRecordingTriggerMode = nil
            shortcutSessionController.reset()
            showAccessibilityAlert()
            return false
        }
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard let triggerMode = activeRecordingTriggerMode else {
                return false
            }

            prepareForMicrophonePermissionPrompt(triggerMode: triggerMode)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    guard let strongSelf = self else { return }
                    let pendingTriggerMode = strongSelf.pendingMicrophonePermissionTriggerMode
                    strongSelf.pendingMicrophonePermissionTriggerMode = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let triggerMode = pendingTriggerMode else { return }
                    if granted {
                        strongSelf.errorMessage = nil
                        if triggerMode == .toggle {
                            guard strongSelf.prepareRecordingStart(
                                triggerMode: .toggle
                            ) else { return }
                            strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                            strongSelf.applyAudioInterruptionIfNeeded()
                            strongSelf.beginRecording(triggerMode: .toggle)
                        } else {
                            strongSelf.statusText = "Microphone access granted. Press and hold again to record."
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: ["Microphone access granted. Press and hold again to record."]
                            )
                        }
                    } else {
                        strongSelf.errorMessage = "Microphone permission denied. \(PrivacyPermission.microphone.enableInstructions(appName: AppName.displayName))"
                        strongSelf.statusText = "No Microphone"
                        strongSelf.activeRecordingTriggerMode = nil
                        strongSelf.shortcutSessionController.reset()
                        strongSelf.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. \(PrivacyPermission.microphone.enableInstructions(appName: AppName.displayName))"
            statusText = "No Microphone"
            activeRecordingTriggerMode = nil
                shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func prepareForMicrophonePermissionPrompt(
        triggerMode: RecordingTriggerMode
    ) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        DictationCleanupSteps.awaitMicrophonePermission(self)
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }

        let wasMuted = SystemAudioStatus.isDefaultOutputMuted()
        if wasMuted {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    func restoreAudioInterruptionIfNeeded() {
        guard let activeAudioInterruption else { return }
        self.activeAudioInterruption = nil

        switch activeAudioInterruption {
        case .muted(let previouslyMuted):
            if !previouslyMuted {
                _ = SystemAudioStatus.setDefaultOutputMuted(false)
            }
        }
    }

    private func beginCriticalDictationActivity() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("LocalFlow dictation in progress")
        automaticTerminationDisabled = true
    }

    func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination("LocalFlow dictation in progress")
        automaticTerminationDisabled = false
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        let attempt = recordingAttempts.begin()
        beginCriticalDictationActivity()
        clearPendingOverlayDismissToken()
        errorMessage = nil

        isRecording = true
        statusText = "Starting..."

        // Show initializing dots only if engine takes longer than 0.2s to start
        var overlayShown = false
        cancelRecordingInitializationTimer()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        recordingInitializationTimer = initTimer
        initTimer.schedule(deadline: .now() + 0.2)
        initTimer.setEventHandler { [weak self] in
            // The timer source targets the main queue.
            MainActor.assumeIsolated {
                guard let self, !overlayShown, self.recordingAttempts.isCurrent(attempt) else { return }
                overlayShown = true
                os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
                self.clearPendingOverlayDismissToken()
                self.overlayManager.showInitializing(
                    mode: self.activeRecordingTriggerMode ?? triggerMode
                )
            }
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.recordingAttempts.isCurrent(attempt) else { return }
                self.cancelRecordingInitializationTimer()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                self.clearPendingOverlayDismissToken()
                if overlayShown {
                    self.overlayManager.transitionToRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode
                    )
                } else {
                    self.overlayManager.showRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode
                    )
                }
                overlayShown = true
                self.playAlertSound(named: "Tink")
            }
        }
        audioRecorder.onRecordingFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.recordingAttempts.isCurrent(attempt) else { return }
                self.cancelRecordingInitializationTimer()
                self.handleRecordingFailure(error)
            }
        }

        // Only this capture feeds this session: the recorder forwards to the sink
        // of the capture its buffers belong to, until that capture has drained.
        let sampleSink = beginStreamingDictation().map { session -> AudioRecorder.SampleSink in { session.append($0) } }
        // Reserve the capture ticket here, before dispatching: a cancel from now on
        // (a discarded tap) voids this start wherever its work then is.
        let captureTicket = audioRecorder.reserveCapture()
        // AudioRecorder is not Sendable, but startRecording is built to run off the
        // main thread: its capture state is behind its session queue and locks.
        nonisolated(unsafe) let recorder = audioRecorder
        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try recorder.startRecording(deviceUID: deviceUID, ticket: captureTicket, sampleSink: sampleSink)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async { [self] in
                    guard self.recordingAttempts.isCurrent(attempt), self.isRecording,
                          self.activeRecordingTriggerMode != nil else { return }
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            // Received on the main queue.
                            MainActor.assumeIsolated {
                                self?.overlayManager.updateAudioLevel(level)
                            }
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.recordingAttempts.isCurrent(attempt) else { return }
                    self.cancelRecordingInitializationTimer()
                    guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                    self.handleRecordingFailure(error)
                }
            }
        }
    }

    /// Audio is retained only while suggestions are on.
    private var retainsAudioForCorrection: Bool {
        isCorrectionSuggestionsEnabled && !dictionaryLoadFailed && AXIsProcessTrusted()
    }

    /// Transcribes the new recording while it is recorded when the model is
    /// ready. Otherwise, and whenever the session cannot be used, the file is
    /// transcribed after recording as before.
    private func beginStreamingDictation() -> ParakeetStreamingSession? {
        cancelStreamingDictation()
        guard localModelPreparationState == .ready else { return nil }
        let dictionary = dictionarySnapshot, retain = retainsAudioForCorrection
        guard let session = LocalParakeetService.shared.beginStreamingTranscription(
            dictionary: dictionary, retainForCorrection: retain) else { return nil }
        streamingDictation = (session, dictionary.revision, retain)
        return session
    }

    /// The recording is discarded or failed: its audio and partial result go.
    func cancelStreamingDictation() {
        streamingDictation?.session.cancel()
        streamingDictation = nil
    }

    /// The session for this transcription, if it began with the same dictionary
    /// and retention; otherwise it is dropped and the file is transcribed.
    private func takeStreamingDictation(dictionary: DictionarySnapshot, retainForCorrection: Bool) -> ParakeetStreamingSession? {
        defer { streamingDictation = nil }
        guard let streaming = streamingDictation else { return nil }
        guard streaming.dictionaryRevision == dictionary.revision, streaming.retainForCorrection == retainForCorrection else {
            streaming.session.cancel()
            return nil
        }
        return streaming.session
    }

    /// The session's result; without one, or after any failure but cancellation,
    /// the recorded file exactly as before. Nonisolated: it runs off the main actor.
    private nonisolated static func transcribeDictation(fileURL: URL, streaming: ParakeetStreamingSession?, dictionary: DictionarySnapshot,
                                            retainForCorrection: Bool) async throws -> TranscriptionResult {
        if let streaming {
            do { return try await streaming.finish() } catch { try Task.checkCancellation() }
        }
        return try await LocalParakeetService.shared.transcribe(fileURL: fileURL, dictionary: dictionary,
                                                                retainForCorrection: retainForCorrection)
    }

    private func handleRecordingFailure(_ error: Error) {
        DictationCleanupSteps.recordingFailed(message: formattedRecordingStartError(error), self)
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    private func formattedTranscriptionError(_ error: Error) -> String {
        error.localizedDescription
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot record audio without Microphone access.\n\n\(PrivacyPermission.microphone.enableInstructions(appName: AppName.displayName))"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "\(PrivacyPermission.accessibility.settingsTitle) Permission Required"
        alert.informativeText = "\(AppName.displayName) needs this access for global shortcuts and pasting transcribed text.\n\n\(PrivacyPermission.accessibility.enableInstructions(appName: AppName.displayName))\n\n\(PrivacyPermission.accessibilityRepairInstructions)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }

        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }

    private func stopAndTranscribe() {
        let appliedPromptTag = shortcutSessionController.isPromptSession ? promptTag : nil
        let dictionary = dictionarySnapshot
        // Audio is retained only while suggestions are on; macros and press-enter
        // results release it right after processing.
        let retainForCorrection = retainsAudioForCorrection
        let streaming = takeStreamingDictation(dictionary: dictionary, retainForCorrection: retainForCorrection)
        // Any cancel or dictionary edit after this point makes the result ineligible.
        let watchGeneration = correctionWatcher.currentGeneration
        DictationCleanupSteps.stopCaptureForTranscription(self)
        lastRawTranscript = ""
        lastOutputTranscript = ""
        lastTranscriptionStatus = ""
        debugStatusMessage = "Preparing audio"
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        playAlertSound(named: "Pop")
        overlayManager.showTranscribing()
        audioRecorder.stopRecording { [weak self] fileURL in
            // AudioRecorder calls back on the main queue, so this runs on the main actor.
            MainActor.assumeIsolated {
                guard let self else { streaming?.cancel(); return }
                guard let fileURL else {
                    streaming?.cancel()
                    DictationCleanupSteps.noAudioRecorded(self)
                    return
                }
                guard self.isTranscribing else {
                    streaming?.cancel()
                    DictationCleanupSteps.recordingStoppedAfterCancel(self)
                    return
                }
                let savedAudio = Self.saveAudioFile(from: fileURL)
                let input = savedAudio?.fileURL ?? fileURL
                self.transcribingAudioFileName = savedAudio?.fileName
                self.statusText = "Transcribing locally..."
                self.debugStatusMessage = "Transcribing audio"
                self.transcriptionTask?.cancel()
                self.transcriptionTask = Task { @MainActor in
                    do {
                        // Read off the main thread, alongside transcription, so it never delays it.
                        async let audioSeconds = Self.audioDuration(of: input)
                        // Casing restoration runs inside, before LocalDictationCore.
                        let transcription = try await Self.transcribeDictation(
                            fileURL: input, streaming: streaming, dictionary: dictionary, retainForCorrection: retainForCorrection)
                        let raw = transcription.text
                        try Task.checkCancellation()
                        let seconds = await audioSeconds
                        guard self.isTranscribing else { return }
                        let result = LocalDictationCore.process(raw, macros: self.voiceMacros,
                                                               pressEnterEnabled: self.isPressEnterVoiceCommandEnabled,
                                                               spokenDelimitersEnabled: self.isSpokenDelimitersEnabled,
                                                               spokenNumbersEnabled: self.isSpokenNumbersEnabled,
                                                               promptTag: appliedPromptTag)
                        self.lastRawTranscript = result.rawTranscript
                        self.lastOutputTranscript = result.output
                        self.lastTranscriptionStatus = result.status
                        self.recordPipelineHistoryEntry(rawTranscript: result.rawTranscript, transcript: result.output,
                                                        status: result.status, audioFileName: savedAudio?.fileName)
                        self.lastTranscript = result.output
                        let completionStatus = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
                        let enterStatus = "Pressed Enter"
                        DictationCleanupSteps.finishTranscription(self) {
                            self.debugStatusMessage = "Done"
                            self.clearPendingOverlayDismissToken()
                            if !self.showPostTranscriptionUpdateReminderIfNeeded() { self.overlayManager.dismiss() }
                            if result.output.isEmpty {
                                if let id = transcription.dictationID { LocalParakeetService.shared.releaseCorrectionSession(dictationID: id) }
                                self.statusText = result.shouldPressEnter ? enterStatus : "Nothing to transcribe"
                                if result.shouldPressEnter { self.pressEnterWhenShortcutReleased() }
                            } else {
                                self.statusText = completionStatus
                                let pendingRestore = self.writeTranscriptToPasteboard(result.output)
                                self.pasteAtCursorWhenShortcutReleased(
                                    correction: self.correctionPasteContext(for: result, dictationID: transcription.dictationID,
                                                             snapshotRevision: dictionary.revision,
                                                             watchGeneration: watchGeneration)
                                ) {
                                    if result.shouldPressEnter {
                                        self.pressEnterAfterPaste { self.restoreClipboardIfNeeded(pendingRestore) }
                                    } else {
                                        self.restoreClipboardIfNeeded(pendingRestore)
                                    }
                                }
                            }
                            // After the paste is triggered, so the counter never delays it. Count spoken
                            // words: macros can expand the output and commands remove words.
                            if let seconds {
                                self.dictationStats.record(words: DictationStats.wordCount(result.rawTranscript),
                                                           seconds: seconds)
                            }
                        }
                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatus, "Nothing to transcribe", enterStatus])
                    } catch is CancellationError {
                        DictationCleanupSteps.transcriptionCancelled(self)
                    } catch {
                        guard self.isTranscribing else { return }
                        let message = self.formattedTranscriptionError(error)
                        self.errorMessage = message
                        DictationCleanupSteps.finishTranscription(self) {
                            self.statusText = "Error"
                            self.overlayManager.showError(message)
                            self.lastTranscriptionStatus = "Error: \(message)"
                            self.recordPipelineHistoryEntry(rawTranscript: "", transcript: "",
                                                            status: self.lastTranscriptionStatus,
                                                            audioFileName: savedAudio?.fileName)
                        }
                    }
                }
            }
        }
    }

    func resetDictationStats() {
        dictationStats = DictationStats()
    }

    private static func loadDictationStats() -> DictationStats {
        guard let data = UserDefaults.standard.data(forKey: dictationStatsStorageKey),
              let stats = try? JSONDecoder().decode(DictationStats.self, from: data) else {
            return DictationStats()
        }
        return stats
    }

    /// Reads only the file header. Called off the main thread during transcription.
    private nonisolated static func audioDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func recordPipelineHistoryEntry(rawTranscript: String, transcript: String, status: String, audioFileName: String?) {
        let entry = PipelineHistoryItem(timestamp: Date(), rawTranscript: rawTranscript, transcript: transcript,
                                        status: status, audioFileName: audioFileName)
        do {
            for name in try pipelineHistoryStore.append(entry, maxCount: maxPipelineHistoryCount) {
                Self.deleteAudioFile(name)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry."
        }
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        clearPendingOverlayDismissToken()
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            // Scheduled on the main run loop (from the main actor), so it fires there.
            MainActor.assumeIsolated {
                self.overlayManager.updateAudioLevel(level)
            }
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
    }

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    private func showPostTranscriptionUpdateReminderIfNeeded() -> Bool {
        if debugShowsUpdateReminderAfterDictation {
            showDebugUpdateAvailableOverlay()
            return true
        }

        let updateManager = UpdateManager.shared
        guard updateManager.shouldShowPostTranscriptionReminder() else { return false }

        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        updateManager.markPostTranscriptionReminderShown()
        overlayManager.showUpdateAvailable(version: updateManager.latestReleaseVersion)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }

        return true
    }

    func showDebugUpdateAvailableOverlay() {
        let updateManager = UpdateManager.shared
        let version = updateManager.latestReleaseVersion.isEmpty ? "9.9.9" : updateManager.latestReleaseVersion
        let dismissToken = UUID()
        if isDebugOverlayActive || debugOverlayTimer != nil {
            stopDebugOverlay()
        }
        pendingOverlayDismissToken = dismissToken
        overlayManager.showUpdateAvailable(version: version)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    private func handleUpdateOverlayPressed() {
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        selectedSettingsTab = .general
        NotificationCenter.default.post(name: .showSettings, object: nil)

        DispatchQueue.main.async {
            if UpdateManager.shared.updateAvailable {
                UpdateManager.shared.showUpdateAlert()
            }
        }
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode = keyCodeForCharacter("v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func keyCodeForCharacter(_ character: String) -> CGKeyCode? {
        guard let char = character.lowercased().utf16.first else { return nil }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in UInt16(0)..<UInt16(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var charCount = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &charCount, &chars
                )
                if status == noErr, charCount > 0, chars[0] == char {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }

    private func pressEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// Writes the final transcript to the system pasteboard.
    /// Also handles appending necessary trailing spaces, declaring transient
    /// types for clipboard managers, and saving the clipboard state for later restoration.
    /// - Parameter transcript: The text to be pasted.
    /// - Returns: A `PendingClipboardRestore` object if clipboard preservation is enabled, otherwise nil.
    /// Append a space when ending with sentence-ending punctuation so the
    /// next dictation does not jam against the prior period.
    private static func pasteboardText(for transcript: String) -> String {
        if let last = transcript.last, ".!?".contains(last) {
            return transcript + " "
        }
        return transcript
    }

    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        let textToWrite = Self.pasteboardText(for: transcript)

        if keepDictationInClipboardHistory {
            // Plain write so clipboard managers record the dictation in history.
            pasteboard.clearContents()
            pasteboard.setString(textToWrite, forType: .string)
        } else {
            // Declare standard transient types alongside .string so well-behaved
            // clipboard managers (Maccy, Raycast, Paste, Clipy, Flycut, etc.) skip
            // recording this entry in their history. The text still pastes normally
            // via Cmd-V — only clipboard history is affected.
            //
            // See: https://github.com/nicke5012/TransientPasteboardType
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
            let legacyTransientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

            pasteboard.declareTypes([
                .string,
                transientType,
                concealedType,
                autoGeneratedType,
                legacyTransientType
            ], owner: nil)

            pasteboard.setString(textToWrite, forType: .string)

            // Populate empty values for the marker types — some clipboard managers
            // check the data presence rather than just the declared type.
            pasteboard.setString("", forType: transientType)
            pasteboard.setString("", forType: concealedType)
            pasteboard.setString("", forType: autoGeneratedType)
            pasteboard.setString("", forType: legacyTransientType)
        }

        guard let snapshot else { return nil }
        return PendingClipboardRestore(
            snapshot: snapshot,
            expectedChangeCount: pasteboard.changeCount,
            writtenTranscript: textToWrite
        )
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }

        // Some apps consume Cmd-V asynchronously, so restoring too quickly can paste
        // the pre-dictation clipboard instead of the transcript.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            // A bare changeCount check is too strict: browsers, iCloud Universal
            // Clipboard sync, and other background apps bump the change count
            // without the user copying anything, which left the transcript
            // stranded on the clipboard. Restore when nothing changed, or when the
            // clipboard still holds exactly the transcript we wrote (so the user
            // has not deliberately copied something new that we would clobber).
            let clipboardStillHoldsTranscript =
                pasteboard.string(forType: .string) == pendingRestore.writtenTranscript
            guard pasteboard.changeCount == pendingRestore.expectedChangeCount
                || clipboardStillHoldsTranscript else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    private func performAfterShortcutReleased(attempt: Int = 0, action: @escaping () -> Void) {
        let maxAttempts = 24
        if hotkeyManager.hasPressedShortcutInputs && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.performAfterShortcutReleased(attempt: attempt + 1, action: action)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteAfterShortcutReleaseDelay) {
            action()
        }
    }

    /// With a correction context (suggestions on), the destination field is
    /// captured on the watcher's queue immediately before Cmd-V is posted. The
    /// capture is bounded (0.3 s) so it can never hold the paste back for long.
    private func pasteAtCursorWhenShortcutReleased(correction: CorrectionPasteContext? = nil,
                                                   completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            guard let self else { return }
            // A context from before a cancel (new recording, setting off,
            // dictionary change) is stale: paste plainly, never watch.
            guard let correction, self.isCorrectionSuggestionsEnabled,
                  self.correctionWatcher.isCurrent(correction.watchGeneration) else {
                if let correction { LocalParakeetService.shared.releaseCorrectionSession(dictationID: correction.dictationID) }
                self.pasteAtCursor()
                completion?()
                return
            }
            self.correctionWatcher.capture(expecting: correction.watchGeneration) { [weak self] capture in
                // CorrectionWatcher completes a capture on the main queue.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pasteAtCursor()
                    if let capture, self.isCorrectionSuggestionsEnabled {
                        self.correctionWatcher.start(capture, pasted: correction.pasted, dictationID: correction.dictationID)
                    } else {
                        LocalParakeetService.shared.releaseCorrectionSession(dictationID: correction.dictationID)
                    }
                    completion?()
                }
            }
        }
    }

    // MARK: - Custom dictionary and correction suggestions

    private struct CorrectionPasteContext {
        /// Exactly what is pasted, including the trailing space LocalFlow adds.
        let pasted: String
        let dictationID: UInt64
        /// The watcher generation when recording stopped; any cancel since makes it stale.
        let watchGeneration: UInt64
    }

    /// Eligible: suggestions on, audio retained with the current dictionary
    /// revision, nothing cancelled since recording stopped, pasted, not a
    /// macro, no press-enter. Otherwise this dictation's audio is released.
    private func correctionPasteContext(for result: LocalDictationResult, dictationID: UInt64?, snapshotRevision: UInt64,
                                        watchGeneration: UInt64) -> CorrectionPasteContext? {
        guard let dictationID else { return nil }
        guard CorrectionEligibility.isEligible(
            suggestionsEnabled: isCorrectionSuggestionsEnabled, dictionaryReadable: !dictionaryLoadFailed, retained: true,
            snapshotRevision: snapshotRevision, currentRevision: dictionaryRevision,
            watchGeneration: watchGeneration, currentGeneration: correctionWatcher.currentGeneration,
            usedMacro: result.usedMacro, shouldPressEnter: result.shouldPressEnter, output: result.output) else {
            LocalParakeetService.shared.releaseCorrectionSession(dictationID: dictationID)
            return nil
        }
        return CorrectionPasteContext(pasted: Self.pasteboardText(for: result.output), dictationID: dictationID,
                                      watchGeneration: watchGeneration)
    }

    /// Discards any watched paste, running verification and retained audio
    /// without finalizing: new dictation, cancel, setting off, dictionary
    /// change, quit. A recording's streaming transcription holds audio
    /// retained under the old state, so it goes too; stop transcribes the file.
    func stopCorrectionSuggestions() {
        correctionWatcher.cancel()
        correctionSuggestionTask?.cancel()
        correctionSuggestionTask = nil
        cancelStreamingDictation()
        LocalParakeetService.shared.discardCorrectionSession()
    }

    /// No suggestion while any dictation is under way, including a pending
    /// shortcut start (start delay) or an active shortcut session.
    private var mayPresentCorrectionSuggestion: Bool {
        CorrectionSuggestionTiming.mayPresent(
            enabled: isCorrectionSuggestionsEnabled, dictionaryEditable: canEditDictionary, recording: isRecording,
            transcribing: isTranscribing, startPending: pendingShortcutStartMode != nil,
            shortcutSessionActive: shortcutSessionController.activeMode != nil)
    }

    /// Checks each settled edit; a newer edit supersedes a running check. The
    /// watch continues after a check that offers nothing, and stops once one
    /// does (one suggestion per dictation).
    private func handleCorrectionEdit(_ edit: CorrectionEdit, isLast: Bool, watch: UInt64) {
        // A full dictionary could not take a new word, so nothing is verified or offered.
        guard mayPresentCorrectionSuggestion, AXIsProcessTrusted(),
              customDictionary.entries.count < DictionaryValidation.capacity else {
            stopCorrectionSuggestions()
            return
        }
        let ignore = Set(customDictionary.ignore)
        // Registered here, in report order, so an older check can never cancel this one.
        let check = LocalParakeetService.shared.beginCorrectionCheck()
        correctionSuggestionTask?.cancel()
        correctionSuggestionTask = Task { @MainActor [weak self] in
            let suggestion = await LocalParakeetService.shared.suggestCorrection(
                typed: edit.typed, edited: edit.edited, dictationID: edit.dictationID, ignore: ignore, isLast: isLast,
                check: check)
            guard let self, !Task.isCancelled else { return }
            self.correctionSuggestionTask = nil
            // Claimed atomically: a watch made stale since (a secure field, lost
            // permission, any cancel) offers nothing, and a claimed one stops.
            guard let suggestion, self.correctionWatcher.claim(watch) else { return }
            LocalParakeetService.shared.releaseCorrectionSession(dictationID: edit.dictationID)
            guard self.mayPresentCorrectionSuggestion else { return }
            let key = DictionaryKey(suggestion.word)
            guard !self.customDictionary.contains(key), !self.customDictionary.isIgnored(key) else { return }
            self.overlayManager.showDictionarySuggestion(suggestion)
        }
    }

    private func handleDictionarySuggestionAction(_ suggestion: DictionarySuggestion, _ action: DictionarySuggestionAction) {
        switch action {
        case .add:
            // Defensive: if the add still fails (for example the dictionary filled
            // meanwhile), say so. The message never contains the word.
            if let message = saveDictionaryEntry(text: suggestion.word, strength: suggestion.strength, replacing: nil) {
                overlayManager.showError(message)
            }
        case .dontSuggest:
            if let message = apply(dictionaryEditor.ignoring(DictionaryKey(suggestion.word), in: customDictionary)) {
                overlayManager.showError(message)
            }
        case .notNow:
            break
        }
    }

    /// Every change needs the speech model's vocabulary (DESIGN §1.1 step 3).
    let dictionaryEditor = DictionaryEditor(encoder: AppState.dictionaryEncoder)

    var canEditDictionary: Bool { dictionaryEditor.canEdit && !dictionaryLoadFailed }

    /// Adds or edits an entry. Returns a user-facing error, or nil on success.
    func saveDictionaryEntry(text: String, strength: Float, replacing original: DictionaryKey?) -> String? {
        apply(dictionaryEditor.saving(text: text, strength: strength, replacing: original, in: customDictionary))
    }

    func removeDictionaryEntry(_ key: DictionaryKey) {
        if let result = dictionaryEditor.removing(key, in: customDictionary) { _ = apply(result) }
    }

    func unignoreDictionarySuggestion(_ key: DictionaryKey) {
        if let result = dictionaryEditor.unignoring(key, in: customDictionary) { _ = apply(result) }
    }

    /// Persists and publishes an accepted change; returns a content-free error otherwise.
    private func apply(_ result: Result<CustomDictionary, DictionaryEditError>) -> String? {
        guard !dictionaryLoadFailed else { return "Reset the saved dictionary first." }
        switch result {
        case .success(let updated):
            applyDictionary(updated)
            return nil
        case .failure(let error):
            return error.message
        }
    }

    /// The explicit recovery for unreadable saved data: removes it and starts empty.
    func resetSavedDictionary() {
        UserDefaults.standard.removeObject(forKey: Self.dictionaryStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.dictionaryIgnoreStorageKey)
        dictionaryLoadFailed = false
        customDictionary = CustomDictionary()
        dictionaryDidChange()
    }

    /// Persists a validated state, then publishes it. Never writes over
    /// unreadable saved data.
    private func applyDictionary(_ updated: CustomDictionary) {
        guard !dictionaryLoadFailed else { return }
        let encoded = DictionaryStorage.encode(updated)
        UserDefaults.standard.set(encoded.entries, forKey: Self.dictionaryStorageKey)
        UserDefaults.standard.set(encoded.ignore, forKey: Self.dictionaryIgnoreStorageKey)
        customDictionary = updated
        dictionaryDidChange()
    }

    /// Any change invalidates the retained correction session (DESIGN §3.4).
    private func dictionaryDidChange() {
        dictionaryRevision += 1
        stopCorrectionSuggestions()
        // A suggestion made against the old dictionary must not stay clickable.
        overlayManager.withdrawDictionarySuggestion()
    }

    private static func loadCustomDictionary() -> (dictionary: CustomDictionary, failed: Bool) {
        let defaults = UserDefaults.standard
        let entries = defaults.object(forKey: dictionaryStorageKey)
        let ignore = defaults.object(forKey: dictionaryIgnoreStorageKey)
        // A value of the wrong type is unreadable, never "missing".
        if (entries != nil && !(entries is Data)) || (ignore != nil && !(ignore is Data)) {
            return (CustomDictionary(), true)
        }
        switch DictionaryStorage.load(entriesData: entries as? Data, ignoreData: ignore as? Data, encoder: dictionaryEncoder) {
        case .success(let dictionary): return (dictionary, false)
        case .failure: return (CustomDictionary(), true)
        }
    }

    private func pressEnterWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func pressEnterAfterPaste(completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pressEnterAfterPasteDelay) { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    private func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let statuses, !statuses.contains(self.statusText) {
                return
            }
            self.statusText = "Ready"
        }
    }
}
