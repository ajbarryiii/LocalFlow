//! Ternary GEMM on residual-INT8 activations with AVX-512 VNNI (variant C).
//!
//! Each thread takes whole 64-row output blocks. Per block it expands the
//! 2-bit codes once into an s8 tile laid out for `VPDPBUSD`: for input quad
//! `q`, four vectors where lane `j` of vector `v` holds the four codes of
//! output `v * 16 + j`. The tile (`64 * K` bytes, at most 256 KiB) stays in L2
//! while every frame streams past it. Activations are u8 (`q + 128`), so the
//! epilogue subtracts `128 * row_sum` before scaling.

use crate::pack::{NR, PackedTernary};
use crate::quant::{QuantizedActs, RATIO};
use crate::{Scratch, SendPtr, ThreadPool, split_range};

/// Scratch bytes per thread for a matrix with `cols` inputs.
pub fn scratch_bytes(cols: usize) -> usize {
    cols * NR
}

pub fn gemm(
    pool: &ThreadPool,
    scratch: &Scratch,
    w: &PackedTernary,
    qa: &QuantizedActs,
    y: &mut [f32],
) {
    assert!(crate::cpu_supported(), "AVX-512 VNNI/VBMI required");
    assert_eq!(qa.cols(), w.cols());
    let (t, k, n, o) = (qa.rows(), w.cols(), qa.components(), w.rows());
    assert!(y.len() >= crate::size(t, o));
    let mt = 6 / n;
    let threads = pool.threads();
    let lease = scratch.lease(threads, scratch_bytes(k));
    let yp = SendPtr(y.as_mut_ptr());
    pool.run(&|idx| {
        let tile = unsafe { lease.get(idx) }.as_mut_ptr();
        for b in split_range(w.blocks(), threads, idx) {
            unsafe { x86::expand_block(w.block(b), tile) };
            let mut t0 = 0;
            while t0 < t {
                let rows = mt.min(t - t0);
                let kernel = x86::kernel_for(n, rows);
                unsafe {
                    kernel(
                        tile,
                        qa.q().as_ptr().add(t0 * n * k),
                        k,
                        yp.get().add(t0 * o + b * NR),
                        o,
                        w.scale().as_ptr().add(b * NR),
                        w.row_sum().as_ptr().add(b * NR),
                        qa.scale().as_ptr().add(t0),
                    )
                };
                t0 += rows;
            }
        }
    });
}

const INV: [f32; 3] = [1.0, 1.0 / RATIO, 1.0 / (RATIO * RATIO)];

// Explicit index loops over const-sized accumulator arrays unroll into registers.
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use super::INV;
    use std::arch::x86_64::*;

    type Kernel =
        unsafe fn(*const u8, *const u8, usize, *mut f32, usize, *const f32, *const i32, *const f32);

    /// Kernel for `n` components and `frames` frames (`n * frames <= 6` rows).
    pub fn kernel_for(n: usize, frames: usize) -> Kernel {
        match (n, frames) {
            (1, 1) => kernel::<1, 1>,
            (1, 2) => kernel::<1, 2>,
            (1, 3) => kernel::<1, 3>,
            (1, 4) => kernel::<1, 4>,
            (1, 5) => kernel::<1, 5>,
            (1, 6) => kernel::<1, 6>,
            (2, 1) => kernel::<2, 2>,
            (2, 2) => kernel::<2, 4>,
            (2, 3) => kernel::<2, 6>,
            (3, 1) => kernel::<3, 3>,
            (3, 2) => kernel::<3, 6>,
            _ => unreachable!("no kernel for {n} components x {frames} frames"),
        }
    }

    /// Expands one block of packed codes (`quads * 64` bytes) into the s8 tile.
    #[target_feature(enable = "avx512f,avx512bw,avx512vbmi")]
    pub unsafe fn expand_block(src: &[u8], dst: *mut u8) {
        // Byte p of vector v takes code byte (v * 16 + p / 4), then field p % 4 of it.
        let mut idx = [[0u8; 64]; 4];
        let mut ctrl = [0u8; 64];
        let mut lut = [0u8; 64];
        for p in 0..64 {
            for (v, row) in idx.iter_mut().enumerate() {
                row[p] = (v * 16 + p / 4) as u8;
            }
            ctrl[p] = (8 * (p % 8) + 2 * (p % 4)) as u8;
        }
        for lane in 0..4 {
            lut[lane * 16 + 1] = 1;
            lut[lane * 16 + 2] = 0xff; // -1
        }
        let idx: [__m512i; 4] =
            std::array::from_fn(|v| unsafe { _mm512_loadu_si512(idx[v].as_ptr().cast()) });
        let ctrl = unsafe { _mm512_loadu_si512(ctrl.as_ptr().cast()) };
        let lut = unsafe { _mm512_loadu_si512(lut.as_ptr().cast()) };
        let three = _mm512_set1_epi8(3);
        for (q, chunk) in src.as_chunks::<64>().0.iter().enumerate() {
            let c = unsafe { _mm512_loadu_si512(chunk.as_ptr().cast()) };
            for (v, &iv) in idx.iter().enumerate() {
                let x = _mm512_permutexvar_epi8(iv, c);
                let x = _mm512_and_si512(_mm512_multishift_epi64_epi8(ctrl, x), three);
                let x = _mm512_shuffle_epi8(lut, x);
                unsafe { _mm512_store_si512(dst.add(q * 256 + v * 64).cast(), x) };
            }
        }
    }

    /// `acc + dot4(a as u8, b as s8)` per 32-bit lane. Inline asm because the
    /// nixpkgs rustc is linked against an LLVM whose `vpdpbusd` intrinsic
    /// signature no longer matches `_mm512_dpbusd_epi32`.
    #[inline]
    #[target_feature(enable = "avx512f,avx512vnni")]
    fn dpbusd(acc: __m512i, a: __m512i, b: __m512i) -> __m512i {
        let mut out = acc;
        unsafe {
            std::arch::asm!(
                "vpdpbusd {acc}, {a}, {b}",
                acc = inout(zmm_reg) out,
                a = in(zmm_reg) a,
                b = in(zmm_reg) b,
                options(pure, nomem, nostack, preserves_flags),
            );
        }
        out
    }

    /// `R = N * frames` accumulator rows of four 16-lane vectors.
    #[target_feature(enable = "avx512f,avx512bw,avx512vnni")]
    unsafe fn kernel<const N: usize, const R: usize>(
        tile: *const u8,
        q: *const u8,
        k: usize,
        y: *mut f32,
        ldy: usize,
        scale: *const f32,
        row_sum: *const i32,
        frame_scale: *const f32,
    ) {
        let mut acc = [[_mm512_setzero_si512(); 4]; R];
        for kq in 0..k / 4 {
            let wp = unsafe { tile.add(kq * 256) };
            let w: [__m512i; 4] =
                std::array::from_fn(|v| unsafe { _mm512_load_si512(wp.add(v * 64).cast()) });
            for r in 0..R {
                let a = _mm512_set1_epi32(unsafe {
                    q.add(r * k + 4 * kq).cast::<i32>().read_unaligned()
                });
                for v in 0..4 {
                    acc[r][v] = dpbusd(acc[r][v], a, w[v]);
                }
            }
        }
        for v in 0..4 {
            let offset =
                _mm512_slli_epi32::<7>(unsafe { _mm512_loadu_si512(row_sum.add(v * 16).cast()) });
            let sc = unsafe { _mm512_loadu_ps(scale.add(v * 16)) };
            for m in 0..R / N {
                let mut sum = _mm512_setzero_ps();
                for c in (0..N).rev() {
                    let d = _mm512_cvtepi32_ps(_mm512_sub_epi32(acc[m * N + c][v], offset));
                    sum = _mm512_fmadd_ps(d, _mm512_set1_ps(INV[c]), sum);
                }
                let fs = _mm512_set1_ps(unsafe { *frame_scale.add(m) });
                let out = _mm512_mul_ps(_mm512_mul_ps(sum, sc), fs);
                unsafe { _mm512_storeu_ps(y.add(m * ldy + v * 16), out) };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gemm_ref::{compare, reference_quantized};
    use lf_model::TernaryMatrix;
    use lf_model::rng::SplitMix64;

    #[test]
    fn matches_reference_on_quantized_inputs() {
        if !crate::cpu_supported() {
            return;
        }
        let m = TernaryMatrix::random(192, 96, 3);
        let w = PackedTernary::new(&m).unwrap();
        let mut rng = SplitMix64::new(4);
        for threads in [1, 3] {
            let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
            let scratch = Scratch::new(threads, scratch_bytes(96));
            for n in 1..=3 {
                for t in [1, 2, 5, 7, 13] {
                    let x: Vec<f32> = (0..t * 96).map(|_| rng.next_gaussian()).collect();
                    let mut qa = QuantizedActs::with_capacity(t, 96, n);
                    qa.quantize(&pool, &x, t).unwrap();
                    let mut y = vec![0.0; t * 192];
                    gemm(&pool, &scratch, &w, &qa, &mut y);
                    let (rel, worst) = compare(&y, &reference_quantized(&m, &qa));
                    assert!(
                        rel < 1e-6 && worst < 1e-5,
                        "n={n} t={t} rel={rel} worst={worst}"
                    );
                }
            }
        }
    }
}
