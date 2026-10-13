//! The shared word-boosting vectors (`linux/testdata/dictionary-vectors.json`)
//! for BPE encoding, entry validation, phrases, the bias graph and the
//! decision rule. The Swift app consumes the same file.

use lf_asr::BiasGraph;
use lf_asr::dictionary::{self, DictionaryEntry, EntryError};
use lf_asr::tokenizer::Tokenizer;
use lf_cpu::decoder::reference::token_decision;
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
    let pieces: Vec<String> = v["vocab"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_owned())
        .collect();
    assert!(pieces.len() <= 1024);
    Tokenizer::from_pieces(pieces).unwrap()
}

fn tokens(v: &Value) -> Vec<usize> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|t| t.as_u64().unwrap() as usize)
        .collect()
}

fn strength(v: &Value) -> f32 {
    v.as_f64().unwrap() as f32
}

fn phrases(v: &Value) -> Vec<(Vec<usize>, f32)> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| (tokens(&p["tokens"]), strength(&p["strength"])))
        .collect()
}

/// The state after `path` (-1 is blank, which keeps the state).
fn walk(g: &BiasGraph, path: &[Value]) -> u32 {
    path.iter()
        .fold(BiasGraph::ROOT, |s, t| match t.as_i64().unwrap() {
            -1 => s,
            t => g.step(s, t as usize).0,
        })
}

#[test]
fn constants_match() {
    let v = vectors();
    assert_eq!(v["version"], 1);
    let c = &v["constants"];
    assert_eq!(c["alpha"].as_f64(), Some(lf_cpu::bias::ALPHA));
    assert_eq!(
        c["context_score"].as_f64(),
        Some(lf_cpu::bias::CONTEXT_SCORE)
    );
    assert_eq!(
        c["depth_scaling"].as_f64(),
        Some(lf_cpu::bias::DEPTH_SCALING)
    );
    assert_eq!(c["blank"].as_u64(), Some(1024));
}

#[test]
fn encode_vectors() {
    let v = vectors();
    let t = tokenizer(&v);
    for case in section(&v, "encode") {
        let text = case["text"].as_str().unwrap();
        assert_eq!(t.encode(text), tokens(&case["tokens"]), "{text:?}");
    }
}

#[test]
fn validation_vectors() {
    let v = vectors();
    let t = tokenizer(&v);
    for case in section(&v, "validation") {
        let text = case["text"].as_str().unwrap();
        let s = case.get("strength").map_or(1.0, strength);
        let got = dictionary::validate(text, s, &t);
        if case["ok"].as_bool().unwrap() {
            let e = got.unwrap_or_else(|e| panic!("{text:?}: {e:?}"));
            assert_eq!(e.text, case["normalized"].as_str().unwrap(), "{text:?}");
            assert_eq!(e.strength, s);
        } else {
            let e: EntryError = got.err().unwrap_or_else(|| panic!("{text:?} validated"));
            assert_eq!(e.name(), case["error"].as_str().unwrap(), "{text:?}");
        }
    }
}

#[test]
fn phrase_vectors() {
    let v = vectors();
    let t = tokenizer(&v);
    for case in section(&v, "phrases") {
        let entries: Vec<DictionaryEntry> = case["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| DictionaryEntry {
                text: e["text"].as_str().unwrap().to_owned(),
                strength: strength(&e["strength"]),
            })
            .collect();
        assert_eq!(
            dictionary::phrases(&entries, &t),
            phrases(&case["phrases"]),
            "{}",
            case["name"]
        );
    }
}

#[test]
fn graph_vectors() {
    let v = vectors();
    for case in section(&v, "graph") {
        let g = BiasGraph::new(&phrases(&case["phrases"]), 1024).unwrap();
        for step in case["steps"].as_array().unwrap() {
            let s = walk(&g, step["path"].as_array().unwrap());
            let token = step["token"].as_u64().unwrap() as usize;
            let got = g.step(s, token).1;
            let want = step["bonus"].as_f64().unwrap() as f32;
            let ulps = (got.to_bits() as i64 - want.to_bits() as i64).abs();
            assert!(ulps <= 1, "{}: {step}: got {got}", case["name"]);
        }
    }
}

#[test]
fn decision_vectors() {
    let v = vectors();
    for case in section(&v, "decision") {
        let g = BiasGraph::new(&phrases(&case["phrases"]), 1024).unwrap();
        let path: Vec<Value> = case["path"].as_array().unwrap().clone();
        let state = walk(&g, &path);
        let mut logits = vec![-100.0f32; 1025];
        for (row, value) in case["logits"].as_object().unwrap() {
            logits[row.parse::<usize>().unwrap()] = strength(value);
        }
        assert_eq!(
            token_decision(&logits, Some(&g), state),
            case["expected_token"].as_u64().unwrap() as usize,
            "{}",
            case["name"]
        );
    }
}
