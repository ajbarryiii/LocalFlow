//! Repacking export codes into output-block order.
//!
//! Codes keep the export's width: 2 bits per weight for a ternary matrix,
//! 1 bit for a binary one. A kernel expands one block at a time into an
//! L2-resident tile and reuses it across every frame.
//!
//! Ternary: for output block `b` (64 rows) and input quad `q` (4 columns),
//! the 64 bytes at `tiled[(b * K/4 + q) * 64..][..64]` are the export bytes
//! `codes[b * 64 + j][q]` for `j` in `0..64`.
//!
//! Binary: the 32 bytes at `tiled[(b * K/4 + q) * 32..][..32]` are four
//! little-endian `u64` masks. Bit `p` of mask `v` is set when the weight of
//! output `b * 64 + v * 16 + p / 4`, input `4 * q + p % 4` is +1 (clear: -1).
//! That is the byte order of the INT8 kernel's tile, so one masked blend
//! expands each mask.

use lf_model::{BinaryMatrix, QuantizedMatrix, Result, TernaryMatrix};

/// Output rows per block: four 16-lane AVX-512 vectors.
pub const NR: usize = 64;

/// How a [`PackedTernary`] stores its codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoding {
    /// 2-bit codes in {-1, 0, +1}, 64 bytes per block quad.
    Ternary,
    /// 1-bit codes in {-1, +1}, 32 bytes per block quad.
    Binary,
}

impl Encoding {
    /// Packed bytes per input quad of one 64-row block.
    pub fn quad_bytes(self) -> usize {
        match self {
            Encoding::Ternary => NR,
            Encoding::Binary => NR / 2,
        }
    }
}

/// A validated matrix of ternary-valued weights in kernel layout. Fields are
/// private so the size invariants the unchecked SIMD kernels rely on cannot
/// be broken.
pub struct PackedTernary {
    rows: usize,
    cols: usize,
    encoding: Encoding,
    tiled: Vec<u8>,
    scale: Vec<f32>,
    row_sum: Vec<i32>,
}

fn check_shape(rows: usize, cols: usize) -> Result<()> {
    if rows == 0 || cols == 0 || !rows.is_multiple_of(NR) || !cols.is_multiple_of(4) {
        return Err(lf_model::Error(format!(
            "unsupported shape {rows}x{cols}: rows must be a multiple of {NR}, columns of 4"
        )));
    }
    Ok(())
}

impl PackedTernary {
    pub fn new(m: &TernaryMatrix) -> Result<Self> {
        check_shape(m.rows, m.cols)?;
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
            encoding: Encoding::Ternary,
            tiled,
            scale: m.scale.clone(),
            row_sum: (0..m.rows).map(|r| m.row_sum(r)).collect(),
        })
    }

    /// Keeps a binary matrix at 1 bit per weight (see the module docs).
    pub fn binary(m: &BinaryMatrix) -> Result<Self> {
        check_shape(m.rows, m.cols)?;
        m.validate()?;
        let quads = m.cols / 4;
        let mut tiled = vec![0u8; m.rows * quads / 2];
        for b in 0..m.rows / NR {
            for q in 0..quads {
                let dst = &mut tiled[(b * quads + q) * (NR / 2)..][..NR / 2];
                for (v, mask) in dst.as_chunks_mut::<8>().0.iter_mut().enumerate() {
                    let mut bits = 0u64;
                    for p in 0..64 {
                        if m.code(b * NR + v * 16 + p / 4, 4 * q + p % 4) == 1 {
                            bits |= 1 << p;
                        }
                    }
                    mask.copy_from_slice(&bits.to_le_bytes());
                }
            }
        }
        Ok(PackedTernary {
            rows: m.rows,
            cols: m.cols,
            encoding: Encoding::Binary,
            tiled,
            scale: m.scale.clone(),
            row_sum: (0..m.rows).map(|r| m.row_sum(r)).collect(),
        })
    }

    /// Packs either kind of export matrix at its own width.
    pub fn pack(m: &QuantizedMatrix) -> Result<Self> {
        match m {
            QuantizedMatrix::Ternary(m) => PackedTernary::new(m),
            QuantizedMatrix::Binary(m) => PackedTernary::binary(m),
        }
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn encoding(&self) -> Encoding {
        self.encoding
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

    /// Bytes of packed codes.
    pub fn code_bytes(&self) -> usize {
        self.tiled.len()
    }

    /// Packed codes for output block `b`, `quads() * encoding().quad_bytes()` bytes.
    pub fn block(&self, b: usize) -> &[u8] {
        let len = self.quads() * self.encoding.quad_bytes();
        &self.tiled[b * len..][..len]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_masks_follow_the_documented_order() {
        let m = BinaryMatrix::random(128, 12, 5);
        let w = PackedTernary::binary(&m).unwrap();
        assert_eq!(w.encoding(), Encoding::Binary);
        assert_eq!(w.code_bytes(), 128 * 12 / 8);
        for b in 0..2 {
            let block = w.block(b);
            assert_eq!(block.len(), 3 * 32);
            for q in 0..3 {
                for v in 0..4 {
                    let at = q * 32 + v * 8;
                    let mask = u64::from_le_bytes(block[at..at + 8].try_into().unwrap());
                    for p in 0..64 {
                        let code = m.code(b * NR + v * 16 + p / 4, 4 * q + p % 4);
                        assert_eq!(mask >> p & 1 == 1, code == 1, "b={b} q={q} v={v} p={p}");
                    }
                }
            }
        }
        assert_eq!(
            w.row_sum(),
            PackedTernary::new(&m.to_ternary()).unwrap().row_sum()
        );
    }

    #[test]
    fn rejects_unsupported_shapes() {
        assert!(PackedTernary::binary(&BinaryMatrix::random(32, 8, 1)).is_err());
        assert!(PackedTernary::binary(&BinaryMatrix::random(64, 6, 1)).is_err());
    }
}
