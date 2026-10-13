//! Training dictionaries per call (experiment 2, DESIGN "Dictionaries for
//! training").
//!
//! - Targets: the call's rare reference words in their most frequent cased
//!   form (`bias_lists::session_targets`, as experiment 1's Earnings-22 lists).
//! - Target dropout: each target is left out with p = 0.2.
//! - Size: targets only, 100, 500 or 1000 entries with probabilities 0.2,
//!   0.2, 0.3, 0.3. When the kept targets exceed the size, all are kept.
//! - Distractors fill the rest, from the targets of the other calls of the
//!   same split (never a word of the call's own reference vocabulary or
//!   targets). 20% of them (rounded) are hard: the pool words nearest by
//!   character edit distance (of normalized forms) to any of the call's
//!   targets, dropped ones included, ties in a seeded random order. The
//!   rest are a seeded random draw from the remaining pool.
//!
//! Every draw comes from SplitMix64 seeded by the run seed, the call id and
//! the sample index, so a (call, sample) dictionary never depends on which
//! other calls are prepared.

#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};

use lf_model::rng::SplitMix64;

/// Probabilities of the size choices, in tenths: targets only, 100, 500, 1000.
pub const SIZE_TENTHS: [(Option<usize>, u64); 4] =
    [(None, 2), (Some(100), 2), (Some(500), 3), (Some(1000), 3)];
/// Target dropout, in tenths.
pub const DROPOUT_TENTHS: u64 = 2;
/// Share of distractors that are hard (nearest by edit distance).
pub const HARD_SHARE: f64 = 0.2;

/// One sampled dictionary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DictSample {
    /// `None`: targets only.
    pub size: Option<usize>,
    /// The call's targets before dropout.
    pub targets: usize,
    /// Kept targets (surface forms), in the call's target order.
    pub kept: Vec<String>,
    pub hard: Vec<String>,
    pub random: Vec<String>,
    /// Distractors missing because the pool ran out.
    pub short: usize,
}

impl DictSample {
    /// Kept targets, then hard, then random distractors.
    pub fn entries(&self) -> Vec<String> {
        self.kept
            .iter()
            .chain(&self.hard)
            .chain(&self.random)
            .cloned()
            .collect()
    }
}

pub fn fnv1a(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// The seed of one (call, sample) draw.
pub fn sample_seed(seed: u64, call: &str, sample: u32) -> u64 {
    seed ^ fnv1a(call) ^ (sample as u64 + 1).wrapping_mul(0x9e37_79b9_7f4a_7c15)
}

/// The distractor pool of a split: every normalized target word of `calls`,
/// with the surface form of the first call (in sorted order) that has it,
/// sorted by normalized word (as `bias_lists::session_lists`).
pub fn target_pool(
    targets: &BTreeMap<String, Vec<(String, String)>>,
    calls: &BTreeSet<String>,
) -> Vec<(String, String)> {
    let mut pool: BTreeMap<&str, &str> = BTreeMap::new();
    for (call, words) in targets {
        if calls.contains(call) {
            for (n, s) in words {
                pool.entry(n).or_insert(s);
            }
        }
    }
    pool.into_iter()
        .map(|(n, s)| (n.to_owned(), s.to_owned()))
        .collect()
}

/// Levenshtein distance between `a` and `b` (characters), or any value
/// `>= bound` once it is certain to reach `bound`.
pub fn edit_distance(a: &[char], b: &[char], bound: u32) -> u32 {
    if a.len().abs_diff(b.len()) as u32 >= bound {
        return bound;
    }
    let mut prev: Vec<u32> = (0..=b.len() as u32).collect();
    let mut cur = vec![0u32; b.len() + 1];
    for (i, &ca) in a.iter().enumerate() {
        cur[0] = i as u32 + 1;
        let mut row_min = cur[0];
        for (j, &cb) in b.iter().enumerate() {
            let sub = prev[j] + u32::from(ca != cb);
            cur[j + 1] = sub.min(prev[j + 1] + 1).min(cur[j] + 1);
            row_min = row_min.min(cur[j + 1]);
        }
        if row_min >= bound {
            return bound;
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// For every pool word, its smallest edit distance to any of `targets`
/// (normalized forms); `u32::MAX` for all when there are no targets.
pub fn nearest_distances(pool: &[(String, String)], targets: &[(String, String)]) -> Vec<u32> {
    let t: Vec<Vec<char>> = targets.iter().map(|(n, _)| n.chars().collect()).collect();
    pool.iter()
        .map(|(n, _)| {
            let p: Vec<char> = n.chars().collect();
            t.iter()
                .fold(u32::MAX, |best, t| best.min(edit_distance(&p, t, best)))
        })
        .collect()
}

/// One dictionary for `call`. `targets`: the call's `(normalized, surface)`
/// targets; `own`: its normalized reference words; `pool`: the split's
/// [`target_pool`]; `nearest`: [`nearest_distances`] of the pool to the
/// call's targets.
pub fn sample_dictionary(
    call: &str,
    sample: u32,
    targets: &[(String, String)],
    own: &BTreeSet<String>,
    pool: &[(String, String)],
    nearest: &[u32],
    seed: u64,
) -> DictSample {
    assert_eq!(pool.len(), nearest.len());
    let s = sample_seed(seed, call, sample);
    let mut rng = SplitMix64::new(s);
    let mut k = rng.below(10);
    let mut size = None;
    for (choice, tenths) in SIZE_TENTHS {
        if k < tenths {
            size = choice;
            break;
        }
        k -= tenths;
    }
    let kept: Vec<String> = targets
        .iter()
        .filter(|_| rng.below(10) >= DROPOUT_TENTHS)
        .map(|(_, surface)| surface.clone())
        .collect();
    let n_dis = size.map_or(0, |n: usize| n.saturating_sub(kept.len()));
    let own_targets: BTreeSet<&str> = targets.iter().map(|(n, _)| n.as_str()).collect();
    let eligible: Vec<usize> = (0..pool.len())
        .filter(|&i| !own.contains(&pool[i].0) && !own_targets.contains(pool[i].0.as_str()))
        .collect();
    let n_hard = if targets.is_empty() {
        0
    } else {
        ((n_dis as f64 * HARD_SHARE).round() as usize).min(eligible.len())
    };
    // Hard: nearest first, ties in a seeded order.
    let tie =
        |i: usize| SplitMix64::new(s ^ (i as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9)).next_u64();
    let mut by_distance = eligible.clone();
    by_distance.sort_by_key(|&i| (nearest[i], tie(i), i));
    let hard_idx: BTreeSet<usize> = by_distance[..n_hard].iter().copied().collect();
    let hard: Vec<String> = by_distance[..n_hard]
        .iter()
        .map(|&i| pool[i].1.clone())
        .collect();
    let mut rest: Vec<usize> = eligible
        .into_iter()
        .filter(|i| !hard_idx.contains(i))
        .collect();
    crate::bias_lists::shuffle(&mut rest, s ^ 0x5bd1_e995);
    let n_random = (n_dis - n_hard).min(rest.len());
    let random: Vec<String> = rest[..n_random]
        .iter()
        .map(|&i| pool[i].1.clone())
        .collect();
    DictSample {
        size,
        targets: targets.len(),
        short: n_dis - n_hard - n_random,
        kept,
        hard,
        random,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(prefix: &str, n: usize) -> Vec<(String, String)> {
        (0..n)
            .map(|i| {
                (
                    format!("{prefix}{i}"),
                    format!("{}{i}", prefix.to_uppercase()),
                )
            })
            .collect()
    }

    #[test]
    fn edit_distance_is_levenshtein_with_a_bound() {
        let c = |s: &str| s.chars().collect::<Vec<_>>();
        assert_eq!(edit_distance(&c("kitten"), &c("sitting"), u32::MAX), 3);
        assert_eq!(edit_distance(&c(""), &c("abc"), u32::MAX), 3);
        assert_eq!(edit_distance(&c("zorbin"), &c("zorbin"), u32::MAX), 0);
        assert_eq!(edit_distance(&c("flaw"), &c("lawn"), u32::MAX), 2);
        // Bounded: never below the true distance's min with the bound.
        assert!(edit_distance(&c("kitten"), &c("sitting"), 2) >= 2);
        assert_eq!(edit_distance(&c("kitten"), &c("sitting"), 4), 3);
    }

    type Setup = (
        Vec<(String, String)>,
        BTreeSet<String>,
        Vec<(String, String)>,
    );

    fn setup() -> Setup {
        let targets = vec![
            ("zorbin".to_owned(), "Zorbin".to_owned()),
            ("quaxel".to_owned(), "Quaxel".to_owned()),
        ];
        let own: BTreeSet<String> = ["the", "zorbin", "quaxel", "plinthos"]
            .map(String::from)
            .into();
        let mut pool = words("w", 2000);
        pool.extend(
            ["zorbim", "quaxels", "zorbin", "plinthos", "zarbon"]
                .map(|w| (w.to_owned(), w.to_uppercase())),
        );
        pool.sort();
        (targets, own, pool)
    }

    #[test]
    fn dictionaries_are_deterministic_per_call_and_sample() {
        let (targets, own, pool) = setup();
        let near = nearest_distances(&pool, &targets);
        let a = sample_dictionary("callA", 0, &targets, &own, &pool, &near, 7);
        assert_eq!(
            a,
            sample_dictionary("callA", 0, &targets, &own, &pool, &near, 7)
        );
        // Samples, calls and seeds draw differently.
        let draws: BTreeSet<Vec<String>> = (0..8)
            .map(|s| sample_dictionary("callA", s, &targets, &own, &pool, &near, 7).entries())
            .collect();
        assert!(draws.len() > 4);
        let other_seed: Vec<Vec<String>> = (0..8)
            .map(|s| sample_dictionary("callA", s, &targets, &own, &pool, &near, 8).entries())
            .collect();
        assert!(other_seed.iter().any(|d| !draws.contains(d)));
    }

    #[test]
    fn dictionaries_follow_the_recipe() {
        let (targets, own, pool) = setup();
        let near = nearest_distances(&pool, &targets);
        let mut sizes: BTreeMap<Option<usize>, usize> = BTreeMap::new();
        let (mut kept, mut total) = (0usize, 0usize);
        for s in 0..2000 {
            let d = sample_dictionary("callB", s, &targets, &own, &pool, &near, 11);
            *sizes.entry(d.size).or_default() += 1;
            kept += d.kept.len();
            total += d.targets;
            let entries = d.entries();
            match d.size {
                None => assert_eq!(entries.len(), d.kept.len()),
                Some(n) => assert_eq!(entries.len(), n.max(d.kept.len())),
            }
            let n_dis = d.hard.len() + d.random.len();
            assert_eq!(d.hard.len(), (n_dis as f64 * 0.2).round() as usize);
            // Never the call's own words or targets; no duplicates.
            let norm: BTreeSet<String> = entries.iter().map(|e| e.to_lowercase()).collect();
            assert_eq!(norm.len(), entries.len());
            for e in d.hard.iter().chain(&d.random) {
                assert!(!own.contains(&e.to_lowercase()), "{e}");
            }
            // Hard distractors are the nearest words: "zorbim", "quaxels" and
            // "zarbon" (distance 1, 1, 2) come first.
            if d.hard.len() >= 3 {
                let first: BTreeSet<&str> = d.hard[..2].iter().map(String::as_str).collect();
                assert_eq!(first, BTreeSet::from(["ZORBIM", "QUAXELS"]));
                assert_eq!(d.hard[2], "ZARBON");
            }
        }
        // The size mixture and the dropout rate.
        let share = |k: Option<usize>| sizes[&k] as f64 / 2000.0;
        assert!((share(None) - 0.2).abs() < 0.04);
        assert!((share(Some(100)) - 0.2).abs() < 0.04);
        assert!((share(Some(500)) - 0.3).abs() < 0.04);
        assert!((share(Some(1000)) - 0.3).abs() < 0.04);
        assert!((kept as f64 / total as f64 - 0.8).abs() < 0.03);
    }

    #[test]
    fn targets_beyond_the_size_are_all_kept_and_the_pool_may_run_short() {
        let targets = words("t", 150);
        let pool = words("p", 300);
        let own = BTreeSet::new();
        let near = nearest_distances(&pool, &targets);
        for s in 0..40 {
            let d = sample_dictionary("callC", s, &targets, &own, &pool, &near, 3);
            match d.size {
                Some(100) => {
                    assert!(d.kept.len() > 100);
                    assert!(d.hard.is_empty() && d.random.is_empty());
                }
                Some(n) if n > 100 => {
                    assert_eq!(d.hard.len() + d.random.len() + d.short, n - d.kept.len());
                    assert!(d.hard.len() + d.random.len() <= 300);
                }
                _ => {}
            }
        }
        // A call without targets gets only random distractors.
        let d = (0..20)
            .map(|s| sample_dictionary("callD", s, &[], &own, &pool, &vec![u32::MAX; 300], 3))
            .find(|d| d.size == Some(100))
            .unwrap();
        assert!(d.hard.is_empty() && d.random.len() == 100);
    }

    #[test]
    fn pool_takes_the_first_calls_surface() {
        let mut t = BTreeMap::new();
        t.insert("a".to_owned(), vec![("x".to_owned(), "X".to_owned())]);
        t.insert(
            "b".to_owned(),
            vec![
                ("x".to_owned(), "x".to_owned()),
                ("y".to_owned(), "Y".to_owned()),
            ],
        );
        t.insert("c".to_owned(), vec![("z".to_owned(), "Z".to_owned())]);
        let calls: BTreeSet<String> = ["a", "b"].map(String::from).into();
        assert_eq!(
            target_pool(&t, &calls),
            vec![("x".into(), "X".into()), ("y".into(), "Y".into())]
        );
    }
}
