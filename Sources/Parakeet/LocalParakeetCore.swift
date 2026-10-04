import CryptoKit
import Foundation

enum LocalParakeetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum LocalParakeetCore {
    static let modelID = "parakeet-v2-ternary"
    static let sampleRate = 16_000
    static let maxSamples = 15 * sampleRate

    static func isLocalModel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modelID
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bucket(samples: Int) throws -> Int {
        guard samples > 0, samples <= maxSamples else {
            throw LocalParakeetError.invalid("Local transcription chunk must contain 1–240000 samples.")
        }
        return [2, 4, 8, 15].first { samples <= $0 * sampleRate }!
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
