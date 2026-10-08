//! Subsampling convolutions (NeMo `dw_striding`), channel-last `[time][freq][C]`.
//!
//! All convolutions are 3x3 with stride 2 and padding 1; positions outside the
//! valid input (time beyond the current length, or frequency beyond the band)
//! read as zero, which matches NeMo's per-stage time masking for one utterance.
//! `C` is fixed at 256 (16 vectors held in registers per output position).

use crate::{SendPtr, ThreadPool, split_range};

pub const CHANNELS: usize = 256;

/// Output length of a stride-2, padding-1, kernel-3 convolution.
pub fn out_len(n: usize) -> usize {
    if n == 0 { 0 } else { (n - 1) / 2 + 1 }
}

/// Output frames of the first convolution computed per chunk (with one frame of
/// overlap), so a thread's intermediate tile stays near L2 size.
const CHUNK_OUT: usize = 4;

/// Fused `conv0` (1 -> 256 channels, then ReLU) and `conv2` (depthwise).
///
/// `feat` is `[t0][f0]`; weights are tap-major `[9][256]` (tap = 3 * dt + df).
/// Writes `out` as `[out_len(out_len(t0))][out_len(out_len(f0))][256]`.
#[allow(clippy::too_many_arguments)]
pub fn conv0_dw(
    pool: &ThreadPool,
    feat: &[f32],
    t0: usize,
    f0: usize,
    w0: &[f32],
    b0: &[f32],
    w2: &[f32],
    b2: &[f32],
    out: &mut [f32],
) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    let (t1, f1) = (out_len(t0), out_len(f0));
    let (t2, f2) = (out_len(t1), out_len(f1));
    assert!(feat.len() >= crate::size(t0, f0));
    assert!(out.len() >= crate::size(crate::size(t2, f2), CHANNELS));
    // The per-thread tile spans 2 * CHUNK_OUT + 1 rows of f1 positions.
    crate::size(crate::size(2 * CHUNK_OUT + 1, f1), CHANNELS);
    assert!(w0.len() >= 9 * CHANNELS && w2.len() >= 9 * CHANNELS);
    assert!(b0.len() >= CHANNELS && b2.len() >= CHANNELS);
    let chunks = t2.div_ceil(CHUNK_OUT);
    let threads = pool.threads();
    let op = SendPtr(out.as_mut_ptr());
    pool.run(&|idx| {
        let mut tile = vec![0.0f32; (2 * CHUNK_OUT + 1) * f1 * CHANNELS];
        for chunk in split_range(chunks, threads, idx) {
            let a = chunk * CHUNK_OUT;
            let b = (a + CHUNK_OUT).min(t2);
            // conv0 rows feeding outputs a..b: 2a-1 ..= 2(b-1)+1, clamped.
            let r0 = (2 * a).saturating_sub(1);
            let r1 = (2 * (b - 1) + 2).min(t1);
            for r in r0..r1 {
                for f in 0..f1 {
                    unsafe {
                        x86::conv0_point(
                            feat.as_ptr(),
                            t0,
                            f0,
                            r,
                            f,
                            w0.as_ptr(),
                            b0.as_ptr(),
                            tile.as_mut_ptr().add(((r - r0) * f1 + f) * CHANNELS),
                        )
                    };
                }
            }
            for t in a..b {
                for f in 0..f2 {
                    unsafe {
                        x86::dw_point(
                            tile.as_ptr(),
                            r0,
                            r1,
                            f1,
                            t,
                            f,
                            w2.as_ptr(),
                            b2.as_ptr(),
                            op.get().add((t * f2 + f) * CHANNELS),
                        )
                    };
                }
            }
        }
    });
}

/// Depthwise 3x3 stride-2 convolution of `input` `[t][f][256]` into
/// `[out_len(t)][out_len(f)][256]`.
#[allow(clippy::too_many_arguments)]
pub fn depthwise_s2(
    pool: &ThreadPool,
    input: &[f32],
    t: usize,
    f: usize,
    w: &[f32],
    b: &[f32],
    out: &mut [f32],
) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    let (to, fo) = (out_len(t), out_len(f));
    assert!(input.len() >= crate::size(crate::size(t, f), CHANNELS));
    assert!(out.len() >= crate::size(crate::size(to, fo), CHANNELS));
    assert!(w.len() >= 9 * CHANNELS && b.len() >= CHANNELS);
    let threads = pool.threads();
    let op = SendPtr(out.as_mut_ptr());
    pool.run(&|idx| {
        for r in split_range(to, threads, idx) {
            for c in 0..fo {
                unsafe {
                    x86::dw_point(
                        input.as_ptr(),
                        0,
                        t,
                        f,
                        r,
                        c,
                        w.as_ptr(),
                        b.as_ptr(),
                        op.get().add((r * fo + c) * CHANNELS),
                    )
                };
            }
        }
    });
}

#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use super::CHANNELS;
    use std::arch::x86_64::*;

    const V: usize = CHANNELS / 16;

    /// One output position of conv0 (single input channel) followed by ReLU.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn conv0_point(
        feat: *const f32,
        t0: usize,
        f0: usize,
        r: usize,
        f: usize,
        w: *const f32,
        b: *const f32,
        out: *mut f32,
    ) {
        unsafe {
            let mut acc: [__m512; V] = std::array::from_fn(|v| _mm512_loadu_ps(b.add(v * 16)));
            for dt in 0..3 {
                let ti = (2 * r + dt).wrapping_sub(1);
                if ti >= t0 {
                    continue;
                }
                for df in 0..3 {
                    let fi = (2 * f + df).wrapping_sub(1);
                    if fi >= f0 {
                        continue;
                    }
                    let x = _mm512_set1_ps(*feat.add(ti * f0 + fi));
                    let wt = w.add((dt * 3 + df) * CHANNELS);
                    for v in 0..V {
                        acc[v] = _mm512_fmadd_ps(_mm512_loadu_ps(wt.add(v * 16)), x, acc[v]);
                    }
                }
            }
            let z = _mm512_setzero_ps();
            for v in 0..V {
                _mm512_storeu_ps(out.add(v * 16), _mm512_max_ps(acc[v], z));
            }
        }
    }

    /// One output position of a depthwise 3x3 stride-2 convolution. `input`
    /// holds rows `row0..row1` of a `[rows][fi][256]` tensor; other rows are zero.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn dw_point(
        input: *const f32,
        row0: usize,
        row1: usize,
        fi_len: usize,
        t: usize,
        f: usize,
        w: *const f32,
        b: *const f32,
        out: *mut f32,
    ) {
        unsafe {
            let mut acc: [__m512; V] = std::array::from_fn(|v| _mm512_loadu_ps(b.add(v * 16)));
            for dt in 0..3 {
                let ti = (2 * t + dt).wrapping_sub(1);
                if ti < row0 || ti >= row1 {
                    continue;
                }
                for df in 0..3 {
                    let fi = (2 * f + df).wrapping_sub(1);
                    if fi >= fi_len {
                        continue;
                    }
                    let src = input.add(((ti - row0) * fi_len + fi) * CHANNELS);
                    let wt = w.add((dt * 3 + df) * CHANNELS);
                    for v in 0..V {
                        acc[v] = _mm512_fmadd_ps(
                            _mm512_loadu_ps(wt.add(v * 16)),
                            _mm512_loadu_ps(src.add(v * 16)),
                            acc[v],
                        );
                    }
                }
            }
            for v in 0..V {
                _mm512_storeu_ps(out.add(v * 16), acc[v]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_model::rng::SplitMix64;

    fn rand(n: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..n).map(|_| rng.next_gaussian()).collect()
    }

    /// Scalar 3x3 stride-2 padding-1 convolution over `[t][f][cin]` with
    /// per-output-channel weights `w(cout, cin, tap)`.
    fn conv_ref(
        x: &[f32],
        t: usize,
        f: usize,
        cin: usize,
        cout: usize,
        w: &dyn Fn(usize, usize, usize) -> f32,
        b: &[f32],
    ) -> Vec<f64> {
        let (to, fo) = (out_len(t), out_len(f));
        let mut y = vec![0.0; to * fo * cout];
        for r in 0..to {
            for c in 0..fo {
                for o in 0..cout {
                    let mut s = b[o] as f64;
                    for dt in 0..3 {
                        for df in 0..3 {
                            let (ti, fi) = ((2 * r + dt) as isize - 1, (2 * c + df) as isize - 1);
                            if ti < 0 || fi < 0 || ti >= t as isize || fi >= f as isize {
                                continue;
                            }
                            for i in 0..cin {
                                let xi = x[((ti as usize) * f + fi as usize) * cin + i] as f64;
                                s += w(o, i, dt * 3 + df) as f64 * xi;
                            }
                        }
                    }
                    y[(r * fo + c) * cout + o] = s;
                }
            }
        }
        y
    }

    #[test]
    fn fused_conv0_dw_matches_reference() {
        if !crate::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1, 2]);
        // Odd time and frequency sizes exercise the padding and chunk edges.
        let (t0, f0) = (23, 13);
        let feat = rand(t0 * f0, 1);
        let (w0, b0, w2, b2) = (
            rand(9 * 256, 2),
            rand(256, 3),
            rand(9 * 256, 4),
            rand(256, 5),
        );
        let c0 = conv_ref(&feat, t0, f0, 1, 256, &|o, _, tap| w0[tap * 256 + o], &b0);
        let c0: Vec<f32> = c0.iter().map(|&v| v.max(0.0) as f32).collect();
        let (t1, f1) = (out_len(t0), out_len(f0));
        let expected = conv_ref(
            &c0,
            t1,
            f1,
            256,
            256,
            &|o, i, tap| if o == i { w2[tap * 256 + o] } else { 0.0 },
            &b2,
        );
        let mut out = vec![0.0; out_len(t1) * out_len(f1) * 256];
        conv0_dw(&pool, &feat, t0, f0, &w0, &b0, &w2, &b2, &mut out);
        for (i, (&a, &e)) in out.iter().zip(&expected).enumerate() {
            assert!((a as f64 - e).abs() < 1e-3, "at {i}: {a} vs {e}");
        }
        // Standalone depthwise matches too.
        let mut out2 = vec![0.0; out_len(t1) * out_len(f1) * 256];
        depthwise_s2(&pool, &c0, t1, f1, &w2, &b2, &mut out2);
        for (&a, &e) in out2.iter().zip(&expected) {
            assert!((a as f64 - e).abs() < 1e-3);
        }
    }
}
