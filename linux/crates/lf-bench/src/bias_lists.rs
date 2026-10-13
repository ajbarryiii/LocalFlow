//! Biasing lists for the word-boosting evaluation.
//!
//! - LibriSpeech: the per-utterance lists of Le et al. 2021
//!   (`test-{clean,other}.biasing_{N}.tsv`: id, reference, JSON rare words of
//!   the reference, JSON biasing list).
//! - Session lists (Earnings-22): one dictionary per call, as a user's
//!   dictionary is session-wide. Targets are the call's reference words (simple
//!   normalizer) that are in a rare-word list, written in their most frequent
//!   cased surface form; distractors are other calls' targets in a fixed
//!   pseudo-random order, so a smaller list is a prefix of a larger one.

use std::collections::{BTreeMap, BTreeSet};

use crate::wer::normalize;

/// One row of a Le et al. reference file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LibriRow {
    pub id: String,
    pub reference: String,
    /// Rare words of the reference: the B-WER word set.
    pub rare: Vec<String>,
    /// The biasing list (a superset of `rare`).
    pub list: Vec<String>,
}

pub fn parse_libri_tsv(text: &str) -> Result<Vec<LibriRow>, String> {
    let mut rows = Vec::new();
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() != 4 {
            return Err(format!(
                "line {}: {} columns, expected 4",
                n + 1,
                cols.len()
            ));
        }
        let words = |s: &str| -> Result<Vec<String>, String> {
            serde_json::from_str(s).map_err(|e| format!("line {}: {e}", n + 1))
        };
        rows.push(LibriRow {
            id: cols[0].to_owned(),
            reference: cols[1].to_owned(),
            rare: words(cols[2])?,
            list: words(cols[3])?,
        });
    }
    Ok(rows)
}

/// Words of `text` as the simple normalizer splits them, with case kept:
/// `(normalized, surface)` for each surface piece that normalizes to exactly
/// one word.
pub fn cased_words(text: &str) -> Vec<(String, String)> {
    let cleaned: String = text
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '\'' {
                c
            } else {
                ' '
            }
        })
        .collect();
    cleaned
        .split_whitespace()
        .map(|w| w.trim_matches('\''))
        .filter(|w| !w.is_empty())
        .filter_map(|w| match normalize(w).as_slice() {
            [n] => Some((n.clone(), w.to_owned())),
            _ => None,
        })
        .collect()
}

/// Per session, the target words: normalized reference words in `rare`, each
/// with its most frequent surface form in that session (ties: the
/// lexicographically smallest form). Sorted by normalized word.
pub fn session_targets<'a>(
    references: impl IntoIterator<Item = (&'a str, &'a str)>,
    rare: &BTreeSet<String>,
) -> BTreeMap<String, Vec<(String, String)>> {
    // session -> normalized -> surface -> count
    let mut counts: BTreeMap<String, BTreeMap<String, BTreeMap<String, usize>>> = BTreeMap::new();
    for (session, text) in references {
        let s = counts.entry(session.to_owned()).or_default();
        for (norm, surface) in cased_words(text) {
            if rare.contains(&norm) {
                *s.entry(norm).or_default().entry(surface).or_default() += 1;
            }
        }
    }
    counts
        .into_iter()
        .map(|(session, words)| {
            let targets = words
                .into_iter()
                .map(|(norm, forms)| {
                    // Highest count; among equal counts the first (smallest) form.
                    let best = forms
                        .iter()
                        .fold(None::<(&String, usize)>, |acc, (f, &c)| match acc {
                            Some((_, bc)) if bc >= c => acc,
                            _ => Some((f, c)),
                        })
                        .map(|(f, _)| f.clone())
                        .unwrap_or_default();
                    (norm, best)
                })
                .collect();
            (session, targets)
        })
        .collect()
}

/// One session's dictionary at one size.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionList {
    pub size: usize,
    /// Number of targets; when it exceeds `size`, all are kept and the list is
    /// longer than `size`.
    pub targets: usize,
    /// Distractors taken from other sessions' targets (the rest, if any, came
    /// from the fallback pool).
    pub from_other_sessions: usize,
    /// Surface forms, targets first, then distractors.
    pub entries: Vec<String>,
}

fn fnv1a(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Fisher-Yates shuffle with SplitMix64.
pub fn shuffle<T>(v: &mut [T], seed: u64) {
    let mut rng = lf_model::rng::SplitMix64::new(seed);
    for i in (1..v.len()).rev() {
        let j = rng.below(i as u64 + 1) as usize;
        v.swap(i, j);
    }
}

/// Dictionaries for every session and size.
///
/// Distractors for a session are first the other sessions' targets (one
/// surface form per normalized word: the one of the first session in sorted
/// order), then, if those run out, words of `fallback`; never a word of the
/// session's own vocabulary (`vocab`: its normalized reference words) or one of
/// its targets. Each source is in an order fixed by `seed` and the session id,
/// so a smaller list is a prefix of a larger one.
pub fn session_lists(
    targets: &BTreeMap<String, Vec<(String, String)>>,
    vocab: &BTreeMap<String, BTreeSet<String>>,
    fallback: &[String],
    sizes: &[usize],
    seed: u64,
) -> BTreeMap<String, Vec<SessionList>> {
    let mut pool: BTreeMap<&str, &str> = BTreeMap::new();
    for words in targets.values() {
        for (norm, surface) in words {
            pool.entry(norm).or_insert(surface);
        }
    }
    let empty = BTreeSet::new();
    let max_size = sizes.iter().copied().max().unwrap_or(0);
    targets
        .iter()
        .map(|(session, words)| {
            let own: BTreeSet<&str> = words
                .iter()
                .map(|(n, _)| n.as_str())
                .chain(
                    vocab
                        .get(session)
                        .unwrap_or(&empty)
                        .iter()
                        .map(String::as_str),
                )
                .collect();
            let mut others: Vec<&str> = pool
                .iter()
                .filter(|(n, _)| !own.contains(*n))
                .map(|(_, &s)| s)
                .collect();
            shuffle(&mut others, seed ^ fnv1a(session));
            let n_others = others.len();
            let mut distractors: Vec<String> = others.into_iter().map(str::to_owned).collect();
            let need = max_size.saturating_sub(words.len() + n_others);
            if need > 0 {
                let mut extra: Vec<&String> = fallback
                    .iter()
                    .filter(|w| !own.contains(w.as_str()) && !pool.contains_key(w.as_str()))
                    .collect();
                extra.sort();
                extra.dedup();
                shuffle(&mut extra, seed ^ fnv1a(session) ^ 0x5bd1_e995);
                distractors.extend(extra.into_iter().take(need).cloned());
            }
            let lists = sizes
                .iter()
                .map(|&size| {
                    let mut entries: Vec<String> = words.iter().map(|(_, s)| s.clone()).collect();
                    let pad = size.saturating_sub(entries.len());
                    entries.extend(distractors.iter().take(pad).cloned());
                    SessionList {
                        size,
                        targets: words.len(),
                        from_other_sessions: pad.min(n_others),
                        entries,
                    }
                })
                .collect();
            (session.clone(), lists)
        })
        .collect()
}

/// Splits sessions into a tuning half (the first `len / 2` after a seeded
/// shuffle of the sorted ids) and a held-out half.
pub fn split_sessions(
    sessions: &BTreeSet<String>,
    seed: u64,
) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut v: Vec<&String> = sessions.iter().collect();
    shuffle(&mut v, seed);
    let half = v.len() / 2;
    (
        v[..half].iter().map(|s| (*s).clone()).collect(),
        v[half..].iter().map(|s| (*s).clone()).collect(),
    )
}

/// [`session_lists`] run separately on each part of a split, so a session's
/// distractors come only from sessions in the same part (then `fallback`):
/// one part's references cannot influence another part's dictionaries.
/// Sessions in no part are dropped.
pub fn session_lists_by_split(
    targets: &BTreeMap<String, Vec<(String, String)>>,
    vocab: &BTreeMap<String, BTreeSet<String>>,
    fallback: &[String],
    sizes: &[usize],
    seed: u64,
    parts: &[&BTreeSet<String>],
) -> BTreeMap<String, Vec<SessionList>> {
    let mut out = BTreeMap::new();
    for part in parts {
        let t: BTreeMap<String, Vec<(String, String)>> = targets
            .iter()
            .filter(|(s, _)| part.contains(*s))
            .map(|(s, w)| (s.clone(), w.clone()))
            .collect();
        out.extend(session_lists(&t, vocab, fallback, sizes, seed));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rare(words: &str) -> BTreeSet<String> {
        words.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_le_et_al_rows() {
        let text = "1-2-3\tthe zorbin sang\t[\"zorbin\"]\t[\"alpha\", \"zorbin\"]\n\n";
        let rows = parse_libri_tsv(text).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "1-2-3");
        assert_eq!(rows[0].rare, vec!["zorbin"]);
        assert_eq!(rows[0].list, vec!["alpha", "zorbin"]);
        assert!(parse_libri_tsv("a\tb\n").is_err());
    }

    #[test]
    fn cased_words_follow_the_normalizer() {
        let w = cased_words("Hello, Zorbin's 'quoted' Q3-results EBITDA.");
        let norms: Vec<&str> = w.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(
            norms,
            vec!["hello", "zorbin's", "quoted", "q3", "results", "ebitda"]
        );
        assert_eq!(w[1].1, "Zorbin's");
        assert_eq!(w[5].1, "EBITDA");
        let joined: Vec<String> = w.into_iter().map(|(n, _)| n).collect();
        assert_eq!(
            joined,
            normalize("Hello, Zorbin's 'quoted' Q3-results EBITDA.")
        );
    }

    #[test]
    fn targets_keep_the_most_frequent_cased_form() {
        let refs = [
            ("c1", "Zorbin met the zorbin team. ZORBIN!"),
            ("c1", "Zorbin and Quaxel."),
            ("c2", "Quaxel quaxel plinth"),
            ("c2", "The plain words."),
        ];
        let t = session_targets(refs, &rare("zorbin quaxel plinth"));
        assert_eq!(
            t["c1"],
            vec![
                ("quaxel".to_owned(), "Quaxel".to_owned()),
                ("zorbin".to_owned(), "Zorbin".to_owned())
            ]
        );
        // Tie between "Quaxel" and "quaxel": the smaller string wins.
        assert_eq!(t["c2"][1], ("quaxel".to_owned(), "Quaxel".to_owned()));
        assert_eq!(t["c2"][0], ("plinth".to_owned(), "plinth".to_owned()));
    }

    fn synthetic_targets() -> BTreeMap<String, Vec<(String, String)>> {
        let mut t = BTreeMap::new();
        for c in 0..6 {
            let words: Vec<(String, String)> = (0..(3 + c))
                .map(|i| (format!("w{c}x{i}"), format!("W{c}x{i}")))
                .collect();
            t.insert(format!("call{c}"), words);
        }
        // A word shared by two sessions is never its own distractor.
        t.get_mut("call0")
            .unwrap()
            .push(("shared".into(), "Shared".into()));
        t.get_mut("call1")
            .unwrap()
            .push(("shared".into(), "shared".into()));
        t
    }

    fn synthetic_vocab() -> BTreeMap<String, BTreeSet<String>> {
        // call2's ordinary vocabulary contains call3's first target and a
        // fallback word: neither may be offered to call2 as a distractor.
        let mut v = BTreeMap::new();
        v.insert("call2".to_owned(), rare("the w3x0 fb1 report"));
        v
    }

    fn fallback() -> Vec<String> {
        (0..40).map(|i| format!("fb{i}")).collect()
    }

    #[test]
    fn session_lists_have_targets_sizes_and_prefix_order() {
        let t = synthetic_targets();
        let vocab = synthetic_vocab();
        let lists = session_lists(&t, &vocab, &fallback(), &[5, 10, 40], 7);
        for (session, sizes) in &lists {
            let mut own: BTreeSet<String> = t[session].iter().map(|(n, _)| n.clone()).collect();
            own.extend(vocab.get(session).cloned().unwrap_or_default());
            for l in sizes {
                assert_eq!(l.targets, t[session].len());
                assert_eq!(l.entries.len(), l.size.max(l.targets));
                // Every target is present, first, in its cased form.
                for (i, (_, s)) in t[session].iter().enumerate() {
                    assert_eq!(&l.entries[i], s);
                }
                // Distractors are unique and never in this session's vocabulary.
                let distractors = &l.entries[l.targets..];
                let uniq: BTreeSet<String> = distractors.iter().map(|d| d.to_lowercase()).collect();
                assert_eq!(uniq.len(), distractors.len());
                assert!(uniq.is_disjoint(&own));
                // Other sessions' targets come before fallback words.
                let others = distractors
                    .iter()
                    .take_while(|d| !d.starts_with("fb"))
                    .count();
                assert_eq!(others, l.from_other_sessions);
                assert!(distractors[others..].iter().all(|d| d.starts_with("fb")));
            }
            // A smaller list is a prefix of a larger one.
            for w in sizes.windows(2) {
                assert!(w[1].entries.starts_with(&w[0].entries));
            }
        }
        // call5 has 8 targets: at size 5 all are kept.
        assert_eq!(lists["call5"][0].entries.len(), 8);
        // The pool has 34 distinct target words. call0 owns 4 (with "shared"),
        // so 30 come from other sessions and 6 from the fallback at size 40.
        assert_eq!(lists["call0"][2].from_other_sessions, 30);
        // call2 owns 5 targets, and w3x0 is in its vocabulary: 28 others.
        assert_eq!(lists["call2"][2].from_other_sessions, 28);
        assert!(!lists["call2"][2].entries.contains(&"fb1".to_owned()));
    }

    #[test]
    fn session_lists_are_deterministic_and_seeded() {
        let (t, v, f) = (synthetic_targets(), synthetic_vocab(), fallback());
        assert_eq!(
            session_lists(&t, &v, &f, &[10, 40], 7),
            session_lists(&t, &v, &f, &[10, 40], 7)
        );
        assert_ne!(
            session_lists(&t, &v, &f, &[10], 7),
            session_lists(&t, &v, &f, &[10], 8)
        );
    }

    #[test]
    fn split_is_a_deterministic_partition() {
        let s: BTreeSet<String> = (0..11).map(|i| format!("s{i}")).collect();
        let (a, b) = split_sessions(&s, 3);
        assert_eq!((a.len(), b.len()), (5, 6));
        assert!(a.is_disjoint(&b));
        assert_eq!(a.union(&b).cloned().collect::<BTreeSet<_>>(), s);
        assert_eq!(split_sessions(&s, 3), (a, b));
    }

    #[test]
    fn split_lists_do_not_leak_across_parts() {
        let t = synthetic_targets();
        let v = synthetic_vocab();
        let f = fallback();
        let tune: BTreeSet<String> = ["call0", "call2", "call4"].map(String::from).into();
        let test: BTreeSet<String> = ["call1", "call3", "call5"].map(String::from).into();
        let lists = session_lists_by_split(&t, &v, &f, &[5, 40], 7, &[&tune, &test]);
        assert_eq!(lists.len(), 6);
        let targets_of = |part: &BTreeSet<String>| -> BTreeSet<String> {
            part.iter()
                .flat_map(|s| t[s].iter().map(|(_, surface)| surface.clone()))
                .collect()
        };
        let (tune_targets, test_targets) = (targets_of(&tune), targets_of(&test));
        for (session, sizes) in &lists {
            let other_part = if tune.contains(session) {
                &test_targets
            } else {
                &tune_targets
            };
            for l in sizes {
                // Distractors from sessions come from the same part only.
                for d in &l.entries[l.targets..l.targets + l.from_other_sessions] {
                    assert!(!other_part.contains(d), "{session}: {d} leaked");
                }
            }
        }
        // Rewriting every held-out session's targets leaves the tuning lists unchanged.
        let mut t2 = t.clone();
        for s in &test {
            t2.insert(s.clone(), vec![("zzz".into(), "Zzz".into())]);
        }
        let lists2 = session_lists_by_split(&t2, &v, &f, &[5, 40], 7, &[&tune, &test]);
        for s in &tune {
            assert_eq!(lists[s], lists2[s]);
        }
        // With few sessions per part, the fallback pool makes up the shortfall.
        assert!(lists["call0"][1].entries.len() == 40);
        assert!(lists["call0"][1].from_other_sessions < 40 - lists["call0"][1].targets);
    }
}
