import Foundation

enum ParakeetBackgroundPreparationTests {
    // Cache/scheduler belong to owner; attempt bookkeeping belongs to worker.
    // Test reads occur after queue barriers or signalled completion.
    private final class State: @unchecked Sendable {
        let cache = ParakeetModelCache<Int>()
        var scheduler: ParakeetBackgroundPreparation<Int>!
        var attempts: [Int] = []
        var failedEight = false
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
        let fourStarted = DispatchSemaphore(value: 0), releaseFour = DispatchSemaphore(value: 0)
        let thirtyStarted = DispatchSemaphore(value: 0), releaseThirty = DispatchSemaphore(value: 0)
        let installedThirty = DispatchSemaphore(value: 0), installedEight = DispatchSemaphore(value: 0)
        let foregroundRan = DispatchSemaphore(value: 0)
        owner.async {
            state.cache.installPrepared(15, for: 15)
            state.scheduler = ParakeetBackgroundPreparation(
                ownerQueue: owner, workerQueue: worker, buckets: [4, 8, 30], makeReady: { bucket in
                    state.attempts.append(bucket)
                    if bucket == 4 { fourStarted.signal(); releaseFour.wait() }
                    if bucket == 8, !state.failedEight {
                        state.failedEight = true
                        throw LocalParakeetError.invalid("Synthetic warmup failure")
                    }
                    if bucket == 30 { thirtyStarted.signal(); releaseThirty.wait() }
                    return bucket
                }, install: { bucket, model in
                    state.cache.installPrepared(model, for: bucket)
                    if bucket == 30 { installedThirty.signal() }
                    if bucket == 8 { installedEight.signal() }
                })
            state.scheduler.start()
            state.scheduler.start() // An active pass must not duplicate jobs.
        }
        wait(fourStarted, "Background warmup must begin")
        owner.async {
            TestSupport.expectEqual(state.cache.preparedBuckets, [15])
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 64000, strategy: .applicationDefault), 15)
            TestSupport.expectEqual(state.cache.chunkSamples(strategy: .applicationDefault), 240000)
            TestSupport.expect(state.scheduler.isPreparing, "Optimization should still be active")
            foregroundRan.signal()
        }
        wait(foregroundRan, "Foreground must run while background warmup is blocked")
        releaseFour.signal()
        wait(thirtyStarted, "A failed 8s warmup must not prevent the 30s attempt")
        owner.sync {
            TestSupport.expectEqual(state.cache.preparedBuckets, [4, 15])
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 64000, strategy: .applicationDefault), 4)
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 64001, strategy: .applicationDefault), 15)
            // Long recordings keep 15s chunks while the 30s warmup is blocked.
            TestSupport.expectEqual(state.cache.chunkSamples(strategy: .applicationDefault), 240000)
        }
        releaseThirty.signal()
        wait(installedThirty, "Successful background model must be installed")
        owner.sync {
            TestSupport.expect(!state.scheduler.isPreparing, "A completed pass must become idle")
            TestSupport.expectEqual(state.cache.preparedBuckets, [4, 15, 30])
            // Fall back to the ready 15s function when 8s failed, rather than
            // warming 8s in the foreground.
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 64001, strategy: .applicationDefault), 15)
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 240001, strategy: .applicationDefault), 30)
            TestSupport.expectEqual(state.cache.chunkSamples(strategy: .applicationDefault), 480000)
            state.scheduler.start()
        }
        wait(installedEight, "A later preparation request must retry failed optimization")
        worker.sync {}
        owner.sync {
            TestSupport.expectEqual(state.attempts, [4, 8, 30, 8])
            TestSupport.expectEqual(state.cache.preparedBuckets, [4, 8, 15, 30])
            TestSupport.expectEqual(try! state.cache.transcriptionBucket(samples: 64001, strategy: .applicationDefault), 8)
            state.scheduler.start()
            TestSupport.expect(!state.scheduler.isPreparing, "Fully optimized startup must be idempotent")
        }
        worker.sync {}
        TestSupport.expectEqual(state.attempts, [4, 8, 30, 8])
    }

    private static func testCancelledRuntimeCannotInstall() {
        let owner = DispatchQueue(label: "test.parakeet.cancel-owner")
        let worker = DispatchQueue(label: "test.parakeet.cancel-worker")
        let state = State()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        owner.async {
            state.cache.installPrepared(15, for: 15)
            state.scheduler = ParakeetBackgroundPreparation(
                ownerQueue: owner, workerQueue: worker, buckets: [4, 8, 30], makeReady: { bucket in
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
        TestSupport.expectEqual(state.attempts, [4])
    }
}
