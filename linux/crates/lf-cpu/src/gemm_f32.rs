//! Ternary GEMM on FP32 activations with FMA (variant A), on AVX-512 or AVX2.
//!
//! Each thread takes whole 64-row output blocks. Per block and per `KC`
//! inputs it expands the 2-bit codes into an f32 tile of {-1, 0, +1}
//! (`KC * 64` floats, 128 KiB) and runs every frame against it. Partial sums
//! accumulate in `Y`; the row scale is applied with the last input block.
//! The AVX2 kernel covers 16 of the block's 64 outputs per call, in the same
//! order of operations per output.

use crate::pack::{Encoding, NR, PackedTernary};
use crate::{Scratch, SendPtr, ThreadPool, Tier, split_range};

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
    let tier = pool.tier();
    let (k, o) = (w.cols(), w.rows());
    assert!(x.len() >= crate::size(t, k) && y.len() >= crate::size(t, o));
    match tier {
        // SAFETY: a pool's tier is one this CPU supports, and the sizes were
        // checked just above.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { gemm_avx512(pool, scratch, w, x, t, y) },
        // SAFETY: as above.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe { gemm_avx2(pool, scratch, w, x, t, y) },
    }
}

/// [`gemm`] on the AVX-512 kernels.
///
/// # Safety
/// The CPU must support AVX-512 F and BMI2; `x` must hold `t * w.cols()`
/// values and `y` `t * w.rows()`.
#[cfg(target_arch = "x86_64")]
unsafe fn gemm_avx512(
    pool: &ThreadPool,
    scratch: &Scratch,
    w: &PackedTernary,
    x: &[f32],
    t: usize,
    y: &mut [f32],
) {
    let (k, o) = (w.cols(), w.rows());
    let threads = pool.threads();
    let lease = scratch.lease(threads, scratch_bytes());
    let yp = SendPtr(y.as_mut_ptr());
    pool.run(&|idx| {
        // SAFETY: `pool.run` calls this closure once per index, so this thread
        // is the only user of buffer `idx` under this lease.
        let tile = unsafe { lease.get(idx) }.as_mut_ptr().cast::<f32>();
        for b in split_range(w.blocks(), threads, idx) {
            let mut kb = 0;
            while kb < k {
                let kc = KC.min(k - kb);
                // SAFETY: AVX-512 F and BMI2 (caller contract). `kb` and `kc`
                // are multiples of 4 (`PackedTernary` makes `k % 4 == 0`, and
                // `KC % 4 == 0`), so quads `kb / 4..(kb + kc) / 4` lie within the
                // block's `k / 4` quads of `w.encoding().quad_bytes()` bytes; the
                // `kc * 64` floats written fit this thread's 64-byte aligned tile
                // of `scratch_bytes()`, checked by `lease`.
                unsafe {
                    match w.encoding() {
                        Encoding::Ternary => x86::expand_block(w.block(b), kb / 4, kc / 4, tile),
                        Encoding::Binary => {
                            x86::expand_block_binary(w.block(b), kb / 4, kc / 4, tile)
                        }
                    }
                };
                let last = kb + kc == k;
                let mut t0 = 0;
                while t0 < t {
                    let rows = MR.min(t - t0);
                    // SAFETY: AVX-512 F (caller contract), and the tile holds
                    // `kc * 64` expanded floats. Rows `t0..t0 + rows` of `x` (stride
                    // `k`) and `y` (stride `o`) lie within their `t * k` and `t * o`
                    // values (caller contract); columns `b * 64..b * 64 + 64` lie
                    // within `o` and `w.scale()` (`PackedTernary::new`: `o % 64 ==
                    // 0`, `scale.len() == o`). Threads own whole blocks `b`, so their
                    // `y` columns are disjoint.
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

/// [`gemm`] on the AVX2 kernels: the same tiles, 16 outputs per kernel call.
///
/// # Safety
/// The CPU must support AVX2 and FMA; `x` must hold `t * w.cols()` values
/// and `y` `t * w.rows()`.
#[cfg(target_arch = "x86_64")]
unsafe fn gemm_avx2(
    pool: &ThreadPool,
    scratch: &Scratch,
    w: &PackedTernary,
    x: &[f32],
    t: usize,
    y: &mut [f32],
) {
    let (k, o) = (w.cols(), w.rows());
    let threads = pool.threads();
    let lease = scratch.lease(threads, scratch_bytes());
    let yp = SendPtr(y.as_mut_ptr());
    pool.run(&|idx| {
        // SAFETY: `pool.run` calls this closure once per index, so this thread
        // is the only user of buffer `idx` under this lease.
        let tile = unsafe { lease.get(idx) }.as_mut_ptr().cast::<f32>();
        for b in split_range(w.blocks(), threads, idx) {
            let mut kb = 0;
            while kb < k {
                let kc = KC.min(k - kb);
                // SAFETY: AVX2 (caller contract). As in `gemm_avx512`: quads
                // `kb / 4..(kb + kc) / 4` lie within the block, and the `kc * 64`
                // floats written fit this thread's 64-byte aligned tile.
                unsafe {
                    match w.encoding() {
                        Encoding::Ternary => avx2::expand_block(w.block(b), kb / 4, kc / 4, tile),
                        Encoding::Binary => {
                            avx2::expand_block_binary(w.block(b), kb / 4, kc / 4, tile)
                        }
                    }
                };
                let last = kb + kc == k;
                let mut t0 = 0;
                while t0 < t {
                    let rows = MR.min(t - t0);
                    for part in 0..NR / avx2::OUTPUTS {
                        let col = b * NR + part * avx2::OUTPUTS;
                        // SAFETY: AVX2 and FMA (caller contract); the tile holds
                        // `kc` rows of 64 expanded floats, and this part's 16
                        // start `part * 16` floats into each. Rows `t0..t0 + rows`
                        // of `x` and `y` lie within their `t * k` and `t * o`
                        // values (caller contract); columns `col..col + 16` lie
                        // within `o` and `w.scale()`. Threads own whole blocks
                        // `b`, so their `y` columns are disjoint.
                        unsafe {
                            avx2::kernel_for(rows)(
                                tile.add(part * avx2::OUTPUTS),
                                x.as_ptr().add(t0 * k + kb),
                                k,
                                kc,
                                yp.get().add(t0 * o + col),
                                o,
                                kb > 0,
                                if last {
                                    w.scale().as_ptr().add(col)
                                } else {
                                    std::ptr::null()
                                },
                            )
                        };
                    }
                    t0 += rows;
                }
                kb += kc;
            }
        }
    });
}

/// The AVX-512 kernels.
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
    ///
    /// # Safety
    /// The CPU must support AVX-512 F, `src` must hold at least
    /// `(q0 + nq) * 64` bytes, and `dst` must be 64-byte aligned and valid for
    /// writes of `4 * nq * 64` floats that no other thread accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn expand_block(src: &[u8], q0: usize, nq: usize, dst: *mut f32) {
        let mut table = [0.0f32; 16];
        table[1] = 1.0;
        table[2] = -1.0;
        // SAFETY: `table` is a local array of 16 floats.
        let table = unsafe { _mm512_loadu_ps(table.as_ptr()) };
        let three = _mm512_set1_epi32(3);
        for ql in 0..nq {
            // SAFETY: `q0 + ql < q0 + nq`, so the 64 bytes lie within `src`
            // (caller contract).
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
                    // SAFETY: the offset is a multiple of 16 floats and ends by
                    // `4 * nq * 64`, so the aligned store stays inside `dst`.
                    unsafe { _mm512_store_ps(dst.add((4 * ql + k4) * 64 + v * 16), vals) };
                }
            }
        }
    }

    /// [`expand_block`] for binary masks (`pack.rs`): bits `4 * j + k4` of mask
    /// `v` are the codes of outputs `v * 16 + j` at input `4 * q + k4`.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F and BMI2, `src` must hold at least
    /// `(q0 + nq) * 32` bytes, and `dst` must be 64-byte aligned and valid for
    /// writes of `4 * nq * 64` floats that no other thread accesses.
    #[target_feature(enable = "avx512f,bmi2")]
    pub unsafe fn expand_block_binary(src: &[u8], q0: usize, nq: usize, dst: *mut f32) {
        const LANE0: u64 = 0x1111_1111_1111_1111;
        let plus = _mm512_set1_ps(1.0);
        let minus = _mm512_set1_ps(-1.0);
        for ql in 0..nq {
            let quad = &src[(q0 + ql) * 32..][..32];
            for (v, mask) in quad.as_chunks::<8>().0.iter().enumerate() {
                let mask = u64::from_le_bytes(*mask);
                for k4 in 0..4 {
                    let lanes = _pext_u64(mask, LANE0 << k4) as u16;
                    let vals = _mm512_mask_blend_ps(lanes, minus, plus);
                    // SAFETY: the offset is a multiple of 16 floats and ends by
                    // `4 * nq * 64`, so the aligned store stays inside `dst`.
                    unsafe { _mm512_store_ps(dst.add((4 * ql + k4) * 64 + v * 16), vals) };
                }
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX-512 F. `tile` must be 64-byte aligned with
    /// `kc * 64` readable floats; `x` must be readable at `r * ldx + i` for
    /// `r < R`, `i < kc`; `y` must be valid for reads and writes of 64 floats
    /// at each `r * ldy` for `r < R`, with no other thread accessing them;
    /// `scale` must be null or point to 64 readable floats.
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
            // SAFETY: `k < kc`, so row `k` lies inside the tile.
            let wp = unsafe { tile.add(k * 64) };
            // SAFETY: 16 floats of tile row `k`, 64-byte aligned (`v * 16 < 64`).
            let w: [__m512; 4] = std::array::from_fn(|v| unsafe { _mm512_load_ps(wp.add(v * 16)) });
            for r in 0..R {
                // SAFETY: `r < R` and `k < kc` (caller contract).
                let b = _mm512_set1_ps(unsafe { *x.add(r * ldx + k) });
                for v in 0..4 {
                    acc[r][v] = _mm512_fmadd_ps(w[v], b, acc[r][v]);
                }
            }
        }
        for r in 0..R {
            for v in 0..4 {
                // SAFETY: `r < R` and `v * 16 < 64` (caller contract).
                let p = unsafe { y.add(r * ldy + v * 16) };
                let mut out = acc[r][v];
                if accumulate {
                    // SAFETY: `p` points at 16 of row `r`'s 64 readable floats.
                    out = _mm512_add_ps(out, unsafe { _mm512_loadu_ps(p) });
                }
                if !scale.is_null() {
                    // SAFETY: a non-null `scale` has 64 floats (caller contract).
                    out = _mm512_mul_ps(out, unsafe { _mm512_loadu_ps(scale.add(v * 16)) });
                }
                // SAFETY: `p` points at 16 of row `r`'s 64 floats, which only this
                // thread accesses (caller contract).
                unsafe { _mm512_storeu_ps(p, out) };
            }
        }
    }
}

/// The AVX2 kernels: 16 outputs (two 8-lane vectors) by up to six frames.
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod avx2 {
    use std::arch::x86_64::*;

    /// Outputs per kernel call.
    pub const OUTPUTS: usize = 16;

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

    /// Expands quads `q0..q0 + nq` of one block into `[4 * nq][64]` floats,
    /// as the AVX-512 path does.
    ///
    /// # Safety
    /// The CPU must support AVX2, `src` must hold at least `(q0 + nq) * 64`
    /// bytes, and `dst` must be 32-byte aligned and valid for writes of
    /// `4 * nq * 64` floats that no other thread accesses.
    #[target_feature(enable = "avx2")]
    pub unsafe fn expand_block(src: &[u8], q0: usize, nq: usize, dst: *mut f32) {
        let table = _mm256_setr_ps(0.0, 1.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        let three = _mm256_set1_epi32(3);
        for ql in 0..nq {
            let quad = &src[(q0 + ql) * 64..][..64];
            for (g, bytes) in quad.as_chunks::<8>().0.iter().enumerate() {
                let d = _mm256_cvtepu8_epi32(_mm_set_epi64x(0, i64::from_le_bytes(*bytes)));
                for k4 in 0..4 {
                    let f = _mm256_and_si256(
                        _mm256_srlv_epi32(d, _mm256_set1_epi32(2 * k4 as i32)),
                        three,
                    );
                    let vals = _mm256_permutevar8x32_ps(table, f);
                    // SAFETY: the offset is a multiple of 8 floats and ends by
                    // `4 * nq * 64`, so the aligned store stays inside `dst`.
                    unsafe { _mm256_store_ps(dst.add((4 * ql + k4) * 64 + g * 8), vals) };
                }
            }
        }
    }

    /// [`expand_block`] for binary masks (`pack.rs`): bits `4 * j + k4` of mask
    /// `v` are the codes of outputs `v * 16 + j` at input `4 * q + k4`.
    ///
    /// # Safety
    /// The CPU must support AVX2, `src` must hold at least `(q0 + nq) * 32`
    /// bytes, and `dst` must be 32-byte aligned and valid for writes of
    /// `4 * nq * 64` floats that no other thread accesses.
    #[target_feature(enable = "avx2")]
    pub unsafe fn expand_block_binary(src: &[u8], q0: usize, nq: usize, dst: *mut f32) {
        // Lane j of `bits[k4]` tests bit `4 * j + k4` of a 32-bit half mask.
        let bits: [__m256i; 4] = std::array::from_fn(|k4| {
            _mm256_setr_epi32(
                1 << k4,
                1 << (4 + k4),
                1 << (8 + k4),
                1 << (12 + k4),
                1 << (16 + k4),
                1 << (20 + k4),
                1 << (24 + k4),
                1 << (28 + k4),
            )
        });
        let plus = _mm256_set1_ps(1.0);
        let minus = _mm256_set1_ps(-1.0);
        for ql in 0..nq {
            let quad = &src[(q0 + ql) * 32..][..32];
            // Half `h` of mask `v` covers outputs `v * 16 + h * 8..` (8 of them).
            for (half, mask) in quad.as_chunks::<4>().0.iter().enumerate() {
                let m = _mm256_set1_epi32(i32::from_le_bytes(*mask));
                for k4 in 0..4 {
                    let set = _mm256_cmpeq_epi32(_mm256_and_si256(m, bits[k4]), bits[k4]);
                    let vals = _mm256_blendv_ps(minus, plus, _mm256_castsi256_ps(set));
                    // SAFETY: the offset is a multiple of 8 floats and ends by
                    // `4 * nq * 64`, so the aligned store stays inside `dst`.
                    unsafe { _mm256_store_ps(dst.add((4 * ql + k4) * 64 + half * 8), vals) };
                }
            }
        }
    }

    /// The AVX-512 kernel's arithmetic for 16 of a tile's 64 columns.
    ///
    /// # Safety
    /// The CPU must support AVX2 and FMA. `tile` must be 32-byte aligned with
    /// 16 readable floats at each `k * 64` for `k < kc`; `x` must be readable
    /// at `r * ldx + i` for `r < R`, `i < kc`; `y` must be valid for reads and
    /// writes of 16 floats at each `r * ldy` for `r < R`, with no other thread
    /// accessing them; `scale` must be null or point to 16 readable floats.
    #[target_feature(enable = "avx2,fma")]
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
        let mut acc = [[_mm256_setzero_ps(); 2]; R];
        for k in 0..kc {
            // SAFETY: `k < kc`, so row `k` lies inside the tile.
            let wp = unsafe { tile.add(k * 64) };
            // SAFETY: 8 of row `k`'s 16 floats, 32-byte aligned (`v * 8 < 16`).
            let w: [__m256; 2] = std::array::from_fn(|v| unsafe { _mm256_load_ps(wp.add(v * 8)) });
            for r in 0..R {
                // SAFETY: `r < R` and `k < kc` (caller contract).
                let b = _mm256_set1_ps(unsafe { *x.add(r * ldx + k) });
                for v in 0..2 {
                    acc[r][v] = _mm256_fmadd_ps(w[v], b, acc[r][v]);
                }
            }
        }
        for r in 0..R {
            for v in 0..2 {
                // SAFETY: `r < R` and `v * 8 < 16` (caller contract).
                let p = unsafe { y.add(r * ldy + v * 8) };
                let mut out = acc[r][v];
                if accumulate {
                    // SAFETY: `p` points at 8 of row `r`'s 16 readable floats.
                    out = _mm256_add_ps(out, unsafe { _mm256_loadu_ps(p) });
                }
                if !scale.is_null() {
                    // SAFETY: a non-null `scale` has 16 floats (caller contract).
                    out = _mm256_mul_ps(out, unsafe { _mm256_loadu_ps(scale.add(v * 8)) });
                }
                // SAFETY: `p` points at 8 of row `r`'s 16 floats, which only this
                // thread accesses (caller contract).
                unsafe { _mm256_storeu_ps(p, out) };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gemm_ref::{compare, reference};
    use lf_model::rng::SplitMix64;
    use lf_model::{BinaryMatrix, TernaryMatrix};

    /// Binary weights at 1 bit give exactly the output of the same weights
    /// widened to 2-bit ternary codes, including across partial `KC` blocks.
    #[test]
    fn binary_matches_widened_ternary_bit_for_bit() {
        let mut rng = SplitMix64::new(15);
        for (rows, cols) in [(128, 96), (64, 1100)] {
            let m = BinaryMatrix::random(rows, cols, 16);
            let binary = PackedTernary::binary(&m).unwrap();
            let ternary = PackedTernary::new(&m.to_ternary()).unwrap();
            for threads in [1, 2] {
                let scratch = Scratch::new(threads, scratch_bytes());
                for pool in crate::tier_pools(threads) {
                    let tier = pool.tier();
                    for t in [1, 6, 11] {
                        let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
                        let mut yb = vec![0.0; t * rows];
                        let mut yt = vec![1.0; t * rows];
                        gemm(&pool, &scratch, &binary, &x, t, &mut yb);
                        gemm(&pool, &scratch, &ternary, &x, t, &mut yt);
                        let bits = |y: &[f32]| y.iter().map(|v| v.to_bits()).collect::<Vec<_>>();
                        assert_eq!(bits(&yb), bits(&yt), "{tier} {rows}x{cols} t={t}");
                        let (rel, worst) = compare(&yb, &reference(&m.to_ternary(), &x, t));
                        assert!(rel < 1e-6 && worst < 1e-5, "{tier} {rows}x{cols} t={t}");
                    }
                }
            }
        }
    }

    #[test]
    fn matches_reference() {
        let mut rng = SplitMix64::new(5);
        // 1100 inputs: two full KC blocks plus a partial one.
        for (rows, cols) in [(128, 96), (64, 1100)] {
            let m = TernaryMatrix::random(rows, cols, 6);
            let w = PackedTernary::new(&m).unwrap();
            for threads in [1, 2] {
                let scratch = Scratch::new(threads, scratch_bytes());
                for pool in crate::tier_pools(threads) {
                    let tier = pool.tier();
                    for t in [1, 6, 11] {
                        let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
                        let mut y = vec![0.0; t * rows];
                        gemm(&pool, &scratch, &w, &x, t, &mut y);
                        let (rel, worst) = compare(&y, &reference(&m, &x, t));
                        assert!(
                            rel < 1e-6 && worst < 1e-5,
                            "{tier} {rows}x{cols} t={t} rel={rel} worst={worst}"
                        );
                    }
                }
            }
        }
    }
}
