//! Vectorized elementwise and normalization operations on row-major `[rows][d]`
//! activations, parallel over rows. Feature widths must be multiples of 16.

use crate::{SendPtr, ThreadPool, Tier, split_range};

/// Checks the width and returns the pool's tier (before any pool job, where
/// a panic aborts).
fn check_width(pool: &ThreadPool, d: usize) -> Tier {
    assert!(
        d > 0 && d.is_multiple_of(16),
        "width must be a positive multiple of 16"
    );
    pool.tier()
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
        // SAFETY: `r < rows = data.len() / row_len`, so the row lies in `data`.
        // `rows_parallel` calls this once per row, so rows are disjoint; `T:
        // Send` lets another thread own one, and `data` stays mutably borrowed
        // until `pool.run` returns.
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
    let tier = check_width(pool, d);
    let n = crate::size(rows, d);
    assert!(x.len() >= n && out.len() >= n && gamma.len() >= d && beta.len() >= d);
    let op = SendPtr(out.as_mut_ptr());
    rows_parallel(pool, rows, &|r| {
        let (xr, g, b) = (x[r * d..].as_ptr(), gamma.as_ptr(), beta.as_ptr());
        match tier {
            // SAFETY: the pool's tier (AVX-512 F) is supported and `d % 16 ==
            // 0` (`check_width`). Row `r < rows` of `x` and `out` (`rows * d`,
            // checked) and `d` values of `gamma`/`beta` are in bounds, and each
            // output row is written by one thread.
            #[cfg(target_arch = "x86_64")]
            Tier::Avx512 => unsafe { x86::layer_norm_row(xr, d, g, b, op.get().add(r * d)) },
            // SAFETY: as above, with AVX2 and FMA.
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { .. } => unsafe { avx2::layer_norm_row(xr, d, g, b, op.get().add(r * d)) },
        }
    });
}

/// `x += s * y` over `rows * d` values.
pub fn add_scaled(pool: &ThreadPool, x: &mut [f32], y: &[f32], rows: usize, d: usize, s: f32) {
    let tier = check_width(pool, d);
    let n = crate::size(rows, d);
    assert!(x.len() >= n && y.len() >= n);
    let xp = SendPtr(x.as_mut_ptr());
    // Row `r < rows` of `x` and `y` (`rows * d`, checked) is in bounds, `x`
    // and `y` cannot overlap (`&mut` and `&`), and each row of `x` is written
    // by one thread.
    rows_parallel(pool, rows, &|r| match tier {
        // SAFETY: the pool's tier (AVX-512 F) is supported, `d % 16 == 0`
        // (`check_width`), and the row is in bounds and exclusive (above).
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { x86::add_scaled(xp.get().add(r * d), y[r * d..].as_ptr(), d, s) },
        // SAFETY: as above, with AVX2 and FMA.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe {
            avx2::add_scaled(xp.get().add(r * d), y[r * d..].as_ptr(), d, s)
        },
    });
}

/// `x = x * sigmoid(x)` in place.
pub fn silu(pool: &ThreadPool, x: &mut [f32], rows: usize, d: usize) {
    let tier = check_width(pool, d);
    assert!(x.len() >= crate::size(rows, d));
    let xp = SendPtr(x.as_mut_ptr());
    rows_parallel(pool, rows, &|r| match tier {
        // SAFETY: the pool's tier (AVX-512 F) is supported and `d % 16 == 0`
        // (`check_width`); row `r < rows` of `x` (`rows * d`, checked) is in
        // bounds and written by one thread.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { x86::silu(xp.get().add(r * d), d) },
        // SAFETY: as above, with AVX2 and FMA.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe { avx2::silu(xp.get().add(r * d), d) },
    });
}

/// `x = max(x, 0)` in place.
pub fn relu(pool: &ThreadPool, x: &mut [f32], rows: usize, d: usize) {
    let tier = check_width(pool, d);
    assert!(x.len() >= crate::size(rows, d));
    let xp = SendPtr(x.as_mut_ptr());
    rows_parallel(pool, rows, &|r| match tier {
        // SAFETY: the pool's tier (AVX-512 F) is supported and `d % 16 == 0`
        // (`check_width`); row `r < rows` of `x` (`rows * d`, checked) is in
        // bounds and written by one thread.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { x86::relu(xp.get().add(r * d), d) },
        // SAFETY: as above, with AVX2.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe { avx2::relu(xp.get().add(r * d), d) },
    });
}

/// Gated linear unit over channels: `out[r][c] = a[r][c] * sigmoid(a[r][d + c])`
/// for `a` of width `2 * d`.
pub fn glu(pool: &ThreadPool, a: &[f32], rows: usize, d: usize, out: &mut [f32]) {
    let tier = check_width(pool, d);
    assert!(a.len() >= crate::size(crate::size(rows, 2), d) && out.len() >= crate::size(rows, d));
    let op = SendPtr(out.as_mut_ptr());
    rows_parallel(pool, rows, &|r| match tier {
        // SAFETY: the pool's tier (AVX-512 F) is supported and `d % 16 == 0`
        // (`check_width`). Row `r < rows` of `a` (`2 * d` values of `rows * 2 *
        // d`) and of `out` (`rows * d`) are in bounds (checked), and each output
        // row is written by one thread.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { x86::glu(a[r * 2 * d..].as_ptr(), d, op.get().add(r * d)) },
        // SAFETY: as above, with AVX2 and FMA.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe { avx2::glu(a[r * 2 * d..].as_ptr(), d, op.get().add(r * d)) },
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
    let tier = check_width(pool, d);
    assert!(k % 2 == 1 && w.len() >= crate::size(k, d) && bias.len() >= d);
    let n = crate::size(rows, d);
    assert!(x.len() >= n && out.len() >= n);
    let op = SendPtr(out.as_mut_ptr());
    let pad = (k - 1) / 2;
    rows_parallel(pool, rows, &|t| {
        // Only taps `j < k` whose input row `t + j - pad` is in `0..rows`.
        let taps = (0..k).filter(|&j| t + j >= pad && t + j - pad < rows);
        let (xp, wp, bp) = (x.as_ptr(), w.as_ptr(), bias.as_ptr());
        // SAFETY: `t < rows`, so row `t` of `out` (`rows * d`, checked) is in
        // bounds.
        let o = unsafe { op.get().add(t * d) };
        match tier {
            // SAFETY: the pool's tier (AVX-512 F) is supported and `d % 16 ==
            // 0` (`check_width`). The filter keeps only taps in range, so `x`
            // (`rows * d`), `w` (`k * d`) and `bias` (`d`) reads are in bounds
            // (checked). Row `t < rows` of `out` is written by one thread, and
            // `out` cannot overlap `x`.
            #[cfg(target_arch = "x86_64")]
            Tier::Avx512 => unsafe {
                x86::depthwise_row(xp, t, pad, taps, d, wp, bp, silu_after, o)
            },
            // SAFETY: as above, with AVX2 and FMA.
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { .. } => unsafe {
                avx2::depthwise_row(xp, t, pad, taps, d, wp, bp, silu_after, o)
            },
        }
    });
}

/// In-place softmax of `row * scale` at `tier` (single-threaded; any length).
pub fn softmax_scaled(tier: Tier, row: &mut [f32], scale: f32) {
    assert!(tier.supported(), "this CPU lacks the {tier} kernels");
    match tier {
        // SAFETY: AVX-512 F was asserted just above; there is no `add`.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { x86::softmax_scaled(row, None, scale) },
        // SAFETY: AVX2 and FMA were asserted just above; there is no `add`.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe { avx2::softmax_scaled(row, None, scale) },
    }
}

/// In-place softmax of `(row + add) * scale` at `tier` (single-threaded; any
/// length).
pub fn softmax_scaled_add(tier: Tier, row: &mut [f32], add: &[f32], scale: f32) {
    assert!(tier.supported(), "this CPU lacks the {tier} kernels");
    assert!(add.len() >= row.len());
    let a = Some(add.as_ptr());
    match tier {
        // SAFETY: AVX-512 F was asserted, and `add` has at least `row.len()`
        // values.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx512 => unsafe { x86::softmax_scaled(row, a, scale) },
        // SAFETY: AVX2 and FMA were asserted, and `add` has at least
        // `row.len()` values.
        #[cfg(target_arch = "x86_64")]
        Tier::Avx2 { .. } => unsafe { avx2::softmax_scaled(row, a, scale) },
    }
}

/// The AVX-512 kernels.
#[cfg(target_arch = "x86_64")]
mod x86 {
    use crate::math::simd::{exp_ps, sigmoid_ps};
    use std::arch::x86_64::*;

    /// # Safety
    /// The CPU must support AVX-512 F and `d` must be a multiple of 16. `x`,
    /// `g` and `b` must be readable for `d` floats, and `out` valid for writes
    /// of `d` floats that no other thread accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn layer_norm_row(
        x: *const f32,
        d: usize,
        g: *const f32,
        b: *const f32,
        out: *mut f32,
    ) {
        // SAFETY: every access covers floats `i..i + 16` with `i + 16 <= d`
        // (`d % 16 == 0`), inside the caller's `d`-float buffers.
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

    /// # Safety
    /// The CPU must support AVX-512 F and `d` must be a multiple of 16. `y`
    /// must be readable for `d` floats, and `x` valid for reads and writes of
    /// `d` floats that no other thread accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn add_scaled(x: *mut f32, y: *const f32, d: usize, s: f32) {
        let sv = _mm512_set1_ps(s);
        for i in (0..d).step_by(16) {
            // SAFETY: `i + 16 <= d` (`d % 16 == 0`), inside both buffers.
            unsafe {
                let r = _mm512_fmadd_ps(_mm512_loadu_ps(y.add(i)), sv, _mm512_loadu_ps(x.add(i)));
                _mm512_storeu_ps(x.add(i), r);
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX-512 F, `d` must be a multiple of 16, and `x`
    /// must be valid for reads and writes of `d` floats that no other thread
    /// accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn silu(x: *mut f32, d: usize) {
        for i in (0..d).step_by(16) {
            // SAFETY: `i + 16 <= d` (`d % 16 == 0`), inside `x`.
            unsafe {
                let v = _mm512_loadu_ps(x.add(i));
                _mm512_storeu_ps(x.add(i), _mm512_mul_ps(v, sigmoid_ps(v)));
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX-512 F, `d` must be a multiple of 16, and `x`
    /// must be valid for reads and writes of `d` floats that no other thread
    /// accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn relu(x: *mut f32, d: usize) {
        let z = _mm512_setzero_ps();
        for i in (0..d).step_by(16) {
            // SAFETY: `i + 16 <= d` (`d % 16 == 0`), inside `x`.
            unsafe { _mm512_storeu_ps(x.add(i), _mm512_max_ps(_mm512_loadu_ps(x.add(i)), z)) };
        }
    }

    /// # Safety
    /// The CPU must support AVX-512 F and `d` must be a multiple of 16. `a`
    /// must be readable for `2 * d` floats, and `out` valid for writes of `d`
    /// floats that no other thread accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn glu(a: *const f32, d: usize, out: *mut f32) {
        for i in (0..d).step_by(16) {
            // SAFETY: `i + 16 <= d` (`d % 16 == 0`), so `a` reads stay below
            // `2 * d` and `out` writes below `d`.
            unsafe {
                let v = _mm512_loadu_ps(a.add(i));
                let gate = sigmoid_ps(_mm512_loadu_ps(a.add(d + i)));
                _mm512_storeu_ps(out.add(i), _mm512_mul_ps(v, gate));
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX-512 F and `d` must be a multiple of 16. For
    /// every tap `j` that `taps` yields, `t + j >= pad`, and row `t + j - pad`
    /// of `x` (`d` floats, stride `d`) and `w[j * d..][..d]` must be readable.
    /// `bias` must be readable for `d` floats, and `out` valid for writes of
    /// `d` floats that no other thread accesses.
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
            // SAFETY: `i + 16 <= d` (`d % 16 == 0`), and every tap's `x` row and
            // `w` row are readable (caller contract).
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
    ///
    /// # Safety
    /// The CPU must support AVX-512 F, and `add`, if given, must be readable
    /// for `row.len()` floats.
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
        // SAFETY: every access starts at `i < n` and is masked to lanes below
        // `n = row.len()`, inside `row` and `add` (caller contract); masked-off
        // lanes are not accessed.
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

/// The AVX2 kernels: the AVX-512 ones 8 lanes at a time (reductions sum 8
/// partial sums instead of 16, so results differ in rounding only).
#[cfg(target_arch = "x86_64")]
mod avx2 {
    use crate::math::simd256::{exp_ps, hmax, hsum, sigmoid_ps};
    use std::arch::x86_64::*;

    /// # Safety
    /// The CPU must support AVX2 and FMA and `d` must be a multiple of 8. `x`,
    /// `g` and `b` must be readable for `d` floats, and `out` valid for writes
    /// of `d` floats that no other thread accesses.
    #[target_feature(enable = "avx2,fma")]
    pub unsafe fn layer_norm_row(
        x: *const f32,
        d: usize,
        g: *const f32,
        b: *const f32,
        out: *mut f32,
    ) {
        // SAFETY: every access covers floats `i..i + 8` with `i + 8 <= d`
        // (`d % 8 == 0`), inside the caller's `d`-float buffers.
        unsafe {
            let mut s = _mm256_setzero_ps();
            for i in (0..d).step_by(8) {
                s = _mm256_add_ps(s, _mm256_loadu_ps(x.add(i)));
            }
            let mean = hsum(s) / d as f32;
            let mv = _mm256_set1_ps(mean);
            let mut v = _mm256_setzero_ps();
            for i in (0..d).step_by(8) {
                let c = _mm256_sub_ps(_mm256_loadu_ps(x.add(i)), mv);
                v = _mm256_fmadd_ps(c, c, v);
            }
            let var = hsum(v) / d as f32;
            let inv = _mm256_set1_ps(1.0 / (var + 1e-5).sqrt());
            for i in (0..d).step_by(8) {
                let c = _mm256_mul_ps(_mm256_sub_ps(_mm256_loadu_ps(x.add(i)), mv), inv);
                let y = _mm256_fmadd_ps(c, _mm256_loadu_ps(g.add(i)), _mm256_loadu_ps(b.add(i)));
                _mm256_storeu_ps(out.add(i), y);
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX2 and FMA and `d` must be a multiple of 8. `y`
    /// must be readable for `d` floats, and `x` valid for reads and writes of
    /// `d` floats that no other thread accesses.
    #[target_feature(enable = "avx2,fma")]
    pub unsafe fn add_scaled(x: *mut f32, y: *const f32, d: usize, s: f32) {
        let sv = _mm256_set1_ps(s);
        for i in (0..d).step_by(8) {
            // SAFETY: `i + 8 <= d` (`d % 8 == 0`), inside both buffers.
            unsafe {
                let r = _mm256_fmadd_ps(_mm256_loadu_ps(y.add(i)), sv, _mm256_loadu_ps(x.add(i)));
                _mm256_storeu_ps(x.add(i), r);
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX2 and FMA, `d` must be a multiple of 8, and `x`
    /// must be valid for reads and writes of `d` floats that no other thread
    /// accesses.
    #[target_feature(enable = "avx2,fma")]
    pub unsafe fn silu(x: *mut f32, d: usize) {
        for i in (0..d).step_by(8) {
            // SAFETY: `i + 8 <= d` (`d % 8 == 0`), inside `x`.
            unsafe {
                let v = _mm256_loadu_ps(x.add(i));
                _mm256_storeu_ps(x.add(i), _mm256_mul_ps(v, sigmoid_ps(v)));
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX2, `d` must be a multiple of 8, and `x` must be
    /// valid for reads and writes of `d` floats that no other thread accesses.
    #[target_feature(enable = "avx2")]
    pub unsafe fn relu(x: *mut f32, d: usize) {
        let z = _mm256_setzero_ps();
        for i in (0..d).step_by(8) {
            // SAFETY: `i + 8 <= d` (`d % 8 == 0`), inside `x`.
            unsafe { _mm256_storeu_ps(x.add(i), _mm256_max_ps(_mm256_loadu_ps(x.add(i)), z)) };
        }
    }

    /// # Safety
    /// The CPU must support AVX2 and FMA and `d` must be a multiple of 8. `a`
    /// must be readable for `2 * d` floats, and `out` valid for writes of `d`
    /// floats that no other thread accesses.
    #[target_feature(enable = "avx2,fma")]
    pub unsafe fn glu(a: *const f32, d: usize, out: *mut f32) {
        for i in (0..d).step_by(8) {
            // SAFETY: `i + 8 <= d` (`d % 8 == 0`), so `a` reads stay below
            // `2 * d` and `out` writes below `d`.
            unsafe {
                let v = _mm256_loadu_ps(a.add(i));
                let gate = sigmoid_ps(_mm256_loadu_ps(a.add(d + i)));
                _mm256_storeu_ps(out.add(i), _mm256_mul_ps(v, gate));
            }
        }
    }

    /// # Safety
    /// The CPU must support AVX2 and FMA and `d` must be a multiple of 8. For
    /// every tap `j` that `taps` yields, `t + j >= pad`, and row `t + j - pad`
    /// of `x` (`d` floats, stride `d`) and `w[j * d..][..d]` must be readable.
    /// `bias` must be readable for `d` floats, and `out` valid for writes of
    /// `d` floats that no other thread accesses.
    #[allow(clippy::too_many_arguments)]
    #[target_feature(enable = "avx2,fma")]
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
        for i in (0..d).step_by(8) {
            // SAFETY: `i + 8 <= d` (`d % 8 == 0`), and every tap's `x` row and
            // `w` row are readable (caller contract).
            unsafe {
                let mut acc = _mm256_loadu_ps(bias.add(i));
                for j in taps.clone() {
                    let src = x.add((t + j - pad) * d + i);
                    acc = _mm256_fmadd_ps(
                        _mm256_loadu_ps(w.add(j * d + i)),
                        _mm256_loadu_ps(src),
                        acc,
                    );
                }
                if silu_after {
                    acc = _mm256_mul_ps(acc, sigmoid_ps(acc));
                }
                _mm256_storeu_ps(out.add(i), acc);
            }
        }
    }

    /// `row = softmax((row + add) * scale)`; `add` (if given) has at least `row.len()` values.
    ///
    /// # Safety
    /// The CPU must support AVX2 and FMA, and `add`, if given, must be
    /// readable for `row.len()` floats.
    #[target_feature(enable = "avx2,fma")]
    pub unsafe fn softmax_scaled(row: &mut [f32], add: Option<*const f32>, scale: f32) {
        let n = row.len();
        if n == 0 {
            return;
        }
        let p = row.as_mut_ptr();
        let sv = _mm256_set1_ps(scale);
        let lane = _mm256_setr_epi32(0, 1, 2, 3, 4, 5, 6, 7);
        // All ones in lanes below `n - i`.
        let mask = |i: usize| -> __m256i {
            let lanes = (n - i).min(8) as i32;
            _mm256_cmpgt_epi32(_mm256_set1_epi32(lanes), lane)
        };
        // SAFETY: every access starts at `i < n` and is masked to lanes below
        // `n = row.len()`, inside `row` and `add` (caller contract); masked-off
        // lanes are not accessed.
        unsafe {
            // First pass: scaled (row + add), stored back, and the running maximum.
            let mut mx = _mm256_set1_ps(f32::NEG_INFINITY);
            for i in (0..n).step_by(8) {
                let k = mask(i);
                let mut v = _mm256_maskload_ps(p.add(i), k);
                if let Some(a) = add {
                    v = _mm256_add_ps(v, _mm256_maskload_ps(a.add(i), k));
                }
                let v = _mm256_mul_ps(v, sv);
                _mm256_maskstore_ps(p.add(i), k, v);
                mx = _mm256_blendv_ps(mx, _mm256_max_ps(mx, v), _mm256_castsi256_ps(k));
            }
            let m = _mm256_set1_ps(hmax(mx));
            let mut sum = _mm256_setzero_ps();
            for i in (0..n).step_by(8) {
                let k = mask(i);
                let v = _mm256_maskload_ps(p.add(i), k);
                let e = _mm256_and_ps(exp_ps(_mm256_sub_ps(v, m)), _mm256_castsi256_ps(k));
                sum = _mm256_add_ps(sum, e);
                _mm256_maskstore_ps(p.add(i), k, e);
            }
            let inv = _mm256_set1_ps(1.0 / hsum(sum));
            for i in (0..n).step_by(8) {
                let k = mask(i);
                let v = _mm256_mul_ps(_mm256_maskload_ps(p.add(i), k), inv);
                _mm256_maskstore_ps(p.add(i), k, v);
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
        for pool in crate::tier_pools(2) {
            let tier = pool.tier();
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
                    let e =
                        (row[i] as f64 - mean) / (var + 1e-5).sqrt() * g[i] as f64 + b[i] as f64;
                    assert!((out[r * d + i] as f64 - e).abs() < 1e-5, "{tier}");
                }
            }

            let y = rand(rows * d, 8);
            let mut acc = x.clone();
            add_scaled(&pool, &mut acc, &y, rows, d, 0.5);
            for i in 0..rows * d {
                assert_eq!(acc[i], y[i].mul_add(0.5, x[i]), "{tier}");
            }
            let mut s = x.clone();
            silu(&pool, &mut s, rows, d);
            let mut r = x.clone();
            relu(&pool, &mut r, rows, d);
            for i in 0..rows * d {
                let v = x[i] as f64;
                assert!(
                    (s[i] as f64 - v / (1.0 + (-v).exp())).abs() < 1e-6,
                    "{tier}"
                );
                assert_eq!(r[i], x[i].max(0.0), "{tier}");
            }

            let a = rand(rows * 2 * d, 4);
            let mut out = vec![0.0; rows * d];
            glu(&pool, &a, rows, d, &mut out);
            for r in 0..rows {
                for i in 0..d {
                    let (v, gte) = (a[r * 2 * d + i] as f64, a[r * 2 * d + d + i] as f64);
                    let e = v / (1.0 + (-gte).exp());
                    assert!((out[r * d + i] as f64 - e).abs() < 1e-6, "{tier}");
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
                        assert!(
                            (out[t * d + c] as f64 - s).abs() < 1e-5,
                            "{tier} t={t} c={c}"
                        );
                    }
                }
            }

            for n in [1, 5, 8, 16, 37] {
                let add = rand(n, 100 + n as u64);
                for with_add in [false, true] {
                    let mut row = rand(n, 7 + n as u64);
                    let orig: Vec<f64> = row
                        .iter()
                        .zip(&add)
                        .map(|(&v, &a)| (v + if with_add { a } else { 0.0 }) as f64 * 0.5)
                        .collect();
                    if with_add {
                        softmax_scaled_add(tier, &mut row, &add, 0.5);
                    } else {
                        softmax_scaled(tier, &mut row, 0.5);
                    }
                    let m = orig.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                    let z: f64 = orig.iter().map(|&v| (v - m).exp()).sum();
                    for i in 0..n {
                        let e = (orig[i] - m).exp() / z;
                        assert!((row[i] as f64 - e).abs() < 1e-6, "{tier} n={n}");
                    }
                }
            }
        }
    }
}
