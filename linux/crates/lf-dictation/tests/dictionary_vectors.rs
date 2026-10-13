//! The shared word-boosting vectors (`linux/testdata/dictionary-vectors.json`)
//! for casing restoration, correction candidates and verification. The
//! Swift app consumes the same file.

use lf_asr::dictionary::DictionaryEntry;
use lf_asr::tokenizer::Tokenizer;
use lf_dictation::correction::{
    Candidate, CandidateKind, apply_casing, correction_candidates, verify_decision,
};
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../testdata/dictionary-vectors.json"
    );
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn section<'a>(v: &'a Value, name: &str) -> &'a [Value] {
    let s = v[name].as_array().unwrap();
    assert!(!s.is_empty(), "{name} is empty");
    s
}

fn tokenizer(v: &Value) -> Tokenizer {
    let pieces = v["vocab"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_owned())
        .collect();
    Tokenizer::from_pieces(pieces).unwrap()
}

fn texts(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|t| t.as_str().unwrap().to_owned())
        .collect()
}

fn entries(v: &Value) -> Vec<DictionaryEntry> {
    texts(v)
        .into_iter()
        .map(|text| DictionaryEntry {
            text,
            strength: 1.0,
        })
        .collect()
}

#[test]
fn casing_vectors() {
    let v = vectors();
    for case in section(&v, "casing") {
        let transcript = case["transcript"].as_str().unwrap();
        assert_eq!(
            apply_casing(transcript, &entries(&case["entries"])),
            case["expected"].as_str().unwrap(),
            "{transcript:?}"
        );
    }
}

fn describe(c: &Candidate) -> Value {
    serde_json::json!({
        "surface": c.surface,
        "kind": c.kind.name(),
        "before_range": [c.before_range.start, c.before_range.end],
        "before_words": c.before_words,
    })
}

#[test]
fn candidate_vectors() {
    let v = vectors();
    let t = tokenizer(&v);
    for case in section(&v, "candidates") {
        let before = case["before"].as_str().unwrap();
        let got = correction_candidates(
            before,
            case["after"].as_str().unwrap(),
            &entries(&case["dictionary"]),
            &texts(&case["ignore"]),
            &t,
        );
        let got: Vec<Value> = got.iter().map(describe).collect();
        assert_eq!(
            Value::Array(got),
            case["expected"],
            "{:?}",
            &before[..before.len().min(80)]
        );
    }
}

#[test]
fn verify_vectors() {
    let v = vectors();
    let t = tokenizer(&v);
    let strengths: Vec<f64> = v["constants"]["verify_strengths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_f64().unwrap())
        .collect();
    let key = |s: f64| match s {
        1.0 => "1.0",
        1.41 => "1.41",
        2.0 => "2.0",
        2.83 => "2.83",
        4.0 => "4.0",
        _ => unreachable!(),
    };
    for case in section(&v, "verify") {
        let name = case["name"].as_str().unwrap();
        let (base, before) = (
            case["B"].as_str().unwrap(),
            case["before"].as_str().unwrap(),
        );
        let cands = correction_candidates(before, case["after"].as_str().unwrap(), &[], &[], &t);
        let c = &cands[case["candidate_index"].as_u64().unwrap() as usize];
        let got = if c.kind == CandidateKind::Casing {
            Some(1.0)
        } else {
            strengths.iter().copied().find(|&s| {
                let n = case["N_by_strength"][key(s)].as_str().unwrap_or(base);
                verify_decision(base, before, c, n)
            })
        };
        assert_eq!(got, case["expected_strength"].as_f64(), "{name}");
    }
}
