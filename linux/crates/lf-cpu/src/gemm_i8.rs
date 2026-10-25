//! Ternary GEMM on residual-INT8 activations with AVX-512 VNNI (variant C).
//!
//! Each thread takes whole 64-row output blocks. Per block it expands the
//! 2-bit codes once into an s8 tile laid out for `VPDPBUSD`: for input quad
//! `q`, four vectors where lane `j` of vector `v` holds the four codes of
//! output `v * 16 + j`. The tile (`64 * K` bytes, at most 256 KiB) stays in L2
//! while every frame streams past it. Activations are u8 (`q + 128`), so the
//! epilogue subtracts `128 * row_sum` before scaling.
//!
//! Binary weights (1 bit, `pack.rs`) skip the tile: their masks already have
//! the tile's byte order, so the kernel expands each one into a register with
//! a single masked blend as it goes. On the 9950X3D that beats expanding a
//! tile at every frame count, and runs at about the VNNI peak with 8 threads.
//! The products are the same integers as for the weights widened to 2-bit
//! codes, so the outputs are bit for bit identical.

use crate::pack::{Encoding, NR, PackedTernary};
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
    let masks = w.encoding() == Encoding::Binary;
    let threads = pool.threads();
    let lease = scratch.lease(threads, if masks { 0 } else { scratch_bytes(k) });
    let yp = SendPtr(y.as_mut_ptr());
    pool.run(&|idx| {
        // SAFETY: `pool.run` calls this closure once per index, so this thread
        // is the only user of buffer `idx` under this lease.
        let tile = unsafe { lease.get(idx) }.as_mut_ptr();
        for b in split_range(w.blocks(), threads, idx) {
            let src = if masks {
                w.block(b).as_ptr()
            } else {
                // SAFETY: AVX-512 F/BW/VBMI were asserted on entry. `w.block(b)`
                // has `k / 4 * 64` bytes of 2-bit codes, and the expansion writes
                // `k * 64` bytes, which is `scratch_bytes(k)`, the size `lease`
                // checked for this thread's 64-byte aligned tile.
                unsafe { x86::expand_block(w.block(b), tile) };
                tile.cast_const()
            };
            let mut t0 = 0;
            while t0 < t {
                let rows = mt.min(t - t0);
                let kernel = x86::kernel_for(n, rows, masks);
                // SAFETY: AVX-512 F/BW/VNNI were asserted on entry. `src` is the
                // tile holding block `b` or, for binary weights, the block's
                // `k * 8` bytes of masks (`PackedTernary::block`), with `k % 4 == 0`
                // (`qa.cols() == w.cols()`). `QuantizedActs` keeps `q()` at
                // `t * n * k` bytes and `scale()` at `t` values, so frames
                // `t0..t0 + rows` (`n * rows` component rows) are readable. `y`
                // rows `t0..t0 + rows` lie within the `t * o` checked on entry, and
                // columns `b * 64..b * 64 + 64` within `o`, `w.scale()` and
                // `w.row_sum()` (`PackedTernary`). Threads own whole blocks `b`, so
                // their `y` columns are disjoint.
                unsafe {
                    kernel(
                        src,
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

    /// Kernel for `n` components and `frames` frames (`n * frames <= 6` rows),
    /// reading an expanded s8 tile, or with `masks` a block of binary masks.
    pub fn kernel_for(n: usize, frames: usize, masks: bool) -> Kernel {
        match (n, frames, masks) {
            (1, 1, false) => kernel::<1, 1, false>,
            (1, 2, false) => kernel::<1, 2, false>,
            (1, 3, false) => kernel::<1, 3, false>,
            (1, 4, false) => kernel::<1, 4, false>,
            (1, 5, false) => kernel::<1, 5, false>,
            (1, 6, false) => kernel::<1, 6, false>,
            (2, 1, false) => kernel::<2, 2, false>,
            (2, 2, false) => kernel::<2, 4, false>,
            (2, 3, false) => kernel::<2, 6, false>,
            (3, 1, false) => kernel::<3, 3, false>,
            (3, 2, false) => kernel::<3, 6, false>,
            (1, 1, true) => kernel::<1, 1, true>,
            (1, 2, true) => kernel::<1, 2, true>,
            (1, 3, true) => kernel::<1, 3, true>,
            (1, 4, true) => kernel::<1, 4, true>,
            (1, 5, true) => kernel::<1, 5, true>,
            (1, 6, true) => kernel::<1, 6, true>,
            (2, 1, true) => kernel::<2, 2, true>,
            (2, 2, true) => kernel::<2, 4, true>,
            (2, 3, true) => kernel::<2, 6, true>,
            (3, 1, true) => kernel::<3, 3, true>,
            (3, 2, true) => kernel::<3, 6, true>,
            _ => unreachable!("no kernel for {n} components x {frames} frames"),
        }
    }

    /// Expands one block of packed codes (`quads * 64` bytes) into the s8 tile.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F, BW and VBMI, and `dst` must be 64-byte
    /// aligned and valid for writes of `src.len() / 64 * 256` bytes that no
    /// other thread accesses.
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
        // SAFETY: each `idx[v]` is a local array of 64 bytes.
        let idx: [__m512i; 4] =
            std::array::from_fn(|v| unsafe { _mm512_loadu_si512(idx[v].as_ptr().cast()) });
        // SAFETY: `ctrl` is a local array of 64 bytes.
        let ctrl = unsafe { _mm512_loadu_si512(ctrl.as_ptr().cast()) };
        // SAFETY: `lut` is a local array of 64 bytes.
        let lut = unsafe { _mm512_loadu_si512(lut.as_ptr().cast()) };
        let three = _mm512_set1_epi8(3);
        for (q, chunk) in src.as_chunks::<64>().0.iter().enumerate() {
            // SAFETY: `chunk` is a `[u8; 64]`.
            let c = unsafe { _mm512_loadu_si512(chunk.as_ptr().cast()) };
            for (v, &iv) in idx.iter().enumerate() {
                let x = _mm512_permutexvar_epi8(iv, c);
                let x = _mm512_and_si512(_mm512_multishift_epi64_epi8(ctrl, x), three);
                let x = _mm512_shuffle_epi8(lut, x);
                // SAFETY: `q < src.len() / 64` and `v < 4`, so the 64 bytes end by
                // `src.len() / 64 * 256`; the offset is a multiple of 64, keeping
                // the aligned store aligned (caller contract).
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
        // SAFETY: a register-only instruction (`nomem`, `nostack`), and this
        // function's `#[target_feature]` makes every caller guarantee AVX-512
        // VNNI.
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
    ///
    /// Without `MASKS`, `w` is an expanded tile. With `MASKS`, `w` is a block
    /// of binary masks (`pack.rs`), expanded into registers quad by quad: one
    /// masked blend per vector instead of a tile store and load.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F, BW and VNNI. Without `MASKS`, `w` must
    /// be a 64-byte aligned expanded block of `k * 64` bytes; with `MASKS`, a
    /// block of `k * 8` bytes of binary masks. `q` must be readable for
    /// `R * k` bytes (`R` component rows of stride `k`); `scale` and `row_sum`
    /// must have 64 readable values and `frame_scale` `R / N`; `y` must be
    /// valid for writes of 64 floats at each `m * ldy` for `m < R / N`, with no
    /// other thread accessing them.
    #[target_feature(enable = "avx512f,avx512bw,avx512vnni")]
    unsafe fn kernel<const N: usize, const R: usize, const MASKS: bool>(
        w: *const u8,
        q: *const u8,
        k: usize,
        y: *mut f32,
        ldy: usize,
        scale: *const f32,
        row_sum: *const i32,
        frame_scale: *const f32,
    ) {
        let plus = _mm512_set1_epi8(1);
        let minus = _mm512_set1_epi8(-1);
        let mut acc = [[_mm512_setzero_si512(); 4]; R];
        for kq in 0..k / 4 {
            let w: [__m512i; 4] = if MASKS {
                // SAFETY: `kq < k / 4`, so quad `kq`'s 32 bytes of masks lie inside
                // the block (caller contract); the reads are unaligned.
                let wp = unsafe { w.add(kq * 32) };
                std::array::from_fn(|v| {
                    // SAFETY: mask `v` of quad `kq` (`v * 8 < 32`).
                    let mask = unsafe { wp.add(v * 8).cast::<u64>().read_unaligned() };
                    _mm512_mask_blend_epi8(u64::from_le(mask), minus, plus)
                })
            } else {
                // SAFETY: `kq < k / 4`, so quad `kq`'s 256 bytes lie inside the tile.
                let wp = unsafe { w.add(kq * 256) };
                // SAFETY: 64 aligned bytes of quad `kq` (`v * 64 < 256`).
                std::array::from_fn(|v| unsafe { _mm512_load_si512(wp.add(v * 64).cast()) })
            };
            for r in 0..R {
                // SAFETY: `r < R` and `4 * kq + 4 <= k`, so the four bytes lie in
                // component row `r` (caller contract); the read is unaligned.
                let a = _mm512_set1_epi32(unsafe {
                    q.add(r * k + 4 * kq).cast::<i32>().read_unaligned()
                });
                for v in 0..4 {
                    acc[r][v] = dpbusd(acc[r][v], a, w[v]);
                }
            }
        }
        for v in 0..4 {
            // SAFETY: 16 of `row_sum`'s 64 values (caller contract).
            let offset =
                _mm512_slli_epi32::<7>(unsafe { _mm512_loadu_si512(row_sum.add(v * 16).cast()) });
            // SAFETY: 16 of `scale`'s 64 values (caller contract).
            let sc = unsafe { _mm512_loadu_ps(scale.add(v * 16)) };
            for m in 0..R / N {
                let mut sum = _mm512_setzero_ps();
                for c in (0..N).rev() {
                    let d = _mm512_cvtepi32_ps(_mm512_sub_epi32(acc[m * N + c][v], offset));
                    sum = _mm512_fmadd_ps(d, _mm512_set1_ps(INV[c]), sum);
                }
                // SAFETY: `m < R / N` (caller contract).
                let fs = _mm512_set1_ps(unsafe { *frame_scale.add(m) });
                let out = _mm512_mul_ps(_mm512_mul_ps(sum, sc), fs);
                // SAFETY: 16 of frame `m`'s 64 output floats, which only this
                // thread accesses (caller contract).
                unsafe { _mm512_storeu_ps(y.add(m * ldy + v * 16), out) };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gemm_ref::{compare, reference_quantized};
    use lf_model::rng::SplitMix64;
    use lf_model::{BinaryMatrix, TernaryMatrix};

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

    /// Binary weights at 1 bit give exactly the output of the same weights
    /// widened to 2-bit ternary codes.
    #[test]
    fn binary_matches_widened_ternary_bit_for_bit() {
        if !crate::cpu_supported() {
            return;
        }
        let m = BinaryMatrix::random(192, 136, 8);
        let binary = PackedTernary::binary(&m).unwrap();
        let ternary = PackedTernary::new(&m.to_ternary()).unwrap();
        let mut rng = SplitMix64::new(9);
        for threads in [1, 3] {
            let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
            let scratch = Scratch::new(threads, scratch_bytes(136));
            for n in 1..=3 {
                // 1..=7 frames reach every kernel specialization for each `n`.
                for t in (1..=7).chain([13]) {
                    let x: Vec<f32> = (0..t * 136).map(|_| rng.next_gaussian()).collect();
                    let mut qa = QuantizedActs::with_capacity(t, 136, n);
                    qa.quantize(&pool, &x, t).unwrap();
                    let mut yb = vec![0.0; t * 192];
                    let mut yt = vec![1.0; t * 192];
                    gemm(&pool, &scratch, &binary, &qa, &mut yb);
                    gemm(&pool, &scratch, &ternary, &qa, &mut yt);
                    let bits = |y: &[f32]| y.iter().map(|v| v.to_bits()).collect::<Vec<_>>();
                    assert_eq!(bits(&yb), bits(&yt), "n={n} t={t} threads={threads}");
                    let (rel, worst) = compare(&yb, &reference_quantized(&m.to_ternary(), &qa));
                    assert!(rel < 1e-6 && worst < 1e-5, "n={n} t={t} rel={rel}");
                }
            }
        }
    }
}
