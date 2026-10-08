//! Ternary weight matrices as stored in the export.
//!
//! `<module>.codes` is `uint8 [out, ceil(in / 4)]`: four 2-bit codes per byte,
//! code `j` of a row at bits `2 * (j % 4)` of byte `j / 4`, with `00` = 0,
//! `01` = +1, `10` = -1 and `11` unused. `<module>.scale` is `f32 [out]`, so
//! `W[o][i] = scale[o] * code(o, i)`.

use crate::rng::SplitMix64;
use crate::safetensors::{Dtype, SafeTensors};
use crate::{Result, bail};

#[derive(Clone)]
pub struct TernaryMatrix {
    pub rows: usize,
    pub cols: usize,
    /// Row-major packed codes, `row_bytes()` per row.
    pub codes: Vec<u8>,
    pub scale: Vec<f32>,
}

#[inline]
pub fn code_value(field: u8) -> i8 {
    match field & 3 {
        1 => 1,
        2 => -1,
        _ => 0,
    }
}

impl TernaryMatrix {
    pub fn row_bytes(&self) -> usize {
        self.cols.div_ceil(4)
    }

    pub fn from_export(tensors: &SafeTensors, module: &str) -> Result<Self> {
        if tensors.contains(&format!("{module}.bias")) {
            bail!("{module}: biases are not supported");
        }
        let (info, codes) = tensors.get(&format!("{module}.codes"))?;
        if info.dtype != Dtype::U8 || info.shape.len() != 2 {
            bail!("{module}.codes: expected 2-D U8");
        }
        let (rows, row_bytes) = (info.shape[0], info.shape[1]);
        let scale = tensors.f32_vec(&format!("{module}.scale"))?;
        if scale.len() != rows {
            bail!("{module}.scale: expected {rows} entries");
        }
        let m = TernaryMatrix {
            rows,
            cols: row_bytes * 4,
            codes: codes.to_vec(),
            scale,
        };
        m.validate()
            .map_err(|e| crate::Error(format!("{module}: {e}")))?;
        Ok(m)
    }

    /// Rejects the unused `11` pattern and nonzero padding past `cols`.
    pub fn validate(&self) -> Result<()> {
        if self.codes.len() != self.rows * self.row_bytes() || self.scale.len() != self.rows {
            bail!("inconsistent sizes");
        }
        for r in 0..self.rows {
            let row = &self.codes[r * self.row_bytes()..(r + 1) * self.row_bytes()];
            for (b, &byte) in row.iter().enumerate() {
                for j in 0..4 {
                    let field = (byte >> (2 * j)) & 3;
                    if field == 3 || (field != 0 && b * 4 + j >= self.cols) {
                        bail!("invalid code at row {r}, column {}", b * 4 + j);
                    }
                }
            }
        }
        Ok(())
    }

    #[inline]
    pub fn code(&self, r: usize, c: usize) -> i8 {
        let byte = self.codes[r * self.row_bytes() + c / 4];
        code_value(byte >> (2 * (c % 4)))
    }

    pub fn row_sum(&self, r: usize) -> i32 {
        (0..self.cols).map(|c| self.code(r, c) as i32).sum()
    }

    /// Uniform codes over {-1, 0, +1}, roughly matching the trained model's
    /// histogram, with per-row scales in [0.01, 0.05).
    pub fn random(rows: usize, cols: usize, seed: u64) -> Self {
        let mut rng = SplitMix64::new(seed);
        let row_bytes = cols.div_ceil(4);
        let mut codes = vec![0u8; rows * row_bytes];
        for r in 0..rows {
            for c in 0..cols {
                let field = rng.below(3) as u8;
                codes[r * row_bytes + c / 4] |= field << (2 * (c % 4));
            }
        }
        let scale = (0..rows).map(|_| 0.01 + 0.04 * rng.next_f32()).collect();
        TernaryMatrix {
            rows,
            cols,
            codes,
            scale,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_bit_layout() {
        // Row 0 codes: [+1, -1, 0, +1, -1] -> byte0 = 01 | 10<<2 | 00<<4 | 01<<6, byte1 = 10.
        let m = TernaryMatrix {
            rows: 1,
            cols: 5,
            codes: vec![0b01_00_10_01, 0b10],
            scale: vec![1.0],
        };
        m.validate().unwrap();
        let row: Vec<i8> = (0..5).map(|c| m.code(0, c)).collect();
        assert_eq!(row, vec![1, -1, 0, 1, -1]);
        assert_eq!(m.row_sum(0), 0);
    }

    #[test]
    fn rejects_unused_pattern_and_padding() {
        let bad = TernaryMatrix {
            rows: 1,
            cols: 4,
            codes: vec![0b11],
            scale: vec![1.0],
        };
        assert!(bad.validate().is_err());
        let padded = TernaryMatrix {
            rows: 1,
            cols: 3,
            codes: vec![0b01 << 6],
            scale: vec![1.0],
        };
        assert!(padded.validate().is_err());
    }

    #[test]
    fn random_is_valid_and_deterministic() {
        let a = TernaryMatrix::random(8, 36, 7);
        a.validate().unwrap();
        assert_eq!(a.codes, TernaryMatrix::random(8, 36, 7).codes);
    }
}
