//! `SpokenNumberFormatter`: writes spoken numbers as digits ("twenty three
//! stores" → "23 stores"). It is a small set of rules, not a grammar of
//! English; when a run of number words doesn't parse cleanly it stays as
//! words. The behaviour is pinned by `linux/testdata/number-vectors.json`.
//!
//! - Ten and up, and compound numbers, become digits. Thousands separators
//!   start at 10,000 (so "two thousand nine" reads as the year 2009), and a
//!   whole number of millions, billions or trillions keeps its word
//!   ("5 million"). A run starting with a scale word ("a hundred times")
//!   stays as words.
//! - Zero to nine stay as words, except in a comma-separated run ("1, 2,
//!   3"), after a label word ("step 3") or a capital letter ("Q3"), before a
//!   unit ("5 GB") or a capital letter ("5G"), after a month, or at either
//!   end of a range whose other end is digits ("5 to 15").
//! - Number words said in pairs: years ("nineteen eighty four" → 1984),
//!   runs of single digits ("four two seven nine" → 4279), and times before
//!   am/pm ("three thirty pm" → 3:30 PM).
//! - Decimals ("three point one four", "point five"), percent, dollars,
//!   cents and euros.
//! - Ordinals from tenth up ("21st"); first to ninth stay as words except
//!   after a month ("March 4th").
//!
//! Words are split on whitespace `Character`s, and leading and trailing
//! punctuation is kept as written. Number words never span punctuation.

use unicode_segmentation::UnicodeSegmentation;

use crate::swift;

const UNITS: [&str; 20] = [
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
];
const TENS: [&str; 8] = [
    "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
];
/// Scale words above a hundred, with their values.
const SCALES: [(&str, u64); 4] = [
    ("thousand", 1_000),
    ("million", 1_000_000),
    ("billion", 1_000_000_000),
    ("trillion", 1_000_000_000_000),
];
/// Scales that keep their word after a whole multiplier ("5 million").
const BIG_SCALES: [&str; 3] = ["million", "billion", "trillion"];
const UNIT_ORDINALS: [&str; 9] = [
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
];
/// Ordinals that always become digits, with their values.
const LARGE_ORDINALS: [(&str, u64); 18] = [
    ("tenth", 10),
    ("eleventh", 11),
    ("twelfth", 12),
    ("thirteenth", 13),
    ("fourteenth", 14),
    ("fifteenth", 15),
    ("sixteenth", 16),
    ("seventeenth", 17),
    ("eighteenth", 18),
    ("nineteenth", 19),
    ("twentieth", 20),
    ("thirtieth", 30),
    ("fortieth", 40),
    ("fiftieth", 50),
    ("sixtieth", 60),
    ("seventieth", 70),
    ("eightieth", 80),
    ("ninetieth", 90),
];
const MONTHS: [&str; 12] = [
    "january",
    "february",
    "march",
    "april",
    "may",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
];
/// Words after which a small number is a label: "step 3", "page 4".
const LABELS: &[&str] = &[
    "step", "steps", "version", "page", "pages", "line", "lines", "chapter", "section", "option",
    "item", "number", "issue", "level", "phase", "figure", "fig", "table", "slide", "slides",
    "grade", "part", "episode", "season", "volume", "vol", "row", "column", "exhibit", "appendix",
    "room", "gate", "platform", "floor",
];
/// Words before which a small number is a measurement: "5 GB", "3 feet".
const UNIT_WORDS: &[&str] = &[
    "percent",
    "percentage",
    "basis",
    "bps",
    "bytes",
    "byte",
    "kb",
    "mb",
    "gb",
    "tb",
    "kilobytes",
    "megabytes",
    "gigabytes",
    "terabytes",
    "bits",
    "kilobits",
    "megabits",
    "gigabits",
    "milliseconds",
    "ms",
    "microseconds",
    "nanoseconds",
    "hertz",
    "hz",
    "khz",
    "mhz",
    "ghz",
    "kilometers",
    "kilometres",
    "km",
    "meters",
    "metres",
    "centimeters",
    "cm",
    "millimeters",
    "mm",
    "miles",
    "mile",
    "feet",
    "foot",
    "inches",
    "inch",
    "kilograms",
    "kg",
    "grams",
    "pounds",
    "lbs",
    "tons",
    "tonnes",
    "ounces",
    "liters",
    "litres",
    "ml",
    "degrees",
    "volts",
    "watts",
    "kw",
    "kwh",
    "megawatts",
    "gigawatts",
    "amps",
    "pixels",
    "px",
    "cores",
    "threads",
    "cents",
    "cent",
    "dollars",
    "dollar",
    "bucks",
    "euros",
    "euro",
];
const CURRENCIES: [(&str, &str); 5] = [
    ("dollars", "$"),
    ("dollar", "$"),
    ("bucks", "$"),
    ("euros", "€"),
    ("euro", "€"),
];
/// After these, "point five" is a noun phrase, not 0.5: "a good point".
const POINT_NOUN_PREVIOUS: &[&str] = &[
    "a", "an", "the", "this", "that", "my", "your", "our", "their", "his", "her", "its", "good",
    "great", "fair", "valid", "main", "key", "next", "last", "first", "second", "one", "no",
    "each", "every", "some", "any", "which", "what", "another", "final",
];
/// Words that join the two ends of a range. "and" only does after "between".
const RANGE_WORDS: [&str; 3] = ["to", "through", "or"];

/// `SpokenNumberFormatter.format`.
pub fn format(text: &str) -> String {
    let (mut tokens, tail) = tokenize(text);
    if tokens.is_empty() {
        return text.to_owned();
    }
    rewrite_ordinals(&mut tokens);
    let mut pieces = number_spans(&tokens);
    choose_small_numbers(&mut pieces);
    attach_suffixes(&mut pieces);
    join_letters_and_months(&mut pieces);
    let mut out: String = pieces
        .iter()
        .map(|p| format!("{}{}{}{}", p.separator, p.lead, p.value, p.trail))
        .collect();
    out.push_str(tail);
    out
}

// MARK: Tokens

/// A whitespace-separated word as written.
#[derive(Clone, Debug)]
struct Token {
    separator: String,
    lead: String,
    core: String,
    trail: String,
}

impl Token {
    fn new(separator: &str, text: &str) -> Token {
        let (lead, core, trail) = split_punctuation(text);
        Token {
            separator: separator.to_owned(),
            lead: lead.to_owned(),
            core: core.to_owned(),
            trail: trail.to_owned(),
        }
    }

    fn lower(&self) -> String {
        swift::lowercased(&self.core)
    }

    fn text(&self) -> String {
        format!("{}{}{}", self.lead, self.core, self.trail)
    }
}

/// Splits `text` into words and the whitespace after the last word.
fn tokenize(text: &str) -> (Vec<Token>, &str) {
    let mut tokens = Vec::new();
    let (mut separator_start, mut word_start) = (0, None);
    for (offset, grapheme) in text.grapheme_indices(true) {
        let space = swift::grapheme_is_whitespace(grapheme);
        match (space, word_start) {
            (true, Some(start)) => {
                tokens.push(Token::new(
                    &text[separator_start..start],
                    &text[start..offset],
                ));
                separator_start = offset;
                word_start = None;
            }
            (false, None) => word_start = Some(offset),
            _ => {}
        }
    }
    match word_start {
        Some(start) => {
            tokens.push(Token::new(&text[separator_start..start], &text[start..]));
            (tokens, "")
        }
        None => (tokens, &text[separator_start..]),
    }
}

/// Leading punctuation, the word, and trailing punctuation.
fn split_punctuation(text: &str) -> (&str, &str, &str) {
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
    (&text[..start], &text[start..end], &text[end..])
}

// MARK: Number words

fn unit_value(word: &str) -> Option<u64> {
    UNITS.iter().position(|&w| w == word).map(|i| i as u64)
}

fn tens_value(word: &str) -> Option<u64> {
    TENS.iter()
        .position(|&w| w == word)
        .map(|i| 10 * (i as u64 + 2))
}

fn scale_value(word: &str) -> Option<u64> {
    SCALES.iter().find(|&&(w, _)| w == word).map(|&(_, v)| v)
}

fn is_number_word(word: &str) -> bool {
    word == "hundred"
        || word == "oh"
        || unit_value(word).is_some()
        || tens_value(word).is_some()
        || scale_value(word).is_some()
}

/// The token's number words ("twenty-three" is two), or `None` if it has any
/// other word.
fn number_words(token: &Token) -> Option<Vec<String>> {
    let lower = token.lower();
    let words: Vec<String> = lower.split('-').map(str::to_owned).collect();
    (!lower.is_empty() && words.iter().all(|w| is_number_word(w))).then_some(words)
}

fn single_digit(word: &str) -> Option<u64> {
    unit_value(word).filter(|&v| v < 10)
}

/// One cardinal number: "one hundred and thirty four thousand".
fn parse_cardinal<S: AsRef<str>>(words: &[S]) -> Option<u64> {
    #[derive(PartialEq)]
    enum Last {
        Unit,
        Teen,
        Tens,
        Hundred,
        Scale,
    }
    let (mut total, mut current, mut last) = (0u64, None::<u64>, None::<Last>);
    let mut largest_scale = u64::MAX;
    for (i, word) in words.iter().map(AsRef::as_ref).enumerate() {
        if word == "and" {
            if !matches!(last, Some(Last::Hundred | Last::Scale)) || i + 1 == words.len() {
                return None;
            }
        } else if let Some(v) = unit_value(word) {
            let after_units = matches!(last, Some(Last::Unit | Last::Teen));
            let after_tens = last == Some(Last::Tens) && (v >= 10 || v == 0);
            let lone_zero = v == 0 && (current.is_some() || total > 0 || words.len() > 1);
            if after_units || after_tens || lone_zero {
                return None;
            }
            current = Some(current.unwrap_or(0) + v);
            last = Some(if v >= 10 { Last::Teen } else { Last::Unit });
        } else if let Some(v) = tens_value(word) {
            if matches!(last, Some(Last::Unit | Last::Teen | Last::Tens)) {
                return None;
            }
            current = Some(current.unwrap_or(0) + v);
            last = Some(Last::Tens);
        } else if word == "hundred" {
            match current {
                Some(c) if c < 100 && last != Some(Last::Hundred) => current = Some(c * 100),
                _ => return None,
            }
            last = Some(Last::Hundred);
        } else {
            let scale = scale_value(word)?;
            match current {
                Some(c) if scale < largest_scale => total += c * scale,
                _ => return None,
            }
            current = None;
            largest_scale = scale;
            last = Some(Last::Scale);
        }
    }
    last.map(|_| total + current.unwrap_or(0))
}

/// 10 to 99 as written ("twenty one", "fifteen"), or "oh five" as "05".
fn two_digits<S: AsRef<str>>(words: &[S]) -> Option<String> {
    if let [oh, digit] = words
        && oh.as_ref() == "oh"
        && let Some(v) = single_digit(digit.as_ref()).filter(|&v| v > 0)
    {
        return Some(format!("0{v}"));
    }
    parse_cardinal(words)
        .filter(|v| (10..=99).contains(v))
        .map(|v| v.to_string())
}

/// "nineteen eighty four", "twenty twenty one", "twenty oh five". The first
/// half is 13 to 20, so "twelve thirty" isn't read as a year.
fn parse_year(words: &[String]) -> Option<String> {
    let century = parse_cardinal(&words[..1]).filter(|v| (13..=20).contains(v))?;
    let rest = two_digits(&words[1..])?;
    Some(format!("{century}{rest}"))
}

/// Two or more single digits: "four two seven nine", "four oh four".
fn parse_digit_run(words: &[String]) -> Option<String> {
    if words.len() < 2 || words[0] == "oh" || words[words.len() - 1] == "oh" {
        return None;
    }
    words
        .iter()
        .map(|w| {
            if w == "oh" {
                Some('0')
            } else {
                single_digit(w).map(|v| char::from(b'0' + v as u8))
            }
        })
        .collect()
}

/// An hour and minutes before am/pm: "three thirty", "ten oh five".
fn parse_time(words: &[String]) -> Option<String> {
    (1..words.len().min(3)).find_map(|split| {
        let hour = parse_cardinal(&words[..split]).filter(|h| (1..=12).contains(h))?;
        let minutes =
            two_digits(&words[split..]).filter(|m| m.parse::<u64>().is_ok_and(|m| m < 60))?;
        Some(format!("{hour}:{minutes}"))
    })
}

/// Thousands separators from 10,000 up.
fn group(v: u64) -> String {
    let digits = v.to_string();
    if v < 10_000 {
        return digits;
    }
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn ordinal_suffix(v: u64) -> &'static str {
    match (v % 10, v % 100) {
        (_, 11..=13) => "th",
        (1, _) => "st",
        (2, _) => "nd",
        (3, _) => "rd",
        _ => "th",
    }
}

/// A month name, except a lowercase "may", which is usually the verb.
fn is_month(word: &str) -> bool {
    word != "may" && MONTHS.contains(&swift::lowercased(word).as_str())
}

fn capitalized(word: &str) -> String {
    let mut chars = word.chars();
    chars.next().map_or_else(String::new, |c| {
        swift::uppercased(&c.to_string()) + chars.as_str()
    })
}

/// A single capital letter other than "A" and "I": "Q", "C", "G".
fn is_letter_label(word: &str) -> bool {
    word.len() == 1 && word.as_bytes()[0].is_ascii_uppercase() && word != "A" && word != "I"
}

// MARK: Ordinals

/// "twenty first" → "21st", "thirteenth" → "13th", and a month's day
/// ("march fourth" → "March 4th"). A tens word after another number word is
/// part of a year ("twenty twenty first quarter"), and "a tenth" is a
/// fraction.
fn rewrite_ordinals(tokens: &mut Vec<Token>) {
    let mut i = 0;
    while i < tokens.len() {
        let previous = (i > 0 && tokens[i - 1].trail.is_empty()).then(|| &tokens[i - 1]);
        let after_number = previous.is_some_and(|p| number_words(p).is_some());
        let lower = tokens[i].lower();
        if let Some(v) = lower
            .split_once('-')
            .and_then(|(tens, unit)| compound_ordinal(tens, unit))
        {
            if !after_number {
                tokens[i].core = ordinal(v);
            }
        } else if let Some(v) = (tokens[i].trail.is_empty()
            && tokens.get(i + 1).is_some_and(|next| next.lead.is_empty()))
        .then(|| compound_ordinal(&lower, &tokens[i + 1].lower()))
        .flatten()
        {
            if !after_number {
                let next = tokens.remove(i + 1);
                tokens[i].core = ordinal(v);
                tokens[i].trail = next.trail;
            }
        } else if let Some(&(_, v)) = LARGE_ORDINALS.iter().find(|&&(w, _)| w == lower) {
            let fraction =
                previous.is_some_and(|p| ["a", "an", "one", "per"].contains(&p.lower().as_str()));
            if !fraction {
                tokens[i].core = ordinal(v);
            }
        }
        i += 1;
    }
    // A month's day: "december 28th", "March fourth".
    for i in 1..tokens.len() {
        let (month, day) = (&tokens[i - 1], &tokens[i]);
        if !is_month(&month.core) || !month.trail.is_empty() || !day.lead.is_empty() {
            continue;
        }
        let lower = day.lower();
        let day = if let Some(n) = UNIT_ORDINALS.iter().position(|&w| w == lower) {
            ordinal(n as u64 + 1)
        } else if is_written_ordinal(&lower) {
            day.core.clone()
        } else {
            continue;
        };
        tokens[i].core = day;
        tokens[i - 1].core = capitalized(&tokens[i - 1].core);
    }
}

/// "twenty" + "first" → 21.
fn compound_ordinal(tens: &str, unit: &str) -> Option<u64> {
    let unit = UNIT_ORDINALS.iter().position(|&w| w == unit)? as u64 + 1;
    Some(tens_value(tens)? + unit)
}

fn ordinal(v: u64) -> String {
    format!("{v}{}", ordinal_suffix(v))
}

/// "28th", "1st".
fn is_written_ordinal(word: &str) -> bool {
    let digits = word.trim_end_matches(|c: char| c.is_ascii_alphabetic());
    let suffix = &word[digits.len()..];
    !digits.is_empty()
        && digits.bytes().all(|b| b.is_ascii_digit())
        && ["st", "nd", "rd", "th"].contains(&suffix)
}

// MARK: Number spans

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// Zero to nine, kept only in context.
    Small,
    /// Anything else written as digits.
    Other,
}

/// Output text: a word as written, or a run of number words written as
/// digits (`kind` is set and `original` holds the words).
#[derive(Clone, Debug)]
struct Piece {
    separator: String,
    lead: String,
    value: String,
    trail: String,
    kind: Option<Kind>,
    original: String,
}

impl Piece {
    fn word(token: &Token) -> Piece {
        Piece {
            separator: token.separator.clone(),
            lead: token.lead.clone(),
            value: token.core.clone(),
            trail: token.trail.clone(),
            kind: None,
            original: String::new(),
        }
    }

    fn lower(&self) -> String {
        swift::lowercased(&self.value)
    }

    /// Nothing is attached after the word.
    fn is_bare(&self) -> bool {
        self.trail.is_empty()
    }

    /// Digits written by the recognizer or by these rules: "42", "$5", "3:30".
    fn is_numeric(&self) -> bool {
        let digits = self.value.trim_start_matches(['$', '€']);
        self.kind.is_some()
            || (digits.starts_with(|c: char| c.is_ascii_digit())
                && digits
                    .chars()
                    .all(|c| c.is_ascii_digit() || ",.:".contains(c)))
    }
}

/// Replaces each run of number words with digits where it parses.
fn number_spans(tokens: &[Token]) -> Vec<Piece> {
    let mut pieces = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        let (mut words, mut end) = match number_words(token) {
            Some(words) => (words, i + 1),
            // "point five" → 0.5
            None if starts_bare_decimal(tokens, i) => (vec!["zero".to_owned()], i),
            None => {
                pieces.push(Piece::word(token));
                i += 1;
                continue;
            }
        };
        let mut decimals = None;
        while end < tokens.len()
            && (end == i || tokens[end - 1].trail.is_empty())
            && tokens[end].lead.is_empty()
        {
            let next = &tokens[end];
            let lower = next.lower();
            if let Some(more) = number_words(next) {
                let after_big_scale = words
                    .last()
                    .is_some_and(|w| BIG_SCALES.contains(&w.as_str()));
                if after_big_scale && !run_contains(tokens, end, &["hundred", "thousand"]) {
                    break; // "fifteen billion three year" is not 15,000,000,003
                }
                words.extend(more);
                end += 1;
            } else if let Some(after) = and_a_half(tokens, end) {
                // "twelve and a half percent" → 12.5%; "two and a half hours" stays.
                decimals = Some("5".to_owned());
                end = take_big_scale(tokens, after, &mut words);
                break;
            } else if lower == "and"
                && next.trail.is_empty()
                && words
                    .last()
                    .is_some_and(|w| w == "hundred" || scale_value(w).is_some())
                && tokens
                    .get(end + 1)
                    .is_some_and(|t| t.lead.is_empty() && number_words(t).is_some())
            {
                words.push("and".to_owned());
                end += 1;
            } else if lower == "point" && next.trail.is_empty() {
                let mut digits = String::new();
                let mut k = end + 1;
                while let Some(v) = tokens
                    .get(k)
                    .filter(|t| t.lead.is_empty())
                    .and_then(|t| single_digit(&t.lower()))
                {
                    digits.push(char::from(b'0' + v as u8));
                    k += 1;
                    if !tokens[k - 1].trail.is_empty() {
                        break;
                    }
                }
                if !digits.is_empty() {
                    decimals = Some(digits);
                    end = take_big_scale(tokens, k, &mut words);
                }
                break;
            } else {
                break;
            }
        }
        if end == i {
            // A lone "point" with no digits after it.
            pieces.push(Piece::word(token));
            i += 1;
            continue;
        }
        let before_am_pm = tokens[end - 1].trail.is_empty()
            && tokens
                .get(end)
                .is_some_and(|t| t.lead.is_empty() && is_am_pm(&t.lower()));
        let time = (before_am_pm && decimals.is_none())
            .then(|| parse_time(&words))
            .flatten()
            .map(|t| (t, Kind::Other));
        let Some((value, kind)) = time.or_else(|| render(&words, decimals.as_deref())) else {
            pieces.extend(tokens[i..end].iter().map(Piece::word));
            i = end;
            continue;
        };
        // "five G" → 5G, "four K" → 4K.
        if kind == Kind::Small
            && tokens[end - 1].trail.is_empty()
            && let Some(letter) = tokens
                .get(end)
                .filter(|t| t.lead.is_empty() && is_letter_label(&t.core))
        {
            pieces.push(Piece {
                separator: token.separator.clone(),
                lead: token.lead.clone(),
                value: format!("{value}{}", letter.core),
                trail: letter.trail.clone(),
                kind: None,
                original: String::new(),
            });
            i = end + 1;
            continue;
        }
        let original = tokens[i..end]
            .iter()
            .enumerate()
            .map(|(k, t)| {
                let separator = if k == 0 { "" } else { t.separator.as_str() };
                format!("{separator}{}", t.text())
            })
            .collect();
        pieces.push(Piece {
            separator: token.separator.clone(),
            lead: token.lead.clone(),
            value,
            trail: tokens[end - 1].trail.clone(),
            kind: Some(kind),
            original,
        });
        i = end;
    }
    pieces
}

/// "point five" with no whole number, unless it is a noun phrase ("a good
/// point five times").
fn starts_bare_decimal(tokens: &[Token], i: usize) -> bool {
    let token = &tokens[i];
    token.lower() == "point"
        && token.trail.is_empty()
        && tokens
            .get(i + 1)
            .is_some_and(|n| n.lead.is_empty() && single_digit(&n.lower()).is_some())
        && !(i > 0
            && tokens[i - 1].trail.is_empty()
            && POINT_NOUN_PREVIOUS.contains(&tokens[i - 1].lower().as_str()))
}

/// Whether the run of number words starting at `tokens[start]` contains one
/// of `needles`.
fn run_contains(tokens: &[Token], start: usize, needles: &[&str]) -> bool {
    for token in &tokens[start..] {
        let Some(words) = number_words(token) else {
            return false;
        };
        if words.iter().any(|w| needles.contains(&w.as_str())) {
            return true;
        }
        if !token.trail.is_empty() {
            return false;
        }
    }
    false
}

/// The index after "and a half" when a percent, scale or currency follows.
fn and_a_half(tokens: &[Token], at: usize) -> Option<usize> {
    let [and, a, half, next] = tokens.get(at..at + 4)? else {
        return None;
    };
    let follows = |w: &str| {
        w == "percent" || BIG_SCALES.contains(&w) || CURRENCIES.iter().any(|&(c, _)| c == w)
    };
    (and.lower() == "and"
        && a.lower() == "a"
        && half.lower() == "half"
        && [and, a, half].iter().all(|t| t.trail.is_empty())
        && [a, half, next].iter().all(|t| t.lead.is_empty())
        && follows(&next.lower()))
    .then_some(at + 3)
}

/// Takes a million/billion/trillion after a decimal: "22.7 million".
fn take_big_scale(tokens: &[Token], at: usize, words: &mut Vec<String>) -> usize {
    match tokens.get(at) {
        Some(t)
            if tokens[at - 1].trail.is_empty()
                && t.lead.is_empty()
                && BIG_SCALES.contains(&t.lower().as_str()) =>
        {
            words.push(t.lower());
            at + 1
        }
        _ => at,
    }
}

fn is_am_pm(word: &str) -> bool {
    matches!(word, "am" | "pm" | "a.m" | "p.m")
}

/// Digits for a run of number words, or `None` to leave the words.
fn render(words: &[String], decimals: Option<&str>) -> Option<(String, Kind)> {
    let scale = words
        .last()
        .filter(|w| BIG_SCALES.contains(&w.as_str()) && words.len() > 1);
    if let Some(decimals) = decimals {
        let whole = if scale.is_some() {
            &words[..words.len() - 1]
        } else {
            words
        };
        let head = if whole == ["zero"] {
            "0".to_owned()
        } else {
            group(parse_cardinal(whole)?)
        };
        let scale = scale.map_or(String::new(), |s| format!(" {s}"));
        return Some((format!("{head}.{decimals}{scale}"), Kind::Other));
    }
    if let Some(v) = parse_cardinal(words) {
        if words.len() == 1 && v < 10 {
            return Some((v.to_string(), Kind::Small));
        }
        if let Some(scale) = scale
            && let Some(head) = parse_cardinal(&words[..words.len() - 1]).filter(|&h| h < 1000)
        {
            return Some((format!("{head} {scale}"), Kind::Other));
        }
        return Some((group(v), Kind::Other));
    }
    parse_year(words)
        .or_else(|| parse_digit_run(words))
        .map(|v| (v, Kind::Other))
}

// MARK: Small numbers

/// Keeps a small number as digits only in context; the rest go back to words.
fn choose_small_numbers(pieces: &mut [Piece]) {
    let mut keep: Vec<bool> = (0..pieces.len())
        .map(|k| kept_before_ranges(pieces, k))
        .collect();
    // Both ends of a range: "one to two meters" → "1 to 2 meters".
    let mut changed = true;
    while changed {
        changed = false;
        for k in 0..pieces.len() {
            if pieces[k].kind == Some(Kind::Small)
                && !keep[k]
                && !after_article(pieces, k)
                && ((k >= 2 && in_range(pieces, &keep, k - 2, k))
                    || in_range(pieces, &keep, k, k + 2))
            {
                keep[k] = true;
                changed = true;
            }
        }
    }
    for (piece, keep) in pieces.iter_mut().zip(keep) {
        if piece.kind.is_some() && !keep {
            piece.lead.clear();
            piece.value = std::mem::take(&mut piece.original);
            piece.trail.clear();
            piece.kind = None;
        }
    }
}

/// Digits that stay digits: kept by these rules, or written by the recognizer.
fn is_digits(pieces: &[Piece], keep: &[bool], k: usize) -> bool {
    keep[k] || (pieces[k].kind.is_none() && pieces[k].is_numeric())
}

/// Whether `pieces[first]` and `pieces[second]` are the two ends of a range
/// ("five to fifteen", "between five and twelve") and one of them is digits.
fn in_range(pieces: &[Piece], keep: &[bool], first: usize, second: usize) -> bool {
    let joiner = first + 1;
    if second >= pieces.len()
        || !(pieces[first].kind.is_some() || pieces[first].is_numeric())
        || !(pieces[second].kind.is_some() || pieces[second].is_numeric())
        || !(is_digits(pieces, keep, first) || is_digits(pieces, keep, second))
        || !pieces[first].is_bare()
        || !pieces[joiner].is_bare()
        || !pieces[joiner].lead.is_empty()
        || !pieces[second].lead.is_empty()
    {
        return false;
    }
    let word = pieces[joiner].lower();
    RANGE_WORDS.contains(&word.as_str())
        || (word == "and"
            && first > 0
            && pieces[first - 1].is_bare()
            && pieces[first - 1].lower() == "between")
}

/// Whether `pieces[k]` stays as digits before ranges are considered.
fn kept_before_ranges(pieces: &[Piece], k: usize) -> bool {
    match pieces[k].kind {
        None => return false,
        Some(Kind::Other) => return true,
        Some(Kind::Small) => {}
    }
    if after_article(pieces, k) {
        return false;
    }
    let piece = &pieces[k];
    let previous = k.checked_sub(1).map(|p| &pieces[p]).filter(|p| p.is_bare());
    let next = pieces
        .get(k + 1)
        .filter(|n| piece.is_bare() && n.lead.is_empty());
    let label = previous.is_some_and(|p| {
        LABELS.contains(&p.lower().as_str()) || is_letter_label(&p.value) || is_month(&p.value)
    });
    let unit = next.is_some_and(|n| {
        let lower = n.lower();
        UNIT_WORDS.contains(&lower.as_str()) || is_am_pm(&lower)
    });
    // A list: "one, two, three", "five, 10 years".
    let number = |p: usize| {
        pieces
            .get(p)
            .is_some_and(|p| p.kind.is_some() || p.is_numeric())
    };
    let list = (k > 0 && number(k - 1) && pieces[k - 1].trail == ",")
        || (number(k + 1) && piece.trail == ",");
    label || unit || list
}

/// "a one", "an eight": never digits.
fn after_article(pieces: &[Piece], k: usize) -> bool {
    k > 0 && pieces[k - 1].is_bare() && ["a", "an"].contains(&pieces[k - 1].lower().as_str())
}

// MARK: Suffixes

/// Percent, currency, am/pm and cents.
fn attach_suffixes(pieces: &mut Vec<Piece>) {
    let mut k = 0;
    while k + 1 < pieces.len() {
        if !pieces[k].is_numeric() || !pieces[k].is_bare() || !pieces[k + 1].lead.is_empty() {
            k += 1;
            continue;
        }
        let lower = pieces[k + 1].lower();
        let symbol = CURRENCIES
            .iter()
            .find(|&&(w, _)| w == lower)
            .map(|&(_, s)| s);
        if lower == "percent" {
            let next = pieces.remove(k + 1);
            pieces[k].value.push('%');
            pieces[k].trail = next.trail;
        } else if let Some(symbol) = symbol
            && !pieces[k].value.starts_with(['$', '€'])
        {
            let next = pieces.remove(k + 1);
            let value = &pieces[k].value;
            // Money groups thousands: $5,000.
            let value = if value.len() == 4 && value.bytes().all(|b| b.is_ascii_digit()) {
                format!("{},{}", &value[..1], &value[1..])
            } else {
                value.clone()
            };
            pieces[k].value = format!("{symbol}{value}");
            pieces[k].trail = next.trail;
        } else if is_am_pm(&lower) && is_clock_time(&pieces[k].value) {
            let next = pieces.remove(k + 1);
            let mut trail = next.trail;
            // The period of "p.m." ends a sentence only at the end or before a capital.
            if lower.contains('.') && trail.starts_with('.') {
                let sentence_ends = pieces.get(k + 1).is_none_or(|p| {
                    p.lead.is_empty() && p.value.chars().next().is_some_and(char::is_uppercase)
                });
                if !sentence_ends {
                    trail.remove(0);
                }
            }
            let suffix = if lower.starts_with('p') { "PM" } else { "AM" };
            pieces[k].value = format!("{} {suffix}", pieces[k].value);
            pieces[k].trail = trail;
        }
        k += 1;
    }
    attach_cents(pieces);
}

/// "3", "11", "3:30": an hour from 1 to 12, with optional minutes.
fn is_clock_time(value: &str) -> bool {
    let (hour, minutes) = value.split_once(':').unwrap_or((value, "00"));
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    digits(hour)
        && hour.len() <= 2
        && digits(minutes)
        && minutes.len() == 2
        && hour.parse::<u64>().is_ok_and(|h| (1..=12).contains(&h))
}

/// "$2 and 37 cents" → "$2.37".
fn attach_cents(pieces: &mut Vec<Piece>) {
    let digits =
        |s: &str, max: usize| (1..=max).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit());
    let mut k = 0;
    while k < pieces.len() {
        let whole_dollars = pieces[k].is_bare()
            && pieces[k]
                .value
                .strip_prefix('$')
                .is_some_and(|d| digits(d, usize::MAX));
        let and = usize::from(
            pieces
                .get(k + 1)
                .is_some_and(|p| p.is_bare() && p.lower() == "and"),
        );
        let (cents, word) = (k + 1 + and, k + 2 + and);
        let attach = whole_dollars
            && pieces
                .get(cents)
                .is_some_and(|p| p.is_bare() && p.lead.is_empty() && digits(&p.value, 2))
            && pieces.get(word).is_some_and(|p| {
                p.lead.is_empty() && ["cents", "cent"].contains(&p.lower().as_str())
            });
        if attach {
            let cents_value: u64 = pieces[cents].value.parse().unwrap_or(0);
            let trail = pieces[word].trail.clone();
            pieces[k].value = format!("{}.{cents_value:02}", pieces[k].value);
            pieces[k].trail = trail;
            pieces.drain(k + 1..=word);
        }
        k += 1;
    }
}

// MARK: Letters and months

/// "Q 3" → "Q3", and a month before digits is capitalized.
fn join_letters_and_months(pieces: &mut [Piece]) {
    for k in 1..pieces.len() {
        if pieces[k].kind.is_none() || !pieces[k - 1].is_bare() || !pieces[k].lead.is_empty() {
            continue;
        }
        let plain_digits = pieces[k].value.bytes().all(|b| b.is_ascii_digit());
        if is_letter_label(&pieces[k - 1].value) && pieces[k - 1].lead.is_empty() && plain_digits {
            pieces[k].separator.clear();
        } else if is_month(&pieces[k - 1].value) {
            pieces[k - 1].value = capitalized(&pieces[k - 1].value);
        }
    }
}
