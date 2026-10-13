//! Word-boosting (phrase biasing) evaluation on public test sets.
//!
//! Every utterance is encoded once (`Transcriber::encode_projected`, cached on
//! disk under `--cache`), then greedily re-decoded with a [`BiasGraph`] for each
//! configuration of a staged sweep. Utterances are decoded in parallel by
//! `--workers` thread pools of `--threads / --workers` pinned CPUs each.
//!
//! Sets:
//! - `--libri ROLE:EVAL_JSON:MANIFEST:TSV_PREFIX` (ROLE `tune` or `test`): a
//!   LibriSpeech set with the per-utterance biasing lists of Le et al. 2021,
//!   read from `TSV_PREFIX{100,500,1000}.tsv`.
//! - `--session EVAL_JSON:MANIFEST` with `--rare-words FILE`: sessions keyed by
//!   the id prefix before `/` (Earnings-22 calls), one dictionary per session
//!   (see `bias_lists`), half the sessions for tuning and half held out. The
//!   lists are written to `--lists-out`.
//!
//! Metrics follow `score.py` of Le et al. with the harness's simple normalizer
//! (see `bias_metrics`). Tuning uses only the `tune` sets; the chosen
//! configurations are then scored on every set. Then the oracle-margin
//! experiment: for each held-out miss of a target word, the utterance is
//! decoded with a dictionary of only that word at increasing alpha.
//!
//! Outputs (JSON, a markdown summary, and per-utterance hypotheses) go to
//! `--out`, which must be outside the repository. `--calibrate` only times
//! worker layouts.

mod audio;
mod bias_lists;
mod bias_metrics;
mod enc_cache;
mod exp2_data;
mod exp2_phrases;
mod exp2_terms;
mod learned;
mod learned_eval;
mod outpath;
#[allow(dead_code)]
mod wer;

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use lf_asr::bias::{BiasConfig, BiasGraph};
use lf_asr::config::VOCAB;
use lf_asr::tokenizer::Tokenizer;
use lf_asr::{Model, Precision, Transcriber};
use lf_cpu::ThreadPool;
use lf_cpu::decoder::{PackedDecoder, Storage};
use lf_model::Export;
use serde_json::{Value, json};

use bias_metrics::{Counts, Rate};
use wer::normalize;

const SIZES: [usize; 3] = [100, 500, 1000];
const CONTEXT_SCORE: f32 = 1.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Role {
    Tune,
    Test,
}

impl Role {
    fn name(self) -> &'static str {
        match self {
            Role::Tune => "tune",
            Role::Test => "held-out",
        }
    }
}

struct LibriArg {
    role: Role,
    eval: PathBuf,
    manifest: PathBuf,
    tsv_prefix: String,
}

struct Args {
    export: PathBuf,
    libri: Vec<LibriArg>,
    session: Option<(PathBuf, PathBuf)>,
    rare_words: Option<PathBuf>,
    lists_out: Option<PathBuf>,
    cache: PathBuf,
    out: Option<PathBuf>,
    threads: usize,
    workers: usize,
    seed: u64,
    limit: Option<usize>,
    calibrate: bool,
    /// Experiment 2 (learned biasing): `Some` selects that mode.
    exp2: Option<learned_eval::Exp2Args>,
}

fn parse_args_from(argv: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut a = Args {
        export: PathBuf::new(),
        libri: Vec::new(),
        session: None,
        rare_words: None,
        lists_out: None,
        cache: PathBuf::new(),
        out: None,
        threads: 16,
        workers: 16,
        seed: 20_261_011,
        limit: None,
        calibrate: false,
        exp2: None,
    };
    let mut x = learned_eval::Exp2Args::default();
    let mut exp2_flags: Vec<String> = Vec::new();
    let mut it = argv.into_iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--export" => a.export = value()?.into(),
            "--libri" => {
                let v = value()?;
                let parts: Vec<&str> = v.splitn(4, ':').collect();
                let [role, eval, manifest, prefix] = parts[..] else {
                    return Err("--libri takes ROLE:EVAL_JSON:MANIFEST:TSV_PREFIX".into());
                };
                let role = match role {
                    "tune" => Role::Tune,
                    "test" => Role::Test,
                    r => return Err(format!("unknown role {r}")),
                };
                a.libri.push(LibriArg {
                    role,
                    eval: eval.into(),
                    manifest: manifest.into(),
                    tsv_prefix: prefix.to_owned(),
                });
            }
            "--session" => {
                let v = value()?;
                let (e, m) = v
                    .split_once(':')
                    .ok_or("--session takes EVAL_JSON:MANIFEST")?;
                a.session = Some((e.into(), m.into()));
            }
            "--rare-words" => a.rare_words = Some(value()?.into()),
            "--lists-out" => a.lists_out = Some(value()?.into()),
            "--cache" => a.cache = value()?.into(),
            "--out" => a.out = Some(value()?.into()),
            "--threads" => a.threads = value()?.parse().map_err(|e| format!("{flag}: {e}"))?,
            "--workers" => a.workers = value()?.parse().map_err(|e| format!("{flag}: {e}"))?,
            "--seed" => a.seed = value()?.parse().map_err(|e| format!("{flag}: {e}"))?,
            "--limit" => a.limit = Some(value()?.parse().map_err(|e| format!("{flag}: {e}"))?),
            "--calibrate" => a.calibrate = true,
            "-h" | "--help" => {
                return Err(format!(
                    "usage: lf-bias-eval --export DIR --cache DIR \
                     [--libri ROLE:EVAL:MANIFEST:TSV_PREFIX]... \
                     [--session EVAL:MANIFEST --rare-words FILE --lists-out FILE] \
                     [--out DIR] [--threads 16] [--workers 16] [--seed N] [--limit N] [--calibrate]\n\
                     experiment 2 (learned biasing), selected by --sets:\n{}",
                    learned_eval::USAGE
                ));
            }
            f => {
                if learned_eval::parse_flag(&mut x, f, &mut value)? {
                    exp2_flags.push(f.to_owned());
                } else {
                    return Err(format!("unknown argument {flag}"));
                }
            }
        }
    }
    if a.export.as_os_str().is_empty() || a.cache.as_os_str().is_empty() {
        return Err("need --export and --cache".into());
    }
    if x.sets.is_some() {
        learned_eval::validate(&mut a, x)?;
        return Ok(a);
    }
    if !exp2_flags.is_empty() {
        return Err(format!(
            "{} only apply to experiment 2: add --sets dev|heldout|both",
            exp2_flags.join(", ")
        ));
    }
    if a.libri.is_empty() && a.session.is_none() {
        return Err("need at least one --libri or --session".into());
    }
    // A session set always contributes a tuning half; LibriSpeech sets only
    // when given the `tune` role.
    if a.session.is_none() && !a.libri.iter().any(|l| l.role == Role::Tune) {
        return Err("no tuning data: give a --libri tune:... set or a --session set".into());
    }
    if a.session.is_some() && (a.rare_words.is_none() || a.lists_out.is_none()) {
        return Err("--session needs --rare-words and --lists-out".into());
    }
    if !a.calibrate && a.out.is_none() {
        return Err("need --out (or --calibrate)".into());
    }
    if a.threads == 0 || a.workers == 0 || !a.threads.is_multiple_of(a.workers) {
        return Err("--threads must be a positive multiple of --workers".into());
    }
    Ok(a)
}

// ---------------------------------------------------------------- data

struct Utt {
    id: String,
    /// The session for per-session output: the call or session of a session
    /// set, the speaker-chapter of a LibriSpeech utterance.
    session: String,
    group: usize,
    ref_words: Vec<String>,
    /// B-WER words: the rare words of the reference (normalized).
    biasing: BTreeSet<String>,
    m1_hyp: String,
    frames: usize,
    /// Shared by the sets of one session set's list conditions.
    proj: Arc<Vec<f32>>,
}

struct Group {
    /// Number of utterances using this group's lists.
    utts: usize,
    /// Dictionary entries per size (index into `SIZES`).
    lists: Vec<Vec<String>>,
    /// Normalized words of `lists`.
    list_norm: Vec<BTreeSet<String>>,
    /// Normalized target word -> the dictionary entry for it.
    surface: BTreeMap<String, String>,
    /// A keyword list (experiment 2): each entry is encoded from its
    /// original and lowercase surfaces (`exp2_terms::keyword_entry_surfaces`).
    keywords: bool,
}

struct Set {
    name: String,
    role: Role,
    utts: Vec<usize>,
    /// The list sizes (indices into `SIZES`) this set is evaluated at.
    sizes: Vec<usize>,
}

struct Data {
    sets: Vec<Set>,
    utts: Vec<Utt>,
    groups: Vec<Group>,
    notes: Vec<String>,
    lists_info: Value,
}

struct EvalRecord {
    reference: String,
    hyp: String,
    scored: bool,
}

fn read_json(path: &Path) -> Result<Value, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

fn read_text(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// Records in file order.
fn eval_records(path: &Path) -> Result<Vec<(String, EvalRecord)>, String> {
    let v = read_json(path)?;
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    for r in v
        .get("records")
        .and_then(|r| r.as_array())
        .ok_or(format!("{}: no records", path.display()))?
    {
        let s = |k: &str| r.get(k).and_then(|v| v.as_str()).map(str::to_owned);
        let (Some(id), Some(reference), Some(hyp)) = (s("id"), s("ref"), s("hyp")) else {
            return Err(format!("{}: record without id, ref or hyp", path.display()));
        };
        if !seen.insert(id.clone()) {
            return Err(format!("{}: duplicate id {id}", path.display()));
        }
        let scored = r.get("scored").and_then(|v| v.as_bool()).unwrap_or(true);
        out.push((
            id,
            EvalRecord {
                reference,
                hyp,
                scored,
            },
        ));
    }
    Ok(out)
}

/// `id -> audio path`.
fn manifest_audio(path: &Path) -> Result<HashMap<String, PathBuf>, String> {
    let mut out = HashMap::new();
    for line in read_text(path)?.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value =
            serde_json::from_str(line).map_err(|e| format!("{}: {e}", path.display()))?;
        if let (Some(id), Some(a)) = (
            v.get("id").and_then(|x| x.as_str()),
            v.get("audio_filepath").and_then(|x| x.as_str()),
        ) {
            out.insert(id.to_owned(), PathBuf::from(a));
        }
    }
    Ok(out)
}

fn stem(p: &Path) -> String {
    p.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("set")
        .to_owned()
}

/// Scored records that have audio, in file order (at most `limit`).
fn scored_items(
    eval: &Path,
    manifest: &Path,
    limit: Option<usize>,
    notes: &mut Vec<String>,
) -> Result<Vec<(String, EvalRecord, PathBuf)>, String> {
    let records = eval_records(eval)?;
    let audio = manifest_audio(manifest)?;
    let total = records.len();
    let (mut unscored, mut no_audio) = (0, 0);
    let mut out = Vec::new();
    for (id, r) in records {
        if !r.scored {
            unscored += 1;
            continue;
        }
        let Some(a) = audio.get(&id) else {
            no_audio += 1;
            continue;
        };
        out.push((id, r, a.clone()));
    }
    if let Some(n) = limit {
        out.truncate(n);
    }
    notes.push(format!(
        "{}: {total} records, {unscored} unscored, {no_audio} without audio, {} used",
        stem(eval),
        out.len()
    ));
    Ok(out)
}

fn norm_set<'a>(words: impl IntoIterator<Item = &'a String>) -> BTreeSet<String> {
    words.into_iter().flat_map(|w| normalize(w)).collect()
}

struct Projected {
    frames: usize,
    proj: Vec<f32>,
}

/// Version tag of the projection cache format and of what it depends on.
const CACHE_FORMAT: &str = "lf-bias-eval projected encoder output v2";

/// What a cached projection depends on, besides each utterance's audio.
struct CacheIdentity {
    /// SHA-256 over the export manifest's format and verified file hashes.
    export_sha256: String,
    precision: String,
    joint_padded: usize,
}

impl CacheIdentity {
    /// The same identity for the per-group cache (`enc_cache`).
    fn shared(&self) -> enc_cache::CacheIdentity {
        enc_cache::CacheIdentity {
            export_sha256: self.export_sha256.clone(),
            precision: self.precision.clone(),
            joint_padded: self.joint_padded,
        }
    }
}

/// The cache header for these utterances, without the frame counts.
fn cache_identity_json(identity: &CacheIdentity, ids: &[&str], audio_sha256: &[String]) -> Value {
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
fn cached_frames(header: &Value, expected: &Value) -> Option<Vec<usize>> {
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

/// Projected encoder outputs for `ids_audio`, from `cache_path` when its
/// header matches the export, precision, format and every audio file's
/// SHA-256, else encoded and written there.
fn projected(
    tr: &mut Transcriber,
    identity: &CacheIdentity,
    ids_audio: &[(String, PathBuf)],
    cache_path: &Path,
    threads: usize,
) -> Result<Vec<Projected>, String> {
    let hashes: Vec<Result<String, String>> = par_map(ids_audio, threads, &|(_, p)| {
        lf_model::manifest::sha256_file(p).map_err(|e| format!("{}: {e}", p.display()))
    });
    let audio_sha256: Vec<String> = hashes.into_iter().collect::<Result<_, _>>()?;
    let ids: Vec<&str> = ids_audio.iter().map(|(id, _)| id.as_str()).collect();
    let expected = cache_identity_json(identity, &ids, &audio_sha256);
    let jp = identity.joint_padded;
    if let Ok(bytes) = std::fs::read(cache_path)
        && let Some(nl) = bytes.iter().position(|&b| b == b'\n')
        && let Ok(header) = serde_json::from_slice::<Value>(&bytes[..nl])
        && let Some(frames) = cached_frames(&header, &expected)
    {
        let body = &bytes[nl + 1..];
        let total: usize = frames.iter().sum::<usize>() * jp;
        if body.len() == total * 4 {
            let mut out = Vec::with_capacity(frames.len());
            let mut off = 0;
            for f in frames {
                let n = f * jp * 4;
                let proj = body[off..off + n]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| f32::from_le_bytes(*c))
                    .collect();
                off += n;
                out.push(Projected { frames: f, proj });
            }
            eprintln!(
                "{}: loaded {} cached encodings",
                cache_path.display(),
                out.len()
            );
            return Ok(out);
        }
    }
    let start = Instant::now();
    let mut out = Vec::with_capacity(ids_audio.len());
    for (i, (id, path)) in ids_audio.iter().enumerate() {
        let samples = audio::read_flac(path)?;
        let (proj, frames) = tr
            .encode_projected(&samples)
            .map_err(|e| format!("{id}: {e}"))?;
        if proj.len() != frames * jp || proj.iter().any(|v| !v.is_finite()) {
            return Err(format!("{id}: malformed projection"));
        }
        out.push(Projected { frames, proj });
        if (i + 1) % 500 == 0 {
            eprintln!("  encoded {}/{}", i + 1, ids_audio.len());
        }
    }
    eprintln!(
        "{}: encoded {} utterances in {:.1?}",
        cache_path.display(),
        out.len(),
        start.elapsed()
    );
    let mut header = expected;
    header["frames"] = json!(out.iter().map(|p| p.frames).collect::<Vec<_>>());
    let tmp = cache_path.with_extension("tmp");
    let mut w = std::io::BufWriter::new(outpath::create_output(&tmp)?);
    let werr = |e: std::io::Error| format!("{}: {e}", tmp.display());
    writeln!(w, "{header}").map_err(werr)?;
    for p in &out {
        for v in &p.proj {
            w.write_all(&v.to_le_bytes()).map_err(werr)?;
        }
    }
    w.flush().map_err(werr)?;
    drop(w);
    // `rename` replaces a link at `cache_path` rather than writing through it.
    std::fs::rename(&tmp, cache_path).map_err(|e| format!("{}: {e}", cache_path.display()))?;
    Ok(out)
}

/// `id` must have a row in every list size's file, with the harness reference
/// (normalized: `ref_words`) and one rare-word set shared by all sizes.
fn check_libri_rows(
    id: &str,
    ref_words: &[String],
    rows: &[HashMap<String, bias_lists::LibriRow>],
) -> Result<(), String> {
    let mut rare: Option<BTreeSet<String>> = None;
    for (m, size) in rows.iter().zip(SIZES) {
        let row = m
            .get(id)
            .ok_or(format!("{id}: no row in the size-{size} biasing list"))?;
        if normalize(&row.reference) != ref_words {
            return Err(format!(
                "{id}: the size-{size} list's reference differs from the harness reference"
            ));
        }
        let r = norm_set(&row.rare);
        match &rare {
            Some(first) if *first != r => {
                return Err(format!("{id}: rare-word set differs at size {size}"));
            }
            _ => rare = Some(r),
        }
    }
    Ok(())
}

fn new_data() -> Data {
    Data {
        sets: Vec::new(),
        utts: Vec::new(),
        groups: Vec::new(),
        notes: Vec::new(),
        lists_info: json!({}),
    }
}

/// The whole-set projection cache file of experiment 1 for set `name`.
fn set_cache_file(args: &Args, name: &str) -> PathBuf {
    let suffix = args.limit.map(|n| format!(".first{n}")).unwrap_or_default();
    args.cache.join(format!("{name}{suffix}.i8x2.proj"))
}

/// Le et al.'s `all_rare_words.txt`, lowercased.
fn read_rare_words(path: &Path) -> Result<BTreeSet<String>, String> {
    Ok(read_text(path)?
        .lines()
        .map(|l| l.trim().to_lowercase())
        .filter(|l| !l.is_empty())
        .collect())
}

fn load_data(args: &Args, tr: &mut Transcriber, identity: &CacheIdentity) -> Result<Data, String> {
    let mut data = new_data();
    outpath::check_output_dir(&args.cache)?;
    for l in &args.libri {
        load_libri(&mut data, args, l, tr, identity)?;
    }
    if let Some((eval, manifest)) = &args.session {
        let rare = read_rare_words(args.rare_words.as_ref().unwrap())?;
        let src = earnings_source(eval, manifest, rare, args.lists_out.clone().unwrap());
        let mut info = load_sessions(&mut data, args, &src, tr, identity)?;
        data.lists_info = info.remove(0).1;
    }
    Ok(data)
}

/// Experiment 1's Earnings-22 session set (halves, `all_rare_words.txt`).
fn earnings_source(
    eval: &Path,
    manifest: &Path,
    rare: BTreeSet<String>,
    lists_out: PathBuf,
) -> SessionSource {
    SessionSource {
        name: stem(eval),
        items_from: ItemsFrom::Eval(eval.to_path_buf()),
        manifest: manifest.to_path_buf(),
        session_of: Box::new(earnings_session),
        keep_session: None,
        fallback: rare.iter().cloned().collect(),
        rare: RareRule::Words(rare),
        split: SessionSplit::Halves,
        groups_cache: None,
        lists_out,
        conditions: vec![ListCondition::Rare],
        keywords: HashMap::new(),
        casing: None,
    }
}

/// A LibriSpeech set with the per-utterance lists of Le et al. (one group per
/// utterance), projections from experiment 1's whole-set cache file.
fn load_libri(
    data: &mut Data,
    args: &Args,
    l: &LibriArg,
    tr: &mut Transcriber,
    identity: &CacheIdentity,
) -> Result<(), String> {
    let name = stem(&l.eval);
    let items = scored_items(&l.eval, &l.manifest, args.limit, &mut data.notes)?;
    let mut rows: Vec<HashMap<String, bias_lists::LibriRow>> = Vec::new();
    for n in SIZES {
        let p = PathBuf::from(format!("{}{n}.tsv", l.tsv_prefix));
        let parsed = bias_lists::parse_libri_tsv(&read_text(&p)?)
            .map_err(|e| format!("{}: {e}", p.display()))?;
        rows.push(parsed.into_iter().map(|r| (r.id.clone(), r)).collect());
    }
    // Every scored utterance needs a list row at every size, with the same
    // normalized reference as the harness and the same rare-word set:
    // otherwise B-WER would be computed on the wrong partition.
    for (id, r, _) in &items {
        let ref_words = normalize(&r.reference);
        check_libri_rows(id, &ref_words, &rows).map_err(|e| format!("{name}: {e}"))?;
    }
    let ids_audio: Vec<(String, PathBuf)> = items
        .iter()
        .map(|(id, _, a)| (id.clone(), a.clone()))
        .collect();
    let proj = projected(
        tr,
        identity,
        &ids_audio,
        &set_cache_file(args, &name),
        args.threads,
    )?;
    let mut set_utts = Vec::new();
    for ((id, r, _), p) in items.iter().zip(proj) {
        let ref_words = normalize(&r.reference);
        let biasing = norm_set(&rows[0][id].rare);
        let lists: Vec<Vec<String>> = rows.iter().map(|m| m[id].list.clone()).collect();
        let list_norm = lists.iter().map(norm_set).collect();
        let surface = biasing.iter().map(|w| (w.clone(), w.clone())).collect();
        let group = data.groups.len();
        data.groups.push(Group {
            utts: 1,
            lists,
            list_norm,
            surface,
            keywords: false,
        });
        set_utts.push(data.utts.len());
        data.utts.push(Utt {
            id: id.clone(),
            session: libri_session(id),
            group,
            ref_words,
            biasing,
            m1_hyp: r.hyp.clone(),
            frames: p.frames,
            proj: Arc::new(p.proj),
        });
    }
    data.notes.push(format!(
        "{name}: all {} scored utterances matched to the biasing lists (same normalized reference, \
         same rare-word set at every size)",
        set_utts.len()
    ));
    data.sets.push(Set {
        name,
        role: l.role,
        utts: set_utts,
        sizes: (0..SIZES.len()).collect(),
    });
    Ok(())
}

/// Earnings-22 and SPGISpeech: the call id before `/`.
fn earnings_session(id: &str) -> String {
    id.split('/').next().unwrap_or(id).to_owned()
}

/// Which reference words count as rare (targets and the B-WER set).
enum RareRule {
    /// Exactly these (normalized) words: experiment 1's `all_rare_words.txt`.
    Words(BTreeSet<String>),
    /// Experiment 2's targets (`exp2_terms::is_target`): not among the common
    /// words, containing a letter, and session-specific by `df` (document
    /// frequency over every session of the dataset, all splits pooled).
    /// `known` (Le's rare list) is only used to report how many targets it
    /// would have covered.
    Common {
        common: Arc<BTreeSet<String>>,
        known: Arc<BTreeSet<String>>,
        df: Arc<exp2_terms::SessionDf>,
    },
}

impl RareRule {
    /// Whether a normalized word is rare (a target) under this rule.
    fn admits(&self, word: &str) -> bool {
        match self {
            RareRule::Words(w) => w.contains(word),
            RareRule::Common { common, df, .. } => exp2_terms::is_target(word, common, df),
        }
    }

    /// The rare words of `references` (normalized, deduplicated).
    fn words_of<'a>(&self, references: impl IntoIterator<Item = &'a str>) -> BTreeSet<String> {
        match self {
            RareRule::Words(w) => w.clone(),
            RareRule::Common { .. } => references
                .into_iter()
                .flat_map(normalize)
                .filter(|w| self.admits(w))
                .collect(),
        }
    }

    /// `pool` restricted to words this rule admits (the distractor fallback).
    fn filter_pool(&self, pool: Vec<String>) -> Vec<String> {
        match self {
            RareRule::Words(_) => pool,
            RareRule::Common { .. } => pool.into_iter().filter(|w| self.admits(w)).collect(),
        }
    }
}

#[derive(Clone, Copy)]
enum SessionSplit {
    /// Experiment 1: a seeded half of the sessions tunes, the rest is held
    /// out (sets `{name}_tune` and `{name}_test`).
    Halves,
    /// Every session in one set `{name}` with this role.
    All(Role),
}

/// Where a session set's utterances and references come from.
enum ItemsFrom {
    /// An evaluation JSON (`records` with id, ref, hyp, scored) plus the
    /// manifest for audio (experiment 1's sets).
    Eval(PathBuf),
    /// The manifest alone: `text` is the reference; an utterance is scored
    /// when its normalized reference is non-empty.
    Manifest,
}

/// The dictionary of each session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ListCondition {
    /// Rare reference words (targets) plus same-split distractors.
    Rare,
    /// The session's `keywords` (e.g. slide keywords), padded with the
    /// keywords of other same-split sessions; B-WER words are the words of
    /// the session's keywords. Set `{name}_keywords`.
    Keywords,
}

/// A set with one dictionary per session (call), built as experiment 1
/// builds Earnings-22's: targets are the session's rare reference words in
/// their most frequent cased form; distractors are other same-split
/// sessions' targets, then `fallback`.
struct SessionSource {
    name: String,
    items_from: ItemsFrom,
    manifest: PathBuf,
    session_of: Box<dyn Fn(&str) -> String>,
    /// Sessions to keep (all when `None`).
    keep_session: Option<fn(&str) -> bool>,
    rare: RareRule,
    fallback: Vec<String>,
    split: SessionSplit,
    /// Per-session cache files `(root, set dir)` (`enc_cache`), instead of
    /// experiment 1's whole-set file.
    groups_cache: Option<(PathBuf, String)>,
    /// Lists of the first condition; `_keywords` is inserted before the
    /// extension for the keyword condition.
    lists_out: PathBuf,
    conditions: Vec<ListCondition>,
    /// Session -> keywords (surface forms), for [`ListCondition::Keywords`].
    keywords: HashMap<String, Vec<String>>,
    /// Declared casing (experiment 2 sets): entry surfaces are normalized
    /// with `exp2_terms::normalize_entry_surface`; `None` leaves them as
    /// built (experiment 1).
    casing: Option<exp2_terms::Casing>,
}

/// The casing normalization of a condition's entries: the set's declared
/// casing for rare-word lists. Keyword entries stay as given: they are
/// encoded from their original and lowercase surfaces
/// ([`keyword_phrases`]), so an all-uppercase OCR keyword yields "neural"
/// and "Neural" while an acronym ("GPU") stays boostable. `None` leaves
/// entries as built.
fn list_casing(
    cond: ListCondition,
    declared: Option<exp2_terms::Casing>,
) -> Option<exp2_terms::Casing> {
    match cond {
        ListCondition::Rare => declared,
        ListCondition::Keywords => None,
    }
}

/// Declared casing: every entry's surface before case variants
/// (`exp2_terms::normalize_entry_surface`).
fn normalize_list_surfaces(
    lists: &mut BTreeMap<String, Vec<bias_lists::SessionList>>,
    casing: exp2_terms::Casing,
) {
    for l in lists.values_mut().flatten() {
        for e in &mut l.entries {
            *e = exp2_terms::normalize_entry_surface(e, casing);
        }
    }
}

/// Every manifest line, in file order.
fn manifest_lines(path: &Path) -> Result<Vec<Value>, String> {
    read_text(path)?
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).map_err(|e| format!("{}: {e}", path.display())))
        .collect()
}

/// Every manifest line `(id, audio)`, in file order.
fn manifest_entries(path: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    Ok(manifest_lines(path)?
        .iter()
        .filter_map(|v| {
            Some((
                v.get("id")?.as_str()?.to_owned(),
                PathBuf::from(v.get("audio_filepath")?.as_str()?),
            ))
        })
        .collect())
}

/// A JSON scalar as a string (sessions may be numbers).
fn json_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// Keywords of a manifest line: a JSON array of strings, or one string with
/// keywords separated by `;` or `,`.
fn line_keywords(v: &Value) -> Vec<String> {
    match v.get("keywords") {
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|k| k.as_str())
            .map(str::to_owned)
            .collect(),
        Some(Value::String(s)) => s.split([';', ',']).map(str::to_owned).collect(),
        _ => Vec::new(),
    }
    .into_iter()
    .map(|k| k.split_whitespace().collect::<Vec<_>>().join(" "))
    .filter(|k| !k.is_empty())
    .collect()
}

/// Utterances of a manifest-only set: `(id, record, audio)` with the `text`
/// as reference; unscored when it normalizes to nothing.
fn manifest_items(
    path: &Path,
    notes: &mut Vec<String>,
) -> Result<Vec<(String, EvalRecord, PathBuf)>, String> {
    let mut out = Vec::new();
    let (mut total, mut empty) = (0, 0);
    for v in manifest_lines(path)? {
        total += 1;
        let (Some(id), Some(audio)) = (
            v.get("id").and_then(Value::as_str),
            v.get("audio_filepath").and_then(Value::as_str),
        ) else {
            return Err(format!(
                "{}: line without id or audio_filepath",
                path.display()
            ));
        };
        let reference = v
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        if normalize(&reference).is_empty() {
            empty += 1;
            continue;
        }
        out.push((
            id.to_owned(),
            EvalRecord {
                reference,
                hyp: String::new(),
                scored: true,
            },
            PathBuf::from(audio),
        ));
    }
    notes.push(format!(
        "{}: {total} manifest lines, {empty} with an empty reference (unscored), {} used",
        stem(path),
        out.len()
    ));
    Ok(out)
}

/// Projections of `items` from per-group cache files under `root/set`: each
/// group holds every manifest line of that session in manifest order (with
/// `--limit`, only the limited items, in a separate `set.firstN` directory).
#[allow(clippy::too_many_arguments)]
fn group_projections(
    args: &Args,
    src: &SessionSource,
    root: &Path,
    set: &str,
    items: &[(String, EvalRecord, PathBuf)],
    tr: &mut Transcriber,
    identity: &CacheIdentity,
) -> Result<Vec<Projected>, String> {
    let wanted: BTreeSet<&str> = items.iter().map(|(id, _, _)| id.as_str()).collect();
    let sessions: BTreeSet<String> = items
        .iter()
        .map(|(id, _, _)| (src.session_of)(id))
        .collect();
    let mut groups: BTreeMap<String, Vec<(String, PathBuf)>> = BTreeMap::new();
    for (id, audio) in manifest_entries(&src.manifest)? {
        let s = (src.session_of)(&id);
        let keep = match args.limit {
            Some(_) => wanted.contains(id.as_str()),
            None => sessions.contains(&s),
        };
        if keep {
            groups.entry(s).or_default().push((id, audio));
        }
    }
    let set_dir = match args.limit {
        Some(n) => format!("{set}.first{n}"),
        None => set.to_owned(),
    };
    let mut by_id: HashMap<String, Projected> = HashMap::new();
    let start = Instant::now();
    for (g, ids_audio) in &groups {
        let path = enc_cache::group_path(root, &set_dir, g)?;
        let proj = enc_cache::projected(tr, &identity.shared(), ids_audio, &path, args.threads)?;
        for ((id, _), p) in ids_audio.iter().zip(proj) {
            by_id.insert(
                id.clone(),
                Projected {
                    frames: p.frames,
                    proj: p.proj,
                },
            );
        }
    }
    eprintln!(
        "{}: {} cached groups ready in {:.1?}",
        root.join(&set_dir).display(),
        groups.len(),
        start.elapsed()
    );
    items
        .iter()
        .map(|(id, _, _)| by_id.remove(id).ok_or(format!("{id}: not in the manifest")))
        .collect()
}

/// `path` with `_keywords` before its extension.
fn keywords_path(path: &Path) -> PathBuf {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("lists");
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("json");
    path.with_file_name(format!("{stem}_keywords.{ext}"))
}

/// Per session, its keywords as targets `(normalized key, surface)`: the
/// first surface of each normalized key, sorted by key.
fn keyword_targets(
    sessions: &BTreeSet<String>,
    keywords: &HashMap<String, Vec<String>>,
) -> BTreeMap<String, Vec<(String, String)>> {
    sessions
        .iter()
        .map(|s| {
            let mut m: BTreeMap<String, String> = BTreeMap::new();
            for k in keywords.get(s).into_iter().flatten() {
                let key = normalize(k).join(" ");
                if !key.is_empty() {
                    m.entry(key).or_insert_with(|| k.clone());
                }
            }
            (s.clone(), m.into_iter().collect())
        })
        .collect()
}

/// Loads a session set (see [`SessionSource`]), one set per list condition
/// (the utterances share their projections). Returns each set's name and
/// lists summary.
fn load_sessions(
    data: &mut Data,
    args: &Args,
    src: &SessionSource,
    tr: &mut Transcriber,
    identity: &CacheIdentity,
) -> Result<Vec<(String, Value)>, String> {
    let name = src.name.clone();
    let mut items = match &src.items_from {
        ItemsFrom::Eval(eval) => scored_items(eval, &src.manifest, None, &mut data.notes)?,
        ItemsFrom::Manifest => manifest_items(&src.manifest, &mut data.notes)?,
    };
    if let Some(keep) = src.keep_session {
        let before = items.len();
        items.retain(|(id, _, _)| keep(&(src.session_of)(id)));
        data.notes.push(format!(
            "{name}: {} of {before} scored utterances in the selected sessions",
            items.len()
        ));
    }
    if let Some(n) = args.limit {
        items.truncate(n);
    }
    let session_of = &src.session_of;
    let rare = src
        .rare
        .words_of(items.iter().map(|(_, r, _)| r.reference.as_str()));
    let fallback = src.rare.filter_pool(src.fallback.clone());
    let records: Vec<(String, &str)> = items
        .iter()
        .map(|(id, r, _)| (session_of(id), r.reference.as_str()))
        .collect();
    let mut vocab: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (s, t) in &records {
        vocab.entry(s.clone()).or_default().extend(normalize(t));
    }
    let sessions: BTreeSet<String> = vocab.keys().cloned().collect();
    if sessions.is_empty() {
        return Err(format!("{name}: no sessions"));
    }
    // Split first, then draw each part's distractors from that part only.
    let (tune, test) = match src.split {
        SessionSplit::Halves => bias_lists::split_sessions(&sessions, args.seed),
        SessionSplit::All(Role::Tune) => (sessions.clone(), BTreeSet::new()),
        SessionSplit::All(Role::Test) => (BTreeSet::new(), sessions.clone()),
    };
    if matches!(src.split, SessionSplit::Halves) && (tune.is_empty() || test.is_empty()) {
        return Err(format!(
            "{name}: {} sessions cannot be split into tuning and held-out halves",
            sessions.len()
        ));
    }
    let parts: Vec<&BTreeSet<String>> = [&tune, &test]
        .into_iter()
        .filter(|p| !p.is_empty())
        .collect();

    let proj = match &src.groups_cache {
        None => {
            let ids_audio: Vec<(String, PathBuf)> = items
                .iter()
                .map(|(id, _, a)| (id.clone(), a.clone()))
                .collect();
            projected(
                tr,
                identity,
                &ids_audio,
                &set_cache_file(args, &name),
                args.threads,
            )?
        }
        Some((root, set)) => group_projections(args, src, root, set, &items, tr, identity)?,
    };
    let proj: Vec<(usize, Arc<Vec<f32>>)> = proj
        .into_iter()
        .map(|p| (p.frames, Arc::new(p.proj)))
        .collect();

    let mut out = Vec::new();
    for &cond in &src.conditions {
        let (set_name, lists_out) = match cond {
            ListCondition::Rare => (name.clone(), src.lists_out.clone()),
            ListCondition::Keywords => (format!("{name}_keywords"), keywords_path(&src.lists_out)),
        };
        let mut targets = match cond {
            ListCondition::Rare => {
                bias_lists::session_targets(records.iter().map(|(s, t)| (s.as_str(), *t)), &rare)
            }
            ListCondition::Keywords => keyword_targets(&sessions, &src.keywords),
        };
        // Sessions without any target still get a list of distractors.
        for s in &sessions {
            targets.entry(s.clone()).or_default();
        }
        // Keyword padding: another session's keyword phrase that is spoken
        // in this session's references is not a distractor (phrase-aware;
        // single words are already in `vocab`).
        let keyword_vocab;
        let vocab_for = match cond {
            ListCondition::Rare => &vocab,
            ListCondition::Keywords => {
                let keys: BTreeSet<String> = targets
                    .values()
                    .flat_map(|t| t.iter().map(|(k, _)| k.clone()))
                    .collect();
                let spoken = exp2_phrases::phrases_in_references(
                    records.iter().map(|(s, t)| (s.as_str(), *t)),
                    &keys,
                );
                let mut v = vocab.clone();
                for (s, p) in spoken {
                    v.entry(s).or_default().extend(p);
                }
                keyword_vocab = v;
                &keyword_vocab
            }
        };
        let mut lists = bias_lists::session_lists_by_split(
            &targets, vocab_for, &fallback, &SIZES, args.seed, &parts,
        );
        if let Some(c) = list_casing(cond, src.casing) {
            normalize_list_surfaces(&mut lists, c);
        }
        let short: Vec<String> = lists
            .iter()
            .flat_map(|(s, ls)| {
                ls.iter()
                    .filter(|l| l.entries.len() > l.targets + l.from_other_sessions)
                    .map(move |l| {
                        format!(
                            "{s} size {}: {} from the fallback pool",
                            l.size,
                            l.entries.len() - l.targets - l.from_other_sessions
                        )
                    })
            })
            .collect();
        data.notes.push(if short.is_empty() {
            format!("{set_name}: same-split targets sufficed for every distractor")
        } else if short.len() <= 24 {
            format!(
                "{set_name}: same-split targets ran short; padded from the rare-word list: {}",
                short.join("; ")
            )
        } else {
            format!(
                "{set_name}: same-split targets ran short for {} session lists; padded from the rare-word list",
                short.len()
            )
        });

        // B-WER words: the session's targets' words (keywords), else rare words.
        let keyword_words: BTreeMap<&String, BTreeSet<String>> = targets
            .iter()
            .map(|(s, t)| (s, t.iter().flat_map(|(k, _)| normalize(k)).collect()))
            .collect();
        let mut group_of = BTreeMap::new();
        for (s, ls) in &lists {
            let surface = match cond {
                ListCondition::Rare => targets[s].iter().cloned().collect(),
                ListCondition::Keywords => targets[s]
                    .iter()
                    .flat_map(|(k, surf)| normalize(k).into_iter().map(move |w| (w, surf.clone())))
                    .collect(),
            };
            group_of.insert(s.clone(), data.groups.len());
            let entries: Vec<Vec<String>> = ls.iter().map(|l| l.entries.clone()).collect();
            data.groups.push(Group {
                utts: 0,
                list_norm: entries.iter().map(norm_set).collect(),
                lists: entries,
                surface,
                keywords: cond == ListCondition::Keywords,
            });
        }
        let first_set = data.sets.len();
        let all_sizes: Vec<usize> = (0..SIZES.len()).collect();
        match src.split {
            SessionSplit::Halves => {
                data.sets.push(Set {
                    name: format!("{set_name}_tune"),
                    role: Role::Tune,
                    utts: Vec::new(),
                    sizes: all_sizes.clone(),
                });
                data.sets.push(Set {
                    name: format!("{set_name}_test"),
                    role: Role::Test,
                    utts: Vec::new(),
                    sizes: all_sizes,
                });
            }
            SessionSplit::All(role) => data.sets.push(Set {
                name: set_name.clone(),
                role,
                utts: Vec::new(),
                sizes: all_sizes,
            }),
        }
        for ((id, r, _), (frames, p)) in items.iter().zip(&proj) {
            let s = session_of(id);
            let set = match src.split {
                SessionSplit::Halves if !tune.contains(&s) => first_set + 1,
                _ => first_set,
            };
            let group = group_of[&s];
            data.groups[group].utts += 1;
            let ref_words = reference_words(&r.reference);
            let biasing = ref_words
                .iter()
                .filter(|w| match cond {
                    ListCondition::Rare => rare.contains(*w),
                    ListCondition::Keywords => keyword_words[&s].contains(*w),
                })
                .cloned()
                .collect();
            data.sets[set].utts.push(data.utts.len());
            data.utts.push(Utt {
                id: id.clone(),
                session: s.clone(),
                group,
                ref_words,
                biasing,
                m1_hyp: r.hyp.clone(),
                frames: *frames,
                proj: Arc::clone(p),
            });
        }
        let in_known = |s: &str| -> Option<usize> {
            match (&src.rare, cond) {
                (RareRule::Common { known, .. }, ListCondition::Rare) => {
                    Some(targets[s].iter().filter(|(n, _)| known.contains(n)).count())
                }
                _ => None,
            }
        };
        let per_session: Value = lists
            .iter()
            .map(|(s, ls)| {
                let mut v = json!({
                    "split": if tune.contains(s) { "tune" } else { "held-out" },
                    "utterances": data.groups[group_of[s]].utts,
                    "targets": targets[s].len(),
                    "lists": ls.iter().map(|l| json!({
                        "size": l.size,
                        "entries": l.entries.len(),
                        "targets": l.targets,
                        "from_other_sessions": l.from_other_sessions,
                        "from_fallback": l.entries.len() - l.targets - l.from_other_sessions,
                    })).collect::<Vec<_>>(),
                });
                if let Some(k) = in_known(s) {
                    v["targets_in_le_rare_list"] = json!(k);
                }
                (s.clone(), v)
            })
            .collect::<serde_json::Map<_, _>>()
            .into();
        let mut info = json!({ "sessions": per_session, "seed": args.seed });
        if let (RareRule::Common { df, .. }, ListCondition::Rare) = (&src.rare, cond) {
            let all: usize = targets.values().map(Vec::len).sum();
            let known: usize = targets.keys().filter_map(|s| in_known(s)).sum();
            info["rare_rule"] = json!(format!(
                "exp2_terms::is_target: not among the {} most frequent words of Le et al.'s \
                 all_words.count.txt, with a letter, and in at most {} of the dataset's {} \
                 sessions (all splits pooled)",
                exp2_data::COMMON_WORDS,
                df.max_df(),
                df.sessions()
            ));
            info["df_sessions"] = json!(df.sessions());
            info["max_df"] = json!(df.max_df());
            info["fallback_pool"] = json!(fallback.len());
            info["targets_total"] = json!(all);
            info["targets_in_le_rare_list"] = json!(known);
            data.notes.push(format!(
                "{set_name}: {all} session targets (rare and in at most {} of {} sessions), \
                 {known} of them in all_rare_words",
                df.max_df(),
                df.sessions()
            ));
        }
        if cond == ListCondition::Keywords {
            info["condition"] = json!("session keywords padded with same-split distractors");
        }
        let full = json!({
            "description": "Per-session (call) dictionaries: targets (rare reference words in their most frequent cased form, or the session's keywords) then distractors (targets of other sessions in the same split, then the fallback rare-word list).",
            "seed": args.seed,
            "tune_sessions": tune,
            "test_sessions": test,
            "sessions": lists.iter().map(|(s, ls)| (s.clone(), json!({
                "targets": targets[s].iter().map(|(n, f)| json!([n, f])).collect::<Vec<_>>(),
                "lists": ls.iter().map(|l| json!({"size": l.size, "targets": l.targets, "from_other_sessions": l.from_other_sessions, "entries": l.entries})).collect::<Vec<_>>(),
            }))).collect::<serde_json::Map<_, _>>(),
        });
        outpath::write_output(
            &lists_out,
            serde_json::to_string_pretty(&full).unwrap().as_bytes(),
        )?;
        let show = |p: &BTreeSet<String>| {
            if p.len() <= 12 {
                format!("{p:?}")
            } else {
                format!("{} sessions", p.len())
            }
        };
        data.notes.push(format!(
            "{set_name}: {} sessions, tune {}, held-out {}; lists written to {}",
            sessions.len(),
            show(&tune),
            show(&test),
            lists_out.display()
        ));
        out.push((set_name, info));
    }
    Ok(out)
}

// ---------------------------------------------------------------- decoding

/// Phrases per dictionary entry: `[plain, with case variants]`. Entries the
/// vocabulary cannot encode are absent.
type PhraseCache = HashMap<String, [Vec<Vec<usize>>; 3]>;

/// An entry's phrases for a keyword list: `phrases(.., case_variants)` of
/// each of its surfaces (original and lowercase), deduplicated, so an
/// all-caps keyword ("GPU") stays boostable as written and in lowercase.
fn keyword_phrases(tokenizer: &Tokenizer, entry: &str) -> lf_model::Result<Vec<Vec<usize>>> {
    let surfaces = exp2_terms::keyword_entry_surfaces(entry);
    let mut out: Vec<Vec<usize>> = Vec::new();
    for p in lf_asr::bias::phrases(tokenizer, &surfaces, true)? {
        if !out.contains(&p) {
            out.push(p);
        }
    }
    Ok(out)
}

/// The cached phrases of `entry`: with case variants or not, and for a
/// keyword list the union over its surfaces (index 2).
fn cached_phrases<'a>(
    cache: &'a PhraseCache,
    entry: &str,
    case: bool,
    keywords: bool,
) -> Option<&'a Vec<Vec<usize>>> {
    let p = cache.get(entry)?;
    Some(match (case, keywords) {
        (true, true) => &p[2],
        (true, false) => &p[1],
        (false, _) => &p[0],
    })
}

fn par_map<T: Send + Sync, R: Send>(
    items: &[T],
    threads: usize,
    f: &(dyn Fn(&T) -> R + Sync),
) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..threads.max(1) {
            s.spawn(|| {
                let mut local = Vec::new();
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= items.len() {
                        break;
                    }
                    local.push((i, f(&items[i])));
                }
                let mut o = out.lock().unwrap();
                for (i, r) in local {
                    o[i] = Some(r);
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

fn phrase_cache(tokenizer: &Tokenizer, groups: &[Group], threads: usize) -> (PhraseCache, usize) {
    let entries: BTreeSet<&String> = groups
        .iter()
        .flat_map(|g| g.lists.iter().flatten())
        .collect();
    let entries: Vec<&String> = entries.into_iter().collect();
    let encoded = par_map(&entries, threads, &|e: &&String| {
        let one = std::slice::from_ref(*e);
        let plain = lf_asr::bias::phrases(tokenizer, one, false).ok()?;
        let cased = lf_asr::bias::phrases(tokenizer, one, true).ok()?;
        // Only an entry with capitals differs as a keyword.
        let keyword = if e.to_lowercase() == **e {
            cased.clone()
        } else {
            keyword_phrases(tokenizer, e).ok()?
        };
        Some([plain, cased, keyword])
    });
    let mut cache = HashMap::new();
    let mut skipped = 0;
    for (e, p) in entries.into_iter().zip(encoded) {
        match p {
            Some(p) => {
                cache.insert(e.clone(), p);
            }
            None => skipped += 1,
        }
    }
    (cache, skipped)
}

/// `Cfg` as a hashable key: alpha and depth bits, cancel, case variants.
type CfgKey = (u32, u32, bool, bool);

/// Best configuration, its objective, and every configuration tried.
type StageResult = Result<(Cfg, f64, Vec<(Cfg, f64)>), String>;

#[derive(Clone, Copy, Debug, PartialEq)]
struct Cfg {
    alpha: f32,
    depth: f32,
    cancel: bool,
    case: bool,
}

impl Cfg {
    fn key(&self) -> CfgKey {
        (
            self.alpha.to_bits(),
            self.depth.to_bits(),
            self.cancel,
            self.case,
        )
    }

    fn bias(&self) -> BiasConfig {
        BiasConfig {
            alpha: self.alpha,
            context_score: CONTEXT_SCORE,
            depth_scaling: self.depth,
            cancel_unfinished: self.cancel,
        }
    }

    fn label(&self) -> String {
        format!(
            "alpha {} depth {} cancel {} case {}",
            self.alpha,
            self.depth,
            if self.cancel { "on" } else { "off" },
            if self.case { "on" } else { "off" }
        )
    }

    fn json(&self) -> Value {
        json!({"alpha": self.alpha, "context_score": CONTEXT_SCORE, "depth_scaling": self.depth,
               "cancel_unfinished": self.cancel, "case_variants": self.case})
    }
}

fn build_graph(
    entries: &[String],
    cache: &PhraseCache,
    cfg: &Cfg,
    keywords: bool,
) -> Result<Option<BiasGraph>, String> {
    let phrases: Vec<Vec<usize>> = entries
        .iter()
        .filter_map(|e| cached_phrases(cache, e, cfg.case, keywords))
        .flat_map(|p| p.iter().cloned())
        .collect();
    if phrases.is_empty() || cfg.alpha == 0.0 {
        return Ok(None);
    }
    BiasGraph::new(&phrases, VOCAB, cfg.bias()).map(Some)
}

struct Engine<'a> {
    decoder: &'a PackedDecoder,
    tokenizer: &'a Tokenizer,
    cache: &'a PhraseCache,
    workers: usize,
    per_worker: usize,
}

#[derive(Clone)]
struct Decoded {
    text: String,
    words: Vec<String>,
    ns: u64,
}

impl Engine<'_> {
    /// Runs `f(pool, item)` over `items` on the worker pools, longest first
    /// (by `cost`), and returns results in item order.
    fn run<T: Sync, R: Send>(
        &self,
        items: &[T],
        cost: &(dyn Fn(&T) -> usize + Sync),
        f: &(dyn Fn(&ThreadPool, &T) -> R + Sync),
    ) -> Vec<R> {
        let mut order: Vec<usize> = (0..items.len()).collect();
        order.sort_by_key(|&i| std::cmp::Reverse(cost(&items[i])));
        let next = AtomicUsize::new(0);
        let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
        std::thread::scope(|s| {
            for w in 0..self.workers {
                let (order, next, out) = (&order, &next, &out);
                s.spawn(move || {
                    let cpus: Vec<usize> =
                        (w * self.per_worker..(w + 1) * self.per_worker).collect();
                    let pool = ThreadPool::new(&cpus);
                    let mut local = Vec::new();
                    loop {
                        let k = next.fetch_add(1, Ordering::Relaxed);
                        if k >= order.len() {
                            break;
                        }
                        let i = order[k];
                        local.push((i, f(&pool, &items[i])));
                    }
                    let mut o = out.lock().unwrap();
                    for (i, r) in local {
                        o[i] = Some(r);
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

    fn decode(&self, pool: &ThreadPool, u: &Utt, graph: Option<&BiasGraph>) -> Decoded {
        let start = Instant::now();
        let emitted = self.decoder.decode(pool, &u.proj, u.frames, None, graph);
        let ns = start.elapsed().as_nanos() as u64;
        let tokens: Vec<usize> = emitted.iter().map(|&(t, _)| t).collect();
        let text = self.tokenizer.decode(&tokens).unwrap_or_default();
        let words = normalize(&text);
        Decoded { text, words, ns }
    }

    /// Decodes `utts` with each utterance's group list at `size` (an index
    /// into `SIZES`), or without bias when `cfg` is `None`.
    fn decode_set(
        &self,
        data: &Data,
        utts: &[usize],
        size: usize,
        cfg: Option<&Cfg>,
    ) -> Result<Vec<Decoded>, String> {
        let shared: Vec<OnceLock<Result<Option<BiasGraph>, String>>> =
            (0..data.groups.len()).map(|_| OnceLock::new()).collect();
        let results = self.run(utts, &|&i| data.utts[i].frames, &|pool,
                                                                  &i|
         -> Result<
            Decoded,
            String,
        > {
            let u = &data.utts[i];
            let Some(cfg) = cfg else {
                return Ok(self.decode(pool, u, None));
            };
            let g = &data.groups[u.group];
            if g.utts > 1 {
                let graph = shared[u.group]
                    .get_or_init(|| build_graph(&g.lists[size], self.cache, cfg, g.keywords));
                let graph = graph.as_ref().map_err(Clone::clone)?;
                Ok(self.decode(pool, u, graph.as_ref()))
            } else {
                let graph = build_graph(&g.lists[size], self.cache, cfg, g.keywords)?;
                Ok(self.decode(pool, u, graph.as_ref()))
            }
        });
        results.into_iter().collect()
    }
}

// ---------------------------------------------------------------- metrics

#[derive(Clone, Copy, Default)]
struct SetMetrics {
    utts: usize,
    counts: Counts,
    /// Utterances with fewer / more word errors than the unbiased decode.
    fixed: usize,
    broken: usize,
    decode_ns: u64,
    base_ns: u64,
}

fn rate_json(r: &Rate) -> Value {
    json!({"words": r.words, "sub": r.sub, "del": r.del, "ins": r.ins, "errors": r.errors(), "percent": r.percent()})
}

impl SetMetrics {
    fn json(&self) -> Value {
        json!({
            "utterances": self.utts,
            "wer": rate_json(&self.counts.wer),
            "b_wer": rate_json(&self.counts.b),
            "u_wer": rate_json(&self.counts.u),
            "b_matched": self.counts.b_matched,
            "recall": self.counts.recall(),
            "false_alarms": self.counts.false_alarms,
            "fixed": self.fixed,
            "broken": self.broken,
            "decode_ms": self.decode_ns as f64 / 1e6,
            "base_decode_ms": self.base_ns as f64 / 1e6,
            "decode_overhead": if self.base_ns > 0 { self.decode_ns as f64 / self.base_ns as f64 - 1.0 } else { 0.0 },
        })
    }
}

struct Baseline {
    decoded: Vec<Option<Decoded>>,
}

impl Baseline {
    fn get(&self, i: usize) -> &Decoded {
        self.decoded[i].as_ref().expect("baseline decoded")
    }
}

fn utt_counts(data: &Data, i: usize, words: &[String], size: usize) -> Counts {
    let u = &data.utts[i];
    bias_metrics::score(
        &u.ref_words,
        words,
        &u.biasing,
        &data.groups[u.group].list_norm[size],
    )
}

fn set_metrics(
    data: &Data,
    base: &Baseline,
    utts: &[usize],
    decoded: &[Decoded],
    size: usize,
) -> SetMetrics {
    let mut m = SetMetrics::default();
    for (&i, d) in utts.iter().zip(decoded) {
        let b = base.get(i);
        let c = utt_counts(data, i, &d.words, size);
        let cb = utt_counts(data, i, &b.words, size);
        m.utts += 1;
        m.counts.add(&c);
        m.fixed += usize::from(c.wer.errors() < cb.wer.errors());
        m.broken += usize::from(c.wer.errors() > cb.wer.errors());
        m.decode_ns += d.ns;
        m.base_ns += b.ns;
    }
    m
}

/// A reference's words as every metric counts them (`wer::normalize`):
/// `ref_words` of a session set's utterances and of `--count-refs`.
fn reference_words(reference: &str) -> Vec<String> {
    normalize(reference)
}

/// A LibriSpeech utterance's session: its speaker-chapter (`116-288045` of
/// `116-288045-0000` or `librispeech:116-288045-0000`).
fn libri_session(id: &str) -> String {
    let id = id.rsplit(':').next().unwrap_or(id);
    id.rsplit_once('-').map_or(id, |(s, _)| s).to_owned()
}

/// One session's counts for one row, set and size (`--per-session`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct SessionCounts {
    utts: usize,
    counts: Counts,
    fixed: usize,
    broken: usize,
    /// Word errors of the unbiased decode on the same utterances.
    baseline_errors: usize,
}

impl SessionCounts {
    fn add(&mut self, o: &SessionCounts) {
        self.utts += o.utts;
        self.counts.add(&o.counts);
        self.fixed += o.fixed;
        self.broken += o.broken;
        self.baseline_errors += o.baseline_errors;
    }

    /// The per-session fields (CONTRACT-2 NOTES, "Experiment 3 (R1)").
    fn json(&self) -> Value {
        let c = &self.counts;
        json!({
            "utterances": self.utts,
            "ref_words": c.wer.words,
            "sub": c.wer.sub,
            "del": c.wer.del,
            "ins": c.wer.ins,
            "errors": c.wer.errors(),
            "b_ref_words": c.b.words,
            "b_errors": c.b.errors(),
            "u_ref_words": c.u.words,
            "u_errors": c.u.errors(),
            "b_matched": c.b_matched,
            "false_alarms": c.false_alarms,
            "fixed": self.fixed,
            "broken": self.broken,
            "baseline_errors": self.baseline_errors,
            "net_errors": c.wer.errors() as i64 - self.baseline_errors as i64,
        })
    }
}

/// Per-session counts of `decoded` (one per utterance of `utts`), by session.
fn session_counts(
    data: &Data,
    base: &Baseline,
    utts: &[usize],
    decoded: &[Decoded],
    size: usize,
) -> BTreeMap<String, SessionCounts> {
    let mut out: BTreeMap<String, SessionCounts> = BTreeMap::new();
    for (&i, d) in utts.iter().zip(decoded) {
        let c = utt_counts(data, i, &d.words, size);
        let cb = utt_counts(data, i, &base.get(i).words, size);
        let one = SessionCounts {
            utts: 1,
            counts: c,
            fixed: usize::from(c.wer.errors() < cb.wer.errors()),
            broken: usize::from(c.wer.errors() > cb.wer.errors()),
            baseline_errors: cb.wer.errors(),
        };
        out.entry(data.utts[i].session.clone())
            .or_default()
            .add(&one);
    }
    out
}

/// The per-session counts must sum exactly to the set's aggregate (`m`) and
/// its baseline's word errors.
fn check_session_sums(
    sessions: &BTreeMap<String, SessionCounts>,
    m: &SetMetrics,
    baseline_errors: usize,
) -> Result<(), String> {
    let mut sum = SessionCounts::default();
    for s in sessions.values() {
        sum.add(s);
    }
    let agg = SessionCounts {
        utts: m.utts,
        counts: m.counts,
        fixed: m.fixed,
        broken: m.broken,
        baseline_errors,
    };
    if sum == agg {
        Ok(())
    } else {
        Err(format!(
            "per-session counts do not sum to the set aggregate: {sum:?} vs {agg:?}"
        ))
    }
}

fn baseline_metrics(data: &Data, base: &Baseline, utts: &[usize], size: usize) -> SetMetrics {
    let decoded: Vec<Decoded> = utts
        .iter()
        .map(|&i| {
            let b = base.get(i);
            Decoded {
                text: String::new(),
                words: b.words.clone(),
                ns: b.ns,
            }
        })
        .collect();
    set_metrics(data, base, utts, &decoded, size)
}

// ---------------------------------------------------------------- sweep

struct Sweeper<'a> {
    engine: &'a Engine<'a>,
    data: &'a Data,
    base: &'a Baseline,
    /// (cfg key, set, size) -> metrics
    memo: HashMap<(CfgKey, usize, usize), SetMetrics>,
    rows: Vec<Value>,
    runs: usize,
    decode_s: f64,
    /// Experiment 2's dev objective instead of experiment 1's.
    dev_objective: bool,
}

impl Sweeper<'_> {
    fn metrics(
        &mut self,
        stage: &str,
        cfg: &Cfg,
        set: usize,
        size: usize,
    ) -> Result<SetMetrics, String> {
        let key = (cfg.key(), set, size);
        if let Some(m) = self.memo.get(&key) {
            return Ok(*m);
        }
        let utts = &self.data.sets[set].utts;
        let start = Instant::now();
        let decoded = self.engine.decode_set(self.data, utts, size, Some(cfg))?;
        self.decode_s += start.elapsed().as_secs_f64();
        self.runs += 1;
        let m = set_metrics(self.data, self.base, utts, &decoded, size);
        self.memo.insert(key, m);
        let s = &self.data.sets[set];
        self.rows.push(json!({
            "stage": stage, "set": s.name, "role": s.role.name(), "size": SIZES[size],
            "config": cfg.json(), "metrics": m.json(),
        }));
        Ok(m)
    }

    /// Mean over tune sets and sizes of WER relative to the unbiased decode
    /// (experiment 1), or experiment 2's dev objective (with `dev_objective`):
    /// the equal-weight mean over dev domains of each one's mean over its sizes.
    fn objective(&mut self, stage: &str, cfg: &Cfg) -> Result<f64, String> {
        let tune: Vec<usize> = (0..self.data.sets.len())
            .filter(|&s| self.data.sets[s].role == Role::Tune)
            .collect();
        let mut pairs = Vec::new();
        let mut per_set = Vec::new();
        for &s in &tune {
            let base = baseline_metrics(self.data, self.base, &self.data.sets[s].utts, 0);
            let mut set_pairs = Vec::new();
            for size in self.data.sets[s].sizes.clone() {
                let m = self.metrics(stage, cfg, s, size)?;
                set_pairs.push((m.counts.wer.errors(), base.counts.wer.errors()));
            }
            pairs.extend_from_slice(&set_pairs);
            per_set.push((self.data.sets[s].name.clone(), set_pairs));
        }
        let obj = if self.dev_objective {
            learned_eval::dev_objective(&per_set)?
        } else {
            relative_wer_objective(&pairs)?
        };
        eprintln!("  [{stage}] {}: relative WER {obj:.4}", cfg.label());
        Ok(obj)
    }

    /// `base` at each of `alphas`; with `extend`, also at higher alphas (steps
    /// of sqrt 2) while the best is the highest tried.
    fn alpha_family(
        &mut self,
        stage: &str,
        base: Cfg,
        alphas: &[f32],
        extend: bool,
    ) -> StageResult {
        let cfgs: Vec<Cfg> = alphas.iter().map(|&alpha| Cfg { alpha, ..base }).collect();
        let (mut b, mut o, mut all) = self.best_of(stage, &cfgs)?;
        let mut top = *alphas.last().ok_or("no alphas")?;
        while extend && b.alpha == top && top < 64.0 {
            top = round3(top * std::f32::consts::SQRT_2);
            let c = Cfg { alpha: top, ..base };
            let oc = self.objective(stage, &c)?;
            all.push((c, oc));
            if oc < o {
                (b, o) = (c, oc);
            }
        }
        Ok((b, o, all))
    }

    fn best_of(&mut self, stage: &str, cfgs: &[Cfg]) -> StageResult {
        let mut all = Vec::new();
        for c in cfgs {
            let o = self.objective(stage, c)?;
            all.push((*c, o));
        }
        let (c, o) = all
            .iter()
            .copied()
            .fold(None::<(Cfg, f64)>, |acc, (c, o)| match acc {
                Some((_, bo)) if bo <= o => acc,
                _ => Some((c, o)),
            })
            .ok_or("empty stage")?;
        Ok((c, o, all))
    }
}

/// Mean over (tuning set, list size) of word errors relative to the unbiased
/// decode, from `(errors, baseline errors)` pairs. Refuses empty tuning data,
/// a zero baseline (the ratio is undefined) and non-finite results.
fn relative_wer_objective(pairs: &[(usize, usize)]) -> Result<f64, String> {
    if pairs.is_empty() {
        return Err("no tuning data: the objective needs at least one tuning set".into());
    }
    if pairs.iter().any(|&(_, base)| base == 0) {
        return Err("a tuning set has no baseline errors; relative WER is undefined".into());
    }
    let obj = pairs
        .iter()
        .map(|&(e, base)| e as f64 / base as f64)
        .sum::<f64>()
        / pairs.len() as f64;
    if obj.is_finite() {
        Ok(obj)
    } else {
        Err(format!("non-finite objective {obj}"))
    }
}

fn round3(x: f32) -> f32 {
    (x * 1000.0).round() / 1000.0
}

fn stage_json(name: &str, all: &[(Cfg, f64)], best: &Cfg) -> Value {
    json!({
        "stage": name,
        "best": best.json(),
        "objective": all.iter().map(|(c, o)| json!({"config": c.json(), "relative_wer": o})).collect::<Vec<_>>(),
    })
}

// ---------------------------------------------------------------- oracle

struct OracleCase {
    utt: usize,
    word: String,
    entry: String,
    /// Baseline: matched occurrences of `word`, errors on other words.
    base_matched: usize,
    /// Reference occurrences of `word` the baseline missed (at least 1).
    missed: usize,
    base_other_errors: usize,
    /// What the baseline produced where `word` should be (aligned hypothesis word).
    said: Option<String>,
}

struct OracleResult {
    matched: usize,
    other_errors: usize,
    hyp_edits: usize,
}

fn oracle_cases(data: &Data, base: &Baseline, set: usize) -> Vec<OracleCase> {
    let mut out = Vec::new();
    for &i in &data.sets[set].utts {
        let u = &data.utts[i];
        let hyp = &base.get(i).words;
        let align = bias_metrics::align(&u.ref_words, hyp);
        for w in &u.biasing {
            let refcount = u.ref_words.iter().filter(|r| *r == w).count();
            let matched = bias_metrics::matched(&u.ref_words, hyp, w);
            if matched >= refcount {
                continue;
            }
            let said = align.iter().find_map(|&(code, r, h)| {
                (code == bias_metrics::Code::Sub && r.is_some_and(|r| &u.ref_words[r] == w))
                    .then(|| hyp[h.unwrap()].clone())
            });
            let entry = data.groups[u.group]
                .surface
                .get(w)
                .cloned()
                .unwrap_or_else(|| w.clone());
            out.push(OracleCase {
                utt: i,
                word: w.clone(),
                entry,
                base_matched: matched,
                missed: refcount - matched,
                base_other_errors: bias_metrics::errors_except(&u.ref_words, hyp, w),
                said,
            });
        }
    }
    out
}

fn quantile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

// ---------------------------------------------------------------- main

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// Every path this run writes (results, lists, cache) must be outside any
/// Git work tree, checked before any work starts.
fn check_output_locations(args: &Args) -> Result<(), String> {
    if let Some(out) = &args.out {
        outpath::check_output_dir(out)?;
    }
    if let Some(p) = &args.lists_out {
        outpath::check_output_path(p)?;
    }
    outpath::check_output_dir(&args.cache)
}

/// The export twice: a decoding model and an i8x2 transcriber on `threads`
/// CPUs (for encoding), both with `Storage::F16` decoder weights, and the
/// cache identity.
fn open_models(args: &Args) -> Result<(Model, Transcriber, CacheIdentity), String> {
    let export =
        Export::open(&args.export).map_err(|e| format!("{}: {e}", args.export.display()))?;
    // `Export::open` verified every file against these hashes.
    let export_sha256 = lf_model::manifest::sha256_hex(
        serde_json::to_string(&json!({
            "format": export.manifest.format,
            "files": export.manifest.files,
        }))
        .unwrap()
        .as_bytes(),
    );
    let enc_model = Model::load(&export, Storage::F16).map_err(|e| e.to_string())?;
    let model = Model::load(&export, Storage::F16).map_err(|e| e.to_string())?;
    drop(export);
    let identity = CacheIdentity {
        export_sha256,
        precision: "i8x2".into(),
        joint_padded: model.decoder.joint_padded(),
    };
    let cpus: Vec<usize> = (0..args.threads).collect();
    let tr = Transcriber::new(enc_model, &cpus, Precision::Int8(2));
    Ok((model, tr, identity))
}

/// Experiment 1's staged search of the fixed-bonus family.
struct Search {
    best: Cfg,
    best_obj: f64,
    stages: Vec<Value>,
    alt_cancel: Cfg,
    alt_case: Cfg,
}

/// Experiment 1's search (stage A: alpha per cancel x case variants at depth
/// 2; B: depth; C: fine alpha; D: one factor flipped), on `sw`'s objective.
fn staged_search(sw: &mut Sweeper) -> Result<Search, String> {
    let mut stages = Vec::new();

    // Alpha grid: powers of sqrt(2) from 0.25 to 4, extended upwards while the
    // best value sits on the top edge.
    let grid_a: Vec<f32> = (-4..=4)
        .map(|k| round3(2f32.powf(k as f32 / 2.0)))
        .collect();
    let alpha_family = Sweeper::alpha_family;

    // Stage A: alpha for every cancel x case-variant combination, at NeMo's
    // recommended depth scaling (2).
    let mut combos = Vec::new();
    for cancel in [true, false] {
        for case in [true, false] {
            let name = format!(
                "A-alpha cancel={} case={}",
                if cancel { "on" } else { "off" },
                if case { "on" } else { "off" }
            );
            let start = Cfg {
                alpha: 1.0,
                depth: 2.0,
                cancel,
                case,
            };
            let (b, o, all) = alpha_family(sw, &name, start, &grid_a, true)?;
            stages.push(stage_json(&name, &all, &b));
            combos.push((b, o));
        }
    }
    let (mut best, mut best_obj) = combos
        .iter()
        .copied()
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .ok_or("no stage A result")?;

    // Stage B: depth scaling, around the best alpha.
    let mut b_cfgs = Vec::new();
    for depth in [0.0f32, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0] {
        for f in [
            std::f32::consts::FRAC_1_SQRT_2,
            1.0,
            std::f32::consts::SQRT_2,
        ] {
            b_cfgs.push(Cfg {
                alpha: round3(best.alpha * f),
                depth,
                ..best
            });
        }
    }
    let (b_best, b_obj, all_b) = sw.best_of("B-depth", &b_cfgs)?;
    if b_obj < best_obj {
        (best, best_obj) = (b_best, b_obj);
    }
    stages.push(stage_json("B-depth", &all_b, &best));

    // Stage C: fine alpha.
    let c_alphas: Vec<f32> = [0.8f32, 0.9, 1.0, 1.1, 1.2]
        .iter()
        .map(|f| round3(best.alpha * f))
        .collect();
    let (c_best, c_obj, all_c) = alpha_family(sw, "C-fine-alpha", best, &c_alphas, false)?;
    if c_obj < best_obj {
        (best, best_obj) = (c_best, c_obj);
    }
    stages.push(stage_json("C-fine-alpha", &all_c, &best));

    // Alternatives: one factor flipped at the tuned depth, alpha re-tuned.
    let alt_alphas: Vec<f32> = (-2..=2)
        .map(|k| round3(best.alpha * 2f32.powf(k as f32 / 2.0)))
        .collect();
    let flip_cancel = Cfg {
        cancel: !best.cancel,
        ..best
    };
    let (alt_cancel, _, all_ac) = alpha_family(sw, "D-alt-cancel", flip_cancel, &alt_alphas, true)?;
    stages.push(stage_json("D-alt-cancel", &all_ac, &alt_cancel));
    let flip_case = Cfg {
        case: !best.case,
        ..best
    };
    let (alt_case, _, all_acase) = alpha_family(sw, "D-alt-case", flip_case, &alt_alphas, true)?;
    stages.push(stage_json("D-alt-case", &all_acase, &alt_case));
    Ok(Search {
        best,
        best_obj,
        stages,
        alt_cancel,
        alt_case,
    })
}

#[allow(clippy::needless_range_loop)]
fn run() -> Result<(), String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    // Reference-only counting: no export, cache, audio or decoding.
    if argv.iter().any(|a| a == "--count-refs") {
        return learned_eval::count_refs_cli(argv);
    }
    let args = parse_args_from(argv)?;
    check_output_locations(&args)?;
    if args.exp2.is_some() {
        return learned_eval::run(&args);
    }
    let t_all = Instant::now();
    let (model, mut tr, identity) = open_models(&args)?;

    let t_data = Instant::now();
    let data = load_data(&args, &mut tr, &identity)?;
    let data_s = t_data.elapsed().as_secs_f64();
    for n in &data.notes {
        eprintln!("{n}");
    }
    let proj_mib: f64 = data
        .utts
        .iter()
        .map(|u| u.proj.len() as f64 * 4.0)
        .sum::<f64>()
        / 1048576.0;
    eprintln!(
        "{} utterances, {proj_mib:.0} MiB of projections, data ready in {data_s:.1} s",
        data.utts.len()
    );

    let t_cache = Instant::now();
    let (cache, skipped) = phrase_cache(&model.tokenizer, &data.groups, args.threads);
    eprintln!(
        "phrase cache: {} entries ({skipped} not encodable) in {:.1?}",
        cache.len(),
        t_cache.elapsed()
    );

    if args.calibrate {
        return calibrate(&args, &model, &cache, &data);
    }
    let out = args.out.clone().unwrap();
    let engine = Engine {
        decoder: &model.decoder,
        tokenizer: &model.tokenizer,
        cache: &cache,
        workers: args.workers,
        per_worker: args.threads / args.workers,
    };

    // Baseline: every utterance without bias.
    let t_base = Instant::now();
    let all: Vec<usize> = (0..data.utts.len()).collect();
    let decoded = engine.decode_set(&data, &all, 0, None)?;
    let base = Baseline {
        decoded: decoded.into_iter().map(Some).collect(),
    };
    let base_s = t_base.elapsed().as_secs_f64();
    eprintln!("baseline decode of {} utterances: {base_s:.1} s", all.len());
    let same_as_m1 = all
        .iter()
        .filter(|&&i| base.get(i).text == data.utts[i].m1_hyp)
        .count();

    // Pooled decoding must match the daemon path (16-thread decode_projected).
    let check: Vec<usize> = all.iter().copied().step_by(17).collect();
    let probe_cfg = Cfg {
        alpha: 1.0,
        depth: 2.0,
        cancel: true,
        case: true,
    };
    let pooled_biased = engine.decode_set(&data, &check, 2, Some(&probe_cfg))?;
    let mut path_mismatch = 0;
    for (&i, pb) in check.iter().zip(&pooled_biased) {
        let u = &data.utts[i];
        let t = tr
            .decode_projected(&u.proj, u.frames, None)
            .map_err(|e| e.to_string())?;
        path_mismatch += usize::from(t.text != base.get(i).text);
        let grp = &data.groups[u.group];
        let g = build_graph(&grp.lists[2], &cache, &probe_cfg, grp.keywords)?;
        let t = tr
            .decode_projected(&u.proj, u.frames, g.as_ref())
            .map_err(|e| e.to_string())?;
        path_mismatch += usize::from(t.text != pb.text);
    }
    eprintln!(
        "pooled vs decode_projected: {path_mismatch} differing texts in {} checks",
        2 * check.len()
    );

    if !data
        .sets
        .iter()
        .any(|s| s.role == Role::Tune && !s.utts.is_empty())
        || data.sets.iter().any(|s| s.utts.is_empty())
    {
        return Err("every set, and at least one tuning set, needs utterances".into());
    }
    let mut sw = Sweeper {
        engine: &engine,
        data: &data,
        base: &base,
        memo: HashMap::new(),
        rows: Vec::new(),
        runs: 0,
        decode_s: 0.0,
        dev_objective: false,
    };
    let t_sweep = Instant::now();
    let Search {
        best,
        best_obj,
        stages,
        alt_cancel,
        alt_case,
    } = staged_search(&mut sw)?;
    let sweep_s = t_sweep.elapsed().as_secs_f64();
    eprintln!(
        "sweep: {} runs, {sweep_s:.0} s; best {} ({best_obj:.4})",
        sw.runs,
        best.label()
    );

    // Per-size best alpha on the tune sets, among runs at the best's other settings.
    let mut per_size_alpha = Vec::new();
    for s in 0..data.sets.len() {
        if data.sets[s].role != Role::Tune {
            continue;
        }
        for size in 0..SIZES.len() {
            let mut cands: Vec<(f32, usize)> = Vec::new();
            for ((k, set, sz), m) in &sw.memo {
                if *set == s
                    && *sz == size
                    && k.1 == best.depth.to_bits()
                    && k.2 == best.cancel
                    && k.3 == best.case
                {
                    cands.push((f32::from_bits(k.0), m.counts.wer.errors()));
                }
            }
            cands.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.total_cmp(&b.0)));
            if let Some(&(a, e)) = cands.first() {
                per_size_alpha.push(json!({"set": data.sets[s].name, "size": SIZES[size], "best_alpha": a, "errors": e}));
            }
        }
    }

    // Final evaluation on every set: the chosen configuration and alternatives.
    let nemo = Cfg {
        alpha: 1.0,
        depth: 2.0,
        cancel: true,
        case: false,
    };
    let flip = |on: bool, what: &str| format!("{}{what}", if on { "" } else { "no-" });
    let finals: Vec<(String, Cfg)> = vec![
        ("best".into(), best),
        (flip(alt_cancel.cancel, "cancel"), alt_cancel),
        (flip(alt_case.case, "case-variants"), alt_case),
        ("nemo-default-ish".into(), nemo),
        (
            "best-alpha/2".into(),
            Cfg {
                alpha: round3(best.alpha / 2.0),
                ..best
            },
        ),
        (
            "best-alpha*2".into(),
            Cfg {
                alpha: round3(best.alpha * 2.0),
                ..best
            },
        ),
    ];
    let mut table = Vec::new();
    let mut best_hyps: HashMap<(usize, usize), Vec<Decoded>> = HashMap::new();
    for s in 0..data.sets.len() {
        for size in 0..SIZES.len() {
            let bm = baseline_metrics(&data, &base, &data.sets[s].utts, size);
            table.push(json!({"label": "baseline", "set": data.sets[s].name, "role": data.sets[s].role.name(),
                              "size": SIZES[size], "config": null, "metrics": bm.json()}));
        }
    }
    for (label, cfg) in &finals {
        for s in 0..data.sets.len() {
            for size in 0..SIZES.len() {
                let m = if *label == "best" {
                    let utts = &data.sets[s].utts;
                    let decoded = engine.decode_set(&data, utts, size, Some(cfg))?;
                    let m = set_metrics(&data, &base, utts, &decoded, size);
                    best_hyps.insert((s, size), decoded);
                    m
                } else {
                    sw.metrics(&format!("final-{label}"), cfg, s, size)?
                };
                table.push(json!({"label": label, "set": data.sets[s].name, "role": data.sets[s].role.name(),
                                  "size": SIZES[size], "config": cfg.json(), "metrics": m.json()}));
            }
        }
    }

    // Oracle margin on the held-out sets.
    let t_oracle = Instant::now();
    let (oracle, oracle_lines) = oracle_experiment(&engine, &data, &base, best, &best_hyps)?;
    let oracle_s = t_oracle.elapsed().as_secs_f64();
    eprintln!("oracle: {oracle_s:.0} s");

    let daemon = daemon_timing(&tr, &data, &cache, &best, args.threads)?;

    // Outputs.
    let total_s = t_all.elapsed().as_secs_f64();
    let sets_json: Vec<Value> = data
        .sets
        .iter()
        .map(|s| {
            let groups: BTreeSet<usize> = s.utts.iter().map(|&i| data.utts[i].group).collect();
            json!({"name": s.name, "role": s.role.name(), "utterances": s.utts.len(), "groups": groups.len(),
                   "b_words": s.utts.iter().map(|&i| data.utts[i].ref_words.iter().filter(|w| data.utts[i].biasing.contains(*w)).count()).sum::<usize>(),
                   "words": s.utts.iter().map(|&i| data.utts[i].ref_words.len()).sum::<usize>()})
        })
        .collect();
    let results = json!({
        "precision": "i8x2",
        "threads": args.threads,
        "workers": args.workers,
        "seed": args.seed,
        "notes": data.notes,
        "sets": sets_json,
        "lists": data.lists_info,
        "phrase_cache": {"entries": cache.len(), "not_encodable": skipped},
        "baseline_same_text_as_m1": same_as_m1,
        "baseline_utterances": data.utts.len(),
        "pooled_vs_decode_projected_mismatches": path_mismatch,
        "pooled_vs_decode_projected_checks": 2 * check.len(),
        "runtime_s": {"total": total_s, "data_and_encode": data_s, "baseline": base_s, "sweep": sweep_s, "sweep_runs": sw.runs, "oracle": oracle_s},
        "stages": stages,
        "best": best.json(),
        "best_objective": best_obj,
        "per_size_best_alpha": per_size_alpha,
        "final": table,
        "sweep_rows": sw.rows,
        "oracle": oracle,
        "daemon_decode": daemon,
    });
    let write = |name: &str, text: String| outpath::write_output(&out.join(name), text.as_bytes());
    write(
        "results.json",
        serde_json::to_string_pretty(&results).unwrap(),
    )?;
    let mut lines = String::new();
    for l in &oracle_lines {
        lines.push_str(&l.to_string());
        lines.push('\n');
    }
    write("oracle_cases.jsonl", lines)?;
    let mut hyps = String::new();
    for s in 0..data.sets.len() {
        for &i in &data.sets[s].utts {
            let u = &data.utts[i];
            let mut rec =
                json!({"set": data.sets[s].name, "id": u.id, "baseline": base.get(i).text});
            let pos = data.sets[s].utts.iter().position(|&j| j == i).unwrap();
            for size in 0..SIZES.len() {
                if let Some(d) = best_hyps.get(&(s, size)) {
                    rec[format!("best_{}", SIZES[size])] = Value::String(d[pos].text.clone());
                }
            }
            hyps.push_str(&rec.to_string());
            hyps.push('\n');
        }
    }
    write("hyps.jsonl", hyps)?;
    write("summary.md", summary(&results))?;
    eprintln!("done in {total_s:.0} s; results in {}", out.display());
    Ok(())
}

/// The oracle-margin experiment on the held-out sets: for each baseline miss
/// of a target word, decode its utterance with a dictionary of only that word
/// at every alpha of a log-spaced grid (other settings from `best`). Returns
/// per-set summaries and per-case records.
fn oracle_experiment(
    engine: &Engine,
    data: &Data,
    base: &Baseline,
    best: Cfg,
    best_hyps: &HashMap<(usize, usize), Vec<Decoded>>,
) -> Result<(Vec<Value>, Vec<Value>), String> {
    let cache = engine.cache;
    let grid: Vec<f32> = (-4..=8).map(|k| 2f32.powf(k as f32 / 2.0)).collect();
    let mut oracle = Vec::new();
    let mut oracle_lines = Vec::new();
    for s in 0..data.sets.len() {
        if data.sets[s].role != Role::Test {
            continue;
        }
        let cases = oracle_cases(data, base, s);
        let jobs: Vec<(usize, usize)> = (0..cases.len())
            .flat_map(|c| (0..grid.len()).map(move |a| (c, a)))
            .collect();
        let results: Vec<Result<OracleResult, String>> = engine.run(
            &jobs,
            &|&(c, _)| data.utts[cases[c].utt].frames,
            &|pool, &(c, a)| {
                let case = &cases[c];
                let u = &data.utts[case.utt];
                let cfg = Cfg {
                    alpha: grid[a],
                    ..best
                };
                let entries = [case.entry.clone()];
                let graph = match cache.get(&case.entry) {
                    Some(_) => build_graph(&entries, cache, &cfg, false)?,
                    None => {
                        let p = lf_asr::bias::phrases(engine.tokenizer, &entries, cfg.case)
                            .map_err(|e| e.to_string())?;
                        Some(BiasGraph::new(&p, VOCAB, cfg.bias())?)
                    }
                };
                let d = engine.decode(pool, u, graph.as_ref());
                Ok(OracleResult {
                    matched: bias_metrics::matched(&u.ref_words, &d.words, &case.word),
                    other_errors: bias_metrics::errors_except(&u.ref_words, &d.words, &case.word),
                    hyp_edits: wer::edits(&base.get(case.utt).words, &d.words),
                })
            },
        );
        let results: Vec<OracleResult> = results.into_iter().collect::<Result<_, _>>()?;
        let pos_in_set: HashMap<usize, usize> = data.sets[s]
            .utts
            .iter()
            .enumerate()
            .map(|(p, &i)| (i, p))
            .collect();
        let g = grid.len();
        let pct = |k: usize, n: usize| (n > 0).then(|| k as f64 / n as f64);

        // Occurrence level: each missed reference occurrence of a word.
        let mut occ_first: Vec<Option<usize>> = Vec::new();
        let mut occ_recovered_at = vec![0usize; g];
        let mut occ_tuned = vec![0usize; SIZES.len()];
        // Probe level (one probe per utterance and missed word, reported separately).
        let mut probe_first: Vec<Option<usize>> = Vec::new();
        let mut probe_recovered_at = vec![0usize; g];
        let mut probe_tuned = vec![0usize; SIZES.len()];
        let mut collateral = Vec::new();
        let mut hyp_edits_at_first = Vec::new();
        for (c, case) in cases.iter().enumerate() {
            let rs = &results[c * g..(c + 1) * g];
            let matched: Vec<usize> = rs.iter().map(|r| r.matched).collect();
            let rec =
                |m: usize| bias_metrics::recovered_occurrences(case.base_matched, case.missed, m);
            occ_first.extend(bias_metrics::occurrence_first_recovery(
                case.base_matched,
                case.missed,
                &matched,
            ));
            for (a, &m) in matched.iter().enumerate() {
                occ_recovered_at[a] += rec(m);
                probe_recovered_at[a] += usize::from(rec(m) > 0);
            }
            let first = matched.iter().position(|&m| rec(m) > 0);
            probe_first.push(first);
            if let Some(a) = first {
                collateral.push(rs[a].other_errors as isize - case.base_other_errors as isize);
                hyp_edits_at_first.push(rs[a].hyp_edits);
            }
            let u = &data.utts[case.utt];
            for size in 0..SIZES.len() {
                if let Some(d) = best_hyps.get(&(s, size)) {
                    let words = &d[pos_in_set[&case.utt]].words;
                    let r = rec(bias_metrics::matched(&u.ref_words, words, &case.word));
                    occ_tuned[size] += r;
                    probe_tuned[size] += usize::from(r > 0);
                }
            }
            oracle_lines.push(json!({
                "set": data.sets[s].name, "id": u.id, "word": case.word, "entry": case.entry,
                "said": case.said, "missed_occurrences": case.missed,
                "first_alpha_any": first.map(|a| grid[a]),
                "collateral_net_at_first_alpha": first.map(|a| rs[a].other_errors as isize - case.base_other_errors as isize),
                "hyp_edits_at_first_alpha": first.map(|a| rs[a].hyp_edits),
                "recovered_occurrences_by_alpha": matched.iter().map(|&m| rec(m)).collect::<Vec<_>>(),
            }));
        }
        let summarize = |first: &[Option<usize>], recovered_at: &[usize], tuned: &[usize]| {
            let n = first.len();
            let mut mins: Vec<f64> = first.iter().flatten().map(|&a| grid[a] as f64).collect();
            mins.sort_by(f64::total_cmp);
            let le_best = mins
                .iter()
                .filter(|&&a| a <= best.alpha as f64 + 1e-6)
                .count();
            json!({
                "missed": n,
                "recoverable_on_grid": mins.len(),
                "never_recovered": n - mins.len(),
                "min_alpha_quantiles": {"p10": quantile(&mins, 0.1), "p25": quantile(&mins, 0.25), "p50": quantile(&mins, 0.5), "p75": quantile(&mins, 0.75), "p90": quantile(&mins, 0.9)},
                "min_alpha_le_tuned_alpha": le_best,
                "fraction_min_alpha_le_tuned_alpha": pct(le_best, n),
                "tuned_config_recovered_with_real_lists": SIZES.iter().zip(tuned).map(|(s, r)| json!({"size": s, "recovered": r, "fraction": pct(*r, n)})).collect::<Vec<_>>(),
                "by_alpha": grid.iter().enumerate().map(|(a, &al)| {
                    let cum = first.iter().filter(|m| m.is_some_and(|m| m <= a)).count();
                    json!({"alpha": al, "recovered_here": recovered_at[a], "fraction_recovered_here": pct(recovered_at[a], n),
                           "min_alpha_le": cum, "fraction_min_alpha_le": pct(cum, n)})
                }).collect::<Vec<_>>(),
            })
        };
        let mut coll_sorted = collateral.clone();
        coll_sorted.sort();
        let coll_f: Vec<f64> = coll_sorted.iter().map(|&c| c as f64).collect();
        let mean = |v: &[f64]| (!v.is_empty()).then(|| v.iter().sum::<f64>() / v.len() as f64);
        let edits_f: Vec<f64> = hyp_edits_at_first.iter().map(|&e| e as f64).collect();
        let mut said_pairs: BTreeMap<(String, String), usize> = BTreeMap::new();
        for c in &cases {
            if let Some(sd) = &c.said {
                *said_pairs.entry((c.word.clone(), sd.clone())).or_default() += 1;
            }
        }
        let mut top_pairs: Vec<((String, String), usize)> = said_pairs.into_iter().collect();
        top_pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let top_pairs: Vec<Value> = top_pairs
            .into_iter()
            .take(20)
            .map(|((w, s), n)| json!({"should": w, "said": s, "count": n}))
            .collect();
        oracle.push(json!({
            "set": data.sets[s].name,
            "tuned_alpha": best.alpha,
            "grid": grid,
            "occurrences": summarize(&occ_first, &occ_recovered_at, &occ_tuned),
            "probes": {
                "description": "one probe per (utterance, missed word); recovered when at least one missed occurrence is recovered",
                "summary": summarize(&probe_first, &probe_recovered_at, &probe_tuned),
                "deleted_not_substituted": cases.iter().filter(|c| c.said.is_none()).count(),
                "collateral_at_first_alpha": {
                    "description": "change in errors on other words (net, vs baseline) at each probe's first recovering alpha",
                    "mean_net_other_errors": mean(&coll_f),
                    "cases_with_more_other_errors": collateral.iter().filter(|&&c| c > 0).count(),
                    "cases_with_zero_net": collateral.iter().filter(|&&c| c == 0).count(),
                    "cases_with_fewer_other_errors": collateral.iter().filter(|&&c| c < 0).count(),
                    "p50_net": quantile(&coll_f, 0.5),
                    "p90_net": quantile(&coll_f, 0.9),
                    "max_net": coll_sorted.last().copied(),
                    "mean_hyp_word_edits": mean(&edits_f),
                },
            },
            "top_said_instead": top_pairs,
        }));
    }
    Ok((oracle, oracle_lines))
}

/// Daemon-path decode cost (`threads`-thread `decode_projected`) on a sample.
/// Each utterance gets a freshly built graph: "cold" is its first decode with
/// it (any per-graph caches empty), "warm" the best of three repeats with the
/// same graph, as when a session-wide dictionary is reused.
fn daemon_timing(
    tr: &Transcriber,
    data: &Data,
    cache: &PhraseCache,
    best: &Cfg,
    threads: usize,
) -> Result<Vec<Value>, String> {
    let sample: Vec<usize> = (0..data.utts.len()).step_by(29).collect();
    let mut daemon = Vec::new();
    for (size, &list_size) in SIZES.iter().enumerate() {
        let (mut base_ns, mut cold_ns, mut warm_ns, mut build_ns) = (0u128, 0u128, 0u128, 0u128);
        for &i in &sample {
            let u = &data.utts[i];
            let t = Instant::now();
            let grp = &data.groups[u.group];
            let graph = build_graph(&grp.lists[size], cache, best, grp.keywords)?;
            build_ns += t.elapsed().as_nanos();
            let timed = |g: Option<&BiasGraph>| -> Result<u128, String> {
                let t = Instant::now();
                tr.decode_projected(&u.proj, u.frames, g)
                    .map_err(|e| e.to_string())?;
                Ok(t.elapsed().as_nanos())
            };
            // Wake the pool, then the cold decode; base and warm: best of 3.
            timed(None)?;
            cold_ns += timed(graph.as_ref())?;
            let (mut b, mut w) = (u128::MAX, u128::MAX);
            for _ in 0..3 {
                b = b.min(timed(None)?);
                w = w.min(timed(graph.as_ref())?);
            }
            base_ns += b;
            warm_ns += w;
        }
        let n = sample.len() as f64;
        let ms = |ns: u128| ns as f64 / 1e6 / n;
        daemon.push(json!({
            "size": list_size, "utterances": sample.len(), "threads": threads,
            "base_decode_ms_per_utt": ms(base_ns),
            "biased_cold_decode_ms_per_utt": ms(cold_ns),
            "biased_warm_decode_ms_per_utt": ms(warm_ns),
            "cold_overhead": cold_ns as f64 / base_ns as f64 - 1.0,
            "warm_overhead": warm_ns as f64 / base_ns as f64 - 1.0,
            "graph_build_ms": ms(build_ns),
        }));
    }
    Ok(daemon)
}

/// `v` with `decimals` places, or "n/a" when it is null (an undefined rate).
fn fmt_num(v: &Value, decimals: usize) -> String {
    match v.as_f64() {
        Some(x) => format!("{x:.decimals$}"),
        None => "n/a".into(),
    }
}

fn summary(r: &Value) -> String {
    let mut s = String::new();
    s.push_str("# Word boosting evaluation (lf-bias-eval)\n\n");
    s.push_str(&format!(
        "Precision {}, {} threads in {} workers. Best configuration (tuned on the tune sets): `{}`.\n\n",
        r["precision"], r["threads"], r["workers"], r["best"]
    ));
    s.push_str(&format!("Runtime: {}\n\n", r["runtime_s"]));
    for n in r["notes"].as_array().into_iter().flatten() {
        s.push_str(&format!("- {}\n", n.as_str().unwrap_or("")));
    }
    s.push_str(&format!(
        "- baseline identical to M1 text: {}/{}; pooled vs decode_projected mismatches: {}/{}\n\n",
        r["baseline_same_text_as_m1"],
        r["baseline_utterances"],
        r["pooled_vs_decode_projected_mismatches"],
        r["pooled_vs_decode_projected_checks"]
    ));
    s.push_str("## Results\n\nRates in %; n/a where the denominator is zero.\n\n| label | set | role | size | WER | B-WER | U-WER | recall | FA | fixed | broken | decode overhead |\n");
    s.push_str(
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n",
    );
    for row in r["final"].as_array().into_iter().flatten() {
        let m = &row["metrics"];
        s.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {:+.1}% |\n",
            row["label"].as_str().unwrap_or(""),
            row["set"].as_str().unwrap_or(""),
            row["role"].as_str().unwrap_or(""),
            row["size"],
            fmt_num(&m["wer"]["percent"], 2),
            fmt_num(&m["b_wer"]["percent"], 2),
            fmt_num(&m["u_wer"]["percent"], 2),
            fmt_num(&m["recall"], 3),
            m["false_alarms"],
            m["fixed"],
            m["broken"],
            100.0 * m["decode_overhead"].as_f64().unwrap_or(0.0),
        ));
    }
    s.push_str("\n## Sweep stages (tune sets, mean relative WER over sets and sizes)\n\n");
    for st in r["stages"].as_array().into_iter().flatten() {
        s.push_str(&format!("### {}\n\n", st["stage"].as_str().unwrap_or("")));
        for o in st["objective"].as_array().into_iter().flatten() {
            s.push_str(&format!(
                "- {} -> {}\n",
                o["config"],
                fmt_num(&o["relative_wer"], 4)
            ));
        }
        s.push('\n');
    }
    s.push_str(&format!(
        "Per-size best alpha: {}\n\n",
        r["per_size_best_alpha"]
    ));
    s.push_str("## Oracle margin (held-out)\n\nSingle-word dictionary per missed word, alpha on the grid. Occurrence counts are primary; probes (one per utterance and missed word) are reported separately.\n\n");
    for o in r["oracle"].as_array().into_iter().flatten() {
        let occ = &o["occurrences"];
        let probes = &o["probes"]["summary"];
        s.push_str(&format!(
            "### {}\n\nOccurrences: missed {}, recoverable {}, never {}, smallest-alpha quantiles {}, <= tuned alpha {}: {} ({}); tuned config with real lists recovered {}\n\n",
            o["set"].as_str().unwrap_or(""),
            occ["missed"], occ["recoverable_on_grid"], occ["never_recovered"],
            occ["min_alpha_quantiles"], o["tuned_alpha"], occ["min_alpha_le_tuned_alpha"],
            fmt_num(&occ["fraction_min_alpha_le_tuned_alpha"], 3),
            occ["tuned_config_recovered_with_real_lists"],
        ));
        s.push_str(&format!(
            "Probes: {} (recoverable {}, never {}), smallest-alpha quantiles {}; collateral at each probe's first recovering alpha {}\n\n",
            probes["missed"], probes["recoverable_on_grid"], probes["never_recovered"],
            probes["min_alpha_quantiles"], o["probes"]["collateral_at_first_alpha"],
        ));
        s.push_str("| alpha | occurrences recovered at alpha | smallest alpha <= | probes recovered at alpha |\n| ---: | ---: | ---: | ---: |\n");
        let pb = probes["by_alpha"].as_array().cloned().unwrap_or_default();
        for (k, b) in occ["by_alpha"].as_array().into_iter().flatten().enumerate() {
            s.push_str(&format!(
                "| {} | {} | {} | {} |\n",
                fmt_num(&b["alpha"], 3),
                fmt_num(&b["fraction_recovered_here"], 3),
                fmt_num(&b["fraction_min_alpha_le"], 3),
                pb.get(k)
                    .map(|p| fmt_num(&p["fraction_recovered_here"], 3))
                    .unwrap_or_default(),
            ));
        }
        s.push('\n');
    }
    s.push_str(&format!(
        "## Daemon-path decode (16 threads)\n\n{}\n",
        r["daemon_decode"]
    ));
    s
}

fn calibrate(args: &Args, model: &Model, cache: &PhraseCache, data: &Data) -> Result<(), String> {
    let tune: Vec<usize> = data
        .sets
        .iter()
        .filter(|s| s.role == Role::Tune)
        .flat_map(|s| s.utts.iter().copied())
        .collect();
    let sample: Vec<usize> = tune.iter().copied().step_by(5).collect();
    let audio_s: f64 = sample
        .iter()
        .map(|&i| data.utts[i].frames as f64 * 0.08)
        .sum();
    let cfg = Cfg {
        alpha: 1.0,
        depth: 2.0,
        cancel: true,
        case: true,
    };
    println!("{} utterances, {audio_s:.0} s of audio", sample.len());
    println!(
        "| workers x threads | baseline s | biased (1000) s | utt/s baseline | decoder ms/utt baseline | biased |"
    );
    for workers in [
        args.threads,
        args.threads / 2,
        args.threads / 4,
        args.threads / 8,
        1,
    ] {
        if workers == 0 || !args.threads.is_multiple_of(workers) {
            continue;
        }
        let engine = Engine {
            decoder: &model.decoder,
            tokenizer: &model.tokenizer,
            cache,
            workers,
            per_worker: args.threads / workers,
        };
        let t = Instant::now();
        let b = engine.decode_set(data, &sample, 2, None)?;
        let bs = t.elapsed().as_secs_f64();
        let t = Instant::now();
        let d = engine.decode_set(data, &sample, 2, Some(&cfg))?;
        let ds = t.elapsed().as_secs_f64();
        let n = sample.len() as f64;
        println!(
            "| {workers} x {} | {bs:.2} | {ds:.2} | {:.0} | {:.2} | {:.2} |",
            args.threads / workers,
            n / bs,
            b.iter().map(|x| x.ns).sum::<u64>() as f64 / 1e6 / n,
            d.iter().map(|x| x.ns).sum::<u64>() as f64 / 1e6 / n,
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_arguments() {
        let a = parse_args_from(argv(
            "--export /e --cache /c --out /o --libri tune:/a.json:/m.jsonl:/x/test-clean.biasing_ --workers 4",
        ))
        .unwrap();
        assert_eq!(a.libri.len(), 1);
        assert_eq!(a.libri[0].role, Role::Tune);
        assert_eq!(a.libri[0].tsv_prefix, "/x/test-clean.biasing_");
        assert_eq!((a.threads, a.workers), (16, 4));
        assert!(parse_args_from(argv("--export /e --cache /c --out /o")).is_err());
        assert!(parse_args_from(argv("--export /e --cache /c --out /o --session /a:/b")).is_err());
        assert!(
            parse_args_from(argv(
                "--export /e --cache /c --out /o --libri tune:/a:/b:/c --workers 3"
            ))
            .is_err()
        );
    }

    #[test]
    fn tuning_data_is_required() {
        // Held-out LibriSpeech alone has nothing to tune on.
        assert!(
            parse_args_from(argv(
                "--export /e --cache /c --out /o --libri test:/a:/b:/c"
            ))
            .is_err()
        );
        assert!(
            parse_args_from(argv(
                "--export /e --cache /c --out /o --libri test:/a:/b:/c --libri tune:/d:/e:/f"
            ))
            .is_ok()
        );
        // A session set always has a tuning half.
        assert!(
            parse_args_from(argv(
                "--export /e --cache /c --out /o --session /a:/b --rare-words /r --lists-out /l"
            ))
            .is_ok()
        );
    }

    #[test]
    fn objective_rejects_empty_undefined_and_nonfinite() {
        assert_eq!(relative_wer_objective(&[(5, 10), (30, 20)]), Ok(1.0));
        assert!(relative_wer_objective(&[]).is_err());
        assert!(relative_wer_objective(&[(1, 0)]).is_err());
        assert!(relative_wer_objective(&[(0, 0), (3, 4)]).is_err());
    }

    fn identity() -> CacheIdentity {
        CacheIdentity {
            export_sha256: "e1".into(),
            precision: "i8x2".into(),
            joint_padded: 4,
        }
    }

    #[test]
    fn cache_header_must_match_every_identity_field() {
        let ids = ["u1", "u2"];
        let audio = vec!["a1".to_owned(), "a2".to_owned()];
        let expected = cache_identity_json(&identity(), &ids, &audio);
        let mut header = expected.clone();
        header["frames"] = json!([3, 5]);
        assert_eq!(cached_frames(&header, &expected), Some(vec![3, 5]));
        // Changed audio, export, precision, format or ids invalidate the cache.
        let changed_audio = cache_identity_json(&identity(), &ids, &["a1".into(), "zz".into()]);
        assert_eq!(cached_frames(&header, &changed_audio), None);
        let other_export = CacheIdentity {
            export_sha256: "e2".into(),
            ..identity()
        };
        assert_eq!(
            cached_frames(&header, &cache_identity_json(&other_export, &ids, &audio)),
            None
        );
        let other_precision = CacheIdentity {
            precision: "f32".into(),
            ..identity()
        };
        assert_eq!(
            cached_frames(
                &header,
                &cache_identity_json(&other_precision, &ids, &audio)
            ),
            None
        );
        let mut old_format = header.clone();
        old_format["format"] = json!("lf-bias-eval projected encoder output v1");
        assert_eq!(cached_frames(&old_format, &expected), None);
        let reordered = cache_identity_json(&identity(), &["u2", "u1"], &audio);
        assert_eq!(cached_frames(&header, &reordered), None);
        // A header without audio hashes (the v1 layout) is never accepted.
        let mut no_audio = header.clone();
        no_audio.as_object_mut().unwrap().remove("audio_sha256");
        assert_eq!(cached_frames(&no_audio, &expected), None);
        // Frame counts must be present, numeric and one per utterance.
        let mut short = header.clone();
        short["frames"] = json!([3]);
        assert_eq!(cached_frames(&short, &expected), None);
        let mut bad = header;
        bad["frames"] = json!([3, "x"]);
        assert_eq!(cached_frames(&bad, &expected), None);
    }

    fn row(id: &str, reference: &str, rare: &[&str]) -> bias_lists::LibriRow {
        bias_lists::LibriRow {
            id: id.into(),
            reference: reference.into(),
            rare: rare.iter().map(|s| s.to_string()).collect(),
            list: rare.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn rows(per_size: [(&str, &[&str]); 3]) -> Vec<HashMap<String, bias_lists::LibriRow>> {
        per_size
            .iter()
            .map(|(r, rare)| [("u1".to_owned(), row("u1", r, rare))].into())
            .collect()
    }

    #[test]
    fn libri_rows_must_agree_with_the_harness() {
        let harness = normalize("The zorbin sang.");
        let ok = rows([
            ("the zorbin sang", &["zorbin"]),
            ("the zorbin sang", &["zorbin"]),
            ("THE ZORBIN SANG", &["ZORBIN"]),
        ]);
        assert!(check_libri_rows("u1", &harness, &ok).is_ok());
        // A different reference at any size is rejected.
        let other_ref = rows([
            ("the zorbin sang", &["zorbin"]),
            ("the quaxel sang", &["zorbin"]),
            ("the zorbin sang", &["zorbin"]),
        ]);
        assert!(check_libri_rows("u1", &harness, &other_ref).is_err());
        // A rare-word set that changes with the list size is rejected.
        let other_rare = rows([
            ("the zorbin sang", &["zorbin"]),
            ("the zorbin sang", &["zorbin"]),
            ("the zorbin sang", &["quaxel"]),
        ]);
        assert!(check_libri_rows("u1", &harness, &other_rare).is_err());
        // A missing row is rejected.
        assert!(check_libri_rows("u2", &harness, &ok).is_err());
    }

    #[test]
    fn every_output_location_must_be_outside_git() {
        let base = std::env::temp_dir().join(format!("lf-bias-eval-test-{}", std::process::id()));
        let repo = base.join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let outside = base.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        let s = |p: &Path| p.display().to_string();
        let args = |out: &Path, cache: &Path, lists: &Path| {
            parse_args_from(argv(&format!(
                "--export /e --out {} --cache {} --session /a:/b --rare-words /r --lists-out {}",
                s(out),
                s(cache),
                s(lists)
            )))
            .unwrap()
        };
        let good = args(
            &outside.join("out"),
            &outside.join("cache"),
            &outside.join("lists.json"),
        );
        assert!(check_output_locations(&good).is_ok());
        for bad in [
            args(
                &repo.join("out"),
                &outside.join("cache"),
                &outside.join("l.json"),
            ),
            args(
                &outside.join("out"),
                &repo.join("cache"),
                &outside.join("l.json"),
            ),
            args(
                &outside.join("out"),
                &outside.join("cache"),
                &repo.join("l.json"),
            ),
        ] {
            assert!(check_output_locations(&bad).is_err());
        }
        // Through a symbolic link into the repository.
        std::os::unix::fs::symlink(&repo, outside.join("link")).unwrap();
        let via_link = args(
            &outside.join("link/out"),
            &outside.join("cache"),
            &outside.join("l.json"),
        );
        assert!(check_output_locations(&via_link).is_err());
        assert!(!repo.join("out").exists() && !repo.join("cache").exists());
        std::fs::remove_dir_all(&base).unwrap();
    }
}
