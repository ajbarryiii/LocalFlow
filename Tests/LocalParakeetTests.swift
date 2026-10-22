import AVFoundation
import Foundation

enum LocalParakeetTests {
    static func run() {
        // Only the 15 s encoder function runs: recordings split into 15 s
        // windows that overlap by 2 s, and every window, however short, is
        // padded to that one function.
        TestSupport.expectEqual(LocalParakeetCore.encoderSeconds, 15)
        TestSupport.expectEqual(LocalParakeetCore.chunkSamples, 240_000)
        TestSupport.expectEqual(LocalParakeetCore.chunkOverlapSamples, 32_000)
        for samples in [1, 480, 2 * 16_000, 4 * 16_000, 64_001, 7 * 16_000, 14 * 16_000, 240_000] {
            TestSupport.expectEqual(try! LocalParakeetCore.bucket(samples: samples), 15)
        }
        expectFailure { _ = try LocalParakeetCore.bucket(samples: 0) }
        expectFailure { _ = try LocalParakeetCore.bucket(samples: 240_001) }
        expectFailure { _ = try LocalParakeetCore.bucket(samples: 480_000) }
        // Words start where their first token was emitted, in recording samples.
        let tokens = [ParakeetToken(id: 0, frame: 2), ParakeetToken(id: 1, frame: 3), ParakeetToken(id: 2, frame: 5)]
        TestSupport.expectEqual(try! LocalParakeetCore.words(tokens, vocabulary: ["▁Blue", "bird", "▁test."], offset: 100),
                                [ParakeetWord(text: "Bluebird", start: 100 + 2 * 1280), ParakeetWord(text: "test.", start: 100 + 5 * 1280)])
        expectFailure { _ = try LocalParakeetCore.words([ParakeetToken(id: 3, frame: 0)], vocabulary: ["▁test"], offset: 0) }

        // An emission whose duration reaches the end must still be returned.
        var predictions: [Int] = []
        let terminal = try! LocalParakeetCore.decode(length: 1, predict: { predictions.append($0) }, joint: { _ in (5, 4) }, check: {})
        TestSupport.expectEqual(terminal, [ParakeetToken(id: 5, frame: 0)])
        TestSupport.expectEqual(predictions, [1024, 5])

        // Zero-duration blanks and ten consecutive emissions must advance.
        var frames: [Int] = []
        let blanks = try! LocalParakeetCore.decode(length: 3, predict: { _ in }, joint: { frame in frames.append(frame); return (1024, 0) }, check: {})
        TestSupport.expectEqual(blanks, [])
        TestSupport.expectEqual(frames, [0, 1, 2])
        let capped = try! LocalParakeetCore.decode(length: 2, predict: { _ in }, joint: { _ in (2, 0) }, check: {})
        TestSupport.expectEqual(capped.map(\.frame), Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10))
        expectFailure { _ = try LocalParakeetCore.decode(length: 1, predict: { _ in }, joint: { _ in (1025, 0) }, check: {}) }
        expectFailure { _ = try LocalParakeetCore.decode(length: 1, predict: { _ in }, joint: { _ in (1, 5) }, check: {}) }
        expectFailure { _ = try LocalParakeetCore.decode(length: 1, predict: { _ in }, joint: { _ in (1, 0) }, check: { throw CancellationError() }) }

        // Silence must normalize to finite zero features without a model file.
        let frontend = try! VDSPFrontEnd(window: [Float](repeating: 1, count: 400), fb: [Float](repeating: 0, count: 128 * 257))
        let silence = frontend.compute([Float](repeating: 0, count: 480))
        TestSupport.expectEqual(silence.valid, 3)
        TestSupport.expectEqual(silence.frames, 4)
        TestSupport.expect(silence.features.allSatisfy { $0.isFinite && $0 == 0 }, "Silence features must remain zero")
        testSyntheticAudioEOF()
        testRecordedSamplesMatchFile()
        testBlobBounds()
        testPreparedModelReuse()
        testFifteenSecondFunctionOnly()
        testSharedChunking()
        testRecordingChunks()
        testOverlapReconciliation()
        testInMemoryTranscriptionFailures()
        testStreamingDigest()
    }

    // Every recording, whatever its length, is cut into the same 15 s windows
    // with a 2 s overlap, and each window runs on the 15 s function. A loud
    // synthetic tone passes the silence compactor unchanged.
    private static func testRecordingChunks() {
        func s(_ seconds: Int) -> Int { seconds * 16_000 }
        func chunks(_ seconds: Int) -> [Range<Int>] {
            let recording = ParakeetSilenceCompactorTests.tone(Double(seconds), level: -20)
            var transcription = ParakeetChunkedTranscription.recording(), ranges: [Range<Int>] = []
            func transcribe(_ chunk: ParakeetChunk) -> [ParakeetWord] {
                TestSupport.expectEqual(chunk.samples, Array(recording[chunk.range]))
                TestSupport.expectEqual(try! LocalParakeetCore.bucket(samples: chunk.samples.count), 15)
                ranges.append(chunk.range)
                return []
            }
            for start in stride(from: 0, to: recording.count, by: 8192) {
                transcription.append(Array(recording[start..<min(start + 8192, recording.count)]), transcribe: transcribe)
            }
            _ = transcription.finish(transcribe: transcribe)
            return ranges
        }
        // Short dictations are one window, padded to the 15 s function.
        TestSupport.expectEqual(chunks(2), [0..<s(2)])
        TestSupport.expectEqual(chunks(4), [0..<s(4)])
        TestSupport.expectEqual(chunks(7), [0..<s(7)])
        TestSupport.expectEqual(chunks(14), [0..<s(14)])
        TestSupport.expectEqual(chunks(15), [0..<s(15)])
        // Longer ones never use a 30 s window: windows start 13 s apart.
        TestSupport.expectEqual(chunks(18), [0..<s(15), s(13)..<s(18)])
        TestSupport.expectEqual(chunks(28), [0..<s(15), s(13)..<s(28)])
        TestSupport.expectEqual(chunks(33), [0..<s(15), s(13)..<s(28), s(26)..<s(33)])
        let long = chunks(60)
        TestSupport.expectEqual(long, [0..<s(15), s(13)..<s(28), s(26)..<s(41), s(39)..<s(54), s(52)..<s(60)])
        for (earlier, later) in zip(long, long.dropFirst()) {
            TestSupport.expectEqual(earlier.upperBound - later.lowerBound, s(2))
        }
    }

    // Model verification hashes files in bounded reads; the digest must match
    // hashing the whole file at once, including partial and empty reads.
    private static func testStreamingDigest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.bin")
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try! data.write(to: url)
        for chunkSize in [1, 4096, 5000, 10_000, 1 << 20] {
            TestSupport.expectEqual(try! LocalParakeetCore.sha256(fileURL: url, chunkSize: chunkSize), LocalParakeetCore.sha256(data))
        }
        TestSupport.expect(try! LocalParakeetCore.sha256(fileURL: url, chunkSize: 4096) != LocalParakeetCore.sha256(data.dropLast()),
                           "A truncated file must not match")
        try! Data().write(to: url)
        TestSupport.expectEqual(try! LocalParakeetCore.sha256(fileURL: url, chunkSize: 4096), LocalParakeetCore.sha256(Data()))
        expectFailure { _ = try LocalParakeetCore.sha256(fileURL: directory.appendingPathComponent("missing.bin")) }
    }

    // Files arrive as bounded reads and in-memory recordings as one array;
    // both must reach the encoder as the same chunks.
    private static func testSharedChunking() {
        func chunks(_ samples: [Float], size: Int, overlap: Int = 0, read: Int) -> [ParakeetChunk] {
            var chunker = ParakeetChunker(size: size, overlap: overlap), result: [ParakeetChunk] = []
            for start in stride(from: 0, to: samples.count, by: read) {
                chunker.append(Array(samples[start..<min(start + read, samples.count)])) { result.append($0) }
                chunker.append([]) { _ in fatalError("Empty reads must not emit chunks") }
            }
            chunker.finish { result.append($0) }
            chunker.finish { _ in fatalError("A finished chunker must not emit again") }
            for chunk in result {
                // A chunk must hold the audio at its range.
                TestSupport.expectEqual(chunk.samples, Array(samples[chunk.range]))
            }
            return result
        }
        let samples = (0..<10).map(Float.init)
        for read in [1, 3, 4, 7, 10] {
            TestSupport.expectEqual(chunks(samples, size: 4, read: read).map(\.samples), [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
            TestSupport.expectEqual(chunks(Array(samples.prefix(8)), size: 4, read: read).map(\.samples), [[0, 1, 2, 3], [4, 5, 6, 7]])

            // Overlapping windows repeat the tail of the previous one. A final
            // window is emitted only when it holds audio no window covered yet.
            TestSupport.expectEqual(chunks(samples, size: 4, overlap: 1, read: read).map(\.range), [0..<4, 3..<7, 6..<10])
            TestSupport.expectEqual(chunks(Array(samples.prefix(8)), size: 4, overlap: 1, read: read).map(\.range), [0..<4, 3..<7, 6..<8])
            TestSupport.expectEqual(chunks(Array(samples.prefix(7)), size: 4, overlap: 1, read: read).map(\.range), [0..<4, 3..<7])
            TestSupport.expectEqual(chunks(samples, size: 4, overlap: 2, read: read).map(\.range), [0..<4, 2..<6, 4..<8, 6..<10])
            TestSupport.expectEqual(chunks(Array(samples.prefix(3)), size: 4, overlap: 1, read: read).map(\.range), [0..<3])
        }
        TestSupport.expectEqual(chunks([], size: 4, read: 1), [])
        TestSupport.expectEqual(chunks([], size: 4, overlap: 2, read: 1), [])
        let recording = [Float](repeating: 0.25, count: 600_001)
        TestSupport.expectEqual(chunks(recording, size: 240_000, read: 8192).map(\.samples.count), [240_000, 240_000, 120_001])
        TestSupport.expectEqual(chunks(recording, size: 240_000, read: recording.count).map(\.samples.count), [240_000, 240_000, 120_001])
        for read in [8192, recording.count] {
            TestSupport.expectEqual(chunks(recording, size: 240_000, overlap: 32_000, read: read).map(\.range),
                                    [0..<240_000, 208_000..<448_000, 416_000..<600_001])
        }
        var failing = ParakeetChunker(size: 2, overlap: 1)
        expectFailure { try failing.append([1, 2, 3]) { _ in throw CancellationError() } }
    }

    // Each chunk's model treats its edges as the start and end of speech. The
    // shared audio must be stitched once, without the edge capitals, periods,
    // or cut-off words that either chunk invented there.
    private static func testOverlapReconciliation() {
        func s(_ seconds: Double) -> Int { Int(seconds * 16_000) }
        func w(_ text: String, _ seconds: Double) -> ParakeetWord { ParakeetWord(text: text, start: s(seconds)) }
        func stitched(_ chunks: [(Range<Int>, [ParakeetWord])]) -> String {
            var transcript = ParakeetTranscriptAssembler()
            for (range, words) in chunks { transcript.append(words, covering: range) }
            return transcript.text
        }

        // A single chunk is joined as-is.
        TestSupport.expectEqual(stitched([(0..<s(4), [w("Hello", 0.2), w("world.", 0.7)])]), "Hello world.")
        TestSupport.expectEqual(stitched([]), "")

        // A false sentence break at the seam: "store. And" ends the first
        // chunk, "To the store" opens the second, and "th" is cut off.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("We", 11.5), w("walked", 12.0), w("to", 13.1), w("the", 13.4), w("store.", 13.8), w("And", 14.5), w("th", 14.85)]),
            (s(13)..<s(17), [w("To", 13.12), w("the", 13.42), w("store", 13.84), w("and", 14.5), w("then", 15.0), w("home.", 15.4)]),
        ]), "We walked to the store and then home.")

        // The seam word keeps the earlier chunk's casing and the later
        // chunk's trailing punctuation.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("We", 12.5), w("lived", 12.9), w("in", 13.5), w("Paris", 13.9), w("We", 14.6)]),
            (s(13)..<s(16), [w("In", 13.5), w("paris,", 13.95), w("we", 14.6), w("met.", 15.0)]),
        ]), "We lived in Paris, we met.")

        // Repeated words pair in order, so neither copy is dropped or doubled
        // even when a crossed pair would sit closer to the middle.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("said", 13.2), w("the", 13.95), w("the", 14.15), w("end.", 14.6)]),
            (s(13)..<s(16), [w("Said", 13.2), w("the", 13.9), w("the", 14.1), w("end", 14.6), w("today.", 15.2)]),
        ]), "said the the end today.")

        // When one chunk misses a repetition, the remaining copy pairs with
        // the copy heard at the same time, not the first one in order.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("very", 13.76), w("very", 14.0), w("good.", 14.88)]),
            (s(13)..<s(16), [w("Very", 14.04), w("good.", 14.92)]),
        ]), "very very good.")

        // Without agreement the seam falls at the middle of the overlap.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("alpha", 12.0), w("bravo", 13.5), w("charlie.", 14.5)]),
            (s(13)..<s(16), [w("Delta", 13.2), w("echo", 14.2), w("foxtrot.", 15.5)]),
        ]), "alpha bravo echo foxtrot.")

        // Equal words heard at different times are different words.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("one", 12.0), w("the", 13.1)]),
            (s(13)..<s(16), [w("The", 14.8), w("end.", 15.2)]),
        ]), "one the The end.")

        // Silence in one chunk keeps only the other chunk's half of the overlap.
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("first", 10.0), w("late", 14.5)]),
            (s(13)..<s(16), []),
        ]), "first")

        // Chunks that do not overlap are concatenated, and each seam of a
        // longer recording is reconciled on its own.
        TestSupport.expectEqual(stitched([(0..<s(4), [w("one", 1)]), (s(4)..<s(8), [w("Two", 5)])]), "one Two")
        TestSupport.expectEqual(stitched([
            (0..<s(15), [w("Start", 1.0), w("of", 13.2), w("it.", 14.7)]),
            (s(13)..<s(28), [w("Of", 13.2), w("it", 14.7), w("goes", 15.2), w("on", 26.5), w("and.", 27.6)]),
            (s(26)..<s(29), [w("On", 26.5), w("and", 27.6), w("on.", 28.2)]),
        ]), "Start of it goes on and on.")
    }

    // No model is needed: in-memory transcription must expose only
    // content-free errors and honor cancellation like the file path.
    private static func testInMemoryTranscriptionFailures() {
        final class Outcome: @unchecked Sendable { var missing: Error?, cancelled: Error? }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LocalParakeetService()
        let outcome = Outcome(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { _ = try await service.transcribe(samples: [0.25, -0.25], directory: directory) } catch { outcome.missing = error }
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await service.transcribe(samples: [0.25], directory: directory) } catch { outcome.cancelled = error }
            done.signal()
        }
        TestSupport.expect(done.wait(timeout: .now() + 5) == .success, "In-memory transcription must finish")
        TestSupport.expectEqual((outcome.missing as? LocalParakeetError)?.errorDescription,
                                "Local transcription failed while loading the model or processing audio.")
        TestSupport.expect(outcome.cancelled is CancellationError, "Cancelled in-memory transcription must throw CancellationError")
    }

    // Preparation loads and warms only the 15 s function, once. A failed load
    // or warm-up leaves nothing prepared and is retried by the next
    // preparation, which keeps a model that loaded before the warm-up failed.
    private static func testFifteenSecondFunctionOnly() {
        final class SyntheticModel {}
        let cache = ParakeetModelCache<SyntheticModel>()
        var loads: [Int] = [], warmed: [Int] = []
        func load(_ bucket: Int) -> SyntheticModel { loads.append(bucket); return SyntheticModel() }
        TestSupport.expect(!cache.isPrepared, "A new cache has nothing prepared")
        try! cache.prepare(load: load) { bucket, _ in warmed.append(bucket) }
        TestSupport.expect(cache.isPrepared, "Preparation must make the function ready")
        TestSupport.expectEqual(loads, [15])
        TestSupport.expectEqual(warmed, [15])
        // Idempotent: a repeated preparation and later transcriptions reuse it.
        let prepared = try! cache.model(load: load)
        try! cache.prepare(load: load) { _, _ in fatalError("A prepared function must not warm twice") }
        TestSupport.expect(try! cache.model(load: load) === prepared, "Transcription must reuse the prepared model")
        TestSupport.expectEqual(loads, [15])
        TestSupport.expectEqual(warmed, [15])

        let failedWarmup = ParakeetModelCache<SyntheticModel>()
        loads = []; warmed = []
        expectFailure { try failedWarmup.prepare(load: load) { _, _ in throw LocalParakeetError.invalid("Synthetic failure") } }
        TestSupport.expect(!failedWarmup.isPrepared, "A failed warm-up must not mark the function ready")
        try! failedWarmup.prepare(load: load) { bucket, _ in warmed.append(bucket) }
        TestSupport.expect(failedWarmup.isPrepared, "A retried preparation must make the function ready")
        TestSupport.expectEqual(loads, [15])
        TestSupport.expectEqual(warmed, [15])

        let failedLoad = ParakeetModelCache<SyntheticModel>()
        loads = []; warmed = []
        expectFailure {
            try failedLoad.prepare(load: { _ in throw LocalParakeetError.invalid("Synthetic failure") }) { _, _ in
                fatalError("A function that failed to load must not warm")
            }
        }
        TestSupport.expect(!failedLoad.isPrepared, "A failed load must not mark the function ready")
        try! failedLoad.prepare(load: load) { bucket, _ in warmed.append(bucket) }
        TestSupport.expect(failedLoad.isPrepared, "A retried preparation must make the function ready")
        TestSupport.expectEqual(loads, [15])
        TestSupport.expectEqual(warmed, [15])
    }

    private static func testPreparedModelReuse() {
        final class SyntheticModel {}
        let cache = ParakeetModelCache<SyntheticModel>()
        var loads: [Int] = [], warmed: [Int] = []
        func load(_ bucket: Int) -> SyntheticModel {
            loads.append(bucket)
            return SyntheticModel()
        }
        // A transcription can load the function before preparation runs.
        let existing = try! cache.model(load: load)
        TestSupport.expect(!cache.isPrepared, "Loading alone must not mark the function ready")
        try! cache.prepare(load: load) { bucket, _ in warmed.append(bucket) }
        TestSupport.expectEqual(loads, [15])
        TestSupport.expectEqual(warmed, [15])
        TestSupport.expect(try! cache.model(load: load) === existing,
                           "Preparation must reuse an already loaded model")
    }

    private static func testSyntheticAudioEOF() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.aiff")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 53258)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        } catch { fatalError("Unable to create synthetic audio fixture") }
        var samples = 0, calls = 0
        try! ParakeetAudioReader.read(fileURL: url, check: {}) { chunk in
            samples += chunk.count; calls += 1
            TestSupport.expect(chunk.count <= 8192, "Audio reader must keep bounded buffers")
            TestSupport.expect(chunk.allSatisfy { $0.isFinite && $0 == 0 }, "Synthetic silence must stay finite")
        }
        TestSupport.expect(calls > 1, "Fixture must exercise multiple reads and EOF")
        TestSupport.expect(abs(samples - Int(Double(buffer.frameLength) * 16000 / 22050)) <= 1, "Resampling must retain the complete recording")
        expectFailure {
            try ParakeetAudioReader.read(fileURL: url, check: { throw CancellationError() }, consume: { _ in })
        }
    }

    // Samples streamed while recording must equal what the model reads back
    // from the recorder's 16 kHz mono 16-bit file, including the extremes.
    private static func testRecordedSamplesMatchFile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var streamed: [Float] = [], state: UInt32 = 1
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            for count in [341, 1, 8192, 9000] {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for index in 0..<count {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    buffer.int16ChannelData![0][index] = Int16(truncatingIfNeeded: state >> 16)
                }
                if count == 341 { buffer.int16ChannelData![0][0] = .min; buffer.int16ChannelData![0][1] = .max }
                try file.write(from: buffer)
                streamed += ParakeetAudioReader.samples(int16: buffer)
            }
        } catch { fatalError("Unable to create synthetic audio fixture") }
        var read: [Float] = []
        try! ParakeetAudioReader.read(fileURL: url, check: {}) { read += $0 }
        TestSupport.expectEqual(read.count, streamed.count)
        TestSupport.expect(read == streamed, "Streamed samples must equal the samples read from the file")
        TestSupport.expectEqual(Array(streamed.prefix(2)), [-1, Float(32767) / 32768])
    }

    private static func testBlobBounds() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var value: Float = 1
        let data = withUnsafeBytes(of: &value) { Data($0) }
        try! data.write(to: directory.appendingPathComponent("synthetic.f32bin"))
        func manifest(offset: Int = 0, shape: [Int] = [1], file: String = "synthetic.f32bin") {
            let json: [String: Any] = ["file": file, "sha256": LocalParakeetCore.sha256(data),
                "tensors": [["name": "synthetic", "shape": shape, "offset": offset, "bytes": 4]]]
            try! JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("synthetic.json"))
        }
        manifest()
        TestSupport.expectEqual(try! NativeBlob(directory: directory, stem: "synthetic").tensor("synthetic", [1]), [1])
        manifest(offset: -4)
        expectFailure { _ = try NativeBlob(directory: directory, stem: "synthetic") }
        manifest(offset: 2)
        expectFailure { _ = try NativeBlob(directory: directory, stem: "synthetic") }
        manifest(shape: [Int.max, Int.max])
        expectFailure { _ = try NativeBlob(directory: directory, stem: "synthetic") }
        manifest(file: "../synthetic.f32bin")
        expectFailure { _ = try NativeBlob(directory: directory, stem: "synthetic") }
    }

    private static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected a local transcription failure") }
        catch { }
    }
}
