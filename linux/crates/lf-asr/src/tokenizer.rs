//! The model's vocabulary: the SentencePiece tokenizer from `lf-text`
//! (re-exported), loaded from the export's `tokenizer.vocab`.

pub use lf_text::tokenizer::*;

use lf_model::{Error, Result};

/// From `tokenizer.vocab` (`piece \t score` per line, id = line number),
/// cross-checked against the model config's vocabulary list if present.
pub fn from_vocab_file(
    bytes: &[u8],
    config_vocab: Option<&[serde_json::Value]>,
) -> Result<Tokenizer> {
    let pieces = parse_vocab(bytes).map_err(text_error)?;
    if pieces.len() != crate::config::VOCAB {
        return Err(Error(format!(
            "tokenizer has {} pieces, expected {}",
            pieces.len(),
            crate::config::VOCAB
        )));
    }
    if let Some(cv) = config_vocab {
        let same =
            cv.len() == pieces.len() && cv.iter().zip(&pieces).all(|(a, b)| a.as_str() == Some(b));
        if !same {
            return Err(Error(
                "tokenizer.vocab disagrees with the config vocabulary".into(),
            ));
        }
    }
    Tokenizer::from_pieces(pieces).map_err(text_error)
}

/// An `lf-text` tokenizer error as this crate's error.
pub(crate) fn text_error(e: lf_text::Error) -> Error {
    Error(e.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vocab_file(pieces: usize) -> String {
        std::iter::once("<unk>\t0\n".to_owned())
            .chain((1..pieces).map(|i| format!("p{i}\t-{i}\n")))
            .collect()
    }

    #[test]
    fn checks_the_model_vocabulary() {
        let v = vocab_file(crate::config::VOCAB);
        let t = from_vocab_file(v.as_bytes(), None).unwrap();
        assert_eq!(t.len(), crate::config::VOCAB);

        let config: Vec<serde_json::Value> = v
            .lines()
            .map(|l| l.split('\t').next().unwrap().into())
            .collect();
        assert!(from_vocab_file(v.as_bytes(), Some(&config[..])).is_ok());
        assert!(from_vocab_file(v.as_bytes(), Some(&config[1..])).is_err());
        let mut other = config.clone();
        other[5] = "q5".into();
        assert!(from_vocab_file(v.as_bytes(), Some(&other[..])).is_err());

        let short = vocab_file(crate::config::VOCAB - 1);
        assert!(from_vocab_file(short.as_bytes(), None).is_err());
        assert!(from_vocab_file(b"a\t0\n", None).is_err());
    }
}
