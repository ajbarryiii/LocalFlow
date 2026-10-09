import CoreML
import Foundation
import UIKit

/// One dictation's measurements for Diagnostics. Content-free and held in memory only.
struct DictationMeasurement: Identifiable, Sendable {
    enum Outcome: String, Sendable { case transcribed, failed, cancelled }

    let id = UUID()
    var audioSeconds: Double
    /// Waiting for readiness, which includes preparation when the model was cold.
    var waitMilliseconds: Double = 0
    var transcriptionMilliseconds: Double = 0
    var computeUnits: String
    var inBackground: Bool
    var outcome: Outcome = .failed
    var footprint: ProcessMemory.Footprint?
}

struct PreparationMeasurement: Sendable {
    var seconds: Double
    var computeUnits: String
    var inBackground: Bool
    var succeeded: Bool
    var footprint: ProcessMemory.Footprint?
}

/// The host-owned Parakeet runtime: `LocalParakeetService(startupStrategy: .fifteenSecondsFirst)` with
/// the Diagnostics compute policy. Preparation is shared; transcription waits for it. Audio and text
/// stay in memory and nothing here logs.
@MainActor
final class ParakeetTranscriber: ObservableObject, HostTranscriber {
    static let maxMeasurements = 10

    @Published private(set) var modelState: HostStatus.Model
    @Published private(set) var preparationStartedAt: Date?
    @Published private(set) var lastPreparation: PreparationMeasurement?
    @Published private(set) var measurements: [DictationMeasurement] = []
    @Published private(set) var policy: ComputePolicy

    /// Called after every model state change, so the session publishes it to the keyboard.
    var onStateChange: (@MainActor () -> Void)?

    private let preferences: AppPreferences
    private var service: LocalParakeetService?
    private var serviceUnits: ComputePolicy.Units?
    private var preparation: Task<Void, Error>?
    private var generation: UInt64 = 0
    private var activeTranscriptions = 0

    init(preferences: AppPreferences) {
        self.preferences = preferences
        policy = preferences.computePolicy
        modelState = Self.modelDirectory == nil ? .unavailable : .notPrepared
    }

    static var modelDirectory: URL? {
        LocalParakeetService.isAvailable ? LocalParakeetService.bundleDirectory : nil
    }

    /// Seconds the last successful preparation took on this device, for a progress estimate.
    var estimatedPreparationSeconds: Double? { preferences.lastPreparationSeconds }

    var activeUnits: ComputePolicy.Units? { serviceUnits }

    func setPolicy(_ newPolicy: ComputePolicy) {
        guard newPolicy != policy else { return }
        policy = newPolicy
        preferences.computePolicy = newPolicy
        // A running transcription keeps its own service; the next one prepares with the new units.
        if let serviceUnits, serviceUnits != newPolicy.primaryUnits { release() }
    }

    // MARK: HostTranscriber

    func prepare() {
        guard let directory = Self.modelDirectory else { return setState(.unavailable) }
        guard preparation == nil else { return }
        let units = policy.primaryUnits
        let service = LocalParakeetService(startupStrategy: .fifteenSecondsFirst, computeUnits: units.mlComputeUnits)
        self.service = service
        serviceUnits = units
        generation &+= 1
        let generation = self.generation
        let started = Date()
        let startedInBackground = Self.isInBackground
        let task = Task { try await service.prepare(directory: directory) }
        preparation = task
        preparationStartedAt = started
        setState(.preparing)
        Task { [weak self] in
            let result = await task.result
            guard let self, generation == self.generation else { return }   // released or replaced meanwhile
            let seconds = Date().timeIntervalSince(started)
            let succeeded = (try? result.get()) != nil
            self.lastPreparation = PreparationMeasurement(
                seconds: seconds, computeUnits: units.label, inBackground: startedInBackground || Self.isInBackground,
                succeeded: succeeded, footprint: ProcessMemory.footprint())
            #if LOCALFLOW_SELFTEST
            SelfTest.report(self.lastPreparation!)
            #endif
            self.preparationStartedAt = nil
            if succeeded {
                self.preferences.lastPreparationSeconds = seconds
                self.setState(.ready)
            } else {
                // The next prepare() or transcription retries.
                self.preparation = nil
                self.service = nil
                self.serviceUnits = nil
                self.setState(.failed)
            }
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let directory = Self.modelDirectory else { throw TranscriptionFailure.modelUnavailable }
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        let startedInBackground = Self.isInBackground
        var measurement = DictationMeasurement(audioSeconds: Double(samples.count) / DictationSampleBuffer.sampleRate,
                                               computeUnits: policy.primaryUnits.label, inBackground: startedInBackground)
        defer { record(measurement) }
        let waitStart = Date()
        do {
            do {
                if preparation == nil { prepare() }   // never prepared, released, or failed before
                guard let preparation, let service else { throw TranscriptionFailure.modelFailed }
                measurement.computeUnits = (serviceUnits ?? policy.primaryUnits).label
                do { try await preparation.value } catch { throw TranscriptionFailure.modelFailed }
                try Task.checkCancellation()
                measurement.waitMilliseconds = Date().timeIntervalSince(waitStart) * 1_000
                let start = Date()
                let text = try await Self.transcribe(samples, on: service, directory: directory)
                measurement.transcriptionMilliseconds = Date().timeIntervalSince(start) * 1_000
                measurement.outcome = .transcribed
                return text
            } catch let failure as TranscriptionFailure
                        where policy.retriesOnCPU(after: failure, inBackground: startedInBackground || Self.isInBackground,
                                                  alreadyRetried: false) {
                // The Neural Engine may be unavailable in the background: retry once on a CPU-only
                // model, released again when this scope ends.
                measurement.computeUnits = "\(measurement.computeUnits) → \(ComputePolicy.Units.cpuOnly.label)"
                let cpu = LocalParakeetService(startupStrategy: .fifteenSecondsFirst, computeUnits: .cpuOnly)
                do { try await cpu.prepare(directory: directory) } catch { throw TranscriptionFailure.modelFailed }
                try Task.checkCancellation()
                measurement.waitMilliseconds = Date().timeIntervalSince(waitStart) * 1_000
                let start = Date()
                let text = try await Self.transcribe(samples, on: cpu, directory: directory)
                measurement.transcriptionMilliseconds = Date().timeIntervalSince(start) * 1_000
                measurement.outcome = .transcribed
                return text
            }
        } catch is CancellationError {
            measurement.outcome = .cancelled
            throw CancellationError()
        }
    }

    func releaseIfIdle() {
        guard activeTranscriptions == 0, modelState == .ready || modelState == .failed else { return }
        release()
    }

    /// Drops the runtime. A preparation still running finishes on the service's queue and is discarded.
    func release() {
        generation &+= 1
        preparation = nil
        service = nil
        serviceUnits = nil
        preparationStartedAt = nil
        setState(Self.modelDirectory == nil ? .unavailable : .notPrepared)
    }

    // MARK: Private

    private static var isInBackground: Bool { UIApplication.shared.applicationState == .background }

    private static func transcribe(_ samples: [Float], on service: LocalParakeetService, directory: URL) async throws -> String {
        do {
            return try await service.transcribe(samples: samples, directory: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.transcriptionFailed
        }
    }

    private func setState(_ state: HostStatus.Model) {
        guard state != modelState else { return }
        modelState = state
        onStateChange?()
    }

    private func record(_ measurement: DictationMeasurement) {
        var measurement = measurement
        measurement.footprint = ProcessMemory.footprint()
        measurements.insert(measurement, at: 0)
        if measurements.count > Self.maxMeasurements { measurements.removeLast(measurements.count - Self.maxMeasurements) }
        #if LOCALFLOW_SELFTEST
        SelfTest.report(measurement)
        #endif
    }
}

extension ComputePolicy {
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .neuralEngine: return "Neural Engine"
        case .cpuOnly: return "CPU only"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: return "Neural Engine, retrying once on the CPU if a transcription fails in the background."
        case .neuralEngine: return "Neural Engine only, with no fallback."
        case .cpuOnly: return "CPU only. Slower, but available in the background."
        }
    }
}

extension ComputePolicy.Units {
    var mlComputeUnits: MLComputeUnits { self == .cpuOnly ? .cpuOnly : .cpuAndNeuralEngine }
    var label: String { self == .cpuOnly ? "CPU" : "CPU + Neural Engine" }
}
