//! Phrase-aware distractor exclusion, shared by `lf-bias-eval` and
//! `lf-bias-prep` (one implementation, so the two recipes agree).
//!
//! A distractor is never a phrase the session itself speaks. Single words are
//! excluded through the session's reference vocabulary; a multi-word phrase
//! (e.g. another session's keyword "neural network") needs a contiguous match
//! in one of the session's references, which [`phrases_in_references`] finds.
//! Callers add the returned phrases to the session's exclusion set before
//! drawing distractors. A binary using this needs `mod wer;`.

#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};

use crate::wer::normalize;

/// Per session, the multi-word `keys` (normalized with `wer::normalize`,
/// words joined by one space) that occur as a contiguous word sequence in one
/// of that session's references. `records`: `(session, reference text)`.
/// Single-word keys are ignored (the reference vocabulary covers them).
pub fn phrases_in_references<'a>(
    records: impl IntoIterator<Item = (&'a str, &'a str)>,
    keys: &BTreeSet<String>,
) -> BTreeMap<String, BTreeSet<String>> {
    let longest = keys.iter().map(|k| k.split(' ').count()).max().unwrap_or(0);
    let mut out: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    if longest < 2 {
        return out;
    }
    for (session, text) in records {
        let words = normalize(text);
        for n in 2..=longest.min(words.len()) {
            for w in words.windows(n) {
                let phrase = w.join(" ");
                if keys.contains(&phrase) {
                    out.entry(session.to_owned()).or_default().insert(phrase);
                }
            }
        }
    }
    out
}

/// Whether `phrase` (any text; normalized here) is spoken in one of
/// `references`, as a contiguous word sequence: the exclusion test for one
/// distractor.
pub fn phrase_excluded<'a>(phrase: &str, references: impl IntoIterator<Item = &'a str>) -> bool {
    let key = normalize(phrase);
    if key.is_empty() {
        return false;
    }
    references
        .into_iter()
        .any(|r| normalize(r).windows(key.len()).any(|w| w == key.as_slice()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_spoken_multiword_phrases_per_session() {
        let records = [
            ("a", "today we train a Neural Network on slides"),
            ("a", "and nothing else"),
            ("b", "graph theory, neural"),
        ];
        let keys: BTreeSet<String> = ["neural network", "graph theory", "zorbin", "deep net"]
            .map(String::from)
            .into();
        let spoken = phrases_in_references(records, &keys);
        assert_eq!(spoken["a"], ["neural network".to_owned()].into());
        assert_eq!(spoken["b"], ["graph theory".to_owned()].into());
        // Single-word keys are left to the vocabulary.
        let only_words: BTreeSet<String> = ["zorbin".to_owned()].into();
        assert!(phrases_in_references(records, &only_words).is_empty());
        // A phrase split across references or out of order is not spoken.
        assert!(!phrase_excluded("network neural", ["neural network"]));
        assert!(!phrase_excluded("neural network", ["neural", "network"]));
        assert!(phrase_excluded("Neural  Network!", ["a neural network."]));
        assert!(phrase_excluded("zorbin", ["the Zorbin team"]));
        assert!(!phrase_excluded("", ["anything"]));
    }
}
