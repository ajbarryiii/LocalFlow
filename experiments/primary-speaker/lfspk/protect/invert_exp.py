"""Utility and inversion of every protection in the grid (DESIGN.md 6.2, 6.3).

    ./python -m lfspk.protect.invert_exp --embedder ecapa [--only raw,lda32] [--smoke]

CPU only. Writes runs/W4/invert/<embedder>/<protection>.json, summary.tsv and
config.json (seeds, commit, command).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .. import paths
from . import attacks, metrics
from .data import DevSet, TrainSet, load_dev, load_train
from .extract import git_commit
from .transforms import GRID, Composed, KeyedRotation, Noise, Protection, Quantizer, SimHash, build, l2n

PROT_SEED = 7301
NOISE_SEED = 7302
PSEUDO_SEED = 7303
SPLIT_SEED = 7304
BOOT_SEED = 7305
MLP_SEEDS = (0, 1, 2)
KS = (3, 10, 20)
K_MAIN = 10
N_BOOT = 1000


@dataclass
class Config:
    per_speaker: int = 20  # train pseudo-profiles per speaker
    per_speaker_linfn: int = 5
    val_frac: float = 0.1
    n_boot: int = N_BOOT
    mlp_epochs: int = 200
    mlp_seeds: tuple[int, ...] = MLP_SEEDS


def _ci(vals_by_spk: dict[str, float], n_boot: int, seed: int = BOOT_SEED) -> dict:
    keys = sorted(vals_by_spk)
    v = np.array([vals_by_spk[k] for k in keys], dtype=np.float64)
    rng = np.random.default_rng(seed)
    boots = v[rng.integers(0, len(v), (n_boot, len(v)))].mean(1)
    lo, hi = np.quantile(boots, [0.025, 0.975])
    return {"mean": float(v.mean()), "lo": float(lo), "hi": float(hi)}


def enc_dim(prot: Composed) -> int:
    return prot.base.out_dim


def templates(prot: Protection, utt_sets: list[np.ndarray], seed_key: int) -> np.ndarray:
    return prot.protect_from_utterances(utt_sets, np.random.default_rng([NOISE_SEED, seed_key]))


def utility(prot: Protection, dev: DevSet, T: np.ndarray, which: str, n_boot: int,
            with_ci: bool, profile_mask: np.ndarray | None = None) -> dict:
    """Profiles (rows of T, in dev.speakers order) vs every H utterance of every
    speaker. EER/minDCF over all impostors, same-sex impostors, and profiles of
    project-separated speakers only (sensitivity). CIs: joint speaker bootstrap
    (metrics.joint_bootstrap)."""
    probe_ids, probe_idx = [], []
    for i, s in enumerate(dev.speakers):
        for u in dev.roles[s].H:
            probe_ids.append(u)
            probe_idx.append(i)
    P = prot.probe(dev.stack(probe_ids, which))
    S = prot.score(T, P)  # [n_spk, n_probe]
    n = len(dev.speakers)
    owner = np.repeat(np.arange(n), len(probe_ids))
    other = np.tile(np.array(probe_idx), n)
    lab = owner == other
    sexes = np.array([dev.sex[s] for s in dev.speakers])
    same_sex = sexes[owner] == sexes[other]
    sep_project = np.array([dev.roles[s].separation == "project" for s in dev.speakers])[owner]
    has_profile = np.ones(n, dtype=bool) if profile_mask is None else np.asarray(profile_mask)
    s_flat = S.ravel()
    out = {}
    for label, mask in (("all", np.ones_like(lab)), ("same_sex", same_sex), ("sep_project", sep_project)):
        rows = np.flatnonzero(mask & has_profile[owner])
        if not lab[rows].any():  # e.g. no project-separated speakers
            out[label] = None
            continue
        rows = rows[np.argsort(s_flat[rows], kind="stable")]  # presorted: cheap re-sorts in the bootstrap
        sc, lb, ow, ot = s_flat[rows], lab[rows], owner[rows], other[rows]
        e_fn = lambda w: metrics.eer(sc, lb, w)[0]
        d_fn = lambda w: metrics.min_dcf(sc, lb, weights=w)
        if with_ci:
            e = metrics.joint_bootstrap(ow, ot, n, e_fn, n_boot, BOOT_SEED)
            d = metrics.joint_bootstrap(ow, ot, n, d_fn, n_boot, BOOT_SEED)
            out[label] = {"eer": e[0], "eer_ci": [e[1], e[2]], "mindcf": d[0], "mindcf_ci": [d[1], d[2]]}
        else:
            out[label] = {"eer": e_fn(None), "mindcf": d_fn(None)}
        out[label]["n_target"] = int(lb.sum())
        out[label]["n_nontarget"] = int((~lb).sum())
        out[label]["n_profiles"] = int(np.unique(ow).size)
    return out


def raw_spoof_threshold(dev: DevSet) -> float:
    """EER threshold of the raw embedder for 'R centroid vs one T utterance'."""
    R = dev.r_centroids()
    ids, spk = [], []
    for i, s in enumerate(dev.speakers):
        for u in dev.roles[s].T:
            ids.append(u)
            spk.append(i)
    U = l2n(dev.stack(ids))
    S = R @ U.T
    lab = (np.arange(len(dev.speakers))[:, None] == np.array(spk)[None, :])
    return metrics.eer(S.ravel(), lab.ravel())[1]


def inversion_metrics(est: np.ndarray, dev: DevSet, c_true: np.ndarray, R: np.ndarray,
                      gallery_train: np.ndarray, spoof_thr: float, n_boot: int,
                      subset: np.ndarray | None = None) -> dict:
    """Metrics for recovered vectors `est` (rows in dev.speakers order). With
    `subset` (boolean over speakers), queries are restricted to it; galleries
    keep every dev speaker."""
    est = l2n(est)
    cos_true = np.sum(est * c_true, 1)
    cos_r = np.sum(est * R, 1)
    n = len(dev.speakers)
    rank_dev = metrics.id_rank(est, R, np.arange(n))
    rank_all = metrics.id_rank(est, np.vstack([R, gallery_train]), np.arange(n))
    spoof = (cos_r >= spoof_thr).astype(float)
    keep = np.ones(n, dtype=bool) if subset is None else np.asarray(subset)
    per = lambda v: {s: float(v[i]) for i, s in enumerate(dev.speakers) if keep[i]}
    out = {
        "n_queries": int(keep.sum()),
        "cos_true": _ci(per(cos_true), n_boot),
        "cos_R": _ci(per(cos_r), n_boot),
        "median_rank_dev": float(np.median(rank_dev[keep])),
        "median_rank_all": float(np.median(rank_all[keep])),
        "spoof_accept": _ci(per(spoof), n_boot),
    }
    # Identification: the gallery stays fixed at its declared size (73 dev R
    # centroids, or those plus the public train centroids); the CI resamples
    # query speakers only (r2 #5).
    out["gallery_dev"] = int(n)
    out["gallery_all"] = int(n + len(gallery_train))
    out["top1_dev"] = _ci(per(rank_dev == 1), n_boot)
    out["top5_dev"] = _ci(per(rank_dev <= 5), n_boot)
    out["top1_all"] = _ci(per(rank_all == 1), n_boot)
    out["top5_all"] = _ci(per(rank_all <= 5), n_boot)
    return out


def sex_leakage(F_tr: np.ndarray, sex_tr: np.ndarray, F_dev: np.ndarray, sex_dev: np.ndarray,
                speakers: list[str], n_boot: int) -> dict:
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    clf = make_pipeline(StandardScaler(), LogisticRegression(C=1.0, max_iter=2000))
    clf.fit(F_tr, sex_tr)
    correct = (clf.predict(F_dev) == sex_dev).astype(float)
    return _ci({s: float(correct[i]) for i, s in enumerate(speakers)}, n_boot)


def speaker_sets(y: np.ndarray, val_frac: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Disjoint fit / validation / selection train-speaker sets (fixed seeds)."""
    rest, sel = attacks.split_speakers(y, val_frac, SPLIT_SEED)
    tr, va = attacks.split_speakers(rest, val_frac / (1 - val_frac), SPLIT_SEED + 1)
    return tr, va, sel


class AttackSuite:
    """Every attacker for one protection, fitted on train pseudo-profiles.

    Train speakers are split three ways: fit, va (ridge lambda, MLP early
    stopping) and sel (the selection set: `sel_cos` ranks attackers there and
    the best is "selected", never using dev). `invert(attacker, T)` applies an
    attacker to any templates (dev, or train-sel with `sel_gallery=True`, which
    keeps the selection speakers out of the nearest-public-voice gallery)."""

    def __init__(self, prot: Protection, name: str, train: TrainSet, cfg: Config):
        self.prot, self.name = prot, name
        excluded = getattr(prot, "cohort", np.array([]))
        self.keep = keep = ~np.isin(train.y, excluded)
        self.Xk, self.yk = train.X[keep], train.y[keep]
        per = cfg.per_speaker_linfn if name == "linfn" else cfg.per_speaker
        self.pp = pp = attacks.sample_pseudo_profiles(self.Xk, self.yk, per, KS, PSEUDO_SEED)
        self.T_pp = templates(prot, [self.Xk[m] for m in pp.members], 99)
        self.F_pp = F_pp = prot.features(self.T_pp)
        # Speaker sets drawn from all train speakers, so they are the same for
        # every protection (a cohort exclusion only removes speakers).
        tr_spk, va_spk, self.sel_spk = speaker_sets(train.y, cfg.val_frac)
        self.tr, self.va, self.sel = (np.isin(pp.speaker, x) for x in (tr_spk, va_spk, self.sel_spk))
        tr, va, sel = self.tr, self.va, self.sel
        self.train_spk, self.train_cent = train.speaker_centroids()
        not_sel = ~np.isin(self.train_spk, self.sel_spk)
        self.knn_all = attacks.NearestPublic(prot, self.train_cent, 10)
        self.knn_sel = attacks.NearestPublic(prot, self.train_cent[not_sel], 10)
        self.ridge = attacks.Ridge().fit(F_pp[tr], pp.C[tr], F_pp[va], pp.C[va])
        self.mlps = {}
        for sd in cfg.mlp_seeds:
            m = attacks.MLP(sd, epochs=cfg.mlp_epochs).fit(F_pp[tr], pp.C[tr], F_pp[va], pp.C[va])
            self.mlps[m.name] = m
        self.enc = prot.encoder if isinstance(prot, Composed) else None
        self.info = {"ridge": {"lambda": self.ridge.lam, "val_cos": self.ridge.val_cos}}
        for k, m in self.mlps.items():
            self.info[k] = {"val_cos": m.val_cos, "epochs": m.epochs_run}
        self.feasibility: dict[str, list[dict]] = {}  # stored codes reproduced / total, per call
        self.sel_cos = {a: attacks.mean_cos(self.invert(a, self.T_pp[sel], sel_gallery=True), pp.C[sel])
                        for a in self.names()}
        for k, v in self.sel_cos.items():
            self.info.setdefault(k, {})["sel_cos"] = v
        self.selected = max(self.sel_cos, key=self.sel_cos.get)

    def names(self) -> list[str]:
        out = ["knn10", "ridge", *self.mlps]
        if self.prot.analytic_inverse(self.T_pp[:1]) is not None:
            out.insert(0, "analytic")
        if isinstance(self.enc, SimHash):
            out += ["maxmargin", "ridge+cons"]
        if isinstance(self.enc, Quantizer):
            out += ["ridge+cons"]
        return out

    def invert(self, attacker: str, T: np.ndarray, sel_gallery: bool = False) -> np.ndarray:
        prot, F = self.prot, self.prot.features(T)
        if attacker == "analytic":
            return attacks.Analytic(prot).invert_templates(T)
        if attacker == "knn10":
            return (self.knn_sel if sel_gallery else self.knn_all).invert_templates(T)
        if attacker == "ridge":
            return self.ridge.invert(F)
        if attacker in self.mlps:
            return self.mlps[attacker].invert(F)
        # Constraint-consistent attacks: the stored code is a set of constraints
        # every candidate must satisfy.
        base = prot.base
        if attacker == "maxmargin" and isinstance(self.enc, SimHash):
            x, ok = attacks.sign_consistent(self.enc.H, T, return_feasible=True)
        elif attacker == "ridge+cons" and isinstance(self.enc, SimHash):
            x, ok = attacks.sign_consistent(self.enc.H, T, base.forward(self.ridge.invert(F)), return_feasible=True)
        elif attacker == "ridge+cons" and isinstance(self.enc, Quantizer):
            x, ok = attacks.quant_consistent(self.enc, T, base.forward(self.ridge.invert(F)), return_feasible=True)
        else:
            raise KeyError(attacker)
        self.feasibility.setdefault(attacker, []).append({"feasible": int(ok.sum()), "n": int(ok.size)})
        return base.inverse(x)


def evaluate_protection(name: str, train: TrainSet, dev: DevSet, cfg: Config,
                        log=print, out_dir: Path | None = None,
                        extra: dict[str, DevSet] | None = None) -> dict:
    """Utility and inversion on dev; with `extra` (the auxiliary clone_eval
    targets), the same attackers and the dev spoofing threshold are applied
    unchanged to those targets and reported separately (no fitting, selection
    or tuning on them)."""
    t0 = time.time()
    prot = build(name, PROT_SEED).fit(train.X, train.y, PROT_SEED)
    res: dict = {"protection": name}
    # ---- dev templates and utility
    # Speakers whose enrollment pool is shorter than k reuse their whole pool for
    # the template but are excluded from that k's utility trials.
    T_by_k = {k: templates(prot, dev.profile_utts(k), k) for k in KS}
    has_k = {k: np.array([len(dev.roles[s].E) >= k for s in dev.speakers]) for k in KS}
    res["stored_bytes"] = len(prot.to_bytes(T_by_k[K_MAIN][0]))
    res["stored_bits"] = prot.stored_bits()
    res["utility"] = {}
    for k in KS:
        for which in ("crop", "full"):
            ci = k == K_MAIN
            res["utility"][f"k{k}_{which}"] = utility(prot, dev, T_by_k[k], which, cfg.n_boot, ci, has_k[k])
    log(f"[{name}] utility done {time.time() - t0:.0f}s: "
        f"EER crop k10 {res['utility']['k10_crop']['all']['eer']:.4f}")

    suite = AttackSuite(prot, name, train, cfg)
    T_dev = T_by_k[K_MAIN]
    c_true = dev.raw_profiles(K_MAIN)
    R = dev.r_centroids()
    train_cent = suite.train_cent
    thr = raw_spoof_threshold(dev)
    res["spoof_threshold"] = thr
    estimates = {a: suite.invert(a, T_dev) for a in suite.names()}
    if name == "keyrot":  # control: an attacker without the key (A1, not A3); never selected
        wrong = KeyedRotation(prot.base.key + 1).fit(train.X, train.y, None)
        estimates["wrongkey"] = wrong.inverse(prot.features(T_dev))
    if isinstance(getattr(prot, "encoder", None), Noise):
        # Worst case only if a seed or the noise were ever persisted (the
        # product never does): replay the experiment's noise and undo it.
        # Reported, never selected.
        enc = prot.encoder
        N = enc.noise((len(T_dev), enc_dim(prot)), np.random.default_rng([NOISE_SEED, K_MAIN]))
        estimates["seedleak"] = prot.base.inverse(Noise.undo(T_dev, N))
    sel_cos = suite.sel_cos
    info = suite.info
    for a, f in suite.feasibility.items():  # [selection set, dev]
        info.setdefault(a, {})["code_feasibility"] = f
    log(f"[{name}] attackers trained {time.time() - t0:.0f}s")

    res["attackers"] = {}
    sep = np.array([dev.roles[s].separation == "project" for s in dev.speakers])
    for an, est in estimates.items():
        res["attackers"][an] = inversion_metrics(est, dev, c_true, R, train_cent, thr, cfg.n_boot)
        res["attackers"][an]["sep_project"] = (inversion_metrics(est, dev, c_true, R, train_cent, thr,
                                                                 cfg.n_boot, subset=sep) if sep.any() else None)
        res["attackers"][an].update(info.get(an, {}))
    if out_dir is not None:  # recovered vectors, for the cloning stage
        np.savez(out_dir / f"{name}.est.npz", speakers=np.array(dev.speakers),
                 **{k: v.astype(np.float32) for k, v in estimates.items()})
    # Primary: the attacker chosen on held-out train speakers (sel_cos), fixed
    # before dev is looked at. Exploratory: the best attacker per metric on dev
    # (selected on dev, so biased toward the attacker; labelled as such).
    res["selected_attacker"] = suite.selected
    res["selected"] = res["attackers"][res["selected_attacker"]]
    best = {}
    for metric in ("cos_true", "cos_R", "top1_dev", "top5_dev", "top1_all", "spoof_accept"):
        an = max(res["attackers"], key=lambda k: res["attackers"][k][metric]["mean"])
        best[metric] = {"attacker": an, **res["attackers"][an][metric]}
    res["best_on_dev_exploratory"] = best

    # ---- sex leakage from the stored template
    sex_pp = np.array([train.sex[s] for s in suite.pp.speaker])
    sex_dev = np.array([dev.sex[s] for s in dev.speakers])
    res["sex_accuracy"] = sex_leakage(suite.F_pp, sex_pp, prot.features(T_dev), sex_dev, dev.speakers, cfg.n_boot)

    # ---- auxiliary target sets: context utility and inversion, nothing fitted
    res["extra"] = {}
    for split, ds in (extra or {}).items():
        T_x = templates(prot, ds.profile_utts(K_MAIN), K_MAIN)
        has = np.array([len(ds.roles[s].E) >= K_MAIN for s in ds.speakers])
        # Context only: point estimates, no bootstrap (clone_eval has ~5 M
        # profile x probe trials; selection uses dev's utility with CIs).
        ex: dict = {"n_targets": len(ds.speakers), "utility_label": "point estimate, no CI (context only)",
                    "utility_context_point_estimates": {
            f"k{K_MAIN}_{which}": utility(prot, ds, T_x, which, cfg.n_boot, False, has) for which in ("crop", "full")}}
        est_x = {a: suite.invert(a, T_x) for a in suite.names()}
        ex["attackers"] = {a: inversion_metrics(e, ds, ds.raw_profiles(K_MAIN), ds.r_centroids(), train_cent, thr,
                                                cfg.n_boot) for a, e in est_x.items()}
        ex["selected"] = ex["attackers"][suite.selected]
        res["extra"][split] = ex
        if out_dir is not None:
            np.savez(out_dir / f"{name}.{split}.est.npz", speakers=np.array(ds.speakers),
                     **{k: v.astype(np.float32) for k, v in est_x.items()})
    res["seconds"] = time.time() - t0
    log(f"[{name}] done {res['seconds']:.0f}s: selected {res['selected_attacker']} top1_dev "
        f"{res['selected']['top1_dev']['mean']:.2f}, sex acc {res['sex_accuracy']['mean']:.2f}")
    return res


SUMMARY_COLS = ("protection", "bytes", "eer_crop_k10", "eer_lo", "eer_hi", "eer_samesex", "mindcf",
                "attacker", "cos_true", "cos_R", "top1_dev", "top1_all", "spoof", "expl_max_top1_dev",
                "sex_acc")


def summary_row(r: dict) -> list:
    u = r["utility"]["k10_crop"]
    a = r["selected"]
    return [r["protection"], r["stored_bytes"], u["all"]["eer"], *u["all"]["eer_ci"], u["same_sex"]["eer"],
            u["all"]["mindcf"], r["selected_attacker"], a["cos_true"]["mean"], a["cos_R"]["mean"],
            a["top1_dev"]["mean"], a["top1_all"]["mean"], a["spoof_accept"]["mean"],
            r["best_on_dev_exploratory"]["top1_dev"]["mean"], r["sex_accuracy"]["mean"]]


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--embedder", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--smoke", action="store_true", help="tiny settings for a quick check")
    ap.add_argument("--clone-eval", action="store_true",
                    help="also report the auxiliary clone_eval targets (no fitting on them)")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args(argv)
    paths.require_mount()
    import torch

    torch.set_num_threads(int(__import__("os").environ.get("OMP_NUM_THREADS", "4")))
    cfg = Config()
    if args.smoke:
        cfg = Config(per_speaker=3, per_speaker_linfn=2, n_boot=50, mlp_epochs=3, mlp_seeds=(0,))
    names = [n for n in args.only.split(",") if n] or list(GRID)
    out = args.out or paths.RUNS / "W4" / ("invert-smoke" if args.smoke else "invert") / args.embedder
    out.mkdir(parents=True, exist_ok=True)
    train, dev = load_train(args.embedder), load_dev(args.embedder)
    extra = {}
    if args.clone_eval:
        extra["clone_eval"] = load_dev(args.embedder, split="clone_eval")
    for ds in [dev, *extra.values()]:
        if train.meta["weights_sha256"] != ds.meta["weights_sha256"]:
            raise SystemExit("caches come from different embedder weights")
    (out / "config.json").write_text(json.dumps({
        "embedder": args.embedder, "train_meta": train.meta, "dev_meta": dev.meta,
        "seeds": {"prot": PROT_SEED, "noise": NOISE_SEED, "pseudo": PSEUDO_SEED, "split": SPLIT_SEED,
                  "boot": BOOT_SEED, "mlp": list(cfg.mlp_seeds)},
        "config": cfg.__dict__, "protections": names, "git_commit": git_commit(),
        "command": " ".join(sys.argv),
        "separation": {s: dev.roles[s].separation for s in dev.speakers},
        "extra_meta": {k: v.meta for k, v in extra.items()},
    }, indent=2, default=list) + "\n")
    rows = []
    for name in names:
        r = evaluate_protection(name, train, dev, cfg, out_dir=out, extra=extra)
        (out / f"{name}.json").write_text(json.dumps(r, indent=2) + "\n")
        rows.append(summary_row(r))
    with open(out / "summary.tsv", "w") as f:
        f.write("\t".join(SUMMARY_COLS) + "\n")
        for row in rows:
            f.write("\t".join(f"{v:.4f}" if isinstance(v, float) else str(v) for v in row) + "\n")


if __name__ == "__main__":
    main()
