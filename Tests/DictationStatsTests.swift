import Foundation

enum DictationStatsTests {
    static func run() {
        testWordCount()
        testInvalidDictationsAreIgnored()
        testAverageWaitsForEnoughAudio()
        testAverageIsWeightedByTime()
        testRoundTripsThroughStorage()
    }

    private static func testWordCount() {
        TestSupport.expectEqual(DictationStats.wordCount(""), 0)
        TestSupport.expectEqual(DictationStats.wordCount("  \n\t "), 0)
        TestSupport.expectEqual(DictationStats.wordCount("Synthetic  phrase,\nsecond line"), 4)
        TestSupport.expectEqual(DictationStats.wordCount(" don't stop "), 2)
    }

    private static func testInvalidDictationsAreIgnored() {
        var stats = DictationStats()
        stats.record(words: 0, seconds: 5)
        stats.record(words: 5, seconds: 0)
        stats.record(words: 5, seconds: .nan)
        stats.record(words: 5, seconds: .infinity)
        TestSupport.expectEqual(stats, DictationStats())
    }

    private static func testAverageWaitsForEnoughAudio() {
        var stats = DictationStats()
        stats.record(words: 12, seconds: 6)
        TestSupport.expectEqual(stats.wordsPerMinute, nil)
        TestSupport.expectEqual(stats.lastWordsPerMinute, 120)
        stats.record(words: 8, seconds: 4)
        TestSupport.expectEqual(stats.wordsPerMinute, 120)
    }

    private static func testAverageIsWeightedByTime() {
        var stats = DictationStats()
        stats.record(words: 30, seconds: 10)  // 180 WPM
        stats.record(words: 2, seconds: 2)    // 60 WPM
        // 32 words in 12 seconds, not the 120 WPM mean of the two rates.
        TestSupport.expectEqual(stats.wordsPerMinute, 160)
        TestSupport.expectEqual(stats.lastWordsPerMinute, 60)
        TestSupport.expectEqual(stats.dictationCount, 2)
        TestSupport.expectEqual(stats.totalWords, 32)
    }

    private static func testRoundTripsThroughStorage() {
        var stats = DictationStats()
        stats.record(words: 25, seconds: 11)
        let data = try! JSONEncoder().encode(stats)
        TestSupport.expectEqual(try! JSONDecoder().decode(DictationStats.self, from: data), stats)
    }
}
