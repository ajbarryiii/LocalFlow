//! The few Swift `String` / Foundation semantics the dictation port relies on.
//!
//! - `Character` is an extended grapheme cluster.
//! - `Character.isWhitespace` / `isPunctuation` look at the first scalar only:
//!   Unicode `White_Space`, and general category `P*`.
//! - `String.lowercased()` / `uppercased()` map each scalar with its full,
//!   context-free case mapping (no final-sigma rule, unlike Rust's
//!   `str::to_lowercase`).
//! - `String` and `Character` equality is canonical equivalence.
//! - `trimmingCharacters(in: .whitespacesAndNewlines)` trims scalars in
//!   `White_Space ∪ {U+200B}`.

use unicode_normalization::UnicodeNormalization;
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

/// Unicode `White_Space`: `Unicode.Scalar.Properties.isWhitespace` (and so
/// `Character.isWhitespace`) and ICU `\s`.
pub fn is_whitespace(c: char) -> bool {
    c.is_whitespace()
}

/// `CharacterSet.whitespacesAndNewlines`: Foundation's whitespace set is
/// `White_Space` plus U+200B ZERO WIDTH SPACE (CoreFoundation's
/// `0x2000...0x200B` range).
pub fn is_foundation_whitespace(c: char) -> bool {
    c.is_whitespace() || c == '\u{200B}'
}

/// General category `P*` (`CharacterSet.punctuationCharacters`, ICU `\p{P}`).
pub fn is_punctuation(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Punctuation
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim(s: &str) -> &str {
    s.trim_matches(is_foundation_whitespace)
}

/// `Character.isWhitespace` for a grapheme cluster.
pub fn grapheme_is_whitespace(g: &str) -> bool {
    g.chars().next().is_some_and(is_whitespace)
}

/// `Character.isPunctuation` for a grapheme cluster.
pub fn grapheme_is_punctuation(g: &str) -> bool {
    g.chars().next().is_some_and(is_punctuation)
}

/// `String.lowercased()`: per-scalar full lowercase mapping.
pub fn lowercased(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// `String.uppercased()`: per-scalar full uppercase mapping.
pub fn uppercased(s: &str) -> String {
    s.chars().flat_map(char::to_uppercase).collect()
}

/// Canonical form used for Swift `==` and hashing (canonical equivalence).
pub fn canonical(s: &str) -> String {
    if s.is_ascii() {
        s.to_owned()
    } else {
        s.nfc().collect()
    }
}

/// Swift `a == b` for strings.
pub fn canonically_equal(a: &str, b: &str) -> bool {
    a == b || (!(a.is_ascii() && b.is_ascii()) && a.nfc().eq(b.nfc()))
}

/// The last `Character` of `s`.
pub fn last_grapheme(s: &str) -> Option<&str> {
    s.graphemes(true).next_back()
}

/// Whether a byte offset is a `Character` boundary, as required by
/// `Range(_: NSRange, in: String)` (it fails otherwise).
pub fn is_grapheme_boundary(s: &str, offset: usize) -> bool {
    offset == s.len() || s.grapheme_indices(true).any(|(start, _)| start == offset)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitespace_sets() {
        for c in [
            '\t', '\n', '\u{0B}', '\u{0C}', '\r', ' ', '\u{85}', '\u{A0}', '\u{1680}', '\u{2000}',
            '\u{200A}', '\u{2028}', '\u{2029}', '\u{202F}', '\u{205F}', '\u{3000}',
        ] {
            assert!(is_whitespace(c), "{:?}", c);
            assert!(is_foundation_whitespace(c), "{:?}", c);
        }
        for c in ['\u{FEFF}', '\u{180E}', 'a', '\u{1C}'] {
            assert!(!is_whitespace(c), "{:?}", c);
            assert!(!is_foundation_whitespace(c), "{:?}", c);
        }
        assert!(!is_whitespace('\u{200B}'));
        assert!(is_foundation_whitespace('\u{200B}'));
        assert_eq!(trim("\u{200B} a\u{200B}b \u{200B}"), "a\u{200B}b");
    }

    #[test]
    fn punctuation_is_general_category_p() {
        for c in [
            '.', ',', '!', '?', '-', '_', '(', ')', '"', '\'', '\u{2026}', '\u{37E}', '“',
        ] {
            assert!(is_punctuation(c), "{:?}", c);
        }
        // Symbols are not punctuation: backtick and caret are Sk, plus and
        // dollar are Sm and Sc.
        for c in ['`', '^', '+', '$', '|', '~', 'a', '1', '🙂'] {
            assert!(!is_punctuation(c), "{:?}", c);
        }
    }

    #[test]
    fn case_mapping_is_per_scalar() {
        assert_eq!(lowercased("ΟΔΟΣ"), "οδοσ");
        assert_ne!("ΟΔΟΣ".to_lowercase(), "οδοσ");
        assert_eq!(lowercased("İ"), "i\u{307}");
        assert_eq!(uppercased("straße"), "STRASSE");
    }

    #[test]
    fn canonical_equality() {
        assert!(canonically_equal("caf\u{E9}", "cafe\u{301}"));
        assert!(canonically_equal("\u{37E}", ";"));
        assert!(!canonically_equal("cafe", "café"));
    }

    #[test]
    fn grapheme_helpers() {
        assert_eq!(last_grapheme("ab\r\n"), Some("\r\n"));
        assert_eq!(last_grapheme("e\u{301}"), Some("e\u{301}"));
        assert_eq!(last_grapheme(""), None);
        assert!(!is_grapheme_boundary("ae\u{301}b", 2));
        assert!(is_grapheme_boundary("ab", 1) && is_grapheme_boundary("ab", 2));
    }
}
