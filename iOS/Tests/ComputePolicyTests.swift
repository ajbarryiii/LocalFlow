import Foundation

enum ComputePolicyTests {
    static var tests: [TestCase] {
        [
            ("storedValueAndDefault", testStoredValueAndDefault),
            ("primaryUnits", testPrimaryUnits),
            ("onlyAutomaticRetriesOnceInTheBackground", testOnlyAutomaticRetriesOnceInTheBackground),
            ("failureCodes", testFailureCodes),
        ]
    }

    private static func testStoredValueAndDefault() {
        TestSupport.expectEqual(ComputePolicy(storedValue: nil), .automatic)
        TestSupport.expectEqual(ComputePolicy(storedValue: "gpu"), .automatic)
        for policy in ComputePolicy.allCases {
            TestSupport.expectEqual(ComputePolicy(storedValue: policy.rawValue), policy)
        }
    }

    private static func testPrimaryUnits() {
        TestSupport.expectEqual(ComputePolicy.automatic.primaryUnits, .cpuAndNeuralEngine)
        TestSupport.expectEqual(ComputePolicy.neuralEngine.primaryUnits, .cpuAndNeuralEngine)
        TestSupport.expectEqual(ComputePolicy.cpuOnly.primaryUnits, .cpuOnly)
    }

    private static func testOnlyAutomaticRetriesOnceInTheBackground() {
        for failure in [TranscriptionFailure.modelFailed, .transcriptionFailed] {
            TestSupport.expect(ComputePolicy.automatic.retriesOnCPU(after: failure, inBackground: true, alreadyRetried: false),
                               "automatic did not retry \(failure)")
            TestSupport.expect(!ComputePolicy.automatic.retriesOnCPU(after: failure, inBackground: true, alreadyRetried: true),
                               "retried twice")
            TestSupport.expect(!ComputePolicy.automatic.retriesOnCPU(after: failure, inBackground: false, alreadyRetried: false),
                               "retried in the foreground")
            for policy in [ComputePolicy.neuralEngine, .cpuOnly] {
                TestSupport.expect(!policy.retriesOnCPU(after: failure, inBackground: true, alreadyRetried: false),
                                   "\(policy) retried")
            }
        }
        TestSupport.expect(!ComputePolicy.automatic.retriesOnCPU(after: .modelUnavailable, inBackground: true, alreadyRetried: false),
                           "retried without a model")
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
