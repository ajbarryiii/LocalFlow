//! Native CPU speech-to-text for the ternary Parakeet TDT 0.6B v2 export:
//! 16 kHz mono f32 samples in, text out.

pub mod bias;
pub mod config;
pub mod encoder;
pub mod frontend;
pub mod model;
pub mod tokenizer;

use std::time::Instant;

use lf_cpu::ThreadPool;
use lf_cpu::bias::{BiasGraph, BiasScorer};
use lf_model::{Error, Result};

pub use encoder::{Precision, Timings};
pub use model::Model;

/// Longest input accepted in one call. Attention memory grows quadratically.
pub const MAX_SECONDS: usize = 600;

/// Default for [`Transcriber::set_position_cache_seconds`].
pub const DEFAULT_POSITION_CACHE_SECONDS: usize = 60;

pub struct Transcript {
    pub text: String,
    pub tokens: Vec<usize>,
    /// Encoder frames (80 ms each).
    pub frames: usize,
    pub timings: Timings,
}

pub struct Transcriber {
    model: Model,
    pool: ThreadPool,
    proj: encoder::Projector,
    front: frontend::FrontendBuffers,
    enc: encoder::EncoderBuffers,
    positions: encoder::PositionCache,
    bias: Option<BiasGraph>,
}

impl Transcriber {
    /// Pins one worker per CPU in `cpus`; the calling thread becomes the first.
    pub fn new(model: Model, cpus: &[usize], precision: Precision) -> Self {
        assert!(
            lf_cpu::cpu_supported(),
            "this CPU lacks AVX-512 F/BW/VNNI/VBMI"
        );
        let pool = ThreadPool::new(cpus);
        let proj = encoder::Projector::new(precision, pool.threads());
        Transcriber {
            model,
            pool,
            proj,
            front: Default::default(),
            enc: Default::default(),
            positions: encoder::PositionCache::new(position_cache_frames(
                DEFAULT_POSITION_CACHE_SECONDS,
            )),
            bias: None,
        }
    }

    /// Caches each layer's projected position embedding for utterances of up
    /// to `seconds` (default [`DEFAULT_POSITION_CACHE_SECONDS`]; 0 disables).
    /// The cache grows to the longest utterance seen, in 5.12 s steps, by about
    /// 2.3 MiB per second of audio (144 MiB at 60 s). Longer utterances project
    /// positions per call, as with no cache. Lowering the limit below the
    /// cached length frees the cache. Results are bit-identical either way.
    pub fn set_position_cache_seconds(&mut self, seconds: usize) {
        self.positions.set_limit(position_cache_frames(seconds));
    }

    /// Bytes currently held by the position cache.
    pub fn position_cache_bytes(&self) -> usize {
        self.positions.bytes()
    }

    /// Phrase boosting for [`Self::transcribe`] (`None`, the default, disables it).
    pub fn set_bias(&mut self, bias: Option<BiasGraph>) {
        self.bias = bias;
    }

    /// Transcribes 16 kHz mono samples in [-1, 1], with the bias from
    /// [`Self::set_bias`]: [`Self::encode_projected`], then [`Self::decode_projected`].
    pub fn transcribe(&mut self, samples: &[f32]) -> Result<Transcript> {
        let mut timings = Timings::default();
        let (projected, frames) = self.encode_timed(samples, &mut timings)?;
        let mut t = self.decode_projected(&projected, frames, self.bias.as_ref())?;
        timings.decoder += t.timings.decoder;
        t.timings = timings;
        Ok(t)
    }

    /// Frontend, encoder and the encoder-side joint projection, so one encoding
    /// can be decoded several ways. Returns the projection and its frame count.
    pub fn encode_projected(&mut self, samples: &[f32]) -> Result<(Vec<f32>, usize)> {
        self.encode_timed(samples, &mut Timings::default())
    }

    /// Greedy decoding of [`Self::encode_projected`]'s output with an optional
    /// bias. Only `timings.decoder` (the decoding alone) is set.
    pub fn decode_projected(
        &self,
        projected: &[f32],
        frames: usize,
        bias: Option<&BiasGraph>,
    ) -> Result<Transcript> {
        let decoder = &self.model.decoder;
        if projected.len() != frames * decoder.joint_padded() {
            return Err(Error(
                "projected encoder output has the wrong length".into(),
            ));
        }
        if let Some(g) = bias
            && g.tokens() != config::VOCAB
        {
            return Err(Error(format!(
                "bias graph has {} tokens, expected {}",
                g.tokens(),
                config::VOCAB
            )));
        }
        let start = Instant::now();
        let emitted = decoder.decode(&self.pool, projected, frames, None, bias);
        self.transcript(&emitted, frames, start)
    }

    /// Greedy decoding of [`Self::encode_projected`]'s output with a learned
    /// bias: `PackedDecoder::decode_scored` with `graph`'s candidates and
    /// `scorer`'s bonuses, on `pool`, which must have exactly one thread (the
    /// transcriber's own pool usually has more). Only `timings.decoder` is set.
    pub fn decode_projected_scored(
        &self,
        pool: &ThreadPool,
        projected: &[f32],
        frames: usize,
        graph: &BiasGraph,
        scorer: &dyn BiasScorer,
    ) -> Result<Transcript> {
        let decoder = &self.model.decoder;
        if projected.len() != frames * decoder.joint_padded() {
            return Err(Error(
                "projected encoder output has the wrong length".into(),
            ));
        }
        if graph.tokens() != config::VOCAB {
            return Err(Error(format!(
                "bias graph has {} tokens, expected {}",
                graph.tokens(),
                config::VOCAB
            )));
        }
        if pool.threads() != 1 {
            return Err(Error(format!(
                "scored decoding needs a 1-thread pool, got {} threads",
                pool.threads()
            )));
        }
        let start = Instant::now();
        let emitted = decoder.decode_scored(pool, projected, frames, graph, scorer);
        self.transcript(&emitted, frames, start)
    }

    fn transcript(
        &self,
        emitted: &[(usize, usize)],
        frames: usize,
        start: Instant,
    ) -> Result<Transcript> {
        let timings = Timings {
            decoder: start.elapsed(),
            ..Default::default()
        };
        let tokens: Vec<usize> = emitted.iter().map(|&(t, _)| t).collect();
        let text = self.model.tokenizer.decode(&tokens)?;
        Ok(Transcript {
            text,
            tokens,
            frames,
            timings,
        })
    }

    fn encode_timed(
        &mut self,
        samples: &[f32],
        timings: &mut Timings,
    ) -> Result<(Vec<f32>, usize)> {
        if samples.len() > MAX_SECONDS * config::SAMPLE_RATE {
            return Err(Error(format!("audio longer than {MAX_SECONDS} s")));
        }
        let start = Instant::now();
        let mel_frames =
            frontend::features(&self.model.frontend, &self.pool, samples, &mut self.front)?;
        timings.frontend = start.elapsed();

        let frames = encoder::encode(
            &self.model,
            &self.pool,
            &mut self.proj,
            &self.front.feat,
            mel_frames,
            &mut self.enc,
            &mut self.positions,
            timings,
        )?;

        let start = Instant::now();
        let enc = &self.enc.x[..frames * config::D_MODEL];
        if enc.iter().any(|v| !v.is_finite()) {
            return Err(Error("encoder produced non-finite output".into()));
        }
        let projected = self.model.decoder.project_encoder(&self.pool, enc, frames);
        timings.decoder += start.elapsed();
        Ok((projected, frames))
    }
}

/// Encoder frames for `seconds` of audio, capped at [`MAX_SECONDS`].
fn position_cache_frames(seconds: usize) -> usize {
    encoder::frames_for_samples(seconds.min(MAX_SECONDS) * config::SAMPLE_RATE)
}
