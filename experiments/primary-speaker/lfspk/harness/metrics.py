"""Word-rule metrics, tau calibration, joint-speaker bootstrap, frame AUC/EER
(DESIGN.md section 8). Pure functions over arrays; no I/O.

WER after filtering uses the alignment of the full hypothesis held fixed:
removing a token aligned as correct turns it into a deletion (+1 error),
removing a substitution leaves the error count (S -> D), removing an insertion
removes an error. This is an upper bound on the WER of re-aligning the kept
tokens (the fixed alignment is one feasible alignment); the evaluator reports
the exact re-aligned value at the point estimate next to it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Sequence

import numpy as np

from ..api import frame_count

SCENARIOS = ("S0", "S1", "S2", "S3", "S4")
SRC = {"target": 0, "interferer": 1, "other": 2}
OPS = {"C": 0, "S": 1, "I": 2}
REG = {"single": 0, "overlap": 1}
BUDGET = 0.005
# No correctly recognised target word to calibrate on: tau is undefined (NaN);
# the condition is reported as uncalibrated and apply refuses it (eval r2).
TAU_UNCALIBRATED = float("nan")


@dataclass
class Tokens:
    """Scorer-independent token table of a set of mixtures."""

    mix: np.ndarray  # mixture index per token
    f0: np.ndarray
    f1: np.ndarray
    source: np.ndarray  # SRC codes (attribution)
    kind: np.ndarray  # OPS codes of the attribution (C, S, I)
    op: np.ndarray  # OPS codes in the time-constrained alignment against the target
    op_region: np.ndarray  # REG of the op (reference word's region for C/S, token's for I)
    region: np.ndarray  # REG of the token's own span
    ambiguous: np.ndarray  # bool: exact match to the target AND to an interferer (time-compatible)
    start: np.ndarray  # raw Parakeet word span, seconds (f0/f1 are the widened decision frames)
    end: np.ndarray
    n_ref: np.ndarray  # [mixtures, 2] target reference words per region
    dels: np.ndarray  # [mixtures, 2] target deletions per region (full hypothesis)
    scenario: np.ndarray  # index into SCENARIOS per mixture
    ids: list[str]

    @property
    def n_mix(self) -> int:
        return len(self.ids)


def build_tokens(records: Sequence[dict[str, Any]], scenarios: Sequence[str]) -> Tokens:
    mix, f0, f1, src, kind, op, opr, reg, amb, st, en = [], [], [], [], [], [], [], [], [], [], []
    n_ref = np.zeros((len(records), 2), np.int64)
    dels = np.zeros((len(records), 2), np.int64)
    for m, r in enumerate(records):
        for t in r["tokens"]:
            mix.append(m)
            f0.append(t[1])
            f1.append(t[2])
            src.append(SRC[t[4]])
            kind.append(OPS[t[5]])
            op.append(OPS[t[7]])
            opr.append(REG[t[8]])
            reg.append(REG[t[9]])
            amb.append(bool(t[12]) if len(t) > 12 else False)
            st.append(float(t[10]))
            en.append(float(t[11]))
        n_ref[m] = [r["n_ref"]["single"], r["n_ref"]["overlap"]]
        dels[m] = [r["dels"]["single"], r["dels"]["overlap"]]
    a = lambda v, dt=np.int64: np.asarray(v, dtype=dt)
    return Tokens(a(mix), a(f0), a(f1), a(src, np.int8), a(kind, np.int8), a(op, np.int8), a(opr, np.int8), a(reg, np.int8),
                  np.asarray(amb, dtype=bool), np.asarray(st, dtype=np.float64), np.asarray(en, dtype=np.float64), n_ref, dels, a([SCENARIOS.index(s) for s in scenarios], np.int8), [r["id"] for r in records])


def rewiden(tok: Tokens, widen_s: float, n_frames: Sequence[int]) -> Tokens:
    """The same tokens with decision frames recomputed at another widening
    (sensitivity of the oracle ceiling only; the contract uses WORD_WIDEN_S)."""
    from dataclasses import replace

    from .align import decision_span

    f0 = np.empty_like(tok.f0)
    f1 = np.empty_like(tok.f1)
    for i in range(tok.mix.size):
        f0[i], f1[i] = decision_span(tok.start[i], tok.end[i], int(n_frames[tok.mix[i]]), widen_s)
    return replace(tok, f0=f0, f1=f1)


def token_means(tok: Tokens, scores: Sequence[np.ndarray]) -> np.ndarray:
    """Mean frame score over each token's frames [f0, f1)."""
    out = np.empty(tok.mix.size, dtype=np.float64)
    order = np.argsort(tok.mix, kind="stable")
    bounds = np.searchsorted(tok.mix[order], np.arange(tok.n_mix + 1))
    for m in range(tok.n_mix):
        idx = order[bounds[m] : bounds[m + 1]]
        if idx.size == 0:
            continue
        c = np.concatenate([[0.0], np.cumsum(np.asarray(scores[m], dtype=np.float64))])
        out[idx] = (c[tok.f1[idx]] - c[tok.f0[idx]]) / (tok.f1[idx] - tok.f0[idx])
    return out


class Ledger:
    """Per-mixture count matrices so every metric under any tau and any mixture
    weighting is a few weighted sums (fast enough for 2000 bootstrap resamples
    with tau re-calibrated in each)."""

    FAMILIES = ("rem_C", "rem_I", "rem_int", "rem_tgtC", "rem_other", "rem_intamb")

    def __init__(self, tok: Tokens, means: np.ndarray):
        self.tok, self.means, n = tok, means, tok.n_mix
        fam_sel = {
            "rem_C": (tok.op == OPS["C"], tok.op_region),
            "rem_I": (tok.op == OPS["I"], tok.op_region),
            "rem_int": (tok.source == SRC["interferer"], tok.region),
            "rem_tgtC": ((tok.source == SRC["target"]) & (tok.kind == OPS["C"]), tok.region),
            "rem_other": (tok.source == SRC["other"], tok.region),
            # Sensitivity (eval r1 #6): interferer words plus tokens exactly matched
            # by both the target and an interferer.
            "rem_intamb": ((tok.source == SRC["interferer"]) | tok.ambiguous, tok.region),
        }
        self._fam = {}
        self.static: dict[str, np.ndarray] = {"n_ref": tok.n_ref.astype(float), "dels": tok.dels.astype(float)}
        for f, (sel, reg) in fam_sel.items():
            idx = np.flatnonzero(sel)
            col = tok.mix[idx] * 2 + reg[idx]
            self._fam[f] = (idx, col)
            self.static["n_" + f[4:]] = np.bincount(col, minlength=2 * n).reshape(n, 2).astype(float)
        sub = tok.op == OPS["S"]
        self.static["S"] = np.bincount(tok.mix[sub] * 2 + tok.op_region[sub], minlength=2 * n).reshape(n, 2).astype(float)
        amb = tok.ambiguous
        self.static["amb"] = np.bincount(tok.mix[amb] * 2 + tok.region[amb], minlength=2 * n).reshape(n, 2).astype(float)
        cand = np.flatnonzero((tok.source == SRC["target"]) & (tok.kind == OPS["C"]))
        order = np.argsort(means[cand], kind="stable")
        self._cand_scores = means[cand][order]
        self._cand_mix = tok.mix[cand][order]

    def removed(self, tau: float) -> dict[str, np.ndarray]:
        rem = self.means < tau
        n = self.tok.n_mix
        return {f: np.bincount(col, weights=rem[idx].astype(float), minlength=2 * n).reshape(n, 2) for f, (idx, col) in self._fam.items()}

    def calibrate(self, w_mix: np.ndarray, budget: float = BUDGET) -> float:
        """Largest tau whose removal of correctly recognised target words
        (attributed target, exact match) is at most `budget` of the target
        reference words, weighted by w_mix. Ties at tau are kept."""
        allowed = budget * float(w_mix @ self.static["n_ref"].sum(axis=1))
        s = self._cand_scores
        w = w_mix[self._cand_mix]
        keep = w > 0
        s, w = s[keep], w[keep]
        if s.size == 0:
            return TAU_UNCALIBRATED
        if float(np.sum(w)) <= allowed + 1e-9:
            # Every candidate fits in the budget: just above the highest candidate
            # (orchestrator decision after eval r2; never "remove everything").
            return float(np.nextafter(s.max(), np.inf))
        uniq, first = np.unique(s, return_index=True)
        removed_before = np.concatenate([[0.0], np.cumsum(w)])[first]  # weight strictly below each unique score
        ok = np.flatnonzero(removed_before <= allowed + 1e-9)
        return float(uniq[ok[-1]])

    def summarize(self, removed: dict[str, np.ndarray], w_mix: np.ndarray, mask: np.ndarray | None = None) -> dict[str, float]:
        wm = w_mix if mask is None else np.where(mask, w_mix, 0.0)
        st = {k: wm @ v for k, v in self.static.items()}  # each a length-2 vector (single, overlap)
        rm = {k: wm @ v for k, v in removed.items()}
        out: dict[str, float] = {}
        for rname, sl in (("all", slice(0, 2)), ("single", slice(0, 1)), ("overlap", slice(1, 2))):
            g = lambda d, k: float(np.sum(d[k][sl]))
            n = g(st, "n_ref")
            e0 = g(st, "S") + g(st, "dels") + g(st, "n_I")
            out[f"wer_before/{rname}"] = _ratio(e0, n)
            out[f"wer_after/{rname}"] = _ratio(e0 + g(rm, "rem_C") - g(rm, "rem_I"), n)
            out[f"n_ref/{rname}"] = n
            n_int = g(st, "n_int")
            out[f"interferer_kept/{rname}"] = _ratio(n_int - g(rm, "rem_int"), n_int)
            out[f"n_interferer/{rname}"] = n_int
            out[f"target_removed/{rname}"] = _ratio(g(rm, "rem_tgtC"), n)
            n_oth = g(st, "n_other")
            out[f"other_kept/{rname}"] = _ratio(n_oth - g(rm, "rem_other"), n_oth)
            n_ia = g(st, "n_intamb")
            out[f"interferer_kept_incl_ambiguous/{rname}"] = _ratio(n_ia - g(rm, "rem_intamb"), n_ia)
            out[f"n_ambiguous/{rname}"] = g(st, "amb")  # every flagged token, whichever source won (eval r2 #5)
            # Target coverage before filtering: correctly recognised target words / reference words.
            out[f"target_coverage/{rname}"] = _ratio(g(st, "n_tgtC"), n)
        out["wer_increase"] = out["wer_after/all"] - out["wer_before/all"]
        return out


def calibrate(means: np.ndarray, tok: Tokens, w_mix: np.ndarray, budget: float = BUDGET) -> float:
    return Ledger(tok, means).calibrate(np.asarray(w_mix, dtype=float), budget)


def _ratio(num: float, den: float) -> float:
    return float(num / den) if den > 0 else float("nan")


def summarize(tok: Tokens, means: np.ndarray, tau: float, w_mix: np.ndarray, scen_mask: np.ndarray | None = None) -> dict[str, float]:
    """Every word-level metric for the mixtures selected by `scen_mask` (bool per
    mixture, default all), weighted by w_mix."""
    led = Ledger(tok, means)
    return led.summarize(led.removed(tau), np.asarray(w_mix, dtype=float), scen_mask)


# --- frame-level ---------------------------------------------------------------------


class FrameRanks:
    """Exact weighted rank statistics of target-present frames (labels 1, 3)
    against interferer-only frames (2), pooled over mixtures. Scores are sorted
    and tie-grouped once; a bootstrap resample only reweights frames by their
    mixture's weight, so every statistic is exact, with no binning (eval r1 #1:
    histograms collapsed saturated scores). Ported from W3's
    lfspk/pvad/metrics.FrameRanks (reviewed there), plus an interpolated EER."""

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
        _, self.group = np.unique(allsc, return_inverse=True)
        self.n_groups = int(self.group.max()) + 1 if self.group.size else 0

    def _group_weights(self, w_items: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        w = np.asarray(w_items, dtype=np.float64)[self.item]
        wp = np.bincount(self.group[self.pos], weights=w[self.pos], minlength=self.n_groups)
        wn = np.bincount(self.group[~self.pos], weights=w[~self.pos], minlength=self.n_groups)
        return wp, wn

    def auc_eer(self, w_items: np.ndarray | None = None) -> tuple[float, float]:
        """AUC = P(pos > neg) + 0.5 P(tie), weighted; EER where the piecewise-linear
        ROC (thresholds between tie groups) crosses FRR = FAR, interpolated."""
        w_items = np.ones(self.n_items) if w_items is None else w_items
        wp, wn = self._group_weights(w_items)
        tp, tn = wp.sum(), wn.sum()
        if tp <= 0 or tn <= 0:
            return float("nan"), float("nan")
        below = np.cumsum(wn) - wn
        auc = float((wp * (below + 0.5 * wn)).sum() / (tp * tn))
        # Threshold k accepts groups >= k: FRR_k = pos below / P, FAR_k = neg at or above / N.
        frr = np.concatenate([[0.0], np.cumsum(wp)]) / tp
        far = 1.0 - np.concatenate([[0.0], np.cumsum(wn)]) / tn
        d = frr - far  # non-decreasing from -1 to 1
        k = int(np.searchsorted(d, 0.0, side="left"))
        if d[k] == 0.0 or k == 0:
            return auc, float(frr[k])
        t = -d[k - 1] / (d[k] - d[k - 1])
        return auc, float(frr[k - 1] + t * (frr[k] - frr[k - 1]))


def exact_auc_eer(scores: np.ndarray, labels: np.ndarray) -> tuple[float, float]:
    return FrameRanks([scores], [labels]).auc_eer()


# --- bootstrap -----------------------------------------------------------------------------


def speaker_weights(involved: Sequence[Sequence[str]], speakers: Sequence[str], rng: np.random.Generator) -> np.ndarray:
    """One joint resample: draw len(speakers) speakers with replacement; each
    mixture's weight is the product of the draw counts of the distinct speakers
    it involves (0 if any is not drawn)."""
    idx = {s: i for i, s in enumerate(speakers)}
    counts = np.bincount(rng.integers(0, len(speakers), len(speakers)), minlength=len(speakers)).astype(np.float64)
    w = np.ones(len(involved))
    for m, spk in enumerate(involved):
        for s in set(spk):
            w[m] *= counts[idx[s]]
    return w


def involvement_matrix(involved: Sequence[Sequence[str]], speakers: Sequence[str]) -> np.ndarray:
    """[mixtures, max roles] speaker indices, -1 padded (distinct speakers per mixture)."""
    idx = {s: i for i, s in enumerate(speakers)}
    rows = [sorted({idx[s] for s in spk}) for spk in involved]
    width = max((len(r) for r in rows), default=0)
    out = np.full((len(rows), max(1, width)), -1, dtype=np.int64)
    for m, r in enumerate(rows):
        out[m, : len(r)] = r
    return out


def weights_from_counts(inv: np.ndarray, counts: np.ndarray) -> np.ndarray:
    """Product of the draw counts of each mixture's speakers (padding counts 1)."""
    c = np.append(np.asarray(counts, dtype=np.float64), 1.0)
    return np.prod(c[inv], axis=1)


def percentile_ci(values: np.ndarray, level: float = 0.95) -> tuple[float, float]:
    v = np.asarray(values, dtype=np.float64)
    v = v[np.isfinite(v)]
    if v.size == 0:
        return float("nan"), float("nan")
    a = (1 - level) / 2
    return float(np.quantile(v, a)), float(np.quantile(v, 1 - a))


def n_valid(values: np.ndarray) -> int:
    """Resamples in which a statistic was defined (sparse strata lose some)."""
    return int(np.isfinite(np.asarray(values, dtype=np.float64)).sum())


def frames_of(audio_samples: int) -> int:
    return frame_count(audio_samples)
