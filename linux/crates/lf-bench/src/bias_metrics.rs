//! Biasing metrics following `score.py` of Le et al. 2021
//! (facebookresearch/fbai-speech, `is21_deep_bias`):
//!
//! - Alignment: weighted edit distance (substitution 4, insertion and
//!   deletion 3), ties broken diagonal first, then insertion, then deletion,
//!   exactly as `EditDistance.align` does.
//! - WER over all reference words. B-WER over reference words in the
//!   utterance's biasing set (in `score.py` this is the set of rare words of
//!   the reference), U-WER over the rest. An insertion counts towards B-WER
//!   when the inserted word is in the biasing set, else towards U-WER.
//!
//! Extra counts (not in `score.py`): matched biasing words (recall) and
//! list false alarms, the hypothesis occurrences of a list word beyond its
//! occurrences in the reference.

use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Match,
    Sub,
    Ins,
    Del,
}

/// One aligned position: `(code, reference index, hypothesis index)`.
/// Insertions have no reference index, deletions no hypothesis index.
pub type Step = (Code, Option<usize>, Option<usize>);

/// `score.py`'s alignment. Both sides empty gives an empty alignment
/// (`score.py` raises instead; such pairs contribute nothing either way).
pub fn align(refs: &[String], hyps: &[String]) -> Vec<Step> {
    const SUB: u32 = 4;
    const INDEL: u32 = 3;
    let (rows, cols) = (refs.len() + 1, hyps.len() + 1);
    let mut score = vec![0u32; rows * cols];
    // Back-pointer: 0 diagonal, 1 left (insertion), 2 up (deletion).
    let mut back = vec![0u8; rows * cols];
    for i in 0..rows {
        for j in 0..cols {
            let at = i * cols + j;
            if i == 0 && j == 0 {
                continue;
            }
            if i == 0 {
                score[at] = score[at - 1] + INDEL;
                back[at] = 1;
                continue;
            }
            if j == 0 {
                score[at] = score[at - cols] + INDEL;
                back[at] = 2;
                continue;
            }
            let diag = score[at - cols - 1] + if refs[i - 1] == hyps[j - 1] { 0 } else { SUB };
            let (mut best, mut ptr) = (diag, 0u8);
            let ins = score[at - 1] + INDEL;
            if ins < best {
                (best, ptr) = (ins, 1);
            }
            let del = score[at - cols] + INDEL;
            if del < best {
                (best, ptr) = (del, 2);
            }
            score[at] = best;
            back[at] = ptr;
        }
    }
    let mut out = Vec::with_capacity(rows.max(cols));
    let (mut i, mut j) = (rows - 1, cols - 1);
    while i > 0 || j > 0 {
        match back[i * cols + j] {
            0 => {
                let code = if refs[i - 1] == hyps[j - 1] {
                    Code::Match
                } else {
                    Code::Sub
                };
                out.push((code, Some(i - 1), Some(j - 1)));
                i -= 1;
                j -= 1;
            }
            1 => {
                out.push((Code::Ins, None, Some(j - 1)));
                j -= 1;
            }
            _ => {
                out.push((Code::Del, Some(i - 1), None));
                i -= 1;
            }
        }
    }
    out.reverse();
    out
}

/// Reference words and S/D/I counts of one error rate.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rate {
    pub words: usize,
    pub sub: usize,
    pub del: usize,
    pub ins: usize,
}

impl Rate {
    pub fn errors(&self) -> usize {
        self.sub + self.del + self.ins
    }

    /// Error rate in percent; `None` (undefined) without reference words, even
    /// when there are insertions.
    pub fn percent(&self) -> Option<f64> {
        (self.words > 0).then(|| 100.0 * self.errors() as f64 / self.words as f64)
    }

    pub fn add(&mut self, o: &Rate) {
        self.words += o.words;
        self.sub += o.sub;
        self.del += o.del;
        self.ins += o.ins;
    }
}

/// Counts for one utterance or a sum over utterances.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub wer: Rate,
    pub b: Rate,
    pub u: Rate,
    /// Biasing-set reference words recognized (aligned as matches).
    pub b_matched: usize,
    /// Hypothesis occurrences of list words beyond their reference count.
    pub false_alarms: usize,
}

impl Counts {
    pub fn add(&mut self, o: &Counts) {
        self.wer.add(&o.wer);
        self.b.add(&o.b);
        self.u.add(&o.u);
        self.b_matched += o.b_matched;
        self.false_alarms += o.false_alarms;
    }

    /// Fraction of biasing-set reference words recognized; `None` without any.
    pub fn recall(&self) -> Option<f64> {
        (self.b.words > 0).then(|| self.b_matched as f64 / self.b.words as f64)
    }
}

/// Per missed reference occurrence of a word, the first probe (index into
/// `matched_by_probe`, e.g. an alpha grid) at which it is recovered.
///
/// `base_matched` occurrences matched before boosting and `missed` did not.
/// At a probe, `matched - base_matched` (clipped to `0..=missed`) occurrences
/// count as recovered, so occurrence `j` (1-based) is recovered from the first
/// probe whose gain is at least `j`. Occurrences never recovered are `None`.
pub fn occurrence_first_recovery(
    base_matched: usize,
    missed: usize,
    matched_by_probe: &[usize],
) -> Vec<Option<usize>> {
    (1..=missed)
        .map(|j| {
            matched_by_probe
                .iter()
                .position(|&m| m.saturating_sub(base_matched) >= j)
        })
        .collect()
}

/// Missed occurrences recovered when `matched` occurrences match after
/// boosting (clipped to `0..=missed`).
pub fn recovered_occurrences(base_matched: usize, missed: usize, matched: usize) -> usize {
    matched.saturating_sub(base_matched).min(missed)
}

/// `score.py`'s WER/U-WER/B-WER for one utterance (`biasing`: the
/// utterance's biasing set) plus recall and false alarms against `list`
/// (the words the decoder was biased towards; empty for no biasing).
pub fn score(
    refs: &[String],
    hyps: &[String],
    biasing: &BTreeSet<String>,
    list: &BTreeSet<String>,
) -> Counts {
    let mut c = Counts::default();
    for (code, r, h) in align(refs, hyps) {
        if code == Code::Ins {
            let w = &hyps[h.unwrap()];
            c.wer.ins += 1;
            if biasing.contains(w) {
                c.b.ins += 1;
            } else {
                c.u.ins += 1;
            }
            continue;
        }
        let in_b = biasing.contains(&refs[r.unwrap()]);
        let part = if in_b { &mut c.b } else { &mut c.u };
        part.words += 1;
        c.wer.words += 1;
        match code {
            Code::Match => c.b_matched += usize::from(in_b),
            Code::Sub => {
                part.sub += 1;
                c.wer.sub += 1;
            }
            Code::Del => {
                part.del += 1;
                c.wer.del += 1;
            }
            Code::Ins => unreachable!(),
        }
    }
    c.false_alarms = false_alarms(refs, hyps, list);
    c
}

/// Hypothesis occurrences of `list` words beyond their reference count.
pub fn false_alarms(refs: &[String], hyps: &[String], list: &BTreeSet<String>) -> usize {
    if list.is_empty() {
        return 0;
    }
    let mut count: BTreeMap<&str, isize> = BTreeMap::new();
    for h in hyps.iter().filter(|w| list.contains(*w)) {
        *count.entry(h).or_default() += 1;
    }
    for r in refs {
        if let Some(n) = count.get_mut(r.as_str()) {
            *n -= 1;
        }
    }
    count.values().map(|&n| n.max(0) as usize).sum()
}

/// Reference occurrences of `word` aligned as matches.
pub fn matched(refs: &[String], hyps: &[String], word: &str) -> usize {
    align(refs, hyps)
        .into_iter()
        .filter(|&(code, r, _)| code == Code::Match && refs[r.unwrap()] == word)
        .count()
}

/// Errors on everything except the reference occurrences of `word`
/// (substitutions and deletions of other words, and all insertions).
pub fn errors_except(refs: &[String], hyps: &[String], word: &str) -> usize {
    align(refs, hyps)
        .into_iter()
        .filter(|&(code, r, _)| match code {
            Code::Match => false,
            Code::Ins => true,
            Code::Sub | Code::Del => refs[r.unwrap()] != word,
        })
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    fn set(s: &str) -> BTreeSet<String> {
        w(s).into_iter().collect()
    }

    fn codes(r: &str, h: &str) -> Vec<Code> {
        align(&w(r), &w(h)).into_iter().map(|s| s.0).collect()
    }

    #[test]
    fn alignment_follows_score_py_costs_and_ties() {
        use Code::*;
        assert_eq!(codes("a b c", "a b c"), vec![Match, Match, Match]);
        assert_eq!(codes("a b c", "a x c"), vec![Match, Sub, Match]);
        assert_eq!(codes("a b c", "a c"), vec![Match, Del, Match]);
        assert_eq!(codes("a c", "a b c"), vec![Match, Ins, Match]);
        assert_eq!(codes("", "x y"), vec![Ins, Ins]);
        assert_eq!(codes("x y", ""), vec![Del, Del]);
        assert!(codes("", "").is_empty());
        // Two substitutions (8) cost more than a deletion plus an insertion
        // (6) when the words shift by one: "a b" -> "b c".
        assert_eq!(codes("a b", "b c"), vec![Del, Match, Ins]);
        // A lone mismatch is a substitution (4), not deletion + insertion (6).
        assert_eq!(codes("a", "b"), vec![Sub]);
    }

    #[test]
    fn b_and_u_split_as_score_py() {
        let refs = w("the zephyr flew over quixotic hills");
        // zephyr -> zefir and quixotic -> big are substitutions; a trailing
        // "zephyr" is an insertion of a biasing word.
        let hyps = w("the zefir flew over big hills zephyr");
        let b = set("zephyr quixotic");
        let c = score(&refs, &hyps, &b, &BTreeSet::new());
        assert_eq!(c.wer.words, 6);
        assert_eq!((c.b.words, c.u.words), (2, 4));
        assert_eq!((c.b.sub, c.b.del, c.b.ins), (2, 0, 1));
        assert_eq!(c.u.errors(), 0);
        assert_eq!(c.wer.errors(), 3);
        assert_eq!(c.b_matched, 0);
        assert_eq!(c.recall(), Some(0.0));
        // Deleting a non-biasing word is a U error.
        let c = score(&refs, &w("the zephyr over quixotic hills"), &b, &b);
        assert_eq!((c.u.del, c.b.errors(), c.b_matched), (1, 0, 2));
        assert_eq!(c.recall(), Some(1.0));
    }

    #[test]
    fn exact_counts_on_a_simple_case() {
        let refs = w("call zorbin now");
        let b = set("zorbin");
        let c = score(&refs, &w("call zorbin now"), &b, &b);
        assert_eq!(
            (c.wer.errors(), c.b.words, c.b_matched, c.false_alarms),
            (0, 1, 1, 0)
        );
        let c = score(&refs, &w("call sorbin now"), &b, &b);
        assert_eq!((c.b.sub, c.u.errors(), c.b_matched), (1, 0, 0));
        // Insertion of a biasing word is a B error; of another word a U error.
        let c = score(&refs, &w("call zorbin zorbin now"), &b, &b);
        assert_eq!((c.b.ins, c.u.ins, c.false_alarms), (1, 0, 1));
        let c = score(&refs, &w("call zorbin now please"), &b, &b);
        assert_eq!((c.b.ins, c.u.ins, c.false_alarms), (0, 1, 0));
    }

    #[test]
    fn insertion_of_a_list_word_outside_the_biasing_set_is_u_but_a_false_alarm() {
        let refs = w("send the report");
        let biasing = BTreeSet::new();
        let list = set("tarrow");
        let c = score(&refs, &w("send tarrow the report"), &biasing, &list);
        assert_eq!((c.b.ins, c.u.ins, c.false_alarms), (0, 1, 1));
        // Substituting a list word for a reference word is also a false alarm.
        let c = score(&refs, &w("send the tarrow"), &biasing, &list);
        assert_eq!((c.u.sub, c.false_alarms), (1, 1));
    }

    #[test]
    fn false_alarms_count_excess_occurrences_only() {
        let list = set("alpha beta");
        assert_eq!(false_alarms(&w("alpha x"), &w("alpha x"), &list), 0);
        assert_eq!(
            false_alarms(&w("alpha x"), &w("alpha alpha beta"), &list),
            2
        );
        assert_eq!(false_alarms(&w("alpha alpha"), &w("alpha"), &list), 0);
        assert_eq!(false_alarms(&w("alpha"), &w("gamma"), &list), 0);
    }

    #[test]
    fn matched_and_errors_except() {
        let refs = w("a zed b zed");
        assert_eq!(matched(&refs, &w("a zed b zed"), "zed"), 2);
        assert_eq!(matched(&refs, &w("a said b zed"), "zed"), 1);
        assert_eq!(errors_except(&refs, &w("a said b zed"), "zed"), 0);
        assert_eq!(errors_except(&refs, &w("a zed c zed x"), "zed"), 2);
    }

    #[test]
    fn rates_sum() {
        let mut a = Counts::default();
        let b = score(&w("x y"), &w("x z"), &set("y"), &BTreeSet::new());
        a.add(&b);
        a.add(&b);
        assert_eq!((a.wer.words, a.wer.sub, a.b.words, a.b.sub), (4, 2, 2, 2));
        assert_eq!(a.wer.percent(), Some(50.0));
        assert_eq!(a.b.percent(), Some(100.0));
    }

    #[test]
    fn zero_denominators_are_undefined_not_zero() {
        // Every reference word is a biasing word: U-WER has an insertion but no
        // reference words, so it is undefined rather than 0%.
        let b = set("zorbin");
        let c = score(&w("zorbin"), &w("zorbin please"), &b, &b);
        assert_eq!((c.u.words, c.u.ins), (0, 1));
        assert_eq!(c.u.percent(), None);
        assert_eq!(c.b.percent(), Some(0.0));
        assert_eq!(c.recall(), Some(1.0));
        // No biasing words at all: B-WER and recall are undefined.
        let c = score(&w("plain words"), &w("plain words"), &BTreeSet::new(), &b);
        assert_eq!((c.b.percent(), c.recall()), (None, None));
        assert_eq!(c.wer.percent(), Some(0.0));
        assert_eq!(Rate::default().percent(), None);
    }

    #[test]
    fn occurrences_are_recovered_one_by_one() {
        // Three occurrences, one matched at baseline, two missed. The probes
        // recover nothing, then one, then both (and a probe that loses the
        // baseline match counts as nothing recovered).
        let first = occurrence_first_recovery(1, 2, &[1, 0, 2, 3, 3]);
        assert_eq!(first, vec![Some(2), Some(3)]);
        // Recovering more than were missed is clipped.
        assert_eq!(occurrence_first_recovery(0, 1, &[0, 4]), vec![Some(1)]);
        // Never recovered.
        assert_eq!(
            occurrence_first_recovery(0, 2, &[0, 1]),
            vec![Some(1), None]
        );
        assert!(occurrence_first_recovery(2, 0, &[2]).is_empty());
        assert_eq!(recovered_occurrences(1, 2, 0), 0);
        assert_eq!(recovered_occurrences(1, 2, 2), 1);
        assert_eq!(recovered_occurrences(1, 2, 9), 2);
    }
}
