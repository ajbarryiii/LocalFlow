//! Repacking export codes into output-block order.
//!
//! Codes stay at 2 bits per weight. For output block `b` (64 rows) and input
//! quad `q` (4 columns), the 64 bytes at `tiled[(b * K/4 + q) * 64..][..64]`
//! are the export bytes `codes[b * 64 + j][q]` for `j` in `0..64`. A kernel
//! expands one block at a time into an L2-resident tile and reuses it across
//! every frame.

use lf_model::{Result, TernaryMatrix};

/// Output rows per block: four 16-lane AVX-512 vectors.
pub const NR: usize = 64;

/// A validated ternary matrix in kernel layout. Fields are private so the
/// size invariants the unchecked SIMD kernels rely on cannot be broken.
pub struct PackedTernary {
    rows: usize,
    cols: usize,
    tiled: Vec<u8>,
    scale: Vec<f32>,
    row_sum: Vec<i32>,
}

impl PackedTernary {
    pub fn new(m: &TernaryMatrix) -> Result<Self> {
        if m.rows == 0 || m.cols == 0 || !m.rows.is_multiple_of(NR) || !m.cols.is_multiple_of(4) {
            return Err(lf_model::Error(format!(
                "unsupported shape {}x{}: rows must be a multiple of {NR}, columns of 4",
                m.rows, m.cols
            )));
        }
        m.validate()?;
        let quads = m.cols / 4;
        let mut tiled = vec![0u8; m.rows * quads];
        for b in 0..m.rows / NR {
            for q in 0..quads {
                let dst = &mut tiled[(b * quads + q) * NR..][..NR];
                for (j, d) in dst.iter_mut().enumerate() {
                    *d = m.codes[(b * NR + j) * m.row_bytes() + q];
                }
            }
        }
        Ok(PackedTernary {
            rows: m.rows,
            cols: m.cols,
            tiled,
            scale: m.scale.clone(),
            row_sum: (0..m.rows).map(|r| m.row_sum(r)).collect(),
        })
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn scale(&self) -> &[f32] {
        &self.scale
    }

    /// Sum of codes per output row, used to undo the u8 activation offset.
    pub fn row_sum(&self) -> &[i32] {
        &self.row_sum
    }

    pub fn blocks(&self) -> usize {
        self.rows / NR
    }

    pub fn quads(&self) -> usize {
        self.cols / 4
    }

    /// Packed codes for output block `b`, `quads() * 64` bytes.
    pub fn block(&self, b: usize) -> &[u8] {
        &self.tiled[b * self.quads() * NR..][..self.quads() * NR]
    }
}
