import Foundation

/// Resamples a swipe to the encoder's fixed-length trajectory, exactly as the reference
/// `swipe/features.py` does (ARCHITECTURE.md, "Typing model v4 and swipe typing", step 2).
enum SwipeResampler {
    static let points = 64

    /// `t` in milliseconds (any origin), `x`/`y` in the swipe frame. Returns `points * 2` values: x0, y0, x1, y1, ...
    ///
    /// Computed in Float64 like the reference, whose output is Float32: each value is rounded to the
    /// nearest Float32, which is also what the encoder takes.
    static func resample(t: [Double], x: [Double], y: [Double]) -> [Double] {
        precondition(!t.isEmpty && t.count == x.count && t.count == y.count, "a swipe needs matching samples")

        // Non-decreasing timestamps (running maximum), shifted to start at 0.
        var times = t
        for index in times.indices.dropFirst() where times[index] < times[index - 1] {
            times[index] = times[index - 1]
        }
        let origin = times[0]
        for index in times.indices { times[index] -= origin }
        let duration = times[times.count - 1]

        var xs = x, ys = y
        if duration > 1.0 && duration.isFinite {
            // Keep the last sample per timestamp, so the times strictly increase.
            var keptT: [Double] = [], keptX: [Double] = [], keptY: [Double] = []
            keptT.reserveCapacity(times.count)
            keptX.reserveCapacity(times.count)
            keptY.reserveCapacity(times.count)
            for index in times.indices where index == times.count - 1 || times[index + 1] != times[index] {
                keptT.append(times[index])
                keptX.append(x[index])
                keptY.append(y[index])
            }
            let grid = linspace(0, duration, count: samples60Hz(duration))
            xs = interpolate(grid, keptT, keptX)
            ys = interpolate(grid, keptT, keptY)
        }

        let index = linspace(0, Double(xs.count - 1), count: points)
        let source = (0 ..< xs.count).map(Double.init)
        let outX = interpolate(index, source, xs)
        let outY = interpolate(index, source, ys)
        var out: [Double] = []
        out.reserveCapacity(points * 2)
        for k in 0 ..< points {
            out.append(Double(Float(outX[k])))
            out.append(Double(Float(outY[k])))
        }
        return out
    }

    /// `max(2, floor(duration × 60 / 1000 + 0.5) + 1)`: 60 Hz, halves round up.
    static func samples60Hz(_ durationMs: Double) -> Int {
        max(2, Int((durationMs * 60.0 / 1000.0 + 0.5).rounded(.down)) + 1)
    }

    /// `numpy.linspace(start, stop, count)`: `i * step + start`, the last value exactly `stop`.
    private static func linspace(_ start: Double, _ stop: Double, count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [start] : [] }
        let div = Double(count - 1)
        let delta = stop - start
        let step = delta / div
        var out = [Double](repeating: 0, count: count)
        for i in 0 ..< count {
            // numpy divides first when the step underflows to zero (denormals).
            out[i] = (step == 0 ? Double(i) / div * delta : Double(i) * step) + start
        }
        out[count - 1] = stop
        return out
    }

    /// `numpy.interp(query, xp, fp)` for ascending `query` and strictly increasing `xp`, with numpy's
    /// arithmetic: `slope * (x - xp[j]) + fp[j]`, ends clamped.
    private static func interpolate(_ query: [Double], _ xp: [Double], _ fp: [Double]) -> [Double] {
        let n = xp.count
        guard n > 1 else { return [Double](repeating: fp[0], count: query.count) }
        var out = [Double](repeating: 0, count: query.count)
        var j = 0
        for (k, value) in query.enumerated() {
            if value >= xp[n - 1] {
                out[k] = fp[n - 1]
                continue
            }
            if value < xp[0] {
                out[k] = fp[0]
                continue
            }
            if value < xp[j] { j = 0 }
            while j + 1 < n - 1 && xp[j + 1] <= value { j += 1 }
            if xp[j] == value {
                out[k] = fp[j]
                continue
            }
            let slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j])
            var result = slope * (value - xp[j]) + fp[j]
            if result.isNaN {
                result = slope * (value - xp[j + 1]) + fp[j + 1]
                if result.isNaN && fp[j] == fp[j + 1] { result = fp[j] }
            }
            out[k] = result
        }
        return out
    }
}
