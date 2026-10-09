//! Scalar f64 references for the ternary GEMM kernels.

use lf_model::TernaryMatrix;

use crate::QuantizedActs;

/// `Y[t][o] = scale[o] * sum_i code(o, i) * X[t][i]` in f64.
pub fn reference(m: &TernaryMatrix, x: &[f32], t: usize) -> Vec<f64> {
    reference_with(m, t, |f, i| x[f * m.cols + i] as f64)
}

/// The same product on the activations the INT8 kernels actually see.
pub fn reference_quantized(m: &TernaryMatrix, qa: &QuantizedActs) -> Vec<f64> {
    reference_with(m, qa.rows(), |f, i| qa.dequantized(f, i))
}

fn reference_with(m: &TernaryMatrix, t: usize, x: impl Fn(usize, usize) -> f64) -> Vec<f64> {
    let codes: Vec<i8> = (0..m.rows * m.cols)
        .map(|j| m.code(j / m.cols, j % m.cols))
        .collect();
    let mut y = vec![0.0; t * m.rows];
    for f in 0..t {
        let xf: Vec<f64> = (0..m.cols).map(|i| x(f, i)).collect();
        for o in 0..m.rows {
            let row = &codes[o * m.cols..(o + 1) * m.cols];
            let dot: f64 = row.iter().zip(&xf).map(|(&c, &v)| c as f64 * v).sum();
            y[f * m.rows + o] = dot * m.scale[o] as f64;
        }
    }
    y
}

/// Relative RMS error and worst absolute error over the reference RMS.
pub fn compare(y: &[f32], reference: &[f64]) -> (f64, f64) {
    let rms = (reference.iter().map(|v| v * v).sum::<f64>() / reference.len() as f64).sqrt();
    let mut sq = 0.0;
    let mut worst = 0.0f64;
    for (&a, &b) in y.iter().zip(reference) {
        let d = a as f64 - b;
        sq += d * d;
        worst = worst.max(d.abs());
    }
    let rel_rms = (sq / reference.len() as f64).sqrt() / rms;
    (rel_rms, worst / rms)
}
