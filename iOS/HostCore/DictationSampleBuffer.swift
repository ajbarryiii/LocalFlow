import Foundation

/// Collects 16 kHz mono samples for the one request that is recording. The audio tap appends from
/// its own thread for the whole session; anything it delivers while no request is recording is
/// dropped on the spot and never retained. One lock owns all sample mutation.
final class DictationSampleBuffer: @unchecked Sendable {
    enum AppendOutcome: Equatable, Sendable {
        case dropped
        /// The first samples of this recording: the request can move from starting to recording.
        case started(generation: UInt64)
        case accepted
        /// This append filled the buffer to `maxDuration` (reported once, taking precedence over
        /// `started`); later appends are dropped until the host finishes the request.
        case reachedLimit(generation: UInt64)
    }

    static let sampleRate: Double = 16_000

    let maxSampleCount: Int

    private let lock = NSLock()
    private var requestID: UUID?
    private var currentGeneration: UInt64 = 0
    private var samples: [Float] = []
    private var meter = LevelMeter()

    init(maxDuration: TimeInterval = DictationProtocol.maxDictationDuration) {
        maxSampleCount = max(0, Int(maxDuration * Self.sampleRate))
    }

    /// The request being recorded, if any.
    var recordingRequestID: UUID? { locked { requestID } }

    /// Increases with every `begin`, so asynchronous completions can tell recordings apart.
    var generation: UInt64 { locked { currentGeneration } }

    var recordedDuration: TimeInterval { locked { Double(samples.count) / Self.sampleRate } }

    var hasReachedLimit: Bool { locked { requestID != nil && samples.count >= maxSampleCount } }

    /// Normalized input level in 0...1 while recording, otherwise 0.
    var level: Float { locked { requestID == nil ? 0 : meter.level } }

    /// Starts accepting samples for `requestID`, discarding anything held for an earlier request.
    @discardableResult
    func begin(requestID: UUID) -> UInt64 {
        locked {
            reset()
            self.requestID = requestID
            currentGeneration += 1
            samples.reserveCapacity(min(maxSampleCount, Int(30 * Self.sampleRate)))
            return currentGeneration
        }
    }

    @discardableResult
    func append<Samples: Collection>(_ newSamples: Samples) -> AppendOutcome where Samples.Element == Float {
        locked {
            guard requestID != nil, samples.count < maxSampleCount, !newSamples.isEmpty else { return .dropped }
            let isFirst = samples.isEmpty
            let accepted = newSamples.prefix(maxSampleCount - samples.count)
            samples.append(contentsOf: accepted)
            meter.update(with: accepted)
            if samples.count >= maxSampleCount { return .reachedLimit(generation: currentGeneration) }
            return isFirst ? .started(generation: currentGeneration) : .accepted
        }
    }

    /// Stops accepting and drains in one step, so no tap callback can append after the snapshot.
    /// Returns nil, changing nothing, unless `requestID` is the one recording.
    func finish(requestID: UUID) -> [Float]? {
        locked {
            guard self.requestID == requestID else { return nil }
            let collected = samples
            reset()
            return collected
        }
    }

    /// Discards the recording for `requestID`; returns false, changing nothing, for any other request.
    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        locked {
            guard self.requestID == requestID else { return false }
            reset()
            return true
        }
    }

    /// Discards whatever is recording, for example when the session ends.
    func cancelAll() {
        locked { reset() }
    }

    private func reset() {
        requestID = nil
        samples = []
        meter = LevelMeter()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// RMS in dBFS mapped onto a fixed speech window, with a fast attack and slow release so the
/// keyboard's level bars rise with speech and settle smoothly.
private struct LevelMeter {
    private static let floorDB: Float = -55
    private static let ceilingDB: Float = -15
    private static let attackBlend: Float = 0.5
    private static let releaseBlend: Float = 0.15

    private(set) var level: Float = 0

    mutating func update<Samples: Collection>(with samples: Samples) where Samples.Element == Float {
        guard !samples.isEmpty else { return }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms.isFinite else { return }
        let levelDB = 20 * log10f(max(rms, 0.000_01))
        let target = min(max((levelDB - Self.floorDB) / (Self.ceilingDB - Self.floorDB), 0), 1)
        level += (target - level) * (target > level ? Self.attackBlend : Self.releaseBlend)
    }
}
