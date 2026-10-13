//! Custom-dictionary text rules that run around recognition (LocalFlow
//! DESIGN §1.4-§1.6 with the pinned interpretations P1-P5):
//!
//! - [`apply_casing`]: restores the exact spelling of dictionary entries
//!   with capitals in a raw transcript.
//! - [`correction_candidates`]: the words a user's correction may teach.
//! - [`Expected`] / [`verify_decision`]: whether a re-decode with a
//!   candidate boosted recovers it exactly where the user corrected it.
//!
//! Characters are Unicode scalars and strings compare by scalar sequence.
//! The texts are a user's dictation: nothing here logs them, and `Debug`
//! output of the types below shows no text.

use std::ops::Range;

use lf_asr::dictionary::{
    DictionaryEntry, fold, is_edge_punct, is_word_char, strip_edge_punct, validate, words,
};
use lf_asr::tokenizer::Tokenizer;

/// Longest text (UTF-8 bytes) a correction is examined for.
pub const MAX_CORRECTION_BYTES: usize = 4096;
/// Most words a correction is examined for.
pub const MAX_CORRECTION_WORDS: usize = 200;
/// The rewrite check applies from this many words.
pub const REWRITE_MIN_WORDS: usize = 5;
/// Most words on either side of a qualifying edit block.
pub const MAX_BLOCK_WORDS: usize = 3;
/// Words of unchanged context required on each side of the correction.
pub const VERIFY_CONTEXT_WORDS: usize = 2;

/// §1.4: entries containing a scalar that folding changes restore their
/// exact text wherever their fold matches a word-bounded span of the
/// original transcript. Matching runs left to right, longest entry first
/// (by scalars) then entry text in scalar order, and never rescans a
/// replacement. Lowercase-only entries change nothing.
pub fn apply_casing(text: &str, entries: &[DictionaryEntry]) -> String {
    let mut casing: Vec<(&str, Vec<char>)> = entries
        .iter()
        .filter(|e| {
            e.text
                .chars()
                .any(|c| !c.to_lowercase().eq(std::iter::once(c)))
        })
        .map(|e| (e.text.as_str(), fold(&e.text).chars().collect()))
        .collect();
    if casing.is_empty() {
        return text.to_owned();
    }
    casing.sort_by(|a, b| {
        b.0.chars()
            .count()
            .cmp(&a.0.chars().count())
            .then_with(|| a.0.cmp(b.0))
    });
    let t: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut p = 0;
    while p < t.len() {
        let starts_word = p == 0 || !is_word_char(t[p - 1]);
        let found = starts_word
            .then(|| {
                casing.iter().find_map(|(entry, target)| {
                    let end = fold_match(&t[p..], target)? + p;
                    (end == t.len() || !is_word_char(t[end])).then_some((*entry, end))
                })
            })
            .flatten();
        match found {
            Some((entry, end)) => {
                out.push_str(entry);
                p = end;
            }
            None => {
                out.push(t[p]);
                p += 1;
            }
        }
    }
    out
}

/// The number of leading scalars of `t` whose fold is exactly `target`.
fn fold_match(t: &[char], target: &[char]) -> Option<usize> {
    let mut at = 0;
    for (k, &c) in t.iter().enumerate() {
        for l in c.to_lowercase() {
            if target.get(at) != Some(&l) {
                return None;
            }
            at += 1;
        }
        if at == target.len() {
            return Some(k + 1);
        }
    }
    None
}

/// `norm(w)`: the fold of a word with leading and trailing edge
/// punctuation stripped.
pub fn norm(word: &str) -> String {
    strip_edge_punct(&fold(word)).to_owned()
}

/// A word of a text, as §1.5 tokenizes it.
struct Word<'a> {
    /// Index among the text's whitespace-separated words.
    index: usize,
    raw: &'a str,
    norm: String,
}

/// Whitespace-separated words with a non-empty norm.
fn tokenize(text: &str) -> Vec<Word<'_>> {
    words(text)
        .enumerate()
        .map(|(index, raw)| Word {
            index,
            raw,
            norm: norm(raw),
        })
        .filter(|w| !w.norm.is_empty())
        .collect()
}

fn norms(text: &str) -> Vec<String> {
    tokenize(text).into_iter().map(|w| w.norm).collect()
}

/// One step of an alignment of `a` to `b` (P2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    /// `a[a]` against `b[b]`; `equal` when they are equal.
    Diag { a: usize, b: usize, equal: bool },
    /// `a[a]` is missing from `b`.
    Del { a: usize },
    /// `b[b]` is missing from `a`.
    Ins { b: usize },
}

/// Levenshtein alignment of `a` to `b` (substitution, insertion and
/// deletion cost 1), in order. Backtracking from the end prefers the
/// diagonal (match or substitution), then deletion, then insertion.
pub fn align(a: &[String], b: &[String]) -> Vec<Op> {
    let (n, m) = (a.len(), b.len());
    let w = m + 1;
    let mut d = vec![0usize; (n + 1) * w];
    for (j, v) in d[..w].iter_mut().enumerate() {
        *v = j;
    }
    for i in 1..=n {
        d[i * w] = i;
        for j in 1..=m {
            let sub = d[(i - 1) * w + j - 1] + usize::from(a[i - 1] != b[j - 1]);
            d[i * w + j] = sub.min(d[(i - 1) * w + j] + 1).min(d[i * w + j - 1] + 1);
        }
    }
    let mut ops = Vec::with_capacity(n.max(m));
    let (mut i, mut j) = (n, m);
    while i > 0 || j > 0 {
        let here = d[i * w + j];
        if i > 0 && j > 0 {
            let equal = a[i - 1] == b[j - 1];
            if here == d[(i - 1) * w + j - 1] + usize::from(!equal) {
                ops.push(Op::Diag {
                    a: i - 1,
                    b: j - 1,
                    equal,
                });
                i -= 1;
                j -= 1;
                continue;
            }
        }
        if i > 0 && here == d[(i - 1) * w + j] + 1 {
            ops.push(Op::Del { a: i - 1 });
            i -= 1;
        } else {
            ops.push(Op::Ins { b: j - 1 });
            j -= 1;
        }
    }
    ops.reverse();
    ops
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CandidateKind {
    /// Different words: verified against the audio (§1.6).
    Replace,
    /// The same words with different capitals: accepted without audio.
    Casing,
}

impl CandidateKind {
    pub fn name(self) -> &'static str {
        match self {
            CandidateKind::Replace => "replace",
            CandidateKind::Casing => "casing",
        }
    }
}

/// A word or phrase a correction may teach (§1.5).
#[derive(Clone, PartialEq)]
pub struct Candidate {
    /// The validated entry text (casing kept).
    pub surface: String,
    pub kind: CandidateKind,
    /// The corrected words: indices into `before`'s whitespace-separated words.
    pub before_range: Range<usize>,
    /// Norms of the corrected words.
    pub before_words: Vec<String>,
}

impl std::fmt::Debug for Candidate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Candidate")
            .field("kind", &self.kind)
            .field("before_range", &self.before_range)
            .finish_non_exhaustive()
    }
}

/// §1.5 with P1: the blocks of a correction from `before` (what was typed)
/// to `after` (the user's edit) that could become dictionary entries, in
/// text order. Not yet in `entries` or `ignore` (identity keys); each
/// validated with `tokenizer`. Callers try at most three, in order.
pub fn correction_candidates(
    before: &str,
    after: &str,
    entries: &[DictionaryEntry],
    ignore: &[String],
    tokenizer: &Tokenizer,
) -> Vec<Candidate> {
    let too_big =
        |t: &str| t.len() > MAX_CORRECTION_BYTES || words(t).count() > MAX_CORRECTION_WORDS;
    if too_big(before) || too_big(after) {
        return Vec::new();
    }
    let (bw, aw) = (tokenize(before), tokenize(after));
    let bn: Vec<String> = bw.iter().map(|w| w.norm.clone()).collect();
    let an: Vec<String> = aw.iter().map(|w| w.norm.clone()).collect();
    let ops = align(&bn, &an);
    let edits = ops
        .iter()
        .filter(|op| !matches!(op, Op::Diag { equal: true, .. }))
        .count();
    let longest = bn.len().max(an.len());
    if longest >= REWRITE_MIN_WORDS && edits * 2 > longest {
        return Vec::new();
    }
    let surface = |w: &Word<'_>| strip_edge_punct(w.raw).to_owned();
    let is_edit = |op: &Op| match *op {
        Op::Diag { a, b, equal } => !equal || surface(&bw[a]) != surface(&aw[b]),
        Op::Del { .. } | Op::Ins { .. } => true,
    };
    let mut out = Vec::new();
    let mut k = 0;
    while k < ops.len() {
        if !is_edit(&ops[k]) {
            k += 1;
            continue;
        }
        let start = k;
        while k < ops.len() && is_edit(&ops[k]) {
            k += 1;
        }
        let (mut bi, mut ai) = (Vec::new(), Vec::new());
        for op in &ops[start..k] {
            match *op {
                Op::Diag { a, b, .. } => {
                    bi.push(a);
                    ai.push(b);
                }
                Op::Del { a } => bi.push(a),
                Op::Ins { b } => ai.push(b),
            }
        }
        if let Some(c) = qualify(&bi, &ai, &bw, &aw, entries, ignore, tokenizer) {
            out.push(c);
        }
    }
    out
}

fn qualify(
    bi: &[usize],
    ai: &[usize],
    bw: &[Word<'_>],
    aw: &[Word<'_>],
    entries: &[DictionaryEntry],
    ignore: &[String],
    tokenizer: &Tokenizer,
) -> Option<Candidate> {
    let sizes = 1..=MAX_BLOCK_WORDS;
    if !sizes.contains(&bi.len()) || !sizes.contains(&ai.len()) {
        return None;
    }
    let joined = ai.iter().map(|&i| aw[i].raw).collect::<Vec<_>>().join(" ");
    let entry = validate(joined.trim_matches(is_edge_punct), 1.0, tokenizer).ok()?;
    let key = entry.key();
    if entries.iter().any(|e| e.key() == key) || ignore.contains(&key) {
        return None;
    }
    let before_words: Vec<String> = bi.iter().map(|&i| bw[i].norm.clone()).collect();
    let after_norms: Vec<&str> = ai.iter().map(|&i| aw[i].norm.as_str()).collect();
    let kind = if before_words.iter().map(String::as_str).eq(after_norms) {
        if !entry.text.chars().skip(1).any(char::is_uppercase) {
            return None;
        }
        CandidateKind::Casing
    } else {
        CandidateKind::Replace
    };
    let first = bw[bi[0]].index;
    let last = bw[bi[bi.len() - 1]].index;
    Some(Candidate {
        surface: entry.text,
        kind,
        before_range: first..last + 1,
        before_words,
    })
}

/// The transcript a re-decode must reproduce for a candidate (§1.6 steps
/// 1-3): the base transcript's norms with the corrected words replaced by
/// the candidate's.
#[derive(Clone)]
pub struct Expected {
    /// `E`.
    words: Vec<String>,
    /// Where the candidate starts in `E`.
    at: usize,
    /// The candidate's norms (`x`).
    x: Vec<String>,
    /// The corrected words' norms.
    before_words: Vec<String>,
}

impl std::fmt::Debug for Expected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Expected")
            .field("words", &self.words.len())
            .field("at", &self.at)
            .finish_non_exhaustive()
    }
}

impl Expected {
    /// Maps `candidate` (from `typed`, the text that was typed) onto `base`,
    /// the raw transcript (§1.6 step 2): its words must align to a
    /// contiguous run of `base` with equal norms. `None` otherwise.
    pub fn new(base: &str, typed: &str, candidate: &Candidate) -> Option<Expected> {
        let b = norms(base);
        let tw = tokenize(typed);
        let positions: Vec<usize> = (0..tw.len())
            .filter(|&p| candidate.before_range.contains(&tw[p].index))
            .collect();
        if positions.is_empty()
            || !positions
                .iter()
                .map(|&p| &tw[p].norm)
                .eq(candidate.before_words.iter())
        {
            return None;
        }
        let tn: Vec<String> = tw.into_iter().map(|w| w.norm).collect();
        let ops = align(&tn, &b);
        let mut mapped = Vec::with_capacity(positions.len());
        for &p in &positions {
            let to = ops.iter().find_map(|op| match *op {
                Op::Diag { a, b, equal: true } if a == p => Some(b),
                _ => None,
            })?;
            mapped.push(to);
        }
        if mapped.windows(2).any(|w| w[1] != w[0] + 1) {
            return None;
        }
        let (i, j) = (mapped[0], mapped[mapped.len() - 1] + 1);
        let x = norms(&candidate.surface);
        let mut words = b[..i].to_vec();
        words.extend(x.iter().cloned());
        words.extend(b[j..].iter().cloned());
        Some(Expected {
            words,
            at: i,
            x,
            before_words: candidate.before_words.clone(),
        })
    }

    /// §1.6 step 4 for one re-decode `redecoded` (`N`): no edit within two
    /// words of the candidate in `E` (P3: an `N`-only word placed before
    /// `E[p]` counts when `lo <= p <= hi`), and every other edit block
    /// replaces the corrected words by the candidate (the same correction
    /// recovered elsewhere).
    pub fn accepts(&self, redecoded: &str) -> bool {
        let n = norms(redecoded);
        let e = &self.words;
        let ops = align(&n, e);
        let lo = self.at.saturating_sub(VERIFY_CONTEXT_WORDS);
        let hi = e.len().min(self.at + self.x.len() + VERIFY_CONTEXT_WORDS);
        let mut consumed = 0;
        for op in &ops {
            match *op {
                Op::Diag { b, equal, .. } => {
                    if !equal && (lo..hi).contains(&b) {
                        return false;
                    }
                    consumed = b + 1;
                }
                Op::Ins { b } => {
                    if (lo..hi).contains(&b) {
                        return false;
                    }
                    consumed = b + 1;
                }
                Op::Del { .. } => {
                    if (lo..=hi).contains(&consumed) {
                        return false;
                    }
                }
            }
        }
        let mut k = 0;
        while k < ops.len() {
            if matches!(ops[k], Op::Diag { equal: true, .. }) {
                k += 1;
                continue;
            }
            let (mut e_side, mut n_side) = (Vec::new(), Vec::new());
            while k < ops.len() && !matches!(ops[k], Op::Diag { equal: true, .. }) {
                match ops[k] {
                    Op::Diag { a, b, .. } => {
                        n_side.push(&n[a]);
                        e_side.push(&e[b]);
                    }
                    Op::Del { a } => n_side.push(&n[a]),
                    Op::Ins { b } => e_side.push(&e[b]),
                }
                k += 1;
            }
            if !e_side.into_iter().eq(self.before_words.iter())
                || !n_side.into_iter().eq(self.x.iter())
            {
                return false;
            }
        }
        true
    }
}

/// §1.6 for one strength: whether re-decoding `redecoded` accepts
/// `candidate`, given the base transcript `base` and the `typed` text the
/// candidate came from. Casing candidates need no audio and are not
/// decided here.
pub fn verify_decision(base: &str, typed: &str, candidate: &Candidate, redecoded: &str) -> bool {
    Expected::new(base, typed, candidate).is_some_and(|e| e.accepts(redecoded))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn alignment_prefers_diagonal_then_deletion() {
        // "cooper netties" -> "kubernetes": netties is substituted (the
        // diagonal is taken from the end), cooper deleted.
        let ops = align(&s(&["on", "cooper", "netties", "x"]), &s(&["on", "k", "x"]));
        assert_eq!(
            ops,
            [
                Op::Diag {
                    a: 0,
                    b: 0,
                    equal: true
                },
                Op::Del { a: 1 },
                Op::Diag {
                    a: 2,
                    b: 1,
                    equal: false
                },
                Op::Diag {
                    a: 3,
                    b: 2,
                    equal: true
                },
            ]
        );
        assert_eq!(align(&[], &s(&["a"])), [Op::Ins { b: 0 }]);
        assert_eq!(align(&s(&["a"]), &[]), [Op::Del { a: 0 }]);
        assert!(align(&[], &[]).is_empty());
    }

    #[test]
    fn debug_shows_no_text() {
        let c = Candidate {
            surface: "Synthetic".into(),
            kind: CandidateKind::Replace,
            before_range: 1..2,
            before_words: s(&["synthetik"]),
        };
        let d = format!("{c:?}");
        assert!(!d.contains("ynthet"), "{d}");
    }
}
