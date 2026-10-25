//! Reading the quantized Parakeet exports: ternary (`parakeet-ternary-v1`)
//! and binary (`parakeet-binary-v1`). The two differ only in how the encoder
//! projections' codes are packed.

pub mod binary;
pub mod half;
pub mod manifest;
pub mod rng;
pub mod safetensors;
pub mod ternary;

use std::fmt;

#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error(format!("io: {e}"))
    }
}

pub type Result<T> = std::result::Result<T, Error>;

macro_rules! bail {
    ($($arg:tt)*) => { return Err($crate::Error(format!($($arg)*))) };
}
pub(crate) use bail;

pub use binary::BinaryMatrix;
pub use manifest::{Export, Manifest};
pub use safetensors::{Dtype, SafeTensors, TensorInfo};
pub use ternary::TernaryMatrix;

/// Export format with 2-bit ternary codes.
pub const TERNARY_FORMAT: &str = "parakeet-ternary-v1";
/// Export format with 1-bit binary codes.
pub const BINARY_FORMAT: &str = "parakeet-binary-v1";

/// How an export packs the encoder projections' codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WeightFormat {
    /// [`TernaryMatrix`]: codes in {-1, 0, +1}, 2 bits each.
    Ternary,
    /// [`BinaryMatrix`]: codes in {-1, +1}, 1 bit each.
    Binary,
}

impl WeightFormat {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            TERNARY_FORMAT => WeightFormat::Ternary,
            BINARY_FORMAT => WeightFormat::Binary,
            _ => return None,
        })
    }

    /// The `format` string in the manifest and the tensor file's metadata.
    pub fn name(self) -> &'static str {
        match self {
            WeightFormat::Ternary => TERNARY_FORMAT,
            WeightFormat::Binary => BINARY_FORMAT,
        }
    }
}

/// One encoder projection as stored in an export of either format.
#[derive(Clone)]
pub enum QuantizedMatrix {
    Ternary(TernaryMatrix),
    Binary(BinaryMatrix),
}

impl QuantizedMatrix {
    /// Reads `<module>.codes` and `<module>.scale` in `format`'s packing.
    pub fn from_export(tensors: &SafeTensors, format: WeightFormat, module: &str) -> Result<Self> {
        Ok(match format {
            WeightFormat::Ternary => {
                QuantizedMatrix::Ternary(TernaryMatrix::from_export(tensors, module)?)
            }
            WeightFormat::Binary => {
                QuantizedMatrix::Binary(BinaryMatrix::from_export(tensors, module)?)
            }
        })
    }

    pub fn rows(&self) -> usize {
        match self {
            QuantizedMatrix::Ternary(m) => m.rows,
            QuantizedMatrix::Binary(m) => m.rows,
        }
    }

    pub fn cols(&self) -> usize {
        match self {
            QuantizedMatrix::Ternary(m) => m.cols,
            QuantizedMatrix::Binary(m) => m.cols,
        }
    }

    /// The same weights as 2-bit ternary codes (a binary matrix has no zeros).
    pub fn to_ternary(&self) -> TernaryMatrix {
        match self {
            QuantizedMatrix::Ternary(m) => m.clone(),
            QuantizedMatrix::Binary(m) => m.to_ternary(),
        }
    }
}

/// The 11 ternary projections in every encoder layer, in execution order.
pub const LAYER_TERNARY_MODULES: [&str; 11] = [
    "feed_forward1.linear1",
    "feed_forward1.linear2",
    "self_attn.linear_q",
    "self_attn.linear_k",
    "self_attn.linear_v",
    "self_attn.linear_pos",
    "self_attn.linear_out",
    "conv.pointwise_conv1",
    "conv.pointwise_conv2",
    "feed_forward2.linear1",
    "feed_forward2.linear2",
];

pub const ENCODER_LAYERS: usize = 24;
