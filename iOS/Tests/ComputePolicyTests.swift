import Foundation

enum ComputePolicyTests {
    static var tests: [TestCase] {
        [
            ("alwaysTheNeuralEngine", testAlwaysTheNeuralEngine),
            ("entitlementHintOnlyForBackgroundFailuresOnIOS27", testEntitlementHint),
            ("failureCodes", testFailureCodes),
        ]
    }

    private static func testAlwaysTheNeuralEngine() {
        TestSupport.expectEqual(ComputePolicy.units, .cpuAndNeuralEngine)
    }

    private static func testEntitlementHint() {
        let hint = ComputeFailureHint.backgroundNeuralEngineNeedsEntitlement
        for failure in [TranscriptionFailure.modelFailed, .transcriptionFailed] {
            for version in [27, 28] {
                TestSupport.expectEqual(ComputePolicy.failureHint(after: failure, inBackground: true, osMajorVersion: version), hint)
            }
            TestSupport.expectEqual(ComputePolicy.failureHint(after: failure, inBackground: true, osMajorVersion: 26), nil)
            TestSupport.expectEqual(ComputePolicy.failureHint(after: failure, inBackground: false, osMajorVersion: 27), nil)
        }
        TestSupport.expectEqual(ComputePolicy.failureHint(after: .modelUnavailable, inBackground: true, osMajorVersion: 27), nil)
    }

    private static func testFailureCodes() {
        TestSupport.expectEqual(TranscriptionFailure.modelUnavailable.errorCode, .modelUnavailable)
        TestSupport.expectEqual(TranscriptionFailure.modelFailed.errorCode, .modelFailed)
        TestSupport.expectEqual(TranscriptionFailure.transcriptionFailed.errorCode, .transcriptionFailed)
    }
}

enum RecentRequestIDsTests {
    static var tests: [TestCase] {
        [
            ("boundedOldestFirst", testBoundedOldestFirst),
            ("reinsertRefreshes", testReinsertRefreshes),
        ]
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    private static func testBoundedOldestFirst() {
        var known = RecentRequestIDs(capacity: 3)
        for n in 1...5 { known.insert(id(n)) }
        TestSupport.expectEqual(known.ordered, [id(3), id(4), id(5)])
        TestSupport.expectEqual(known.set, [id(3), id(4), id(5)])
        TestSupport.expect(!known.contains(id(1)) && known.contains(id(5)), "wrong members")
        TestSupport.expectEqual(RecentRequestIDs().capacity, 32)
        TestSupport.expectEqual(RecentRequestIDs(capacity: 2, [id(1), id(2), id(3)]).ordered, [id(2), id(3)])
        TestSupport.expectEqual(RecentRequestIDs(capacity: 0).capacity, 1)
    }

    private static func testReinsertRefreshes() {
        var known = RecentRequestIDs(capacity: 3, [id(1), id(2), id(3)])
        known.insert(id(1))
        known.insert(id(4))
        TestSupport.expectEqual(known.ordered, [id(3), id(1), id(4)])
    }
}
