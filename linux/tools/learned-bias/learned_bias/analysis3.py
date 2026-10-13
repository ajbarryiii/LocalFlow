"""Experiment 3 analysis (DESIGN-3 "Evaluation", "Dev reporting") on the
evaluator's per-session output (`{out}/per_session.jsonl`, R1's schema: one
object per (row, set, size, session) with integer counts; `net_errors` =
errors − baseline_errors).

- `exploratory`: per held-out domain, the paired difference new − reference
  of net errors (summed over sizes per session; new rows averaged), as
  Σd / Σref words in WER points, with a 95% percentile bootstrap CI over
  sessions (10,000 resamples, seed 20261011).
- `earnings21`: the pre-registered verdict. Supported if the CI's upper
  bound is below 0; not supported if the point estimate is at least 0;
  inconclusive otherwise. Missing rows (any seed, call or size), a failed
  parity check, or a baseline-fallback selection mean "not supported".
- `stability`: the share of 1,000 session-level bootstrap resamples of the
  dev domains in which selection (select3's rule) picks the same
  (run, step), from a dev reporting run with per-session output.
- `sensitivity`: the CI half-width expected for a set of N sessions, by
  drawing N sessions at a time from existing per-session data (experiment
  2's GigaSpeech as the proxy for Earnings-21).

    python -m learned_bias.analysis3 earnings21 --per-session F --new R1,R2,R3 --ref REF \\
        --selection selection3.json --out e21.json
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

from . import SEED
from .devcheck import DEV_DOMAINS, LAMBDA_LITERALS, LAMBDAS  # noqa: F401 (LAMBDA_LITERALS re-exported)
from .select3 import BASELINE_RUN, candidate_key

BASELINE_ROW = "baseline"
SIZES = (100, 500, 1000)
BOOTSTRAP = 10000
STABILITY = 1000
TEXT_FIELDS = ("row", "set", "role", "session")
COUNT_FIELDS = ("size", "utterances", "ref_words", "sub", "del", "ins", "errors", "b_ref_words", "b_errors",
                "u_ref_words", "u_errors", "b_matched", "false_alarms", "fixed", "broken", "baseline_errors",
                "net_errors")


class AnalysisError(RuntimeError):
    pass


def _int(x):
    return isinstance(x, int) and not isinstance(x, bool)


class PerSession:
    """Validated per-session records keyed (row, set, size, session)."""

    def __init__(self, records):
        self.records = {}
        words = {}
        for r in records:
            for f in TEXT_FIELDS:
                if not isinstance(r.get(f), str) or not r[f]:
                    raise AnalysisError(f"record {r!r}: {f} is not a string")
            for f in COUNT_FIELDS:
                if not _int(r.get(f)):
                    raise AnalysisError(f"record {r.get('row')}/{r.get('set')}: {f} {r.get(f)!r} is not an int")
            if r["role"] not in ("dev", "held-out"):
                raise AnalysisError(f"record role {r['role']!r}")
            if r["size"] not in SIZES:
                raise AnalysisError(f"record size {r['size']}")
            if r["errors"] != r["sub"] + r["del"] + r["ins"]:
                raise AnalysisError(f"{r['row']}/{r['set']}/{r['session']}: errors != sub + del + ins")
            if r["b_errors"] + r["u_errors"] != r["errors"]:
                raise AnalysisError(f"{r['row']}/{r['set']}/{r['session']}: b_errors + u_errors != errors")
            if r["net_errors"] != r["errors"] - r["baseline_errors"]:
                raise AnalysisError(f"{r['row']}/{r['set']}/{r['session']}: net_errors != errors - baseline_errors")
            key = (r["row"], r["set"], r["size"], r["session"])
            if key in self.records:
                raise AnalysisError(f"duplicate record {key}")
            wk = (r["set"], r["size"], r["session"])
            if words.setdefault(wk, (r["ref_words"], r["baseline_errors"])) != (r["ref_words"], r["baseline_errors"]):
                raise AnalysisError(f"{wk}: rows disagree on ref_words or baseline_errors")
            self.records[key] = r

    def get(self, row, set_, size, session):
        return self.records.get((row, set_, size, session))

    def cells(self, row, set_):
        """{(size, session): record} of one row and set."""
        return {(k[2], k[3]): v for k, v in self.records.items() if k[0] == row and k[1] == set_}

    def sets(self, role=None):
        return sorted({k[1] for k, v in self.records.items() if role is None or v["role"] == role})


def read_per_session(path):
    with open(path) as f:
        return PerSession(json.loads(line) for line in f if line.strip())


# ------------------------------------------------------------ paired bootstrap


def _paired(ps, new_rows, ref_row, set_, sizes=None):
    """Per-session arrays (d, ref words): d = mean over new rows of Σ_sizes
    net − Σ_sizes net of the reference. Every row must cover exactly the
    reference's (size, session) cells (and all `sizes` if given)."""
    ref = ps.cells(ref_row, set_)
    if not ref:
        raise AnalysisError(f"missing row {ref_row!r} for {set_}")
    if sizes is not None:
        have = {z for z, _ in ref}
        if have != set(sizes):
            raise AnalysisError(f"{ref_row} on {set_} has sizes {sorted(have)}, expected {sorted(sizes)}")
        sessions = {s for _, s in ref}
        if set(ref) != {(z, s) for z in sizes for s in sessions}:
            raise AnalysisError(f"{ref_row} on {set_}: not every session has every size")
    if not new_rows:
        raise AnalysisError("no new rows")
    for row in new_rows:
        cells = ps.cells(row, set_)
        if not cells:
            raise AnalysisError(f"missing row {row!r} for {set_}")
        if set(cells) != set(ref):
            raise AnalysisError(f"missing cells: {row} and {ref_row} cover different sessions/sizes on {set_}")
    sessions = sorted({s for _, s in ref})
    idx = {s: i for i, s in enumerate(sessions)}
    d = np.zeros(len(sessions))
    words = np.zeros(len(sessions))
    for (z, s), r in ref.items():
        i = idx[s]
        words[i] += r["ref_words"]
        d[i] -= r["net_errors"]
        d[i] += sum(ps.get(row, set_, z, s)["net_errors"] for row in new_rows) / len(new_rows)
    return sessions, d, words


def _boot_ratio(d, words, resamples, seed):
    rng = np.random.default_rng(seed)
    n = len(d)
    idx = rng.integers(0, n, size=(resamples, n))
    num = d[idx].sum(axis=1)
    den = words[idx].sum(axis=1)
    return 100.0 * num / den


def paired_bootstrap(ps, new_rows, ref_row, set_, sizes=None, resamples=BOOTSTRAP, seed=SEED):
    """Σd/Σref words in WER points with a 95% percentile CI over sessions."""
    sessions, d, words = _paired(ps, list(new_rows), ref_row, set_, sizes)
    stats = _boot_ratio(d, words, resamples, seed)
    lo, hi = np.percentile(stats, [2.5, 97.5])
    point = 100.0 * d.sum() / words.sum()
    return {
        "set": set_, "new": list(new_rows), "reference": ref_row,
        "point": float(point), "ci": [float(lo), float(hi)],
        "sum_d": float(d.sum()), "sum_ref_words": int(words.sum()),
        "sessions": len(sessions), "resamples": resamples, "seed": seed,
    }


def exploratory(ps, new_rows, ref_row, sets=None, resamples=BOOTSTRAP, seed=SEED):
    """Per held-out domain (every held-out set by default)."""
    sets = sets or ps.sets(role="held-out")
    return {s: paired_bootstrap(ps, new_rows, ref_row, s, resamples=resamples, seed=seed) for s in sets}


def not_supported(out, reason, incomplete=False):
    return dict(out, verdict="not supported", reason=reason, incomplete=incomplete)


class PipelineError(RuntimeError):
    """A broken analysis pipeline (not a verdict): the run aborts with a
    non-zero exit and writes no verdict file."""


def read_json_object(path, what):
    """A JSON object from `path`, or AnalysisError naming `what` (missing,
    unreadable, malformed, or not an object)."""
    try:
        obj = json.loads(Path(path).read_text())
    except (OSError, ValueError, UnicodeDecodeError) as e:
        raise AnalysisError(f"{what} {path}: {e.__class__.__name__}: {e}") from None
    if not isinstance(obj, dict):
        raise AnalysisError(f"{what} {path} is not a JSON object")
    return obj


def normalize_words(text):
    """The evaluator's word normalization (lf-bench `wer::normalize`):
    lowercase; letters, digits and apostrophes kept, everything else a space;
    split on whitespace; apostrophes trimmed from word ends; empties dropped.
    Only a cross-check of the Rust counts (`read_rust_counts`)."""
    cleaned = "".join(c if (c.isalnum() or c == "'") else " " for c in text.lower())
    return [w.strip("'") for w in cleaned.split() if w.strip("'")]


RUST_COUNTS_NAME = "ref_counts.json"  # next to FREEZE.json, written by R1's reference-only pass
RUST_COUNTS_FORMAT = "lf-bias-eval reference counts v1"
RUST_SESSION_RULE = "field:session"


def read_rust_counts(path):
    """R1's reference-only counts (`wer::normalize`, no audio): (manifest
    sha256, {call: {"utterances", "ref_words"}}). The one place that knows
    the file's shape (format v1: manifest, manifest_sha256, session_rule,
    normalizer, manifest_lines, unscored_lines, utterances, ref_words,
    sessions [{session, utterances, ref_words}] sorted). Requires session
    rule field:session and, explicitly, no unscored lines (every Earnings-21
    line has words, so scored utterances = the frozen counts). Raises
    PipelineError if missing, malformed or inconsistent."""
    def fail(msg):
        return PipelineError(f"Rust reference counts {path}: {msg}")

    try:
        obj = read_json_object(path, "Rust reference counts")
    except AnalysisError as e:
        raise fail(e) from None
    if obj.get("format") != RUST_COUNTS_FORMAT:
        raise fail(f"format {obj.get('format')!r} != {RUST_COUNTS_FORMAT!r}")
    if obj.get("session_rule") != RUST_SESSION_RULE:
        raise fail(f"session_rule {obj.get('session_rule')!r} != {RUST_SESSION_RULE!r}")
    for k in ("manifest_lines", "unscored_lines", "utterances", "ref_words"):
        if not _int(obj.get(k)) or obj[k] < 0:
            raise fail(f"{k} {obj.get(k)!r} is not a count")
    if obj["unscored_lines"] != 0:
        raise fail(f"{obj['unscored_lines']} unscored lines; Earnings-21 is frozen with every line scored")
    if obj["utterances"] != obj["manifest_lines"]:
        raise fail(f"utterances {obj['utterances']} != manifest_lines {obj['manifest_lines']}")
    sessions = obj.get("sessions")
    if not isinstance(sessions, list) or not all(
            isinstance(s, dict) and isinstance(s.get("session"), str) and _int(s.get("utterances"))
            and _int(s.get("ref_words")) for s in sessions):
        raise fail("sessions is not a list of {session, utterances, ref_words}")
    names = [s["session"] for s in sessions]
    if names != sorted(set(names)):
        raise fail("sessions are not sorted and unique")
    if sum(s["utterances"] for s in sessions) != obj["utterances"] \
            or sum(s["ref_words"] for s in sessions) != obj["ref_words"]:
        raise fail("session counts do not sum to the totals")
    if not isinstance(obj.get("manifest_sha256"), str):
        raise fail("no manifest_sha256")
    return obj["manifest_sha256"], {s["session"]: {"utterances": s["utterances"], "ref_words": s["ref_words"]}
                                    for s in sessions}


def frozen_coverage(freeze_path, manifest=None, rust_counts=None):
    """The frozen Earnings-21 set: {"manifest_sha256", "calls": {call:
    {"utterances", "ref_words"}}}.
    - FREEZE.json and its manifest: the manifest hashes to the frozen
      sha256 and gives exactly the frozen calls with their utterance counts
      (AnalysisError otherwise: the coverage is not the frozen one).
    - Reference words: the Rust counts (`rust_counts`, default
      ref_counts.json next to FREEZE.json), bound to the same manifest
      sha256; the Python count must match them exactly per call. A missing
      or unbound counts file or any mismatch is a PipelineError."""
    from .provenance import sha256_file

    freeze = read_json_object(freeze_path, "FREEZE.json")
    try:
        path = Path(manifest or freeze["manifest"])
        sha = sha256_file(path)
    except (KeyError, TypeError, OSError) as e:
        raise AnalysisError(f"the frozen manifest: {e}") from None
    if sha != freeze.get("manifest_sha256"):
        raise AnalysisError(f"{path}: sha256 {sha} != frozen {freeze.get('manifest_sha256')}")
    calls = defaultdict(lambda: {"utterances": 0, "ref_words": 0})
    try:
        with open(path) as f:
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    c = calls[str(r["session"])]
                    c["utterances"] += 1
                    c["ref_words"] += len(normalize_words(r["text"]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        raise AnalysisError(f"{path}: malformed manifest ({e})") from None
    per_call = freeze.get("per_call")
    if not isinstance(per_call, dict):
        raise AnalysisError("FREEZE.json has no per_call object")
    problems = []
    if set(calls) != set(per_call) or len(calls) != freeze.get("calls"):
        problems.append(f"manifest calls {len(calls)} != frozen calls {freeze.get('calls')}/{len(per_call)}")
    for call, c in calls.items():
        want = per_call.get(call).get("utterances") if isinstance(per_call.get(call), dict) else None
        if c["utterances"] != want:
            problems.append(f"call {call}: {c['utterances']} utterances, frozen {want}")
    if sum(c["utterances"] for c in calls.values()) != freeze.get("utterances"):
        problems.append(f"manifest utterances != frozen {freeze.get('utterances')}")
    if problems:
        raise AnalysisError("the Earnings-21 freeze does not match its manifest: " + "; ".join(problems[:5]))
    # Reference words: Rust's, cross-checked exactly against the Python port.
    rust_path = Path(rust_counts) if rust_counts else Path(freeze_path).with_name(RUST_COUNTS_NAME)
    rust_sha, rust = read_rust_counts(rust_path)
    if rust_sha != sha:
        raise PipelineError(f"{rust_path} counts manifest {rust_sha}, not the frozen {sha}")
    if set(rust) != set(calls):
        raise PipelineError(f"{rust_path} covers other calls than the frozen manifest")
    diff = {c: (rust[c], calls[c]) for c in calls if rust[c] != calls[c]}
    if diff:
        raise PipelineError(f"Rust and Python reference counts differ (rust, python): "
                            f"{dict(sorted(diff.items())[:5])}")
    for c in calls:
        calls[c]["ref_words"] = rust[c]["ref_words"]  # Rust's are authoritative
    return {"manifest_sha256": sha, "calls": dict(calls), "ref_counts": str(rust_path)}


def coverage_problems(ps, rows, set_, sizes, frozen):
    """Every compared row covers exactly the frozen calls at every size, with
    the frozen utterance and reference-word counts."""
    p = []
    want = {(z, c) for z in sizes for c in frozen["calls"]}
    for row in rows:
        cells = ps.cells(row, set_)
        if not cells:
            p.append(f"row {row} has no {set_} output")
            continue
        missing, extra = want - set(cells), set(cells) - want
        if missing:
            p.append(f"{row}: {len(missing)} frozen (size, call) cells missing, e.g. {sorted(missing)[:3]}")
        if extra:
            p.append(f"{row}: {len(extra)} cells outside the freeze, e.g. {sorted(extra)[:3]}")
        for (z, c), r in sorted(cells.items()):
            f = frozen["calls"].get(c)
            if f and (r["utterances"], r["ref_words"]) != (f["utterances"], f["ref_words"]):
                p.append(f"{row}: call {c} size {z} has {r['utterances']} utterances / {r['ref_words']} words, "
                         f"frozen {f['utterances']} / {f['ref_words']}")
    return p


def results_problems(results, set_, frozen):
    """The evaluation that wrote the per-session data: no parity failures, and
    the set scored from the frozen manifest (its df=scored source)."""
    if not isinstance(results, dict):
        return ["results.json is not a JSON object"]
    p = []
    if results.get("parity_failures") != []:
        p.append(f"parity failures {results.get('parity_failures')!r}")
    dfs = results.get("df_source")
    df = dfs.get(set_) if isinstance(dfs, dict) else None
    if not isinstance(df, dict):
        p.append(f"results.json has no df_source.{set_}")
    else:
        # Exactly one manifest entry, an object naming the frozen sha256.
        mans = df.get("manifests")
        ok = (isinstance(mans, list) and len(mans) == 1 and isinstance(mans[0], dict)
              and mans[0].get("sha256") == frozen["manifest_sha256"])
        if df.get("split") != "scored" or not ok:
            p.append(f"{set_} was scored from {mans!r} ({df.get('split')}), not exactly the frozen manifest "
                     f"{frozen['manifest_sha256']}")
    return p


ROW_ID = re.compile(r"^(?P<variant>[^/]+)/(?P<run>[^/]+)/model-s(?P<step>\d+)@(?P<lam>[0-9.]+)$")
SEED_SET = (20261011, 20261012, 20261013)
# Allow-list (finding 8): the only run.json fields in which a seed replicate
# may differ from the selected run. Everything else (optimizer, lr, horizon,
# weight decay, batch, loss weights, window, variant and parameter count,
# shards/calls/decisions and their identity, train_df, export, dev command,
# subset flags, epochs, device, torch) must be equal, presence included.
REPLICATE_MAY_DIFFER = frozenset({
    "train_seed",            # the replicate's seed
    "step_plan",             # it stops at S: plan [S], not the 8-step plan
    "total_steps",
    "checkpoints_planned",
    "checkpoints",
    "checkpoint_stats",      # counts at its own checkpoints
})
REPLICATE_ARGS_MAY_DIFFER = frozenset({
    "run",                   # its name
    "train_seed",            # given only to replicates
    "checkpoint_steps",      # S versus the plan
    "fixed_lambda",          # replicate mode (checked to be the selected λ)
    "overwrite",             # bookkeeping, no effect on training
    "wait_gpu_lock",
    "log_every",             # logging cadence only
})


def run_json_shape(info):
    """Types of the run.json fields the seed checks read (re-check #9)."""
    p = []
    if not isinstance(info.get("args"), dict):
        p.append(f"args {info.get('args')!r} is not an object")
    elif not isinstance(info["args"].get("call_fraction", "1.0"), str):
        p.append(f"args.call_fraction {info['args'].get('call_fraction')!r} is not a string")
    if not isinstance(info.get("checkpoints"), list):
        p.append(f"checkpoints {info.get('checkpoints')!r} is not a list")
    if not _int(info.get("train_seed")):
        p.append(f"train_seed {info.get('train_seed')!r} is not an integer")
    return p


def config_problems(name, info, sel_info, sel_lambda):
    """Differences between a replicate's run.json and the selected run's,
    outside REPLICATE_MAY_DIFFER / REPLICATE_ARGS_MAY_DIFFER."""
    p = []
    for k in sorted((set(info) | set(sel_info)) - REPLICATE_MAY_DIFFER - {"args"}):
        if info.get(k, "<absent>") != sel_info.get(k, "<absent>"):
            p.append(f"{name}: run.json {k} differs from the selected run")
    a, b = info.get("args"), sel_info.get("args")
    if not isinstance(a, dict) or not isinstance(b, dict):
        return p + [f"{name}: run.json args is not an object"]
    for k in sorted((set(a) | set(b)) - REPLICATE_ARGS_MAY_DIFFER):
        if a.get(k, "<absent>") != b.get(k, "<absent>"):
            p.append(f"{name}: args.{k} {a.get(k, '<absent>')!r} != selected {b.get(k, '<absent>')!r}")
    if "fixed_lambda" in a and a["fixed_lambda"] != str(sel_lambda):
        p.append(f"{name}: args.fixed_lambda {a['fixed_lambda']} is not the selected λ {sel_lambda}")
    return p


def seed_row_problems(rows, selection, root):
    """The three seed rows (DESIGN-3 "Seed replicates"): exactly three
    distinct rows `L2/<run>/model-s{S}@{λ}` at the selected step S and λ, the
    20261011 row being the selected run itself and the others replicates
    with seeds 20261012 and 20261013 whose run.json equals the selected run's
    except for the allow-listed fields; no toy runs, no subsets. Never
    raises: malformed inputs are problems."""
    from .select3 import FROZEN_VARIANT, subset_of

    if not isinstance(rows, (list, tuple)) or len(rows) != 3 or len(set(rows)) != 3:
        return [f"need exactly three distinct seed rows, got {rows!r}"]
    if not isinstance(selection, dict) or selection.get("mode") != "global" \
            or not isinstance(selection.get("selected"), dict):
        return ["the selection is not a global selection3.json"]
    sel = selection["selected"]
    if not isinstance(sel.get("run"), str) or not _int(sel.get("step")) or sel.get("lambda") not in LAMBDAS:
        return [f"selection3.json selected {sel!r} is not a learned (run, step, λ)"]
    lit = LAMBDA_LITERALS[sel["lambda"]]
    try:
        sel_info = read_json_object(Path(root) / sel["run"] / "run.json", "selected run.json")
    except AnalysisError as e:
        return [str(e)]
    p = []
    seeds = {}
    for row in rows:
        m = ROW_ID.match(row) if isinstance(row, str) else None
        if not m:
            p.append(f"{row!r}: not a model row id")
            continue
        if m["variant"] != FROZEN_VARIANT or int(m["step"]) != sel["step"] or m["lam"] != lit:
            p.append(f"{row}: not {FROZEN_VARIANT} at the selected step {sel['step']} and λ {lit}")
        try:
            info = read_json_object(Path(root) / m["run"] / "run.json", f"{row}: run.json")
        except AnalysisError as e:
            p.append(str(e))
            continue
        shape = run_json_shape(info)
        if shape:
            p += [f"{row}: run {m['run']}: {x}" for x in shape]
            continue
        if info.get("toy") is not False:
            p.append(f"{row}: run {m['run']} is a toy run (toy={info.get('toy')!r})")
        for k in ("lr", "horizon_steps"):
            if info.get(k) != sel.get(k):
                p.append(f"{row}: {k} {info.get(k)!r}, selected {sel.get(k)!r}")
        if f"s{sel['step']}" not in (info.get("checkpoints") or []):
            p.append(f"{row}: run {m['run']} has no checkpoint s{sel['step']}")
        if subset_of(info) or info.get("variant") != FROZEN_VARIANT:
            p.append(f"{row}: run {m['run']} is not {FROZEN_VARIANT} on the full-data pool")
        seeds[row] = info.get("train_seed")
        if info.get("train_seed") == SEED_SET[0]:
            if m["run"] != sel["run"]:
                p.append(f"{row}: the seed-{SEED_SET[0]} row must be the selected run {sel['run']}")
        elif m["run"] != sel["run"]:
            p += [f"{row}: {x}" for x in config_problems(m["run"], info, sel_info, sel["lambda"])]
    if not p and sorted(seeds.values()) != list(SEED_SET):
        p.append(f"training seeds {sorted(map(str, seeds.values()))} are not {list(SEED_SET)}")
    return p


def earnings21_verdict(ps, new_rows, ref_row, *, frozen, set_="earnings21", sizes=SIZES, seeds=3,
                       parity_ok=True, selection_fallback=False, seed_problems=(), results=None,
                       resamples=BOOTSTRAP, seed=SEED):
    """DESIGN-3's confirmatory verdict: new L2 (its `seeds` distinct seed
    rows, averaged per call) versus `ref_row` on Earnings-21, over exactly
    the frozen calls (`frozen_coverage`). Fails closed: anything else is
    "not supported" with the reason."""
    out = {"comparison": {"new": list(new_rows), "reference": ref_row, "set": set_, "sizes": list(sizes)}}
    if selection_fallback:
        return not_supported(out, "selection fell back to the baseline")
    if not parity_ok:
        return not_supported(out, "a parity check failed")
    if len(new_rows) != seeds or len(set(new_rows)) != seeds:
        return not_supported(out, f"incomplete: need {seeds} distinct seed rows, got {list(new_rows)}", True)
    if seed_problems:
        return not_supported(out, "incomplete: seed rows: " + "; ".join(seed_problems), True)
    if results is not None:
        rp = results_problems(results, set_, frozen)
        if rp:
            return not_supported(out, "incomplete: evaluation: " + "; ".join(rp), True)
    cp = coverage_problems(ps, list(new_rows) + [ref_row], set_, sizes, frozen)
    if cp:
        return not_supported(out, "incomplete: " + "; ".join(cp[:5]), True)
    try:
        r = paired_bootstrap(ps, new_rows, ref_row, set_, sizes, resamples, seed)
    except AnalysisError as e:
        return not_supported(out, f"incomplete: {e}", True)
    if r["ci"][1] < 0:
        v = "supported"
    elif r["point"] >= 0:
        v = "not supported"
    else:
        v = "inconclusive"
    return dict(out, **{k: r[k] for k in ("point", "ci", "sum_d", "sum_ref_words", "sessions", "resamples",
                                          "seed")}, verdict=v, reason="rule", incomplete=False,
                frozen_calls=len(frozen["calls"]), manifest_sha256=frozen["manifest_sha256"])


# ------------------------------------------------------------ dev objective, stability


def _dev_arrays(ps, rows, domains):
    """Per domain: (sessions, errors [rows, sizes, sessions], baseline
    errors [sizes, sessions])."""
    out = {}
    for dom in domains:
        base = ps.cells(BASELINE_ROW, dom)
        if not base:
            raise AnalysisError(f"dev domain {dom} has no baseline rows")
        sizes = sorted({z for z, _ in base})
        sessions = sorted({s for _, s in base})
        if set(base) != {(z, s) for z in sizes for s in sessions}:
            raise AnalysisError(f"{dom}: not every session has every size")
        b = np.array([[base[(z, s)]["baseline_errors"] for s in sessions] for z in sizes], dtype=float)
        e = np.zeros((len(rows), len(sizes), len(sessions)))
        for i, row in enumerate(rows):
            cells = ps.cells(row, dom)
            if set(cells) != set(base):
                raise AnalysisError(f"{row} does not cover {dom}")
            e[i] = [[cells[(z, s)]["errors"] for s in sessions] for z in sizes]
        out[dom] = (sessions, e, b)
    return out


def _objectives(arrays, weights=None):
    """Mean over domains of the mean over sizes of Σerrors/Σbaseline errors
    (per row); `weights` {domain: session counts} for a resample. NaN where
    a denominator is 0."""
    per = []
    for dom, (sessions, e, b) in arrays.items():
        w = np.ones(len(sessions)) if weights is None else weights[dom]
        num = e @ w
        den = b @ w
        with np.errstate(divide="ignore", invalid="ignore"):
            per.append(np.where(den > 0, num / den, np.nan).mean(axis=1))
    return np.mean(per, axis=0)


def dev_grid(ps, candidates, domains=DEV_DOMAINS):
    """DESIGN-3 "Dev reporting": per candidate row, each domain's term (mean
    over sizes of Σerrors/Σbaseline errors) and the objective (their mean)."""
    rows = [c["row"] for c in candidates if c["run"] != BASELINE_RUN]
    arrays = _dev_arrays(ps, rows, domains)
    out = {row: {} for row in rows}
    for dom, (sessions, e, b) in arrays.items():
        terms = (e.sum(axis=2) / b.sum(axis=1)).mean(axis=1)
        for row, t in zip(rows, terms):
            out[row][dom] = float(t)
    for row in rows:
        out[row]["objective"] = float(np.mean([out[row][d] for d in domains]))
    return out


def dev_objectives(ps, rows, domains=DEV_DOMAINS):
    """The dev objective of each row, from per-session counts."""
    arrays = _dev_arrays(ps, list(rows), domains)
    return {row: float(v) for row, v in zip(rows, _objectives(arrays))}


def selection_stability(ps, candidates, domains=DEV_DOMAINS, run_order=None, resamples=STABILITY, seed=SEED):
    """Share of session-level bootstrap resamples (stratified by dev domain)
    in which the select3 rule picks the same (run, step) as on the full dev
    data. `candidates`: dicts with row, run, step, lr, lambda (select3's
    candidates; the baseline is added here)."""
    cands = [c for c in candidates if c["run"] != BASELINE_RUN]
    run_order = run_order or list(dict.fromkeys(c["run"] for c in cands))
    rows = [c["row"] for c in cands]
    arrays = _dev_arrays(ps, rows, domains)

    def winner(objs):
        if np.isnan(objs).any():
            return None
        pool = [{"run": BASELINE_RUN, "step": 0, "lambda": 0.0, "lr": 0.0, "objective": 1.0}]
        pool += [dict(c, objective=float(o)) for c, o in zip(cands, objs)]
        best = min(pool, key=lambda c: candidate_key(c, run_order))
        return (best["run"], best["step"])

    full = winner(_objectives(arrays))
    if full is None:
        raise AnalysisError("the dev objective is undefined on the full data")
    rng = np.random.default_rng(seed)
    counts = defaultdict(int)
    undefined = 0
    for _ in range(resamples):
        w = {dom: np.bincount(rng.integers(0, len(a[0]), size=len(a[0])), minlength=len(a[0])).astype(float)
             for dom, a in arrays.items()}
        win = winner(_objectives(arrays, w))
        if win is None:
            undefined += 1
        else:
            counts[f"{win[0]}/s{win[1]}"] += 1
    valid = resamples - undefined
    return {
        "winner": {"run": full[0], "step": full[1]},
        "share": counts.get(f"{full[0]}/s{full[1]}", 0) / valid if valid else float("nan"),
        "winners": dict(sorted(counts.items())),
        "undefined": undefined,
        "resamples": resamples,
        "seed": seed,
        "full_objectives": {c["row"]: float(o) for c, o in zip(cands, _objectives(arrays))},
    }


# ------------------------------------------------------------ sensitivity


def sensitivity(ps, new_row, ref_row, set_="gigaspeech", units=None, target_words=None, draws=BOOTSTRAP,
                seed=SEED):
    """Expected 95% CI half-width (WER points) of Σd/Σref for a set of
    `units` sessions drawn from `set_`'s sessions (or as many as hold
    `target_words` physical reference words at the source's mean session
    length: one size's words, since every size scores the same words)."""
    sessions, d, words = _paired(ps, [new_row], ref_row, set_)
    if (units is None) == (target_words is None):
        raise AnalysisError("give exactly one of units and target_words")
    ref = ps.cells(ref_row, set_)
    physical = {}
    for (z, s), r in ref.items():
        if physical.setdefault(s, r["ref_words"]) != r["ref_words"]:
            raise AnalysisError(f"{set_} session {s}: sizes disagree on reference words")
    mean_physical = float(np.mean(list(physical.values())))
    if target_words is not None:
        units = max(1, round(target_words / mean_physical))
    stats = _boot_ratio(d, words, draws, seed) if units == len(d) else None
    if stats is None:
        rng = np.random.default_rng(seed)
        idx = rng.integers(0, len(d), size=(draws, units))
        stats = 100.0 * d[idx].sum(axis=1) / words[idx].sum(axis=1)
    lo, hi = np.percentile(stats, [2.5, 97.5])
    return {
        "set": set_, "new": new_row, "reference": ref_row,
        "source_sessions": len(sessions), "source_mean_words": mean_physical,
        "units": int(units), "target_words": target_words,
        "half_width_points": float((hi - lo) / 2), "sd_points": float(stats.std()),
        "source_point": float(100.0 * d.sum() / words.sum()),
        "draws": draws, "seed": seed,
    }


# ------------------------------------------------------------ CLI


def earnings21_cli(a):
    """The registered verdict, always: failure states are decided before any
    evaluation output is read, and a missing or invalid output is itself
    "not supported"."""
    from .env import ConfigError, exp2_root

    new_rows = a.new.split(",")
    out = {"comparison": {"new": new_rows, "reference": a.ref, "set": a.set, "sizes": list(SIZES)}}
    try:
        sel = read_json_object(a.selection, "selection3.json")
    except AnalysisError as e:
        return not_supported(out, f"no valid selection3.json: {e}")
    if not isinstance(sel.get("baseline_fallback"), bool):
        return not_supported(out, f"{a.selection} has no boolean baseline_fallback")
    if sel["baseline_fallback"]:
        return not_supported(out, "selection fell back to the baseline")
    if a.parity_failed:
        return not_supported(out, "a parity check failed")
    if not a.per_session.exists():
        return not_supported(out, f"incomplete: no evaluation output {a.per_session}", True)
    results_path = a.results or a.per_session.with_name("results.json")
    if not results_path.exists():
        return not_supported(out, f"incomplete: no evaluation results {results_path}", True)
    try:
        root = a.runs_root or exp2_root() / "train"
        freeze = a.freeze or exp2_root() / "datasets" / "earnings21" / "FREEZE.json"
    except ConfigError as e:
        return not_supported(out, f"incomplete: {e}", True)
    # Every input validation step runs inside this handler: inputs that are
    # malformed anywhere (truncated, wrong JSON shape or type, schema errors)
    # give the registered failure verdict, never a traceback. A broken
    # reference-word count (PipelineError) is not caught: it aborts the run.
    try:
        seed_problems = seed_row_problems(new_rows, sel, root)
        frozen = frozen_coverage(freeze, a.manifest, a.ref_counts)
        ps = read_per_session(a.per_session)
        results = read_json_object(results_path, "results.json")
        return earnings21_verdict(ps, new_rows, a.ref, frozen=frozen, set_=a.set, seed_problems=seed_problems,
                                  results=results)
    except (AnalysisError, OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        return not_supported(out, f"incomplete: invalid input: {e}", True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--per-session", required=True, type=Path)
        p.add_argument("--out", required=True, type=Path)

    p = sub.add_parser("exploratory", help="per held-out domain paired bootstrap")
    common(p)
    p.add_argument("--new", required=True, help="new row(s), comma-separated (averaged)")
    p.add_argument("--ref", required=True)
    p.add_argument("--sets", default=None, help="sets (default every held-out set)")
    p = sub.add_parser("earnings21", help="the confirmatory verdict")
    common(p)
    p.add_argument("--new", required=True, help="the three seed rows, comma-separated")
    p.add_argument("--ref", required=True)
    p.add_argument("--set", default="earnings21")
    p.add_argument("--selection", required=True, type=Path, help="selection3.json (fallback, selected config)")
    p.add_argument("--parity-failed", action="store_true", help="a reference-row parity check failed")
    p.add_argument("--freeze", type=Path, default=None,
                   help="Earnings-21 FREEZE.json (default $LF_EXP2_ROOT/datasets/earnings21/FREEZE.json)")
    p.add_argument("--manifest", type=Path, default=None, help="the frozen manifest (default FREEZE.json's)")
    p.add_argument("--ref-counts", type=Path, default=None,
                   help=f"Rust reference-word counts (default {RUST_COUNTS_NAME} next to FREEZE.json)")
    p.add_argument("--results", type=Path, default=None,
                   help="the evaluation's results.json (default next to --per-session)")
    p.add_argument("--runs-root", type=Path, default=None,
                   help="training runs of the seed rows (default $LF_EXP2_ROOT/train)")
    p = sub.add_parser("stability", help="dev selection stability")
    common(p)
    p.add_argument("--selection", required=True, type=Path, help="selection3.json (its candidates and runs)")
    p = sub.add_parser("sensitivity", help="expected CI half-width from existing data")
    common(p)
    p.add_argument("--new", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--set", default="gigaspeech")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--units", type=int)
    g.add_argument("--target-words", type=int)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "earnings21":
            try:
                out = earnings21_cli(a)  # a verdict for every input problem
            except PipelineError as e:  # but no verdict from a broken pipeline
                print(f"pipeline error: {e}", file=sys.stderr)
                return 2
        elif a.cmd == "exploratory":
            ps = read_per_session(a.per_session)
            out = exploratory(ps, a.new.split(","), a.ref, a.sets.split(",") if a.sets else None)
        elif a.cmd == "stability":
            ps = read_per_session(a.per_session)
            sel = read_json_object(a.selection, "selection3.json")
            if sel.get("mode") != "global":
                raise AnalysisError(f"{a.selection} is not a global selection")
            out = selection_stability(ps, sel["candidates"], run_order=sel["runs"])
            out["grid"] = dev_grid(ps, sel["candidates"])
        else:
            ps = read_per_session(a.per_session)
            out = sensitivity(ps, a.new, a.ref, a.set, a.units, a.target_words)
    except AnalysisError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(out, indent=2, allow_nan=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
