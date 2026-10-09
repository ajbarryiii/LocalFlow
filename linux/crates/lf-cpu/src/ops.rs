//! Vectorized elementwise and normalization operations on row-major `[rows][d]`
//! activations, parallel over rows. Feature widths must be multiples of 16.

use crate::{SendPtr, ThreadPool, split_range};

fn check_width(d: usize) {
    assert!(
        d > 0 && d.is_multiple_of(16),
        "width must be a positive multiple of 16"
    );
    assert!(crate::cpu_supported(), "AVX-512 required");
}

/// Runs `f(row)` for every row in parallel; rows are disjoint.
pub fn rows_parallel(pool: &ThreadPool, rows: usize, f: &(dyn Fn(usize) + Sync)) {
    let threads = pool.threads();
    pool.run(&|idx| {
        for r in split_range(rows, threads, idx) {
            f(r);
        }
    });
}

/// Calls `f(row_index, row)` for every `row_len`-sized row of `data` in
/// parallel. Rows are disjoint, so this is safe to call with any `f`.
pub fn for_each_row_mut<T: Send>(
    pool: &ThreadPool,
    data: &mut [T],
    row_len: usize,
    f: &(dyn Fn(usize, &mut [T]) + Sync),
) {
    assert!(row_len > 0 && data.len().is_multiple_of(row_len));
    // Rows are carved from `data` itself, so no size can overflow here.
    let rows = data.len() / row_len;
    let p = SendPtr(data.as_mut_ptr());
    rows_parallel(pool, rows, &|r| {
        let row = unsafe { std::slice::from_raw_parts_mut(p.get().add(r * row_len), row_len) };
        f(r, row);
    });
}

/// `out = LayerNorm(x) * gamma + beta` per row, eps 1e-5 (biased variance).
#[allow(clippy::too_many_arguments)]
pub fn layer_norm(
    pool: &ThreadPool,
    x: &[f32],
    rows: usize,
    d: usize,
    gamma: &[f32],
    beta: &[f32],
    out: &mut [f32],
) {
    check_width(d);
    let n = crate::size(rows, d);
    assert!(x.len() >= n && out.len() >= n && gamma.len() >= d && beta.len() >= d);
    let op = SendPtr(out.as_mut_ptr());
    rows_parallel(pool, rows, &|r| unsafe {
        x86::layer_norm_row(
            x[r * d..].as_ptr(),
            d,
            gamma.as_ptr(),
            beta.as_ptr(),
            op.get().add(r * d),
        )
    });
}

/// `x += s * y` over `rows * d` values.
pub fn add_scaled(pool: &ThreadPool, x: &mut [f32], y: &[f32], rows: usize, d: usize, s: f32) {
    check_width(d);
    let n = crate::size(rows, d);
    assert!(x.len() >= n && y.len() >= n);
    let xp = SendPtr(x.as_mut_ptr());
    rows_parallel(pool, rows, &|r| unsafe {
        x86::add_scaled(xp.get().add(r * d), y[r * d..].as_ptr(), d, s)
    });
}

/// `x = x * sigmoid(x)` in place.
pub fn silu(pool: &ThreadPool, x: &mut [f32], rows: usize, d: usize) {
    check_width(d);
    assert!(x.len() >= crate::size(rows, d));
    let xp = SendPtr(x.as_mut_ptr());
    rows_parallel(pool, rows, &|r| unsafe {
        x86::silu(xp.get().add(r * d), d)
    });
}

/// `x = max(x, 0)` in place.
pub fn relu(pool: &ThreadPool, x: &mut [f32], rows: usize, d: usize) {
    check_width(d);
    assert!(x.len() >= crate::size(rows, d));
    let xp = SendPtr(x.as_mut_ptr());
    rows_parallel(pool, rows, &|r| unsafe {
        x86::relu(xp.get().add(r * d), d)
    });
}

/// Gated linear unit over channels: `out[r][c] = a[r][c] * sigmoid(a[r][d + c])`
/// for `a` of width `2 * d`.
pub fn glu(pool: &ThreadPool, a: &[f32], rows: usize, d: usize, out: &mut [f32]) {
    check_width(d);
    assert!(a.len() >= crate::size(crate::size(rows, 2), d) && out.len() >= crate::size(rows, d));
    let op = SendPtr(out.as_mut_ptr());
    rows_parallel(pool, rows, &|r| unsafe {
        x86::glu(a[r * 2 * d..].as_ptr(), d, op.get().add(r * d))
    });
}

/// Depthwise convolution over time (rows) with zero padding `(k - 1) / 2`, per
/// channel weights `w` as `[k][d]` and bias `[d]`, optionally followed by SiLU.
#[allow(clippy::too_many_arguments)]
pub fn depthwise_time(
    pool: &ThreadPool,
    x: &[f32],
    rows: usize,
    d: usize,
    w: &[f32],
    k: usize,
    bias: &[f32],
    silu_after: bool,
    out: &mut [f32],
) {
    check_width(d);
    assert!(k % 2 == 1 && w.len() >= crate::size(k, d) && bias.len() >= d);
    let n = crate::size(rows, d);
    assert!(x.len() >= n && out.len() >= n);
    let op = SendPtr(out.as_mut_ptr());
    let pad = (k - 1) / 2;
    rows_parallel(pool, rows, &|t| unsafe {
        let taps = (0..k).filter(|&j| t + j >= pad && t + j - pad < rows);
        x86::depthwise_row(
            x.as_ptr(),
            t,
            pad,
            taps,
            d,
            w.as_ptr(),
            bias.as_ptr(),
            silu_after,
            op.get().add(t * d),
        )
    });
}

/// In-place softmax of `row * scale` (single-threaded; any length).
pub fn softmax_scaled(row: &mut [f32], scale: f32) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    unsafe { x86::softmax_scaled(row, None, scale) }
}

/// In-place softmax of `(row + add) * scale` (single-threaded; any length).
pub fn softmax_scaled_add(row: &mut [f32], add: &[f32], scale: f32) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    assert!(add.len() >= row.len());
    unsafe { x86::softmax_scaled(row, Some(add.as_ptr()), scale) }
}

#[cfg(target_arch = "x86_64")]
mod x86 {
    use crate::math::simd::{exp_ps, sigmoid_ps};
    use std::arch::x86_64::*;

    #[target_feature(enable = "avx512f")]
    pub unsafe fn layer_norm_row(
        x: *const f32,
        d: usize,
        g: *const f32,
        b: *const f32,
        out: *mut f32,
    ) {
        unsafe {
            let mut s = _mm512_setzero_ps();
            for i in (0..d).step_by(16) {
                s = _mm512_add_ps(s, _mm512_loadu_ps(x.add(i)));
            }
            let mean = _mm512_reduce_add_ps(s) / d as f32;
            let mv = _mm512_set1_ps(mean);
            let mut v = _mm512_setzero_ps();
            for i in (0..d).step_by(16) {
                let c = _mm512_sub_ps(_mm512_loadu_ps(x.add(i)), mv);
                v = _mm512_fmadd_ps(c, c, v);
            }
            let var = _mm512_reduce_add_ps(v) / d as f32;
            let inv = _mm512_set1_ps(1.0 / (var + 1e-5).sqrt());
            for i in (0..d).step_by(16) {
                let c = _mm512_mul_ps(_mm512_sub_ps(_mm512_loadu_ps(x.add(i)), mv), inv);
                let y = _mm512_fmadd_ps(c, _mm512_loadu_ps(g.add(i)), _mm512_loadu_ps(b.add(i)));
                _mm512_storeu_ps(out.add(i), y);
            }
        }
    }

    #[target_feature(enable = "avx512f")]
    pub unsafe fn add_scaled(x: *mut f32, y: *const f32, d: usize, s: f32) {
        let sv = _mm512_set1_ps(s);
        for i in (0..d).step_by(16) {
            unsafe {
                let r = _mm512_fmadd_ps(_mm512_loadu_ps(y.add(i)), sv, _mm512_loadu_ps(x.add(i)));
                _mm512_storeu_ps(x.add(i), r);
            }
        }
    }

    #[target_feature(enable = "avx512f")]
    pub unsafe fn silu(x: *mut f32, d: usize) {
        for i in (0..d).step_by(16) {
            unsafe {
                let v = _mm512_loadu_ps(x.add(i));
                _mm512_storeu_ps(x.add(i), _mm512_mul_ps(v, sigmoid_ps(v)));
            }
        }
    }

    #[target_feature(enable = "avx512f")]
    pub unsafe fn relu(x: *mut f32, d: usize) {
        let z = _mm512_setzero_ps();
        for i in (0..d).step_by(16) {
            unsafe { _mm512_storeu_ps(x.add(i), _mm512_max_ps(_mm512_loadu_ps(x.add(i)), z)) };
        }
    }

    #[target_feature(enable = "avx512f")]
    pub unsafe fn glu(a: *const f32, d: usize, out: *mut f32) {
        for i in (0..d).step_by(16) {
            unsafe {
                let v = _mm512_loadu_ps(a.add(i));
                let gate = sigmoid_ps(_mm512_loadu_ps(a.add(d + i)));
                _mm512_storeu_ps(out.add(i), _mm512_mul_ps(v, gate));
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[target_feature(enable = "avx512f")]
    pub unsafe fn depthwise_row(
        x: *const f32,
        t: usize,
        pad: usize,
        taps: impl Iterator<Item = usize> + Clone,
        d: usize,
        w: *const f32,
        bias: *const f32,
        silu_after: bool,
        out: *mut f32,
    ) {
        for i in (0..d).step_by(16) {
            unsafe {
                let mut acc = _mm512_loadu_ps(bias.add(i));
                for j in taps.clone() {
                    let src = x.add((t + j - pad) * d + i);
                    acc = _mm512_fmadd_ps(
                        _mm512_loadu_ps(w.add(j * d + i)),
                        _mm512_loadu_ps(src),
                        acc,
                    );
                }
                if silu_after {
                    acc = _mm512_mul_ps(acc, sigmoid_ps(acc));
                }
                _mm512_storeu_ps(out.add(i), acc);
            }
        }
    }

    /// `row = softmax((row + add) * scale)`; `add` (if given) has at least `row.len()` values.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn softmax_scaled(row: &mut [f32], add: Option<*const f32>, scale: f32) {
        let n = row.len();
        if n == 0 {
            return;
        }
        let p = row.as_mut_ptr();
        let sv = _mm512_set1_ps(scale);
        let mask = |i: usize| -> __mmask16 {
            let lanes = (n - i).min(16);
            if lanes == 16 { !0 } else { (1u16 << lanes) - 1 }
        };
        unsafe {
            // First pass: scaled (row + add), stored back, and the running maximum.
            let mut mx = _mm512_set1_ps(f32::NEG_INFINITY);
            for i in (0..n).step_by(16) {
                let k = mask(i);
                let mut v = _mm512_maskz_loadu_ps(k, p.add(i));
                if let Some(a) = add {
                    v = _mm512_add_ps(v, _mm512_maskz_loadu_ps(k, a.add(i)));
                }
                let v = _mm512_mul_ps(v, sv);
                _mm512_mask_storeu_ps(p.add(i), k, v);
                mx = _mm512_mask_max_ps(mx, k, mx, v);
            }
            let m = _mm512_set1_ps(_mm512_reduce_max_ps(mx));
            let mut sum = _mm512_setzero_ps();
            for i in (0..n).step_by(16) {
                let k = mask(i);
                let v = _mm512_maskz_loadu_ps(k, p.add(i));
                let e = _mm512_maskz_mov_ps(k, exp_ps(_mm512_sub_ps(v, m)));
                sum = _mm512_add_ps(sum, e);
                _mm512_mask_storeu_ps(p.add(i), k, e);
            }
            let inv = _mm512_set1_ps(1.0 / _mm512_reduce_add_ps(sum));
            for i in (0..n).step_by(16) {
                let k = mask(i);
                let v = _mm512_mul_ps(_mm512_maskz_loadu_ps(k, p.add(i)), inv);
                _mm512_mask_storeu_ps(p.add(i), k, v);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_model::rng::SplitMix64;

    fn rand(n: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..n).map(|_| rng.next_gaussian()).collect()
    }

    #[test]
    fn overflowing_sizes_are_rejected_before_any_access() {
        let pool = ThreadPool::new(&[0]);
        let g = [0.0f32; 16];
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            layer_norm(&pool, &[], 1usize << 63, 16, &g, &g, &mut []);
        }));
        assert!(r.is_err());
    }

    #[test]
    fn ops_match_scalar() {
        if !crate::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1]);
        let (rows, d) = (7, 48);
        let x = rand(rows * d, 1);
        let (g, b) = (rand(d, 2), rand(d, 3));

        let mut out = vec![0.0; rows * d];
        layer_norm(&pool, &x, rows, d, &g, &b, &mut out);
        for r in 0..rows {
            let row = &x[r * d..(r + 1) * d];
            let mean = row.iter().map(|&v| v as f64).sum::<f64>() / d as f64;
            let var = row.iter().map(|&v| (v as f64 - mean).powi(2)).sum::<f64>() / d as f64;
            for i in 0..d {
                let e = (row[i] as f64 - mean) / (var + 1e-5).sqrt() * g[i] as f64 + b[i] as f64;
                assert!((out[r * d + i] as f64 - e).abs() < 1e-5);
            }
        }

        let a = rand(rows * 2 * d, 4);
        let mut out = vec![0.0; rows * d];
        glu(&pool, &a, rows, d, &mut out);
        for r in 0..rows {
            for i in 0..d {
                let (v, gte) = (a[r * 2 * d + i] as f64, a[r * 2 * d + d + i] as f64);
                assert!((out[r * d + i] as f64 - v / (1.0 + (-gte).exp())).abs() < 1e-6);
            }
        }

        let (k, w, bias) = (9, rand(9 * d, 5), rand(d, 6));
        for silu_after in [false, true] {
            let mut out = vec![0.0; rows * d];
            depthwise_time(&pool, &x, rows, d, &w, k, &bias, silu_after, &mut out);
            for t in 0..rows {
                for c in 0..d {
                    let mut s = bias[c] as f64;
                    for j in 0..k {
                        let src = t as isize + j as isize - 4;
                        if (0..rows as isize).contains(&src) {
                            s += w[j * d + c] as f64 * x[src as usize * d + c] as f64;
                        }
                    }
                    if silu_after {
                        s /= 1.0 + (-s).exp();
                    }
                    assert!((out[t * d + c] as f64 - s).abs() < 1e-5, "t={t} c={c}");
                }
            }
        }

        for n in [1, 5, 16, 37] {
            let add = rand(n, 100 + n as u64);
            for with_add in [false, true] {
                let mut row = rand(n, 7 + n as u64);
                let orig: Vec<f64> = row
                    .iter()
                    .zip(&add)
                    .map(|(&v, &a)| (v + if with_add { a } else { 0.0 }) as f64 * 0.5)
                    .collect();
                if with_add {
                    softmax_scaled_add(&mut row, &add, 0.5);
                } else {
                    softmax_scaled(&mut row, 0.5);
                }
                let m = orig.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                let z: f64 = orig.iter().map(|&v| (v - m).exp()).sum();
                for i in 0..n {
                    assert!((row[i] as f64 - (orig[i] - m).exp() / z).abs() < 1e-6);
                }
            }
        }
    }
}
