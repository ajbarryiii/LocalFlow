//! Native CPU speech-to-text for the ternary Parakeet TDT 0.6B v2 export:
//! 16 kHz mono f32 samples in, text out.

pub mod config;
pub mod encoder;
pub mod frontend;
pub mod model;
pub mod tokenizer;

use std::time::Instant;

use lf_cpu::ThreadPool;
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

    /// Transcribes 16 kHz mono samples in [-1, 1].
    pub fn transcribe(&mut self, samples: &[f32]) -> Result<Transcript> {
        if samples.len() > MAX_SECONDS * config::SAMPLE_RATE {
            return Err(Error(format!("audio longer than {MAX_SECONDS} s")));
        }
        let mut timings = Timings::default();
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
            &mut timings,
        )?;

        let start = Instant::now();
        let enc = &self.enc.x[..frames * config::D_MODEL];
        if enc.iter().any(|v| !v.is_finite()) {
            return Err(Error("encoder produced non-finite output".into()));
        }
        let projected = self.model.decoder.project_encoder(&self.pool, enc, frames);
        let emitted = self
            .model
            .decoder
            .decode(&self.pool, &projected, frames, None);
        timings.decoder = start.elapsed();

        let tokens: Vec<usize> = emitted.iter().map(|&(t, _)| t).collect();
        let text = self.model.tokenizer.decode(&tokens)?;
        Ok(Transcript {
            text,
            tokens,
            frames,
            timings,
        })
    }
}

/// Encoder frames for `seconds` of audio, capped at [`MAX_SECONDS`].
fn position_cache_frames(seconds: usize) -> usize {
    encoder::frames_for_samples(seconds.min(MAX_SECONDS) * config::SAMPLE_RATE)
}
