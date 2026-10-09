//! Speech recognition behind a trait, so the daemon can be tested without
//! loading the model.

use std::path::PathBuf;
use std::time::Instant;

use crate::config::Precision;

pub trait Recognizer {
    /// Transcribes 16 kHz mono samples in [-1, 1]. Errors must not contain
    /// audio or transcript content.
    fn transcribe(&mut self, samples: &[f32]) -> Result<String, String>;
}

/// Builds the recognizer on the worker thread (the real one pins that thread
/// to the first configured CPU).
pub type RecognizerFactory = Box<dyn FnOnce() -> Result<Box<dyn Recognizer>, String> + Send>;

/// The native CPU recognizer for the ternary Parakeet export.
pub struct AsrRecognizer(lf_asr::Transcriber);

impl Recognizer for AsrRecognizer {
    fn transcribe(&mut self, samples: &[f32]) -> Result<String, String> {
        self.0
            .transcribe(samples)
            .map(|t| t.text)
            .map_err(|e| e.to_string())
    }
}

/// Length of the silent warm-up transcription run after loading.
pub const WARM_UP_SECONDS: usize = 30;

pub fn asr_factory(export: PathBuf, cpus: Vec<usize>, precision: Precision) -> RecognizerFactory {
    Box::new(move || {
        if !lf_cpu::cpu_supported() {
            return Err("this CPU lacks AVX-512 F/BW/VNNI/VBMI".into());
        }
        let start = Instant::now();
        let exp = lf_model::Export::open(&export)
            .map_err(|e| format!("model export {}: {e}", export.display()))?;
        let model = lf_asr::Model::load(&exp, lf_cpu::decoder::Storage::F16)
            .map_err(|e| format!("model export {}: {e}", export.display()))?;
        drop(exp);
        let mut transcriber = lf_asr::Transcriber::new(model, &cpus, precision.to_asr());
        // The first call allocates and faults in the working buffers, which
        // would otherwise make the first dictation several times slower.
        let silence = vec![0.0f32; WARM_UP_SECONDS * lf_io_api::SAMPLE_RATE as usize];
        transcriber
            .transcribe(&silence)
            .map_err(|e| format!("warm-up transcription failed: {e}"))?;
        crate::info!(
            "model loaded in {:.1?} ({}, {} threads)",
            start.elapsed(),
            precision.name(),
            cpus.len()
        );
        Ok(Box::new(AsrRecognizer(transcriber)) as Box<dyn Recognizer>)
    })
}
