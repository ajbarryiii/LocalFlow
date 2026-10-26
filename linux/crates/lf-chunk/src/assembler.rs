//! Ports of `LocalParakeetCore.words` and `ParakeetTranscriptAssembler` in
//! `Sources/Parakeet/LocalParakeetCore.swift`. Text is compared the way Swift
//! compares strings (canonical equivalence), folded scalar by scalar, and
//! filtered to Apple's `alphanumerics` (general categories L, M and N).

use std::fmt;
use std::ops::Range;

use unicode_normalization::UnicodeNormalization;
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

use crate::SAMPLES_PER_ENCODER_FRAME;

/// A whitespace-separated word of a transcript.
#[derive(Clone, PartialEq, Eq)]
pub struct Word {
    pub text: String,
    /// Sample of the model input (the recording with silence compacted)
    /// where the word's first token was emitted.
    pub start: usize,
}

impl fmt::Debug for Word {
    /// Transcript text is user content, so only its length is shown.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Word")
            .field("bytes", &self.text.len())
            .field("start", &self.start)
            .finish()
    }
}

/// A token id outside the vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidToken;

impl fmt::Display for InvalidToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the model returned an invalid token")
    }
}

impl std::error::Error for InvalidToken {}

/// Whitespace-separated words of `(token, encoder frame)` emissions, each
/// starting at the sample where its first token was emitted. `offset` is the
/// chunk's first sample. A grapheme cluster that is exactly `▁` is a space,
/// as is one starting with whitespace (Swift's `Character.isWhitespace`).
pub fn words(
    emitted: &[(usize, usize)],
    pieces: &[String],
    offset: usize,
) -> Result<Vec<Word>, InvalidToken> {
    if emitted.iter().any(|&(id, _)| id >= pieces.len()) {
        return Err(InvalidToken);
    }
    let mut words = Vec::new();
    let mut text = String::new();
    let mut start = 0;
    for &(id, frame) in emitted {
        for cluster in pieces[id].graphemes(true) {
            let space =
                cluster == "\u{2581}" || cluster.chars().next().is_some_and(char::is_whitespace);
            if space {
                if !text.is_empty() {
                    words.push(Word {
                        text: std::mem::take(&mut text),
                        start,
                    });
                }
            } else {
                if text.is_empty() {
                    start = offset + frame * SAMPLES_PER_ENCODER_FRAME;
                }
                text.push_str(cluster);
            }
        }
    }
    if !text.is_empty() {
        words.push(Word { text, start });
    }
    Ok(words)
}

/// Joins chunk transcripts in recording order. A chunk's model treats its
/// edges as the start and end of speech, so it may capitalize, punctuate, or
/// cut off words there. Where two chunks overlap, the seam is placed on a word
/// both heard, near the middle of the shared audio: earlier words come from
/// the earlier chunk and later words from the later one.
#[derive(Default)]
pub struct TranscriptAssembler {
    words: Vec<Word>,
    end: Option<usize>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Alignment {
    count: usize,
    cost: usize,
}

impl Alignment {
    fn better(self, other: Alignment) -> bool {
        if self.count != other.count {
            self.count > other.count
        } else {
            self.cost < other.cost
        }
    }
}

impl TranscriptAssembler {
    /// Starts of the same word in two chunks differ by a few encoder frames.
    pub const ALIGNMENT_TOLERANCE: usize = 6400;

    pub fn text(&self) -> String {
        let mut out = String::new();
        for (i, w) in self.words.iter().enumerate() {
            if i > 0 {
                out.push(' ');
            }
            out.push_str(&w.text);
        }
        out
    }

    pub fn append(&mut self, chunk_words: Vec<Word>, covering: Range<usize>) {
        match self.end {
            Some(end) if covering.start < end => {
                let left = std::mem::take(&mut self.words);
                self.words = merge(left, chunk_words, covering.start..end);
            }
            _ => self.words.extend(chunk_words),
        }
        self.end = Some(covering.end);
    }
}

fn merge(left: Vec<Word>, right: Vec<Word>, overlap: Range<usize>) -> Vec<Word> {
    let tolerance = TranscriptAssembler::ALIGNMENT_TOLERANCE;
    // Swift compares signed positions; `overlap.start - tolerance` may be negative.
    let low = overlap.start as i64 - tolerance as i64;
    let high = overlap.end + tolerance;
    let l: Vec<usize> = (0..left.len())
        .filter(|&i| left[i].start as i64 >= low)
        .collect();
    let r: Vec<usize> = (0..right.len())
        .filter(|&j| right[j].start < high)
        .collect();
    let left_keys: Vec<String> = l.iter().map(|&i| key(&left[i].text)).collect();
    let right_keys: Vec<String> = r.iter().map(|&j| key(&right[j].text)).collect();
    let distance = |x: usize, y: usize| left[l[x]].start.abs_diff(right[r[y]].start);
    let matches = |x: usize, y: usize| {
        !left_keys[x].is_empty() && left_keys[x] == right_keys[y] && distance(x, y) <= tolerance
    };
    // Longest common subsequence, so repeated words pair in order. Among
    // equally long alignments, the one whose pairs are closest in time wins.
    let width = r.len() + 1;
    let zero = Alignment { count: 0, cost: 0 };
    let mut best = vec![zero; (l.len() + 1) * width];
    let at = |x: usize, y: usize| x * width + y;
    let paired = |best: &[Alignment], x: usize, y: usize| {
        let next = best[at(x + 1, y + 1)];
        Alignment {
            count: next.count + 1,
            cost: next.cost + distance(x, y),
        }
    };
    for x in (0..l.len()).rev() {
        for y in (0..r.len()).rev() {
            let down = best[at(x, y + 1)];
            let across = best[at(x + 1, y)];
            let skip = if down.better(across) { down } else { across };
            best[at(x, y)] = if matches(x, y) && paired(&best, x, y).better(skip) {
                paired(&best, x, y)
            } else {
                skip
            };
        }
    }
    let mut pairs = Vec::new();
    let (mut x, mut y) = (0, 0);
    while x < l.len() && y < r.len() {
        if matches(x, y) && paired(&best, x, y) == best[at(x, y)] {
            pairs.push((l[x], r[y]));
            x += 1;
            y += 1;
        } else if best[at(x + 1, y)] == best[at(x, y)] {
            x += 1;
        } else {
            y += 1;
        }
    }
    let middle = overlap.start + overlap.end;
    // The first pair nearest the middle, as Swift's `min(by:)` picks.
    let anchor = pairs
        .iter()
        .min_by_key(|&&(i, j)| (left[i].start + right[j].start).abs_diff(middle));
    let Some(&(i, j)) = anchor else {
        let mut words: Vec<Word> = left.into_iter().filter(|w| 2 * w.start < middle).collect();
        words.extend(right.into_iter().filter(|w| 2 * w.start >= middle));
        return words;
    };
    let joined = seam(&left[i], &right[j]);
    let mut words: Vec<Word> = left.into_iter().take(i).collect();
    words.push(joined);
    words.extend(right.into_iter().skip(j + 1));
    words
}

/// Casing comes from the earlier chunk, which heard what preceded the word;
/// trailing punctuation from the later chunk, which heard what follows it.
fn seam(left: &Word, right: &Word) -> Word {
    let last_alnum = |s: &str| s.char_indices().rfind(|&(_, c)| is_alnum(c));
    let (Some((le, lc)), Some((re, rc))) = (last_alnum(&left.text), last_alnum(&right.text)) else {
        return left.clone();
    };
    let mut text = left.text[..le + lc.len_utf8()].to_owned();
    text.push_str(&right.text[re + rc.len_utf8()..]);
    Word {
        text,
        start: left.start,
    }
}

/// Lowercased scalar by scalar, filtered to letters, marks and numbers, and
/// decomposed so canonically equivalent words compare equal.
fn key(text: &str) -> String {
    lf_text::dictionary::fold(text)
        .chars()
        .filter(|&c| is_alnum(c))
        .nfd()
        .collect()
}

/// Apple's `CharacterSet.alphanumerics`: general categories L*, M* and N*.
fn is_alnum(c: char) -> bool {
    matches!(
        c.general_category_group(),
        GeneralCategoryGroup::Letter | GeneralCategoryGroup::Mark | GeneralCategoryGroup::Number
    )
}
