//! Model-independent text rules: the custom dictionary's shared rules and
//! entry validation, and the SentencePiece BPE tokenizer they encode with.
//!
//! This is a leaf crate (no model, no kernels), so `lf-dictation` can use
//! the dictionary rules without the recognition stack. `lf-asr` re-exports
//! both modules and adds what needs the model: loading the vocabulary from
//! an export and building the bias graph.

pub mod dictionary;
pub mod tokenizer;

use std::fmt;

/// A tokenizer error.
#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
