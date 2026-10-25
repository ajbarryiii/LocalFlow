//! Register-only throughput probes: the most multiply-accumulates per second a
//! core can retire with 512-bit VNNI (u8 x s8) or FP32 FMA, and the AVX2
//! tier's counterparts (256-bit AVX-VNNI, `vpmaddubsw` + `vpaddw`, FMA). Used
//! as the ceiling when judging kernel efficiency and latency targets. Each
//! probe panics if the CPU lacks its tier.

use crate::Tier;

/// Multiply-accumulates performed by one call with `iters` iterations.
pub fn vnni_macs(iters: u64) -> u64 {
    iters * CHAINS as u64 * 64
}

pub fn fma_macs(iters: u64) -> u64 {
    iters * CHAINS as u64 * 16
}

const CHAINS: usize = 16;

/// Multiply-accumulates of one [`vnni_avx2`] or [`maddubs`] call.
pub fn avx2_int8_macs(iters: u64) -> u64 {
    iters * AVX2_CHAINS as u64 * 32
}

pub fn fma_avx2_macs(iters: u64) -> u64 {
    iters * AVX2_CHAINS as u64 * 8
}

/// Chains of the AVX2 probes: with the two operands they fill 14 of the 16
/// ymm registers (16 chains would spill).
const AVX2_CHAINS: usize = 12;

fn require(tier: Tier) {
    assert!(tier.supported(), "this CPU lacks {}", tier.requirements());
}

/// Like [`vnni`] with 256-bit AVX-VNNI `vpdpbusd`.
pub fn vnni_avx2(iters: u64) -> i32 {
    require(Tier::Avx2 { vnni: true });
    // SAFETY: AVX2 and AVX-VNNI were checked just above.
    unsafe { avx2::vnni(iters) }
}

/// 12 chains of `vpmaddubsw` + `vpaddw` (32 multiply-accumulates per pair),
/// the AVX2 tier's INT8 step without VNNI.
pub fn maddubs(iters: u64) -> i32 {
    require(Tier::Avx2 { vnni: false });
    // SAFETY: AVX2 was checked just above.
    unsafe { avx2::maddubs(iters) }
}

/// Like [`fma`] on 256-bit vectors.
pub fn fma_avx2(iters: u64) -> f32 {
    require(Tier::Avx2 { vnni: false });
    // SAFETY: AVX2 and FMA were checked just above.
    unsafe { avx2::fma(iters) }
}

/// Runs `iters` rounds of 16 independent `vpdpbusd` chains; returns a checksum.
pub fn vnni(iters: u64) -> i32 {
    require(Tier::Avx512);
    // SAFETY: AVX-512 F and VNNI were checked just above.
    unsafe { x86::vnni(iters) }
}

/// Runs `iters` rounds of 16 independent FP32 FMA chains; returns a checksum.
pub fn fma(iters: u64) -> f32 {
    require(Tier::Avx512);
    // SAFETY: AVX-512 F was checked just above.
    unsafe { x86::fma(iters) }
}

/// Ternary lookup step: one 32-entry `vpermt2ps` (16 outputs x 3 inputs) plus
/// one accumulate, so 48 multiply-accumulate equivalents.
pub fn lut_macs(iters: u64) -> u64 {
    iters * LUT_CHAINS as u64 * 48
}

const LUT_CHAINS: usize = 12;

/// How the looked-up value is accumulated.
#[derive(Clone, Copy, Debug)]
pub enum LutAccumulate {
    /// `vaddps`.
    Add,
    /// `vfmadd231ps` with a constant 1.0, to use the FMA pipes.
    FmaOne,
    /// Alternate the two across chains.
    Mixed,
}

/// Runs `iters` rounds of 12 independent permute-and-accumulate chains.
pub fn lut(iters: u64, mode: LutAccumulate) -> f32 {
    require(Tier::Avx512);
    // SAFETY: AVX-512 F was checked just above.
    unsafe { x86::lut(iters, mode) }
}

/// Like [`lut`] with `Add`, but the destroyed operand is reloaded from L1 for
/// every lookup instead of copied: the table half with `vpermt2ps` if `table`,
/// otherwise the index with `vpermi2ps`.
pub fn lut_load(iters: u64, table: bool) -> f32 {
    require(Tier::Avx512);
    // SAFETY: AVX-512 F was checked just above.
    unsafe { x86::lut_load(iters, table) }
}

/// Sign-symmetric ternary lookup (the `gemm_lut` scheme): a non-destructive
/// 16-entry `vpermps` over 14 of the 27 sums of 3 inputs (one per ± pair,
/// indexed by the non-negative balanced-ternary patterns), then an FMA
/// by a per-lane ±1 sign. Two vector operations per 48 multiply-accumulate
/// equivalents, with no register copy. With `fma == false` the FMA becomes an
/// add, which isolates the permute's throughput.
pub fn lut_sym(iters: u64, fma: bool) -> f32 {
    require(Tier::Avx512);
    // SAFETY: AVX-512 F was checked just above.
    unsafe { x86::lut_sym(iters, fma) }
}

/// The AVX-512 probes.
mod x86 {
    use super::{CHAINS, LUT_CHAINS, LutAccumulate};

    /// `vpermps` through asm (not `pure`) so repeated lookups are not merged.
    #[inline]
    #[target_feature(enable = "avx512f")]
    fn perm16(idx: __m512i, table: __m512) -> __m512 {
        let t: __m512;
        // SAFETY: a register-only instruction (`nomem`, `nostack`), and this
        // function's `#[target_feature]` makes every caller guarantee AVX-512 F.
        unsafe {
            std::arch::asm!(
                "vpermps {t}, {idx}, {tab}",
                t = out(zmm_reg) t,
                idx = in(zmm_reg) idx,
                tab = in(zmm_reg) table,
                options(nomem, nostack, preserves_flags),
            );
        }
        t
    }

    /// # Safety
    /// The CPU must support AVX-512 F.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn lut_sym(iters: u64, fma: bool) -> f32 {
        let table = _mm512_set1_ps(1e-7);
        let sign = _mm512_set1_ps(-1.0);
        let idx: [__m512i; 4] = std::array::from_fn(|i| _mm512_set1_epi32(i as i32 * 3 + 1));
        let mut acc = [_mm512_setzero_ps(); LUT_CHAINS];
        for _ in 0..iters {
            for (c, v) in acc.iter_mut().enumerate() {
                let t = perm16(idx[c % 4], table);
                *v = if fma {
                    _mm512_fmadd_ps(t, sign, *v)
                } else {
                    _mm512_add_ps(*v, t)
                };
            }
        }
        acc.iter().map(|&v| _mm512_reduce_add_ps(v)).sum()
    }

    /// `vpermt2ps` through asm (not `pure`) so repeated lookups are not merged.
    #[inline]
    #[target_feature(enable = "avx512f")]
    fn perm(idx: __m512i, a: __m512, b: __m512) -> __m512 {
        let mut t = a;
        // SAFETY: a register-only instruction (`nomem`, `nostack`), and this
        // function's `#[target_feature]` makes every caller guarantee AVX-512 F.
        unsafe {
            std::arch::asm!(
                "vpermt2ps {t}, {idx}, {b}",
                t = inout(zmm_reg) t,
                idx = in(zmm_reg) idx,
                b = in(zmm_reg) b,
                options(nomem, nostack, preserves_flags),
            );
        }
        t
    }

    /// Index loaded from memory straight into the destination of `vpermi2ps`,
    /// so the destroyed operand costs a load instead of a register copy.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F, and `idx` must be readable for 16 `i32`s.
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn perm_load(idx: *const i32, a: __m512, b: __m512) -> __m512 {
        let t: __m512;
        // SAFETY: the asm reads 64 bytes at `idx` (unaligned `vmovdqu32`), which
        // the caller contract makes readable, writes only registers (`readonly`,
        // `nostack`), and needs AVX-512 F, also guaranteed by the caller.
        unsafe {
            std::arch::asm!(
                "vmovdqu32 {t}, [{p}]",
                "vpermi2ps {t}, {a}, {b}",
                t = out(zmm_reg) t,
                p = in(reg) idx,
                a = in(zmm_reg) a,
                b = in(zmm_reg) b,
                options(readonly, nostack, preserves_flags),
            );
        }
        t
    }

    /// Table half `a` loaded from memory into the destination of `vpermt2ps`.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F, and `a` must be readable for 16 floats.
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn perm_load_table(idx: __m512i, a: *const f32, b: __m512) -> __m512 {
        let t: __m512;
        // SAFETY: the asm reads 64 bytes at `a` (unaligned `vmovups`), which the
        // caller contract makes readable, writes only registers (`readonly`,
        // `nostack`), and needs AVX-512 F, also guaranteed by the caller.
        unsafe {
            std::arch::asm!(
                "vmovups {t}, [{p}]",
                "vpermt2ps {t}, {idx}, {b}",
                t = out(zmm_reg) t,
                p = in(reg) a,
                idx = in(zmm_reg) idx,
                b = in(zmm_reg) b,
                options(readonly, nostack, preserves_flags),
            );
        }
        t
    }

    /// # Safety
    /// The CPU must support AVX-512 F.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn lut_load(iters: u64, table: bool) -> f32 {
        let a = _mm512_set1_ps(1e-7);
        let b = _mm512_set1_ps(-1e-7);
        let a_mem = [1e-7f32; 16];
        let idx_mem: [[i32; 16]; 4] = std::array::from_fn(|i| [i as i32 * 7 + 3; 16]);
        let idx: [__m512i; 4] = std::array::from_fn(|i| _mm512_set1_epi32(i as i32 * 7 + 3));
        let mut acc = [_mm512_setzero_ps(); LUT_CHAINS];
        for _ in 0..iters {
            for (c, v) in acc.iter_mut().enumerate() {
                // SAFETY: `a_mem` and `idx_mem[c % 4]` are local arrays of 16
                // four-byte values, and AVX-512 F is the caller's contract.
                let t = unsafe {
                    if table {
                        perm_load_table(idx[c % 4], a_mem.as_ptr(), b)
                    } else {
                        perm_load(idx_mem[c % 4].as_ptr(), a, b)
                    }
                };
                *v = _mm512_add_ps(*v, t);
            }
        }
        acc.iter().map(|&v| _mm512_reduce_add_ps(v)).sum()
    }

    /// # Safety
    /// The CPU must support AVX-512 F.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn lut(iters: u64, mode: LutAccumulate) -> f32 {
        let a = _mm512_set1_ps(1e-7);
        let b = _mm512_set1_ps(-1e-7);
        let one = _mm512_set1_ps(1.0);
        let idx: [__m512i; 4] = std::array::from_fn(|i| _mm512_set1_epi32(i as i32 * 7 + 3));
        let mut acc = [_mm512_setzero_ps(); LUT_CHAINS];
        for _ in 0..iters {
            for (c, v) in acc.iter_mut().enumerate() {
                let t = perm(idx[c % 4], a, b);
                let fma = match mode {
                    LutAccumulate::Add => false,
                    LutAccumulate::FmaOne => true,
                    LutAccumulate::Mixed => c % 2 == 1,
                };
                *v = if fma {
                    _mm512_fmadd_ps(t, one, *v)
                } else {
                    _mm512_add_ps(*v, t)
                };
            }
        }
        acc.iter().map(|&v| _mm512_reduce_add_ps(v)).sum()
    }
    use std::arch::x86_64::*;

    /// # Safety
    /// The CPU must support AVX-512 F and VNNI.
    #[target_feature(enable = "avx512f,avx512vnni")]
    pub unsafe fn vnni(iters: u64) -> i32 {
        let a = _mm512_set1_epi8(1);
        let b = _mm512_set1_epi8(1);
        let mut acc = [_mm512_setzero_si512(); CHAINS];
        for _ in 0..iters {
            for v in acc.iter_mut() {
                // SAFETY: a register-only instruction (`nomem`, `nostack`), and
                // AVX-512 VNNI is the caller's contract.
                unsafe {
                    std::arch::asm!(
                        "vpdpbusd {acc}, {a}, {b}",
                        acc = inout(zmm_reg) *v,
                        a = in(zmm_reg) a,
                        b = in(zmm_reg) b,
                        options(pure, nomem, nostack, preserves_flags),
                    );
                }
            }
        }
        acc.iter()
            .fold(0, |s, &v| s.wrapping_add(_mm512_reduce_add_epi32(v)))
    }

    /// # Safety
    /// The CPU must support AVX-512 F.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn fma(iters: u64) -> f32 {
        let a = _mm512_set1_ps(0.999_999);
        let b = _mm512_set1_ps(1e-7);
        let mut acc = [_mm512_set1_ps(1.0); CHAINS];
        for _ in 0..iters {
            for v in acc.iter_mut() {
                *v = _mm512_fmadd_ps(*v, a, b);
            }
        }
        acc.iter().map(|&v| _mm512_reduce_add_ps(v)).sum()
    }
}

/// The AVX2 probes.
mod avx2 {
    use super::AVX2_CHAINS as CHAINS;
    use std::arch::x86_64::*;

    /// # Safety
    /// The CPU must support AVX2 and AVX-VNNI.
    #[target_feature(enable = "avx2")]
    pub unsafe fn vnni(iters: u64) -> i32 {
        let a = _mm256_set1_epi8(1);
        let b = _mm256_set1_epi8(1);
        let mut acc = [_mm256_setzero_si256(); CHAINS];
        for _ in 0..iters {
            for v in acc.iter_mut() {
                // SAFETY: a register-only instruction (`nomem`, `nostack`), and
                // AVX-VNNI is the caller's contract.
                unsafe {
                    std::arch::asm!(
                        "{{vex}} vpdpbusd {acc}, {a}, {b}",
                        acc = inout(ymm_reg) *v,
                        a = in(ymm_reg) a,
                        b = in(ymm_reg) b,
                        options(pure, nomem, nostack, preserves_flags),
                    );
                }
            }
        }
        acc.iter().fold(0, |s, &v| s.wrapping_add(hsum(v)))
    }

    /// # Safety
    /// The CPU must support AVX2.
    #[target_feature(enable = "avx2")]
    pub unsafe fn maddubs(iters: u64) -> i32 {
        let a = _mm256_set1_epi8(1);
        let b = _mm256_set1_epi8(1);
        let mut acc = [_mm256_setzero_si256(); CHAINS];
        for _ in 0..iters {
            for v in acc.iter_mut() {
                // SAFETY: register-only instructions (`nomem`, `nostack`), and
                // AVX2 is the caller's contract.
                unsafe {
                    std::arch::asm!(
                        "vpmaddubsw {t}, {a}, {b}",
                        "vpaddw {acc}, {acc}, {t}",
                        acc = inout(ymm_reg) *v,
                        t = out(ymm_reg) _,
                        a = in(ymm_reg) a,
                        b = in(ymm_reg) b,
                        options(pure, nomem, nostack, preserves_flags),
                    );
                }
            }
        }
        acc.iter().fold(0, |s, &v| s.wrapping_add(hsum(v)))
    }

    #[target_feature(enable = "avx2")]
    fn hsum(v: __m256i) -> i32 {
        let mut lanes = [0i32; 8];
        // SAFETY: `lanes` is a local array of 8 `i32`s.
        unsafe { _mm256_storeu_si256(lanes.as_mut_ptr().cast(), v) };
        lanes.iter().fold(0, |s, &x| s.wrapping_add(x))
    }

    /// # Safety
    /// The CPU must support AVX2 and FMA.
    #[target_feature(enable = "avx2,fma")]
    pub unsafe fn fma(iters: u64) -> f32 {
        let a = _mm256_set1_ps(0.999_999);
        let b = _mm256_set1_ps(1e-7);
        let mut acc = [_mm256_set1_ps(1.0); CHAINS];
        for _ in 0..iters {
            for v in acc.iter_mut() {
                *v = _mm256_fmadd_ps(*v, a, b);
            }
        }
        let mut lanes = [0.0f32; 8];
        let mut sum = 0.0;
        for v in acc {
            // SAFETY: `lanes` is a local array of 8 floats.
            unsafe { _mm256_storeu_ps(lanes.as_mut_ptr(), v) };
            sum += lanes.iter().sum::<f32>();
        }
        sum
    }
}
