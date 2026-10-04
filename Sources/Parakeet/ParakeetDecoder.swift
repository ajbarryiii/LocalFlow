// Adapted from wilderness-labs-stt BenchCore (parakeet-ios, WP7).
// Native vDSP front end and FP32 Accelerate decoder; no diagnostic persistence.
import Accelerate
import Foundation

/// Decoder + joint weights of a benchmark model (native.py weights: decoder_joint.json + .f32bin).
public final class NativeWeights {
    public static let hidden = 640, layers = 2, dModel = 1024, outputs = 1030, vocabPlusBlank = 1025
    public let manifest: [String: Any]
    let embed, wih0, whh0, bias0, w1cat, bias1, encW, encB, predW, predB, outW, outB: [Float]

    public convenience init(directory: URL) throws {
        let blob = try NativeBlob(directory: directory, stem: "decoder_joint")
        try self.init(tensors: blob.tensors.mapValues { $0.values }, manifest: blob.manifest)
    }

    /// From NeMo-named tensors (sizes checked; shapes as in native.py DECODER_KEYS).
    public init(tensors: [String: [Float]], manifest: [String: Any] = [:]) throws {
        let blob = NamedTensors(tensors)
        let H = Self.hidden, G = 4 * H
        let p = "decoder.prediction."
        embed = try blob.tensor(p + "embed.weight", [Self.vocabPlusBlank, H])
        wih0 = try blob.tensor(p + "dec_rnn.lstm.weight_ih_l0", [G, H])
        whh0 = try blob.tensor(p + "dec_rnn.lstm.weight_hh_l0", [G, H])
        let bih0 = try blob.tensor(p + "dec_rnn.lstm.bias_ih_l0", [G]), bhh0 = try blob.tensor(p + "dec_rnn.lstm.bias_hh_l0", [G])
        let wih1 = try blob.tensor(p + "dec_rnn.lstm.weight_ih_l1", [G, H]), whh1 = try blob.tensor(p + "dec_rnn.lstm.weight_hh_l1", [G, H])
        let bih1 = try blob.tensor(p + "dec_rnn.lstm.bias_ih_l1", [G]), bhh1 = try blob.tensor(p + "dec_rnn.lstm.bias_hh_l1", [G])
        bias0 = zip(bih0, bhh0).map { $0 + $1 }
        bias1 = zip(bih1, bhh1).map { $0 + $1 }
        var cat = [Float](repeating: 0, count: G * 2 * H)  // [W_ih1 | W_hh1], [2560, 1280]
        for r in 0..<G {
            for c in 0..<H { cat[r * 2 * H + c] = wih1[r * H + c]; cat[r * 2 * H + H + c] = whh1[r * H + c] }
        }
        w1cat = cat
        encW = try blob.tensor("joint.enc.weight", [H, Self.dModel]); encB = try blob.tensor("joint.enc.bias", [H])
        predW = try blob.tensor("joint.pred.weight", [H, H]); predB = try blob.tensor("joint.pred.bias", [H])
        outW = try blob.tensor("joint.joint_net.2.weight", [Self.outputs, H]); outB = try blob.tensor("joint.joint_net.2.bias", [Self.outputs])
        guard embed[(Self.vocabPlusBlank - 1) * H..<Self.vocabPlusBlank * H].allSatisfy({ $0 == 0 }) else {
            throw LocalParakeetError.invalid("the blank embedding row must be zero (start symbol)")
        }
        self.manifest = manifest
    }
}

struct NamedTensors {
    let values: [String: [Float]]
    init(_ values: [String: [Float]]) { self.values = values }
    func tensor(_ name: String, _ shape: [Int]) throws -> [Float] {
        guard let v = values[name] else { throw LocalParakeetError.invalid("missing tensor \(name)") }
        guard v.count == shape.reduce(1, *) else { throw LocalParakeetError.invalid("\(name): \(v.count) values for \(shape)") }
        return v
    }
}

/// Shared native math: the 2-layer LSTM step (PyTorch gate order i, f, g, o), the pred projection and the joint.
final class NativeMath {
    let w: NativeWeights
    let H = NativeWeights.hidden
    /// layer-0 input contribution per token: embed[token] W_ih0^T + b_ih0 + b_hh0, [1025, 2560] (one sgemm at load)
    let table0: [Float]
    var gates = [Float](repeating: 0, count: 2560)
    var xcat = [Float](repeating: 0, count: 1280)

    init(_ w: NativeWeights) {
        self.w = w
        let G = 4 * NativeWeights.hidden, V = NativeWeights.vocabPlusBlank
        var t = [Float](repeating: 0, count: V * G)
        for v in 0..<V { for g in 0..<G { t[v * G + g] = w.bias0[g] } }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(V), Int32(G), Int32(NativeWeights.hidden), 1,
                    w.embed, Int32(NativeWeights.hidden), w.wih0, Int32(NativeWeights.hidden), 1, &t, Int32(G))
        table0 = t
    }

    @inline(__always) static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// One LSTM cell update in place: h, c [640] with gates [2560] (already holding the input + bias part).
    func cell(_ gates: UnsafeMutablePointer<Float>, h: UnsafeMutablePointer<Float>, c: UnsafeMutablePointer<Float>) {
        for k in 0..<H {
            let i = Self.sigmoid(gates[k]), f = Self.sigmoid(gates[H + k])
            let g = tanh(gates[2 * H + k]), o = Self.sigmoid(gates[3 * H + k])
            let cn = f * c[k] + i * g
            c[k] = cn
            h[k] = o * tanh(cn)
        }
    }

    /// Prediction network on `token` from state (h, c) [2, 640] each, updated in place; writes the projected output
    /// g = W_pred h_top + b_pred [640].
    func predict(_ token: Int, h: UnsafeMutablePointer<Float>, c: UnsafeMutablePointer<Float>, g: UnsafeMutablePointer<Float>) {
        let G = 4 * H
        gates.withUnsafeMutableBufferPointer { gp in
            // layer 0: gates = table0[token] + W_hh0 h0
            table0.withUnsafeBufferPointer { gp.baseAddress!.update(from: $0.baseAddress! + token * G, count: G) }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(G), Int32(H), 1, w.whh0, Int32(H), h, 1, 1, gp.baseAddress!, 1)
            cell(gp.baseAddress!, h: h, c: c)
            // layer 1: gates = [W_ih1 | W_hh1] [h0'; h1] + b_ih1 + b_hh1
            xcat.withUnsafeMutableBufferPointer { x in
                x.baseAddress!.update(from: h, count: H)
                (x.baseAddress! + H).update(from: h + H, count: H)
                w.bias1.withUnsafeBufferPointer { gp.baseAddress!.update(from: $0.baseAddress!, count: G) }
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(G), Int32(2 * H), 1, w.w1cat, Int32(2 * H), x.baseAddress!, 1, 1,
                            gp.baseAddress!, 1)
            }
            cell(gp.baseAddress!, h: h + H, c: c + H)
        }
        w.predB.withUnsafeBufferPointer { g.update(from: $0.baseAddress!, count: H) }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(H), Int32(H), 1, w.predW, Int32(H), h + H, 1, 1, g, 1)
    }

    /// Encoder-side joint projection of frames 0..<length: f [length, 640] = E W_enc^T + b_enc (one sgemm).
    func project(_ frames: EncoderFrames, length: Int, into f: UnsafeMutablePointer<Float>) {
        for t in 0..<length { w.encB.withUnsafeBufferPointer { (f + t * H).update(from: $0.baseAddress!, count: H) } }
        if frames.hiddenStride == 1 {  // time-major [T, 1024]
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(length), Int32(H), 1024, 1, frames.base,
                        Int32(frames.timeStride), w.encW, 1024, 1, f, Int32(H))
        } else {                       // hidden-major [1024, T_alloc] with unit time stride
            cblas_sgemm(CblasRowMajor, CblasTrans, CblasTrans, Int32(length), Int32(H), 1024, 1, frames.base,
                        Int32(frames.hiddenStride), w.encW, 1024, 1, f, Int32(H))
        }
    }

    /// Joint logits [1030] = W_out relu(f_t + g) + b_out; returns (argmax token over 1025, argmax duration bin).
    func joint(f: UnsafePointer<Float>, g: UnsafePointer<Float>, z: UnsafeMutablePointer<Float>,
               logits: UnsafeMutablePointer<Float>) -> (Int, Int) {
        vDSP_vadd(f, 1, g, 1, z, 1, vDSP_Length(H))
        var zero: Float = 0
        vDSP_vthr(z, 1, &zero, z, 1, vDSP_Length(H))
        w.outB.withUnsafeBufferPointer { logits.update(from: $0.baseAddress!, count: NativeWeights.outputs) }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(NativeWeights.outputs), Int32(H), 1, w.outW, Int32(H), z, 1, 1, logits, 1)
        return (argmax(logits, 1025), argmax(logits + 1025, 5))
    }

    @inline(__always) func argmax(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        var best = 0
        for i in 1..<n where p[i] > p[best] { best = i }  // first maximum, as torch.max
        return best
    }
}

