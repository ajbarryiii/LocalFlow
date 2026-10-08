//! SentencePiece vocabulary and detokenization, matching NeMo 3.0's RNNT
//! decoding: SentencePiece `DecodeIds`, then one whitespace character removed
//! before each punctuation mark the vocabulary contains
//! (`decode_tokens_to_str_with_strip_punctuation`).

use std::collections::BTreeSet;

use lf_model::{Error, Result};
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

pub struct Tokenizer {
    pieces: Vec<String>,
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
        let pieces: Vec<String> = text
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.split('\t').next().unwrap_or("").to_owned())
            .collect();
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
        Ok(Tokenizer {
            pieces,
            punctuation,
        })
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
