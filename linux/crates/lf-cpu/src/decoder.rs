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
use crate::{SendPtr, ThreadPool, split_range};

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

    fn joint_padded(&self) -> usize {
        self.joint.div_ceil(SB) * SB
    }

    pub fn joint_dim(&self) -> usize {
        self.joint
    }

    /// Encoder-side joint projection for `frames` frames of `enc` (`[frames][enc_dim]`),
    /// written as `[frames][joint_padded]`.
    pub fn project_encoder(&self, pool: &ThreadPool, enc: &[f32], frames: usize) -> Vec<f32> {
        assert!(crate::cpu_supported(), "AVX-512 required");
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
                unsafe {
                    x86::gemm_rows(
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
    /// joint evaluations. Returns `(token, frame)` emissions.
    pub fn decode(
        &self,
        pool: &ThreadPool,
        enc_proj: &[f32],
        frames: usize,
        schedule: Option<&[ScheduledStep]>,
    ) -> Vec<(usize, usize)> {
        assert!(crate::cpu_supported(), "AVX-512 required");
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
        let state = DecodeState::new(n, h, jp);
        let barrier = SpinBarrier::new(n);
        let result = Mutex::new(Vec::new());
        pool.run(&|idx| {
            let emitted =
                unsafe { self.decode_thread(idx, n, &state, &barrier, enc_proj, frames, schedule) };
            if idx == 0 {
                *result.lock().unwrap() = emitted;
            }
        });
        result.into_inner().unwrap()
    }

    #[allow(clippy::too_many_arguments)]
    unsafe fn decode_thread(
        &self,
        idx: usize,
        n: usize,
        st: &DecodeState,
        barrier: &SpinBarrier,
        enc_proj: &[f32],
        frames: usize,
        schedule: Option<&[ScheduledStep]>,
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

        let step = |token: usize, parity: usize| unsafe {
            let (h0_in, h0_out) = (st.h0[parity].get(), st.h0[1 - parity].get());
            let (h1_in, h1_out) = (st.h1[parity].get(), st.h1[1 - parity].get());
            for sb in lstm_sbs.clone() {
                let bias = self.table0.as_ptr().add(token * 4 * h + sb * SB);
                x86::lstm_superblock(
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
                x86::lstm_superblock(
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
                x86::gemm_rows(
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
            // Joint: z = relu(enc_proj[frame] + g); logits for this thread's rows.
            unsafe {
                x86::relu_add(
                    enc_proj.as_ptr().add(frame * jp),
                    st.g.get(),
                    z.as_mut_ptr(),
                    jp,
                );
                let mut best = Partial::NONE;
                for sb in out_sbs.clone() {
                    let mut logits = [0.0f32; SB];
                    x86::gemm_rows(
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
                let p = unsafe { *st.partial.get().add(i) };
                if p.tok_val > best.tok_val {
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
    tok: u32,
    dur_val: f32,
    dur: u32,
}

impl Partial {
    const NONE: Partial = Partial {
        tok_val: f32::NEG_INFINITY,
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

unsafe impl Sync for DecodeState {}

#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use super::{SB, Weights};
    use crate::math::simd::{sigmoid_ps, tanh_ps};
    use std::arch::x86_64::*;

    trait Elem: Copy {
        unsafe fn load16(p: *const Self) -> __m512;
    }

    impl Elem for f32 {
        #[inline]
        #[target_feature(enable = "avx512f")]
        unsafe fn load16(p: *const f32) -> __m512 {
            unsafe { _mm512_loadu_ps(p) }
        }
    }

    impl Elem for u16 {
        #[inline]
        #[target_feature(enable = "avx512f")]
        unsafe fn load16(p: *const u16) -> __m512 {
            unsafe { _mm512_cvtph_ps(_mm256_loadu_si256(p.cast())) }
        }
    }

    /// Sum over `k` of superblock weights `[k][64]` times `x[k]`, two k at a time
    /// so eight independent FMA chains hide latency.
    #[inline]
    #[target_feature(enable = "avx512f")]
    unsafe fn dot64<E: Elem>(w: *const E, k: usize, x: *const f32) -> [__m512; 4] {
        let mut a = [[_mm512_setzero_ps(); 4]; 2];
        let mut i = 0;
        while i + 2 <= k {
            for u in 0..2 {
                let xb = _mm512_set1_ps(unsafe { *x.add(i + u) });
                let wp = unsafe { w.add((i + u) * SB) };
                for v in 0..4 {
                    a[u][v] = _mm512_fmadd_ps(unsafe { E::load16(wp.add(v * 16)) }, xb, a[u][v]);
                }
            }
            i += 2;
        }
        if i < k {
            let xb = _mm512_set1_ps(unsafe { *x.add(i) });
            let wp = unsafe { w.add(i * SB) };
            for v in 0..4 {
                a[0][v] = _mm512_fmadd_ps(unsafe { E::load16(wp.add(v * 16)) }, xb, a[0][v]);
            }
        }
        std::array::from_fn(|v| _mm512_add_ps(a[0][v], a[1][v]))
    }

    fn superblock<E>(w: &[E], sb: usize, k: usize) -> *const E {
        w[sb * k * SB..].as_ptr()
    }

    #[target_feature(enable = "avx512f")]
    unsafe fn dot_weights(w: &Weights, sb: usize, k: usize, x: *const f32) -> [__m512; 4] {
        unsafe {
            match w {
                Weights::F32(v) => dot64(superblock(v, sb, k), k, x),
                Weights::F16(v) => dot64(superblock(v, sb, k), k, x),
            }
        }
    }

    /// One LSTM superblock (16 hidden units, gates i, f, g, o): pre-activations from
    /// `wa * xa (+ wb * xb) + bias`, then the cell and hidden updates for those units.
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
            let wp = unsafe { w.add(i * SB) };
            let wv: [__m512; 4] = std::array::from_fn(|v| unsafe { E::load16(wp.add(v * 16)) });
            for r in 0..R {
                let xb = _mm512_set1_ps(unsafe { *x.add(r * ldx + i) });
                for v in 0..4 {
                    acc[r][v] = _mm512_fmadd_ps(wv[v], xb, acc[r][v]);
                }
            }
        }
        for r in 0..R {
            for v in 0..4 {
                let b = unsafe { _mm512_loadu_ps(bias.add(v * 16)) };
                unsafe { _mm512_storeu_ps(out.add(r * ldo + v * 16), _mm512_add_ps(acc[r][v], b)) };
            }
        }
    }

    /// `z = max(a + b, 0)` over `n` (a multiple of 16) values.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn relu_add(a: *const f32, b: *const f32, z: *mut f32, n: usize) {
        let zero = _mm512_setzero_ps();
        for i in (0..n).step_by(16) {
            unsafe {
                let s = _mm512_add_ps(_mm512_loadu_ps(a.add(i)), _mm512_loadu_ps(b.add(i)));
                _mm512_storeu_ps(z.add(i), _mm512_max_ps(s, zero));
            }
        }
    }
}

/// Scalar f64 reference: encoder projection, prediction network, joint and the
/// same greedy rules. Returns emissions and the final logits of each decision.
pub mod reference {
    use super::{DecoderParams, MAX_SYMBOLS_PER_FRAME};

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

    pub fn decode(
        p: &DecoderParams,
        enc: &[f32],
        frames: usize,
    ) -> (Vec<(usize, usize)>, Vec<Decision>) {
        let blank = p.blank();
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
            let logits = matvec(&p.w_out, p.out_rows(), p.joint, &z, &p.b_out);
            let argmax = |r: std::ops::Range<usize>| {
                r.clone().fold(
                    r.start,
                    |best, i| if logits[i] > logits[best] { i } else { best },
                )
            };
            let token = argmax(0..p.vocab);
            let duration = p.durations[argmax(p.vocab..p.out_rows()) - p.vocab];
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

    fn encoder_frames(frames: usize, dim: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix64::new(seed);
        (0..frames * dim).map(|_| rng.next_gaussian()).collect()
    }

    #[test]
    fn matches_f64_reference() {
        if !crate::cpu_supported() {
            return;
        }
        // Small shapes with padding: 38 output rows, joint 48 (not a multiple of 64).
        let p = DecoderParams::random(33, 32, 40, 48, 11);
        let frames = 40;
        let enc = encoder_frames(frames, p.enc_dim, 12);
        let (expected, decisions) = reference::decode(&p, &enc, frames);
        assert!(expected.len() > 3, "synthetic model should emit tokens");
        for storage in [Storage::F32, Storage::F16] {
            let d = PackedDecoder::new(&p, storage);
            for threads in [1, 3] {
                let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
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
                        assert!((proj[t * jp + j] as f64 - x).abs() < 1e-5);
                    }
                }
                let got = d.decode(&pool, &proj, frames, None);
                assert_eq!(got, expected, "{storage:?}, {threads} threads");
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

    #[test]
    fn schedule_controls_emissions() {
        if !crate::cpu_supported() {
            return;
        }
        let p = DecoderParams::random(33, 32, 40, 48, 3);
        let d = PackedDecoder::new(&p, Storage::F16);
        let pool = ThreadPool::new(&[0, 1]);
        let frames = 30;
        let proj = d.project_encoder(&pool, &encoder_frames(frames, p.enc_dim, 4), frames);
        let sched = synthetic_schedule(frames, 20, p.vocab, 5);
        let got = d.decode(&pool, &proj, frames, Some(&sched));
        let expected: Vec<(usize, usize)> = sched
            .iter()
            .filter_map(|s| s.token.map(|t| (t, s.frame)))
            .collect();
        assert_eq!(got, expected);
        assert_eq!(got.len(), 20);
    }
}
