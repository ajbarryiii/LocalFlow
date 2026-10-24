"""Stage-0 glue over the shared transcript metrics (`lfspk.harness.tmetrics`, W0F).

The definitions (correct sets, S/D/I by region, attribution counts, L+, G,
G_u, R, E, the re-aligned threshold search, the bootstrap draws) live in
tmetrics, one implementation shared with the harness's front-end evaluator.
This module keeps only what stage 0 needs around them: per-mixture records
holding each system's tokens, oracle token means, the filtered hypothesis of
the oracle word filter, and the count matrix of a system. W5's earlier
definitions (f6bea72) are frozen as W0F's agreement fixture
(tests/fixtures/W0_tmetrics_evalwords_f6bea72.json).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence

import numpy as np

from lfspk.harness import tmetrics as tm
from lfspk.harness.align import Word, decision_span, tokens_from_words
from lfspk.harness.metrics import involvement_matrix


@dataclass
class MixRecord:
    key: str
    family: str
    speakers: tuple[str, ...]  # bootstrap involvement (stage0.involved_speakers)
    target_ref: list[Word]
    int_refs: list[list[Word]]
    labels: np.ndarray
    hyps: dict[str, list[Word]] = field(default_factory=dict)  # system -> tokens
    evals: dict[str, tm.HypEval] = field(default_factory=dict)
    unreachable: frozenset = frozenset()

    def evaluate(self, system: str) -> tm.HypEval:
        self.evals[system] = tm.evaluate_hyp(self.hyps[system], self.target_ref, self.int_refs, self.labels)
        return self.evals[system]


def tokens(words: Sequence[Sequence]) -> list[Word]:
    return tokens_from_words([tuple(w) for w in words])


def oracle_scores(labels: np.ndarray) -> np.ndarray:
    """Oracle frame scores: 1 on labels 1 and 3 (target active), else 0."""
    return np.isin(labels, (1, 3)).astype(np.float64)


def token_means(hyp: Sequence[Word], scores: np.ndarray) -> np.ndarray:
    """Mean frame score of each token over its 80 ms-widened span (W0's rule)."""
    out = np.empty(len(hyp), dtype=np.float64)
    for i, h in enumerate(hyp):
        f0, f1 = decision_span(h.start, h.end, scores.size)
        out[i] = float(np.mean(scores[f0:f1]))
    return out


def filtered(hyp: Sequence[Word], means: np.ndarray, tau: float) -> list[Word]:
    """Keep iff mean >= tau (+inf removes everything)."""
    return [h for h, v in zip(hyp, means) if v >= tau]


def counts(rec: MixRecord, system: str, base: str = "B") -> np.ndarray:
    """tmetrics count vector of `system` on one mixture, relative to `base`.
    Dropout is not evaluated in stage 0 (no dry-target transcripts): 0."""
    return tm.mix_counts(rec.evals[system], rec.evals[base], rec.unreachable, False, False)


def count_matrix(recs: Sequence[MixRecord], system: str) -> np.ndarray:
    return np.stack([counts(r, system) for r in recs]) if recs else np.zeros((0, len(tm.COLS)))


def filter_steps(rec: MixRecord, means: np.ndarray, base: str = "B"):
    """The mixture's counts as a step function of tau for a word filter on
    `base`'s hypothesis (tmetrics.step_counts, re-aligned at every level)."""
    b = rec.evals[base]

    def count_fn(kept):
        return tm.mix_counts(tm.evaluate_hyp(kept, rec.target_ref, rec.int_refs, rec.labels), b, rec.unreachable,
                             False, False)

    return tm.step_counts(rec.hyps[base], means, count_fn)


def boot_weights(recs: Sequence[MixRecord], n_boot: int = 2000, seed: int = 0) -> np.ndarray:
    """[n_boot, n_mix] joint-speaker resample weights over the integer-sorted
    speaker universe (tmetrics.boot_draws, W0's draw order)."""
    universe = sorted({s for r in recs for s in r.speakers}, key=int)
    inv = involvement_matrix([r.speakers for r in recs], universe)
    return tm.boot_weights(inv, tm.boot_draws(len(universe), n_boot, seed))


__all__ = ["MixRecord", "tokens", "oracle_scores", "token_means", "filtered", "counts", "count_matrix", "filter_steps",
           "boot_weights"]
