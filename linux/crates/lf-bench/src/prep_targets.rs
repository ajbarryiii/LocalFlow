//! Corrected training targets for the learned bias module (experiment 2,
//! DESIGN "Training targets").
//!
//! The unbiased greedy hypothesis H (emitted token ids) is aligned word by
//! word with the reference (both normalized as `lf-bias-eval` does, with
//! `score.py`'s alignment). Dictionary entries (one or more words) are found
//! as whole occurrences in both word sequences ([`occurrences`]: longest
//! first, non-overlapping), and only errors on those occurrences are
//! repaired, each occurrence as one span:
//!
//! - **write-in**: a reference occurrence that is not matched word for word
//!   is written in, spelled as in the reference. Inserted hypothesis words
//!   directly next to it (no match in between) are taken to be pieces of the
//!   misrecognized phrase and removed with it.
//! - **false alarm**: a hypothesis occurrence that is not matched, where
//!   reference words were, is replaced by those reference words plus any
//!   deleted reference words directly next to it.
//! - **remove**: a hypothesis occurrence aligned only to insertions is removed.
//!
//! A component word of a multi-word entry is not a dictionary word on its
//! own unless it is itself an entry.
//!
//! Everything else keeps the emitted ids, punctuation ids included. A repaired
//! span is re-tokenized with `Tokenizer::encode` of its surface text (whose
//! dummy prefix makes it word-initial, i.e. the text " " + surface).
//! Punctuation ownership follows the rendered text (after NeMo's
//! space-before-punctuation strip): a `▁,` token renders glued to the
//! preceding word, so a deleted word is inserted after it.
//!
//! A unit that cannot be repaired cleanly is **reverted**: H's tokens are
//! kept and the caller drops the unit's decisions from supervision. Reasons:
//! a write-in whose tokens are not exactly a phrase variant of the dictionary
//! graph (the audit), a span whose first or last token is shared with
//! neighbouring characters, punctuation between the span's words, a
//! replacement that would glue onto the previous token, and text the
//! vocabulary cannot encode.

#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::ops::Range;

use lf_asr::tokenizer::Tokenizer;

use crate::bias_lists::cased_words;
use crate::bias_metrics::{self, Code};
use crate::wer::normalize;

/// One normalized word of a hypothesis and the emitted tokens it spans.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WordSpan {
    pub word: String,
    pub tokens: Range<usize>,
    /// Nothing but whitespace precedes the word inside its first token.
    pub start_aligned: bool,
    /// Nothing but whitespace follows the word inside its last token.
    pub end_aligned: bool,
    /// The word's first character is uppercase in the text.
    pub capitalized: bool,
    /// The text between this word and the next (or the end) has `.`, `?` or `!`.
    pub ends_sentence: bool,
}

/// The emitted tokens as NeMo text, with the normalized words mapped back to tokens.
#[derive(Clone, Debug)]
pub struct HypText {
    pub text: String,
    pub words: Vec<WordSpan>,
    /// Per token: its rendered text (after NeMo's space-before-punctuation
    /// strip) starts a new word: a leading space, or the first non-empty
    /// rendered token of the utterance.
    pub token_initial: Vec<bool>,
    /// Per token: some character of it belongs to a normalized word.
    pub token_in_word: Vec<bool>,
    /// Per token: it renders at least one character that is neither part of
    /// a normalized word nor whitespace (punctuation), whether or not the
    /// token also holds word characters.
    pub token_punct: Vec<bool>,
}

/// Maps `ids` to text (`Tokenizer::decode`) and each normalized word
/// (`wer::normalize` of that text) to its token span. Fails if the mapping
/// does not reproduce `normalize` exactly.
pub fn hyp_text(tok: &Tokenizer, ids: &[usize]) -> Result<HypText, String> {
    let n = ids.len();
    // SentencePiece text, token by token (each token appends its surface).
    let mut sp = String::new();
    let mut sp_chars: Vec<(char, usize)> = Vec::new();
    for i in 0..n {
        let full = tok
            .sentencepiece_decode(&ids[..=i])
            .map_err(|e| e.to_string())?;
        let surface = full
            .strip_prefix(sp.as_str())
            .ok_or("sentencepiece_decode is not incremental")?
            .to_owned();
        sp_chars.extend(surface.chars().map(|c| (c, i)));
        sp = full;
    }
    let text = tok.strip_space_before_punctuation(&sp);
    if text != tok.decode(ids).map_err(|e| e.to_string())? {
        return Err("decode differs from the stripped SentencePiece text".into());
    }
    // `text` is `sp` with some whitespace removed: map its characters back.
    let mut text_chars: Vec<(char, usize)> = Vec::with_capacity(sp_chars.len());
    let mut it = sp_chars.iter();
    for c in text.chars() {
        loop {
            let &(s, t) = it.next().ok_or("stripped text does not map to tokens")?;
            if s == c {
                text_chars.push((c, t));
                break;
            }
            if !s.is_whitespace() {
                return Err("strip removed a non-space character".into());
            }
        }
    }
    // Word starts by rendered text (review B6): a "▁," token renders as ","
    // glued to the previous word, so it does not start a word.
    let mut rendered = vec![String::new(); n];
    for &(c, t) in &text_chars {
        rendered[t].push(c);
    }
    let mut token_initial = vec![false; n];
    let mut space_only = vec![false; n];
    let mut seen = false;
    for (i, r) in rendered.iter().enumerate() {
        if !r.is_empty() {
            token_initial[i] = !seen || r.starts_with(char::is_whitespace);
            space_only[i] = r.chars().all(char::is_whitespace);
            seen = true;
        }
    }
    // `normalize` with provenance: lowercase, keep alphanumerics and
    // apostrophes, split on the rest, trim apostrophes.
    let mut lc: Vec<(char, usize)> = Vec::new(); // (cleaned char, index into text_chars)
    for (k, &(c, _)) in text_chars.iter().enumerate() {
        for l in c.to_lowercase() {
            let kept = l.is_alphanumeric() || l == '\'';
            lc.push((if kept { l } else { ' ' }, k));
        }
    }
    let mut words = Vec::new();
    let mut token_in_word = vec![false; n];
    // Per rendered character: it belongs to a normalized word.
    let mut owned = vec![false; text_chars.len()];
    let mut i = 0;
    while i < lc.len() {
        if lc[i].0 == ' ' {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < lc.len() && lc[j].0 != ' ' {
            j += 1;
        }
        let (mut a, mut b) = (i, j);
        while a < b && lc[a].0 == '\'' {
            a += 1;
        }
        while b > a && lc[b - 1].0 == '\'' {
            b -= 1;
        }
        if a < b {
            let word: String = lc[a..b].iter().map(|&(c, _)| c).collect();
            let (first, last) = (lc[a].1, lc[b - 1].1);
            let (mut t0, t1) = (text_chars[first].1, text_chars[last].1);
            // A word spelled "▁" + pieces without "▁" (no word-initial piece
            // exists for its first character) owns the bare space token.
            if !token_initial[t0] && t0 > 0 && space_only[t0 - 1] {
                t0 -= 1;
            }
            let start_aligned = text_chars[..first]
                .iter()
                .rev()
                .take_while(|&&(_, t)| t == t0)
                .all(|&(c, _)| c.is_whitespace());
            let end_aligned = text_chars[last + 1..]
                .iter()
                .take_while(|&&(_, t)| t == t1)
                .all(|&(c, _)| c.is_whitespace());
            for &(_, k) in &lc[a..b] {
                token_in_word[text_chars[k].1] = true;
                owned[k] = true;
            }
            words.push((
                WordSpan {
                    word,
                    tokens: t0..t1 + 1,
                    start_aligned,
                    end_aligned,
                    capitalized: text_chars[first].0.is_uppercase(),
                    ends_sentence: false,
                },
                first,
                last,
            ));
        }
        i = j;
    }
    let ends: Vec<bool> = (0..words.len())
        .map(|w| {
            let to = words.get(w + 1).map_or(text_chars.len(), |n| n.1);
            text_chars[words[w].2 + 1..to]
                .iter()
                .any(|&(c, _)| matches!(c, '.' | '?' | '!'))
        })
        .collect();
    let words: Vec<WordSpan> = words
        .into_iter()
        .zip(ends)
        .map(|((mut w, _, _), e)| {
            w.ends_sentence = e;
            w
        })
        .collect();
    let plain: Vec<&str> = words.iter().map(|w| w.word.as_str()).collect();
    if plain != normalize(&text) {
        return Err("word spans do not reproduce the normalized text".into());
    }
    // Punctuation by rendered-character ownership (re-review #7): a token
    // counts if any of its rendered characters is neither a word's nor a
    // space, so a mixed piece such as "▁neural," counts too.
    let mut token_punct = vec![false; n];
    for (k, &(c, t)) in text_chars.iter().enumerate() {
        if !owned[k] && !c.is_whitespace() {
            token_punct[t] = true;
        }
    }
    Ok(HypText {
        text,
        words,
        token_initial,
        token_in_word,
        token_punct,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnitKind {
    WriteIn,
    FalseAlarm,
    Remove,
}

impl UnitKind {
    pub fn name(self) -> &'static str {
        match self {
            UnitKind::WriteIn => "write_in",
            UnitKind::FalseAlarm => "false_alarm",
            UnitKind::Remove => "remove",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Revert {
    /// A write-in whose tokens are not exactly a phrase variant of the graph.
    NotPhrase,
    /// The span's first or last token also holds other characters.
    Boundary,
    /// The replacement would start inside a word-continuing token.
    Glued,
    /// The text has characters the vocabulary lacks.
    Unencodable,
    /// The replaced span has punctuation between its words, which a
    /// replacement would erase.
    InternalPunctuation,
}

impl Revert {
    pub fn name(self) -> &'static str {
        match self {
            Revert::NotPhrase => "not_phrase_variant",
            Revert::Boundary => "shared_boundary_token",
            Revert::Glued => "glued",
            Revert::Unencodable => "unencodable",
            Revert::InternalPunctuation => "internal_punctuation",
        }
    }
}

/// One repair (or reverted repair).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unit {
    pub kind: UnitKind,
    pub revert: Option<Revert>,
    /// Reference words written in (indices into the reference's words).
    pub ref_words: Vec<usize>,
    /// Hypothesis words taken out (indices into `HypText::words`).
    pub hyp_words: Range<usize>,
    /// Hypothesis tokens replaced (empty for an insertion).
    pub hyp_tokens: Range<usize>,
    /// The unit's target tokens: the replacement, or H's tokens when reverted.
    pub target: Range<usize>,
}

/// The corrected target sequence T.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub tokens: Vec<usize>,
    /// Per target token: it belongs to an applied write-in or false-alarm replacement.
    pub corrected: Vec<bool>,
    pub units: Vec<Unit>,
    /// Reference words (normalized), for reporting.
    pub ref_words: Vec<String>,
}

impl Target {
    /// Decisions to drop from supervision: inclusive ranges of the target
    /// position u, one per reverted unit (its tokens and the blanks before
    /// them; for an insertion, the position it would have gone).
    pub fn excluded(&self) -> Vec<(usize, usize)> {
        self.units
            .iter()
            .filter(|u| u.revert.is_some())
            .map(|u| (u.target.start, u.target.end.max(u.target.start + 1) - 1))
            .collect()
    }

    /// Applied units that took a dictionary word out of H: `(u, H tokens)`,
    /// where `u` is the target position at which H had emitted it.
    pub fn removals(&self) -> Vec<(usize, Range<usize>)> {
        self.units
            .iter()
            .filter(|u| u.revert.is_none() && u.kind != UnitKind::WriteIn)
            .map(|u| (u.target.start, u.hyp_tokens.clone()))
            .collect()
    }
}

/// The dictionary as the repair sees it.
pub struct DictView<'a> {
    /// Every entry as its normalized word sequence (one or more words).
    pub entries: &'a BTreeSet<Vec<String>>,
    /// Every phrase variant the graph was built from.
    pub phrases: &'a HashSet<Vec<usize>>,
}

pub use crate::exp2_terms::Casing;

/// Non-overlapping occurrences of `entries` in `words`, left to right,
/// longest entry first at each position.
pub fn occurrences(words: &[String], entries: &BTreeSet<Vec<String>>) -> Vec<Range<usize>> {
    let max_len = entries.iter().map(Vec::len).max().unwrap_or(0);
    let mut out = Vec::new();
    let mut i = 0;
    while i < words.len() {
        let found = (1..=max_len.min(words.len() - i))
            .rev()
            .find(|&l| entries.contains(&words[i..i + l]));
        match found {
            Some(l) => {
                out.push(i..i + l);
                i += l;
            }
            None => i += 1,
        }
    }
    out
}

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    c.next()
        .map(|f| f.to_uppercase().chain(c).collect())
        .unwrap_or_default()
}

/// Why an utterance gets no target at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Skip {
    /// The reference's cased words do not reproduce its normalization.
    Reference,
}

/// Repairs H (`hyp_ids`, mapped by `hyp`) against `reference`.
pub fn repair(
    tok: &Tokenizer,
    hyp_ids: &[usize],
    hyp: &HypText,
    reference: &str,
    dict: &DictView,
    casing: Casing,
) -> Result<Target, Skip> {
    let cased = cased_words(reference);
    let ref_words: Vec<String> = cased.iter().map(|(n, _)| n.clone()).collect();
    if ref_words != normalize(reference) {
        return Err(Skip::Reference);
    }
    let hyp_words: Vec<String> = hyp.words.iter().map(|w| w.word.clone()).collect();
    let ops = bias_metrics::align(&ref_words, &hyp_words);
    let mut ref_op = vec![0usize; ref_words.len()];
    let mut hyp_op = vec![0usize; hyp_words.len()];
    for (i, &(_, r, h)) in ops.iter().enumerate() {
        if let Some(r) = r {
            ref_op[r] = i;
        }
        if let Some(h) = h {
            hyp_op[h] = i;
        }
    }

    // Units are dictionary-phrase occurrences (review B4), each covering a
    // range of alignment ops, then absorbing directly adjacent free ops.
    // Write-ins first: a reference occurrence that is not matched op for op.
    let mut owner: Vec<bool> = vec![false; ops.len()];
    let mut specs: Vec<(UnitKind, Range<usize>)> = Vec::new();
    let absorb = |owner: &mut Vec<bool>, mut a: usize, mut b: usize, code: Code| {
        for o in &mut owner[a..b] {
            *o = true;
        }
        while a > 0 && !owner[a - 1] && ops[a - 1].0 == code {
            a -= 1;
            owner[a] = true;
        }
        while b < ops.len() && !owner[b] && ops[b].0 == code {
            owner[b] = true;
            b += 1;
        }
        a..b
    };
    for occ in occurrences(&ref_words, dict.entries) {
        let (a, b) = (ref_op[occ.start], ref_op[occ.end - 1] + 1);
        if ops[a..b].iter().all(|s| s.0 == Code::Match) || owner[a..b].iter().any(|&o| o) {
            continue;
        }
        specs.push((UnitKind::WriteIn, absorb(&mut owner, a, b, Code::Ins)));
    }
    // Then hypothesis occurrences that are not matched and not already
    // covered: false alarms (reference words come back) or removals.
    for occ in occurrences(&hyp_words, dict.entries) {
        let (a, b) = (hyp_op[occ.start], hyp_op[occ.end - 1] + 1);
        if ops[a..b].iter().all(|s| s.0 == Code::Match) || owner[a..b].iter().any(|&o| o) {
            continue;
        }
        let range = absorb(&mut owner, a, b, Code::Del);
        let kind = if ops[range.clone()].iter().any(|s| s.1.is_some()) {
            UnitKind::FalseAlarm
        } else {
            UnitKind::Remove
        };
        specs.push((kind, range));
    }
    specs.sort_by_key(|(_, r)| r.start);

    let n = hyp_ids.len();
    let surface = |r: usize| cased[r].1.as_str();
    let mut units = Vec::with_capacity(specs.len());
    let mut planned: Vec<Option<Vec<usize>>> = Vec::with_capacity(specs.len());
    for &(kind, ref range) in &specs {
        let ops_u = &ops[range.clone()];
        let ref_idx: Vec<usize> = ops_u.iter().filter_map(|s| s.1).collect();
        let hyp_idx: Vec<usize> = ops_u.iter().filter_map(|s| s.2).collect();
        let hyp_words = match (hyp_idx.first(), hyp_idx.last()) {
            (Some(&a), Some(&b)) => a..b + 1,
            _ => {
                // The hypothesis word before this unit (in alignment order).
                let prev = ops[..range.start].iter().rev().find_map(|s| s.2);
                let k = prev.map_or(0, |p| p + 1);
                k..k
            }
        };
        let mut revert = None;
        let hyp_tokens = if hyp_words.is_empty() {
            // Insert after the previous word and its attached punctuation.
            let mut k = match hyp_words.start {
                0 => 0,
                w => hyp.words[w - 1].tokens.end,
            };
            while k < n && !hyp.token_initial[k] && !hyp.token_in_word[k] {
                k += 1;
            }
            if k < n && !hyp.token_initial[k] {
                revert = Some(Revert::Glued);
            }
            k..k
        } else {
            let (first, last) = (&hyp.words[hyp_words.start], &hyp.words[hyp_words.end - 1]);
            let t = first.tokens.start..last.tokens.end;
            if !first.start_aligned || !last.end_aligned {
                revert = Some(Revert::Boundary);
            } else if t.clone().any(|i| hyp.token_punct[i]) {
                revert = Some(Revert::InternalPunctuation);
            } else if kind != UnitKind::Remove && !hyp.token_initial[t.start] {
                revert = Some(Revert::Glued);
            }
            t
        };
        let mut replacement = None;
        if revert.is_none() {
            let text: Vec<String> = match casing {
                Casing::Cased => ref_idx.iter().map(|&r| surface(r).to_owned()).collect(),
                Casing::Uncased => {
                    let w = hyp_words.start;
                    let starts = w == 0 || hyp.words[w - 1].ends_sentence;
                    let cap = starts || (!hyp_words.is_empty() && hyp.words[w].capitalized);
                    ref_idx
                        .iter()
                        .enumerate()
                        .map(|(k, &r)| {
                            let lower = surface(r).to_lowercase();
                            if k == 0 && cap {
                                upper_first(&lower)
                            } else {
                                lower
                            }
                        })
                        .collect()
                }
            };
            let tokens = if text.is_empty() {
                Ok(Vec::new())
            } else {
                tok.encode(&text.join(" "))
            };
            match tokens {
                Ok(t) if tok.unk().is_some_and(|u| t.contains(&u)) => {
                    revert = Some(Revert::Unencodable)
                }
                Err(_) => revert = Some(Revert::Unencodable),
                Ok(t) if kind == UnitKind::WriteIn && !dict.phrases.contains(&t) => {
                    revert = Some(Revert::NotPhrase)
                }
                Ok(t) => replacement = Some(t),
            }
        }
        units.push(Unit {
            kind,
            revert,
            ref_words: ref_idx,
            hyp_words,
            hyp_tokens,
            target: 0..0,
        });
        planned.push(replacement);
    }

    // Splice. Units come in alignment order, so their spans do not decrease.
    let mut tokens = Vec::with_capacity(n + 8);
    let mut corrected = Vec::with_capacity(n + 8);
    let mut pos = 0usize;
    for (u, rep) in units.iter_mut().zip(planned) {
        let start = u.hyp_tokens.start.max(pos);
        tokens.extend_from_slice(&hyp_ids[pos..start]);
        corrected.resize(tokens.len(), false);
        let t0 = tokens.len();
        match rep {
            Some(new) if u.hyp_tokens.start >= pos => {
                tokens.extend_from_slice(&new);
                corrected.resize(tokens.len(), u.kind != UnitKind::Remove);
            }
            _ => {
                u.revert.get_or_insert(Revert::Boundary);
                let end = u.hyp_tokens.end.max(start);
                tokens.extend_from_slice(&hyp_ids[start..end]);
                corrected.resize(tokens.len(), false);
            }
        }
        u.target = t0..tokens.len();
        pos = u.hyp_tokens.end.max(pos);
    }
    tokens.extend_from_slice(&hyp_ids[pos..]);
    corrected.resize(tokens.len(), false);
    Ok(Target {
        tokens,
        corrected,
        units,
        ref_words,
    })
}

/// Named counters, summed over utterances and written as JSON.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counters(pub BTreeMap<String, u64>);

impl Counters {
    pub fn add(&mut self, key: &str, n: u64) {
        *self.0.entry(key.to_owned()).or_default() += n;
    }

    pub fn get(&self, key: &str) -> u64 {
        self.0.get(key).copied().unwrap_or(0)
    }

    pub fn merge(&mut self, o: &Counters) {
        for (k, v) in &o.0 {
            self.add(k, *v);
        }
    }

    /// Per unit kind: total, applied, reverted by reason.
    pub fn add_units(&mut self, units: &[Unit]) {
        for u in units {
            let k = u.kind.name();
            self.add(&format!("{k}.total"), 1);
            match u.revert {
                None => self.add(&format!("{k}.applied"), 1),
                Some(r) => self.add(&format!("{k}.reverted.{}", r.name()), 1),
            }
        }
    }

    pub fn json(&self) -> serde_json::Value {
        serde_json::to_value(&self.0).unwrap()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A BPE vocabulary of exactly the model's size: `<unk>`, every prefix
    /// chain of `words` (so each word encodes to its listed pieces), single
    /// characters, then filler.
    pub(crate) fn tokenizer(words: &[&str]) -> Tokenizer {
        let mut pieces: Vec<String> = vec!["<unk>".into()];
        let push = |p: String, pieces: &mut Vec<String>| {
            if !pieces.contains(&p) {
                pieces.push(p);
            }
        };
        for w in words {
            let chars: Vec<char> = w.chars().collect();
            for k in 2..=chars.len() {
                push(chars[..k].iter().collect(), &mut pieces);
            }
        }
        let singles =
            "\u{2581}abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,.'?-()";
        for c in singles.chars() {
            push(c.to_string(), &mut pieces);
        }
        let mut i = 0;
        while pieces.len() < lf_asr::config::VOCAB {
            push(format!("<f{i}>"), &mut pieces);
            i += 1;
        }
        let text: String = pieces
            .iter()
            .enumerate()
            .map(|(i, p)| format!("{p}\t-{i}\n"))
            .collect();
        Tokenizer::from_vocab_file(text.as_bytes(), None).unwrap()
    }

    pub(crate) fn tok() -> Tokenizer {
        tokenizer(&[
            "\u{2581}the",
            "\u{2581}Zor",
            "bin",
            "\u{2581}sore",
            "\u{2581}sales",
            "\u{2581}rose",
            "\u{2581}we",
            "\u{2581}met",
            "\u{2581}Quaxel",
            "\u{2581}quaxel",
            "\u{2581}team",
            "\u{2581}new",
            "\u{2581}york",
            "\u{2581}Newark",
            "\u{2581}Sore",
            "\u{2581}neural",
            "\u{2581}network",
            "\u{2581}nets",
            "\u{2581},",
        ])
    }

    fn ids(t: &Tokenizer, text: &str) -> Vec<usize> {
        t.encode(text).unwrap()
    }

    struct Case {
        entries: BTreeSet<Vec<String>>,
        phrases: HashSet<Vec<usize>>,
    }

    /// The dictionary as `lf-bias-prep` builds it: each entry's surface
    /// normalized for the casing, then its case variants.
    fn dict_cased(t: &Tokenizer, entries: &[&str], casing: Casing) -> Case {
        let entries: Vec<String> = entries
            .iter()
            .map(|s| crate::exp2_terms::normalize_entry_surface(s, casing))
            .collect();
        let phrases = lf_asr::bias::phrases(t, &entries, true).unwrap();
        Case {
            entries: entries.iter().map(|e| normalize(e)).collect(),
            phrases: phrases.into_iter().collect(),
        }
    }

    fn dict(t: &Tokenizer, entries: &[&str]) -> Case {
        dict_cased(t, entries, Casing::Cased)
    }

    fn run_cased(
        t: &Tokenizer,
        hyp: &str,
        reference: &str,
        d: &Case,
        casing: Casing,
    ) -> (Target, Vec<usize>) {
        let h = ids(t, hyp);
        let ht = hyp_text(t, &h).unwrap();
        let view = DictView {
            entries: &d.entries,
            phrases: &d.phrases,
        };
        (repair(t, &h, &ht, reference, &view, casing).unwrap(), h)
    }

    fn run(t: &Tokenizer, hyp: &str, reference: &str, d: &Case) -> (Target, Vec<usize>) {
        run_cased(t, hyp, reference, d, Casing::Cased)
    }

    #[test]
    fn occurrences_are_longest_first_and_disjoint() {
        let e: BTreeSet<Vec<String>> = [vec!["neural"], vec!["neural", "network"], vec!["net"]]
            .iter()
            .map(|v| v.iter().map(|s| s.to_string()).collect())
            .collect();
        let w: Vec<String> = "a neural network neural net neural"
            .split(' ')
            .map(String::from)
            .collect();
        assert_eq!(occurrences(&w, &e), vec![1..3, 3..4, 4..5, 5..6]);
    }

    #[test]
    fn multiword_entries_are_repaired_as_whole_spans() {
        // Regression (review B4).
        let t = tok();
        let d = dict(&t, &["neural network"]);
        let (tg, _) = run(
            &t,
            "we met neural nets team",
            "we met neural network team",
            &d,
        );
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met neural network team");
        assert_eq!(tg.units.len(), 1);
        let u = &tg.units[0];
        assert_eq!((u.kind, u.revert), (UnitKind::WriteIn, None));
        assert_eq!(
            (u.hyp_words.clone(), u.ref_words.clone()),
            (2..4, vec![2, 3])
        );
        assert_eq!(tg.tokens[u.target.clone()], ids(&t, "neural network")[..]);
        // A whole hypothesis occurrence where other words were is undone.
        let (tg, _) = run(&t, "we met neural network team", "we met sales team", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met sales team");
        assert_eq!(tg.units[0].kind, UnitKind::FalseAlarm);
        // A correct occurrence is left alone.
        let (tg, h) = run(
            &t,
            "we met neural network team",
            "We met neural network team.",
            &d,
        );
        assert!(tg.units.is_empty() && tg.tokens == h);
    }

    #[test]
    fn component_words_are_not_dictionary_words_on_their_own() {
        // Regression (review B4): "network" is only part of an entry.
        let t = tok();
        let d = dict(&t, &["neural network"]);
        let (tg, h) = run(&t, "we met network team", "we met the team", &d);
        assert!(tg.units.is_empty() && tg.tokens == h);
        let (tg, h) = run(&t, "we met the team", "we met network team", &d);
        assert!(tg.units.is_empty() && tg.tokens == h);
        // Unless it is an entry itself.
        let d = dict(&t, &["neural network", "network"]);
        let (tg, _) = run(&t, "we met network team", "we met the team", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met the team");
        assert_eq!(tg.units[0].kind, UnitKind::FalseAlarm);
    }

    #[test]
    fn spaced_punctuation_belongs_to_the_preceding_word() {
        // Regression (review B6): "▁," renders as "," glued to "met", so the
        // deleted word goes after it, and its id is kept.
        let t = tok();
        let h = ids(&t, "we met , the team");
        let comma = ids(&t, " ,")[1];
        assert!(h.contains(&comma));
        let ht = hyp_text(&t, &h).unwrap();
        assert_eq!(ht.text, "we met, the team");
        assert!(!ht.token_initial[2] && ht.token_punct[2]);
        let d = dict(&t, &["Quaxel"]);
        let (tg, _) = run(&t, "we met , the team", "We met, Quaxel the team.", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met, Quaxel the team");
        assert_eq!(tg.tokens[..3], h[..3]);
        assert_eq!(tg.units[0].hyp_tokens, 3..3);
    }

    #[test]
    fn punctuation_inside_a_replaced_span_reverts_it() {
        // Regression (review B6): "sore, bin" for "Zorbin" would erase the
        // comma; the unit is reverted explicitly and counted.
        let t = tok();
        let d = dict(&t, &["Zorbin"]);
        let (tg, h) = run(&t, "the sore, bin sales", "the Zorbin sales", &d);
        assert_eq!(tg.tokens, h);
        assert_eq!(tg.units[0].revert, Some(Revert::InternalPunctuation));
        assert_eq!(tg.excluded().len(), 1);
        let mut c = Counters::default();
        c.add_units(&tg.units);
        assert_eq!(c.get("write_in.reverted.internal_punctuation"), 1);
    }

    #[test]
    fn punctuation_inside_a_mixed_token_reverts_the_span() {
        // Regression (re-review #7): with a piece "▁neural," the comma shares
        // a token with a word. Repairing "neural, nets" as "neural network"
        // would erase it, so the span is reverted and counted.
        let t = tokenizer(&[
            "\u{2581}we",
            "\u{2581}met",
            "\u{2581}neural,",
            "\u{2581}network",
            "\u{2581}nets",
            "\u{2581}team",
        ]);
        let h = ids(&t, "we met neural, nets team");
        let ht = hyp_text(&t, &h).unwrap();
        assert_eq!(ht.words[2].word, "neural");
        assert_eq!(ht.words[2].tokens, 2..3);
        assert!(ht.token_in_word[2] && ht.token_punct[2]);
        let d = dict(&t, &["neural network"]);
        let (tg, h) = run(
            &t,
            "we met neural, nets team",
            "we met neural network team",
            &d,
        );
        assert_eq!(tg.tokens, h);
        assert_eq!(tg.units[0].revert, Some(Revert::InternalPunctuation));
        let mut c = Counters::default();
        c.add_units(&tg.units);
        assert_eq!(c.get("write_in.reverted.internal_punctuation"), 1);
        // Without punctuation the same pieces repair normally.
        let (tg, _) = run(
            &t,
            "we met neural nets team",
            "we met neural network team",
            &d,
        );
        assert_eq!(tg.units[0].revert, None);
    }

    #[test]
    fn uncased_entries_yield_the_write_in_casing() {
        // Regression (review B5): an uncased set's entry "QUAXEL" must
        // produce "Quaxel" at a sentence start.
        let t = tok();
        let d = dict_cased(&t, &["QUAXEL"], Casing::Uncased);
        let (tg, _) = run_cased(
            &t,
            "we met. the team",
            "we met quaxel the team",
            &d,
            Casing::Uncased,
        );
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met. Quaxel the team");
        assert_eq!(tg.units[0].revert, None);
        // Without the shared normalization the write-in was reverted.
        let raw = dict(&t, &["QUAXEL"]);
        let (tg, _) = run_cased(
            &t,
            "we met. the team",
            "we met quaxel the team",
            &raw,
            Casing::Uncased,
        );
        assert_eq!(tg.units[0].revert, Some(Revert::NotPhrase));
    }

    #[test]
    fn uncased_references_follow_the_hypothesis_casing() {
        let t = tok();
        let d = dict(&t, &["Zorbin", "Quaxel"]);
        // Lowercase reference: the write-in is capitalized after a sentence
        // end or where the replaced word was capitalized, else lowercase.
        let (tg, _) = run_cased(
            &t,
            "we met. Sore bin sales",
            "we met zorbin sales",
            &d,
            Casing::Uncased,
        );
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met. Zorbin sales");
        let (tg, _) = run_cased(
            &t,
            "we met the sales",
            "WE MET QUAXEL THE SALES",
            &d,
            Casing::Uncased,
        );
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met quaxel the sales");
        assert_eq!(tg.units[0].revert, None);
        let (tg, _) = run_cased(
            &t,
            "met the sales",
            "quaxel met the sales",
            &d,
            Casing::Uncased,
        );
        assert_eq!(t.decode(&tg.tokens).unwrap(), "Quaxel met the sales");
        // A cased reference keeps its own spelling.
        let (tg, _) = run(&t, "we met. Sore bin sales", "we met. zorbin sales", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met. zorbin sales");
    }

    #[test]
    fn word_spans_follow_the_normalizer() {
        let t = tok();
        let h = ids(&t, "the Zorbin, sales rose.");
        let ht = hyp_text(&t, &h).unwrap();
        assert_eq!(ht.text, "the Zorbin, sales rose.");
        let words: Vec<(&str, Range<usize>)> = ht
            .words
            .iter()
            .map(|w| (w.word.as_str(), w.tokens.clone()))
            .collect();
        // ▁the | ▁Zor bin | , | ▁sales | ▁rose | .
        assert_eq!(
            words,
            vec![
                ("the", 0..1),
                ("zorbin", 1..3),
                ("sales", 4..5),
                ("rose", 5..6)
            ]
        );
        assert!(ht.words.iter().all(|w| w.start_aligned && w.end_aligned));
        assert_eq!(
            ht.token_initial,
            vec![true, true, false, false, true, true, false]
        );
        assert_eq!(
            ht.token_in_word,
            vec![true, true, true, false, true, true, false]
        );
        // Apostrophes inside a word belong to it.
        let h = ids(&t, "we met Quaxel's team");
        let ht = hyp_text(&t, &h).unwrap();
        assert_eq!(ht.words[2].word, "quaxel's");
        assert_eq!(ht.words.len(), 4);
    }

    #[test]
    fn substitution_of_a_dictionary_word_is_written_in() {
        let t = tok();
        let d = dict(&t, &["Zorbin"]);
        // "Zorbin" heard as "sore bin": the inserted "bin" goes with it, and
        // the comma stays attached after the replacement.
        let (tg, h) = run(&t, "the sore bin, sales rose", "The Zorbin sales rose.", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "the Zorbin, sales rose");
        assert_eq!(tg.units.len(), 1);
        let u = &tg.units[0];
        assert_eq!((u.kind, u.revert), (UnitKind::WriteIn, None));
        assert_eq!(u.hyp_words, 1..3);
        // Unchanged spans keep their ids; only the replacement is new.
        assert_eq!(&tg.tokens[..1], &h[..1]);
        assert_eq!(&tg.tokens[u.target.end..], &h[u.hyp_tokens.end..]);
        assert_eq!(tg.tokens[u.target.clone()], ids(&t, "Zorbin")[..]);
        let corr: Vec<usize> = (0..tg.tokens.len()).filter(|&i| tg.corrected[i]).collect();
        assert_eq!(corr, u.target.clone().collect::<Vec<_>>());
        assert!(tg.excluded().is_empty() && tg.removals().is_empty());
    }

    #[test]
    fn deletion_is_inserted_after_attached_punctuation() {
        let t = tok();
        let d = dict(&t, &["Quaxel"]);
        let (tg, h) = run(&t, "we met, the team", "We met, Quaxel the team.", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met, Quaxel the team");
        let u = &tg.units[0];
        assert_eq!((u.kind, u.revert), (UnitKind::WriteIn, None));
        // After "▁met" and ",": position 3 of H.
        assert_eq!(u.hyp_tokens, 3..3);
        assert_eq!(&tg.tokens[..3], &h[..3]);
        assert_eq!(&tg.tokens[u.target.end..], &h[3..]);
        // At the very start and end too.
        let (tg, _) = run(&t, "met the team.", "Quaxel met the team Quaxel", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "Quaxel met the team. Quaxel");
    }

    #[test]
    fn inserted_dictionary_word_is_removed() {
        let t = tok();
        let d = dict(&t, &["Zorbin"]);
        let (tg, h) = run(&t, "the Zorbin sales rose", "The sales rose.", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "the sales rose");
        let u = &tg.units[0];
        assert_eq!((u.kind, u.revert), (UnitKind::Remove, None));
        assert_eq!(u.hyp_tokens, 1..3);
        assert!(tg.corrected.iter().all(|&c| !c));
        // The blank that replaces it sits at target position 1.
        assert_eq!(tg.removals(), vec![(1, 1..3)]);
        assert_eq!(&tg.tokens[1..], &h[3..]);
    }

    #[test]
    fn dictionary_word_replacing_another_word_is_undone() {
        let t = tok();
        let d = dict(&t, &["Newark"]);
        // "Newark" replaced "new york": both reference words come back.
        let (tg, _) = run(&t, "we met Newark sales", "We met New York sales.", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met New York sales");
        let u = &tg.units[0];
        assert_eq!((u.kind, u.revert), (UnitKind::FalseAlarm, None));
        assert_eq!(u.ref_words, vec![2, 3]);
        assert_eq!(tg.removals(), vec![(u.target.start, u.hyp_tokens.clone())]);
        assert!(u.target.clone().all(|i| tg.corrected[i]));
    }

    #[test]
    fn unrelated_errors_and_formatting_are_kept() {
        let t = tok();
        let d = dict(&t, &["Quaxel"]);
        // "sales" -> "sore" is not dictionary-related; case and punctuation
        // differences are not errors.
        let (tg, h) = run(&t, "We met the sore, team", "we met the sales team.", &d);
        assert_eq!(tg.tokens, h);
        assert!(tg.units.is_empty());
    }

    #[test]
    fn audit_reverts_spans_that_are_not_phrase_variants() {
        let t = tok();
        // The dictionary spells it "quaxel"; the reference's "QUaxel" is no
        // case variant of it: H is kept and the decisions are excluded.
        let d = dict(&t, &["quaxel"]);
        let (tg, h) = run(&t, "we met the team", "we met QUaxel the team", &d);
        assert_eq!(tg.tokens, h);
        let u = &tg.units[0];
        assert_eq!(u.revert, Some(Revert::NotPhrase));
        assert_eq!(tg.excluded(), vec![(2, 2)]);
        // The reference spelling is used, not the dictionary's: "Quaxel" is
        // a case variant of "quaxel", so it is written in as "Quaxel".
        let (tg, _) = run(&t, "we met the team", "we met Quaxel the team", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met Quaxel the team");
        assert_eq!(tg.units[0].revert, None);
        let mut c = Counters::default();
        c.add_units(&tg.units);
        assert_eq!(c.get("write_in.applied"), 1);
    }

    #[test]
    fn a_word_after_a_bare_space_token_owns_it() {
        let t = tok();
        // "Xyl" has no word-initial piece: "▁" "X" "y" "l". The word spans
        // the bare "▁" too, so replacing or removing it leaves no stray space.
        let h = ids(&t, "the Xyl sales");
        let ht = hyp_text(&t, &h).unwrap();
        assert_eq!(ht.words[1].word, "xyl");
        assert_eq!(ht.words[1].tokens, 1..5);
        assert!(ht.token_initial[1] && !ht.token_initial[2]);
        let d = dict(&t, &["Zorbin"]);
        let (tg, _) = run(&t, "the Xyl sales", "the Zorbin sales", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "the Zorbin sales");
        assert_eq!(tg.units[0].revert, None);
        let (tg, _) = run(&t, "the Xyl Zorbin sales", "the Xyl sales", &d);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "the Xyl sales");
    }

    #[test]
    fn reverted_replacement_keeps_its_tokens_and_is_excluded() {
        let t = tok();
        let d = dict(&t, &["Zorbin"]);
        // "(sore" glues the word to the bracket: no clean word-initial replacement.
        let (tg, h) = run(&t, "the (sore sales", "the Zorbin sales", &d);
        assert_eq!(tg.tokens, h);
        let u = &tg.units[0];
        assert_eq!(u.revert, Some(Revert::Glued));
        assert_eq!(tg.excluded(), vec![(u.target.start, u.target.end - 1)]);
        assert_eq!(t.decode(&h[u.target.clone()]).unwrap(), "sore");
    }
}
