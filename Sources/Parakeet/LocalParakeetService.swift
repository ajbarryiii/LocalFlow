import AVFoundation
import CoreML
import Foundation

/// Runtime/cache/decoder state belongs to queue. A separate worker prepares
/// unused encoder instances and transfers them only after warmup succeeds.
/// Audio and text stay in memory; this backend never writes diagnostics.
final class LocalParakeetService: @unchecked Sendable {
    static let shared = LocalParakeetService()
    static var bundleDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Parakeet", isDirectory: true)
    }
    static var isAvailable: Bool {
        #if arch(arm64)
        if #available(macOS 26, *), let directory = bundleDirectory {
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("bundle.json").path)
        }
        #endif
        return false
    }
    private let queue = DispatchQueue(label: "localflow.local-model", qos: .userInitiated)
    private let preparationQueue = DispatchQueue(label: "localflow.local-model-optimization", qos: .utility)
    private var runtime: LocalParakeetRuntime?
    private let startupStrategy: ParakeetStartupStrategy
    private let computeUnits: MLComputeUnits
    private let onBucketUsed: (@Sendable (Int) -> Void)?

    // Dictation becomes ready after 15s; optional 4/8/30s warmups do not occupy
    // its serial queue. Benchmarks can compare startup policies explicitly.
    // A host that may lose the Neural Engine in the background can use .cpuOnly.
    init(startupStrategy: ParakeetStartupStrategy = .applicationDefault,
         computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
         onBucketUsed: (@Sendable (Int) -> Void)? = nil) {
        self.startupStrategy = startupStrategy
        self.computeUnits = computeUnits
        self.onBucketUsed = onBucketUsed
    }

    func prepare() async throws {
        guard Self.isAvailable, let directory = Self.bundleDirectory else {
            throw LocalParakeetError.invalid("The bundled LocalFlow model requires Apple Silicon and macOS 26 or newer. Use a build that includes the model.")
        }
        try await prepare(directory: directory)
    }

    // Synthetic inputs only: preparation never records audio or accesses context.
    func prepare(directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let runtime = try self.runtime(for: directory)
                    try runtime.prepare(buckets: self.startupStrategy.initialBuckets)
                    runtime.startBackgroundPreparation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: LocalParakeetError.invalid("Local model preparation failed. Retry model preparation in Settings."))
                }
            }
        }
    }

    // Content-free progress for the standalone synthetic benchmark. No logging,
    // microphone access or user settings/history are involved.
    func preparationProgress(directory: URL) async throws -> ParakeetPreparationProgress {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.runtime(for: directory).preparationProgress) }
                catch { continuation.resume(throwing: LocalParakeetError.invalid("Local model preparation is unavailable.")) }
            }
        }
    }

    // Call only on queue. Keep the runtime and any loaded models alive.
    private func runtime(for directory: URL) throws -> LocalParakeetRuntime {
        if let runtime, runtime.directory == directory { return runtime }
        let runtime = try LocalParakeetRuntime(directory: directory, startupStrategy: startupStrategy,
                                               computeUnits: computeUnits,
                                               ownerQueue: queue, preparationQueue: preparationQueue,
                                               onBucketUsed: onBucketUsed)
        self.runtime?.cancelBackgroundPreparation()
        self.runtime = runtime
        return runtime
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard Self.isAvailable, let directory = Self.bundleDirectory else {
            throw LocalParakeetError.invalid("The bundled LocalFlow model requires Apple Silicon and macOS 26 or newer. Use a build that includes the model.")
        }
        return try await transcribe(fileURL: fileURL, directory: directory)
    }

    // Explicit directory also permits a synthetic-audio smoke check without
    // launching the app, reading user settings, or requesting microphone access.
    func transcribe(fileURL: URL, directory: URL) async throws -> String {
        try await transcribe(directory: directory) { runtime, check in
            try runtime.transcribe(fileURL: fileURL, check: check)
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard Self.isAvailable, let directory = Self.bundleDirectory else {
            throw LocalParakeetError.invalid("The bundled LocalFlow model requires Apple Silicon and macOS 26 or newer. Use a build that includes the model.")
        }
        return try await transcribe(samples: samples, directory: directory)
    }

    // 16 kHz mono samples that are already in memory, such as a live capture
    // buffer. Nothing is written to disk.
    func transcribe(samples: [Float], directory: URL) async throws -> String {
        try await transcribe(directory: directory) { runtime, check in
            try runtime.transcribe(samples: samples, check: check)
        }
    }

    private func transcribe(directory: URL,
                            _ operation: @escaping @Sendable (LocalParakeetRuntime, () throws -> Void) throws -> String) async throws -> String {
        let cancellation = ParakeetCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let text = try operation(self.runtime(for: directory), cancellation.check)
                        try cancellation.check()
                        continuation.resume(returning: text)
                    } catch {
                        // Core ML exceptions may carry input details;
                        // expose only our content-free errors or cancellation.
                        if error is CancellationError || error is LocalParakeetError {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: LocalParakeetError.invalid("Local transcription failed while loading the model or processing audio."))
                        }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

// Every access to cancelled is protected by lock.
private final class ParakeetCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private final class LocalParakeetRuntime {
    let directory: URL
    let frontend: VDSPFrontEnd
    let math: NativeMath
    let vocabulary: [String]
    private let models = ParakeetModelCache<MLModel>()
    private let startupStrategy: ParakeetStartupStrategy
    private let computeUnits: MLComputeUnits
    private var backgroundPreparation: ParakeetBackgroundPreparation<MLModel>?
    private let onBucketUsed: (@Sendable (Int) -> Void)?

    init(directory: URL, startupStrategy: ParakeetStartupStrategy, computeUnits: MLComputeUnits,
         ownerQueue: DispatchQueue, preparationQueue: DispatchQueue,
         onBucketUsed: (@Sendable (Int) -> Void)?) throws {
        self.directory = directory
        self.startupStrategy = startupStrategy
        self.computeUnits = computeUnits
        self.onBucketUsed = onBucketUsed
        let data = try Data(contentsOf: directory.appendingPathComponent("bundle.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["model"] as? String == LocalParakeetCore.modelID,
              let files = manifest["files"] as? [String: String],
              ["frontend.json", "frontend.f32bin", "decoder_joint.json", "decoder_joint.f32bin", "vocabulary.json"].allSatisfy({ files[$0] != nil }),
              files.keys.contains(where: { $0.hasPrefix("Encoder.mlmodelc/") }) else {
            throw LocalParakeetError.invalid("Invalid bundled LocalFlow manifest.")
        }
        for (name, digest) in files {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                  try LocalParakeetCore.sha256(fileURL: directory.appendingPathComponent(name)) == digest else {
                throw LocalParakeetError.invalid("Bundled LocalFlow integrity check failed. Rebuild the app.")
            }
        }
        frontend = try VDSPFrontEnd(constantsDir: directory)
        math = try NativeMath(NativeWeights(directory: directory))
        let vocab = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
        guard vocab.count == 1024, (0..<1024).allSatisfy({ vocab[String($0)] != nil }) else {
            throw LocalParakeetError.invalid("Invalid local vocabulary.")
        }
        vocabulary = (0..<1024).map { vocab[String($0)]! }
        if !startupStrategy.backgroundBuckets.isEmpty {
            backgroundPreparation = ParakeetBackgroundPreparation(
                ownerQueue: ownerQueue, workerQueue: preparationQueue, buckets: startupStrategy.backgroundBuckets,
                makeReady: { bucket in
                    try autoreleasepool {
                        let model = try ParakeetEncoder.load(bucket: bucket, directory: directory, computeUnits: computeUnits)
                        try ParakeetEncoder.warm(bucket: bucket, model: model)
                        return model
                    }
                }, install: { [weak self] bucket, model in self?.models.installPrepared(model, for: bucket) })
        }
    }

    var preparationProgress: ParakeetPreparationProgress {
        ParakeetPreparationProgress(preparedBuckets: models.preparedBuckets,
                                     isOptimizing: backgroundPreparation?.isPreparing ?? false)
    }

    func startBackgroundPreparation() { backgroundPreparation?.start() }
    func cancelBackgroundPreparation() { backgroundPreparation?.cancel() }

    func prepare(buckets: [Int]) throws {
        try models.prepare(buckets: buckets, load: loadModel, warm: ParakeetEncoder.warm)
    }

    private func loadModel(bucket: Int) throws -> MLModel {
        try ParakeetEncoder.load(bucket: bucket, directory: directory, computeUnits: computeUnits)
    }

    func transcribe(fileURL: URL, check: () throws -> Void) throws -> String {
        var chunker = makeChunker(), pieces: [String] = []
        try ParakeetAudioReader.read(fileURL: fileURL, check: check) { samples in
            try chunker.append(samples) { pieces.append(try transcribeChunk($0, check: check)) }
        }
        try chunker.finish { pieces.append(try transcribeChunk($0, check: check)) }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func transcribe(samples: [Float], check: () throws -> Void) throws -> String {
        var chunker = makeChunker(), pieces: [String] = []
        try chunker.append(samples) { pieces.append(try transcribeChunk($0, check: check)) }
        try chunker.finish { pieces.append(try transcribeChunk($0, check: check)) }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Installs also run on this queue, so readiness is fixed for the recording.
    private func makeChunker() -> ParakeetChunker {
        ParakeetChunker(size: models.chunkSamples(strategy: startupStrategy))
    }

    private func transcribeChunk(_ input: [Float], check: () throws -> Void) throws -> String {
        try check()
        guard input.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Audio contains invalid samples.") }
        if input.allSatisfy({ $0 == 0 }) { return "" }
        // NeMo's unbiased per-feature normalization needs at least two frames.
        let pcm = input.count < 480 ? input + [Float](repeating: 0, count: 480 - input.count) : input
        let bucket = try models.transcriptionBucket(samples: pcm.count, strategy: startupStrategy)
        let model = try models.model(for: bucket, load: loadModel)
        try check()
        let features = frontend.compute(pcm)
        let size = bucket * 100 + 1
        let mel = try MLMultiArray(shape: [1, 128, NSNumber(value: size)], dataType: .float32)
        let dst = mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count)
        dst.initialize(repeating: 0, count: mel.count)
        features.features.withUnsafeBufferPointer { src in
            for channel in 0..<128 { (dst + channel * size).update(from: src.baseAddress! + channel * features.frames, count: features.frames) }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: features.valid)
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": mel, "mel_length": length]))
        // Optional content-free observer for synthetic benchmarks, invoked only
        // on the owning queue. The app installs no observer and records nothing.
        onBucketUsed?(bucket)
        guard let encoder = result.featureValue(for: "encoder")?.multiArrayValue,
              let valid = result.featureValue(for: "encoder_length")?.multiArrayValue else {
            throw LocalParakeetError.invalid("Local encoder output is missing.")
        }
        let frames = try EncoderFrames(encoder, validLength: valid[0].intValue)
        let projection = FloatBuffer(count: frames.count * 640)
        math.project(frames, length: frames.count, into: projection.pointer)
        var h = [Float](repeating: 0, count: 1280), c = h
        var g = [Float](repeating: 0, count: 640), z = g, logits = [Float](repeating: 0, count: 1030)
        let tokens = try LocalParakeetCore.decode(length: frames.count, predict: { token in
            math.predict(token, h: &h, c: &c, g: &g)
        }, joint: { frame in
            let decision = math.joint(f: projection.pointer + frame * 640, g: &g, z: &z, logits: &logits)
            guard logits.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Local decoder produced invalid values.") }
            return decision
        }, check: check)
        return try LocalParakeetCore.detokenize(tokens, vocabulary: vocabulary)
    }
}

private enum ParakeetEncoder {
    static func load(bucket: Int, directory: URL, computeUnits: MLComputeUnits) throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        if #available(macOS 15, *) { config.functionName = "b\(bucket)" }
        else { throw LocalParakeetError.invalid("LocalFlow requires macOS 26 or newer.") }
        return try MLModel(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: config)
    }

    static func warm(bucket: Int, model: MLModel) throws {
        // Invented zero features; no audio or user content is read.
        let size = bucket * 100 + 1
        let mel = try MLMultiArray(shape: [1, 128, NSNumber(value: size)], dataType: .float32)
        mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count).initialize(repeating: 0, count: mel.count)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: size)
        _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": mel, "mel_length": length]))
    }
}
