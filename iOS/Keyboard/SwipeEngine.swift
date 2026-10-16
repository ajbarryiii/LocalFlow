import CoreML
import Foundation

/// The swipe encoder: a trajectory and the letter keys in, per-frame log-probabilities out
/// (ARCHITECTURE.md, "Typing model v4 and swipe typing", step 3). Core ML in the keyboard, a fake in
/// tests.
protocol SwipeEncoding: AnyObject {
    /// `trajectory`: `SwipeResampler.points` × 2 values (x, y per point); `keys`: 26 × 2 (a–z centers),
    /// both in the frame. Returns frames × `SwipeDecoder.columns` log-probabilities, row-major.
    func logProbs(trajectory: [Float], keys: [Float]) throws -> [Double]
}

enum SwipeEngineError: Error, Equatable {
    case unsupportedFormat
    case invalidSettings
    case invalidModel
    case invalidOutput
}

/// `bundle.json` of a swipe bundle: `{"format": 1, "decode": {beam, top_k, length_power, freq_weight,
/// length_bonus}, "files": {path: sha256}}`. The build checks the hashes; the keyboard reads the
/// decoder settings.
struct SwipeBundleManifest: Decodable {
    static let format = 1

    struct Decode: Decodable {
        var beam: Int
        var topK: Int
        var lengthPower: Double
        var freqWeight: Double
        var lengthBonus: Double

        enum CodingKeys: String, CodingKey {
            case beam
            case topK = "top_k"
            case lengthPower = "length_power"
            case freqWeight = "freq_weight"
            case lengthBonus = "length_bonus"
        }
    }

    var format: Int
    var decode: Decode

    /// The decoder settings of a `bundle.json`, or an error if it is not a valid format-1 manifest.
    static func decodeConfig(from data: Data) throws -> SwipeDecodeConfig {
        let manifest = try JSONDecoder().decode(SwipeBundleManifest.self, from: data)
        guard manifest.format == format else { throw SwipeEngineError.unsupportedFormat }
        let d = manifest.decode
        guard d.beam >= 1, d.topK >= 1, d.lengthPower.isFinite, d.freqWeight.isFinite, d.lengthBonus.isFinite else {
            throw SwipeEngineError.invalidSettings
        }
        return SwipeDecodeConfig(beam: d.beam, topK: d.topK, lengthPower: d.lengthPower, freqWeight: d.freqWeight,
                                 lengthBonus: d.lengthBonus)
    }
}

/// Decodes a swipe into candidate words: the frame from the letter keys, the samples normalized and
/// resampled, the encoder, then the lexicon-constrained beam search. Loaded once off the main thread;
/// immutable afterwards and used on the main thread only, so it is shared unchecked. Samples,
/// candidates and decoder state stay in memory: nothing here logs, stores or sends them.
final class SwipeEngine: @unchecked Sendable {
    /// The bundle's directory inside the keyboard extension.
    static let directoryName = "Swipe"

    let config: SwipeDecodeConfig
    private let encoder: SwipeEncoding
    private let lexicon: SwipeLexicon

    init(encoder: SwipeEncoding, lexicon: SwipeLexicon, config: SwipeDecodeConfig) {
        self.encoder = encoder
        self.lexicon = lexicon
        self.config = config
    }

    /// Loads `bundle.json`, `lexicon.bin` (memory-mapped) and `SwipeEncoder.mlmodelc` (CPU only) from
    /// `directory`, and runs the encoder once to check its output. Slow: call off the main thread.
    static func load(from directory: URL) throws -> SwipeEngine {
        let config = try SwipeBundleManifest.decodeConfig(from: Data(contentsOf: directory.appendingPathComponent("bundle.json")))
        let lexicon = try SwipeLexicon(data: Data(contentsOf: directory.appendingPathComponent("lexicon.bin"),
                                                  options: .alwaysMapped))
        let encoder = try CoreMLSwipeEncoder(url: directory.appendingPathComponent("SwipeEncoder.mlmodelc"))
        let probe = try encoder.logProbs(trajectory: [Float](repeating: 0, count: SwipeResampler.points * 2),
                                         keys: [Float](repeating: 0, count: 52))
        guard probe.count == CoreMLSwipeEncoder.frames * SwipeDecoder.columns else { throw SwipeEngineError.invalidOutput }
        return SwipeEngine(encoder: encoder, lexicon: lexicon, config: config)
    }

    /// The bundle in this process's main bundle (the keyboard extension), or nil if it has none.
    static var bundledDirectory: URL? {
        Bundle.main.url(forResource: directoryName, withExtension: nil)
    }

    /// The candidates for a swipe over `keys` (the letters layer, in the samples' coordinates), best
    /// first; empty when the keys are not a letters layout, the swipe has no samples, or the encoder
    /// fails.
    func candidates(for samples: [SwipeSample], keys: [PlacedKey]) -> [SwipeCandidate] {
        guard !samples.isEmpty, let frame = SwipeFrame(keys: keys) else { return [] }
        let points = samples.map { frame.normalize(x: $0.x, y: $0.y) }
        let trajectory = SwipeResampler.resample(t: samples.map { $0.t * 1000 }, x: points.map(\.x), y: points.map(\.y))
        guard trajectory.count == SwipeResampler.points * 2, trajectory.allSatisfy(\.isFinite),
              let logProbs = try? encoder.logProbs(trajectory: trajectory.map { Float($0) },
                                                   keys: frame.letterCenters.map { Float($0) }),
              !logProbs.isEmpty, logProbs.count % SwipeDecoder.columns == 0 else { return [] }
        return SwipeDecoder.decode(logProbs: logProbs, frames: logProbs.count / SwipeDecoder.columns, lexicon: lexicon,
                                   config: config)
    }
}

/// `SwipeEncoder.mlmodelc`: inputs `traj` Float32 [1, 64, 2] and `keys` Float32 [1, 26, 2], output
/// `log_probs` Float32 [1, 32, 27]; CPU only.
final class CoreMLSwipeEncoder: SwipeEncoding {
    static let frames = 32
    private let model: MLModel

    init(url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard Self.isArray(inputs["traj"], shape: [1, SwipeResampler.points, 2]),
              Self.isArray(inputs["keys"], shape: [1, 26, 2]),
              outputs["log_probs"]?.type == .multiArray else { throw SwipeEngineError.invalidModel }
    }

    private static func isArray(_ description: MLFeatureDescription?, shape: [Int]) -> Bool {
        guard let constraint = description?.multiArrayConstraint else { return false }
        return constraint.shape.map(\.intValue) == shape
    }

    func logProbs(trajectory: [Float], keys: [Float]) throws -> [Double] {
        guard trajectory.count == SwipeResampler.points * 2, keys.count == 52 else { throw SwipeEngineError.invalidOutput }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "traj": MLFeatureValue(multiArray: Self.array(trajectory, shape: [1, SwipeResampler.points, 2])),
            "keys": MLFeatureValue(multiArray: Self.array(keys, shape: [1, 26, 2])),
        ])
        let output = try model.prediction(from: input)
        guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue,
              logProbs.shape.map(\.intValue) == [1, Self.frames, SwipeDecoder.columns] else {
            throw SwipeEngineError.invalidOutput
        }
        // Contiguous Float32 whatever the output's strides or type.
        return MLShapedArray<Float>(converting: logProbs).scalars.map(Double.init)
    }

    private static func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        try array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            // A fresh array is contiguous in row-major order.
            guard strides.last == 1, buffer.count == values.count else { throw SwipeEngineError.invalidModel }
            for (index, value) in values.enumerated() { buffer[index] = value }
        }
        return array
    }
}
