//! Speech recognition behind a trait, so the daemon can be tested without
//! loading the model.

use std::path::{Path, PathBuf};
use std::time::Instant;

use lf_asr::dictionary::{self, DictionaryEntry};
use lf_asr::{BiasGraph, Projection};
use lf_chunk::{Chunk, Word};
use lf_io_api::wipe::Wiped;

use crate::config::Precision;
use crate::dictionary::Snapshot;

/// One chunk's words, and the projection they were decoded from when asked
/// to keep it (for checking a later correction).
pub struct ChunkResult {
    pub words: Vec<Word>,
    pub projection: Option<Projection>,
}

pub trait Recognizer {
    /// Transcribes one chunk of a dictation's compacted audio (16 kHz mono in
    /// [-1, 1]), boosting the snapshot's entries. Word starts count from
    /// `chunk.start`. With `retain`, also returns the projection. Errors must
    /// not contain audio or transcript content.
    fn transcribe_chunk(
        &mut self,
        chunk: &Chunk,
        dictionary: &Snapshot,
        retain: bool,
    ) -> Result<ChunkResult, String>;

    /// Decodes a retained chunk projection again, boosting the snapshot's
    /// entries plus `extra`. Word starts count from `start`.
    fn redecode_chunk(
        &mut self,
        projection: &Projection,
        start: usize,
        dictionary: &Snapshot,
        extra: &DictionaryEntry,
    ) -> Result<Vec<Word>, String>;

    /// The joined words of a dictation as the text to type. The default
    /// keeps them as they are.
    fn tidy(&self, text: &str) -> String {
        text.to_owned()
    }
}

/// Builds the recognizer on the worker thread (the real one pins that thread
/// to the first configured CPU).
pub type RecognizerFactory = Box<dyn FnOnce() -> Result<Box<dyn Recognizer>, String> + Send>;

/// A snapshot revision with its phrases and bias graph.
type Prepared = (u64, Vec<(Vec<usize>, f32)>, BiasGraph);

/// What a correction check boosts on top of a snapshot: its revision, the
/// extra entry's text and its strength's bits.
type Boost = (u64, String, u32);

/// Chunks shorter than this are padded with silence, as on the Mac: NeMo's
/// per-feature normalization needs at least two frames.
const MIN_CHUNK_SAMPLES: usize = 480;

/// The native CPU recognizer for a Parakeet export (ternary or binary).
pub struct AsrRecognizer {
    transcriber: lf_asr::Transcriber,
    /// The phrases and graph of the last snapshot seen, by revision.
    cache: Option<Prepared>,
    /// The graph of the last correction check, which re-decodes every chunk
    /// with it.
    boosted: Option<(Boost, BiasGraph)>,
}

impl AsrRecognizer {
    pub fn new(transcriber: lf_asr::Transcriber) -> AsrRecognizer {
        AsrRecognizer {
            transcriber,
            cache: None,
            boosted: None,
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

    /// The words of a projection decoded with `graph`, timed from `start`.
    fn words(
        &self,
        projection: &Projection,
        start: usize,
        graph: Option<&BiasGraph>,
    ) -> Result<Vec<Word>, String> {
        let t = self
            .transcriber
            .decode_projected(projection, graph)
            .map_err(|e| e.to_string())?;
        let emitted: Vec<(usize, usize)> = t
            .tokens
            .iter()
            .copied()
            .zip(t.token_frames.iter().copied())
            .collect();
        lf_chunk::words(&emitted, self.transcriber.tokenizer().pieces(), start)
            .map_err(|e| e.to_string())
    }
}

impl Recognizer for AsrRecognizer {
    fn transcribe_chunk(
        &mut self,
        chunk: &Chunk,
        dictionary: &Snapshot,
        retain: bool,
    ) -> Result<ChunkResult, String> {
        let samples = chunk.samples;
        if samples.iter().any(|v| !v.is_finite()) {
            return Err("audio contains invalid samples".into());
        }
        // Digital silence: no words, nothing to re-decode, no model time.
        if samples.iter().all(|&v| v == 0.0) {
            return Ok(ChunkResult {
                words: Vec::new(),
                projection: None,
            });
        }
        let padded;
        let input = if samples.len() < MIN_CHUNK_SAMPLES {
            let mut p = Wiped(Vec::with_capacity(MIN_CHUNK_SAMPLES));
            p.0.extend_from_slice(samples);
            p.0.resize(MIN_CHUNK_SAMPLES, 0.0);
            padded = p;
            &padded.0[..]
        } else {
            samples
        };
        let projection = self
            .transcriber
            .encode_projected(input)
            .map_err(|e| e.to_string())?;
        self.prepare(dictionary)?;
        let graph = self.cached(dictionary).map(|c| &c.2);
        let words = self.words(&projection, chunk.start, graph)?;
        Ok(ChunkResult {
            words,
            projection: retain.then_some(projection),
        })
    }

    fn redecode_chunk(
        &mut self,
        projection: &Projection,
        start: usize,
        dictionary: &Snapshot,
        extra: &DictionaryEntry,
    ) -> Result<Vec<Word>, String> {
        let boost = (
            dictionary.revision,
            extra.text.clone(),
            extra.strength.to_bits(),
        );
        if self.boosted.as_ref().is_none_or(|(b, _)| *b != boost) {
            self.prepare(dictionary)?;
            let mut phrases = self
                .cached(dictionary)
                .map_or_else(Vec::new, |c| c.1.clone());
            let tokenizer = self.transcriber.tokenizer();
            // Duplicate sequences keep the larger strength (in the graph).
            phrases.extend(dictionary::phrases(std::slice::from_ref(extra), tokenizer));
            let graph = BiasGraph::new(&phrases, tokenizer.len())
                .map_err(|e| format!("dictionary: {e}"))?;
            self.boosted = Some((boost, graph));
        }
        let graph = self.boosted.as_ref().map(|(_, g)| g);
        self.words(projection, start, graph)
    }

    /// NeMo's spacing: no space before the vocabulary's punctuation.
    fn tidy(&self, text: &str) -> String {
        self.transcriber
            .tokenizer()
            .strip_space_before_punctuation(text)
    }
}

/// Length of the silent warm-up transcription run after loading: one whole
/// chunk, the longest input the encoder sees.
pub const WARM_UP_SECONDS: usize = 15;

/// Where to get a model when `export_path` holds none.
pub const MODEL_HINT: &str = "run `localflowctl fetch-model` to install kea-b \
     (https://huggingface.co/rajb3/kea-b) there, or point export_path at an export";

/// Fails with [`MODEL_HINT`] when `export` has no `manifest.json`. Other
/// errors (permissions, I/O) are left to the loader, which reports them.
pub fn check_export(export: &Path) -> Result<(), String> {
    match export.join("manifest.json").try_exists() {
        Ok(false) => Err(format!(
            "no model export at {}; {MODEL_HINT}",
            export.display()
        )),
        _ => Ok(()),
    }
}

pub fn asr_factory(export: PathBuf, cpus: Vec<usize>, precision: Precision) -> RecognizerFactory {
    Box::new(move || {
        check_export(&export)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_export_says_where_to_get_a_model() {
        let dir = std::env::temp_dir().join(format!("lf-no-model-{}", std::process::id()));
        let Err(e) = asr_factory(dir.clone(), vec![0], Precision::Int8(2))() else {
            panic!("loaded a model from an empty path");
        };
        assert_eq!(
            e,
            format!("no model export at {}; {MODEL_HINT}", dir.display())
        );
        assert!(MODEL_HINT.contains("https://huggingface.co/rajb3/kea-b"));
        assert!(MODEL_HINT.contains("localflowctl fetch-model"));
    }
}
