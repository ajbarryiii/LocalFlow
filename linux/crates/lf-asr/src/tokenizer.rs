//! SentencePiece vocabulary and detokenization, matching NeMo 3.0's RNNT
//! decoding: SentencePiece `DecodeIds`, then one whitespace character removed
//! before each punctuation mark the vocabulary contains
//! (`decode_tokens_to_str_with_strip_punctuation`). Also SentencePiece BPE
//! encoding, for phrase boosting.

use std::cmp::Ordering;
use std::collections::{BTreeSet, BinaryHeap, HashMap};

use lf_model::{Error, Result};
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

const SPACE: char = '\u{2581}';
const UNK: &str = "<unk>";

pub struct Tokenizer {
    pieces: Vec<String>,
    /// The vocabulary's score column: for a BPE model, higher merges first.
    scores: Vec<f32>,
    /// Pieces that text can produce (every piece but `<unk>`).
    ids: HashMap<String, usize>,
    unk: Option<usize>,
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

impl Tokenizer {
    /// From `tokenizer.vocab` (`piece \t score` per line, id = line number),
    /// cross-checked against the model config's vocabulary list if present.
    pub fn from_vocab_file(
        bytes: &[u8],
        config_vocab: Option<&[serde_json::Value]>,
    ) -> Result<Self> {
        let text =
            std::str::from_utf8(bytes).map_err(|_| Error("tokenizer.vocab is not UTF-8".into()))?;
        let mut pieces = Vec::new();
        let mut scores = Vec::new();
        for (i, line) in text.lines().filter(|l| !l.is_empty()).enumerate() {
            let mut fields = line.split('\t');
            pieces.push(fields.next().unwrap_or("").to_owned());
            let score = fields.next().and_then(|s| s.trim().parse::<f32>().ok());
            match score {
                Some(s) if s.is_finite() => scores.push(s),
                _ => return Err(Error(format!("tokenizer.vocab line {}: bad score", i + 1))),
            }
        }
        if pieces.len() != crate::config::VOCAB {
            return Err(Error(format!(
                "tokenizer has {} pieces, expected {}",
                pieces.len(),
                crate::config::VOCAB
            )));
        }
        if let Some(cv) = config_vocab {
            let same = cv.len() == pieces.len()
                && cv.iter().zip(&pieces).all(|(a, b)| a.as_str() == Some(b));
            if !same {
                return Err(Error(
                    "tokenizer.vocab disagrees with the config vocabulary".into(),
                ));
            }
        }
        let punctuation = vocab_punctuation(&pieces);
        let unk = pieces.iter().position(|p| p == UNK);
        let mut ids = HashMap::new();
        for (i, p) in pieces.iter().enumerate() {
            if Some(i) != unk && !p.is_empty() {
                ids.entry(p.clone()).or_insert(i);
            }
        }
        Ok(Tokenizer {
            pieces,
            scores,
            ids,
            unk,
            punctuation,
        })
    }

    /// The id of `<unk>`, if the vocabulary has it.
    pub fn unk(&self) -> Option<usize> {
        self.unk
    }

    /// Text to token ids as SentencePiece `EncodeAsIds` does for this BPE model.
    /// Normalization: dummy prefix on (for non-empty text), each space becomes
    /// `▁`, no extra-whitespace removal. The model's `nmt_nfkc` normalization
    /// table is not applied, so text that NFKC would change (compatibility
    /// characters, unusual whitespace) may encode differently from
    /// SentencePiece; plain text is unaffected. The text is split into characters, then the adjacent pair whose
    /// concatenation is the highest-scoring piece merges, leftmost first on
    /// ties, until no pair is a piece. Characters no piece covers become
    /// `<unk>`, one per run (an error without `<unk>`).
    pub fn encode(&self, text: &str) -> Result<Vec<usize>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }
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

        #[derive(PartialEq)]
        struct Pair {
            score: f32,
            left: usize,
            right: usize,
            len: usize,
        }
        impl Eq for Pair {}
        impl Ord for Pair {
            fn cmp(&self, o: &Self) -> Ordering {
                self.score
                    .total_cmp(&o.score)
                    .then_with(|| o.left.cmp(&self.left))
            }
        }
        impl PartialOrd for Pair {
            fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
                Some(self.cmp(o))
            }
        }
        let pair = |symbols: &[Symbol], left: usize, right: usize| -> Option<Pair> {
            let (l, r) = (&symbols[left], &symbols[right]);
            let len = l.len + r.len;
            let &id = self.ids.get(&normalized[l.start..l.start + len])?;
            Some(Pair {
                score: self.scores[id],
                left,
                right,
                len,
            })
        };
        let mut agenda: BinaryHeap<Pair> = (1..symbols.len())
            .filter_map(|r| pair(&symbols, r - 1, r))
            .collect();
        while let Some(top) = agenda.pop() {
            // Skip pairs whose symbols have merged since.
            let (l, r) = (&symbols[top.left], &symbols[top.right]);
            if l.len == 0 || r.len == 0 || l.len + r.len != top.len {
                continue;
            }
            let next = r.next;
            symbols[top.left].len = top.len;
            symbols[top.left].next = next;
            symbols[top.right].len = 0;
            if let Some(n) = next {
                symbols[n].prev = Some(top.left);
            }
            if let Some(p) = symbols[top.left].prev {
                agenda.extend(pair(&symbols, p, top.left));
            }
            if let Some(n) = next {
                agenda.extend(pair(&symbols, top.left, n));
            }
        }

        let mut out = Vec::new();
        let mut at = Some(0);
        while let Some(i) = at {
            let s = &symbols[i];
            match self.ids.get(&normalized[s.start..s.start + s.len]) {
                Some(&id) => out.push(id),
                None => {
                    let unk = self
                        .unk
                        .ok_or_else(|| Error("text outside the vocabulary and no <unk>".into()))?;
                    if out.last() != Some(&unk) {
                        out.push(unk);
                    }
                }
            }
            at = s.next;
        }
        Ok(out)
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
        const UNK_SURFACE: &str = " \u{2047} ";
        let mut out = String::new();
        let mut at_start = true;
        for &t in tokens {
            let Some(piece) = self.pieces.get(t) else {
                return Err(Error(format!("token {t} out of range")));
            };
            let surface = if piece == UNK {
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
pub(crate) mod tests {
    use super::*;

    /// A small BPE vocabulary in SentencePiece's layout: `<unk>`, merged pieces
    /// in merge order, then single characters, with score `-id`; filler pieces
    /// no text produces pad it to the model's size.
    pub(crate) fn synthetic() -> Tokenizer {
        let merges = [
            "he",
            "ll",
            "\u{2581}he",
            "llo",
            "\u{2581}hello",
            "\u{2581}w",
            "or",
            "\u{2581}wor",
            "ld",
            "\u{2581}n",
            "ew",
            "\u{2581}new",
            "\u{2581}y",
            "ork",
            "\u{2581}york",
            "lo",
        ];
        let chars = "\u{2581}abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ,.?";
        let mut pieces = vec![UNK.to_owned()];
        pieces.extend(merges.iter().map(|m| m.to_string()));
        pieces.extend(chars.chars().map(String::from));
        let mut v = String::new();
        for i in 0..crate::config::VOCAB {
            let p = pieces.get(i).cloned().unwrap_or_else(|| format!("<f{i}>"));
            v.push_str(&format!("{p}\t-{i}\n"));
        }
        Tokenizer::from_vocab_file(v.as_bytes(), None).unwrap()
    }

    fn pieces(t: &Tokenizer, text: &str) -> Vec<String> {
        let ids = t.encode(text).unwrap();
        ids.iter()
            .map(|&i| t.pieces[i].replace(SPACE, "_"))
            .collect()
    }

    #[test]
    fn encodes_known_segmentations() {
        let t = synthetic();
        assert_eq!(pieces(&t, "hello world"), ["_hello", "_wor", "ld"]);
        assert_eq!(pieces(&t, "new york"), ["_new", "_york"]);
        // Merges happen in score order, not longest match: "▁he" + "llo" exist,
        // but "lo" (merged after "ll") never forms when "ll" can.
        assert_eq!(pieces(&t, "hellow"), ["_hello", "w"]);
        assert_eq!(pieces(&t, "low"), ["_", "lo", "w"]);
        // Equal scores merge leftmost first.
        assert_eq!(pieces(&t, "lll"), ["_", "ll", "l"]);
        // Spaces are kept as written; the dummy prefix applies once.
        assert_eq!(
            pieces(&t, " hello  world"),
            ["_", "_hello", "_", "_wor", "ld"]
        );
        assert_eq!(pieces(&t, "Hello"), ["_", "H", "e", "llo"]);
        assert_eq!(
            pieces(&t, "hello, world."),
            ["_hello", ",", "_wor", "ld", "."]
        );
        assert!(t.encode("").unwrap().is_empty());
    }

    #[test]
    fn encode_round_trips_ordinary_text() {
        let t = synthetic();
        for s in [
            "hello world",
            "Hello World, new York.",
            "the quick brown fox jumps over the lazy dog",
            "Is it   spaced?",
            "x",
        ] {
            assert_eq!(t.decode(&t.encode(s).unwrap()).unwrap(), s);
        }
    }

    #[test]
    fn uncovered_characters_become_one_unk_per_run() {
        let t = synthetic();
        assert_eq!(t.unk(), Some(0));
        assert_eq!(pieces(&t, "h\u{e9}llo"), ["_", "h", UNK, "llo"]);
        assert_eq!(pieces(&t, "\u{e9}\u{e8}9 w"), ["_", UNK, "_w"]);
        // Special pieces are never produced from text.
        assert_eq!(pieces(&t, "<unk>"), ["_", UNK, "u", "n", "k", UNK]);
    }

    fn vocab(pieces: &[&str]) -> Tokenizer {
        let mut v: String = pieces
            .iter()
            .enumerate()
            .map(|(i, p)| format!("{p}\t-{i}\n"))
            .collect();
        for i in pieces.len()..crate::config::VOCAB {
            v.push_str(&format!("x{i}\t-{i}\n"));
        }
        Tokenizer::from_vocab_file(v.as_bytes(), None).unwrap()
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
        for i in 5..crate::config::VOCAB {
            vocab.push_str(&format!("p{i}\t-{i}\n"));
        }
        let t = Tokenizer::from_vocab_file(vocab.as_bytes(), None).unwrap();
        assert_eq!(t.decode(&[1, 2, 3]).unwrap(), "hello world");
        // At the start, each piece loses one boundary until a surface is non-empty;
        // after that, repeated boundaries stay.
        assert_eq!(t.decode(&[4, 4, 1]).unwrap(), "he");
        assert_eq!(t.decode(&[1, 4, 4, 3]).unwrap(), "he   world");
        // Unknown surface, including at the start (no prefix stripping there).
        assert_eq!(t.decode(&[0, 1]).unwrap(), " \u{2047}  he");
        assert_eq!(t.decode(&[1, 0]).unwrap(), "he \u{2047} ");
        assert_eq!(t.decode(&[]).unwrap(), "");
        assert!(t.decode(&[crate::config::VOCAB]).is_err());
        assert!(Tokenizer::from_vocab_file(b"a\t0\n", None).is_err());
    }
}
