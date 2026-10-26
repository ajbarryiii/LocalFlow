//! Runs the shared vectors in `linux/testdata/chunking-vectors.json`, whose
//! expected values come from the Swift reference.

use std::convert::Infallible;
use std::path::PathBuf;

use lf_chunk::{
    CHUNK_OVERLAP_SAMPLES, CHUNK_SAMPLES, Chunk, ChunkedTranscription, Chunker,
    SAMPLES_PER_ENCODER_FRAME, SilenceCompactor, TranscriptAssembler, Word, words,
};
use serde_json::Value;

fn vectors() -> Value {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../testdata/chunking-vectors.json");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let v: Value = serde_json::from_slice(&bytes).expect("vectors are valid JSON");
    assert_eq!(v["version"], 1);
    v
}

fn section<'a>(v: &'a Value, name: &str) -> &'a [Value] {
    let s = v[name].as_array().unwrap();
    assert!(!s.is_empty(), "{name} is empty");
    s
}

fn int(v: &Value) -> usize {
    v.as_u64().unwrap() as usize
}

fn name(v: &Value) -> &str {
    v["name"].as_str().unwrap()
}

fn pairs(v: &Value) -> Vec<[usize; 2]> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| [int(&p[0]), int(&p[1])])
        .collect()
}

fn patterns(v: &Value) -> Vec<Vec<usize>> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_array().unwrap().iter().map(int).collect())
        .collect()
}

/// The file's signal descriptions, generated with the same exact arithmetic
/// as the Swift test.
fn signal(v: &Value) -> Vec<f32> {
    let mut out = Vec::new();
    for seg in v.as_array().unwrap() {
        let n = int(&seg[1]);
        match seg[0].as_str().unwrap() {
            "zeros" => out.extend(std::iter::repeat_n(0.0f32, n)),
            "nan" => out.extend(std::iter::repeat_n(f32::NAN, n)),
            "constant" => out.extend(std::iter::repeat_n(seg[2].as_f64().unwrap() as f32, n)),
            "square" => {
                let a = seg[2].as_f64().unwrap() as f32;
                let half = int(&seg[3]) / 2;
                out.extend((0..n).map(|i| if (i / half) % 2 == 0 { a } else { -a }));
            }
            "noise" => {
                let a = seg[2].as_f64().unwrap() as f32;
                let mut x = seg[3].as_u64().unwrap();
                for _ in 0..n {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    out.push(((x >> 32) as u32 as i32) as f32 / 2_147_483_648.0 * a);
                }
            }
            kind => panic!("unknown signal segment {kind}"),
        }
    }
    out
}

/// Appends of the pattern's sizes, repeated until the input is used up.
fn split<'a>(samples: &'a [f32], pattern: &[usize]) -> Vec<&'a [f32]> {
    if pattern.is_empty() {
        return if samples.is_empty() {
            vec![]
        } else {
            vec![samples]
        };
    }
    let mut parts = Vec::new();
    let mut rest = samples;
    for &n in pattern.iter().cycle() {
        if rest.is_empty() {
            break;
        }
        let (part, tail) = rest.split_at(n.min(rest.len()));
        parts.push(part);
        rest = tail;
    }
    parts
}

fn same(a: &[f32], b: &[f32]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.to_bits() == y.to_bits())
}

fn word_list(v: &Value) -> Vec<Word> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|w| Word {
            text: w[0].as_str().unwrap().to_owned(),
            start: int(&w[1]),
        })
        .collect()
}

/// The file's fake recognizer: a word at every multiple of `every`, the
/// chunk's first capitalized and its last ending in "."; none for silence.
fn fake_words(chunk: &Chunk, every: usize) -> Vec<Word> {
    if chunk.samples.iter().all(|&s| s == 0.0) {
        return vec![];
    }
    let mut words: Vec<Word> = chunk
        .range()
        .filter(|p| p % every == 0)
        .map(|p| Word {
            text: format!("w{}", p / every),
            start: p,
        })
        .collect();
    if let Some(first) = words.first_mut() {
        first.text.replace_range(..1, "W");
    }
    if let Some(last) = words.last_mut() {
        last.text.push('.');
    }
    words
}

#[test]
fn constants() {
    let v = vectors();
    let c = &v["constants"];
    assert_eq!(int(&c["sample_rate"]), lf_chunk::SAMPLE_RATE);
    assert_eq!(int(&c["chunk_samples"]), CHUNK_SAMPLES);
    assert_eq!(int(&c["chunk_overlap_samples"]), CHUNK_OVERLAP_SAMPLES);
    assert_eq!(
        int(&c["samples_per_encoder_frame"]),
        SAMPLES_PER_ENCODER_FRAME
    );
    assert_eq!(
        int(&c["alignment_tolerance"]),
        TranscriptAssembler::ALIGNMENT_TOLERANCE
    );
    assert_eq!(int(&c["compactor_margin"]), SilenceCompactor::DEFAULT_MARGIN);
    assert_eq!(
        int(&c["compactor_interior_pause"]),
        SilenceCompactor::DEFAULT_INTERIOR_PAUSE
    );
    assert_eq!(
        int(&c["compactor_max_piece_samples"]),
        SilenceCompactor::MAX_PIECE_SAMPLES
    );
    assert_eq!(
        int(&c["compactor_frame_samples"]),
        SilenceCompactor::FRAME_SAMPLES
    );
}

#[test]
fn compactor() {
    let v = vectors();
    let reads = patterns(&v["compactor_reads"]);
    for item in section(&v, "compactor") {
        let input = signal(&item["signal"]);
        let mut expected = Vec::new();
        for [s, e] in pairs(&item["kept"]) {
            expected.extend_from_slice(&input[s..e]);
        }
        assert_eq!(expected.len(), int(&item["output_samples"]));
        let margin = item
            .get("margin")
            .map_or(SilenceCompactor::DEFAULT_MARGIN, int);
        let pause = item
            .get("interior_pause")
            .map_or(SilenceCompactor::DEFAULT_INTERIOR_PAUSE, int);
        for pattern in &reads {
            let mut compactor = SilenceCompactor::new(margin, pause);
            let mut output = Vec::new();
            let mut emit = |piece: &[f32]| -> Result<(), Infallible> {
                assert!(
                    !piece.is_empty() && piece.len() <= SilenceCompactor::MAX_PIECE_SAMPLES,
                    "compactor {}: unbounded piece",
                    name(item)
                );
                output.extend_from_slice(piece);
                Ok(())
            };
            for part in split(&input, pattern) {
                compactor.append(part, &mut emit).unwrap();
            }
            compactor.finish(&mut emit).unwrap();
            assert!(
                same(&output, &expected),
                "compactor {} reads {pattern:?}",
                name(item)
            );
        }
    }
}

#[test]
fn chunker() {
    let v = vectors();
    let reads = patterns(&v["chunker_reads"]);
    for item in section(&v, "chunker") {
        let input: Vec<f32> = (0..int(&item["total"])).map(|i| i as f32).collect();
        for pattern in &reads {
            let mut chunker = Chunker::new(int(&item["size"]), int(&item["overlap"]));
            let mut chunks = Vec::new();
            let mut emit = |chunk: &Chunk| -> Result<(), Infallible> {
                assert!(same(chunk.samples, &input[chunk.range()]), "{}", name(item));
                chunks.push([chunk.start, chunk.samples.len()]);
                Ok(())
            };
            for part in split(&input, pattern) {
                chunker.append(part, &mut emit).unwrap();
            }
            chunker.finish(&mut emit).unwrap();
            assert_eq!(
                chunks,
                pairs(&item["chunks"]),
                "chunker {} reads {pattern:?}",
                name(item)
            );
        }
    }
}

#[test]
fn words_from_tokens() {
    let v = vectors();
    let vocab: Vec<String> = v["words"]["vocab"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_owned())
        .collect();
    let cases = v["words"]["cases"].as_array().unwrap();
    assert!(!cases.is_empty());
    for item in cases {
        let tokens: Vec<(usize, usize)> = pairs(&item["tokens"])
            .into_iter()
            .map(|[id, frame]| (id, frame))
            .collect();
        let result = words(&tokens, &vocab, int(&item["offset"]));
        if item.get("error").is_some_and(|e| e.as_bool().unwrap()) {
            assert!(result.is_err(), "words {} must fail", name(item));
        } else {
            let got = result.unwrap_or_else(|_| panic!("words {}", name(item)));
            assert!(
                got == word_list(&item["words"]),
                "words {}: got {:?}",
                name(item),
                got.iter().map(|w| (&w.text, w.start)).collect::<Vec<_>>()
            );
        }
    }
}

#[test]
fn assembler() {
    let v = vectors();
    for item in section(&v, "assembler") {
        let mut assembler = TranscriptAssembler::default();
        for append in item["appends"].as_array().unwrap() {
            let r = &append["range"];
            assembler.append(word_list(&append["words"]), int(&r[0])..int(&r[1]));
        }
        assert_eq!(
            assembler.text(),
            item["text"].as_str().unwrap(),
            "assembler {}",
            name(item)
        );
    }
}

#[test]
fn transcription() {
    let v = vectors();
    let reads = patterns(&v["transcription_reads"]);
    for item in section(&v, "transcription") {
        let input = signal(&item["signal"]);
        let every = int(&item["every"]);
        for pattern in &reads {
            let mut transcription = if item["compact"].as_bool().unwrap() {
                ChunkedTranscription::recording()
            } else {
                ChunkedTranscription::new(
                    item.get("size").map_or(CHUNK_SAMPLES, int),
                    item.get("overlap").map_or(CHUNK_OVERLAP_SAMPLES, int),
                    None,
                )
            };
            let mut chunks = Vec::new();
            let mut transcribe = |chunk: &Chunk| -> Result<Vec<Word>, Infallible> {
                chunks.push([chunk.start, chunk.samples.len()]);
                Ok(fake_words(chunk, every))
            };
            for part in split(&input, pattern) {
                transcription.append(part, &mut transcribe).unwrap();
            }
            let text = transcription.finish(&mut transcribe).unwrap();
            assert_eq!(
                chunks,
                pairs(&item["chunks"]),
                "transcription {} reads {pattern:?}",
                name(item)
            );
            assert_eq!(text, item["text"].as_str().unwrap(), "{}", name(item));
        }
    }
}
