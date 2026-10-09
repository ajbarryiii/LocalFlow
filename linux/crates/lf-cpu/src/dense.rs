//! Dense FP32 GEMM: `C = A * B (+ bias)` with `B` packed into 64-column panels.
//!
//! `A` is row-major with stride `lda`. `B` is packed once into `[panel][k][64]`
//! (zero padded), so the micro-kernel streams one 64-wide row of `B` per `k`
//! and broadcasts up to six values of `A`, keeping 24 accumulators in
//! registers. Used for the floating-point parts of the model: subsampling
//! convolutions, the subsampling output projection and attention.

use std::ops::Range;

use crate::{SendPtr, ThreadPool, split_range};

/// Columns per panel.
pub const NB: usize = 64;
/// Inputs per cache block.
const KC: usize = 512;
/// Rows per micro-kernel call.
const MR: usize = 6;
/// Rows per parallel work unit (16 micro-kernel calls).
const UNIT_ROWS: usize = 96;

/// `B` packed as `[ceil(n / 64)][k][64]`.
#[derive(Default)]
pub struct Panels {
    n: usize,
    k: usize,
    data: Vec<f32>,
}

impl Panels {
    pub fn n(&self) -> usize {
        self.n
    }

    pub fn k(&self) -> usize {
        self.k
    }

    pub fn panels(&self) -> usize {
        self.n.div_ceil(NB)
    }

    fn reset(&mut self, k: usize, n: usize) {
        self.k = k;
        self.n = n;
        self.data.clear();
        self.data
            .resize(crate::size(crate::size(n.div_ceil(NB), k), NB), 0.0);
    }

    /// Packs `B[k][n] = src[n * ld + k]`: rows of `src` become columns of `B`
    /// (for `A * src^T`, e.g. a weight matrix `[out][in]` or attention keys).
    pub fn pack_rows(&mut self, src: &[f32], n: usize, k: usize, ld: usize) {
        assert!(src.len() >= crate::span(n, ld, k));
        self.reset(k, n);
        for j in 0..n {
            let (p, lane) = (j / NB, j % NB);
            let row = &src[j * ld..j * ld + k];
            let base = p * k * NB + lane;
            for (i, &v) in row.iter().enumerate() {
                self.data[base + i * NB] = v;
            }
        }
    }

    /// Packs `B[k][n] = src[k * ld + n]` (for `A * src`, e.g. attention values).
    pub fn pack_cols(&mut self, src: &[f32], k: usize, n: usize, ld: usize) {
        assert!(src.len() >= crate::span(k, ld, n));
        self.reset(k, n);
        for p in 0..n.div_ceil(NB) {
            let width = NB.min(n - p * NB);
            for i in 0..k {
                let dst = &mut self.data[(p * k + i) * NB..][..width];
                dst.copy_from_slice(&src[i * ld + p * NB..][..width]);
            }
        }
    }

    fn panel(&self, p: usize) -> *const f32 {
        self.data[p * self.k * NB..].as_ptr()
    }
}

/// `C[m][n] = A[m][k] * B (+ bias[n])`, parallel over panels and row blocks.
#[allow(clippy::too_many_arguments)]
pub fn gemm(
    pool: &ThreadPool,
    a: &[f32],
    m: usize,
    lda: usize,
    b: &Panels,
    c: &mut [f32],
    ldc: usize,
    bias: Option<&[f32]>,
) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    check_shapes(a, m, lda, b, c, ldc, bias);
    let np = b.panels();
    let units = crate::size(np, m.div_ceil(UNIT_ROWS));
    let threads = pool.threads();
    let cp = SendPtr(c.as_mut_ptr());
    pool.run(&|idx| {
        for u in split_range(units, threads, idx) {
            // Panel-major: consecutive units reuse the same panel.
            let (p, chunk) = (u / m.div_ceil(UNIT_ROWS), u % m.div_ceil(UNIT_ROWS));
            let rows = chunk * UNIT_ROWS..(chunk * UNIT_ROWS + UNIT_ROWS).min(m);
            unsafe { block(a, lda, b, p, rows, cp.get().add(p * NB), ldc, bias) };
        }
    });
}

/// Single-threaded `C[m][cols of panels] = A * B[.., panels]`, with column 0 of
/// `c` being the first column of `panels.start`. No bias.
pub fn gemm_serial(
    a: &[f32],
    m: usize,
    lda: usize,
    b: &Panels,
    panels: Range<usize>,
    c: &mut [f32],
    ldc: usize,
) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    assert!(panels.end <= b.panels());
    if m == 0 || panels.is_empty() {
        return;
    }
    assert!(a.len() >= crate::span(m, lda, b.k));
    let last_width = NB.min(b.n - (panels.end - 1) * NB);
    let width = crate::size(panels.len() - 1, NB)
        .checked_add(last_width)
        .expect("size overflow");
    assert!(c.len() >= crate::span(m, ldc, width));
    let c0 = c.as_mut_ptr();
    for p in panels.clone() {
        let cp = unsafe { c0.add((p - panels.start) * NB) };
        unsafe { block(a, lda, b, p, 0..m, cp, ldc, None) };
    }
}

fn check_shapes(
    a: &[f32],
    m: usize,
    lda: usize,
    b: &Panels,
    c: &[f32],
    ldc: usize,
    bias: Option<&[f32]>,
) {
    if m == 0 {
        return;
    }
    assert!(
        lda >= b.k && a.len() >= crate::span(m, lda, b.k),
        "A too small"
    );
    // ldc >= n keeps rows written by different threads disjoint.
    assert!(
        ldc >= b.n && c.len() >= crate::span(m, ldc, b.n),
        "C too small"
    );
    if let Some(bias) = bias {
        assert!(bias.len() >= b.n, "bias too small");
    }
}

/// Rows `rows` of `C` for panel `p`; row `r` of the panel's columns starts at `c + r * ldc`.
#[allow(clippy::too_many_arguments)]
unsafe fn block(
    a: &[f32],
    lda: usize,
    b: &Panels,
    p: usize,
    rows: Range<usize>,
    c: *mut f32,
    ldc: usize,
    bias: Option<&[f32]>,
) {
    let k = b.k;
    let width = NB.min(b.n - p * NB);
    let panel = b.panel(p);
    let bias_p = bias.map(|bv| bv[p * NB..].as_ptr());
    let mut kb = 0;
    while kb < k.max(1) {
        let kc = KC.min(k - kb);
        let mut r = rows.start;
        while r < rows.end {
            let mr = MR.min(rows.end - r);
            unsafe {
                x86::kernel_for(mr)(
                    panel.add(kb * NB),
                    kc,
                    a.as_ptr().add(r * lda + kb),
                    lda,
                    c.add(r * ldc),
                    ldc,
                    width,
                    kb > 0,
                    if kb == 0 { bias_p } else { None },
                )
            };
            r += mr;
        }
        kb += KC;
    }
}

#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use std::arch::x86_64::*;

    type Kernel = unsafe fn(
        *const f32,
        usize,
        *const f32,
        usize,
        *mut f32,
        usize,
        usize,
        bool,
        Option<*const f32>,
    );

    pub fn kernel_for(rows: usize) -> Kernel {
        match rows {
            1 => kernel::<1>,
            2 => kernel::<2>,
            3 => kernel::<3>,
            4 => kernel::<4>,
            5 => kernel::<5>,
            6 => kernel::<6>,
            _ => unreachable!(),
        }
    }

    /// `R` rows of `A` times `kc` rows of one panel; adds to `C` when
    /// `accumulate`, adds `bias` if given, and stores the first `width` columns.
    #[target_feature(enable = "avx512f")]
    unsafe fn kernel<const R: usize>(
        panel: *const f32,
        kc: usize,
        a: *const f32,
        lda: usize,
        c: *mut f32,
        ldc: usize,
        width: usize,
        accumulate: bool,
        bias: Option<*const f32>,
    ) {
        let mut acc = [[_mm512_setzero_ps(); 4]; R];
        for i in 0..kc {
            let wp = unsafe { panel.add(i * 64) };
            let w: [__m512; 4] =
                std::array::from_fn(|v| unsafe { _mm512_loadu_ps(wp.add(v * 16)) });
            for r in 0..R {
                let x = _mm512_set1_ps(unsafe { *a.add(r * lda + i) });
                for v in 0..4 {
                    acc[r][v] = _mm512_fmadd_ps(w[v], x, acc[r][v]);
                }
            }
        }
        for v in 0..4 {
            let lanes = width.saturating_sub(v * 16).min(16);
            if lanes == 0 {
                break;
            }
            let mask: __mmask16 = if lanes == 16 { !0 } else { (1u16 << lanes) - 1 };
            let b = match bias {
                Some(bp) => unsafe { _mm512_maskz_loadu_ps(mask, bp.add(v * 16)) },
                None => _mm512_setzero_ps(),
            };
            for r in 0..R {
                let p = unsafe { c.add(r * ldc + v * 16) };
                let mut out = _mm512_add_ps(acc[r][v], b);
                if accumulate {
                    out = _mm512_add_ps(out, unsafe { _mm512_maskz_loadu_ps(mask, p) });
                }
                unsafe { _mm512_mask_storeu_ps(p, mask, out) };
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

    fn reference(
        a: &[f32],
        m: usize,
        lda: usize,
        b: &dyn Fn(usize, usize) -> f32,
        k: usize,
        n: usize,
    ) -> Vec<f64> {
        let mut c = vec![0.0; m * n];
        for i in 0..m {
            for j in 0..n {
                c[i * n + j] = (0..k).map(|t| a[i * lda + t] as f64 * b(t, j) as f64).sum();
            }
        }
        c
    }

    #[test]
    fn packed_rows_and_cols_match_reference() {
        if !crate::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1, 2]);
        // Odd sizes: partial panels, K spanning blocks, M spanning units.
        for (m, k, n) in [(1, 3, 5), (13, 600, 70), (200, 1030, 129)] {
            let lda = k + 3;
            let a = rand(m * lda, 1);
            let src = rand(n * k, 2);
            let bias = rand(n, 3);
            let mut rows = Panels::default();
            rows.pack_rows(&src, n, k, k);
            let mut c = vec![0.0; m * n];
            gemm(&pool, &a, m, lda, &rows, &mut c, n, Some(&bias));
            let r = reference(&a, m, lda, &|t, j| src[j * k + t], k, n);
            for i in 0..m * n {
                assert!(
                    (c[i] as f64 - r[i] - bias[i % n] as f64).abs() < 1e-3,
                    "rows {m}x{k}x{n} at {i}"
                );
            }
            let mut cols = Panels::default();
            cols.pack_cols(&src, k, n, n);
            let mut c = vec![0.0; m * n];
            gemm(&pool, &a, m, lda, &cols, &mut c, n, None);
            let r = reference(&a, m, lda, &|t, j| src[t * n + j], k, n);
            for i in 0..m * n {
                assert!((c[i] as f64 - r[i]).abs() < 1e-3, "cols {m}x{k}x{n} at {i}");
            }
            // Serial over a sub-range of panels, written from column 0 of `c`.
            if rows.panels() > 1 {
                let mut c = vec![0.0; m * 200];
                gemm_serial(&a, m, lda, &rows, 1..rows.panels(), &mut c, 200);
                let r = reference(&a, m, lda, &|t, j| src[j * k + t], k, n);
                for i in 0..m {
                    for j in 64..n {
                        assert!((c[i * 200 + j - 64] as f64 - r[i * n + j]).abs() < 1e-3);
                    }
                }
            }
        }
    }
}
