//! Runs the shared vectors in `linux/testdata/dictation-vectors.json`.

use std::path::PathBuf;

use lf_dictation::{Options, VoiceMacro, process};
use serde_json::Value;

fn vectors() -> Value {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/dictation-vectors.json");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let v: Value = serde_json::from_slice(&bytes).expect("vectors are valid JSON");
    assert_eq!(v["version"], 1);
    v
}

fn string(v: &Value, key: &str) -> String {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("missing string {key}"))
        .to_owned()
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).is_none_or(|b| b.as_bool().expect("boolean"))
}

fn macros(v: &Value) -> Vec<VoiceMacro> {
    v.get("macros")
        .map(|m| {
            m.as_array()
                .expect("macros array")
                .iter()
                .map(|m| VoiceMacro {
                    command: string(m, "command"),
                    payload: string(m, "payload"),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Runs a section with the `process` case schema; `prompt_tag` defaults to
/// none.
fn run_process_section(section: &str, min_cases: usize) {
    let v = vectors();
    let cases = v[section]
        .as_array()
        .unwrap_or_else(|| panic!("{section} array"));
    assert!(cases.len() >= min_cases, "{section} vectors are incomplete");
    let mut failures = Vec::new();
    for (i, case) in cases.iter().enumerate() {
        let input = string(case, "input");
        let options = Options {
            press_enter: flag(case, "press_enter_enabled"),
            spoken_delimiters: flag(case, "spoken_delimiters_enabled"),
            spoken_numbers: flag(case, "spoken_numbers_enabled"),
        };
        let tag = case
            .get("prompt_tag")
            .map(|t| t.as_str().expect("prompt_tag string"));
        let result = process(&input, &macros(case), options, tag);
        let expected = case["expected"].as_object().expect("expected object");
        assert!(!expected.is_empty(), "{section}[{i}] checks nothing");
        for (key, want) in expected {
            let ok = match key.as_str() {
                "raw" => want.as_str() == Some(result.raw_transcript.as_str()),
                "output" => want.as_str() == Some(result.output.as_str()),
                "press_enter" => want.as_bool() == Some(result.should_press_enter),
                "used_macro" => want.as_bool() == Some(result.used_macro),
                "added_prompt_tag" => want.as_bool() == Some(result.added_prompt_tag),
                // `LocalDictationResult.status` is the macOS pipeline-history
                // label; lf-dictation has no status string. The Swift suite
                // checks it.
                "status" => {
                    assert!(want.is_string(), "{section}[{i}]: status must be a string");
                    true
                }
                other => panic!("{section}[{i}]: unknown expected field {other}"),
            };
            if !ok {
                failures.push(format!(
                    "{section}[{i}] {input:?}: {key} expected {want}, got {result:?}"
                ));
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn process_vectors() {
    run_process_section("process", 40);
}

#[test]
fn prompt_tag_vectors() {
    run_process_section("prompt_tag", 10);
}

#[test]
fn spoken_delimiter_vectors() {
    let v = vectors();
    let cases = v["spoken_delimiters"]
        .as_array()
        .expect("spoken_delimiters array");
    assert!(cases.len() >= 100);
    let swift = cases.iter().filter(|c| c["origin"] == "swift").count();
    assert_eq!(swift, 86, "every Swift delimiter case is ported");
    let mut failures = Vec::new();
    for (i, case) in cases.iter().enumerate() {
        let input = string(case, "input");
        let expected = string(case, "expected");
        let disabled = case
            .get("expected_disabled")
            .map_or(input.clone(), |d| d.as_str().expect("string").to_owned());
        // Spoken numbers are pinned by number-vectors.json; these vectors
        // test delimiters alone.
        let delimiters_only = Options {
            spoken_numbers: false,
            ..Options::default()
        };
        let on = process(&input, &[], delimiters_only, None);
        if on.output != expected {
            failures.push(format!(
                "delimiters[{i}] {input:?}: expected {expected:?}, got {:?}",
                on.output
            ));
        }
        let off = process(
            &input,
            &[],
            Options {
                spoken_delimiters: false,
                ..delimiters_only
            },
            None,
        );
        if off.output != disabled {
            failures.push(format!(
                "delimiters[{i}] disabled {input:?}: expected {disabled:?}, got {:?}",
                off.output
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
