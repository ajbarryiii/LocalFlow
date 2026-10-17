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
    // Retained correction audio; queue only. Memory only, never written.
    private let corrections = CorrectionSessionStore<RetainedCorrection>()
    private var expiry: DispatchWorkItem?
    private let verificationLock = NSLock()
    private var verification: ParakeetCancellation?

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

    /// In-memory samples with an immutable dictionary snapshot (iOS): boosting,
    /// then casing restoration. An empty dictionary takes the unbiased path.
    func transcribe(samples: [Float], directory: URL, dictionary: DictionarySnapshot) async throws -> String {
        try await transcribe(directory: directory) { runtime, check in
            let bias = runtime.graph(for: dictionary)
            let text = try runtime.transcribe(samples: samples, bias: bias, retain: false, check: check).text
            return CasingRestorer.apply(text, entries: dictionary.entries)
        }
    }

    /// "Find strength" (iOS, `StrengthProbe`): transcribes `samples` with the
    /// dictionary minus `word`, then re-decodes the same encoder output with
    /// `word` added at increasing strengths. Audio and text stay in memory and
    /// are released when this returns. `word` must be a validated entry text.
    func probeStrength(samples: [Float], directory: URL, word: String,
                       dictionary: DictionarySnapshot) async throws -> StrengthProbe.Result {
        try await transcribe(directory: directory) { runtime, check in
            let key = DictionaryKey(word)
            let others = dictionary.entries.filter { $0.key != key }
            let bias = others.isEmpty ? nil : BiasGraph.build(entries: others, encoder: runtime.encoder)
            let decoded = try runtime.transcribe(samples: samples, bias: bias, retain: true, check: check)
            guard let retained = decoded.retained else {
                throw LocalParakeetError.invalid("The recording is too long to test.")
            }
            let base = CasingRestorer.apply(decoded.text, entries: others)
            return try StrengthProbe.find(word: word, base: base) { strength in
                let entries = others + [DictionaryEntry(text: word, strength: strength)]
                guard let graph = BiasGraph.build(entries: entries, encoder: runtime.encoder) else {
                    throw LocalParakeetError.invalid("This word can't be tested with the speech model.")
                }
                return CasingRestorer.apply(try runtime.decode(retained.chunks, bias: graph, check: check), entries: entries)
            }
        }
    }

    /// Dictation with an immutable dictionary snapshot: boosting, then casing
    /// restoration on the raw text. With `retainForCorrection`, the audio
    /// projections are kept in memory for later verification (DESIGN §3.4) and
    /// the result carries their `dictationID`. Any previous session is dropped.
    func transcribe(fileURL: URL, dictionary: DictionarySnapshot, retainForCorrection: Bool) async throws -> TranscriptionResult {
        guard Self.isAvailable, let directory = Self.bundleDirectory else {
            throw LocalParakeetError.invalid("The bundled LocalFlow model requires Apple Silicon and macOS 26 or newer. Use a build that includes the model.")
        }
        cancelVerification()
        return try await transcribe(directory: directory) { runtime, check in
            self.corrections.discard()
            let bias = runtime.graph(for: dictionary)
            let decoded = try runtime.transcribe(fileURL: fileURL, bias: bias, retain: retainForCorrection, check: check)
            let text = CasingRestorer.apply(decoded.text, entries: dictionary.entries)
            guard retainForCorrection, let retained = decoded.retained else {
                return TranscriptionResult(text: text, dictationID: nil)
            }
            let session = RetainedCorrection(runtime: runtime, chunks: retained.chunks, dictionary: dictionary, base: text)
            let id = self.corrections.retain(session, bytes: retained.bytes, now: ProcessInfo.processInfo.systemUptime)
            if let id { self.scheduleExpiry(id: id) }
            return TranscriptionResult(text: text, dictationID: id)
        }
    }

    /// Registers a correction check now, cancelling any older one. Call it
    /// synchronously when the check is decided, so checks keep that order
    /// however late their work starts.
    func beginCorrectionCheck() -> CorrectionCheck {
        CorrectionCheck(cancellation: beginVerification())
    }

    /// Runs candidates and verification (DESIGN §1.5-1.6) against the retained
    /// session on the model queue. A stale or expired `dictationID`, a new
    /// recording, a newer check, a dictionary change or cancelling the calling
    /// task yields nil. The audio stays retained for later checks of the same
    /// dictation until `isLast` (the watch has ended) or `releaseCorrectionSession`.
    func suggestCorrection(typed: String, edited: String, dictationID: UInt64, ignore: Set<DictionaryKey>,
                           isLast: Bool, check: CorrectionCheck) async -> DictionarySuggestion? {
        let cancellation = check.cancellation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let now = { ProcessInfo.processInfo.systemUptime }
                    guard !cancellation.isCancelled, let session = self.corrections.session(id: dictationID, now: now()) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let encoder = session.runtime.encoder
                    let suggestion = DictionarySuggestionFinder.find(
                        typed: typed, edited: edited, base: session.base, dictionary: session.dictionary.entries, ignore: ignore,
                        encoder: encoder, exhausted: session.exhausted, now: now,
                        isCancelled: { cancellation.isCancelled || self.corrections.currentID != dictationID },
                        decode: { extra in
                            let entries = session.dictionary.entries.filter { $0.key != extra.key } + [extra]
                            guard let graph = BiasGraph.build(entries: entries, encoder: encoder),
                                  let text = try? session.runtime.decode(session.chunks, bias: graph, check: cancellation.check) else {
                                return nil
                            }
                            return CasingRestorer.apply(text, entries: entries)
                        })
                    let cancelled = cancellation.isCancelled
                    // After the last check nothing else can use this dictation's audio.
                    if isLast && !cancelled { self.corrections.expire(id: dictationID) }
                    continuation.resume(returning: cancelled ? nil : suggestion)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// New recording, cancel, setting off or dictionary change: stop any
    /// verification between decodes and drop the retained audio.
    func discardCorrectionSession() {
        cancelVerification()
        queue.async {
            self.corrections.discard()
            self.expiry?.cancel()
            self.expiry = nil
        }
    }

    /// One verification at a time; a newer one cancels the older.
    private func beginVerification() -> ParakeetCancellation {
        let cancellation = ParakeetCancellation()
        verificationLock.lock()
        verification?.cancel()
        verification = cancellation
        verificationLock.unlock()
        return cancellation
    }

    /// Releases one dictation's retained audio, never a newer one's.
    func releaseCorrectionSession(dictationID: UInt64) {
        queue.async { self.corrections.expire(id: dictationID) }
    }

    private func cancelVerification() {
        verificationLock.lock()
        verification?.cancel()
        verification = nil
        verificationLock.unlock()
    }

    // Call only on queue.
    private func scheduleExpiry(id: UInt64) {
        expiry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.corrections.expire(id: id) }
        expiry = item
        queue.asyncAfter(deadline: .now() + CorrectionSessionStore<RetainedCorrection>.defaultLifetime, execute: item)
    }

    private func transcribe<T>(directory: URL,
                               _ operation: @escaping @Sendable (LocalParakeetRuntime, () throws -> Void) throws -> T) async throws -> T {
        let cancellation = ParakeetCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let result = try operation(self.runtime(for: directory), cancellation.check)
                        try cancellation.check()
                        continuation.resume(returning: result)
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
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// An immutable dictionary: decoding never reads mutable dictionary state.
/// `revision` identifies the snapshot for graph caching.
struct DictionarySnapshot: Sendable {
    let revision: UInt64
    let entries: [DictionaryEntry]

    static let empty = DictionarySnapshot(revision: 0, entries: [])
}

struct TranscriptionResult: Sendable {
    /// Raw transcript after casing restoration, before LocalDictationCore.
    let text: String
    /// Set only when the audio was retained for correction suggestions.
    let dictationID: UInt64?
}

/// Encoder output kept for re-decoding, owned (not a view on Core ML memory).
private final class RetainedProjection {
    let buffer: FloatBuffer
    let frames: Int
    init(buffer: FloatBuffer, frames: Int) { self.buffer = buffer; self.frames = frames }
}

/// One chunk's place in the recording, so re-decoding stitches overlaps
/// exactly as the original transcription did. A nil projection marks a silent
/// chunk, which stitches as no words.
private struct RetainedChunk {
    let range: Range<Int>
    let projection: RetainedProjection?
}

/// Every chunk of one dictation in order.
private struct RetainedAudio {
    var chunks: [RetainedChunk] = []
    var bytes = 0
}

private struct RetainedCorrection {
    let runtime: LocalParakeetRuntime
    let chunks: [RetainedChunk]
    let dictionary: DictionarySnapshot
    let base: String
    /// Shared by every check of this dictation; model queue only.
    let exhausted = ExhaustedCandidates()
}

private final class LocalParakeetRuntime {
    private enum Audio { case file(URL), samples([Float]) }

    let directory: URL
    let frontend: VDSPFrontEnd
    let math: NativeMath
    let vocabulary: [String]
    /// Scalar-keyed BPE over the same vocabulary, for dictionary phrases.
    let encoder: BPEEncoder
    private var cachedGraph: (revision: UInt64, graph: BiasGraph?)?
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
        encoder = BPEEncoder(pieces: vocabulary)
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
        try transcribe(fileURL: fileURL, bias: nil, retain: false, check: check).text
    }

    func transcribe(fileURL: URL, bias: BiasGraph?, retain: Bool,
                    check: () throws -> Void) throws -> (text: String, retained: RetainedAudio?) {
        try transcribe(.file(fileURL), bias: bias, retain: retain, check: check)
    }

    func transcribe(samples: [Float], check: () throws -> Void) throws -> String {
        try transcribe(samples: samples, bias: nil, retain: false, check: check).text
    }

    func transcribe(samples: [Float], bias: BiasGraph?, retain: Bool,
                    check: () throws -> Void) throws -> (text: String, retained: RetainedAudio?) {
        try transcribe(.samples(samples), bias: bias, retain: retain, check: check)
    }

    /// Silence is compacted before chunking, so chunk ranges and word starts
    /// are positions in the compacted model input, not in the recording.
    private func transcribe(_ audio: Audio, bias: BiasGraph?, retain: Bool,
                            check: () throws -> Void) throws -> (text: String, retained: RetainedAudio?) {
        var compactor = ParakeetSilenceCompactor(), chunker = makeChunker(), transcript = ParakeetTranscriptAssembler()
        var retained: RetainedAudio? = retain ? RetainedAudio() : nil
        func assemble(_ chunk: ParakeetChunk) throws {
            transcript.append(try transcribeChunk(chunk, bias: bias, retained: &retained, check: check), covering: chunk.range)
        }
        func feed(_ samples: [Float]) throws { try chunker.append(samples, emit: assemble) }
        switch audio {
        case .file(let url): try ParakeetAudioReader.read(fileURL: url, check: check) { try compactor.append($0, emit: feed) }
        case .samples(let samples): try compactor.append(samples, emit: feed)
        }
        try compactor.finish(emit: feed)
        try chunker.finish(emit: assemble)
        return (transcript.text, retained)
    }

    /// Re-decodes retained chunks exactly as transcribed, with a new bias.
    func decode(_ chunks: [RetainedChunk], bias: BiasGraph?, check: () throws -> Void) throws -> String {
        var transcript = ParakeetTranscriptAssembler()
        for chunk in chunks {
            let words = try chunk.projection.map { try decode($0, offset: chunk.range.lowerBound, bias: bias, check: check) } ?? []
            transcript.append(words, covering: chunk.range)
        }
        return transcript.text
    }

    /// Built here, on the model queue, and cached by snapshot revision. An
    /// empty dictionary has no graph, so decoding takes the unbiased path.
    func graph(for snapshot: DictionarySnapshot) -> BiasGraph? {
        guard !snapshot.entries.isEmpty else { return nil }
        if let cachedGraph, cachedGraph.revision == snapshot.revision { return cachedGraph.graph }
        let graph = BiasGraph.build(entries: snapshot.entries, encoder: encoder)
        cachedGraph = (snapshot.revision, graph)
        return graph
    }

    // Installs also run on this queue, so readiness is fixed for the recording.
    private func makeChunker() -> ParakeetChunker {
        ParakeetChunker(size: models.chunkSamples(strategy: startupStrategy), overlap: LocalParakeetCore.chunkOverlapSamples)
    }

    private func transcribeChunk(_ chunk: ParakeetChunk, bias: BiasGraph?, retained: inout RetainedAudio?,
                                 check: () throws -> Void) throws -> [ParakeetWord] {
        guard let projection = try project(chunk.samples, check: check) else {
            retained?.chunks.append(RetainedChunk(range: chunk.range, projection: nil))
            return []
        }
        if retained != nil {
            retained!.chunks.append(RetainedChunk(range: chunk.range, projection: projection))
            retained!.bytes += projection.frames * 640 * MemoryLayout<Float>.size
            // Over the limit nothing is kept, but transcription continues.
            if retained!.bytes > CorrectionSessionStore<RetainedProjection>.defaultMaxBytes { retained = nil }
        }
        return try decode(projection, offset: chunk.start, bias: bias, check: check)
    }

    /// Encoder and joint projection of one chunk; nil for digital silence.
    private func project(_ input: [Float], check: () throws -> Void) throws -> RetainedProjection? {
        try check()
        guard input.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Audio contains invalid samples.") }
        if input.allSatisfy({ $0 == 0 }) { return nil }
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
        return RetainedProjection(buffer: projection, frames: frames.count)
    }

    /// Words of one chunk, timed from `offset`, the chunk's first recording sample.
    private func decode(_ retained: RetainedProjection, offset: Int, bias: BiasGraph?,
                        check: () throws -> Void) throws -> [ParakeetWord] {
        let projection = retained.buffer
        var h = [Float](repeating: 0, count: 1280), c = h
        if let bias {
            var g = [Float](repeating: 0, count: 640), z = g
            let logits = FloatBuffer(count: 1030)
            let tokens = try LocalParakeetCore.decode(length: retained.frames, bias: bias, predict: { token in
                math.predict(token, h: &h, c: &c, g: &g)
            }, joint: { frame in
                let decision = math.joint(f: projection.pointer + frame * 640, g: &g, z: &z, logits: logits.pointer)
                guard UnsafeBufferPointer(start: logits.pointer, count: 1030).allSatisfy(\.isFinite) else {
                    throw LocalParakeetError.invalid("Local decoder produced invalid values.")
                }
                return (UnsafePointer(logits.pointer), decision.1)
            }, check: check)
            return try LocalParakeetCore.words(tokens, vocabulary: vocabulary, offset: offset)
        }
        // No dictionary: exactly the original decoding path.
        var g = [Float](repeating: 0, count: 640), z = g, logits = [Float](repeating: 0, count: 1030)
        let tokens = try LocalParakeetCore.decode(length: retained.frames, predict: { token in
            math.predict(token, h: &h, c: &c, g: &g)
        }, joint: { frame in
            let decision = math.joint(f: projection.pointer + frame * 640, g: &g, z: &z, logits: &logits)
            guard logits.allSatisfy(\.isFinite) else { throw LocalParakeetError.invalid("Local decoder produced invalid values.") }
            return decision
        }, check: check)
        return try LocalParakeetCore.words(tokens, vocabulary: vocabulary, offset: offset)
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

/// A registered correction check. Registering a newer one, a new recording,
/// a dictionary change or turning suggestions off cancels it.
struct CorrectionCheck: Sendable {
    fileprivate let cancellation: ParakeetCancellation

    var isCancelled: Bool { cancellation.isCancelled }
}
