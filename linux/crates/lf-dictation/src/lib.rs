//! Deterministic post-processing of a transcript: a port of
//! `Sources/LocalDictationCore.swift` (`LocalDictationCore` and
//! `SpokenDelimiterFormatter`).
//!
//! Dictated instructions are always text; nothing here interprets them beyond
//! the fixed commands below. The behaviour is pinned by the shared vectors in
//! `linux/testdata/dictation-vectors.json`, which the Swift tests also run;
//! its `prompt_tag` section pins the prompt tag (Hold to Prompt).
//!
//! [`correction`] (custom dictionary) uses the dictionary text rules and the
//! BPE tokenizer from the leaf crate `lf-text`; this crate does not depend on
//! the recognition stack (`lf-asr`, `lf-cpu`, `lf-model`).

pub mod correction;
mod delimiters;
mod numbers;
mod press_enter;
pub mod swift;

pub use delimiters::format as format_spoken_delimiters;
pub use numbers::format as format_spoken_numbers;

/// A whole-phrase voice macro: dictating `command` (ignoring case,
/// punctuation and surrounding whitespace) types `payload` instead.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VoiceMacro {
    pub command: String,
    pub payload: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Options {
    /// Strip a trailing "press enter" and press Return after typing.
    pub press_enter: bool,
    /// Convert "quote … end quote" style pairs into punctuation.
    pub spoken_delimiters: bool,
    /// Write spoken numbers as digits ("twenty three" → "23").
    pub spoken_numbers: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            press_enter: true,
            spoken_delimiters: true,
            spoken_numbers: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DictationResult {
    /// The trimmed transcript with any trailing "press enter" removed.
    pub raw_transcript: String,
    /// Text to type.
    pub output: String,
    pub should_press_enter: bool,
    pub used_macro: bool,
    /// The prompt tag was put before the output.
    pub added_prompt_tag: bool,
}

/// `LocalDictationCore.process`.
///
/// `prompt_tag` (Hold to Prompt) is put before dictated output, separated by
/// a space, so an AI agent receiving it knows it came from speech-to-text.
/// It is trimmed; an empty or whitespace-only tag adds nothing. Macro
/// payloads are the user's own saved text, and empty output is never typed,
/// so neither is tagged.
pub fn process(
    transcript: &str,
    macros: &[VoiceMacro],
    options: Options,
    prompt_tag: Option<&str>,
) -> DictationResult {
    let mut raw = swift::trim(transcript);
    let mut should_press_enter = false;
    // The match is applied even when it starts inside a `Character` (after a
    // Prepend scalar such as U+0600): on macOS 15 and later,
    // `Range(match.range, in: raw)` accepts any Unicode scalar boundary and
    // `removeSubrange` removes exactly those scalars. The match start is
    // always a scalar boundary, so slicing at it is that behaviour.
    if options.press_enter
        && let Some(start) = press_enter::trailing_match_start(raw)
    {
        raw = swift::trim(&raw[..start]);
        should_press_enter = true;
    }
    let normalized = normalize(raw);
    let used = if normalized.is_empty() {
        None
    } else {
        macros
            .iter()
            .find(|m| swift::canonically_equal(&normalize(&m.command), &normalized))
    };
    let output = match used {
        Some(m) => swift::trim(&m.payload).to_owned(),
        None => {
            let dictated = if options.spoken_numbers {
                numbers::format(raw)
            } else {
                raw.to_owned()
            };
            if options.spoken_delimiters {
                swift::trim(&delimiters::format(&dictated)).to_owned()
            } else {
                dictated
            }
        }
    };
    let tag = match prompt_tag {
        Some(t) if used.is_none() && !output.is_empty() => swift::trim(t),
        _ => "",
    };
    DictationResult {
        raw_transcript: raw.to_owned(),
        output: if tag.is_empty() {
            output
        } else {
            format!("{tag} {output}")
        },
        should_press_enter,
        used_macro: used.is_some(),
        added_prompt_tag: !tag.is_empty(),
    }
}

/// Whether a macro with this command can ever match: its normalized form
/// must be non-empty (Swift never matches an empty normalized transcript).
pub fn command_can_match(command: &str) -> bool {
    !normalize(command).is_empty()
}

/// `text.lowercased().components(separatedBy: .punctuationCharacters).joined()
/// .trimmingCharacters(in: .whitespacesAndNewlines)`.
fn normalize(text: &str) -> String {
    let lowered = swift::lowercased(text);
    let stripped: String = lowered
        .chars()
        .filter(|&c| !swift::is_punctuation(c))
        .collect();
    swift::trim(&stripped).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_matches_swift() {
        assert_eq!(normalize("  Blue, Bird!  "), "blue bird");
        assert_eq!(normalize("Blue-Bird"), "bluebird");
        assert_eq!(normalize("!!!"), "");
        // Punctuation removal can expose whitespace that is then trimmed.
        assert_eq!(normalize(". Hi ."), "hi");
        assert_eq!(normalize("ΟΔΟΣ"), "οδοσ");
    }

    fn tagged(transcript: &str, macros: &[VoiceMacro], tag: Option<&str>) -> DictationResult {
        process(transcript, macros, Options::default(), tag)
    }

    /// Port of `runPromptTagTests` (Tests/LocalDictationTests.swift).
    #[test]
    fn prompt_tag_matches_swift() {
        let t = tagged("  Rename the helper.  ", &[], Some("  [dictated]  "));
        assert_eq!(t.output, "[dictated] Rename the helper.");
        assert_eq!(t.raw_transcript, "Rename the helper.");
        assert!(t.added_prompt_tag, "a prompt dictation must report its tag");

        let plain = tagged("Rename the helper.", &[], None);
        assert_eq!(plain.output, "Rename the helper.");
        assert!(!plain.added_prompt_tag);
        let blank = tagged("Rename the helper.", &[], Some("   "));
        assert_eq!(blank.output, "Rename the helper.");
        assert!(!blank.added_prompt_tag);

        let formatted = tagged(
            "Run quote make check end quote, press enter.",
            &[],
            Some("[dictated]"),
        );
        assert_eq!(formatted.output, "[dictated] Run \"make check\"");
        assert!(
            formatted.should_press_enter,
            "the prompt tag must compose with press enter"
        );

        let enter_only = tagged("Press enter.", &[], Some("[dictated]"));
        assert_eq!(enter_only.output, "");
        assert!(enter_only.should_press_enter);
        assert!(
            !enter_only.added_prompt_tag,
            "a tag alone must never be typed"
        );

        let macros = [VoiceMacro {
            command: "Blue bird".into(),
            payload: "Synthetic saved prompt.".into(),
        }];
        let m = tagged("Blue bird", &macros, Some("[dictated]"));
        assert_eq!(m.output, "Synthetic saved prompt.");
        assert!(
            !m.added_prompt_tag,
            "macro payloads are saved text, not speech-to-text"
        );
    }

    #[test]
    fn prompt_tag_edge_cases() {
        // Without spoken delimiters the raw text is tagged the same way.
        let off = Options {
            spoken_delimiters: false,
            ..Options::default()
        };
        let r = process("Synthetic words", &[], off, Some("[dictated]"));
        assert_eq!(r.output, "[dictated] Synthetic words");
        // Empty transcripts stay empty.
        assert_eq!(tagged("   ", &[], Some("[dictated]")).output, "");
        // Inner whitespace of the tag is kept; only its ends are trimmed.
        assert_eq!(
            tagged("Synthetic.", &[], Some("\t[voice  note]\n")).output,
            "[voice  note] Synthetic."
        );
    }
}
