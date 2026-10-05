import Foundation

enum ParakeetBackgroundPreparationTests {
    // Cache/scheduler belong to owner; attempt bookkeeping belongs to worker.
    // Test reads occur after queue barriers or signalled completion.
    private final class State: @unchecked Sendable {
        let cache = ParakeetModelCache<Int>()
        var scheduler: ParakeetBackgroundPreparation<Int>!
        var attempts: [Int] = []
        var failedFour = false
    }

    static func run() {
        testNonblockingPreparationAndRetry()
        testCancelledRuntimeCannotInstall()
    }

    private static func wait(_ signal: DispatchSemaphore, _ message: String) {
        TestSupport.expect(signal.wait(timeout: .now() + 5) == .success, message)
    }

    private static func testNonblockingPreparationAndRetry() {
        let owner = DispatchQueue(label: "test.parakeet.owner")
        let worker = DispatchQueue(label: "test.parakeet.worker")
        let state = State()
        let twoStarted = DispatchSemaphore(value: 0), releaseTwo = DispatchSemaphore(value: 0)
        let eightStarted = DispatchSemaphore(value: 0), releaseEight = DispatchSemaphore(value: 0)
        let installedEight = DispatchSemaphore(value: 0), installedFour = DispatchSemaphore(value: 0)
        let foregroundRan = DispatchSemaphore(value: 0)
        owner.async {
            state.cache.installPrepared(15, for: 15)
            state.scheduler = ParakeetBackgroundPreparation(
                ownerQueue: owner, workerQueue: worker, buckets: [2, 4, 8], makeReady: { bucket in
                    state.attempts.append(bucket)
                    if bucket == 2 { twoStarted.signal(); releaseTwo.wait() }
                    if bucket == 4, !state.failedFour {
                        state.failedFour = true
                        throw LocalParakeetError.invalid("Synthetic warmup failure")
                    }
                    if bucket == 8 { eightStarted.signal(); releaseEight.wait() }
                    return bucket
                }, install: { bucket, model in
                    state.cache.installPrepared(model, for: bucket)
                    if bucket == 8 { installedEight.signal() }
                    if bucket == 4 { installedFour.signal() }
                })
            state.scheduler.start()
            state.scheduler.start() // An active pass must not duplicate jobs.
        }
        wait(twoStarted, "Background warmup must begin")
        owner.async {
            TestSupport.expectEqual(state.cache.preparedBuckets, [15])
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 32000, strategy: .applicationDefault), 15)
            TestSupport.expect(state.scheduler.isPreparing, "Optimization should still be active")
            foregroundRan.signal()
        }
        wait(foregroundRan, "Foreground must run while background warmup is blocked")
        releaseTwo.signal()
        wait(eightStarted, "A failed 4s warmup must not prevent the 8s attempt")
        owner.sync {
            TestSupport.expectEqual(state.cache.preparedBuckets, [2, 15])
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 32000, strategy: .applicationDefault), 2)
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 32001, strategy: .applicationDefault), 15)
        }
        releaseEight.signal()
        wait(installedEight, "Successful background model must be installed")
        owner.sync {
            TestSupport.expect(!state.scheduler.isPreparing, "A completed pass must become idle")
            TestSupport.expectEqual(state.cache.preparedBuckets, [2, 8, 15])
            // Use a ready 8s function when 4s failed, rather than warming 4s in
            // the foreground or unnecessarily falling back to 15s.
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 32001, strategy: .applicationDefault), 8)
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 128001, strategy: .applicationDefault), 15)
            state.scheduler.start()
        }
        wait(installedFour, "A later preparation request must retry failed optimization")
        worker.sync {}
        owner.sync {
            TestSupport.expectEqual(state.attempts, [2, 4, 8, 4])
            TestSupport.expectEqual(state.cache.preparedBuckets, [2, 4, 8, 15])
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 32001, strategy: .applicationDefault), 4)
            state.scheduler.start()
            TestSupport.expect(!state.scheduler.isPreparing, "Fully optimized startup must be idempotent")
        }
        worker.sync {}
        TestSupport.expectEqual(state.attempts, [2, 4, 8, 4])
    }

    private static func testCancelledRuntimeCannotInstall() {
        let owner = DispatchQueue(label: "test.parakeet.cancel-owner")
        let worker = DispatchQueue(label: "test.parakeet.cancel-worker")
        let state = State()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        owner.async {
            state.cache.installPrepared(15, for: 15)
            state.scheduler = ParakeetBackgroundPreparation(
                ownerQueue: owner, workerQueue: worker, buckets: [2, 4, 8], makeReady: { bucket in
                    state.attempts.append(bucket)
                    started.signal()
                    release.wait()
                    return bucket
                }, install: { bucket, model in state.cache.installPrepared(model, for: bucket) })
            state.scheduler.start()
        }
        wait(started, "Synthetic warmup must start before cancellation")
        owner.sync { state.scheduler.cancel() }
        release.signal()
        worker.sync {}
        owner.sync {
            TestSupport.expectEqual(state.cache.preparedBuckets, [15])
            TestSupport.expect(!state.scheduler.isPreparing, "Cancelled warmup must finish without installing")
            state.scheduler.start()
            TestSupport.expect(!state.scheduler.isPreparing, "Cancelled runtime must not restart")
        }
        worker.sync {}
        TestSupport.expectEqual(state.attempts, [2])
    }
}
