//! Ternary GEMM on FP32 activations with AVX-512 FMA (variant A).
//!
//! Each thread takes whole 64-row output blocks. Per block and per `KC`
//! inputs it expands the 2-bit codes into an f32 tile of {-1, 0, +1}
//! (`KC * 64` floats, 128 KiB) and runs every frame against it. Partial sums
//! accumulate in `Y`; the row scale is applied with the last input block.

use crate::pack::{NR, PackedTernary};
use crate::{Scratch, SendPtr, ThreadPool, split_range};

pub const KC: usize = 512;
const MR: usize = 6;

pub fn scratch_bytes() -> usize {
    KC * NR * 4
}

pub fn gemm(
    pool: &ThreadPool,
    scratch: &Scratch,
    w: &PackedTernary,
    x: &[f32],
    t: usize,
    y: &mut [f32],
) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    let (k, o) = (w.cols(), w.rows());
    assert!(x.len() >= crate::size(t, k) && y.len() >= crate::size(t, o));
    let threads = pool.threads();
    let lease = scratch.lease(threads, scratch_bytes());
    let yp = SendPtr(y.as_mut_ptr());
    pool.run(&|idx| {
        let tile = unsafe { lease.get(idx) }.as_mut_ptr().cast::<f32>();
        for b in split_range(w.blocks(), threads, idx) {
            let mut kb = 0;
            while kb < k {
                let kc = KC.min(k - kb);
                unsafe { x86::expand_block(w.block(b), kb / 4, kc / 4, tile) };
                let last = kb + kc == k;
                let mut t0 = 0;
                while t0 < t {
                    let rows = MR.min(t - t0);
                    unsafe {
                        x86::kernel_for(rows)(
                            tile,
                            x.as_ptr().add(t0 * k + kb),
                            k,
                            kc,
                            yp.get().add(t0 * o + b * NR),
                            o,
                            kb > 0,
                            if last {
                                w.scale().as_ptr().add(b * NR)
                            } else {
                                std::ptr::null()
                            },
                        )
                    };
                    t0 += rows;
                }
                kb += kc;
            }
        }
    });
}

// Explicit index loops over const-sized accumulator arrays unroll into registers.
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use std::arch::x86_64::*;

    type Kernel =
        unsafe fn(*const f32, *const f32, usize, usize, *mut f32, usize, bool, *const f32);

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

    /// Expands quads `q0..q0 + nq` of one block into `[4 * nq][64]` floats.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn expand_block(src: &[u8], q0: usize, nq: usize, dst: *mut f32) {
        let mut table = [0.0f32; 16];
        table[1] = 1.0;
        table[2] = -1.0;
        let table = unsafe { _mm512_loadu_ps(table.as_ptr()) };
        let three = _mm512_set1_epi32(3);
        for ql in 0..nq {
            let c = unsafe { _mm512_loadu_si512(src.as_ptr().add((q0 + ql) * 64).cast()) };
            let lanes = [
                _mm512_extracti32x4_epi32::<0>(c),
                _mm512_extracti32x4_epi32::<1>(c),
                _mm512_extracti32x4_epi32::<2>(c),
                _mm512_extracti32x4_epi32::<3>(c),
            ];
            for (v, &bytes) in lanes.iter().enumerate() {
                let d = _mm512_cvtepu8_epi32(bytes);
                for k4 in 0..4 {
                    let f = _mm512_and_si512(
                        _mm512_srlv_epi32(d, _mm512_set1_epi32(2 * k4 as i32)),
                        three,
                    );
                    let vals = _mm512_permutexvar_ps(f, table);
                    unsafe { _mm512_store_ps(dst.add((4 * ql + k4) * 64 + v * 16), vals) };
                }
            }
        }
    }

    #[target_feature(enable = "avx512f")]
    unsafe fn kernel<const R: usize>(
        tile: *const f32,
        x: *const f32,
        ldx: usize,
        kc: usize,
        y: *mut f32,
        ldy: usize,
        accumulate: bool,
        scale: *const f32,
    ) {
        let mut acc = [[_mm512_setzero_ps(); 4]; R];
        for k in 0..kc {
            let wp = unsafe { tile.add(k * 64) };
            let w: [__m512; 4] = std::array::from_fn(|v| unsafe { _mm512_load_ps(wp.add(v * 16)) });
            for r in 0..R {
                let b = _mm512_set1_ps(unsafe { *x.add(r * ldx + k) });
                for v in 0..4 {
                    acc[r][v] = _mm512_fmadd_ps(w[v], b, acc[r][v]);
                }
            }
        }
        for r in 0..R {
            for v in 0..4 {
                let p = unsafe { y.add(r * ldy + v * 16) };
                let mut out = acc[r][v];
                if accumulate {
                    out = _mm512_add_ps(out, unsafe { _mm512_loadu_ps(p) });
                }
                if !scale.is_null() {
                    out = _mm512_mul_ps(out, unsafe { _mm512_loadu_ps(scale.add(v * 16)) });
                }
                unsafe { _mm512_storeu_ps(p, out) };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gemm_ref::{compare, reference};
    use lf_model::TernaryMatrix;
    use lf_model::rng::SplitMix64;

    #[test]
    fn matches_reference() {
        if !crate::cpu_supported() {
            return;
        }
        let mut rng = SplitMix64::new(5);
        // 1100 inputs: two full KC blocks plus a partial one.
        for (rows, cols) in [(128, 96), (64, 1100)] {
            let m = TernaryMatrix::random(rows, cols, 6);
            let w = PackedTernary::new(&m).unwrap();
            for threads in [1, 2] {
                let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
                let scratch = Scratch::new(threads, scratch_bytes());
                for t in [1, 6, 11] {
                    let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
                    let mut y = vec![0.0; t * rows];
                    gemm(&pool, &scratch, &w, &x, t, &mut y);
                    let (rel, worst) = compare(&y, &reference(&m, &x, t));
                    assert!(
                        rel < 1e-6 && worst < 1e-5,
                        "{rows}x{cols} t={t} rel={rel} worst={worst}"
                    );
                }
            }
        }
    }
}
