//! The shared word-boosting vectors (`linux/testdata/dictionary-vectors.json`)
//! for BPE encoding, entry validation, keys and phrases. The bias graph and
//! decision rule sections run in `lf-asr`. The Swift app consumes the same
//! file.

use lf_text::dictionary::{self, DictionaryEntry, EntryError};
use lf_text::tokenizer::Tokenizer;
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
fn key_vectors() {
    let v = vectors();
    for case in section(&v, "keys") {
        let key = case["key"].as_str().unwrap();
        let shown = &key[..key.len().min(24)];
        assert_eq!(
            dictionary::valid_key(key),
            case["valid"].as_bool().unwrap(),
            "{shown:?}"
        );
        if let Some(from) = case.get("from") {
            assert_eq!(dictionary::fold(from.as_str().unwrap()), key, "{shown:?}");
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
