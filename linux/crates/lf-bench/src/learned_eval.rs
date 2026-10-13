//! Experiment 2 (learned biasing) in `lf-bias-eval`, selected by `--sets`.
//!
//! One decoder for every row: `PackedDecoder::decode` on 1-thread pools (one
//! per worker, `--threads` workers), and for learned models its
//! `decode_scored` hook. Rows:
//! - baseline (no bias);
//! - L0-historical: experiment 1's chosen fixed bonus (`--l0`), re-decoded;
//!   with `--l0-parity` also through `decode_scored` with the graph's own
//!   bonuses, compared token for token and against experiment 1's published
//!   numbers (`--exp1-results`);
//! - L0-retuned (`--l0-retune`): experiment 1's staged search, with the same
//!   budget, on the dev objective;
//! - each learned model (`--learned`) at each λ (`--lambdas`).
//!
//! Sets (`--sets dev|heldout|both` picks the roles):
//! - experiment 1's `--libri test:...` (LibriSpeech test-other, held out) and
//!   `--session` (Earnings-22: tuning calls are dev, the rest held out), with
//!   experiment 1's lists and encoder cache;
//! - `--libri-dev MANIFEST`: a fixed 600-utterance subset of LibriSpeech
//!   dev-other with simulated Le et al. lists at size 500 (dev);
//! - `--set ROLE:NAME:MANIFEST[:OPTIONS]`: any manifest with per-session
//!   lists (`--spgi-dev` and `--gigaspeech` are shorthands).
//!
//! The dev objective is the equal-weight mean, over the dev domains present
//! (each one of [`DEV_DOMAINS`], frozen here), of the domain's mean over its
//! list sizes of boosted / baseline word errors. Minimized.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use lf_asr::bias::{BiasConfig, BiasGraph, GraphBonusScorer};
use lf_asr::config::VOCAB;
use lf_cpu::ThreadPool;
use serde_json::{Value, json};

use super::{
    Args, Baseline, Cfg, Data, Decoded, Engine, Group, ItemsFrom, ListCondition, PhraseCache,
    RareRule, Role, SIZES, SessionSource, SessionSplit, Set, SetMetrics, Sweeper, Utt,
    baseline_metrics, bias_metrics, build_graph, check_session_sums, earnings_source, enc_cache,
    exp2_data, exp2_terms, learned, load_libri, load_sessions, manifest_items, manifest_lines,
    new_data, norm_set, outpath, phrase_cache, read_rare_words, read_text, session_counts,
    set_metrics, staged_search,
};
use learned::{LearnedModel, LearnedScorer, PreparedDict, ScorerStats, TrieFeatures, Variant};

/// The dev domains of the objective, frozen before any training result
/// exists (DESIGN.md): a dev set must be one of these.
pub const DEV_DOMAINS: [&str; 6] = [
    "spgispeech_dev",
    "earnings22_tune",
    "librispeech_dev_other_600",
    "slidespeech_dev",
    "icsi_dev",
    "acl6060_dev",
];

/// The frozen seed (lists, subsets, splits).
pub const DEFAULT_SEED: u64 = 20_261_011;

/// λ grid of DESIGN.md.
pub const DEFAULT_LAMBDAS: [f32; 5] = [0.5, 0.71, 1.0, 1.41, 2.0];

/// Experiment 1's chosen configuration (results/full: alpha 1.414, depth
/// scaling 3, cancel off, case variants on).
pub const L0_HISTORICAL: Cfg = Cfg {
    alpha: 1.414,
    depth: 3.0,
    cancel: false,
    case: true,
};

/// Learned variants: one graph per dictionary with case variants and no
/// cancel (the bonus values are unused; only candidates and states matter).
pub const LEARNED_GRAPH: BiasConfig = BiasConfig {
    alpha: 1.0,
    context_score: 1.0,
    depth_scaling: 0.0,
    cancel_unfinished: false,
};

/// Experiment 1's published sets (results/full), each at sizes 100/500/1000:
/// the frozen parity coverage whenever they are evaluated.
pub const EXP1_SETS: [&str; 3] = ["librispeech_other", "earnings22_tune", "earnings22_test"];
/// Experiment 1's held-out sets with oracle cases (results/full/oracle_cases.jsonl).
pub const EXP1_ORACLE_SETS: [&str; 2] = ["librispeech_other", "earnings22_test"];

/// The environment variable naming the experiment root W (outside any
/// repository); default locations are derived from it.
pub const ROOT_ENV: &str = "LF_EXP2_ROOT";

/// `$LF_EXP2_ROOT/rel`, or an error naming the flag that replaces it.
fn root_path(rel: &str, flag: &str) -> Result<PathBuf, String> {
    match std::env::var_os(ROOT_ENV) {
        Some(r) if !r.is_empty() => Ok(PathBuf::from(r).join(rel)),
        _ => Err(format!(
            "set {ROOT_ENV} (the experiment root) or pass {flag}"
        )),
    }
}

/// The frozen identity of the dev-other domain (re-review 2, finding 2): the
/// manifest's file name and SHA-256, and the SHA-256 of the 600 selected
/// utterance ids (sorted, each followed by a newline).
pub const DEV_OTHER_MANIFEST_NAME: &str = "librispeech_dev_other.jsonl";
pub const DEV_OTHER_MANIFEST_SHA256: &str =
    "d66037522094c8c3f30e5c8f3c0b1fbc8ae66a848693a9557992ca867396a740";
pub const DEV_OTHER_IDS_SHA256: &str =
    "58040fb1a0076429a61145f676729e6bbdc685978a40a22f3f73700abbd4be95";

/// SHA-256 of sorted utterance ids, each followed by `\n`.
pub fn ids_sha256(ids: &[String]) -> String {
    let mut v: Vec<&String> = ids.iter().collect();
    v.sort();
    let text: String = v.iter().map(|s| format!("{s}\n")).collect();
    lf_model::manifest::sha256_hex(text.as_bytes())
}

/// Refuses any dev-other manifest but the frozen one (by file name and
/// SHA-256), before anything is encoded.
pub fn check_dev_other_manifest(path: &Path) -> Result<String, String> {
    if path.file_name().and_then(|n| n.to_str()) != Some(DEV_OTHER_MANIFEST_NAME) {
        return Err(format!(
            "--libri-dev {}: expected the frozen {DEV_OTHER_MANIFEST_NAME}",
            path.display()
        ));
    }
    let sha =
        lf_model::manifest::sha256_file(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if sha != DEV_OTHER_MANIFEST_SHA256 {
        return Err(format!(
            "--libri-dev {}: SHA-256 {sha}, frozen {DEV_OTHER_MANIFEST_SHA256}",
            path.display()
        ));
    }
    Ok(sha)
}

const DEV_OTHER_NAME: &str = "librispeech_dev_other_600";
const DEV_OTHER_SIZE: usize = 600;
/// Index into `SIZES` of the dev-other lists (500).
const DEV_OTHER_LIST: usize = 1;

pub const USAGE: &str = "  --sets dev|heldout|both     roles to evaluate (selects experiment 2)
  --learned SPEC[,SPEC...]    model files (PATH, PATH@LAMBDA, PATH@meta) or random:VARIANT[:SEED] (smoke tests)
  --lambdas 0.5,0.71,1,1.41,2 λ grid for models given without @
  --l0 ALPHA,DEPTH,CANCEL,CASE  L0-historical (default 1.414,3,off,on)
  --l0-retune                 re-run experiment 1's staged search on the dev objective
  --l0-parity                 re-decode L0-historical through decode_scored and compare
  --no-l0                     skip the L0-historical row (checkpoint dev checks)
  --allow-partial-dev         allow dev runs without every frozen dev domain (results marked partial)
  --sizes 100[,500,1000]      evaluate only these list sizes (parity smoke checks)
  --exp1-results FILE         experiment 1's results.json (parity of baseline and L0-historical)
  --exp1-oracle FILE          experiment 1's oracle_cases.jsonl (fixed-denominator oracle recovery)
  --libri-dev MANIFEST        LibriSpeech dev-other: 600-utterance subset, simulated Le lists at 500
  --set ROLE:NAME:MANIFEST[:OPTS]  ROLE dev|heldout; OPTS comma-separated:
                              session=field:F | session=before:SEP (default field:session),
                              lists=rare|keywords|rare+keywords (default rare),
                              keep=spgi-dev | keep=spgi-train, cache=DIR (default NAME),
                              df=PATH[+PATH...] (manifests of every split of the dataset for the
                              session document frequency; default MANIFEST)
  --spgi-dev MANIFEST         = --set dev:spgispeech_dev:MANIFEST:session=before:/,keep=spgi-dev,cache=spgispeech
  --gigaspeech [EVAL:]MANIFEST = --set heldout:gigaspeech:MANIFEST:session=before:_S,cache=gigaspeech
  --common-words FILE         Le et al.'s all_words.count.txt (rare = not in its first 5000, with a letter)
  --prep-index FILE           lf-bias-prep's index.json, whose train DF tables must match
                              (default $LF_EXP2_ROOT/prep/index.json)
  --group-cache DIR           per-session encoder cache root (default $LF_EXP2_ROOT/cache; one of the two is required)
  --dev-subset N              dev-other subset size (default 600)
  --costs                     node-pass, per-decision and cold-latency timings
  --hyps                      write hyps.jsonl (every row's hypotheses)
  --per-session               write per_session.jsonl (counts per row, set, size and session)
  --l0-row LABEL=ALPHA,DEPTH,CANCEL,CASE
                              an extra fixed-bonus row, decoded as given (repeatable)
  --expect-rows FILE:ID[,ID...]
                              experiment 2's results.json: the listed rows must reproduce its counts";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetSel {
    Dev,
    Heldout,
    Both,
}

impl SetSel {
    fn includes(self, role: Role) -> bool {
        match self {
            SetSel::Both => true,
            SetSel::Dev => role == Role::Tune,
            SetSel::Heldout => role == Role::Test,
        }
    }

    fn name(self) -> &'static str {
        match self {
            SetSel::Dev => "dev",
            SetSel::Heldout => "heldout",
            SetSel::Both => "both",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ModelSource {
    File(PathBuf),
    /// Random weights (PyTorch-style init, gate 0.5, non-zero final layers):
    /// for smoke tests and timing only.
    Random {
        variant: Variant,
        seed: u64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LambdaSel {
    Grid,
    Meta,
    Fixed(f32),
}

#[derive(Clone, Debug, PartialEq)]
pub struct LearnedSpec {
    pub source: ModelSource,
    pub lambda: LambdaSel,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionKey {
    /// A manifest field.
    Field(String),
    /// The id before the first occurrence of a separator.
    Before(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Keep {
    SpgiDev,
    SpgiTrain,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GenericSet {
    pub role: Role,
    pub name: String,
    pub manifest: PathBuf,
    pub session: SessionKey,
    pub conditions: Vec<ListCondition>,
    pub keep: Option<Keep>,
    pub cache_dir: String,
    /// Where the session document frequency comes from (DESIGN "DF source");
    /// required.
    pub df: Option<DfSource>,
    /// Declared casing of the references (`cased=yes|no`); required.
    pub casing: Option<exp2_terms::Casing>,
    /// The technical dataset (`dataset=NAME`, one of [`DATASETS`]); required.
    pub dataset: Option<String>,
}

/// How a dataset's lines are assigned to splits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitRule {
    /// The manifest's `split` field, on every line.
    Field,
    /// SPGISpeech: experiment 2's call hash (`exp2_data::spgi_is_dev`).
    SpgiHash,
    /// The whole manifest is one held-out split (GigaSpeech test).
    WholeHeldout,
}

/// A split, as manifest `split` values name it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitName {
    Train,
    Dev,
    Heldout,
}

impl SplitName {
    /// A manifest `split` value, with `lf-bias-prep`'s aliases: train; dev,
    /// validation, valid; heldout, held-out, test, eval.
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "train" => Some(SplitName::Train),
            "dev" | "validation" | "valid" => Some(SplitName::Dev),
            "heldout" | "held-out" | "test" | "eval" => Some(SplitName::Heldout),
            _ => None,
        }
    }

    fn of_role(role: Role) -> Self {
        match role {
            Role::Tune => SplitName::Dev,
            Role::Test => SplitName::Heldout,
        }
    }

    fn name(self) -> &'static str {
        match self {
            SplitName::Train => "train",
            SplitName::Dev => "dev",
            SplitName::Heldout => "heldout",
        }
    }
}

/// A technical dataset's frozen rules: whether it has a train split (then
/// its DF source is the train split; otherwise the scored split) and how its
/// lines are assigned to splits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DatasetRule {
    pub name: &'static str,
    pub has_train: bool,
    /// Evaluation only: a `--set` of it must be held out.
    pub heldout_only: bool,
    pub split: SplitRule,
}

/// The technical datasets (frozen): experiment 2's, plus experiment 3's
/// fresh confirmation set Earnings-21 (evaluation only, no train split, the
/// manifest `split` field must name held-out, DF from the scored split).
pub const DATASETS: [DatasetRule; 6] = [
    DatasetRule {
        name: "spgispeech",
        has_train: true,
        heldout_only: false,
        split: SplitRule::SpgiHash,
    },
    DatasetRule {
        name: "slidespeech",
        has_train: true,
        heldout_only: false,
        split: SplitRule::Field,
    },
    DatasetRule {
        name: "icsi",
        has_train: true,
        heldout_only: false,
        split: SplitRule::Field,
    },
    DatasetRule {
        name: "acl6060",
        has_train: false,
        heldout_only: false,
        split: SplitRule::Field,
    },
    DatasetRule {
        name: "gigaspeech",
        has_train: false,
        heldout_only: true,
        split: SplitRule::WholeHeldout,
    },
    DatasetRule {
        name: "earnings21",
        has_train: false,
        heldout_only: true,
        split: SplitRule::Field,
    },
];

pub fn dataset_rule(name: &str) -> Option<DatasetRule> {
    DATASETS.iter().copied().find(|d| d.name == name)
}

/// The DF-source and split rules a `--set` must satisfy for its dataset.
pub fn check_set_rules(g: &GenericSet) -> Result<DatasetRule, String> {
    let name = &g.name;
    let ds = g
        .dataset
        .as_deref()
        .ok_or(format!("--set {name}: dataset=NAME is required"))?;
    let rule = dataset_rule(ds).ok_or(format!(
        "--set {name}: unknown dataset {ds:?} (one of {:?})",
        DATASETS.map(|d| d.name)
    ))?;
    match (&g.df, rule.has_train) {
        (Some(DfSource::Scored), true) => {
            return Err(format!(
                "--set {name}: {ds} has a train split, so df= must be its train manifest, not scored"
            ));
        }
        (Some(DfSource::Train { .. }), false) => {
            return Err(format!(
                "--set {name}: {ds} has no train split, so df=scored is required"
            ));
        }
        _ => {}
    }
    let df_keep = match &g.df {
        Some(DfSource::Train { keep, .. }) => *keep,
        _ => None,
    };
    match rule.split {
        SplitRule::SpgiHash => {
            if g.role != Role::Tune
                || g.keep != Some(Keep::SpgiDev)
                || df_keep != Some(Keep::SpgiTrain)
            {
                return Err(format!(
                    "--set {name}: SPGISpeech is dev only, with keep=spgi-dev and \
                     df-keep=spgi-train (the call-hash split)"
                ));
            }
        }
        SplitRule::Field | SplitRule::WholeHeldout => {
            if g.keep.is_some() || df_keep.is_some() {
                return Err(format!(
                    "--set {name}: keep/df-keep are for SPGISpeech's call hash only"
                ));
            }
            if rule.heldout_only && g.role != Role::Test {
                return Err(format!("--set {name}: {ds} is held-out only"));
            }
        }
    }
    Ok(rule)
}

/// The session document frequency's source (DESIGN.md, "DF source"): the
/// dataset's train split, frozen; for datasets without one, the scored split.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DfSource {
    /// The train-split manifests, restricted to the sessions `keep` admits
    /// (SPGISpeech: the train calls of the one manifest).
    Train {
        manifests: Vec<PathBuf>,
        keep: Option<Keep>,
    },
    /// No train split: the scored split (the set's manifest and `keep`).
    Scored,
}

impl Keep {
    fn admits(self, session: &str) -> bool {
        match self {
            Keep::SpgiDev => exp2_data::spgi_is_dev(session),
            Keep::SpgiTrain => !exp2_data::spgi_is_dev(session),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Keep::SpgiDev => "spgi-dev",
            Keep::SpgiTrain => "spgi-train",
        }
    }
}

#[derive(Default)]
pub struct Exp2Args {
    pub sets: Option<SetSel>,
    pub learned: Vec<LearnedSpec>,
    pub lambdas: Option<Vec<f32>>,
    pub l0: Option<Cfg>,
    pub l0_retune: bool,
    pub l0_parity: bool,
    /// Skip the L0-historical row (checkpoint dev checks).
    pub no_l0: bool,
    /// Accept a dev objective without every frozen domain (smoke runs);
    /// results are marked `"partial": true`.
    pub allow_partial_dev: bool,
    /// Evaluate only these list sizes (parity smoke checks).
    pub sizes: Option<Vec<usize>>,
    pub exp1_results: Option<PathBuf>,
    pub exp1_oracle: Option<PathBuf>,
    pub generic: Vec<GenericSet>,
    pub libri_dev: Option<PathBuf>,
    pub dev_subset: Option<usize>,
    pub common_words: Option<PathBuf>,
    pub group_cache: Option<PathBuf>,
    pub costs: bool,
    pub hyps: bool,
    /// `lf-bias-prep`'s index, for the frozen train DF tables.
    pub prep_index: Option<PathBuf>,
    /// Write `per_session.jsonl` (experiment 3).
    pub per_session: bool,
    /// Extra fixed-bonus rows `(label, config)`, decoded as given, never
    /// searched (`--l0-row LABEL=ALPHA,DEPTH,CANCEL,CASE`).
    pub l0_rows: Vec<(String, Cfg)>,
    /// Experiment 2's results.json and the row ids whose per-set counts the
    /// re-decoded rows must reproduce (`--expect-rows FILE:ID[,ID...]`).
    pub expect_rows: Option<(PathBuf, Vec<String>)>,
    /// An explicit, narrower `--expect-rows` comparison scope (set names).
    pub expect_scope: Option<BTreeSet<String>>,
}

/// `ALPHA,DEPTH,CANCEL,CASE` (as `--l0`).
fn parse_l0(v: &str) -> Result<Cfg, String> {
    let p: Vec<&str> = v.split(',').collect();
    let [a, d, c, k] = p[..] else {
        return Err(format!("{v:?}: ALPHA,DEPTH,CANCEL,CASE"));
    };
    let cfg = Cfg {
        alpha: a.parse().map_err(|e| format!("{a:?}: {e}"))?,
        depth: d.parse().map_err(|e| format!("{d:?}: {e}"))?,
        cancel: parse_on_off(c)?,
        case: parse_on_off(k)?,
    };
    if !(cfg.alpha.is_finite() && cfg.alpha >= 0.0 && cfg.depth.is_finite()) {
        return Err(format!("{v:?}: bad alpha or depth"));
    }
    Ok(cfg)
}

/// Row labels the evaluator writes itself; an `--l0-row` may not use them.
const RESERVED_ROWS: [&str; 3] = ["baseline", "L0-historical", BASELINE_ROW];

impl Exp2Args {
    fn lambdas(&self) -> Vec<f32> {
        self.lambdas.clone().unwrap_or(DEFAULT_LAMBDAS.to_vec())
    }

    /// `--group-cache`, else `$LF_EXP2_ROOT/cache`.
    fn group_cache(&self) -> Result<PathBuf, String> {
        match &self.group_cache {
            Some(p) => Ok(p.clone()),
            None => root_path("cache", "--group-cache DIR"),
        }
    }

    /// `--prep-index`, else `$LF_EXP2_ROOT/prep/index.json`.
    fn prep_index(&self) -> Result<PathBuf, String> {
        match &self.prep_index {
            Some(p) => Ok(p.clone()),
            None => root_path("prep/index.json", "--prep-index FILE"),
        }
    }
}

fn parse_f32_list(v: &str) -> Result<Vec<f32>, String> {
    v.split(',')
        .map(|s| {
            let x: f32 = s.trim().parse().map_err(|e| format!("{s:?}: {e}"))?;
            if x.is_finite() && x >= 0.0 {
                Ok(x)
            } else {
                Err(format!("{s:?}: λ must be finite and non-negative"))
            }
        })
        .collect()
}

fn parse_on_off(s: &str) -> Result<bool, String> {
    match s {
        "on" | "true" | "1" => Ok(true),
        "off" | "false" | "0" => Ok(false),
        _ => Err(format!("{s:?}: expected on or off")),
    }
}

pub fn parse_learned(v: &str) -> Result<Vec<LearnedSpec>, String> {
    v.split(',')
        .filter(|s| !s.is_empty())
        .map(|s| {
            let (src, lambda) = match s.rsplit_once('@') {
                Some((p, "meta")) => (p, LambdaSel::Meta),
                Some((p, l)) => (
                    p,
                    LambdaSel::Fixed(parse_f32_list(l)?.first().copied().ok_or("empty λ")?),
                ),
                None => (s, LambdaSel::Grid),
            };
            let source = match src.strip_prefix("random:") {
                Some(r) => {
                    let (v, seed) = r.split_once(':').unwrap_or((r, "1"));
                    ModelSource::Random {
                        variant: Variant::parse(v)?,
                        seed: seed.parse().map_err(|e| format!("{s}: {e}"))?,
                    }
                }
                None => ModelSource::File(src.into()),
            };
            Ok(LearnedSpec { source, lambda })
        })
        .collect()
}

pub fn parse_set(v: &str) -> Result<GenericSet, String> {
    let parts: Vec<&str> = v.splitn(4, ':').collect();
    let (role, name, manifest) = match parts[..] {
        [r, n, m] | [r, n, m, _] => (r, n, m),
        _ => return Err("--set takes ROLE:NAME:MANIFEST[:OPTIONS]".into()),
    };
    let role = match role {
        "dev" => Role::Tune,
        "heldout" => Role::Test,
        r => return Err(format!("--set: unknown role {r:?} (dev or heldout)")),
    };
    if name.is_empty() || name.contains(['/', ':', ',']) {
        return Err(format!("--set: bad name {name:?}"));
    }
    let mut g = GenericSet {
        role,
        name: name.to_owned(),
        manifest: manifest.into(),
        session: SessionKey::Field("session".into()),
        conditions: vec![ListCondition::Rare],
        keep: None,
        cache_dir: name.to_owned(),
        df: None,
        casing: None,
        dataset: None,
    };
    let mut df_keep = None;
    for opt in parts.get(3).map(|o| o.split(',')).into_iter().flatten() {
        let (k, val) = opt
            .split_once('=')
            .ok_or(format!("--set option {opt:?}: expected KEY=VALUE"))?;
        match k {
            "session" => {
                g.session = match val.split_once(':') {
                    Some(("field", f)) if !f.is_empty() => SessionKey::Field(f.into()),
                    Some(("before", sep)) if !sep.is_empty() => SessionKey::Before(sep.into()),
                    _ => return Err(format!("--set session={val}: field:NAME or before:SEP")),
                }
            }
            "lists" => {
                g.conditions = val
                    .split('+')
                    .map(|c| match c {
                        "rare" => Ok(ListCondition::Rare),
                        "keywords" => Ok(ListCondition::Keywords),
                        _ => Err(format!(
                            "--set lists={val}: rare, keywords or rare+keywords"
                        )),
                    })
                    .collect::<Result<_, _>>()?;
            }
            "keep" => {
                g.keep = Some(match val {
                    "spgi-dev" => Keep::SpgiDev,
                    "spgi-train" => Keep::SpgiTrain,
                    _ => return Err(format!("--set keep={val}: spgi-dev or spgi-train")),
                })
            }
            "cache" => {
                if val.is_empty() || val.contains(['/', '\\']) || val == "." || val == ".." {
                    return Err(format!("--set cache={val}: a plain directory name"));
                }
                g.cache_dir = val.into();
            }
            "dataset" => g.dataset = Some(val.to_owned()),
            "cased" => {
                g.casing = Some(match val {
                    "yes" => exp2_terms::Casing::Cased,
                    "no" => exp2_terms::Casing::Uncased,
                    _ => return Err(format!("--set cased={val}: yes or no")),
                })
            }
            "df" if val == "scored" => g.df = Some(DfSource::Scored),
            "df" => {
                let manifests: Vec<PathBuf> = val.split('+').map(PathBuf::from).collect();
                if manifests.iter().any(|p| p.as_os_str().is_empty()) {
                    return Err(format!("--set df={val}: TRAIN_PATH[+PATH...] or scored"));
                }
                g.df = Some(DfSource::Train {
                    manifests,
                    keep: None,
                });
            }
            "df-keep" => {
                df_keep = Some(match val {
                    "spgi-train" => Keep::SpgiTrain,
                    "spgi-dev" => Keep::SpgiDev,
                    _ => return Err(format!("--set df-keep={val}: spgi-train or spgi-dev")),
                })
            }
            _ => return Err(format!("--set: unknown option {k:?}")),
        }
    }
    match (&mut g.df, df_keep) {
        (Some(DfSource::Train { keep, .. }), Some(k)) => *keep = Some(k),
        (_, Some(_)) => return Err("--set df-keep needs df=TRAIN_PATH".into()),
        _ => {}
    }
    if g.casing.is_none() {
        return Err(format!(
            "--set {name}: cased=yes|no (the references' declared casing) is required"
        ));
    }
    if g.df.is_none() {
        return Err(format!(
            "--set {name}: df=TRAIN_MANIFEST[+...] (the train split) or df=scored (datasets \
             without a train split) is required"
        ));
    }
    check_set_rules(&g)?;
    Ok(g)
}

/// Experiment 2 flags; `Ok(false)` when `flag` is not one of them.
pub fn parse_flag(
    x: &mut Exp2Args,
    flag: &str,
    value: &mut dyn FnMut() -> Result<String, String>,
) -> Result<bool, String> {
    let err = |e: String| format!("{flag}: {e}");
    match flag {
        "--sets" => {
            x.sets = Some(match value()?.as_str() {
                "dev" => SetSel::Dev,
                "heldout" => SetSel::Heldout,
                "both" => SetSel::Both,
                s => return Err(format!("--sets {s:?}: dev, heldout or both")),
            })
        }
        "--learned" => x.learned.extend(parse_learned(&value()?).map_err(err)?),
        "--lambdas" => x.lambdas = Some(parse_f32_list(&value()?).map_err(err)?),
        "--l0" => {
            let v = value()?;
            let p: Vec<&str> = v.split(',').collect();
            let [a, d, c, k] = p[..] else {
                return Err("--l0 takes ALPHA,DEPTH,CANCEL,CASE".into());
            };
            x.l0 = Some(Cfg {
                alpha: a.parse().map_err(|e| format!("--l0: {e}"))?,
                depth: d.parse().map_err(|e| format!("--l0: {e}"))?,
                cancel: parse_on_off(c).map_err(err)?,
                case: parse_on_off(k).map_err(err)?,
            });
        }
        "--l0-retune" => x.l0_retune = true,
        "--no-l0" => x.no_l0 = true,
        "--allow-partial-dev" => x.allow_partial_dev = true,
        "--per-session" => x.per_session = true,
        "--l0-row" => {
            let v = value()?;
            let (label, cfg) = v
                .split_once('=')
                .ok_or("--l0-row takes LABEL=ALPHA,DEPTH,CANCEL,CASE")?;
            if label.is_empty() || label.contains('@') || RESERVED_ROWS.contains(&label) {
                return Err(format!(
                    "--l0-row: label {label:?} is empty, has '@' or is reserved ({RESERVED_ROWS:?})"
                ));
            }
            if x.l0_rows.iter().any(|(l, _)| l == label) {
                return Err(format!("--l0-row: label {label:?} given twice"));
            }
            x.l0_rows
                .push((label.to_owned(), parse_l0(cfg).map_err(err)?));
        }
        "--expect-scope" => {
            let sets: BTreeSet<String> = value()?
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect();
            if sets.is_empty() {
                return Err("--expect-scope takes SET[,SET...]".into());
            }
            x.expect_scope = Some(sets);
        }
        "--expect-rows" => {
            let v = value()?;
            let (file, ids) = v
                .rsplit_once(':')
                .ok_or("--expect-rows takes FILE:ROW_ID[,ROW_ID...]")?;
            let ids: Vec<String> = ids
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect();
            if file.is_empty() || ids.is_empty() {
                return Err("--expect-rows takes FILE:ROW_ID[,ROW_ID...]".into());
            }
            x.expect_rows = Some((file.into(), ids));
        }
        "--sizes" => {
            x.sizes = Some(
                value()?
                    .split(',')
                    .map(|s| {
                        s.trim()
                            .parse::<usize>()
                            .map_err(|e| format!("--sizes: {e}"))
                    })
                    .collect::<Result<_, _>>()?,
            )
        }
        "--l0-parity" => x.l0_parity = true,
        "--exp1-results" => x.exp1_results = Some(value()?.into()),
        "--exp1-oracle" => x.exp1_oracle = Some(value()?.into()),
        "--libri-dev" => x.libri_dev = Some(value()?.into()),
        "--dev-subset" => {
            x.dev_subset = Some(value()?.parse().map_err(|e| format!("{e}")).map_err(err)?)
        }
        "--set" => x.generic.push(parse_set(&value()?)?),
        "--spgi-dev" => {
            let v = value()?;
            let m = v.rsplit(':').next().unwrap_or(&v);
            x.generic.push(parse_set(&format!(
                "dev:spgispeech_dev:{m}:dataset=spgispeech,session=before:/,keep=spgi-dev,cache=spgispeech,cased=yes,\
                 df={m},df-keep=spgi-train"
            ))?);
        }
        "--gigaspeech" => {
            let v = value()?;
            let m = v.rsplit(':').next().unwrap_or(&v);
            x.generic.push(parse_set(&format!(
                "heldout:gigaspeech:{m}:dataset=gigaspeech,session=before:_S,cache=gigaspeech,df=scored,cased=no"
            ))?);
        }
        "--common-words" => x.common_words = Some(value()?.into()),
        "--group-cache" => x.group_cache = Some(value()?.into()),
        "--prep-index" => x.prep_index = Some(value()?.into()),
        "--costs" => x.costs = true,
        "--hyps" => x.hyps = true,
        _ => return Ok(false),
    }
    Ok(true)
}

/// Checks experiment 2's arguments and stores them in `a`. Decoding uses
/// 1-thread pools: `--workers` becomes `--threads`.
pub fn validate(a: &mut Args, x: Exp2Args) -> Result<(), String> {
    let sel = x.sets.expect("exp2 mode");
    if a.out.is_none() {
        return Err("need --out".into());
    }
    if a.calibrate {
        return Err("--calibrate is experiment 1 only".into());
    }
    if a.threads == 0 {
        return Err("--threads must be positive".into());
    }
    a.workers = a.threads;
    let needs_words = !x.generic.is_empty() || x.libri_dev.is_some();
    if (needs_words || a.session.is_some()) && a.rare_words.is_none() {
        return Err("--rare-words (Le et al.'s all_rare_words.txt) is required".into());
    }
    if needs_words && x.common_words.is_none() {
        return Err("--set, --spgi-dev, --gigaspeech and --libri-dev need --common-words".into());
    }
    for g in &x.generic {
        if g.role == Role::Tune && !DEV_DOMAINS.contains(&g.name.as_str()) {
            return Err(format!(
                "dev set {:?} is not a frozen dev domain ({DEV_DOMAINS:?})",
                g.name
            ));
        }
        if g.role == Role::Tune && g.conditions != [ListCondition::Rare] {
            return Err(format!(
                "dev set {:?}: only rare-word lists count for the objective",
                g.name
            ));
        }
    }
    let names: Vec<&String> = x.generic.iter().map(|g| &g.name).collect();
    if names.iter().collect::<BTreeSet<_>>().len() != names.len() {
        return Err("--set names must be unique".into());
    }
    let has = |role: Role| {
        x.generic.iter().any(|g| g.role == role)
            || a.session.is_some()
            || a.libri.iter().any(|l| l.role == role)
            || (role == Role::Tune && x.libri_dev.is_some())
    };
    if sel.includes(Role::Tune) && !has(Role::Tune) {
        return Err("--sets includes dev but no dev set is given".into());
    }
    if sel.includes(Role::Test) && !has(Role::Test) {
        return Err("--sets includes heldout but no held-out set is given".into());
    }
    if x.exp1_oracle.is_some() && !(x.exp1_results.is_some() && x.l0_parity && !x.no_l0) {
        return Err(
            "--exp1-oracle relies on L0-historical parity: add --exp1-results and --l0-parity"
                .into(),
        );
    }
    if x.expect_scope.is_some() && x.expect_rows.is_none() {
        return Err("--expect-scope narrows --expect-rows; give --expect-rows".into());
    }
    if x.l0_retune && x.l0_rows.iter().any(|(l, _)| l == "L0-retuned") {
        return Err("--l0-row L0-retuned=... and --l0-retune both write the L0-retuned row".into());
    }
    if x.no_l0 && x.exp1_results.is_some() {
        return Err("--exp1-results compares the L0-historical row (drop --no-l0)".into());
    }
    if x.no_l0 && x.l0_parity {
        return Err("--l0-parity needs the L0-historical row (drop --no-l0)".into());
    }
    // Fail before any encoding when a frozen dev domain has no source (the
    // names of experiment 1's sets are checked again after loading).
    if sel.includes(Role::Tune) {
        let mut predicted: Vec<String> = x
            .generic
            .iter()
            .filter(|g| g.role == Role::Tune)
            .map(|g| g.name.clone())
            .collect();
        if let Some((eval, _)) = &a.session {
            predicted.push(format!("{}_tune", super::stem(eval)));
        }
        if x.libri_dev.is_some() {
            predicted.push(DEV_OTHER_NAME.into());
        }
        let names: Vec<&str> = predicted.iter().map(String::as_str).collect();
        check_dev_domains(&names, x.allow_partial_dev)?;
    }
    if let Some(sizes) = &x.sizes
        && (sizes.is_empty() || sizes.iter().any(|n| !SIZES.contains(n)))
    {
        return Err(format!("--sizes: each size must be one of {SIZES:?}"));
    }
    if x.l0_retune && !sel.includes(Role::Tune) {
        return Err("--l0-retune needs the dev sets (--sets dev or both)".into());
    }
    if let Some(Cfg { alpha, depth, .. }) = x.l0
        && !(alpha.is_finite() && alpha >= 0.0 && depth.is_finite())
    {
        return Err("--l0: bad alpha or depth".into());
    }
    a.exp2 = Some(x);
    Ok(())
}

// ---------------------------------------------------------------- objective

/// Whether the dev sets `present` cover every frozen domain: `Ok(false)`
/// when they do, `Ok(true)` (a partial objective) when some are missing and
/// `allow_partial` is set, an error otherwise.
pub fn check_dev_domains(present: &[&str], allow_partial: bool) -> Result<bool, String> {
    // Exactly one set per domain, whatever source type loaded it.
    let mut seen = BTreeSet::new();
    for p in present {
        if !seen.insert(*p) {
            return Err(format!(
                "dev domain {p} is given more than once (--libri-dev, --set and the shorthands \
                 must name each domain once)"
            ));
        }
    }
    let missing: Vec<&str> = DEV_DOMAINS
        .iter()
        .copied()
        .filter(|d| !present.contains(d))
        .collect();
    match (missing.is_empty(), allow_partial) {
        (true, _) => Ok(false),
        (false, true) => Ok(true),
        (false, false) => Err(format!(
            "dev domains missing: {missing:?}; the dev objective needs all of {DEV_DOMAINS:?} \
             (--allow-partial-dev for smoke runs, marked partial)"
        )),
    }
}

/// The dev objective: the mean over dev sets (each a frozen dev domain) of
/// the mean over its sizes of `errors / baseline errors`. Refuses no sets, a
/// set without sizes, an unknown domain and a zero baseline.
pub fn dev_objective(per_set: &[(String, Vec<(usize, usize)>)]) -> Result<f64, String> {
    if per_set.is_empty() {
        return Err("no dev sets: the objective needs at least one dev domain".into());
    }
    let mut total = 0.0;
    for (name, pairs) in per_set {
        if !DEV_DOMAINS.contains(&name.as_str()) {
            return Err(format!("{name} is not a frozen dev domain"));
        }
        if pairs.is_empty() {
            return Err(format!("{name}: no list sizes"));
        }
        if pairs.iter().any(|&(_, b)| b == 0) {
            return Err(format!(
                "{name}: no baseline errors; relative WER is undefined"
            ));
        }
        total += pairs.iter().map(|&(e, b)| e as f64 / b as f64).sum::<f64>() / pairs.len() as f64;
    }
    let obj = total / per_set.len() as f64;
    if obj.is_finite() {
        Ok(obj)
    } else {
        Err(format!("non-finite objective {obj}"))
    }
}

// ---------------------------------------------------------------- data

/// Maps an utterance id to its session.
type SessionOf = Box<dyn Fn(&str) -> String>;

fn session_fn(key: &SessionKey, manifest: &Path) -> Result<SessionOf, String> {
    Ok(match key {
        SessionKey::Before(sep) => {
            let sep = sep.clone();
            Box::new(move |id: &str| id.split(sep.as_str()).next().unwrap_or(id).to_owned())
        }
        SessionKey::Field(f) => {
            let mut map = HashMap::new();
            for v in manifest_lines(manifest)? {
                let id = v
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or(format!("{}: line without id", manifest.display()))?;
                let s = v.get(f).and_then(super::json_string).ok_or(format!(
                    "{}: {id} has no session field {f:?}",
                    manifest.display()
                ))?;
                map.insert(id.to_owned(), s);
            }
            Box::new(move |id: &str| map.get(id).cloned().unwrap_or_default())
        }
    })
}

/// The frozen session document frequency of a generic set (DESIGN "DF
/// source"): from the train-split manifests (restricted by their `keep`),
/// or, for a dataset without a train split, from the scored split (the set's
/// manifest and `keep`). Independent of `--limit`. Returns the table and its
/// identity for results.json (`df_source`).
/// Every DF line must belong to the DF split (train lines for a dataset with
/// a train split, checked by its split rule); the third value is the DF
/// sessions.
pub fn set_df(
    g: &GenericSet,
    rule: DatasetRule,
) -> Result<(exp2_terms::SessionDf, Value, BTreeSet<String>), String> {
    let (paths, keep, split, expect) = match g.df.as_ref().ok_or("df source required")? {
        DfSource::Train { manifests, keep } => {
            (manifests.clone(), *keep, "train", SplitName::Train)
        }
        DfSource::Scored => (
            vec![g.manifest.clone()],
            g.keep,
            "scored",
            SplitName::of_role(g.role),
        ),
    };
    let mut refs = Vec::new();
    for p in &paths {
        refs.extend(split_lines(p, &g.session, keep, rule, expect)?);
    }
    if refs.is_empty() {
        return Err(format!("{}: no lines in the DF source", g.name));
    }
    let sessions: BTreeSet<String> = refs.iter().map(|(s, _)| s.clone()).collect();
    let df =
        exp2_terms::SessionDf::from_references(refs.iter().map(|(s, t)| (s.as_str(), t.as_str())));
    let manifests: Vec<Value> = paths
        .iter()
        .map(|p| {
            lf_model::manifest::sha256_file(p)
                .map(|h| json!({"path": p.display().to_string(), "sha256": h}))
                .map_err(|e| format!("{}: {e}", p.display()))
        })
        .collect::<Result<_, _>>()?;
    let info = json!({
        "dataset": rule.name,
        "split": split,
        "split_checked": expect.name(),
        "split_rule": format!("{:?}", rule.split),
        "manifests": manifests,
        "keep": keep.map(Keep::name),
        "sessions": df.sessions(),
        "max_df": df.max_df(),
        "table_sha256": df.sha256(),
    });
    Ok((df, info, sessions))
}

/// `(session, text)` of every line of `path` admitted by `keep`, after
/// checking that each belongs to split `expect` by the dataset's rule:
/// - `Field`: every line has a `split` field naming `expect` (a mixed-split
///   manifest is an error, never filtered);
/// - `SpgiHash`: membership is the call hash, applied through `keep`, which
///   must be given; a `split` field, if present, must agree;
/// - `WholeHeldout`: `expect` must be held out; a `split` field, if
///   present, must agree.
pub fn split_lines(
    path: &Path,
    key: &SessionKey,
    keep: Option<Keep>,
    rule: DatasetRule,
    expect: SplitName,
) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    let mut wrong: BTreeMap<String, usize> = BTreeMap::new();
    for v in manifest_lines(path)? {
        let id = v
            .get("id")
            .and_then(Value::as_str)
            .ok_or(format!("{}: line without id", path.display()))?;
        let session = match key {
            SessionKey::Before(sep) => id.split(sep.as_str()).next().unwrap_or(id).to_owned(),
            SessionKey::Field(f) => v.get(f).and_then(super::json_string).ok_or(format!(
                "{}: {id} has no session field {f:?}",
                path.display()
            ))?,
        };
        let field = v.get("split").and_then(Value::as_str);
        let declared = match field {
            Some(s) => Some(
                SplitName::parse(s)
                    .ok_or(format!("{}: {id} has unknown split {s:?}", path.display()))?,
            ),
            None => None,
        };
        let member = match rule.split {
            SplitRule::Field => {
                let d = declared.ok_or(format!(
                    "{}: {id} has no split field ({} needs one on every line)",
                    path.display(),
                    rule.name
                ))?;
                if d != expect {
                    *wrong.entry(d.name().to_owned()).or_default() += 1;
                    continue;
                }
                true
            }
            SplitRule::SpgiHash => {
                let k = keep.ok_or(format!(
                    "{}: SPGISpeech lines need keep/df-keep (the call-hash split)",
                    path.display()
                ))?;
                let hash_split = if exp2_data::spgi_is_dev(&session) {
                    SplitName::Dev
                } else {
                    SplitName::Train
                };
                if declared.is_some_and(|d| d != hash_split) {
                    return Err(format!(
                        "{}: {id} declares split {:?} but its call hashes to {}",
                        path.display(),
                        field,
                        hash_split.name()
                    ));
                }
                k.admits(&session)
            }
            SplitRule::WholeHeldout => {
                if expect != SplitName::Heldout || declared.is_some_and(|d| d != SplitName::Heldout)
                {
                    *wrong
                        .entry(declared.map_or("undeclared", SplitName::name).to_owned())
                        .or_default() += 1;
                    continue;
                }
                true
            }
        };
        if member {
            let text = v.get("text").and_then(Value::as_str).unwrap_or("");
            out.push((session, text.to_owned()));
        }
    }
    if !wrong.is_empty() {
        return Err(format!(
            "{}: expected only {} lines for {}, found other splits {wrong:?} (pass the \
             split-specific manifest; lines are never filtered silently)",
            path.display(),
            expect.name(),
            rule.name
        ));
    }
    Ok(out)
}

/// Records each of `sessions` of `dataset` under `role` (train, dev,
/// heldout); a session seen under two roles is an error.
pub fn record_roles(
    roles: &mut BTreeMap<(String, String), &'static str>,
    dataset: &str,
    sessions: &BTreeSet<String>,
    role: &'static str,
) -> Result<(), String> {
    for s in sessions {
        if let Some(prev) = roles.insert((dataset.to_owned(), s.clone()), role)
            && prev != role
        {
            return Err(format!(
                "{dataset} session {s:?} appears as both {prev} and {role}"
            ));
        }
    }
    Ok(())
}

/// `lf-bias-prep`'s frozen train DF table for `dataset`
/// (`datasets.{ds}.splits.train.policy.df_source_sha256` of `index`).
pub fn prep_df_sha(index: &Value, dataset: &str) -> Option<String> {
    let policy = &index["datasets"][dataset]["splits"]["train"]["policy"];
    // The policy may be stored as an object or as its JSON string.
    let policy = match policy {
        Value::String(s) => serde_json::from_str(s).ok()?,
        v => v.clone(),
    };
    policy["df_source_sha256"].as_str().map(str::to_owned)
}

/// `field:NAME` or `before:SEP`, as `--set session=`.
fn parse_session_key(v: &str) -> Result<SessionKey, String> {
    match v.split_once(':') {
        Some(("field", f)) if !f.is_empty() => Ok(SessionKey::Field(f.into())),
        Some(("before", sep)) if !sep.is_empty() => Ok(SessionKey::Before(sep.into())),
        _ => Err(format!("session rule {v:?}: field:NAME or before:SEP")),
    }
}

fn session_rule_name(k: &SessionKey) -> String {
    match k {
        SessionKey::Field(f) => format!("field:{f}"),
        SessionKey::Before(s) => format!("before:{s}"),
    }
}

pub const REF_COUNTS_FORMAT: &str = "lf-bias-eval reference counts v1";

/// Reference-only counts of a manifest (experiment 3; no audio, export or
/// cache): per session, the scored utterances and their reference words,
/// through exactly the evaluator's path (`manifest_items`, the `--set`
/// session rule, `reference_words`), so `ref_words` equals
/// `per_session.jsonl`'s for any row, set and size.
pub fn count_refs(manifest: &Path, key: &SessionKey) -> Result<Value, String> {
    let mut notes = Vec::new();
    let items = manifest_items(manifest, &mut notes)?;
    let session_of = session_fn(key, manifest)?;
    let total_lines = manifest_lines(manifest)?.len();
    let mut sessions: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for (id, r, _) in &items {
        let e = sessions.entry(session_of(id)).or_default();
        e.0 += 1;
        e.1 += super::reference_words(&r.reference).len();
    }
    let sha = lf_model::manifest::sha256_file(manifest)
        .map_err(|e| format!("{}: {e}", manifest.display()))?;
    Ok(json!({
        "format": REF_COUNTS_FORMAT,
        "manifest": manifest.file_name().and_then(|n| n.to_str()).unwrap_or(""),
        "manifest_sha256": sha,
        "session_rule": session_rule_name(key),
        "normalizer": "wer::normalize (lf-bench), the evaluator's reference words",
        "manifest_lines": total_lines,
        "unscored_lines": total_lines - items.len(),
        "utterances": items.len(),
        "ref_words": sessions.values().map(|s| s.1).sum::<usize>(),
        "sessions": sessions.iter().map(|(s, (u, w))| json!({
            "session": s, "utterances": u, "ref_words": w,
        })).collect::<Vec<_>>(),
    }))
}

/// `lf-bias-eval --count-refs MANIFEST --out FILE [--session field:F|before:SEP]`.
pub fn count_refs_cli(argv: Vec<String>) -> Result<(), String> {
    let usage = "usage: lf-bias-eval --count-refs MANIFEST --out FILE [--session field:NAME|before:SEP] \
                 (default --session field:session)";
    let (mut manifest, mut out, mut key) = (None, None, SessionKey::Field("session".into()));
    let mut it = argv.into_iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--count-refs" => manifest = Some(PathBuf::from(value()?)),
            "--out" => out = Some(PathBuf::from(value()?)),
            "--session" => key = parse_session_key(&value()?)?,
            f => return Err(format!("--count-refs: unexpected argument {f}; {usage}")),
        }
    }
    let (Some(manifest), Some(out)) = (manifest, out) else {
        return Err(usage.into());
    };
    outpath::check_output_path(&out)?;
    let counts = count_refs(&manifest, &key)?;
    outpath::write_output(
        &out,
        (serde_json::to_string_pretty(&counts).unwrap() + "\n").as_bytes(),
    )?;
    eprintln!(
        "{}: {} sessions, {} utterances, {} reference words -> {}",
        manifest.display(),
        counts["sessions"].as_array().map_or(0, Vec::len),
        counts["utterances"],
        counts["ref_words"],
        out.display()
    );
    Ok(())
}

/// Session -> keywords (first-seen order, deduplicated) from a manifest's
/// `keywords` field.
fn session_keywords(
    manifest: &Path,
    session_of: &dyn Fn(&str) -> String,
) -> Result<HashMap<String, Vec<String>>, String> {
    let mut out: HashMap<String, Vec<String>> = HashMap::new();
    for v in manifest_lines(manifest)? {
        let Some(id) = v.get("id").and_then(Value::as_str) else {
            continue;
        };
        let list = out.entry(session_of(id)).or_default();
        for k in super::line_keywords(&v) {
            if !list.contains(&k) {
                list.push(k);
            }
        }
    }
    Ok(out)
}

/// LibriSpeech dev-other: a fixed subset with simulated Le et al. lists
/// (rare reference words plus 500 distractors from `pool`), one group per
/// utterance, evaluated at size 500 only.
#[allow(clippy::too_many_arguments)]
fn load_libri_dev(
    data: &mut Data,
    args: &Args,
    manifest: &Path,
    subset: usize,
    common: &BTreeSet<String>,
    pool: &[String],
    root: &Path,
    tr: &mut lf_asr::Transcriber,
    identity: &super::CacheIdentity,
    strict: bool,
) -> Result<(), String> {
    let items = manifest_items(manifest, &mut data.notes)?;
    let ids: Vec<String> = items.iter().map(|(id, _, _)| id.clone()).collect();
    let manifest_sha = check_dev_other_manifest(manifest)?;
    let mut chosen = exp2_data::fixed_subset(&ids, subset, args.seed);
    let chosen_sha = ids_sha256(&chosen);
    if subset == DEV_OTHER_SIZE && chosen_sha != DEV_OTHER_IDS_SHA256 {
        return Err(format!(
            "{DEV_OTHER_NAME}: selected ids hash to {chosen_sha}, frozen {DEV_OTHER_IDS_SHA256}"
        ));
    }
    data.lists_info["dev_other"] = json!({
        "manifest": DEV_OTHER_MANIFEST_NAME,
        "manifest_sha256": manifest_sha,
        "ids_sha256": chosen_sha,
        "selected": chosen.len(),
    });
    if chosen.len() != subset {
        let msg = format!(
            "{DEV_OTHER_NAME}: {} unique scored utterances, {subset} required",
            chosen.len()
        );
        if strict {
            return Err(msg);
        }
        data.notes.push(format!("{msg} (smoke run, ineligible)"));
    }
    if let Some(n) = args.limit {
        chosen.truncate(n);
    }
    let by_id: HashMap<&str, usize> = items
        .iter()
        .enumerate()
        .map(|(i, (id, _, _))| (id.as_str(), i))
        .collect();
    let ids_audio: Vec<(String, PathBuf)> = chosen
        .iter()
        .map(|id| (id.clone(), items[by_id[id.as_str()]].2.clone()))
        .collect();
    let (set_dir, group) = match args.limit {
        Some(n) => (
            format!("librispeech_dev_other.first{n}"),
            "dev600".to_owned(),
        ),
        None => ("librispeech_dev_other".to_owned(), "dev600".to_owned()),
    };
    let path = enc_cache::group_path(root, &set_dir, &group)?;
    let proj = enc_cache::projected(tr, &identity.shared(), &ids_audio, &path, args.threads)?;
    let n = SIZES[DEV_OTHER_LIST];
    let mut set_utts = Vec::new();
    let mut entries_total = 0;
    for (id, p) in chosen.iter().zip(proj) {
        let r = &items[by_id[id.as_str()]].1;
        let rare = exp2_data::rare_words_of(&r.reference, common);
        let list = exp2_data::le_list(id, &rare, pool, n, args.seed);
        entries_total += list.len();
        let mut lists = vec![Vec::new(); SIZES.len()];
        lists[DEV_OTHER_LIST] = list;
        let group = data.groups.len();
        data.groups.push(Group {
            utts: 1,
            list_norm: lists.iter().map(norm_set).collect(),
            lists,
            surface: rare.iter().map(|w| (w.clone(), w.clone())).collect(),
            keywords: false,
        });
        set_utts.push(data.utts.len());
        data.utts.push(Utt {
            id: id.clone(),
            session: super::libri_session(id),
            group,
            ref_words: super::normalize(&r.reference),
            biasing: rare,
            m1_hyp: String::new(),
            frames: p.frames,
            proj: Arc::new(p.proj),
        });
    }
    data.notes.push(format!(
        "{DEV_OTHER_NAME}: {} of {} utterances (seeded subset), simulated Le lists (rare words by \
         the common-word rule plus {n} distractors from all_rare_words), mean {:.0} entries",
        set_utts.len(),
        items.len(),
        entries_total as f64 / set_utts.len().max(1) as f64
    ));
    data.sets.push(Set {
        name: DEV_OTHER_NAME.into(),
        role: Role::Tune,
        utts: set_utts,
        sizes: vec![DEV_OTHER_LIST],
    });
    Ok(())
}

fn load(
    args: &Args,
    x: &Exp2Args,
    tr: &mut lf_asr::Transcriber,
    identity: &super::CacheIdentity,
    out: &Path,
    strict: bool,
) -> Result<(Data, Value, Value), String> {
    let sel = x.sets.unwrap();
    let mut data = new_data();
    let mut info = serde_json::Map::new();
    let mut df_sources = serde_json::Map::new();
    let mut roles: BTreeMap<(String, String), &'static str> = BTreeMap::new();
    let prep_index: Result<Value, String> = x
        .prep_index()
        .and_then(|p| read_text(&p))
        .and_then(|t| serde_json::from_str(&t).map_err(|e| e.to_string()));
    outpath::check_output_dir(&args.cache)?;
    let root = x.group_cache()?;
    for l in args.libri.iter().filter(|l| sel.includes(l.role)) {
        load_libri(&mut data, args, l, tr, identity)?;
    }
    let rare = match &args.rare_words {
        Some(p) => read_rare_words(p)?,
        None => BTreeSet::new(),
    };
    let common = match &x.common_words {
        Some(p) => Arc::new(exp2_data::common_words(&read_text(p)?)?),
        None => Arc::new(BTreeSet::new()),
    };
    let known = Arc::new(rare.clone());
    if let Some((eval, manifest)) = &args.session {
        let lists_out = args
            .lists_out
            .clone()
            .unwrap_or(out.join("earnings22_lists.json"));
        let src = earnings_source(eval, manifest, rare.clone(), lists_out);
        for (name, v) in load_sessions(&mut data, args, &src, tr, identity)? {
            info.insert(name, v);
        }
    }
    if let Some(m) = &x.libri_dev
        && sel.includes(Role::Tune)
    {
        let pool: Vec<String> = rare.iter().cloned().collect();
        let n = x.dev_subset.unwrap_or(DEV_OTHER_SIZE);
        load_libri_dev(
            &mut data, args, m, n, &common, &pool, &root, tr, identity, strict,
        )?;
    }
    for g in x.generic.iter().filter(|g| sel.includes(g.role)) {
        let session_of = session_fn(&g.session, &g.manifest)?;
        let keywords = if g.conditions.contains(&ListCondition::Keywords) {
            session_keywords(&g.manifest, &*session_of)?
        } else {
            HashMap::new()
        };
        let rule = check_set_rules(g)?;
        // The scored lines must all belong to the set's role (no silent
        // filtering), and no session may hold two roles in this run.
        let scored = split_lines(
            &g.manifest,
            &g.session,
            g.keep,
            rule,
            SplitName::of_role(g.role),
        )?;
        let scored_sessions: BTreeSet<String> = scored.into_iter().map(|(s, _)| s).collect();
        record_roles(
            &mut roles,
            rule.name,
            &scored_sessions,
            SplitName::of_role(g.role).name(),
        )?;
        let (df, mut df_info, df_sessions) = set_df(g, rule)?;
        if rule.has_train {
            record_roles(&mut roles, rule.name, &df_sessions, "train")?;
            // The frozen train table must be preparation's.
            df_info["prep_index"] = prep_status(&prep_index, rule.name, &df.sha256());
        }
        data.notes.push(format!(
            "{}: session document frequency ({} split) over {} sessions (targets in at most {}), \
             table {}",
            g.name,
            df_info["split"].as_str().unwrap_or(""),
            df.sessions(),
            df.max_df(),
            df.sha256()
        ));
        df_sources.insert(g.name.clone(), df_info);
        let src = SessionSource {
            name: g.name.clone(),
            items_from: ItemsFrom::Manifest,
            manifest: g.manifest.clone(),
            session_of,
            keep_session: g.keep.map(|k| match k {
                Keep::SpgiDev => exp2_data::spgi_is_dev as fn(&str) -> bool,
                Keep::SpgiTrain => |s: &str| !exp2_data::spgi_is_dev(s),
            }),
            rare: RareRule::Common {
                common: Arc::clone(&common),
                known: Arc::clone(&known),
                df: Arc::new(df),
            },
            fallback: rare.iter().cloned().collect(),
            split: SessionSplit::All(g.role),
            groups_cache: Some((root.clone(), g.cache_dir.clone())),
            lists_out: out.join(format!("{}_lists.json", g.name)),
            conditions: g.conditions.clone(),
            keywords,
            casing: g.casing,
        };
        for (name, v) in load_sessions(&mut data, args, &src, tr, identity)? {
            info.insert(name, v);
        }
    }
    data.sets.retain(|s| sel.includes(s.role));
    if let Some(sizes) = &x.sizes {
        for s in &mut data.sets {
            s.sizes.retain(|&z| sizes.contains(&SIZES[z]));
        }
        data.sets.retain(|s| !s.sizes.is_empty());
        data.notes
            .push(format!("list sizes restricted to {sizes:?}"));
    }
    if sel.includes(Role::Tune) {
        let present: Vec<&str> = data
            .sets
            .iter()
            .filter(|s| s.role == Role::Tune)
            .map(|s| s.name.as_str())
            .collect();
        check_dev_domains(&present, x.allow_partial_dev)?;
    }
    for s in &data.sets {
        if s.role == Role::Tune && !DEV_DOMAINS.contains(&s.name.as_str()) {
            return Err(format!(
                "dev set {} is not a frozen dev domain ({DEV_DOMAINS:?})",
                s.name
            ));
        }
        if s.utts.is_empty() {
            return Err(format!("{}: no utterances", s.name));
        }
    }
    Ok((data, Value::Object(info), Value::Object(df_sources)))
}

// ---------------------------------------------------------------- decoding

/// A dictionary's graph and node pass.
struct LearnedDict {
    graph: BiasGraph,
    dict: PreparedDict,
}

/// Graph of a learned variant: every encodable entry with case variants, no
/// cancel. Returns it and the number of distinct encodable entries (`None`
/// without any phrase).
/// For a keyword list (`keywords`), each entry is encoded from its original
/// and lowercase surfaces, and `entries` counts distinct keywords
/// case-insensitively (by their lowercase form), as preparation does.
fn learned_graph(
    entries: &[String],
    cache: &PhraseCache,
    keywords: bool,
) -> Result<Option<(BiasGraph, usize)>, String> {
    let mut seen = BTreeSet::new();
    let mut phrases = Vec::new();
    for e in entries {
        let key = if keywords {
            e.to_lowercase()
        } else {
            e.clone()
        };
        if let Some(p) = super::cached_phrases(cache, e, true, keywords) {
            phrases.extend(p.iter().cloned());
            seen.insert(key);
        }
    }
    if phrases.is_empty() {
        return Ok(None);
    }
    Ok(Some((
        BiasGraph::new(&phrases, VOCAB, LEARNED_GRAPH)?,
        seen.len(),
    )))
}

/// Node-pass records: (trie nodes, entries, ns).
type NodePasses = Mutex<Vec<(usize, usize, u64)>>;

fn prepare_dict(
    pool: &ThreadPool,
    model: &LearnedModel,
    entries: &[String],
    cache: &PhraseCache,
    keywords: bool,
    passes: &NodePasses,
) -> Result<Option<LearnedDict>, String> {
    let Some((graph, n)) = learned_graph(entries, cache, keywords)? else {
        return Ok(None);
    };
    let feats = TrieFeatures::new(&graph);
    let dict = model.prepare(pool, &feats, n);
    passes
        .lock()
        .unwrap()
        .push((dict.nodes, n, dict.node_pass_ns));
    Ok(Some(LearnedDict { graph, dict }))
}

fn decoded(engine: &Engine, emitted: &[(usize, usize)], ns: u64) -> Decoded {
    let tokens: Vec<usize> = emitted.iter().map(|&(t, _)| t).collect();
    let text = engine.tokenizer.decode(&tokens).unwrap_or_default();
    let words = super::normalize(&text);
    Decoded { text, words, ns }
}

/// Decodes `utts` with a learned model at every λ (list size index `size`);
/// returns `[λ][utterance]`. The node pass runs once per dictionary.
#[allow(clippy::too_many_arguments)]
fn decode_set_learned(
    engine: &Engine,
    data: &Data,
    utts: &[usize],
    size: usize,
    model: &LearnedModel,
    lambdas: &[f32],
    stats: &ScorerStats,
    passes: &NodePasses,
) -> Result<Vec<Vec<Decoded>>, String> {
    type Shared = OnceLock<Result<Option<LearnedDict>, String>>;
    let shared: Vec<Shared> = (0..data.groups.len()).map(|_| OnceLock::new()).collect();
    let results = engine.run(utts, &|&i| data.utts[i].frames, &|pool,
                                                                &i|
     -> Result<
        Vec<Decoded>,
        String,
    > {
        let u = &data.utts[i];
        let g = &data.groups[u.group];
        let local;
        let d = if g.utts > 1 {
            let r = shared[u.group].get_or_init(|| {
                prepare_dict(
                    pool,
                    model,
                    &g.lists[size],
                    engine.cache,
                    g.keywords,
                    passes,
                )
            });
            r.as_ref().map_err(Clone::clone)?.as_ref()
        } else {
            local = prepare_dict(
                pool,
                model,
                &g.lists[size],
                engine.cache,
                g.keywords,
                passes,
            )?;
            local.as_ref()
        };
        let Some(d) = d else {
            let plain = engine.decode(pool, u, None);
            return Ok(lambdas.iter().map(|_| plain.clone()).collect());
        };
        Ok(lambdas
            .iter()
            .map(|&lambda| {
                let scorer = LearnedScorer::new(model, &d.dict, lambda, Some(stats));
                let t = Instant::now();
                let em = engine
                    .decoder
                    .decode_scored(pool, &u.proj, u.frames, &d.graph, &scorer);
                decoded(engine, &em, t.elapsed().as_nanos() as u64)
            })
            .collect())
    });
    let per_utt: Vec<Vec<Decoded>> = results.into_iter().collect::<Result<_, _>>()?;
    Ok((0..lambdas.len())
        .map(|k| per_utt.iter().map(|v| v[k].clone()).collect())
        .collect())
}

/// Decodes `utts` through `decode_scored` with the fixed-bonus graph's own
/// bonuses (cancel must be off), for the parity check.
fn decode_set_graph_scored(
    engine: &Engine,
    data: &Data,
    utts: &[usize],
    size: usize,
    cfg: &Cfg,
) -> Result<Vec<Decoded>, String> {
    if cfg.cancel {
        return Err("graph-scored decoding needs cancel off".into());
    }
    let results = engine.run(utts, &|&i| data.utts[i].frames, &|pool,
                                                                &i|
     -> Result<
        Decoded,
        String,
    > {
        let u = &data.utts[i];
        let grp = &data.groups[u.group];
        let Some(g) = build_graph(&grp.lists[size], engine.cache, cfg, grp.keywords)? else {
            return Ok(engine.decode(pool, u, None));
        };
        let t = Instant::now();
        let em = engine
            .decoder
            .decode_scored(pool, &u.proj, u.frames, &g, &GraphBonusScorer(&g));
        Ok(decoded(engine, &em, t.elapsed().as_nanos() as u64))
    });
    results.into_iter().collect()
}

// ---------------------------------------------------------------- oracle

/// One of experiment 1's held-out oracle cases (an utterance and a missed
/// target word) present in this run.
struct FixedCase {
    utt: usize,
    word: String,
    /// Experiment 1's missed occurrences, and the most its oracle recovered.
    missed: usize,
    oracle_max: usize,
}

/// Experiment 1's oracle cases by set name (`oracle_cases.jsonl`).
fn fixed_cases(path: &Path, data: &Data) -> Result<HashMap<String, Vec<FixedCase>>, String> {
    let index: HashMap<(&str, &str), usize> = data
        .sets
        .iter()
        .flat_map(|s| {
            s.utts
                .iter()
                .map(move |&i| ((s.name.as_str(), data.utts[i].id.as_str()), i))
        })
        .collect();
    let mut out: HashMap<String, Vec<FixedCase>> = HashMap::new();
    for line in read_text(path)?.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value =
            serde_json::from_str(line).map_err(|e| format!("{}: {e}", path.display()))?;
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("");
        let (set, id, word) = (s("set"), s("id"), s("word"));
        let Some(&utt) = index.get(&(set, id)) else {
            continue;
        };
        let missed = v["missed_occurrences"].as_u64().unwrap_or(0) as usize;
        let oracle_max = v["recovered_occurrences_by_alpha"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_u64).max().unwrap_or(0) as usize)
            .unwrap_or(0);
        out.entry(set.to_owned()).or_default().push(FixedCase {
            utt,
            word: word.to_owned(),
            missed,
            oracle_max,
        });
    }
    Ok(out)
}

/// Fixed-denominator oracle recovery of one row: of experiment 1's baseline
/// misses that its oracle recovered, how many occurrences this row recovers
/// (capped per case at the oracle's), plus all recoveries of its misses.
fn fixed_oracle(
    data: &Data,
    base: &Baseline,
    cases: &[FixedCase],
    words_of: &HashMap<usize, &Vec<String>>,
) -> Value {
    let (mut den, mut rec_capped, mut rec_any, mut missed_total, mut mismatched) = (0, 0, 0, 0, 0);
    for c in cases {
        let Some(words) = words_of.get(&c.utt) else {
            continue;
        };
        let u = &data.utts[c.utt];
        let refcount = u.ref_words.iter().filter(|w| **w == c.word).count();
        let base_matched = bias_metrics::matched(&u.ref_words, &base.get(c.utt).words, &c.word);
        let missed = refcount.saturating_sub(base_matched);
        mismatched += usize::from(missed != c.missed);
        let m = bias_metrics::matched(&u.ref_words, words, &c.word);
        let rec = bias_metrics::recovered_occurrences(base_matched, missed, m);
        den += c.oracle_max;
        rec_capped += rec.min(c.oracle_max);
        rec_any += rec;
        missed_total += c.missed;
    }
    json!({
        "denominator_occurrences": den,
        "recovered": rec_capped,
        "fraction": (den > 0).then(|| rec_capped as f64 / den as f64),
        "exp1_missed_occurrences": missed_total,
        "recovered_any": rec_any,
        "cases": cases.len(),
        "baseline_miss_mismatches": mismatched,
    })
}

// ---------------------------------------------------------------- rows

/// Metrics of every row, keyed by (set, size).
struct RowSet {
    label: String,
    config: Value,
    metrics: BTreeMap<(usize, usize), SetMetrics>,
    entries: Vec<Value>,
    /// Hypothesis texts per (set, size), kept only for `--hyps`.
    texts: BTreeMap<(usize, usize), Vec<String>>,
    /// `per_session.jsonl` lines, kept only for `--per-session`.
    sessions: Vec<Value>,
}

struct Ctx<'a> {
    data: &'a Data,
    base: &'a Baseline,
    cases: &'a HashMap<String, Vec<FixedCase>>,
    keep_texts: bool,
    per_session: bool,
}

impl RowSet {
    fn new(label: &str, config: Value) -> Self {
        RowSet {
            label: label.into(),
            config,
            metrics: BTreeMap::new(),
            entries: Vec::new(),
            texts: BTreeMap::new(),
            sessions: Vec::new(),
        }
    }

    fn add(
        &mut self,
        cx: &Ctx,
        set: usize,
        size: usize,
        decoded: &[Decoded],
    ) -> Result<(), String> {
        let s = &cx.data.sets[set];
        let m = set_metrics(cx.data, cx.base, &s.utts, decoded, size);
        let base = baseline_metrics(cx.data, cx.base, &s.utts, size);
        if cx.per_session {
            let sessions = session_counts(cx.data, cx.base, &s.utts, decoded, size);
            check_session_sums(&sessions, &m, base.counts.wer.errors())
                .map_err(|e| format!("{} {} size {}: {e}", self.label, s.name, SIZES[size]))?;
            for (session, c) in sessions {
                let mut line = json!({
                    "row": self.label, "set": s.name, "role": role_name(s.role),
                    "size": SIZES[size], "session": session,
                });
                if let (Value::Object(l), Value::Object(f)) = (&mut line, c.json()) {
                    l.extend(f);
                }
                self.sessions.push(line);
            }
        }
        let mut e = json!({
            "row": self.label, "set": s.name, "role": role_name(s.role), "size": SIZES[size],
            "config": self.config, "metrics": m.json(),
            "net_errors_vs_baseline": m.counts.wer.errors() as i64 - base.counts.wer.errors() as i64,
        });
        if let Some(cases) = cx.cases.get(&s.name) {
            let words: HashMap<usize, &Vec<String>> = s
                .utts
                .iter()
                .zip(decoded)
                .map(|(&i, d)| (i, &d.words))
                .collect();
            e["oracle_recovery"] = fixed_oracle(cx.data, cx.base, cases, &words);
        }
        self.entries.push(e);
        self.metrics.insert((set, size), m);
        if cx.keep_texts {
            self.texts.insert(
                (set, size),
                decoded.iter().map(|d| d.text.clone()).collect(),
            );
        }
        Ok(())
    }

    /// The dev objective of this row, when every dev set was decoded.
    fn objective(&self, data: &Data, base: &Baseline) -> Option<Result<f64, String>> {
        let mut per_set = Vec::new();
        for (si, s) in data.sets.iter().enumerate() {
            if s.role != Role::Tune {
                continue;
            }
            let b = baseline_metrics(data, base, &s.utts, 0).counts.wer.errors();
            let mut pairs = Vec::new();
            for &size in &s.sizes {
                pairs.push((self.metrics.get(&(si, size))?.counts.wer.errors(), b));
            }
            per_set.push((s.name.clone(), pairs));
        }
        (!per_set.is_empty()).then(|| dev_objective(&per_set))
    }
}

fn role_name(r: Role) -> &'static str {
    match r {
        Role::Tune => "dev",
        Role::Test => "held-out",
    }
}

fn fixed_row(engine: &Engine, cx: &Ctx, label: &str, cfg: &Cfg) -> Result<RowSet, String> {
    let mut row = RowSet::new(label, cfg.json());
    for (si, s) in cx.data.sets.iter().enumerate() {
        for &size in &s.sizes {
            let d = engine.decode_set(cx.data, &s.utts, size, Some(cfg))?;
            row.add(cx, si, size, &d)?;
        }
    }
    Ok(row)
}

/// Experiment 1's published numbers for `label` rows ("baseline" or "best")
/// against ours: every count must be identical.
/// Experiment 1's published counts for `label` rows against ours. Expected
/// coverage: every evaluated (set, size) of a set experiment 1 published
/// must have an experiment 1 row, identical in every count.
fn exp1_parity(exp1: &Value, label: &str, row: &RowSet, data: &Data) -> Value {
    let mut checked = Vec::new();
    let mut all_equal = true;
    let finals: Vec<&Value> = exp1["final"].as_array().into_iter().flatten().collect();
    // Expected coverage is frozen, not taken from the supplied rows.
    for (si, s) in data.sets.iter().enumerate() {
        if !EXP1_SETS.contains(&s.name.as_str()) {
            continue;
        }
        for &z in &s.sizes {
            let size = SIZES[z] as u64;
            let (set, Some(m)) = (s.name.as_str(), row.metrics.get(&(si, z))) else {
                continue;
            };
            let Some(e) = finals.iter().find(|e| {
                e["label"] == label
                    && e["set"].as_str() == Some(set)
                    && e["size"].as_u64() == Some(size)
            }) else {
                all_equal = false;
                checked
                    .push(json!({"set": set, "size": size, "identical": false, "missing": true}));
                continue;
            };
            let ours = m.json();
            let fields = [
                "wer",
                "b_wer",
                "u_wer",
                "b_matched",
                "false_alarms",
                "fixed",
                "broken",
            ];
            let differing: Vec<&str> = fields
                .iter()
                .copied()
                .filter(|f| {
                    let strip = |v: &Value| {
                        let mut v = v.clone();
                        if let Some(o) = v.as_object_mut() {
                            o.remove("percent");
                        }
                        v
                    };
                    strip(&ours[*f]) != strip(&e["metrics"][*f])
                })
                .collect();
            all_equal &= differing.is_empty();
            checked.push(json!({"set": set, "size": size, "identical": differing.is_empty(), "differing": differing}));
        }
    }
    json!({"label": label, "rows_checked": checked.len(), "all_identical": all_equal && !checked.is_empty(), "rows": checked})
}

// ---------------------------------------------------------------- costs

fn quantile(v: &mut [f64], p: f64) -> f64 {
    if v.is_empty() {
        return f64::NAN;
    }
    v.sort_by(f64::total_cmp);
    v[((v.len() - 1) as f64 * p).round() as usize]
}

/// Node-pass time against trie size: bins, and a least-squares line.
fn node_pass_summary(passes: &[(usize, usize, u64)]) -> Value {
    let bins = [0usize, 500, 1000, 2000, 4000, 8000, 16000, usize::MAX];
    let rows: Vec<Value> = bins
        .windows(2)
        .filter_map(|w| {
            let mut ms: Vec<f64> = passes
                .iter()
                .filter(|p| p.0 >= w[0] && p.0 < w[1])
                .map(|p| p.2 as f64 / 1e6)
                .collect();
            let n: Vec<usize> = passes
                .iter()
                .filter(|p| p.0 >= w[0] && p.0 < w[1])
                .map(|p| p.0)
                .collect();
            (!ms.is_empty()).then(|| {
                json!({"nodes_from": w[0], "nodes_below": if w[1] == usize::MAX { None } else { Some(w[1]) },
                       "dictionaries": ms.len(), "mean_nodes": n.iter().sum::<usize>() as f64 / n.len() as f64,
                       "median_ms": quantile(&mut ms, 0.5), "p90_ms": quantile(&mut ms, 0.9)})
            })
        })
        .collect();
    let n = passes.len() as f64;
    let (sx, sy) = passes.iter().fold((0.0, 0.0), |(a, b), p| {
        (a + p.0 as f64, b + p.2 as f64 / 1e6)
    });
    let (mx, my) = (sx / n, sy / n);
    let (sxy, sxx) = passes.iter().fold((0.0, 0.0), |(a, b), p| {
        let dx = p.0 as f64 - mx;
        (a + dx * (p.2 as f64 / 1e6 - my), b + dx * dx)
    });
    let slope = (sxx > 0.0).then(|| sxy / sxx);
    json!({
        "dictionaries": passes.len(),
        "threads": 1,
        "by_nodes": rows,
        "fit_ms": slope.map(|s| json!({"intercept": my - s * mx, "per_1000_nodes": 1000.0 * s})),
    })
}

/// Joint time per decision (one `joint_row`, single thread) on real frames.
fn joint_ns(engine: &Engine, data: &Data) -> f64 {
    let Some(u) = data.utts.first() else {
        return f64::NAN;
    };
    let jp = engine.decoder.joint_padded();
    let pool = ThreadPool::new(&[0]);
    let g = engine.decoder.predictor_outputs(&pool, &[]);
    let mut out = vec![0.0f32; VOCAB + 1 + 5];
    let reps = 4000;
    let t = Instant::now();
    for r in 0..reps {
        let f = (r % u.frames.max(1)) * jp;
        engine.decoder.joint_row(&u.proj[f..f + jp], &g, &mut out);
    }
    t.elapsed().as_nanos() as f64 / reps as f64
}

/// Cold first-utterance latency with a fresh dictionary: phrase encoding,
/// graph, node pass (1 thread and `threads` threads) and the first scored
/// decode, against the unbiased decode, on a sample per set at its largest
/// list size.
fn cold_latency(
    engine: &Engine,
    data: &Data,
    model: &LearnedModel,
    lambda: f32,
    threads: usize,
) -> Result<Value, String> {
    let one = ThreadPool::new(&[0]);
    let many = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
    let mut per_set = Vec::new();
    for s in &data.sets {
        let size = *s.sizes.iter().max().unwrap();
        let step = (s.utts.len() / 8).max(1);
        let (mut encode, mut build, mut node1, mut node_n, mut first, mut base, mut nodes) =
            (vec![], vec![], vec![], vec![], vec![], vec![], vec![]);
        for &i in s.utts.iter().step_by(step).take(8) {
            let u = &data.utts[i];
            let grp = &data.groups[u.group];
            let entries = &grp.lists[size];
            let t = Instant::now();
            let mut phrases = Vec::new();
            let mut counted = BTreeSet::new();
            for e in entries.iter().collect::<BTreeSet<_>>() {
                let p = if grp.keywords {
                    super::keyword_phrases(engine.tokenizer, e)
                } else {
                    lf_asr::bias::phrases(engine.tokenizer, std::slice::from_ref(e), true)
                };
                if let Ok(p) = p {
                    phrases.extend(p);
                    counted.insert(if grp.keywords {
                        e.to_lowercase()
                    } else {
                        e.clone()
                    });
                }
            }
            let n = counted.len();
            encode.push(t.elapsed().as_secs_f64() * 1e3);
            if phrases.is_empty() {
                continue;
            }
            let t = Instant::now();
            let graph = BiasGraph::new(&phrases, VOCAB, LEARNED_GRAPH)?;
            let feats = TrieFeatures::new(&graph);
            build.push(t.elapsed().as_secs_f64() * 1e3);
            let t = Instant::now();
            let dict = model.prepare(&one, &feats, n);
            node1.push(t.elapsed().as_secs_f64() * 1e3);
            let t = Instant::now();
            let _ = model.prepare(&many, &feats, n);
            node_n.push(t.elapsed().as_secs_f64() * 1e3);
            nodes.push(feats.nodes() as f64);
            let scorer = LearnedScorer::new(model, &dict, lambda, None);
            let t = Instant::now();
            engine
                .decoder
                .decode_scored(&one, &u.proj, u.frames, &graph, &scorer);
            first.push(t.elapsed().as_secs_f64() * 1e3);
            let t = Instant::now();
            engine.decoder.decode(&one, &u.proj, u.frames, None, None);
            base.push(t.elapsed().as_secs_f64() * 1e3);
        }
        let med = |v: &mut Vec<f64>| quantile(v, 0.5);
        let mut ms = json!({
            "phrase_encoding": med(&mut encode), "graph_and_features": med(&mut build),
            "node_pass_1_thread": med(&mut node1),
            "first_scored_decode_1_thread": med(&mut first), "unbiased_decode_1_thread": med(&mut base),
        });
        ms[format!("node_pass_{threads}_threads")] = json!(med(&mut node_n));
        per_set.push(json!({
            "set": s.name, "size": SIZES[size], "utterances": first.len(),
            "median_ms": ms, "median_nodes": med(&mut nodes),
        }));
    }
    Ok(json!(per_set))
}

// ---------------------------------------------------------------- run

/// A model's unique id: `VARIANT/RUN/FILE_STEM` for a file (RUN = its
/// directory, e.g. `L3/L3-c50/model-e2.5`), `random/VARIANT/SEED` for random
/// weights.
pub fn model_id(variant: Variant, source: &ModelSource) -> String {
    match source {
        ModelSource::File(p) => {
            let part =
                |s: Option<&std::ffi::OsStr>| s.and_then(|s| s.to_str()).unwrap_or("-").to_owned();
            format!(
                "{}/{}/{}",
                variant.name(),
                part(p.parent().and_then(Path::file_name)),
                part(p.file_stem())
            )
        }
        ModelSource::Random { seed, .. } => format!("random/{}/{seed}", variant.name()),
    }
}

/// Rejects two different model sources with one id, and any repeated
/// `(id, λ)` row, before decoding. `models`: (id, source, λs).
pub fn check_model_ids(models: &[(String, &ModelSource, Vec<f32>)]) -> Result<(), String> {
    let mut by_id: HashMap<&str, &ModelSource> = HashMap::new();
    let mut rows = BTreeSet::new();
    for (id, src, lambdas) in models {
        if let Some(prev) = by_id.insert(id, src)
            && prev != *src
        {
            return Err(format!(
                "model id {id} names two different models ({prev:?}, {src:?})"
            ));
        }
        for l in lambdas {
            if !rows.insert((id.clone(), l.to_bits())) {
                return Err(format!("row {id}@{l} is given twice"));
            }
        }
    }
    Ok(())
}

fn load_model(spec: &LearnedSpec) -> Result<(LearnedModel, String), String> {
    let m = match &spec.source {
        ModelSource::File(p) => LearnedModel::load(p)?,
        ModelSource::Random { variant, seed } => {
            let t = learned::random_tensors(*variant, *seed, 0.5, false);
            LearnedModel::from_tensors(*variant, 1.0, t)?
        }
    };
    let id = model_id(m.variant(), &spec.source);
    Ok((m, id))
}

/// Reasons a run cannot select a checkpoint (empty: eligible). Only a dev
/// run with every frozen domain at its full specification, the frozen λ
/// grid and real model files is eligible.
pub fn ineligibility(x: &Exp2Args, args: &Args, partial: bool) -> Vec<String> {
    let mut r = Vec::new();
    if x.sets != Some(SetSel::Dev) {
        r.push("--sets is not dev (held-out sets must not be decoded in a selection run)".into());
    }
    if args.limit.is_some() {
        r.push("--limit".into());
    }
    if x.sizes.is_some() {
        r.push("--sizes".into());
    }
    if x.dev_subset.is_some() {
        r.push("--dev-subset".into());
    }
    if x.allow_partial_dev || partial {
        r.push("partial dev domains (--allow-partial-dev)".into());
    }
    if args.seed != DEFAULT_SEED {
        r.push(format!("--seed {} (frozen {DEFAULT_SEED})", args.seed));
    }
    if x.lambdas
        .as_ref()
        .is_some_and(|l| l[..] != DEFAULT_LAMBDAS[..])
    {
        r.push("--lambdas differs from the frozen grid".into());
    }
    if x.learned.is_empty() {
        r.push("no --learned model".into());
    }
    for s in &x.learned {
        if matches!(s.source, ModelSource::Random { .. }) {
            r.push("random: model (smoke)".into());
        }
        if s.lambda != LambdaSel::Grid {
            r.push("a model with @λ or @meta instead of the frozen grid".into());
        }
    }
    if x.l0.is_some_and(|c| c != L0_HISTORICAL) {
        r.push("--l0 differs from experiment 1's configuration".into());
    }
    r.sort();
    r.dedup();
    r
}

/// Reasons found in the loaded data: a dev-other subset that is not exactly
/// 600 utterances, and a train DF table that does not match preparation's
/// (`mismatch`, fatal in production) or cannot be compared (`absent`).
pub fn data_ineligibility(data: &Data, df_sources: &Value) -> Vec<String> {
    let mut r = Vec::new();
    if let Some(s) = data.sets.iter().find(|s| s.name == DEV_OTHER_NAME)
        && s.utts.len() != DEV_OTHER_SIZE
    {
        r.push(format!(
            "{DEV_OTHER_NAME} has {} utterances, not {DEV_OTHER_SIZE}",
            s.utts.len()
        ));
    }
    for (set, info) in df_sources.as_object().into_iter().flatten() {
        match info["prep_index"]["status"].as_str() {
            Some("match") | None => {}
            Some("mismatch") => r.push(format!(
                "{set}: train DF table mismatch with the prep index ({} vs {})",
                info["prep_index"]["eval_table_sha256"], info["prep_index"]["df_source_sha256"]
            )),
            Some(other) => r.push(format!(
                "{set}: prep index {other}: {}",
                info["prep_index"]["detail"]
            )),
        }
    }
    r
}

/// Whether a run is a smoke or diagnostic run (results never used, parity
/// failures allowed to continue): any reduced or synthetic specification.
fn is_smoke(x: &Exp2Args, args: &Args, partial: bool) -> bool {
    args.limit.is_some()
        || x.sizes.is_some()
        || x.dev_subset.is_some()
        || x.allow_partial_dev
        || partial
        || args.seed != DEFAULT_SEED
        || x.learned
            .iter()
            .any(|s| matches!(s.source, ModelSource::Random { .. }))
}

/// Failures of the L0-historical parity checks recorded in `parity`:
/// differing re-decodes, a configuration different from experiment 1's, and
/// any expected experiment 1 row missing or not identical.
pub fn parity_failures(parity: &Value) -> Vec<String> {
    let mut f = Vec::new();
    for k in [
        "decode_scored_vs_decode",
        "decode_projected_scored_vs_16_thread_decode_projected",
    ] {
        if parity[k]["differing_texts"].as_u64().is_some_and(|n| n > 0) {
            f.push(format!(
                "{k}: {} differing texts",
                parity[k]["differing_texts"]
            ));
        }
    }
    let compared = parity.get("exp1_best_config_equals_l0").is_some();
    if compared && parity["exp1_best_config_equals_l0"] != json!(true) {
        f.push("L0 configuration differs from experiment 1's best".into());
    }
    for k in ["decode_scored_vs_decode"] {
        if parity.get(k).is_some() && parity[k]["utterances_compared"].as_u64() == Some(0) {
            f.push(format!("{k}: nothing compared"));
        }
    }
    for k in ["baseline_vs_exp1", "l0_historical_vs_exp1"] {
        // Comparing with experiment 1 needs both labels, non-empty and
        // identical (fail closed).
        if !compared {
            continue;
        }
        let Some(rows) = parity[k]["rows"].as_array() else {
            f.push(format!("{k}: missing"));
            continue;
        };
        if rows.is_empty() {
            f.push(format!(
                "{k}: no experiment 1 set was evaluated (empty check)"
            ));
        }
        if parity[k]["all_identical"] != json!(true) && !rows.is_empty() {
            f.push(format!("{k}: not all identical"));
        }
        for r in rows {
            if r["identical"] != json!(true) {
                f.push(format!(
                    "{k}: {} size {} {}",
                    r["set"].as_str().unwrap_or("?"),
                    r["size"],
                    if r["missing"] == json!(true) {
                        "has no experiment 1 row (incomplete coverage)".to_owned()
                    } else {
                        format!("differs in {}", r["differing"])
                    }
                ));
            }
        }
    }
    f
}

/// Experiment 1's oracle cases against this run's baseline, per case: for
/// every evaluated set of [`EXP1_ORACLE_SETS`], the cases `(utterance id,
/// word) -> missed occurrences` of `exp1_cases` must equal this baseline's
/// (`super::oracle_cases`): no missing case, no extra case, no different
/// count. `ours`: per set name, this baseline's cases.
pub fn oracle_case_failures(
    exp1_cases: &[Value],
    ours: &BTreeMap<String, BTreeMap<(String, String), usize>>,
) -> Vec<String> {
    let mut theirs: BTreeMap<String, BTreeMap<(String, String), usize>> = BTreeMap::new();
    for v in exp1_cases {
        let set = v["set"].as_str().unwrap_or("").to_owned();
        if !ours.contains_key(&set) {
            continue;
        }
        let key = (
            v["id"].as_str().unwrap_or("").to_owned(),
            v["word"].as_str().unwrap_or("").to_owned(),
        );
        let missed = v["missed_occurrences"].as_u64().unwrap_or(0) as usize;
        if theirs
            .entry(set.clone())
            .or_default()
            .insert(key.clone(), missed)
            .is_some()
        {
            return vec![format!(
                "{set}: experiment 1 oracle case {key:?} is duplicated"
            )];
        }
    }
    let mut f = Vec::new();
    for (set, mine) in ours {
        let empty = BTreeMap::new();
        let exp1 = theirs.get(set).unwrap_or(&empty);
        let missing: Vec<_> = exp1.keys().filter(|k| !mine.contains_key(*k)).collect();
        let extra: Vec<_> = mine.keys().filter(|k| !exp1.contains_key(*k)).collect();
        let differing: Vec<_> = exp1
            .iter()
            .filter(|(k, n)| mine.get(*k).is_some_and(|m| m != *n))
            .map(|(k, _)| k)
            .collect();
        if exp1.is_empty() {
            f.push(format!("{set}: no experiment 1 oracle cases (incomplete)"));
        }
        for (what, list) in [
            ("experiment 1 cases this baseline does not miss", &missing),
            ("baseline misses absent from experiment 1's cases", &extra),
            ("cases with a different missed count", &differing),
        ] {
            if !list.is_empty() {
                f.push(format!(
                    "{set}: {} {what}, e.g. {:?}",
                    list.len(),
                    &list[..list.len().min(3)]
                ));
            }
        }
    }
    f
}

/// The count fields of two `metrics` objects that differ (rates compared by
/// words and S/D/I, ignoring derived percentages and timings).
pub fn count_differences(ours: &Value, theirs: &Value) -> Vec<&'static str> {
    let strip = |v: &Value| {
        let mut v = v.clone();
        if let Some(o) = v.as_object_mut() {
            o.remove("percent");
        }
        v
    };
    [
        "utterances",
        "wer",
        "b_wer",
        "u_wer",
        "b_matched",
        "false_alarms",
        "fixed",
        "broken",
    ]
    .into_iter()
    .filter(|f| strip(&ours[*f]) != strip(&theirs[*f]))
    .collect()
}

/// Re-decoded rows against experiment 2's results.json (`expected`), for
/// each of `ids` (DESIGN-3, finding 7). `current`: row id -> (set, size) ->
/// metrics; `loaded`: the sets this run loaded.
///
/// The comparison scope of a row is every set experiment 2 evaluated for it
/// that this run also loads, or exactly `scope` when given (each scope set
/// must then be both loaded and in experiment 2's results). Within the
/// scope every expected (set, size) cell must be present here with
/// identical counts, and every cell here must be expected. A failure: the
/// row missing here or there, a scope set missing, an expected cell absent
/// here, an extra cell here, any differing count, or an empty scope. Sets
/// outside the scope (e.g. Earnings-21) are listed as skipped. Returns a
/// report and the failures.
pub fn expect_row_failures(
    expected: &Value,
    ids: &[String],
    current: &BTreeMap<String, BTreeMap<(String, u64), Value>>,
    loaded: &BTreeSet<String>,
    scope: Option<&BTreeSet<String>>,
) -> (Value, Vec<String>) {
    let mut failures = Vec::new();
    let mut report = Vec::new();
    for id in ids {
        let theirs: BTreeMap<(String, u64), &Value> = expected["rows"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|e| e["row"].as_str() == Some(id))
            .filter_map(|e| {
                Some((
                    (e["set"].as_str()?.to_owned(), e["size"].as_u64()?),
                    &e["metrics"],
                ))
            })
            .collect();
        let their_sets: BTreeSet<String> = theirs.keys().map(|(s, _)| s.clone()).collect();
        let Some(ours) = current.get(id) else {
            failures.push(format!("{id}: not decoded in this run"));
            continue;
        };
        if theirs.is_empty() {
            failures.push(format!("{id}: not in experiment 2's results"));
            continue;
        }
        let in_scope: BTreeSet<String> = match scope {
            Some(s) => {
                for set in s {
                    if !their_sets.contains(set) {
                        failures.push(format!(
                            "{id}: scope set {set} not in experiment 2's results"
                        ));
                    }
                    if !loaded.contains(set) {
                        failures.push(format!("{id}: scope set {set} not loaded in this run"));
                    }
                }
                s.clone()
            }
            None => their_sets.intersection(loaded).cloned().collect(),
        };
        let mut compared = 0;
        // Every expected cell in scope must be here, identical.
        for ((set, size), t) in &theirs {
            if !in_scope.contains(set) {
                continue;
            }
            match ours.get(&(set.clone(), *size)) {
                None => failures.push(format!(
                    "{id}: {set} size {size} was evaluated by experiment 2 but not here"
                )),
                Some(m) => {
                    let d = count_differences(m, t);
                    if !d.is_empty() {
                        failures.push(format!("{id}: {set} size {size} differs in {d:?}"));
                    }
                    compared += 1;
                }
            }
        }
        // Every cell here in scope must be expected.
        for (set, size) in ours.keys() {
            if in_scope.contains(set) && !theirs.contains_key(&(set.clone(), *size)) {
                failures.push(format!("{id}: {set} size {size} has no experiment 2 entry"));
            }
        }
        if compared == 0 {
            failures.push(format!("{id}: nothing compared (empty scope)"));
        }
        let skipped: BTreeSet<&String> = ours
            .keys()
            .map(|(s, _)| s)
            .filter(|s| !in_scope.contains(*s))
            .collect();
        report.push(
            json!({"row": id, "compared": compared, "scope": in_scope, "skipped_sets": skipped}),
        );
    }
    let scope_json = match scope {
        Some(s) => json!({"explicit": true, "sets": s}),
        None => {
            json!({"explicit": false, "sets": "every set experiment 2 evaluated that this run loads"})
        }
    };
    (
        json!({"scope": scope_json, "rows": report, "failures": failures.clone()}),
        failures,
    )
}

/// The row id of the baseline fallback (λ = 0).
pub const BASELINE_ROW: &str = "baseline@0";

/// λ's literal: the shortest decimal that reads back as the same f32, so the
/// frozen grid gives exactly `0.5`, `0.71`, `1`, `1.41` and `2`.
pub fn lambda_literal(l: f32) -> String {
    format!("{l}")
}

/// λ as written in results.json: the literal's value (0.71, not the f32's
/// expansion 0.7099999785…).
pub fn lambda_number(l: f32) -> f64 {
    lambda_literal(l).parse().expect("a float literal parses")
}

/// The one stored identifier of a learned row: `<model id>@<λ literal>`.
pub fn row_id(model: &str, l: f32) -> String {
    format!("{model}@{}", lambda_literal(l))
}

/// `spec.models[].{id, rows, lambdas}` must equal the learned rows actually
/// written (`learned[].id` and its non-fallback `by_lambda[].{row, lambda}`),
/// in order; checked before results.json is written.
pub fn check_spec_rows(spec: &Value, learned: &[Value]) -> Result<(), String> {
    let models = spec["models"].as_array().cloned().unwrap_or_default();
    if models.len() != learned.len() {
        return Err("spec.models and learned differ in length".into());
    }
    for (s, l) in models.iter().zip(learned) {
        let rows: Vec<&Value> = l["by_lambda"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|b| b["fallback"] != json!(true))
            .collect();
        let (ids, lambdas): (Vec<Value>, Vec<Value>) = rows
            .iter()
            .map(|b| (b["row"].clone(), b["lambda"].clone()))
            .unzip();
        if s["id"] != l["id"]
            || s["rows"] != Value::Array(ids)
            || s["lambdas"] != Value::Array(lambdas)
        {
            return Err(format!(
                "spec.models entry {} disagrees with its learned rows",
                s["id"]
            ));
        }
    }
    Ok(())
}

/// One selectable row: id, model id, λ, dev objective.
pub type Candidate = (String, String, f64, f64);

/// The selected row: the lowest dev objective among the learned rows, with
/// the baseline ([`BASELINE_ROW`], model "baseline", λ = 0) as the fallback;
/// ties go to the baseline.
pub fn select(baseline: f64, learned: &[Candidate]) -> Candidate {
    let mut best = (
        BASELINE_ROW.to_owned(),
        "baseline".to_owned(),
        0.0,
        baseline,
    );
    for c in learned {
        if c.3 < best.3 {
            best = c.clone();
        }
    }
    best
}

// ---------------------------------------------------------------- results.json

/// A model's source as written: its path, or `random_label` for random weights.
fn model_source(src: &ModelSource, random_label: &str) -> String {
    match src {
        ModelSource::File(p) => p.display().to_string(),
        ModelSource::Random { .. } => random_label.to_owned(),
    }
}

/// One learned row's objective, for [`learned_entry`].
pub struct LearnedRow {
    pub row: String,
    pub lambda: f32,
    pub objective: Result<Option<f64>, String>,
}

/// `learned[i]`: the model, the baseline fallback (λ = 0, [`BASELINE_ROW`])
/// first, then each row; `extra`'s keys (timings, costs) are added.
#[allow(clippy::too_many_arguments)]
pub fn learned_entry(
    id: &str,
    model: &str,
    variant: Variant,
    parameters: usize,
    model_lambda: f32,
    baseline: Option<f64>,
    rows: &[LearnedRow],
    extra: Value,
) -> Value {
    let mut by_lambda = vec![json!({
        "lambda": 0.0, "row": BASELINE_ROW, "dev_objective": baseline,
        "dev_objective_error": null, "fallback": true,
    })];
    by_lambda.extend(rows.iter().map(|r| {
        json!({"lambda": lambda_number(r.lambda), "row": r.row,
               "dev_objective": r.objective.clone().ok().flatten(),
               "dev_objective_error": r.objective.clone().err(), "fallback": false})
    }));
    let mut v = json!({
        "id": id, "model": model, "label": id, "variant": variant.name(),
        "parameters": parameters, "model_lambda": lambda_number(model_lambda),
        "by_lambda": by_lambda,
    });
    if let Value::Object(e) = extra {
        for (k, x) in e {
            v[k] = x;
        }
    }
    v
}

/// The `prep_index` record of a train DF table: `status` (`match`,
/// `mismatch`, `absent`), the eval table's hash always, and the index's when
/// it has one.
pub fn prep_status(index: &Result<Value, String>, dataset: &str, eval_sha: &str) -> Value {
    match index {
        Err(e) => json!({"status": "absent", "detail": e, "eval_table_sha256": eval_sha}),
        Ok(index) => match prep_df_sha(index, dataset) {
            None => json!({"status": "absent", "eval_table_sha256": eval_sha,
                           "detail": format!("no train policy for {dataset} in the index")}),
            Some(p) => json!({
                "status": if p == eval_sha { "match" } else { "mismatch" },
                "df_source_sha256": p,
                "eval_table_sha256": eval_sha,
            }),
        },
    }
}

/// One loaded dev set, for `spec.domains`.
pub struct SpecDomain {
    pub name: String,
    pub sizes: Vec<usize>,
    pub utterances: usize,
    pub groups: usize,
}

/// One model, for `spec.models`.
pub struct SpecModel {
    pub id: String,
    pub variant: Variant,
    pub source: String,
    pub lambdas: Vec<f32>,
}

/// Everything `spec` records.
pub struct SpecParts {
    pub sets: SetSel,
    pub domains: Vec<SpecDomain>,
    pub limit: Option<usize>,
    pub sizes_flag: Option<Vec<usize>>,
    pub dev_subset: Option<usize>,
    pub dev_subset_flag: Option<usize>,
    pub allow_partial_dev: bool,
    pub seed: u64,
    pub lambdas: Vec<f32>,
    pub models: Vec<SpecModel>,
    /// The loaded dev-other identity (`load_libri_dev`), or null.
    pub dev_other: Value,
}

/// `spec`: the run's full specification (CONTRACT-2 NOTES, "results.json
/// validation fields (R1)").
pub fn spec_json(p: &SpecParts) -> Value {
    let mut dev_other = p.dev_other.clone();
    if dev_other.is_object() {
        dev_other["frozen_manifest_sha256"] = json!(DEV_OTHER_MANIFEST_SHA256);
        dev_other["frozen_ids_sha256"] = json!(DEV_OTHER_IDS_SHA256);
    }
    json!({
        "sets": p.sets.name(),
        "frozen_domains": DEV_DOMAINS,
        "domains": p.domains.iter().map(|d| json!({
            "name": d.name, "sizes": d.sizes, "utterances": d.utterances, "groups": d.groups,
        })).collect::<Vec<_>>(),
        "limit": p.limit,
        "sizes_flag": p.sizes_flag,
        "dev_subset": p.dev_subset,
        "dev_subset_flag": p.dev_subset_flag,
        "dev_other": dev_other,
        "allow_partial_dev": p.allow_partial_dev,
        "seed": p.seed,
        "lambdas": p.lambdas.iter().map(|l| lambda_number(*l)).collect::<Vec<_>>(),
        "models": p.models.iter().map(|m| json!({
            "id": m.id, "variant": m.variant.name(), "source": m.source,
            "lambdas": m.lambdas.iter().map(|l| lambda_number(*l)).collect::<Vec<_>>(),
            "rows": m.lambdas.iter().map(|l| row_id(&m.id, *l)).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

/// The parts of results.json; [`results_json`] adds the selection.
pub struct ResultsParts {
    pub ineligible: Vec<String>,
    pub spec: Value,
    pub partial: bool,
    pub df_source: Value,
    pub parity_failures: Vec<String>,
    pub baseline_dev_objective: Option<f64>,
    pub learned: Vec<Value>,
    /// Every other key (sets, rows, parity, costs, ...).
    pub rest: serde_json::Map<String, Value>,
}

/// results.json: the parts, plus `format`, `eligible_for_selection`, and the
/// selection over every learned row and the baseline fallback
/// (`dev_objective`, `dev_objective_row`, `dev_objectives_learned`). Checks
/// `spec.models` against `learned` first.
pub fn results_json(p: ResultsParts) -> Result<Value, String> {
    check_spec_rows(&p.spec, &p.learned)?;
    // Every key is the stored row id (`<model id>@<λ literal>`).
    let learned_objs: Vec<Candidate> = p
        .learned
        .iter()
        .flat_map(|m| {
            let id = m["id"].as_str().unwrap_or("").to_owned();
            m["by_lambda"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|b| b["fallback"] != json!(true))
                .filter_map(move |b| {
                    Some((
                        b["row"].as_str()?.to_owned(),
                        id.clone(),
                        b["lambda"].as_f64()?,
                        b["dev_objective"].as_f64()?,
                    ))
                })
        })
        .collect();
    let dev_best = p.baseline_dev_objective.map(|b| select(b, &learned_objs));
    let mut by_row: serde_json::Map<String, Value> = learned_objs
        .iter()
        .map(|(row, _, _, o)| (row.clone(), json!(o)))
        .collect();
    if let Some(b) = p.baseline_dev_objective {
        by_row.insert(BASELINE_ROW.into(), json!(b));
    }
    let mut out = serde_json::Map::new();
    let mut put = |k: &str, v: Value| out.insert(k.to_owned(), v);
    put("format", json!("lf-bias-eval experiment 2 v2"));
    put("eligible_for_selection", json!(p.ineligible.is_empty()));
    put("ineligible_reasons", json!(p.ineligible));
    put("spec", p.spec);
    put("partial", json!(p.partial));
    put("df_source", p.df_source);
    put("parity_failures", json!(p.parity_failures));
    put("learned", json!(p.learned));
    put("dev_objective", json!(dev_best.as_ref().map(|b| b.3)));
    put(
        "dev_objective_row",
        json!(dev_best.as_ref().map(|b| json!({
            "row": b.0, "model": b.1, "lambda": b.2, "fallback": b.0 == BASELINE_ROW,
        }))),
    );
    put("baseline_dev_objective", json!(p.baseline_dev_objective));
    put("dev_objectives_learned", Value::Object(by_row));
    for (k, v) in p.rest {
        if out.insert(k.clone(), v).is_some() {
            return Err(format!("results.json: key {k} given twice"));
        }
    }
    Ok(Value::Object(out))
}

pub fn run(args: &Args) -> Result<(), String> {
    let x = args.exp2.as_ref().unwrap();
    let sel = x.sets.unwrap();
    let out = args.out.clone().unwrap();
    outpath::check_output_dir(&out)?;
    outpath::check_output_dir(&x.group_cache()?)?;
    let t_all = Instant::now();
    // The frozen dev-other manifest, before any encoding.
    if let Some(m) = &x.libri_dev
        && sel.includes(Role::Tune)
    {
        check_dev_other_manifest(m)?;
    }
    // Model files first, so a bad file fails before any encoding.
    let models: Vec<(LearnedModel, String, &LearnedSpec)> = x
        .learned
        .iter()
        .map(|s| load_model(s).map(|(m, l)| (m, l, s)))
        .collect::<Result<_, _>>()?;
    let model_lambdas = |m: &LearnedModel, spec: &LearnedSpec| match spec.lambda {
        LambdaSel::Grid => x.lambdas(),
        LambdaSel::Meta => vec![m.lambda()],
        LambdaSel::Fixed(l) => vec![l],
    };
    check_model_ids(
        &models
            .iter()
            .map(|(m, id, s)| (id.clone(), &s.source, model_lambdas(m, s)))
            .collect::<Vec<_>>(),
    )?;
    let (model, mut tr, identity) = super::open_models(args)?;
    let t_data = Instant::now();
    let strict = !is_smoke(x, args, false);
    let (data, lists_info, df_sources) = load(args, x, &mut tr, &identity, &out, strict)?;
    let data_s = t_data.elapsed().as_secs_f64();
    let present: Vec<&str> = data
        .sets
        .iter()
        .filter(|s| s.role == Role::Tune)
        .map(|s| s.name.as_str())
        .collect();
    // `load` refused missing domains unless --allow-partial-dev.
    let partial = sel.includes(Role::Tune) && check_dev_domains(&present, true)?;
    let smoke = is_smoke(x, args, partial);
    let mut ineligible = ineligibility(x, args, partial);
    let data_reasons = data_ineligibility(&data, &df_sources);
    if let Some(m) = data_reasons.iter().find(|r| r.contains("mismatch"))
        && !smoke
    {
        return Err(format!("aborting: {m}"));
    }
    ineligible.extend(data_reasons);
    for n in &data.notes {
        eprintln!("{n}");
    }
    let (cache, skipped) = phrase_cache(&model.tokenizer, &data.groups, args.threads);
    eprintln!(
        "phrase cache: {} entries ({skipped} not encodable)",
        cache.len()
    );
    let engine = Engine {
        decoder: &model.decoder,
        tokenizer: &model.tokenizer,
        cache: &cache,
        workers: args.threads,
        per_worker: 1,
    };

    // Baseline on every utterance of the selected sets.
    let t_base = Instant::now();
    let needed: Vec<usize> = data
        .sets
        .iter()
        .flat_map(|s| s.utts.iter().copied())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let mut decoded_base: Vec<Option<Decoded>> = (0..data.utts.len()).map(|_| None).collect();
    for (i, d) in needed
        .iter()
        .zip(engine.decode_set(&data, &needed, 0, None)?)
    {
        decoded_base[*i] = Some(d);
    }
    let base = Baseline {
        decoded: decoded_base,
    };
    let base_s = t_base.elapsed().as_secs_f64();
    eprintln!("baseline: {} utterances in {base_s:.1} s", needed.len());

    let cases = match &x.exp1_oracle {
        Some(p) => fixed_cases(p, &data)?,
        None => HashMap::new(),
    };
    let cx = Ctx {
        data: &data,
        base: &base,
        cases: &cases,
        keep_texts: x.hyps,
        per_session: x.per_session,
    };
    let mut rows: Vec<RowSet> = Vec::new();
    let mut baseline_row = RowSet::new("baseline", Value::Null);
    for (si, s) in data.sets.iter().enumerate() {
        for &size in &s.sizes {
            let d: Vec<Decoded> = s.utts.iter().map(|&i| base.get(i).clone()).collect();
            baseline_row.add(&cx, si, size, &d)?;
        }
    }
    rows.push(baseline_row);

    // L0-historical (and its parity checks).
    let t_l0 = Instant::now();
    let l0 = x.l0.unwrap_or(L0_HISTORICAL);
    if !x.no_l0 {
        rows.push(fixed_row(&engine, &cx, "L0-historical", &l0)?);
    }
    let mut parity = serde_json::Map::new();
    if x.l0_parity {
        let mut checks = Vec::new();
        let mut differing = 0;
        let mut compared = 0;
        for s in &data.sets {
            for &size in &s.sizes {
                let scored = decode_set_graph_scored(&engine, &data, &s.utts, size, &l0)?;
                let plain = engine.decode_set(&data, &s.utts, size, Some(&l0))?;
                let n = scored
                    .iter()
                    .zip(&plain)
                    .filter(|(a, b)| a.text != b.text)
                    .count();
                differing += n;
                compared += plain.len();
                checks.push(json!({"set": s.name, "size": SIZES[size], "utterances": plain.len(), "differing_texts": n}));
            }
        }
        parity.insert(
            "decode_scored_vs_decode".into(),
            json!({"description": "L0-historical through decode_scored (graph bonuses as the scorer) against decode with the graph, 1-thread pools",
                   "utterances_compared": compared, "differing_texts": differing, "per_set": checks}),
        );
        // The daemon path: Transcriber::decode_projected_scored on a sample.
        let one = ThreadPool::new(&[0]);
        let mut daemon_mismatch = 0;
        let mut daemon_checked = 0;
        for s in &data.sets {
            let size = s.sizes[0];
            for &i in s.utts.iter().step_by(23) {
                let u = &data.utts[i];
                let grp = &data.groups[u.group];
                if let Some(g) = build_graph(&grp.lists[size], &cache, &l0, grp.keywords)? {
                    let a = tr
                        .decode_projected_scored(&one, &u.proj, u.frames, &g, &GraphBonusScorer(&g))
                        .map_err(|e| e.to_string())?;
                    let b = tr
                        .decode_projected(&u.proj, u.frames, Some(&g))
                        .map_err(|e| e.to_string())?;
                    daemon_mismatch += usize::from(a.text != b.text);
                    daemon_checked += 1;
                }
            }
        }
        parity.insert(
            "decode_projected_scored_vs_16_thread_decode_projected".into(),
            json!({"checked": daemon_checked, "differing_texts": daemon_mismatch}),
        );
    }
    if let Some(p) = &x.exp1_results {
        let exp1: Value =
            serde_json::from_str(&read_text(p)?).map_err(|e| format!("{}: {e}", p.display()))?;
        let cfg_same = exp1["best"] == l0.json();
        parity.insert("exp1_best_config_equals_l0".into(), json!(cfg_same));
        parity.insert(
            "baseline_vs_exp1".into(),
            exp1_parity(&exp1, "baseline", &rows[0], &data),
        );
        if let Some(l0_row) = rows.iter().find(|r| r.label == "L0-historical") {
            parity.insert(
                "l0_historical_vs_exp1".into(),
                exp1_parity(&exp1, "best", l0_row, &data),
            );
        }
    }
    let l0_s = t_l0.elapsed().as_secs_f64();
    // A failed parity (re-decode, configuration, counts or coverage) aborts
    // a production run; smoke runs continue, already ineligible.
    let mut parity_failed = parity_failures(&Value::Object(parity.clone()));
    // The fixed oracle denominator is experiment 1's cases: they must be
    // exactly this baseline's misses, case by case.
    if let Some(p) = &x.exp1_oracle {
        let exp1_cases: Vec<Value> = read_text(p)?
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).map_err(|e| format!("{}: {e}", p.display())))
            .collect::<Result<_, _>>()?;
        let mut ours: BTreeMap<String, BTreeMap<(String, String), usize>> = BTreeMap::new();
        for (si, s) in data.sets.iter().enumerate() {
            if !EXP1_ORACLE_SETS.contains(&s.name.as_str()) {
                continue;
            }
            let m = ours.entry(s.name.clone()).or_default();
            for c in super::oracle_cases(&data, &base, si) {
                m.insert((data.utts[c.utt].id.clone(), c.word.clone()), c.missed);
            }
        }
        let f = oracle_case_failures(&exp1_cases, &ours);
        parity.insert(
            "oracle_cases_vs_exp1".into(),
            json!({"sets": ours.keys().collect::<Vec<_>>(),
                   "cases": ours.values().map(BTreeMap::len).sum::<usize>(), "failures": f}),
        );
        parity_failed.extend(f);
    }
    if !parity_failed.is_empty() {
        if !smoke {
            return Err(format!(
                "L0-historical parity failed; aborting: {}",
                parity_failed.join("; ")
            ));
        }
        eprintln!(
            "L0-historical parity failed (smoke run, continuing): {}",
            parity_failed.join("; ")
        );
    }

    // L0-retuned: experiment 1's search on the dev objective.
    let mut retune = Value::Null;
    if x.l0_retune {
        let t = Instant::now();
        let mut sw = Sweeper {
            engine: &engine,
            data: &data,
            base: &base,
            memo: HashMap::new(),
            rows: Vec::new(),
            runs: 0,
            decode_s: 0.0,
            dev_objective: true,
        };
        let search = staged_search(&mut sw)?;
        eprintln!(
            "L0 retune: {} runs, best {} ({:.4})",
            sw.runs,
            search.best.label(),
            search.best_obj
        );
        retune = json!({"best": search.best.json(), "dev_objective": search.best_obj, "runs": sw.runs,
                        "stages": search.stages, "sweep_rows": sw.rows, "seconds": t.elapsed().as_secs_f64()});
        rows.push(fixed_row(&engine, &cx, "L0-retuned", &search.best)?);
    }
    // Fixed-bonus rows decoded as given (`--l0-row`), never searched.
    for (label, cfg) in &x.l0_rows {
        rows.push(fixed_row(&engine, &cx, label, cfg)?);
    }

    // Learned models.
    let mut learned_json = Vec::new();
    let t_learned = Instant::now();
    // The baseline's objective (1 by construction); undefined (e.g. a dev
    // set without baseline errors) is fatal except in smoke runs.
    let baseline_obj = match rows[0].objective(&data, &base).transpose() {
        Ok(o) => o,
        Err(e) if smoke => {
            eprintln!("baseline dev objective undefined (smoke run): {e}");
            None
        }
        Err(e) => return Err(e),
    };
    for (m, label, spec) in &models {
        let lambdas = model_lambdas(m, spec);
        let stats = ScorerStats::default();
        let passes: NodePasses = Mutex::new(Vec::new());
        let mut lam_rows: Vec<RowSet> = lambdas
            .iter()
            .map(|l| {
                RowSet::new(
                    &row_id(label, *l),
                    json!({"model": label, "variant": m.variant().name(), "lambda": lambda_number(*l)}),
                )
            })
            .collect();
        let t = Instant::now();
        for (si, s) in data.sets.iter().enumerate() {
            for &size in &s.sizes {
                let per_lambda = decode_set_learned(
                    &engine, &data, &s.utts, size, m, &lambdas, &stats, &passes,
                )?;
                for (row, d) in lam_rows.iter_mut().zip(&per_lambda) {
                    row.add(&cx, si, size, d)?;
                }
            }
        }
        let secs = t.elapsed().as_secs_f64();
        let calls = stats.calls.load(Ordering::Relaxed);
        let scorer = json!({
            "calls": calls,
            "mean_candidates": stats.candidates.load(Ordering::Relaxed) as f64 / calls.max(1) as f64,
            "mean_us_per_call": stats.ns.load(Ordering::Relaxed) as f64 / 1e3 / calls.max(1) as f64,
        });
        let passes = passes.into_inner().unwrap();
        let learned_rows: Vec<LearnedRow> = lam_rows
            .iter()
            .zip(&lambdas)
            .map(|(r, l)| LearnedRow {
                row: r.label.clone(),
                lambda: *l,
                objective: r.objective(&data, &base).transpose(),
            })
            .collect();
        learned_json.push(learned_entry(
            label,
            &model_source(&spec.source, label),
            m.variant(),
            m.parameters(),
            m.lambda(),
            baseline_obj,
            &learned_rows,
            json!({"seconds": secs, "scorer": scorer, "node_pass": node_pass_summary(&passes)}),
        ));
        eprintln!("{label}: {} λ in {secs:.0} s", lambdas.len());
        rows.extend(lam_rows);
    }
    let learned_s = t_learned.elapsed().as_secs_f64();

    // Re-decoded experiment 2 rows must reproduce its per-set counts.
    if let Some((file, ids)) = &x.expect_rows {
        let expected: Value = serde_json::from_str(&read_text(file)?)
            .map_err(|e| format!("{}: {e}", file.display()))?;
        let mut current: BTreeMap<String, BTreeMap<(String, u64), Value>> = BTreeMap::new();
        for r in &rows {
            let m = current.entry(r.label.clone()).or_default();
            for ((si, z), metrics) in &r.metrics {
                m.insert(
                    (data.sets[*si].name.clone(), SIZES[*z] as u64),
                    metrics.json(),
                );
            }
        }
        let loaded: BTreeSet<String> = data.sets.iter().map(|s| s.name.clone()).collect();
        let (report, failures) =
            expect_row_failures(&expected, ids, &current, &loaded, x.expect_scope.as_ref());
        parity.insert("exp2_rows".into(), report);
        if !failures.is_empty() {
            if !smoke {
                return Err(format!(
                    "re-decoded experiment 2 rows differ; aborting: {}",
                    failures.join("; ")
                ));
            }
            eprintln!(
                "experiment 2 row parity failed (smoke run, continuing): {}",
                failures.join("; ")
            );
            parity_failed.extend(failures);
        }
    }

    // Objectives of every row.
    let objectives: Vec<Value> = rows
        .iter()
        .map(|r| {
            let o = r.objective(&data, &base).transpose();
            json!({"row": r.label, "config": r.config, "dev_objective": o.clone().ok().flatten(), "error": o.err()})
        })
        .collect();
    let best_dev = objectives
        .iter()
        .filter_map(|o| Some((o["row"].as_str()?, o["dev_objective"].as_f64()?)))
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(r, o)| json!({"row": r, "dev_objective": o}));
    // Costs.
    let mut costs = Value::Null;
    if x.costs {
        let joint = joint_ns(&engine, &data);
        let mut per_model = Vec::new();
        for ((m, label, _), lj) in models.iter().zip(&learned_json) {
            let us = lj["scorer"]["mean_us_per_call"]
                .as_f64()
                .unwrap_or(f64::NAN);
            per_model.push(json!({
                "label": label, "variant": m.variant().name(), "parameters": m.parameters(),
                "scorer_us_per_decision": us, "joint_us_per_decision": joint / 1e3,
                "scorer_over_joint": us * 1e3 / joint,
                "mean_candidates": lj["scorer"]["mean_candidates"],
                "node_pass": lj["node_pass"],
                "cold": cold_latency(&engine, &data, m, x.lambdas()[0], args.threads)?,
            }));
        }
        costs = json!({"joint_ns_per_decision_1_thread": joint, "models": per_model});
    }

    let total_s = t_all.elapsed().as_secs_f64();
    let sets_json: Vec<Value> = data
        .sets
        .iter()
        .map(|s| {
            let groups: BTreeSet<usize> = s.utts.iter().map(|&i| data.utts[i].group).collect();
            json!({"name": s.name, "role": role_name(s.role), "utterances": s.utts.len(), "groups": groups.len(),
                   "sizes": s.sizes.iter().map(|&z| SIZES[z]).collect::<Vec<_>>(),
                   "b_words": s.utts.iter().map(|&i| data.utts[i].ref_words.iter().filter(|w| data.utts[i].biasing.contains(*w)).count()).sum::<usize>(),
                   "words": s.utts.iter().map(|&i| data.utts[i].ref_words.len()).sum::<usize>()})
        })
        .collect();
    ineligible.sort();
    ineligible.dedup();
    if !parity_failed.is_empty() {
        ineligible.push("L0-historical parity failed".into());
    }
    let spec = spec_json(&SpecParts {
        sets: sel,
        domains: data
            .sets
            .iter()
            .filter(|s| s.role == Role::Tune)
            .map(|s| {
                let groups: BTreeSet<usize> = s.utts.iter().map(|&i| data.utts[i].group).collect();
                SpecDomain {
                    name: s.name.clone(),
                    sizes: s.sizes.iter().map(|&z| SIZES[z]).collect(),
                    utterances: s.utts.len(),
                    groups: groups.len(),
                }
            })
            .collect(),
        limit: args.limit,
        sizes_flag: x.sizes.clone(),
        dev_subset: data
            .sets
            .iter()
            .find(|s| s.name == DEV_OTHER_NAME)
            .map(|s| s.utts.len()),
        dev_subset_flag: x.dev_subset,
        allow_partial_dev: x.allow_partial_dev,
        seed: args.seed,
        lambdas: x.lambdas(),
        models: models
            .iter()
            .map(|(m, id, s)| SpecModel {
                id: id.clone(),
                variant: m.variant(),
                source: model_source(&s.source, "random"),
                lambdas: model_lambdas(m, s),
            })
            .collect(),
        dev_other: data.lists_info["dev_other"].clone(),
    });
    let mut rest = json!({
        "sets_selected": sel.name(),
        "precision": "i8x2",
        "decoder_storage": "F16",
        "pools": "1 thread per worker",
        "workers": args.threads,
        "seed": args.seed,
        "limit": args.limit,
        "cache_identity": identity.shared().hash(),
        "dev_domains_frozen": DEV_DOMAINS,
        "dev_domains_present": data.sets.iter().filter(|s| s.role == Role::Tune).map(|s| s.name.clone()).collect::<Vec<_>>(),
        "notes": data.notes,
        "sets": sets_json,
        "lists": lists_info,
        "phrase_cache": {"entries": cache.len(), "not_encodable": skipped},
        "l0_historical": l0.json(),
        "l0_retuned": retune,
        "parity": Value::Object(parity),
        "objectives": objectives,
        "best_dev": best_dev,
        "rows": rows.iter().flat_map(|r| r.entries.iter().cloned()).collect::<Vec<_>>(),
        "costs": costs,
        "runtime_s": {"total": total_s, "data": data_s, "baseline": base_s, "l0": l0_s, "learned": learned_s},
    });
    let results = results_json(ResultsParts {
        ineligible,
        spec,
        partial,
        df_source: df_sources,
        parity_failures: parity_failed,
        baseline_dev_objective: baseline_obj,
        learned: learned_json,
        rest: std::mem::take(rest.as_object_mut().expect("an object")),
    })?;
    let write = |name: &str, text: String| outpath::write_output(&out.join(name), text.as_bytes());
    write(
        "results.json",
        serde_json::to_string_pretty(&results).unwrap(),
    )?;
    write("summary.md", summary(&results))?;
    if x.per_session {
        let mut lines = String::new();
        for r in &rows {
            for l in &r.sessions {
                lines.push_str(&l.to_string());
                lines.push('\n');
            }
        }
        write("per_session.jsonl", lines)?;
    }
    if x.hyps {
        let mut lines = String::new();
        for (si, s) in data.sets.iter().enumerate() {
            for (pos, &i) in s.utts.iter().enumerate() {
                let mut rec =
                    json!({"set": s.name, "id": data.utts[i].id, "baseline": base.get(i).text});
                for r in rows.iter().skip(1) {
                    for &size in &s.sizes {
                        if let Some(t) = r.texts.get(&(si, size)) {
                            rec[format!("{}#{}", r.label, SIZES[size])] = json!(t[pos]);
                        }
                    }
                }
                lines.push_str(&rec.to_string());
                lines.push('\n');
            }
        }
        write("hyps.jsonl", lines)?;
    }
    eprintln!("done in {total_s:.0} s; results in {}", out.display());
    Ok(())
}

fn summary(r: &Value) -> String {
    let f = super::fmt_num;
    let mut s = String::from("# Learned biasing evaluation (lf-bias-eval, experiment 2)\n\n");
    s.push_str(&format!(
        "Sets: {}; precision {}, F16 decoder weights, 1-thread pools. Runtime: {}\n\n",
        r["sets_selected"], r["precision"], r["runtime_s"]
    ));
    for n in r["notes"].as_array().into_iter().flatten() {
        s.push_str(&format!("- {}\n", n.as_str().unwrap_or("")));
    }
    s.push_str("\n## Dev objective (mean over dev domains of mean-over-sizes errors / baseline errors; lower is better)\n\n");
    for o in r["objectives"].as_array().into_iter().flatten() {
        s.push_str(&format!(
            "- {}: {}\n",
            o["row"].as_str().unwrap_or(""),
            f(&o["dev_objective"], 4)
        ));
    }
    s.push_str(&format!(
        "\nBest: {}\n\n## Parity\n\n{}\n\n",
        r["best_dev"], r["parity"]
    ));
    s.push_str("## Rows\n\nRates in %; n/a where undefined. Oracle: recovered / fixed denominator (experiment 1's oracle-recoverable baseline misses).\n\n");
    s.push_str("| row | set | role | size | WER | B-WER | U-WER | recall | FA | fixed | broken | net errors | oracle |\n");
    s.push_str("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n");
    for e in r["rows"].as_array().into_iter().flatten() {
        let m = &e["metrics"];
        let o = &e["oracle_recovery"];
        s.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
            e["row"].as_str().unwrap_or(""),
            e["set"].as_str().unwrap_or(""),
            e["role"].as_str().unwrap_or(""),
            e["size"],
            f(&m["wer"]["percent"], 2),
            f(&m["b_wer"]["percent"], 2),
            f(&m["u_wer"]["percent"], 2),
            f(&m["recall"], 3),
            m["false_alarms"],
            m["fixed"],
            m["broken"],
            e["net_errors_vs_baseline"],
            if o.is_null() {
                "-".into()
            } else {
                format!("{}/{}", o["recovered"], o["denominator_occurrences"])
            },
        ));
    }
    s.push_str(&format!("\n## Costs\n\n{}\n", r["costs"]));
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_experiment_2_flags() {
        let a = super::super::parse_args_from(argv(
            "--export /e --cache /c --out /o --sets both --threads 8 --workers 2 \
             --libri test:/a.json:/m.jsonl:/x/test-other.biasing_ --session /x/earnings22.json:/e22.jsonl \
             --rare-words /r --common-words /w --libri-dev /d.jsonl --spgi-dev /s.jsonl \
             --gigaspeech /g.json:/g.jsonl \
             --set heldout:slidespeech_test:/ss.jsonl:lists=rare+keywords,dataset=slidespeech,cased=yes,df=/st.jsonl \
             --set dev:slidespeech_dev:/sd.jsonl:dataset=slidespeech,cased=yes,df=/st.jsonl \
             --set dev:icsi_dev:/id.jsonl:dataset=icsi,cased=no,df=/it.jsonl \
             --set dev:acl6060_dev:/ad.jsonl:dataset=acl6060,cased=yes,df=scored \
             --learned /m/L3.safetensors,/m/L1.safetensors@0.71,random:L3S:4 --lambdas 1,2 --l0-retune --costs \
             --sizes 100,1000",
        ))
        .unwrap();
        let x = a.exp2.as_ref().unwrap();
        assert_eq!(a.workers, 8, "1-thread pools");
        assert_eq!(x.sets, Some(SetSel::Both));
        assert_eq!(x.lambdas(), [1.0, 2.0]);
        assert_eq!(x.sizes, Some(vec![100, 1000]));
        assert!(!x.allow_partial_dev);
        assert_eq!(x.learned.len(), 3);
        assert_eq!(x.learned[1].lambda, LambdaSel::Fixed(0.71));
        assert_eq!(
            x.learned[2].source,
            ModelSource::Random {
                variant: Variant::L3S,
                seed: 4
            }
        );
        assert_eq!(x.generic.len(), 6);
        let spgi = &x.generic[0];
        assert_eq!(
            (spgi.name.as_str(), spgi.role, spgi.keep),
            ("spgispeech_dev", Role::Tune, Some(Keep::SpgiDev))
        );
        assert_eq!(spgi.session, SessionKey::Before("/".into()));
        assert_eq!(spgi.cache_dir, "spgispeech");
        // SPGI's DF source: the train calls of the same manifest; cased.
        assert_eq!(
            spgi.df,
            Some(DfSource::Train {
                manifests: vec!["/s.jsonl".into()],
                keep: Some(Keep::SpgiTrain)
            })
        );
        assert_eq!(spgi.casing, Some(exp2_terms::Casing::Cased));
        let giga = &x.generic[1];
        assert_eq!(giga.manifest, PathBuf::from("/g.jsonl"));
        assert_eq!(giga.session, SessionKey::Before("_S".into()));
        // GigaSpeech: no train split, lowercase references.
        assert_eq!(giga.df, Some(DfSource::Scored));
        assert_eq!(giga.casing, Some(exp2_terms::Casing::Uncased));
        assert_eq!(x.generic[4].casing, Some(exp2_terms::Casing::Uncased));
        assert_eq!(x.generic[5].df, Some(DfSource::Scored));
        let ss = &x.generic[2];
        assert_eq!(
            ss.conditions,
            [ListCondition::Rare, ListCondition::Keywords]
        );
        assert_eq!(ss.session, SessionKey::Field("session".into()));
        assert_eq!(x.l0, None);
        assert!(x.l0_retune && x.costs && !x.hyps);
    }

    #[test]
    fn rejects_bad_experiment_2_arguments() {
        let base = "--export /e --cache /c --out /o --rare-words /r --common-words /w \
                    --allow-partial-dev";
        // Every `--set` here gets the required casing and DF source.
        let with_opts = |extra: &str| {
            extra
                .split(' ')
                .map(|w| {
                    if w.matches(':').count() == 2 && !w.contains("random:") {
                        format!("{w}:dataset=icsi,cased=yes,df=/t.jsonl")
                    } else if w.matches(':').count() == 3 && w.contains('=') {
                        format!("{w},dataset=icsi,cased=yes,df=/t.jsonl")
                    } else {
                        w.to_owned()
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
        };
        let bad = |extra: &str| {
            super::super::parse_args_from(argv(&format!("{base} {}", with_opts(extra)))).is_err()
        };
        assert!(bad("--sets dev --set dev:icsi_dev:/m.jsonl --sizes 200"));
        // Casing and the DF source must be declared.
        let raw = |extra: &str| super::super::parse_args_from(argv(&format!("{base} {extra}")));
        assert!(raw("--sets dev --set dev:icsi_dev:/m.jsonl:dataset=icsi,cased=yes").is_err());
        assert!(raw("--sets dev --set dev:icsi_dev:/m.jsonl:df=/t.jsonl").is_err());
        assert!(
            raw("--sets dev --set dev:icsi_dev:/m.jsonl:dataset=icsi,cased=maybe,df=/t.jsonl")
                .is_err()
        );
        assert!(
            raw("--sets dev --set dev:acl6060_dev:/m.jsonl:dataset=acl6060,cased=no,df=scored")
                .is_ok()
        );
        assert!(
            raw("--sets dev --set dev:icsi_dev:/m.jsonl:dataset=acl6060,cased=no,df=scored,df-keep=spgi-train")
                .is_err()
        );
        // The oracle denominator needs parity.
        assert!(bad(
            "--sets heldout --set heldout:icsi_test:/m.jsonl --exp1-oracle /o.jsonl"
        ));
        // Experiment 2 flags need --sets.
        assert!(bad("--libri tune:/a:/b:/c --learned /m.safetensors"));
        // A dev set must be a frozen domain, and only with rare lists.
        assert!(bad("--sets dev --set dev:my_dev:/m.jsonl"));
        assert!(bad("--sets dev --set dev:icsi_dev:/m.jsonl:lists=keywords"));
        assert!(!bad("--sets dev --set dev:icsi_dev:/m.jsonl"));
        // The selected roles need sets.
        assert!(bad("--sets heldout --set dev:icsi_dev:/m.jsonl"));
        assert!(bad("--sets dev --set heldout:icsi_test:/m.jsonl"));
        // Retuning needs the dev sets.
        assert!(bad(
            "--sets heldout --set heldout:icsi_test:/m.jsonl --l0-retune"
        ));
        // Malformed options.
        assert!(bad("--sets dev --set dev:icsi_dev:/m.jsonl:session=x"));
        assert!(bad("--sets dev --set dev:icsi_dev:/m.jsonl:cache=../x"));
        assert!(bad("--sets dev --set nope:icsi_dev:/m.jsonl"));
        assert!(bad(
            "--sets dev --set dev:icsi_dev:/m.jsonl --set dev:icsi_dev:/n.jsonl"
        ));
        assert!(bad("--sets dev --set dev:icsi_dev:/m.jsonl --lambdas 1,-2"));
        assert!(bad(
            "--sets dev --set dev:icsi_dev:/m.jsonl --learned random:L9"
        ));
        // Generic sets need the word lists.
        assert!(
            super::super::parse_args_from(argv(
                "--export /e --cache /c --out /o --sets dev --set dev:icsi_dev:/m.jsonl:dataset=icsi,cased=yes,df=/t"
            ))
            .is_err()
        );
        let l0 = super::super::parse_args_from(argv(&format!(
            "{base} --sets dev --set dev:icsi_dev:/m.jsonl:dataset=icsi,cased=yes,df=/t --l0 0.7,2,on,off"
        )))
        .unwrap();
        assert_eq!(
            l0.exp2.unwrap().l0,
            Some(Cfg {
                alpha: 0.7,
                depth: 2.0,
                cancel: true,
                case: false
            })
        );
    }

    #[test]
    fn experiment_2_targets_are_session_specific() {
        // 40 sessions: max_df = max(floor(5% of 40), 2) = 2.
        let mut refs: Vec<(String, String)> = (0..40)
            .map(|i| (format!("s{i}"), "the report".to_owned()))
            .collect();
        refs[0].1.push_str(" zorbin quaxel 2019");
        refs[1].1.push_str(" zorbin quaxel");
        refs[2].1.push_str(" quaxel");
        let df = exp2_terms::SessionDf::from_references(
            refs.iter().map(|(s, t)| (s.as_str(), t.as_str())),
        );
        assert_eq!((df.sessions(), df.max_df()), (40, 2));
        let common: BTreeSet<String> = ["the", "report"].map(String::from).into();
        let rule = RareRule::Common {
            common: Arc::new(common),
            known: Arc::new(BTreeSet::new()),
            df: Arc::new(df),
        };
        // Scored references may be one split only; the DF is the dataset's.
        let words = rule.words_of([refs[0].1.as_str(), refs[2].1.as_str()]);
        assert_eq!(
            words,
            ["zorbin".to_owned()].into(),
            "quaxel is in 3 sessions"
        );
        assert!(rule.admits("zorbin") && !rule.admits("quaxel") && !rule.admits("2019"));
        let pool: Vec<String> = ["plinth", "quaxel", "the", "zorbin"]
            .map(String::from)
            .into();
        assert_eq!(rule.filter_pool(pool.clone()), ["plinth", "zorbin"]);
        // Experiment 1's rule is unchanged: its word list, its full pool.
        let words1: BTreeSet<String> = ["quaxel".to_owned()].into();
        let exp1 = RareRule::Words(words1.clone());
        assert_eq!(exp1.words_of(["zorbin and the rest"]), words1);
        assert_eq!(exp1.filter_pool(pool.clone()), pool);
    }

    /// A manifest line with a session and, unless `split` is empty, a split.
    fn mline(id: &str, session: &str, split: &str, text: &str) -> String {
        let split = if split.is_empty() {
            String::new()
        } else {
            format!(", \"split\": \"{split}\"")
        };
        format!(
            "{{\"id\": \"{id}\", \"session\": \"{session}\"{split}, \"audio_filepath\": \"/a\", \"text\": \"{text}\"}}\n"
        )
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("lf-exp2-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// DESIGN "DF source" (re-review #1): the DF of a dataset with a train
    /// split comes from train lines only, is frozen, and is identified.
    #[test]
    fn df_source_is_the_train_split_only() {
        let dir = scratch("df");
        let train = dir.join("train.jsonl");
        let dev = dir.join("dev.jsonl");
        let mixed = dir.join("all.jsonl");
        std::fs::write(
            &train,
            mline("t1", "m1", "train", "Zorbin here") + &mline("t2", "m1", "train", "zorbin"),
        )
        .unwrap();
        std::fs::write(&dev, mline("d1", "m2", "dev", "a zorbin")).unwrap();
        std::fs::write(
            &mixed,
            mline("t1", "m1", "train", "zorbin") + &mline("d1", "m2", "dev", "a zorbin"),
        )
        .unwrap();
        let set = |df: &str| {
            parse_set(&format!(
                "dev:icsi_dev:{}:dataset=icsi,cased=yes,df={df}",
                dev.display()
            ))
        };
        let g = set(&train.display().to_string()).unwrap();
        let rule = check_set_rules(&g).unwrap();
        let (df, info, sessions) = set_df(&g, rule).unwrap();
        assert_eq!((df.sessions(), df.df("zorbin"), df.df("a")), (1, 1, 0));
        assert_eq!(sessions, ["m1".to_owned()].into());
        assert_eq!(info["split"], "train");
        assert_eq!(info["dataset"], "icsi");
        assert_eq!(info["table_sha256"], df.sha256());
        let sha = lf_model::manifest::sha256_file(&train).unwrap();
        assert_eq!(info["manifests"][0]["sha256"], sha);
        // Frozen: a dev reference never changes the table.
        std::fs::write(&dev, mline("d1", "m2", "dev", "quaxel zorbin")).unwrap();
        assert_eq!(set_df(&g, rule).unwrap().0.sha256(), df.sha256());
        // A combined manifest given as the train DF source is refused, not
        // filtered (its dev lines are not train).
        let g = set(&mixed.display().to_string()).unwrap();
        let err = set_df(&g, rule).unwrap_err();
        assert!(err.contains("other splits"), "{err}");
        // A dataset with a train split may not use the scored split, and one
        // without may only use it.
        assert!(set("scored").is_err());
        let acl = |df: &str| {
            parse_set(&format!(
                "dev:acl6060_dev:{}:dataset=acl6060,cased=yes,df={df}",
                dev.display()
            ))
        };
        assert!(acl(&train.display().to_string()).is_err());
        let g = acl("scored").unwrap();
        let (scored, info, _) = set_df(&g, check_set_rules(&g).unwrap()).unwrap();
        assert_eq!((scored.sessions(), scored.df("quaxel")), (1, 1));
        assert_eq!(info["split"], "scored");
        // SPGI: the train calls of the one manifest, by the call hash.
        let calls: Vec<String> = (0..60).map(|i| format!("{i:032x}")).collect();
        let spgi = dir.join("spgi.jsonl");
        let text: String = calls
            .iter()
            .map(|c| mline(&format!("{c}/1.wav"), c, "", "zorbin"))
            .collect();
        std::fs::write(&spgi, text).unwrap();
        let mut x = Exp2Args::default();
        let mut v = vec![spgi.display().to_string()].into_iter();
        parse_flag(&mut x, "--spgi-dev", &mut || v.next().ok_or("x".into())).unwrap();
        let g = &x.generic[0];
        let rule = check_set_rules(g).unwrap();
        let (kept, info, _) = set_df(g, rule).unwrap();
        let train_calls = calls.iter().filter(|c| !exp2_data::spgi_is_dev(c)).count();
        assert!(train_calls < calls.len());
        assert_eq!(
            (kept.sessions(), kept.df("zorbin")),
            (train_calls, train_calls)
        );
        assert_eq!(info["keep"], "spgi-train");
        std::fs::remove_dir_all(&dir).unwrap();
        // The option: several train manifests joined by `+`.
        let p =
            parse_set("dev:icsi_dev:/d.jsonl:dataset=icsi,cased=no,df=/t.jsonl+/t2.jsonl").unwrap();
        assert_eq!(
            p.df,
            Some(DfSource::Train {
                manifests: vec!["/t.jsonl".into(), "/t2.jsonl".into()],
                keep: None
            })
        );
        assert!(parse_set("dev:icsi_dev:/d.jsonl:dataset=icsi,cased=no").is_err());
        assert!(parse_set("dev:icsi_dev:/d.jsonl:dataset=icsi,cased=no,df=/t.jsonl+").is_err());
        assert!(parse_set("dev:icsi_dev:/d.jsonl:cased=no,df=/t.jsonl").is_err());
        assert!(parse_set("dev:x_dev:/d.jsonl:dataset=nope,cased=no,df=/t.jsonl").is_err());
        // SPGI is dev only, with both hash filters; GigaSpeech held out only.
        assert!(
            parse_set(
                "heldout:s:/s:dataset=spgispeech,cased=yes,keep=spgi-dev,df=/s,df-keep=spgi-train"
            )
            .is_err()
        );
        assert!(parse_set("dev:s:/s:dataset=spgispeech,cased=yes,keep=spgi-dev,df=/s").is_err());
        assert!(parse_set("dev:g:/g:dataset=gigaspeech,cased=no,df=scored").is_err());
        assert!(parse_set("dev:i:/i:dataset=icsi,cased=no,df=/t,keep=spgi-dev").is_err());
    }

    /// Re-review #1: scored lines must all belong to the role's split (a
    /// mixed manifest is refused), and no session may hold two roles.
    #[test]
    fn split_membership_is_enforced() {
        let dir = scratch("split");
        let rule = dataset_rule("icsi").unwrap();
        let key = SessionKey::Field("session".into());
        let write = |name: &str, text: String| {
            let p = dir.join(name);
            std::fs::write(&p, text).unwrap();
            p
        };
        let dev = write(
            "dev.jsonl",
            mline("a", "m1", "dev", "x") + &mline("b", "m2", "validation", "y"),
        );
        let lines = split_lines(&dev, &key, None, rule, SplitName::Dev).unwrap();
        assert_eq!(lines.len(), 2);
        // The same manifest as held-out is wrong, never silently empty.
        assert!(split_lines(&dev, &key, None, rule, SplitName::Heldout).is_err());
        let mixed = write(
            "mixed.jsonl",
            mline("a", "m1", "dev", "x") + &mline("c", "m3", "test", "z"),
        );
        let err = split_lines(&mixed, &key, None, rule, SplitName::Dev).unwrap_err();
        assert!(err.contains("heldout"), "{err}");
        let unlabelled = write("none.jsonl", mline("a", "m1", "", "x"));
        assert!(split_lines(&unlabelled, &key, None, rule, SplitName::Dev).is_err());
        let odd = write("odd.jsonl", mline("a", "m1", "dev2", "x"));
        assert!(split_lines(&odd, &key, None, rule, SplitName::Dev).is_err());
        // GigaSpeech: the whole manifest is held out; a declared split must agree.
        let giga = dataset_rule("gigaspeech").unwrap();
        let g = write(
            "giga.jsonl",
            mline("P_S1", "P", "", "x") + &mline("Q_S1", "Q", "test", "y"),
        );
        assert_eq!(
            split_lines(&g, &key, None, giga, SplitName::Heldout)
                .unwrap()
                .len(),
            2
        );
        let g2 = write("giga2.jsonl", mline("P_S1", "P", "train", "x"));
        assert!(split_lines(&g2, &key, None, giga, SplitName::Heldout).is_err());
        // A session in two roles.
        let mut roles = BTreeMap::new();
        let s = |v: &[&str]| {
            v.iter()
                .map(|x| x.to_string())
                .collect::<BTreeSet<String>>()
        };
        record_roles(&mut roles, "icsi", &s(&["m1", "m2"]), "train").unwrap();
        record_roles(&mut roles, "icsi", &s(&["m3"]), "dev").unwrap();
        record_roles(&mut roles, "slidespeech", &s(&["m1"]), "dev").unwrap();
        let err = record_roles(&mut roles, "icsi", &s(&["m2"]), "dev").unwrap_err();
        assert!(err.contains("m2") && err.contains("train"), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Re-review #1: the train DF table is compared with preparation's.
    #[test]
    fn prep_index_tables_are_compared() {
        let index = json!({"datasets": {
            "icsi": {"splits": {"train": {"policy": {"df_source_sha256": "abc"}}}},
            "slidespeech": {"splits": {"train": {"policy": "{\"df_source_sha256\": \"def\"}"}}},
        }});
        assert_eq!(prep_df_sha(&index, "icsi").as_deref(), Some("abc"));
        assert_eq!(prep_df_sha(&index, "slidespeech").as_deref(), Some("def"));
        assert_eq!(prep_df_sha(&index, "acl6060"), None);
        let data = super::super::new_data();
        let sources = |status: Value| json!({"icsi_dev": {"prep_index": status}});
        assert!(data_ineligibility(&data, &sources(json!({"status": "match"}))).is_empty());
        let r = data_ineligibility(
            &data,
            &sources(
                json!({"status": "mismatch", "df_source_sha256": "abc", "eval_table_sha256": "x"}),
            ),
        );
        assert!(r[0].contains("mismatch"), "{r:?}");
        let r = data_ineligibility(
            &data,
            &sources(json!({"status": "absent", "detail": "no file"})),
        );
        assert!(r[0].contains("absent"), "{r:?}");
        // No comparison for datasets without a train split.
        assert!(data_ineligibility(&data, &json!({"acl6060_dev": {"split": "scored"}})).is_empty());
    }

    /// Re-review #5: dev-other must have exactly 600 utterances to be eligible.
    #[test]
    fn dev_other_needs_exactly_600_utterances() {
        let mut data = super::super::new_data();
        data.sets.push(Set {
            name: DEV_OTHER_NAME.into(),
            role: Role::Tune,
            utts: (0..599).collect(),
            sizes: vec![DEV_OTHER_LIST],
        });
        let r = data_ineligibility(&data, &json!({}));
        assert!(r[0].contains("599"), "{r:?}");
        data.sets[0].utts.push(599);
        assert!(data_ineligibility(&data, &json!({})).is_empty());
    }

    #[test]
    fn dev_runs_need_every_frozen_domain() {
        assert_eq!(check_dev_domains(&DEV_DOMAINS, false), Ok(false));
        let some = ["spgispeech_dev", "earnings22_tune"];
        let err = check_dev_domains(&some, false).unwrap_err();
        assert!(
            err.contains("icsi_dev") && err.contains("acl6060_dev"),
            "{err}"
        );
        assert_eq!(check_dev_domains(&some, true), Ok(true));
        // At the command line: dev runs refuse missing domains unless
        // --allow-partial-dev; held-out runs have no dev objective.
        let base = "--export /e --cache /c --out /o --rare-words /r --common-words /w";
        let parse = |extra: &str| {
            super::super::parse_args_from(argv(&format!(
                "{base} {}",
                extra.replace(".jsonl", ".jsonl:dataset=icsi,cased=yes,df=/t.jsonl")
            )))
        };
        assert!(parse("--sets dev --set dev:icsi_dev:/m.jsonl").is_err());
        assert!(parse("--sets both --set dev:icsi_dev:/m.jsonl --set heldout:x:/n.jsonl").is_err());
        let ok = parse("--sets dev --set dev:icsi_dev:/m.jsonl --allow-partial-dev").unwrap();
        assert!(ok.exp2.unwrap().allow_partial_dev);
        assert!(parse("--sets heldout --set heldout:icsi_test:/m.jsonl").is_ok());
        // Experiment 1's Earnings-22 set provides `earnings22_tune` (by its
        // file name), dev-other `librispeech_dev_other_600`.
        let all = "--sets dev --session /d/earnings22.json:/m.json --libri-dev /d.json \
                   --spgi-dev /s.json --set dev:slidespeech_dev:/a.json:dataset=slidespeech,cased=yes,df=/t \
                   --set dev:icsi_dev:/b.jsonl \
                   --set dev:acl6060_dev:/c.json:dataset=acl6060,cased=yes,df=scored";
        assert!(parse(all).is_ok());
        assert!(parse(&all.replace("earnings22.json", "e22.json")).is_err());
        assert!(parse(&all.replace("--libri-dev /d.json", "")).is_err());
        // Exactly one set per domain, across source types (A3).
        let dup = format!("{all} --set dev:librispeech_dev_other_600:/x.jsonl");
        let err = parse(&dup).err().unwrap();
        assert!(err.contains("more than once"), "{err}");
        assert!(parse(&format!("{all} --set dev:spgispeech_dev:/y.jsonl")).is_err());
        assert!(check_dev_domains(&["icsi_dev", "icsi_dev"], true).is_err());
    }

    /// A5: another session's keyword phrase spoken in this session is not a
    /// distractor, also when it is several words long.
    #[test]
    fn keyword_padding_excludes_spoken_phrases() {
        use super::super::{bias_lists, exp2_phrases::phrases_in_references};
        let records = [
            ("a", "today we train a Neural Network on slides"),
            ("a", "and nothing else"),
            ("b", "graph theory"),
        ];
        let keys: BTreeSet<String> = ["neural network", "graph theory", "zorbin", "deep net"]
            .map(String::from)
            .into();
        let spoken = phrases_in_references(records, &keys);
        assert_eq!(spoken["a"], ["neural network".to_owned()].into());
        assert_eq!(spoken["b"], ["graph theory".to_owned()].into());
        // Session b's keywords would pad a's list; "Neural Network" is said in a.
        let mut targets: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        targets.insert("a".into(), vec![("quaxel".into(), "Quaxel".into())]);
        targets.insert(
            "b".into(),
            vec![
                ("neural network".into(), "Neural Network".into()),
                ("zorbin".into(), "Zorbin".into()),
            ],
        );
        let mut vocab: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for (s, t) in records {
            vocab
                .entry(s.into())
                .or_default()
                .extend(super::super::normalize(t));
        }
        let plain = bias_lists::session_lists(&targets, &vocab, &[], &[5], 1);
        assert!(plain["a"][0].entries.contains(&"Neural Network".to_owned()));
        for (s, p) in spoken {
            vocab.entry(s).or_default().extend(p);
        }
        let aware = bias_lists::session_lists(&targets, &vocab, &[], &[5], 1);
        assert_eq!(aware["a"][0].entries, ["Quaxel", "Zorbin"]);
    }

    /// B5: declared-uncased sets lowercase every entry before case variants;
    /// cased sets keep the spelling.
    #[test]
    fn uncased_sets_normalize_entry_surfaces() {
        use super::super::{bias_lists::SessionList, normalize_list_surfaces};
        let make = || {
            let mut m = BTreeMap::new();
            m.insert(
                "s".to_owned(),
                vec![SessionList {
                    size: 2,
                    targets: 1,
                    from_other_sessions: 1,
                    entries: vec!["QUAXEL".into(), "Neural Network".into()],
                }],
            );
            m
        };
        let mut lists = make();
        normalize_list_surfaces(&mut lists, exp2_terms::Casing::Uncased);
        assert_eq!(lists["s"][0].entries, ["quaxel", "neural network"]);
        let mut lists = make();
        normalize_list_surfaces(&mut lists, exp2_terms::Casing::Cased);
        assert_eq!(lists, make());
    }

    /// Keyword lists are always uncased (all-uppercase OCR keywords), rare
    /// lists follow the declared casing.
    #[test]
    fn rare_lists_follow_the_declared_casing() {
        use super::super::{bias_lists::SessionList, list_casing, normalize_list_surfaces};
        use exp2_terms::Casing;
        // Rare lists: the declared casing; keyword lists keep their entries
        // as given (their surfaces are expanded at encoding instead).
        assert_eq!(
            list_casing(ListCondition::Rare, Some(Casing::Cased)),
            Some(Casing::Cased)
        );
        assert_eq!(
            list_casing(ListCondition::Rare, Some(Casing::Uncased)),
            Some(Casing::Uncased)
        );
        assert_eq!(list_casing(ListCondition::Rare, None), None);
        assert_eq!(list_casing(ListCondition::Keywords, None), None);
        let mut lists = BTreeMap::new();
        lists.insert(
            "s".to_owned(),
            vec![SessionList {
                size: 2,
                targets: 2,
                from_other_sessions: 0,
                entries: vec!["NEURAL NETWORK".into(), "GPU".into()],
            }],
        );
        normalize_list_surfaces(&mut lists, Casing::Uncased);
        assert_eq!(lists["s"][0].entries, ["neural network", "gpu"]);
    }

    /// Re-review 2, finding 2: only the frozen dev-other manifest is accepted.
    #[test]
    fn dev_other_identity_is_frozen() {
        let dir = scratch("devother");
        let wrong_name = dir.join("librispeech_test_other.jsonl");
        std::fs::write(&wrong_name, "{}\n").unwrap();
        let err = check_dev_other_manifest(&wrong_name).unwrap_err();
        assert!(err.contains(DEV_OTHER_MANIFEST_NAME), "{err}");
        let right_name = dir.join(DEV_OTHER_MANIFEST_NAME);
        std::fs::write(&right_name, mline("x", "s", "dev", "test other text")).unwrap();
        let err = check_dev_other_manifest(&right_name).unwrap_err();
        assert!(err.contains(DEV_OTHER_MANIFEST_SHA256), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
        // The ids hash is order-independent and pinned.
        let ids: Vec<String> = ["b", "a", "c"].map(String::from).into();
        let sorted: Vec<String> = ["a", "b", "c"].map(String::from).into();
        assert_eq!(ids_sha256(&ids), ids_sha256(&sorted));
        assert_eq!(
            ids_sha256(&sorted),
            lf_model::manifest::sha256_hex(b"a\nb\nc\n")
        );
        assert_eq!(DEV_OTHER_IDS_SHA256.len(), 64);
        // Paths come from flags or $LF_EXP2_ROOT, never from the code.
        let x = Exp2Args {
            group_cache: Some("/w/cache".into()),
            prep_index: Some("/w/prep/index.json".into()),
            ..Default::default()
        };
        assert_eq!(x.group_cache().unwrap(), PathBuf::from("/w/cache"));
        assert_eq!(x.prep_index().unwrap(), PathBuf::from("/w/prep/index.json"));
    }

    /// Re-review 2, finding 1: every prep-index record carries the eval
    /// table's hash, also on a match.
    #[test]
    fn prep_status_always_carries_the_eval_hash() {
        let index = Ok(
            json!({"datasets": {"icsi": {"splits": {"train": {"policy": {"df_source_sha256": "abc"}}}}}}),
        );
        let m = prep_status(&index, "icsi", "abc");
        assert_eq!(
            m,
            json!({"status": "match", "df_source_sha256": "abc", "eval_table_sha256": "abc"})
        );
        assert_eq!(prep_status(&index, "icsi", "zzz")["status"], "mismatch");
        assert_eq!(
            prep_status(&index, "slidespeech", "abc")["eval_table_sha256"],
            "abc"
        );
        let absent = prep_status(&Err("no file".into()), "icsi", "abc");
        assert_eq!(
            (
                absent["status"].as_str(),
                absent["eval_table_sha256"].as_str()
            ),
            (Some("absent"), Some("abc"))
        );
    }

    /// The Rust-produced results.json fixture P's tests consume
    /// (`tests/fixtures/results-eligible.json`): an eligible dev check built
    /// with synthetic values through the production code (argument checks,
    /// eligibility, DF sources, prep status, spec, learned entries and
    /// selection). Written when absent or with `LF_UPDATE_FIXTURES=1`;
    /// otherwise it must match byte for byte.
    #[test]
    fn rust_results_fixture_is_current() {
        let dir = scratch("results");
        // DF sources through `set_df` on synthetic manifests.
        let manifest = |name: &str, split: &str| {
            let p = dir.join(name);
            std::fs::write(
                &p,
                mline("u1", "s1", split, "the quaxel zorbin") + &mline("u2", "s2", split, "plinth"),
            )
            .unwrap();
            p
        };
        let calls: String = (0..20)
            .map(|i| format!("{i:032x}"))
            .map(|c| mline(&format!("{c}/1.wav"), &c, "", "zorbin call"))
            .collect();
        let spgi = dir.join("spgi.jsonl");
        std::fs::write(&spgi, calls).unwrap();
        let sets = [
            format!(
                "dev:spgispeech_dev:{0}:dataset=spgispeech,session=before:/,keep=spgi-dev,cased=yes,df={0},df-keep=spgi-train",
                spgi.display()
            ),
            format!(
                "dev:slidespeech_dev:{}:dataset=slidespeech,cased=yes,df={}",
                manifest("slidespeech_dev.jsonl", "dev").display(),
                manifest("slidespeech_train_s95.jsonl", "train").display()
            ),
            format!(
                "dev:icsi_dev:{}:dataset=icsi,cased=yes,df={}",
                manifest("icsi_dev.jsonl", "dev").display(),
                manifest("icsi_train.jsonl", "train").display()
            ),
            format!(
                "dev:acl6060_dev:{}:dataset=acl6060,cased=yes,df=scored",
                manifest("acl6060_dev.jsonl", "dev").display()
            ),
        ];
        let generic: Vec<GenericSet> = sets.iter().map(|s| parse_set(s).unwrap()).collect();
        let mut tables = Vec::new();
        for g in &generic {
            let rule = check_set_rules(g).unwrap();
            let (df, info, _) = set_df(g, rule).unwrap();
            tables.push((g.name.clone(), rule, df.sha256(), info));
        }
        let mut index = json!({"datasets": {}});
        for (_, rule, sha, _) in &tables {
            if rule.has_train {
                index["datasets"][rule.name] =
                    json!({"splits": {"train": {"policy": {"df_source_sha256": sha}}}});
            }
        }
        let index = Ok(index);
        let mut df_source = serde_json::Map::new();
        for (name, rule, sha, mut info) in tables {
            if rule.has_train {
                info["prep_index"] = prep_status(&index, rule.name, &sha);
            }
            // Machine-independent paths in the committed fixture.
            for m in info["manifests"].as_array_mut().unwrap() {
                let file = PathBuf::from(m["path"].as_str().unwrap());
                m["path"] = json!(format!(
                    "$LF_EXP2_ROOT/datasets/manifests/{}",
                    file.file_name().unwrap().to_str().unwrap()
                ));
            }
            df_source.insert(name, info);
        }
        let df_source = Value::Object(df_source);
        std::fs::remove_dir_all(&dir).unwrap();

        // The eligible command line, through the production argument checks.
        let model = "/w/train/L3/model-e1.0.safetensors";
        let args = super::super::parse_args_from(argv(&format!(
            "--export /e --cache /c --out /o --group-cache /g --rare-words /r --common-words /w \
             --sets dev --no-l0 --session /d/earnings22.json:/m.json --libri-dev /d/{DEV_OTHER_MANIFEST_NAME} \
             {} --learned {model}",
            sets.iter().map(|s| format!("--set {s}")).collect::<Vec<_>>().join(" ")
        )))
        .unwrap();
        let x = args.exp2.as_ref().unwrap();
        // Synthetic data: the six domains, dev-other with exactly 600.
        let mut data = super::super::new_data();
        for d in DEV_DOMAINS {
            let other = d == DEV_OTHER_NAME;
            data.sets.push(Set {
                name: d.into(),
                role: Role::Tune,
                utts: (0..if other { DEV_OTHER_SIZE } else { 10 }).collect(),
                sizes: if other {
                    vec![DEV_OTHER_LIST]
                } else {
                    (0..SIZES.len()).collect()
                },
            });
        }
        let mut ineligible = ineligibility(x, &args, false);
        ineligible.extend(data_ineligibility(&data, &df_source));
        assert!(ineligible.is_empty(), "{ineligible:?}");

        let id = model_id(Variant::L3, &x.learned[0].source);
        let objectives = [1.01, 0.99, 0.97, 0.98, 1.03];
        let rows: Vec<LearnedRow> = x
            .lambdas()
            .iter()
            .zip(objectives)
            .map(|(&l, o)| LearnedRow {
                row: row_id(&id, l),
                lambda: l,
                objective: Ok(Some(o)),
            })
            .collect();
        let learned = vec![learned_entry(
            &id,
            model,
            Variant::L3,
            5_599_298,
            1.0,
            Some(1.0),
            &rows,
            json!({}),
        )];
        let spec = spec_json(&SpecParts {
            sets: SetSel::Dev,
            domains: data
                .sets
                .iter()
                .map(|s| SpecDomain {
                    name: s.name.clone(),
                    sizes: s.sizes.iter().map(|&z| SIZES[z]).collect(),
                    utterances: s.utts.len(),
                    groups: if s.name == DEV_OTHER_NAME { 600 } else { 2 },
                })
                .collect(),
            limit: args.limit,
            sizes_flag: x.sizes.clone(),
            dev_subset: Some(DEV_OTHER_SIZE),
            dev_subset_flag: x.dev_subset,
            allow_partial_dev: x.allow_partial_dev,
            seed: args.seed,
            lambdas: x.lambdas(),
            models: vec![SpecModel {
                id: id.clone(),
                variant: Variant::L3,
                source: model.into(),
                lambdas: x.lambdas(),
            }],
            dev_other: json!({
                "manifest": DEV_OTHER_MANIFEST_NAME,
                "manifest_sha256": DEV_OTHER_MANIFEST_SHA256,
                "ids_sha256": DEV_OTHER_IDS_SHA256,
                "selected": DEV_OTHER_SIZE,
            }),
        });
        let rest = json!({
            "sets_selected": "dev",
            "precision": "i8x2",
            "decoder_storage": "F16",
            "pools": "1 thread per worker",
            "workers": 16,
            "seed": args.seed,
            "limit": null,
            "dev_domains_frozen": DEV_DOMAINS,
            "dev_domains_present": DEV_DOMAINS,
            "notes": ["synthetic fixture written by learned_eval::tests::rust_results_fixture_is_current"],
        });
        let results = results_json(ResultsParts {
            ineligible,
            spec,
            partial: false,
            df_source,
            parity_failures: Vec::new(),
            baseline_dev_objective: Some(1.0),
            learned,
            rest: rest.as_object().unwrap().clone(),
        })
        .unwrap();
        assert_eq!(results["eligible_for_selection"], true);
        assert_eq!(results["dev_objective"], 0.97);
        assert_eq!(results["dev_objective_row"]["row"], "L3/L3/model-e1.0@1");
        assert_eq!(
            results["dev_objectives_learned"]["L3/L3/model-e1.0@0.71"],
            0.99
        );
        for s in ["spgispeech_dev", "slidespeech_dev", "icsi_dev"] {
            let p = &results["df_source"][s]["prep_index"];
            assert_eq!(p["status"], "match");
            assert_eq!(
                p["eval_table_sha256"],
                results["df_source"][s]["table_sha256"]
            );
        }
        let text = serde_json::to_string_pretty(&results).unwrap() + "\n";
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/results-eligible.json");
        if !path.exists() || std::env::var_os("LF_UPDATE_FIXTURES").is_some() {
            std::fs::write(&path, &text).unwrap();
        }
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            text,
            "results.json layout changed: rerun with LF_UPDATE_FIXTURES=1 and update P's validator"
        );
    }

    /// Experiment 3: Earnings-21 is evaluation only (held out, `df=scored`,
    /// a `split` field naming held-out on every line).
    #[test]
    fn earnings21_is_registered_as_evaluation_only() {
        let rule = dataset_rule("earnings21").unwrap();
        assert!(!rule.has_train && rule.heldout_only);
        assert_eq!(rule.split, SplitRule::Field);
        let ok = parse_set("heldout:earnings21:/e.jsonl:dataset=earnings21,cased=yes,df=scored")
            .unwrap();
        assert_eq!(check_set_rules(&ok).unwrap(), rule);
        assert!(
            parse_set("dev:earnings21:/e.jsonl:dataset=earnings21,cased=yes,df=scored").is_err()
        );
        assert!(
            parse_set("heldout:earnings21:/e.jsonl:dataset=earnings21,cased=yes,df=/t.jsonl")
                .is_err()
        );
        assert!(parse_set("heldout:earnings21:/e.jsonl:dataset=earnings21,df=scored").is_err());
        // The six dev domains are unchanged.
        assert_eq!(DEV_DOMAINS.len(), 6);
        assert!(!DEV_DOMAINS.iter().any(|d| d.contains("earnings21")));
        // Synthetic manifest in D's layout: id `{call}/{nnnn}`, session the call.
        let dir = scratch("e21");
        let m = dir.join("earnings21_test.jsonl");
        std::fs::write(
            &m,
            mline("4320211/0001", "4320211", "heldout", "Zorbin results")
                + &mline("4320211/0002", "4320211", "heldout", "more")
                + &mline("4341191/0001", "4341191", "heldout", "Quaxel"),
        )
        .unwrap();
        let key = SessionKey::Field("session".into());
        let lines = split_lines(&m, &key, None, rule, SplitName::Heldout).unwrap();
        assert_eq!(lines.len(), 3);
        let g = parse_set(&format!(
            "heldout:earnings21:{}:dataset=earnings21,cased=yes,df=scored",
            m.display()
        ))
        .unwrap();
        let (df, info, sessions) = set_df(&g, rule).unwrap();
        assert_eq!((df.sessions(), sessions.len()), (2, 2));
        assert_eq!(info["split"], "scored");
        std::fs::write(&m, mline("4320211/0001", "4320211", "train", "x")).unwrap();
        assert!(split_lines(&m, &key, None, rule, SplitName::Heldout).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A synthetic set: two sessions, three utterances; returns the data, a
    /// baseline and a biased decode.
    fn session_fixture() -> (Data, Baseline, Vec<Decoded>) {
        let w = |s: &str| super::super::normalize(s);
        let mut data = super::super::new_data();
        data.groups.push(Group {
            utts: 3,
            lists: vec![vec!["zorbin".into(), "quaxel".into()]; SIZES.len()],
            list_norm: vec![["zorbin", "quaxel"].map(String::from).into(); SIZES.len()],
            surface: BTreeMap::new(),
            keywords: false,
        });
        let refs = [
            ("c1/1", "c1", "the zorbin sang today"),
            ("c1/2", "c1", "a quaxel and a zorbin"),
            ("c2/1", "c2", "nothing rare here"),
        ];
        for (id, session, text) in refs {
            let ref_words = w(text);
            let biasing = ref_words
                .iter()
                .filter(|x| ["zorbin", "quaxel"].contains(&x.as_str()))
                .cloned()
                .collect();
            data.utts.push(Utt {
                id: id.into(),
                session: session.into(),
                group: 0,
                ref_words,
                biasing,
                m1_hyp: String::new(),
                frames: 0,
                proj: Arc::new(Vec::new()),
            });
        }
        data.sets.push(Set {
            name: "earnings21".into(),
            role: Role::Test,
            utts: vec![0, 1, 2],
            sizes: (0..SIZES.len()).collect(),
        });
        let d = |t: &str| Decoded {
            text: t.into(),
            words: w(t),
            ns: 1,
        };
        let base = Baseline {
            decoded: vec![
                Some(d("the sorbin sang today")),
                Some(d("a quaxel and zorbin")),
                Some(d("nothing rare here")),
            ],
        };
        let biased = vec![
            d("the zorbin sang today"),
            d("a quaxel and a zorbin zorbin"),
            d("nothing quaxel here"),
        ];
        (data, base, biased)
    }

    /// Experiment 3 `--per-session`: the counts per session sum exactly to
    /// the set aggregate, with the documented field names.
    #[test]
    fn per_session_counts_sum_to_the_aggregate() {
        let (data, base, biased) = session_fixture();
        let utts = &data.sets[0].utts;
        for size in 0..SIZES.len() {
            let m = set_metrics(&data, &base, utts, &biased, size);
            let b = baseline_metrics(&data, &base, utts, size);
            let s = session_counts(&data, &base, utts, &biased, size);
            assert_eq!(s.keys().collect::<Vec<_>>(), ["c1", "c2"]);
            check_session_sums(&s, &m, b.counts.wer.errors()).unwrap();
            // A wrong baseline total is caught.
            assert!(check_session_sums(&s, &m, b.counts.wer.errors() + 1).is_err());
            let sum_net: i64 = s
                .values()
                .map(|c| c.json()["net_errors"].as_i64().unwrap())
                .sum();
            assert_eq!(
                sum_net,
                m.counts.wer.errors() as i64 - b.counts.wer.errors() as i64
            );
        }
        let s = session_counts(&data, &base, &data.sets[0].utts, &biased, 0);
        let c1 = s["c1"].json();
        let fields: Vec<&String> = c1.as_object().unwrap().keys().collect();
        assert_eq!(
            fields,
            [
                "b_errors",
                "b_matched",
                "b_ref_words",
                "baseline_errors",
                "broken",
                "del",
                "errors",
                "false_alarms",
                "fixed",
                "ins",
                "net_errors",
                "ref_words",
                "sub",
                "u_errors",
                "u_ref_words",
                "utterances"
            ]
        );
        // c1: utterance 1 fixed (sorbin -> zorbin), utterance 2 fixed (the
        // missing "a"), with one extra "zorbin": a false alarm and an insertion.
        assert_eq!(
            (
                c1["utterances"].as_u64(),
                c1["fixed"].as_u64(),
                c1["false_alarms"].as_u64()
            ),
            (Some(2), Some(1), Some(1))
        );
        let c2 = s["c2"].json();
        assert_eq!(
            (c2["broken"].as_u64(), c2["net_errors"].as_i64()),
            (Some(1), Some(1))
        );
        // LibriSpeech sessions are speaker-chapters.
        assert_eq!(super::super::libri_session("116-288045-0000"), "116-288045");
        assert_eq!(
            super::super::libri_session("librispeech:116-288045-0003"),
            "116-288045"
        );
    }

    /// Experiment 3, finding 7 (and impl3 review #4): re-decoded experiment 2
    /// rows must reproduce its per-set counts, for every expected cell in
    /// the comparison scope.
    #[test]
    fn expected_rows_must_match_experiment_2() {
        let m = |words: u64, sub: u64| {
            json!({"utterances": 3, "wer": {"words": words, "sub": sub, "del": 0, "ins": 0, "percent": 1.5},
                   "b_wer": {"words": 2, "sub": 0, "del": 0, "ins": 0}, "u_wer": {"words": 8, "sub": sub, "del": 0, "ins": 0},
                   "b_matched": 2, "false_alarms": 0, "fixed": 1, "broken": 0})
        };
        let id = "L2/L2/model-e0.5@1";
        let expected = json!({"rows": [
            {"row": id, "set": "gigaspeech", "size": 100, "metrics": m(10, 1)},
            {"row": id, "set": "gigaspeech", "size": 500, "metrics": m(10, 2)},
            {"row": id, "set": "icsi_eval", "size": 100, "metrics": m(20, 4)},
            {"row": "other@1", "set": "gigaspeech", "size": 100, "metrics": m(10, 9)},
        ]});
        let set = |v: &[&str]| {
            v.iter()
                .map(|s| s.to_string())
                .collect::<BTreeSet<String>>()
        };
        let mut ours: BTreeMap<(String, u64), Value> = BTreeMap::new();
        ours.insert(("gigaspeech".into(), 100), m(10, 1));
        ours.insert(("gigaspeech".into(), 500), m(10, 2));
        ours.insert(("icsi_eval".into(), 100), m(20, 4));
        // A set experiment 2 never evaluated is skipped, not compared.
        ours.insert(("earnings21".into(), 100), m(50, 5));
        let mut current = BTreeMap::new();
        current.insert(id.to_owned(), ours.clone());
        let ids = vec![id.to_owned()];
        let loaded = set(&["gigaspeech", "icsi_eval", "earnings21"]);
        let check = |c: &BTreeMap<String, BTreeMap<(String, u64), Value>>,
                     loaded: &BTreeSet<String>,
                     scope: Option<&BTreeSet<String>>| {
            expect_row_failures(&expected, &ids, c, loaded, scope)
        };
        let (report, f) = check(&current, &loaded, None);
        assert!(f.is_empty(), "{f:?}");
        assert_eq!(report["rows"][0]["compared"], 3);
        assert_eq!(report["rows"][0]["skipped_sets"], json!(["earnings21"]));
        assert_eq!(report["scope"]["explicit"], false);
        // Regression (review #4): an expected size omitted here fails.
        let mut c = current.clone();
        c.get_mut(id)
            .unwrap()
            .remove(&("gigaspeech".to_owned(), 500));
        let f = check(&c, &loaded, None).1;
        assert!(
            f[0].contains("gigaspeech size 500 was evaluated by experiment 2 but not here"),
            "{f:?}"
        );
        // A whole expected set that this run loads but did not decode fails.
        let mut c = current.clone();
        c.get_mut(id)
            .unwrap()
            .remove(&("icsi_eval".to_owned(), 100));
        assert!(!check(&c, &loaded, None).1.is_empty());
        // Percent and timings are ignored; any differing count fails.
        let mut c = current.clone();
        c.get_mut(id)
            .unwrap()
            .insert(("gigaspeech".into(), 500), m(10, 3));
        assert!(check(&c, &loaded, None).1[0].contains("differs"));
        // An extra size in an expected set fails.
        let mut c = current.clone();
        c.get_mut(id)
            .unwrap()
            .insert(("gigaspeech".into(), 1000), m(10, 2));
        assert!(check(&c, &loaded, None).1[0].contains("no experiment 2 entry"));
        // Explicit narrower scope (GigaSpeech-only sensitivity re-decode).
        let giga_only = set(&["gigaspeech"]);
        let mut c = BTreeMap::new();
        let mut g = BTreeMap::new();
        g.insert(("gigaspeech".to_owned(), 100), m(10, 1));
        g.insert(("gigaspeech".to_owned(), 500), m(10, 2));
        c.insert(id.to_owned(), g.clone());
        let (report, f) = check(&c, &set(&["gigaspeech"]), Some(&giga_only));
        assert!(f.is_empty(), "{f:?}");
        assert_eq!(
            report["scope"],
            json!({"explicit": true, "sets": ["gigaspeech"]})
        );
        assert_eq!(report["rows"][0]["compared"], 2);
        // ... still complete within the scope ...
        let mut c2 = c.clone();
        c2.get_mut(id)
            .unwrap()
            .remove(&("gigaspeech".to_owned(), 100));
        assert!(
            !check(&c2, &set(&["gigaspeech"]), Some(&giga_only))
                .1
                .is_empty()
        );
        // ... and every scope set must be loaded and in experiment 2's results.
        assert!(
            !check(
                &c,
                &set(&["gigaspeech"]),
                Some(&set(&["gigaspeech", "acl6060_eval"]))
            )
            .1
            .is_empty()
        );
        assert!(
            !check(&c, &set(&["icsi_eval"]), Some(&giga_only))
                .1
                .is_empty()
        );
        // Missing here, missing there, nothing in common.
        assert!(!check(&BTreeMap::new(), &loaded, None).1.is_empty());
        let unknown = vec!["L2/L2/model-e9@1".to_owned()];
        let mut c = BTreeMap::new();
        c.insert(unknown[0].clone(), ours.clone());
        assert!(
            expect_row_failures(&expected, &unknown, &c, &loaded, None).1[0]
                .contains("not in experiment 2")
        );
        let mut c = BTreeMap::new();
        let mut only_new = BTreeMap::new();
        only_new.insert(("earnings21".to_owned(), 100), m(50, 5));
        c.insert(id.to_owned(), only_new);
        assert!(check(&c, &set(&["earnings21"]), None).1[0].contains("empty scope"));
        // The scope flag needs --expect-rows.
        let base = "--export /e --cache /c --out /o --group-cache /g --rare-words /r --common-words /w \
                    --sets heldout --gigaspeech /g.jsonl";
        let parse = |extra: &str| super::super::parse_args_from(argv(&format!("{base} {extra}")));
        assert!(parse("--expect-scope gigaspeech").is_err());
        let a = parse("--expect-rows /x/results.json:a@1 --expect-scope gigaspeech").unwrap();
        assert_eq!(a.exp2.unwrap().expect_scope, Some(giga_only));
    }

    /// Experiment 3 (impl3 recheck): reference-only counts equal the
    /// `ref_words` and `utterances` a `--per-session` run reports on the same
    /// manifest (built here through the same loader functions as
    /// `load_sessions`).
    #[test]
    fn count_refs_equals_per_session_ref_words() {
        let dir = scratch("refcounts");
        let m = dir.join("earnings21_test.jsonl");
        let text = [
            (
                "4320211/0001",
                "4320211",
                "Q3 revenue was $4.2 billion, up 12%.",
            ),
            (
                "4320211/0002",
                "4320211",
                "We're seeing it — co-op, e-mail; naïve ‘quotes’ 'n'",
            ),
            ("4320211/0003", "4320211", "   ...   "),
            (
                "4341191/0001",
                "4341191",
                "Zorbin's CEO, Ms. O'Brien: \"thanks.\"",
            ),
            ("4341191/0002", "4341191", "ÉCOLE straße 2,000 1st"),
        ]
        .iter()
        .map(|(id, s, t)| mline(id, s, "heldout", &t.replace('"', "\\\"")))
        .collect::<String>();
        std::fs::write(&m, text).unwrap();
        let key = SessionKey::Field("session".into());
        let counts = count_refs(&m, &key).unwrap();
        assert_eq!(counts["format"], REF_COUNTS_FORMAT);
        assert_eq!(counts["session_rule"], "field:session");
        assert_eq!(counts["manifest"], "earnings21_test.jsonl");
        assert_eq!(
            counts["manifest_sha256"],
            lf_model::manifest::sha256_file(&m).unwrap()
        );
        assert_eq!(
            (
                counts["manifest_lines"].as_u64(),
                counts["unscored_lines"].as_u64()
            ),
            (Some(5), Some(1))
        );

        // The per-session path: utterances loaded as `load_sessions` loads a
        // manifest set, then `session_counts` (what writes per_session.jsonl).
        let mut notes = Vec::new();
        let items = super::super::manifest_items(&m, &mut notes).unwrap();
        let session_of = session_fn(&key, &m).unwrap();
        let mut data = super::super::new_data();
        data.groups.push(Group {
            utts: items.len(),
            lists: vec![Vec::new(); SIZES.len()],
            list_norm: vec![BTreeSet::new(); SIZES.len()],
            surface: BTreeMap::new(),
            keywords: false,
        });
        for (id, r, _) in &items {
            data.utts.push(Utt {
                id: id.clone(),
                session: session_of(id),
                group: 0,
                ref_words: super::super::reference_words(&r.reference),
                biasing: BTreeSet::new(),
                m1_hyp: String::new(),
                frames: 0,
                proj: Arc::new(Vec::new()),
            });
        }
        let utts: Vec<usize> = (0..items.len()).collect();
        let hyp = |t: &str| Decoded {
            text: t.into(),
            words: super::super::normalize(t),
            ns: 0,
        };
        let base = Baseline {
            decoded: utts.iter().map(|_| Some(hyp("some other words"))).collect(),
        };
        let decoded: Vec<Decoded> = utts.iter().map(|_| hyp("q3 revenue")).collect();
        for size in 0..SIZES.len() {
            let per = session_counts(&data, &base, &utts, &decoded, size);
            let ours: Vec<Value> = per
                .iter()
                .map(|(s, c)| {
                    let j = c.json();
                    json!({"session": s, "utterances": j["utterances"], "ref_words": j["ref_words"]})
                })
                .collect();
            assert_eq!(Value::Array(ours), counts["sessions"]);
        }
        let total: u64 = counts["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["ref_words"].as_u64().unwrap())
            .sum();
        assert_eq!(counts["ref_words"].as_u64(), Some(total));
        // Another session rule.
        let by_id = count_refs(&m, &SessionKey::Before("/".into())).unwrap();
        assert_eq!(by_id["session_rule"], "before:/");
        assert_eq!(by_id["sessions"], counts["sessions"]);
        // The CLI: no export or cache needed; the output must be outside Git.
        let out = dir.join("ref_counts.json");
        count_refs_cli(argv(&format!(
            "--count-refs {} --out {}",
            m.display(),
            out.display()
        )))
        .unwrap();
        let written: Value = serde_json::from_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
        assert_eq!(written, counts);
        assert!(count_refs_cli(argv(&format!("--count-refs {}", m.display()))).is_err());
        assert!(
            count_refs_cli(argv(&format!(
                "--count-refs {} --out {} --export /e",
                m.display(),
                out.display()
            )))
            .is_err()
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Experiment 3: frozen fixed-bonus rows next to L0-historical, and the
    /// new flags' parsing.
    #[test]
    fn fixed_l0_rows_and_experiment_3_flags() {
        let base = "--export /e --cache /c --out /o --group-cache /g --rare-words /r --common-words /w \
                    --sets heldout --set heldout:earnings21:/e.jsonl:dataset=earnings21,cased=yes,df=scored";
        let parse = |extra: &str| super::super::parse_args_from(argv(&format!("{base} {extra}")));
        let a = parse("--l0-row L0-retuned=0.5,2,on,on --per-session --expect-rows /w/exp2/results.json:L2/L2/model-e0.5@1,L3/L3-c25/model-e0.5@1")
            .unwrap();
        let x = a.exp2.as_ref().unwrap();
        assert!(x.per_session);
        assert_eq!(
            x.l0, None,
            "L0-historical keeps experiment 1's configuration"
        );
        assert_eq!(
            x.l0_rows,
            [(
                "L0-retuned".to_owned(),
                Cfg {
                    alpha: 0.5,
                    depth: 2.0,
                    cancel: true,
                    case: true
                }
            )]
        );
        let (file, ids) = x.expect_rows.clone().unwrap();
        assert_eq!(file, PathBuf::from("/w/exp2/results.json"));
        assert_eq!(ids, ["L2/L2/model-e0.5@1", "L3/L3-c25/model-e0.5@1"]);
        // Labels: no reserved, duplicated or '@' labels; not with --l0-retune.
        assert!(parse("--l0-row L0-historical=0.5,2,on,on").is_err());
        assert!(parse("--l0-row baseline=0.5,2,on,on").is_err());
        assert!(parse("--l0-row a@1=0.5,2,on,on").is_err());
        assert!(parse("--l0-row a=0.5,2,on,on --l0-row a=1,2,on,on").is_err());
        assert!(parse("--l0-row a=0.5,2,maybe,on").is_err());
        assert!(parse("--l0-row a=-1,2,on,on").is_err());
        assert!(parse("--l0-row a=0.5,2,on,on --l0-row b=1,3,off,on").is_ok());
        assert!(parse("--expect-rows /w/results.json").is_err());
        let dev = "--export /e --cache /c --out /o --group-cache /g --rare-words /r --common-words /w \
                   --sets dev --allow-partial-dev --set dev:icsi_dev:/i.jsonl:dataset=icsi,cased=yes,df=/t";
        assert!(
            super::super::parse_args_from(argv(&format!(
                "{dev} --l0-retune --l0-row L0-retuned=0.5,2,on,on"
            )))
            .is_err()
        );
        // A per-session dev reporting run is accepted (and not selected from).
        assert!(super::super::parse_args_from(argv(&format!("{dev} --per-session"))).is_ok());
    }

    /// A1: the baseline (λ = 0) is every model's fallback; ties keep it.
    #[test]
    fn selection_falls_back_to_the_baseline() {
        let l = |m: &str, lam: f32, o: f64| (row_id(m, lam), m.to_owned(), lambda_number(lam), o);
        let worse = [
            l("L3/L3/model-e1", 1.0, 1.02),
            l("L3/L3/model-e1", 2.0, 1.4),
        ];
        let base = (BASELINE_ROW.to_owned(), "baseline".to_owned(), 0.0, 1.0);
        assert_eq!(select(1.0, &worse), base);
        assert_eq!(select(1.0, &[l("a", 1.0, 1.0)]).0, "baseline@0");
        let better = [
            l("L3/L3/model-e1", 1.0, 0.97),
            l("L1/L1/model-e1", 0.71, 0.95),
        ];
        let best = select(1.0, &better);
        assert_eq!(best.0, "L1/L1/model-e1@0.71");
        assert_eq!(
            (best.1.as_str(), best.2, best.3),
            ("L1/L1/model-e1", 0.71, 0.95)
        );
        assert_eq!(select(1.0, &[]).3, 1.0);
    }

    /// Re-review #8: one row id, from the grid's literal, everywhere.
    #[test]
    fn row_ids_use_the_grid_literals() {
        let lits: Vec<String> = DEFAULT_LAMBDAS.iter().map(|&l| lambda_literal(l)).collect();
        assert_eq!(lits, ["0.5", "0.71", "1", "1.41", "2"]);
        assert_eq!(lambda_number(0.71), 0.71);
        assert_eq!(json!(lambda_number(1.41)).to_string(), "1.41");
        assert_eq!(row_id("L3/L3/model-e2.5", 0.71), "L3/L3/model-e2.5@0.71");
        assert_eq!(row_id("L3/L3/model-e2.5", 2.0), "L3/L3/model-e2.5@2");
        assert_eq!(BASELINE_ROW, "baseline@0");
        // spec.models must equal the learned rows written.
        let learned = vec![json!({"id": "L1/L1/m", "by_lambda": [
            {"row": BASELINE_ROW, "lambda": 0.0, "fallback": true},
            {"row": "L1/L1/m@0.71", "lambda": 0.71, "fallback": false},
        ]})];
        let spec = |rows: Value, lambdas: Value| json!({"models": [{"id": "L1/L1/m", "rows": rows, "lambdas": lambdas}]});
        assert!(check_spec_rows(&spec(json!(["L1/L1/m@0.71"]), json!([0.71])), &learned).is_ok());
        assert!(check_spec_rows(&spec(json!(["L1/L1/m@0.7"]), json!([0.71])), &learned).is_err());
        assert!(check_spec_rows(&spec(json!(["L1/L1/m@0.71"]), json!([1.0])), &learned).is_err());
        assert!(check_spec_rows(&json!({"models": []}), &learned).is_err());
    }

    /// Re-review #2: oracle cases are compared one by one.
    #[test]
    fn oracle_cases_must_match_case_by_case() {
        let case = |set: &str, id: &str, word: &str, missed: u64| json!({"set": set, "id": id, "word": word, "missed_occurrences": missed});
        let exp1 = vec![
            case("librispeech_other", "u1", "zorbin", 1),
            case("librispeech_other", "u2", "quaxel", 2),
            case("earnings22_test", "c/1", "plinth", 1),
        ];
        let mut ours: BTreeMap<String, BTreeMap<(String, String), usize>> = BTreeMap::new();
        let key = |a: &str, b: &str| (a.to_owned(), b.to_owned());
        let lib = ours.entry("librispeech_other".into()).or_default();
        lib.insert(key("u1", "zorbin"), 1);
        lib.insert(key("u2", "quaxel"), 2);
        // Earnings is not evaluated: its cases are ignored.
        assert!(oracle_case_failures(&exp1, &ours).is_empty());
        // A different count, a missing and an extra case each fail, even when
        // the aggregate total (3) is unchanged.
        let mut o = ours.clone();
        let lib = o.get_mut("librispeech_other").unwrap();
        lib.insert(key("u1", "zorbin"), 2);
        lib.remove(&key("u2", "quaxel"));
        lib.insert(key("u3", "other"), 1);
        let f = oracle_case_failures(&exp1, &o);
        assert_eq!(f.len(), 3, "{f:?}");
        // An evaluated set without any experiment 1 case is incomplete.
        let mut o = ours.clone();
        o.insert("earnings22_test".into(), BTreeMap::new());
        o.get_mut("earnings22_test")
            .unwrap()
            .insert(key("c/1", "plinth"), 1);
        assert!(oracle_case_failures(&exp1, &o).is_empty());
        let only: Vec<Value> = exp1[..2].to_vec();
        assert!(!oracle_case_failures(&only, &o).is_empty());
        // Duplicated experiment 1 cases are refused.
        let dup = vec![exp1[0].clone(), exp1[0].clone()];
        assert!(!oracle_case_failures(&dup, &ours).is_empty());
    }

    fn exp2_args(extra: &str) -> Args {
        super::super::parse_args_from(argv(&format!(
            "--export /e --cache /c --out /o --rare-words /r --common-words /w \
             --sets dev --session /d/earnings22.json:/m.json --libri-dev /d.json \
             --spgi-dev /s.json --set dev:slidespeech_dev:/a:dataset=slidespeech,cased=yes,df=/t \
             --set dev:icsi_dev:/b:dataset=icsi,cased=no,df=/t --set dev:acl6060_dev:/c:dataset=acl6060,cased=yes,df=scored \
             {extra}"
        )))
        .unwrap()
    }

    /// A2: only a complete, frozen dev specification is eligible.
    #[test]
    fn smoke_specifications_are_ineligible() {
        let reasons = |extra: &str, partial: bool| {
            let a = exp2_args(extra);
            ineligibility(a.exp2.as_ref().unwrap(), &a, partial)
        };
        assert!(reasons("--learned /r/L3/model-e1.safetensors", false).is_empty());
        assert!(
            reasons(
                "--learned /r/L3/m.safetensors --lambdas 0.5,0.71,1,1.41,2",
                false
            )
            .is_empty()
        );
        for extra in [
            "--limit 4",
            "--sizes 100",
            "--dev-subset 600",
            "--allow-partial-dev",
            "--seed 7",
            "--lambdas 1,2",
            "--l0 1,2,off,on",
        ] {
            let r = reasons(&format!("--learned /r/L3/m.safetensors {extra}"), false);
            assert!(!r.is_empty(), "{extra} must make the run ineligible");
        }
        assert!(!reasons("--learned random:L3", false).is_empty());
        assert!(!reasons("--learned /r/L3/m.safetensors@1", false).is_empty());
        assert!(!reasons("--learned /r/L3/m.safetensors", true).is_empty());
        assert!(!reasons("", false).is_empty(), "no model");
        let a = exp2_args("--learned /r/L3/m.safetensors --limit 4");
        assert!(is_smoke(a.exp2.as_ref().unwrap(), &a, false));
        let a = exp2_args("--learned /r/L3/m.safetensors");
        assert!(!is_smoke(a.exp2.as_ref().unwrap(), &a, false));
    }

    /// A6: ids are `variant/run/stem`; collisions fail before decoding.
    #[test]
    fn model_ids_are_unique() {
        let f = |p: &str| ModelSource::File(p.into());
        let (a, b) = (
            f("/w/train/L1/model-e4.0.safetensors"),
            f("/w/train/L3/model-e4.0.safetensors"),
        );
        assert_eq!(model_id(Variant::L1, &a), "L1/L1/model-e4.0");
        assert_eq!(model_id(Variant::L3, &b), "L3/L3/model-e4.0");
        let r = ModelSource::Random {
            variant: Variant::L3S,
            seed: 2,
        };
        assert_eq!(model_id(Variant::L3S, &r), "random/L3S/2");
        let row = |id: &str, s, l: &[f32]| (id.to_owned(), s, l.to_vec());
        assert!(check_model_ids(&[row("L1/L1/m", &a, &[1.0]), row("L3/L3/m", &b, &[1.0])]).is_ok());
        // The same file at two λ is fine; the same row twice is not.
        assert!(check_model_ids(&[row("L1/L1/m", &a, &[0.5]), row("L1/L1/m", &a, &[1.0])]).is_ok());
        assert!(
            check_model_ids(&[row("L1/L1/m", &a, &[1.0]), row("L1/L1/m", &a, &[1.0])]).is_err()
        );
        // Two different files with one id are rejected.
        let c = f("/other/L1/m.safetensors");
        assert!(
            check_model_ids(&[row("L1/L1/m", &a, &[1.0]), row("L1/L1/m", &c, &[2.0])]).is_err()
        );
    }

    /// A7: any parity mismatch, configuration difference or missing
    /// experiment 1 row is a failure.
    #[test]
    fn parity_failures_cover_counts_config_and_coverage() {
        let ok = json!({
            "decode_scored_vs_decode": {"differing_texts": 0},
            "decode_projected_scored_vs_16_thread_decode_projected": {"differing_texts": 0},
            "exp1_best_config_equals_l0": true,
            "baseline_vs_exp1": {"all_identical": true, "rows": [{"set": "librispeech_other", "size": 100, "identical": true}]},
            "l0_historical_vs_exp1": {"all_identical": true, "rows": [{"set": "librispeech_other", "size": 100, "identical": true}]},
        });
        assert!(parity_failures(&ok).is_empty());
        assert!(parity_failures(&json!({})).is_empty());
        let mut v = ok.clone();
        v["decode_scored_vs_decode"]["differing_texts"] = json!(2);
        assert_eq!(parity_failures(&v).len(), 1);
        let mut v = ok.clone();
        v["exp1_best_config_equals_l0"] = json!(false);
        assert_eq!(parity_failures(&v).len(), 1);
        let mut v = ok.clone();
        v["l0_historical_vs_exp1"]["rows"][0] = json!({"set": "earnings22_test", "size": 500, "identical": false, "differing": ["wer"]});
        assert!(parity_failures(&v)[0].contains("differs"));
        let mut v = ok.clone();
        v["baseline_vs_exp1"]["rows"][0] =
            json!({"set": "earnings22_tune", "size": 100, "identical": false, "missing": true});
        assert!(
            parity_failures(&v)
                .iter()
                .any(|f| f.contains("incomplete coverage"))
        );
        // Fail closed (re-review #2): an empty check, a non-identical summary
        // and a missing label all fail once experiment 1 is compared.
        let mut v = ok.clone();
        v["l0_historical_vs_exp1"]["rows"] = json!([]);
        assert!(parity_failures(&v)[0].contains("empty check"));
        let mut v = ok.clone();
        v["baseline_vs_exp1"]["all_identical"] = json!(false);
        assert!(parity_failures(&v)[0].contains("not all identical"));
        let mut v = ok.clone();
        v.as_object_mut().unwrap().remove("l0_historical_vs_exp1");
        assert!(parity_failures(&v)[0].contains("missing"));
        let mut v = ok;
        v["decode_scored_vs_decode"]["utterances_compared"] = json!(0);
        assert!(parity_failures(&v)[0].contains("nothing compared"));
    }

    #[test]
    fn dev_objective_is_an_equal_weight_mean_of_domains() {
        let d = |n: &str, p: &[(usize, usize)]| (n.to_owned(), p.to_vec());
        // Domain means 0.5 (one size) and 1.0 (mean of 0.5 and 1.5): 0.75.
        let o = dev_objective(&[
            d("librispeech_dev_other_600", &[(5, 10)]),
            d("spgispeech_dev", &[(5, 10), (30, 20)]),
        ])
        .unwrap();
        assert!((o - 0.75).abs() < 1e-12);
        // Not a pooled mean over (set, size) pairs, which would give 0.8333.
        assert!(dev_objective(&[]).is_err());
        assert!(dev_objective(&[d("librispeech_clean", &[(1, 2)])]).is_err());
        assert!(dev_objective(&[d("icsi_dev", &[])]).is_err());
        assert!(dev_objective(&[d("icsi_dev", &[(1, 0)])]).is_err());
        assert_eq!(DEV_DOMAINS.len(), 6);
    }

    #[test]
    fn keyword_targets_and_paths() {
        let sessions: BTreeSet<String> = ["s1", "s2"].map(String::from).into();
        let mut kw = HashMap::new();
        kw.insert(
            "s1".to_owned(),
            vec![
                "Neural  Nets".into(),
                "neural nets".into(),
                "Zorbin".into(),
                "!!".into(),
            ],
        );
        let t = super::super::keyword_targets(&sessions, &kw);
        assert_eq!(
            t["s1"],
            [
                ("neural nets".to_owned(), "Neural  Nets".to_owned()),
                ("zorbin".to_owned(), "Zorbin".to_owned())
            ]
        );
        assert!(t["s2"].is_empty());
        assert_eq!(
            super::super::keywords_path(Path::new("/o/slidespeech_test_lists.json")),
            PathBuf::from("/o/slidespeech_test_lists_keywords.json")
        );
        let v: Value = serde_json::from_str(r#"{"keywords": ["a b", " c ", ""]}"#).unwrap();
        assert_eq!(super::super::line_keywords(&v), ["a b", "c"]);
        let v: Value = serde_json::from_str(r#"{"keywords": "x; y z,w"}"#).unwrap();
        assert_eq!(super::super::line_keywords(&v), ["x", "y z", "w"]);
    }

    #[test]
    fn learned_graphs_use_case_variants_without_cancel() {
        let mut cache: PhraseCache = HashMap::new();
        cache.insert(
            "Zorbin".into(),
            [
                vec![vec![1, 2]],
                vec![vec![1, 2], vec![3, 2]],
                vec![vec![1, 2], vec![3, 2]],
            ],
        );
        cache.insert(
            "quax".into(),
            [
                vec![vec![4]],
                vec![vec![4], vec![5]],
                vec![vec![4], vec![5]],
            ],
        );
        let entries: Vec<String> = ["Zorbin", "quax", "Zorbin", "unencodable"]
            .map(String::from)
            .into();
        let (g, n) = learned_graph(&entries, &cache, false).unwrap().unwrap();
        assert_eq!(n, 2, "distinct encodable entries");
        assert_eq!(g.config(), LEARNED_GRAPH);
        let roots: Vec<u32> = g.candidates(BiasGraph::ROOT).iter().map(|c| c.0).collect();
        assert_eq!(roots, [1, 3, 4, 5]);
        assert!(
            learned_graph(&["unencodable".to_owned()], &cache, false)
                .unwrap()
                .is_none()
        );
    }

    /// Keyword lists (R2's `keyword_entry_surfaces`): an entry is encoded from
    /// its original and lowercase surfaces, and `entries` counts keywords
    /// case-insensitively; rare lists are unchanged.
    #[test]
    fn keyword_entries_use_original_and_lowercase_surfaces() {
        use super::super::cached_phrases;
        assert_eq!(exp2_terms::keyword_entry_surfaces("GPU"), ["GPU", "gpu"]);
        assert_eq!(exp2_terms::keyword_entry_surfaces("gpu"), ["gpu"]);
        // Cache: [plain, case variants of "GPU", union over "GPU" and "gpu"].
        let mut cache: PhraseCache = HashMap::new();
        let gpu_caps = vec![vec![7]]; // "GPU" and its variants
        let gpu_union = vec![vec![7], vec![8], vec![9]]; // + "gpu", "Gpu"
        cache.insert(
            "GPU".into(),
            [gpu_caps.clone(), gpu_caps.clone(), gpu_union.clone()],
        );
        cache.insert(
            "gpu".into(),
            [
                vec![vec![8]],
                vec![vec![8], vec![9]],
                vec![vec![8], vec![9]],
            ],
        );
        assert_eq!(cached_phrases(&cache, "GPU", true, true), Some(&gpu_union));
        assert_eq!(cached_phrases(&cache, "GPU", true, false), Some(&gpu_caps));
        assert_eq!(cached_phrases(&cache, "GPU", false, true), Some(&gpu_caps));
        let entries: Vec<String> = ["GPU", "gpu"].map(String::from).into();
        // A keyword list: one entry (case-insensitive), all three phrases.
        let (g, n) = learned_graph(&entries, &cache, true).unwrap().unwrap();
        assert_eq!(n, 1);
        let roots: Vec<u32> = g.candidates(BiasGraph::ROOT).iter().map(|c| c.0).collect();
        assert_eq!(roots, [7, 8, 9]);
        // A rare list: distinct strings, case variants of each as written.
        let (_, n) = learned_graph(&entries, &cache, false).unwrap().unwrap();
        assert_eq!(n, 2);
        // Keyword entries are no longer lowercased in the list itself.
        assert_eq!(
            super::super::list_casing(ListCondition::Keywords, Some(exp2_terms::Casing::Cased)),
            None
        );
    }

    #[test]
    fn node_pass_fit_recovers_a_line() {
        let passes: Vec<(usize, usize, u64)> = (1..20)
            .map(|k| (k * 500, 10, (2_000_000 + k * 500 * 3000) as u64))
            .collect();
        let s = node_pass_summary(&passes);
        let fit = &s["fit_ms"];
        assert!((fit["per_1000_nodes"].as_f64().unwrap() - 3.0).abs() < 1e-9);
        assert!((fit["intercept"].as_f64().unwrap() - 2.0).abs() < 1e-9);
        assert_eq!(s["dictionaries"], 19);
    }
}
