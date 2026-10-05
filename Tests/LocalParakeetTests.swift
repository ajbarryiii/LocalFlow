import AVFoundation
import Foundation

enum LocalParakeetTests {
    static func run() {
        for (samples, bucket) in [(1, 2), (32000, 2), (32001, 4), (64000, 4), (64001, 8), (128000, 8), (128001, 15), (240000, 15)] {
            TestSupport.expectEqual(try! LocalParakeetCore.bucket(samples: samples), bucket)
        }
        expectFailure { _ = try LocalParakeetCore.bucket(samples: 0) }
        expectFailure { _ = try LocalParakeetCore.bucket(samples: 240001) }
        TestSupport.expectEqual(try! LocalParakeetCore.detokenize([0, 1, 2], vocabulary: ["▁Blue", "bird", "▁test."]), "Bluebird test.")
        expectFailure { _ = try LocalParakeetCore.detokenize([3], vocabulary: ["▁test"]) }

        // An emission whose duration reaches the end must still be returned.
        var predictions: [Int] = []
        let terminal = try! LocalParakeetCore.decode(length: 1, predict: { predictions.append($0) }, joint: { _ in (5, 4) }, check: {})
        TestSupport.expectEqual(terminal, [5])
        TestSupport.expectEqual(predictions, [1024, 5])

        // Zero-duration blanks and ten consecutive emissions must advance.
        var frames: [Int] = []
        let blanks = try! LocalParakeetCore.decode(length: 3, predict: { _ in }, joint: { frame in frames.append(frame); return (1024, 0) }, check: {})
        TestSupport.expectEqual(blanks, [])
        TestSupport.expectEqual(frames, [0, 1, 2])
        let capped = try! LocalParakeetCore.decode(length: 2, predict: { _ in }, joint: { _ in (2, 0) }, check: {})
        TestSupport.expectEqual(capped.count, 20)
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
        testBlobBounds()
        testPreparedModelReuse()
        testFifteenSecondBootstrap()
    }

    private static func testFifteenSecondBootstrap() {
        let cache = ParakeetModelCache<Int>()
        var loads: [Int] = []
        let strategy = ParakeetStartupStrategy.fifteenSecondsFirst
        func load(_ bucket: Int) -> Int { loads.append(bucket); return bucket }
        // Before bootstrap, retain normal lazy loading rather than selecting an
        // unavailable fallback. Every chunk length is valid for the 15s bucket.
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 1, strategy: strategy), 2)
        try! cache.prepare(buckets: strategy.initialBuckets, load: load) { _, _ in }
        TestSupport.expectEqual(loads, [15])
        for samples in [1, 32000, 32001, 64001, 128001, 240000] {
            TestSupport.expectEqual(try! cache.transcriptionBucket(samples: samples, strategy: strategy), 15)
        }
        expectFailure { _ = try cache.transcriptionBucket(samples: 240001, strategy: strategy) }
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 1, strategy: .allBuckets), 2)
        // A loaded but failed warmup must not displace the usable fallback.
        expectFailure {
            try cache.prepare(buckets: [2], load: load) { _, _ in throw CancellationError() }
        }
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 1, strategy: strategy), 15)
        try! cache.prepare(buckets: [2], load: load) { _, _ in }
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 1, strategy: strategy), 2)
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 32001, strategy: strategy), 15)
        try! cache.prepare(load: load) { _, _ in }
        TestSupport.expectEqual(loads, [15, 2, 4, 8])
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 32001, strategy: strategy), 4)
        TestSupport.expectEqual(try! cache.transcriptionBucket(samples: 64001, strategy: strategy), 8)
    }

    private static func testPreparedModelReuse() {
        final class SyntheticModel {}
        let cache = ParakeetModelCache<SyntheticModel>()
        var loads: [Int] = [], warmed: [Int] = []
        func load(_ bucket: Int) -> SyntheticModel {
            loads.append(bucket)
            return SyntheticModel()
        }
        // A transcription can load one bucket before startup preparation runs.
        let existing = try! cache.model(for: 4, load: load)
        try! cache.prepare(load: load) { bucket, _ in warmed.append(bucket) }
        TestSupport.expectEqual(loads, [4, 2, 8, 15])
        TestSupport.expectEqual(warmed, LocalParakeetCore.buckets)
        TestSupport.expect(try! cache.model(for: 4, load: load) === existing,
                           "Startup preparation must reuse an already loaded model")
        try! cache.prepare(load: load) { _, _ in fatalError("Prepared models must not warm twice") }
        for bucket in LocalParakeetCore.buckets { _ = try! cache.model(for: bucket, load: load) }
        TestSupport.expectEqual(loads, [4, 2, 8, 15])

        let retry = ParakeetModelCache<SyntheticModel>()
        loads = []; warmed = []
        expectFailure {
            try retry.prepare(load: load) { bucket, _ in
                if bucket == 4 { throw LocalParakeetError.invalid("Synthetic failure") }
                warmed.append(bucket)
            }
        }
        try! retry.prepare(load: load) { bucket, _ in warmed.append(bucket) }
        TestSupport.expectEqual(loads, LocalParakeetCore.buckets)
        TestSupport.expectEqual(warmed, LocalParakeetCore.buckets)
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
