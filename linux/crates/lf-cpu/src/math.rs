//! AVX-512 and AVX2 `exp`, `sigmoid` and `tanh` at FP32 accuracy (Cephes
//! polynomials).

#[cfg(target_arch = "x86_64")]
pub(crate) mod simd {
    use std::arch::x86_64::*;

    /// e^x, about 1 ulp; inputs clamped to the finite f32 range.
    #[inline]
    #[target_feature(enable = "avx512f")]
    pub fn exp_ps(x: __m512) -> __m512 {
        let x = _mm512_min_ps(
            _mm512_max_ps(x, _mm512_set1_ps(-87.3)),
            _mm512_set1_ps(88.3),
        );
        let n = _mm512_roundscale_ps::<{ _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC }>(
            _mm512_mul_ps(x, _mm512_set1_ps(std::f32::consts::LOG2_E)),
        );
        let r = _mm512_fnmadd_ps(n, _mm512_set1_ps(0.693_359_4), x);
        let r = _mm512_fnmadd_ps(n, _mm512_set1_ps(-2.121_944_4e-4), r);
        let mut p = _mm512_set1_ps(1.987_569_1e-4);
        for c in [
            1.398_199_9e-3,
            8.333_452e-3,
            4.166_579_6e-2,
            1.666_666_5e-1,
            5e-1,
        ] {
            p = _mm512_fmadd_ps(p, r, _mm512_set1_ps(c));
        }
        let y = _mm512_fmadd_ps(
            p,
            _mm512_mul_ps(r, r),
            _mm512_add_ps(r, _mm512_set1_ps(1.0)),
        );
        _mm512_scalef_ps(y, n)
    }

    #[inline]
    #[target_feature(enable = "avx512f")]
    pub fn sigmoid_ps(x: __m512) -> __m512 {
        let one = _mm512_set1_ps(1.0);
        let e = exp_ps(_mm512_sub_ps(_mm512_setzero_ps(), x));
        _mm512_div_ps(one, _mm512_add_ps(one, e))
    }

    /// Odd polynomial below |x| = 0.625, `1 - 2 / (e^2|x| + 1)` above.
    #[inline]
    #[target_feature(enable = "avx512f")]
    pub fn tanh_ps(x: __m512) -> __m512 {
        let ax = _mm512_abs_ps(x);
        let z = _mm512_mul_ps(x, x);
        let mut p = _mm512_set1_ps(-5.704_988_7e-3);
        for c in [2.063_909e-2, -5.373_971_6e-2, 1.333_144_2e-1, -3.333_328e-1] {
            p = _mm512_fmadd_ps(p, z, _mm512_set1_ps(c));
        }
        let small = _mm512_fmadd_ps(_mm512_mul_ps(p, z), x, x);
        let one = _mm512_set1_ps(1.0);
        let e = exp_ps(_mm512_add_ps(ax, ax));
        let big = _mm512_sub_ps(
            one,
            _mm512_div_ps(_mm512_set1_ps(2.0), _mm512_add_ps(e, one)),
        );
        // Restore the sign of x on the large branch.
        let sign = _mm512_and_si512(_mm512_castps_si512(x), _mm512_set1_epi32(i32::MIN));
        let big = _mm512_castsi512_ps(_mm512_or_si512(_mm512_castps_si512(big), sign));
        let use_small = _mm512_cmp_ps_mask::<_CMP_LT_OQ>(ax, _mm512_set1_ps(0.625));
        _mm512_mask_blend_ps(use_small, big, small)
    }
}

/// The same functions on 8-lane AVX2 vectors: the operations of [`simd`] in
/// the same order, with `scalef` replaced by a multiply by `2^n` built from its
/// exponent bits (`n` stays in `-126..=127` after the clamp, so `2^n` is exact
/// and both round the same product once).
#[cfg(target_arch = "x86_64")]
pub(crate) mod simd256 {
    use std::arch::x86_64::*;

    /// e^x, about 1 ulp; inputs clamped to the finite f32 range.
    #[inline]
    #[target_feature(enable = "avx2,fma")]
    pub fn exp_ps(x: __m256) -> __m256 {
        let x = _mm256_min_ps(
            _mm256_max_ps(x, _mm256_set1_ps(-87.3)),
            _mm256_set1_ps(88.3),
        );
        let n = _mm256_round_ps::<{ _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC }>(
            _mm256_mul_ps(x, _mm256_set1_ps(std::f32::consts::LOG2_E)),
        );
        let r = _mm256_fnmadd_ps(n, _mm256_set1_ps(0.693_359_4), x);
        let r = _mm256_fnmadd_ps(n, _mm256_set1_ps(-2.121_944_4e-4), r);
        let mut p = _mm256_set1_ps(1.987_569_1e-4);
        for c in [
            1.398_199_9e-3,
            8.333_452e-3,
            4.166_579_6e-2,
            1.666_666_5e-1,
            5e-1,
        ] {
            p = _mm256_fmadd_ps(p, r, _mm256_set1_ps(c));
        }
        let y = _mm256_fmadd_ps(
            p,
            _mm256_mul_ps(r, r),
            _mm256_add_ps(r, _mm256_set1_ps(1.0)),
        );
        let bits = _mm256_add_epi32(_mm256_cvtps_epi32(n), _mm256_set1_epi32(127));
        _mm256_mul_ps(y, _mm256_castsi256_ps(_mm256_slli_epi32::<23>(bits)))
    }

    #[inline]
    #[target_feature(enable = "avx2,fma")]
    pub fn sigmoid_ps(x: __m256) -> __m256 {
        let one = _mm256_set1_ps(1.0);
        let e = exp_ps(_mm256_sub_ps(_mm256_setzero_ps(), x));
        _mm256_div_ps(one, _mm256_add_ps(one, e))
    }

    /// Odd polynomial below |x| = 0.625, `1 - 2 / (e^2|x| + 1)` above.
    #[inline]
    #[target_feature(enable = "avx2,fma")]
    pub fn tanh_ps(x: __m256) -> __m256 {
        let sign_bit = _mm256_castsi256_ps(_mm256_set1_epi32(i32::MIN));
        let ax = _mm256_andnot_ps(sign_bit, x);
        let z = _mm256_mul_ps(x, x);
        let mut p = _mm256_set1_ps(-5.704_988_7e-3);
        for c in [2.063_909e-2, -5.373_971_6e-2, 1.333_144_2e-1, -3.333_328e-1] {
            p = _mm256_fmadd_ps(p, z, _mm256_set1_ps(c));
        }
        let small = _mm256_fmadd_ps(_mm256_mul_ps(p, z), x, x);
        let one = _mm256_set1_ps(1.0);
        let e = exp_ps(_mm256_add_ps(ax, ax));
        let big = _mm256_sub_ps(
            one,
            _mm256_div_ps(_mm256_set1_ps(2.0), _mm256_add_ps(e, one)),
        );
        // Restore the sign of x on the large branch.
        let big = _mm256_or_ps(big, _mm256_and_ps(x, sign_bit));
        let use_small = _mm256_cmp_ps::<_CMP_LT_OQ>(ax, _mm256_set1_ps(0.625));
        _mm256_blendv_ps(big, small, use_small)
    }

    /// Sum of the 16 lanes of `lo` (lanes 0..8) and `hi` (8..16), added in
    /// the order `_mm512_reduce_add_ps` adds a 16-lane vector: halves, then
    /// quarters, then pairs, so AVX2 reductions round as the AVX-512 ones do.
    #[inline]
    #[target_feature(enable = "avx2")]
    pub fn hsum16(lo: __m256, hi: __m256) -> f32 {
        let v = _mm256_add_ps(lo, hi);
        let s = _mm_add_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps::<1>(v));
        let s = _mm_add_ps(s, _mm_movehl_ps(s, s));
        _mm_cvtss_f32(_mm_add_ss(s, _mm_movehdup_ps(s)))
    }

    /// Largest of the 8 lanes (no NaNs).
    #[inline]
    #[target_feature(enable = "avx2")]
    pub fn hmax(v: __m256) -> f32 {
        let s = _mm_max_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps::<1>(v));
        let s = _mm_max_ps(s, _mm_movehl_ps(s, s));
        _mm_cvtss_f32(_mm_max_ss(s, _mm_movehdup_ps(s)))
    }
}

#[cfg(all(test, target_arch = "x86_64"))]
mod tests {
    use crate::Tier;
    use std::arch::x86_64::*;

    #[derive(Clone, Copy)]
    enum F {
        Exp,
        Sigmoid,
        Tanh,
    }

    /// `f` of every value in `xs`, on the tier's vectors.
    fn eval(tier: Tier, f: F, xs: &[f32]) -> Vec<f32> {
        let width = match tier {
            Tier::Avx512 => 16,
            Tier::Avx2 { .. } => 8,
        };
        let mut out = vec![0.0; xs.len()];
        for (i, chunk) in xs.chunks(width).enumerate() {
            let mut lane = [0.0f32; 16];
            lane[..chunk.len()].copy_from_slice(chunk);
            let mut res = [0.0f32; 16];
            // SAFETY: `lane` and `res` are local arrays of 16 floats, and
            // `tier` comes from `Tier::available()`, so the CPU has the
            // features of the functions and intrinsics used for it.
            unsafe {
                match tier {
                    Tier::Avx512 => {
                        use super::simd::*;
                        let g: unsafe fn(__m512) -> __m512 = match f {
                            F::Exp => exp_ps,
                            F::Sigmoid => sigmoid_ps,
                            F::Tanh => tanh_ps,
                        };
                        _mm512_storeu_ps(res.as_mut_ptr(), g(_mm512_loadu_ps(lane.as_ptr())));
                    }
                    Tier::Avx2 { .. } => {
                        use super::simd256::*;
                        let g: unsafe fn(__m256) -> __m256 = match f {
                            F::Exp => exp_ps,
                            F::Sigmoid => sigmoid_ps,
                            F::Tanh => tanh_ps,
                        };
                        _mm256_storeu_ps(res.as_mut_ptr(), g(_mm256_loadu_ps(lane.as_ptr())));
                    }
                }
            }
            out[i * width..i * width + chunk.len()].copy_from_slice(&res[..chunk.len()]);
        }
        out
    }

    fn sweep() -> Vec<f32> {
        (-40_000..=40_000).map(|i| i as f32 * 5e-4).collect()
    }

    #[test]
    fn accurate_against_f64() {
        for tier in Tier::available() {
            let xs = sweep();
            let exp = eval(tier, F::Exp, &xs);
            let sig = eval(tier, F::Sigmoid, &xs);
            let tanh = eval(tier, F::Tanh, &xs);
            for (i, &x) in xs.iter().enumerate() {
                let x64 = x as f64;
                let e = x64.exp();
                assert!(((exp[i] as f64 - e) / e).abs() < 3e-7, "{tier} exp({x})");
                let s = 1.0 / (1.0 + (-x64).exp());
                assert!((sig[i] as f64 - s).abs() < 2e-7, "{tier} sigmoid({x})");
                let t = x64.tanh();
                assert!((tanh[i] as f64 - t).abs() < 2e-7, "{tier} tanh({x}) abs");
                if x.abs() < 0.625 && x != 0.0 {
                    assert!(
                        ((tanh[i] as f64 - t) / t).abs() < 3e-7,
                        "{tier} tanh({x}) rel"
                    );
                }
            }
            // Saturation stays finite and exact at the ends.
            let ends = eval(tier, F::Sigmoid, &[-200.0, 200.0]);
            assert!(
                ends[0] >= 0.0 && ends[0] < 1e-30 && ends[1] == 1.0,
                "{tier}"
            );
            assert_eq!(
                eval(tier, F::Tanh, &[-50.0, 50.0]),
                vec![-1.0, 1.0],
                "{tier}"
            );
        }
    }
}
