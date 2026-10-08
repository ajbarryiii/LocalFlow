//! `SpokenDelimiterFormatter`: converts matched spoken delimiter pairs
//! ("quote … end quote", "open paren … close paren") into punctuation, and
//! "all caps on … all caps off" style pairs into a case change. A closer pairs
//! with the nearest opener of its kind; unmatched or empty pairs stay literal
//! text. An unmatched case command that opens the dictation ("All caps, do
//! not merge") applies to all of it.
//!
//! Words are split on whitespace `Character`s (grapheme clusters), and all
//! comparisons use Swift's canonical equivalence; see [`crate::swift`].

use std::collections::HashMap;
use std::sync::OnceLock;

use unicode_segmentation::UnicodeSegmentation;

use crate::swift;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Quote,
    Paren,
    Bracket,
    Brace,
    Backtick,
    Bold,
    Upper,
    Lower,
}

impl Kind {
    fn delimiters(self) -> (&'static str, &'static str) {
        match self {
            Kind::Quote => ("\"", "\""),
            Kind::Paren => ("(", ")"),
            Kind::Bracket => ("[", "]"),
            Kind::Brace => ("{", "}"),
            Kind::Backtick => ("`", "`"),
            Kind::Bold => ("**", "**"),
            Kind::Upper | Kind::Lower => ("", ""),
        }
    }

    fn changes_case(self) -> bool {
        matches!(self, Kind::Upper | Kind::Lower)
    }

    /// Only a quotation ("He said, "…"") or a case change reads naturally after a comma.
    fn keeps_comma_before(self) -> bool {
        self == Kind::Quote || self.changes_case()
    }

    fn apply_case(self, text: &str) -> String {
        if self == Kind::Upper {
            swift::uppercased(text)
        } else {
            swift::lowercased(text)
        }
    }
}

#[derive(Debug)]
struct Phrase {
    words: Vec<&'static str>,
    kind: Kind,
    opens: bool,
    /// The recognizer often hears "end" as "and"; that reading only closes an open pair.
    needs_opener: bool,
}

impl Phrase {
    /// Openers without an "open"/"begin"/"left" prefix can also be ordinary
    /// nouns ("the quote"). Case commands are never nouns.
    fn is_bare(&self) -> bool {
        self.opens
            && !self.kind.changes_case()
            && !matches!(self.words[0], "open" | "begin" | "left")
    }
}

struct Word<'a> {
    separator: &'a str,
    text: &'a str,
    /// Lowercased text without leading and trailing punctuation, in
    /// canonical (NFC) form for comparisons.
    core: String,
    has_leading_punctuation: bool,
    trailing: &'a str,
}

enum Item {
    Word(usize),
    /// A phrase (index into the phrase table) covering `words[start..end]`.
    Marker(usize, usize, usize),
}

const ENTRIES: &[(&str, Kind, bool)] = &[
    ("quote", Kind::Quote, true),
    ("open quote", Kind::Quote, true),
    ("begin quote", Kind::Quote, true),
    ("end quote", Kind::Quote, false),
    ("close quote", Kind::Quote, false),
    ("unquote", Kind::Quote, false),
    ("end of quote", Kind::Quote, false),
    ("open paren", Kind::Paren, true),
    ("open parenthesis", Kind::Paren, true),
    ("open parentheses", Kind::Paren, true),
    ("left paren", Kind::Paren, true),
    ("paren", Kind::Paren, true),
    ("parenthesis", Kind::Paren, true),
    ("parentheses", Kind::Paren, true),
    ("close paren", Kind::Paren, false),
    ("close parenthesis", Kind::Paren, false),
    ("close parentheses", Kind::Paren, false),
    ("end paren", Kind::Paren, false),
    ("right paren", Kind::Paren, false),
    ("open bracket", Kind::Bracket, true),
    ("open square bracket", Kind::Bracket, true),
    ("left bracket", Kind::Bracket, true),
    ("close bracket", Kind::Bracket, false),
    ("close square bracket", Kind::Bracket, false),
    ("end bracket", Kind::Bracket, false),
    ("right bracket", Kind::Bracket, false),
    ("open brace", Kind::Brace, true),
    ("open curly brace", Kind::Brace, true),
    ("open curly", Kind::Brace, true),
    ("left brace", Kind::Brace, true),
    ("close brace", Kind::Brace, false),
    ("close curly brace", Kind::Brace, false),
    ("close curly", Kind::Brace, false),
    ("end brace", Kind::Brace, false),
    ("right brace", Kind::Brace, false),
    ("backtick", Kind::Backtick, true),
    ("back tick", Kind::Backtick, true),
    ("open backtick", Kind::Backtick, true),
    ("open back tick", Kind::Backtick, true),
    ("end backtick", Kind::Backtick, false),
    ("end back tick", Kind::Backtick, false),
    ("close backtick", Kind::Backtick, false),
    ("close back tick", Kind::Backtick, false),
    ("double asterisk", Kind::Bold, true),
    ("open double asterisk", Kind::Bold, true),
    ("close double asterisk", Kind::Bold, false),
    ("end double asterisk", Kind::Bold, false),
    ("all caps on", Kind::Upper, true),
    ("all caps", Kind::Upper, true),
    ("all caps off", Kind::Upper, false),
    ("end all caps", Kind::Upper, false),
    ("all lowercase", Kind::Lower, true),
    ("all lower case", Kind::Lower, true),
    ("end lowercase", Kind::Lower, false),
    ("end lower case", Kind::Lower, false),
];

struct Table {
    phrases: Vec<Phrase>,
    /// Phrase indices keyed by first word, longest phrases first so "end
    /// quote" is never read as "end" plus an opening "quote".
    by_first_word: HashMap<&'static str, Vec<usize>>,
}

fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let parsed: Vec<Phrase> = ENTRIES
            .iter()
            .map(|&(text, kind, opens)| Phrase {
                words: text.split(' ').collect(),
                kind,
                opens,
                needs_opener: false,
            })
            .collect();
        let misheard: Vec<Phrase> = parsed
            .iter()
            .filter(|p| !p.opens && p.words[0] == "end")
            .map(|p| Phrase {
                words: std::iter::once("and")
                    .chain(p.words[1..].iter().copied())
                    .collect(),
                kind: p.kind,
                opens: false,
                needs_opener: true,
            })
            .collect();
        let mut phrases: Vec<Phrase> = parsed.into_iter().chain(misheard).collect();
        // Stable, like Swift's `sorted`.
        phrases.sort_by_key(|p| std::cmp::Reverse(p.words.len()));
        let mut by_first_word: HashMap<&'static str, Vec<usize>> = HashMap::new();
        for (i, p) in phrases.iter().enumerate() {
            by_first_word.entry(p.words[0]).or_default().push(i);
        }
        Table {
            phrases,
            by_first_word,
        }
    })
}

/// Recognizer punctuation dropped just inside a closing delimiter; "?" and "!" are kept.
fn stripped_before_closing(grapheme: &str) -> bool {
    [",", ";", ":", "."]
        .iter()
        .any(|p| swift::canonically_equal(grapheme, p))
}

/// A bare opener directly after one of these is a noun ("the quote"), never an opener.
const DETERMINERS: &[&str] = &[
    "a", "an", "the", "this", "that", "my", "your", "his", "her", "our", "their", "its",
];

/// The speech recognizer spells "paren" many ways (paran, peren, peran, perran, …):
/// `^p[ae]r{1,2}[ae]n$`.
fn recognizer_spelling(core: String) -> String {
    let b = core.as_bytes();
    let vowel = |c: u8| c == b'a' || c == b'e';
    let ok = match b.len() {
        5 => b[0] == b'p' && vowel(b[1]) && b[2] == b'r' && vowel(b[3]) && b[4] == b'n',
        6 => {
            b[0] == b'p'
                && vowel(b[1])
                && b[2] == b'r'
                && b[3] == b'r'
                && vowel(b[4])
                && b[5] == b'n'
        }
        _ => false,
    };
    if ok { "paren".to_owned() } else { core }
}

fn split_words(text: &str) -> Vec<Word<'_>> {
    let mut result = Vec::new();
    let mut separator_start = 0;
    let mut word_start: Option<usize> = None;
    for (offset, grapheme) in text.grapheme_indices(true) {
        if swift::grapheme_is_whitespace(grapheme) {
            if let Some(start) = word_start.take() {
                result.push(word(&text[separator_start..start], &text[start..offset]));
                separator_start = offset;
            }
        } else if word_start.is_none() {
            word_start = Some(offset);
        }
    }
    if let Some(start) = word_start {
        result.push(word(&text[separator_start..start], &text[start..]));
    }
    result
}

fn word<'a>(separator: &'a str, text: &'a str) -> Word<'a> {
    let graphemes: Vec<(usize, &str)> = text.grapheme_indices(true).collect();
    let first = graphemes
        .iter()
        .position(|&(_, g)| !swift::grapheme_is_punctuation(g))
        .unwrap_or(graphemes.len());
    let mut last = graphemes.len();
    while last > first && swift::grapheme_is_punctuation(graphemes[last - 1].1) {
        last -= 1;
    }
    let offset = |i: usize| graphemes.get(i).map_or(text.len(), |&(o, _)| o);
    let (start, end) = (offset(first), offset(last));
    let core = recognizer_spelling(swift::lowercased(&text[start..end]));
    Word {
        separator,
        text,
        core: swift::canonical(&core),
        has_leading_punctuation: start != 0,
        trailing: &text[end..],
    }
}

fn matches(phrase: &Phrase, index: usize, words: &[Word<'_>]) -> bool {
    if index + phrase.words.len() > words.len() {
        return false;
    }
    if phrase.is_bare()
        && index > 0
        && words[index - 1].trailing.is_empty()
        && DETERMINERS.contains(&words[index - 1].core.as_str())
    {
        return false;
    }
    phrase.words.iter().enumerate().all(|(offset, expected)| {
        let word = &words[index + offset];
        word.core == *expected
            && !word.has_leading_punctuation
            && (offset == phrase.words.len() - 1 || word.trailing.is_empty())
    })
}

/// `SpokenDelimiterFormatter.format`.
pub fn format(text: &str) -> String {
    let table = table();
    let words = split_words(text);
    let mut items: Vec<Item> = Vec::new();
    let mut paired: Vec<bool> = Vec::new();
    // Pairing happens during the scan so "and …" closers see exactly which
    // openers are still open. Entries are (item index, kind).
    let mut openers: Vec<(usize, Kind)> = Vec::new();
    let mut index = 0;
    while index < words.len() {
        let found = table
            .by_first_word
            .get(words[index].core.as_str())
            .and_then(|candidates| {
                candidates.iter().copied().find(|&p| {
                    let phrase = &table.phrases[p];
                    (!phrase.needs_opener || openers.iter().any(|&(_, k)| k == phrase.kind))
                        && matches(phrase, index, &words)
                })
            });
        let Some(p) = found else {
            items.push(Item::Word(index));
            paired.push(false);
            index += 1;
            continue;
        };
        let phrase = &table.phrases[p];
        let item_index = items.len();
        items.push(Item::Marker(p, index, index + phrase.words.len()));
        paired.push(false);
        index += phrase.words.len();
        if phrase.opens {
            openers.push((item_index, phrase.kind));
            continue;
        }
        while let Some(position) = openers.iter().rposition(|&(_, k)| k == phrase.kind) {
            let opener = openers[position].0;
            if opener + 1 == item_index {
                // Empty pairs stay literal. A bare opener may be a noun ("a
                // price quote, end quote"), so keep looking for an earlier
                // opener; otherwise the closer is spent.
                openers.remove(position);
                if let Item::Marker(op, _, _) = items[opener]
                    && table.phrases[op].is_bare()
                {
                    continue;
                }
                break;
            }
            paired[opener] = true;
            paired[item_index] = true;
            // Openers of another kind left inside the pair become literal text.
            openers.truncate(position);
            break;
        }
    }

    // A case command that opens the dictation and is still unclosed (not
    // paired, not part of a rejected empty pair) applies to all of it.
    let mut case_prefix: Option<Kind> = None;
    if items.len() > 1
        && openers.first().map(|&(item, _)| item) == Some(0)
        && let Item::Marker(p, _, _) = items[0]
        && table.phrases[p].opens
        && table.phrases[p].kind.changes_case()
    {
        case_prefix = Some(table.phrases[p].kind);
    }
    if !paired.contains(&true) && case_prefix.is_none() {
        return text.to_owned();
    }

    let mut output = String::with_capacity(text.len() + 8);
    let mut content_starts: Vec<usize> = Vec::new();
    let mut after_opening = false;
    let append = |output: &mut String, after_opening: &mut bool, word: &Word<'_>| {
        if !*after_opening {
            output.push_str(word.separator);
        }
        output.push_str(word.text);
        *after_opening = false;
    };
    for (item_index, item) in items.iter().enumerate() {
        if item_index == 0 && case_prefix.is_some() {
            after_opening = true;
            continue;
        }
        match *item {
            Item::Word(w) => append(&mut output, &mut after_opening, &words[w]),
            Item::Marker(p, start, end) => {
                if !paired[item_index] {
                    for word in &words[start..end] {
                        append(&mut output, &mut after_opening, word);
                    }
                    continue;
                }
                let phrase = &table.phrases[p];
                let (opening, closing) = phrase.kind.delimiters();
                if phrase.opens {
                    if !phrase.kind.keeps_comma_before()
                        && swift::last_grapheme(&output).is_some_and(|g| g == ",")
                    {
                        output.pop();
                    }
                    if !after_opening {
                        output.push_str(words[start].separator);
                    }
                    output.push_str(opening);
                    content_starts.push(output.len());
                    after_opening = true;
                } else {
                    let content_start = content_starts
                        .pop()
                        .expect("a paired closer always follows its opener");
                    while output.len() > content_start {
                        match swift::last_grapheme(&output) {
                            Some(g) if stripped_before_closing(g) => {
                                output.truncate(output.len() - g.len());
                            }
                            _ => break,
                        }
                    }
                    if phrase.kind.changes_case() {
                        // Swift replaces from the recorded UTF-8 offset, which
                        // is scalar-aligned, without rounding to a Character.
                        let changed = phrase.kind.apply_case(&output[content_start..]);
                        output.truncate(content_start);
                        output.push_str(&changed);
                    }
                    output.push_str(closing);
                    output.push_str(words[end - 1].trailing);
                }
            }
        }
    }
    match case_prefix {
        Some(kind) => kind.apply_case(&output),
        None => output,
    }
}
