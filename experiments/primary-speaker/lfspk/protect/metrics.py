"""Verification and identification metrics with bootstrap CIs over speakers."""

from __future__ import annotations

from typing import Callable, Sequence

import numpy as np


def _error_curves(scores: np.ndarray, labels: np.ndarray,
                  weights: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """FNR and FPR for every realisable threshold (accept iff score >= t): each
    distinct score, plus +inf (reject everything). Optional non-negative trial
    weights (bootstrap multiplicities)."""
    scores = np.asarray(scores, dtype=np.float64)
    labels = np.asarray(labels).astype(bool)
    w = np.ones(scores.size) if weights is None else np.asarray(weights, dtype=np.float64)
    order = np.argsort(scores, kind="mergesort")
    s, lab, w = scores[order], labels[order], w[order]
    wt, wn = w * lab, w * ~lab
    tot_t, tot_n = wt.sum(), wn.sum()
    if tot_t <= 0 or tot_n <= 0:
        raise ValueError("need both target and non-target trials")
    # Group equal scores: a threshold can only fall between distinct values.
    last = np.r_[s[1:] != s[:-1], True]
    ct, cn = np.cumsum(wt)[last], np.cumsum(wn)[last]
    cand = np.concatenate([s[last], [np.inf]])
    below_t = np.concatenate([[0.0], ct])  # target weight strictly below cand[i]
    below_n = np.concatenate([[0.0], cn])
    return cand, below_t / tot_t, 1.0 - below_n / tot_n


def eer(scores: np.ndarray, labels: np.ndarray, weights: np.ndarray | None = None) -> tuple[float, float]:
    """Equal error rate and its threshold. labels: 1 target, 0 non-target.
    Accept iff score >= threshold; the EER is the mean of FNR and FPR at the
    realisable threshold where they are closest."""
    cand, fnr, fpr = _error_curves(scores, labels, weights)
    i = int(np.argmin(np.abs(fnr - fpr)))
    return float((fnr[i] + fpr[i]) / 2), float(cand[i])


def min_dcf(scores: np.ndarray, labels: np.ndarray, p_target: float = 0.01,
            c_miss: float = 1.0, c_fa: float = 1.0, weights: np.ndarray | None = None) -> float:
    """Normalised minimum detection cost (NIST SRE convention)."""
    _, fnr, fpr = _error_curves(scores, labels, weights)
    dcf = c_miss * p_target * fnr + c_fa * (1 - p_target) * fpr
    return float(dcf.min() / min(c_miss * p_target, c_fa * (1 - p_target)))


def joint_multiplicity_weights(owner: np.ndarray, other: np.ndarray, counts: np.ndarray) -> np.ndarray:
    """Bootstrap weight of each trial when speakers are resampled jointly across
    roles: a trial survives only if all its speakers are drawn, and counts once
    per combination of draws (m_i for a single-speaker trial, m_i * m_j for a
    trial between two speakers)."""
    w = counts[owner].astype(np.float64)
    two = owner != other
    w[two] *= counts[other[two]]
    return w


def joint_bootstrap(owner: np.ndarray, other: np.ndarray, n_speakers: int,
                    stat, n_boot: int = 1000, seed: int = 0, alpha: float = 0.05) -> tuple[float, float, float]:
    """Point estimate and percentile CI of stat(weights) under joint speaker
    resampling. owner/other: speaker indices (0..n_speakers-1) of each trial's
    two roles (equal for a target trial). stat takes a weight per trial."""
    point = stat(np.ones(owner.size))
    rng = np.random.default_rng(seed)
    vals = []
    for _ in range(n_boot):
        counts = np.bincount(rng.integers(0, n_speakers, n_speakers), minlength=n_speakers)
        w = joint_multiplicity_weights(owner, other, counts)
        try:
            vals.append(stat(w))
        except ValueError:  # a resample without targets or non-targets
            continue
    lo, hi = np.quantile(vals, [alpha / 2, 1 - alpha / 2])
    return float(point), float(lo), float(hi)


def rate_at_threshold(scores: np.ndarray, threshold: float) -> float:
    return float(np.mean(np.asarray(scores) >= threshold))


def threshold_at_far(nontarget_scores: np.ndarray, far: float, weights: np.ndarray | None = None) -> float:
    """The smallest threshold (accept iff score >= t) whose weighted false-accept
    rate on these scores is <= far.

    Thresholds sit just above a distinct score; placing t at nextafter(v_i)
    accepts exactly the non-targets with score > v_i. We take the smallest such
    t that meets the budget, so no feasible clone is rejected unnecessarily."""
    s = np.asarray(nontarget_scores, dtype=np.float64)
    w = np.ones(s.size) if weights is None else np.asarray(weights, dtype=np.float64)
    order = np.argsort(s, kind="stable")
    s, w = s[order], w[order]
    total = w.sum()
    if total <= 0:
        raise ValueError("no non-target weight")
    last = np.r_[s[1:] != s[:-1], True]
    vals = s[last]
    strict_above = total - np.cumsum(w)[last]  # non-target weight with score > vals[i]
    ok = np.flatnonzero(strict_above <= far * total + 1e-12)
    i = ok[0] if ok.size else len(vals) - 1
    return float(np.nextafter(vals[i], np.inf))


def clopper_pearson_upper(successes: int, n: int, alpha: float = 0.05) -> float:
    """One-sided (1 - alpha) upper bound on a binomial proportion (exact).
    successes/n speakers with any successful clone -> upper bound on the
    vulnerable fraction. 0/73 gives about 0.040, so the best resolvable tier
    on 73 dev speakers is 'low', not 'negligible'."""
    from scipy.stats import beta

    if not 0 <= successes <= n or n <= 0:
        raise ValueError("need 0 <= successes <= n, n > 0")
    if successes == n:
        return 1.0
    return float(beta.ppf(1 - alpha, successes + 1, n - successes))


def _wsr_lower(x: np.ndarray, alpha: float, grid: int, c: float, bisect: int = 40) -> float:
    """One-sided lower (1 - alpha) confidence bound on the mean of i.i.d. x in
    [0, 1]: the hedged-capital betting bound of Waudby-Smith & Ramdas (2023),
    "Estimating means of bounded random variables by betting", JRSS-B 86(1),
    section 4 (predictable plug-in bets, Ville's inequality on the running
    maximum of capital), one-sided version.

    For a candidate mean m the capital is K_t(m) = prod_{i<=t} (1 + l_i (x_i - m))
    with bets l_i = min(sqrt(2 log(1/alpha) / (s2_i i log(1 + i))), c / m),
    where s2_i is the predictable variance estimate (1/4 + sum_{j<i}
    (x_j - mu_j)^2) / i and mu_i = (1/2 + sum_{j<i} x_j) / i. m is rejected
    if max_t K_t(m) >= 1/alpha.

    Inversion rounds OUTWARD (review invert-r5 #3; WSR section 4.4 asks for a
    superset of the confidence set): the first non-rejected grid point is
    found, the bracket (last rejected, first non-rejected) is narrowed by
    bisection, and the bracket's lower (rejected) end is returned, so the
    returned bound never exceeds the exact infimum of the non-rejected set
    within the bracket. Observations are used in the given (pre-registered)
    order."""
    x = np.clip(np.asarray(x, dtype=np.float64), 0.0, 1.0)
    n = x.size
    if n == 0:
        return 0.0
    t = np.arange(1, n + 1, dtype=np.float64)
    prev_sum = np.concatenate([[0.0], np.cumsum(x)[:-1]])
    mu = (0.5 + prev_sum) / t
    prev_sq = np.concatenate([[0.0], np.cumsum((x - mu) ** 2)[:-1]])
    s2 = (0.25 + prev_sq) / t
    lam = np.sqrt(2.0 * np.log(1.0 / alpha) / (s2 * t * np.log1p(t)))
    log_thr = np.log(1.0 / alpha)

    def rejected(m: float) -> bool:
        if m <= 0.0:
            return bool(np.any(x > 0))  # any positive observation rules out mean 0
        lam_m = np.minimum(lam, c / m)
        return bool(np.cumsum(np.log1p(lam_m * (x - m))).max() >= log_thr)

    ms = np.linspace(0.0, 1.0, grid + 1)
    for k, m in enumerate(ms):
        if not rejected(m):
            if k == 0:
                return 0.0
            lo, hi = float(ms[k - 1]), float(m)  # lo rejected, hi not
            for _ in range(bisect):
                mid = (lo + hi) / 2
                if rejected(mid):
                    lo = mid
                else:
                    hi = mid
            return lo
    return float(ms[-1])  # every grid point rejected (x all at 1): bound 1 is exact


def wsr_lower_mean(x: np.ndarray, alpha: float = 0.025, grid: int = 2000, c: float = 0.75) -> float:
    """Lower (1 - alpha) bound on the mean of x in [0, 1] (Waudby-Smith & Ramdas 2023)."""
    return _wsr_lower(x, alpha, grid, c)


def wsr_upper_mean(x: np.ndarray, alpha: float = 0.025, grid: int = 2000, c: float = 0.75) -> float:
    """Upper (1 - alpha) bound on the mean of x in [0, 1], by symmetry (1 - x)."""
    return 1.0 - _wsr_lower(1.0 - np.asarray(x, dtype=np.float64), alpha, grid, c)


def delta_upper(a: np.ndarray, f: np.ndarray, alpha: float = 0.05, **kw) -> float:
    """Distribution-free upper (1 - alpha) bound on mean(a) - mean(f) for
    per-target rates in [0, 1]: U_{alpha/2}(a) - L_{alpha/2}(f) (Bonferroni)."""
    return wsr_upper_mean(a, alpha / 2, **kw) - wsr_lower_mean(f, alpha / 2, **kw)


def target_order(speakers, seed: int) -> np.ndarray:
    """Pre-registered, outcome-independent order of targets for the sequential
    betting bounds: a seeded permutation of the targets sorted by integer id
    (review invert-r5: identifier order can align with strata)."""
    base = np.argsort(np.asarray(speakers).astype(int), kind="stable")
    return base[np.random.default_rng(seed).permutation(base.size)]


def delta_lower(a: np.ndarray, f: np.ndarray, alpha: float = 0.05, **kw) -> float:
    """Distribution-free lower (1 - alpha) bound on mean(a) - mean(f):
    L_{alpha/2}(a) - U_{alpha/2}(f) (Bonferroni)."""
    return wsr_lower_mean(a, alpha / 2, **kw) - wsr_upper_mean(f, alpha / 2, **kw)


def id_rank(queries: np.ndarray, gallery: np.ndarray, true_index: Sequence[int]) -> np.ndarray:
    """1-based rank of the true gallery entry for each query by cosine (ties
    count against the query: rank = 1 + number of entries scoring >= the true
    one, excluding itself)."""
    q = queries / np.linalg.norm(queries, axis=1, keepdims=True)
    g = gallery / np.linalg.norm(gallery, axis=1, keepdims=True)
    sim = q @ g.T
    idx = np.asarray(true_index)
    true = sim[np.arange(len(q)), idx]
    better = (sim >= true[:, None]).sum(axis=1) - 1
    return 1 + better


def bootstrap_ci(per_speaker: dict[str, np.ndarray], stat: Callable[[np.ndarray], float],
                 n_boot: int = 1000, seed: int = 0, alpha: float = 0.05) -> tuple[float, float, float]:
    """Point estimate and percentile CI, resampling speakers with replacement.

    per_speaker maps a speaker to the row indices (into whatever arrays `stat`
    closes over) that belong to that speaker; a resampled speaker brings all
    its rows. `stat` gets the concatenated row indices."""
    keys = sorted(per_speaker)
    rows = [np.asarray(per_speaker[k]) for k in keys]
    point = stat(np.concatenate(rows))
    rng = np.random.default_rng(seed)
    vals = np.empty(n_boot)
    for b in range(n_boot):
        pick = rng.integers(0, len(keys), len(keys))
        vals[b] = stat(np.concatenate([rows[i] for i in pick]))
    lo, hi = np.quantile(vals, [alpha / 2, 1 - alpha / 2])
    return float(point), float(lo), float(hi)


def paired_bootstrap_diff(a: dict[str, float], b: dict[str, float], n_boot: int = 1000,
                          seed: int = 0, alpha: float = 0.05) -> tuple[float, float, float]:
    """Mean over speakers of a[s] - b[s] with a speaker-bootstrap CI."""
    keys = sorted(set(a) & set(b))
    d = np.array([a[k] - b[k] for k in keys])
    rng = np.random.default_rng(seed)
    boots = d[rng.integers(0, len(d), (n_boot, len(d)))].mean(axis=1)
    lo, hi = np.quantile(boots, [alpha / 2, 1 - alpha / 2])
    return float(d.mean()), float(lo), float(hi)
