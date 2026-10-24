"""Frame-level metrics and the speaker bootstrap (DESIGN.md section 7).

Frame metrics are a training monitor and a diagnostic; the decision metrics
come from W0's word-level harness.
"""

from __future__ import annotations

from typing import Callable, Mapping, Sequence

import numpy as np
from scipy.stats import rankdata


def roc_auc(pos: np.ndarray, neg: np.ndarray) -> float:
    """P(score(pos) > score(neg)) + 0.5 P(tie), by ranks. NaN if either side is empty."""
    pos = np.asarray(pos, dtype=np.float64).ravel()
    neg = np.asarray(neg, dtype=np.float64).ravel()
    if pos.size == 0 or neg.size == 0:
        return float("nan")
    ranks = rankdata(np.concatenate([pos, neg]))  # average ranks for ties
    rp = ranks[: pos.size].sum()
    return float((rp - pos.size * (pos.size + 1) / 2) / (pos.size * neg.size))


def eer(pos: np.ndarray, neg: np.ndarray) -> float:
    """Empirical equal error rate: miss(thr) = P(pos < thr), fa(thr) = P(neg >= thr)
    over every distinct threshold, linearly interpolated between the two adjacent
    operating points that bracket miss = fa."""
    pos = np.sort(np.asarray(pos, dtype=np.float64).ravel())
    neg = np.sort(np.asarray(neg, dtype=np.float64).ravel())
    if pos.size == 0 or neg.size == 0:
        return float("nan")
    thr = np.unique(np.concatenate([pos, neg, [np.inf]]))
    miss = np.searchsorted(pos, thr, side="left") / pos.size
    fa = 1.0 - np.searchsorted(neg, thr, side="left") / neg.size
    d = miss - fa  # non-decreasing, starts <= 0 (lowest threshold) and ends at 1
    i = int(np.argmax(d >= 0))
    if d[i] == 0 or i == 0:
        return float((miss[i] + fa[i]) / 2)
    t = -d[i - 1] / (d[i] - d[i - 1])
    return float(miss[i - 1] + t * (miss[i] - miss[i - 1]))


def pass_rate_at_miss(pos: np.ndarray, neg: np.ndarray, miss: float = 0.02) -> float:
    """Fraction of neg at or above the threshold that rejects (at most) `miss` of pos."""
    pos = np.sort(np.asarray(pos, dtype=np.float64).ravel())
    neg = np.asarray(neg, dtype=np.float64).ravel()
    if pos.size == 0 or neg.size == 0:
        return float("nan")
    k = int(np.floor(miss * pos.size))  # number of pos frames we may reject
    thr = pos[k]  # rejecting pos < thr rejects at most k
    return float((neg >= thr).mean())


def average_precision(scores: np.ndarray, positive: np.ndarray) -> float:
    """sklearn-style AP: sum_n (R_n - R_{n-1}) P_n over distinct thresholds."""
    s = np.asarray(scores, dtype=np.float64).ravel()
    y = np.asarray(positive, dtype=bool).ravel()
    if y.sum() == 0:
        return float("nan")
    order = np.argsort(-s, kind="mergesort")
    s, y = s[order], y[order]
    tp = np.cumsum(y)
    fp = np.cumsum(~y)
    last = np.r_[np.flatnonzero(np.diff(s)), s.size - 1]
    prec = tp[last] / (tp[last] + fp[last])
    rec = tp[last] / y.sum()
    rec_prev = np.r_[0.0, rec[:-1]]
    return float(np.sum((rec - rec_prev) * prec))


def frame_metrics(score: np.ndarray, labels: np.ndarray, posteriors: np.ndarray | None = None) -> dict:
    """score: the target log-odds per frame (`logit_from_logits`), the one score
    representation used for every target statistic, point or bootstrap, so that
    float32 probabilities cannot saturate into ties. labels: contract labels
    (0..3). Target-present = 1 or 3; interferer-only = 2; non-speech = 0.
    posteriors [T, 3] (optional) only feed the ns and ntss APs."""
    p = np.asarray(score, dtype=np.float64)
    lab = np.asarray(labels)
    tgt = p[(lab == 1) | (lab == 3)]
    intf = p[lab == 2]
    nonsp = p[lab == 0]
    out = {
        "auc_tgt_vs_intf": roc_auc(tgt, intf),
        "eer_tgt_vs_intf": eer(tgt, intf),
        "auc_tgt_vs_rest": roc_auc(tgt, np.concatenate([intf, nonsp])),
        "intf_pass_at_2pct_miss": pass_rate_at_miss(tgt, intf, 0.02),
        "ap_tss": average_precision(p, (lab == 1) | (lab == 3)),
        "auc_overlap_vs_intf": roc_auc(p[lab == 3], intf),
        "n_tgt": int(tgt.size), "n_intf": int(intf.size), "n_ns": int(nonsp.size),
    }
    if posteriors is not None:
        post = np.asarray(posteriors, dtype=np.float64)  # [T, 3] ns, tss, ntss
        out["ap_ns"] = average_precision(post[:, 0], lab == 0)
        out["ap_ntss"] = average_precision(post[:, 2], lab == 2)
    return out


def logit_from_logits(logits: np.ndarray, target: int = 1) -> np.ndarray:
    """Target log-odds z_t - logsumexp(other z) from 3-class logits [T, 3], float64,
    unclipped."""
    z = np.asarray(logits, dtype=np.float64)
    others = np.delete(z, target, axis=1)
    m = others.max(axis=1, keepdims=True)
    lse = (m + np.log(np.exp(others - m).sum(axis=1, keepdims=True)))[:, 0]
    return z[:, target] - lse


def speaker_counts(speakers: Sequence[str], rng: np.random.Generator) -> dict[str, int]:
    pick = rng.integers(0, len(speakers), size=len(speakers))
    counts = np.bincount(pick, minlength=len(speakers))
    return {s: int(c) for s, c in zip(speakers, counts)}


def joint_weights(item_speakers: Sequence[Sequence[str]], counts: Mapping[str, int]) -> np.ndarray:
    """Weight of each item under one joint speaker resample: the product of the
    draw counts of every distinct speaker it involves (0 if any is not drawn)."""
    w = np.ones(len(item_speakers), np.float64)
    for i, spk in enumerate(item_speakers):
        for s in set(spk):
            w[i] *= counts.get(s, 0)
    return w


def joint_bootstrap(item_speakers: Sequence[Sequence[str]], statistic: Callable[[np.ndarray], float],
                    n_boot: int = 1000, seed: int = 0, alpha: float = 0.05) -> dict:
    """Percentile CI of statistic(weights) when speakers are resampled jointly
    across roles (CONTRACT.md): each resample draws one speaker multiset from
    every speaker appearing in any item, and an item counts with the product of
    its speakers' draw counts. `statistic` gets one weight per item. A paired
    comparison is a statistic that returns the difference of two systems."""
    spk = sorted({s for it in item_speakers for s in it})
    if not spk:
        raise ValueError("no speakers")
    rng = np.random.default_rng(seed)
    point = statistic(np.ones(len(item_speakers)))
    vals = []
    for _ in range(n_boot):
        w = joint_weights(item_speakers, speaker_counts(spk, rng))
        vals.append(statistic(w) if w.sum() > 0 else np.nan)
    vals = np.asarray(vals, dtype=np.float64)
    fin = vals[np.isfinite(vals)]
    lo, hi = np.quantile(fin, [alpha / 2, 1 - alpha / 2]) if fin.size else (np.nan, np.nan)
    return {"point": float(point), "lo": float(lo), "hi": float(hi), "n_speakers": len(spk),
            "n_boot": int(n_boot), "n_finite": int(fin.size), "seed": seed}


class FrameRanks:
    """Exact weighted rank statistics of target-present (labels 1, 3) against
    interferer-only (2) frames, pooled over items (mixtures), for the joint
    speaker bootstrap. Scores are sorted and tie-grouped once; each resample
    only reweights frames by their item's weight, so per-resample statistics
    are exact, with no binning."""

    def __init__(self, scores: Sequence[np.ndarray], labels: Sequence[np.ndarray]):
        sc, it, pos = [], [], []
        for i, (s_, l_) in enumerate(zip(scores, labels)):
            s_ = np.asarray(s_, dtype=np.float64)
            l_ = np.asarray(l_)
            if s_.shape != l_.shape:
                raise ValueError("scores and labels differ in length")
            sel = (l_ == 1) | (l_ == 2) | (l_ == 3)
            sc.append(s_[sel])
            pos.append(l_[sel] != 2)
            it.append(np.full(int(sel.sum()), i, np.int64))
        self.n_items = len(scores)
        allsc = np.concatenate(sc) if sc else np.zeros(0)
        if not np.isfinite(allsc).all():
            raise ValueError("scores must be finite")
        self.item = np.concatenate(it) if it else np.zeros(0, np.int64)
        self.pos = np.concatenate(pos) if pos else np.zeros(0, bool)
        uniq, self.group = np.unique(allsc, return_inverse=True)
        self.n_groups = uniq.size

    def _group_weights(self, w_items: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        w = np.asarray(w_items, dtype=np.float64)[self.item]
        wp = np.bincount(self.group[self.pos], weights=w[self.pos], minlength=self.n_groups)
        wn = np.bincount(self.group[~self.pos], weights=w[~self.pos], minlength=self.n_groups)
        return wp, wn

    def auc(self, w_items: np.ndarray) -> float:
        """P(pos > neg) + 0.5 P(tie), weighted; equals roc_auc with all weights 1."""
        wp, wn = self._group_weights(w_items)
        tp, tn = wp.sum(), wn.sum()
        if tp <= 0 or tn <= 0:
            return float("nan")
        below = np.cumsum(wn) - wn
        return float((wp * (below + 0.5 * wn)).sum() / (tp * tn))

    def pass_at_miss(self, w_items: np.ndarray, miss: float = 0.02) -> float:
        """Weighted pass_rate_at_miss: the threshold is the lowest score whose
        cumulative pos weight exceeds miss * total; neg at or above it pass."""
        wp, wn = self._group_weights(w_items)
        tp, tn = wp.sum(), wn.sum()
        if tp <= 0 or tn <= 0:
            return float("nan")
        g = int(np.searchsorted(np.cumsum(wp), miss * tp, side="right"))
        return float(wn[g:].sum() / tn)


def frame_bootstrap(ranks: FrameRanks, item_speakers: Sequence[Sequence[str]], kind: str,
                    other: FrameRanks | None = None, n_boot: int = 1000, seed: int = 0) -> dict:
    """Joint speaker bootstrap of an exact frame statistic ("auc_tgt_vs_intf" or
    "intf_pass_at_2pct_miss"); with `other`, of the paired difference
    stat(ranks) - stat(other) on the same items."""
    if len(item_speakers) != ranks.n_items or (other is not None and other.n_items != ranks.n_items):
        raise ValueError("one speaker tuple per item, same items in both systems")

    def one(r: FrameRanks, w: np.ndarray) -> float:
        if kind == "auc_tgt_vs_intf":
            return r.auc(w)
        if kind == "intf_pass_at_2pct_miss":
            return r.pass_at_miss(w, 0.02)
        raise ValueError(kind)

    stat = (lambda w: one(ranks, w)) if other is None else (lambda w: one(ranks, w) - one(other, w))
    return joint_bootstrap(item_speakers, stat, n_boot=n_boot, seed=seed)
