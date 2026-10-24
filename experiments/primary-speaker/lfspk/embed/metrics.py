"""Verification metrics with trial weights, and a speaker-level bootstrap.

Bootstrap over speakers: each replicate draws the speaker set with
replacement; a speaker drawn m times contributes its target trials with weight
m, and a non-target trial between enrolled speaker A and test speaker B
(A != B) gets weight m_A * m_B. Trials between two copies of the same speaker
are not formed. Every system compared in one table uses the same replicates,
so paired differences are valid.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Roc:
    fnr: np.ndarray  # increasing, starts at 0
    fpr: np.ndarray  # decreasing, starts at 1


def _check(scores, labels, weights):
    scores = np.asarray(scores, np.float64)
    labels = np.asarray(labels, bool)
    weights = np.ones_like(scores) if weights is None else np.asarray(weights, np.float64)
    if not (scores.shape == labels.shape == weights.shape) or scores.ndim != 1:
        raise ValueError("scores, labels and weights must be 1-D and equally long")
    if not np.isfinite(scores).all() or (weights < 0).any():
        raise ValueError("non-finite score or negative weight")
    return scores, labels, weights


class SortedTrials:
    """Scores sorted once; ROC for any trial weighting in O(n)."""

    def __init__(self, scores, labels):
        scores, labels, _ = _check(scores, labels, None)
        self.order = np.argsort(scores, kind="mergesort")
        s = scores[self.order]
        self.labels = labels[self.order]
        self.last = np.r_[s[1:] != s[:-1], True] if s.size else np.zeros(0, bool)

    def roc(self, weights=None) -> Roc:
        n = self.labels.size
        w = np.ones(n) if weights is None else np.asarray(weights, np.float64)[self.order]
        tw = np.where(self.labels, w, 0.0)
        nw = w - tw
        t_tot, n_tot = tw.sum(), nw.sum()
        if t_tot <= 0 or n_tot <= 0:
            raise ValueError("need positive target and non-target weight")
        # Threshold above the i-th distinct score: everything at or below is rejected.
        fnr = np.r_[0.0, np.cumsum(tw)[self.last]] / t_tot
        fpr = 1.0 - np.r_[0.0, np.cumsum(nw)[self.last]] / n_tot
        return Roc(fnr, fpr)


def eer_from_roc(roc: Roc) -> float:
    """Equal error rate by linear interpolation where FNR crosses FPR."""
    d = roc.fnr - roc.fpr  # increasing from -1 to 1
    i = int(np.argmax(d >= 0))
    if i == 0:
        return float(roc.fpr[0])
    d0, d1 = d[i - 1], d[i]
    t = d0 / (d0 - d1) if d1 != d0 else 0.0
    return float(roc.fnr[i - 1] + t * (roc.fnr[i] - roc.fnr[i - 1]))


def min_dcf_from_roc(roc: Roc, p_target: float, c_miss: float = 1.0, c_fa: float = 1.0) -> float:
    """Normalised minimum detection cost (NIST SRE definition)."""
    dcf = c_miss * p_target * roc.fnr + c_fa * (1 - p_target) * roc.fpr
    return float(dcf.min() / min(c_miss * p_target, c_fa * (1 - p_target)))


def fpr_at_fnr_from_roc(roc: Roc, fnr_target: float) -> float:
    """Lowest impostor pass rate attainable with a target miss rate of at most
    `fnr_target`: the last ROC point whose FNR is within the budget (FPR never
    rises along the ROC), interpolated linearly toward the next point so that
    the miss rate equals the budget exactly. This is the product-relevant
    operating point: the contract budgets target loss (0.5 % of words), so what
    matters is how many impostors survive there."""
    if not 0.0 <= fnr_target <= 1.0:
        raise ValueError("fnr_target outside [0, 1]")
    j = int(np.nonzero(roc.fnr <= fnr_target)[0][-1])  # fnr[0] == 0, so j exists
    if roc.fnr[j] == fnr_target or j == roc.fnr.size - 1:
        return float(roc.fpr[j])
    f0, f1 = roc.fnr[j], roc.fnr[j + 1]
    t = (fnr_target - f0) / (f1 - f0)
    return float(roc.fpr[j] + t * (roc.fpr[j + 1] - roc.fpr[j]))


def eer(scores, labels, weights=None) -> float:
    return eer_from_roc(SortedTrials(scores, labels).roc(weights))


def min_dcf(scores, labels, p_target: float, weights=None) -> float:
    return min_dcf_from_roc(SortedTrials(scores, labels).roc(weights), p_target)


def speaker_multiplicities(n_speakers: int, n_boot: int, seed: int) -> np.ndarray:
    """(n_boot, n_speakers) counts of each speaker in each replicate."""
    rng = np.random.default_rng(seed)
    draws = rng.integers(0, n_speakers, size=(n_boot, n_speakers))
    return np.stack([np.bincount(d, minlength=n_speakers) for d in draws])


def trial_weights(mult: np.ndarray, model_spk: np.ndarray, test_spk: np.ndarray,
                  extra_spk: np.ndarray | None = None) -> np.ndarray:
    """Weights of each trial for one replicate's multiplicities (see module
    doc). `extra_spk` (per trial, -1 for none) names one more identity the
    trial involves, e.g. a second speaker whose dictations entered the
    enrolled profile: the trial then also needs that speaker drawn, and its
    weight is the product of the multiplicities of the distinct identities
    {model, test, extra}."""
    model_spk = np.asarray(model_spk)
    test_spk = np.asarray(test_spk)
    target = model_spk == test_spk
    w = np.where(target, mult[model_spk], mult[model_spk] * mult[test_spk]).astype(np.float64)
    if extra_spk is not None:
        extra_spk = np.asarray(extra_spk)
        distinct = (extra_spk >= 0) & (extra_spk != model_spk) & (extra_spk != test_spk)
        w = w * np.where(distinct, mult[np.maximum(extra_spk, 0)], 1)
    return w


@dataclass(frozen=True)
class Estimate:
    value: float
    lo: float
    hi: float

    def as_dict(self) -> dict:
        return {"value": self.value, "lo": self.lo, "hi": self.hi}


def bootstrap(metric, scores, labels, model_spk, test_spk, mults: np.ndarray, alpha: float = 0.05):
    """Point estimate and percentile CI of `metric(Roc)` over speaker replicates.
    Returns (Estimate, replicate values) so callers can pair systems."""
    st = SortedTrials(scores, labels)
    point = metric(st.roc())
    reps = []
    for m in mults:
        w = trial_weights(m, model_spk, test_spk)
        try:
            reps.append(metric(st.roc(w)))
        except ValueError:  # a replicate without targets or non-targets
            reps.append(np.nan)
    reps = np.asarray(reps)
    ok = reps[np.isfinite(reps)]
    lo, hi = np.percentile(ok, [100 * alpha / 2, 100 * (1 - alpha / 2)])
    return Estimate(float(point), float(lo), float(hi)), reps


def bootstrap_multi(metrics: dict, scores, labels, model_spk, test_spk, mults: np.ndarray, alpha: float = 0.05,
                    extra_spk=None):
    """`bootstrap` for several metrics of the same ROC per replicate:
    {name: (Estimate, replicate values)}. `extra_spk`: see `trial_weights`."""
    st = SortedTrials(scores, labels)
    roc = st.roc()
    points = {k: f(roc) for k, f in metrics.items()}
    reps = {k: [] for k in metrics}
    for m in mults:
        try:
            r = st.roc(trial_weights(m, model_spk, test_spk, extra_spk))
            for k, f in metrics.items():
                reps[k].append(f(r))
        except ValueError:
            for k in metrics:
                reps[k].append(np.nan)
    out = {}
    for k in metrics:
        v = np.asarray(reps[k])
        ok = v[np.isfinite(v)]
        lo, hi = np.percentile(ok, [100 * alpha / 2, 100 * (1 - alpha / 2)])
        out[k] = (Estimate(float(points[k]), float(lo), float(hi)), v)
    return out


def paired_difference(point_a: float, reps_a, point_b: float, reps_b, alpha: float = 0.05) -> Estimate:
    d = np.asarray(reps_a) - np.asarray(reps_b)
    d = d[np.isfinite(d)]
    lo, hi = np.percentile(d, [100 * alpha / 2, 100 * (1 - alpha / 2)])
    return Estimate(point_a - point_b, float(lo), float(hi))
