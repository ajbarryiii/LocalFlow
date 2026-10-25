//! Binary weight matrices as stored in a `parakeet-binary-v1` export.
//!
//! `<module>.codes` is `uint8 [out, ceil(in / 8)]`: code `j` of a row is bit
//! `j % 8` of byte `j / 8` (least significant bit first), with 1 = +1 and
//! 0 = -1; unused tail bits are 0. `<module>.scale` is `f32 [out]`, so
//! `W[o][i] = scale[o] * code(o, i)`.

use crate::rng::SplitMix64;
use crate::safetensors::{Dtype, SafeTensors};
use crate::{Result, TernaryMatrix, bail};

#[derive(Clone)]
pub struct BinaryMatrix {
    pub rows: usize,
    pub cols: usize,
    /// Row-major packed bits, `row_bytes()` per row.
    pub bits: Vec<u8>,
    pub scale: Vec<f32>,
}

impl BinaryMatrix {
    pub fn row_bytes(&self) -> usize {
        self.cols.div_ceil(8)
    }

    pub fn from_export(tensors: &SafeTensors, module: &str) -> Result<Self> {
        if tensors.contains(&format!("{module}.bias")) {
            bail!("{module}: biases are not supported");
        }
        let (info, bits) = tensors.get(&format!("{module}.codes"))?;
        if info.dtype != Dtype::U8 || info.shape.len() != 2 {
            bail!("{module}.codes: expected 2-D U8");
        }
        let (rows, row_bytes) = (info.shape[0], info.shape[1]);
        let scale = tensors.f32_vec(&format!("{module}.scale"))?;
        if scale.len() != rows {
            bail!("{module}.scale: expected {rows} entries");
        }
        let m = BinaryMatrix {
            rows,
            cols: row_bytes * 8,
            bits: bits.to_vec(),
            scale,
        };
        m.validate()
            .map_err(|e| crate::Error(format!("{module}: {e}")))?;
        Ok(m)
    }

    /// Rejects inconsistent sizes and set bits past `cols`.
    pub fn validate(&self) -> Result<()> {
        if self.bits.len() != self.rows * self.row_bytes() || self.scale.len() != self.rows {
            bail!("inconsistent sizes");
        }
        let tail = self.cols % 8;
        if tail != 0 {
            let unused = !0u8 << tail;
            for r in 0..self.rows {
                if self.bits[(r + 1) * self.row_bytes() - 1] & unused != 0 {
                    bail!("set padding bit in row {r}");
                }
            }
        }
        Ok(())
    }

    #[inline]
    pub fn code(&self, r: usize, c: usize) -> i8 {
        let byte = self.bits[r * self.row_bytes() + c / 8];
        if (byte >> (c % 8)) & 1 == 1 { 1 } else { -1 }
    }

    pub fn row_sum(&self, r: usize) -> i32 {
        let row = &self.bits[r * self.row_bytes()..(r + 1) * self.row_bytes()];
        let ones: u32 = row.iter().map(|b| b.count_ones()).sum();
        2 * ones as i32 - self.cols as i32
    }

    /// The same weights as 2-bit ternary codes (`01` = +1, `10` = -1).
    pub fn to_ternary(&self) -> TernaryMatrix {
        let row_bytes = self.cols.div_ceil(4);
        let mut codes = vec![0u8; self.rows * row_bytes];
        for r in 0..self.rows {
            for c in 0..self.cols {
                let field = if self.code(r, c) == 1 { 1 } else { 2 };
                codes[r * row_bytes + c / 4] |= field << (2 * (c % 4));
            }
        }
        TernaryMatrix {
            rows: self.rows,
            cols: self.cols,
            codes,
            scale: self.scale.clone(),
        }
    }

    /// Uniform codes over {-1, +1} with per-row scales in [0.01, 0.05).
    pub fn random(rows: usize, cols: usize, seed: u64) -> Self {
        let mut rng = SplitMix64::new(seed);
        let row_bytes = cols.div_ceil(8);
        let mut bits = vec![0u8; rows * row_bytes];
        for r in 0..rows {
            for c in 0..cols {
                bits[r * row_bytes + c / 8] |= (rng.below(2) as u8) << (c % 8);
            }
        }
        let scale = (0..rows).map(|_| 0.01 + 0.04 * rng.next_f32()).collect();
        BinaryMatrix {
            rows,
            cols,
            bits,
            scale,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{QuantizedMatrix, WeightFormat};

    #[test]
    fn decodes_bit_layout() {
        // Row 0 codes: [+1, -1, -1, +1, -1, -1, -1, -1, +1, -1] -> byte0 = 0b0000_1001, byte1 = 0b01.
        let m = BinaryMatrix {
            rows: 1,
            cols: 10,
            bits: vec![0b0000_1001, 0b01],
            scale: vec![1.0],
        };
        m.validate().unwrap();
        let row: Vec<i8> = (0..10).map(|c| m.code(0, c)).collect();
        assert_eq!(row, vec![1, -1, -1, 1, -1, -1, -1, -1, 1, -1]);
        assert_eq!(m.row_sum(0), 3 - 7);
    }

    #[test]
    fn rejects_padding_bits_and_bad_sizes() {
        let padded = BinaryMatrix {
            rows: 1,
            cols: 10,
            bits: vec![0, 0b100],
            scale: vec![1.0],
        };
        assert!(padded.validate().is_err());
        let short = BinaryMatrix {
            rows: 2,
            cols: 8,
            bits: vec![0],
            scale: vec![1.0, 1.0],
        };
        assert!(short.validate().is_err());
    }

    #[test]
    fn widens_to_the_same_ternary_weights() {
        let b = BinaryMatrix::random(5, 37, 3);
        b.validate().unwrap();
        let t = b.to_ternary();
        t.validate().unwrap();
        for r in 0..5 {
            for c in 0..37 {
                assert_eq!(t.code(r, c), b.code(r, c), "row {r} column {c}");
            }
            assert_eq!(t.row_sum(r), b.row_sum(r));
        }
        assert_eq!(t.scale, b.scale);
    }

    #[test]
    fn reads_export_tensors() {
        let header = r#"{"__metadata__":{"format":"parakeet-binary-v1"},"m.codes":{"dtype":"U8","shape":[2,2],"data_offsets":[0,4]},"m.scale":{"dtype":"F32","shape":[2],"data_offsets":[4,12]}}"#;
        let mut file = (header.len() as u64).to_le_bytes().to_vec();
        file.extend_from_slice(header.as_bytes());
        file.extend_from_slice(&[0xff, 0x00, 0x01, 0x80]);
        file.extend_from_slice(&0.5f32.to_le_bytes());
        file.extend_from_slice(&0.25f32.to_le_bytes());
        let st = SafeTensors::parse(file).unwrap();
        let m = BinaryMatrix::from_export(&st, "m").unwrap();
        assert_eq!((m.rows, m.cols), (2, 16));
        assert_eq!(m.row_sum(0), 0);
        assert_eq!((m.code(1, 0), m.code(1, 1), m.code(1, 15)), (1, -1, 1));
        assert_eq!(m.scale, vec![0.5, 0.25]);
        let q = QuantizedMatrix::from_export(&st, WeightFormat::Binary, "m").unwrap();
        assert_eq!((q.rows(), q.cols()), (2, 16));
        assert!(matches!(q, QuantizedMatrix::Binary(_)));
        // The same codes read as 2-bit fields come out as a 2x8 ternary matrix
        // (0xff holds the unused `11` pattern, so it is rejected).
        assert!(QuantizedMatrix::from_export(&st, WeightFormat::Ternary, "m").is_err());
    }

    #[test]
    fn formats_round_trip() {
        for f in [WeightFormat::Ternary, WeightFormat::Binary] {
            assert_eq!(WeightFormat::parse(f.name()), Some(f));
        }
        assert_eq!(WeightFormat::parse("parakeet-ternary-v2"), None);
    }

    #[test]
    fn random_is_valid_and_deterministic() {
        let a = BinaryMatrix::random(8, 36, 7);
        a.validate().unwrap();
        assert_eq!(a.bits, BinaryMatrix::random(8, 36, 7).bits);
    }
}
