import AVFoundation
import CoreML
import Foundation

/// All model and decoder state belongs to this serial queue. Audio and text stay
/// in memory; this backend never makes network requests or writes diagnostics.
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
    private let queue = DispatchQueue(label: "freeflow.local-parakeet", qos: .userInitiated)
    private var runtime: LocalParakeetRuntime?

    func transcribe(fileURL: URL, language: String?) async throws -> String {
        guard language == nil || language == "en" else {
            throw LocalParakeetError.invalid("Parakeet v2 supports English. Select English or Auto-detect.")
        }
        guard Self.isAvailable, let directory = Self.bundleDirectory else {
            throw LocalParakeetError.invalid("The bundled Parakeet model requires Apple Silicon and macOS 26 or newer. Build with PARAKEET_BUNDLE_DIR to include it.")
        }
        return try await transcribe(fileURL: fileURL, directory: directory)
    }

    // Explicit directory also permits a synthetic-audio smoke check without
    // launching the app, reading user settings, or requesting microphone access.
    func transcribe(fileURL: URL, directory: URL) async throws -> String {
        let cancellation = ParakeetCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        if self.runtime?.directory != directory {
                            self.runtime = try LocalParakeetRuntime(directory: directory)
                        }
                        let text = try self.runtime!.transcribe(fileURL: fileURL, check: cancellation.check)
                        try cancellation.check()
                        continuation.resume(returning: text)
                    } catch {
                        // Core ML/provider exceptions may carry input details;
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
    var models: [Int: MLModel] = [:]

    init(directory: URL) throws {
        self.directory = directory
        let data = try Data(contentsOf: directory.appendingPathComponent("bundle.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["model"] as? String == LocalParakeetCore.modelID,
              let files = manifest["files"] as? [String: String],
              ["frontend.json", "frontend.f32bin", "decoder_joint.json", "decoder_joint.f32bin", "vocabulary.json"].allSatisfy({ files[$0] != nil }),
              files.keys.contains(where: { $0.hasPrefix("Encoder.mlmodelc/") }) else {
            throw LocalParakeetError.invalid("Invalid bundled Parakeet manifest.")
        }
        for (name, digest) in files {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                  LocalParakeetCore.sha256(try Data(contentsOf: directory.appendingPathComponent(name))) == digest else {
                throw LocalParakeetError.invalid("Bundled Parakeet integrity check failed. Rebuild the app.")
            }
        }
        frontend = try VDSPFrontEnd(constantsDir: directory)
        math = try NativeMath(NativeWeights(directory: directory))
        let vocab = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
        guard vocab.count == 1024, (0..<1024).allSatisfy({ vocab[String($0)] != nil }) else {
            throw LocalParakeetError.invalid("Invalid local vocabulary.")
        }
        vocabulary = (0..<1024).map { vocab[String($0)]! }
    }

    func transcribe(fileURL: URL, check: () throws -> Void) throws -> String {
        var pending: [Float] = [], pieces: [String] = []
        try ParakeetAudioReader.read(fileURL: fileURL, check: check) { samples in
            pending.append(contentsOf: samples)
            while pending.count >= LocalParakeetCore.maxSamples {
                pieces.append(try transcribeChunk(Array(pending.prefix(LocalParakeetCore.maxSamples)), check: check))
                pending.removeFirst(LocalParakeetCore.maxSamples)
            }
        }
        if !pending.isEmpty { pieces.append(try transcribeChunk(pending, check: check)) }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func transcribeChunk(_ input: [Float], check: () throws -> Void) throws -> String {
        try check()
        guard input.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Audio contains invalid samples.") }
        if input.allSatisfy({ $0 == 0 }) { return "" }
        // NeMo's unbiased per-feature normalization needs at least two frames.
        let pcm = input.count < 480 ? input + [Float](repeating: 0, count: 480 - input.count) : input
        let bucket = try LocalParakeetCore.bucket(samples: pcm.count)
        let model: MLModel
        if let cached = models[bucket] { model = cached }
        else {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            if #available(macOS 15, *) { config.functionName = "b\(bucket)" }
            else { throw LocalParakeetError.invalid("Parakeet requires macOS 26 or newer.") }
            model = try MLModel(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: config)
            models[bucket] = model
        }
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
