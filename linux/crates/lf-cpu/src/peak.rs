//! Register-only throughput probes: the most multiply-accumulates per second a
//! core can retire with 512-bit VNNI (u8 x s8) or FP32 FMA. Used as the
//! ceiling when judging kernel efficiency and latency targets.

/// Multiply-accumulates performed by one call with `iters` iterations.
pub fn vnni_macs(iters: u64) -> u64 {
    iters * CHAINS as u64 * 64
}

pub fn fma_macs(iters: u64) -> u64 {
    iters * CHAINS as u64 * 16
}

const CHAINS: usize = 16;

/// Runs `iters` rounds of 16 independent `vpdpbusd` chains; returns a checksum.
pub fn vnni(iters: u64) -> i32 {
    assert!(crate::cpu_supported());
    unsafe { x86::vnni(iters) }
}

/// Runs `iters` rounds of 16 independent FP32 FMA chains; returns a checksum.
pub fn fma(iters: u64) -> f32 {
    assert!(crate::cpu_supported());
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
    assert!(crate::cpu_supported());
    unsafe { x86::lut(iters, mode) }
}

/// Like [`lut`] with `Add`, but the destroyed operand is reloaded from L1 for
/// every lookup instead of copied: the table half with `vpermt2ps` if `table`,
/// otherwise the index with `vpermi2ps`.
pub fn lut_load(iters: u64, table: bool) -> f32 {
    assert!(crate::cpu_supported());
    unsafe { x86::lut_load(iters, table) }
}

/// Sign-symmetric ternary lookup (the `gemm_lut` scheme): a non-destructive
/// 16-entry `vpermps` over 14 of the 27 sums of 3 inputs (one per ± pair,
/// indexed by the non-negative balanced-ternary patterns), then an FMA
/// by a per-lane ±1 sign. Two vector operations per 48 multiply-accumulate
/// equivalents, with no register copy. With `fma == false` the FMA becomes an
/// add, which isolates the permute's throughput.
pub fn lut_sym(iters: u64, fma: bool) -> f32 {
    assert!(crate::cpu_supported());
    unsafe { x86::lut_sym(iters, fma) }
}

#[cfg(target_arch = "x86_64")]
mod x86 {
    use super::{CHAINS, LUT_CHAINS, LutAccumulate};

    /// `vpermps` through asm (not `pure`) so repeated lookups are not merged.
    #[inline]
    #[target_feature(enable = "avx512f")]
    fn perm16(idx: __m512i, table: __m512) -> __m512 {
        let t: __m512;
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
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn perm_load(idx: *const i32, a: __m512, b: __m512) -> __m512 {
        let t: __m512;
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
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn perm_load_table(idx: __m512i, a: *const f32, b: __m512) -> __m512 {
        let t: __m512;
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

    #[target_feature(enable = "avx512f,avx512vnni")]
    pub unsafe fn vnni(iters: u64) -> i32 {
        let a = _mm512_set1_epi8(1);
        let b = _mm512_set1_epi8(1);
        let mut acc = [_mm512_setzero_si512(); CHAINS];
        for _ in 0..iters {
            for v in acc.iter_mut() {
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
