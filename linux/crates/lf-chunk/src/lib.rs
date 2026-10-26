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

    /// Compacted samples chunked so far: grows with speech and the pauses
    /// kept, not with silence that is cut.
    pub fn position(&self) -> usize {
        self.chunker.position()
    }

    /// The windows [`Self::finish`] would transcribe if the recording ended
    /// now, in order, changing nothing. Only once the speaker has paused
    /// (see [`SilenceCompactor::in_trailing_pause`]): then they stay the same
    /// until speech resumes, so they can be transcribed ahead of `finish`.
    /// Returns whether it emitted (always false without a compactor).
    pub fn ending(&self, emit: &mut impl FnMut(&Chunk)) -> bool {
        let Some(compactor) = self.compactor.as_ref().filter(|c| c.in_trailing_pause()) else {
            return false;
        };
        let mut compactor = compactor.clone();
        let mut chunker = self.chunker.clone();
        let mut window = |chunk: &Chunk| -> Result<(), std::convert::Infallible> {
            emit(chunk);
            Ok(())
        };
        let _ = compactor.finish(&mut |piece: &[f32]| chunker.append(piece, &mut window));
        let _ = chunker.finish(&mut window);
        true
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::convert::Infallible;

    fn speech(n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| if (i / 32) % 2 == 0 { 0.1 } else { -0.1 })
            .collect()
    }

    /// The windows a transcription emits from now to its end.
    fn finished(t: ChunkedTranscription, rest: &[f32]) -> Vec<(usize, Vec<f32>)> {
        let mut t = t;
        let mut seen = Vec::new();
        let mut record = |c: &Chunk| -> Result<Vec<Word>, Infallible> {
            seen.push((c.start, c.samples.to_vec()));
            Ok(Vec::new())
        };
        t.append(rest, &mut record).unwrap();
        t.finish(&mut record).unwrap();
        seen
    }

    fn ending(t: &ChunkedTranscription) -> Option<Vec<(usize, Vec<f32>)>> {
        let mut seen = Vec::new();
        t.ending(&mut |c: &Chunk| seen.push((c.start, c.samples.to_vec())))
            .then_some(seen)
    }

    fn fed(samples: &[f32]) -> ChunkedTranscription {
        let mut t = ChunkedTranscription::recording();
        t.append(samples, &mut |_: &Chunk| Ok::<_, Infallible>(Vec::new()))
            .unwrap();
        t
    }

    #[test]
    fn the_ending_is_known_once_the_speaker_pauses() {
        let mut audio = speech(20 * SAMPLE_RATE);
        // Still speaking, or not yet paused for the margin: unknown.
        assert_eq!(ending(&fed(&audio)), None);
        audio.extend(std::iter::repeat_n(
            0.0,
            SilenceCompactor::DEFAULT_MARGIN - 160,
        ));
        assert_eq!(ending(&fed(&audio)), None);
        // Paused long enough: what finish emits, whatever silence follows.
        audio.extend(std::iter::repeat_n(0.0, 160));
        let t = fed(&audio);
        let at = t.position();
        let predicted = ending(&t).expect("known");
        assert_eq!(predicted.len(), 1);
        assert_eq!(finished(t, &[]), predicted);
        for more in [1, 4800, 16_000, 5 * SAMPLE_RATE] {
            let t = fed(&audio);
            assert_eq!(finished(t, &vec![0.0; more]), predicted, "{more} more");
        }
        // Silence does not move the position; resumed speech does.
        let mut longer = audio.clone();
        longer.extend(std::iter::repeat_n(0.0, 2 * SAMPLE_RATE));
        assert_eq!(fed(&longer).position(), at);
        longer.extend(speech(SAMPLE_RATE));
        let t = fed(&longer);
        assert!(t.position() > at);
        assert_ne!(finished(t, &[]), predicted);
        // Finding the ending changes nothing.
        let t = fed(&audio);
        let _ = ending(&t);
        assert_eq!(finished(t, &[]), predicted);
    }

    #[test]
    fn no_ending_without_speech_or_a_compactor() {
        assert_eq!(ending(&fed(&vec![0.0; 5 * SAMPLE_RATE])), None);
        let mut t = ChunkedTranscription::new(CHUNK_SAMPLES, CHUNK_OVERLAP_SAMPLES, None);
        t.append(&speech(SAMPLE_RATE), &mut |_: &Chunk| {
            Ok::<_, Infallible>(Vec::new())
        })
        .unwrap();
        assert_eq!(ending(&t), None);
    }
}
