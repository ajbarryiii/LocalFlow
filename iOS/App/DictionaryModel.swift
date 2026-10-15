import Foundation
import UIKit

/// `DictionaryLibrary` (HostCore) as SwiftUI state. Every change hands the transcriber a new snapshot.
@MainActor
final class DictionaryModel: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var loadFailed = false
    @Published private(set) var canEdit = false

    /// The bundled model's vocabulary, so entries the model can't produce are rejected.
    let encoder: BPEEncoder?
    private let library: DictionaryLibrary
    private let transcriber: ParakeetTranscriber

    init(transcriber: ParakeetTranscriber, defaults: UserDefaults = .standard) {
        let directory = LocalParakeetService.isAvailable ? LocalParakeetService.bundleDirectory : nil
        encoder = directory.flatMap { try? BPEEncoder(vocabularyFile: $0.appendingPathComponent("vocabulary.json")) }
        library = DictionaryLibrary(defaults: defaults, encoder: encoder)
        self.transcriber = transcriber
        library.onChange = { [weak self] in self?.sync() }
        sync()
    }

    var hasVocabulary: Bool { encoder != nil }
    var isFull: Bool { library.isFull }

    func save(text: String, strength: Float, replacing original: DictionaryKey?) -> String? {
        library.save(text: text, strength: strength, replacing: original)
    }

    func setStrength(_ strength: Float, for key: DictionaryKey) -> String? {
        library.setStrength(strength, for: key)
    }

    func remove(_ key: DictionaryKey) {
        library.remove(key)
    }

    func reset() {
        library.reset()
    }

    /// Inline validation for the editor; nil while the text is blank.
    func validationMessage(text: String, strength: Float) -> String? {
        guard !text.unicodeScalars.allSatisfy(DictionaryText.isWhitespace) else { return nil }
        if case .failure(let error) = DictionaryValidation.validate(text: text, strength: strength, encoder: encoder) {
            return error.message
        }
        return nil
    }

    private func sync() {
        entries = library.entries
        loadFailed = library.loadFailed
        canEdit = library.canEdit
        transcriber.useDictionary(DictionarySnapshot(revision: library.revision, entries: library.snapshotEntries))
    }
}

/// One "Find strength" run: permission, a paused Flow session, the recording, then the probe.
@MainActor
final class StrengthProbeModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case recording
        case checking
        case finished(StrengthProbe.Result)
        case failed(String)
        case microphoneDenied
    }

    /// Shorter recordings are treated as nothing heard.
    static let minimumSamples = Int(0.3 * DictationSampleBuffer.sampleRate)

    @Published private(set) var phase = Phase.starting
    @Published private(set) var level: Float = 0
    /// A Flow session was ended for the recording and starts again when the sheet closes.
    @Published private(set) var pausedSession = false

    let word: String
    private let recorder = VoiceSampleRecorder()
    private weak var host: HostSessionController?
    private var task: Task<Void, Never>?
    private var levelTimer: Timer?

    init(word: String) {
        self.word = word
        recorder.onLimit = { [weak self] in self?.done() }
        recorder.onInterrupted = { [weak self] in self?.fail("Recording stopped because the microphone was interrupted.") }
    }

    func start(host: HostSessionController) {
        guard task == nil, phase == .starting else { return }
        self.host = host
        guard !host.isDictationInProgress else {
            phase = .failed("Finish the dictation in progress first.")
            return
        }
        host.prepareModel()   // in parallel with the recording
        task = Task { [weak self] in await self?.beginRecording() }
    }

    func done() {
        guard phase == .recording, let host else { return }
        stopLevelTimer()
        phase = .checking
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            guard let samples = await recorder.finish(), samples.count >= Self.minimumSamples else {
                if !Task.isCancelled { fail("Nothing was heard. Try again and say the sentence aloud.") }
                return
            }
            do {
                let result = try await host.transcriber.probeStrength(samples: samples, word: word)
                guard !Task.isCancelled else { return }
                phase = .finished(result)
            } catch {
                if !Task.isCancelled { fail("LocalFlow couldn't check this recording. Try again.") }
            }
        }
    }

    /// "Try another sentence": records again; a paused session stays paused.
    func retry() {
        guard let host else { return }
        cancelWork()
        phase = .starting
        start(host: host)
    }

    /// The app left the foreground: a recording in progress is discarded.
    func leftForeground() {
        guard phase == .starting || phase == .recording else { return }
        cancelWork()
        phase = .failed("Recording stopped because LocalFlow left the screen.")
    }

    /// The sheet closed: everything is released, and a paused session starts again if the app is in front.
    func close() {
        cancelWork()
        if pausedSession, let host, UIApplication.shared.applicationState == .active {
            host.startSession()
        }
        pausedSession = false
    }

    private func beginRecording() async {
        guard let host else { return }
        switch recorder.permission {
        case .granted:
            break
        case .denied:
            phase = .microphoneDenied
            return
        case .undetermined:
            let granted = await recorder.requestPermission()
            guard !Task.isCancelled, phase == .starting else { return }
            guard granted else {
                phase = .microphoneDenied
                return
            }
        }
        guard UIApplication.shared.applicationState == .active else {
            return fail("Recording stopped because LocalFlow left the screen.")
        }
        // The session owns the microphone; this recording needs its own capture.
        if host.session != .inactive {
            pausedSession = true
            host.endSession()
        }
        do {
            try recorder.start(useBuiltInMicrophone: host.preferences.useBuiltInMicrophone)
        } catch {
            return fail("The microphone could not start. Try again.")
        }
        phase = .recording
        startLevelTimer()
    }

    private func fail(_ message: String) {
        cancelWork()
        phase = .failed(message)
    }

    private func cancelWork() {
        task?.cancel()
        task = nil
        recorder.cancel()
        stopLevelTimer()
    }

    private func startLevelTimer() {
        stopLevelTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.recorder.level
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
    }
}
