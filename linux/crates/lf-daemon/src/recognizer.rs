//! Speech recognition behind a trait, so the daemon can be tested without
//! loading the model.

use std::path::PathBuf;
use std::time::Instant;

use lf_asr::dictionary::{self, DictionaryEntry};
use lf_asr::{BiasGraph, Projection};

use crate::config::Precision;
use crate::dictionary::Snapshot;

/// A transcription, and the projection it was decoded from when asked to
/// keep it (for checking a later correction).
pub struct Recognized {
    pub text: String,
    pub projection: Option<Projection>,
}

pub trait Recognizer {
    /// Transcribes 16 kHz mono samples in [-1, 1], boosting the snapshot's
    /// entries. With `retain`, also returns the projection. Errors must not
    /// contain audio or transcript content.
    fn transcribe(
        &mut self,
        samples: &[f32],
        dictionary: &Snapshot,
        retain: bool,
    ) -> Result<Recognized, String>;

    /// Decodes a retained projection again, boosting the snapshot's entries
    /// plus `extra`.
    fn redecode(
        &mut self,
        projection: &Projection,
        dictionary: &Snapshot,
        extra: &DictionaryEntry,
    ) -> Result<String, String>;
}

/// Builds the recognizer on the worker thread (the real one pins that thread
/// to the first configured CPU).
pub type RecognizerFactory = Box<dyn FnOnce() -> Result<Box<dyn Recognizer>, String> + Send>;

/// A snapshot revision with its phrases and bias graph.
type Prepared = (u64, Vec<(Vec<usize>, f32)>, BiasGraph);

/// The native CPU recognizer for the ternary Parakeet export.
pub struct AsrRecognizer {
    transcriber: lf_asr::Transcriber,
    /// The phrases and graph of the last snapshot seen, by revision.
    cache: Option<Prepared>,
}

impl AsrRecognizer {
    pub fn new(transcriber: lf_asr::Transcriber) -> AsrRecognizer {
        AsrRecognizer {
            transcriber,
            cache: None,
        }
    }

    /// Caches the snapshot's phrases and graph unless it has no entries.
    fn prepare(&mut self, snapshot: &Snapshot) -> Result<(), String> {
        if snapshot.dictionary.entries.is_empty()
            || self
                .cache
                .as_ref()
                .is_some_and(|c| c.0 == snapshot.revision)
        {
            return Ok(());
        }
        let tokenizer = self.transcriber.tokenizer();
        let phrases = dictionary::phrases(&snapshot.dictionary.entries, tokenizer);
        let graph =
            BiasGraph::new(&phrases, tokenizer.len()).map_err(|e| format!("dictionary: {e}"))?;
        self.cache = Some((snapshot.revision, phrases, graph));
        Ok(())
    }

    /// The prepared snapshot's phrases and graph; `None` for an empty
    /// dictionary, so decoding takes exactly the unboosted path.
    fn cached(&self, snapshot: &Snapshot) -> Option<&Prepared> {
        self.cache
            .as_ref()
            .filter(|c| !snapshot.dictionary.entries.is_empty() && c.0 == snapshot.revision)
    }
}

impl Recognizer for AsrRecognizer {
    fn transcribe(
        &mut self,
        samples: &[f32],
        dictionary: &Snapshot,
        retain: bool,
    ) -> Result<Recognized, String> {
        let projection = self
            .transcriber
            .encode_projected(samples)
            .map_err(|e| e.to_string())?;
        self.prepare(dictionary)?;
        let graph = self.cached(dictionary).map(|c| &c.2);
        let text = self
            .transcriber
            .decode_projected(&projection, graph)
            .map_err(|e| e.to_string())?
            .text;
        Ok(Recognized {
            text,
            projection: retain.then_some(projection),
        })
    }

    fn redecode(
        &mut self,
        projection: &Projection,
        dictionary: &Snapshot,
        extra: &DictionaryEntry,
    ) -> Result<String, String> {
        self.prepare(dictionary)?;
        let mut phrases = self
            .cached(dictionary)
            .map_or_else(Vec::new, |c| c.1.clone());
        let tokenizer = self.transcriber.tokenizer();
        // Duplicate sequences keep the larger strength (in the graph).
        phrases.extend(dictionary::phrases(std::slice::from_ref(extra), tokenizer));
        let graph =
            BiasGraph::new(&phrases, tokenizer.len()).map_err(|e| format!("dictionary: {e}"))?;
        self.transcriber
            .decode_projected(projection, Some(&graph))
            .map(|t| t.text)
            .map_err(|e| e.to_string())
    }
}

/// Length of the silent warm-up transcription run after loading.
pub const WARM_UP_SECONDS: usize = 30;

pub fn asr_factory(export: PathBuf, cpus: Vec<usize>, precision: Precision) -> RecognizerFactory {
    Box::new(move || {
        lf_asr::tier().map_err(|e| e.to_string())?;
        let start = Instant::now();
        let exp = lf_asr::Export::open(&export)
            .map_err(|e| format!("model export {}: {e}", export.display()))?;
        let model = lf_asr::Model::load(&exp, lf_asr::DecoderStorage::F16)
            .map_err(|e| format!("model export {}: {e}", export.display()))?;
        let format = exp.format.name();
        drop(exp);
        let mut transcriber = lf_asr::Transcriber::new(model, &cpus, precision.to_asr());
        // The first call allocates and faults in the working buffers, which
        // would otherwise make the first dictation several times slower.
        let silence = vec![0.0f32; WARM_UP_SECONDS * lf_io_api::SAMPLE_RATE as usize];
        transcriber
            .transcribe(&silence, None)
            .map_err(|e| format!("warm-up transcription failed: {e}"))?;
        crate::info!(
            "model loaded in {:.1?} ({format}, {}, {} kernels, {} threads)",
            start.elapsed(),
            precision.name(),
            transcriber.tier(),
            cpus.len()
        );
        Ok(Box::new(AsrRecognizer::new(transcriber)) as Box<dyn Recognizer>)
    })
}
