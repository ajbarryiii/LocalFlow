//! Register-only throughput probes: the most multiply-accumulates per second a
//! core can retire with 512-bit VNNI (u8 x s8) or FP32 FMA, and the AVX2
//! tier's counterparts (256-bit AVX-VNNI, `vpmaddubsw` + `vpaddw`, FMA). Used
//! as the ceiling when judging kernel efficiency and latency targets. Each
//! probe panics if the CPU lacks its tier.

#![deny(clippy::undocumented_unsafe_blocks, clippy::missing_safety_doc)]

use lf_cpu::Tier;

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

/// The AVX-512 probes.
mod x86 {
    use super::CHAINS;
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
