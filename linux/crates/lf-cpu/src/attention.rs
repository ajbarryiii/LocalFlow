//! Relative-position multi-head self-attention (NeMo `RelPositionMultiHeadAttention`,
//! Transformer-XL style), for one unmasked utterance of `t` frames.
//!
//! Per head `h` with `qu = q + bias_u[h]`, `qv = q + bias_v[h]`:
//! `score[i][j] = (qu[i] . k[j] + qv[i] . p[t - 1 - i + j]) / sqrt(dk)`, softmax
//! over `j`, then `out[i] = sum_j softmax[i][j] * v[j]`. Row `p[m]` of the
//! projected position embedding encodes relative position `t - 1 - m`, so this
//! equals NeMo's `rel_shift` of `qv * p^T`. Each block of query rows computes
//! only the window of `p` columns it needs instead of all `2t - 1`.
//!
//! The position rows can also come pre-packed ([`Positions::Packed`]): in a
//! packing for `t_max` frames, row `m` encodes relative position
//! `t_max - 1 - m`, so the rows for `t <= t_max` frames are rows
//! `t_max - t ..= t_max + t - 2`. Each position score is one lane of a dot
//! product over `dk` inputs in a fixed order, so where a row sits within its
//! panel does not change the result: packed and per-call rows give
//! bit-identical outputs.

use crate::dense::{NB, Panels, gemm_serial};
use crate::{SendPtr, ThreadPool, split_range};

/// Query rows per parallel work unit (a multiple of the 6-row micro-kernel).
const ROWS: usize = 48;

#[derive(Default)]
pub struct AttentionWorkspace {
    qu: Vec<f32>,
    qv: Vec<f32>,
    k: Vec<Panels>,
    p: Vec<Panels>,
    v: Vec<Panels>,
}

/// The projected position embedding for one attention call of `t` frames.
#[derive(Clone, Copy)]
pub enum Positions<'a> {
    /// `[2t - 1][heads * dk]` rows, packed into the workspace on every call.
    Rows(&'a [f32]),
    /// Per-head panels from [`pack_positions`]; the call uses rows
    /// `offset .. offset + 2t - 1` of each.
    Packed { heads: &'a [Panels], offset: usize },
}

/// Packs `rows` rows of a projected position embedding `p`
/// (`[rows][heads * dk]`) into one [`Panels`] per head; `out` is resized to
/// `heads` and its buffers are reused.
pub fn pack_positions(
    pool: &ThreadPool,
    p: &[f32],
    rows: usize,
    heads: usize,
    dk: usize,
    out: &mut Vec<Panels>,
) {
    // Checked here, not inside the pool job, where a panic aborts.
    assert!(heads > 0 && dk > 0 && rows > 0);
    let d = crate::size(heads, dk);
    assert!(p.len() >= crate::size(rows, d));
    out.resize_with(heads, Panels::default);
    let op = SendPtr(out.as_mut_ptr());
    let threads = pool.threads();
    pool.run(&|idx| {
        for h in split_range(heads, threads, idx) {
            // Each head's panels are written by exactly one work item.
            unsafe { (*op.get().add(h)).pack_rows(&p[h * dk..], rows, dk, d) };
        }
    });
}

/// `out` (`[t][heads * dk]`) from `q`, `k`, `v` (`[t][heads * dk]`), the projected
/// position embedding `p` (`[2t - 1][heads * dk]`) and per-head biases (`[heads][dk]`).
#[allow(clippy::too_many_arguments)]
pub fn rel_pos_attention(
    pool: &ThreadPool,
    q: &[f32],
    k: &[f32],
    v: &[f32],
    p: &[f32],
    t: usize,
    heads: usize,
    dk: usize,
    bias_u: &[f32],
    bias_v: &[f32],
    ws: &mut AttentionWorkspace,
    out: &mut [f32],
) {
    rel_pos_attention_with(
        pool,
        q,
        k,
        v,
        Positions::Rows(p),
        t,
        heads,
        dk,
        bias_u,
        bias_v,
        ws,
        out,
    );
}

/// [`rel_pos_attention`] with the position embedding given either as rows or
/// as pre-packed panels.
#[allow(clippy::too_many_arguments)]
pub fn rel_pos_attention_with(
    pool: &ThreadPool,
    q: &[f32],
    k: &[f32],
    v: &[f32],
    pos: Positions<'_>,
    t: usize,
    heads: usize,
    dk: usize,
    bias_u: &[f32],
    bias_v: &[f32],
    ws: &mut AttentionWorkspace,
    out: &mut [f32],
) {
    assert!(crate::cpu_supported(), "AVX-512 required");
    assert!(t > 0 && dk > 0 && heads > 0);
    let d = crate::size(heads, dk);
    let n = crate::size(t, d);
    assert!(q.len() >= n && k.len() >= n && v.len() >= n && out.len() >= n);
    let pos_rows = crate::size(2, t) - 1;
    // Phase-1 work items per head: qu+qv, k, v, and p when packed here.
    let (raw_p, items) = match pos {
        Positions::Rows(p) => {
            assert!(p.len() >= crate::size(pos_rows, d));
            (Some(p), 4)
        }
        Positions::Packed { heads: ph, offset } => {
            assert!(ph.len() >= heads, "too few packed position heads");
            let end = offset.checked_add(pos_rows).expect("size overflow");
            for panels in &ph[..heads] {
                assert!(
                    panels.k() == dk && panels.n() >= end,
                    "packed positions do not cover the rows needed"
                );
            }
            (None, 3)
        }
    };
    assert!(bias_u.len() >= d && bias_v.len() >= d);
    // Per-thread buffers in phase 2.
    let tpad = t.div_ceil(NB) * NB;
    crate::size(ROWS, tpad + 2 * NB);
    ws.qu.resize(n, 0.0);
    ws.qv.resize(n, 0.0);
    ws.k.resize_with(heads, Panels::default);
    if raw_p.is_some() {
        ws.p.resize_with(heads, Panels::default);
    }
    ws.v.resize_with(heads, Panels::default);

    let threads = pool.threads();
    // Phase 1: per head, biased queries and packed keys, values and (for
    // per-call rows) positions.
    {
        let qu = SendPtr(ws.qu.as_mut_ptr());
        let qv = SendPtr(ws.qv.as_mut_ptr());
        let kp = SendPtr(ws.k.as_mut_ptr());
        let pp = SendPtr(ws.p.as_mut_ptr());
        let vp = SendPtr(ws.v.as_mut_ptr());
        // Work items: (head, which of qu+qv / k / v / p).
        pool.run(&|idx| {
            for item in split_range(heads * items, threads, idx) {
                let (h, what) = (item / items, item % items);
                let col = h * dk;
                // Each (head, what) item owns disjoint buffers.
                unsafe {
                    match what {
                        0 => {
                            let qu =
                                std::slice::from_raw_parts_mut(qu.get().add(h * t * dk), t * dk);
                            let qv =
                                std::slice::from_raw_parts_mut(qv.get().add(h * t * dk), t * dk);
                            for i in 0..t {
                                for c in 0..dk {
                                    let x = q[i * d + col + c];
                                    qu[i * dk + c] = x + bias_u[col + c];
                                    qv[i * dk + c] = x + bias_v[col + c];
                                }
                            }
                        }
                        1 => (*kp.get().add(h)).pack_rows(&k[col..], t, dk, d),
                        2 => (*vp.get().add(h)).pack_cols(&v[col..], t, dk, d),
                        _ => {
                            let p = raw_p.expect("only per-call rows have a fourth item");
                            (*pp.get().add(h)).pack_rows(&p[col..], pos_rows, dk, d)
                        }
                    }
                }
            }
        });
    }

    // Phase 2: (head, block of query rows) units.
    let ws = &*ws;
    let (p_heads, base): (&[Panels], usize) = match pos {
        Positions::Rows(_) => (&ws.p, 0),
        Positions::Packed { heads: ph, offset } => (ph, offset),
    };
    let blocks = t.div_ceil(ROWS);
    let scale = 1.0 / (dk as f32).sqrt();
    let op = SendPtr(out.as_mut_ptr());
    pool.run(&|idx| {
        let mut scores = vec![0.0f32; ROWS * tpad];
        // A block's window spans (m + t - 2) / NB + 2 panels at most, which is
        // at most tpad / NB + 2 for m <= ROWS < NB, at any `base`.
        let mut pos = vec![0.0f32; ROWS * (tpad + 2 * NB)];
        let mut o = vec![0.0f32; ROWS * dk];
        for unit in split_range(heads * blocks, threads, idx) {
            let (h, blk) = (unit / blocks, unit % blocks);
            let (i0, i1) = (blk * ROWS, ((blk + 1) * ROWS).min(t));
            let m = i1 - i0;
            let qu = &ws.qu[(h * t + i0) * dk..];
            let qv = &ws.qv[(h * t + i0) * dk..];
            gemm_serial(qu, m, dk, &ws.k[h], 0..ws.k[h].panels(), &mut scores, tpad);
            // Rows i0..i1 need position rows base + (t-i1 ..= 2t-2-i0).
            let p_lo = base + t - i1;
            let p_hi = base + 2 * t - 2 - i0;
            let (pp0, pp1) = (p_lo / NB, p_hi / NB + 1);
            let ldp = (pp1 - pp0) * NB;
            assert!(ldp <= tpad + 2 * NB);
            gemm_serial(qv, m, dk, &p_heads[h], pp0..pp1, &mut pos, ldp);
            for r in 0..m {
                let i = i0 + r;
                let off = base + t - 1 - i - pp0 * NB;
                let row = &mut scores[r * tpad..r * tpad + t];
                crate::ops::softmax_scaled_add(row, &pos[r * ldp + off..r * ldp + off + t], scale);
            }
            gemm_serial(&scores, m, tpad, &ws.v[h], 0..ws.v[h].panels(), &mut o, dk);
            for r in 0..m {
                // Rows i0..i1 of head h's columns belong to this unit only.
                let dst = unsafe {
                    std::slice::from_raw_parts_mut(op.get().add((i0 + r) * d + h * dk), dk)
                };
                dst.copy_from_slice(&o[r * dk..(r + 1) * dk]);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_model::rng::SplitMix64;

    fn rand(n: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..n).map(|_| rng.next_gaussian()).collect()
    }

    /// Literal NeMo formulation: full `qv * p^T`, `rel_shift`, then slice.
    #[allow(clippy::too_many_arguments)]
    fn reference(
        q: &[f32],
        k: &[f32],
        v: &[f32],
        p: &[f32],
        t: usize,
        h: usize,
        dk: usize,
        bu: &[f32],
        bv: &[f32],
    ) -> Vec<f64> {
        let d = h * dk;
        let pl = 2 * t - 1;
        let mut out = vec![0.0; t * d];
        for hh in 0..h {
            let dot = |a: &[f32], ab: &[f32], ra: usize, b: &[f32], rb: usize| -> f64 {
                (0..dk)
                    .map(|c| {
                        (a[ra * d + hh * dk + c] + ab[hh * dk + c]) as f64
                            * b[rb * d + hh * dk + c] as f64
                    })
                    .sum()
            };
            // bd before shifting: [t][pl]
            let bd: Vec<f64> = (0..t)
                .flat_map(|i| (0..pl).map(move |m| (i, m)))
                .map(|(i, m)| dot(q, bv, i, p, m))
                .collect();
            // rel_shift: pad one zero column on the left, view as [pl + 1][t], drop first row, view [t][pl].
            let mut padded = vec![0.0; t * (pl + 1)];
            for i in 0..t {
                for m in 0..pl {
                    padded[i * (pl + 1) + m + 1] = bd[i * pl + m];
                }
            }
            let shifted = &padded[t..];
            for i in 0..t {
                let mut s: Vec<f64> = (0..t)
                    .map(|j| (dot(q, bu, i, k, j) + shifted[i * pl + j]) / (dk as f64).sqrt())
                    .collect();
                let mx = s.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                let z: f64 = s.iter().map(|x| (x - mx).exp()).sum();
                s.iter_mut().for_each(|x| *x = (*x - mx).exp() / z);
                for c in 0..dk {
                    out[i * d + hh * dk + c] =
                        (0..t).map(|j| s[j] * v[j * d + hh * dk + c] as f64).sum();
                }
            }
        }
        out
    }

    #[test]
    fn matches_rel_shift_reference() {
        if !crate::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1, 2]);
        let mut ws = AttentionWorkspace::default();
        for (t, h, dk) in [(1, 1, 16), (7, 2, 32), (70, 3, 16), (131, 2, 32)] {
            let d = h * dk;
            let (q, k, v) = (rand(t * d, 1), rand(t * d, 2), rand(t * d, 3));
            let p = rand((2 * t - 1) * d, 4);
            let (bu, bv) = (rand(d, 5), rand(d, 6));
            let mut out = vec![0.0; t * d];
            rel_pos_attention(&pool, &q, &k, &v, &p, t, h, dk, &bu, &bv, &mut ws, &mut out);
            let e = reference(&q, &k, &v, &p, t, h, dk, &bu, &bv);
            for i in 0..t * d {
                assert!(
                    (out[i] as f64 - e[i]).abs() < 1e-4,
                    "t={t} at {i}: {} vs {}",
                    out[i],
                    e[i]
                );
            }
        }
    }

    /// Positions packed once for `t_max` frames give bit-identical outputs to
    /// per-call rows for every `t <= t_max`, at any panel alignment.
    #[test]
    fn packed_positions_match_rows_bit_for_bit() {
        if !crate::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1, 2]);
        let (mut ws_rows, mut ws_packed) =
            (AttentionWorkspace::default(), AttentionWorkspace::default());
        // (t_max, t): assorted lengths, then every offset alignment mod 64
        // for lengths around the 48-row query blocks.
        let mut pairs: Vec<(usize, usize)> = Vec::new();
        for t_max in [1, 64, 65, 200] {
            for t in [1, 2, 5, 47, 48, 49, 63, 64, 65, 97, 131, 200] {
                if t <= t_max {
                    pairs.push((t_max, t));
                }
            }
        }
        for t in [1, 5, 48, 49, 97] {
            pairs.extend((0..=64).map(|offset| (t + offset, t)));
        }
        for (h, dk) in [(2, 32), (1, 128)] {
            let d = h * dk;
            let (bu, bv) = (rand(d, 15), rand(d, 16));
            let mut packed = Vec::new();
            for &(t_max, t) in &pairs {
                {
                    // Row m of the big table stands for relative position t_max - 1 - m.
                    let big = rand((2 * t_max - 1) * d, 17 + t_max as u64);
                    pack_positions(&pool, &big, 2 * t_max - 1, h, dk, &mut packed);
                    let (q, k, v) = (rand(t * d, 11), rand(t * d, 12), rand(t * d, 13));
                    let offset = t_max - t;
                    let rows = &big[offset * d..(offset + 2 * t - 1) * d];
                    let mut a = vec![0.0; t * d];
                    rel_pos_attention(
                        &pool,
                        &q,
                        &k,
                        &v,
                        rows,
                        t,
                        h,
                        dk,
                        &bu,
                        &bv,
                        &mut ws_rows,
                        &mut a,
                    );
                    let mut b = vec![f32::NAN; t * d];
                    let pos = Positions::Packed {
                        heads: &packed,
                        offset,
                    };
                    rel_pos_attention_with(
                        &pool,
                        &q,
                        &k,
                        &v,
                        pos,
                        t,
                        h,
                        dk,
                        &bu,
                        &bv,
                        &mut ws_packed,
                        &mut b,
                    );
                    let same = a.iter().zip(&b).all(|(x, y)| x.to_bits() == y.to_bits());
                    assert!(same, "h={h} dk={dk} t_max={t_max} t={t}");
                }
            }
        }
    }

    /// An empty table is rejected before the pool job (where a panic aborts).
    #[test]
    #[should_panic(expected = "rows > 0")]
    fn packing_no_positions_panics_before_dispatch() {
        let pool = ThreadPool::new(&[0, 1]);
        pack_positions(&pool, &[], 0, 2, 128, &mut Vec::new());
    }

    #[test]
    #[should_panic(expected = "packed positions do not cover")]
    fn packed_positions_out_of_range_panics() {
        if !crate::cpu_supported() {
            panic!("packed positions do not cover (skipped: no AVX-512)");
        }
        let pool = ThreadPool::new(&[0]);
        let (h, dk, t) = (1, 16, 5);
        let mut packed = Vec::new();
        pack_positions(&pool, &rand(9 * dk, 1), 9, h, dk, &mut packed);
        let x = rand(t * dk, 2);
        let mut out = vec![0.0; t * dk];
        let pos = Positions::Packed {
            heads: &packed,
            offset: 1,
        };
        let mut ws = AttentionWorkspace::default();
        rel_pos_attention_with(
            &pool,
            &x,
            &x,
            &x,
            pos,
            t,
            h,
            dk,
            &x[..dk],
            &x[..dk],
            &mut ws,
            &mut out,
        );
    }
}
