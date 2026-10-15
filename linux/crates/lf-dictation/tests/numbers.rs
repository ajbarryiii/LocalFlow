//! Runs the shared vectors in `linux/testdata/number-vectors.json`, and
//! checks how spoken-number formatting composes with the rest of `process`.

use std::path::PathBuf;

use lf_dictation::{Options, VoiceMacro, format_spoken_numbers, process};
use serde_json::Value;

fn vectors() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/number-vectors.json");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let v: Value = serde_json::from_slice(&bytes).expect("vectors are valid JSON");
    assert_eq!(v["version"], 1);
    v
}

#[test]
fn number_vectors() {
    let v = vectors();
    let cases = v["format"].as_array().expect("format array");
    assert!(cases.len() >= 80);
    let mut failures = Vec::new();
    for (i, case) in cases.iter().enumerate() {
        let input = case["input"].as_str().expect("input");
        let expected = case["expected"].as_str().expect("expected");
        let got = format_spoken_numbers(input);
        if got != expected {
            failures.push(format!(
                "format[{i}] ({}) {input:?}: expected {expected:?}, got {got:?}",
                case["rule"]
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn options(spoken_numbers: bool) -> Options {
    Options {
        spoken_numbers,
        ..Options::default()
    }
}

#[test]
fn spoken_numbers_are_on_by_default() {
    assert!(Options::default().spoken_numbers);
    let r = process(
        "Step three takes twenty minutes.",
        &[],
        Options::default(),
        None,
    );
    assert_eq!(r.output, "Step 3 takes 20 minutes.");
    // The raw transcript is what was heard, before any formatting.
    assert_eq!(r.raw_transcript, "Step three takes twenty minutes.");
}

#[test]
fn disabled_spoken_numbers_leave_words() {
    let r = process(
        "Step three takes twenty minutes.",
        &[],
        options(false),
        None,
    );
    assert_eq!(r.output, "Step three takes twenty minutes.");
}

#[test]
fn macros_match_the_spoken_words_and_are_not_formatted() {
    let macros = [VoiceMacro {
        command: "Template twenty".into(),
        payload: "Synthetic payload with twenty words.".into(),
    }];
    let r = process("Template twenty.", &macros, Options::default(), None);
    assert!(
        r.used_macro,
        "a macro command with a number word must still match"
    );
    assert_eq!(r.output, "Synthetic payload with twenty words.");
}

#[test]
fn spoken_numbers_compose_with_delimiters_press_enter_and_the_prompt_tag() {
    let r = process(
        "Set quote twenty five percent end quote, press enter.",
        &[],
        Options::default(),
        Some("[dictated]"),
    );
    assert_eq!(r.output, "[dictated] Set \"25%\"");
    assert!(r.should_press_enter);
}
