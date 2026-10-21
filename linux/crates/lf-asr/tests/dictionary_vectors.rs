//! The shared word-boosting vectors (`linux/testdata/dictionary-vectors.json`)
//! for the bias graph and the decision rule. BPE encoding, entry validation,
//! keys and phrases run in `lf-text`. The Swift app consumes the same file.

use lf_asr::BiasGraph;
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
