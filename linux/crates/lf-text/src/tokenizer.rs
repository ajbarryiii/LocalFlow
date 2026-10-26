// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
//! SentencePiece vocabulary and detokenization, matching NeMo 3.0's RNNT
//! decoding: SentencePiece `DecodeIds`, then one whitespace character removed
//! before each punctuation mark the vocabulary contains
//! (`decode_tokens_to_str_with_strip_punctuation`). Also SentencePiece BPE
//! encoding, for word boosting (LocalFlow DESIGN §1.3).
//!
//! Loading the model's vocabulary from an export (its size and the config
//! cross-check) is `lf_asr::tokenizer::from_vocab_file`.

use std::cmp::Reverse;
use std::collections::{BTreeSet, BinaryHeap, HashMap};

use crate::{Error, Result};
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

const SPACE: char = '\u{2581}';
const UNK: &str = "<unk>";
/// `<unk>`'s id: the first piece.
pub const UNK_ID: usize = 0;

pub struct Tokenizer {
    pieces: Vec<String>,
    /// Piece to id for encoding: every piece but `<unk>` (the first of
    /// duplicates wins). An id is the piece's merge rank: lower merges first.
    ids: HashMap<String, usize>,
    /// NeMo `extract_punctuation_from_vocab`: punctuation (general category P*)
    /// in pieces that do not look special.
    punctuation: BTreeSet<char>,
}

/// Python's `\s` for `str` patterns (`str.isspace`): Unicode White_Space plus
/// the information separators U+001C..U+001F.
pub fn is_python_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// NeMo's "special token" patterns: `[...]`, `<...>`, `##...`, `▁...`, or blank.
/// (Python's `.` and `$` newline subtleties cannot matter: vocabulary pieces
/// come from separate lines and contain no newline.)
fn is_special_piece(p: &str) -> bool {
    (p.starts_with('[') && p.ends_with(']') && p.len() >= 2)
        || (p.starts_with('<') && p.ends_with('>') && p.len() >= 2)
        || p.starts_with("##")
        || p.starts_with('\u{2581}')
        || p.chars().all(is_python_space)
}

fn vocab_punctuation(pieces: &[String]) -> BTreeSet<char> {
    pieces
        .iter()
        .filter(|p| !is_special_piece(p))
        .flat_map(|p| p.chars())
        .filter(|c| c.general_category_group() == GeneralCategoryGroup::Punctuation)
        .collect()
}

/// The pieces of a SentencePiece `tokenizer.vocab` (`piece \t score` per
/// line, id = line number), in id order, for [`Tokenizer::from_pieces`].
pub fn parse_vocab(bytes: &[u8]) -> Result<Vec<String>> {
    let text =
        std::str::from_utf8(bytes).map_err(|_| Error("tokenizer.vocab is not UTF-8".into()))?;
    let mut pieces = Vec::new();
    let mut scores = Vec::new();
    for (i, line) in text.lines().filter(|l| !l.is_empty()).enumerate() {
        let mut fields = line.split('\t');
        pieces.push(fields.next().unwrap_or("").to_owned());
        match fields.next().and_then(|s| s.trim().parse::<f64>().ok()) {
            Some(s) if s.is_finite() => scores.push(s),
            _ => return Err(Error(format!("tokenizer.vocab line {}: bad score", i + 1))),
        }
    }
    // Encoding merges by id (DESIGN §1.3), which is only SentencePiece's
    // merge order if scores fall strictly with the id after `<unk>`.
    if let Some(i) = (2..scores.len()).find(|&i| scores[i] >= scores[i - 1]) {
        return Err(Error(format!(
            "tokenizer.vocab scores do not decrease strictly at id {i}"
        )));
    }
    Ok(pieces)
}

impl Tokenizer {
    /// From pieces in rank order (the id is the merge rank), `<unk>` first.
    /// For tests and the shared vectors; the model's vocabulary goes through
    /// `lf_asr::tokenizer::from_vocab_file`.
    pub fn from_pieces(pieces: Vec<String>) -> Result<Self> {
        if pieces.first().map(String::as_str) != Some(UNK) {
            return Err(Error("the first piece must be <unk>".into()));
        }
        let mut ids = HashMap::new();
        for (i, p) in pieces.iter().enumerate().skip(1) {
            if !p.is_empty() {
                ids.entry(p.clone()).or_insert(i);
            }
        }
        let punctuation = vocab_punctuation(&pieces);
        Ok(Tokenizer {
            pieces,
            ids,
            punctuation,
        })
    }

    /// Number of pieces, `<unk>` included (token ids are below it).
    pub fn len(&self) -> usize {
        self.pieces.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pieces.is_empty()
    }

    /// The pieces by token id, `<unk>` first.
    pub fn pieces(&self) -> &[String] {
        &self.pieces
    }

    /// Text to token ids, SentencePiece BPE as LocalFlow specifies it
    /// (DESIGN §1.3): `▁` before the text and in place of each ASCII space;
    /// one symbol per Unicode scalar; then, repeatedly, the adjacent pair
    /// whose concatenation is the piece with the lowest id merges (the
    /// leftmost such pair on ties) until no pair is a piece. Each maximal
    /// run of final symbols that are not pieces becomes one `<unk>`
    /// ([`UNK_ID`]). No other normalization is applied.
    pub fn encode(&self, text: &str) -> Vec<usize> {
        let normalized: String = std::iter::once(SPACE)
            .chain(text.chars().map(|c| if c == ' ' { SPACE } else { c }))
            .collect();

        struct Symbol {
            start: usize,
            len: usize,
            prev: Option<usize>,
            next: Option<usize>,
        }
        let mut symbols: Vec<Symbol> = normalized
            .char_indices()
            .enumerate()
            .map(|(i, (start, c))| Symbol {
                start,
                len: c.len_utf8(),
                prev: i.checked_sub(1),
                next: Some(i + 1),
            })
            .collect();
        if let Some(last) = symbols.last_mut() {
            last.next = None;
        }

        // Candidate merges, lowest id first, then leftmost (symbols keep the
        // index of their first scalar, so indices order positions). Entries
        // whose symbols have changed since are skipped when popped: symbols
        // only grow, so a stale pair's summed length no longer matches.
        let pair = |symbols: &[Symbol], left: usize, right: usize| {
            let (l, r) = (&symbols[left], &symbols[right]);
            let len = l.len + r.len;
            let &id = self.ids.get(&normalized[l.start..l.start + len])?;
            Some(Reverse((id, left, right, len)))
        };
        let mut agenda: BinaryHeap<Reverse<(usize, usize, usize, usize)>> = (1..symbols.len())
            .filter_map(|r| pair(&symbols, r - 1, r))
            .collect();
        while let Some(Reverse((_, left, right, len))) = agenda.pop() {
            let (l, r) = (&symbols[left], &symbols[right]);
            if l.len == 0 || r.len == 0 || l.len + r.len != len {
                continue;
            }
            let next = r.next;
            symbols[left].len = len;
            symbols[left].next = next;
            symbols[right].len = 0;
            if let Some(n) = next {
                symbols[n].prev = Some(left);
            }
            if let Some(p) = symbols[left].prev {
                agenda.extend(pair(&symbols, p, left));
            }
            if let Some(n) = next {
                agenda.extend(pair(&symbols, left, n));
            }
        }

        let mut out = Vec::new();
        let mut at = Some(0);
        while let Some(i) = at {
            let s = &symbols[i];
            match self.ids.get(&normalized[s.start..s.start + s.len]) {
                Some(&id) => out.push(id),
                None if out.last() == Some(&UNK_ID) => {}
                None => out.push(UNK_ID),
            }
            at = s.next;
        }
        out
    }

    /// Token ids (blank excluded) to text, as NeMo produces `hypothesis.text`:
    /// [`Self::sentencepiece_decode`], then [`Self::strip_space_before_punctuation`].
    pub fn decode(&self, tokens: &[usize]) -> Result<String> {
        Ok(self.strip_space_before_punctuation(&self.sentencepiece_decode(tokens)?))
    }

    /// NeMo's `re.sub(r'(\s)(<punct>)', r'\2', text)`: left to right and
    /// non-overlapping, one whitespace character directly before a vocabulary
    /// punctuation mark is removed (so two spaces before `?` leave one).
    pub fn strip_space_before_punctuation(&self, text: &str) -> String {
        let chars: Vec<char> = text.chars().collect();
        let mut out = String::with_capacity(text.len());
        let mut i = 0;
        while i < chars.len() {
            if is_python_space(chars[i])
                && chars
                    .get(i + 1)
                    .is_some_and(|c| self.punctuation.contains(c))
            {
                out.push(chars[i + 1]);
                i += 2;
            } else {
                out.push(chars[i]);
                i += 1;
            }
        }
        out
    }

    /// SentencePiece `DecodeIds` with this model's normalizer (dummy prefix on,
    /// extra-whitespace removal off): `<unk>` becomes " ⁇ ", the first non-empty
    /// piece loses one leading `▁`, and every other `▁` becomes a space.
    pub fn sentencepiece_decode(&self, tokens: &[usize]) -> Result<String> {
        const SPACE: char = '\u{2581}';
        const UNK_SURFACE: &str = " \u{2047} ";
        let mut out = String::new();
        let mut at_start = true;
        for &t in tokens {
            let Some(piece) = self.pieces.get(t) else {
                return Err(Error(format!("token {t} out of range")));
            };
            let surface = if piece == "<unk>" {
                UNK_SURFACE.to_owned()
            } else {
                let p = if at_start {
                    piece.strip_prefix(SPACE).unwrap_or(piece)
                } else {
                    piece
                };
                p.replace(SPACE, " ")
            };
            if !surface.is_empty() {
                at_start = false;
            }
            out.push_str(&surface);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The model's vocabulary size (`lf_asr::config::VOCAB`).
    const VOCAB: usize = 1024;

    fn from_vocab_file(bytes: &[u8]) -> Result<Tokenizer> {
        Tokenizer::from_pieces(parse_vocab(bytes)?)
    }

    fn vocab(pieces: &[&str]) -> Tokenizer {
        let mut v: String = pieces
            .iter()
            .enumerate()
            .map(|(i, p)| format!("{p}\t-{i}\n"))
            .collect();
        for i in pieces.len()..VOCAB {
            v.push_str(&format!("x{i}\t-{i}\n"));
        }
        from_vocab_file(v.as_bytes()).unwrap()
    }

    #[test]
    fn strips_one_space_before_vocabulary_punctuation_like_nemo() {
        // 1 "▁he", 2 "▁", 3 "?", 4 ",", 5 "▁!" (special: its "!" does not count),
        // 6 "[x.]" and 7 "<y;>" (special), 8 "a.b" (contributes ".").
        let t = vocab(&[
            "<unk>",
            "\u{2581}he",
            "\u{2581}",
            "?",
            ",",
            "\u{2581}!",
            "[x.]",
            "<y;>",
            "a.b",
        ]);
        assert_eq!(t.punctuation, BTreeSet::from(['?', ',', '.']));
        assert_eq!(t.decode(&[1, 2, 3]).unwrap(), "he?");
        // Only one of two spaces is removed.
        assert_eq!(t.decode(&[1, 2, 2, 3]).unwrap(), "he ?");
        // Non-overlapping, left to right.
        assert_eq!(t.decode(&[1, 2, 3, 2, 3]).unwrap(), "he??");
        assert_eq!(t.decode(&[1, 2, 4, 2, 3]).unwrap(), "he,?");
        // "!" only appears in a special piece, so the space stays.
        assert_eq!(t.decode(&[1, 5]).unwrap(), "he !");
        // Nothing to strip at the very start.
        assert_eq!(t.decode(&[3, 1]).unwrap(), "? he");
        assert_eq!(t.sentencepiece_decode(&[1, 2, 3]).unwrap(), "he ?");
        // Python's `\s` includes the information separators U+001C..U+001F,
        // which Rust's `is_whitespace` does not.
        for sep in ['\u{1c}', '\u{1f}', '\u{a0}', '\t'] {
            assert_eq!(t.strip_space_before_punctuation(&format!("a{sep}?")), "a?");
        }
        assert_eq!(t.strip_space_before_punctuation("a\u{200b}?"), "a\u{200b}?");
    }

    #[test]
    fn decodes_word_boundaries() {
        let mut vocab =
            String::from("<unk>\t0\n\u{2581}he\t-1\nllo\t-2\n\u{2581}world\t-3\n\u{2581}\t-4\n");
        for i in 5..VOCAB {
            vocab.push_str(&format!("p{i}\t-{i}\n"));
        }
        let t = from_vocab_file(vocab.as_bytes()).unwrap();
        assert_eq!(t.decode(&[1, 2, 3]).unwrap(), "hello world");
        // At the start, each piece loses one boundary until a surface is non-empty;
        // after that, repeated boundaries stay.
        assert_eq!(t.decode(&[4, 4, 1]).unwrap(), "he");
        assert_eq!(t.decode(&[1, 4, 4, 3]).unwrap(), "he   world");
        // Unknown surface, including at the start (no prefix stripping there).
        assert_eq!(t.decode(&[0, 1]).unwrap(), " \u{2047}  he");
        assert_eq!(t.decode(&[1, 0]).unwrap(), "he \u{2047} ");
        assert_eq!(t.decode(&[]).unwrap(), "");
        assert!(t.decode(&[VOCAB]).is_err());
        // `<unk>` must come first.
        assert!(from_vocab_file(b"a\t0\n").is_err());
    }

    #[test]
    fn vocab_scores_must_fall_strictly_after_unk() {
        assert_eq!(
            parse_vocab(b"<unk>\t0\na\t0\nb\t-1\n\nc\t-1.5\n").unwrap(),
            ["<unk>", "a", "b", "c"]
        );
        for bad in [
            &b"<unk>\t0\na\t-1\nb\t-1\n"[..],
            b"<unk>\t0\na\t-1\nb\t-0.5\n",
            b"<unk>\t0\na\n",
            b"<unk>\t0\na\tx\n",
            b"<unk>\t0\na\tinf\n",
            b"<unk>\t0\n\xff\t-1\n",
        ] {
            assert!(parse_vocab(bad).is_err(), "{bad:?}");
        }
    }
}
