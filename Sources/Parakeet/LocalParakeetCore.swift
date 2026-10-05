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
    static let maxSamples = 15 * sampleRate
    static let buckets = [2, 4, 8, 15]

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bucket(samples: Int) throws -> Int {
        guard samples > 0, samples <= maxSamples else {
            throw LocalParakeetError.invalid("Local transcription chunk must contain 1–240000 samples.")
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

enum ParakeetStartupStrategy: String {
    case allBuckets = "all"
    case fifteenSecondsFirst = "fifteen-first"

    // Dictation becomes usable after one function rather than all four.
    static let applicationDefault: Self = .fifteenSecondsFirst

    var initialBuckets: [Int] {
        self == .fifteenSecondsFirst ? [15] : LocalParakeetCore.buckets
    }
}

/// Used only on the service's serial queue. Failed warmups can be retried,
/// while successful preparation and transcription reuse the same model.
final class ParakeetModelCache<Model> {
    private var models: [Int: Model] = [:]
    private var prepared: Set<Int> = []

    func model(for bucket: Int, load: (Int) throws -> Model) throws -> Model {
        if let model = models[bucket] { return model }
        let model = try load(bucket)
        models[bucket] = model
        return model
    }

    func transcriptionBucket(samples: Int, strategy: ParakeetStartupStrategy) throws -> Int {
        let preferred = try LocalParakeetCore.bucket(samples: samples)
        if strategy == .fifteenSecondsFirst, !prepared.contains(preferred), prepared.contains(15) {
            return 15
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
