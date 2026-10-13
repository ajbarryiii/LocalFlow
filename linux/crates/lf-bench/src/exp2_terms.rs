//! Dictionary targets for experiment 2's datasets (SPGISpeech, SlideSpeech
//! rare-word lists, ICSI, ACL 60/60, GigaSpeech): technical terms and names
//! rather than generic vocabulary.
//!
//! A normalized word is a target iff
//! 1. it is rare (`exp2_data::is_rare`: not among the common 5k, with a
//!    letter), and
//! 2. it is session-specific: the number of sessions whose references contain
//!    it (document frequency) is at most 5% of the DF-source sessions,
//!    rounded down, and never below 2 (so in a set of fewer than 40 sessions a
//!    word in two sessions still counts).
//!
//! DF source (DESIGN "DF source"): only the dataset's **train** sessions,
//! frozen and reused for its dev and held-out lists; a dataset without a
//! train split uses only the split being scored ([`df_source_split`]). Callers
//! select the reference lines and pass them to
//! [`SessionDf::from_references`]; [`SessionDf::sha256`] identifies the
//! frozen table in metadata. Experiment 1's held-out lists are not built
//! this way.
//!
//! Casing (declared per dataset, never detected): [`normalize_entry_surface`]
//! is applied to every dictionary entry before case variants are generated,
//! in preparation and in evaluation alike.

#![allow(dead_code)]

use std::collections::{BTreeSet, HashMap};

use crate::wer::normalize;

/// How a dataset's references are written (declared, not detected).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Casing {
    /// Cased (and punctuated): entries and write-ins keep the reference's
    /// spelling.
    Cased,
    /// All lowercase or all uppercase: entries are lowercased before case
    /// variants are generated, and a write-in is the lowercase reference word,
    /// capitalized where the hypothesis has it capitalized or at a sentence
    /// start.
    Uncased,
}

/// A dictionary entry's surface form before case variants are generated:
/// unchanged for cased datasets, lowercased for uncased ones (so entry
/// "QUAXEL" of an uncased set yields the variants "quaxel" and "Quaxel", and
/// a sentence-initial write-in "Quaxel" is one of them).
pub fn normalize_entry_surface(surface: &str, casing: Casing) -> String {
    match casing {
        Casing::Cased => surface.to_owned(),
        Casing::Uncased => surface.to_lowercase(),
    }
}

/// The surfaces of a keyword entry before case variants: the original and
/// its lowercase form, deduplicated, in that order. Each is then expanded
/// with `lf_asr::bias::phrases(.., case_variants = true)` and the union taken,
/// so "GPU" keeps "GPU" besides "gpu"/"Gpu", and "NEURAL NETWORK" yields
/// "NEURAL NETWORK", "neural network", "Neural network" and "Neural Network".
/// Rare-word entries use [`normalize_entry_surface`] instead.
pub fn keyword_entry_surfaces(surface: &str) -> Vec<String> {
    let lower = surface.to_lowercase();
    if lower == surface {
        vec![lower]
    } else {
        vec![surface.to_owned(), lower]
    }
}

/// The split whose sessions are the DF source when scoring `scored`: "train"
/// if the dataset has train sessions, else `scored` itself.
pub fn df_source_split(has_train: bool, scored: &str) -> &str {
    if has_train { "train" } else { scored }
}

/// Share of sessions (in percent) a target may occur in.
pub const MAX_DF_PERCENT: usize = 5;
/// The smallest allowed document-frequency limit.
pub const MIN_DF_LIMIT: usize = 2;

/// Per normalized word, the number of sessions whose references contain it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionDf {
    sessions: usize,
    df: HashMap<String, usize>,
}

impl SessionDf {
    /// From `(session, reference text)` pairs: every utterance of the DF-source
    /// sessions, and nothing else (the caller selects them). Words are
    /// normalized with `wer::normalize`.
    pub fn from_references<'a>(refs: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        let mut words: HashMap<&'a str, BTreeSet<String>> = HashMap::new();
        for (session, text) in refs {
            words.entry(session).or_default().extend(normalize(text));
        }
        let mut df: HashMap<String, usize> = HashMap::new();
        for set in words.values() {
            for w in set {
                *df.entry(w.clone()).or_default() += 1;
            }
        }
        SessionDf {
            sessions: words.len(),
            df,
        }
    }

    /// Number of sessions.
    pub fn sessions(&self) -> usize {
        self.sessions
    }

    /// Sessions whose references contain `word` (normalized).
    pub fn df(&self, word: &str) -> usize {
        self.df.get(word).copied().unwrap_or(0)
    }

    /// The largest document frequency a target may have:
    /// `max(floor(5% of sessions), 2)`.
    pub fn max_df(&self) -> usize {
        (self.sessions * MAX_DF_PERCENT / 100).max(MIN_DF_LIMIT)
    }

    /// `word` occurs in at most [`Self::max_df`] sessions.
    pub fn is_session_specific(&self, word: &str) -> bool {
        self.df(word) <= self.max_df()
    }

    /// SHA-256 (hex) of the table: the session count, then every `word\tdf`
    /// line in sorted order. Equal tables hash equally whatever the input order.
    pub fn sha256(&self) -> String {
        let mut words: Vec<(&String, &usize)> = self.df.iter().collect();
        words.sort();
        let mut text = format!("sessions\t{}\n", self.sessions);
        for (w, n) in words {
            text.push_str(&format!("{w}\t{n}\n"));
        }
        lf_model::manifest::sha256_hex(text.as_bytes())
    }
}

/// Whether a normalized word is a dictionary target: rare and session-specific.
pub fn is_target(word: &str, common: &BTreeSet<String>, df: &SessionDf) -> bool {
    crate::exp2_data::is_rare(word, common) && df.is_session_specific(word)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refs(n: usize, word_in: impl Fn(usize) -> bool) -> Vec<(String, String)> {
        (0..n)
            .flat_map(|s| {
                let session = format!("s{s}");
                let mut v = vec![(session.clone(), "The Zorbin report.".to_owned())];
                if word_in(s) {
                    v.push((session, "Quaxel, quaxel and QUAXEL.".to_owned()));
                }
                v
            })
            .collect()
    }

    fn df_of(r: &[(String, String)]) -> SessionDf {
        SessionDf::from_references(r.iter().map(|(s, t)| (s.as_str(), t.as_str())))
    }

    #[test]
    fn counts_sessions_not_occurrences() {
        // "quaxel" occurs three times in each of 3 sessions, normalized.
        let d = df_of(&refs(10, |s| s < 3));
        assert_eq!(d.sessions(), 10);
        assert_eq!(d.df("quaxel"), 3);
        assert_eq!(d.df("zorbin"), 10);
        assert_eq!(d.df("the"), 10);
        assert_eq!(d.df("absent"), 0);
        // Utterances of one session in any order count once.
        let mut r = refs(4, |s| s == 1);
        r.reverse();
        assert_eq!(df_of(&r).df("quaxel"), 1);
    }

    #[test]
    fn threshold_is_five_percent_with_a_floor_of_two() {
        // 100 sessions: at most 5.
        let at = |n: usize, k: usize| df_of(&refs(n, |s| s < k));
        assert_eq!(at(100, 0).max_df(), 5);
        assert!(at(100, 5).is_session_specific("quaxel"));
        assert!(!at(100, 6).is_session_specific("quaxel"));
        // 1010 sessions: 50.
        assert_eq!(at(1010, 0).max_df(), 50);
        assert!(at(1010, 50).is_session_specific("quaxel"));
        assert!(!at(1010, 51).is_session_specific("quaxel"));
        // Small sets: 5% would be 0 or 1, the floor keeps two sessions.
        for n in [5, 20, 39] {
            assert_eq!(at(n, 0).max_df(), 2, "{n}");
            assert!(at(n, 2).is_session_specific("quaxel"));
            assert!(!at(n, 3).is_session_specific("quaxel"));
        }
        assert_eq!(at(40, 0).max_df(), 2);
        assert_eq!(at(60, 0).max_df(), 3);
    }

    #[test]
    fn targets_are_rare_and_session_specific() {
        let common: BTreeSet<String> = ["the", "report"].map(String::from).into();
        let d = df_of(&refs(100, |s| s < 4));
        assert!(is_target("quaxel", &common, &d));
        // In every session: rare but generic.
        assert!(!is_target("zorbin", &common, &d));
        // Common words and numbers never count.
        assert!(!is_target("the", &common, &d));
        assert!(!is_target("2019", &common, &d));
        // Unseen rare words pass (DF 0), e.g. keyword lists.
        assert!(is_target("plinth", &common, &d));
    }

    #[test]
    fn deterministic() {
        let r = refs(50, |s| s % 7 == 0);
        assert_eq!(df_of(&r), df_of(&r));
        let mut shuffled = r.clone();
        shuffled.reverse();
        shuffled.rotate_left(17);
        assert_eq!(df_of(&r), df_of(&shuffled));
        // The hash identifies the table, not the input order.
        assert_eq!(df_of(&r).sha256(), df_of(&shuffled).sha256());
        assert_ne!(
            df_of(&r).sha256(),
            df_of(&refs(50, |s| s % 6 == 0)).sha256()
        );
        assert_ne!(
            df_of(&r).sha256(),
            df_of(&refs(51, |s| s % 7 == 0)).sha256()
        );
    }

    #[test]
    fn df_source_is_train_only_when_there_is_one() {
        // Regression (review B2): held-out references never change train DF.
        assert_eq!(df_source_split(true, "dev"), "train");
        assert_eq!(df_source_split(true, "heldout"), "train");
        assert_eq!(df_source_split(true, "train"), "train");
        assert_eq!(df_source_split(false, "heldout"), "heldout");
        assert_eq!(df_source_split(false, "dev"), "dev");
    }

    #[test]
    fn keyword_entries_keep_their_original_and_lowercase_surfaces() {
        assert_eq!(keyword_entry_surfaces("GPU"), ["GPU", "gpu"]);
        assert_eq!(
            keyword_entry_surfaces("NEURAL NETWORK"),
            ["NEURAL NETWORK", "neural network"]
        );
        assert_eq!(keyword_entry_surfaces("quaxel"), ["quaxel"]);
        assert_eq!(keyword_entry_surfaces("iPhone"), ["iPhone", "iphone"]);
    }

    #[test]
    fn uncased_entries_are_lowercased_before_variants() {
        // Regression (review B5).
        assert_eq!(normalize_entry_surface("QUAXEL", Casing::Uncased), "quaxel");
        assert_eq!(
            normalize_entry_surface("neural NETWORK", Casing::Uncased),
            "neural network"
        );
        assert_eq!(normalize_entry_surface("iPhone", Casing::Cased), "iPhone");
        assert_eq!(normalize_entry_surface("QUAXEL", Casing::Cased), "QUAXEL");
    }
}
