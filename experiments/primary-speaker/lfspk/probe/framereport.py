"""Stage 3 metrics (CPU job, DESIGN 6.3/6.4): frame AUC/EER of target speech vs
interferer-only frames, seed means with two-way speaker-bootstrap CIs (target
and interferer speakers), tap selection on dev half S, viability on half E.

    ./python -m lfspk.probe.framereport --weights base m1 --seeds 1 2 3
"""

from __future__ import annotations

import argparse
import json
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

from . import N_TAPS, SEED
from .metrics import GroupedTrials, bootstrap, difference, resample_weights
from .stage3 import OUT

N_BOOT = 1000
HALVES = ("full", "S", "E")
# subset -> (positive labels, negative labels)
SUBSETS = {
    "target_vs_interferer": ((1, 3), (2,)),
    "target_only_vs_interferer": ((1,), (2,)),
    "overlap_vs_interferer": ((3,), (2,)),
}
VIABLE = {"cond_minus_uncond": 0.05, "auc": 0.90, "fa_at_miss2": 0.50}


MIX_FILTERS = ("all", "same_sex", "cross_project")


def frame_items(z, subset: str, half: str = "full", mixtures: str = "all"):
    """Frames of a subset in one dev half: (frame indices, binary labels,
    target-speaker group, interferer-speaker group, number of groups).

    mixtures: all; same_sex (same-sex interferer); cross_project (target
    speakers whose enrollment and test utterances come from different LibriVox
    projects, so a profile cannot match the target by its recording chain)."""
    if mixtures not in MIX_FILTERS:
        raise ValueError(mixtures)
    labels, lengths = z["labels"], z["lengths"]
    tspk = np.array([str(s) for s in z["target_speaker"]])
    ispk = np.array([str(s) for s in z["interferer_speaker"]])
    pos, neg = SUBSETS[subset]
    if half == "full":
        inside = sorted(set(tspk) | set(ispk), key=int)
    else:
        inside = sorted(map(str, z[f"half_{half}"]), key=int)
    gi = {s: i for i, s in enumerate(inside)}
    mix_ok = np.isin(tspk, inside) & np.isin(ispk, inside)
    if mixtures == "same_sex":
        mix_ok &= np.asarray(z["same_sex"], bool)
    elif mixtures == "cross_project":
        mix_ok &= np.array([str(x) == "cross_project" for x in z["target_session"]])
    mix_of = np.repeat(np.arange(lengths.size), lengths)
    keep = np.isin(labels, pos + neg) & mix_ok[mix_of]
    idx = np.flatnonzero(keep)
    gt = np.array([gi.get(s, -1) for s in tspk])[mix_of[idx]]
    gj = np.array([gi.get(s, -1) for s in ispk])[mix_of[idx]]
    return idx, np.isin(labels[idx], pos), gt, gj, len(inside)


def _seed_mean(trials: list[GroupedTrials]):
    def stat(wg):
        return np.mean([t.auc_eer(wg) for t in trials], axis=0)  # [AUC, EER, FA@1%miss, FA@2%miss]
    return stat


def _task(args):
    a_name, b_name, files, subset, half, mixtures = args
    zs = [np.load(f) for f in files]
    z0 = zs[0]
    for z in zs[1:]:
        if not np.array_equal(z["labels"], z0["labels"]):
            raise ValueError("seeds disagree on dev labels")
    idx, y, gt, gj, n = frame_items(z0, subset, half, mixtures)
    base = {"a": a_name, "b": b_name, "subset": subset, "half": half, "mixtures": mixtures,
            "frames": int(idx.size), "positives": int(y.sum()), "speakers": n}
    if y.all() or not y.any():
        nan = {"value": float("nan"), "lo": float("nan"), "hi": float("nan")}
        return {**base, "auc": nan, "eer": nan, "fa_at_miss1": nan, "fa_at_miss2": nan, "per_seed_a": []}
    # frames of one (target, interferer) speaker pair share their bootstrap weight m_t * m_i
    pairs, pair_idx = np.unique(np.stack([gt, gj], 1), axis=0, return_inverse=True)
    pair_idx = pair_idx.ravel()

    def grouped(name):
        return [GroupedTrials(z[f"score/{name}"][idx].astype(np.float64), y, pair_idx, len(pairs)) for z in zs]
    ta = grouped(a_name)
    stat = _seed_mean(ta)
    if b_name:
        stat = difference(stat, _seed_mean(grouped(b_name)))
    mult = resample_weights(n, N_BOOT, SEED + HALVES.index(half))
    est = bootstrap(stat, lambda m: m[pairs[:, 0]] * m[pairs[:, 1]], mult)
    keys = ("auc", "eer", "fa_at_miss1", "fa_at_miss2")
    per_seed = [dict(zip(keys, map(float, t.auc_eer()))) for t in ta]
    return {**base, **{k: e.as_dict() for k, e in zip(keys, est)}, "per_seed_a": per_seed}


def plan_tasks(weights: str, files: list[Path]) -> list[tuple]:
    tasks = []
    names = [f"{weights}:tap{t}:{c}" for t in range(N_TAPS) for c in ("cond", "uncond")]
    names += ["logmel:tap0:cond", "logmel:tap0:uncond"]
    for half in HALVES:
        for subset in SUBSETS:
            for mix in MIX_FILTERS:
                tasks += [(n, None, files, subset, half, mix) for n in names]
        for mix in MIX_FILTERS:
            for t in range(N_TAPS):
                tasks.append((f"{weights}:tap{t}:cond", f"{weights}:tap{t}:uncond", files, "target_vs_interferer", half, mix))
                tasks.append((f"{weights}:tap{t}:cond", "logmel:tap0:cond", files, "target_vs_interferer", half, mix))
            tasks.append(("logmel:tap0:cond", "logmel:tap0:uncond", files, "target_vs_interferer", half, mix))
    return tasks


def _find(results, a, b, half, subset="target_vs_interferer", mixtures="all"):
    for r in results:
        if r["a"] == a and r["b"] == b and r["subset"] == subset and r["half"] == half and r["mixtures"] == mixtures:
            return r
    raise KeyError((a, b, half, subset, mixtures))


def select_tap(results: list[dict], weights: str) -> str:
    """argmax of the seed-mean conditioned AUC (target vs interferer, all mixtures) on half S."""
    return max((f"tap{t}" for t in range(N_TAPS)),
               key=lambda tp: (_find(results, f"{weights}:{tp}:cond", None, "S")["auc"]["value"], -int(tp[3:])))


def viability(results: list[dict], weights: str, tap: str, half: str = "E") -> dict:
    """DESIGN 6.4 at the S-selected tap, judged on half E, all mixtures:
    permission to continue to the harness, not a product verdict.

    (a) AUC(cond) - AUC(uncond) >= 0.05 and its CI above 0;
    (b) AUC(cond) - AUC(logmel cond): CI above 0;
    (c) AUC(cond) >= 0.90;
    (d) at most 2 % of target frames dropped, the conditioned head keeps at most
        50 % of interferer-only frames, and fewer than the unconditioned head
        (CI of the difference below 0).
    The same quantities for cross-project targets are reported alongside
    (descriptive: they bound how much a profile could match the recording
    chain rather than the voice)."""
    c = f"{weights}:{tap}:cond"

    def block(mixtures):
        d_u = _find(results, c, f"{weights}:{tap}:uncond", half, mixtures=mixtures)
        d_l = _find(results, c, "logmel:tap0:cond", half, mixtures=mixtures)
        own = _find(results, c, None, half, mixtures=mixtures)
        return {"a_cond_minus_uncond": d_u["auc"], "b_cond_minus_logmel": d_l["auc"], "c_auc": own["auc"],
                "d_fa_at_miss2": own["fa_at_miss2"], "d_fa_cond_minus_uncond": d_u["fa_at_miss2"],
                "fa_cond_minus_logmel": d_l["fa_at_miss2"], "fa_at_miss1": own["fa_at_miss1"]}
    allm = block("all")
    viable = bool(allm["a_cond_minus_uncond"]["value"] >= VIABLE["cond_minus_uncond"]
                  and allm["a_cond_minus_uncond"]["lo"] > 0
                  and allm["b_cond_minus_logmel"]["lo"] > 0
                  and allm["c_auc"]["value"] >= VIABLE["auc"]
                  and allm["d_fa_at_miss2"]["value"] <= VIABLE["fa_at_miss2"]
                  and allm["d_fa_cond_minus_uncond"]["hi"] < 0)
    return {"tap": tap, "half": half, **allm, "cross_project": block("cross_project"),
            "continue_to_harness": viable}


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", nargs="+", default=["base", "m1"])
    ap.add_argument("--seeds", type=int, nargs="+", default=[1, 2, 3])
    ap.add_argument("--root", type=Path, default=OUT)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args(argv)
    report = {"n_boot": N_BOOT, "seed": SEED, "seeds": args.seeds, "bootstrap": "two-way (target x interferer speakers)",
              "results": {}, "selected_tap": {}, "viability": {}}
    for w in args.weights:
        files = [args.root / f"{w}-seed{s}" / "dev_scores.npz" for s in args.seeds]
        for f in files:
            run = json.loads((f.parent / "run.json").read_text())
            if run.get("smoke"):
                raise ValueError(f"{f} is a smoke run")
        with ProcessPoolExecutor(args.workers) as ex:
            res = list(ex.map(_task, plan_tasks(w, files)))
        report["results"][w] = res
        tap = select_tap(res, w)
        report["selected_tap"][w] = tap
        report["viability"][w] = viability(res, w, tap)
    (args.root / "report.json").write_text(json.dumps(report, indent=1))
    for w, v in report["viability"].items():
        print(w, v["tap"], "E: AUC", round(v["c_auc"]["value"], 4), "cond-uncond",
              round(v["a_cond_minus_uncond"]["value"], 4), "cond-logmel", round(v["b_cond_minus_logmel"]["value"], 4),
              "FA@2%miss", round(v["d_fa_at_miss2"]["value"], 4), "continue_to_harness", v["continue_to_harness"])


if __name__ == "__main__":
    main()
