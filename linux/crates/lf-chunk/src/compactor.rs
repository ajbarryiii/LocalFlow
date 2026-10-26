//! Port of `Sources/Parakeet/ParakeetSilenceCompactor.swift`.

use lf_io_api::wipe::{push_wiping, remove_wiping, truncate_wiping, wipe};

/// Shortens silence in 16 kHz mono audio before chunking, so pauses cost no
/// encoder time. Leading silence keeps its last `margin` and trailing silence
/// its first. A pause between speech longer than `interior_pause` is cut to
/// exactly that: its first half after speech and its last half before the
/// next. Speech and shorter pauses, which cue phrasing and punctuation, pass
/// through unchanged: the output is the input's own runs in order, spliced
/// without resampling, gain or fades. A stream with no speech is emitted
/// unchanged by `finish`, so audio is held until speech starts; after that at
/// most `interior_pause` is held. The output depends only on the samples, not
/// on how they are split across calls.
///
/// Every buffer is zeroed before it is freed or reused.
pub struct SilenceCompactor {
    margin: usize,
    interior_pause: usize,
    floor: f64,
    speaking: bool,
    heard_speech: bool,
    frame: Vec<f32>,
    /// Before speech, everything so far; in a later pause, its first and last
    /// half of `interior_pause`.
    held: Vec<f32>,
    /// Output of the current call, not yet emitted.
    output: Vec<f32>,
}

// Levels are a frame's mean square in dB relative to full scale. The noise
// floor follows the quietest recent frames: it drops at once and, outside
// speech, rises 3 dB/s, so steady noise is learned within seconds while
// speech, however long, is not. It stays within -70...-40 dB, so speech never
// starts below -60 dB, and frames above -30 dB are always speech.
const FLOOR_MIN: f64 = -70.0;
const FLOOR_MAX: f64 = -40.0;
const FLOOR_RISE: f64 = 0.03;
// A frame starts speech 10 dB over the floor and continues it 6 dB over.
const ONSET: f64 = 10.0;
const RELEASE: f64 = 6.0;

impl SilenceCompactor {
    /// 0.3 s.
    pub const DEFAULT_MARGIN: usize = 4800;
    /// 0.8 s: a pause between speech, such as searching for a word.
    pub const DEFAULT_INTERIOR_PAUSE: usize = 12_800;
    /// Output is emitted in pieces of at most 1 s, so appending a whole
    /// recording at once never builds a second full-size copy.
    pub const MAX_PIECE_SAMPLES: usize = 16_000;
    /// 10 ms, the front end's hop. Speech is decided per frame.
    pub const FRAME_SAMPLES: usize = 160;

    /// Panics unless a kept pause can hold both edge margins.
    pub fn new(margin: usize, interior_pause: usize) -> SilenceCompactor {
        assert!(
            interior_pause >= 2 * margin,
            "a kept pause must hold both edge margins"
        );
        SilenceCompactor {
            margin,
            interior_pause,
            floor: FLOOR_MAX,
            speaking: false,
            heard_speech: false,
            frame: Vec::new(),
            held: Vec::new(),
            output: Vec::new(),
        }
    }

    pub fn append<E>(
        &mut self,
        samples: &[f32],
        emit: &mut impl FnMut(&[f32]) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut rest = samples;
        if !self.frame.is_empty() {
            let take = (Self::FRAME_SAMPLES - self.frame.len()).min(rest.len());
            push_wiping(&mut self.frame, &rest[..take]);
            rest = &rest[take..];
            if self.frame.len() == Self::FRAME_SAMPLES {
                let mut frame = std::mem::take(&mut self.frame);
                self.process(&frame);
                truncate_wiping(&mut frame, 0);
                self.frame = frame;
            }
        }
        let result = (|| {
            while rest.len() >= Self::FRAME_SAMPLES {
                let (frame, tail) = rest.split_at(Self::FRAME_SAMPLES);
                self.process(frame);
                rest = tail;
                self.flush(false, emit)?;
            }
            push_wiping(&mut self.frame, rest);
            self.flush(true, emit)
        })();
        // An emit error drops this call's unemitted output.
        truncate_wiping(&mut self.output, 0);
        result
    }

    /// Emits the rest and resets the compactor for a new stream.
    pub fn finish<E>(&mut self, emit: &mut impl FnMut(&[f32]) -> Result<(), E>) -> Result<(), E> {
        if !self.frame.is_empty() {
            let mut frame = std::mem::take(&mut self.frame);
            self.process(&frame);
            truncate_wiping(&mut frame, 0);
            self.frame = frame;
        }
        // Trailing silence keeps its first margin. With no speech at all, the
        // model hears the recording unchanged.
        if self.heard_speech {
            let keep = self.margin.min(self.held.len());
            push_wiping(&mut self.output, &self.held[..keep]);
        } else {
            std::mem::swap(&mut self.output, &mut self.held);
        }
        truncate_wiping(&mut self.held, 0);
        self.floor = FLOOR_MAX;
        self.speaking = false;
        self.heard_speech = false;
        let result = self.flush(true, emit);
        truncate_wiping(&mut self.output, 0);
        result
    }

    /// Emits full pieces of the output, and with `whole` the rest too.
    fn flush<E>(
        &mut self,
        whole: bool,
        emit: &mut impl FnMut(&[f32]) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut start = 0;
        let len = self.output.len();
        let mut result = Ok(());
        while len - start >= Self::MAX_PIECE_SAMPLES || (whole && start < len) {
            let end = (start + Self::MAX_PIECE_SAMPLES).min(len);
            result = emit(&self.output[start..end]);
            start = end;
            if result.is_err() {
                break;
            }
        }
        remove_wiping(&mut self.output, 0..start);
        result
    }

    fn process(&mut self, samples: &[f32]) {
        if self.is_speech(samples) {
            let from = if self.heard_speech {
                0
            } else {
                self.held.len().saturating_sub(self.margin)
            };
            push_wiping(&mut self.output, &self.held[from..]);
            push_wiping(&mut self.output, samples);
            self.heard_speech = true;
            truncate_wiping(&mut self.held, 0);
        } else {
            push_wiping(&mut self.held, samples);
            // After speech, a pause keeps only what speech resuming or the
            // stream ending could need: the first and last half of the kept
            // pause.
            let head = self.interior_pause / 2;
            let tail = self.interior_pause - head;
            if self.heard_speech && self.held.len() > self.interior_pause {
                let len = self.held.len();
                remove_wiping(&mut self.held, head..len - tail);
            }
        }
    }

    fn is_speech(&mut self, samples: &[f32]) -> bool {
        let mut energy = 0.0f64;
        for &s in samples {
            energy += f64::from(s) * f64::from(s);
        }
        // Invalid samples are kept, so the model rejects them.
        if !energy.is_finite() {
            self.speaking = true;
            return true;
        }
        // Digital silence is silence and says nothing about the room's noise.
        if energy <= 0.0 {
            self.speaking = false;
            return false;
        }
        let level = 10.0 * (energy / samples.len() as f64).log10();
        self.speaking = level
            > self.floor
                + if self.speaking { RELEASE } else { ONSET };
        let next = if level < self.floor {
            level
        } else if self.speaking {
            self.floor
        } else {
            self.floor + FLOOR_RISE
        };
        self.floor = next.clamp(FLOOR_MIN, FLOOR_MAX);
        self.speaking
    }
}

impl Default for SilenceCompactor {
    fn default() -> SilenceCompactor {
        SilenceCompactor::new(Self::DEFAULT_MARGIN, Self::DEFAULT_INTERIOR_PAUSE)
    }
}

impl Drop for SilenceCompactor {
    fn drop(&mut self) {
        wipe(&mut self.frame);
        wipe(&mut self.held);
        wipe(&mut self.output);
    }
}
