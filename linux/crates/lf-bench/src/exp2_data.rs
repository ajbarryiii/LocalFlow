//! Shared definitions of experiment 2 (learned biasing), used by
//! `lf-bias-eval` and `lf-bias-prep` so both sides split and count words
//! identically:
//!
//! - SPGISpeech calls: a fixed 10% are dev, by a hash of the call id.
//! - Rare words for SPGISpeech and GigaSpeech: not among the 5,000 most
//!   frequent words of Le et al.'s `all_words.count.txt` (their
//!   `common_words_5k.txt`), and containing a letter (so formatted numbers
//!   such as "2019" never count).
//! - Session ids: the call id before "/" (SPGISpeech, Earnings-22) and the
//!   GigaSpeech session before "_S".
//! - Le-style simulated per-utterance lists (rare words of the reference
//!   plus `n` distractors from Le's rare-word list), for LibriSpeech dev-other.

#![allow(dead_code)]

use std::collections::BTreeSet;

use crate::wer::normalize;

/// Size of Le et al.'s common-word list.
pub const COMMON_WORDS: usize = 5000;

/// The SPGISpeech call of an utterance id ("call/123.wav" -> "call").
pub fn spgi_call_id(utt_id: &str) -> &str {
    utt_id.split('/').next().unwrap_or(utt_id)
}

/// Whether a SPGISpeech call is in the dev 10%: the first 8 bytes of
/// SHA-256(call id), big-endian, are 0 mod 10. Every other call is train.
/// (Python: `int(hashlib.sha256(call.encode()).hexdigest()[:16], 16) % 10 == 0`.)
pub fn spgi_is_dev(call_id: &str) -> bool {
    let hex = lf_model::manifest::sha256_hex(call_id.as_bytes());
    u64::from_str_radix(&hex[..16], 16)
        .expect("sha256 hex")
        .is_multiple_of(10)
}

/// The GigaSpeech session of an utterance id ("POD1000000005_S0000000" ->
/// "POD1000000005").
pub fn gigaspeech_session(utt_id: &str) -> &str {
    utt_id.split("_S").next().unwrap_or(utt_id)
}

/// The first [`COMMON_WORDS`] words of Le et al.'s `all_words.count.txt`
/// (one `word<TAB>count` per line, by descending count), which is their
/// `common_words_5k.txt`. Words are normalized as the harness does.
pub fn common_words(all_words_count: &str) -> Result<BTreeSet<String>, String> {
    let mut out = BTreeSet::new();
    let mut lines = 0;
    for line in all_words_count.lines().filter(|l| !l.trim().is_empty()) {
        if lines == COMMON_WORDS {
            break;
        }
        let word = line
            .split_whitespace()
            .next()
            .ok_or("empty line in the word-count list")?;
        out.extend(normalize(word));
        lines += 1;
    }
    if lines < COMMON_WORDS {
        return Err(format!(
            "word-count list has {lines} words, expected at least {COMMON_WORDS}"
        ));
    }
    Ok(out)
}

/// Whether a normalized word is rare: not a common word, and with at least
/// one letter.
pub fn is_rare(word: &str, common: &BTreeSet<String>) -> bool {
    word.chars().any(char::is_alphabetic) && !common.contains(word)
}

/// The rare words (normalized, deduplicated) of `text`.
pub fn rare_words_of(text: &str, common: &BTreeSet<String>) -> BTreeSet<String> {
    normalize(text)
        .into_iter()
        .filter(|w| is_rare(w, common))
        .collect()
}

/// A Le-style simulated biasing list: the rare words of the reference
/// (`rare`), plus `n` distractors drawn without replacement from `pool`
/// (Le's `all_rare_words.txt`, normalized), never one of `rare`; sorted, as
/// Le's lists are. The draw is a seeded shuffle keyed by `seed` and `id`.
pub fn le_list(
    id: &str,
    rare: &BTreeSet<String>,
    pool: &[String],
    n: usize,
    seed: u64,
) -> Vec<String> {
    let mut rng = lf_model::rng::SplitMix64::new(seed ^ fnv1a(id));
    let mut picked: BTreeSet<&str> = BTreeSet::new();
    // Rejection sampling: the pool is ~200k words, the list at most ~1000.
    let budget = pool
        .iter()
        .filter(|w| !rare.contains(*w))
        .collect::<BTreeSet<_>>()
        .len();
    while picked.len() < n.min(budget) {
        let w = &pool[rng.below(pool.len() as u64) as usize];
        if !rare.contains(w) {
            picked.insert(w);
        }
    }
    let mut out: Vec<String> = rare.iter().cloned().collect();
    out.extend(picked.into_iter().map(str::to_owned));
    out.sort();
    out.dedup();
    out
}

fn fnv1a(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// A fixed subset of `ids`: `n` of them after a seeded shuffle of the sorted
/// ids, returned sorted.
pub fn fixed_subset(ids: &[String], n: usize, seed: u64) -> Vec<String> {
    let mut v: Vec<String> = ids.to_vec();
    v.sort();
    v.dedup();
    let mut rng = lf_model::rng::SplitMix64::new(seed);
    for i in (1..v.len()).rev() {
        let j = rng.below(i as u64 + 1) as usize;
        v.swap(i, j);
    }
    v.truncate(n);
    v.sort();
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The first dev ids among `format!("{i:032x}")`, pinned (the first was
    /// checked with `sha256sum`: 0x5ef2077f964e0002 % 10 == 0).
    const PINNED_DEV: [&str; 3] = [
        "0000000000000000000000000000000b",
        "00000000000000000000000000000010",
        "00000000000000000000000000000015",
    ];

    #[test]
    fn spgi_split_is_a_fixed_hash() {
        // Pinned values: changing the hash would silently move calls between
        // train and dev (the Python side uses the same formula).
        let calls: Vec<String> = (0..2000).map(|i| format!("{i:032x}")).collect();
        let dev: Vec<&String> = calls.iter().filter(|c| spgi_is_dev(c)).collect();
        assert!((150..250).contains(&dev.len()), "{}", dev.len());
        // SHA-256("abc") = ba7816bf8f01cfea...: 0xba7816bf8f01cfea % 10 = 4.
        assert_eq!(0xba78_16bf_8f01_cfeau64 % 10, 4);
        assert!(!spgi_is_dev("abc"));
        assert_eq!(
            dev.iter().take(3).map(|s| s.as_str()).collect::<Vec<_>>(),
            PINNED_DEV
        );
        assert_eq!(
            spgi_call_id("0018ad922e541b415ae60e175160b976/118.wav"),
            "0018ad922e541b415ae60e175160b976"
        );
        assert_eq!(
            gigaspeech_session("POD1000000005_S0000000"),
            "POD1000000005"
        );
        assert_eq!(
            gigaspeech_session("YOU1000000038_S0000012"),
            "YOU1000000038"
        );
    }

    #[test]
    fn rare_needs_a_letter_and_no_common_word() {
        let counts: String = (0..COMMON_WORDS)
            .map(|i| format!("w{i}\t{}\n", 10_000 - i))
            .chain(["zorbin\t1\n".to_owned()])
            .collect();
        let common = common_words(&counts).unwrap();
        assert_eq!(common.len(), COMMON_WORDS);
        assert!(common.contains("w0") && common.contains("w4999") && !common.contains("zorbin"));
        assert!(is_rare("zorbin", &common));
        assert!(is_rare("q3", &common));
        assert!(!is_rare("w12", &common));
        assert!(!is_rare("2019", &common));
        assert!(!is_rare("5", &common));
        assert_eq!(
            rare_words_of("Zorbin's W1 report: 2019, Q3, zorbin.", &common),
            ["q3", "report", "zorbin", "zorbin's"]
                .map(String::from)
                .into()
        );
        assert!(common_words("a\t1\nb\t1\n").is_err());
    }

    #[test]
    fn le_lists_are_seeded_sorted_and_hold_the_rare_words() {
        let pool: Vec<String> = (0..300).map(|i| format!("r{i}")).collect();
        let rare: BTreeSet<String> = ["r5", "zorbin"].map(String::from).into();
        let a = le_list("utt1", &rare, &pool, 50, 7);
        assert_eq!(a.len(), 52);
        assert!(a.windows(2).all(|w| w[0] < w[1]));
        assert!(rare.iter().all(|r| a.contains(r)));
        assert_eq!(a, le_list("utt1", &rare, &pool, 50, 7));
        assert_ne!(a, le_list("utt2", &rare, &pool, 50, 7));
        assert_ne!(a, le_list("utt1", &rare, &pool, 50, 8));
        // A tiny pool is exhausted, never looped forever.
        let small: Vec<String> = vec!["r5".into(), "x".into()];
        assert_eq!(le_list("u", &rare, &small, 10, 1), ["r5", "x", "zorbin"]);
    }

    #[test]
    fn fixed_subset_is_seeded_and_sorted() {
        let ids: Vec<String> = (0..100).rev().map(|i| format!("u{i:03}")).collect();
        let s = fixed_subset(&ids, 10, 3);
        assert_eq!(s.len(), 10);
        assert!(s.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(s, fixed_subset(&ids, 10, 3));
        assert_ne!(s, fixed_subset(&ids, 10, 4));
        assert_eq!(fixed_subset(&ids, 1000, 3).len(), 100);
    }
}
