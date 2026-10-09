//! FastConformer encoder: `dw_striding` subsampling and 24 conformer layers.
//!
//! Per layer (NeMo `ConformerLayer`, eval mode):
//! `x += 0.5 * FF1(LN(x))`; `x += MHSA(LN(x))`; `x += Conv(LN(x))`;
//! `x += 0.5 * FF2(LN(x))`; `x = LN(x)`. FF is `linear2(silu(linear1))`; Conv is
//! `pointwise2(silu(bn(depthwise(glu(pointwise1)))))` with batch norm folded
//! into the depthwise weights. One utterance at its exact length needs no
//! attention or padding masks.
//!
//! Each layer's `linear_pos` projection of the relative position embedding
//! depends only on the length, so [`PositionCache`] keeps it, packed for
//! attention, for the longest utterance seen (up to a limit).

use std::time::{Duration, Instant};

use lf_cpu::attention::{AttentionWorkspace, Positions, pack_positions, rel_pos_attention_with};
use lf_cpu::conv2d::{conv0_dw, depthwise_s2, out_len};
use lf_cpu::dense::{NB, Panels, gemm};
use lf_cpu::ops::{add_scaled, depthwise_time, for_each_row_mut, glu, layer_norm, relu, silu};
use lf_cpu::{PackedTernary, QuantizedActs, Scratch, ThreadPool, gemm_f32, gemm_i8};
use lf_model::{Error, Result};

use crate::config::*;
use crate::model::{Layer, Model, Norm};

/// Activation precision for the ternary projections.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Precision {
    /// FP32 activations, FMA kernels.
    F32,
    /// Activations split into `n` residual INT8 components (1..=3); 3 is
    /// within FP32 rounding, 2 has roughly FP16-level error.
    Int8(usize),
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Timings {
    pub frontend: Duration,
    pub subsampling: Duration,
    /// Ternary projections, including activation quantization.
    pub projections: Duration,
    pub attention: Duration,
    /// Norms, residuals, activations and the depthwise convolution.
    pub elementwise: Duration,
    /// Encoder-side joint projection and greedy TDT decoding.
    pub decoder: Duration,
}

impl Timings {
    pub fn total(&self) -> Duration {
        self.frontend
            + self.subsampling
            + self.projections
            + self.attention
            + self.elementwise
            + self.decoder
    }
}

/// Which quantization buffer an input uses (inputs of different widths or
/// lifetimes must not overwrite each other).
#[derive(Clone, Copy)]
enum Slot {
    Model,
    Ff,
    Pos,
}

/// Runs ternary projections at the chosen precision.
pub struct Projector {
    precision: Precision,
    scratch: Scratch,
    q_model: QuantizedActs,
    q_ff: QuantizedActs,
    q_pos: QuantizedActs,
}

impl Projector {
    pub fn new(precision: Precision, threads: usize) -> Self {
        let n = match precision {
            Precision::F32 => 1,
            Precision::Int8(n) => {
                assert!((1..=3).contains(&n), "Int8 components must be 1..=3");
                n
            }
        };
        let bytes = gemm_i8::scratch_bytes(D_FF).max(gemm_f32::scratch_bytes());
        Projector {
            precision,
            scratch: Scratch::new(threads, bytes),
            q_model: QuantizedActs::with_capacity(0, D_MODEL, n),
            q_ff: QuantizedActs::with_capacity(0, D_FF, n),
            q_pos: QuantizedActs::with_capacity(0, D_MODEL, n),
        }
    }

    pub fn precision(&self) -> Precision {
        self.precision
    }

    /// Frees the quantized position embedding (it can be large).
    fn release_pos(&mut self) {
        let n = self.q_pos.components();
        self.q_pos = QuantizedActs::with_capacity(0, D_MODEL, n);
    }

    /// `y = W x` for `rows` rows of `x`. With `reuse`, the activations already
    /// quantized in `slot` (from the same `x`) are used again.
    #[allow(clippy::too_many_arguments)]
    fn run(
        &mut self,
        pool: &ThreadPool,
        w: &PackedTernary,
        x: &[f32],
        rows: usize,
        y: &mut [f32],
        slot: Slot,
        reuse: bool,
    ) -> Result<()> {
        match self.precision {
            Precision::F32 => gemm_f32::gemm(pool, &self.scratch, w, x, rows, y),
            Precision::Int8(_) => {
                let qa = match slot {
                    Slot::Model => &mut self.q_model,
                    Slot::Ff => &mut self.q_ff,
                    Slot::Pos => &mut self.q_pos,
                };
                if !reuse {
                    qa.quantize(pool, x, rows)
                        .map_err(|e| Error(format!("encoder: {e}")))?;
                }
                assert_eq!(qa.rows(), rows);
                gemm_i8::gemm(pool, &self.scratch, w, qa, y);
            }
        }
        Ok(())
    }
}

/// Reusable activation buffers, grown to the longest utterance seen.
#[derive(Default)]
pub struct EncoderBuffers {
    sub_a: Vec<f32>,
    sub_b: Vec<f32>,
    /// Encoder output `[frames][1024]` after `encode`.
    pub x: Vec<f32>,
    ln: Vec<f32>,
    h: Vec<f32>,
    y: Vec<f32>,
    q: Vec<f32>,
    k: Vec<f32>,
    v: Vec<f32>,
    pos_emb: Vec<f32>,
    p: Vec<f32>,
    att: Vec<f32>,
    g: Vec<f32>,
    dw: Vec<f32>,
    attn_ws: AttentionWorkspace,
}

fn sized(v: &mut Vec<f32>, n: usize) -> &mut [f32] {
    if v.len() < n {
        v.resize(n, 0.0);
    }
    &mut v[..n]
}

/// Encoder frames (80 ms each) for `samples` 16 kHz samples.
pub fn frames_for_samples(samples: usize) -> usize {
    out_len(out_len(out_len(samples / HOP_LENGTH)))
}

/// Encoder frames the position cache grows by (5.12 s of audio), so a run of
/// slightly longer utterances does not rebuild it each time. `2 * 64` rows
/// fill whole 64-row panels.
const CACHE_STEP: usize = 64;

/// Each layer's `linear_pos` projection of the relative position embedding,
/// packed per head for attention, for utterances of up to `frames` frames.
///
/// The projection is row-wise (each row is projected, and for INT8
/// quantized, on its own), and row `m` of the embedding for `t` frames is row
/// `m + t_max - t` of the one for `t_max` frames, so the rows for any shorter
/// utterance are a centre slice. The cache is built lazily for the longest
/// utterance seen, rounded up to [`CACHE_STEP`] frames and capped at `limit`;
/// longer utterances project per call, as without a cache. Outputs are
/// bit-identical either way.
///
/// Memory: 24 layers x `2 * frames` rows x 1024 f32, 192 KiB per frame
/// (144 MiB for 60 s). Building costs about one uncached call's position work.
///
/// A cache holds one model's weights at one precision. The precision is
/// checked on every use; using one cache with two models is a logic error that
/// gives wrong results.
pub struct PositionCache {
    /// Longest utterance, in frames, the cache may cover.
    limit: usize,
    /// Frames covered (0 when empty).
    frames: usize,
    precision: Option<Precision>,
    /// `[layer][head]`: rows for relative positions `frames - 1 ..= -(frames - 1)`.
    layers: Vec<Vec<Panels>>,
}

impl PositionCache {
    /// An empty cache for utterances of up to `limit` frames (0 disables it).
    pub fn new(limit: usize) -> Self {
        PositionCache {
            limit,
            frames: 0,
            precision: None,
            layers: Vec::new(),
        }
    }

    pub fn limit(&self) -> usize {
        self.limit
    }

    /// Frames currently covered.
    pub fn frames(&self) -> usize {
        self.frames
    }

    /// Changes the limit; a cache longer than the new limit (or left
    /// incomplete by a panic) is dropped.
    pub fn set_limit(&mut self, limit: usize) {
        self.limit = limit;
        if self.frames > limit || self.frames == 0 {
            self.clear();
        }
    }

    /// Frees the cache.
    pub fn clear(&mut self) {
        self.frames = 0;
        self.precision = None;
        self.layers = Vec::new();
    }

    /// Bytes held by the packed projections. Each rebuild allocates them
    /// afresh at exactly this size.
    pub fn bytes(&self) -> usize {
        self.layers
            .iter()
            .flatten()
            .map(|p| p.panels() * p.k() * NB * size_of::<f32>())
            .sum()
    }

    /// Makes the cache cover `t` frames if `t <= limit`. Returns whether it
    /// does; if not, the caller projects positions itself. `pos_emb` and `p`
    /// are scratch, freed after a rebuild.
    #[allow(clippy::too_many_arguments)]
    fn ensure(
        &mut self,
        layers: &[Layer],
        pool: &ThreadPool,
        proj: &mut Projector,
        t: usize,
        pos_emb: &mut Vec<f32>,
        p: &mut Vec<f32>,
        timings: &mut Timings,
    ) -> Result<bool> {
        if self.precision != Some(proj.precision) || self.layers.len() != layers.len() {
            self.clear();
        }
        if t <= self.frames {
            return Ok(true);
        }
        if t > self.limit {
            return Ok(false);
        }
        let target = t.next_multiple_of(CACHE_STEP).min(self.limit);
        // Drop the old panels first: fresh buffers are allocated at their exact
        // size (reused ones would keep the capacity growth slack), the peak is
        // lower, and an error or panic below leaves the cache empty.
        self.clear();
        let built = self.build(layers, pool, proj, target, pos_emb, p, timings);
        // Cached calls need neither the embedding nor its projection.
        *pos_emb = Vec::new();
        *p = Vec::new();
        proj.release_pos();
        match built {
            Ok(()) => {
                self.frames = target;
                self.precision = Some(proj.precision);
                Ok(true)
            }
            Err(e) => {
                self.clear();
                Err(e)
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn build(
        &mut self,
        layers: &[Layer],
        pool: &ThreadPool,
        proj: &mut Projector,
        target: usize,
        pos_emb: &mut Vec<f32>,
        p: &mut Vec<f32>,
        timings: &mut Timings,
    ) -> Result<()> {
        let rows = 2 * target - 1;
        let n = rows * D_MODEL;
        let start = Instant::now();
        rel_positional_embedding(pool, target, sized(pos_emb, n));
        timings.elementwise += start.elapsed();
        self.layers.resize_with(layers.len(), Vec::new);
        for (li, (l, packed)) in layers.iter().zip(&mut self.layers).enumerate() {
            let start = Instant::now();
            // The embedding is the same for every layer: quantize it once.
            proj.run(
                pool,
                &l.pos,
                &pos_emb[..n],
                rows,
                sized(p, n),
                Slot::Pos,
                li > 0,
            )?;
            timings.projections += start.elapsed();
            let start = Instant::now();
            pack_positions(pool, &p[..n], rows, HEADS, D_HEAD, packed);
            timings.attention += start.elapsed();
        }
        Ok(())
    }
}

/// NeMo `RelPositionalEncoding` for `t` frames: positions `t-1 .. -(t-1)`,
/// `[2t - 1][d]`, with sin on even and cos on odd features, computed in f32
/// like torch.
fn rel_positional_embedding(pool: &ThreadPool, t: usize, out: &mut [f32]) {
    let neg_log = -(10_000f32.ln() / D_MODEL as f32);
    let div: Vec<f32> = (0..D_MODEL / 2)
        .map(|i| ((2 * i) as f32 * neg_log).exp())
        .collect();
    for_each_row_mut(
        pool,
        &mut out[..(2 * t - 1) * D_MODEL],
        D_MODEL,
        &|r, row| {
            let pos = (t as isize - 1 - r as isize) as f32;
            for (i, &dv) in div.iter().enumerate() {
                let arg = pos * dv;
                row[2 * i] = (arg as f64).sin() as f32;
                row[2 * i + 1] = (arg as f64).cos() as f32;
            }
        },
    );
}

/// Runs subsampling and all layers on `feat` (`[frames][128]`); the output
/// (`[returned frames][1024]`) is left in `buf.x`. `cache` must only ever be
/// used with this `model`.
#[allow(clippy::too_many_arguments)]
pub fn encode(
    model: &Model,
    pool: &ThreadPool,
    proj: &mut Projector,
    feat: &[f32],
    frames: usize,
    buf: &mut EncoderBuffers,
    cache: &mut PositionCache,
    timings: &mut Timings,
) -> Result<usize> {
    let start = Instant::now();
    let s = &model.sub;
    let c = SUB_CHANNELS;
    let (t1, f1) = (out_len(frames), out_len(FEATURES));
    let (t2, f2) = (out_len(t1), out_len(f1));
    let (t, f3) = (out_len(t2), out_len(f2));
    debug_assert_eq!(f3 * c, D_FF);
    {
        let a = sized(&mut buf.sub_a, t2 * f2 * c);
        conv0_dw(pool, feat, frames, FEATURES, &s.w0, &s.b0, &s.w2, &s.b2, a);
        let b = sized(&mut buf.sub_b, t2 * f2 * c);
        gemm(
            pool,
            &buf.sub_a[..t2 * f2 * c],
            t2 * f2,
            c,
            &s.p3,
            b,
            c,
            Some(&s.b3),
        );
        relu(pool, b, t2 * f2, c);
        let a = sized(&mut buf.sub_a, t * f3 * c);
        depthwise_s2(pool, &buf.sub_b[..t2 * f2 * c], t2, f2, &s.w5, &s.b5, a);
        let b = sized(&mut buf.sub_b, t * f3 * c);
        gemm(
            pool,
            &buf.sub_a[..t * f3 * c],
            t * f3,
            c,
            &s.p6,
            b,
            c,
            Some(&s.b6),
        );
        relu(pool, b, t * f3, c);
        let x = sized(&mut buf.x, t * D_MODEL);
        gemm(
            pool,
            &buf.sub_b[..t * D_FF],
            t,
            D_FF,
            &s.out,
            x,
            D_MODEL,
            Some(&s.out_b),
        );
    }
    timings.subsampling += start.elapsed();
    run_layers(&model.layers, pool, proj, t, buf, cache, timings)?;
    Ok(t)
}

/// Runs `layers` on `buf.x` (`[t][1024]`), with positions from `cache` when it
/// covers `t`.
fn run_layers(
    layers: &[Layer],
    pool: &ThreadPool,
    proj: &mut Projector,
    t: usize,
    buf: &mut EncoderBuffers,
    cache: &mut PositionCache,
    timings: &mut Timings,
) -> Result<()> {
    let cached = cache.ensure(layers, pool, proj, t, &mut buf.pos_emb, &mut buf.p, timings)?;
    if !cached {
        let start = Instant::now();
        let pos_rows = 2 * t - 1;
        rel_positional_embedding(pool, t, sized(&mut buf.pos_emb, pos_rows * D_MODEL));
        timings.elementwise += start.elapsed();
    }
    for (li, layer) in layers.iter().enumerate() {
        let pos = if cached {
            LayerPositions::Cached {
                heads: &cache.layers[li],
                offset: cache.frames - t,
            }
        } else {
            // The position embedding is the same for every layer: quantize it once.
            LayerPositions::Project { quantized: li > 0 }
        };
        run_layer(pool, proj, layer, t, pos, buf, timings)?;
    }
    Ok(())
}

/// Where a layer's projected positions come from.
enum LayerPositions<'a> {
    /// Rows `offset .. offset + 2t - 1` of a [`PositionCache`] layer.
    Cached { heads: &'a [Panels], offset: usize },
    /// Projected from `buf.pos_emb` into `buf.p`; with `quantized`, reusing the
    /// quantized embedding from an earlier layer of this call.
    Project { quantized: bool },
}

#[allow(clippy::too_many_arguments)]
fn run_layer(
    pool: &ThreadPool,
    proj: &mut Projector,
    l: &Layer,
    t: usize,
    pos: LayerPositions<'_>,
    buf: &mut EncoderBuffers,
    timings: &mut Timings,
) -> Result<()> {
    let d = D_MODEL;
    let n = t * d;
    let norm = |buf: &mut EncoderBuffers, nm: &Norm, timings: &mut Timings| {
        norm_into_ln(pool, buf, nm, t, timings)
    };

    feed_forward(pool, proj, buf, &l.ff1, &l.norm_ff1, t, timings)?;

    // Self-attention.
    norm(buf, &l.norm_att, timings);
    let start = Instant::now();
    let pos_rows = 2 * t - 1;
    proj.run(
        pool,
        &l.q,
        &buf.ln[..n],
        t,
        sized(&mut buf.q, n),
        Slot::Model,
        false,
    )?;
    proj.run(
        pool,
        &l.k,
        &buf.ln[..n],
        t,
        sized(&mut buf.k, n),
        Slot::Model,
        true,
    )?;
    proj.run(
        pool,
        &l.v,
        &buf.ln[..n],
        t,
        sized(&mut buf.v, n),
        Slot::Model,
        true,
    )?;
    if let LayerPositions::Project { quantized } = pos {
        let p = sized(&mut buf.p, pos_rows * d);
        proj.run(
            pool,
            &l.pos,
            &buf.pos_emb[..pos_rows * d],
            pos_rows,
            p,
            Slot::Pos,
            quantized,
        )?;
    }
    timings.projections += start.elapsed();
    let start = Instant::now();
    let positions = match pos {
        LayerPositions::Cached { heads, offset } => Positions::Packed { heads, offset },
        LayerPositions::Project { .. } => Positions::Rows(&buf.p[..pos_rows * d]),
    };
    let att = sized(&mut buf.att, n);
    rel_pos_attention_with(
        pool,
        &buf.q[..n],
        &buf.k[..n],
        &buf.v[..n],
        positions,
        t,
        HEADS,
        D_HEAD,
        &l.bias_u,
        &l.bias_v,
        &mut buf.attn_ws,
        att,
    );
    timings.attention += start.elapsed();
    let start = Instant::now();
    proj.run(
        pool,
        &l.out,
        &buf.att[..n],
        t,
        sized(&mut buf.y, n),
        Slot::Model,
        false,
    )?;
    timings.projections += start.elapsed();
    let start = Instant::now();
    add_scaled(pool, &mut buf.x[..n], &buf.y[..n], t, d, 1.0);
    timings.elementwise += start.elapsed();

    // Convolution module.
    norm(buf, &l.norm_conv, timings);
    let start = Instant::now();
    proj.run(
        pool,
        &l.pw1,
        &buf.ln[..n],
        t,
        sized(&mut buf.h, 2 * n),
        Slot::Model,
        false,
    )?;
    timings.projections += start.elapsed();
    let start = Instant::now();
    glu(pool, &buf.h[..2 * n], t, d, sized(&mut buf.g, n));
    depthwise_time(
        pool,
        &buf.g[..n],
        t,
        d,
        &l.dw_w,
        CONV_KERNEL,
        &l.dw_b,
        true,
        sized(&mut buf.dw, n),
    );
    timings.elementwise += start.elapsed();
    let start = Instant::now();
    proj.run(
        pool,
        &l.pw2,
        &buf.dw[..n],
        t,
        sized(&mut buf.y, n),
        Slot::Model,
        false,
    )?;
    timings.projections += start.elapsed();
    let start = Instant::now();
    add_scaled(pool, &mut buf.x[..n], &buf.y[..n], t, d, 1.0);
    timings.elementwise += start.elapsed();

    feed_forward(pool, proj, buf, &l.ff2, &l.norm_ff2, t, timings)?;

    // Output norm: x = LN(x).
    norm(buf, &l.norm_out, timings);
    std::mem::swap(&mut buf.x, &mut buf.ln);
    Ok(())
}

/// `buf.ln = LN(buf.x)`.
fn norm_into_ln(
    pool: &ThreadPool,
    buf: &mut EncoderBuffers,
    nm: &Norm,
    t: usize,
    timings: &mut Timings,
) {
    let start = Instant::now();
    let n = t * D_MODEL;
    let ln = sized(&mut buf.ln, n);
    layer_norm(pool, &buf.x[..n], t, D_MODEL, &nm.gamma, &nm.beta, ln);
    timings.elementwise += start.elapsed();
}

/// `x += 0.5 * linear2(silu(linear1(LN(x))))`.
fn feed_forward(
    pool: &ThreadPool,
    proj: &mut Projector,
    buf: &mut EncoderBuffers,
    w: &[PackedTernary; 2],
    nm: &Norm,
    t: usize,
    timings: &mut Timings,
) -> Result<()> {
    let n = t * D_MODEL;
    norm_into_ln(pool, buf, nm, t, timings);
    let start = Instant::now();
    let h = sized(&mut buf.h, t * D_FF);
    proj.run(pool, &w[0], &buf.ln[..n], t, h, Slot::Model, false)?;
    timings.projections += start.elapsed();
    let start = Instant::now();
    silu(pool, &mut buf.h[..t * D_FF], t, D_FF);
    timings.elementwise += start.elapsed();
    let start = Instant::now();
    let y = sized(&mut buf.y, n);
    proj.run(pool, &w[1], &buf.h[..t * D_FF], t, y, Slot::Ff, false)?;
    timings.projections += start.elapsed();
    let start = Instant::now();
    add_scaled(pool, &mut buf.x[..n], &buf.y[..n], t, D_MODEL, 0.5);
    timings.elementwise += start.elapsed();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_model::TernaryMatrix;
    use lf_model::rng::SplitMix64;

    const PRECISIONS: [Precision; 4] = [
        Precision::F32,
        Precision::Int8(1),
        Precision::Int8(2),
        Precision::Int8(3),
    ];

    fn ternary(rows: usize, cols: usize, seed: u64) -> PackedTernary {
        PackedTernary::new(&TernaryMatrix::random(rows, cols, seed)).unwrap()
    }

    fn rand(n: usize, seed: u64, scale: f32) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..n).map(|_| scale * rng.next_gaussian()).collect()
    }

    fn norm(seed: u64) -> Norm {
        Norm {
            gamma: rand(D_MODEL, seed, 0.1).iter().map(|g| 1.0 + g).collect(),
            beta: rand(D_MODEL, seed + 1, 0.1),
        }
    }

    /// A full-width layer with synthetic weights.
    fn layer(seed: u64) -> Layer {
        let s = seed * 100;
        Layer {
            norm_ff1: norm(s),
            norm_att: norm(s + 2),
            norm_conv: norm(s + 4),
            norm_ff2: norm(s + 6),
            norm_out: norm(s + 8),
            ff1: [
                ternary(D_FF, D_MODEL, s + 10),
                ternary(D_MODEL, D_FF, s + 11),
            ],
            ff2: [
                ternary(D_FF, D_MODEL, s + 12),
                ternary(D_MODEL, D_FF, s + 13),
            ],
            q: ternary(D_MODEL, D_MODEL, s + 14),
            k: ternary(D_MODEL, D_MODEL, s + 15),
            v: ternary(D_MODEL, D_MODEL, s + 16),
            pos: ternary(D_MODEL, D_MODEL, s + 17),
            out: ternary(D_MODEL, D_MODEL, s + 18),
            pw1: ternary(2 * D_MODEL, D_MODEL, s + 19),
            pw2: ternary(D_MODEL, D_MODEL, s + 20),
            bias_u: rand(D_MODEL, s + 21, 0.1),
            bias_v: rand(D_MODEL, s + 22, 0.1),
            dw_w: rand(CONV_KERNEL * D_MODEL, s + 23, 0.3),
            dw_b: rand(D_MODEL, s + 24, 0.1),
        }
    }

    fn bits(x: &[f32]) -> Vec<u32> {
        x.iter().map(|v| v.to_bits()).collect()
    }

    fn embedding(pool: &ThreadPool, t: usize) -> Vec<f32> {
        let mut e = vec![0.0; (2 * t - 1) * D_MODEL];
        rel_positional_embedding(pool, t, &mut e);
        e
    }

    #[test]
    fn frames_for_samples_matches_80_ms_frames() {
        assert_eq!(frames_for_samples(0), 0);
        assert_eq!(frames_for_samples(10 * SAMPLE_RATE), 125);
        assert_eq!(frames_for_samples(60 * SAMPLE_RATE), 750);
    }

    /// The premise of the cache, checked rather than assumed: the embedding for
    /// `t` frames is the centre of the one for `t_max`, and projecting it gives
    /// bit-identical rows whatever the batch size, the row's position in the
    /// batch (6-row and `6 / n`-frame kernel groups, K blocks of 512) and the
    /// thread count.
    #[test]
    fn position_rows_do_not_depend_on_the_batch() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let (pool3, pool1) = (ThreadPool::new(&[0, 1, 2]), ThreadPool::new(&[3]));
        let w = ternary(D_MODEL, D_MODEL, 7);
        let t_max = 150;
        let big_emb = embedding(&pool3, t_max);
        for precision in PRECISIONS {
            let mut proj3 = Projector::new(precision, 3);
            let mut proj1 = Projector::new(precision, 1);
            let rows = 2 * t_max - 1;
            let mut big = vec![0.0; rows * D_MODEL];
            proj3
                .run(&pool3, &w, &big_emb, rows, &mut big, Slot::Pos, false)
                .unwrap();
            for t in [1, 2, 5, 7, 64, 65, 97, 149, 150] {
                let emb = embedding(&pool1, t);
                let centre = (t_max - t) * D_MODEL..(t_max + t - 1) * D_MODEL;
                assert_eq!(
                    bits(&emb),
                    bits(&big_emb[centre.clone()]),
                    "embedding t={t}"
                );
                let mut small = vec![0.0; emb.len()];
                proj1
                    .run(&pool1, &w, &emb, 2 * t - 1, &mut small, Slot::Pos, false)
                    .unwrap();
                assert_eq!(bits(&small), bits(&big[centre]), "{precision:?} t={t}");
            }
        }
    }

    /// Two full-width layers run with and without the cache give bit-identical
    /// outputs, across cache growth, shorter utterances, lengths past the
    /// limit, a precision change and a lowered limit.
    #[test]
    fn cached_layers_match_uncached_bit_for_bit() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1, 2, 3]);
        let layers = [layer(1), layer(2)];
        let limit = 150;
        // One cache across all precisions: a precision change must rebuild it.
        let mut cache = PositionCache::new(limit);
        let mut off = PositionCache::new(0);
        // (t, frames covered afterwards)
        let steps = [
            (70, 128),
            (1, 128),
            (65, 128),
            (64, 128),
            (130, 150),
            (131, 150),
            (20, 150),
            (151, 150),
            (150, 150),
            (63, 150),
        ];
        for precision in PRECISIONS {
            let mut proj_a = Projector::new(precision, pool.threads());
            let mut proj_b = Projector::new(precision, pool.threads());
            let (mut buf_a, mut buf_b) = (EncoderBuffers::default(), EncoderBuffers::default());
            let mut timings = Timings::default();
            for (i, &(t, covered)) in steps.iter().enumerate() {
                let x = rand(t * D_MODEL, 1000 + i as u64, 1.0);
                buf_a.x = x.clone();
                buf_b.x = x;
                run_layers(
                    &layers,
                    &pool,
                    &mut proj_a,
                    t,
                    &mut buf_a,
                    &mut off,
                    &mut timings,
                )
                .unwrap();
                run_layers(
                    &layers,
                    &pool,
                    &mut proj_b,
                    t,
                    &mut buf_b,
                    &mut cache,
                    &mut timings,
                )
                .unwrap();
                assert_eq!(cache.frames(), covered, "{precision:?} t={t}");
                let n = t * D_MODEL;
                assert!(buf_a.x[..n].iter().all(|v| v.is_finite()));
                assert_eq!(
                    bits(&buf_a.x[..n]),
                    bits(&buf_b.x[..n]),
                    "{precision:?} t={t}"
                );
            }
            assert_eq!(off.frames(), 0);
            assert_eq!(off.bytes(), 0);
        }
        // 2 layers x 8 heads x ceil(299 / 64) panels x 128 x 64 floats.
        assert_eq!(cache.bytes(), 2 * HEADS * 5 * D_HEAD * NB * 4);
        cache.set_limit(149);
        assert_eq!((cache.frames(), cache.bytes()), (0, 0));
    }
}
