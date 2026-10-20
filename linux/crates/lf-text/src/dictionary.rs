// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
//! The custom dictionary's shared text rules, entry validation and the token
//! sequences boosted for entries (LocalFlow DESIGN §1.0-§1.2). The bias graph
//! built from them is in `lf-asr` (`lf_asr::dictionary::build_graph`).
//!
//! Characters are Unicode scalar values throughout, and strings compare by
//! scalar sequence (no normalization). Dictionary text is the user's own and
//! private: nothing here formats it into errors or `Debug` output.

use unicode_properties::{GeneralCategory, GeneralCategoryGroup, UnicodeGeneralCategory};

use crate::tokenizer::{Tokenizer, UNK_ID};

/// Most entries in a dictionary.
pub const MAX_ENTRIES: usize = 1000;
/// Most identity keys in the ignore list.
pub const MAX_IGNORED: usize = 1000;
/// Most words in an entry.
pub const MAX_WORDS: usize = 8;
/// Most scalars in an entry.
pub const MAX_SCALARS: usize = 100;
pub const MIN_STRENGTH: f32 = 0.25;
pub const MAX_STRENGTH: f32 = 8.0;
pub const DEFAULT_STRENGTH: f32 = 1.0;
/// Strengths offered in user interfaces.
pub const STRENGTH_PRESETS: [f32; 8] = [0.5, 1.0, 1.41, 2.0, 2.83, 4.0, 5.66, 8.0];

/// A validated dictionary entry: the stored text and its strength.
#[derive(Clone, PartialEq)]
pub struct DictionaryEntry {
    pub text: String,
    pub strength: f32,
}

impl std::fmt::Debug for DictionaryEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DictionaryEntry")
            .field(
                "text",
                &format_args!("<{} scalars>", self.text.chars().count()),
            )
            .field("strength", &self.strength)
            .finish()
    }
}

impl DictionaryEntry {
    /// [`identity_key`] of the text.
    pub fn key(&self) -> String {
        fold(&self.text)
    }
}

/// Why text cannot be an entry. Names are stable (shared vectors, UI).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryError {
    /// No words.
    Empty,
    /// More than [`MAX_WORDS`] words.
    TooManyWords,
    /// More than [`MAX_SCALARS`] scalars.
    TooLong,
    /// No letter (general category L*).
    NoLetter,
    /// The text encodes with `<unk>`.
    Unencodable,
    /// Not finite, or outside [`MIN_STRENGTH`, `MAX_STRENGTH`].
    BadStrength,
}

impl EntryError {
    pub fn name(self) -> &'static str {
        match self {
            EntryError::Empty => "empty",
            EntryError::TooManyWords => "too-many-words",
            EntryError::TooLong => "too-long",
            EntryError::NoLetter => "no-letter",
            EntryError::Unencodable => "unencodable",
            EntryError::BadStrength => "bad-strength",
        }
    }
}

impl std::fmt::Display for EntryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            EntryError::Empty => "the entry is empty",
            EntryError::TooManyWords => "the entry has more than 8 words",
            EntryError::TooLong => "the entry is longer than 100 characters",
            EntryError::NoLetter => "the entry has no letter",
            EntryError::Unencodable => "the entry has characters the model cannot spell",
            EntryError::BadStrength => "the strength must be between 0.25 and 8",
        })
    }
}

impl std::error::Error for EntryError {}

/// `fold(s)`: every scalar through its full lowercase mapping.
pub fn fold(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// `upper1(s)`: the first scalar through its full uppercase mapping, the
/// rest unchanged.
pub fn upper1(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Unicode `White_Space`.
pub fn is_whitespace(c: char) -> bool {
    c.is_whitespace()
}

/// General category L*.
pub fn is_letter(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Letter
}

/// Word characters: letters (L*), marks (M*), decimal digits (Nd) and
/// connector punctuation (Pc).
pub fn is_word_char(c: char) -> bool {
    matches!(
        c.general_category_group(),
        GeneralCategoryGroup::Letter | GeneralCategoryGroup::Mark
    ) || matches!(
        c.general_category(),
        GeneralCategory::DecimalNumber | GeneralCategory::ConnectorPunctuation
    )
}

/// Edge punctuation, stripped from the ends of words and phrases. Other
/// symbols (`# + & / @ - _` …) are kept.
pub fn is_edge_punct(c: char) -> bool {
    matches!(
        c,
        '.' | ','
            | ';'
            | ':'
            | '!'
            | '?'
            | '"'
            | '\''
            | '\u{201C}'
            | '\u{201D}'
            | '\u{2018}'
            | '\u{2019}'
            | '('
            | ')'
            | '['
            | ']'
            | '{'
            | '}'
            | '\u{2026}'
            | '\u{2014}'
            | '\u{2013}'
            | '\u{AB}'
            | '\u{BB}'
    )
}

/// `s` without leading and trailing edge punctuation.
pub fn strip_edge_punct(s: &str) -> &str {
    s.trim_matches(is_edge_punct)
}

/// Whitespace-separated words, as entry validation and §1.5 split them.
pub fn words(s: &str) -> impl Iterator<Item = &str> {
    s.split(is_whitespace).filter(|w| !w.is_empty())
}

/// Validation steps 1 and 2 (DESIGN §1.1): trims, collapses internal
/// whitespace runs to one ASCII space, and checks the word, length and
/// letter rules. Returns the text to store, which still has to be encodable
/// (see [`validate`]).
pub fn normalize(text: &str) -> std::result::Result<String, EntryError> {
    let words: Vec<&str> = words(text).collect();
    if words.is_empty() {
        return Err(EntryError::Empty);
    }
    if words.len() > MAX_WORDS {
        return Err(EntryError::TooManyWords);
    }
    let joined = words.join(" ");
    if joined.chars().count() > MAX_SCALARS {
        return Err(EntryError::TooLong);
    }
    if !joined.chars().any(is_letter) {
        return Err(EntryError::NoLetter);
    }
    Ok(joined)
}

/// Whether `text` encodes with no `<unk>`. A control character (Cc) is never
/// a vocabulary piece (DESIGN P6), so text with one is never encodable.
pub fn encodable(text: &str, tokenizer: &Tokenizer) -> bool {
    !text.chars().any(char::is_control) && !tokenizer.encode(text).contains(&UNK_ID)
}

/// Most scalars in a stored identity or ignore key (folding can expand a
/// 100-scalar entry).
pub const MAX_KEY_SCALARS: usize = 300;

/// DESIGN P6: a stored identity or ignore key is non-empty, has at most
/// [`MAX_KEY_SCALARS`] scalars and [`MAX_WORDS`] space-separated words, no
/// control character (Cc), and is its own fold.
pub fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.chars().count() <= MAX_KEY_SCALARS
        && key.split(' ').count() <= MAX_WORDS
        && !key.chars().any(char::is_control)
        && fold(key) == key
}

/// Checks a strength (DESIGN §1.1 step 4).
pub fn check_strength(strength: f32) -> std::result::Result<f32, EntryError> {
    if strength.is_finite() && (MIN_STRENGTH..=MAX_STRENGTH).contains(&strength) {
        Ok(strength)
    } else {
        Err(EntryError::BadStrength)
    }
}

/// Full entry validation (DESIGN §1.1). Errors come in this order: empty,
/// too many words, too long, no letter, unencodable, bad strength.
pub fn validate(
    text: &str,
    strength: f32,
    tokenizer: &Tokenizer,
) -> std::result::Result<DictionaryEntry, EntryError> {
    let text = normalize(text)?;
    if !encodable(&text, tokenizer) {
        return Err(EntryError::Unencodable);
    }
    Ok(DictionaryEntry {
        text,
        strength: check_strength(strength)?,
    })
}

/// The identity key of an entry's text: [`fold`]. Two entries are the same
/// entry when their keys are equal scalar sequences.
pub fn identity_key(text: &str) -> String {
    fold(text)
}

/// The surfaces an entry is boosted as (DESIGN §1.2): the text, `fold`,
/// `upper1`, and each word through `upper1`; without repeats, in that order.
pub fn surfaces(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(4);
    let each_word = text.split(' ').map(upper1).collect::<Vec<_>>().join(" ");
    for s in [text.to_owned(), fold(text), upper1(text), each_word] {
        if !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// Token sequences to boost for `entries`, each with its strength: every
/// surface that encodes without `<unk>` (others are skipped). Duplicate
/// sequences keep the largest strength. Sorted by token sequence.
pub fn phrases(entries: &[DictionaryEntry], tokenizer: &Tokenizer) -> Vec<(Vec<usize>, f32)> {
    let mut map: std::collections::BTreeMap<Vec<usize>, f32> = Default::default();
    for e in entries {
        for s in surfaces(&e.text) {
            let tokens = tokenizer.encode(&s);
            if tokens.is_empty() || tokens.contains(&UNK_ID) {
                continue;
            }
            let v = map.entry(tokens).or_insert(e.strength);
            *v = v.max(e.strength);
        }
    }
    map.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn case_mappings_are_full_and_per_scalar() {
        assert_eq!(fold("ΟΔΟΣ"), "οδοσ");
        assert_eq!(fold("İx"), "i\u{307}x");
        assert_eq!(upper1("ßolo"), "SSolo");
        assert_eq!(upper1("ŉa"), "\u{2BC}Na");
        assert_eq!(upper1(""), "");
        assert_eq!(upper1("new york"), "New york");
    }

    #[test]
    fn character_classes() {
        for c in ['a', 'Z', 'é', '\u{301}', '7', '_', 'α', '\u{203F}'] {
            assert!(is_word_char(c), "{c:?}");
        }
        for c in [' ', '.', '-', '#', '\u{2160}', '½', '\''] {
            assert!(!is_word_char(c), "{c:?}");
        }
        for c in ['#', '+', '&', '/', '@', '-', '_'] {
            assert!(!is_edge_punct(c), "{c:?}");
        }
        assert_eq!(strip_edge_punct("«(NixOS)»."), "NixOS");
        assert_eq!(strip_edge_punct("C#."), "C#");
        assert_eq!(strip_edge_punct("—"), "");
        assert!(is_whitespace('\u{A0}') && !is_whitespace('\u{200B}'));
    }

    #[test]
    fn key_validity() {
        let expanded = fold(&format!("\u{130}{}", "a".repeat(99)));
        assert_eq!(expanded.chars().count(), 101);
        assert!(valid_key(&expanded));
        assert!(valid_key("new york") && valid_key("12") && valid_key(&"a".repeat(300)));
        for bad in [
            String::new(),
            "a".repeat(301),
            "a b c d e f g h i".into(),
            "New".into(),
            "a\u{7}b".into(),
            "a\u{85}b".into(),
            "\u{3a3}".into(),
        ] {
            assert!(!valid_key(&bad), "{bad:?}");
        }
    }

    #[test]
    fn debug_hides_text() {
        let e = DictionaryEntry {
            text: "Synthetic".into(),
            strength: 1.0,
        };
        let d = format!("{e:?}");
        assert!(!d.contains("Synthetic"), "{d}");
        assert!(d.contains("9 scalars"));
    }

    #[test]
    fn surfaces_are_deduplicated_in_order() {
        assert_eq!(surfaces("new york"), ["new york", "New york", "New York"]);
        assert_eq!(surfaces("NixOS"), ["NixOS", "nixos"]);
        assert_eq!(surfaces("ßolo"), ["ßolo", "SSolo"]);
    }
}
