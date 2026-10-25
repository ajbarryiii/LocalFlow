//! Native CPU speech-to-text for the ternary Parakeet TDT 0.6B v2 export:
//! 16 kHz mono f32 samples in, text out.
//!
//! The dictionary text rules and the BPE tokenizer live in the leaf crate
//! `lf-text`; [`dictionary`] and [`tokenizer`] re-export them and add the
//! model-dependent parts. The re-exports below let callers load and run a
//! model without depending on `lf-cpu` or `lf-model` themselves.

pub mod config;
pub mod dictionary;
pub mod encoder;
pub mod frontend;
pub mod model;
pub mod tokenizer;

use std::time::Instant;

pub use lf_cpu::bias::BiasGraph;
pub use lf_cpu::decoder::Storage as DecoderStorage;
pub use lf_cpu::{ThreadPool, Tier, TierError, cpu_supported, tier, topology};
pub use lf_model::Export;
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
}

impl Transcriber {
    /// Pins one worker per CPU in `cpus`; the calling thread becomes the first.
    /// Panics if no kernel [`tier`] can run here.
    pub fn new(model: Model, cpus: &[usize], precision: Precision) -> Self {
        if let Err(e) = tier() {
            panic!("{e}");
        }
        Transcriber::with_pool(model, ThreadPool::new(cpus), precision)
    }

    /// Runs on `pool`, with its placement and at its [`Tier`].
    pub fn with_pool(model: Model, pool: ThreadPool, precision: Precision) -> Self {
        // Fail here rather than in the first transcription.
        pool.tier();
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

    /// The kernel tier the transcriber runs at.
    pub fn tier(&self) -> Tier {
        self.pool.tier()
    }

    /// Threads in its pool.
    pub fn threads(&self) -> usize {
        self.pool.threads()
    }

    /// Bytes currently held by the position cache.
    pub fn position_cache_bytes(&self) -> usize {
        self.positions.bytes()
    }

    /// The model's vocabulary, for encoding dictionary entries.
    pub fn tokenizer(&self) -> &tokenizer::Tokenizer {
        &self.model.tokenizer
    }

    /// Transcribes 16 kHz mono samples in [-1, 1], boosting `bias` (an
    /// immutable dictionary snapshot; `None` or an empty graph decodes
    /// exactly as without boosting): [`Self::encode_projected`], then
    /// [`Self::decode_projected`].
    pub fn transcribe(&mut self, samples: &[f32], bias: Option<&BiasGraph>) -> Result<Transcript> {
        let mut timings = Timings::default();
        let projection = self.encode_timed(samples, &mut timings)?;
        let mut t = self.decode_projected(&projection, bias)?;
        timings.decoder += t.timings.decoder;
        t.timings = timings;
        Ok(t)
    }

    /// Frontend, encoder and the encoder-side joint projection, so one
    /// utterance can be decoded several ways.
    pub fn encode_projected(&mut self, samples: &[f32]) -> Result<Projection> {
        self.encode_timed(samples, &mut Timings::default())
    }

    /// Greedy decoding of a [`Projection`] with an optional bias. Only
    /// `timings.decoder` (the decoding alone) is set.
    pub fn decode_projected(
        &self,
        projection: &Projection,
        bias: Option<&BiasGraph>,
    ) -> Result<Transcript> {
        let decoder = &self.model.decoder;
        let frames = projection.frames;
        if projection.data.len() != frames * decoder.joint_padded() {
            return Err(Error("projection has the wrong length".into()));
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
        let emitted = decoder.decode(&self.pool, &projection.data, frames, None, bias);
        let timings = Timings {
            decoder: start.elapsed(),
            ..Default::default()
        };
        let tokens: Vec<usize> = emitted.iter().map(|&(t, _)| t).collect();
        let text = self
            .model
            .tokenizer
            .decode(&tokens)
            .map_err(tokenizer::text_error)?;
        Ok(Transcript {
            text,
            tokens,
            frames,
            timings,
        })
    }

    fn encode_timed(&mut self, samples: &[f32], timings: &mut Timings) -> Result<Projection> {
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
        let data = self.model.decoder.project_encoder(&self.pool, enc, frames);
        timings.decoder += start.elapsed();
        Ok(Projection { data, frames })
    }
}

/// The encoder-side joint projection of one utterance (`frames` rows of the
/// decoder's padded joint width). Derived from audio, so it is overwritten
/// with zeros when dropped.
pub struct Projection {
    pub data: Vec<f32>,
    pub frames: usize,
}

impl Projection {
    /// Bytes held.
    pub fn bytes(&self) -> usize {
        self.data.len() * std::mem::size_of::<f32>()
    }
}

impl Drop for Projection {
    fn drop(&mut self) {
        for v in self.data.iter_mut() {
            // SAFETY: `v` is a valid, aligned, exclusive reference.
            unsafe { std::ptr::write_volatile(v, 0.0) };
        }
    }
}

impl std::fmt::Debug for Projection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Projection({} frames)", self.frames)
    }
}

/// Encoder frames for `seconds` of audio, capped at [`MAX_SECONDS`].
fn position_cache_frames(seconds: usize) -> usize {
    encoder::frames_for_samples(seconds.min(MAX_SECONDS) * config::SAMPLE_RATE)
}
