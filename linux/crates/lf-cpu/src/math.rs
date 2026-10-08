//! AVX-512 `exp`, `sigmoid` and `tanh` at FP32 accuracy (Cephes polynomials).

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

#[cfg(test)]
mod tests {
    use super::simd::*;
    use std::arch::x86_64::*;

    fn eval(f: unsafe fn(__m512) -> __m512, xs: &[f32]) -> Vec<f32> {
        let mut out = vec![0.0; xs.len()];
        for (i, chunk) in xs.chunks(16).enumerate() {
            let mut lane = [0.0f32; 16];
            lane[..chunk.len()].copy_from_slice(chunk);
            let mut res = [0.0f32; 16];
            unsafe { _mm512_storeu_ps(res.as_mut_ptr(), f(_mm512_loadu_ps(lane.as_ptr()))) };
            out[i * 16..i * 16 + chunk.len()].copy_from_slice(&res[..chunk.len()]);
        }
        out
    }

    fn sweep() -> Vec<f32> {
        (-40_000..=40_000).map(|i| i as f32 * 5e-4).collect()
    }

    #[test]
    fn accurate_against_f64() {
        if !crate::cpu_supported() {
            return;
        }
        let xs = sweep();
        let exp = eval(exp_ps, &xs);
        let sig = eval(sigmoid_ps, &xs);
        let tanh = eval(tanh_ps, &xs);
        for (i, &x) in xs.iter().enumerate() {
            let x64 = x as f64;
            let e = x64.exp();
            assert!(((exp[i] as f64 - e) / e).abs() < 3e-7, "exp({x})");
            let s = 1.0 / (1.0 + (-x64).exp());
            assert!((sig[i] as f64 - s).abs() < 2e-7, "sigmoid({x})");
            let t = x64.tanh();
            assert!((tanh[i] as f64 - t).abs() < 2e-7, "tanh({x}) abs");
            if x.abs() < 0.625 && x != 0.0 {
                assert!(((tanh[i] as f64 - t) / t).abs() < 3e-7, "tanh({x}) rel");
            }
        }
        // Saturation stays finite and exact at the ends.
        let ends = eval(sigmoid_ps, &[-200.0, 200.0]);
        assert!(ends[0] >= 0.0 && ends[0] < 1e-30 && ends[1] == 1.0);
        assert_eq!(eval(tanh_ps, &[-50.0, 50.0]), vec![-1.0, 1.0]);
    }
}
