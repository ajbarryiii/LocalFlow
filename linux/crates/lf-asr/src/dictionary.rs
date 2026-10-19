//! The custom dictionary: the shared text rules and entry validation from
//! `lf-text` (re-exported), and the bias graph built from entries (LocalFlow
//! DESIGN §1.2).

pub use lf_text::dictionary::*;

use lf_cpu::bias::BiasGraph;
use lf_model::Result;

use crate::tokenizer::Tokenizer;

/// The bias graph for `entries` over the model's vocabulary (blank excluded).
pub fn build_graph(entries: &[DictionaryEntry], tokenizer: &Tokenizer) -> Result<BiasGraph> {
    BiasGraph::new(&phrases(entries, tokenizer), tokenizer.len())
}
