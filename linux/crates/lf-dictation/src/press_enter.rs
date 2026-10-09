//! The Swift pattern, evaluated with ICU semantics by `NSRegularExpression`:
//!
//! ```text
//! (?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$
//! ```
//!
//! A hand-written matcher rather than a regex crate, to keep ICU details:
//! - `(?i)` on a literal string uses full case folding, so "ß"/"ẞ" match "ss"
//!   and "ſ" matches "s";
//! - `\s` is `White_Space` and `\p{P}` is general category `P*`;
//! - `$` without multiline matches at the end, or before a final line
//!   terminator, which the greedy `[\s\p{P}]*` absorbs anyway;
//! - `firstMatch` returns the leftmost match.
//!
//! The input is already trimmed by the caller, so a match always extends to
//! the end of the string and only its start matters.

use crate::swift;

fn is_separator(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n' | ',' | ';' | ':' | '-')
}

fn is_gap(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n')
}

fn is_tail(c: char) -> bool {
    swift::is_whitespace(c) || swift::is_punctuation(c)
}

/// Full case folding of the characters that can fold into the ASCII letters
/// of "press" or "enter". Everything else folds to itself, or (ASCII) to
/// lowercase.
fn fold(c: char) -> FoldIter {
    match c {
        'A'..='Z' => FoldIter::one(c.to_ascii_lowercase()),
        '\u{17F}' => FoldIter::one('s'),
        '\u{DF}' | '\u{1E9E}' => FoldIter::two('s', 's'),
        _ => FoldIter::one(c),
    }
}

struct FoldIter {
    chars: [char; 2],
    len: u8,
    pos: u8,
}

impl FoldIter {
    fn one(a: char) -> Self {
        FoldIter {
            chars: [a, '\0'],
            len: 1,
            pos: 0,
        }
    }
    fn two(a: char, b: char) -> Self {
        FoldIter {
            chars: [a, b],
            len: 2,
            pos: 0,
        }
    }
}

impl Iterator for FoldIter {
    type Item = char;
    fn next(&mut self) -> Option<char> {
        (self.pos < self.len).then(|| {
            self.pos += 1;
            self.chars[usize::from(self.pos - 1)]
        })
    }
}

/// Case-insensitively matches the lowercase ASCII `literal` at `chars[i..]`.
/// Returns the index after the match. As in ICU, a match may not end in the
/// middle of a character's case-folding expansion.
fn match_literal(chars: &[char], mut i: usize, literal: &str) -> Option<usize> {
    let mut expected = literal.chars().peekable();
    while expected.peek().is_some() {
        let c = *chars.get(i)?;
        i += 1;
        let mut folded = fold(c);
        for f in folded.by_ref() {
            if expected.next() != Some(f) {
                return None;
            }
            if expected.peek().is_none() {
                break;
            }
        }
        if folded.next().is_some() {
            // Literal ended inside an expansion (e.g. "pres" + "ß").
            return None;
        }
    }
    Some(i)
}

/// The rest of the pattern after the leading alternative, at `chars[i..]`.
fn matches_rest(chars: &[char], i: usize) -> bool {
    let Some(mut i) = match_literal(chars, i, "press") else {
        return false;
    };
    let gap_start = i;
    while chars.get(i).copied().is_some_and(is_gap) {
        i += 1;
    }
    if i == gap_start {
        return false;
    }
    let Some(i) = match_literal(chars, i, "enter") else {
        return false;
    };
    chars[i..].iter().all(|&c| is_tail(c))
}

/// Byte offset where the leftmost match starts, if any.
pub fn trailing_match_start(text: &str) -> Option<usize> {
    let indexed: Vec<(usize, char)> = text.char_indices().collect();
    let chars: Vec<char> = indexed.iter().map(|&(_, c)| c).collect();
    let mut i = 0;
    while i < chars.len() {
        // `^` alternative.
        if i == 0 && matches_rest(&chars, 0) {
            return Some(0);
        }
        if is_separator(chars[i]) {
            // A separator run cannot be followed by a shorter run that
            // matches: no separator folds to "p". So try the maximal run,
            // and skip the rest of it (later starts would not be leftmost).
            let mut j = i;
            while j < chars.len() && is_separator(chars[j]) {
                j += 1;
            }
            if matches_rest(&chars, j) {
                return Some(indexed[i].0);
            }
            i = j;
            continue;
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start(s: &str) -> Option<usize> {
        trailing_match_start(s)
    }

    #[test]
    fn leftmost_start() {
        assert_eq!(start("press enter"), Some(0));
        assert_eq!(start("Send it, press enter."), Some(7));
        assert_eq!(start("Send it; -  press enter"), Some(7));
        assert_eq!(start("press enter press enter"), Some(11));
        assert_eq!(start(", press enter"), Some(0));
    }

    #[test]
    fn rejects() {
        assert_eq!(start("express enter"), None);
        assert_eq!(start("press enter now"), None);
        assert_eq!(start("pressenter"), None);
        assert_eq!(start("a.press enter"), None);
        assert_eq!(start("a\u{A0}press enter"), None);
        assert_eq!(start("press\u{A0}enter"), None);
        assert_eq!(start("press enter 🙂"), None);
        assert_eq!(start(""), None);
    }

    #[test]
    fn icu_case_folding() {
        assert_eq!(start("PRESS ENTER"), Some(0));
        assert_eq!(start("pre\u{DF} enter"), Some(0));
        assert_eq!(start("PRE\u{1E9E} ENTER"), Some(0));
        assert_eq!(start("pre\u{17F}s enter"), Some(0));
        // "pres" + "ß" folds to "presss": the literal ends inside "ß".
        assert_eq!(start("pres\u{DF} enter"), None);
        // Dotted capital I and Kelvin sign fold to non-matching letters.
        assert_eq!(start("press \u{130}nter"), None);
    }

    #[test]
    fn tail_is_whitespace_or_punctuation() {
        assert_eq!(start("go, press enter!?\u{2026}"), Some(2));
        assert_eq!(start("go, press enter.\u{85}."), Some(2));
        assert_eq!(start("go, press enter.\u{301}"), None);
    }
}
