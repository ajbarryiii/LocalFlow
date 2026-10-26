//! Port of `ParakeetChunker` in `Sources/Parakeet/LocalParakeetCore.swift`.

use std::ops::Range;

use lf_io_api::wipe::{push_wiping, remove_wiping, truncate_wiping, wipe};

/// A window of the recording, starting at sample `start`.
pub struct Chunk<'a> {
    pub start: usize,
    pub samples: &'a [f32],
}

impl Chunk<'_> {
    pub fn range(&self) -> Range<usize> {
        self.start..self.start + self.samples.len()
    }
}

/// Windows of exactly `size` samples that start `size - overlap` apart. Only
/// the final one may be shorter, and it is emitted only when it holds audio no
/// earlier window covered. The windows do not depend on how the samples are
/// split across calls.
pub struct Chunker {
    size: usize,
    overlap: usize,
    /// The window being filled; it never holds more than `size` samples.
    pending: Vec<f32>,
    /// How much of `pending` the previous window already covered.
    carried: usize,
    start: usize,
}

impl Chunker {
    /// Panics unless `size > 0` and `2 * overlap <= size`, so a seam only
    /// ever involves two chunks.
    pub fn new(size: usize, overlap: usize) -> Chunker {
        assert!(size > 0, "chunk size must be positive");
        assert!(
            2 * overlap <= size,
            "chunk overlap must be at most half the chunk size"
        );
        Chunker {
            size,
            overlap,
            pending: Vec::new(),
            carried: 0,
            start: 0,
        }
    }

    pub fn append<E>(
        &mut self,
        samples: &[f32],
        emit: &mut impl FnMut(&Chunk) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut rest = samples;
        while self.pending.len() + rest.len() >= self.size {
            let take = self.size - self.pending.len();
            push_wiping(&mut self.pending, &rest[..take]);
            rest = &rest[take..];
            let result = emit(&Chunk {
                start: self.start,
                samples: &self.pending,
            });
            remove_wiping(&mut self.pending, 0..self.size - self.overlap);
            self.carried = self.overlap;
            self.start += self.size - self.overlap;
            result?;
        }
        push_wiping(&mut self.pending, rest);
        Ok(())
    }

    /// Emits the final window if it holds new audio, and resets the chunker.
    pub fn finish<E>(&mut self, emit: &mut impl FnMut(&Chunk) -> Result<(), E>) -> Result<(), E> {
        let result = if self.pending.len() > self.carried {
            emit(&Chunk {
                start: self.start,
                samples: &self.pending,
            })
        } else {
            Ok(())
        };
        truncate_wiping(&mut self.pending, 0);
        self.carried = 0;
        self.start = 0;
        result
    }
}

impl Drop for Chunker {
    fn drop(&mut self) {
        wipe(&mut self.pending);
    }
}
