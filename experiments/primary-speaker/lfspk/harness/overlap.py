"""Why does the oracle keep interferer words? (owner-requested diagnostic; descriptive only)

    ./python -m lfspk.harness.overlap --set dev-v1 [--out FILE.json]

At the headline condition (builtin, clean, k = 10; primary coherent mixtures of
headline targets), the oracle scores each frame 1 where the target is labelled
active, so a word's oracle score is the fraction of its decision span (Parakeet
span widened 80 ms, the contract rule) covered by target-speech frames, and the
oracle keeps it iff that fraction >= the oracle's dev tau. This module reports:

- the distribution of that target-coverage fraction over all interferer words
  and over the interferer words the oracle keeps, in bins 0, (0, .25],
  (.25, .5], (.5, 1];
- the share of kept interferer words with coverage above 0.5 (overlap the word
  rule cannot split);
- a cause for each kept interferer word: the strictest of the nested label
  variants, recomputed from the same placements and alignments, under which
  the actual decision (the widened span) already keeps it: `acoustic` (the
  target's aligned word intervals themselves, no padding, no gap merging) ⊂
  `padding` (+ the 40 ms label padding) ⊂ `gap_merging` (+ inter-word gaps under
  200 ms merged = the frozen labels). Causes are exclusive and exhaustive for
  kept words (eval overlap-r1 #1);
- the role of the 80 ms widening, separately: a cross-tab of each decision
  against the decision the unwidened Parakeet span would get with the frozen
  labels;
- for target words the oracle removes (correctly recognised target words below
  tau): `pause` (no target frame in the widened span: a timestamp shifted into a
  labelled pause) or `partial` (0 < coverage < tau), with the same widening
  cross-tab (`raw_span_would_keep`: widening diluted it below tau).

No tuning, no CIs: counts and fractions. Refuses sets that are not dev.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from .align import frame_span
from .forced import GAP_S, PAD_S, words_to_frames

BINS = ("0", "(0,.25]", "(.25,.5]", "(.5,1]")
KEPT_CAUSES = ("acoustic", "padding", "gap_merging")
REMOVED_CAUSES = ("pause", "partial")
# Strictest first: (pad, gap) of each target-activity variant.
VARIANTS = {"raw": (0.0, 0.0), "padded": (PAD_S, 0.0), "primary": (PAD_S, GAP_S)}


def coverage(f0: int, f1: int, act: np.ndarray) -> float:
    """Fraction of frames [f0, f1) that are target-active."""
    seg = act[f0:f1]
    return float(seg.mean()) if seg.size else 0.0


def bin_of(x: float) -> str:
    if x <= 0.0:
        return BINS[0]
    if x <= 0.25:
        return BINS[1]
    if x <= 0.5:
        return BINS[2]
    return BINS[3]


def kept_cause(span: tuple[int, int], acts: dict[str, np.ndarray], tau: float) -> str:
    """The strictest nested label variant under which the decision span is
    covered >= tau (span: the widened decision frames of a kept word)."""
    f0, f1 = span
    if coverage(f0, f1, acts["raw"]) >= tau:
        return "acoustic"
    if coverage(f0, f1, acts["padded"]) >= tau:
        return "padding"
    if coverage(f0, f1, acts["primary"]) >= tau:
        return "gap_merging"
    raise ValueError("kept_cause called for a word the frozen labels do not keep")


def removed_cause(span: tuple[int, int], act_primary: np.ndarray, tau: float) -> str:
    """For a removed word (span: widened decision frames, coverage < tau)."""
    f0, f1 = span
    cov = coverage(f0, f1, act_primary)
    if cov >= tau:
        raise ValueError("removed_cause called for a word the frozen labels keep")
    return "pause" if cov <= 0.0 else "partial"


def placed_target_activity(corpus, placements: Sequence[Sequence[Any]], n_frames: int, pad_s: float, gap_s: float) -> np.ndarray:
    """Target activity under a (pad, gap) rule from the recorded placements."""
    from ..api import FRAME_SAMPLES
    from .activity import place

    out = np.zeros(n_frames, bool)
    for uid, s, e, off in placements:
        u = corpus.utterance_by_id[uid]
        n = -(-u.samples // FRAME_SAMPLES)
        a = words_to_frames(corpus.alignment(uid), n, pad_s, gap_s)
        out |= place(a[s:e], off, n_frames)
    return out


def summarize(items: Sequence[dict[str, Any]], tau: float) -> dict[str, Any]:
    """items: one per interferer or correct-target token with keys group,
    source ('interferer' | 'target'), cov (widened, primary labels), and cause
    (for kept interferer / removed target words)."""
    out: dict[str, Any] = {"tau": tau}
    by: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for it in items:
        by[it["group"]].append(it)
        if it["group"] != "S0":
            by["pooled_S1-S4"].append(it)
    for g, its in sorted(by.items()):
        intf = [i for i in its if i["source"] == "interferer"]
        kept = [i for i in intf if i["cov"] >= tau]
        tgt = [i for i in its if i["source"] == "target"]
        rem = [i for i in tgt if i["cov"] < tau]
        dist = lambda xs: {b: c / max(1, len(xs)) for b, c in ((b, sum(1 for x in xs if bin_of(x["cov"]) == b)) for b in BINS)}
        causes = lambda xs, names: {c: sum(1 for x in xs if x["cause"] == c) / max(1, len(xs)) for c in names}
        raw_keep = lambda xs: sum(1 for x in xs if x.get("raw_keep")) / max(1, len(xs))
        out[g] = {
            "interferer_words": len(intf), "kept": len(kept), "kept_fraction": len(kept) / max(1, len(intf)),
            "coverage_all_interferer": dist(intf), "coverage_kept_interferer": dist(kept),
            "kept_explained_by_overlap_above_half": sum(1 for x in kept if x["cov"] > 0.5) / max(1, len(kept)),
            "kept_causes": causes(kept, KEPT_CAUSES),
            "kept_causes_low_overlap": causes([x for x in kept if x["cov"] <= 0.5], KEPT_CAUSES),
            # Widening cross-tab: share whose unwidened span would also be kept.
            "kept_raw_span_would_keep": raw_keep(kept),
            "dropped_interferer_raw_span_would_keep": raw_keep([x for x in intf if x["cov"] < tau]),
            "correct_target_words": len(tgt), "removed": len(rem), "removed_fraction": len(rem) / max(1, len(tgt)),
            "coverage_removed_target": dist(rem), "removed_causes": causes(rem, REMOVED_CAUSES),
            "removed_raw_span_would_keep": raw_keep(rem),
        }
    return out


def run(set_id: str, fs=None, words=None, corpus=None) -> dict[str, Any]:
    from . import metrics as M
    from .corpora import Corpus
    from .evaluate import HEADLINE_RELATIONS, oracle_scores
    from .frozen import FrozenSet
    from .refs import read_words

    fs = fs or FrozenSet(set_id)
    if fs.manifest[0]["meta"]["split"] != "dev":
        raise SystemExit("this diagnostic runs on dev sets only")
    words = words if words is not None else read_words(set_id)
    corpus = corpus or Corpus("dev")
    rows = fs.manifest
    # Every mixture's recomputed target activity must equal its frozen labels
    # (eval overlap-r1 #3: checked before filtering to the headline).
    acts_all = []
    for r in rows:
        F = int(r["meta"]["frames"])
        acts = {k: placed_target_activity(corpus, r["meta"]["target"]["placements"], F, p, g) for k, (p, g) in VARIANTS.items()}
        lab = fs.labels(r)["labels"]
        if not np.array_equal(acts["primary"], (lab == 1) | (lab == 3)):
            raise SystemExit(f"{r['id']}: recomputed primary target activity differs from the frozen labels")
        acts_all.append(acts)
    rel = np.array([r["relation_at"]["10"] or "short" for r in rows])
    head = np.isin(rel, HEADLINE_RELATIONS) & np.array([r.get("rir_mode", "coherent") == "coherent" for r in rows])
    records = [words[r["id"]] for r in rows]
    tok = M.build_tokens(records, [r["scenario"] for r in rows])
    orc = list(oracle_scores(fs, rows).values())
    led = M.Ledger(tok, M.token_means(tok, orc))
    tau = led.calibrate(head.astype(float))  # the oracle's dev tau, exactly as the evaluator fits it
    if not np.isfinite(tau):
        raise SystemExit("oracle uncalibrated on this selection (no correctly recognised target word); nothing to diagnose")
    items = []
    for m, r in enumerate(rows):
        if not head[m]:
            continue
        F = int(r["meta"]["frames"])
        acts = acts_all[m]
        for t in records[m]["tokens"]:
            src, kind = t[4], t[5]
            if not (src == "interferer" or (src == "target" and kind == "C")):
                continue
            span = (t[1], t[2])  # the widened decision frames
            cov = coverage(*span, acts["primary"])
            raw_keep = coverage(*frame_span(t[10], t[11], F), acts["primary"]) >= tau
            if src == "interferer":
                cause = kept_cause(span, acts, tau) if cov >= tau else None
            else:
                cause = removed_cause(span, acts["primary"], tau) if cov < tau else None
            items.append({"group": r["scenario"], "source": src, "cov": cov, "cause": cause, "raw_keep": raw_keep})
    res = summarize(items, tau)
    res.update({"set_id": set_id, "set_hash": fs.hash, "condition": "builtin|clean|10", "n_mixtures": int(head.sum())})
    return res


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", required=True)
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args(argv)
    res = run(a.set)
    text = json.dumps(res, indent=1)
    if a.out:
        a.out.write_text(text)
    print(text)


if __name__ == "__main__":
    sys.exit(main())
