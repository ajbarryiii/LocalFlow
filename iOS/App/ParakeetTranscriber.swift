import CoreML
import Foundation
import UIKit

/// One dictation's measurements for Diagnostics. Content-free and held in memory only.
struct DictationMeasurement: Identifiable, Sendable {
    typealias Outcome = TranscriptionEngine.AttemptReport.Outcome

    let id = UUID()
    var audioSeconds: Double
    /// Waiting for readiness, which includes preparation when the model was cold.
    var waitMilliseconds: Double
    var transcriptionMilliseconds: Double
    var computeUnits: String
    var inBackground: Bool
    var outcome: Outcome
    /// A content-free explanation of a failure, such as the iOS 27 background entitlement.
    var hint: ComputeFailureHint?
    var footprint: ProcessMemory.Footprint?
}

struct PreparationMeasurement: Sendable {
    var seconds: Double
    var computeUnits: String
    var inBackground: Bool
    var succeeded: Bool
    var footprint: ProcessMemory.Footprint?
}

/// The model runtime for SwiftUI and Diagnostics. The work is done by `TranscriptionEngine` (HostCore),
/// which the session core uses directly; this adds the Parakeet runtime, the persisted preparation
/// estimate and in-memory measurements.
@MainActor
final class ParakeetTranscriber: ObservableObject {
    static let maxMeasurements = 10

    let engine: TranscriptionEngine
    @Published private(set) var modelState: HostStatus.Model
    @Published private(set) var preparationStartedAt: Date?
    @Published private(set) var lastPreparation: PreparationMeasurement?
    @Published private(set) var measurements: [DictationMeasurement] = []
    /// The compute units of the loaded runtime, nil when none is loaded. Read-only: always the Neural Engine.
    @Published private(set) var activeUnits: ComputePolicy.Units?
    /// The hint of the most recent failed dictation, cleared by the next success. For Diagnostics.
    @Published private(set) var lastFailureHint: ComputeFailureHint?

    /// Called after every model state change, so the session publishes it to the keyboard.
    var onStateChange: (@MainActor () -> Void)?

    private let preferences: AppPreferences
    private let dictionary = DictionarySnapshotBox()

    init(preferences: AppPreferences) {
        self.preferences = preferences
        let directory = LocalParakeetService.isAvailable ? LocalParakeetService.bundleDirectory : nil
        let dictionary = self.dictionary
        engine = TranscriptionEngine(
            isAvailable: directory != nil, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            isInBackground: { UIApplication.shared.applicationState == .background },
            makeRuntime: { ParakeetRuntime(units: ComputePolicy.units, directory: directory, dictionary: dictionary) })
        modelState = engine.modelState
        engine.onStateChange = { [weak self] in
            self?.sync()
            self?.onStateChange?()
        }
        engine.onPreparation = { [weak self] report in self?.recordPreparation(report) }
        engine.onAttempt = { [weak self] report in self?.recordAttempt(report) }
    }

    /// Seconds the last successful preparation took on this device, for a progress estimate.
    var estimatedPreparationSeconds: Double? { preferences.lastPreparationSeconds }

    /// The dictionary later transcriptions decode with; one already running keeps its snapshot.
    func useDictionary(_ snapshot: DictionarySnapshot) {
        dictionary.set(snapshot)
    }

    /// "Find strength" on the loaded model (contract: "Custom dictionary"). Not a dictation: no measurement.
    func probeStrength(samples: [Float], word: String) async throws -> StrengthProbe.Result {
        let snapshot = dictionary.current
        return try await engine.withReadyRuntime { runtime in
            guard let runtime = runtime as? ParakeetRuntime else { throw TranscriptionFailure.modelUnavailable }
            return try await runtime.probeStrength(samples: samples, word: word, dictionary: snapshot)
        }
    }

    func prepare() {
        engine.prepare()
        sync()
    }

    @discardableResult
    func releaseIfIdle() -> Bool {
        defer { sync() }
        return engine.releaseIfIdle()
    }

    private func sync() {
        if modelState != engine.modelState { modelState = engine.modelState }
        if preparationStartedAt != engine.preparationStartedAt { preparationStartedAt = engine.preparationStartedAt }
        let units = engine.isLoaded ? ComputePolicy.units : nil
        if activeUnits != units { activeUnits = units }
    }

    private func recordPreparation(_ report: TranscriptionEngine.PreparationReport) {
        let measurement = PreparationMeasurement(seconds: report.seconds, computeUnits: ComputePolicy.units.label,
                                                 inBackground: report.inBackground, succeeded: report.succeeded,
                                                 footprint: ProcessMemory.footprint())
        lastPreparation = measurement
        if report.succeeded { preferences.lastPreparationSeconds = report.seconds }
        sync()
        #if LOCALFLOW_SELFTEST
        SelfTest.report(measurement)
        #endif
    }

    private func recordAttempt(_ report: TranscriptionEngine.AttemptReport) {
        let measurement = DictationMeasurement(
            audioSeconds: report.audioSeconds, waitMilliseconds: report.waitSeconds * 1_000,
            transcriptionMilliseconds: report.transcriptionSeconds * 1_000,
            computeUnits: ComputePolicy.units.label, inBackground: report.inBackground, outcome: report.outcome,
            hint: report.hint, footprint: ProcessMemory.footprint())
        switch report.outcome {
        case .transcribed: lastFailureHint = nil
        case .failed: lastFailureHint = report.hint
        case .cancelled: break
        }
        measurements.insert(measurement, at: 0)
        if measurements.count > Self.maxMeasurements { measurements.removeLast(measurements.count - Self.maxMeasurements) }
        #if LOCALFLOW_SELFTEST
        SelfTest.report(measurement)
        #endif
    }
}

/// `LocalParakeetService` as a `SpeechRuntime`: one encoder function (`.fifteenSecondsFirst`) to bound
/// memory. Dropping the last reference releases the model. The model loads from the app's stable copy
/// (`ParakeetModelStore.application`), falling back to the bundle.
private final class ParakeetRuntime: SpeechRuntime {
    private let service: LocalParakeetService
    private let directory: URL?
    private let dictionary: DictionarySnapshotBox

    init(units: ComputePolicy.Units, directory: URL?, dictionary: DictionarySnapshotBox) {
        service = LocalParakeetService(startupStrategy: .fifteenSecondsFirst, computeUnits: units.mlComputeUnits,
                                       modelStore: .application)
        self.directory = directory
        self.dictionary = dictionary
    }

    func prepare() async throws {
        guard let directory else { throw TranscriptionFailure.modelUnavailable }
        try await service.prepare(directory: directory)
    }

    /// One snapshot per transcription, taken when it starts.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let directory else { throw TranscriptionFailure.modelUnavailable }
        let snapshot = dictionary.current
        guard !snapshot.entries.isEmpty else { return try await service.transcribe(samples: samples, directory: directory) }
        return try await service.transcribe(samples: samples, directory: directory, dictionary: snapshot)
    }

    func probeStrength(samples: [Float], word: String, dictionary: DictionarySnapshot) async throws -> StrengthProbe.Result {
        guard let directory else { throw TranscriptionFailure.modelUnavailable }
        return try await service.probeStrength(samples: samples, directory: directory, word: word, dictionary: dictionary)
    }
}

/// The current dictionary snapshot, set on the main actor and read when a transcription starts.
private final class DictionarySnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = DictionarySnapshot.empty

    var current: DictionarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func set(_ snapshot: DictionarySnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }
}

extension ComputeFailureHint {
    var message: String {
        switch self {
        case .backgroundNeuralEngineNeedsEntitlement:
            return "Transcription failed in the background. From iOS 27 the Neural Engine needs an entitlement this build does not have yet, so dictate with LocalFlow in the foreground for now."
        }
    }
}

extension ComputePolicy.Units {
    var mlComputeUnits: MLComputeUnits { self == .cpuOnly ? .cpuOnly : .cpuAndNeuralEngine }
    var label: String { self == .cpuOnly ? "CPU" : "CPU + Neural Engine" }
}
