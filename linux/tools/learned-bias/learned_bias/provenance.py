"""Shard provenance (review finding B3): before training, every shard must
come from the frozen training mix and the train split, name the export whose
joint weights compute the base logits, and carry one preparation policy per
dataset; the index must describe exactly the shards present and be complete.
Any mismatch refuses the run. Field names follow CONTRACT-2 NOTES "Shard
validation fields (R2), authoritative".
"""

import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path

from . import SEED, J
from .shards import Shard
from .splits import spgi_is_dev

# ---- Field-name table (R2, authoritative) --------------------------------
SHARD_FORMAT = "lf-bias-prep-v1"
INDEX_FORMAT = "lf-bias-prep-index-v2"
TRAIN_SPLIT = "train"
TRAIN_MIX = ("spgispeech", "slidespeech", "icsi")  # DESIGN.md, frozen
# The bundled `policy` object's keys; each is also a metadata field.
POLICY_KEYS = (
    "format", "dataset", "split", "casing", "targets_mode", "rare_rule", "df_source",
    "df_source_sha256", "split_rule", "manifest_sha256", "seed", "samples",
    "export_sha256", "cache_identity", "graph", "split_sessions", "split_sessions_sha256",
)
# The train split's reference casing per dataset (R2: casing per manifest;
# `mixed` within a split is rejected).
TRAIN_CASING = {"spgispeech": "cased", "slidespeech": "uncased", "icsi": "cased"}
SPLIT_RULES = {"spgispeech": "spgi call hash (exp2_data::spgi_is_dev)"}
SPLIT_RULE_OTHER = "manifest split field"
RARE_RULE = {"rule": "exp2_terms::is_target", "common_words": 5000, "requires_letter": True,
             "max_df_percent": 5, "min_df_limit": 2}
# The only supported learned-graph semantics (DESIGN.md "Candidates"): the
# policy's `graph` is exactly this JSON object.
GRAPH_SUPPORTED = {"case_variants": True, "cancel_unfinished": False}
# The split's expected session set: sha256 hex of the raw session ids,
# sorted bytewise and joined with "\n" (no trailing newline); with the count
# `split_sessions`.
SESSION_SET_FIELD = "split_sessions_sha256"
SESSION_COUNT_FIELD = "split_sessions"
# Index entry fields compared with the shard's own metadata.
ENTRY_FIELDS = ("dataset", "call", "session", "split", "sample", "policy_sha256", "df_source_sha256",
                "decisions", "nodes", "entries", "utterances", "corrections")
# Rust enc_cache::CacheIdentity (experiment 1's cache format).
CACHE_FORMAT = "lf-bias-eval projected encoder output v2"
PRECISION = "i8x2"
JOINT_PADDED = 640  # PackedDecoder::joint_padded for J = 640
# ---- end of table ----------------------------------------------------------


class ProvenanceError(RuntimeError):
    def __init__(self, problems):
        self.problems = list(problems)
        shown = "\n  ".join(self.problems[:50])
        more = f"\n  ... and {len(self.problems) - 50} more" if len(self.problems) > 50 else ""
        super().__init__(f"refusing to train: {len(self.problems)} provenance problem(s):\n  {shown}{more}")


def canonical(v):
    """serde_json's compact form of a json! value (keys sorted)."""
    return json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_hex(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file(path, chunk=1 << 22):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(chunk), b""):
            h.update(b)
    return h.hexdigest()


def export_paths(export):
    """(export dir, weights file) from either the directory or the file."""
    p = Path(export)
    if p.is_dir():
        man = json.loads((p / "manifest.json").read_text())
        return p, p / man.get("file", "export.safetensors")
    return p.parent, p


class ExportIdentity:
    """The identities Rust records for an export: `export_sha256` (sha256 of
    the manifest's format and file hashes) and `cache_identity`. The weights
    file is verified against the manifest, so the joint weights used for the
    base logits are the ones these identities name."""

    def __init__(self, export, verify_file=True):
        self.dir, self.weights = export_paths(export)
        man = json.loads((self.dir / "manifest.json").read_text())
        self.export_sha256 = sha256_hex(canonical({"format": man["format"], "files": man["files"]}).encode())
        self.cache_identity = sha256_hex(canonical({
            "format": CACHE_FORMAT,
            "export_sha256": self.export_sha256,
            "precision": PRECISION,
            "joint_padded": JOINT_PADDED,
        }).encode())
        rel = self.weights.relative_to(self.dir).as_posix()
        want = man["files"].get(rel)
        if want is None:
            raise ProvenanceError([f"{self.weights}: not listed in {self.dir}/manifest.json"])
        if verify_file:
            got = sha256_file(self.weights)
            if got != want:
                raise ProvenanceError([f"{self.weights}: sha256 {got} != manifest {want}"])


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _same(meta_value, policy_value):
    """A metadata string against the policy's value (strings verbatim, other
    JSON values as serialized by Rust)."""
    if meta_value is None:
        return False
    if isinstance(policy_value, str):
        return meta_value == policy_value
    try:
        return json.loads(meta_value) == policy_value
    except ValueError:
        return False


def shard_policy(meta, tag, full=True):
    """(policy object or None, problems) for one shard's metadata: the
    bundled policy string hashes to `policy_sha256`; every policy key the
    metadata repeats agrees with it; `call` = dataset/session; 0 <= sample <
    samples. `full` also requires exactly the production policy keys."""
    problems = []
    pol_s, sha = meta.get("policy"), meta.get("policy_sha256")
    if not pol_s or not sha:
        return None, [f"{tag}: no policy/policy_sha256"]
    if sha256_hex(pol_s.encode()) != sha:
        problems.append(f"{tag}: policy_sha256 {sha} does not hash its policy string")
    try:
        pol = json.loads(pol_s)
    except ValueError:
        return None, problems + [f"{tag}: policy is not JSON"]
    if not isinstance(pol, dict):
        return None, problems + [f"{tag}: policy is not an object"]
    if full and set(pol) != set(POLICY_KEYS):
        problems.append(f"{tag}: policy keys {sorted(pol)} != {sorted(POLICY_KEYS)}")
    for k, v in pol.items():
        if k in meta and not _same(meta[k], v):
            problems.append(f"{tag}: metadata {k}={meta[k][:80]!r} disagrees with its policy ({canonical(v)[:80]})")
        elif full and k not in meta:
            problems.append(f"{tag}: metadata lacks policy field {k!r}")
    ds, sess, call = meta.get("dataset"), meta.get("session"), meta.get("call")
    if not ds or not sess or call != f"{ds}/{sess}":
        problems.append(f"{tag}: call {call!r} != dataset/session ({ds!r}/{sess!r})")
    s, n = _num(meta.get("sample")), _num(meta.get("samples"))
    if s is None or n is None or not (0 <= s < n) or s != int(s):
        problems.append(f"{tag}: sample {meta.get('sample')!r} not in [0, samples={meta.get('samples')!r})")
    return pol, problems


def production_policy_problems(pol, meta, tag, ident, split, train_mix):
    """The policy values a training shard must have."""
    p = []
    ds = pol.get("dataset")
    if pol.get("format") != SHARD_FORMAT:
        p.append(f"{tag}: format {pol.get('format')!r} != {SHARD_FORMAT!r}")
    if pol.get("split") != split or meta.get("split") != split:
        p.append(f"{tag}: split {pol.get('split')!r} is not {split!r}")
    if ds not in train_mix:
        p.append(f"{tag}: dataset {ds!r} is not in the training mix {list(train_mix)}")
    if str(pol.get("seed")) != str(SEED):
        p.append(f"{tag}: seed {pol.get('seed')!r} != {SEED}")
    if pol.get("export_sha256") != ident.export_sha256:
        p.append(f"{tag}: export_sha256 {pol.get('export_sha256')!r} != {ident.export_sha256}")
    if pol.get("cache_identity") != ident.cache_identity:
        p.append(f"{tag}: cache_identity {pol.get('cache_identity')!r} != {ident.cache_identity}")
    want_casing = TRAIN_CASING.get(ds)
    if pol.get("casing") not in ("cased", "uncased"):
        p.append(f"{tag}: casing {pol.get('casing')!r} (only cased or uncased; mixed is rejected)")
    elif want_casing and pol["casing"] != want_casing:
        p.append(f"{tag}: casing {pol['casing']!r}, but {ds} train is frozen as {want_casing!r}")
    want_rule = SPLIT_RULES.get(ds, SPLIT_RULE_OTHER)
    if pol.get("split_rule") != want_rule:
        p.append(f"{tag}: split_rule {pol.get('split_rule')!r} != {want_rule!r}")
    if ds == "spgispeech" and spgi_is_dev(str(meta.get("session"))):
        p.append(f"{tag}: SPGISpeech session {meta.get('session')!r} is a dev call by the split hash")
    if not is_sha256(pol.get("manifest_sha256")):
        p.append(f"{tag}: manifest_sha256 {pol.get('manifest_sha256')!r} is not a sha256")
    if not isinstance(pol.get("samples"), int) or isinstance(pol.get("samples"), bool) or pol["samples"] < 1:
        p.append(f"{tag}: samples {pol.get('samples')!r} is not a positive integer")
    if not _int(pol.get("split_sessions")) or pol["split_sessions"] < 1:
        p.append(f"{tag}: policy split_sessions {pol.get('split_sessions')!r} is not a positive integer")
    if not is_sha256(pol.get("split_sessions_sha256")):
        p.append(f"{tag}: policy split_sessions_sha256 {pol.get('split_sessions_sha256')!r} is not a sha256")
    p += [f"{tag}: {x}" for x in graph_problems(pol.get("graph"))]
    mode, rule, df = pol.get("targets_mode"), pol.get("rare_rule"), pol.get("df_source")
    if mode == "rare":
        if (not isinstance(rule, dict) or set(rule) != set(RARE_RULE) | {"common_words_file_sha256"}
                or any(rule.get(k) != v or type(rule.get(k)) is not type(v) for k, v in RARE_RULE.items())
                or not is_sha256(rule.get("common_words_file_sha256"))):
            p.append(f"{tag}: rare_rule {canonical(rule)[:160]} is not the frozen rule "
                     f"(with a sha256 of the common-words file)")
        p += [f"{tag}: {x}" for x in df_source_problems(df)]
        if not is_sha256(pol.get("df_source_sha256")):
            p.append(f"{tag}: df_source_sha256 {pol.get('df_source_sha256')!r} is not a sha256")
    elif mode == "keywords":
        kw = rule.get("keywords_file_sha256") if isinstance(rule, dict) else None
        if (not isinstance(rule, dict) or set(rule) != {"rule", "keywords_file_sha256"}
                or rule.get("rule") != "keywords" or not (kw is None or is_sha256(kw))):
            p.append(f"{tag}: keywords mode with rare_rule {canonical(rule)[:160]}")
        if df is not None or pol.get("df_source_sha256") != "none":
            p.append(f"{tag}: keywords mode with a df_source")
    else:
        p.append(f"{tag}: targets_mode {mode!r}")
    return p


def is_sha256(v):
    return isinstance(v, str) and len(v) == 64 and all(c in "0123456789abcdef" for c in v)


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def df_source_problems(df):
    """The frozen DF source of rare-word targets: the train split's manifests
    (non-empty, each with a path and sha256), the session count, and max_df =
    max(floor(MAX_DF_PERCENT% of sessions), MIN_DF_LIMIT)."""
    if not isinstance(df, dict) or set(df) != {"manifests", "split", "sessions", "max_df"}:
        return [f"df_source {canonical(df)[:160]} does not have exactly manifests/split/sessions/max_df"]
    p = []
    if df["split"] != TRAIN_SPLIT:
        p.append(f"df_source is not the train split ({df['split']!r})")
    mans = df["manifests"]
    if (not isinstance(mans, list) or not mans
            or any(not isinstance(m, dict) or set(m) != {"path", "sha256"} or not isinstance(m["path"], str)
                   or not m["path"] or not is_sha256(m["sha256"]) for m in mans)):
        p.append(f"df_source manifests {canonical(mans)[:160]} are not [{{path, sha256}}, ...]")
    s, k = df["sessions"], df["max_df"]
    if not _int(s) or s < 1:
        p.append(f"df_source sessions {s!r} is not a positive integer")
    elif not _int(k) or k != max(s * RARE_RULE["max_df_percent"] // 100, RARE_RULE["min_df_limit"]):
        p.append(f"df_source max_df {k!r} != max(floor({RARE_RULE['max_df_percent']}% of {s}), "
                 f"{RARE_RULE['min_df_limit']})")
    return p


def graph_problems(graph):
    """The supported learned-graph semantics: `graph` is exactly the JSON
    object {"case_variants": true, "cancel_unfinished": false}; unknown or
    missing keys are rejected."""
    if not isinstance(graph, dict):
        return [f"graph {graph!r} is not a JSON object"]
    p = []
    for k, v in GRAPH_SUPPORTED.items():
        if k not in graph or graph[k] is not v:
            p.append(f"graph {k}={graph.get(k, '<missing>')!r}, only {k}={canonical(v)} is supported")
    extra = sorted(set(graph) - set(GRAPH_SUPPORTED))
    if extra:
        p.append(f"graph has unsupported settings {extra}")
    return p


def session_set_sha256(sessions):
    """sha256 hex of the session ids sorted bytewise, joined with "\\n"."""
    return sha256_hex("\n".join(sorted(sessions, key=lambda s: s.encode())).encode())


def validate_training_shards(prep_dir, export, split=TRAIN_SPLIT, train_mix=TRAIN_MIX, identity=None):
    """Validate the index and every shard of `split`; returns the Shards in
    index order. Raises ProvenanceError listing every problem."""
    prep_dir = Path(prep_dir).resolve()
    problems = []
    ident = identity or ExportIdentity(export)
    index_path = prep_dir / "index.json"
    if not index_path.exists():
        raise ProvenanceError([f"{index_path} is missing (experiment runs need the index)"])
    index = json.loads(index_path.read_text())
    if index.get("format") != INDEX_FORMAT:
        problems.append(f"index format {index.get('format')!r} != {INDEX_FORMAT!r}")
    if index.get("shard_format") != SHARD_FORMAT:
        problems.append(f"index shard_format {index.get('shard_format')!r} != {SHARD_FORMAT!r}")
    if index.get("complete") is not True:
        problems.append(f"index complete is {index.get('complete')!r}, not true")
    splits = index.get("splits")
    if not isinstance(splits, dict) or not isinstance(splits.get(split), dict):
        raise ProvenanceError(problems + [f"index has no splits.{split}"])
    entries = splits[split].get("shards")
    if not isinstance(entries, list) or not entries:
        raise ProvenanceError(problems + [f"index splits.{split}.shards is empty or missing"])

    # Completeness: the index lists exactly the shard files present.
    split_dir = (prep_dir / split).resolve()
    listed = {}
    for e in entries:
        rel = e.get("path") if isinstance(e, dict) else None
        if not rel:
            problems.append(f"index entry without a path: {e!r}")
            continue
        p = (prep_dir / rel).resolve()
        if p.parent != split_dir:
            problems.append(f"index entry {rel} is not in {split}/")
        if p in listed:
            problems.append(f"index lists {rel} twice")
        listed[p] = e
    present = {p.resolve() for p in split_dir.glob("*.safetensors")}
    for p in sorted(present - set(listed)):
        problems.append(f"{p.name}: present in {split}/ but not in the index")
    for p in sorted(set(listed) - present):
        problems.append(f"{p.name}: in the index but missing")

    # Calls of other splits (no call may be in two splits).
    other_calls = defaultdict(set)
    for name, s in splits.items():
        if name != split and isinstance(s, dict):
            for e in s.get("shards") or []:
                if isinstance(e, dict) and e.get("call") is not None:
                    other_calls[str(e["call"])].add(name)

    shards = []
    keys = set()
    per_ds = defaultdict(lambda: {"sha": None, "policy": None, "tag": None, "n": 0,
                                  "sessions": defaultdict(set), "counts": set(), "manifests": set()})
    totals = defaultdict(float)
    for p, e in listed.items():
        if p not in present:
            continue
        try:
            sh = Shard(p)
        except Exception as ex:  # noqa: BLE001 (report every unreadable shard)
            problems.append(f"{p.name}: unreadable ({ex})")
            continue
        m, tag = sh.meta, p.name
        pol, pp = shard_policy(m, tag, full=True)
        problems += pp
        if pol is not None:
            problems += production_policy_problems(pol, m, tag, ident, split, train_mix)
            d = per_ds[sh.dataset]
            if d["sha"] is None:
                d.update(sha=m["policy_sha256"], policy=pol, tag=tag)
            elif d["sha"] != m.get("policy_sha256"):
                problems.append(f"{tag}: policy_sha256 differs from {d['tag']} (one policy per dataset)")
        per_ds[sh.dataset]["n"] += 1
        per_ds[sh.dataset]["sessions"][str(m.get("session"))].add(sh.sample)
        per_ds[sh.dataset]["counts"].add((m.get(SESSION_COUNT_FIELD), m.get(SESSION_SET_FIELD)))
        per_ds[sh.dataset]["manifests"].add(m.get("manifest_sha256"))
        if not is_sha256(m.get(SESSION_SET_FIELD)):
            problems.append(f"{tag}: {SESSION_SET_FIELD} {m.get(SESSION_SET_FIELD)!r} is not a sha256")
        key = (sh.call, sh.sample)
        if key in keys:
            problems.append(f"{tag}: duplicate (call, sample) {key}")
        keys.add(key)
        for s in sorted(other_calls.get(str(sh.call), ())):
            problems.append(f"{tag}: call {sh.call!r} also appears in split {s!r}")
        for f in ENTRY_FIELDS:
            if f not in e:
                problems.append(f"{tag}: index entry lacks {f!r}")
                continue
            mv = sh.decisions if f == "decisions" else m.get(f)
            a, b = _num(e[f]), _num(mv)
            if not ((a is not None and b is not None and a == b) or str(e[f]) == str(mv)):
                problems.append(f"{tag}: index {f}={e[f]!r} but shard has {mv!r}")
        if _num(m.get("decisions")) != sh.decisions:
            problems.append(f"{tag}: metadata decisions {m.get('decisions')!r} != {sh.decisions} rows")
        if sh.joint_dim != J:
            problems.append(f"{tag}: enc/pred width {sh.joint_dim} != {J}")
        totals["shards"] += 1
        totals["decisions"] += sh.decisions
        shards.append(sh)

    # The index's per-dataset policy and completeness.
    dsets = index.get("datasets") if isinstance(index.get("datasets"), dict) else {}
    for ds in train_mix:
        if per_ds[ds]["n"] == 0:
            problems.append(f"dataset {ds!r} of the training mix has no {split} shards")
    for ds, d in per_ds.items():
        if d["n"] == 0:
            continue
        # The set's manifest identity (one file's sha256, or the sha256 of
        # several sorted hashes; opaque here) is one value per dataset.
        if len(d["manifests"]) != 1:
            problems.append(f"{ds}/{split}: manifest_sha256 differs across shards: {sorted(map(str, d['manifests']))}")
        # Completeness from the shards' own metadata, never the index: one
        # session count and session-set hash per dataset; the sessions
        # present are exactly that set; each has samples 0..samples-1.
        expected = None
        if len(d["counts"]) != 1:
            problems.append(f"{ds}/{split}: shards disagree on ({SESSION_COUNT_FIELD}, {SESSION_SET_FIELD}): "
                            f"{sorted(map(str, d['counts']))}")
        else:
            (count_s, set_sha), = d["counts"]
            sessions = d["sessions"]
            count = _num(count_s)
            if count is None or count != int(count) or count < 1:
                problems.append(f"{ds}/{split}: {SESSION_COUNT_FIELD} {count_s!r} is not a positive integer")
            elif len(sessions) != count:
                problems.append(f"{ds}/{split}: {len(sessions)} sessions present, "
                                f"{SESSION_COUNT_FIELD} = {int(count)}")
            if session_set_sha256(sessions) != set_sha:
                problems.append(f"{ds}/{split}: the sessions present do not hash to {SESSION_SET_FIELD} "
                                f"{set_sha!r} (missing or extra sessions)")
            samples = d["policy"].get("samples") if d["policy"] else None
            if _int(samples) and samples >= 1:
                want = set(range(samples))
                for sess, got in sorted(sessions.items()):
                    if got != want:
                        problems.append(f"{ds}/{split}: session {sess!r} has samples {sorted(got)}, "
                                        f"expected {sorted(want)}")
                if count is not None:
                    expected = int(count) * samples
            if expected is not None and expected != d["n"]:
                problems.append(f"{ds}/{split}: {d['n']} shards, expected {expected} from the metadata")
        g = ((dsets.get(ds) or {}).get("splits") or {}).get(split)
        if not isinstance(g, dict):
            problems.append(f"index has no datasets.{ds}.splits.{split}")
            continue
        if g.get("complete") is not True:
            problems.append(f"index datasets.{ds}.splits.{split}.complete is {g.get('complete')!r}")
        exp_n, pres_n = _num(g.get("expected_shards")), _num(g.get("present_shards"))
        if exp_n != expected or pres_n != d["n"]:
            problems.append(f"{ds}/{split}: index expected_shards {g.get('expected_shards')!r}, present_shards "
                            f"{g.get('present_shards')!r}; derived {expected}, counted {d['n']}")
        # (The index's policy object, compared below, carries the hash too.)
        if g.get(SESSION_SET_FIELD) is not None and g[SESSION_SET_FIELD] not in {s for _, s in d["counts"]}:
            problems.append(f"{ds}/{split}: index {SESSION_SET_FIELD} differs from the shards'")
        if d["sha"] is not None:
            if g.get("policy_sha256") != d["sha"]:
                problems.append(f"{ds}/{split}: index policy_sha256 {g.get('policy_sha256')!r} != shards' {d['sha']}")
            if g.get("policy") != d["policy"]:
                problems.append(f"{ds}/{split}: index policy object differs from the shards' policy")
    t = splits[split].get("totals")
    if not isinstance(t, dict):
        problems.append(f"index splits.{split}.totals missing")
    else:
        for f in ("shards", "decisions"):
            if _num(t.get(f)) is None or not math.isclose(_num(t[f]), totals[f]):
                problems.append(f"index splits.{split}.totals.{f}={t.get(f)!r} != {totals[f]:.0f} counted")
    if problems:
        raise ProvenanceError(problems)
    return shards
