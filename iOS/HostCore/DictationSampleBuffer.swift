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
    /// Fed every accepted sample of the recording, in order, under the lock; cancelled whenever the
    /// recording is discarded or replaced, and handed over with the samples by `finishRecording`.
    private var stream: SpeechStream?
    private var meter = LevelMeter()
    private let hostClock: @Sendable () -> UInt64
    private var beginHostTime: UInt64 = 0
    private var endHostTime: UInt64?

    /// `hostClock` is the capture clock (`mach_absolute_time`, the clock of `AVAudioTime.hostTime`); tests
    /// inject their own.
    init(maxDuration: TimeInterval = DictationProtocol.maxDictationDuration,
         hostClock: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }) {
        maxSampleCount = max(0, Int(maxDuration * Self.sampleRate))
        self.hostClock = hostClock
    }

    /// The request being recorded, if any.
    var recordingRequestID: UUID? { locked { requestID } }

    /// Increases with every `begin`, so asynchronous completions can tell recordings apart.
    var generation: UInt64 { locked { currentGeneration } }

    /// The recording token: the current generation while a request is recording, nil while idle. Capture
    /// reads it before converting a buffer and hands it back to `append(_:token:)`, which drops the
    /// samples unless it still matches under the lock. Converted audio therefore never crosses a
    /// boundary, even when finish, cancel or begin runs during the conversion.
    var recordingToken: UInt64? { locked { requestID == nil ? nil : currentGeneration } }

    /// The recording token with its capture-time boundaries, read in one step. Capture keeps only frames
    /// captured at or after `begin` and, once the recording is closing, before `end`.
    var recordingWindow: RecordingWindow? {
        locked { requestID == nil ? nil : RecordingWindow(token: currentGeneration, begin: beginHostTime, end: endHostTime) }
    }

    var recordedDuration: TimeInterval { locked { Double(samples.count) / Self.sampleRate } }

    var hasReachedLimit: Bool { locked { requestID != nil && samples.count >= maxSampleCount } }

    /// Normalized input level in 0...1 while recording, otherwise 0.
    var level: Float { locked { requestID == nil ? 0 : meter.level } }

    /// Starts accepting samples for `requestID`, discarding anything held for an earlier request. `stream`,
    /// if given, receives exactly the samples `finishRecording` will return.
    @discardableResult
    func begin(requestID: UUID, stream: SpeechStream? = nil) -> UInt64 {
        locked {
            reset()
            self.requestID = requestID
            self.stream = stream
            currentGeneration += 1
            beginHostTime = hostClock()
            samples.reserveCapacity(min(maxSampleCount, Int(30 * Self.sampleRate)))
            return currentGeneration
        }
    }

    @discardableResult
    func append<Samples: Collection>(_ newSamples: Samples) -> AppendOutcome where Samples.Element == Float {
        locked {
            appendLocked(newSamples)
        }
    }

    /// Appends only if `token` (read from `recordingToken` before converting) still names the recording.
    @discardableResult
    func append<Samples: Collection>(_ newSamples: Samples, token: UInt64) -> AppendOutcome where Samples.Element == Float {
        locked {
            guard requestID != nil, currentGeneration == token else { return .dropped }
            return appendLocked(newSamples)
        }
    }

    /// Marks the end of `requestID`'s audio at the current capture time. Appends still land, trimmed to
    /// frames captured before the end, until `finish` drains: audio captured just before the user stopped
    /// is still in flight. False, changing nothing, unless `requestID` is recording and not yet closing.
    @discardableResult
    func close(requestID: UUID) -> Bool {
        locked {
            guard self.requestID == requestID, endHostTime == nil else { return false }
            endHostTime = hostClock()
            return true
        }
    }

    /// Stops accepting and drains in one step, so no tap callback can append after the snapshot.
    /// Returns nil, changing nothing, unless `requestID` is the one recording.
    func finish(requestID: UUID) -> [Float]? {
        let audio = finishRecording(requestID: requestID)
        audio?.stream?.cancel()
        return audio?.samples
    }

    /// As `finish(requestID:)`, with the stream that was fed exactly the returned samples.
    func finishRecording(requestID: UUID) -> RecordedAudio? {
        locked {
            guard self.requestID == requestID else { return nil }
            let audio = RecordedAudio(samples: samples, stream: stream)
            stream = nil
            reset()
            return audio
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

    private func appendLocked<Samples: Collection>(_ newSamples: Samples) -> AppendOutcome where Samples.Element == Float {
        guard requestID != nil, samples.count < maxSampleCount, !newSamples.isEmpty else { return .dropped }
        let isFirst = samples.isEmpty
        let accepted = newSamples.prefix(maxSampleCount - samples.count)
        samples.append(contentsOf: accepted)
        stream?.append(Array(accepted))
        meter.update(with: accepted)
        if samples.count >= maxSampleCount { return .reachedLimit(generation: currentGeneration) }
        return isFirst ? .started(generation: currentGeneration) : .accepted
    }

    private func reset() {
        stream?.cancel()
        stream = nil
        requestID = nil
        endHostTime = nil
        samples = []
        meter = LevelMeter()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// RMS in dBFS mapped onto the speaker's own range, with a fast attack and a release that still falls between
/// syllables, so the keyboard's wave and the app's level bars follow the voice. Round 10 (owner: the wave was "slow,
/// consistent"): it falls in about 0.2 s. Round 11 (Opus, round 10: a fixed window topping out at -12 dBFS, tuned on
/// `say`'s loud voice, left a quiet phrase at -32 dBFS flat; a real voice at arm's length often sits at -35 to -25): the
/// window runs up to the recording's recent loudest moment, a peak that holds for a moment and then sinks slowly, never
/// below a floor, and down 27 dB from it, never below an absolute noise gate. Soft, normal and loud speakers alike reach the top on their syllables;
/// a quiet room (below the gate) stays at 0, and the floor keeps a murmur just above the gate small.
struct LevelMeter {
    /// Below this the input is the room, not a voice: 0.
    static let gateDB: Float = -45
    /// The peak never sinks below this, so a murmur just above the gate is never stretched to the top.
    static let peakFloorDB: Float = -30
    /// How long the peak holds after the loudest moment, and how fast it then sinks.
    static let peakHold: Float = 1.2
    static let peakDecayDBPerSecond: Float = 6
    /// The window's depth under the peak at most, so a loud speaker's gaps between syllables still read as gaps.
    static let rangeDB: Float = 27
    private static let attackBlend: Float = 0.8
    private static let releaseBlend: Float = 0.55

    private let sampleRate: Float
    private(set) var level: Float = 0
    private var peakDB = Self.peakFloorDB
    private var sincePeak: Float = 0

    init(sampleRate: Double = DictationSampleBuffer.sampleRate) {
        self.sampleRate = Float(sampleRate)
    }

    mutating func update<Samples: Collection>(with samples: Samples) where Samples.Element == Float {
        guard !samples.isEmpty else { return }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms.isFinite else { return }
        let levelDB = 20 * log10f(max(rms, 0.000_01))
        sincePeak += Float(samples.count) / sampleRate
        if sincePeak > Self.peakHold {
            peakDB -= Self.peakDecayDBPerSecond * min(sincePeak - Self.peakHold, Float(samples.count) / sampleRate)
        }
        if levelDB >= peakDB {
            peakDB = levelDB
            sincePeak = 0
        }
        peakDB = max(peakDB, Self.peakFloorDB)
        let low = max(Self.gateDB, peakDB - Self.rangeDB)
        let target = min(max((levelDB - low) / (peakDB - low), 0), 1)
        level += (target - level) * (target > level ? Self.attackBlend : Self.releaseBlend)
    }
}
