"""Metrics of transcript-changing systems relative to B (DESIGN.md 14.2 fe-7 to
fe-9; W5 DESIGN 9.2). One implementation shared by the harness's front-end
evaluator and W5's stage 0. Pure functions; no I/O.

Per mixture and system X, with W0's time-constrained alignment and attribution
(`align.align(timed=True)`, `align.attribute`, unchanged):
- correct_X: the target reference indices with an exact match;
- S and D by reference-word region, I by token region;
- n_int and n_other: hypothesis tokens attributed to an interferer or to
  neither source, by token region.
A region is `align.word_region`: overlap iff at least half of the span's
frames carry label 3.

Relative to B, by reference-word identity:
lost = correct_B - correct_X, gained = correct_X - correct_B, and gained_u =
gained words that are unreachable by filtering, meaning that B's whole
hypothesis holds no same-text, `align.compatible` token. A word whose match
moves between repeated words therefore counts as one loss plus one gain.

A mixture is a count vector (`COLS`). Every statistic is a ratio of weighted
sums (`summarize`), vectorised over any leading axes so that a whole bootstrap
is one matrix product. The threshold search for word filters (`step_counts`,
`pooled_steps`, `search_tau`) is exact under re-alignment: it evaluates every
attainable threshold and assumes no monotonicity.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Sequence

import numpy as np

from .align import DEL, INS, INTERFERER, MATCH, OTHER, SUB, Word, align, attribute, compatible, word_region
from .metrics import percentile_ci, weights_from_counts

REGIONS = ("single", "overlap")
_REG = {"single": 0, "overlap": 1}
REGION_FIELDS = ("n_ref", "correct", "lost", "gained", "gained_u", "S", "D", "I", "err_B", "n_int", "n_int_B", "n_other",
                 "n_other_B")
MIX_FIELDS = ("dropout", "dropout_B", "mixtures")
COLS = tuple(f"{f}/{r}" for f in REGION_FIELDS for r in REGIONS) + MIX_FIELDS
COL = {c: i for i, c in enumerate(COLS)}
BONFERRONI_LEVEL = 1 - 0.05 / 4  # the confirmatory family {H1a, H1b, H2, H5}
DROPOUT_LOST = 0.5  # refs.mixture_record's rule
DROPOUT_DRY_WER = 0.1


@dataclass(frozen=True)
class HypEval:
    """One system's hypothesis against one mixture's references. Pairs are
    (single, overlap)."""

    correct: frozenset
    ref_region: tuple  # 0 single / 1 overlap per target reference word
    S: tuple
    D: tuple
    I: tuple
    n_int: tuple
    n_other: tuple
    untimed_lost: int  # S + D of the untimed alignment (dropout rule)

    @property
    def n_ref(self) -> tuple:
        return (self.ref_region.count(0), self.ref_region.count(1))


def evaluate_hyp(hyp: Sequence[Word], target_ref: Sequence[Word], int_refs: Sequence[Sequence[Word]],
                 labels: np.ndarray) -> HypEval:
    ref_reg = tuple(_REG[word_region(r, labels)] for r in target_ref)
    tok_reg = [_REG[word_region(h, labels)] for h in hyp]
    S, D, I, ni, no = [0, 0], [0, 0], [0, 0], [0, 0], [0, 0]
    correct = set()
    for op, i, j in align(hyp, target_ref, timed=True):
        if op == MATCH:
            correct.add(j)
        elif op == SUB:
            S[ref_reg[j]] += 1
        elif op == DEL:
            D[ref_reg[j]] += 1
        elif op == INS:
            I[tok_reg[i]] += 1
    for a, r in zip(attribute(hyp, target_ref, int_refs, labels) if hyp else [], tok_reg):
        if a.source == INTERFERER:
            ni[r] += 1
        elif a.source == OTHER:
            no[r] += 1
    ut = sum(op in (SUB, DEL) for op, _, _ in align(hyp, target_ref, timed=False))
    return HypEval(frozenset(correct), ref_reg, tuple(S), tuple(D), tuple(I), tuple(ni), tuple(no), int(ut))


def unreachable(b_hyp: Sequence[Word], target_ref: Sequence[Word]) -> frozenset:
    """Reference indices no word filter can make correct: B's hypothesis holds no
    token with the same text that is time-compatible with the word."""
    return frozenset(j for j, r in enumerate(target_ref) if not any(h.text == r.text and compatible(h, r) for h in b_hyp))


def is_dropout(e: HypEval, dry_target_wer: float) -> bool:
    """refs.mixture_record's target-dropout rule applied to any system: more
    than half of the target words lost (untimed S + D) while the dry target
    alone transcribes with WER <= 10 %."""
    n = sum(e.n_ref)
    return bool(e.untimed_lost / max(1, n) > DROPOUT_LOST and dry_target_wer <= DROPOUT_DRY_WER)


def mix_counts(x: HypEval, b: HypEval, unreach: frozenset, dropout_x: bool, dropout_b: bool) -> np.ndarray:
    """The count vector (COLS) of system X on one mixture, relative to B."""
    if x.ref_region != b.ref_region:
        raise ValueError("X and B were evaluated against different references")
    out = np.zeros(len(COLS), dtype=np.float64)

    def put(field: str, pair) -> None:
        out[COL[f"{field}/single"]] += pair[0]
        out[COL[f"{field}/overlap"]] += pair[1]

    def by_ref(idx) -> tuple:
        c = [0, 0]
        for j in idx:
            c[x.ref_region[j]] += 1
        return tuple(c)

    put("n_ref", x.n_ref)
    put("correct", by_ref(x.correct))
    put("lost", by_ref(b.correct - x.correct))
    gained = x.correct - b.correct
    put("gained", by_ref(gained))
    put("gained_u", by_ref(gained & unreach))
    put("S", x.S)
    put("D", x.D)
    put("I", x.I)
    put("err_B", tuple(b.S[r] + b.D[r] + b.I[r] for r in range(2)))
    put("n_int", x.n_int)
    put("n_int_B", b.n_int)
    put("n_other", x.n_other)
    put("n_other_B", b.n_other)
    out[COL["dropout"]] = float(dropout_x)
    out[COL["dropout_B"]] = float(dropout_b)
    out[COL["mixtures"]] = 1.0
    return out


def weighted_totals(C: np.ndarray, w: np.ndarray, mask: np.ndarray | None = None) -> np.ndarray:
    """Weighted sums of per-mixture count vectors C [n_mix, COLS]. w is [n_mix],
    or [..., n_mix] for many weightings at once (bootstrap). mask zeroes
    mixtures out."""
    w = np.asarray(w, dtype=np.float64)
    if mask is not None:
        w = w * np.asarray(mask, dtype=np.float64)
    return w @ np.asarray(C, dtype=np.float64)


def _ratio(num, den):
    num, den = np.asarray(num, dtype=np.float64), np.asarray(den, dtype=np.float64)
    with np.errstate(divide="ignore", invalid="ignore"):
        r = np.where(den > 0, num / np.where(den > 0, den, 1.0), np.nan)
    return float(r) if r.ndim == 0 else r


def summarize(totals: np.ndarray) -> dict:
    """Statistics from totals [..., COLS]; each value has the leading shape (a
    float for a single total). NaN where a denominator is 0 (e.g. R without any
    interferer word of B), which the bootstrap counts as an invalid resample."""
    t = np.asarray(totals, dtype=np.float64)

    def g(field: str, region: str):
        if region == "all":
            return t[..., COL[f"{field}/single"]] + t[..., COL[f"{field}/overlap"]]
        return t[..., COL[f"{field}/{region}"]]

    out: dict = {}
    for r in ("all",) + REGIONS:
        n = g("n_ref", r)
        err = g("S", r) + g("D", r) + g("I", r)
        out[f"R/{r}"] = _ratio(g("n_int", r), g("n_int_B", r))
        out[f"L+/{r}"] = _ratio(g("lost", r), n)
        out[f"G/{r}"] = _ratio(g("gained", r), n)
        out[f"G_u/{r}"] = _ratio(g("gained_u", r), n)
        out[f"net_L/{r}"] = _ratio(g("lost", r) - g("gained", r), n)
        out[f"G_u-L+/{r}"] = _ratio(g("gained_u", r) - g("lost", r), n)
        out[f"E/{r}"] = _ratio(g("S", r) + g("D", r), n)
        out[f"WER/{r}"] = _ratio(err, n)
        out[f"WER_B/{r}"] = _ratio(g("err_B", r), n)
        out[f"dWER/{r}"] = _ratio(err - g("err_B", r), n)
        out[f"other/{r}"] = _ratio(g("n_other", r), n)
        out[f"d_other/{r}"] = _ratio(g("n_other", r) - g("n_other_B", r), n)
        out[f"coverage/{r}"] = _ratio(g("correct", r), n)
        for c in ("n_ref", "n_int", "n_int_B", "n_other", "n_other_B"):
            v = g(c, r)
            out[f"{c}/{r}" if c != "n_ref" else f"N/{r}"] = float(v) if np.ndim(v) == 0 else v
    m = t[..., COL["mixtures"]]
    out["dropout"] = _ratio(t[..., COL["dropout"]], m)
    out["dropout_B"] = _ratio(t[..., COL["dropout_B"]], m)
    out["n_mixtures"] = float(m) if np.ndim(m) == 0 else m
    return out


# --- word-filter thresholds (exact under re-alignment) -------------------------------------


def step_counts(hyp: Sequence[Word], means: np.ndarray, count_fn: Callable[[list], np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """One mixture's counts as a step function of tau. A token is kept iff its
    mean >= tau. With levels l_1 < ... < l_K the distinct means, state s (s
    levels below tau) keeps the tokens with mean >= l_{s+1}; state K keeps none.
    Returns (levels [K], counts [K + 1, COLS]); count_fn(kept tokens) is
    evaluated (re-aligned) at every state."""
    m = np.asarray(means, dtype=np.float64)
    if m.shape != (len(hyp),):
        raise ValueError("one mean per hypothesis token")
    if not np.isfinite(m).all():
        raise ValueError("token means must be finite")
    levels = np.unique(m)
    cuts = np.concatenate([levels, [np.inf]])
    counts = np.stack([np.asarray(count_fn([h for h, v in zip(hyp, m) if v >= c]), dtype=np.float64) for c in cuts])
    return levels, counts


def pooled_steps(steps: Sequence[tuple[np.ndarray, np.ndarray]], weights: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Weighted pooled totals at every candidate threshold: every distinct token
    mean of every mixture (a mixture of weight 0 still contributes its levels),
    plus +inf, which removes everything. Exact, via difference arrays over the
    sorted candidates. Returns (candidates [n], totals [n, COLS])."""
    w = np.asarray(weights, dtype=np.float64)
    if w.shape != (len(steps),):
        raise ValueError("one weight per mixture")
    cands = np.unique(np.concatenate([lv for lv, _ in steps] + [np.array([np.inf])]))
    delta = np.zeros((cands.size + 1, len(COLS)), dtype=np.float64)
    for (levels, counts), wi in zip(steps, w):
        if wi == 0:
            continue
        delta[0] += wi * counts[0]
        # state k (k >= 1) holds from the first candidate strictly above level k-1
        at = np.searchsorted(cands, levels, side="right")
        np.add.at(delta, at, wi * (counts[1:] - counts[:-1]))
    return cands, np.cumsum(delta[:-1], axis=0)


def largest_feasible(values: np.ndarray, allowed: float) -> int | None:
    """Index of the largest candidate (ascending) whose value is within
    `allowed`, checking every candidate (values need not be monotone)."""
    ok = np.flatnonzero(np.asarray(values, dtype=np.float64) <= allowed + 1e-9)
    return int(ok[-1]) if ok.size else None


def budget_rule(budget: float) -> Callable[[np.ndarray], np.ndarray]:
    """Pooled gross loss within the budget: lost <= budget * N (count space, as
    W0's calibration)."""
    def rule(totals: np.ndarray) -> np.ndarray:
        t = np.asarray(totals, dtype=np.float64)
        lost = t[..., COL["lost/single"]] + t[..., COL["lost/overlap"]]
        n = t[..., COL["n_ref/single"]] + t[..., COL["n_ref/overlap"]]
        return lost <= budget * n + 1e-9
    return rule


def matched_rule(limit: float) -> Callable[[np.ndarray], np.ndarray]:
    """dWER (all regions, re-aligned, vs B) at most `limit` (e.g. F's half-A
    dWER_S0 when the weights select S0 mixtures). Undefined (N = 0) is
    infeasible."""
    def rule(totals: np.ndarray) -> np.ndarray:
        d = np.asarray(summarize(totals)["dWER/all"], dtype=np.float64)
        return np.isfinite(d) & (d <= limit + 1e-12)
    return rule


def search_tau(steps: Sequence[tuple[np.ndarray, np.ndarray]], weights: np.ndarray,
               rule: Callable[[np.ndarray], np.ndarray]) -> tuple[float | None, int | None, np.ndarray | None]:
    """The largest candidate threshold whose pooled totals satisfy `rule`, with
    every candidate checked. Returns (tau, candidate index, totals at tau), or
    (None, None, None) if none does (the infeasible case).

    The convention is the decision rule's: keep iff mean >= tau. So tau = +inf
    removes every token, and keep-everything is the smallest candidate (the
    minimum token mean, or +inf only if there are no tokens at all)."""
    cands, totals = pooled_steps(steps, weights)
    ok = np.flatnonzero(np.asarray(rule(totals), dtype=bool))
    if not ok.size:
        return None, None, None
    j = int(ok[-1])
    return float(cands[j]), j, totals[j]


# --- bootstrap -----------------------------------------------------------------------------


def boot_draws(n_universe: int, n_boot: int = 2000, seed: int = 0) -> np.ndarray:
    """Speaker draw counts [n_boot, n_universe], generated exactly as
    evaluate.compute_metrics does (one generator, `bincount(integers(0, U, U))`
    per resample), so systems evaluated here and scorers evaluated there share
    resamples."""
    rng = np.random.default_rng(seed)
    return np.stack([np.bincount(rng.integers(0, n_universe, n_universe), minlength=n_universe).astype(np.float64)
                     for _ in range(n_boot)]) if n_boot else np.zeros((0, n_universe))


def boot_weights(inv: np.ndarray, draws: np.ndarray) -> np.ndarray:
    """Mixture weights [n_boot, n_mix]: the product of the draw counts of each
    mixture's speakers (metrics.weights_from_counts per resample)."""
    return np.stack([weights_from_counts(inv, c) for c in draws]) if len(draws) else np.zeros((0, inv.shape[0]))


def ci(values: np.ndarray, level: float = 0.95) -> tuple[float, float]:
    """Percentile CI over the finite resamples (metrics.percentile_ci)."""
    return percentile_ci(values, level)


__all__ = ["REGIONS", "REGION_FIELDS", "MIX_FIELDS", "COLS", "COL", "BONFERRONI_LEVEL", "HypEval", "evaluate_hyp",
           "unreachable", "is_dropout", "mix_counts", "weighted_totals", "summarize", "step_counts", "pooled_steps",
           "largest_feasible", "budget_rule", "matched_rule", "search_tau", "boot_draws", "boot_weights", "ci"]
