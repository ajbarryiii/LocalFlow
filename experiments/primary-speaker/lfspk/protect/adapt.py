"""Adaptation compatibility of protected templates (DESIGN.md section 6.5).

    ./python -m lfspk.protect.adapt --embedder ecapa-vox

Per dev speaker, the enrollment stream E is folded in one dictation at a time
starting from a 3-dictation enrollment. At n = 3, 10, 20 the primary EER (2 s
crops, all impostors, joint speaker bootstrap) of each protected-domain update
rule is compared with the exact template of the first n dictations (which needs
the unprotected running mean). Noise templates also report how much of the
injected noise survives updates, and the snapshot-averaging attack. CPU only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from .. import paths
from .data import DevSet, load_dev, load_train
from .extract import git_commit
from .invert_exp import PROT_SEED, utility
from .transforms import Composed, Noise, Quantizer, build, l2n

NS = (3, 10, 20)
ADAPT_SEED = 7320
SNAPSHOTS = (1, 2, 5, 10)
RULES = {
    "raw": ("exact",),
    "lda32": ("exact",),
    "center+q2": ("round", "stochastic"),
    "lda32+q1": ("round", "stochastic"),
    "lda32+q2": ("round", "stochastic"),
    "center+sh128": ("votes", "flip"),
    "lda32+sh64": ("votes", "flip"),
    "center+noise0.5": ("decay",),
    "lda32+noise0.5": ("decay",),
}


def quant_update(enc: Quantizer, T: np.ndarray, n: int, v: np.ndarray, rng: np.random.Generator | None) -> np.ndarray:
    """Fold unit base vectors v (one per profile) into codes of n dictations:
    z = (n dequant(T) + v) / (n + 1), re-encoded with deterministic (rng None)
    or stochastic rounding (unbiased: floor(u + U[0, 1)))."""
    L = 2 ** enc.bits
    deq = ((T.astype(np.float64) + 0.5) / L * 2.0 - 1.0) * enc.scale
    z = (n * deq + v) / (n + 1)
    u = (np.clip(z / enc.scale, -1.0, 1.0) + 1.0) / 2.0 * L - 0.5  # level coordinate
    if rng is None:
        q = np.round(u)
    else:
        q = np.floor(u + rng.random(u.shape))
    return np.clip(q, 0, L - 1).astype(np.uint8)


def flip_update(T: np.ndarray, n: int, bits_new: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Signs only: where the new dictation disagrees, flip with probability
    1 / (n + 1) (each stored bit is then the bit of a uniformly random past
    dictation)."""
    flip = (bits_new != T) & (rng.random(T.shape) < 1.0 / (n + 1))
    return np.where(flip, bits_new, T).astype(np.uint8)


def run_rules(prot: Composed, rule: str, E: list[np.ndarray], rng: np.random.Generator) -> dict[int, np.ndarray]:
    """Templates after n dictations for each n in NS (profiles with |E| < n are
    left at their last template; the caller masks them)."""
    base, enc = prot.base, prot.encoder
    m = len(E)
    out: dict[int, np.ndarray] = {}
    if rule == "exact":
        T = prot.protect_from_utterances([e[:3] for e in E])
        counts = np.full(m, 3)
        for n in range(3, max(NS)):
            if n in NS:
                out[n] = T.copy()
            x = np.stack([e[min(n, len(e) - 1)] for e in E])
            active = np.array([n < len(e) for e in E])
            T = np.where(active[:, None], prot.update(T, counts, x), T)
            counts = counts + active
        out[max(NS)] = T
        return out
    if rule in ("round", "stochastic"):
        T = prot.protect_from_utterances([e[:3] for e in E])
        for n in range(3, max(NS)):
            if n in NS:
                out[n] = T.copy()
            v = base.forward(np.stack([e[min(n, len(e) - 1)] for e in E]))
            active = np.array([n < len(e) for e in E])
            T = np.where(active[:, None], quant_update(enc, T, n, v, None if rule == "round" else rng), T)
        out[max(NS)] = T
        return out
    if rule == "votes":
        # Stored: per-bit counts of 1-votes and n. Template bits = majority (ties -> 1).
        votes = np.stack([(base.forward(e[:3]) @ enc.H > 0).sum(0) for e in E]).astype(float)
        counts = np.full(m, 3.0)
        for n in range(3, max(NS) + 1):
            if n in NS:
                out[n] = (votes / counts[:, None] >= 0.5).astype(np.uint8)
            if n == max(NS):
                break
            active = np.array([n < len(e) for e in E])
            b = (base.forward(np.stack([e[min(n, len(e) - 1)] for e in E])) @ enc.H > 0)
            votes += active[:, None] * b
            counts += active
        return out
    if rule == "flip":
        T = prot.protect_from_utterances([e[:3] for e in E])
        for n in range(3, max(NS)):
            if n in NS:
                out[n] = T.copy()
            b = (base.forward(np.stack([e[min(n, len(e) - 1)] for e in E])) @ enc.H > 0).astype(np.uint8)
            active = np.array([n < len(e) for e in E])
            T = np.where(active[:, None], flip_update(T, n, b, rng), T)
        out[max(NS)] = T
        return out
    if rule == "decay":
        # Noise injected once at enrollment, then a running mean of the noisy
        # direction: the noise weight falls as 3 / n.
        T = prot.protect_from_utterances([e[:3] for e in E], rng).astype(np.float64)
        for n in range(3, max(NS)):
            if n in NS:
                out[n] = T.copy()
            v = base.forward(np.stack([e[min(n, len(e) - 1)] for e in E]))
            active = np.array([n < len(e) for e in E])
            T = np.where(active[:, None], l2n((n * T + v) / (n + 1)), T)
        out[max(NS)] = T
        return out
    raise ValueError(rule)


def noise_analysis(prot: Composed, dev: DevSet, rng: np.random.Generator) -> dict:
    """How close the stored noisy direction is to the true (noise-free) state:
    (a) after decay updates, (b) when fresh noise is drawn at every save and an
    attacker averages the last N saved snapshots (dictations 11..20)."""
    base = prot.base
    E = [dev.stack(dev.roles[s].E) for s in dev.speakers]
    full = np.array([len(e) >= max(NS) for e in E])
    # Truth: the normalised projected running mean, the state templates encode
    # (review clone-r1 #4: not forward(mean), which renormalises before centring).
    truth = {n: l2n(base.project(np.stack([l2n(e[:n]).mean(0) for e in E]))) for n in NS}
    dec = run_rules(prot, "decay", E, rng)
    out = {"decay_cos_to_true_state": {n: float(np.mean(np.sum(l2n(dec[n]) * truth[n], 1)[full])) for n in NS}}
    snaps = []
    for n in range(max(NS) - max(SNAPSHOTS) + 1, max(NS) + 1):
        state = base.project(np.stack([l2n(e[:n]).mean(0) for e in E]))
        snaps.append(prot.encoder.encode(state, rng).astype(np.float64))
    snaps = np.stack(snaps)  # [N, m, p]
    out["renoise_snapshot_average_cos"] = {
        N: float(np.mean(np.sum(l2n(snaps[-N:].mean(0)) * truth[max(NS)], 1)[full])) for N in SNAPSHOTS}
    return out


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--embedder", required=True)
    ap.add_argument("--n-boot", type=int, default=1000)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args(argv)
    paths.require_mount()
    train, dev = load_train(args.embedder), load_dev(args.embedder)
    out_dir = args.out or paths.RUNS / "W4" / "adapt" / args.embedder
    out_dir.mkdir(parents=True, exist_ok=True)
    E = [dev.stack(dev.roles[s].E) for s in dev.speakers]
    res: dict = {"embedder": args.embedder, "git_commit": git_commit(), "command": " ".join(sys.argv),
                 "seed": ADAPT_SEED, "protections": {}}
    for name, rules in RULES.items():
        prot = build(name, PROT_SEED).fit(train.X, train.y, PROT_SEED)
        entry: dict = {}
        for rule in ("batch",) + rules:
            rng = np.random.default_rng([ADAPT_SEED, len(entry)])
            if rule == "batch":
                Tn = {n: prot.protect_from_utterances([e[:n] for e in E], rng) for n in NS}
            else:
                Tn = run_rules(prot, rule, E, rng)
            entry[rule] = {}
            for n in NS:
                mask = np.array([len(e) >= n for e in E])
                u = utility(prot, dev, Tn[n], "crop", args.n_boot, True, mask)["all"]
                entry[rule][n] = {"eer": u["eer"], "eer_ci": u["eer_ci"], "n_profiles": u["n_profiles"]}
            print(f"[{name}] {rule}: " + ", ".join(f"n={n} EER {entry[rule][n]['eer']:.4f}" for n in NS), flush=True)
        if isinstance(prot.encoder, Noise):
            entry["noise"] = noise_analysis(prot, dev, np.random.default_rng([ADAPT_SEED, 99]))
        # Vote-count leakage: evaluated by invert_exp as protections
        # center+shv128 and lda32+shv64 (full attack suite; review clone-r1 #5).
        res["protections"][name] = entry
        (out_dir / "results.json").write_text(json.dumps(res, indent=2) + "\n")


if __name__ == "__main__":
    main()
