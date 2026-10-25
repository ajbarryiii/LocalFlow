//! Ternary GEMM on FP32 activations with AVX-512 FMA (variant A).
//!
//! Each thread takes whole 64-row output blocks. Per block and per `KC`
//! inputs it expands the 2-bit codes into an f32 tile of {-1, 0, +1}
//! (`KC * 64` floats, 128 KiB) and runs every frame against it. Partial sums
//! accumulate in `Y`; the row scale is applied with the last input block.

use crate::pack::{Encoding, NR, PackedTernary};
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
        // SAFETY: `pool.run` calls this closure once per index, so this thread
        // is the only user of buffer `idx` under this lease.
        let tile = unsafe { lease.get(idx) }.as_mut_ptr().cast::<f32>();
        for b in split_range(w.blocks(), threads, idx) {
            let mut kb = 0;
            while kb < k {
                let kc = KC.min(k - kb);
                // SAFETY: AVX-512 F and BMI2 were asserted on entry. `kb` and `kc`
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
                    // SAFETY: AVX-512 F was asserted on entry, and the tile holds
                    // `kc * 64` expanded floats. Rows `t0..t0 + rows` of `x` (stride
                    // `k`) and `y` (stride `o`) lie within the `t * k` and `t * o`
                    // checked on entry; columns `b * 64..b * 64 + 64` lie within `o`
                    // and `w.scale()` (`PackedTernary::new`: `o % 64 == 0`,
                    // `scale.len() == o`). Threads own whole blocks `b`, so their
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
        if !crate::cpu_supported() {
            return;
        }
        let mut rng = SplitMix64::new(15);
        for (rows, cols) in [(128, 96), (64, 1100)] {
            let m = BinaryMatrix::random(rows, cols, 16);
            let binary = PackedTernary::binary(&m).unwrap();
            let ternary = PackedTernary::new(&m.to_ternary()).unwrap();
            for threads in [1, 2] {
                let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
                let scratch = Scratch::new(threads, scratch_bytes());
                for t in [1, 6, 11] {
                    let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
                    let mut yb = vec![0.0; t * rows];
                    let mut yt = vec![1.0; t * rows];
                    gemm(&pool, &scratch, &binary, &x, t, &mut yb);
                    gemm(&pool, &scratch, &ternary, &x, t, &mut yt);
                    let bits = |y: &[f32]| y.iter().map(|v| v.to_bits()).collect::<Vec<_>>();
                    assert_eq!(bits(&yb), bits(&yt), "{rows}x{cols} t={t}");
                }
            }
        }
    }

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
