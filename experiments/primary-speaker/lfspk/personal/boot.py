"""The joint speaker bootstrap of DESIGN 6.1 and the frozen coverage smoke test.

Universe: the 48 held-out speakers in sorted id order, drawn with W0's
`tmetrics.boot_draws` (B = 2000, seed 0). A render of subject A's set involves
{A, B(A), its audible interferers} (plus the absent talker); its weight in a
resample is the product of its involvement's draw counts
(`tmetrics.boot_weights`). One weight matrix serves every quantity, so both
sides of every paired contrast share each resample. A resample in which a
group's identity under-suppression sum is 0 makes frac undefined: it is
dropped, counted, and if more than 1 % (20 of 2000) are undefined the CI is
"unresolved" (a gate needing it fails).

The coverage smoke test (DESIGN 6.1 (ii), r2 M3) uses the generator and seed
frozen below: 22 subjects in the pilot's cyclic same-sex pairing, nonzero
subject, donor-model and interferer effects, unequal per-subject oracle
denominators, 200 replications. Tolerance: coverage >= 0.90 of the nominal
95 % interval of the pooled ratio gain; reported with its Monte Carlo SE.
"""

from __future__ import annotations

import numpy as np

N_BOOT = 2000
BOOT_SEED = 0
LEVEL = 0.95
MAX_UNDEFINED = 20  # of 2000


def involvement_matrix(involved: list[list[str]], universe: list[str]) -> np.ndarray:
    """[n_renders, max_k] indices into the universe, padded with len(universe) (count 1)."""
    pos = {s: i for i, s in enumerate(universe)}
    k = max(len(x) for x in involved)
    inv = np.full((len(involved), k), len(universe), dtype=np.int64)
    for r, spk in enumerate(involved):
        if len(set(spk)) != len(spk):
            raise ValueError("duplicate speaker in an involvement set")
        for j, s in enumerate(spk):
            inv[r, j] = pos[s]
    return inv


def weights(inv: np.ndarray, n_universe: int, n_boot: int = N_BOOT, seed: int = BOOT_SEED) -> np.ndarray:
    from lfspk.harness.tmetrics import boot_draws, boot_weights

    return boot_weights(inv, boot_draws(n_universe, n_boot, seed))


def frac(w: np.ndarray, id_under: np.ndarray, under: np.ndarray) -> np.ndarray:
    """1 - sum(w under) / sum(w id_under) along the last axis; NaN where the denominator is 0."""
    den = np.sum(w * id_under, axis=-1)
    num = np.sum(w * under, axis=-1)
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(den > 0, 1.0 - num / np.where(den > 0, den, 1.0), np.nan)


def wmean(w: np.ndarray, x: np.ndarray) -> np.ndarray:
    den = np.sum(w, axis=-1)
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(den > 0, np.sum(w * x, axis=-1) / np.where(den > 0, den, 1.0), np.nan)


def ci(resampled: np.ndarray, level: float = LEVEL) -> dict:
    v = np.asarray(resampled, dtype=np.float64)
    undefined = int(np.sum(~np.isfinite(v)))
    from lfspk.harness.tmetrics import ci as pct

    lo, hi = pct(v, level)
    return {"lo": lo, "hi": hi, "undefined": undefined, "resolved": undefined <= MAX_UNDEFINED and np.isfinite(lo)}


def contrast(W: np.ndarray, mask: np.ndarray, id_under: np.ndarray, under_a: np.ndarray, under_b: np.ndarray) -> dict:
    """frac(a) - frac(b) on the masked renders: point estimate and shared-resample CI."""
    m = np.asarray(mask, bool)
    one = np.ones(int(m.sum()))
    pa, pb = frac(one, id_under[m], under_a[m]), frac(one, id_under[m], under_b[m])
    ra, rb = frac(W[:, m], id_under[m], under_a[m]), frac(W[:, m], id_under[m], under_b[m])
    d = ra - rb
    fin = d[np.isfinite(d)]
    return {"point": float(pa - pb), "a": float(pa), "b": float(pb), "ci": ci(d),
            "se": float(np.std(fin, ddof=1)) if fin.size > 1 else float("nan")}


def mean_contrast(W: np.ndarray, mask: np.ndarray, xa: np.ndarray, xb: np.ndarray) -> dict:
    """mean(a) - mean(b) over the masked renders (e.g. under- or over-suppression), shared-resample CI."""
    m = np.asarray(mask, bool)
    d = wmean(W[:, m], xa[m]) - wmean(W[:, m], xb[m])
    return {"point": float(xa[m].mean() - xb[m].mean()), "a": float(xa[m].mean()), "b": float(xb[m].mean()), "ci": ci(d)}


def mean_ci(W: np.ndarray, mask: np.ndarray, x: np.ndarray) -> dict:
    m = np.asarray(mask, bool)
    return {"point": float(x[m].mean()), "ci": ci(wmean(W[:, m], x[m]))}


def frac_ci(W: np.ndarray, mask: np.ndarray, id_under: np.ndarray, under: np.ndarray) -> dict:
    m = np.asarray(mask, bool)
    return {"point": float(frac(np.ones(int(m.sum())), id_under[m], under[m])),
            "ci": ci(frac(W[:, m], id_under[m], under[m]))}


# --- the frozen coverage smoke test (generator and seed fixed at the stage-3 review) ------------

COVERAGE_SEED = 20261024
COVERAGE_REPS = 200
COVERAGE_TOL = 0.90
COV = {"n_per_sex": 11, "renders_per_subject": 16, "n_interferers": 26, "delta": 0.06, "mu": 0.30,
       "sd_subject": 0.05, "sd_model": 0.04, "sd_interferer": 0.02, "sd_render": 0.08, "sd_log_scale": 0.6}


def coverage_dataset(rng: np.random.Generator) -> dict:
    """One synthetic replication: per-render identity under-suppression and the personal/control under-suppression.

    f(model X on a render of A) = mu + [X == A] delta + a_A + v_X + c_interferer + e_render; under = id (1 - f).
    The truth is delta (the pooled ratio is a U_id-weighted mean of the per-render gains, whose expectation is
    delta)."""
    c = COV
    n = 2 * c["n_per_sex"]
    subj = [f"s{i}" for i in range(n)]
    donor = {}
    for sx in range(2):
        mem = subj[sx * c["n_per_sex"]:(sx + 1) * c["n_per_sex"]]
        for i, s in enumerate(mem):
            donor[s] = mem[(i + 1) % len(mem)]
    intf = [f"i{j}" for j in range(c["n_interferers"])]
    a = dict(zip(subj, rng.normal(0, c["sd_subject"], n)))
    v = dict(zip(subj, rng.normal(0, c["sd_model"], n)))
    ce = dict(zip(intf, rng.normal(0, c["sd_interferer"], len(intf))))
    scale = dict(zip(subj, np.exp(rng.normal(0, c["sd_log_scale"], n))))  # unequal oracle denominators
    rows = {"id": [], "up": [], "uc": [], "inv": []}
    for s in subj:
        for _ in range(c["renders_per_subject"]):
            it = intf[int(rng.integers(len(intf)))]
            idu = scale[s] * float(rng.gamma(4.0, 0.25))
            fp = c["mu"] + c["delta"] + a[s] + v[s] + ce[it] + rng.normal(0, c["sd_render"])
            fc = c["mu"] + a[s] + v[donor[s]] + ce[it] + rng.normal(0, c["sd_render"])
            rows["id"].append(idu)
            rows["up"].append(idu * (1 - fp))
            rows["uc"].append(idu * (1 - fc))
            rows["inv"].append([s, donor[s], it])
    return {"universe": subj + intf, **{k: (np.asarray(x) if k != "inv" else x) for k, x in rows.items()}}


def coverage_smoke(reps: int = COVERAGE_REPS, seed: int = COVERAGE_SEED, n_boot: int = N_BOOT) -> dict:
    rng = np.random.default_rng(seed)
    hits = 0
    for r in range(reps):
        d = coverage_dataset(rng)
        inv = involvement_matrix(d["inv"], d["universe"])
        W = weights(inv, len(d["universe"]), n_boot, seed=int(rng.integers(2**31)))
        res = contrast(W, np.ones(len(d["id"]), bool), d["id"], d["up"], d["uc"])
        hits += int(res["ci"]["lo"] <= COV["delta"] <= res["ci"]["hi"])
    cov = hits / reps
    return {"reps": reps, "seed": seed, "coverage": cov, "mc_se": float(np.sqrt(cov * (1 - cov) / reps)),
            "tolerance": COVERAGE_TOL, "passes_smoke": cov >= COVERAGE_TOL, "generator": COV}


__all__ = ["N_BOOT", "BOOT_SEED", "MAX_UNDEFINED", "involvement_matrix", "weights", "frac", "wmean", "ci", "contrast",
           "mean_contrast", "mean_ci", "frac_ci",
           "coverage_dataset", "coverage_smoke"]
