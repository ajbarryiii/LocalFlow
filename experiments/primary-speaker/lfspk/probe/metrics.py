"""Detection metrics with sample weights and the speaker bootstrap (DESIGN 5.4, 6.3).

Weights let the bootstrap resample speakers by multiplicity without copying
trials: a speaker drawn k times contributes each of its items with weight k.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import numpy as np

P_TARGET = 0.01
C_MISS = 1.0
C_FA = 1.0


class SortedTrials:
    """Scores sorted once; EER, minDCF and AUC evaluated for any weight vector.

    labels: 1 target / positive, 0 non-target / negative.
    """

    def __init__(self, scores: np.ndarray, labels: np.ndarray):
        scores = np.asarray(scores, dtype=np.float64)
        labels = np.asarray(labels).astype(bool)
        if scores.shape != labels.shape or scores.ndim != 1:
            raise ValueError("scores and labels must be 1-D of equal length")
        if not np.isfinite(scores).all():
            raise ValueError("non-finite score")
        order = np.argsort(scores, kind="stable")
        self.order = order
        self.labels = labels[order]
        s = scores[order]
        # boundaries between distinct score values (ties form one operating point)
        self.last_of_group = np.r_[s[1:] != s[:-1], True]

    def _curves(self, w: np.ndarray | None) -> tuple[np.ndarray, np.ndarray]:
        """P_miss and P_fa at thresholds just above each distinct score, plus the
        threshold below everything (accept all): arrays of length groups + 1,
        P_miss increasing, P_fa decreasing."""
        if w is None:
            w = np.ones(self.labels.size)
        else:
            w = np.asarray(w, dtype=np.float64)[self.order]
        wt = np.where(self.labels, w, 0.0)
        wn = np.where(self.labels, 0.0, w)
        tot_t, tot_n = wt.sum(), wn.sum()
        if tot_t <= 0 or tot_n <= 0:
            raise ValueError("need positive weight on both classes")
        ct = np.cumsum(wt)[self.last_of_group]
        cn = np.cumsum(wn)[self.last_of_group]
        p_miss = np.r_[0.0, ct / tot_t]
        p_fa = np.r_[1.0, 1.0 - cn / tot_n]
        return p_miss, p_fa

    def eer(self, w: np.ndarray | None = None) -> float:
        """Equal error rate by linear interpolation where P_miss crosses P_fa."""
        return _eer_from(*self._curves(w))

    def min_dcf(self, w: np.ndarray | None = None, p_target: float = P_TARGET) -> float:
        return _dcf_from(*self._curves(w), p_target)

    def eer_dcf(self, w: np.ndarray | None = None, p_target: float = P_TARGET) -> tuple[float, float]:
        """(EER, normalised minDCF) from one pass over the curve."""
        p_miss, p_fa = self._curves(w)
        return _eer_from(p_miss, p_fa), _dcf_from(p_miss, p_fa, p_target)

    def auc(self, w: np.ndarray | None = None) -> float:
        """P(positive score > negative score) + 0.5 P(tie), weighted."""
        p_miss, p_fa = self._curves(w)
        # ROC with TPR = 1 - p_miss, FPR = p_fa; trapezoid handles ties as 0.5.
        tpr, fpr = 1.0 - p_miss, p_fa
        return float(np.sum((fpr[:-1] - fpr[1:]) * (tpr[:-1] + tpr[1:]) / 2.0))


class GroupedTrials:
    """Same statistics as SortedTrials when item weights are constant within
    groups (e.g. a mixture's (target, interferer) speaker pair): items are
    pre-aggregated into per-group histograms over the distinct score values,
    so a resample costs a [groups] x [values] product instead of a sort-order
    cumulative sum over every item. Exact, including ties."""

    def __init__(self, scores: np.ndarray, labels: np.ndarray, groups: np.ndarray, n_groups: int):
        from scipy.sparse import csr_matrix

        scores = np.asarray(scores, dtype=np.float64)
        labels = np.asarray(labels).astype(bool)
        groups = np.asarray(groups)
        if scores.shape != labels.shape or scores.shape != groups.shape or scores.ndim != 1:
            raise ValueError("scores, labels and groups must be 1-D of equal length")
        if not np.isfinite(scores).all():
            raise ValueError("non-finite score")
        if groups.size and (groups.min() < 0 or groups.max() >= n_groups):
            raise ValueError("group index out of range")
        values, inv = np.unique(scores, return_inverse=True)
        self.n_values = values.size
        shape = (n_groups, values.size)
        ones = np.ones(int(labels.sum()))
        self.pos = csr_matrix((ones, (groups[labels], inv[labels])), shape=shape)
        ones = np.ones(int((~labels).sum()))
        self.neg = csr_matrix((ones, (groups[~labels], inv[~labels])), shape=shape)
        self.n_groups = n_groups

    def _curves(self, wg: np.ndarray | None) -> tuple[np.ndarray, np.ndarray]:
        wg = np.ones(self.n_groups) if wg is None else np.asarray(wg, dtype=np.float64)
        pt = self.pos.T @ wg
        nt = self.neg.T @ wg
        tot_t, tot_n = pt.sum(), nt.sum()
        if tot_t <= 0 or tot_n <= 0:
            raise ValueError("need positive weight on both classes")
        p_miss = np.r_[0.0, np.cumsum(pt) / tot_t]
        p_fa = np.r_[1.0, 1.0 - np.cumsum(nt) / tot_n]
        return p_miss, p_fa

    def auc_eer(self, wg: np.ndarray | None = None) -> np.ndarray:
        """[AUC, EER, P_fa at P_miss <= 1 %, P_fa at P_miss <= 2 %] for group
        weights wg (None = unit weights)."""
        p_miss, p_fa = self._curves(wg)
        tpr = 1.0 - p_miss
        auc = float(np.sum((p_fa[:-1] - p_fa[1:]) * (tpr[:-1] + tpr[1:]) / 2.0))
        return np.array([auc, _eer_from(p_miss, p_fa), _fa_at_miss(p_miss, p_fa, 0.01),
                         _fa_at_miss(p_miss, p_fa, 0.02)])


def _eer_from(p_miss: np.ndarray, p_fa: np.ndarray) -> float:
    d = p_miss - p_fa  # non-decreasing from -1 to +1
    i = int(np.searchsorted(d, 0.0))  # first index with d >= 0
    if i == 0:
        return float(p_miss[0])
    d0, d1 = d[i - 1], d[i]
    a = d0 / (d0 - d1) if d1 != d0 else 0.0
    return float(p_miss[i - 1] + a * (p_miss[i] - p_miss[i - 1]))


def _fa_at_miss(p_miss: np.ndarray, p_fa: np.ndarray, miss: float) -> float:
    """Operating point: the false-accept rate at the strictest threshold whose
    miss rate is still <= `miss` (no interpolation; ties stay together). For
    frames: the fraction of interferer-only frames kept when at most `miss` of
    target-speech frames are dropped."""
    ok = np.flatnonzero(p_miss <= miss + 1e-12)
    return float(p_fa[ok[-1]])


def _dcf_from(p_miss: np.ndarray, p_fa: np.ndarray, p_target: float) -> float:
    c = C_MISS * p_target * p_miss + C_FA * (1 - p_target) * p_fa
    return float(c.min() / min(C_MISS * p_target, C_FA * (1 - p_target)))


def eer(scores, labels, weights=None) -> float:
    return SortedTrials(scores, labels).eer(weights)


def min_dcf(scores, labels, weights=None, p_target: float = P_TARGET) -> float:
    return SortedTrials(scores, labels).min_dcf(weights, p_target)


def auc(scores, labels, weights=None) -> float:
    return SortedTrials(scores, labels).auc(weights)


@dataclass(frozen=True)
class Estimate:
    value: float
    lo: float
    hi: float

    def as_dict(self) -> dict:
        return {"value": self.value, "lo": self.lo, "hi": self.hi}


def resample_weights(n_groups: int, n_boot: int, seed: int, strata: np.ndarray | None = None) -> np.ndarray:
    """[n_boot, n_groups] multiplicities of a with-replacement draw of groups.

    With `strata` (one label per group) groups are drawn within each stratum,
    so every resample keeps the stratum sizes (e.g. the session classes)."""
    rng = np.random.default_rng(seed)
    if strata is None:
        strata = np.zeros(n_groups, dtype=int)
    strata = np.asarray(strata)
    if strata.size != n_groups:
        raise ValueError("one stratum label per group")
    out = np.zeros((n_boot, n_groups))
    for st in np.unique(strata):
        members = np.flatnonzero(strata == st)
        draws = members[rng.integers(0, members.size, size=(n_boot, members.size))]
        for b in range(n_boot):
            out[b] += np.bincount(draws[b], minlength=n_groups)
    return out


def one_way(groups: np.ndarray) -> Callable[[np.ndarray], np.ndarray]:
    """Item weight = multiplicity of the item's group."""
    groups = np.asarray(groups)
    return lambda m: m[groups]


def two_way(g_enroll: np.ndarray, g_test: np.ndarray, target: np.ndarray) -> Callable[[np.ndarray], np.ndarray]:
    """Speaker bootstrap over both trial roles with one shared draw of speakers.

    A non-target trial (enrollment speaker a, test speaker b) counts once per
    pair of drawn copies: m_a * m_b (zero unless both were drawn). A target
    trial counts once per drawn copy of its speaker: m_a. Test-speaker
    variability (one hard impostor recording reused across many enrollment
    models) therefore enters the interval, which one-way enrollment resampling
    misses."""
    ge, gt, tg = np.asarray(g_enroll), np.asarray(g_test), np.asarray(target).astype(bool)
    if not np.array_equal(ge[tg], gt[tg]):
        raise ValueError("target trials must have the same speaker in both roles")
    return lambda m: np.where(tg, m[ge], m[ge] * m[gt])


def pair_weights(g_a: np.ndarray, g_b: np.ndarray) -> Callable[[np.ndarray], np.ndarray]:
    """Items that belong to an ordered pair of distinct speakers (a mixture's
    target and interferer): weight m_a * m_b."""
    ga, gb = np.asarray(g_a), np.asarray(g_b)
    return lambda m: m[ga] * m[gb]


def difference(stat_a: Callable, stat_b: Callable) -> Callable:
    """Paired a - b under the same weights."""
    return lambda w: np.subtract(np.asarray(stat_a(w), dtype=np.float64), np.asarray(stat_b(w), dtype=np.float64))


def bootstrap(
    stat: Callable[[np.ndarray | None], object],
    weigh: Callable[[np.ndarray], np.ndarray],
    multiplicities: np.ndarray,
) -> Estimate | list[Estimate]:
    """Point estimate (unit weights) and percentile 95 % CI of stat(weigh(m))
    over the resamples m. stat returns a float or a sequence of floats (then a
    list of Estimates). Share `multiplicities` across statistics for paired
    comparisons (or use `difference`). Resamples in which stat is undefined
    (ValueError, e.g. no target trial drawn) are skipped; if more than 1 % are,
    the CI is NaN rather than silently biased."""
    v0 = stat(None)
    scalar = np.ndim(v0) == 0
    value = np.atleast_1d(np.asarray(v0, dtype=np.float64))
    vals = []
    for m in multiplicities:
        try:
            vals.append(np.atleast_1d(np.asarray(stat(weigh(m)), dtype=np.float64)))
        except ValueError:
            pass
    if len(vals) < 0.99 * len(multiplicities):
        lo = hi = np.full(value.shape, np.nan)
    else:
        lo, hi = np.percentile(np.stack(vals), [2.5, 97.5], axis=0)
    out = [Estimate(float(v), float(a), float(b)) for v, a, b in zip(value, lo, hi)]
    return out[0] if scalar else out
