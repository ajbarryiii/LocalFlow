// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
//! Parakeet TDT prediction network, joint network and greedy decoding on the CPU.
//!
//! Per emitted token the prediction network runs two LSTM layers (H = 640)
//! and the prediction projection; every decision runs the joint output layer
//! (640 -> 1025 tokens + 5 durations). Each step is a few small matrix-vector
//! products, so the cost is reading weights, not arithmetic. Weights are split
//! across threads in 64-row superblocks so every thread re-reads only its own
//! slice, ideally from L2. Phases are separated by a spinning barrier.
//!
//! Precomputed once per model: the embedding times the first layer's input
//! weights plus both first-layer biases (`table0`). Once per utterance: the
//! encoder-side joint projection for every frame.

use std::sync::Mutex;

use lf_model::half::f32_to_f16;
use lf_model::rng::SplitMix64;
use lf_model::{Result, SafeTensors};

use crate::barrier::SpinBarrier;
use crate::bias::{BiasGraph, BiasState};
use crate::{SendPtr, ThreadPool, Tier, split_range};

/// Maximum emissions on one frame before forcing an advance (NeMo default).
pub const MAX_SYMBOLS_PER_FRAME: usize = 10;

/// Floating-point decoder weights in the export's layout (values exact in f32).
pub struct DecoderParams {
    /// Tokens including blank, which is the last index.
    pub vocab: usize,
    pub hidden: usize,
    pub enc_dim: usize,
    pub joint: usize,
    pub durations: Vec<usize>,
    /// `[vocab][hidden]`.
    pub embed: Vec<f32>,
    /// Per layer, `[4 * hidden][hidden]` in PyTorch gate order i, f, g, o.
    pub w_ih: [Vec<f32>; 2],
    pub w_hh: [Vec<f32>; 2],
    pub b_ih: [Vec<f32>; 2],
    pub b_hh: [Vec<f32>; 2],
    /// `[joint][enc_dim]`.
    pub w_enc: Vec<f32>,
    pub b_enc: Vec<f32>,
    /// `[joint][hidden]`.
    pub w_pred: Vec<f32>,
    pub b_pred: Vec<f32>,
    /// `[vocab + durations][joint]`.
    pub w_out: Vec<f32>,
    pub b_out: Vec<f32>,
}

impl DecoderParams {
    pub fn blank(&self) -> usize {
        self.vocab - 1
    }

    pub fn out_rows(&self) -> usize {
        self.vocab + self.durations.len()
    }

    pub fn from_export(st: &SafeTensors, durations: Vec<usize>) -> Result<Self> {
        let get = |name: &str, shape: &[usize]| -> Result<Vec<f32>> {
            let (s, v) = st.float_vec(name)?;
            if s != shape {
                return Err(lf_model::Error(format!(
                    "{name}: shape {s:?}, expected {shape:?}"
                )));
            }
            Ok(v)
        };
        let dims = |name: &str| -> Result<(usize, usize)> {
            match st.tensors.get(name).map(|t| t.shape.as_slice()) {
                Some(&[a, b]) if a > 1 && b > 0 => Ok((a, b)),
                _ => Err(lf_model::Error(format!("{name}: expected a 2-D tensor"))),
            }
        };
        let (vocab, hidden) = dims("decoder.prediction.embed.weight")?;
        let (joint, enc_dim) = dims("joint.enc.weight")?;
        if durations.is_empty() {
            return Err(lf_model::Error("no TDT durations".into()));
        }
        let lstm = |kind: &str, l: usize, shape: &[usize]| {
            get(
                &format!("decoder.prediction.dec_rnn.lstm.{kind}_l{l}"),
                shape,
            )
        };
        let g4 = 4 * hidden;
        let embed = get("decoder.prediction.embed.weight", &[vocab, hidden])?;
        // The start symbol is a zero input; decoding feeds the blank row for it.
        if embed[(vocab - 1) * hidden..].iter().any(|&v| v != 0.0) {
            return Err(lf_model::Error("blank embedding row is not zero".into()));
        }
        Ok(DecoderParams {
            vocab,
            hidden,
            enc_dim,
            joint,
            embed,
            w_ih: [
                lstm("weight_ih", 0, &[g4, hidden])?,
                lstm("weight_ih", 1, &[g4, hidden])?,
            ],
            w_hh: [
                lstm("weight_hh", 0, &[g4, hidden])?,
                lstm("weight_hh", 1, &[g4, hidden])?,
            ],
            b_ih: [lstm("bias_ih", 0, &[g4])?, lstm("bias_ih", 1, &[g4])?],
            b_hh: [lstm("bias_hh", 0, &[g4])?, lstm("bias_hh", 1, &[g4])?],
            w_enc: get("joint.enc.weight", &[joint, enc_dim])?,
            b_enc: get("joint.enc.bias", &[joint])?,
            w_pred: get("joint.pred.weight", &[joint, hidden])?,
            b_pred: get("joint.pred.bias", &[joint])?,
            w_out: get(
                "joint.joint_net.2.weight",
                &[vocab + durations.len(), joint],
            )?,
            b_out: get("joint.joint_net.2.bias", &[vocab + durations.len()])?,
            durations,
        })
    }

    /// Synthetic weights, exactly representable in f16 (multiples of 2^-12).
    pub fn random(vocab: usize, hidden: usize, enc_dim: usize, joint: usize, seed: u64) -> Self {
        let mut rng = SplitMix64::new(seed);
        let mut v = |n: usize, range: u64| -> Vec<f32> {
            (0..n)
                .map(|_| (rng.below(2 * range + 1) as f32 - range as f32) / 4096.0)
                .collect()
        };
        let durations = vec![0, 1, 2, 3, 4];
        let out = vocab + durations.len();
        let g4 = 4 * hidden;
        let mut embed = v(vocab * hidden, 1024);
        // NeMo pads the blank embedding with zeros.
        embed[(vocab - 1) * hidden..].fill(0.0);
        DecoderParams {
            vocab,
            hidden,
            enc_dim,
            joint,
            embed,
            w_ih: [v(g4 * hidden, 160), v(g4 * hidden, 160)],
            w_hh: [v(g4 * hidden, 160), v(g4 * hidden, 160)],
            b_ih: [v(g4, 400), v(g4, 400)],
            b_hh: [v(g4, 400), v(g4, 400)],
            w_enc: v(joint * enc_dim, 128),
            b_enc: v(joint, 400),
            w_pred: v(joint * hidden, 160),
            b_pred: v(joint, 400),
            w_out: v(out * joint, 160),
            b_out: v(out, 400),
            durations,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Storage {
    F32,
    F16,
}

enum Weights {
    F32(Vec<f32>),
    F16(Vec<u16>),
}

impl Weights {
    fn new(values: Vec<f32>, storage: Storage) -> Self {
        match storage {
            Storage::F32 => Weights::F32(values),
            Storage::F16 => Weights::F16(values.iter().map(|&v| f32_to_f16(v)).collect()),
        }
    }

    fn bytes(&self) -> usize {
        match self {
            Weights::F32(v) => v.len() * 4,
            Weights::F16(v) => v.len() * 2,
        }
    }
}

/// Rows per superblock: four 16-lane vectors.
const SB: usize = 64;

/// Packs `[rows][k]` row-major weights into `[superblocks][k][64]`, where
/// `row_of(sb, lane)` names the source row for each lane (or `None` for padding).
fn pack(
    src: &[f32],
    k: usize,
    superblocks: usize,
    row_of: impl Fn(usize, usize) -> Option<usize>,
) -> Vec<f32> {
    let mut out = vec![0.0; superblocks * k * SB];
    for sb in 0..superblocks {
        for lane in 0..SB {
            if let Some(r) = row_of(sb, lane) {
                for i in 0..k {
                    out[(sb * k + i) * SB + lane] = src[r * k + i];
                }
            }
        }
    }
    out
}

fn pack_vec(
    src: &[f32],
    superblocks: usize,
    row_of: impl Fn(usize, usize) -> Option<usize>,
) -> Vec<f32> {
    let mut out = vec![0.0; superblocks * SB];
    for sb in 0..superblocks {
        for lane in 0..SB {
            if let Some(r) = row_of(sb, lane) {
                out[sb * SB + lane] = src[r];
            }
        }
    }
    out
}

pub struct PackedDecoder {
    pub storage: Storage,
    vocab: usize,
    hidden: usize,
    enc_dim: usize,
    joint: usize,
    durations: Vec<usize>,
    /// `[vocab][4H]` in LSTM superblock order: embedding x W_ih0 + b_ih0 + b_hh0.
    table0: Vec<f32>,
    w0: Weights,
    w1_ih: Weights,
    w1_hh: Weights,
    b1: Vec<f32>,
    w_pred: Weights,
    b_pred: Vec<f32>,
    w_out: Weights,
    b_out: Vec<f32>,
    w_enc: Weights,
    b_enc: Vec<f32>,
}

impl PackedDecoder {
    pub fn new(p: &DecoderParams, storage: Storage) -> Self {
        // `decode` indexes `table0` with `vocab - 1` and argmax tokens, so the
        // vocabulary must hold at least the blank token; `DecoderParams` has
        // public fields, so a hand-built one can have `vocab == 0`.
        assert!(p.vocab > 0, "the vocabulary must include blank");
        let h = p.hidden;
        assert!(h.is_multiple_of(16), "hidden size must be a multiple of 16");
        let lstm_sb = h / 16;
        // Superblock sb, lane (gate * 16 + j) -> row gate * H + 16 * sb + j.
        let lstm_row = move |sb: usize, lane: usize| Some((lane / 16) * h + 16 * sb + lane % 16);
        let joint_sb = p.joint.div_ceil(SB);
        let out_sb = p.out_rows().div_ceil(SB);
        let plain =
            |rows: usize| move |sb: usize, lane: usize| Some(sb * SB + lane).filter(|&r| r < rows);

        let mut table0 = vec![0.0f32; p.vocab * 4 * h];
        let bias0: Vec<f64> = (0..4 * h)
            .map(|r| p.b_ih[0][r] as f64 + p.b_hh[0][r] as f64)
            .collect();
        for tok in 0..p.vocab {
            let e = &p.embed[tok * h..(tok + 1) * h];
            for sb in 0..lstm_sb {
                for lane in 0..SB {
                    let r = lstm_row(sb, lane).unwrap();
                    let w = &p.w_ih[0][r * h..(r + 1) * h];
                    let dot: f64 = w.iter().zip(e).map(|(&a, &b)| a as f64 * b as f64).sum();
                    table0[tok * 4 * h + sb * SB + lane] = (dot + bias0[r]) as f32;
                }
            }
        }
        let b1: Vec<f32> = (0..4 * h).map(|r| p.b_ih[1][r] + p.b_hh[1][r]).collect();
        PackedDecoder {
            storage,
            vocab: p.vocab,
            hidden: h,
            enc_dim: p.enc_dim,
            joint: p.joint,
            durations: p.durations.clone(),
            table0,
            w0: Weights::new(pack(&p.w_hh[0], h, lstm_sb, lstm_row), storage),
            w1_ih: Weights::new(pack(&p.w_ih[1], h, lstm_sb, lstm_row), storage),
            w1_hh: Weights::new(pack(&p.w_hh[1], h, lstm_sb, lstm_row), storage),
            b1: pack_vec(&b1, lstm_sb, lstm_row),
            w_pred: Weights::new(pack(&p.w_pred, h, joint_sb, plain(p.joint)), storage),
            b_pred: pack_vec(&p.b_pred, joint_sb, plain(p.joint)),
            w_out: Weights::new(
                pack(&p.w_out, p.joint, out_sb, plain(p.out_rows())),
                storage,
            ),
            b_out: pack_vec(&p.b_out, out_sb, plain(p.out_rows())),
            w_enc: Weights::new(pack(&p.w_enc, p.enc_dim, joint_sb, plain(p.joint)), storage),
            b_enc: pack_vec(&p.b_enc, joint_sb, plain(p.joint)),
        }
    }

    /// Bytes of weights read per emitted token (both LSTM layers, prediction
    /// projection and joint output).
    pub fn bytes_per_token_step(&self) -> usize {
        self.w0.bytes()
            + self.w1_ih.bytes()
            + self.w1_hh.bytes()
            + self.w_pred.bytes()
            + self.w_out.bytes()
    }

    /// Row stride of [`Self::project_encoder`]'s output.
    pub fn joint_padded(&self) -> usize {
        self.joint.div_ceil(SB) * SB
    }

    pub fn joint_dim(&self) -> usize {
        self.joint
    }

    /// Encoder-side joint projection for `frames` frames of `enc` (`[frames][enc_dim]`),
    /// written as `[frames][joint_padded]`.
    pub fn project_encoder(&self, pool: &ThreadPool, enc: &[f32], frames: usize) -> Vec<f32> {
        let kern = Kernels::of(pool.tier());
        assert!(enc.len() >= crate::size(frames, self.enc_dim));
        let jp = self.joint_padded();
        let mut out = vec![0.0f32; crate::size(frames, jp)];
        let op = SendPtr(out.as_mut_ptr());
        let threads = pool.threads();
        let sbs = jp / SB;
        // Split frames across threads when there are fewer superblocks than threads.
        let units = crate::size(sbs, frames.div_ceil(6));
        pool.run(&|idx| {
            for u in split_range(units, threads, idx) {
                let (sb, tb) = (u % sbs, u / sbs);
                let t0 = tb * 6;
                let rows = 6.min(frames - t0);
                // SAFETY: `kern` holds the kernels of the pool's tier, which this
                // CPU supports. `sb < jp / 64`, a superblock of `w_enc` (`[jp /
                // 64][enc_dim][64]`) and `b_enc` (`jp`) as packed by `new`. `t0 < frames` and `rows <= frames - t0`, so
                // input rows lie in `enc` (`frames * enc_dim`, checked) and output
                // rows in `out` (`frames * jp`). Units `(sb, tb)` are distinct, so
                // threads write disjoint 64-column blocks.
                unsafe {
                    (kern.gemm_rows)(
                        &self.w_enc,
                        sb,
                        self.enc_dim,
                        enc.as_ptr().add(t0 * self.enc_dim),
                        self.enc_dim,
                        rows,
                        op.get().add(t0 * jp + sb * SB),
                        jp,
                        self.b_enc.as_ptr().add(sb * SB),
                    )
                };
            }
        });
        out
    }

    /// Greedy TDT decode over `frames` frames of projected encoder output.
    ///
    /// With a `schedule`, decisions are taken from it instead of the argmax (the
    /// argmax is still computed), so benchmarks can fix the number of tokens and
    /// joint evaluations. With a non-empty `bias`, each decision adds the
    /// current bias state's bonuses to the token logits and takes the argmax
    /// in f64 (first maximum wins); a non-blank emission moves the state.
    /// Without one (or with an empty graph) decoding is exactly as before
    /// word boosting existed. Returns `(token, frame)` emissions.
    pub fn decode(
        &self,
        pool: &ThreadPool,
        enc_proj: &[f32],
        frames: usize,
        schedule: Option<&[ScheduledStep]>,
        bias: Option<&BiasGraph>,
    ) -> Vec<(usize, usize)> {
        let kern = Kernels::of(pool.tier());
        let n = pool.threads();
        let h = self.hidden;
        let jp = self.joint_padded();
        assert!(enc_proj.len() >= crate::size(frames, jp));
        // Validate before any thread dereferences a scheduled frame or token.
        if let Some(s) = schedule {
            for step in s {
                assert!(step.frame < frames, "scheduled frame out of range");
                assert!(
                    step.token.is_none_or(|t| t < self.vocab - 1),
                    "scheduled token out of range"
                );
            }
        }
        // An empty graph adds nothing; skipping it keeps today's exact path.
        let bias = bias.filter(|g| !g.is_empty());
        if let Some(g) = bias {
            assert_eq!(g.tokens(), self.vocab - 1, "bias vocabulary size");
        }
        let state = DecodeState::new(n, h, jp);
        let barrier = SpinBarrier::new(n);
        let result = Mutex::new(Vec::new());
        pool.run(&|idx| {
            // SAFETY: `kern` holds the pool's tier's kernels, which this CPU
            // supports; `vocab >= 1` is asserted by
            // `PackedDecoder::new` (the only constructor), `enc_proj` covers
            // `frames * jp`, and every scheduled frame and token was validated
            // above. `pool.run` runs this once for every `idx < n` concurrently,
            // with the same arguments, `state` built for `n` threads and
            // `barrier` for `n`.
            let emitted = unsafe {
                self.decode_thread(
                    kern, idx, n, &state, &barrier, enc_proj, frames, schedule, bias,
                )
            };
            if idx == 0 {
                *result.lock().unwrap() = emitted;
            }
        });
        result.into_inner().unwrap()
    }

    /// One pool thread's share of [`Self::decode`].
    ///
    /// # Safety
    /// `kern` must hold the kernels of a tier this CPU supports. Exactly `n`
    /// threads, one per `idx < n`, must run this concurrently with otherwise
    /// identical arguments, so that all take the same decisions and meet at
    /// the same barriers. `st` must
    /// come from `DecodeState::new(n, hidden, joint_padded)` and `barrier` from
    /// `SpinBarrier::new(n)`. `enc_proj` must hold `frames * joint_padded`
    /// values, every scheduled frame must be below `frames` and every
    /// scheduled token below `vocab - 1`. `vocab` must be at least 1.
    #[allow(clippy::too_many_arguments)]
    unsafe fn decode_thread(
        &self,
        kern: Kernels,
        idx: usize,
        n: usize,
        st: &DecodeState,
        barrier: &SpinBarrier,
        enc_proj: &[f32],
        frames: usize,
        schedule: Option<&[ScheduledStep]>,
        bias: Option<&BiasGraph>,
    ) -> Vec<(usize, usize)> {
        let h = self.hidden;
        let jp = self.joint_padded();
        let blank = self.vocab - 1;
        let lstm_sbs = split_range(h / 16, n, idx);
        let pred_sbs = split_range(jp / SB, n, idx);
        let out_rows = self.vocab + self.durations.len();
        let out_sbs = split_range(out_rows.div_ceil(SB), n, idx);
        let mut z = vec![0.0f32; jp];
        let mut parity = 0usize;
        let mut emitted = Vec::new();
        // Biased decoding only: the state, and this thread's non-blank token
        // rows with their bonuses.
        let mut bias_state: BiasState = BiasGraph::ROOT;
        let bias_rows = if bias.is_some() {
            (out_sbs.start * SB).min(blank)..(out_sbs.end * SB).min(blank)
        } else {
            0..0
        };
        let mut bonus = vec![0.0f32; bias_rows.len()];

        // SAFETY: `kern`'s tier is supported (caller contract). `token <
        // vocab`: it is `blank = vocab - 1` (`vocab >= 1`: `PackedDecoder::new`),
        // an argmax row below `vocab` (or 0 if no logit beat -inf), or a scheduled token below `vocab - 1`; so
        // the `table0` row `token * 4 * h` exists (`table0` is `[vocab][4h]`).
        // This thread's `sb < h / 16` index superblocks of `w0` and `w1_*`
        // (`[h / 16][h][64]`), 64 values of the `table0` row and of `b1` (`4h`),
        // and 16 values of the `h`-value `c*`/`h*` buffers; pred `sb < jp / 64`
        // index `w_pred`, `b_pred` and `g` (`jp`). Phases are ordered by
        // `barrier`: threads write only their own superblocks' slices, read
        // whole vectors only after the barrier that follows their writes, and
        // `h*_in`/`h*_out` are different buffers (`parity`) whose reads in the
        // previous step ended before a barrier this thread has passed. All
        // threads call `step` at the same points because they reduce the same
        // partials to the same decisions.
        let step = |token: usize, parity: usize| unsafe {
            let (h0_in, h0_out) = (st.h0[parity].get(), st.h0[1 - parity].get());
            let (h1_in, h1_out) = (st.h1[parity].get(), st.h1[1 - parity].get());
            for sb in lstm_sbs.clone() {
                let bias = self.table0.as_ptr().add(token * 4 * h + sb * SB);
                (kern.lstm)(
                    &self.w0,
                    None,
                    sb,
                    h,
                    h0_in,
                    None,
                    bias,
                    st.c0.get().add(sb * 16),
                    h0_out.add(sb * 16),
                );
            }
            barrier.wait();
            for sb in lstm_sbs.clone() {
                let bias = self.b1.as_ptr().add(sb * SB);
                (kern.lstm)(
                    &self.w1_ih,
                    Some(&self.w1_hh),
                    sb,
                    h,
                    h0_out,
                    Some(h1_in),
                    bias,
                    st.c1.get().add(sb * 16),
                    h1_out.add(sb * 16),
                );
            }
            barrier.wait();
            for sb in pred_sbs.clone() {
                (kern.gemm_rows)(
                    &self.w_pred,
                    sb,
                    h,
                    h1_out,
                    h,
                    1,
                    st.g.get().add(sb * SB),
                    jp,
                    self.b_pred.as_ptr().add(sb * SB),
                );
            }
            barrier.wait();
        };

        step(blank, parity);
        parity ^= 1;
        let (mut frame, mut last_frame, mut symbols, mut event) =
            (0usize, usize::MAX, 0usize, 0usize);
        loop {
            if let Some(s) = schedule {
                let Some(e) = s.get(event) else { break };
                frame = e.frame;
            } else if frame >= frames {
                break;
            }
            // Every thread takes the same decisions, so each follows the bias
            // state itself and fills the bonuses of its own token rows.
            if let Some(g) = bias {
                g.bonuses(bias_state, bias_rows.start, &mut bonus);
            }
            // Joint: z = relu(enc_proj[frame] + g); logits for this thread's rows.
            // SAFETY: `kern`'s tier is supported (caller contract). `frame <
            // frames` (the loop condition, or a validated scheduled frame), so
            // `enc_proj` row
            // `frame` has `jp` values; `g` and this thread's `z` hold `jp` values
            // (`jp % 64 == 0`), and `g` was completed before the last barrier of
            // the previous `step`. Superblocks `sb < out_rows.div_ceil(64)` lie in
            // `w_out` (`[..][joint][64]`) and `b_out`; `z` has `jp >= joint`
            // inputs and `logits` 64 outputs. `partial[idx]` (`idx < n`) is this
            // thread's slot; every thread finished reading it before the second
            // barrier of the previous decision.
            unsafe {
                (kern.relu_add)(
                    enc_proj.as_ptr().add(frame * jp),
                    st.g.get(),
                    z.as_mut_ptr(),
                    jp,
                );
                let mut best = Partial::NONE;
                for sb in out_sbs.clone() {
                    let mut logits = [0.0f32; SB];
                    (kern.gemm_rows)(
                        &self.w_out,
                        sb,
                        self.joint,
                        z.as_ptr(),
                        self.joint,
                        1,
                        logits.as_mut_ptr(),
                        SB,
                        self.b_out.as_ptr().add(sb * SB),
                    );
                    if bias.is_some() {
                        // Biased scores in f64, like the reference, so adding a
                        // bonus never rounds two logits into a tie.
                        for (lane, &v) in logits.iter().enumerate() {
                            let row = sb * SB + lane;
                            if row < self.vocab {
                                let b = if row < blank {
                                    bonus[row - bias_rows.start]
                                } else {
                                    0.0
                                };
                                let s = f64::from(v) + f64::from(b);
                                if s > best.tok_score {
                                    best.tok_score = s;
                                    best.tok = row as u32;
                                }
                            } else if row < out_rows && v > best.dur_val {
                                best.dur_val = v;
                                best.dur = (row - self.vocab) as u32;
                            }
                        }
                        continue;
                    }
                    for (lane, &v) in logits.iter().enumerate() {
                        let row = sb * SB + lane;
                        if row < self.vocab {
                            if v > best.tok_val {
                                best.tok_val = v;
                                best.tok = row as u32;
                            }
                        } else if row < out_rows && v > best.dur_val {
                            best.dur_val = v;
                            best.dur = (row - self.vocab) as u32;
                        }
                    }
                }
                *st.partial.get().add(idx) = best;
            }
            barrier.wait();
            // Every thread reduces the same partials in index order (first max wins).
            let mut best = Partial::NONE;
            for i in 0..n {
                // SAFETY: `i < n` partial slots; every thread wrote its slot
                // before the barrier above, and none writes again before the
                // barrier below.
                let p = unsafe { *st.partial.get().add(i) };
                if bias.is_some() {
                    if p.tok_score > best.tok_score {
                        best.tok_score = p.tok_score;
                        best.tok = p.tok;
                    }
                } else if p.tok_val > best.tok_val {
                    best.tok_val = p.tok_val;
                    best.tok = p.tok;
                }
                if p.dur_val > best.dur_val {
                    best.dur_val = p.dur_val;
                    best.dur = p.dur;
                }
            }
            // Partials are reused after the next joint; keep them stable until everyone has read.
            barrier.wait();
            let (token, duration) = match schedule {
                Some(s) => {
                    let e = s[event];
                    event += 1;
                    (e.token.unwrap_or(blank), 1)
                }
                None => (best.tok as usize, self.durations[best.dur as usize]),
            };
            let mut advance = if token == blank && duration == 0 {
                1
            } else {
                duration
            };
            if token != blank {
                symbols = if last_frame == frame { symbols + 1 } else { 1 };
                last_frame = frame;
                emitted.push((token, frame));
                if let Some(g) = bias {
                    bias_state = g.step(bias_state, token).0;
                }
                step(token, parity);
                parity ^= 1;
                if advance == 0 && symbols >= MAX_SYMBOLS_PER_FRAME {
                    advance = 1;
                }
            }
            if schedule.is_none() {
                frame += advance;
            }
        }
        emitted
    }
}

#[derive(Clone, Copy)]
pub struct ScheduledStep {
    pub frame: usize,
    /// `None` means blank.
    pub token: Option<usize>,
}

/// Synthetic decision sequence: `tokens` emissions spread over `frames`, with
/// one blank decision per ten emissions (the Mac measurements show about 1.09
/// joint evaluations per prediction-network call).
pub fn synthetic_schedule(
    frames: usize,
    tokens: usize,
    vocab: usize,
    seed: u64,
) -> Vec<ScheduledStep> {
    let mut rng = SplitMix64::new(seed);
    let total = tokens + tokens / 10;
    (0..total)
        .map(|i| ScheduledStep {
            frame: (i * frames / total.max(1)).min(frames.saturating_sub(1)),
            token: if i % 11 == 10 {
                None
            } else {
                Some(rng.below(vocab as u64 - 1) as usize)
            },
        })
        .collect()
}

#[derive(Clone, Copy)]
struct Partial {
    tok_val: f32,
    /// Best biased token score, in place of `tok_val` when decoding with a bias.
    tok_score: f64,
    tok: u32,
    dur_val: f32,
    dur: u32,
}

impl Partial {
    const NONE: Partial = Partial {
        tok_val: f32::NEG_INFINITY,
        tok_score: f64::NEG_INFINITY,
        tok: 0,
        dur_val: f32::NEG_INFINITY,
        dur: 0,
    };
}

struct DecodeState {
    h0: [SendPtrBuf; 2],
    h1: [SendPtrBuf; 2],
    c0: SendPtrBuf,
    c1: SendPtrBuf,
    g: SendPtrBuf,
    partial: SendPtr<Partial>,
    _partials: Vec<Partial>,
}

/// An owned f32 buffer shared across pool threads; phases are ordered by the barrier.
struct SendPtrBuf {
    ptr: SendPtr<f32>,
    _buf: Vec<f32>,
}

impl SendPtrBuf {
    fn new(len: usize) -> Self {
        let mut buf = vec![0.0f32; len];
        SendPtrBuf {
            ptr: SendPtr(buf.as_mut_ptr()),
            _buf: buf,
        }
    }
    fn get(&self) -> *mut f32 {
        self.ptr.get()
    }
}

impl DecodeState {
    fn new(threads: usize, hidden: usize, joint_padded: usize) -> Self {
        let mut partials = vec![Partial::NONE; threads];
        DecodeState {
            h0: [SendPtrBuf::new(hidden), SendPtrBuf::new(hidden)],
            h1: [SendPtrBuf::new(hidden), SendPtrBuf::new(hidden)],
            c0: SendPtrBuf::new(hidden),
            c1: SendPtrBuf::new(hidden),
            g: SendPtrBuf::new(joint_padded),
            partial: SendPtr(partials.as_mut_ptr()),
            _partials: partials,
        }
    }
}

// SAFETY: the fields are owned buffers and `SendPtr`s into them, which are
// already `Sync`; `decode_thread`'s barrier protocol orders every access
// through those pointers across threads.
unsafe impl Sync for DecodeState {}

/// One tier's decoder kernels (`lstm_superblock`, `gemm_rows` and `relu_add`
/// of its module).
#[derive(Clone, Copy)]
struct Kernels {
    lstm: LstmFn,
    gemm_rows: GemmRowsFn,
    relu_add: unsafe fn(*const f32, *const f32, *mut f32, usize),
}

type LstmFn = unsafe fn(
    &Weights,
    Option<&Weights>,
    usize,
    usize,
    *const f32,
    Option<*const f32>,
    *const f32,
    *mut f32,
    *mut f32,
);
type GemmRowsFn =
    unsafe fn(&Weights, usize, usize, *const f32, usize, usize, *mut f32, usize, *const f32);

impl Kernels {
    fn of(tier: Tier) -> Kernels {
        match tier {
            #[cfg(target_arch = "x86_64")]
            Tier::Avx512 => Kernels {
                lstm: x86::lstm_superblock,
                gemm_rows: x86::gemm_rows,
                relu_add: x86::relu_add,
            },
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { .. } => Kernels {
                lstm: avx2::lstm_superblock,
                gemm_rows: avx2::gemm_rows,
                relu_add: avx2::relu_add,
            },
        }
    }
}

/// The AVX-512 kernels.
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use super::{SB, Weights};
    use crate::math::simd::{sigmoid_ps, tanh_ps};
    use std::arch::x86_64::*;

    trait Elem: Copy {
        /// Loads 16 values at `p` as f32.
        ///
        /// # Safety
        /// The CPU must support AVX-512 F, and `p` must be readable for 16
        /// values.
        unsafe fn load16(p: *const Self) -> __m512;
    }

    impl Elem for f32 {
        #[inline]
        #[target_feature(enable = "avx512f")]
        unsafe fn load16(p: *const f32) -> __m512 {
            // SAFETY: 16 readable floats at `p` (trait contract).
            unsafe { _mm512_loadu_ps(p) }
        }
    }

    impl Elem for u16 {
        #[inline]
        #[target_feature(enable = "avx512f")]
        unsafe fn load16(p: *const u16) -> __m512 {
            // SAFETY: 16 readable `u16`s (32 bytes) at `p` (trait contract).
            unsafe { _mm512_cvtph_ps(_mm256_loadu_si256(p.cast())) }
        }
    }

    /// Sum over `k` of superblock weights `[k][64]` times `x[k]`, two k at a time
    /// so eight independent FMA chains hide latency.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F; `w` must be readable for `k * 64`
    /// values and `x` for `k` floats.
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn dot64<E: Elem>(w: *const E, k: usize, x: *const f32) -> [__m512; 4] {
        let mut a = [[_mm512_setzero_ps(); 4]; 2];
        let mut i = 0;
        while i + 2 <= k {
            for u in 0..2 {
                // SAFETY: `i + u < k` (caller contract).
                let xb = _mm512_set1_ps(unsafe { *x.add(i + u) });
                // SAFETY: `i + u < k`, so weight row `i + u` lies inside `w`.
                let wp = unsafe { w.add((i + u) * SB) };
                for v in 0..4 {
                    // SAFETY: 16 of weight row `i + u`'s 64 values.
                    a[u][v] = _mm512_fmadd_ps(unsafe { E::load16(wp.add(v * 16)) }, xb, a[u][v]);
                }
            }
            i += 2;
        }
        if i < k {
            // SAFETY: `i < k` (caller contract).
            let xb = _mm512_set1_ps(unsafe { *x.add(i) });
            // SAFETY: `i < k`, so weight row `i` lies inside `w`.
            let wp = unsafe { w.add(i * SB) };
            for v in 0..4 {
                // SAFETY: 16 of weight row `i`'s 64 values.
                a[0][v] = _mm512_fmadd_ps(unsafe { E::load16(wp.add(v * 16)) }, xb, a[0][v]);
            }
        }
        std::array::from_fn(|v| _mm512_add_ps(a[0][v], a[1][v]))
    }

    fn superblock<E>(w: &[E], sb: usize, k: usize) -> *const E {
        w[sb * k * SB..].as_ptr()
    }

    /// # Safety
    /// The CPU must support AVX-512 F; `w` must hold superblock `sb` of
    /// `k * 64` values (`(sb + 1) * k * 64` in all), and `x` must be readable
    /// for `k` floats.
    #[target_feature(enable = "avx512f")]
    unsafe fn dot_weights(w: &Weights, sb: usize, k: usize, x: *const f32) -> [__m512; 4] {
        // SAFETY: `superblock` points at superblock `sb`, which has `k * 64`
        // values (caller contract); `x` has `k` floats.
        unsafe {
            match w {
                Weights::F32(v) => dot64(superblock(v, sb, k), k, x),
                Weights::F16(v) => dot64(superblock(v, sb, k), k, x),
            }
        }
    }

    /// One LSTM superblock (16 hidden units, gates i, f, g, o): pre-activations from
    /// `wa * xa (+ wb * xb) + bias`, then the cell and hidden updates for those units.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F. `wa` (and `wb`) must hold superblock
    /// `sb` of `k * 64` values, `xa` (and `xb`) must be readable for `k`
    /// floats and `bias` for 64. `c` must be valid for reads and writes and
    /// `h_out` for writes of 16 floats, with no other thread accessing them.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn lstm_superblock(
        wa: &Weights,
        wb: Option<&Weights>,
        sb: usize,
        k: usize,
        xa: *const f32,
        xb: Option<*const f32>,
        bias: *const f32,
        c: *mut f32,
        h_out: *mut f32,
    ) {
        // SAFETY: the weight, input and `bias` reads and the 16-float `c` and
        // `h_out` accesses are exactly those the caller contract covers.
        unsafe {
            let mut g = dot_weights(wa, sb, k, xa);
            if let (Some(wb), Some(xb)) = (wb, xb) {
                let gb = dot_weights(wb, sb, k, xb);
                for v in 0..4 {
                    g[v] = _mm512_add_ps(g[v], gb[v]);
                }
            }
            for v in 0..4 {
                g[v] = _mm512_add_ps(g[v], _mm512_loadu_ps(bias.add(v * 16)));
            }
            let i = sigmoid_ps(g[0]);
            let f = sigmoid_ps(g[1]);
            let gg = tanh_ps(g[2]);
            let o = sigmoid_ps(g[3]);
            let cn = _mm512_fmadd_ps(f, _mm512_loadu_ps(c), _mm512_mul_ps(i, gg));
            _mm512_storeu_ps(c, cn);
            _mm512_storeu_ps(h_out, _mm512_mul_ps(o, tanh_ps(cn)));
        }
    }

    /// `rows` input rows (stride `ldx`) times superblock `sb` of `w` (`[k][64]`) plus bias,
    /// written to `out` (stride `ldo`, 64 values per row).
    ///
    /// # Safety
    /// The CPU must support AVX-512 F. `w` must hold superblock `sb` of
    /// `k * 64` values; `x` must be readable at `r * ldx + i` for `r < rows`,
    /// `i < k`; `bias` must be readable for 64 floats; `out` must be valid for
    /// writes of 64 floats at each `r * ldo` for `r < rows`, with no other
    /// thread accessing them.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn gemm_rows(
        w: &Weights,
        sb: usize,
        k: usize,
        x: *const f32,
        ldx: usize,
        rows: usize,
        out: *mut f32,
        ldo: usize,
        bias: *const f32,
    ) {
        // SAFETY: `superblock` points at superblock `sb`, which has `k * 64`
        // values; the other pointers are passed on under this contract.
        unsafe {
            match w {
                Weights::F32(v) => {
                    gemm_dispatch(superblock(v, sb, k), k, x, ldx, rows, out, ldo, bias)
                }
                Weights::F16(v) => {
                    gemm_dispatch(superblock(v, sb, k), k, x, ldx, rows, out, ldo, bias)
                }
            }
        }
    }

    /// # Safety
    /// As [`gemm_rows`], with `w` readable for `k * 64` values.
    #[target_feature(enable = "avx512f")]
    unsafe fn gemm_dispatch<E: Elem>(
        w: *const E,
        k: usize,
        x: *const f32,
        ldx: usize,
        rows: usize,
        out: *mut f32,
        ldo: usize,
        bias: *const f32,
    ) {
        // SAFETY: the one-row path reads `k * 64` weights, `k` inputs and 64
        // `bias` floats and writes 64 `out` floats; the others pass the same
        // contract to `gemm_r` with `R = rows`.
        unsafe {
            match rows {
                1 => {
                    let acc = dot64(w, k, x);
                    for v in 0..4 {
                        _mm512_storeu_ps(
                            out.add(v * 16),
                            _mm512_add_ps(acc[v], _mm512_loadu_ps(bias.add(v * 16))),
                        );
                    }
                }
                2 => gemm_r::<E, 2>(w, k, x, ldx, out, ldo, bias),
                3 => gemm_r::<E, 3>(w, k, x, ldx, out, ldo, bias),
                4 => gemm_r::<E, 4>(w, k, x, ldx, out, ldo, bias),
                5 => gemm_r::<E, 5>(w, k, x, ldx, out, ldo, bias),
                6 => gemm_r::<E, 6>(w, k, x, ldx, out, ldo, bias),
                _ => unreachable!(),
            }
        }
    }

    /// # Safety
    /// As [`gemm_rows`] with `rows = R`, and `w` readable for `k * 64` values.
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn gemm_r<E: Elem, const R: usize>(
        w: *const E,
        k: usize,
        x: *const f32,
        ldx: usize,
        out: *mut f32,
        ldo: usize,
        bias: *const f32,
    ) {
        let mut acc = [[_mm512_setzero_ps(); 4]; R];
        for i in 0..k {
            // SAFETY: `i < k`, so weight row `i` lies inside `w`.
            let wp = unsafe { w.add(i * SB) };
            // SAFETY: 16 of weight row `i`'s 64 values.
            let wv: [__m512; 4] = std::array::from_fn(|v| unsafe { E::load16(wp.add(v * 16)) });
            for r in 0..R {
                // SAFETY: `r < R` and `i < k` (caller contract).
                let xb = _mm512_set1_ps(unsafe { *x.add(r * ldx + i) });
                for v in 0..4 {
                    acc[r][v] = _mm512_fmadd_ps(wv[v], xb, acc[r][v]);
                }
            }
        }
        for r in 0..R {
            for v in 0..4 {
                // SAFETY: 16 of `bias`'s 64 floats.
                let b = unsafe { _mm512_loadu_ps(bias.add(v * 16)) };
                // SAFETY: 16 of row `r`'s 64 output floats, which only this thread
                // accesses (caller contract).
                unsafe { _mm512_storeu_ps(out.add(r * ldo + v * 16), _mm512_add_ps(acc[r][v], b)) };
            }
        }
    }

    /// `z = max(a + b, 0)` over `n` (a multiple of 16) values.
    ///
    /// # Safety
    /// The CPU must support AVX-512 F and `n` must be a multiple of 16. `a`
    /// and `b` must be readable for `n` floats, and `z` valid for writes of
    /// `n` floats that no other thread accesses.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn relu_add(a: *const f32, b: *const f32, z: *mut f32, n: usize) {
        let zero = _mm512_setzero_ps();
        for i in (0..n).step_by(16) {
            // SAFETY: `i + 16 <= n` (`n % 16 == 0`), inside all three buffers.
            unsafe {
                let s = _mm512_add_ps(_mm512_loadu_ps(a.add(i)), _mm512_loadu_ps(b.add(i)));
                _mm512_storeu_ps(z.add(i), _mm512_max_ps(s, zero));
            }
        }
    }
}

/// The AVX2 kernels: the AVX-512 arithmetic 8 lanes at a time, bit for bit
/// (F16 weights through F16C).
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod avx2 {
    use super::{SB, Weights};
    use crate::math::simd256::{sigmoid_ps, tanh_ps};
    use std::arch::x86_64::*;

    /// 8-lane vectors per 64-row superblock.
    const V: usize = SB / 8;

    trait Elem: Copy {
        /// Loads 8 values at `p` as f32.
        ///
        /// # Safety
        /// The CPU must support AVX2 and F16C, and `p` must be readable for 8
        /// values.
        unsafe fn load8(p: *const Self) -> __m256;
    }

    impl Elem for f32 {
        #[inline]
        #[target_feature(enable = "avx2,f16c")]
        unsafe fn load8(p: *const f32) -> __m256 {
            // SAFETY: 8 readable floats at `p` (trait contract).
            unsafe { _mm256_loadu_ps(p) }
        }
    }

    impl Elem for u16 {
        #[inline]
        #[target_feature(enable = "avx2,f16c")]
        unsafe fn load8(p: *const u16) -> __m256 {
            // SAFETY: 8 readable `u16`s (16 bytes) at `p` (trait contract).
            unsafe { _mm256_cvtph_ps(_mm_loadu_si128(p.cast())) }
        }
    }

    /// Sum over `k` of superblock weights `[k][64]` times `x[k]`, in the AVX-512
    /// order: per output, one FMA chain over even `k` and one over odd `k`,
    /// added at the end. Half the outputs at a time keeps the eight chains in
    /// registers.
    ///
    /// # Safety
    /// The CPU must support AVX2, FMA and F16C; `w` must be readable for
    /// `k * 64` values and `x` for `k` floats.
    #[inline]
    #[target_feature(enable = "avx2,fma,f16c")]
    unsafe fn dot64<E: Elem>(w: *const E, k: usize, x: *const f32) -> [__m256; V] {
        let mut out = [_mm256_setzero_ps(); V];
        for half in 0..2 {
            let mut a = [[_mm256_setzero_ps(); V / 2]; 2];
            let mut i = 0;
            while i < k {
                // The last, odd `k` goes to the even chain, as in AVX-512.
                for u in 0..2.min(k - i) {
                    // SAFETY: `i + u < k` (caller contract).
                    let xb = _mm256_set1_ps(unsafe { *x.add(i + u) });
                    // SAFETY: `i + u < k`, so this half of weight row `i + u`
                    // lies inside `w`.
                    let wp = unsafe { w.add((i + u) * SB + half * SB / 2) };
                    for v in 0..V / 2 {
                        // SAFETY: 8 of the half row's 32 values.
                        let wv = unsafe { E::load8(wp.add(v * 8)) };
                        a[u][v] = _mm256_fmadd_ps(wv, xb, a[u][v]);
                    }
                }
                i += 2;
            }
            for v in 0..V / 2 {
                out[half * V / 2 + v] = _mm256_add_ps(a[0][v], a[1][v]);
            }
        }
        out
    }

    fn superblock<E>(w: &[E], sb: usize, k: usize) -> *const E {
        w[sb * k * SB..].as_ptr()
    }

    /// # Safety
    /// The CPU must support AVX2, FMA and F16C; `w` must hold superblock `sb`
    /// of `k * 64` values (`(sb + 1) * k * 64` in all), and `x` must be
    /// readable for `k` floats.
    #[target_feature(enable = "avx2,fma,f16c")]
    unsafe fn dot_weights(w: &Weights, sb: usize, k: usize, x: *const f32) -> [__m256; V] {
        // SAFETY: `superblock` points at superblock `sb`, which has `k * 64`
        // values (caller contract); `x` has `k` floats.
        unsafe {
            match w {
                Weights::F32(v) => dot64(superblock(v, sb, k), k, x),
                Weights::F16(v) => dot64(superblock(v, sb, k), k, x),
            }
        }
    }

    /// As the AVX-512 `lstm_superblock`.
    ///
    /// # Safety
    /// The CPU must support AVX2, FMA and F16C. `wa` (and `wb`) must hold
    /// superblock `sb` of `k * 64` values, `xa` (and `xb`) must be readable
    /// for `k` floats and `bias` for 64. `c` must be valid for reads and writes
    /// and `h_out` for writes of 16 floats, with no other thread accessing
    /// them.
    #[target_feature(enable = "avx2,fma,f16c")]
    pub unsafe fn lstm_superblock(
        wa: &Weights,
        wb: Option<&Weights>,
        sb: usize,
        k: usize,
        xa: *const f32,
        xb: Option<*const f32>,
        bias: *const f32,
        c: *mut f32,
        h_out: *mut f32,
    ) {
        // SAFETY: the weight, input and `bias` reads and the 16-float `c` and
        // `h_out` accesses are exactly those the caller contract covers.
        unsafe {
            let mut g = dot_weights(wa, sb, k, xa);
            if let (Some(wb), Some(xb)) = (wb, xb) {
                let gb = dot_weights(wb, sb, k, xb);
                for v in 0..V {
                    g[v] = _mm256_add_ps(g[v], gb[v]);
                }
            }
            for v in 0..V {
                g[v] = _mm256_add_ps(g[v], _mm256_loadu_ps(bias.add(v * 8)));
            }
            // Gate `q` of units `8 * h..8 * h + 8` is vector `2 * q + h`.
            for h in 0..2 {
                let i = sigmoid_ps(g[h]);
                let f = sigmoid_ps(g[2 + h]);
                let gg = tanh_ps(g[4 + h]);
                let o = sigmoid_ps(g[6 + h]);
                let cn = _mm256_fmadd_ps(f, _mm256_loadu_ps(c.add(h * 8)), _mm256_mul_ps(i, gg));
                _mm256_storeu_ps(c.add(h * 8), cn);
                _mm256_storeu_ps(h_out.add(h * 8), _mm256_mul_ps(o, tanh_ps(cn)));
            }
        }
    }

    /// As the AVX-512 `gemm_rows`.
    ///
    /// # Safety
    /// The CPU must support AVX2, FMA and F16C. `w` must hold superblock `sb`
    /// of `k * 64` values; `x` must be readable at `r * ldx + i` for
    /// `r < rows`, `i < k`; `bias` must be readable for 64 floats; `out` must
    /// be valid for writes of 64 floats at each `r * ldo` for `r < rows`, with
    /// no other thread accessing them.
    #[target_feature(enable = "avx2,fma,f16c")]
    pub unsafe fn gemm_rows(
        w: &Weights,
        sb: usize,
        k: usize,
        x: *const f32,
        ldx: usize,
        rows: usize,
        out: *mut f32,
        ldo: usize,
        bias: *const f32,
    ) {
        // SAFETY: `superblock` points at superblock `sb`, which has `k * 64`
        // values; the other pointers are passed on under this contract.
        unsafe {
            match w {
                Weights::F32(v) => {
                    gemm_dispatch(superblock(v, sb, k), k, x, ldx, rows, out, ldo, bias)
                }
                Weights::F16(v) => {
                    gemm_dispatch(superblock(v, sb, k), k, x, ldx, rows, out, ldo, bias)
                }
            }
        }
    }

    /// # Safety
    /// As [`gemm_rows`], with `w` readable for `k * 64` values.
    #[target_feature(enable = "avx2,fma,f16c")]
    unsafe fn gemm_dispatch<E: Elem>(
        w: *const E,
        k: usize,
        x: *const f32,
        ldx: usize,
        rows: usize,
        out: *mut f32,
        ldo: usize,
        bias: *const f32,
    ) {
        // SAFETY: the one-row path reads `k * 64` weights, `k` inputs and 64
        // `bias` floats and writes 64 `out` floats; the others pass the same
        // contract to `gemm_r` with `R = rows`.
        unsafe {
            match rows {
                1 => {
                    let acc = dot64(w, k, x);
                    for v in 0..V {
                        _mm256_storeu_ps(
                            out.add(v * 8),
                            _mm256_add_ps(acc[v], _mm256_loadu_ps(bias.add(v * 8))),
                        );
                    }
                }
                2 => gemm_r::<E, 2>(w, k, x, ldx, out, ldo, bias),
                3 => gemm_r::<E, 3>(w, k, x, ldx, out, ldo, bias),
                4 => gemm_r::<E, 4>(w, k, x, ldx, out, ldo, bias),
                5 => gemm_r::<E, 5>(w, k, x, ldx, out, ldo, bias),
                6 => gemm_r::<E, 6>(w, k, x, ldx, out, ldo, bias),
                _ => unreachable!(),
            }
        }
    }

    /// `R` rows against the superblock, 16 of its 64 outputs at a time.
    ///
    /// # Safety
    /// As [`gemm_rows`] with `rows = R`, and `w` readable for `k * 64` values.
    #[inline]
    #[target_feature(enable = "avx2,fma,f16c")]
    unsafe fn gemm_r<E: Elem, const R: usize>(
        w: *const E,
        k: usize,
        x: *const f32,
        ldx: usize,
        out: *mut f32,
        ldo: usize,
        bias: *const f32,
    ) {
        for col in (0..SB).step_by(16) {
            let mut acc = [[_mm256_setzero_ps(); 2]; R];
            for i in 0..k {
                // SAFETY: `i < k` and `col < 64`, so the 16 values from `col` lie
                // in weight row `i`.
                let wp = unsafe { w.add(i * SB + col) };
                // SAFETY: 8 of those 16 values.
                let wv: [__m256; 2] = std::array::from_fn(|v| unsafe { E::load8(wp.add(v * 8)) });
                for r in 0..R {
                    // SAFETY: `r < R` and `i < k` (caller contract).
                    let xb = _mm256_set1_ps(unsafe { *x.add(r * ldx + i) });
                    for v in 0..2 {
                        acc[r][v] = _mm256_fmadd_ps(wv[v], xb, acc[r][v]);
                    }
                }
            }
            for r in 0..R {
                for v in 0..2 {
                    // SAFETY: 8 of `bias`'s 64 floats.
                    let b = unsafe { _mm256_loadu_ps(bias.add(col + v * 8)) };
                    // SAFETY: 8 of row `r`'s 64 output floats, which only this
                    // thread accesses (caller contract).
                    unsafe {
                        _mm256_storeu_ps(
                            out.add(r * ldo + col + v * 8),
                            _mm256_add_ps(acc[r][v], b),
                        )
                    };
                }
            }
        }
    }

    /// `z = max(a + b, 0)` over `n` (a multiple of 8) values.
    ///
    /// # Safety
    /// The CPU must support AVX2 and `n` must be a multiple of 8. `a` and `b`
    /// must be readable for `n` floats, and `z` valid for writes of `n` floats
    /// that no other thread accesses.
    #[target_feature(enable = "avx2")]
    pub unsafe fn relu_add(a: *const f32, b: *const f32, z: *mut f32, n: usize) {
        let zero = _mm256_setzero_ps();
        for i in (0..n).step_by(8) {
            // SAFETY: `i + 8 <= n` (`n % 8 == 0`), inside all three buffers.
            unsafe {
                let s = _mm256_add_ps(_mm256_loadu_ps(a.add(i)), _mm256_loadu_ps(b.add(i)));
                _mm256_storeu_ps(z.add(i), _mm256_max_ps(s, zero));
            }
        }
    }
}

/// Scalar f64 reference: encoder projection, prediction network, joint and the
/// same greedy rules and bias bonuses (added in f64). Returns emissions and
/// the final logits of each decision, bonuses included.
pub mod reference {
    use super::{DecoderParams, MAX_SYMBOLS_PER_FRAME};
    use crate::bias::BiasGraph;

    fn sigmoid(x: f64) -> f64 {
        1.0 / (1.0 + (-x).exp())
    }

    fn matvec(w: &[f32], rows: usize, k: usize, x: &[f64], bias: &[f32]) -> Vec<f64> {
        (0..rows)
            .map(|r| {
                let row = &w[r * k..(r + 1) * k];
                row.iter().zip(x).map(|(&a, &b)| a as f64 * b).sum::<f64>() + bias[r] as f64
            })
            .collect()
    }

    struct Lstm {
        h: [Vec<f64>; 2],
        c: [Vec<f64>; 2],
    }

    fn lstm_step(p: &DecoderParams, s: &mut Lstm, token: usize) -> Vec<f64> {
        let hd = p.hidden;
        let mut x: Vec<f64> = p.embed[token * hd..(token + 1) * hd]
            .iter()
            .map(|&v| v as f64)
            .collect();
        for l in 0..2 {
            let a = matvec(&p.w_ih[l], 4 * hd, hd, &x, &p.b_ih[l]);
            let b = matvec(&p.w_hh[l], 4 * hd, hd, &s.h[l], &p.b_hh[l]);
            for u in 0..hd {
                let gate = |g: usize| a[g * hd + u] + b[g * hd + u];
                let (i, f, gg, o) = (
                    sigmoid(gate(0)),
                    sigmoid(gate(1)),
                    gate(2).tanh(),
                    sigmoid(gate(3)),
                );
                s.c[l][u] = f * s.c[l][u] + i * gg;
                s.h[l][u] = o * s.c[l][u].tanh();
            }
            x = s.h[l].clone();
        }
        let zero = vec![0.0f32; p.joint];
        let g = matvec(&p.w_pred, p.joint, hd, &x, &zero);
        g.iter()
            .zip(&p.b_pred)
            .map(|(v, &b)| v + b as f64)
            .collect()
    }

    pub struct Decision {
        pub frame: usize,
        pub token: usize,
        pub duration: usize,
        /// Token logits followed by duration logits.
        pub logits: Vec<f64>,
    }

    /// Adds each non-blank token's bonus at `state` to its score.
    fn add_bonuses(scores: &mut [f64], g: &BiasGraph, state: crate::bias::BiasState) {
        for (t, v) in scores.iter_mut().enumerate() {
            *v += f64::from(g.step(state, t).1);
        }
    }

    /// The first maximum of `scores` over `r`.
    fn argmax(scores: &[f64], r: std::ops::Range<usize>) -> usize {
        r.clone().fold(
            r.start,
            |best, i| if scores[i] > scores[best] { i } else { best },
        )
    }

    /// The token decision rule (DESIGN §1.2) for one row of token logits,
    /// blank last: the first maximum of `f64(logit) + f64(bonus)`, where
    /// blank gets no bonus. `state` is the bias state before the decision.
    pub fn token_decision(
        logits: &[f32],
        bias: Option<&BiasGraph>,
        state: crate::bias::BiasState,
    ) -> usize {
        let mut scores: Vec<f64> = logits.iter().map(|&v| f64::from(v)).collect();
        if let Some(g) = bias {
            let blank = scores.len() - 1;
            add_bonuses(&mut scores[..blank], g, state);
        }
        argmax(&scores, 0..scores.len())
    }

    pub fn decode(
        p: &DecoderParams,
        enc: &[f32],
        frames: usize,
        bias: Option<&BiasGraph>,
    ) -> (Vec<(usize, usize)>, Vec<Decision>) {
        let blank = p.blank();
        let bias = bias.filter(|g| !g.is_empty());
        if let Some(g) = bias {
            assert_eq!(g.tokens(), blank, "bias vocabulary size");
        }
        let mut bias_state = BiasGraph::ROOT;
        let mut s = Lstm {
            h: [vec![0.0; p.hidden], vec![0.0; p.hidden]],
            c: [vec![0.0; p.hidden], vec![0.0; p.hidden]],
        };
        let mut g = lstm_step(p, &mut s, blank);
        let (mut frame, mut last_frame, mut symbols) = (0usize, usize::MAX, 0usize);
        let (mut emitted, mut decisions) = (Vec::new(), Vec::new());
        while frame < frames {
            let x: Vec<f64> = enc[frame * p.enc_dim..(frame + 1) * p.enc_dim]
                .iter()
                .map(|&v| v as f64)
                .collect();
            let f = matvec(&p.w_enc, p.joint, p.enc_dim, &x, &p.b_enc);
            let z: Vec<f64> = f.iter().zip(&g).map(|(a, b)| (a + b).max(0.0)).collect();
            let mut logits = matvec(&p.w_out, p.out_rows(), p.joint, &z, &p.b_out);
            if let Some(g) = bias {
                add_bonuses(&mut logits[..blank], g, bias_state);
            }
            let token = argmax(&logits, 0..p.vocab);
            let duration = p.durations[argmax(&logits, p.vocab..p.out_rows()) - p.vocab];
            decisions.push(Decision {
                frame,
                token,
                duration,
                logits,
            });
            let mut advance = if token == blank && duration == 0 {
                1
            } else {
                duration
            };
            if token != blank {
                symbols = if last_frame == frame { symbols + 1 } else { 1 };
                last_frame = frame;
                emitted.push((token, frame));
                g = lstm_step(p, &mut s, token);
                if let Some(b) = bias {
                    bias_state = b.step(bias_state, token).0;
                }
                if advance == 0 && symbols >= MAX_SYMBOLS_PER_FRAME {
                    advance = 1;
                }
            }
            frame += advance;
        }
        (emitted, decisions)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tier_pools as pools;

    /// [`crate::tier_pools`] as an iterator.
    fn tier_pools(threads: usize) -> impl Iterator<Item = ThreadPool> {
        pools(threads).into_iter()
    }

    /// A hand-built decoder without even the blank token must be rejected at
    /// construction: decoding indexes its embedding table with `vocab - 1`.
    #[test]
    #[should_panic(expected = "the vocabulary must include blank")]
    fn empty_vocabulary_is_rejected() {
        let mut p = DecoderParams::random(2, 16, 16, 16, 1);
        p.vocab = 0;
        PackedDecoder::new(&p, Storage::F32);
    }

    fn encoder_frames(frames: usize, dim: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..frames * dim).map(|_| rng.next_gaussian()).collect()
    }

    #[test]
    fn matches_f64_reference() {
        if crate::Tier::available().is_empty() {
            return;
        }
        // Small shapes with padding: 38 output rows, joint 48 (not a multiple of 64).
        let p = DecoderParams::random(33, 32, 40, 48, 11);
        let frames = 40;
        let enc = encoder_frames(frames, p.enc_dim, 12);
        let (expected, decisions) = reference::decode(&p, &enc, frames, None);
        assert!(expected.len() > 3, "synthetic model should emit tokens");
        for storage in [Storage::F32, Storage::F16] {
            let d = PackedDecoder::new(&p, storage);
            for (threads, pool) in [1, 3]
                .into_iter()
                .flat_map(|n| tier_pools(n).map(move |p| (n, p)))
            {
                let tier = pool.tier();
                let proj = d.project_encoder(&pool, &enc, frames);
                // Projection agrees with the reference to f32 rounding.
                let jp = d.joint_padded();
                for t in [0, frames - 1] {
                    for j in 0..p.joint {
                        let x: f64 = (0..p.enc_dim)
                            .map(|i| {
                                p.w_enc[j * p.enc_dim + i] as f64 * enc[t * p.enc_dim + i] as f64
                            })
                            .sum::<f64>()
                            + p.b_enc[j] as f64;
                        assert!((proj[t * jp + j] as f64 - x).abs() < 1e-5, "{tier}");
                    }
                }
                let got = d.decode(&pool, &proj, frames, None, None);
                assert_eq!(got, expected, "{tier} {storage:?}, {threads} threads");
            }
        }
        // Make sure the comparison exercised real margins, not ties.
        let min_gap = decisions
            .iter()
            .map(|dec| {
                let mut v: Vec<f64> = dec.logits[..p.vocab].to_vec();
                v.sort_by(|a, b| b.partial_cmp(a).unwrap());
                v[0] - v[1]
            })
            .fold(f64::INFINITY, f64::min);
        assert!(
            min_gap > 1e-4,
            "token logits too close to compare: {min_gap}"
        );
    }

    /// Every tier projects the same encoder frames bit for bit (one-row
    /// and six-row kernels) and decodes the same emissions.
    #[test]
    fn tiers_match_bit_for_bit() {
        let p = DecoderParams::random(71, 32, 40, 48, 21);
        for storage in [Storage::F32, Storage::F16] {
            let d = PackedDecoder::new(&p, storage);
            for frames in [1, 13, 48] {
                let enc = encoder_frames(frames, p.enc_dim, 22);
                let runs: Vec<_> = tier_pools(2)
                    .map(|pool| {
                        let proj = d.project_encoder(&pool, &enc, frames);
                        let bits: Vec<u32> = proj.iter().map(|v| v.to_bits()).collect();
                        (bits, d.decode(&pool, &proj, frames, None, None))
                    })
                    .collect();
                for r in &runs {
                    assert!(r == &runs[0], "{storage:?} frames={frames}");
                }
            }
        }
    }

    /// Packed emissions for every storage, a few thread counts and every
    /// tier, which must agree.
    fn packed_decode(
        p: &DecoderParams,
        enc: &[f32],
        frames: usize,
        bias: Option<&BiasGraph>,
    ) -> Vec<(usize, usize)> {
        let mut out: Option<Vec<(usize, usize)>> = None;
        for storage in [Storage::F32, Storage::F16] {
            let d = PackedDecoder::new(p, storage);
            for (threads, pool) in [1, 2, 3]
                .into_iter()
                .flat_map(|n| tier_pools(n).map(move |p| (n, p)))
            {
                let tier = pool.tier();
                let proj = d.project_encoder(&pool, enc, frames);
                let got = d.decode(&pool, &proj, frames, None, bias);
                match &out {
                    Some(o) => assert_eq!(&got, o, "{tier} {storage:?}, {threads} threads"),
                    None => out = Some(got),
                }
            }
        }
        out.unwrap()
    }

    fn graph(phrases: &[(&[usize], f32)], tokens: usize) -> BiasGraph {
        let phrases: Vec<(Vec<usize>, f32)> =
            phrases.iter().map(|(p, s)| (p.to_vec(), *s)).collect();
        BiasGraph::new(&phrases, tokens).unwrap()
    }

    /// Emissions of both decoders before word boosting existed (captured
    /// from `main`), so a regression shared by the packed and reference
    /// decoders cannot pass; an empty graph must give them bit for bit. The
    /// second list is `(token, frame, repeats)`.
    #[test]
    fn frozen_synthetic_emissions() {
        if crate::Tier::available().is_empty() {
            return;
        }
        let first: &[(usize, usize)] = &[
            (19, 0),
            (1, 3),
            (19, 6),
            (1, 9),
            (1, 12),
            (19, 15),
            (18, 18),
            (19, 21),
            (1, 27),
            (1, 30),
            (19, 33),
            (19, 36),
            (1, 39),
        ];
        #[rustfmt::skip]
        let runs: &[(usize, usize, usize)] = &[
            (57, 0, 10), (57, 1, 10), (57, 2, 10), (43, 3, 10), (43, 4, 10), (0, 5, 1),
            (57, 7, 10), (57, 8, 10), (67, 9, 10), (43, 10, 10), (67, 11, 10), (57, 12, 10),
            (67, 13, 10), (67, 14, 10), (67, 15, 10), (0, 16, 10), (67, 17, 10), (43, 18, 10),
            (47, 19, 10), (57, 20, 10), (43, 21, 10), (67, 22, 1), (57, 24, 10), (57, 25, 10),
            (43, 26, 1), (57, 28, 10), (9, 29, 10), (57, 30, 10), (9, 31, 10), (67, 32, 1),
            (43, 34, 1), (43, 36, 1), (57, 38, 10), (43, 39, 10), (67, 40, 10), (28, 41, 10),
            (67, 42, 10), (57, 43, 10), (43, 44, 10), (43, 45, 10), (67, 46, 10), (57, 47, 10),
        ];
        let second: Vec<(usize, usize)> = runs
            .iter()
            .flat_map(|&(t, f, n)| std::iter::repeat_n((t, f), n))
            .collect();
        for (vocab, seed, frames, expected) in [(33, 11, 40, first), (71, 21, 48, &second[..])] {
            let p = DecoderParams::random(vocab, 32, 40, 48, seed);
            let enc = encoder_frames(frames, p.enc_dim, seed + 1);
            assert_eq!(reference::decode(&p, &enc, frames, None).0, expected);
            assert_eq!(packed_decode(&p, &enc, frames, None), expected);
            let empty = BiasGraph::new(&[], vocab - 1).unwrap();
            assert_eq!(
                reference::decode(&p, &enc, frames, Some(&empty)).0,
                expected
            );
            assert_eq!(packed_decode(&p, &enc, frames, Some(&empty)), expected);
        }
    }

    /// Synthetic weights whose joint ignores the prediction network: token and
    /// duration logits are `b_out`, plus encoder dimension 0 of the frame
    /// (when positive) on the blank row.
    fn controlled(vocab: usize, b_out: impl Fn(usize) -> f32) -> DecoderParams {
        let mut p = DecoderParams::random(vocab, 32, 40, 48, 9);
        p.w_pred.fill(0.0);
        p.b_pred.fill(0.0);
        p.w_enc.fill(0.0);
        p.w_enc[0] = 1.0;
        p.b_enc.fill(0.0);
        p.w_out.fill(0.0);
        p.w_out[(vocab - 1) * p.joint] = 1.0;
        p.b_out = (0..p.out_rows()).map(b_out).collect();
        p
    }

    /// Frames whose encoder dimension 0 is `blank[t]`; the rest are zero.
    fn blank_frames(p: &DecoderParams, blank: &[f32]) -> Vec<f32> {
        let mut enc = vec![0.0f32; blank.len() * p.enc_dim];
        for (t, &b) in blank.iter().enumerate() {
            enc[t * p.enc_dim] = b;
        }
        enc
    }

    #[test]
    fn biased_ties_resolve_in_f64() {
        if crate::Tier::available().is_empty() {
            return;
        }
        // Tokens 0 and 64 (in different superblocks, so different threads with
        // 2 or more) have raw logits 0 and 2^-16 and the same bonus of about
        // 1414. In f32 both sums round alike and the first would win;
        // exactly, 64 wins.
        let p = controlled(71, |r| if r == 64 { 2f32.powi(-16) } else { 0.0 });
        let frames = 3;
        let enc = blank_frames(&p, &[0.0; 3]);
        let g = graph(&[(&[0], 1000.0), (&[64], 1000.0)], 70);
        let (b0, b64) = (g.step(BiasGraph::ROOT, 0).1, g.step(BiasGraph::ROOT, 64).1);
        assert_eq!(b0, b64);
        assert_eq!(b0 + 2f32.powi(-16), b0, "the tie must exist in f32");
        let (expected, _) = reference::decode(&p, &enc, frames, Some(&g));
        assert!(expected.iter().all(|e| e.0 == 64), "{expected:?}");
        assert_eq!(packed_decode(&p, &enc, frames, Some(&g)), expected);
    }

    #[test]
    fn blank_keeps_the_bias_state() {
        if crate::Tier::available().is_empty() {
            return;
        }
        // Token 3 has raw logit -0.5, token 5 has 0, every other token -10 and
        // duration 1 wins. The blank logit is 0 on frames 0 and 4 and 5 elsewhere.
        let (a, b) = (3, 5);
        let p = controlled(33, |r| match r {
            3 => -0.5,
            34 => 1.0,
            5 | 32.. => 0.0,
            _ => -10.0,
        });
        let frames = 8;
        let enc = blank_frames(&p, &[0.0, 5.0, 5.0, 5.0, 0.0, 5.0, 5.0, 5.0]);
        // Unbiased, token 5 wins frames 0 and 4.
        assert_eq!(
            reference::decode(&p, &enc, frames, None).0,
            [(b, 0), (b, 4)]
        );
        // With "3 5" boosted, 3 wins at the root (0.914 against 0). After
        // three blanks, 5 must still continue the phrase (4.35, below the
        // blank's 5 on frames 1-3); back at the root, 3 would win again.
        let g = graph(&[(&[a, b], 1.0)], 32);
        let (expected, _) = reference::decode(&p, &enc, frames, Some(&g));
        assert_eq!(expected, [(a, 0), (b, 4)]);
        assert_eq!(packed_decode(&p, &enc, frames, Some(&g)), expected);
    }

    #[test]
    fn forced_advance_holds_under_bias() {
        if crate::Tier::available().is_empty() {
            return;
        }
        // Duration 0 always wins and the bias makes token 7 beat blank on every
        // decision, so each frame emits MAX_SYMBOLS_PER_FRAME sevens and advances.
        let p = controlled(33, |r| if r == 33 { 1.0 } else { 0.0 });
        let frames = 3;
        let enc = blank_frames(&p, &[0.0; 3]);
        let expected: Vec<(usize, usize)> = (0..frames)
            .flat_map(|f| std::iter::repeat_n((7, f), MAX_SYMBOLS_PER_FRAME))
            .collect();
        let g = graph(&[(&[7], 100.0)], 32);
        assert_eq!(reference::decode(&p, &enc, frames, Some(&g)).0, expected);
        assert_eq!(packed_decode(&p, &enc, frames, Some(&g)), expected);
    }

    #[test]
    fn packed_matches_reference_with_bias() {
        if crate::Tier::available().is_empty() {
            return;
        }
        // 70 tokens put the token rows across two superblocks, so the bonuses
        // must be split between threads.
        for (vocab, seed) in [(33, 11), (71, 21)] {
            let p = DecoderParams::random(vocab, 32, 40, 48, seed);
            let frames = 48;
            let enc = encoder_frames(frames, p.enc_dim, seed + 1);
            let (plain, _) = reference::decode(&p, &enc, frames, None);
            let toks: Vec<usize> = plain.iter().map(|e| e.0).collect();
            assert!(toks.len() > 6, "synthetic model should emit tokens");
            // Phrases that partly match what the model says, overlap and diverge.
            let phrases = [
                toks[1..4].to_vec(),
                vec![toks[1], toks[2], (toks[3] + 1) % (vocab - 1)],
                toks[4..6].to_vec(),
                vec![vocab - 2, 0, vocab / 2],
                vec![5],
            ];
            for strengths in [[1.0f32; 5], [0.25, 4.0, 1.41, 2.83, 0.5], [2.0; 5]] {
                let weighted: Vec<(Vec<usize>, f32)> =
                    phrases.iter().cloned().zip(strengths).collect();
                let g = BiasGraph::new(&weighted, vocab - 1).unwrap();
                let (expected, decisions) = reference::decode(&p, &enc, frames, Some(&g));
                assert_ne!(expected, plain, "bias should change the output");
                assert_eq!(
                    packed_decode(&p, &enc, frames, Some(&g)),
                    expected,
                    "vocab {vocab}, strengths {strengths:?}"
                );
                let min_gap = decisions
                    .iter()
                    .map(|dec| {
                        let mut v: Vec<f64> = dec.logits[..p.vocab].to_vec();
                        v.sort_by(|a, b| b.partial_cmp(a).unwrap());
                        v[0] - v[1]
                    })
                    .fold(f64::INFINITY, f64::min);
                assert!(min_gap > 1e-4, "token logits too close: {min_gap}");
            }
        }
    }

    #[test]
    fn schedule_controls_emissions() {
        if crate::Tier::available().is_empty() {
            return;
        }
        let p = DecoderParams::random(33, 32, 40, 48, 3);
        let d = PackedDecoder::new(&p, Storage::F16);
        let frames = 30;
        let sched = synthetic_schedule(frames, 20, p.vocab, 5);
        let expected: Vec<(usize, usize)> = sched
            .iter()
            .filter_map(|s| s.token.map(|t| (t, s.frame)))
            .collect();
        for pool in tier_pools(2) {
            let proj = d.project_encoder(&pool, &encoder_frames(frames, p.enc_dim, 4), frames);
            let got = d.decode(&pool, &proj, frames, Some(&sched), None);
            assert_eq!(got, expected, "{}", pool.tier());
            assert_eq!(got.len(), 20);
        }
    }
}
