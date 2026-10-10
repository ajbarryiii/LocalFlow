import CryptoKit
import Foundation

enum LocalParakeetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum LocalParakeetCore {
    static let modelID = "localflow"
    static let sampleRate = 16_000
    static let maxSamples = 30 * sampleRate
    static let buckets = [4, 8, 15, 30]

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    // Bounded reads keep a 330 MB encoder out of memory while verifying it.
    static func sha256(fileURL: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Drain each chunk's autoreleased buffer before reading the next.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func bucket(samples: Int) throws -> Int {
        guard samples > 0, samples <= maxSamples else {
            throw LocalParakeetError.invalid("Local transcription chunk must contain 1–480000 samples.")
        }
        return buckets.first { samples <= $0 * sampleRate }!
    }

    static func detokenize(_ tokens: [Int], vocabulary: [String]) throws -> String {
        guard tokens.allSatisfy({ vocabulary.indices.contains($0) }) else {
            throw LocalParakeetError.invalid("Local model returned an invalid token.")
        }
        return tokens.map { vocabulary[$0] }.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// NeMo TDT semantics, including terminal emissions and the per-frame symbol cap.
    static func decode(length: Int, predict: (Int) throws -> Void,
                       joint: (Int) throws -> (Int, Int), check: () throws -> Void) throws -> [Int] {
        let blank = 1024
        var tokens: [Int] = [], frame = 0, lastFrame = -1, symbols = 0
        try predict(blank)
        while frame < length {
            try check()
            let (token, duration) = try joint(frame)
            guard (0...blank).contains(token), (0...4).contains(duration) else {
                throw LocalParakeetError.invalid("Invalid local model decision.")
            }
            var advance = token == blank && duration == 0 ? 1 : duration
            if token != blank {
                symbols = lastFrame == frame ? symbols + 1 : 1
                lastFrame = frame
                tokens.append(token)
                try predict(token)
                if advance == 0 && symbols >= 10 { advance = 1 }
            }
            frame += advance
        }
        return tokens
    }
}

/// Consecutive chunks of exactly `size` samples; only the final one may be
/// shorter. Streamed files and in-memory recordings share it, so both split
/// the same audio at the same boundaries.
struct ParakeetChunker {
    let size: Int
    private var pending: [Float] = []

    init(size: Int) {
        precondition(size > 0, "Chunk size must be positive")
        self.size = size
    }

    mutating func append(_ samples: [Float], emit: ([Float]) throws -> Void) rethrows {
        var rest = samples[...]
        while pending.count + rest.count >= size {
            let take = size - pending.count
            let chunk = pending + rest.prefix(take)
            pending = []
            rest = rest.dropFirst(take)
            try emit(chunk)
        }
        pending.append(contentsOf: rest)
    }

    mutating func finish(emit: ([Float]) throws -> Void) rethrows {
        let chunk = pending
        pending = []
        if !chunk.isEmpty { try emit(chunk) }
    }
}

enum ParakeetStartupStrategy: String {
    case allBuckets = "all"
    case fifteenSecondsFirst = "fifteen-first"
    case fifteenSecondsThenOthers = "fifteen-background"

    // Dictation becomes usable after one function rather than all four.
    static let applicationDefault: Self = .fifteenSecondsThenOthers

    var initialBuckets: [Int] {
        self == .allBuckets ? LocalParakeetCore.buckets : [15]
    }

    // Short functions first; the 30s function is the slowest to prepare.
    var backgroundBuckets: [Int] {
        self == .fifteenSecondsThenOthers ? [4, 8, 30] : []
    }
}

/// Used only on the service's serial queue. Failed warmups can be retried,
/// while successful preparation and transcription reuse the same model.
final class ParakeetModelCache<Model> {
    private var models: [Int: Model] = [:]
    private var prepared: Set<Int> = []

    var preparedBuckets: [Int] { prepared.sorted() }

    // Install only after prediction succeeds, and only on the owning queue.
    func installPrepared(_ model: Model, for bucket: Int) {
        guard !prepared.contains(bucket) else { return }
        models[bucket] = model
        prepared.insert(bucket)
    }

    func model(for bucket: Int, load: (Int) throws -> Model) throws -> Model {
        if let model = models[bucket] { return model }
        let model = try load(bucket)
        models[bucket] = model
        return model
    }

    // Recordings split at the largest ready function, so 30s chunks are used
    // only after that function is prepared. Until then chunks stay at 15s.
    func chunkSamples(strategy: ParakeetStartupStrategy) -> Int {
        (prepared.union(strategy.initialBuckets).max() ?? 15) * LocalParakeetCore.sampleRate
    }

    func transcriptionBucket(samples: Int, strategy: ParakeetStartupStrategy) throws -> Int {
        let preferred = try LocalParakeetCore.bucket(samples: samples)
        if strategy != .allBuckets {
            // Use the smallest ready function that can hold the input. A failed
            // 4s warmup can still benefit from a ready 8s or 15s function.
            return LocalParakeetCore.buckets.first { $0 >= preferred && prepared.contains($0) } ?? preferred
        }
        return preferred
    }

    func prepare(buckets: [Int] = LocalParakeetCore.buckets,
                 load: (Int) throws -> Model, warm: (Int, Model) throws -> Void) throws {
        for bucket in buckets where !prepared.contains(bucket) {
            let model = try model(for: bucket, load: load)
            try warm(bucket, model)
            prepared.insert(bucket)
        }
    }
}

struct ParakeetPreparationProgress: Sendable {
    let preparedBuckets: [Int]
    let isOptimizing: Bool
}

/// Control state and installation belong exclusively to ownerQueue. Only
/// makeReady runs on workerQueue, with a fresh model that is not yet in use.
/// A completed model crosses queues once, after its synchronous warmup returns.
final class ParakeetBackgroundPreparation<Model>: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private let buckets: [Int]
    private let makeReady: (Int) throws -> Model
    private let install: (Int, Model) -> Void
    private var completed: Set<Int> = []
    private var pending: [Int] = []
    private var cancelled = false
    private(set) var isPreparing = false

    init(ownerQueue: DispatchQueue, workerQueue: DispatchQueue, buckets: [Int],
         makeReady: @escaping (Int) throws -> Model, install: @escaping (Int, Model) -> Void) {
        self.ownerQueue = ownerQueue
        self.workerQueue = workerQueue
        self.buckets = buckets
        self.makeReady = makeReady
        self.install = install
    }

    // Both calls must be made on ownerQueue. Each start attempts failed buckets
    // once; repeated starts during an active pass do not duplicate work.
    func start() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !cancelled, !isPreparing else { return }
        pending = buckets.filter { !completed.contains($0) }
        scheduleNext()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        cancelled = true
        pending.removeAll()
        // An active synchronous load/prediction must finish. Its result is
        // discarded, and subsequent jobs are never scheduled for this runtime.
    }

    private func scheduleNext() {
        guard !cancelled, !pending.isEmpty else { isPreparing = false; return }
        isPreparing = true
        let bucket = pending.removeFirst()
        workerQueue.async {
            let transfer = ParakeetPreparedTransfer(Result { try self.makeReady(bucket) })
            self.ownerQueue.async {
                if !self.cancelled, case .success(let model) = transfer.result {
                    self.install(bucket, model)
                    self.completed.insert(bucket)
                }
                // A failed optimization never changes readiness of other models.
                self.scheduleNext()
            }
        }
    }
}

// Immutable handoff envelope. The background worker stops accessing the model
// before the owning queue adopts it; the model is never predicted concurrently.
private final class ParakeetPreparedTransfer<Model>: @unchecked Sendable {
    let result: Result<Model, Error>
    init(_ result: Result<Model, Error>) { self.result = result }
}

enum LocalParakeetPreparationState {
    case idle, preparing, ready, failed

    var message: String {
        switch self {
        case .idle: return "Local model has not been prepared yet."
        case .preparing: return "Preparing local model… First-time preparation may take several minutes."
        case .ready: return "Local model ready. Kept in memory for this session."
        case .failed: return "Local model preparation failed. Select the model again to retry."
        }
    }
}
