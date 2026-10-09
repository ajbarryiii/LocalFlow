//! Per-frame activation quantization into `n` residual INT8 components.
//!
//! For a frame `x` with `m = max|x|` and `s = m / 127`:
//! `x ≈ s * (q0 + q1 / 254 + q2 / 254²)`, each `q` in [-127, 127]. The first
//! component's rounding error is at most `s / 2`, so the next one has 254 times
//! finer steps and still fits in [-127, 127]. Components are stored offset by
//! +128 as u8 for `VPDPBUSD`. One component carries about 8 bits of precision,
//! three about 24.

use std::sync::atomic::{AtomicBool, Ordering};

use crate::{SendPtr, ThreadPool, split_range};

pub const RATIO: f32 = 254.0;
pub const MAX_COMPONENTS: usize = 3;
const WEIGHTS: [f32; MAX_COMPONENTS] = [1.0, RATIO, RATIO * RATIO];

/// An activation was NaN or infinite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NonFiniteActivation;

impl std::fmt::Display for NonFiniteActivation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("non-finite activation")
    }
}

impl std::error::Error for NonFiniteActivation {}

/// Quantized frames. Fields are private so the buffer sizes the INT8 kernels
/// rely on always match `rows`, `components` and `cols`.
pub struct QuantizedActs {
    components: usize,
    rows: usize,
    cols: usize,
    /// `[rows][components][cols]`, offset by +128.
    q: Vec<u8>,
    /// Per-frame scale `s`.
    scale: Vec<f32>,
}

impl QuantizedActs {
    pub fn with_capacity(max_rows: usize, cols: usize, components: usize) -> Self {
        assert!((1..=MAX_COMPONENTS).contains(&components));
        assert!(cols > 0);
        QuantizedActs {
            components,
            rows: 0,
            cols,
            q: vec![128; crate::size(crate::size(max_rows, components), cols)],
            scale: vec![0.0; max_rows],
        }
    }

    pub fn components(&self) -> usize {
        self.components
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    /// `[rows][components][cols]`, offset by +128.
    pub fn q(&self) -> &[u8] {
        &self.q[..self.rows * self.components * self.cols]
    }

    /// Per-frame scale `s`.
    pub fn scale(&self) -> &[f32] {
        &self.scale[..self.rows]
    }

    /// Quantizes `rows` frames of `x` (`[rows][cols]`), growing the buffers if
    /// needed. Fails without a usable result if any activation is NaN or infinite.
    pub fn quantize(
        &mut self,
        pool: &ThreadPool,
        x: &[f32],
        rows: usize,
    ) -> Result<(), NonFiniteActivation> {
        let (k, n) = (self.cols, self.components);
        assert!(x.len() >= crate::size(rows, k));
        if self.scale.len() < rows {
            self.scale.resize(rows, 0.0);
            self.q.resize(crate::size(crate::size(rows, n), k), 128);
        }
        self.rows = 0;
        let q = SendPtr(self.q.as_mut_ptr());
        let s = SendPtr(self.scale.as_mut_ptr());
        let threads = pool.threads();
        let vector = k.is_multiple_of(16) && crate::cpu_supported();
        let bad = AtomicBool::new(false);
        pool.run(&|idx| {
            for t in split_range(rows, threads, idx) {
                let row = &x[t * k..(t + 1) * k];
                // Each thread writes disjoint frames; both buffers hold at least `rows`.
                let out = unsafe { std::slice::from_raw_parts_mut(q.get().add(t * n * k), n * k) };
                let scale = unsafe { &mut *s.get().add(t) };
                let ok = if vector {
                    unsafe { avx512::quantize_row(row, n, out, scale) }
                } else {
                    quantize_row_scalar(row, n, out, scale)
                };
                if !ok {
                    bad.store(true, Ordering::Relaxed);
                }
            }
        });
        if bad.load(Ordering::Relaxed) {
            return Err(NonFiniteActivation);
        }
        self.rows = rows;
        Ok(())
    }

    /// Reconstructed activation, for tests and references.
    pub fn dequantized(&self, t: usize, i: usize) -> f64 {
        let (k, n) = (self.cols, self.components);
        (0..n)
            .map(|c| (self.q[(t * n + c) * k + i] as f64 - 128.0) / WEIGHTS[c] as f64)
            .sum::<f64>()
            * self.scale[t] as f64
    }
}

/// Frames whose finest step would overflow f32 (maximum below about 2e-32)
/// are treated as zero; they contribute nothing measurable to the products.
fn too_small(m: f32, n: usize) -> bool {
    m == 0.0 || !((127.0 / m) * WEIGHTS[n - 1]).is_finite()
}

/// Returns false if `x` holds a NaN or infinity (the output is then unspecified).
pub fn quantize_row_scalar(x: &[f32], n: usize, out: &mut [u8], scale: &mut f32) -> bool {
    let k = x.len();
    if x.iter().any(|v| !v.is_finite()) {
        return false;
    }
    let m = x.iter().fold(0.0f32, |a, v| a.max(v.abs()));
    if too_small(m, n) {
        out[..n * k].fill(128);
        *scale = 0.0;
        return true;
    }
    let (inv, s) = (127.0 / m, m / 127.0);
    for (i, &v) in x.iter().enumerate() {
        let mut r = v;
        for (c, &wt) in WEIGHTS.iter().enumerate().take(n) {
            let q = (r * (inv * wt)).round_ties_even().clamp(-127.0, 127.0);
            r = (-q).mul_add(s / wt, r);
            out[c * k + i] = (q as i32 + 128) as u8;
        }
    }
    *scale = s;
    true
}

#[cfg(target_arch = "x86_64")]
mod avx512 {
    use super::{WEIGHTS, too_small};
    use std::arch::x86_64::*;

    #[target_feature(enable = "avx512f,avx512bw")]
    pub unsafe fn quantize_row(x: &[f32], n: usize, out: &mut [u8], scale: &mut f32) -> bool {
        let k = x.len();
        let p = x.as_ptr();
        let mut mx = _mm512_setzero_ps();
        let inf = _mm512_set1_ps(f32::INFINITY);
        let mut non_finite: __mmask16 = 0;
        for i in (0..k).step_by(16) {
            let a = _mm512_abs_ps(unsafe { _mm512_loadu_ps(p.add(i)) });
            // "Not less than infinity, or unordered": infinities and NaNs.
            non_finite |= _mm512_cmp_ps_mask::<_CMP_NLT_UQ>(a, inf);
            mx = _mm512_max_ps(mx, a);
        }
        if non_finite != 0 {
            return false;
        }
        let m = _mm512_reduce_max_ps(mx);
        if too_small(m, n) {
            out[..n * k].fill(128);
            *scale = 0.0;
            return true;
        }
        let (inv, s) = (127.0 / m, m / 127.0);
        let lo = _mm512_set1_epi32(-127);
        let hi = _mm512_set1_epi32(127);
        let offset = _mm512_set1_epi32(128);
        let o = out.as_mut_ptr();
        for i in (0..k).step_by(16) {
            let mut r = unsafe { _mm512_loadu_ps(p.add(i)) };
            for (c, &wt) in WEIGHTS.iter().enumerate().take(n) {
                let mult = _mm512_set1_ps(inv * wt);
                let step = _mm512_set1_ps(s / wt);
                let q = _mm512_cvt_roundps_epi32::<{ _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC }>(
                    _mm512_mul_ps(r, mult),
                );
                let q = _mm512_min_epi32(_mm512_max_epi32(q, lo), hi);
                r = _mm512_fnmadd_ps(_mm512_cvtepi32_ps(q), step, r);
                let bytes = _mm512_cvtepi32_epi8(_mm512_add_epi32(q, offset));
                unsafe { _mm_storeu_si128(o.add(c * k + i).cast(), bytes) };
            }
        }
        *scale = s;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_model::rng::SplitMix64;

    fn frame(k: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..k)
            .map(|i| rng.next_gaussian() * if i % 37 == 0 { 20.0 } else { 1.0 })
            .collect()
    }

    #[test]
    fn vector_matches_scalar_bit_for_bit() {
        if !crate::cpu_supported() {
            return;
        }
        for n in 1..=3 {
            let x = frame(1024, n as u64);
            let (mut a, mut b) = (vec![0u8; n * 1024], vec![0u8; n * 1024]);
            let (mut sa, mut sb) = (0.0, 0.0);
            quantize_row_scalar(&x, n, &mut a, &mut sa);
            unsafe { avx512::quantize_row(&x, n, &mut b, &mut sb) };
            assert_eq!(sa, sb);
            assert_eq!(a, b, "components {n}");
        }
    }

    #[test]
    fn error_shrinks_with_components() {
        let pool = ThreadPool::new(&[0]);
        let x = frame(256, 9);
        let m = x.iter().fold(0.0f32, |a, v| a.max(v.abs())) as f64;
        let mut prev = f64::INFINITY;
        for n in 1..=3 {
            let mut qa = QuantizedActs::with_capacity(1, 256, n);
            qa.quantize(&pool, &x, 1).unwrap();
            let err = (0..256)
                .map(|i| (qa.dequantized(0, i) - x[i] as f64).abs())
                .fold(0.0, f64::max);
            // Bound: half a step of the last component, plus f32 rounding slack.
            let bound = m / 127.0 / 2.0 / (RATIO as f64).powi(n as i32 - 1) + m * 1e-6;
            assert!(err <= bound, "n={n} err={err} bound={bound}");
            assert!(err < prev);
            prev = err;
        }
    }

    #[test]
    fn zero_frame() {
        let pool = ThreadPool::new(&[0]);
        let mut qa = QuantizedActs::with_capacity(1, 32, 2);
        qa.quantize(&pool, &[0.0; 32], 1).unwrap();
        assert_eq!(qa.scale()[0], 0.0);
        assert!(qa.q().iter().all(|&b| b == 128));
    }

    #[test]
    fn tiny_frames_are_zero_and_non_finite_frames_fail() {
        let pool = ThreadPool::new(&[0]);
        let mut qa = QuantizedActs::with_capacity(0, 32, 3);
        // Grows from zero capacity; a maximum of 1e-35 would overflow the third step.
        qa.quantize(&pool, &[1e-35; 32], 1).unwrap();
        assert_eq!(qa.scale()[0], 0.0);
        assert!(qa.q().iter().all(|&b| b == 128));
        for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            let mut x = [1.0f32; 32];
            x[17] = bad;
            assert_eq!(qa.quantize(&pool, &x, 1), Err(NonFiniteActivation));
            assert_eq!(qa.rows(), 0);
            let (mut out, mut s) = (vec![0u8; 96], 0.0);
            assert!(!quantize_row_scalar(&x, 3, &mut out, &mut s));
        }
    }
}
