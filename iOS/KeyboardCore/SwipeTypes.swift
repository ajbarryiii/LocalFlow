import Foundation

/// One touch sample of a swipe: key-area points and the touch's timestamp in seconds
/// (ARCHITECTURE.md, "Typing model v4 and swipe typing").
struct SwipeSample: Equatable, Sendable {
    var x: Double
    var y: Double
    var t: TimeInterval
}

/// Decoder settings, read from the swipe bundle's `bundle.json`.
struct SwipeDecodeConfig: Equatable, Sendable {
    var beam = 32
    var topK = 5
    var lengthPower = 0.0
    var freqWeight = 0.02
    var lengthBonus = 0.0
}

/// A decoded word and its score; higher is better.
struct SwipeCandidate: Equatable, Sendable {
    var word: String
    var score: Double
}
