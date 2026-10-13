//! Per-group cache of projected encoder output, shared by the evaluation and
//! preparation binaries of the word-boosting experiments.
//!
//! The file format and identity are experiment 1's (`lf-bias-eval`'s
//! `projected`): one JSON header line, then little-endian f32 projections of
//! every utterance in order. The header names the format, the export (SHA-256
//! over the export manifest's format and verified file hashes), the encoder
//! precision, the projection row stride, the utterance ids and each audio
//! file's SHA-256, plus the frame counts. A cache file is used only when every
//! one of those fields matches exactly; otherwise the group is encoded and
//! the file rewritten.
//!
//! Experiment 1 keeps one file per evaluation set (read by `lf-bias-eval`).
//! Here a file holds one group (a call or a session), at
//! `ROOT/SET/GROUP.i8x2.proj`, so a 100-hour set is never read whole.

#![allow(dead_code)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use lf_asr::Transcriber;
use lf_model::Export;
use serde_json::{Value, json};

use crate::{audio, outpath};

/// Version tag of the cache format (experiment 1's, unchanged).
pub const CACHE_FORMAT: &str = "lf-bias-eval projected encoder output v2";

/// What a cached projection depends on, besides each utterance's audio.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheIdentity {
    /// SHA-256 over the export manifest's format and verified file hashes.
    pub export_sha256: String,
    /// Encoder precision label; experiment 1 and 2 use "i8x2".
    pub precision: String,
    /// Row stride of the projection (`PackedDecoder::joint_padded`).
    pub joint_padded: usize,
}

impl CacheIdentity {
    /// Experiment 1's identity for `export` (already verified by
    /// `Export::open`) at precision `precision`.
    pub fn new(export: &Export, precision: &str, joint_padded: usize) -> Self {
        let export_sha256 = lf_model::manifest::sha256_hex(
            serde_json::to_string(&json!({
                "format": export.manifest.format,
                "files": export.manifest.files,
            }))
            .unwrap()
            .as_bytes(),
        );
        CacheIdentity {
            export_sha256,
            precision: precision.to_owned(),
            joint_padded,
        }
    }

    /// SHA-256 of the identity fields (format, export, precision, stride),
    /// recorded in derived outputs so they can be traced to their encodings.
    pub fn hash(&self) -> String {
        lf_model::manifest::sha256_hex(
            json!({
                "format": CACHE_FORMAT,
                "export_sha256": self.export_sha256,
                "precision": self.precision,
                "joint_padded": self.joint_padded,
            })
            .to_string()
            .as_bytes(),
        )
    }
}

/// One utterance's projected encoder output, `[frames][joint_padded]`.
pub struct Projected {
    pub frames: usize,
    pub proj: Vec<f32>,
}

/// The cache header for these utterances, without the frame counts
/// (experiment 1's `cache_identity_json`).
pub fn header_json(identity: &CacheIdentity, ids: &[&str], audio_sha256: &[String]) -> Value {
    json!({
        "format": CACHE_FORMAT,
        "export_sha256": identity.export_sha256,
        "precision": identity.precision,
        "joint_padded": identity.joint_padded,
        "ids": ids,
        "audio_sha256": audio_sha256,
    })
}

/// Frame counts from a cache `header` if every field of `expected` matches
/// it exactly and there is one count per utterance; `None` otherwise.
pub fn cached_frames(header: &Value, expected: &Value) -> Option<Vec<usize>> {
    let fields = expected.as_object()?;
    if fields.iter().any(|(k, v)| header.get(k) != Some(v)) {
        return None;
    }
    let n = expected["ids"].as_array()?.len();
    let frames: Vec<usize> = header["frames"]
        .as_array()?
        .iter()
        .map(|f| f.as_u64().map(|f| f as usize))
        .collect::<Option<_>>()?;
    (frames.len() == n).then_some(frames)
}

/// `ROOT/SET/GROUP.i8x2.proj`. `set` and `group` must be single, ordinary
/// path components (no separators, not `.` or `..`).
pub fn group_path(root: &Path, set: &str, group: &str) -> Result<PathBuf, String> {
    for c in [set, group] {
        if c.is_empty() || c == "." || c == ".." || c.contains(['/', '\\', '\0']) {
            return Err(format!("cache: {c:?} is not a plain file name"));
        }
    }
    Ok(root.join(set).join(format!("{group}.i8x2.proj")))
}

fn par_map<T: Sync, R: Send>(items: &[T], threads: usize, f: &(dyn Fn(&T) -> R + Sync)) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..threads.max(1) {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= items.len() {
                        break;
                    }
                    let r = f(&items[i]);
                    out.lock().unwrap()[i] = Some(r);
                }
            });
        }
    });
    out.into_inner()
        .unwrap()
        .into_iter()
        .map(|r| r.unwrap())
        .collect()
}

/// SHA-256 of each audio file, hashed on up to `threads` threads.
pub fn audio_hashes(
    ids_audio: &[(String, PathBuf)],
    threads: usize,
) -> Result<Vec<String>, String> {
    par_map(ids_audio, threads, &|(_, p)| {
        lf_model::manifest::sha256_file(p).map_err(|e| format!("{}: {e}", p.display()))
    })
    .into_iter()
    .collect()
}

/// The cached projections at `path` if its header matches `expected`
/// ([`header_json`]) and the body has the right length; `None` otherwise.
pub fn load(path: &Path, expected: &Value, joint_padded: usize) -> Option<Vec<Projected>> {
    let bytes = std::fs::read(path).ok()?;
    let nl = bytes.iter().position(|&b| b == b'\n')?;
    let header = serde_json::from_slice::<Value>(&bytes[..nl]).ok()?;
    let frames = cached_frames(&header, expected)?;
    let body = &bytes[nl + 1..];
    let total: usize = frames.iter().sum::<usize>() * joint_padded;
    if body.len() != total * 4 {
        return None;
    }
    let mut out = Vec::with_capacity(frames.len());
    let mut off = 0;
    for f in frames {
        let n = f * joint_padded * 4;
        let proj = body[off..off + n]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| f32::from_le_bytes(*c))
            .collect();
        off += n;
        out.push(Projected { frames: f, proj });
    }
    Some(out)
}

/// Writes `projected` under `header` (the frame counts are added) to `path`,
/// through a temporary file and a rename; refuses paths inside a Git work tree.
pub fn store(path: &Path, header: &Value, projected: &[Projected]) -> Result<(), String> {
    let mut header = header.clone();
    header["frames"] = json!(projected.iter().map(|p| p.frames).collect::<Vec<_>>());
    let tmp = path.with_extension("tmp");
    let mut w = std::io::BufWriter::new(outpath::create_output(&tmp)?);
    let werr = |e: std::io::Error| format!("{}: {e}", tmp.display());
    writeln!(w, "{header}").map_err(werr)?;
    for p in projected {
        for v in &p.proj {
            w.write_all(&v.to_le_bytes()).map_err(werr)?;
        }
    }
    w.flush().map_err(werr)?;
    drop(w);
    // `rename` replaces a link at `path` rather than writing through it.
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

/// Projected encoder outputs for one group's utterances (`ids_audio`, in a
/// fixed order), from `path` when its header matches, else encoded with `tr`
/// and written there (created on a miss). `tr` must use the precision named
/// by `identity`. Audio files are hashed on `threads` threads.
pub fn projected(
    tr: &mut Transcriber,
    identity: &CacheIdentity,
    ids_audio: &[(String, PathBuf)],
    path: &Path,
    threads: usize,
) -> Result<Vec<Projected>, String> {
    let audio_sha256 = audio_hashes(ids_audio, threads)?;
    let ids: Vec<&str> = ids_audio.iter().map(|(id, _)| id.as_str()).collect();
    let expected = header_json(identity, &ids, &audio_sha256);
    let jp = identity.joint_padded;
    if let Some(out) = load(path, &expected, jp) {
        return Ok(out);
    }
    if let Some(dir) = path.parent() {
        outpath::check_output_dir(dir)?;
    }
    let start = Instant::now();
    let mut out = Vec::with_capacity(ids_audio.len());
    for (id, p) in ids_audio {
        let samples = audio::read_flac(p)?;
        let (proj, frames) = tr
            .encode_projected(&samples)
            .map_err(|e| format!("{id}: {e}"))?;
        if proj.len() != frames * jp || proj.iter().any(|v| !v.is_finite()) {
            return Err(format!("{id}: malformed projection"));
        }
        out.push(Projected { frames, proj });
    }
    store(path, &expected, &out)?;
    eprintln!(
        "{}: encoded {} utterances in {:.1?}",
        path.display(),
        out.len(),
        start.elapsed()
    );
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> CacheIdentity {
        CacheIdentity {
            export_sha256: "e".repeat(64),
            precision: "i8x2".into(),
            joint_padded: 4,
        }
    }

    #[test]
    fn round_trips_and_rejects_any_identity_change() {
        let dir = std::env::temp_dir().join(format!("lf-enc-cache-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = group_path(&dir, "set", "call1").unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let id = identity();
        let hashes = vec!["a".repeat(64), "b".repeat(64)];
        let header = header_json(&id, &["c/1", "c/2"], &hashes);
        let data = vec![
            Projected {
                frames: 2,
                proj: (0..8).map(|v| v as f32 * 0.5).collect(),
            },
            Projected {
                frames: 1,
                proj: vec![-1.0, 2.0, 3.5, 1e-3],
            },
        ];
        store(&path, &header, &data).unwrap();
        let got = load(&path, &header, 4).unwrap();
        assert_eq!(got.len(), 2);
        for (a, b) in got.iter().zip(&data) {
            assert_eq!((a.frames, &a.proj), (b.frames, &b.proj));
        }
        // Experiment 1's header layout: the same keys, plus the frame counts.
        let bytes = std::fs::read(&path).unwrap();
        let nl = bytes.iter().position(|&b| b == b'\n').unwrap();
        let h: Value = serde_json::from_slice(&bytes[..nl]).unwrap();
        assert_eq!(bytes.len() - nl - 1, 12 * 4);
        let mut keys: Vec<&String> = h.as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            [
                "audio_sha256",
                "export_sha256",
                "format",
                "frames",
                "ids",
                "joint_padded",
                "precision"
            ]
        );
        assert_eq!(h["format"], CACHE_FORMAT);
        // Any change of identity, ids or audio misses.
        let mut other = id.clone();
        other.precision = "f32".into();
        assert!(load(&path, &header_json(&other, &["c/1", "c/2"], &hashes), 4).is_none());
        assert!(load(&path, &header_json(&id, &["c/2", "c/1"], &hashes), 4).is_none());
        let mut h2 = hashes.clone();
        h2[1] = "c".repeat(64);
        assert!(load(&path, &header_json(&id, &["c/1", "c/2"], &h2), 4).is_none());
        assert!(load(&path, &header, 8).is_none());
        assert_ne!(id.hash(), other.hash());
        // Group names are plain file names.
        assert!(group_path(&dir, "set", "../x").is_err());
        assert!(group_path(&dir, "", "x").is_err());
        assert!(group_path(&dir, "set", "..").is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
