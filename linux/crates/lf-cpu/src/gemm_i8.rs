//! Ternary GEMM on residual-INT8 activations with VNNI (variant C), with an
//! AVX2 path (see [`crate::tier`]) described at the end.
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
//!
//! AVX2 expands both encodings into the same tile and runs 16 outputs per
//! kernel call (two 8-lane vectors, up to six component rows). INT8 dot
//! products use AVX-VNNI's `vpdpbusd` when the CPU has it; otherwise
//! `vpmaddubsw` sums pairs into 16 bits, which cannot saturate here (see
//! `QUADS16`), and `vpmaddwd` widens them every 64 quads.

use crate::pack::{Encoding, NR, PackedTernary};
use crate::quant::{QuantizedActs, RATIO};
use crate::{Scratch, SendPtr, ThreadPool, Tier, split_range};

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
    let tier = pool.tier();
    assert_eq!(qa.cols(), w.cols());
    assert!(y.len() >= crate::size(qa.rows(), w.rows()));
    match tier {
        // SAFETY: a pool's tier is one this CPU supports, and the shapes were
        // checked just above.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { gemm_avx512(pool, scratch, w, qa, y) },
        // SAFETY: as above.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { vnni } => unsafe { gemm_avx2(pool, scratch, w, qa, y, vnni) },
    }
}

/// [`gemm`] on the AVX-512 kernels.
///
/// # Safety
/// The CPU must support AVX-512 F, BW, VNNI and VBMI; `qa.cols() == w.cols()`
/// and `y` must hold `qa.rows() * w.rows()` values.
#[cfg(target_arch = "x86_64")]
unsafe fn gemm_avx512(
    pool: &ThreadPool,
    scratch: &Scratch,
    w: &PackedTernary,
    qa: &QuantizedActs,
    y: &mut [f32],
) {
    let (t, k, n, o) = (qa.rows(), w.cols(), qa.components(), w.rows());
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
                // SAFETY: AVX-512 F/BW/VBMI (caller contract). `w.block(b)` has
                // `k / 4 * 64` bytes of 2-bit codes, and the expansion writes
                // `k * 64` bytes, which is `scratch_bytes(k)`, the size `lease`
                // checked for this thread's 64-byte aligned tile.
                unsafe { x86::expand_block(w.block(b), tile) };
                tile.cast_const()
            };
            let mut t0 = 0;
            while t0 < t {
                let rows = mt.min(t - t0);
                let kernel = x86::kernel_for(n, rows, masks);
                // SAFETY: AVX-512 F/BW/VNNI (caller contract). `src` is the
                // tile holding block `b` or, for binary weights, the block's
                // `k * 8` bytes of masks (`PackedTernary::block`), with `k % 4 == 0`
                // (`qa.cols() == w.cols()`). `QuantizedActs` keeps `q()` at
                // `t * n * k` bytes and `scale()` at `t` values, so frames
                // `t0..t0 + rows` (`n * rows` component rows) are readable. `y`
                // rows `t0..t0 + rows` lie within its `t * o` values (caller
                // contract), and columns `b * 64..b * 64 + 64` within `o`,
                // `w.scale()` and `w.row_sum()` (`PackedTernary`). Threads own
                // whole blocks `b`, so their `y` columns are disjoint.
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

/// [`gemm`] on the AVX2 kernels, with AVX-VNNI dot products if `vnni`.
///
/// Both encodings expand each block into the same s8 tile as the AVX-512
/// ternary path; a kernel call then covers 16 of the block's 64 outputs.
///
/// # Safety
/// The CPU must support AVX2 and FMA, and AVX-VNNI if `vnni`;
/// `qa.cols() == w.cols()` and `y` must hold `qa.rows() * w.rows()` values.
#[cfg(target_arch = "x86_64")]
unsafe fn gemm_avx2(
    pool: &ThreadPool,
    scratch: &Scratch,
    w: &PackedTernary,
    qa: &QuantizedActs,
    y: &mut [f32],
    vnni: bool,
) {
    let (t, k, n, o) = (qa.rows(), w.cols(), qa.components(), w.rows());
    let mt = avx2::ROWS / n;
    let threads = pool.threads();
    let lease = scratch.lease(threads, scratch_bytes(k));
    let yp = SendPtr(y.as_mut_ptr());
    pool.run(&|idx| {
        // SAFETY: `pool.run` calls this closure once per index, so this thread
        // is the only user of buffer `idx` under this lease.
        let tile = unsafe { lease.get(idx) }.as_mut_ptr();
        for b in split_range(w.blocks(), threads, idx) {
            // SAFETY: AVX2 (caller contract). `w.block(b)` has `k / 4` quads of
            // `w.encoding().quad_bytes()` bytes, and either expansion writes
            // `k * 64` bytes, which is `scratch_bytes(k)`, the size `lease`
            // checked for this thread's 64-byte aligned tile.
            unsafe {
                match w.encoding() {
                    Encoding::Ternary => avx2::expand_block(w.block(b), tile),
                    Encoding::Binary => avx2::expand_block_binary(w.block(b), tile),
                }
            };
            let mut t0 = 0;
            while t0 < t {
                let rows = mt.min(t - t0);
                let kernel = avx2::kernel_for(n, rows, vnni);
                for part in 0..NR / avx2::OUTPUTS {
                    let col = b * NR + part * avx2::OUTPUTS;
                    // SAFETY: AVX2 and FMA, and AVX-VNNI if `vnni` (caller
                    // contract). The tile holds block `b` expanded (`k * 64`
                    // bytes, 64-byte aligned), and outputs `part * 16..` of
                    // each quad start `part * 64` bytes in. `QuantizedActs`
                    // keeps `q()` at `t * n * k` bytes and `scale()` at `t`
                    // values, so frames `t0..t0 + rows` (`n * rows` component
                    // rows) are readable. `y` rows `t0..t0 + rows` lie within
                    // its `t * o` values (caller contract), and columns
                    // `col..col + 16` within `o`, `w.scale()` and `w.row_sum()`
                    // (`PackedTernary`). Threads own whole blocks `b`, so their
                    // `y` columns are disjoint.
                    unsafe {
                        kernel(
                            tile.add(part * 64),
                            qa.q().as_ptr().add(t0 * n * k),
                            k,
                            yp.get().add(t0 * o + col),
                            o,
                            w.scale().as_ptr().add(col),
                            w.row_sum().as_ptr().add(col),
                            qa.scale().as_ptr().add(t0),
                        )
                    };
                }
                t0 += rows;
            }
        }
    });
}

const INV: [f32; 3] = [1.0, 1.0 / RATIO, 1.0 / (RATIO * RATIO)];

/// The AVX-512 kernels.
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

/// The AVX2 kernels: 16 outputs (two 8-lane vectors) by up to six
/// component rows per call.
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod avx2 {
    use super::INV;
    use std::arch::x86_64::*;

    /// Outputs per kernel call.
    pub const OUTPUTS: usize = 16;
    /// Most component rows per call (`n * frames`), with two accumulators each.
    pub const ROWS: usize = 6;
    /// Quads summed in 16 bits before widening, without VNNI. Weights are -1,
    /// 0 or +1 and activations u8, so each `vpmaddubsw` lane (two products) is
    /// at most 2 * 255 = 510 in magnitude and never saturates, and 64 of them
    /// stay within 64 * 510 = 32,640 < 32,767.
    const QUADS16: usize = 64;

    type Kernel =
        unsafe fn(*const u8, *const u8, usize, *mut f32, usize, *const f32, *const i32, *const f32);

    /// Kernel for `n` components and `frames` frames (`n * frames <= 6` rows),
    /// with AVX-VNNI if `vnni`.
    pub fn kernel_for(n: usize, frames: usize, vnni: bool) -> Kernel {
        match (n, frames, vnni) {
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
            _ => unreachable!("no kernel for {n} components x {frames} frames"),
        }
    }

    /// Expands one block of 2-bit codes (`quads * 64` bytes) into the s8 tile
    /// of the AVX-512 path: byte `4 * j + f` of quad `q` is the weight of
    /// output `j`, input `4 * q + f`.
    ///
    /// # Safety
    /// The CPU must support AVX2, and `dst` must be 32-byte aligned and valid
    /// for writes of `src.len() / 64 * 256` bytes that no other thread
    /// accesses.
    #[target_feature(enable = "avx2")]
    pub unsafe fn expand_block(src: &[u8], dst: *mut u8) {
        // A code byte holds fields 0 and 1 in its low nibble and 2 and 3 in
        // its high one; `even` maps a nibble to its low field's weight, `odd`
        // to its high field's (code 0 is 0, 1 is +1, 2 is -1).
        let even = _mm256_setr_epi8(
            0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, //
            0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0,
        );
        let odd = _mm256_setr_epi8(
            0, 0, 0, 0, 1, 1, 1, 1, -1, -1, -1, -1, 0, 0, 0, 0, //
            0, 0, 0, 0, 1, 1, 1, 1, -1, -1, -1, -1, 0, 0, 0, 0,
        );
        let nibble = _mm256_set1_epi8(0x0f);
        for (q, chunk) in src.as_chunks::<64>().0.iter().enumerate() {
            for half in 0..2 {
                // SAFETY: 32 of the chunk's 64 bytes (`half * 32 + 32 <= 64`).
                let c = unsafe { _mm256_loadu_si256(chunk.as_ptr().add(half * 32).cast()) };
                let lo = _mm256_and_si256(c, nibble);
                let hi = _mm256_and_si256(_mm256_srli_epi16::<4>(c), nibble);
                // Weights of fields 0..4 for the 32 outputs of this half.
                let f0 = _mm256_shuffle_epi8(even, lo);
                let f1 = _mm256_shuffle_epi8(odd, lo);
                let f2 = _mm256_shuffle_epi8(even, hi);
                let f3 = _mm256_shuffle_epi8(odd, hi);
                // Interleave to four bytes per output. Unpacks work within
                // 128-bit lanes: `a` holds outputs 0..4 and 16..20, `b` 4..8 and
                // 20..24, `c` 8..12 and 24..28, `d` 12..16 and 28..32.
                let (p01l, p01h) = (_mm256_unpacklo_epi8(f0, f1), _mm256_unpackhi_epi8(f0, f1));
                let (p23l, p23h) = (_mm256_unpacklo_epi8(f2, f3), _mm256_unpackhi_epi8(f2, f3));
                let a = _mm256_unpacklo_epi16(p01l, p23l);
                let b = _mm256_unpackhi_epi16(p01l, p23l);
                let c = _mm256_unpacklo_epi16(p01h, p23h);
                let d = _mm256_unpackhi_epi16(p01h, p23h);
                let out = [
                    _mm256_permute2x128_si256::<0x20>(a, b),
                    _mm256_permute2x128_si256::<0x20>(c, d),
                    _mm256_permute2x128_si256::<0x31>(a, b),
                    _mm256_permute2x128_si256::<0x31>(c, d),
                ];
                for (i, v) in out.into_iter().enumerate() {
                    // SAFETY: `q < src.len() / 64`, so the 32 bytes end by
                    // `src.len() / 64 * 256`; the offset is a multiple of 32,
                    // keeping the aligned store aligned (caller contract).
                    unsafe { _mm256_store_si256(dst.add(q * 256 + half * 128 + i * 32).cast(), v) };
                }
            }
        }
    }

    /// Expands one block of binary masks (`quads * 32` bytes, `pack.rs`) into
    /// the same tile as [`expand_block`]: bit `p` of mask `v` becomes byte
    /// `v * 64 + p` of its quad, +1 if set and -1 if clear.
    ///
    /// # Safety
    /// As [`expand_block`], with `dst` valid for `src.len() / 32 * 256` bytes.
    #[target_feature(enable = "avx2")]
    pub unsafe fn expand_block_binary(src: &[u8], dst: *mut u8) {
        // Byte i of 32 takes mask byte i / 8 and tests bit i % 8 of it.
        let spread = _mm256_setr_epi8(
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, //
            2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3,
        );
        let bit = _mm256_set1_epi64x(0x8040_2010_0804_0201u64 as i64);
        let one = _mm256_set1_epi8(1);
        for (i, mask) in src.as_chunks::<4>().0.iter().enumerate() {
            let m = _mm256_set1_epi32(i32::from_le_bytes(*mask));
            let x = _mm256_and_si256(_mm256_shuffle_epi8(m, spread), bit);
            // Clear bits compare equal to zero (-1 | 1 = -1); set bits give 0 | 1.
            let v = _mm256_or_si256(_mm256_cmpeq_epi8(x, _mm256_setzero_si256()), one);
            // SAFETY: mask `i < src.len() / 4` covers bytes `i * 32..i * 32 + 32`,
            // which end by `src.len() / 32 * 256`; the offset is a multiple of
            // 32 (caller contract).
            unsafe { _mm256_store_si256(dst.add(i * 32).cast(), v) };
        }
    }

    /// `acc + dot4(a as u8, b as s8)` per 32-bit lane with AVX-VNNI. Inline
    /// asm for the reason given in the AVX-512 path; `{vex}` forces the VEX
    /// encoding, which (unlike the EVEX one) needs no AVX-512. Only AVX2 is
    /// enabled, so that this inlines into the kernel the `vpmaddubsw` path
    /// shares.
    ///
    /// # Safety
    /// The CPU must support AVX-VNNI.
    #[inline]
    #[target_feature(enable = "avx2")]
    unsafe fn dpbusd(acc: __m256i, a: __m256i, b: __m256i) -> __m256i {
        let mut out = acc;
        // SAFETY: a register-only instruction (`nomem`, `nostack`); the caller
        // guarantees AVX-VNNI.
        unsafe {
            std::arch::asm!(
                "{{vex}} vpdpbusd {acc}, {a}, {b}",
                acc = inout(ymm_reg) out,
                a = in(ymm_reg) a,
                b = in(ymm_reg) b,
                options(pure, nomem, nostack, preserves_flags),
            );
        }
        out
    }

    /// `R = N * frames` accumulator rows of two 8-lane vectors, for 16
    /// outputs of a tile whose quads are 256 bytes apart.
    ///
    /// # Safety
    /// The CPU must support AVX2 and FMA, and AVX-VNNI if `VNNI`. `w` must be
    /// 32-byte aligned and readable for 64 bytes at each `kq * 256` for
    /// `kq < k / 4`. `q` must be readable for `R * k` bytes (`R` component
    /// rows of stride `k`); `scale` and `row_sum` must have 16 readable values
    /// and `frame_scale` `R / N`; `y` must be valid for writes of 16 floats at
    /// each `m * ldy` for `m < R / N`, with no other thread accessing them.
    #[target_feature(enable = "avx2,fma")]
    unsafe fn kernel<const N: usize, const R: usize, const VNNI: bool>(
        w: *const u8,
        q: *const u8,
        k: usize,
        y: *mut f32,
        ldy: usize,
        scale: *const f32,
        row_sum: *const i32,
        frame_scale: *const f32,
    ) {
        let quads = k / 4;
        let weights = |kq: usize| -> [__m256i; 2] {
            // SAFETY: the two aligned vectors of quad `kq < k / 4` (caller
            // contract).
            std::array::from_fn(|v| unsafe { _mm256_load_si256(w.add(kq * 256 + v * 32).cast()) })
        };
        let acts = |r: usize, kq: usize| -> __m256i {
            // SAFETY: `r < R` and `4 * kq + 4 <= k`, so the four bytes lie in
            // component row `r` (caller contract); the read is unaligned.
            _mm256_set1_epi32(unsafe { q.add(r * k + 4 * kq).cast::<i32>().read_unaligned() })
        };
        let mut acc = [[_mm256_setzero_si256(); 2]; R];
        if VNNI {
            for kq in 0..quads {
                let wv = weights(kq);
                for r in 0..R {
                    let a = acts(r, kq);
                    for v in 0..2 {
                        // SAFETY: `VNNI` implies AVX-VNNI (caller contract).
                        acc[r][v] = unsafe { dpbusd(acc[r][v], a, wv[v]) };
                    }
                }
            }
        } else {
            let ones = _mm256_set1_epi16(1);
            let mut kq0 = 0;
            while kq0 < quads {
                let end = (kq0 + QUADS16).min(quads);
                let mut acc16 = [[_mm256_setzero_si256(); 2]; R];
                for kq in kq0..end {
                    let wv = weights(kq);
                    for r in 0..R {
                        let a = acts(r, kq);
                        for v in 0..2 {
                            let p = _mm256_maddubs_epi16(a, wv[v]);
                            acc16[r][v] = _mm256_add_epi16(acc16[r][v], p);
                        }
                    }
                }
                for r in 0..R {
                    for v in 0..2 {
                        let wide = _mm256_madd_epi16(acc16[r][v], ones);
                        acc[r][v] = _mm256_add_epi32(acc[r][v], wide);
                    }
                }
                kq0 = end;
            }
        }
        // The AVX-512 epilogue, 8 lanes at a time.
        for v in 0..2 {
            // SAFETY: 8 of `row_sum`'s 16 values (caller contract).
            let offset =
                _mm256_slli_epi32::<7>(unsafe { _mm256_loadu_si256(row_sum.add(v * 8).cast()) });
            // SAFETY: 8 of `scale`'s 16 values (caller contract).
            let sc = unsafe { _mm256_loadu_ps(scale.add(v * 8)) };
            for m in 0..R / N {
                let mut sum = _mm256_setzero_ps();
                for c in (0..N).rev() {
                    let d = _mm256_cvtepi32_ps(_mm256_sub_epi32(acc[m * N + c][v], offset));
                    sum = _mm256_fmadd_ps(d, _mm256_set1_ps(INV[c]), sum);
                }
                // SAFETY: `m < R / N` (caller contract).
                let fs = _mm256_set1_ps(unsafe { *frame_scale.add(m) });
                let out = _mm256_mul_ps(_mm256_mul_ps(sum, sc), fs);
                // SAFETY: 8 of frame `m`'s 16 output floats, which only this
                // thread accesses (caller contract).
                unsafe { _mm256_storeu_ps(y.add(m * ldy + v * 8), out) };
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

    /// 1100 inputs span several 64-quad blocks of the `vpmaddubsw` path.
    const SHAPES: [(usize, usize); 2] = [(192, 96), (64, 1100)];

    #[test]
    fn matches_reference_on_quantized_inputs() {
        let mut rng = SplitMix64::new(4);
        for (rows, cols) in SHAPES {
            let m = TernaryMatrix::random(rows, cols, 3);
            let w = PackedTernary::new(&m).unwrap();
            for threads in [1, 3] {
                let scratch = Scratch::new(threads, scratch_bytes(cols));
                for pool in crate::tier_pools(threads) {
                    let tier = pool.tier();
                    for n in 1..=3 {
                        for t in [1, 2, 5, 7, 13] {
                            let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
                            let mut qa = QuantizedActs::with_capacity(t, cols, n);
                            qa.quantize(&pool, &x, t).unwrap();
                            let mut y = vec![0.0; t * rows];
                            gemm(&pool, &scratch, &w, &qa, &mut y);
                            let (rel, worst) = compare(&y, &reference_quantized(&m, &qa));
                            assert!(
                                rel < 1e-6 && worst < 1e-5,
                                "{tier} {rows}x{cols} n={n} t={t} rel={rel} worst={worst}"
                            );
                        }
                    }
                }
            }
        }
    }

    /// Binary weights at 1 bit give exactly the output of the same weights
    /// widened to 2-bit ternary codes.
    #[test]
    fn binary_matches_widened_ternary_bit_for_bit() {
        let mut rng = SplitMix64::new(9);
        for (rows, cols) in [(192, 136), (64, 1100)] {
            let m = BinaryMatrix::random(rows, cols, 8);
            let binary = PackedTernary::binary(&m).unwrap();
            let ternary = PackedTernary::new(&m.to_ternary()).unwrap();
            for threads in [1, 3] {
                let scratch = Scratch::new(threads, scratch_bytes(cols));
                for pool in crate::tier_pools(threads) {
                    let tier = pool.tier();
                    for n in 1..=3 {
                        // 1..=7 frames reach every kernel specialization for each `n`.
                        for t in (1..=7).chain([13]) {
                            let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
                            let mut qa = QuantizedActs::with_capacity(t, cols, n);
                            qa.quantize(&pool, &x, t).unwrap();
                            let mut yb = vec![0.0; t * rows];
                            let mut yt = vec![1.0; t * rows];
                            gemm(&pool, &scratch, &binary, &qa, &mut yb);
                            gemm(&pool, &scratch, &ternary, &qa, &mut yt);
                            let bits =
                                |y: &[f32]| y.iter().map(|v| v.to_bits()).collect::<Vec<_>>();
                            assert_eq!(
                                bits(&yb),
                                bits(&yt),
                                "{tier} n={n} t={t} threads={threads}"
                            );
                            let (rel, worst) =
                                compare(&yb, &reference_quantized(&m.to_ternary(), &qa));
                            assert!(rel < 1e-6 && worst < 1e-5, "{tier} n={n} t={t} rel={rel}");
                        }
                    }
                }
            }
        }
    }

    /// The largest sums the kernels can see: rows of all +1 or all -1 against
    /// frames at full scale (every first component at 255 or 1 as u8), over
    /// many 64-quad blocks.
    #[test]
    fn extreme_inputs_match_reference() {
        let (rows, cols) = (64, 1024);
        let codes = |r: usize| match r % 4 {
            0 => 0x55, // all +1
            1 => 0xaa, // all -1
            2 => 0x99, // +1, -1, -1, +1
            _ => 0x00,
        };
        let m = TernaryMatrix {
            rows,
            cols,
            codes: (0..rows * cols / 4)
                .map(|i| codes(i / (cols / 4)))
                .collect(),
            scale: (0..rows).map(|r| 0.01 + r as f32 * 1e-3).collect(),
        };
        let w = PackedTernary::new(&m).unwrap();
        let ones = BinaryMatrix {
            rows,
            cols,
            bits: (0..rows * cols / 8)
                .map(|i| if i / (cols / 8) % 2 == 0 { 0xff } else { 0x00 })
                .collect(),
            scale: m.scale.clone(),
        };
        let wb = PackedTernary::binary(&ones).unwrap();
        let t = 4;
        let x: Vec<f32> = (0..t * cols)
            .map(|i| match i / cols {
                0 => 3.0,
                1 => -3.0,
                2 => {
                    if i % 2 == 0 {
                        3.0
                    } else {
                        -3.0
                    }
                }
                _ => {
                    if i % 3 == 0 {
                        -3.0
                    } else {
                        2.5
                    }
                }
            })
            .collect();
        let scratch = Scratch::new(2, scratch_bytes(cols));
        for pool in crate::tier_pools(2) {
            let tier = pool.tier();
            for n in 1..=3 {
                let mut qa = QuantizedActs::with_capacity(t, cols, n);
                qa.quantize(&pool, &x, t).unwrap();
                for (mat, packed) in [(&m, &w), (&ones.to_ternary(), &wb)] {
                    let mut y = vec![0.0; t * rows];
                    gemm(&pool, &scratch, packed, &qa, &mut y);
                    let (rel, worst) = compare(&y, &reference_quantized(mat, &qa));
                    assert!(
                        rel < 1e-6 && worst < 1e-5,
                        "{tier} n={n} rel={rel} worst={worst}"
                    );
                }
            }
        }
    }
}
