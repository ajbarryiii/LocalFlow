"""Cosine scoring and cohort score normalisation (s-norm and adaptive s-norm).

All embeddings are L2-normalised rows. Cohort embeddings come from the train
split only. For AS-norm, each side's statistics use its `top_k` highest
cohort scores (Matejka et al. 2017; Cumani et al. 2011)."""

from __future__ import annotations

import numpy as np

SD_FLOOR = 1e-4


def cohort_stats(emb: np.ndarray, cohort: np.ndarray, top_k: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Mean and standard deviation of each row's cohort scores (all of them,
    or the `top_k` largest). Returns two arrays of shape (n,)."""
    emb = np.atleast_2d(emb)
    s = emb @ cohort.T
    if top_k is not None:
        if not 1 <= top_k <= cohort.shape[0]:
            raise ValueError(f"top_k {top_k} outside [1, {cohort.shape[0]}]")
        s = np.partition(s, s.shape[1] - top_k, axis=1)[:, s.shape[1] - top_k:]
    return s.mean(axis=1), np.maximum(s.std(axis=1), SD_FLOOR)


def snorm(raw: np.ndarray, mu_e, sd_e, mu_t, sd_t) -> np.ndarray:
    """Symmetric normalisation of raw scores given enrollment-side and
    test-side cohort statistics (broadcastable)."""
    return 0.5 * ((raw - mu_e) / sd_e + (raw - mu_t) / sd_t)


def score_matrix(profiles: np.ndarray, tests: np.ndarray, *, cohort_profile: np.ndarray | None = None,
                 cohort_test: np.ndarray | None = None, top_k: int | None = None) -> np.ndarray:
    """(n_profiles, n_tests) scores: raw cosine when no cohort is given,
    otherwise (A)S-norm with the profile side normalised against
    `cohort_profile` and the test side against `cohort_test` (length-matched
    cohorts may differ between the two sides)."""
    raw = profiles @ tests.T
    if cohort_profile is None and cohort_test is None:
        return raw
    if cohort_profile is None or cohort_test is None:
        raise ValueError("give both cohorts or neither")
    mu_e, sd_e = cohort_stats(profiles, cohort_profile, top_k)
    mu_t, sd_t = cohort_stats(tests, cohort_test, top_k)
    return snorm(raw, mu_e[:, None], sd_e[:, None], mu_t[None, :], sd_t[None, :])
