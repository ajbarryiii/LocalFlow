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

#[test]
fn process_vectors() {
    let v = vectors();
    let cases = v["process"].as_array().expect("process array");
    assert!(cases.len() >= 40);
    let mut failures = Vec::new();
    for (i, case) in cases.iter().enumerate() {
        let input = string(case, "input");
        let options = Options {
            press_enter: flag(case, "press_enter_enabled"),
            spoken_delimiters: flag(case, "spoken_delimiters_enabled"),
        };
        let result = process(&input, &macros(case), options, None);
        let expected = case["expected"].as_object().expect("expected object");
        assert!(!expected.is_empty(), "case {i} checks nothing");
        for (key, want) in expected {
            let ok = match key.as_str() {
                "raw" => want.as_str() == Some(result.raw_transcript.as_str()),
                "output" => want.as_str() == Some(result.output.as_str()),
                "press_enter" => want.as_bool() == Some(result.should_press_enter),
                "used_macro" => want.as_bool() == Some(result.used_macro),
                other => panic!("case {i}: unknown expected field {other}"),
            };
            if !ok {
                failures.push(format!(
                    "process[{i}] {input:?}: {key} expected {want}, got {result:?}"
                ));
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
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
        let on = process(&input, &[], Options::default(), None);
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
                press_enter: true,
                spoken_delimiters: false,
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
