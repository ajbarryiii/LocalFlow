// Adapted from wilderness-labs-stt BenchCore (parakeet-ios, WP7).
// Native vDSP front end and FP32 Accelerate decoder; no diagnostic persistence.
import Accelerate
import CoreML
import Foundation

extension MLMultiArray {
    var intShape: [Int] { shape.map(\.intValue) }
    var intStrides: [Int] { strides.map(\.intValue) }
}

/// Float storage that outlives the views onto it (external encoder outputs, native buffers).
public final class FloatBuffer {
    public let pointer: UnsafeMutablePointer<Float>
    public let count: Int
    public init(count: Int) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: 0, count: max(count, 1))
    }
    public convenience init(_ values: [Float]) {
        self.init(count: values.count)
        values.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: values.count) }
    }
    deinit { pointer.deallocate() }
}

/// Stride-aware view of encoder frames: the Core ML output [1, 1024, T] or [1, T, 1024] (FluidAudio 0.7.8
/// EncoderFrameView), or an external time-major [T, 1024] buffer (the reference's encoder output, F2 gate).
public struct EncoderFrames {
    public let count: Int
    public let hiddenStride: Int
    public let timeStride: Int
    public let base: UnsafeMutablePointer<Float>
    let owner: AnyObject

    public init(_ output: MLMultiArray, validLength: Int) throws {
        let shape = output.intShape, strides = output.intStrides
        guard shape.count == 3, shape[0] == 1, shape[1] == 1024 || shape[2] == 1024, output.dataType == .float32 else {
            throw LocalParakeetError.invalid("unexpected encoder output \(shape) \(output.dataType.rawValue)")
        }
        let hiddenAxis = shape[1] == 1024 ? 1 : 2
        let timeAxis = 3 - hiddenAxis
        hiddenStride = strides[hiddenAxis]
        timeStride = strides[timeAxis]
        count = min(validLength, shape[timeAxis])
        guard count > 0, hiddenStride > 0, timeStride > 0 else { throw LocalParakeetError.invalid("encoder output has no frames") }
        owner = output
        base = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
    }

    public init(timeMajor buffer: FloatBuffer, frames: Int) throws {
        guard frames > 0, buffer.count == frames * 1024 else { throw LocalParakeetError.invalid("external encoder output size") }
        count = frames; hiddenStride = 1; timeStride = 1024; base = buffer.pointer; owner = buffer
    }

    public func copyFrame(_ t: Int, into dest: UnsafeMutablePointer<Float>, destStride: Int) throws {
        guard t >= 0 && t < count else { throw LocalParakeetError.invalid("encoder frame \(t) out of range \(count)") }
        let src = base.advanced(by: t * timeStride)
        if hiddenStride == 1 && destStride == 1 {
            dest.update(from: src, count: 1024)
        } else {
            cblas_scopy(1024, src, Int32(hiddenStride), dest, Int32(destStride))
        }
    }

    /// Time-major copy of the valid frames [count, 1024] (diagnostics).
    public func timeMajor() throws -> [Float] {
        var out = [Float](repeating: 0, count: count * 1024)
        try out.withUnsafeMutableBufferPointer { buf in
            for t in 0..<count { try copyFrame(t, into: buf.baseAddress! + t * 1024, destStride: 1) }
        }
        return out
    }
}
