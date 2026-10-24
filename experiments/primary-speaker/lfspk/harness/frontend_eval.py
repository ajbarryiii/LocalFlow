"""`evaluate frontend`: metrics, selection, report and apply for front ends that
change the transcript (DESIGN.md 14.2; W5 DESIGN 9.2-9.6, 10.2-10.3).

    ./python      -m lfspk.harness.frontend_eval stage-a --set dev-v1 --frontend SPEC [--arg k=v] [--condition SLUG] [--exploratory]
    ./python-nemo -m lfspk.harness.frontend_eval stage-b --set dev-v1 --frontend SPEC [--arg k=v] --config C1 [--condition SLUG]
    ./python-nemo -m lfspk.harness.frontend_eval stage-b --set dev-v1 --bstar [--exploratory]
    ./python      -m lfspk.harness.frontend_eval purge   --set dev-v1 --frontend SPEC --condition SLUG --configs C1,C3
    ./python      -m lfspk.harness.frontend_eval select  --set dev-v1 --frontend SPEC --filter DIR[,DIR] ...
    ./python      -m lfspk.harness.frontend_eval report  --set dev-v1 --half B --selection SEL --frontend SPEC --filter ... [--bstar]
    ./python      -m lfspk.harness.frontend_eval apply   --set noise-dev-v1 --selection SEL --frontend SPEC [--half B|all]
    ./python-nemo -m lfspk.harness.frontend_eval latency --set dev-v1 --frontend SPEC [--encoder]

Stages A and B live in fe_stage_a / fe_stage_b and the metric definitions in
tmetrics. Everything here is relative to B (the harness's ASR cache) and uses
W0's exact re-aligned accounting. Every accounting dependency is imported at
module top level, so that the closure hash (`closure_sha256`) covers it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from .. import paths
from ..extract import cachepin
from . import evaluate as E
from . import fe_registry as R
from . import fe_stage_a as A
from . import fe_stage_b as B
from . import metrics as M
from . import tmetrics as T
from .align import decision_span, normalize, tokens_from_words, transfer_times
from .frozen import FrozenSet
from .refs import ASR_DIR, mixture_record, placed_words

OUT = paths.RUNS / "W0" / "frontend"
CODE_ROOT = Path(__file__).resolve().parents[2]  # the code whose closure is hashed (not the registration repository)
CONFIGS = ("C1", "C2", "C3", "C4")
CONSERVATIVE = ("C4", "C3", "C2", "C1")
BUDGET = 0.005  # gross L+ budget, pooled S0-S4 (contract)
NONINF_S0 = 0.001  # +0.10 points: the S0 non-inferiority margin
R_MARGIN = 0.02  # W5 9.3: non-inferior to the reference configuration within two points
STATS = ("R", "L+", "G", "G_u", "net_L", "G_u-L+", "E", "WER", "dWER", "other", "d_other", "coverage")
KIND = "w0f-selection"


def canon(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _f(x) -> float | None:
    x = float(x)
    return x if np.isfinite(x) else None


# --- evaluation records (fe-6) ---------------------------------------------------------------


@dataclass
class Rec:
    id: str
    row: dict
    labels: np.ndarray
    target_ref: list
    int_refs: list
    b_hyp: list
    b_f0: np.ndarray  # decision frames of B's tokens (the word record's)
    b_f1: np.ndarray
    b_tgtc: np.ndarray  # B tokens attributed target with an exact match (W0's fixed-alignment "removed" candidates)
    b_eval: T.HypEval
    unreach: frozenset
    dropout_b: bool
    dry_wer: float


def references(row: dict, labels: np.ndarray, target_active: np.ndarray, asr: dict, corpus) -> tuple[list, list]:
    """The references `refs.mixture_record` builds, by the same calls; the
    full-record guard in build_records proves they are the ones words.jsonl was
    made from."""
    mid, F = row["id"], labels.size
    if corpus is not None:
        target_ref = placed_words(corpus, row["meta"]["target"]["placements"], F, min_inside=0.0)
        int_refs = [placed_words(corpus, it["placements"], F) for it in row["meta"]["interferers"]]
        return target_ref, int_refs
    tdry = tokens_from_words([tuple(w) for w in asr[f"tdry:{mid}"]["words"]])
    act = np.flatnonzero(target_active)
    fallback = (act[0] / 100.0, (act[-1] + 1) / 100.0) if act.size else (0.0, F / 100.0)
    target_ref = transfer_times(normalize(row["meta"]["target"]["text"]), tdry, fallback)
    int_refs = [tokens_from_words([tuple(w) for w in asr[f"idry:{mid}:{k}"]["words"]]) for k in range(len(row["files"]["interferers_dry"]))]
    return target_ref, int_refs


def b_keys(row: dict) -> list[str]:
    """The B records a mixture's word record is built from."""
    return [f"mix:{row['id']}", f"tdry:{row['id']}"] + [f"idry:{row['id']}:{k}" for k in range(len(row["files"]["interferers_dry"]))]


def build_records(fs: FrozenSet, rows: list[dict], b_recs: dict, words: dict, corpus) -> list[Rec]:
    """Records of `rows` with the reference guard (design-r1 #1): the
    forced-alignment file pinned to each row's render-time hash, and B's whole
    word record recomputed with refs.mixture_record and equal to words.jsonl."""
    if corpus is not None:
        have = corpus.index_hashes()["alignment"]
        bad = [r["id"] for r in rows if r["meta"].get("index_hashes", {}).get("alignment") != have]
        if bad:
            raise SystemExit(f"the forced-alignment file differs from the one {len(bad)} mixtures were rendered with ({bad[:3]})")
    out = []
    for row in rows:
        lab = fs.labels(row)
        stored = words.get(row["id"])
        if stored is None:
            raise SystemExit(f"{row['id']}: no word record")
        now = json.loads(json.dumps(mixture_record(row, lab["labels"], lab["target_active"], b_recs, corpus)))
        if canon(now) != canon(stored):
            diff = sorted(k for k in set(now) | set(stored) if now.get(k) != stored.get(k))
            raise SystemExit(f"{row['id']}: B's word record differs from words.jsonl in {diff}: references or B drifted")
        tref, irefs = references(row, lab["labels"], lab["target_active"], b_recs, corpus)
        if [[w.text, round(w.start, 3), round(w.end, 3)] for w in tref] != stored["target_ref"] \
                or [len(r) for r in irefs] != stored["n_interferer_ref"]:
            raise SystemExit(f"{row['id']}: the references used differ from the word record")
        b_hyp = tokens_from_words([tuple(w) for w in b_recs[f"mix:{row['id']}"]["words"]])
        toks = stored["tokens"]
        if [t[0] for t in toks] != [w.text for w in b_hyp]:
            raise SystemExit(f"{row['id']}: B's tokens differ from the word record")
        b_eval = T.evaluate_hyp(b_hyp, tref, irefs, lab["labels"])
        dropout_b = T.is_dropout(b_eval, stored["dry_target_wer"])
        if dropout_b != bool(stored["dropout"]):
            raise SystemExit(f"{row['id']}: the dropout rule disagrees with the word record")
        out.append(Rec(row["id"], row, lab["labels"], tref, irefs, b_hyp, np.array([t[1] for t in toks], np.int64),
                       np.array([t[2] for t in toks], np.int64), np.array([t[4] == "target" and t[5] == "C" for t in toks], bool),
                       b_eval, T.unreachable(b_hyp, tref), dropout_b, float(stored["dry_target_wer"])))
    return out


def read_words(path: Path) -> dict[str, dict]:
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"{p}: words.jsonl (the set's B word records) is required")
    return {r["id"]: r for r in (json.loads(l) for l in p.read_text().splitlines() if l.strip())}


# --- systems -------------------------------------------------------------------------------------


def hyp_of(entry: dict) -> list:
    return tokens_from_words([tuple(w) for w in entry["words"]])


def sys_hyps(recs: list[Rec], entries: dict) -> list[list]:
    """A system's hypotheses in manifest row order. A mixture whose speaker's
    stream does not reach k has no entry; it gets B's hypothesis as a
    placeholder, and every statistic masks it out (headline_mask requires the
    condition), as W0's scorer path does with zero scores (code3-r1 #4)."""
    return [hyp_of(entries[f"mix:{r.id}"]) if f"mix:{r.id}" in entries else r.b_hyp for r in recs]


def filter_hyps(recs: list[Rec], flt: "Filter", tau: float, have: set, cond: tuple = None) -> list[list]:
    """B's tokens kept by word filter `flt` at tau; B's hypothesis as a
    placeholder where the condition does not exist (masked out)."""
    cond = cond or A.HEADLINE
    return [keep(r.b_hyp, means_over(flt.frames(cond, r.id), r.b_f0, r.b_f1), tau) if r.id in have else r.b_hyp for r in recs]


def stacked_hyps(recs: list[Rec], fh: list[list], flt: "Filter", tau: float, have: set) -> list[list]:
    return [keep(h, means_over(flt.frames(A.HEADLINE, r.id), *spans_of(h, r.labels.size)), tau) if r.id in have else h
            for r, h in zip(recs, fh)]


def counts_of(rec: Rec, hyp: list) -> np.ndarray:
    x = T.evaluate_hyp(hyp, rec.target_ref, rec.int_refs, rec.labels)
    return T.mix_counts(x, rec.b_eval, rec.unreach, T.is_dropout(x, rec.dry_wer), rec.dropout_b)


def matrix(recs: list[Rec], hyps: list[list]) -> np.ndarray:
    return np.stack([counts_of(r, h) for r, h in zip(recs, hyps)]) if recs else np.zeros((0, len(T.COLS)))


def means_over(scores: np.ndarray, f0: np.ndarray, f1: np.ndarray) -> np.ndarray:
    """Mean frame score over each token's decision frames [f0, f1)."""
    c = np.concatenate([[0.0], np.cumsum(np.asarray(scores, np.float64))])
    return (c[f1] - c[f0]) / np.maximum(f1 - f0, 1)


def spans_of(hyp: list, n_frames: int) -> tuple[np.ndarray, np.ndarray]:
    """The contract's decision frames (80 ms widening) of any system's tokens."""
    sp = [decision_span(w.start, w.end, n_frames) for w in hyp]
    return np.array([a for a, _ in sp], np.int64), np.array([b for _, b in sp], np.int64)


def keep(hyp: list, means: np.ndarray, tau: float) -> list:
    return [h for h, m in zip(hyp, means) if m >= tau]


def steps(recs: list[Rec], hyps: list[list], means: list[np.ndarray]) -> list:
    return [T.step_counts(h, m, lambda kept, r=r: counts_of(r, kept)) for r, h, m in zip(recs, hyps, means)]


def fixed_removed(recs: list[Rec], means: list[np.ndarray], tau: float) -> float | None:
    """W0's fixed-alignment "target removed" at tau (B tokens attributed target
    with an exact match whose mean is below tau, over reference words),
    reported beside the re-aligned L+."""
    rem = sum(int(np.sum(r.b_tgtc & (m < tau))) for r, m in zip(recs, means))
    n = sum(len(r.target_ref) for r in recs)
    return rem / n if n else None


# --- word filters --------------------------------------------------------------------------------


@dataclass
class Filter:
    scorer: str
    args: dict
    scores: dict  # "<condition key>|<mixture>" -> float32 frame scores
    files: dict  # score file path -> SHA-256
    content_sha256: str = ""  # the scorer's code and loaded files (evaluate.content_identity), equal across directories

    @property
    def name(self) -> str:
        return f"{self.scorer} {canon(self.args)}"

    @property
    def key(self) -> tuple[str, str]:
        return self.scorer, canon(self.args)

    def frames(self, cond: tuple, mid: str) -> np.ndarray:
        k = f"{E.cond_key(*cond)}|{mid}"
        if k not in self.scores:
            raise SystemExit(f"word filter {self.name}: no saved scores for {k}")
        return self.scores[k]


def require_full_coverage(fs: FrozenSet, flt: "Filter", cond: tuple = None) -> None:
    """A candidate's pinned score files must cover every mixture of the set at
    the condition (both halves), so the report can be bound to exactly them."""
    cond = cond or A.HEADLINE
    want = [k for k in E.expected_score_keys(fs, fs.manifest) if k.startswith(E.cond_key(*cond) + "|")]
    missing = [k for k in want if k not in flt.scores]
    if missing:
        raise SystemExit(f"word filter {flt.name}: scores must cover the whole set ({len(missing)} keys missing); give every half's directory")


def load_filters(fs: FrozenSet, groups: list[list[Path]]) -> list["Filter"]:
    fl = [load_filter(fs, g) for g in groups]
    if len({f.key for f in fl}) != len(fl):
        raise SystemExit("conflicting word-filter directories: each scorer configuration must be given once")
    return fl


def load_filter(fs: FrozenSet, dirs: list[Path]) -> Filter:
    """A word filter from `evaluate run`/`apply` output directories (one per half,
    or one for all), each verified with check_score_identity and its own half's
    expected keys, all of one scorer configuration on this set."""
    spec_args, scores, files, content = None, {}, {}, None
    for d in map(Path, dirs):
        p = d / "scores" / "IDENTITY.json"
        if not p.exists():
            raise SystemExit(f"{d}: no score identity")
        ident = json.loads(p.read_text())
        cp = d / "scores" / "CONTENT.json"
        c = json.loads(cp.read_text()) if cp.exists() else None
        if c is None or c.get("kind") != "w0-scorer-content" or c.get("identity_sha256") != ident.get("hash") or not c.get("sha256"):
            raise SystemExit(f"{d}: no content identity bound to its score identity (scores/CONTENT.json; "
                             "`evaluate backfill-content --out DIR` for directories scored before content identities)")
        if content is not None and c["sha256"] != content:
            raise SystemExit(f"{d}: scorer content (code or loaded files) differs from the other directories of this word filter; "
                             "refusing to combine them")
        content = c["sha256"]
        sa = (ident["scorer"], ident["args"])
        if spec_args is not None and sa != spec_args:
            raise SystemExit("the --filter directories of one candidate must hold one scorer configuration")
        spec_args = sa
        ok = None
        for half in ("all", "A", "B"):
            rows = [r for r in fs.manifest if half == "all" or r["half"] == half]
            try:
                E.check_score_identity(d, sa[0], sa[1], fs.set_id, fs.hash, E.expected_score_keys(fs, rows))
                ok = rows
                break
            except SystemExit:
                continue
        if ok is None:
            raise SystemExit(f"{d}: not a complete, verified scoring run of {sa[0]} on {fs.set_id}")
        for s in sorted({r["speaker"] for r in ok}, key=int):
            f = d / "scores" / f"{s}.npz"
            files[str(f)] = hashlib.sha256(f.read_bytes()).hexdigest()
            part = E.load_scores(f)
            dup = sorted(set(part) & set(scores))
            if dup:  # never resolve overlaps by directory order (code3-r2 #1)
                raise SystemExit(f"word filter {sa[0]}: {len(dup)} score keys appear in more than one file (e.g. {dup[0]}); "
                                 "give non-overlapping directories")
            scores.update(part)
    if spec_args is None:
        raise SystemExit("a word filter needs at least one directory")
    return Filter(spec_args[0], dict(spec_args[1]), scores, files, content)


# --- bootstrap, groups, statistics (fe-8) ------------------------------------------------------


@dataclass
class Boot:
    universe: list
    W: np.ndarray  # [n_boot, n_mix]


def make_boot(fs: FrozenSet, half: str, rows: list[dict], n_boot: int = E.BOOT) -> Boot:
    """Joint speaker bootstrap exactly as compute_metrics draws it. Contract
    (tmetrics review r1): the rows must be the half's manifest rows in manifest
    order, and the universe is their involved speakers sorted as integers."""
    want = [r["id"] for r in fs.manifest if half == "all" or r["half"] == half]
    if [r["id"] for r in rows] != want:
        raise SystemExit("bootstrap rows must be the half's manifest rows, in manifest order")
    universe = sorted({s for r in rows for s in E.involved_speakers(r)}, key=int)
    inv = M.involvement_matrix([E.involved_speakers(r) for r in rows], universe)
    return Boot(universe, T.boot_weights(inv, T.boot_draws(len(universe), n_boot)))


def headline_mask(rows: list[dict], have: set, k: int) -> np.ndarray:
    """Primary (coherent) mixtures whose condition exists and whose enrollment
    relation at k is cross_project or same_project_cross_chapter."""
    return np.array([r["id"] in have and r["relation_at"].get(str(k)) in E.HEADLINE_RELATIONS
                     and r.get("rir_mode", "coherent") == "coherent" for r in rows], bool)


def group_masks(rows: list[dict], recs: list[Rec]) -> dict[str, np.ndarray]:
    """dev sets: S0-S4, pooled S1-S4 (with and without B-dropout mixtures) and
    pooled all; noise sets: family x SNR, per family and pooled."""
    sc = np.array([r["scenario"] for r in rows])
    if (sc == "N").any():
        fam = np.array([r.get("noise_family", "") for r in rows])
        snr = np.array([float(r.get("snr_db", np.nan)) for r in rows])
        g = {"pooled_N": sc == "N"}
        for f in sorted(set(fam[sc == "N"])):
            g[f"N-{f}"] = (sc == "N") & (fam == f)
            for x in sorted(set(snr[(sc == "N") & (fam == f)]), reverse=True):
                g[f"N-{f}-{int(x)}dB"] = (sc == "N") & (fam == f) & (snr == x)
        return g
    drop = np.array([r.dropout_b for r in recs], bool)
    g = {"pooled_all": np.isin(sc, M.SCENARIOS), "pooled_S1-S4": np.isin(sc, M.SCENARIOS[1:]),
         "pooled_S1-S4_nondropout": np.isin(sc, M.SCENARIOS[1:]) & ~drop}
    g.update({s: sc == s for s in M.SCENARIOS})
    return g


def point(C: np.ndarray, mask: np.ndarray) -> dict:
    return T.summarize(T.weighted_totals(C, np.ones(len(C)), mask))


def boots(C: np.ndarray, bt: Boot, mask: np.ndarray) -> dict:
    return T.summarize(T.weighted_totals(C, bt.W, mask))


def table(C: np.ndarray, bt: Boot, masks: dict, level: float = 0.95) -> dict:
    out = {}
    for g, m in masks.items():
        if not m.any():
            continue
        p, b = point(C, m), boots(C, bt, m)
        row = {}
        for st in STATS:
            for r in ("all", "single", "overlap"):
                k = f"{st}/{r}"
                row[k] = {"point": _f(p[k]), "ci": [_f(v) for v in T.ci(b[k], level)], "valid": int(np.isfinite(b[k]).sum())}
        for k in ("dropout", "dropout_B"):
            row[k] = {"point": _f(p[k]), "ci": [_f(v) for v in T.ci(b[k], level)], "valid": int(np.isfinite(b[k]).sum())}
        for k in ("N/all", "N/overlap", "n_int_B/all", "n_int_B/overlap", "n_mixtures"):
            row[k] = float(p[k])
        out[g] = row
    return out


PAIRED_KEYS = ("R/all", "R/single", "R/overlap", "L+/all", "G/all", "G_u/all", "G_u-L+/all", "E/all", "WER/all", "dWER/all", "other/all")


def paired(CX: np.ndarray, CY: np.ndarray, bt: Boot, masks: dict, level: float = 0.95) -> dict:
    """Paired differences X - Y, both computed from the same weights in every
    resample."""
    out = {}
    for g, m in masks.items():
        if not m.any():
            continue
        px, py, bx, by = point(CX, m), point(CY, m), boots(CX, bt, m), boots(CY, bt, m)
        out[g] = {k: {"point": _f(px[k] - py[k]), "ci": [_f(v) for v in T.ci(bx[k] - by[k], level)],
                      "valid": int(np.isfinite(bx[k] - by[k]).sum())} for k in PAIRED_KEYS}
    return out


# --- selection rules (fe-10) --------------------------------------------------------------------


def select_config(stats: dict[str, dict]) -> dict:
    """W5 9.3 on half A. stats[c]: dwer_s0_hi (upper end of the paired 95 % CI
    of dWER_S0 against B), lplus (pooled S0-S4 point), r (pooled S1-S4 point)
    and r_boot (R per resample). Eligible: dwer_s0_hi < +0.001 and lplus <=
    0.005. The reference is the eligible configuration with the lowest R
    (ties: the more conservative). The selection is the first eligible one in
    C4, C3, C2, C1 whose 95 % CI upper end of (R - R_ref) is below +0.02; the
    reference qualifies trivially."""
    def ok(c):
        s = stats.get(c)
        return s is not None and s["dwer_s0_hi"] is not None and s["dwer_s0_hi"] < NONINF_S0 and s["lplus"] is not None \
            and s["lplus"] <= BUDGET + 1e-12
    elig = [c for c in CONFIGS if ok(c)]
    if not elig:
        return {"selected": None, "eligible": [], "reference": None, "outcome": "F fails the guardrail: no configuration is eligible"}
    rv = lambda c: stats[c]["r"] if stats[c]["r"] is not None else np.inf
    ref = min(elig, key=lambda c: (rv(c), CONSERVATIVE.index(c)))
    his = {}
    for c in CONSERVATIVE:
        if c not in elig:
            continue
        hi = 0.0 if c == ref else T.ci(np.asarray(stats[c]["r_boot"]) - np.asarray(stats[ref]["r_boot"]))[1]
        his[c] = _f(hi)
        if c == ref or (np.isfinite(hi) and hi < R_MARGIN):
            return {"selected": c, "eligible": elig, "reference": ref, "r_minus_ref_ci_hi": his, "outcome": "selected"}
    raise AssertionError("the reference always qualifies")


def choose_pairing(cands: list[tuple[str, float | None, float | None]]) -> tuple[str, float, float] | None:
    """The feasible candidate (tau not None) with the lowest half-A pooled S1-S4
    R at its threshold; ties go to the first in the fixed candidate list."""
    best = None
    for name, tau, r in cands:
        if tau is None:
            continue
        rr = r if r is not None else np.inf
        if best is None or rr < best[2]:
            best = (name, tau, rr)
    return best


# --- confirmatory evidence (fe-10) ---------------------------------------------------------------


def confirmatory_evidence(fe_identity: dict, artefacts: list[tuple[str, dict]], repo: Path, ledger: Path) -> dict:
    """Whether a selection or report may carry confirmatory labels. artefacts:
    (label, identity with "_run") of every consumed dev artefact. This catches
    accidental out-of-order runs in this checkout. It cannot detect a deleted
    ledger or runs in other checkouts or on other machines; procedure and the
    orchestrator's audit cover those."""
    reasons = []
    reg = R.current_registration(repo, ledger)
    if reg is None:
        reasons.append("no committed registration")
    else:
        if not (fe_identity.get("run") == "R1" and fe_identity.get("seed") == 0 and fe_identity.get("checkpoint_sha256") == reg["sha256"]):
            reasons.append("the front end is not the registered R1 seed-0 checkpoint")
        for label, ident in artefacts:
            if ident.get("registration") != reg or not ident.get("confirmatory_eligible") or ident.get("exploratory"):
                reasons.append(f"{label} does not carry the current registration as confirmatory-eligible")
        for e in R.read_ledger(ledger):
            # Every start event is a run, whether or not a complete event follows (code1-r1 #1).
            if e.get("event", "start") != "start" or e.get("checkpoint_sha256") != reg["sha256"]:
                continue
            head = e.get("head") or ""
            if e.get("registration") != reg or not head or not R.is_ancestor(repo, reg["anchor"], head):
                reasons.append(f"ledger run {e.get('run_id')} ({e.get('stage')}, {e.get('utc')}) predates or lacks the registration")
    return {"confirmatory": not reasons, "reasons": reasons, "registration": reg, "ledger_sha256": R.ledger_sha256(ledger),
            "run_events": {label: ident.get("_run") for label, ident in artefacts}}


# --- code identity: the accounting import closure (design-r3 #3, r4) --------------------------------


def closure(repo: Path | None = None) -> list[tuple[str, str]]:
    """(path relative to the repository, SHA-256) of every lfspk module that a
    fresh interpreter imports with lfspk.harness.tmetrics and frontend_eval."""
    repo = Path(repo or CODE_ROOT).resolve()
    code = ("import json, sys; import lfspk.harness.tmetrics, lfspk.harness.frontend_eval; print(json.dumps(sorted(m.__file__ "
            "for n, m in list(sys.modules.items()) if (n == 'lfspk' or n.startswith('lfspk.')) and getattr(m, '__file__', None))))")
    env = {**os.environ, "PYTHONPATH": str(repo)}
    res = subprocess.run([sys.executable, "-c", code], cwd=repo, env=env, capture_output=True, text=True, timeout=600)
    if res.returncode != 0:
        raise SystemExit(f"closure: the import failed: {res.stderr[-500:]}")
    out = []
    for f in json.loads(res.stdout.strip().splitlines()[-1]):
        p = Path(f).resolve()
        try:
            rel = p.relative_to(repo)
        except ValueError:
            raise SystemExit(f"closure: {p} lies outside {repo}")
        out.append((str(rel), hashlib.sha256(p.read_bytes()).hexdigest()))
    return sorted(out)


def closure_sha256(repo: Path | None = None) -> str:
    return sha("".join(f"{p} {h}\n" for p, h in closure(repo)))


def check_code(transfer: dict, repo: Path | None = None) -> None:
    if transfer.get("code_closure_sha256") != closure_sha256(repo):
        raise SystemExit("the accounting code changed since the selection (closure hash differs); refusing")


# --- digests (design-r1 #6) ---------------------------------------------------------------------


def digest_b(rows: list[dict], b_recs: dict) -> str:
    lines = []
    for r in rows:
        for k in b_keys(r):
            if k not in b_recs:
                raise SystemExit(f"B's cache lacks {k}")
            lines.append(f"{k} {cachepin.record_digest(b_recs[k])}")
    return sha("\n".join(sorted(lines)))


def digest_words(rows: list[dict], words: dict) -> str:
    return sha("\n".join(canon(words[r["id"]]) for r in sorted(rows, key=lambda r: r["id"])))


def digest_entries(rows: list[dict], entries: dict) -> str:
    """Rows without an entry (the condition does not reach them) are part of
    the digest as explicitly absent."""
    return sha("\n".join(canon(entries[f"mix:{r['id']}"]) if f"mix:{r['id']}" in entries else f"{r['id']} absent"
                         for r in sorted(rows, key=lambda r: r["id"])))


# --- inputs ----------------------------------------------------------------------------------------


@dataclass
class Inputs:
    fs: FrozenSet
    b_dir: Path
    b_recs: dict
    b_ident: dict
    words: dict
    corpus: Any
    repo: Path
    masks_root: Path
    out: Path
    ledger: Path


def inputs(fs: FrozenSet, out: Path, b_dir: Path | None = None, corpus=None, repo: Path = R.REPO, masks_root: Path = A.ROOT,
           ledger: Path | None = None, use_corpus: bool = True) -> Inputs:
    b_dir = Path(b_dir or ASR_DIR / fs.set_id)
    b_recs, b_ident = B.load_b(b_dir)
    if corpus is None and use_corpus:
        from .corpora import Corpus

        corpus = Corpus(fs.manifest[0]["meta"]["split"])
    return Inputs(fs, b_dir, b_recs, b_ident, read_words(b_dir / "words.jsonl"), corpus, Path(repo), Path(masks_root), Path(out),
                  Path(ledger) if ledger else A.LEDGER)


def _split(fs: FrozenSet) -> str:
    return fs.manifest[0]["meta"]["split"]


def _with_run(stage) -> dict:
    ident = dict(stage.key if isinstance(stage, A.StageA) else stage.identity)
    ident["_run"] = stage.run
    return ident


# --- select (dev half A) --------------------------------------------------------------------------


def select(ip: Inputs, spec: str, kwargs: dict, filter_dirs: list[list[Path]], n_boot: int = E.BOOT, chunk: int = B.CHUNK) -> dict:
    """F among C1-C4, and the word filter of each pairing with its threshold,
    all fitted on dev half A; returns the selection artefact."""
    fs = ip.fs
    refuse_smoke(fs)
    if _split(fs) != "dev":
        raise SystemExit("selection runs on dev sets only (half A)")
    fe = E.load_factory(spec)(**kwargs)
    st = A.load_stage_a(fs, spec, kwargs, A.HEADLINE, root=ip.masks_root, repo=ip.repo, fe=fe, ledger=ip.ledger)
    sbs = {c: B.load_stage_b(fs, ip.out, stage_a=st, fe=fe, config_name=c, b_dir=ip.b_dir, repo=ip.repo, chunk=chunk, ledger=ip.ledger) for c in CONFIGS}
    rows = [r for r in fs.manifest if r["half"] == "A"]  # half A only, before any quantity is computed
    recs = build_records(fs, rows, ip.b_recs, ip.words, ip.corpus)
    bt = make_boot(fs, "A", rows, n_boot)
    hl = headline_mask(rows, set(st.hashes), A.HEADLINE[2])
    gm = group_masks(rows, recs)
    s0, s14, pall = hl & gm["S0"], hl & gm["pooled_S1-S4"], hl & gm["pooled_all"]
    CF = {c: matrix(recs, sys_hyps(recs, sbs[c].entries)) for c in CONFIGS}
    stats = {}
    for c, C in CF.items():
        b0, b14 = boots(C, bt, s0), boots(C, bt, s14)
        stats[c] = {"dwer_s0": _f(point(C, s0)["dWER/all"]), "dwer_s0_hi": _f(T.ci(b0["dWER/all"])[1]),
                    "lplus": _f(point(C, pall)["L+/all"]), "r": _f(point(C, s14)["R/all"]), "r_boot": b14["R/all"]}
    choice = select_config(stats)
    fsel = choice["selected"]
    # Word filters: exact re-aligned threshold search over the half-A headline mixtures (fe-9).
    hidx = np.flatnonzero(hl)
    hrecs = [recs[i] for i in hidx]
    s0h = gm["S0"][hidx]
    filters = load_filters(fs, filter_dirs)
    for flt in filters:
        require_full_coverage(fs, flt)
    fstats, cands_eq, cands_m = [], [], []
    for flt in filters:
        means = [means_over(flt.frames(A.HEADLINE, r.id), r.b_f0, r.b_f1) for r in hrecs]
        stp = steps(hrecs, [r.b_hyp for r in hrecs], means)
        tau_eq = T.search_tau(stp, np.ones(len(hrecs)), T.budget_rule(BUDGET))[0]
        tau_m = T.search_tau(stp, s0h.astype(float), T.matched_rule(stats[fsel]["dwer_s0"]))[0] if fsel is not None else None
        res = {"filter": flt.name}
        for pname, tau, lst in (("equal_budget", tau_eq, cands_eq), ("matched_s0", tau_m, cands_m)):
            if tau is None:
                lst.append((flt.name, None, None))
                res[pname] = {"tau": None, "infeasible": pname == "matched_s0" and fsel is not None}
                continue
            Cw = matrix(hrecs, [keep(r.b_hyp, m, tau) for r, m in zip(hrecs, means)])
            ones = np.ones(len(hrecs), bool)
            p14, pal, p0 = point(Cw, gm["pooled_S1-S4"][hidx]), point(Cw, ones), point(Cw, s0h)
            lst.append((flt.name, tau, _f(p14["R/all"])))
            res[pname] = {"tau": tau, "R_S1-S4": _f(p14["R/all"]), "L+": _f(pal["L+/all"]), "dWER_S0": _f(p0["dWER/all"]),
                          "fixed_alignment_removed": fixed_removed(hrecs, means, tau)}
        fstats.append(res)
    pair_eq = choose_pairing(cands_eq)
    pair_m = choose_pairing(cands_m) if fsel is not None else None
    by_name = {f.name: f for f in filters}
    stack = None
    if fsel is not None and pair_eq is not None:
        flt = by_name[pair_eq[0]]
        fh = [hyp_of(sbs[fsel].entries[f"mix:{r.id}"]) for r in hrecs]
        fm = [means_over(flt.frames(A.HEADLINE, r.id), *spans_of(h, r.labels.size)) for r, h in zip(hrecs, fh)]
        # No shortcut when F alone exceeds the budget: every threshold is scanned (design-r1 #8).
        tau_s, _, tot = T.search_tau(steps(hrecs, fh, fm), np.ones(len(hrecs)), T.budget_rule(BUDGET))
        stack = {"scorer": flt.scorer, "args": flt.args, "tau": tau_s, "infeasible": tau_s is None, "content_sha256": flt.content_sha256,
                 "L+": _f(T.summarize(tot)["L+/all"]) if tot is not None else None}
    arts = [("stage A", _with_run(st))] + [(f"stage B {c}", _with_run(sbs[c])) for c in CONFIGS]
    conf = confirmatory_evidence(st.key["frontend_identity"], arts, ip.repo, ip.ledger)
    if len(bt.W) != E.BOOT:  # the registered bootstrap size (code3-r1 #2)
        conf = {**conf, "confirmatory": False, "reasons": conf["reasons"] + [f"bootstrap B = {len(bt.W)}, not the registered {E.BOOT}"]}
    fe_id = st.key["frontend_identity"]
    pairing = lambda p: None if p is None else {"scorer": by_name[p[0]].scorer, "args": by_name[p[0]].args, "tau": p[1],
                                                "content_sha256": by_name[p[0]].content_sha256}
    transfer = {"frontend": spec, "args": dict(sorted(kwargs.items())), "frontend_identity": fe_id,
                "frontend_identity_sha256": cachepin.identity_hash(fe_id), "config": fe.config(fsel).to_dict() if fsel else None,
                "weights": "base", "pairings": {"equal_budget": pairing(pair_eq), "matched_s0": pairing(pair_m)},
                "matched_s0_infeasible": fsel is not None and pair_m is None, "stack": stack,
                "confirmatory": conf["confirmatory"], "code_closure_sha256": closure_sha256(CODE_ROOT)}
    provenance = {"set_id": fs.set_id, "set_hash": fs.hash, "split": "dev", "half": "A", "b_identity": ip.b_ident,
                  "stage_a": st.key_sha256, "stage_b": {c: sbs[c].identity_sha256 for c in CONFIGS},
                  "filters": [{"scorer": f.scorer, "args": f.args, "files": f.files, "content_sha256": f.content_sha256} for f in filters],
                  "digests": {"b_records": digest_b(rows, ip.b_recs), "words": digest_words(rows, ip.words),
                              "stage_b": {c: digest_entries(rows, sbs[c].entries) for c in CONFIGS}},
                  "confirmatory_evidence": conf}
    art = {"kind": KIND, "transfer": transfer, "provenance": provenance, "git": E._git(),
           "results": {"configs": {c: {k: v for k, v in s.items() if k != "r_boot"} for c, s in stats.items()}, "choice": choice,
                       "filters": fstats, "n_mixtures_headline": int(hl.sum()), "n_bootstrap": int(len(bt.W))}}
    art["hash"] = E.calibration_hash(json.loads(json.dumps(art, default=float)))
    return json.loads(json.dumps(art, default=float))


def load_selection(path: Path) -> dict:
    sel = json.loads(Path(path).read_text())
    if sel.get("kind") != KIND or sel.get("hash") != E.calibration_hash(sel):
        raise SystemExit(f"{path}: not a valid selection artefact (hash check)")
    pv = sel["provenance"]
    if pv.get("split") != "dev" or pv.get("half") != "A":
        raise SystemExit("selections come from dev half A only")
    return sel


# --- report / apply (fe-11) ------------------------------------------------------------------------


def report(ip: Inputs, sel: dict, spec: str, kwargs: dict, half: str, filter_dirs: list[list[Path]], bstar: bool = False,
           conditions: tuple = (), n_boot: int = E.BOOT, chunk: int = B.CHUNK, sealed_apply: bool = False) -> dict:
    """Every number with the half-A selection held fixed. On the selection's own
    set: half B, provenance digests re-verified, confirmatory family when
    eligible. On another set: transfer identities required, provenance only
    reported, everything exploratory."""
    fs, tr, pv = ip.fs, sel["transfer"], sel["provenance"]
    refuse_smoke(fs)
    check_code(tr, CODE_ROOT)
    if spec != tr["frontend"] or dict(sorted(kwargs.items())) != tr["args"]:
        raise SystemExit("the front end differs from the selection's")
    fe = E.load_factory(spec)(**kwargs)
    if cachepin.identity_hash(fe.identity()) != tr["frontend_identity_sha256"]:
        raise SystemExit("the front end's identity differs from the selection's")
    same = fs.set_id == pv["set_id"] and fs.hash == pv["set_hash"]
    if same and half != "B":
        raise SystemExit("on the selection's own set, reports are on half B")
    if _split(fs) != "dev" and not sealed_apply:
        raise SystemExit("sealed sets are evaluated only under the orchestrator's apply")
    if tr["config"] is None:
        return {"outcome": "F failed the guardrail on half A; nothing to report", "selection_hash": sel["hash"]}
    cfg = tr["config"]["name"]
    st = A.load_stage_a(fs, spec, kwargs, A.HEADLINE, root=ip.masks_root, repo=ip.repo, fe=fe, ledger=ip.ledger)
    sb = B.load_stage_b(fs, ip.out, stage_a=st, fe=fe, config_name=cfg, b_dir=ip.b_dir, repo=ip.repo, chunk=chunk, ledger=ip.ledger)
    if sb.identity["config"] != tr["config"]:
        raise SystemExit("stage B's configuration differs from the selection's")
    others = {c: B.load_stage_b(fs, ip.out, stage_a=st, fe=fe, config_name=c, b_dir=ip.b_dir, repo=ip.repo, chunk=chunk, ledger=ip.ledger) for c in CONFIGS
              if c != cfg and (same or (B.stage_b_dir(ip.out, "base", A.slug(A.HEADLINE), c) / "asr.meta.json").exists())}
    sbstar = B.load_stage_b(fs, ip.out, stage_a=None, fe=None, config_name="C1", b_dir=ip.b_dir, repo=ip.repo, chunk=chunk, ledger=ip.ledger) if bstar else None
    filters = {f.key: f for f in load_filters(fs, filter_dirs)}
    if same:  # what the selection was fitted on (half A) must be unchanged: every configuration, every W (code3-r1 #3)
        rows_a = [r for r in fs.manifest if r["half"] == "A"]
        allb = {cfg: sb, **others}
        if digest_b(rows_a, ip.b_recs) != pv["digests"]["b_records"] or digest_words(rows_a, ip.words) != pv["digests"]["words"] \
                or st.key_sha256 != pv["stage_a"] or sorted(allb) != sorted(pv["stage_b"]) \
                or any(allb[c].identity_sha256 != pv["stage_b"][c] or digest_entries(rows_a, allb[c].entries) != pv["digests"]["stage_b"][c]
                       for c in allb):
            raise SystemExit("the inputs the selection was fitted on changed (provenance digests differ); refusing")
        pinned = {(pf["scorer"], canon(pf["args"])): pf["files"] for pf in pv["filters"]}
        for files in pinned.values():
            for path, h in files.items():
                if not Path(path).exists() or hashlib.sha256(Path(path).read_bytes()).hexdigest() != h:
                    raise SystemExit(f"{path}: a score file the selection was fitted on changed")
        for k, f in filters.items():  # the report consumes exactly the pinned files (code3-r1 #1)
            if pinned.get(k) != f.files:
                raise SystemExit(f"word filter {f.name}: the supplied score files are not the ones the selection pinned")
    for p in list((tr.get("pairings") or {}).values()) + [tr.get("stack")]:  # the same scorer content everywhere
        f = filters.get((p["scorer"], canon(p["args"]))) if p else None
        if f is not None and f.content_sha256 != p.get("content_sha256"):
            raise SystemExit(f"word filter {f.name}: scorer content differs from the one the selection used")
    rows = [r for r in fs.manifest if half == "all" or r["half"] == half]
    recs = build_records(fs, rows, ip.b_recs, ip.words, ip.corpus)
    bt = make_boot(fs, half, rows, n_boot)
    hl = headline_mask(rows, set(st.hashes), A.HEADLINE[2])
    gm = group_masks(rows, recs)
    masks = {g: hl & m for g, m in gm.items()}
    fname = f"F({cfg})"
    have = set(st.hashes)
    systems = {"B": matrix(recs, [r.b_hyp for r in recs]), fname: matrix(recs, sys_hyps(recs, sb.entries))}
    for c, s in others.items():
        systems[f"F({c}) [exploratory]"] = matrix(recs, sys_hyps(recs, s.entries))
    if sbstar is not None:
        systems["B* [diagnostic]"] = matrix(recs, sys_hyps(recs, sbstar.entries))
    wsys = {}
    for pname, p in (tr.get("pairings") or {}).items():
        f = filters.get((p["scorer"], canon(p["args"]))) if p else None
        if f is None:
            continue
        wsys[pname] = f"W {pname}"
        systems[wsys[pname]] = matrix(recs, filter_hyps(recs, f, p["tau"], have))
    stk = tr.get("stack")
    if stk and stk.get("tau") is not None and (stk["scorer"], canon(stk["args"])) in filters:
        f = filters[(stk["scorer"], canon(stk["args"]))]
        systems["F+W [exploratory]"] = matrix(recs, stacked_hyps(recs, sys_hyps(recs, sb.entries), f, stk["tau"], have))
    F = systems[fname]
    res = {"set_id": fs.set_id, "set_hash": fs.hash, "half": half, "selection_hash": sel["hash"], "config": tr["config"],
           "source_set": same, "n_bootstrap": int(len(bt.W)), "n_speakers_universe": len(bt.universe), "n_mixtures_headline": int(hl.sum()),
           "tables": {n: table(C, bt, masks) for n, C in systems.items()},
           "paired": {f"{n} - B": paired(C, systems["B"], bt, masks) for n, C in systems.items() if n != "B"}}
    for wn in wsys.values():
        res["paired"][f"{fname} - {wn}"] = paired(F, systems[wn], bt, masks)
    res["bypass_rate"] = {g: _f(np.mean([sb.entries[f"mix:{r.id}"]["bypass"] for r, x in zip(recs, m) if x])) for g, m in masks.items() if m.any()}
    res["n_without_condition"] = int(sum(r.id not in have for r in recs))
    masked = [r for r, x in zip(recs, hl) if x and not sb.entries[f"mix:{r.id}"]["bypass"]]
    res["masked_identical_to_B"] = _f(np.mean([sb.entries[f"mix:{r.id}"]["words"] == ip.b_recs[f"mix:{r.id}"]["words"] for r in masked])) if masked else None
    if sbstar is not None:
        res["bstar_identical_to_B"] = {g: _f(np.mean([sbstar.entries[f"mix:{r.id}"]["words"] == ip.b_recs[f"mix:{r.id}"]["words"]
                                                      for r, x in zip(recs, m) if x])) for g, m in masks.items() if m.any()}
    arts = [("stage A", _with_run(st)), (f"stage B {cfg}", _with_run(sb))] + ([("B*", _with_run(sbstar))] if sbstar else [])
    conf = confirmatory_evidence(st.key["frontend_identity"], arts, ip.repo, ip.ledger) if _split(fs) == "dev" \
        else {"confirmatory": False, "reasons": [f"{_split(fs)} set"]}
    dev_s = "S0" in masks
    boot_ok = len(bt.W) == E.BOOT and sel["results"].get("n_bootstrap") == E.BOOT  # the registered B = 2000 (code3-r1 #2)
    if not boot_ok:
        conf = {**conf, "confirmatory": False, "reasons": conf.get("reasons", []) + [f"bootstrap B = {len(bt.W)} (selection "
                                                                                      f"{sel['results'].get('n_bootstrap')}), not {E.BOOT}"]}
    confirm = bool(same and half == "B" and tr.get("confirmatory") and conf["confirmatory"] and "equal_budget" in wsys and dev_s)
    if dev_s:
        level = T.BONFERRONI_LEVEL if confirm else 0.95  # exploratory intervals are 95 % (code3-r1 #5)
        fam = family(F, systems, wsys, bt, masks, tr, level)
        if not confirm:
            fam = {k: {**v, "verdict": None, "label": "exploratory"} for k, v in fam.items()}
        res["confirmatory_family"] = {"confirmatory": confirm, "evidence": conf, "level": level, "claims": fam}
    res["conditions"] = {}
    for cond in conditions:  # other enrollment conditions: F against B only (W5 9.6), exploratory
        sa = A.load_stage_a(fs, spec, kwargs, cond, root=ip.masks_root, repo=ip.repo, fe=fe, ledger=ip.ledger)
        sbc = B.load_stage_b(fs, ip.out, stage_a=sa, fe=fe, config_name=cfg, b_dir=ip.b_dir, repo=ip.repo, chunk=chunk, ledger=ip.ledger)
        hk = headline_mask(rows, set(sa.hashes), cond[2])
        Cc = matrix(recs, [hyp_of(sbc.entries[f"mix:{r.id}"]) if r.id in sa.hashes else r.b_hyp for r in recs])
        res["conditions"][A.slug(cond)] = {"n_mixtures": int(hk.sum()), "table": table(Cc, bt, {g: hk & m for g, m in gm.items()})}
    rel = np.array([r["relation_at"].get("10") or "short" for r in rows])
    coh = np.array([r.get("rir_mode", "coherent") == "coherent" for r in rows], bool)
    hv = np.array([r["id"] in have for r in rows], bool)
    sec = {f"relation:{x}": hv & (rel == x) & coh for x in ("cross_project", "same_project_cross_chapter", "same_chapter")}
    sec["mixed_rir"] = hv & np.isin(rel, E.HEADLINE_RELATIONS) & ~coh
    res["secondary"] = {g: {"n_mixtures": int(m.sum()), **{k: _f(point(F, m)[k]) for k in ("R/all", "L+/all", "G/all", "dWER/all", "E/all")}}
                        for g, m in sec.items() if m.any()}
    res["inputs"] = {"b_records": digest_b(rows, ip.b_recs), "words": digest_words(rows, ip.words), "stage_b": digest_entries(rows, sb.entries),
                     "stage_a": st.key_sha256, "stage_b_identity": sb.identity_sha256, "filters": {f.name: f.files for f in filters.values()},
                     "code_closure_sha256": tr["code_closure_sha256"], "ledger_sha256": R.ledger_sha256(ip.ledger), "git": E._git()}
    return json.loads(json.dumps(res, default=float))


def family(F: np.ndarray, systems: dict, wsys: dict, bt: Boot, masks: dict, tr: dict, level: float = T.BONFERRONI_LEVEL) -> dict:
    """{H1a, H1b, H2, H5}: Bonferroni-adjusted 98.75 % percentile CIs when
    confirmatory, 95 % when exploratory (the caller passes the level)."""
    lv = level
    m14, m0 = masks["pooled_S1-S4"], masks["S0"]
    bF14, bF0 = boots(F, bt, m14), boots(F, bt, m0)
    pF14, pF0 = point(F, m14), point(F, m0)
    out = {}
    for h, pname in (("H1a", "equal_budget"), ("H1b", "matched_s0")):
        wn = wsys.get(pname)
        if wn is None:
            out[h] = {"tested": False, "note": "infeasible: no word-filter threshold reaches F's half-A S0 harm"
                      if pname == "matched_s0" and tr.get("matched_s0_infeasible") else "the word filter is not available"}
            continue
        lo, hi = T.ci(bF14["R/all"] - boots(systems[wn], bt, m14)["R/all"], lv)
        out[h] = {"tested": True, "stat": "R_F - R_W, pooled S1-S4", "point": _f(pF14["R/all"] - point(systems[wn], m14)["R/all"]),
                  "ci": [_f(lo), _f(hi)], "verdict": "supported" if np.isfinite(hi) and hi < 0 else "not resolved"}
    lo, hi = T.ci(bF14["G_u-L+/all"], lv)
    out["H2"] = {"tested": True, "stat": "G_u - L+ of F, pooled S1-S4", "point": _f(pF14["G_u-L+/all"]), "ci": [_f(lo), _f(hi)],
                 "verdict": "supported" if np.isfinite(lo) and lo > 0 else "not resolved",
                 "descriptive_E_F_minus_E_B": _f(pF14["E/all"] - point(systems["B"], m14)["E/all"])}
    lo, hi = T.ci(bF0["dWER/all"], lv)
    out["H5"] = {"tested": True, "stat": "dWER_S0 (F - B)", "point": _f(pF0["dWER/all"]), "ci": [_f(lo), _f(hi)],
                 "verdict": "supported" if np.isfinite(hi) and hi < NONINF_S0 else "not resolved"}
    return out


def _pct(x) -> str:
    return "n/a" if x is None else f"{100 * x:.2f}"


def report_md(res: dict) -> str:
    if "tables" not in res:
        return f"# Front-end report\n\n{res.get('outcome')}\n"
    L = [f"# Front-end report: {res['set_id']} ({res['half']})", "",
         f"Selection `{res['selection_hash']}`, configuration {res['config']}, {res['n_mixtures_headline']} headline mixtures. "
         f"Bootstrap B = {res['n_bootstrap']} over {res['n_speakers_universe']} speakers, all roles jointly. CIs are conditional on the "
         "half-A choices and the fixed enrollment contamination streams. Percent; 95 % CIs unless stated.", ""]
    fam = res.get("confirmatory_family")
    if fam:
        L += [f"## Confirmatory family: {'CONFIRMATORY' if fam['confirmatory'] else 'EXPLORATORY (not confirmatory)'}, "
              f"{100 * fam['level']:.2f} % CIs", ""]
        if not fam["confirmatory"]:
            L += [f"Not confirmatory because: {fam['evidence'].get('reasons') or 'not half B of the selection set'}", ""]
        for h, v in fam["claims"].items():
            L.append(f"- {h}: not tested ({v['note']})" if not v["tested"] else
                     f"- {h}: {v['stat']} = {_pct(v['point'])} [{_pct(v['ci'][0])}, {_pct(v['ci'][1])}]: {v.get('verdict') or 'exploratory'}")
        L.append("")
    for name, tab in res["tables"].items():
        L += [f"## {name}", "", "| group | N | R | L+ | G | G_u | net L | E | WER | dWER | other | dropout |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for g, row in tab.items():
            c = lambda k: f"{_pct(row[k]['point'])} [{_pct(row[k]['ci'][0])}, {_pct(row[k]['ci'][1])}]"
            L.append(f"| {g} | {row['N/all']:.0f} | {c('R/all')} | {c('L+/all')} | {c('G/all')} | {c('G_u/all')} | {c('net_L/all')} | "
                     f"{c('E/all')} | {c('WER/all')} | {c('dWER/all')} | {c('other/all')} | {c('dropout')} |")
        L.append("")
    L += [f"Bypass rate: {json.dumps(res.get('bypass_rate'))}", f"Masked transcripts identical to B: {res.get('masked_identical_to_B')}", ""]
    return "\n".join(L)


# --- latency (fe-14) --------------------------------------------------------------------------------


def latency(fs: FrozenSet, spec: str, kwargs: dict, encoder: bool = False, selected: str | None = None) -> dict:
    """CPU latency in CPU_ENV (verified before and after), on evaluate.latency's
    30 fixed mixtures with the profile from the first 3 built-in clean
    dictations: analyse, apply per configuration, analyse + apply (C1) per audio
    second, update per 10 s dictation, and optionally Parakeet's preprocessor +
    encoder measured the same way."""
    from ..extract.frontend import apply

    missing = {k: v for k, v in E.CPU_ENV.items() if os.environ.get(k) != v}
    if missing:
        raise SystemExit(f"latency must run with CPU_ENV; differing: {sorted(missing)}")
    import torch

    torch.set_num_threads(1)
    if torch.cuda.is_available():
        raise SystemExit("latency refused: a CUDA device is visible")
    check: dict[str, Any] = {"env": E.CPU_ENV}
    rows = sorted(fs.manifest, key=lambda r: r["id"])
    pick = [r for i, r in enumerate(rows) if i % max(1, len(rows) // E.LATENCY_MIXTURES) == 0][:E.LATENCY_MIXTURES]
    fe = E.load_factory(spec)(**kwargs)
    E._verify_threads(check, "after front-end construction")
    cfgs = {c: fe.config(c) for c in CONFIGS if c in ("C1", "C2") or fe.identity().get("theta_b") is not None}
    per: dict[str, list] = {"analyse": [], **{f"apply_{c}": [] for c in cfgs}, **{f"analyse_plus_apply_{c}": [] for c in cfgs}}
    upd, enc = [], []
    model = None
    if encoder:
        from .asr import load_model

        model = load_model("cpu")
    for r in pick:
        stream = fs.enrollment_stream(r["speaker"], "builtin", False)
        prof = fe.enroll([fs.audio(x["file"]) for x in stream[:3]])
        a = fs.audio(r["files"]["mix"])
        sec = a.size / 16000
        mo = fe.analyse(prof, a)  # warm-up
        t = time.perf_counter()
        mo = fe.analyse(prof, a)
        ta = time.perf_counter() - t
        per["analyse"].append(ta / sec)
        for c, cfg in cfgs.items():
            apply(a, mo, cfg)
            t = time.perf_counter()
            apply(a, mo, cfg)
            per[f"apply_{c}"].append((time.perf_counter() - t) / sec)
        for c in cfgs:
            per[f"analyse_plus_apply_{c}"].append(per["analyse"][-1] + per[f"apply_{c}"][-1])
        if len(stream) > 3:
            u = fs.audio(stream[3]["file"])
            t = time.perf_counter()
            fe.update(prof, u)
            upd.append((time.perf_counter() - t) / (u.size / 16000) * 10.0)
        if model is not None:
            with torch.inference_mode():
                x, n = torch.from_numpy(a)[None], torch.tensor([a.size])
                feats, fl = model.preprocessor(input_signal=x, length=n)
                model.encoder(audio_signal=feats, length=fl)  # warm-up
                t = time.perf_counter()
                feats, fl = model.preprocessor(input_signal=x, length=n)
                model.encoder(audio_signal=feats, length=fl)
                enc.append((time.perf_counter() - t) / sec)
    E._verify_threads(check, "after measurement")
    q = lambda v: {"median": float(np.median(v)), "p90": float(np.quantile(v, 0.9))} if v else None
    out = {"threads": 1, "verified": check, "n_mixtures": len(pick), "s_per_audio_s": {k: q(v) for k, v in per.items()},
           "update_s_per_10s_dictation": q(upd), "parakeet_preprocessor_plus_encoder_s_per_audio_s": q(enc)}
    if selected:
        out["selected"] = {"config": selected, "analyse_plus_apply": q(per.get(f"analyse_plus_apply_{selected}", []))}
    return out


def latency_subprocess(set_id: str, spec: str, kwargs: dict, encoder: bool = False, selected: str | None = None,
                       set_root: Path | None = None) -> dict:
    """Run the measurement in a fresh interpreter started with CPU_ENV, so that
    the thread settings hold before torch or any backend is imported."""
    cmd = [sys.executable, "-m", "lfspk.harness.frontend_eval", "latency-worker", "--set", set_id, "--frontend", spec]
    cmd += sum((["--arg", f"{k}={v}"] for k, v in kwargs.items()), [])
    cmd += (["--encoder"] if encoder else []) + (["--config", selected] if selected else []) + (["--set-root", str(set_root)] if set_root else [])
    r = subprocess.run(cmd, cwd=CODE_ROOT, env={**os.environ, **E.CPU_ENV}, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"latency worker failed: {r.stderr[-2000:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


# --- smoke: a tiny real dev-v1 subset, exploratory, never selectable ------------------------------

SMOKE_DIR = OUT / "smoke"
SMOKE_MARKER = "SMOKE"


class IdentityFrontEnd:
    """A deterministic stand-in until a W5 checkpoint exists: log_mask = 0 (the
    mask path changes nothing, as B*) and u in {0.1, 0.9} from the audio's hash,
    so that C3/C4 exercise both the bypass and the masked path."""

    name = "identity-mask"

    def __init__(self, theta_b: str = "0.5"):
        self.theta_b = float(theta_b)

    def enroll(self, utterances):
        return ("identity", len(utterances))

    def update(self, profile, utterance):
        return ("identity", profile[1] + 1)

    def analyse(self, profile, audio):
        from ..extract.api import N_MELS, MaskOutput, feature_frames

        t = feature_frames(audio.size)
        hi = hashlib.sha256(np.ascontiguousarray(audio, np.float32).tobytes()).digest()[0] % 2 == 0
        return MaskOutput(np.zeros((N_MELS, t), np.float32), np.full(t, 0.9 if hi else 0.1, np.float32))

    def cost(self):
        from ..api import CostReport

        return CostReport(params=0, macs_per_audio_second=0.0, update_macs=0.0, profile_bytes=0, reads_parakeet_layers=(), notes="identity mask")

    def identity(self) -> dict:
        return {"kind": "w0f-identity-mask", "checkpoint_sha256": hashlib.sha256(b"w0f identity mask v1").hexdigest(), "run": "smoke",
                "seed": None, "analyse_threads": 1, "theta_b": self.theta_b}

    def config(self, name: str):
        from ..extract.api import InferenceConfig

        return InferenceConfig(name, self.theta_b if name in ("C3", "C4") else None)


def identity_frontend(**kwargs) -> IdentityFrontEnd:
    return IdentityFrontEnd(**kwargs)


IDENTITY_SPEC = "lfspk.harness.frontend_eval:identity_frontend"


def is_smoke(fs: FrozenSet) -> bool:
    return fs.set_id.endswith("-smoke") or (Path(fs.root) / SMOKE_MARKER).exists()


def refuse_smoke(fs: FrozenSet) -> None:
    if is_smoke(fs):
        raise SystemExit(f"{fs.set_id} is a smoke set: never selected, reported or applied")


def build_smoke_set(src: FrozenSet, root: Path, n_speakers: int = 4) -> FrozenSet:
    """A read-only view of `src` (dev-v1): the coherent target-0 groups (S0-S4)
    of the first n speakers, about 20 mixtures, with their enrollment rows; files
    are symlinks into `src`, the listing is the subset of src's CONTENT.sha256,
    and the set id ends in -smoke with a SMOKE marker."""
    if _split(src) != "dev":
        raise SystemExit("smoke sets are cut from dev sets only")
    root = Path(root)
    if root.exists() and any(root.iterdir()):
        raise SystemExit(f"{root} exists; use a fresh smoke directory")
    spk = sorted({r["speaker"] for r in src.manifest}, key=int)[:n_speakers]
    rows = [r for r in src.manifest if r["speaker"] in spk and r["target_index"] == 0 and r.get("rir_mode", "coherent") == "coherent"]
    enr = [e for e in src.enrollment_rows if e["speaker"] in spk]
    files = sorted({r["files"]["mix"] for r in rows} | {r["files"]["labels"] for r in rows} | {e["file"] for e in enr})
    listing = {ln.split("  ", 1)[1]: ln for ln in (src.root / "CONTENT.sha256").read_text().splitlines()}
    for f in files:
        (root / f).parent.mkdir(parents=True, exist_ok=True)
        (root / f).symlink_to((src.root / f).resolve())
    (root / "manifest.jsonl").write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
    (root / "enrollment.jsonl").write_text("".join(json.dumps(e, sort_keys=True) + "\n" for e in enr))
    plans = json.loads((src.root / "plans.json").read_text())
    plans["plans"] = [x for x in plans["plans"] if x["speaker"] in spk]
    plans["smoke_of"] = {"set_id": src.set_id, "set_hash": src.hash}
    (root / "plans.json").write_text(json.dumps(plans, indent=1, sort_keys=True))
    content = "".join(listing[f] + "\n" for f in files)
    (root / "CONTENT.sha256").write_text(content)
    (root / "HASH").write_text(sha(content) + "\n")
    (root / SMOKE_MARKER).write_text(json.dumps({"of": src.set_id, "hash": src.hash, "rows": len(rows)}))
    return FrozenSet(f"{src.set_id}-smoke", root=root)


def refuse_confirmatory_checkpoint(fe_identity: dict, repo: Path = R.REPO, ledger: Path | None = None) -> None:
    """Smokes never touch the pre-registered confirmatory checkpoint: a front
    end whose identity says run R1 seed 0, or whose checkpoint SHA-256 is the
    registered one, is refused (a smoke is an unregistered dev run and would
    block its confirmatory use)."""
    if fe_identity.get("run") == "R1" and fe_identity.get("seed") == 0:
        raise SystemExit("smoke refused: the front end is R1 seed 0, the confirmatory checkpoint; use the identity mask or another checkpoint")
    reg = R.current_registration(repo, ledger)
    if reg is not None and fe_identity.get("checkpoint_sha256") == reg["sha256"]:
        raise SystemExit("smoke refused: the front end is the registered confirmatory checkpoint")


def smoke_set(out: Path, src_id: str = "dev-v1") -> FrozenSet:
    return FrozenSet(f"{src_id}-smoke", root=Path(out) / "set")


def smoke_prepare(src: FrozenSet, out: Path, spec: str, kwargs: dict, workers: int = 4, repo: Path = R.REPO,
                  ledger: Path | None = None) -> FrozenSet:
    """CPU: the subset set and stage A (headline condition, exploratory, masks
    under the smoke directory). Every run is in the real ledger: a smoke of the
    registered checkpoint counts as an unregistered dev run of it."""
    refuse_confirmatory_checkpoint(E.load_factory(spec)(**kwargs).identity(), repo, ledger)
    fs = build_smoke_set(src, Path(out) / "set")
    A.run_stage_a(fs, spec, kwargs, A.HEADLINE, workers, root=Path(out) / "masks", exploratory=True, repo=repo, ledger=ledger)
    return fs


def smoke_asr(fs: FrozenSet, out: Path, spec: str, kwargs: dict, model, asr_identity: dict, b_dir: Path, transcribe_fn=None,
              repo: Path = R.REPO, ledger: Path | None = None, configs=CONFIGS) -> None:
    """GPU: stage B for each configuration and B*, through transcribe_masked."""
    fe = E.load_factory(spec)(**kwargs)
    refuse_confirmatory_checkpoint(fe.identity(), repo, ledger)
    st = A.load_stage_a(fs, spec, kwargs, A.HEADLINE, root=Path(out) / "masks", repo=repo, fe=fe, ledger=ledger)
    for c in configs:
        B.run_stage_b(fs, out, stage_a=st, fe=fe, config_name=c, model=model, asr_identity=asr_identity, b_dir=b_dir,
                      transcribe_fn=transcribe_fn, repo=repo, ledger=ledger)
    B.run_stage_b(fs, out, stage_a=None, fe=None, config_name="C1", model=model, asr_identity=asr_identity, b_dir=b_dir,
                  transcribe_fn=transcribe_fn, repo=repo, ledger=ledger, exploratory=True)


def smoke_metrics(fs: FrozenSet, out: Path, spec: str, kwargs: dict, b_dir: Path, corpus=None, use_corpus: bool = True,
                  repo: Path = R.REPO, configs=CONFIGS, n_boot: int = 200) -> dict:
    """CPU: every load check, build_records with the reference guard, and the
    metrics of each configuration and B* against B (exploratory)."""
    fe = E.load_factory(spec)(**kwargs)
    refuse_confirmatory_checkpoint(fe.identity(), repo)
    ip = inputs(fs, out, b_dir=b_dir, corpus=corpus, repo=repo, masks_root=Path(out) / "masks", use_corpus=use_corpus)
    st = A.load_stage_a(fs, spec, kwargs, A.HEADLINE, root=ip.masks_root, repo=repo, fe=fe, ledger=ip.ledger)
    sbs = {c: B.load_stage_b(fs, out, stage_a=st, fe=fe, config_name=c, b_dir=b_dir, repo=repo, ledger=ip.ledger) for c in configs}
    sbstar = B.load_stage_b(fs, out, stage_a=None, fe=None, config_name="C1", b_dir=b_dir, repo=repo, ledger=ip.ledger)
    rows = list(fs.manifest)
    recs = build_records(fs, rows, ip.b_recs, ip.words, ip.corpus)
    bt = make_boot(fs, "all", rows, n_boot)
    # Every subset mixture the condition reaches (no relation restriction in a smoke); rows whose stream
    # is short of k have no F entry and are masked out of every comparison (code3-r2 #2).
    have = set(st.hashes)
    hl = np.array([r.id in have for r in recs], bool)
    masks = {g: hl & m for g, m in group_masks(rows, recs).items()}
    systems = {"B": matrix(recs, [r.b_hyp for r in recs]), "B*": matrix(recs, [hyp_of(sbstar.entries[f"mix:{r.id}"]) for r in recs])}
    for c, sb in sbs.items():
        systems[f"F({c})"] = matrix(recs, sys_hyps(recs, sb.entries))
    same = lambda a, b: _f(np.mean([a.entries[f"mix:{r.id}"]["words"] == b[f"mix:{r.id}"]["words"] for r in recs]))
    res = {"exploratory": True, "smoke_of": json.loads((Path(fs.root) / SMOKE_MARKER).read_text()), "n_mixtures": len(rows),
           "n_without_condition": int((~hl).sum()),
           "frontend": spec, "args": kwargs, "frontend_identity": st.key["frontend_identity"],
           "bypass": {c: sb.n_bypass for c, sb in sbs.items()}, "bstar_identical_to_B": same(sbstar, ip.b_recs),
           "identical_to_bstar": {c: _f(np.mean(v)) if (v := [sb.entries[f"mix:{r.id}"]["words"] == sbstar.entries[f"mix:{r.id}"]["words"]
                                                               for r in recs if f"mix:{r.id}" in sb.entries
                                                               and not sb.entries[f"mix:{r.id}"]["bypass"]]) else None
                                  for c, sb in sbs.items()},
           "tables": {n: table(C, bt, masks) for n, C in systems.items()}}
    # B* against B: not asserted equal (B* runs through the hook in other batches than B's cache); every
    # differing mixture is listed with its WER delta, which measures that batching sensitivity.
    Cb, Cs = systems["B"], systems["B*"]
    res["bstar_differs"] = [{"id": r.id, "scenario": r.row["scenario"], "dWER": _f(T.summarize(Cs[i])["dWER/all"]),
                             "b_text": ip.b_recs[f"mix:{r.id}"]["text"], "bstar_text": sbstar.entries[f"mix:{r.id}"]["text"]}
                            for i, r in enumerate(recs) if sbstar.entries[f"mix:{r.id}"]["words"] != ip.b_recs[f"mix:{r.id}"]["words"]]
    res["bstar_dWER_pooled"] = _f(point(Cs, np.ones(len(recs), bool))["dWER/all"])
    return json.loads(json.dumps(res, default=float))


# --- CLI ------------------------------------------------------------------------------------------


def _cond(s: str | None) -> tuple:
    return A.parse_slug(s) if s else A.HEADLINE


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("stage-a", "stage-b", "purge", "select", "report", "apply", "latency", "latency-worker", "smoke"))
    ap.add_argument("--set-root", type=Path, default=None, help=argparse.SUPPRESS)  # tests only
    ap.add_argument("--step", default=None, choices=("prepare", "asr", "metrics"), help="smoke: the step to run")
    ap.add_argument("--set", required=True)
    ap.add_argument("--frontend", default=None, help="MODULE:CALLABLE front-end factory")
    ap.add_argument("--arg", action="append", default=[])
    ap.add_argument("--condition", default=None, help="e.g. builtin-clean-10 (default: the headline)")
    ap.add_argument("--conditions", default="", help="report: further condition slugs, comma-separated (F against B only)")
    ap.add_argument("--config", default="C1")
    ap.add_argument("--configs", default="", help="purge: the configurations in use, comma-separated")
    ap.add_argument("--bstar", action="store_true")
    ap.add_argument("--exploratory", action="store_true")
    ap.add_argument("--sealed-apply", action="store_true", help="orchestrator only: the sealed sets")
    ap.add_argument("--filter", action="append", default=[], help="one word-filter candidate: its evaluate output dirs, comma-separated")
    ap.add_argument("--selection", type=Path, default=None)
    ap.add_argument("--half", default="B", choices=("A", "B", "all"))
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--boot", type=int, default=E.BOOT)
    ap.add_argument("--encoder", action="store_true")
    a = ap.parse_args(argv)
    paths.require_mount()
    kwargs = E.parse_args_kv(a.arg)
    if a.cmd == "latency":  # the measurement itself runs in a CPU_ENV worker (code3-r1 #6)
        print(json.dumps(latency_subprocess(a.set, a.frontend, kwargs, a.encoder, a.config, a.set_root)))
        return
    fs = FrozenSet(a.set, root=a.set_root) if a.set_root else FrozenSet(a.set)
    if a.cmd == "latency-worker":
        print(json.dumps(latency(fs, a.frontend, kwargs, a.encoder, a.config)))
        return
    if a.cmd == "smoke":
        spec = a.frontend or IDENTITY_SPEC
        name = getattr(E.load_factory(spec)(**kwargs), "name", "frontend")
        sdir = a.out or SMOKE_DIR / name
        b_dir = ASR_DIR / fs.set_id
        if a.step == "prepare":
            print(smoke_prepare(fs, sdir, spec, kwargs, a.workers).root)
        elif a.step == "asr":
            from .asr import cache_identity, load_model

            smoke_asr(smoke_set(sdir, fs.set_id), sdir, spec, kwargs, load_model("cuda"), cache_identity(), b_dir)
        elif a.step == "metrics":
            res = smoke_metrics(smoke_set(sdir, fs.set_id), sdir, spec, kwargs, b_dir, n_boot=a.boot)
            (sdir / "smoke-results.json").write_text(json.dumps(res, indent=1))
            print(json.dumps({k: res[k] for k in ("n_mixtures", "bypass", "bstar_identical_to_B", "bstar_dWER_pooled", "identical_to_bstar")}))
            print(json.dumps({"bstar_differs": res["bstar_differs"]}))
        else:
            raise SystemExit("smoke needs --step prepare|asr|metrics")
        return
    if a.cmd == "stage-a":
        print(A.run_stage_a(fs, a.frontend, kwargs, _cond(a.condition), a.workers, exploratory=a.exploratory, sealed_apply=a.sealed_apply))
        return
    fe = E.load_factory(a.frontend)(**kwargs) if a.frontend else None
    out = a.out or OUT / (getattr(fe, "name", "frontend") if fe else "bstar") / fs.set_id
    if a.cmd == "stage-b":
        from .asr import cache_identity, load_model

        model = load_model("cuda")
        if a.bstar:
            d = B.run_stage_b(fs, out, stage_a=None, fe=None, config_name="C1", model=model, asr_identity=cache_identity(),
                              exploratory=a.exploratory, sealed_apply=a.sealed_apply)
        else:
            st = A.load_stage_a(fs, a.frontend, kwargs, _cond(a.condition), fe=fe)
            d = B.run_stage_b(fs, out, stage_a=st, fe=fe, config_name=a.config, model=model, asr_identity=cache_identity())
        print(d)
        return
    if a.cmd == "purge":
        st = A.load_stage_a(fs, a.frontend, kwargs, _cond(a.condition), fe=fe)
        B.purge(fs, out, st, fe, [c for c in a.configs.split(",") if c])
        return
    ip = inputs(fs, out)
    groups = [[Path(x) for x in f.split(",") if x] for f in a.filter]
    if a.cmd == "select":
        art = select(ip, a.frontend, kwargs, groups, a.boot)
        d = out / "select-A"
        d.mkdir(parents=True, exist_ok=True)
        (d / "selection.json").write_text(json.dumps(art, indent=1, sort_keys=True))
        print(d / "selection.json")
        return
    if a.selection is None:
        raise SystemExit(f"{a.cmd} needs --selection")
    sel = load_selection(a.selection)
    half = "all" if a.sealed_apply else a.half
    res = report(ip, sel, a.frontend, kwargs, half, groups, a.bstar, tuple(A.parse_slug(s) for s in a.conditions.split(",") if s), a.boot,
                 sealed_apply=a.sealed_apply)
    d = out / f"{a.cmd}-{half}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "results.json").write_text(json.dumps(res, indent=1))
    (d / "results.md").write_text(report_md(res))
    print(d / "results.json")


if __name__ == "__main__":
    sys.exit(main())
