//! Reading the ternary Parakeet export (`parakeet-ternary-v1`).

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

pub use manifest::{Export, Manifest};
pub use safetensors::{Dtype, SafeTensors, TensorInfo};
pub use ternary::TernaryMatrix;

/// Export format this crate understands.
pub const EXPORT_FORMAT: &str = "parakeet-ternary-v1";

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
