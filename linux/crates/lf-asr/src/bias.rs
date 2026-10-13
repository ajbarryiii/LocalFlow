//! Boosting phrases for [`BiasGraph`] from words and phrases as text.

use std::collections::HashSet;

pub use lf_cpu::bias::{BiasConfig, BiasGraph, BiasScorer, BiasState, GraphBonusScorer};
use lf_model::{Error, Result};

use crate::tokenizer::Tokenizer;

/// Token sequences for `entries` (words or multi-word phrases), each encoded
/// as text, so the dummy prefix makes it word-initial. Runs of whitespace
/// become one space: the model never emits `▁▁`, so a phrase with doubled
/// spaces could never match. With `case_variants`, also the lowercase form, the form
/// with its first letter uppercased and the form with every word's first
/// letter uppercased (other letters as written). Deduplicated, in order.
/// An empty entry, or one with characters the vocabulary lacks, is an error.
pub fn phrases(
    tokenizer: &Tokenizer,
    entries: &[String],
    case_variants: bool,
) -> Result<Vec<Vec<usize>>> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for (i, entry) in entries.iter().enumerate() {
        let words: Vec<&str> = entry.split_whitespace().collect();
        if words.is_empty() {
            return Err(Error(format!("bias entry {i} is empty")));
        }
        let text = words.join(" ");
        let mut forms = vec![text.clone()];
        if case_variants {
            forms.push(text.to_lowercase());
            forms.push(upper_first(&text));
            forms.push(
                words
                    .iter()
                    .map(|w| upper_first(w))
                    .collect::<Vec<_>>()
                    .join(" "),
            );
        }
        for form in forms {
            let tokens = tokenizer.encode(&form)?;
            if tokenizer.unk().is_some_and(|u| tokens.contains(&u)) {
                return Err(Error(format!(
                    "bias entry {i} has characters outside the vocabulary"
                )));
            }
            if seen.insert(tokens.clone()) {
                out.push(tokens);
            }
        }
    }
    Ok(out)
}

fn upper_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tokenizer::tests::synthetic;

    fn entries(e: &[&str]) -> Vec<String> {
        e.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn encodes_entries_word_initially() {
        let t = synthetic();
        let p = phrases(&t, &entries(&["hello", "  hello  world "]), false).unwrap();
        assert_eq!(p.len(), 2);
        assert_eq!(p[0], t.encode("hello").unwrap());
        assert_eq!(p[1], t.encode("hello world").unwrap());
        assert_eq!(t.decode(&p[1]).unwrap(), "hello world");
        // The dummy prefix: the first piece is word-initial.
        assert_eq!(p[0], t.encode(" hello").unwrap()[1..]);
    }

    #[test]
    fn adds_deduplicated_case_variants() {
        let t = synthetic();
        let texts = |e: &[&str], v: bool| -> Vec<String> {
            phrases(&t, &entries(e), v)
                .unwrap()
                .iter()
                .map(|p| t.decode(p).unwrap())
                .collect()
        };
        assert_eq!(
            texts(&["new york"], true),
            ["new york", "New york", "New York"]
        );
        assert_eq!(texts(&["McDonald"], true), ["McDonald", "mcdonald"]);
        assert_eq!(
            texts(&["hello", "Hello", "hello"], true),
            ["hello", "Hello"]
        );
        assert_eq!(texts(&["hello", "hello"], false), ["hello"]);
        assert_eq!(texts(&["Hello"], false), ["Hello"]);
    }

    #[test]
    fn rejects_empty_and_unspellable_entries() {
        let t = synthetic();
        assert!(phrases(&t, &entries(&["hello", " "]), false).is_err());
        assert!(phrases(&t, &entries(&["h\u{e9}llo"]), false).is_err());
        assert!(phrases(&t, &[], true).unwrap().is_empty());
    }
}
