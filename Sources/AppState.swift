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
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .macros: return "music.mic"
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

final class AppState: ObservableObject, @unchecked Sendable {
    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let spokenDelimitersStorageKey = "spoken_delimiters_enabled"
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
            copyAgainKey: copyAgainShortcutStorageKey
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
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let isSpokenDelimitersEnabled = UserDefaults.standard.object(forKey: spokenDelimitersStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: spokenDelimitersStorageKey)
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
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.isSpokenDelimitersEnabled = isSpokenDelimitersEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
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
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
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
        removeAudioDeviceObservers()
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
        let didUpdateHoldStoredValue: Bool
        let didUpdateToggleStoredValue: Bool
        let didUpdateCopyAgainStoredValue: Bool
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
        copyAgainKey: String
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        let storedHold = loadShortcut(forKey: holdKey)
        let storedToggle = loadShortcut(forKey: toggleKey)
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize
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
    static func recordingStateFlagURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = AppName.supportDirectoryName
        return appSupport.appendingPathComponent("\(appName)/is-recording")
    }

    /// Serial queue that owns every flag-file I/O so the recording
    /// start/stop hot path never blocks on disk.
    private static let recordingStateFlagQueue = DispatchQueue(
        label: "com.ajbarryiii.localflow.recording-state-flag"
    )

    /// Write or clear the `is-recording` flag file. Called from the
    /// `isRecording` didSet. Dispatches to a background queue so disk
    /// I/O never adds latency to recording start/stop. Failures are
    /// swallowed — this is advisory IPC and must never interrupt the
    /// recording pipeline.
    static func writeRecordingStateFlag(_ recording: Bool) {
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
                let raw = try await LocalParakeetService.shared.transcribe(fileURL: audioURL)
                let result = LocalDictationCore.process(raw, macros: voiceMacros,
                                                       pressEnterEnabled: isPressEnterVoiceCommandEnabled,
                                                       spokenDelimitersEnabled: isSpokenDelimitersEnabled)
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
            DispatchQueue.main.async {
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
                DispatchQueue.main.async {
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

    private func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        refreshAvailableMicrophones()
    }

    private func installAudioDeviceObservers() {
        removeAudioDeviceObservers()

        let notificationCenter = NotificationCenter.default
        let refreshOnAudioDeviceChange: (Notification) -> Void = { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else {
                return
            }
            self?.refreshAvailableMicrophones()
        }

        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasConnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey || copyAgainShortcut.usesFnKey
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
        }

        return nil
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        hotkeyManager.onEscapeKeyPressed = { [weak self] in
            self?.handleEscapeKeyPress() ?? false
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyMonitoringErrorMessage = nil
        hotkeyManager.onShortcutEvent = nil
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
        ShortcutConfiguration(hold: holdShortcut, toggle: toggleShortcut, copyAgain: copyAgainShortcut)
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

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        if event == .copyAgainTriggered {
            copyLastTranscriptToPasteboard()
            return
        }

        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else {
            return
        }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
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

    private func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }

        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func cancelTranscription() {
        guard isTranscribing else { return }

        transcriptionTask?.cancel()
        transcriptionTask = nil
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        isRecording = false
        isTranscribing = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
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

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        guard !isRecording && !isTranscribing else { return }
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
                DispatchQueue.main.async {
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
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        overlayManager.dismiss()
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

    private func restoreAudioInterruptionIfNeeded() {
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

    private func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination("LocalFlow dictation in progress")
        automaticTerminationDisabled = false
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
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
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.clearPendingOverlayDismissToken()
            self.overlayManager.showInitializing(
                mode: self.activeRecordingTriggerMode ?? triggerMode
            )
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
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
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                self.handleRecordingFailure(error)
            }
        }

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async {
                    guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelRecordingInitializationTimer()
                    guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                    self.handleRecordingFailure(error)
                }
            }
        }
    }

    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        audioRecorder.cleanup()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        activeRecordingTriggerMode = nil
        shortcutSessionController.reset()
        endCriticalDictationActivity()
        errorMessage = formattedRecordingStartError(error)
        statusText = "Error"
        overlayManager.dismiss()
        refreshAvailableMicrophonesIfNeeded()
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
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        lastRawTranscript = ""
        lastOutputTranscript = ""
        lastTranscriptionStatus = ""
        debugStatusMessage = "Preparing audio"
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        playAlertSound(named: "Pop")
        overlayManager.showTranscribing()
        audioRecorder.stopRecording { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.isTranscribing = false
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.errorMessage = "No audio recorded"
                self.statusText = "Error"
                self.overlayManager.dismiss()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }
            guard self.isTranscribing else {
                self.audioRecorder.cleanup()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }
            let savedAudio = Self.saveAudioFile(from: fileURL)
            let input = savedAudio?.fileURL ?? fileURL
            self.transcribingAudioFileName = savedAudio?.fileName
            let audioSeconds = Self.audioDuration(of: input)
            self.statusText = "Transcribing locally..."
            self.debugStatusMessage = "Transcribing audio"
            self.transcriptionTask?.cancel()
            self.transcriptionTask = Task {
                do {
                    let raw = try await LocalParakeetService.shared.transcribe(fileURL: input)
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        let result = LocalDictationCore.process(raw, macros: self.voiceMacros,
                                                               pressEnterEnabled: self.isPressEnterVoiceCommandEnabled,
                                                               spokenDelimitersEnabled: self.isSpokenDelimitersEnabled)
                        self.lastRawTranscript = result.rawTranscript
                        self.lastOutputTranscript = result.output
                        self.lastTranscriptionStatus = result.status
                        self.recordPipelineHistoryEntry(rawTranscript: result.rawTranscript, transcript: result.output,
                                                        status: result.status, audioFileName: savedAudio?.fileName)
                        // Count spoken words: macros can expand the output and commands remove words.
                        if let audioSeconds {
                            self.dictationStats.record(words: DictationStats.wordCount(result.rawTranscript),
                                                       seconds: audioSeconds)
                        }
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        self.lastTranscript = result.output
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.debugStatusMessage = "Done"
                        let completionStatus = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
                        let enterStatus = "Pressed Enter"
                        self.clearPendingOverlayDismissToken()
                        if !self.showPostTranscriptionUpdateReminderIfNeeded() { self.overlayManager.dismiss() }
                        if result.output.isEmpty {
                            self.statusText = result.shouldPressEnter ? enterStatus : "Nothing to transcribe"
                            if result.shouldPressEnter { self.pressEnterWhenShortcutReleased() }
                        } else {
                            self.statusText = completionStatus
                            let pendingRestore = self.writeTranscriptToPasteboard(result.output)
                            self.pasteAtCursorWhenShortcutReleased {
                                if result.shouldPressEnter {
                                    self.pressEnterAfterPaste { self.restoreClipboardIfNeeded(pendingRestore) }
                                } else {
                                    self.restoreClipboardIfNeeded(pendingRestore)
                                }
                            }
                        }
                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()
                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatus, "Nothing to transcribe", enterStatus])
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.transcriptionTask = nil
                        self.endCriticalDictationActivity()
                    }
                } catch {
                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        let message = self.formattedTranscriptionError(error)
                        self.errorMessage = message
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.statusText = "Error"
                        self.overlayManager.showError(message)
                        self.lastTranscriptionStatus = "Error: \(message)"
                        self.recordPipelineHistoryEntry(rawTranscript: "", transcript: "", status: self.lastTranscriptionStatus,
                                                        audioFileName: savedAudio?.fileName)
                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()
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

    /// Reads only the file header, so this is cheap enough for the main thread.
    private static func audioDuration(of url: URL) -> TimeInterval? {
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
            self.overlayManager.updateAudioLevel(level)
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

    @MainActor
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

    @MainActor
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

    @MainActor
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
    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        // Append a space when ending with sentence-ending punctuation so the
        // next dictation does not jam against the prior period.
        let textToWrite: String
        if let last = transcript.last, ".!?".contains(last) {
            textToWrite = transcript + " "
        } else {
            textToWrite = transcript
        }

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

    private func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pasteAtCursor()
            completion?()
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

    private func cancelRecordingInitializationTimer() {
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
