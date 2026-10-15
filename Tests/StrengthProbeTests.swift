import Foundation

/// Contract tests for "Find strength" (iOS/ARCHITECTURE.md, "Custom dictionary"). All text is invented.
enum StrengthProbeTests {
    static func run() {
        testContains()
        testAcceptance()
        testFindOrder()
        testOutcomes()
        testDecodeFailureStops()
    }

    private static func testContains() {
        TestSupport.expect(StrengthProbe.contains("Zorblax", in: "we shipped zorblax, finally."), "folded, edge punctuation")
        TestSupport.expect(StrengthProbe.contains("Quint Morrow", in: "ask quint morrow today"), "a phrase")
        TestSupport.expect(!StrengthProbe.contains("Quint Morrow", in: "ask quint and morrow"), "words apart")
        TestSupport.expect(!StrengthProbe.contains("Zorblax", in: "zorb lax"), "split word")
        TestSupport.expect(!StrengthProbe.contains("Zorblax", in: ""), "empty text")
    }

    private static func testAcceptance() {
        let base = "we moved the service to zor blacks last week"
        TestSupport.expect(StrengthProbe.accepts(word: "Zorblax", base: base,
                                                 decoded: "we moved the service to Zorblax last week"),
                           "a misheard block replaced by the word")
        TestSupport.expect(!StrengthProbe.accepts(word: "Zorblax", base: base,
                                                  decoded: "we moved the service to Zorblax last month"),
                           "another change elsewhere")
        TestSupport.expect(!StrengthProbe.accepts(word: "Zorblax", base: base, decoded: base), "no change")
        TestSupport.expect(!StrengthProbe.accepts(word: "Zorblax", base: base,
                                                  decoded: "we moved the service to Zorblax lax week"),
                           "the word plus a neighbouring change")
        // The replaced side may be at most two words longer than the word.
        TestSupport.expect(StrengthProbe.accepts(word: "Zorblax", base: "use zor bla ax now", decoded: "use Zorblax now"),
                           "three words for one")
        TestSupport.expect(!StrengthProbe.accepts(word: "Zorblax", base: "use it with zor blacks now",
                                                  decoded: "use Zorblax now"),
                           "a block swallowing four words")
        TestSupport.expect(StrengthProbe.accepts(word: "Zorblax", base: "zor blacks and zor blacks",
                                                 decoded: "Zorblax and Zorblax"),
                           "every occurrence replaced")
        TestSupport.expect(StrengthProbe.accepts(word: "Zorblax", base: "we use it", decoded: "we use Zorblax it"),
                           "an inserted word")
    }

    private static func testFindOrder() {
        var tried: [Float] = []
        let result = StrengthProbe.find(word: "Zorblax", base: "ship zor blacks today") { strength in
            tried.append(strength)
            return strength >= 2.83 ? "ship Zorblax today" : "ship zor blacks today"
        }
        TestSupport.expectEqual(tried, [1, 1.41, 2, 2.83])
        TestSupport.expectEqual(result, StrengthProbe.Result(outcome: .recognized(strength: 2.83),
                                                             base: "ship zor blacks today", boosted: "ship Zorblax today"))
    }

    private static func testOutcomes() {
        var calls = 0
        let already = StrengthProbe.find(word: "Zorblax", base: "ship Zorblax today") { _ in
            calls += 1
            return ""
        }
        TestSupport.expectEqual(already.outcome, .alreadyRecognized)
        TestSupport.expectEqual(already.boosted, nil)
        TestSupport.expectEqual(calls, 0)

        var tried: [Float] = []
        let missed = StrengthProbe.find(word: "Zorblax", base: "ship zor blacks today") { strength in
            tried.append(strength)
            return "ship Zorblax tomorrow"
        }
        TestSupport.expectEqual(missed, StrengthProbe.Result(outcome: .notRecognized, base: "ship zor blacks today",
                                                             boosted: nil))
        TestSupport.expectEqual(tried, VerifyDecision.strengths)
    }

    private struct Stop: Error {}

    private static func testDecodeFailureStops() {
        var calls = 0
        do {
            _ = try StrengthProbe.find(word: "Zorblax", base: "ship zor blacks today") { _ -> String in
                calls += 1
                throw Stop()
            }
            TestSupport.expect(false, "a failed decode must end the probe")
        } catch {
            TestSupport.expect(error is Stop, "the decode error is passed on")
        }
        TestSupport.expectEqual(calls, 1)
    }
}
