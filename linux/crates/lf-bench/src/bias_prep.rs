//! `lf-bias-prep`: training shards for the learned bias module (experiment
//! 2, CONTRACT-2 §4) and the pre-training gate (DESIGN "Gate").
//!
//! Inputs are one or more sets (`--set`), each a dataset's manifest with its
//! declared casing and target mode. Sessions are dictionary groups; each
//! session belongs to one split: SPGISpeech by experiment 2's call hash
//! (train/dev), every other dataset by the manifest's explicit `split` field
//! (train, dev or held-out). Held-out sessions are never prepared.
//!
//! `prep`: for each selected train or dev session, encode its utterances once
//! (i8x2, cached by `enc_cache`), decode them greedily without bias
//! (`Storage::F16`), then for each of `--samples` sampled dictionaries
//! (`prep_dict`): repair dictionary-related errors (`prep_targets`), align the
//! corrected target decode-consistently (`prep_align`) and write one shard
//! (`prep_shard`) to `OUT/prep/{split}/{prefix}{session}.{sample}.safetensors`.
//! `OUT/prep/index.json` is rebuilt from every shard present (with each
//! dataset's policy and completeness), and `OUT/prep/report-{sets}.json`
//! describes the run (timings, peak RSS, audit, speaker overlap).
//!
//! `gate`: decode every given set's train sessions without bias and count
//! missed target occurrences, distinct missed words, sessions, the
//! candidate-reachable share, and run experiment 1's single-word oracle on a
//! sample of the combined misses. Thresholds apply to the combined training
//! mix. Writes `OUT/gate/{dataset}.json` per set, and
//! `OUT/gate/combined-{sets}.json` with `OUT/gate/probes-{sets}.jsonl`.
//!
//! Targets: rare and session-specific reference words (`exp2_terms`), with
//! document frequency from the dataset's train sessions only (or, without a
//! train split, the split itself), or with `targets=keywords` the manifest's
//! `keywords` fields and/or a keywords file. Entries are normalized for the
//! declared casing (`exp2_terms::normalize_entry_surface`) before variants.
//!
//! Every output must be outside a Git work tree (`outpath`).

mod audio;
#[allow(dead_code)]
mod bias_lists;
#[allow(dead_code)]
mod bias_metrics;
mod enc_cache;
mod exp2_data;
mod exp2_phrases;
mod exp2_terms;
mod learned;
mod outpath;
mod prep_align;
mod prep_dict;
mod prep_shard;
mod prep_targets;
#[allow(dead_code)]
mod wer;

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use lf_asr::bias::{BiasConfig, BiasGraph};
use lf_asr::config::{DURATIONS, VOCAB};
use lf_asr::tokenizer::Tokenizer;
use lf_asr::{Model, Precision, Transcriber};
use lf_cpu::ThreadPool;
use lf_cpu::decoder::{PackedDecoder, Storage};
use lf_model::Export;
use lf_model::safetensors::TensorData;
use serde_json::{Value, json};

use enc_cache::{CacheIdentity, Projected};
use exp2_terms::{Casing, SessionDf};
use prep_shard::{ShardDecision, ShardUtt};
use prep_targets::{Counters, DictView, HypText, Target};
use wer::normalize;

const DEFAULT_SEED: u64 = 20_261_011;
/// Decisions per shard whose Rust joint rows are stored for P's logit check.
const CHECK_ROWS: usize = 16;
const BLANK: usize = VOCAB;
const V: usize = VOCAB + 1;

// ---------------------------------------------------------------- datasets

/// A session's split.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Split {
    Train,
    Dev,
    Heldout,
}

impl Split {
    fn name(self) -> &'static str {
        match self {
            Split::Train => "train",
            Split::Dev => "dev",
            Split::Heldout => "heldout",
        }
    }

    /// A manifest `split` value: train; dev, validation or valid; heldout,
    /// test or eval.
    fn parse(s: &str) -> Result<Split, String> {
        match s.to_ascii_lowercase().as_str() {
            "train" => Ok(Split::Train),
            "dev" | "validation" | "valid" => Ok(Split::Dev),
            "heldout" | "held-out" | "test" | "eval" => Ok(Split::Heldout),
            _ => Err(format!("unknown split {s:?}")),
        }
    }
}

/// One manifest utterance.
#[derive(Clone, Debug)]
struct MUtt {
    id: String,
    audio: PathBuf,
    text: String,
    seconds: f64,
    /// The manifest's `session` field, if any.
    session: Option<String>,
    /// The manifest's `split` field, if any.
    split: Option<String>,
    /// The manifest's `speaker` (or `speaker_id`) field, if any.
    speaker: Option<String>,
    /// The manifest's `keywords` field, if any.
    keywords: Vec<String>,
    /// The declared casing of the manifest this line came from.
    casing: Casing,
}

/// What `lf-bias-prep` needs to know about a dataset.
#[derive(Clone, Debug)]
struct Dataset {
    name: String,
    /// SPGISpeech: sessions are calls (the id before "/") and the split is
    /// experiment 2's call hash. Otherwise sessions and splits come from the
    /// manifest's `session` and `split` fields.
    spgi: bool,
    /// Shard file-name prefix: empty for SPGISpeech (CONTRACT-2 fixes
    /// `{call}.{sample}`); `{name}.` for other datasets, so files never collide.
    shard_prefix: String,
}

impl Dataset {
    fn new(name: &str) -> Result<Self, String> {
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_".contains(c))
        {
            return Err(format!("bad dataset name {name:?}"));
        }
        let spgi = name == "spgispeech";
        Ok(Dataset {
            name: name.into(),
            spgi,
            shard_prefix: if spgi {
                String::new()
            } else {
                format!("{name}.")
            },
        })
    }

    /// The casing assumed for a manifest without a declaration: SPGISpeech
    /// is cased; every other dataset must declare it.
    fn default_casing(&self) -> Option<Casing> {
        self.spgi.then_some(Casing::Cased)
    }

    fn session(&self, u: &MUtt) -> Result<String, String> {
        if self.spgi {
            Ok(exp2_data::spgi_call_id(&u.id).to_owned())
        } else {
            u.session
                .clone()
                .ok_or(format!("{}: {}: no session field", self.name, u.id))
        }
    }

    fn split(&self, session: &str, u: &MUtt) -> Result<Split, String> {
        if self.spgi {
            Ok(if exp2_data::spgi_is_dev(session) {
                Split::Dev
            } else {
                Split::Train
            })
        } else {
            let s = u
                .split
                .as_deref()
                .ok_or(format!("{}: {}: no split field", self.name, u.id))?;
            Split::parse(s).map_err(|e| format!("{}: {}: {e}", self.name, u.id))
        }
    }

    /// The namespaced session id used in shard metadata and seeds.
    fn call_id(&self, session: &str) -> String {
        format!("{}/{session}", self.name)
    }
}

/// The harness's JSON lines: `id`, `audio_filepath`, `text`, `duration`,
/// optionally `session`, `split`, `speaker` (or `speaker_id`) and `keywords`
/// (a list of strings). Every line takes the manifest's declared `casing`.
fn read_manifest(path: &Path, casing: Casing) -> Result<Vec<MUtt>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let v: Value =
            serde_json::from_str(line).map_err(|e| format!("{}:{}: {e}", path.display(), n + 1))?;
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        let (Some(id), Some(audio), Some(t)) = (s("id"), s("audio_filepath"), s("text")) else {
            return Err(format!(
                "{}:{}: need id, audio_filepath and text",
                path.display(),
                n + 1
            ));
        };
        if !seen.insert(id.clone()) {
            return Err(format!("{}: duplicate id {id}", path.display()));
        }
        let keywords = v
            .get("keywords")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        let speaker = s("speaker").or_else(|| s("speaker_id")).or_else(|| {
            v.get("speaker")
                .or_else(|| v.get("speaker_id"))
                .and_then(Value::as_i64)
                .map(|x| x.to_string())
        });
        out.push(MUtt {
            id,
            audio: audio.into(),
            text: t,
            seconds: v.get("duration").and_then(Value::as_f64).unwrap_or(0.0),
            session: s("session"),
            split: s("split"),
            speaker,
            keywords,
            casing,
        });
    }
    Ok(out)
}

// ---------------------------------------------------------------- arguments

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Cmd {
    Prep,
    Gate,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum SplitSel {
    Train,
    Dev,
    All,
}

/// One manifest of a set, with its declared reference casing.
#[derive(Clone, Debug, PartialEq, Eq)]
struct ManifestArg {
    path: PathBuf,
    casing: Casing,
}

/// One input set: a dataset's manifests (e.g. its train and dev files,
/// each with its own casing) and how to read them.
#[derive(Clone, Debug)]
struct SetArg {
    dataset: Dataset,
    manifests: Vec<ManifestArg>,
    keyword_targets: bool,
    keywords: Option<PathBuf>,
    /// Manifests read only for the speaker-overlap audit (e.g. the held-out
    /// eval split): never prepared, never part of the DF source.
    audit: Vec<PathBuf>,
}

impl SetArg {
    /// Each manifest's declared casing, or the dataset default; an
    /// undeclared casing is an error for every dataset but SPGISpeech.
    fn new(
        dataset: Dataset,
        manifests: Vec<(PathBuf, Option<Casing>)>,
        keyword_targets: bool,
        keywords: Option<PathBuf>,
    ) -> Result<Self, String> {
        if manifests.is_empty() {
            return Err(format!("{}: needs manifest=", dataset.name));
        }
        if keywords.is_some() && !keyword_targets {
            return Err("keywords= needs targets=keywords".into());
        }
        let manifests = manifests
            .into_iter()
            .map(|(path, casing)| {
                let casing = casing.or(dataset.default_casing()).ok_or(format!(
                    "{}: {}: declare casing=cased|uncased",
                    dataset.name,
                    path.display()
                ))?;
                Ok(ManifestArg { path, casing })
            })
            .collect::<Result<_, String>>()?;
        Ok(SetArg {
            dataset,
            manifests,
            keyword_targets,
            keywords,
            audit: Vec::new(),
        })
    }
}

struct Args {
    cmd: Cmd,
    sets: Vec<SetArg>,
    export: PathBuf,
    word_counts: PathBuf,
    cache: PathBuf,
    out: PathBuf,
    split: SplitSel,
    sessions: Option<usize>,
    samples: u32,
    seed: u64,
    threads: usize,
    oracle_occurrences: usize,
    /// Also store `dec.logits` (every decision's Rust joint row): fixtures only.
    dec_logits: bool,
}

/// The experiment root W: `--cache` defaults to `$LF_EXP2_ROOT/cache` and
/// `--out` to `$LF_EXP2_ROOT`.
const ROOT_ENV: &str = "LF_EXP2_ROOT";

const USAGE: &str = "usage: lf-bias-prep prep|gate --export DIR --word-counts FILE [--cache DIR] [--out DIR] \
     (--set name=NAME,manifest=FILE[,casing=cased|uncased][,manifest=FILE[,casing=…]]...[,targets=rare|keywords][,keywords=FILE])... \
     | [--dataset spgispeech|NAME] --manifest FILE [--casing cased|uncased] [--targets rare|keywords] [--keywords FILE] \
     [--split train|dev|all] [--sessions N] [--samples 2] [--seed 20261011] [--threads 16] \
     [--oracle-occurrences 500] [--dec-logits]\n\
     --cache and --out default to $LF_EXP2_ROOT/cache and $LF_EXP2_ROOT (the experiment root); \
     one or the other is required. casing= applies to the manifest= before it.";

fn parse_casing(s: &str) -> Result<Casing, String> {
    match s {
        "cased" => Ok(Casing::Cased),
        "uncased" => Ok(Casing::Uncased),
        c => Err(format!("unknown casing {c}")),
    }
}

fn parse_targets(s: &str) -> Result<bool, String> {
    match s {
        "rare" => Ok(false),
        "keywords" => Ok(true),
        t => Err(format!("unknown target rule {t}")),
    }
}

/// `name=NAME,manifest=FILE[,casing=…][,manifest=FILE[,casing=…]]...[,targets=…][,keywords=FILE][,audit=FILE]...`:
/// each `casing=` belongs to the `manifest=` before it; `audit=` manifests
/// only feed the speaker-overlap audit.
fn parse_set(spec: &str) -> Result<SetArg, String> {
    let (mut name, mut targets, mut keywords) = (None, false, None);
    let mut manifests: Vec<(PathBuf, Option<Casing>)> = Vec::new();
    let mut audit = Vec::new();
    for kv in spec.split(',') {
        let (k, v) = kv
            .split_once('=')
            .ok_or(format!("--set: {kv:?} is not key=value"))?;
        match k {
            "name" => name = Some(v.to_owned()),
            "manifest" => manifests.push((PathBuf::from(v), None)),
            "casing" => match manifests.last_mut() {
                Some((_, c @ None)) => *c = Some(parse_casing(v)?),
                _ => return Err("--set: casing= must follow its manifest= (once)".into()),
            },
            "targets" => targets = parse_targets(v)?,
            "keywords" => keywords = Some(PathBuf::from(v)),
            "audit" => audit.push(PathBuf::from(v)),
            _ => return Err(format!("--set: unknown key {k}")),
        }
    }
    let mut set = SetArg::new(
        Dataset::new(&name.ok_or("--set needs name=")?)?,
        manifests,
        targets,
        keywords,
    )?;
    set.audit = audit;
    Ok(set)
}

fn parse_args(argv: impl IntoIterator<Item = String>) -> Result<Args, String> {
    parse_args_with_root(argv, std::env::var_os(ROOT_ENV).map(PathBuf::from))
}

/// [`parse_args`] with the experiment root (`$LF_EXP2_ROOT`) given.
fn parse_args_with_root(
    argv: impl IntoIterator<Item = String>,
    root: Option<PathBuf>,
) -> Result<Args, String> {
    let mut it = argv.into_iter();
    let cmd = match it.next().as_deref() {
        Some("prep") => Cmd::Prep,
        Some("gate") => Cmd::Gate,
        _ => return Err(USAGE.into()),
    };
    let (mut dataset, mut manifest, mut casing, mut targets, mut keywords) = (
        None::<String>,
        None::<PathBuf>,
        None,
        false,
        None::<PathBuf>,
    );
    let mut a = Args {
        cmd,
        sets: Vec::new(),
        export: PathBuf::new(),
        word_counts: PathBuf::new(),
        cache: PathBuf::new(),
        out: PathBuf::new(),
        split: SplitSel::Train,
        sessions: None,
        samples: 2,
        seed: DEFAULT_SEED,
        threads: 16,
        oracle_occurrences: 500,
        dec_logits: false,
    };
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        let num = |v: String| v.parse::<u64>().map_err(|e| format!("{flag}: {e}"));
        match flag.as_str() {
            "--set" => a.sets.push(parse_set(&value()?)?),
            "--dataset" => dataset = Some(value()?),
            "--manifest" => manifest = Some(value()?.into()),
            "--casing" => casing = Some(parse_casing(&value()?)?),
            "--targets" => targets = parse_targets(&value()?)?,
            "--keywords" => keywords = Some(value()?.into()),
            "--export" => a.export = value()?.into(),
            "--word-counts" => a.word_counts = value()?.into(),
            "--cache" => a.cache = value()?.into(),
            "--out" => a.out = value()?.into(),
            "--split" => {
                a.split = match value()?.as_str() {
                    "train" => SplitSel::Train,
                    "dev" => SplitSel::Dev,
                    "all" => SplitSel::All,
                    s => return Err(format!("unknown split {s}")),
                }
            }
            "--sessions" => a.sessions = Some(num(value()?)? as usize),
            "--samples" => a.samples = num(value()?)? as u32,
            "--seed" => a.seed = num(value()?)?,
            "--threads" => a.threads = num(value()?)? as usize,
            "--oracle-occurrences" => a.oracle_occurrences = num(value()?)? as usize,
            "--dec-logits" => a.dec_logits = true,
            "-h" | "--help" => return Err(USAGE.into()),
            _ => return Err(format!("unknown argument {flag}\n{USAGE}")),
        }
    }
    let legacy = manifest.is_some()
        || dataset.is_some()
        || casing.is_some()
        || targets
        || keywords.is_some();
    if legacy {
        if !a.sets.is_empty() {
            return Err("use either --set or --dataset/--manifest, not both".into());
        }
        if keywords.is_some() && !targets {
            return Err("--keywords needs --targets keywords".into());
        }
        a.sets.push(SetArg::new(
            Dataset::new(dataset.as_deref().unwrap_or("spgispeech"))?,
            vec![(manifest.ok_or(format!("need --manifest\n{USAGE}"))?, casing)],
            targets,
            keywords,
        )?);
    }
    // Defaults from the experiment root; without it the flags are required.
    if let Some(root) = &root {
        if a.cache.as_os_str().is_empty() {
            a.cache = root.join("cache");
        }
        if a.out.as_os_str().is_empty() {
            a.out = root.clone();
        }
    }
    if a.sets.is_empty() {
        return Err(format!("need at least one --set\n{USAGE}"));
    }
    let names: BTreeSet<&str> = a.sets.iter().map(|s| s.dataset.name.as_str()).collect();
    if names.len() != a.sets.len() {
        return Err("each dataset may be given once".into());
    }
    for (p, name) in [
        (&a.export, "--export"),
        (&a.word_counts, "--word-counts"),
        (&a.cache, "--cache (or set LF_EXP2_ROOT)"),
        (&a.out, "--out (or set LF_EXP2_ROOT)"),
    ] {
        if p.as_os_str().is_empty() {
            return Err(format!("need {name}\n{USAGE}"));
        }
    }
    if a.threads == 0 || a.threads > 16 {
        return Err("--threads must be 1..=16".into());
    }
    if a.cmd == Cmd::Gate && a.split != SplitSel::Train {
        return Err("the gate runs on the train split only".into());
    }
    Ok(a)
}

impl Args {
    /// The set names joined by "+", for file names of combined outputs.
    fn sets_label(&self) -> String {
        self.sets
            .iter()
            .map(|s| s.dataset.name.as_str())
            .collect::<Vec<_>>()
            .join("+")
    }
}

// ---------------------------------------------------------------- corpus

/// The frozen document-frequency table used for one split's targets.
struct DfSource {
    /// The split whose sessions it was computed over.
    split: Split,
    df: SessionDf,
}

struct Corpus {
    set: SetArg,
    utts: Vec<MUtt>,
    /// Session -> utterance indices, in manifest order.
    sessions: BTreeMap<String, Vec<usize>>,
    split_of: BTreeMap<String, Split>,
    /// Session -> `(normalized, surface)` targets.
    targets: BTreeMap<String, Vec<(String, String)>>,
    /// Session -> its distractor exclusion set: normalized reference words,
    /// plus the dataset's multi-word targets spoken in its references.
    vocab: BTreeMap<String, BTreeSet<String>>,
    target_rule: String,
    /// Rare reference words that are not targets because too many DF-source
    /// sessions contain them (rare-word rule only).
    df_excluded: BTreeSet<String>,
    /// Per split with sessions, its DF source (rare-word rule only).
    df: BTreeMap<Split, DfSource>,
    /// Each manifest's SHA-256, in the set's order.
    manifest_shas: Vec<String>,
    /// Per manifest, the splits of its sessions.
    manifest_splits: Vec<BTreeSet<Split>>,
    /// SHA-256 of the manifest file; with several, of their SHA-256s
    /// sorted and joined by "\n".
    manifest_sha256: String,
    /// Session -> the declared casing of its manifest.
    casing_of: BTreeMap<String, Casing>,
    /// The rule's provenance, recorded in every shard (`rare_rule`).
    rare_rule: Value,
    /// Speaker overlap between train and the other splits.
    speakers: Value,
}

/// Keyword targets: per session, the manifest `keywords` of its utterances
/// and, with `file` (a JSON object from a session or utterance id to a list
/// of strings), those listed for the session or its utterances; the first
/// surface per normalized form.
fn keyword_targets(
    file: Option<&Path>,
    sessions: &BTreeMap<String, Vec<usize>>,
    utts: &[MUtt],
) -> Result<BTreeMap<String, Vec<(String, String)>>, String> {
    let ext: serde_json::Map<String, Value> = match file {
        Some(p) => {
            let v: Value = serde_json::from_str(
                &std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?,
            )
            .map_err(|e| format!("{}: {e}", p.display()))?;
            v.as_object()
                .cloned()
                .ok_or("--keywords: expected a JSON object")?
        }
        None => serde_json::Map::new(),
    };
    let list = |id: &str| -> Vec<String> {
        ext.get(id)
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    };
    let mut out = BTreeMap::new();
    for (s, idx) in sessions {
        let mut seen = BTreeMap::new();
        let from_utts = idx
            .iter()
            .flat_map(|&i| utts[i].keywords.iter().cloned().chain(list(&utts[i].id)));
        for kw in list(s).into_iter().chain(from_utts) {
            let norm = normalize(&kw).join(" ");
            if !norm.is_empty() {
                seen.entry(norm).or_insert(kw);
            }
        }
        out.insert(s.clone(), seen.into_iter().collect());
    }
    Ok(out)
}

fn sha256_of(path: &Path) -> Result<String, String> {
    lf_model::manifest::sha256_file(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// Speakers of the train split that also speak in dev or held-out lines,
/// from `(speaker, split)` per utterance.
fn speaker_overlap(lines: &[(Option<&str>, Split)]) -> Value {
    if lines.iter().all(|(s, _)| s.is_none()) {
        return json!({"speaker_field": false});
    }
    let mut by_split: BTreeMap<Split, BTreeSet<&str>> = BTreeMap::new();
    for &(s, split) in lines {
        if let Some(s) = s {
            by_split.entry(split).or_default().insert(s);
        }
    }
    let train = by_split.remove(&Split::Train).unwrap_or_default();
    let mut out = json!({
        "speaker_field": true,
        "utterances_without_speaker": lines.iter().filter(|(s, _)| s.is_none()).count(),
        "train_speakers": train.len(),
    });
    for split in [Split::Dev, Split::Heldout] {
        let other = by_split.get(&split).cloned().unwrap_or_default();
        let shared: Vec<&str> = other.intersection(&train).copied().collect();
        let utts_shared = lines
            .iter()
            .filter(|&&(s, sp)| sp == split && s.is_some_and(|s| train.contains(s)))
            .count();
        out[split.name()] = json!({
            "speakers": other.len(),
            "shared_with_train": shared.len(),
            "utterances_with_train_speaker": utts_shared,
            "examples": shared.iter().take(10).collect::<Vec<_>>(),
        });
    }
    out
}

fn corpus(set: &SetArg, word_counts: &Path) -> Result<Corpus, String> {
    let ds = &set.dataset;
    let mut utts = Vec::new();
    let mut utt_manifest = Vec::new();
    let mut manifest_shas = Vec::new();
    for (k, m) in set.manifests.iter().enumerate() {
        let lines = read_manifest(&m.path, m.casing)?;
        utt_manifest.extend(std::iter::repeat_n(k, lines.len()));
        utts.extend(lines);
        manifest_shas.push(sha256_of(&m.path)?);
    }
    let manifest_sha256 = if manifest_shas.len() == 1 {
        manifest_shas[0].clone()
    } else {
        let mut v = manifest_shas.clone();
        v.sort();
        lf_model::manifest::sha256_hex(v.join("\n").as_bytes())
    };
    let mut ids = BTreeSet::new();
    let mut manifest_splits: Vec<BTreeSet<Split>> = vec![BTreeSet::new(); set.manifests.len()];
    let mut sessions: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    let mut split_of: BTreeMap<String, Split> = BTreeMap::new();
    let mut casing_of: BTreeMap<String, Casing> = BTreeMap::new();
    for (i, u) in utts.iter().enumerate() {
        if !ids.insert(u.id.as_str()) {
            return Err(format!(
                "{}: id {} in more than one manifest",
                ds.name, u.id
            ));
        }
        let s = ds.session(u)?;
        if enc_cache::group_path(Path::new("."), &ds.name, &s).is_err() {
            return Err(format!("{}: session {s:?} is not a plain file name", u.id));
        }
        let sp = ds.split(&s, u)?;
        if *split_of.entry(s.clone()).or_insert(sp) != sp {
            return Err(format!(
                "{}: session {s} has utterances in more than one split",
                ds.name
            ));
        }
        if *casing_of.entry(s.clone()).or_insert(u.casing) != u.casing {
            return Err(format!(
                "{}: session {s} is in manifests of different casing",
                ds.name
            ));
        }
        manifest_splits[utt_manifest[i]].insert(sp);
        sessions.entry(s).or_default().push(i);
    }
    let session_of: Vec<&str> = {
        let mut v = vec![""; utts.len()];
        for (s, idx) in &sessions {
            for &i in idx {
                v[i] = s;
            }
        }
        v
    };
    let vocab: BTreeMap<String, BTreeSet<String>> = sessions
        .iter()
        .map(|(s, idx)| {
            (
                s.clone(),
                idx.iter().flat_map(|&i| normalize(&utts[i].text)).collect(),
            )
        })
        .collect();
    // Speaker overlap, including audit-only manifests (e.g. held-out eval):
    // their lines need a non-train split and sessions of their own.
    let mut audit_lines = Vec::new();
    for p in &set.audit {
        for u in read_manifest(p, Casing::Cased)? {
            let s = ds.session(&u)?;
            let sp = ds.split(&s, &u)?;
            if sp == Split::Train || split_of.contains_key(&s) {
                return Err(format!(
                    "{}: audit manifest {}: {} must be a non-train session of its own",
                    ds.name,
                    p.display(),
                    u.id
                ));
            }
            audit_lines.push((u.speaker, sp));
        }
    }
    let speaker_lines: Vec<(Option<&str>, Split)> = (0..utts.len())
        .map(|i| (utts[i].speaker.as_deref(), split_of[session_of[i]]))
        .chain(audit_lines.iter().map(|(s, sp)| (s.as_deref(), *sp)))
        .collect();
    let mut speakers = speaker_overlap(&speaker_lines);
    if !set.audit.is_empty() {
        speakers["audit_manifests"] = json!(
            set.audit
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
        );
    }
    let present: BTreeSet<Split> = split_of.values().copied().collect();
    let mut df_excluded = BTreeSet::new();
    let mut df = BTreeMap::new();
    let (mut targets, target_rule, rare_rule) = if set.keyword_targets {
        let kw_sha = set.keywords.as_deref().map(sha256_of).transpose()?;
        (
            keyword_targets(set.keywords.as_deref(), &sessions, &utts)?,
            "keywords (manifest field and keywords file)".to_owned(),
            json!({"rule": "keywords", "keywords_file_sha256": kw_sha}),
        )
    } else {
        let counts = std::fs::read_to_string(word_counts)
            .map_err(|e| format!("{}: {e}", word_counts.display()))?;
        let common = exp2_data::common_words(&counts)?;
        let mut targets = BTreeMap::new();
        let has_train = present.contains(&Split::Train);
        for &split in &present {
            // DF from the train sessions only, frozen; without a train split,
            // from this split only (DESIGN "DF source").
            let source = Split::parse(exp2_terms::df_source_split(has_train, split.name()))?;
            let table = SessionDf::from_references(
                (0..utts.len())
                    .filter(|&i| split_of[session_of[i]] == source)
                    .map(|i| (session_of[i], utts[i].text.as_str())),
            );
            let in_split: BTreeSet<&String> = sessions
                .keys()
                .filter(|s| split_of[s.as_str()] == split)
                .collect();
            let mut rare = BTreeSet::new();
            for w in in_split.iter().flat_map(|s| &vocab[s.as_str()]) {
                if exp2_terms::is_target(w, &common, &table) {
                    rare.insert(w.clone());
                } else if exp2_data::is_rare(w, &common) {
                    df_excluded.insert(w.clone());
                }
            }
            let records = (0..utts.len())
                .filter(|&i| in_split.contains(&session_of[i].to_owned()))
                .map(|i| (session_of[i], utts[i].text.as_str()));
            targets.extend(bias_lists::session_targets(records, &rare));
            df.insert(
                split,
                DfSource {
                    split: source,
                    df: table,
                },
            );
        }
        (
            targets,
            format!(
                "exp2_terms::is_target: rare (not among the first {} of all_words.count.txt, \
                 with a letter) and in at most max(5%, 2) of the DF-source sessions \
                 (train only; the scored split without one)",
                exp2_data::COMMON_WORDS
            ),
            json!({
                "rule": "exp2_terms::is_target",
                "common_words": exp2_data::COMMON_WORDS,
                "common_words_file_sha256": sha256_of(word_counts)?,
                "requires_letter": true,
                "max_df_percent": exp2_terms::MAX_DF_PERCENT,
                "min_df_limit": exp2_terms::MIN_DF_LIMIT,
            }),
        )
    };
    for s in sessions.keys() {
        targets.entry(s.clone()).or_default();
    }
    // Distractor exclusion (re-review #6): besides its words, a session
    // excludes every multi-word target of the dataset spoken in its own
    // references (`exp2_phrases`, shared with lf-bias-eval).
    let keys: BTreeSet<String> = targets
        .values()
        .flat_map(|t| t.iter().map(|(k, _)| k.clone()))
        .collect();
    let spoken = exp2_phrases::phrases_in_references(
        (0..utts.len()).map(|i| (session_of[i], utts[i].text.as_str())),
        &keys,
    );
    let mut vocab = vocab;
    for (s, phrases) in spoken {
        vocab.entry(s).or_default().extend(phrases);
    }
    Ok(Corpus {
        set: set.clone(),
        utts,
        sessions,
        split_of,
        targets,
        vocab,
        target_rule,
        df_excluded,
        df,
        manifest_shas,
        manifest_splits,
        manifest_sha256,
        casing_of,
        rare_rule,
        speakers,
    })
}

impl Corpus {
    /// Sessions of `split`, sorted.
    fn split_sessions(&self, split: Split) -> BTreeSet<String> {
        self.split_of
            .iter()
            .filter(|(_, s)| **s == split)
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// Selected train/dev sessions: the first `limit` of each (sorted ids).
    /// Held-out sessions are never selected.
    fn selected(&self, split: SplitSel, limit: Option<usize>) -> Vec<(Split, String)> {
        let mut out = Vec::new();
        for (s, on) in [
            (Split::Train, split != SplitSel::Dev),
            (Split::Dev, split != SplitSel::Train),
        ] {
            if on {
                out.extend(
                    self.split_sessions(s)
                        .into_iter()
                        .take(limit.unwrap_or(usize::MAX))
                        .map(|x| (s, x)),
                );
            }
        }
        out
    }

    /// The declared reference casing of `session`'s manifest.
    fn casing(&self, session: &str) -> Casing {
        self.casing_of[session]
    }

    /// How `session`'s dictionary entries become surfaces: keywords
    /// (all-uppercase OCR for SlideSpeech) as their original and lowercase
    /// forms, rare words normalized for their references' casing.
    fn entry_rule(&self, session: &str) -> EntryRule {
        if self.set.keyword_targets {
            EntryRule::Keyword
        } else {
            EntryRule::Normalized(self.casing(session))
        }
    }

    /// The casing of `split`'s sessions: "cased", "uncased", "mixed", or
    /// "none" without sessions.
    fn split_casing(&self, split: Split) -> &'static str {
        let c: BTreeSet<&'static str> = self
            .split_sessions(split)
            .iter()
            .map(|s| match self.casing(s) {
                Casing::Cased => "cased",
                Casing::Uncased => "uncased",
            })
            .collect();
        match c.len() {
            0 => "none",
            1 => c.into_iter().next().unwrap(),
            _ => "mixed",
        }
    }

    /// `df_source` metadata for `split` (null under the keyword rule): the
    /// manifests holding the DF-source sessions' lines.
    fn df_source(&self, split: Split) -> (Value, String) {
        match self.df.get(&split) {
            Some(d) => (
                json!({
                    "manifests": self.set.manifests.iter().enumerate()
                        .filter(|(k, _)| self.manifest_splits[*k].contains(&d.split))
                        .map(|(k, m)| json!({"path": m.path.display().to_string(), "sha256": self.manifest_shas[k]}))
                        .collect::<Vec<_>>(),
                    "split": d.split.name(),
                    "sessions": d.df.sessions(),
                    "max_df": d.df.max_df(),
                }),
                d.df.sha256(),
            ),
            None => (Value::Null, "none".into()),
        }
    }

    /// The policy fields of `split`'s shards (CONTRACT-2 NOTES "Shard
    /// validation fields (R2)"); `policy_sha256` hashes this object.
    fn policy(&self, split: Split, args: &Args, identity: &CacheIdentity) -> Value {
        let (df_source, df_sha) = self.df_source(split);
        let sessions = self.split_sessions(split);
        json!({
            "split_sessions": sessions.len(),
            "split_sessions_sha256": session_set_sha256(&sessions),
            "format": prep_shard::SHARD_FORMAT,
            "dataset": self.set.dataset.name,
            "split": split.name(),
            "casing": self.split_casing(split),
            "targets_mode": if self.set.keyword_targets { "keywords" } else { "rare" },
            "rare_rule": self.rare_rule,
            "df_source": df_source,
            "df_source_sha256": df_sha,
            "split_rule": if self.set.dataset.spgi { "spgi call hash (exp2_data::spgi_is_dev)" } else { "manifest split field" },
            "manifest_sha256": self.manifest_sha256,
            "seed": args.seed.to_string(),
            "samples": args.samples,
            "export_sha256": identity.export_sha256,
            "cache_identity": identity.hash(),
            "graph": graph_policy(),
        })
    }
}

/// The `graph` policy object: exactly these keys (CONTRACT-2 NOTES).
fn graph_policy() -> Value {
    json!({"case_variants": true, "cancel_unfinished": false})
}

/// SHA-256 (hex) of a split's session ids (raw, as in `session`), sorted
/// bytewise and joined with "\n", no trailing newline.
fn session_set_sha256(sessions: &BTreeSet<String>) -> String {
    let joined: Vec<&str> = sessions.iter().map(String::as_str).collect();
    lf_model::manifest::sha256_hex(joined.join("\n").as_bytes())
}

// ---------------------------------------------------------------- workers

/// Runs `f(pool, item)` on `threads` workers, each with its own pinned
/// one-thread pool, longest items first (by `cost`); results in item order.
fn run_workers<T: Sync, R: Send>(
    threads: usize,
    items: &[T],
    cost: &(dyn Fn(&T) -> usize + Sync),
    f: &(dyn Fn(&ThreadPool, &T) -> R + Sync),
) -> Vec<R> {
    let mut order: Vec<usize> = (0..items.len()).collect();
    order.sort_by_key(|&i| std::cmp::Reverse(cost(&items[i])));
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for w in 0..threads.min(items.len()).max(1) {
            let (order, next, out) = (&order, &next, &out);
            s.spawn(move || {
                let pool = ThreadPool::new(&[w]);
                loop {
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    if k >= order.len() {
                        break;
                    }
                    let i = order[k];
                    let r = f(&pool, &items[i]);
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

/// Peak resident set size of this process, in KiB (`VmHWM`).
fn peak_rss_kib() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmHWM:"))
                .and_then(|l| l.split_whitespace().nth(1)?.parse().ok())
        })
        .unwrap_or(0)
}

// ---------------------------------------------------------------- models

struct Models {
    tr: Transcriber,
    model: Model,
    identity: CacheIdentity,
}

fn load_models(args: &Args) -> Result<Models, String> {
    let export =
        Export::open(&args.export).map_err(|e| format!("{}: {e}", args.export.display()))?;
    let enc_model = Model::load(&export, Storage::F16).map_err(|e| e.to_string())?;
    let model = Model::load(&export, Storage::F16).map_err(|e| e.to_string())?;
    let identity = CacheIdentity::new(&export, "i8x2", model.decoder.joint_padded());
    let cpus: Vec<usize> = (0..args.threads).collect();
    let tr = Transcriber::new(enc_model, &cpus, Precision::Int8(2));
    Ok(Models {
        tr,
        model,
        identity,
    })
}

/// Projected encodings of one session (from the cache, or encoded): every
/// manifest line of the session, in manifest order.
fn session_projections(
    args: &Args,
    m: &mut Models,
    corpus: &Corpus,
    session: &str,
) -> Result<Vec<Projected>, String> {
    let ids_audio: Vec<(String, PathBuf)> = corpus.sessions[session]
        .iter()
        .map(|&i| (corpus.utts[i].id.clone(), corpus.utts[i].audio.clone()))
        .collect();
    let path = enc_cache::group_path(&args.cache, &corpus.set.dataset.name, session)?;
    enc_cache::projected(&mut m.tr, &m.identity, &ids_audio, &path, args.threads)
}

/// The joint rows of one utterance with prediction-network outputs `g`.
fn joint_rows<'a>(
    dec: &'a PackedDecoder,
    proj: &'a [f32],
    g: &'a [f32],
) -> impl FnMut(usize, usize, &mut [f32]) + 'a {
    let jp = dec.joint_padded();
    move |t, u, out| dec.joint_row(&proj[t * jp..(t + 1) * jp], &g[u * jp..(u + 1) * jp], out)
}

/// The unbiased greedy decode of one utterance and its exactness check.
struct Base {
    emitted: Vec<(usize, usize)>,
    hyp: Result<HypText, String>,
    /// Greedy replay through `predictor_outputs`/`joint_row` equals `decode`.
    replay_ok: bool,
    decode_ns: u64,
}

fn baseline(dec: &PackedDecoder, tok: &Tokenizer, pool: &ThreadPool, p: &Projected) -> Base {
    let t = Instant::now();
    let emitted = dec.decode(pool, &p.proj, p.frames, None, None);
    let decode_ns = t.elapsed().as_nanos() as u64;
    let h: Vec<usize> = emitted.iter().map(|e| e.0).collect();
    let g = dec.predictor_outputs(pool, &h);
    let replay = prep_align::greedy_replay(
        p.frames,
        &h,
        V,
        &DURATIONS,
        &mut joint_rows(dec, &p.proj, &g),
    );
    Base {
        replay_ok: replay.as_ref() == Ok(&emitted),
        hyp: prep_targets::hyp_text(tok, &h),
        emitted,
        decode_ns,
    }
}

// ---------------------------------------------------------------- prep

/// A dictionary built for one sample.
struct Dict {
    /// Distinct entries ([`EntryRule::entry`], deduplicated by
    /// [`EntryRule::key`]) the tokenizer can encode: the `entries` count.
    entries: Vec<String>,
    unencodable: usize,
    /// Every entry's normalized word sequence.
    words: BTreeSet<Vec<String>>,
    phrases: Vec<Vec<usize>>,
    phrase_set: HashSet<Vec<usize>>,
    graph: BiasGraph,
}

/// The learned variants' graph: case variants on, cancel off. The scores
/// are irrelevant (the learned scorer replaces them) but alpha must be
/// non-zero to keep the trie.
fn learned_graph_config() -> BiasConfig {
    BiasConfig {
        alpha: 1.0,
        context_score: 1.0,
        depth_scaling: 0.0,
        cancel_unfinished: false,
    }
}

/// How dictionary entries become surfaces before case variants.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EntryRule {
    /// Rare-word entries: one surface, `normalize_entry_surface(e, casing)`.
    Normalized(Casing),
    /// Keyword entries: `keyword_entry_surfaces(e)` (original and lowercase).
    Keyword,
}

impl EntryRule {
    /// The entry as counted and listed: normalized for rare words, the
    /// first-seen original for keywords.
    fn entry(self, e: &str) -> String {
        match self {
            EntryRule::Normalized(c) => exp2_terms::normalize_entry_surface(e, c),
            EntryRule::Keyword => e.to_owned(),
        }
    }

    /// The key entries are deduplicated by: keywords case-insensitively.
    fn key(self, e: &str) -> String {
        match self {
            EntryRule::Normalized(_) => self.entry(e),
            EntryRule::Keyword => e.to_lowercase(),
        }
    }

    /// The surfaces fed to `phrases(.., case_variants = true)`.
    fn surfaces(self, e: &str) -> Vec<String> {
        match self {
            EntryRule::Normalized(_) => vec![self.entry(e)],
            EntryRule::Keyword => exp2_terms::keyword_entry_surfaces(e),
        }
    }
}

/// The sample's graph: entries deduplicated by [`EntryRule::key`], each
/// encoded from its [`EntryRule::surfaces`] with case variants (the union);
/// unencodable entries are skipped.
fn build_dict(tok: &Tokenizer, entries: Vec<String>, rule: EntryRule) -> Result<Dict, String> {
    let mut seen = BTreeSet::new();
    let mut kept = Vec::new();
    let mut unencodable = 0;
    let mut phrases = Vec::new();
    let mut phrase_set = HashSet::new();
    let mut words = BTreeSet::new();
    for raw in entries {
        if !seen.insert(rule.key(&raw)) {
            continue;
        }
        let e = rule.entry(&raw);
        match lf_asr::bias::phrases(tok, &rule.surfaces(&raw), true) {
            Ok(p) => {
                for ph in p {
                    if phrase_set.insert(ph.clone()) {
                        phrases.push(ph);
                    }
                }
                let w = normalize(&e);
                if !w.is_empty() {
                    words.insert(w);
                }
                kept.push(e);
            }
            Err(_) => unencodable += 1,
        }
    }
    let graph = BiasGraph::new(&phrases, VOCAB, learned_graph_config())?;
    Ok(Dict {
        entries: kept,
        unencodable,
        words,
        phrases,
        phrase_set,
        graph,
    })
}

#[derive(Default)]
struct UttStats {
    counters: Counters,
    align_ns: u64,
}

enum UttOut {
    Skipped(&'static str, Counters),
    Done(Box<ShardUtt>, UttStats),
}

/// Target, alignment and decision records of one utterance for one dictionary.
#[allow(clippy::too_many_arguments)]
fn prepare_utt(
    dec: &PackedDecoder,
    tok: &Tokenizer,
    pool: &ThreadPool,
    id: &str,
    reference: &str,
    p: &Projected,
    base: &Base,
    dict: &Dict,
    casing: Casing,
) -> UttOut {
    let mut c = Counters::default();
    let Ok(hyp) = &base.hyp else {
        return UttOut::Skipped("hypothesis_text", c);
    };
    let h: Vec<usize> = base.emitted.iter().map(|e| e.0).collect();
    let view = DictView {
        entries: &dict.words,
        phrases: &dict.phrase_set,
    };
    let start = Instant::now();
    let Ok(target): Result<Target, _> =
        prep_targets::repair(tok, &h, hyp, reference, &view, casing)
    else {
        return UttOut::Skipped("reference_normalization", c);
    };
    c.add_units(&target.units);
    let g = dec.predictor_outputs(pool, &target.tokens);
    let Some(al) = prep_align::align(
        p.frames,
        &target.tokens,
        V,
        &DURATIONS,
        &mut joint_rows(dec, &p.proj, &g),
    ) else {
        c.add("utterances.unreachable", 1);
        c.add(
            if target.tokens == h {
                "utterances.unreachable_unchanged"
            } else {
                "utterances.unreachable_repaired"
            },
            1,
        );
        return UttOut::Skipped("unreachable", c);
    };
    let align_ns = start.elapsed().as_nanos() as u64;
    // Bias state after T[..u].
    let mut states = vec![BiasGraph::ROOT];
    for &t in &target.tokens {
        states.push(dict.graph.step(*states.last().unwrap(), t).0);
    }
    let excluded = target.excluded();
    // Removed dictionary words: (target position, first and last frame H emitted them at).
    let removal_frames: Vec<(usize, usize, usize)> = target
        .removals()
        .into_iter()
        .filter(|(_, r)| !r.is_empty())
        .map(|(u, r)| {
            let f = &base.emitted[r];
            (
                u,
                f.iter().map(|e| e.1).min().unwrap(),
                f.iter().map(|e| e.1).max().unwrap(),
            )
        })
        .collect();
    let mut decisions = Vec::with_capacity(al.decisions.len());
    for d in &al.decisions {
        if excluded.iter().any(|&(a, b)| (a..=b).contains(&d.u)) {
            c.add("decisions.excluded", 1);
            continue;
        }
        let correction = if d.label == BLANK {
            removal_frames
                .iter()
                .any(|&(u, f0, f1)| u == d.u && (f0..=f1).contains(&d.t))
        } else {
            target.corrected[d.u]
        };
        c.add(
            match (correction, d.label == BLANK) {
                (true, true) => "decisions.correction_blank",
                (true, false) => "decisions.correction_token",
                (false, true) => "decisions.preservation_blank",
                (false, false) => "decisions.preservation_token",
            },
            1,
        );
        decisions.push(ShardDecision {
            t: d.t as u32,
            u: d.u as u32,
            state: states[d.u],
            label: d.label as u32,
            kind: u8::from(correction),
        });
    }
    c.add("utterances.aligned", 1);
    if target.units.iter().any(|u| u.revert.is_none()) {
        c.add("utterances.repaired", 1);
    }
    if target.tokens == h {
        // Diagnostic: does the best path emit at greedy's frames?
        let frames: Vec<usize> = al
            .decisions
            .iter()
            .filter(|d| d.label != BLANK)
            .map(|d| d.t)
            .collect();
        let greedy: Vec<usize> = base.emitted.iter().map(|e| e.1).collect();
        c.add("utterances.unchanged", 1);
        c.add(
            if frames == greedy {
                "utterances.unchanged_greedy_frames"
            } else {
                "utterances.unchanged_other_frames"
            },
            1,
        );
    }
    let (jp, j) = (dec.joint_padded(), dec.joint_dim());
    let rows = |src: &[f32], n: usize| -> Vec<f32> {
        (0..n)
            .flat_map(|r| src[r * jp..r * jp + j].iter().copied())
            .collect()
    };
    UttOut::Done(
        Box::new(ShardUtt {
            id: id.to_owned(),
            enc: rows(&p.proj, p.frames),
            pred: rows(&g, target.tokens.len() + 1),
            target: target.tokens,
            decisions,
        }),
        UttStats {
            counters: c,
            align_ns,
        },
    )
}

/// Totals over a run, for the report.
#[derive(Default)]
struct RunStats {
    counters: Counters,
    sessions: usize,
    utterances: usize,
    audio_s: f64,
    encode_s: f64,
    baseline_s: f64,
    baseline_thread_s: f64,
    prepare_s: f64,
    align_thread_s: f64,
    write_s: f64,
    shard_bytes: u64,
    shards: usize,
    replay_mismatch: usize,
    hyp_text_errors: usize,
}

struct ShardInfo<'a> {
    split: Split,
    session: &'a str,
    sample: u32,
    seconds: f64,
}

/// Every shard's metadata (CONTRACT-2 NOTES "Shard validation fields (R2)").
#[allow(clippy::too_many_arguments)]
fn shard_metadata(
    args: &Args,
    m: &Models,
    corpus: &Corpus,
    info: &ShardInfo,
    d: &prep_dict::DictSample,
    dict: &Dict,
    utts: &[ShardUtt],
    skipped: &BTreeMap<String, &str>,
    counters: &Counters,
) -> BTreeMap<String, String> {
    let decisions: usize = utts.iter().map(|u| u.decisions.len()).sum();
    let corrections: usize = utts
        .iter()
        .map(|u| u.decisions.iter().filter(|d| d.kind == 1).count())
        .sum();
    let j = m.model.decoder.joint_dim();
    let frames: usize = utts.iter().map(|u| u.enc.len() / j).sum();
    let s = |v: &Value| v.to_string();
    let policy = corpus.policy(info.split, args, &m.identity);
    let str_of = |k: &str| match &policy[k] {
        Value::String(x) => x.clone(),
        v => v.to_string(),
    };
    BTreeMap::from([
        ("format".into(), prep_shard::SHARD_FORMAT.into()),
        ("dataset".into(), corpus.set.dataset.name.clone()),
        ("call".into(), corpus.set.dataset.call_id(info.session)),
        ("session".into(), info.session.into()),
        ("split".into(), info.split.name().into()),
        ("sample".into(), info.sample.to_string()),
        ("seed".into(), args.seed.to_string()),
        ("samples".into(), args.samples.to_string()),
        (
            "split_sessions".into(),
            corpus.split_sessions(info.split).len().to_string(),
        ),
        ("casing".into(), str_of("casing")),
        ("targets_mode".into(), str_of("targets_mode")),
        ("rare_rule".into(), s(&policy["rare_rule"])),
        ("df_source".into(), s(&policy["df_source"])),
        ("df_source_sha256".into(), str_of("df_source_sha256")),
        ("split_rule".into(), str_of("split_rule")),
        ("manifest_sha256".into(), corpus.manifest_sha256.clone()),
        ("policy".into(), s(&policy)),
        (
            "policy_sha256".into(),
            lf_model::manifest::sha256_hex(policy.to_string().as_bytes()),
        ),
        (
            "size_choice".into(),
            d.size.map_or("targets".into(), |n| n.to_string()),
        ),
        ("entries".into(), dict.entries.len().to_string()),
        ("entries_unencodable".into(), dict.unencodable.to_string()),
        ("targets".into(), d.targets.to_string()),
        ("targets_kept".into(), d.kept.len().to_string()),
        ("distractors_hard".into(), d.hard.len().to_string()),
        ("distractors_random".into(), d.random.len().to_string()),
        ("distractors_short".into(), d.short.to_string()),
        ("phrases".into(), dict.phrases.len().to_string()),
        ("nodes".into(), dict.graph.states().to_string()),
        ("utterances".into(), utts.len().to_string()),
        (
            "utterance_ids".into(),
            s(&json!(
                utts.iter().map(|u| u.id.as_str()).collect::<Vec<_>>()
            )),
        ),
        ("skipped_utterances".into(), s(&json!(skipped))),
        ("decisions".into(), decisions.to_string()),
        ("corrections".into(), corrections.to_string()),
        ("frames".into(), frames.to_string()),
        ("audio_seconds".into(), format!("{:.3}", info.seconds)),
        ("audit".into(), s(&counters.json())),
        ("cache_identity".into(), m.identity.hash()),
        ("export_sha256".into(), m.identity.export_sha256.clone()),
        ("dictionary".into(), s(&json!(dict.entries))),
        ("graph".into(), s(&policy["graph"])),
        (
            "split_sessions_sha256".into(),
            str_of("split_sessions_sha256"),
        ),
    ])
}

/// The Rust joint rows (1025 token then 5 duration logits, from
/// `joint_row`) at `count` decisions spread evenly over the shard, or at
/// every decision: (indices into `dec.*`, `[k][1030]` logits).
fn rust_logits(
    dec: &PackedDecoder,
    utts: &[ShardUtt],
    count: Option<usize>,
) -> (Vec<i32>, Vec<f32>) {
    let j = dec.joint_dim();
    let all: Vec<(usize, &ShardDecision)> = utts
        .iter()
        .enumerate()
        .flat_map(|(i, u)| u.decisions.iter().map(move |d| (i, d)))
        .collect();
    let k = count.unwrap_or(all.len()).min(all.len());
    let (mut idx, mut logits) = (Vec::new(), Vec::new());
    let mut out = vec![0.0f32; V + DURATIONS.len()];
    for c in 0..k {
        let n = c * all.len() / k;
        let (i, d) = all[n];
        let u = &utts[i];
        let (t, uu) = (d.t as usize, d.u as usize);
        dec.joint_row(
            &u.enc[t * j..(t + 1) * j],
            &u.pred[uu * j..(uu + 1) * j],
            &mut out,
        );
        idx.push(n as i32);
        logits.extend_from_slice(&out);
    }
    (idx, logits)
}

fn shard_path(args: &Args, ds: &Dataset, split: Split, session: &str, sample: u32) -> PathBuf {
    args.out
        .join("prep")
        .join(split.name())
        .join(format!("{}{session}.{sample}.safetensors", ds.shard_prefix))
}

fn run_prep(args: &Args) -> Result<(), String> {
    let t_all = Instant::now();
    let mut m = load_models(args)?;
    let mut st = RunStats::default();
    let mut per_set = serde_json::Map::new();
    let mut all_hours = 0.0;
    for set in &args.sets {
        let corpus = corpus(set, &args.word_counts)?;
        all_hours += corpus.utts.iter().map(|u| u.seconds).sum::<f64>() / 3600.0;
        let ds = &corpus.set.dataset;
        let selected = corpus.selected(args.split, args.sessions);
        eprintln!(
            "{}: {} utterances, {} sessions (train {}, dev {}, held-out {}); preparing {} sessions x {} samples",
            ds.name,
            corpus.utts.len(),
            corpus.sessions.len(),
            corpus.split_sessions(Split::Train).len(),
            corpus.split_sessions(Split::Dev).len(),
            corpus.split_sessions(Split::Heldout).len(),
            selected.len(),
            args.samples
        );
        eprintln!("{}: speakers {}", ds.name, corpus.speakers);
        let pools: BTreeMap<Split, Vec<(String, String)>> = [Split::Train, Split::Dev]
            .into_iter()
            .map(|s| {
                (
                    s,
                    prep_dict::target_pool(&corpus.targets, &corpus.split_sessions(s)),
                )
            })
            .collect();
        let mut set_counters = Counters::default();
        for (si, (split, session)) in selected.iter().enumerate() {
            // Never a held-out session, and only into its own split's shards.
            assert!(*split != Split::Heldout && corpus.split_of[session] == *split);
            let idx = &corpus.sessions[session];
            let t = Instant::now();
            let proj = session_projections(args, &mut m, &corpus, session)?;
            st.encode_s += t.elapsed().as_secs_f64();
            let dec = &m.model.decoder;
            let tok = &m.model.tokenizer;
            let positions: Vec<usize> = (0..idx.len()).collect();
            let t = Instant::now();
            let bases = run_workers(
                args.threads,
                &positions,
                &|&k| proj[k].frames,
                &|pool, &k| baseline(dec, tok, pool, &proj[k]),
            );
            st.baseline_s += t.elapsed().as_secs_f64();
            st.baseline_thread_s += bases.iter().map(|b| b.decode_ns as f64 / 1e9).sum::<f64>();
            st.replay_mismatch += bases.iter().filter(|b| !b.replay_ok).count();
            st.hyp_text_errors += bases.iter().filter(|b| b.hyp.is_err()).count();
            let targets = &corpus.targets[session];
            let pool = &pools[split];
            let nearest = prep_dict::nearest_distances(pool, targets);
            let call = ds.call_id(session);
            for sample in 0..args.samples {
                let t = Instant::now();
                let d = prep_dict::sample_dictionary(
                    &call,
                    sample,
                    targets,
                    &corpus.vocab[session],
                    pool,
                    &nearest,
                    args.seed,
                );
                let dict = build_dict(tok, d.entries(), corpus.entry_rule(session))?;
                let outs = run_workers(
                    args.threads,
                    &positions,
                    &|&k| proj[k].frames,
                    &|pool, &k| {
                        let u = &corpus.utts[idx[k]];
                        prepare_utt(
                            dec,
                            tok,
                            pool,
                            &u.id,
                            &u.text,
                            &proj[k],
                            &bases[k],
                            &dict,
                            corpus.casing(session),
                        )
                    },
                );
                st.prepare_s += t.elapsed().as_secs_f64();
                let mut counters = Counters::default();
                let mut utts = Vec::new();
                let mut skipped = BTreeMap::new();
                let mut seconds = 0.0;
                for (k, o) in outs.into_iter().enumerate() {
                    match o {
                        UttOut::Done(u, s) => {
                            counters.merge(&s.counters);
                            st.align_thread_s += s.align_ns as f64 / 1e9;
                            seconds += corpus.utts[idx[k]].seconds;
                            utts.push(*u);
                        }
                        UttOut::Skipped(why, c) => {
                            counters.merge(&c);
                            counters.add(&format!("utterances.skipped.{why}"), 1);
                            skipped.insert(corpus.utts[idx[k]].id.clone(), why);
                        }
                    }
                }
                counters.add("utterances.total", idx.len() as u64);
                let t = Instant::now();
                let info = ShardInfo {
                    split: *split,
                    session,
                    sample,
                    seconds,
                };
                let meta = shard_metadata(
                    args, &m, &corpus, &info, &d, &dict, &utts, &skipped, &counters,
                );
                let trie = learned::TrieFeatures::new(&dict.graph);
                let tables =
                    prep_shard::cand_tables(dict.graph.states(), &|s| dict.graph.candidates(s));
                let (cidx, clog) = rust_logits(dec, &utts, Some(CHECK_ROWS));
                let mut extra = vec![
                    TensorData::i32("check.dec", vec![cidx.len()], &cidx),
                    TensorData::f32("check.logits", vec![cidx.len(), V + DURATIONS.len()], &clog),
                ];
                if args.dec_logits {
                    let (all, logits) = rust_logits(dec, &utts, None);
                    extra.push(TensorData::f32(
                        "dec.logits",
                        vec![all.len(), V + DURATIONS.len()],
                        &logits,
                    ));
                }
                let bytes = prep_shard::shard_bytes(
                    &meta,
                    &trie,
                    &tables,
                    learned::g_size(dict.entries.len()),
                    dec.joint_dim(),
                    &utts,
                    extra,
                )?;
                let path = shard_path(args, ds, *split, session, sample);
                outpath::check_output_dir(path.parent().unwrap())?;
                outpath::write_output(&path, &bytes)?;
                st.write_s += t.elapsed().as_secs_f64();
                st.shard_bytes += bytes.len() as u64;
                st.shards += 1;
                set_counters.merge(&counters);
            }
            st.sessions += 1;
            st.utterances += idx.len();
            st.audio_s += idx.iter().map(|&i| corpus.utts[i].seconds).sum::<f64>();
            eprintln!(
                "[{}/{}] {} {} {session}: {} utterances; {:.0} s so far, peak RSS {} MiB",
                si + 1,
                selected.len(),
                ds.name,
                split.name(),
                idx.len(),
                t_all.elapsed().as_secs_f64(),
                peak_rss_kib() / 1024
            );
        }
        st.counters.merge(&set_counters);
        per_set.insert(
            ds.name.clone(),
            json!({
                "target_rule": corpus.target_rule,
                "speakers": corpus.speakers,
                "counters": set_counters.json(),
                "policy": {
                    "train": corpus.policy(Split::Train, args, &m.identity),
                    "dev": corpus.policy(Split::Dev, args, &m.identity),
                },
            }),
        );
    }
    let index = rebuild_index(&args.out.join("prep"))?;
    let total_s = t_all.elapsed().as_secs_f64();
    let mut report = run_report(args, &st, total_s, &index, all_hours);
    report["sets"] = Value::Object(per_set);
    outpath::write_output(
        &args
            .out
            .join("prep")
            .join(format!("report-{}.json", args.sets_label())),
        serde_json::to_string_pretty(&report).unwrap().as_bytes(),
    )?;
    eprintln!(
        "{}",
        serde_json::to_string_pretty(&report["summary"]).unwrap()
    );
    Ok(())
}

fn run_report(args: &Args, st: &RunStats, total_s: f64, index: &Value, all_hours: f64) -> Value {
    let c = &st.counters;
    let hours = st.audio_s / 3600.0;
    let share = |a: u64, b: u64| (b > 0).then(|| a as f64 / b as f64);
    let samples = args.samples.max(1) as f64;
    let write_in = c.get("write_in.total");
    let corr = c.get("decisions.correction_token") + c.get("decisions.correction_blank");
    let pres = c.get("decisions.preservation_token") + c.get("decisions.preservation_blank");
    let attempted = c.get("utterances.aligned") + c.get("utterances.unreachable");
    let per_hour = |s: f64| if hours > 0.0 { s / hours } else { f64::NAN };
    let reverted: u64 =
        c.0.iter()
            .filter(|(k, _)| k.contains(".reverted."))
            .map(|(_, v)| v)
            .sum();
    json!({
        "seed": args.seed,
        "samples": args.samples,
        "threads": args.threads,
        "sessions": st.sessions,
        "utterances": st.utterances,
        "audio_hours": hours,
        "shards": st.shards,
        "shard_bytes": st.shard_bytes,
        "seconds": {
            "total": total_s, "encode_or_cache_load": st.encode_s, "baseline_wall": st.baseline_s,
            "baseline_decode_thread": st.baseline_thread_s, "prepare_wall": st.prepare_s,
            "repair_align_thread": st.align_thread_s, "write": st.write_s,
        },
        "counters": c.json(),
        "summary": {
            "alignment_utterances_per_thread_second": attempted as f64 / st.align_thread_s.max(1e-9),
            "alignment_audio_hours_per_wall_hour": (st.prepare_s > 0.0).then(|| hours * samples * 3600.0 / st.prepare_s),
            "peak_rss_mib": peak_rss_kib() as f64 / 1024.0,
            "shard_mib_per_audio_hour": per_hour(st.shard_bytes as f64 / 1048576.0),
            "shard_mib_per_audio_hour_per_sample": per_hour(st.shard_bytes as f64 / 1048576.0) / samples,
            "unreachable_share": share(c.get("utterances.unreachable"), attempted),
            "write_in_applied_share": share(c.get("write_in.applied"), write_in),
            "write_in_not_phrase_share": share(c.get("write_in.reverted.not_phrase_variant"), write_in),
            "units_reverted": reverted,
            "false_alarm_applied_share": share(c.get("false_alarm.applied"), c.get("false_alarm.total")),
            "remove_applied_share": share(c.get("remove.applied"), c.get("remove.total")),
            "correction_decision_share": share(corr, corr + pres),
            "unchanged_on_greedy_frames_share": share(c.get("utterances.unchanged_greedy_frames"), c.get("utterances.unchanged")),
            "greedy_replay_mismatches": st.replay_mismatch,
            "hypothesis_text_errors": st.hyp_text_errors,
            "projection_all_sessions": {
                "audio_hours": all_hours,
                "decode_prepare_write_hours": per_hour(st.baseline_s + st.prepare_s + st.write_s) * all_hours / 3600.0,
                "shard_gib": per_hour(st.shard_bytes as f64) * all_hours / 1073741824.0,
                "encoder_cache_gib": all_hours * 3600.0 / 0.08 * 640.0 * 4.0 / 1073741824.0,
            },
        },
        "index_totals": index["totals"],
        "index_complete": index["complete"],
    })
}

/// The shards of one (dataset, split) seen by [`rebuild_index`].
struct IndexGroup {
    policy: Value,
    policy_sha256: String,
    split_sessions: usize,
    split_sessions_sha256: String,
    samples: u64,
    /// (session, sample) of every shard present.
    present: BTreeSet<(String, u64)>,
}

impl IndexGroup {
    /// Every session of the split has every sample `0..samples`: the
    /// sessions present hash to `split_sessions_sha256`, and no sample is
    /// missing or out of range.
    fn complete(&self) -> bool {
        let sessions: BTreeSet<String> = self.present.iter().map(|(s, _)| s.clone()).collect();
        sessions.len() == self.split_sessions
            && session_set_sha256(&sessions) == self.split_sessions_sha256
            && self.present.iter().all(|&(_, k)| k < self.samples)
            && self.present.len() as u64 == self.split_sessions as u64 * self.samples
    }
}

/// Rebuilds `prep/index.json` from the metadata of every shard present:
/// per split the shard list and totals; per dataset its policy (which every
/// shard of a dataset and split must share, else this fails) and
/// completeness (`split_sessions` x `samples` shards expected).
fn rebuild_index(prep: &Path) -> Result<Value, String> {
    let mut splits = serde_json::Map::new();
    let mut grand: BTreeMap<String, f64> = BTreeMap::new();
    let mut groups: BTreeMap<(String, String), IndexGroup> = BTreeMap::new();
    for split in ["train", "dev"] {
        let dir = prep.join(split);
        let mut files: Vec<PathBuf> = match std::fs::read_dir(&dir) {
            Ok(rd) => rd
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "safetensors"))
                .collect(),
            Err(_) => Vec::new(),
        };
        files.sort();
        let mut shards = Vec::new();
        let mut totals: BTreeMap<String, f64> = BTreeMap::new();
        for f in &files {
            let meta = read_metadata(f)?;
            let get = |k: &str| meta.get(k).cloned().unwrap_or_default();
            let num = |k: &str| {
                meta.get(k)
                    .and_then(|v| v.parse::<f64>().ok())
                    .unwrap_or(0.0)
            };
            if get("split") != split {
                return Err(format!(
                    "{}: metadata split {:?} in the {split} directory",
                    f.display(),
                    get("split")
                ));
            }
            let policy: Value = serde_json::from_str(&get("policy")).unwrap_or(Value::Null);
            let key = (get("dataset"), split.to_owned());
            let entry = groups.entry(key.clone()).or_insert_with(|| IndexGroup {
                policy: policy.clone(),
                policy_sha256: get("policy_sha256"),
                split_sessions: num("split_sessions") as usize,
                split_sessions_sha256: get("split_sessions_sha256"),
                samples: num("samples") as u64,
                present: BTreeSet::new(),
            });
            if entry.policy_sha256 != get("policy_sha256")
                || entry.split_sessions != num("split_sessions") as usize
                || entry.split_sessions_sha256 != get("split_sessions_sha256")
                || entry.samples != num("samples") as u64
            {
                return Err(format!(
                    "{}: {} {} shards disagree on their policy; regenerate them together",
                    f.display(),
                    key.0,
                    key.1
                ));
            }
            if !entry.present.insert((get("session"), num("sample") as u64)) {
                return Err(format!(
                    "{}: duplicate session and sample in {} {}",
                    f.display(),
                    key.0,
                    key.1
                ));
            }
            let bytes = std::fs::metadata(f).map(|m| m.len()).unwrap_or(0) as f64;
            for (k, v) in [
                ("shards", 1.0),
                ("utterances", num("utterances")),
                ("decisions", num("decisions")),
                ("corrections", num("corrections")),
                ("frames", num("frames")),
                ("audio_seconds", num("audio_seconds")),
                ("bytes", bytes),
            ] {
                *totals.entry(k.into()).or_default() += v;
                *grand.entry(k.into()).or_default() += v;
            }
            shards.push(json!({
                "path": format!("{split}/{}", f.file_name().unwrap().to_string_lossy()),
                "dataset": get("dataset"), "call": get("call"), "session": get("session"),
                "split": get("split"), "sample": num("sample"),
                "policy_sha256": get("policy_sha256"), "df_source_sha256": get("df_source_sha256"),
                "utterances": num("utterances"), "decisions": num("decisions"),
                "corrections": num("corrections"), "frames": num("frames"),
                "audio_seconds": num("audio_seconds"), "entries": num("entries"),
                "nodes": num("nodes"), "bytes": bytes,
            }));
        }
        splits.insert(split.into(), json!({"shards": shards, "totals": totals}));
    }
    let mut datasets = serde_json::Map::new();
    let mut complete = !groups.is_empty();
    for ((ds, split), g) in groups {
        let c = g.complete();
        complete &= c;
        let d = datasets.entry(ds).or_insert_with(|| json!({"splits": {}}));
        d["splits"][split] = json!({
            "policy": g.policy,
            "policy_sha256": g.policy_sha256,
            "split_sessions": g.split_sessions,
            "split_sessions_sha256": g.split_sessions_sha256,
            "samples": g.samples,
            "expected_shards": g.split_sessions as u64 * g.samples,
            "present_shards": g.present.len(),
            "complete": c,
        });
    }
    let index = json!({
        "format": "lf-bias-prep-index-v2",
        "shard_format": prep_shard::SHARD_FORMAT,
        "splits": splits,
        "datasets": datasets,
        "complete": complete,
        "totals": grand,
    });
    outpath::check_output_dir(prep)?;
    outpath::write_output(
        &prep.join("index.json"),
        serde_json::to_string_pretty(&index).unwrap().as_bytes(),
    )?;
    Ok(index)
}

/// The `__metadata__` of a safetensors file, reading only its header.
fn read_metadata(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let err = |e: std::io::Error| format!("{}: {e}", path.display());
    let mut f = std::fs::File::open(path).map_err(err)?;
    let mut len = [0u8; 8];
    f.read_exact(&mut len).map_err(err)?;
    let n = u64::from_le_bytes(len) as usize;
    if n > 1 << 26 {
        return Err(format!("{}: header too large", path.display()));
    }
    let mut header = vec![0u8; n];
    f.read_exact(&mut header).map_err(err)?;
    let v: Value =
        serde_json::from_slice(&header).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(v.get("__metadata__")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_owned())))
                .collect()
        })
        .unwrap_or_default())
}

// ---------------------------------------------------------------- gate

/// Experiment 1's chosen configuration at `alpha` (the oracle varies alpha).
fn exp1_config(alpha: f32) -> BiasConfig {
    BiasConfig {
        alpha,
        context_score: 1.0,
        depth_scaling: 3.0,
        cancel_unfinished: false,
    }
}

/// One (utterance, missed target) of the gate.
struct Probe {
    set: usize,
    utt: usize,
    /// `dataset/session`.
    call: String,
    /// The target's normalized form (words joined by spaces).
    word: String,
    entry: String,
    /// The surfaces the dictionary encodes the entry from.
    surfaces: Vec<String>,
    refs: Vec<String>,
    base_matched: usize,
    missed: usize,
    reachable: usize,
    frames: usize,
    proj: std::sync::Arc<Projected>,
}

/// What the gate aggregates of one probe.
struct ProbeStat<'a> {
    set: usize,
    call: &'a str,
    word: &'a str,
    missed: usize,
    reachable: usize,
}

/// Gate totals over the probes of the selected sets.
#[derive(Debug, PartialEq)]
struct GateTotals {
    /// Summed missed occurrences.
    missed: usize,
    /// The union of normalized missed targets: a word missed in two
    /// datasets counts once.
    words: BTreeSet<String>,
    reachable: usize,
    /// `dataset/session` ids with a miss.
    sessions: BTreeSet<String>,
}

fn gate_totals(stats: &[ProbeStat], sel: &dyn Fn(usize) -> bool) -> GateTotals {
    let ps: Vec<&ProbeStat> = stats.iter().filter(|p| sel(p.set)).collect();
    GateTotals {
        missed: ps.iter().map(|p| p.missed).sum(),
        words: ps.iter().map(|p| p.word.to_owned()).collect(),
        reachable: ps.iter().map(|p| p.reachable).sum(),
        sessions: ps.iter().map(|p| p.call.to_owned()).collect(),
    }
}

/// The oracle's probes: a seeded shuffle of every probe of every set (the
/// combined population), taken in order until at least `occurrences` missed
/// occurrences are covered (`missed[i]` per probe).
fn oracle_sample(missed: &[usize], occurrences: usize, seed: u64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..missed.len()).collect();
    bias_lists::shuffle(&mut order, seed ^ 0x6a7e);
    let mut sample = Vec::new();
    let mut covered = 0;
    for i in order {
        if covered >= occurrences {
            break;
        }
        covered += missed[i];
        sample.push(i);
    }
    sample
}

/// Occurrences of the normalized target `target` (one or more words) in
/// `words`, as start positions.
fn target_positions(words: &[String], target: &[String]) -> Vec<usize> {
    if target.is_empty() || target.len() > words.len() {
        return Vec::new();
    }
    (0..=words.len() - target.len())
        .filter(|&i| words[i..i + target.len()] == *target)
        .collect()
}

/// Reference occurrences of `target` matched word for word in the alignment.
fn matched_occurrences(refs: &[String], hyp: &[String], target: &[String]) -> usize {
    let ops = bias_metrics::align(refs, hyp);
    let mut code_of = vec![bias_metrics::Code::Del; refs.len()];
    for (c, r, _) in &ops {
        if let Some(r) = r {
            code_of[*r] = *c;
        }
    }
    target_positions(refs, target)
        .into_iter()
        .filter(|&i| (i..i + target.len()).all(|r| code_of[r] == bias_metrics::Code::Match))
        .count()
}

/// Per-dataset gate counts.
#[derive(Default)]
struct GateCounts {
    sessions: usize,
    utterances: usize,
    target_occ: usize,
    target_words: BTreeSet<String>,
    ex_occ: usize,
    ex_missed: usize,
    ex_words: BTreeSet<String>,
    ex_missed_words: BTreeSet<String>,
}

fn examples(set: &BTreeSet<String>) -> Vec<String> {
    let v: Vec<&String> = set.iter().collect();
    let k = v.len().min(10);
    (0..k).map(|i| v[i * v.len() / k].clone()).collect()
}

fn run_gate(args: &Args) -> Result<(), String> {
    let t_all = Instant::now();
    let mut m = load_models(args)?;
    let mut probes: Vec<Probe> = Vec::new();
    let mut corpora = Vec::new();
    let mut counts = Vec::new();
    for (si, set) in args.sets.iter().enumerate() {
        let corpus = corpus(set, &args.word_counts)?;
        let selected = corpus.selected(SplitSel::Train, args.sessions);
        let mut gc = GateCounts {
            sessions: selected.len(),
            ..Default::default()
        };
        for (k_sess, (_, session)) in selected.iter().enumerate() {
            let idx = &corpus.sessions[session];
            let proj = session_projections(args, &mut m, &corpus, session)?;
            let dec = &m.model.decoder;
            let tok = &m.model.tokenizer;
            let positions: Vec<usize> = (0..idx.len()).collect();
            let hyps = run_workers(
                args.threads,
                &positions,
                &|&k| proj[k].frames,
                &|pool, &k| {
                    let e = dec.decode(pool, &proj[k].proj, proj[k].frames, None, None);
                    let toks: Vec<usize> = e.iter().map(|x| x.0).collect();
                    normalize(&tok.decode(&toks).unwrap_or_default())
                },
            );
            let targets: BTreeMap<&str, &str> = corpus.targets[session]
                .iter()
                .map(|(n, s)| (n.as_str(), s.as_str()))
                .collect();
            let proj: Vec<std::sync::Arc<Projected>> =
                proj.into_iter().map(std::sync::Arc::new).collect();
            for (k, hyp) in hyps.iter().enumerate() {
                let u = &corpus.utts[idx[k]];
                let cased = bias_lists::cased_words(&u.text);
                let refs: Vec<String> = cased.iter().map(|(n, _)| n.clone()).collect();
                if refs != normalize(&u.text) {
                    continue;
                }
                gc.utterances += 1;
                // Rare words the document-frequency rule excluded, for the report.
                let excluded: BTreeSet<&str> = refs
                    .iter()
                    .map(String::as_str)
                    .filter(|w| corpus.df_excluded.contains(*w))
                    .collect();
                for w in excluded {
                    let refcount = refs.iter().filter(|r| *r == w).count();
                    let missed = refcount - bias_metrics::matched(&refs, hyp, w).min(refcount);
                    gc.ex_occ += refcount;
                    gc.ex_missed += missed;
                    gc.ex_words.insert(w.to_owned());
                    if missed > 0 {
                        gc.ex_missed_words.insert(w.to_owned());
                    }
                }
                for (&norm, &entry) in &targets {
                    let target: Vec<String> = norm.split(' ').map(str::to_owned).collect();
                    let pos = target_positions(&refs, &target);
                    if pos.is_empty() {
                        continue;
                    }
                    gc.target_words.insert(norm.to_owned());
                    let refcount = pos.len();
                    gc.target_occ += refcount;
                    let matched = matched_occurrences(&refs, hyp, &target).min(refcount);
                    if matched >= refcount {
                        continue;
                    }
                    // Reachable: a missed occurrence's reference spelling is a
                    // phrase variant of the session's entry (its surfaces as
                    // the dictionary builds them).
                    let rule = corpus.entry_rule(session);
                    let entry_n = rule.entry(entry);
                    let surfaces = rule.surfaces(entry);
                    let variants: HashSet<Vec<usize>> = lf_asr::bias::phrases(tok, &surfaces, true)
                        .map(|p| p.into_iter().collect())
                        .unwrap_or_default();
                    let ops = bias_metrics::align(&refs, hyp);
                    let mut code_of = vec![bias_metrics::Code::Del; refs.len()];
                    for (c, r, _) in &ops {
                        if let Some(r) = r {
                            code_of[*r] = *c;
                        }
                    }
                    let reachable = pos
                        .iter()
                        .filter(|&&i| {
                            (i..i + target.len()).any(|r| code_of[r] != bias_metrics::Code::Match)
                        })
                        .filter(|&&i| {
                            let surface: Vec<&str> = cased[i..i + target.len()]
                                .iter()
                                .map(|(_, s)| s.as_str())
                                .collect();
                            let surface = match corpus.casing(session) {
                                Casing::Cased => surface.join(" "),
                                Casing::Uncased => surface.join(" ").to_lowercase(),
                            };
                            tok.encode(&surface).is_ok_and(|t| variants.contains(&t))
                        })
                        .count();
                    probes.push(Probe {
                        set: si,
                        utt: idx[k],
                        call: corpus.set.dataset.call_id(session),
                        word: norm.to_owned(),
                        entry: entry_n,
                        surfaces,
                        refs: refs.clone(),
                        base_matched: matched,
                        missed: refcount - matched,
                        reachable,
                        frames: proj[k].frames,
                        proj: proj[k].clone(),
                    });
                }
            }
            eprintln!(
                "[{}/{}] {} {session}: {} probes so far",
                k_sess + 1,
                selected.len(),
                set.dataset.name,
                probes.len()
            );
        }
        corpora.push(corpus);
        counts.push(gc);
    }

    // Experiment 1's oracle on a seeded sample of the combined probes
    // covering `--oracle-occurrences` missed occurrences.
    let missed_by_probe: Vec<usize> = probes.iter().map(|p| p.missed).collect();
    let sample = oracle_sample(&missed_by_probe, args.oracle_occurrences, args.seed);
    let grid: Vec<f32> = (-4..=8).map(|k| 2f32.powf(k as f32 / 2.0)).collect();
    let jobs: Vec<(usize, usize)> = sample
        .iter()
        .flat_map(|&p| (0..grid.len()).map(move |a| (p, a)))
        .collect();
    let dec = &m.model.decoder;
    let tok = &m.model.tokenizer;
    let results = run_workers(
        args.threads,
        &jobs,
        &|&(p, _)| probes[p].frames,
        &|pool, &(p, a)| -> Result<usize, String> {
            let pr = &probes[p];
            let ph = lf_asr::bias::phrases(tok, &pr.surfaces, true).map_err(|e| e.to_string())?;
            let g = BiasGraph::new(&ph, VOCAB, exp1_config(grid[a]))?;
            let e = dec.decode(pool, &pr.proj.proj, pr.proj.frames, None, Some(&g));
            let toks: Vec<usize> = e.iter().map(|x| x.0).collect();
            let words = normalize(&tok.decode(&toks).unwrap_or_default());
            let target: Vec<String> = pr.word.split(' ').map(str::to_owned).collect();
            Ok(matched_occurrences(&pr.refs, &words, &target))
        },
    );
    let results: Vec<usize> = results.into_iter().collect::<Result<_, _>>()?;
    let mut first: Vec<(usize, Option<usize>)> = Vec::new();
    let mut lines = String::new();
    for (k, &p) in sample.iter().enumerate() {
        let pr = &probes[p];
        let matched = &results[k * grid.len()..(k + 1) * grid.len()];
        let f = bias_metrics::occurrence_first_recovery(pr.base_matched, pr.missed, matched);
        lines.push_str(
            &json!({"dataset": corpora[pr.set].set.dataset.name, "id": corpora[pr.set].utts[pr.utt].id,
                    "word": pr.word, "entry": pr.entry, "missed": pr.missed, "reachable": pr.reachable,
                    "first_alpha": f.iter().map(|x| x.map(|a| grid[a])).collect::<Vec<_>>()})
            .to_string(),
        );
        lines.push('\n');
        first.extend(f.into_iter().map(|x| (pr.set, x)));
    }
    let oracle_of = |sel: &dyn Fn(usize) -> bool| -> Value {
        let occ: Vec<Option<usize>> = first.iter().filter(|(s, _)| sel(*s)).map(|x| x.1).collect();
        let mut mins: Vec<f64> = occ.iter().flatten().map(|&a| grid[a] as f64).collect();
        mins.sort_by(f64::total_cmp);
        let q = |p: f64| {
            (!mins.is_empty()).then(|| mins[((mins.len() - 1) as f64 * p).round() as usize])
        };
        json!({
            "occurrences": occ.len(),
            "recoverable_on_grid": mins.len(),
            "recoverable_share": (!occ.is_empty()).then(|| mins.len() as f64 / occ.len() as f64),
            "min_alpha_quantiles": {"p10": q(0.1), "p25": q(0.25), "p50": q(0.5), "p75": q(0.75), "p90": q(0.9)},
        })
    };
    let stats: Vec<ProbeStat> = probes
        .iter()
        .map(|p| ProbeStat {
            set: p.set,
            call: &p.call,
            word: &p.word,
            missed: p.missed,
            reachable: p.reachable,
        })
        .collect();
    let summary_of = |sel: &dyn Fn(usize) -> bool| {
        let t = gate_totals(&stats, sel);
        (t.missed, t.words, t.reachable, t.sessions)
    };
    let dir = args.out.join("gate");
    outpath::check_output_dir(&dir)?;
    let mut per_dataset = serde_json::Map::new();
    for (si, (c, gc)) in corpora.iter().zip(&counts).enumerate() {
        let (missed, words, reachable, sessions) = summary_of(&|s| s == si);
        let report = json!({
            "dataset": c.set.dataset.name,
            "manifests": c.set.manifests.iter().map(|m| m.path.display().to_string()).collect::<Vec<_>>(),
            "manifest_sha256": c.manifest_sha256,
            "target_rule": c.target_rule,
            "rare_rule": c.rare_rule,
            "df_source": c.df_source(Split::Train).0,
            "df_source_sha256": c.df_source(Split::Train).1,
            "speakers": c.speakers,
            "sessions": gc.sessions,
            "utterances": gc.utterances,
            "target_words": gc.target_words.len(),
            "target_occurrences": gc.target_occ,
            "missed_occurrences": missed,
            "distinct_missed_words": words.len(),
            "sessions_with_misses": sessions.len(),
            "candidate_reachable_occurrences": reachable,
            "candidate_reachable_share": (missed > 0).then(|| reachable as f64 / missed as f64),
            "oracle_from_combined_sample": oracle_of(&|s| s == si),
            "target_filter": {
                "description": "targets versus rare words excluded as not session-specific; 'before' (rare only) = targets + excluded",
                "excluded_words": gc.ex_words.len(),
                "excluded_occurrences": gc.ex_occ,
                "excluded_missed_occurrences": gc.ex_missed,
                "excluded_distinct_missed_words": gc.ex_missed_words.len(),
                "before": {
                    "target_words": gc.target_words.len() + gc.ex_words.len(),
                    "target_occurrences": gc.target_occ + gc.ex_occ,
                    "missed_occurrences": missed + gc.ex_missed,
                    "distinct_missed_words": words.len() + gc.ex_missed_words.len(),
                },
                "examples_target_missed": examples(&words),
                "examples_excluded_missed": examples(&gc.ex_missed_words),
            },
        });
        outpath::write_output(
            &dir.join(format!("{}.json", c.set.dataset.name)),
            serde_json::to_string_pretty(&report).unwrap().as_bytes(),
        )?;
        per_dataset.insert(c.set.dataset.name.clone(), report);
    }
    let (missed, words, reachable, sessions) = summary_of(&|_| true);
    let pass = missed >= 5000 && words.len() >= 2000;
    let gate = json!({
        "description": "combined training mix: every given set's train sessions; distinct words are the union of normalized targets",
        "sets": args.sets.iter().map(|s| s.dataset.name.clone()).collect::<Vec<_>>(),
        "sessions": counts.iter().map(|c| c.sessions).sum::<usize>(),
        "utterances": counts.iter().map(|c| c.utterances).sum::<usize>(),
        "target_occurrences": counts.iter().map(|c| c.target_occ).sum::<usize>(),
        "missed_occurrences": missed,
        "distinct_missed_words": words.len(),
        "sessions_with_misses": sessions.len(),
        "candidate_reachable_occurrences": reachable,
        "candidate_reachable_share": (missed > 0).then(|| reachable as f64 / missed as f64),
        "candidate_reachable_definition": "the missed occurrence's reference spelling (casing-normalized) encodes to a phrase variant (case variants on) of its session's entry",
        "pass": pass,
        "thresholds": {"missed_occurrences": 5000, "distinct_missed_words": 2000},
        "oracle": {
            "procedure": "experiment 1's: per (utterance, missed target), a one-entry dictionary (case variants on, depth 3, cancel off) at alpha 2^(k/2), k=-4..8; occurrence j counts as recovered from the first alpha whose matched gain reaches j; probes sampled from the combined population",
            "probes": sample.len(),
            "grid": grid,
            "combined": oracle_of(&|_| true),
        },
        "per_dataset": per_dataset,
        "seconds": t_all.elapsed().as_secs_f64(),
        "peak_rss_mib": peak_rss_kib() as f64 / 1024.0,
    });
    let label = args.sets_label();
    outpath::write_output(&dir.join(format!("probes-{label}.jsonl")), lines.as_bytes())?;
    outpath::write_output(
        &dir.join(format!("combined-{label}.json")),
        serde_json::to_string_pretty(&gate).unwrap().as_bytes(),
    )?;
    eprintln!("{}", serde_json::to_string_pretty(&gate).unwrap());
    Ok(())
}

// ---------------------------------------------------------------- main

fn main() -> ExitCode {
    let run = || -> Result<(), String> {
        let args = parse_args(std::env::args().skip(1))?;
        outpath::check_output_dir(&args.out)?;
        outpath::check_output_dir(&args.cache)?;
        match args.cmd {
            Cmd::Prep => run_prep(&args),
            Cmd::Gate => run_gate(&args),
        }
    };
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_cpu::decoder::DecoderParams;
    use lf_model::SafeTensors;
    use lf_model::half::{f16_to_f32, f32_to_f16};
    use lf_model::rng::SplitMix64;
    use lf_model::safetensors::Dtype;

    const FIXTURE: &str = "tests/fixtures/prep-shard.safetensors";

    fn argv(extra: &[&str]) -> Vec<String> {
        let mut v: Vec<String> = [
            "prep",
            "--export",
            "e",
            "--word-counts",
            "w",
            "--cache",
            "c",
            "--out",
            "o",
        ]
        .map(String::from)
        .to_vec();
        v.extend(extra.iter().map(|s| s.to_string()));
        v
    }

    /// `parse_args` without the environment's experiment root.
    fn pa(v: Vec<String>) -> Result<Args, String> {
        parse_args_with_root(v, None)
    }

    #[test]
    fn arguments_parse_and_validate() {
        let a = pa(argv(&["--manifest", "m"])).unwrap();
        assert_eq!(
            (a.cmd, a.split, a.samples, a.seed, a.threads),
            (Cmd::Prep, SplitSel::Train, 2, 20_261_011, 16)
        );
        assert_eq!(a.sets.len(), 1);
        let d = &a.sets[0].dataset;
        assert_eq!((d.name.as_str(), d.spgi), ("spgispeech", true));
        assert_eq!(a.sets[0].manifests[0].casing, Casing::Cased);
        assert_eq!(d.shard_prefix, "");
        // Several sets; casing must be declared except for SPGISpeech, per
        // manifest (SlideSpeech train is uncased, dev cased).
        let a = pa(argv(&[
            "--set",
            "name=spgispeech,manifest=a.jsonl",
            "--set",
            "name=icsi,manifest=b.jsonl,casing=uncased",
            "--set",
            "name=slidespeech,manifest=t.jsonl,casing=uncased,manifest=d.jsonl,casing=cased,targets=keywords,keywords=k.json",
            "--split",
            "all",
        ]))
        .unwrap();
        assert_eq!(a.sets_label(), "spgispeech+icsi+slidespeech");
        assert_eq!(a.sets[1].manifests[0].casing, Casing::Uncased);
        assert_eq!(a.sets[1].dataset.shard_prefix, "icsi.");
        assert!(a.sets[2].keyword_targets);
        let casings: Vec<Casing> = a.sets[2].manifests.iter().map(|m| m.casing).collect();
        assert_eq!(casings, [Casing::Uncased, Casing::Cased]);
        // Each casing= belongs to the manifest= before it.
        assert!(pa(argv(&["--set", "name=icsi,casing=cased,manifest=b"])).is_err());
        assert!(
            pa(argv(&[
                "--set",
                "name=icsi,manifest=b,casing=cased,casing=cased"
            ]))
            .is_err()
        );
        assert!(
            pa(argv(&[
                "--set",
                "name=icsi,manifest=a,casing=cased,manifest=b"
            ]))
            .is_err()
        );
        assert!(pa(argv(&["--set", "name=icsi"])).is_err());
        assert!(pa(argv(&["--set", "name=icsi,manifest=b"])).is_err());
        assert!(pa(argv(&["--manifest", "m", "--dataset", "icsi"])).is_err());
        assert!(
            pa(argv(&[
                "--set",
                "name=spgispeech,manifest=a",
                "--manifest",
                "m"
            ]))
            .is_err()
        );
        assert!(
            pa(argv(&[
                "--set",
                "name=spgispeech,manifest=a",
                "--set",
                "name=spgispeech,manifest=b"
            ]))
            .is_err()
        );
        assert!(pa(argv(&["--manifest", "m", "--threads", "32"])).is_err());
        assert!(pa(argv(&["--manifest", "m", "--keywords", "k.json"])).is_err());
        assert!(
            pa(argv(&[
                "--manifest",
                "m",
                "--dataset",
                "../x",
                "--casing",
                "cased"
            ]))
            .is_err()
        );
        assert!(pa(argv(&["--manifest", "m", "--bogus"])).is_err());
        assert!(pa(argv(&[])).is_err());
        let mut gate = argv(&["--manifest", "m", "--split", "dev"]);
        gate[0] = "gate".into();
        assert!(pa(gate).is_err());
    }

    #[test]
    fn cache_and_out_default_to_the_experiment_root() {
        let bare = |extra: &[&str]| -> Vec<String> {
            let mut v: Vec<String> = [
                "prep",
                "--export",
                "e",
                "--word-counts",
                "w",
                "--manifest",
                "m",
            ]
            .map(String::from)
            .to_vec();
            v.extend(extra.iter().map(|s| s.to_string()));
            v
        };
        // Without LF_EXP2_ROOT and without the flags: a clear error.
        let e = parse_args_with_root(bare(&[]), None).err().unwrap();
        assert!(e.contains("LF_EXP2_ROOT"), "{e}");
        let a = parse_args_with_root(bare(&[]), Some(PathBuf::from("W"))).unwrap();
        assert_eq!(
            (a.cache, a.out),
            (PathBuf::from("W/cache"), PathBuf::from("W"))
        );
        // Flags win over the root.
        let a = parse_args_with_root(bare(&["--out", "o"]), Some(PathBuf::from("W"))).unwrap();
        assert_eq!(
            (a.cache, a.out),
            (PathBuf::from("W/cache"), PathBuf::from("o"))
        );
    }

    #[test]
    fn keyword_entries_keep_original_and_lowercase_surfaces() {
        // SlideSpeech keywords are all-uppercase OCR. A keyword entry is
        // encoded from both its original and lowercase surfaces (union of
        // their case variants), whatever the references' casing; rare-word
        // entries keep normalize_entry_surface.
        let s = Scratch::new("kwcase");
        let line = |sess: &str, kw: &str| {
            json!({"id": format!("{sess}_0"), "audio_filepath": "/x.flac", "duration": 1.0,
                   "text": "The Neural Network.", "session": sess, "split": "train", "keywords": [kw]})
        };
        let m = s.manifest(
            "kw.jsonl",
            &[line("a", "NEURAL NETWORK"), line("b", "QUAXEL")],
        );
        let kw = corpus(
            &s.set("slidespeech", &m, ",casing=cased,targets=keywords"),
            &s.counts,
        )
        .unwrap();
        assert_eq!(kw.casing("a"), Casing::Cased);
        assert_eq!(kw.entry_rule("a"), EntryRule::Keyword);
        let rare = corpus(&s.set("slidespeech", &m, ",casing=uncased"), &s.counts).unwrap();
        assert_eq!(rare.entry_rule("a"), EntryRule::Normalized(Casing::Uncased));
        let t = prep_targets::tests::tok();
        let entries = vec![
            "NEURAL NETWORK".to_owned(),
            "QUAXEL".to_owned(),
            "GPU".to_owned(),
            "gpu".to_owned(),
        ];
        let d = build_dict(&t, entries, EntryRule::Keyword).unwrap();
        // Entries count keywords, not surfaces; "gpu" is the same keyword.
        assert_eq!(d.entries, ["NEURAL NETWORK", "QUAXEL", "GPU"]);
        for variant in [
            "NEURAL NETWORK",
            "Neural Network",
            "Neural network",
            "neural network",
            "Quaxel",
            "QUAXEL",
            "GPU",
            "gpu",
            "Gpu",
        ] {
            assert!(
                d.phrase_set.contains(&t.encode(variant).unwrap()),
                "{variant}"
            );
        }
    }

    #[test]
    fn audit_manifests_count_speakers_but_are_never_prepared() {
        // The ICSI eval split feeds the train<->held-out speaker audit only.
        let s = Scratch::new("audit");
        let line = |sess: &str, split: &str, spk: &str| {
            json!({"id": format!("{sess}_{spk}"), "audio_filepath": "/x.flac", "duration": 1.0,
                   "text": "the quaxel met", "session": sess, "split": split, "speaker": spk})
        };
        let train = s.manifest(
            "train.jsonl",
            &[line("a", "train", "me011"), line("b", "train", "fe008")],
        );
        let eval = s.manifest(
            "eval.jsonl",
            &[line("e1", "eval", "me011"), line("e2", "eval", "mn999")],
        );
        let spec = |audit: &Path| {
            format!(
                "name=icsi,manifest={},casing=cased,audit={}",
                train.display(),
                audit.display()
            )
        };
        let c = corpus(&parse_set(&spec(&eval)).unwrap(), &s.counts).unwrap();
        assert_eq!(c.sessions.keys().collect::<Vec<_>>(), ["a", "b"]);
        assert!(
            c.selected(SplitSel::All, None)
                .iter()
                .all(|(sp, _)| *sp == Split::Train)
        );
        assert_eq!(c.speakers["heldout"]["speakers"], 2);
        assert_eq!(c.speakers["heldout"]["shared_with_train"], 1);
        assert_eq!(c.speakers["heldout"]["examples"], json!(["me011"]));
        assert_eq!(c.df[&Split::Train].df.sessions(), 2);
        // An audit manifest may not hold train lines or prepared sessions.
        let bad = s.manifest("bad.jsonl", &[line("e1", "train", "x")]);
        assert!(corpus(&parse_set(&spec(&bad)).unwrap(), &s.counts).is_err());
        let bad = s.manifest("bad2.jsonl", &[line("a", "eval", "x")]);
        assert!(corpus(&parse_set(&spec(&bad)).unwrap(), &s.counts).is_err());
    }

    #[test]
    fn acronym_keywords_are_written_in() {
        // Regression: with lowercase-only keyword surfaces, the cased
        // reference "GPU" was no phrase variant and the write-in reverted.
        let t = prep_targets::tests::tok();
        let repair = |d: &Dict| {
            let hyp = t.encode("we met the team").unwrap();
            let ht = prep_targets::hyp_text(&t, &hyp).unwrap();
            let view = DictView {
                entries: &d.words,
                phrases: &d.phrase_set,
            };
            prep_targets::repair(&t, &hyp, &ht, "We met GPU the team.", &view, Casing::Cased)
                .unwrap()
        };
        let d = build_dict(&t, vec!["GPU".to_owned()], EntryRule::Keyword).unwrap();
        let tg = repair(&d);
        assert_eq!(tg.units[0].revert, None);
        assert_eq!(t.decode(&tg.tokens).unwrap(), "we met GPU the team");
        let lower_only = build_dict(
            &t,
            vec!["GPU".to_owned()],
            EntryRule::Normalized(Casing::Uncased),
        )
        .unwrap();
        assert_eq!(
            repair(&lower_only).units[0].revert,
            Some(prep_targets::Revert::NotPhrase)
        );
    }

    #[test]
    fn casing_is_per_manifest_and_dev_uses_train_df() {
        // SlideSpeech: an uncased train manifest and a cased dev manifest in
        // one set. Casing follows each session's manifest; dev targets use
        // the train DF; ids and session casings must not clash.
        let s = Scratch::new("permanifest");
        let line = |sess: &str, j: usize, split: &str, text: &str| {
            json!({"id": format!("{sess}_{j}"), "audio_filepath": "/x.flac", "duration": 1.0,
                   "text": text, "session": sess, "split": split})
        };
        let train = s.manifest(
            "train.jsonl",
            &[
                line("a", 0, "train", "the zorbin met"),
                line("b", 0, "train", "the quaxel met"),
            ],
        );
        let dev = s.manifest(
            "dev.jsonl",
            &[line("c", 0, "dev", "The Plinth met the Zorbin.")],
        );
        let spec = format!(
            "name=slidespeech,manifest={},casing=uncased,manifest={},casing=cased",
            train.display(),
            dev.display()
        );
        let c = corpus(&parse_set(&spec).unwrap(), &s.counts).unwrap();
        assert_eq!(
            (c.casing("a"), c.casing("c")),
            (Casing::Uncased, Casing::Cased)
        );
        assert_eq!(c.split_casing(Split::Train), "uncased");
        assert_eq!(c.split_casing(Split::Dev), "cased");
        assert_eq!(
            (c.df[&Split::Dev].split, c.df[&Split::Dev].df.sessions()),
            (Split::Train, 2)
        );
        let (src, _) = c.df_source(Split::Dev);
        assert_eq!(src["manifests"].as_array().unwrap().len(), 1);
        assert_eq!(src["manifests"][0]["path"], train.display().to_string());
        assert_eq!(c.targets["c"].len(), 2);
        // The same id twice, or one session in both manifests, fails.
        let dup = s.manifest("dup.jsonl", &[line("a", 0, "dev", "x")]);
        let spec = format!(
            "name=slidespeech,manifest={},casing=uncased,manifest={},casing=cased",
            train.display(),
            dup.display()
        );
        assert!(corpus(&parse_set(&spec).unwrap(), &s.counts).is_err());
        let clash = s.manifest("clash.jsonl", &[line("a", 9, "train", "x")]);
        let spec = format!(
            "name=slidespeech,manifest={},casing=uncased,manifest={},casing=cased",
            train.display(),
            clash.display()
        );
        assert!(corpus(&parse_set(&spec).unwrap(), &s.counts).is_err());
    }

    /// A scratch directory with a common-word list ("the", "met", filler).
    struct Scratch {
        dir: PathBuf,
        counts: PathBuf,
    }

    impl Scratch {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir()
                .join(format!("lf-bias-prep-test-{tag}-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let mut counts: Vec<String> = (0..5000)
                .map(|i| format!("common{i}\t{}", 9999 - i))
                .collect();
            counts.insert(0, "met\t10000".into());
            counts.insert(0, "the\t10001".into());
            let path = dir.join("counts.txt");
            std::fs::write(&path, counts.join("\n")).unwrap();
            Scratch { dir, counts: path }
        }

        fn manifest(&self, name: &str, lines: &[Value]) -> PathBuf {
            let p = self.dir.join(name);
            let text: Vec<String> = lines.iter().map(Value::to_string).collect();
            std::fs::write(&p, text.join("\n")).unwrap();
            p
        }

        fn set(&self, name: &str, manifest: &Path, extra: &str) -> SetArg {
            parse_set(&format!(
                "name={name},manifest={}{extra}",
                manifest.display()
            ))
            .unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// 40 SPGI-style utterances over 20 calls; `dev_extra` is appended to
    /// the text of dev calls only.
    fn spgi_lines(dev_extra: &str) -> Vec<Value> {
        (0..40)
            .map(|i| {
                let call = format!("{:032x}", i % 20);
                let mut text = format!("Zorbin met Quaxel{}, the plinth.", i % 20);
                if exp2_data::spgi_is_dev(&call) {
                    text.push(' ');
                    text.push_str(dev_extra);
                }
                json!({"id": format!("{call}/{i}.wav"), "audio_filepath": "/x.flac",
                       "text": text, "duration": 1.5})
            })
            .collect()
    }

    #[test]
    fn spgi_sessions_split_by_call_hash_with_train_only_df() {
        let s = Scratch::new("spgi");
        let m = s.manifest("spgi.jsonl", &spgi_lines(""));
        let c = corpus(&s.set("spgispeech", &m, ""), &s.counts).unwrap();
        assert_eq!(c.sessions.len(), 20);
        assert_eq!(c.sessions[&format!("{:032x}", 3)], vec![3, 23]);
        for (sess, sp) in &c.split_of {
            let dev = exp2_data::spgi_is_dev(sess);
            assert_eq!(*sp, if dev { Split::Dev } else { Split::Train });
        }
        let (train, dev) = (c.split_sessions(Split::Train), c.split_sessions(Split::Dev));
        assert_eq!((train.len(), dev.len()), (18, 2));
        // Targets are rare and session-specific: "quaxel3" occurs in one of 18
        // train calls (limit max(5% of 18, 2) = 2); "zorbin" and "plinth" are
        // rare but in every call; "the" and "met" are common.
        let t = &c.targets[&format!("{:032x}", 3)];
        assert_eq!(t, &[("quaxel3".to_owned(), "Quaxel3".to_owned())]);
        let excluded: Vec<&str> = c.df_excluded.iter().map(String::as_str).collect();
        assert_eq!(excluded, ["plinth", "zorbin"]);
        // DF comes from the train calls for both splits.
        assert_eq!(c.df[&Split::Train].split, Split::Train);
        assert_eq!(c.df[&Split::Dev].split, Split::Train);
        assert_eq!(c.df[&Split::Dev].df.sessions(), 18);
        // Regression (review B2): dev references never change train targets
        // or the DF table. With pooled DF, "quaxel3" in both dev calls would
        // reach 3 sessions and stop being a target.
        let m2 = s.manifest("spgi2.jsonl", &spgi_lines("Quaxel3 quaxel3"));
        let c2 = corpus(&s.set("spgispeech", &m2, ""), &s.counts).unwrap();
        for sess in &train {
            assert_eq!(c.targets[sess], c2.targets[sess], "{sess}");
        }
        assert_eq!(c.df_source(Split::Train).1, c2.df_source(Split::Train).1);
        assert_ne!(c.manifest_sha256, c2.manifest_sha256);
        // Selection: the first N sessions of each split, never held-out.
        let sel = c.selected(SplitSel::All, Some(2));
        assert_eq!(sel, c2.selected(SplitSel::All, Some(2)));
        assert_eq!(sel.iter().filter(|(s, _)| *s == Split::Train).count(), 2);
        // Regression (review B11): call ids are namespaced by dataset.
        assert_eq!(c.set.dataset.call_id("abc"), "spgispeech/abc");
        assert_eq!(c.speakers, json!({"speaker_field": false}));
    }

    fn session_lines(splits: &[(&str, &str)], speaker: impl Fn(usize) -> String) -> Vec<Value> {
        splits
            .iter()
            .enumerate()
            .flat_map(|(k, (sess, split))| (0..2).map(move |j| (k, j, *sess, *split)))
            .map(|(k, j, sess, split)| {
                json!({"id": format!("{sess}_{j}"), "audio_filepath": "/x.flac", "duration": 2.0,
                       "text": format!("THE TERM{k} MET"), "session": sess, "split": split,
                       "speaker": speaker(k), "keywords": [format!("Key{k}")]})
            })
            .collect()
    }

    #[test]
    fn explicit_splits_are_honoured_and_held_out_never_prepared() {
        // Regression (review B1).
        let s = Scratch::new("splits");
        let plan = [
            ("a", "train"),
            ("b", "train"),
            ("c", "dev"),
            ("d", "test"),
            ("e", "heldout"),
        ];
        // Speakers: a and d share "spk0"; e has its own.
        let spk = |k: usize| ["spk0", "spk1", "spk2", "spk0", "spk9"][k].to_owned();
        let m = s.manifest("icsi.jsonl", &session_lines(&plan, spk));
        let c = corpus(&s.set("icsi", &m, ",casing=uncased"), &s.counts).unwrap();
        let splits: Vec<(&str, Split)> = c.split_of.iter().map(|(k, v)| (k.as_str(), *v)).collect();
        assert_eq!(
            splits,
            [
                ("a", Split::Train),
                ("b", Split::Train),
                ("c", Split::Dev),
                ("d", Split::Heldout),
                ("e", Split::Heldout)
            ]
        );
        let sel = c.selected(SplitSel::All, None);
        assert_eq!(
            sel,
            [
                (Split::Train, "a".to_owned()),
                (Split::Train, "b".to_owned()),
                (Split::Dev, "c".to_owned())
            ]
        );
        // Speaker overlap between train and the other splits is reported.
        assert_eq!(c.speakers["train_speakers"], 2);
        assert_eq!(c.speakers["heldout"]["shared_with_train"], 1);
        assert_eq!(c.speakers["heldout"]["utterances_with_train_speaker"], 2);
        assert_eq!(c.speakers["heldout"]["examples"], json!(["spk0"]));
        assert_eq!(c.speakers["dev"]["shared_with_train"], 0);
        // DF from the 2 train sessions, also for dev and held-out.
        for sp in [Split::Train, Split::Dev, Split::Heldout] {
            assert_eq!(
                (c.df[&sp].split, c.df[&sp].df.sessions()),
                (Split::Train, 2)
            );
        }
        // A session in two splits, a missing split field and an unknown split fail.
        let mut bad = session_lines(&plan, spk);
        bad[1]["split"] = json!("dev");
        let mb = s.manifest("bad.jsonl", &bad);
        assert!(corpus(&s.set("icsi", &mb, ",casing=uncased"), &s.counts).is_err());
        let mut bad = session_lines(&plan, spk);
        bad[0].as_object_mut().unwrap().remove("split");
        let mb = s.manifest("bad2.jsonl", &bad);
        assert!(corpus(&s.set("icsi", &mb, ",casing=uncased"), &s.counts).is_err());
        let mut bad = session_lines(&plan, spk);
        bad[0]["split"] = json!("pretrain");
        let mb = s.manifest("bad3.jsonl", &bad);
        assert!(corpus(&s.set("icsi", &mb, ",casing=uncased"), &s.counts).is_err());
        // Keyword targets from the manifest field.
        let ck = corpus(
            &s.set("icsi", &m, ",casing=uncased,targets=keywords"),
            &s.counts,
        )
        .unwrap();
        assert_eq!(ck.targets["c"], [("key2".to_owned(), "Key2".to_owned())]);
        assert!(ck.df.is_empty());
        assert_eq!(ck.df_source(Split::Train).1, "none");
    }

    #[test]
    fn without_a_train_split_df_comes_from_the_scored_split() {
        // DESIGN "DF source": e.g. ACL 60/60, with dev and eval only.
        let s = Scratch::new("notrain");
        let plan = [("a", "dev"), ("b", "dev"), ("c", "dev"), ("d", "eval")];
        let m = s.manifest("acl.jsonl", &session_lines(&plan, |k| format!("s{k}")));
        let c = corpus(&s.set("acl6060", &m, ",casing=cased"), &s.counts).unwrap();
        assert_eq!(
            (c.df[&Split::Dev].split, c.df[&Split::Dev].df.sessions()),
            (Split::Dev, 3)
        );
        assert_eq!(
            (
                c.df[&Split::Heldout].split,
                c.df[&Split::Heldout].df.sessions()
            ),
            (Split::Heldout, 1)
        );
        assert_eq!(c.df_source(Split::Dev).0["split"], "dev");
    }

    #[test]
    fn gate_counts_multiword_targets_as_whole_occurrences() {
        let w = |s: &str| -> Vec<String> { s.split(' ').map(String::from).collect() };
        let refs = w("a neural network and a neural network b");
        let t = w("neural network");
        assert_eq!(target_positions(&refs, &t), vec![1, 5]);
        assert_eq!(matched_occurrences(&refs, &refs, &t), 2);
        assert_eq!(
            matched_occurrences(&refs, &w("a neural net and a neural network b"), &t),
            1
        );
        assert_eq!(matched_occurrences(&refs, &w("a and a b"), &t), 0);
    }

    /// A shard with no utterances and the given metadata, for index tests.
    fn empty_shard(meta: &[(&str, &str)]) -> Vec<u8> {
        let g = prep_shard::tests::random_graph(1, 8, 3);
        let trie = learned::TrieFeatures::new(&g);
        let tables = prep_shard::cand_tables(g.states(), &|s| g.candidates(s));
        let meta: BTreeMap<String, String> = meta
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        prep_shard::shard_bytes(&meta, &trie, &tables, 0.5, 4, &[], Vec::new()).unwrap()
    }

    #[test]
    fn index_records_policy_completeness_and_refuses_mixtures() {
        let s = Scratch::new("index");
        let prep = s.dir.join("prep");
        std::fs::create_dir_all(prep.join("train")).unwrap();
        // The split has sessions "x" and "y", two samples each.
        let set_sha = session_set_sha256(&["x", "y"].map(String::from).into());
        assert_eq!(
            set_sha,
            lf_model::manifest::sha256_hex(b"x\ny"),
            "sorted, joined by newlines, no trailing newline"
        );
        let shard = |name: &str, session: &str, sample: &str, policy: &str| {
            let call = format!("spgispeech/{session}");
            let meta = [
                ("dataset", "spgispeech"),
                ("call", call.as_str()),
                ("session", session),
                ("split", "train"),
                ("sample", sample),
                ("samples", "2"),
                ("split_sessions", "2"),
                ("split_sessions_sha256", set_sha.as_str()),
                ("policy", "{\"seed\":\"1\"}"),
                ("policy_sha256", policy),
                ("df_source_sha256", "d"),
            ];
            std::fs::write(prep.join("train").join(name), empty_shard(&meta)).unwrap();
        };
        shard("x.0.safetensors", "x", "0", "p1");
        shard("x.1.safetensors", "x", "1", "p1");
        shard("y.0.safetensors", "y", "0", "p1");
        let index = rebuild_index(&prep).unwrap();
        let tr = &index["datasets"]["spgispeech"]["splits"]["train"];
        assert_eq!(tr["expected_shards"], 4);
        assert_eq!(tr["present_shards"], 3);
        assert_eq!(tr["complete"], false);
        assert_eq!(tr["policy_sha256"], "p1");
        assert_eq!(tr["split_sessions_sha256"], set_sha.as_str());
        assert_eq!(index["complete"], false);
        assert_eq!(
            index["splits"]["train"]["shards"][0]["call"],
            "spgispeech/x"
        );
        shard("y.1.safetensors", "y", "1", "p1");
        assert_eq!(rebuild_index(&prep).unwrap()["complete"], true);
        // Four shards but the wrong sessions or samples are not complete:
        // completeness is derived per session and sample, not from a count.
        std::fs::remove_file(prep.join("train/y.1.safetensors")).unwrap();
        shard("w.0.safetensors", "w", "0", "p1");
        assert_eq!(rebuild_index(&prep).unwrap()["complete"], false);
        std::fs::remove_file(prep.join("train/w.0.safetensors")).unwrap();
        shard("y.2.safetensors", "y", "2", "p1");
        assert_eq!(rebuild_index(&prep).unwrap()["complete"], false);
        std::fs::remove_file(prep.join("train/y.2.safetensors")).unwrap();
        // A repeated (session, sample) is refused.
        shard("y.0b.safetensors", "y", "0", "p1");
        assert!(rebuild_index(&prep).is_err());
        std::fs::remove_file(prep.join("train/y.0b.safetensors")).unwrap();
        shard("y.1.safetensors", "y", "1", "p1");
        assert_eq!(rebuild_index(&prep).unwrap()["complete"], true);
        // Shards of one dataset and split under different policies are refused.
        shard("z.0.safetensors", "z", "0", "p2");
        assert!(rebuild_index(&prep).is_err());
        std::fs::remove_file(prep.join("train/z.0.safetensors")).unwrap();
        // So is a shard whose metadata split is not its directory.
        std::fs::create_dir_all(prep.join("dev")).unwrap();
        std::fs::write(
            prep.join("dev/w.0.safetensors"),
            empty_shard(&[("dataset", "spgispeech"), ("split", "train")]),
        )
        .unwrap();
        assert!(rebuild_index(&prep).is_err());
    }

    #[test]
    fn spoken_keyword_phrases_are_never_distractors() {
        // Regression (re-review #6): session "b" says "neural network" but its
        // own keyword is "Kubernetes"; session "a"'s keyword "Neural Network"
        // must never be a distractor in "b"'s dictionaries. It may be in "c"'s.
        let s = Scratch::new("kwphrase");
        let line = |sess: &str, j: usize, text: &str, kw: &str| {
            json!({"id": format!("{sess}_{j}"), "audio_filepath": "/x.flac", "duration": 1.0,
                   "text": text, "session": sess, "split": "train", "keywords": [kw]})
        };
        let m = s.manifest(
            "slides.jsonl",
            &[
                line("a", 0, "The neural network.", "Neural Network"),
                line("b", 0, "We trained a Neural network today.", "Kubernetes"),
                line("c", 0, "Nothing relevant here.", "Quaxel"),
            ],
        );
        let set = s.set("slidespeech", &m, ",casing=cased,targets=keywords");
        let c = corpus(&set, &s.counts).unwrap();
        assert!(c.vocab["b"].contains("neural network"));
        assert!(!c.vocab["c"].contains("neural network"));
        let pool = prep_dict::target_pool(&c.targets, &c.split_sessions(Split::Train));
        assert!(pool.iter().any(|(n, _)| n == "neural network"));
        let draws = |sess: &str| -> Vec<Vec<String>> {
            let near = prep_dict::nearest_distances(&pool, &c.targets[sess]);
            (0..200)
                .map(|k| {
                    prep_dict::sample_dictionary(
                        &format!("slidespeech/{sess}"),
                        k,
                        &c.targets[sess],
                        &c.vocab[sess],
                        &pool,
                        &near,
                        7,
                    )
                    .entries()
                })
                .collect()
        };
        let has = |d: &Vec<Vec<String>>| d.iter().any(|e| e.iter().any(|x| x == "Neural Network"));
        assert!(!has(&draws("b")));
        assert!(has(&draws("c")));
    }

    #[test]
    fn combined_gate_sums_occurrences_and_unions_words() {
        // Regression (re-review, B9 coverage).
        let st = |set, call, word, missed, reachable| ProbeStat {
            set,
            call,
            word,
            missed,
            reachable,
        };
        let stats = [
            st(0, "spgispeech/a", "kubernetes", 2, 2),
            st(0, "spgispeech/a", "orkin", 1, 1),
            st(0, "spgispeech/b", "nadir", 1, 0),
            st(1, "icsi/a", "kubernetes", 3, 3),
            st(1, "icsi/c", "phyox", 1, 1),
        ];
        let words = |v: &[&str]| -> BTreeSet<String> { v.iter().map(|w| w.to_string()).collect() };
        let all = gate_totals(&stats, &|_| true);
        assert_eq!(all.missed, 8);
        assert_eq!(all.reachable, 7);
        // A word missed in both datasets counts once; the same raw session
        // id in two datasets counts twice.
        assert_eq!(all.words, words(&["kubernetes", "nadir", "orkin", "phyox"]));
        assert_eq!(all.sessions.len(), 4);
        let a = gate_totals(&stats, &|s| s == 0);
        let b = gate_totals(&stats, &|s| s == 1);
        assert_eq!((a.missed, a.words.len(), a.sessions.len()), (4, 3, 2));
        assert_eq!((b.missed, b.words.len(), b.sessions.len()), (4, 2, 2));
        assert!(a.words.len() + b.words.len() > all.words.len());
        // The oracle samples the combined population: a seeded shuffle of
        // every probe, cut once the requested occurrences are covered.
        let missed: Vec<usize> = stats.iter().map(|p| p.missed).collect();
        let every = oracle_sample(&missed, 100, 9);
        assert_eq!(
            every.iter().copied().collect::<BTreeSet<_>>(),
            (0..5).collect()
        );
        let some = oracle_sample(&missed, 3, 9);
        assert_eq!(some, every[..some.len()]);
        let covered: usize = some.iter().map(|&i| missed[i]).sum();
        let without_last: usize = some[..some.len() - 1].iter().map(|&i| missed[i]).sum();
        assert!(covered >= 3 && without_last < 3);
        assert_eq!(some, oracle_sample(&missed, 3, 9));
    }

    #[test]
    fn policy_records_the_session_set_and_graph() {
        // P derives expected shards as split_sessions x samples and checks
        // the session set by hash (re-review, P's #4).
        let s = Scratch::new("policy");
        let m = s.manifest("spgi.jsonl", &spgi_lines(""));
        let c = corpus(&s.set("spgispeech", &m, ""), &s.counts).unwrap();
        let args = pa(argv(&["--manifest", "m", "--samples", "3"])).unwrap();
        let id = CacheIdentity {
            export_sha256: "e".into(),
            precision: "i8x2".into(),
            joint_padded: 640,
        };
        let p = c.policy(Split::Train, &args, &id);
        assert_eq!(
            p["graph"],
            json!({"case_variants": true, "cancel_unfinished": false})
        );
        assert_eq!(p["graph"].as_object().unwrap().len(), 2);
        let train: Vec<String> = c.split_sessions(Split::Train).into_iter().collect();
        assert_eq!(p["split_sessions"], 18);
        assert_eq!(
            p["split_sessions_sha256"],
            lf_model::manifest::sha256_hex(train.join("\n").as_bytes())
        );
        assert_eq!(p["samples"], 3);
        assert_eq!(p["split"], "train");
        assert_ne!(
            p["split_sessions_sha256"],
            c.policy(Split::Dev, &args, &id)["split_sessions_sha256"]
        );
    }

    /// The synthetic prep fixture for P's reader test: a shard written by
    /// [`prep_shard::shard_bytes`] from a synthetic model (vocab 1025, joint
    /// 8, F16 weights) and dictionary, plus everything needed to check a
    /// reader without Rust:
    /// - `joint.joint_net.2.weight` (F16 `[1030, 8]`) and `.bias` (F16
    ///   `[1030]`), named as in the export: the joint output layer, for
    ///   recomputing logits from `enc` and `pred`;
    /// - `dec.logits` (F32 `[decisions, 1030]`): Rust `joint_row` logits at
    ///   every decision;
    /// - `check.cand.offset`, `check.cand`: `BiasGraph::candidates` of every
    ///   state, which the candidate tables must reproduce;
    /// - `fixture.phrase.offset`, `fixture.phrase`: the dictionary's phrases.
    fn fixture_bytes() -> Vec<u8> {
        let mut p = DecoderParams::random(V, 16, 8, 8, 2026);
        // Short durations, so a written-in phrase fits (multiples of 2^-12
        // stay exact in f16).
        p.b_out[V] += 0.25;
        p.b_out[V + 1] += 0.5;
        p.b_out[BLANK] += 0.5;
        // The export stores the joint output bias as F16 too: keep it exact.
        for b in &mut p.b_out {
            *b = f16_to_f32(f32_to_f16(*b));
        }
        let dec = PackedDecoder::new(&p, Storage::F16);
        let pool = ThreadPool::new(&[0]);
        let mut rng = SplitMix64::new(2027);
        let mut phrases: Vec<Vec<usize>> = (0..5)
            .map(|_| {
                (0..1 + rng.below(3))
                    .map(|_| rng.below(VOCAB as u64) as usize)
                    .collect()
            })
            .collect();
        // Overlapping phrases so that some states override the root's candidates.
        phrases.push(vec![phrases[0][0], phrases[1][0], 7]);
        phrases.push(vec![phrases[1][0], 7, 9]);
        let graph = BiasGraph::new(&phrases, VOCAB, learned_graph_config()).unwrap();
        let mut utts = Vec::new();
        let (j, jp) = (dec.joint_dim(), dec.joint_padded());
        for i in 0..2 {
            let frames = 8 + 2 * i;
            let enc: Vec<f32> = (0..frames * p.enc_dim)
                .map(|_| rng.next_gaussian())
                .collect();
            let proj = dec.project_encoder(&pool, &enc, frames);
            let h: Vec<usize> = dec
                .decode(&pool, &proj, frames, None, None)
                .iter()
                .map(|e| e.0)
                .collect();
            // Write a phrase in, as a repair would, where the alignment allows it.
            let phrase = &phrases[i % phrases.len()];
            let (target, al, at) = (0..=h.len())
                .find_map(|k| {
                    let mut t = h[..k].to_vec();
                    t.extend_from_slice(phrase);
                    t.extend_from_slice(&h[k..]);
                    let g = dec.predictor_outputs(&pool, &t);
                    prep_align::align(frames, &t, V, &DURATIONS, &mut joint_rows(&dec, &proj, &g))
                        .map(|a| (t, a, k))
                })
                .unwrap_or_else(|| {
                    let g = dec.predictor_outputs(&pool, &h);
                    let a = prep_align::align(
                        frames,
                        &h,
                        V,
                        &DURATIONS,
                        &mut joint_rows(&dec, &proj, &g),
                    )
                    .unwrap();
                    (h.clone(), a, usize::MAX)
                });
            let g = dec.predictor_outputs(&pool, &target);
            let mut states = vec![BiasGraph::ROOT];
            for &t in &target {
                states.push(graph.step(*states.last().unwrap(), t).0);
            }
            let decisions = al
                .decisions
                .iter()
                .map(|d| ShardDecision {
                    t: d.t as u32,
                    u: d.u as u32,
                    state: states[d.u],
                    label: d.label as u32,
                    kind: u8::from(
                        d.label != BLANK && (at..at.saturating_add(phrase.len())).contains(&d.u),
                    ),
                })
                .collect();
            let rows = |src: &[f32], n: usize| -> Vec<f32> {
                (0..n)
                    .flat_map(|r| src[r * jp..r * jp + j].iter().copied())
                    .collect()
            };
            utts.push(ShardUtt {
                id: format!("fixture/{i}"),
                enc: rows(&proj, frames),
                pred: rows(&g, target.len() + 1),
                target,
                decisions,
            });
        }
        let trie = learned::TrieFeatures::new(&graph);
        let tables = prep_shard::cand_tables(graph.states(), &|s| graph.candidates(s));
        let (all, logits) = rust_logits(&dec, &utts, None);
        let mut cand_offset = vec![0i64];
        let mut cand = Vec::new();
        for s in 0..graph.states() as u32 {
            cand.extend(
                graph
                    .candidates(s)
                    .into_iter()
                    .flat_map(|(t, d)| [t as i32, d as i32]),
            );
            cand_offset.push(cand.len() as i64 / 2);
        }
        let mut ph_offset = vec![0i64];
        let mut ph = Vec::new();
        for x in &phrases {
            ph.extend(x.iter().map(|&t| t as i32));
            ph_offset.push(ph.len() as i64);
        }
        let f16 = |name: &'static str, shape: Vec<usize>, v: &[f32]| TensorData {
            name,
            dtype: Dtype::F16,
            shape,
            bytes: std::borrow::Cow::Owned(
                v.iter()
                    .flat_map(|&x| f32_to_f16(x).to_le_bytes())
                    .collect(),
            ),
        };
        assert_eq!(
            all.len(),
            utts.iter().map(|u| u.decisions.len()).sum::<usize>()
        );
        let extra = vec![
            TensorData::f32("dec.logits", vec![all.len(), V + DURATIONS.len()], &logits),
            TensorData::i64("check.cand.offset", vec![cand_offset.len()], &cand_offset),
            TensorData::i32("check.cand", vec![cand.len() / 2, 2], &cand),
            TensorData::i64("fixture.phrase.offset", vec![ph_offset.len()], &ph_offset),
            TensorData::i32("fixture.phrase", vec![ph.len()], &ph),
            f16("joint.joint_net.2.weight", vec![p.out_rows(), j], &p.w_out),
            f16("joint.joint_net.2.bias", vec![p.out_rows()], &p.b_out),
        ];
        let entries = phrases.len();
        // The validation fields of real shards, with synthetic values.
        let sessions_sha = session_set_sha256(&BTreeSet::from(["fixture".to_owned()]));
        let policy = json!({"format": prep_shard::SHARD_FORMAT, "dataset": "synthetic",
            "split": "train", "casing": "cased", "targets_mode": "rare", "rare_rule": null,
            "df_source": null, "df_source_sha256": "none", "seed": "0", "samples": 1,
            "split_sessions": 1, "split_sessions_sha256": sessions_sha,
            "export_sha256": "synthetic", "cache_identity": "synthetic", "graph": graph_policy()});
        let meta = BTreeMap::from([
            ("format".to_owned(), prep_shard::SHARD_FORMAT.to_owned()),
            ("dataset".into(), "synthetic".into()),
            ("call".into(), "synthetic/fixture".into()),
            ("session".into(), "fixture".into()),
            ("split".into(), "train".into()),
            ("sample".into(), "0".into()),
            ("samples".into(), "1".into()),
            ("split_sessions".into(), "1".into()),
            ("split_sessions_sha256".into(), sessions_sha.clone()),
            ("graph".into(), graph_policy().to_string()),
            ("seed".into(), "0".into()),
            ("casing".into(), "cased".into()),
            ("targets_mode".into(), "rare".into()),
            ("rare_rule".into(), "null".into()),
            ("df_source".into(), "null".into()),
            ("df_source_sha256".into(), "none".into()),
            ("export_sha256".into(), "synthetic".into()),
            ("cache_identity".into(), "synthetic".into()),
            ("policy".into(), policy.to_string()),
            (
                "policy_sha256".into(),
                lf_model::manifest::sha256_hex(policy.to_string().as_bytes()),
            ),
            ("entries".into(), entries.to_string()),
            ("phrases".into(), phrases.len().to_string()),
            ("nodes".into(), graph.states().to_string()),
            ("utterances".into(), utts.len().to_string()),
            (
                "utterance_ids".into(),
                json!(utts.iter().map(|u| &u.id).collect::<Vec<_>>()).to_string(),
            ),
            (
                "note".into(),
                "synthetic weights and tokens; no dataset text".into(),
            ),
        ]);
        prep_shard::shard_bytes(
            &meta,
            &trie,
            &tables,
            learned::g_size(entries),
            j,
            &utts,
            extra,
        )
        .unwrap()
    }

    fn fixture_path() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join(FIXTURE)
    }

    /// Regenerates the committed fixture: `cargo test -p lf-bench --bin
    /// lf-bias-prep -- --ignored write_prep_fixture`.
    #[test]
    #[ignore]
    fn write_prep_fixture() {
        assert!(lf_cpu::cpu_supported());
        let path = fixture_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, fixture_bytes()).unwrap();
    }

    #[test]
    fn prep_fixture_is_current() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let committed = std::fs::read(fixture_path())
            .expect("prep fixture missing: run the ignored write_prep_fixture test");
        assert!(
            committed == fixture_bytes(),
            "prep fixture is stale: regenerate it"
        );
    }

    /// What P's reader must be able to do, checked on the committed fixture
    /// without any Rust model code: candidates from the tables, logits from
    /// `enc`, `pred` and the f16 joint, and the bias states from the phrases.
    #[test]
    fn prep_fixture_is_self_consistent() {
        let st = SafeTensors::parse(std::fs::read(fixture_path()).unwrap()).unwrap();
        let i32v = |k: &str| st.i32_vec(k).unwrap();
        let i64v = |k: &str| st.i64_vec(k).unwrap();
        let pairs = |v: Vec<i32>| -> Vec<(u32, u32)> {
            v.chunks(2).map(|c| (c[0] as u32, c[1] as u32)).collect()
        };
        let tables = prep_shard::CandTables {
            root: pairs(i32v("cand.root")),
            offset: i64v("cand.override.offset"),
            overrides: pairs(i32v("cand.override")),
        };
        let co = i64v("check.cand.offset");
        let cand = pairs(i32v("check.cand"));
        let n = i32v("trie.token").len();
        assert_eq!(co.len(), n + 1);
        let mut overridden = 0;
        for s in 0..n {
            let want = &cand[co[s] as usize..co[s + 1] as usize];
            assert_eq!(prep_shard::reconstruct(&tables, s), want, "state {s}");
            overridden += (tables.offset[s + 1] - tables.offset[s]) as usize;
        }
        assert!(overridden > 0);
        // The same candidates from the phrases through BiasGraph (step).
        let po = i64v("fixture.phrase.offset");
        let pt = i32v("fixture.phrase");
        let phrases: Vec<Vec<usize>> = po
            .windows(2)
            .map(|w| {
                pt[w[0] as usize..w[1] as usize]
                    .iter()
                    .map(|&t| t as usize)
                    .collect()
            })
            .collect();
        let graph = BiasGraph::new(&phrases, VOCAB, learned_graph_config()).unwrap();
        assert_eq!(graph.states(), n);
        for s in 0..n {
            assert_eq!(
                prep_shard::tests::candidates_by_step(&graph, s as u32),
                &cand[co[s] as usize..co[s + 1] as usize]
            );
        }
        // Logits: W_out (f16) · relu(f + g) + b_out, f32 accumulation.
        let f16v = |k: &str| -> (Vec<usize>, Vec<f32>) {
            let (info, bytes) = st.get(k).unwrap();
            assert_eq!(info.dtype, Dtype::F16);
            let v = bytes
                .as_chunks::<2>()
                .0
                .iter()
                .map(|b| f16_to_f32(u16::from_le_bytes(*b)))
                .collect();
            (info.shape.clone(), v)
        };
        let (shape, w) = f16v("joint.joint_net.2.weight");
        let (rows, j) = (shape[0], shape[1]);
        let (_, b) = f16v("joint.joint_net.2.bias");
        let enc = st.f32_vec("enc").unwrap();
        let pred = st.f32_vec("pred").unwrap();
        let (fo, pdo) = (i64v("utt.frame_offset"), i64v("utt.pred_offset"));
        let (du, dt, duu) = (i32v("dec.utt"), i32v("dec.t"), i32v("dec.u"));
        let check = st.f32_vec("dec.logits").unwrap();
        assert_eq!(st.tensors["dec.logits"].shape, vec![du.len(), rows]);
        let mut worst = 0f32;
        for d in 0..du.len() {
            let fr = (fo[du[d] as usize] + dt[d] as i64) as usize;
            let pr = (pdo[du[d] as usize] + duu[d] as i64) as usize;
            let z: Vec<f32> = (0..j)
                .map(|x| (enc[fr * j + x] + pred[pr * j + x]).max(0.0))
                .collect();
            for r in 0..rows {
                let l = w[r * j..(r + 1) * j]
                    .iter()
                    .zip(&z)
                    .map(|(a, b)| a * b)
                    .sum::<f32>()
                    + b[r];
                worst = worst.max((l - check[d * rows + r]).abs());
            }
        }
        assert!(worst <= 1e-3, "logit deviation {worst}");
        // Bias states: walking the phrases' graph over each target.
        let (to, tg) = (i64v("target.offset"), i32v("target"));
        let ds = i32v("dec.state");
        for d in 0..du.len() {
            let u = du[d] as usize;
            let target = &tg[to[u] as usize..to[u + 1] as usize];
            let mut s = BiasGraph::ROOT;
            for &t in &target[..duu[d] as usize] {
                s = graph.step(s, t as usize).0;
            }
            assert_eq!(ds[d] as u32, s);
        }
        let kinds = st.u8_vec("dec.kind").unwrap();
        assert!(kinds.contains(&1) && kinds.contains(&0));
    }
}
