//! Chunked transcription, ported from the macOS app so both split and join a
//! recording identically (pinned by `linux/testdata/chunking-vectors.json`):
//! silence is shortened ([`SilenceCompactor`]), the result is cut into
//! overlapping 15 s windows ([`Chunker`]), each window is transcribed on its
//! own, and the window transcripts are joined at word seams
//! ([`TranscriptAssembler`]). Windows can be transcribed while the user is
//! still speaking, so after the recording ends only the last one is left.
//!
//! Privacy: every buffer holding audio is zeroed before it is freed or reused,
//! and [`Word`]'s `Debug` shows no text.

mod assembler;
mod chunker;
mod compactor;

pub use assembler::{InvalidToken, TranscriptAssembler, Word, words};
pub use chunker::{Chunk, Chunker};
pub use compactor::SilenceCompactor;

pub const SAMPLE_RATE: usize = 16_000;
/// Recordings are split into windows of at most this many samples (15 s).
pub const CHUNK_SAMPLES: usize = 15 * SAMPLE_RATE;
/// Consecutive chunks share this much audio (2 s), so the seam between them
/// can be placed where both chunks heard the speech with context on each side.
pub const CHUNK_OVERLAP_SAMPLES: usize = 2 * SAMPLE_RATE;
/// 10 ms features, subsampled 8x by the encoder.
pub const SAMPLES_PER_ENCODER_FRAME: usize = 1280;

/// One recording split into chunks, each transcribed as soon as it is
/// complete, and joined. However the samples arrive, it gives the same
/// chunks, seams and text. With a compactor, silence is shortened before
/// chunking, so chunk ranges are positions in the compacted audio.
pub struct ChunkedTranscription {
    compactor: Option<SilenceCompactor>,
    chunker: Chunker,
    transcript: TranscriptAssembler,
}

impl ChunkedTranscription {
    pub fn new(size: usize, overlap: usize, compactor: Option<SilenceCompactor>) -> Self {
        ChunkedTranscription {
            compactor,
            chunker: Chunker::new(size, overlap),
            transcript: TranscriptAssembler::default(),
        }
    }

    /// How every dictation is split, whatever its length: silence compacted,
    /// then 15 s windows that overlap by 2 s.
    pub fn recording() -> Self {
        Self::new(
            CHUNK_SAMPLES,
            CHUNK_OVERLAP_SAMPLES,
            Some(SilenceCompactor::default()),
        )
    }

    /// Feeds samples in recording order, transcribing every window they
    /// complete.
    pub fn append<E>(
        &mut self,
        samples: &[f32],
        transcribe: &mut impl FnMut(&Chunk) -> Result<Vec<Word>, E>,
    ) -> Result<(), E> {
        let ChunkedTranscription {
            compactor,
            chunker,
            transcript,
        } = self;
        let mut window = |chunk: &Chunk| {
            transcript.append(transcribe(chunk)?, chunk.range());
            Ok(())
        };
        match compactor {
            Some(c) => c.append(samples, &mut |piece: &[f32]| {
                chunker.append(piece, &mut window)
            }),
            None => chunker.append(samples, &mut window),
        }
    }

    /// Transcribes the remaining partial window, if it holds new audio, and
    /// returns the text.
    pub fn finish<E>(
        mut self,
        transcribe: &mut impl FnMut(&Chunk) -> Result<Vec<Word>, E>,
    ) -> Result<String, E> {
        let ChunkedTranscription {
            compactor,
            chunker,
            transcript,
        } = &mut self;
        let mut window = |chunk: &Chunk| {
            transcript.append(transcribe(chunk)?, chunk.range());
            Ok(())
        };
        if let Some(c) = compactor {
            c.finish(&mut |piece: &[f32]| chunker.append(piece, &mut window))?;
        }
        chunker.finish(&mut window)?;
        Ok(transcript.text())
    }
}
