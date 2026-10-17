import Foundation

/// Transcription while recording, driven by a synthetic chunk transcriber on a
/// private queue: no model, audio or Core ML.
enum ParakeetStreamingTests {
    static func run() {
        testMatchesBatchForAnySplit()
        testFullChunksBeforeFinish()
        testReadinessFixedAtBegin()
        testEarlyFailureSurfacesFromFinish()
        testCancel()
        testCancelDuringChunk()
        testTaskCancellation()
        testServiceWithoutModel()
    }

    private static let size = 40, overlap = 8

    /// Invented words at every fifth sample, named after the sample value. Each
    /// chunk capitalizes its first word and ends with a period, as the model
    /// does at chunk edges, so seams are reconciled.
    private static func words(_ chunk: ParakeetChunk) -> [ParakeetWord] {
        let positions = chunk.range.filter { $0 % 5 == 0 }
        return positions.enumerated().map { index, position in
            var text = "w\(Int(chunk.samples[position - chunk.start]))"
            if index == 0 { text = text.capitalized }
            if index == positions.count - 1 { text += "." }
            return ParakeetWord(text: text, start: position)
        }
    }

    private static func samples(_ count: Int, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 26)
        }
    }

    /// The batch path: every sample in one append.
    private static func batch(_ samples: [Float]) -> (text: String, chunks: [ParakeetChunk]) {
        var transcription = ParakeetChunkedTranscription(size: size, overlap: overlap), chunks: [ParakeetChunk] = []
        transcription.append(samples) { chunks.append($0); return words($0) }
        let text = transcription.finish { chunks.append($0); return words($0) }
        return (text, chunks)
    }

    private static func session(_ queue: DispatchQueue, _ log: ChunkLog, size: Int = size,
                                transcribe: @escaping @Sendable (ParakeetChunk) throws -> [ParakeetWord] = { words($0) },
                                complete: @escaping @Sendable (String) -> String = { $0 }) -> ParakeetStreamingTranscription<String> {
        ParakeetStreamingTranscription(queue: queue) {
            dispatchPrecondition(condition: .onQueue(queue))
            log.began()
            return .init(transcription: ParakeetChunkedTranscription(size: size, overlap: overlap), transcribe: { chunk, check in
                dispatchPrecondition(condition: .onQueue(queue))
                try check()
                log.add(chunk)
                return try transcribe(chunk)
            }, complete: { text, _ in log.completed(); return complete(text) })
        }
    }

    // However the recording is split into appends, the result, the chunks and
    // their order equal one batch transcription of the whole recording.
    private static func testMatchesBatchForAnySplit() {
        var random: UInt32 = 7
        func next(_ bound: Int) -> Int {
            random = random &* 1_103_515_245 &+ 12_345
            return Int(random >> 16) % bound
        }
        let stride = size - overlap
        for count in [0, 1, size - 1, size, size + 1, size + stride, 3 * stride + overlap, 3 * stride + overlap + 1, 7 * size + 3] {
            let recording = samples(count, seed: UInt32(count + 1))
            let expected = batch(recording)
            var splits: [[Int]] = [[count], Array(repeating: 1, count: count)]
            for _ in 0..<6 {
                var pieces: [Int] = [], left = count
                while left > 0 {
                    let piece = min(left, next(3 * size))   // includes empty appends
                    pieces.append(piece)
                    left -= piece
                }
                splits.append(pieces)
            }
            for pieces in splits {
                let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
                let streaming = session(queue, log)
                var offset = 0
                for piece in pieces {
                    streaming.append(Array(recording[offset..<(offset + piece)]))
                    offset += piece
                }
                let result = wait { try await streaming.finish() }
                TestSupport.expectEqual(try? result.get(), expected.text)
                TestSupport.expectEqual(log.chunks, expected.chunks)
                TestSupport.expectEqual(log.completions, 1)
            }
        }
    }

    // Every complete chunk is transcribed while recording; finish is left with
    // only the final partial chunk.
    private static func testFullChunksBeforeFinish() {
        let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
        let streaming = session(queue, log)
        let recording = samples(100, seed: 3)
        for start in Swift.stride(from: 0, to: 100, by: 10) { streaming.append(Array(recording[start..<(start + 10)])) }
        queue.sync {}
        TestSupport.expectEqual(log.chunks.map(\.range), [0..<40, 32..<72])
        log.markFinishing()
        let result = wait { try await streaming.finish() }
        TestSupport.expectEqual(try? result.get(), batch(recording).text)
        TestSupport.expectEqual(log.chunks.map(\.range), [0..<40, 32..<72, 64..<100])
        TestSupport.expectEqual(log.chunksAfterFinishing, [64..<100])
    }

    // Chunk size is read once, on the model queue, when the session begins: a
    // readiness change while recording does not move chunk boundaries.
    private static func testReadinessFixedAtBegin() {
        final class Readiness: @unchecked Sendable { var size = 40 }
        let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog(), readiness = Readiness()
        let streaming = ParakeetStreamingTranscription<String>(queue: queue) {
            log.began()
            return .init(transcription: ParakeetChunkedTranscription(size: readiness.size, overlap: overlap),
                         transcribe: { chunk, _ in log.add(chunk); return words(chunk) }, complete: { text, _ in text })
        }
        queue.sync { readiness.size = 80 }
        streaming.append(samples(100, seed: 5))
        _ = wait { try await streaming.finish() }
        TestSupport.expectEqual(log.chunks.map(\.range), [0..<40, 32..<72, 64..<100])
        TestSupport.expectEqual(log.begins, 1)
    }

    // A failed chunk stops all later chunk work; finish reports it with the
    // batch path's content-free mapping and completes nothing.
    private static func testEarlyFailureSurfacesFromFinish() {
        let generic = "Local transcription failed while loading the model or processing audio."
        let cases: [(Error, String)] = [
            (NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "w12 w7 invented words"]), generic),
            (LocalParakeetError.invalid("Audio contains invalid samples."), "Audio contains invalid samples."),
        ]
        for (thrown, expected) in cases {
            let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
            let streaming = session(queue, log, transcribe: { chunk in
                if chunk.start > 0 { throw thrown }
                return words(chunk)
            })
            streaming.append(samples(200, seed: 9))
            queue.sync {}
            TestSupport.expectEqual(log.chunks.map(\.range), [0..<40, 32..<72])
            streaming.append(samples(200, seed: 10))
            queue.sync {}
            TestSupport.expectEqual(log.chunks.count, 2)
            let result = wait { try await streaming.finish() }
            TestSupport.expectEqual(failureMessage(result), expected)
            TestSupport.expectEqual(log.chunks.count, 2)
            TestSupport.expectEqual(log.completions, 0)
        }

        // A failure to begin (model loading) surfaces the same way, with no chunk work.
        let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
        let failed = ParakeetStreamingTranscription<String>(queue: queue) {
            throw NSError(domain: "synthetic", code: 2, userInfo: [NSLocalizedDescriptionKey: "/invented/path"])
        }
        failed.append(samples(100, seed: 11))
        TestSupport.expectEqual(failureMessage(wait { try await failed.finish() }), generic)
        TestSupport.expectEqual(log.chunks.count, 0)
    }

    // Cancel drops pending audio and partial results, completes (retains)
    // nothing and is idempotent; a later finish throws CancellationError.
    private static func testCancel() {
        let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
        let streaming = session(queue, log)
        streaming.append(samples(80, seed: 13))
        queue.sync {}
        TestSupport.expectEqual(log.chunks.count, 2)
        streaming.cancel()
        streaming.cancel()
        streaming.append(samples(200, seed: 14))
        queue.sync {}
        TestSupport.expectEqual(log.chunks.count, 2)
        TestSupport.expect(isCancellation(wait { try await streaming.finish() }), "Finish after cancel must throw CancellationError")
        streaming.cancel()
        TestSupport.expectEqual(log.completions, 0)

        // Cancelled before it began: no stage is built.
        let early = DispatchQueue(label: "localflow.tests.streaming"), earlyLog = ChunkLog()
        early.suspend()
        let unborn = session(early, earlyLog)
        unborn.append(samples(100, seed: 15))
        unborn.cancel()
        early.resume()
        early.sync {}
        TestSupport.expectEqual(earlyLog.begins, 0)
        TestSupport.expectEqual(earlyLog.chunks.count, 0)

        // Finish is called once; a second call is rejected.
        let once = DispatchQueue(label: "localflow.tests.streaming"), onceLog = ChunkLog()
        let finished = session(once, onceLog)
        finished.append(samples(10, seed: 16))
        TestSupport.expect((try? wait { try await finished.finish() }.get()) != nil, "First finish must succeed")
        TestSupport.expect(isCancellation(wait { try await finished.finish() }), "A second finish must throw CancellationError")
        TestSupport.expectEqual(onceLog.completions, 1)
    }

    // A cancel that arrives while a chunk is being transcribed stops the work
    // still queued behind it.
    private static func testCancelDuringChunk() {
        let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let streaming = session(queue, log, transcribe: { chunk in
            if chunk.start == 0 { entered.signal(); release.wait() }
            return words(chunk)
        })
        streaming.append(samples(200, seed: 17))
        entered.wait()
        streaming.cancel()
        release.signal()
        queue.sync {}
        TestSupport.expectEqual(log.chunks.map(\.range), [0..<40])
        TestSupport.expect(isCancellation(wait { try await streaming.finish() }), "Finish after cancel must throw CancellationError")
        TestSupport.expectEqual(log.completions, 0)
    }

    // Cancelling the task awaiting finish cancels the session.
    private static func testTaskCancellation() {
        let queue = DispatchQueue(label: "localflow.tests.streaming"), log = ChunkLog()
        let streaming = session(queue, log)
        streaming.append(samples(30, seed: 19))
        let blocked = DispatchSemaphore(value: 0)
        queue.async { blocked.wait() }
        let outcome = AsyncResult<String>(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { outcome.value = .success(try await streaming.finish()) } catch { outcome.value = .failure(error) }
            done.signal()
        }
        task.cancel()
        blocked.signal()
        TestSupport.expect(done.wait(timeout: .now() + 5) == .success, "Cancelled finish must return")
        TestSupport.expect(isCancellation(outcome.value!), "A cancelled finish must throw CancellationError")
        streaming.append(samples(100, seed: 20))
        queue.sync {}
        TestSupport.expectEqual(log.chunks.count, 0)
        TestSupport.expectEqual(log.completions, 0)
    }

    // Through the service without a model: errors are content-free and a
    // cancelled session throws CancellationError.
    private static func testServiceWithoutModel() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LocalParakeetService(startupStrategy: .fifteenSecondsFirst)
        let missing = service.beginStreamingTranscription(directory: directory, dictionary: .empty, retainForCorrection: true)
        missing.append(samples(1_000, seed: 21).map { $0 / 64 })
        TestSupport.expectEqual(failureMessage(wait { try await missing.finish() }),
                                "Local transcription failed while loading the model or processing audio.")
        let cancelled = service.beginStreamingTranscription(directory: directory, dictionary: .empty, retainForCorrection: false)
        cancelled.append([0.25])
        cancelled.cancel()
        TestSupport.expect(isCancellation(wait { try await cancelled.finish() }), "A cancelled session must throw CancellationError")
    }

    private static func failureMessage<T>(_ result: Result<T, Error>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return (error as? LocalParakeetError)?.errorDescription
    }

    private static func isCancellation<T>(_ result: Result<T, Error>) -> Bool {
        guard case .failure(let error) = result else { return false }
        return error is CancellationError
    }

    private static func wait<T>(_ operation: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let outcome = AsyncResult<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { outcome.value = .success(try await operation()) } catch { outcome.value = .failure(error) }
            done.signal()
        }
        TestSupport.expect(done.wait(timeout: .now() + 5) == .success, "Streaming transcription must finish")
        return outcome.value!
    }
}

private final class AsyncResult<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// What the synthetic transcriber saw, from the model queue; read by the test.
private final class ChunkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(chunk: ParakeetChunk, afterFinishing: Bool)] = []
    private var finishing = false
    private var beginCount = 0, completionCount = 0

    func began() { lock.lock(); beginCount += 1; lock.unlock() }
    func completed() { lock.lock(); completionCount += 1; lock.unlock() }
    func markFinishing() { lock.lock(); finishing = true; lock.unlock() }
    func add(_ chunk: ParakeetChunk) { lock.lock(); entries.append((chunk, finishing)); lock.unlock() }

    var chunks: [ParakeetChunk] { lock.lock(); defer { lock.unlock() }; return entries.map { $0.chunk } }
    var chunksAfterFinishing: [Range<Int>] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.afterFinishing }.map { $0.chunk.range }
    }
    var begins: Int { lock.lock(); defer { lock.unlock() }; return beginCount }
    var completions: Int { lock.lock(); defer { lock.unlock() }; return completionCount }
}
