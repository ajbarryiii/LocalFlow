import Foundation

/// Speaking pace across dictations. Only word and time totals are kept,
/// never transcript text.
struct DictationStats: Codable, Equatable {
    /// Below this much total audio a lifetime average is too noisy to show.
    static let minimumTotalSeconds: TimeInterval = 10

    private(set) var totalWords = 0
    private(set) var totalSeconds: TimeInterval = 0
    private(set) var dictationCount = 0
    private(set) var lastWordsPerMinute: Int?

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    mutating func record(words: Int, seconds: TimeInterval) {
        guard words > 0, seconds > 0, seconds.isFinite else { return }
        totalWords += words
        totalSeconds += seconds
        dictationCount += 1
        lastWordsPerMinute = Self.wordsPerMinute(words: words, seconds: seconds)
    }

    /// Total words over total minutes, so short dictations count for less.
    var wordsPerMinute: Int? {
        totalSeconds >= Self.minimumTotalSeconds ? Self.wordsPerMinute(words: totalWords, seconds: totalSeconds) : nil
    }

    private static func wordsPerMinute(words: Int, seconds: TimeInterval) -> Int {
        Int((Double(words) * 60 / seconds).rounded())
    }
}
