"""Cloning end to end (DESIGN.md section 6.4), in three stages.

    ./python -m lfspk.protect.clone_exp prepare --embedder ecapa-vox     (CPU)
    ./python-nemo -m lfspk.protect.clone_exp synth                         (GPU)
    ./python -m lfspk.protect.clone_exp stats                              (CPU)

prepare: per profile embedder and cloned protection, fit the attack suite, the
  bridge (embedder centroid -> OpenVoice se) and the direct routes (protected
  template -> se) on train, choose fusion weights on held-out train speakers,
  and write every dev target se of every route (no audio) to
  runs/W4/clone/prepare-<embedder>.npz + .json.
synth: OpenVoice se of the attacker's real audio (3 s, 10 s), voice conversion
  of 5 same-sex train source utterances per dev target per condition, scored by
  two independent verifiers against the target's R centroid. Audio exists only
  in memory. Writes runs/W4/clone/scores.npz.
stats: thresholds from real dev trials, acceptance rates, Delta against the
  floor with the attack envelope, joint speaker bootstrap. Writes
  runs/W4/clone/results.json.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path

import numpy as np

from .. import paths
from . import attacks, embcache, metrics
from .data import DevSet, TrainSet, load_dev, load_train
from .extract import git_commit, load_segment, plan_rows
from .invert_exp import K_MAIN, PROT_SEED, AttackSuite, Config, speaker_sets, templates
from .transforms import build, l2n

OUT = paths.RUNS / "W4" / "clone"
CLONED = ("raw", "lda32", "lda16", "lda32+sh64", "lda32+q1", "anchor32", "center+noise0.5", "linfn")
# raw is always cloned; the others only if inside the utility budget (DESIGN 6.4),
# chosen with --only from invert_exp results before any cloning number exists.
ROUTES = ("inv+bridge", "direct-ridge", "direct-mlp")
VERIFIERS = ("wespeaker-r34lm", "titanet-l")
ALPHAS = (0.0, 0.25, 0.5, 0.75, 1.0)
SOURCE_SEED = 7310
N_SOURCES_PER_SEX = 5
DRAWS_PER_SOURCE = 4  # OpenVoice samples its latent (tau): repeated conversions differ
N_ATTEMPTS = N_SOURCES_PER_SEX * DRAWS_PER_SOURCE
FARS = (0.01, 0.001)
FAR = FARS[0]
KS_ATTEMPTS = (1, 5, 20)
# Pre-registered risk tiers for the 95 % upper bound of Delta at FAR 1 % (r2,
# orchestrator). AJ chooses the acceptable tier; the experiment only reports it.
TIERS = ((0.02, "negligible"), (0.05, "low"), (0.10, "moderate"), (float("inf"), "high"))
DELTA = 0.10  # power check: raw must exceed this clearly
# Boundary-valid bound (review invert-r3 #1): a target is "vulnerable" if some
# route's clones are accepted in at least VULN_CUT of its attempts at FAR 1 %.
# Not "any success". Illustration only, assuming independent accepts at a 1 %
# rate (shared seeds make routes correlated, so the real figures differ):
# 3 routes x 20 attempts would give 1 - 0.99^60 = 45 % of targets one chance
# success, while P(Binomial(20, 0.01) >= 5) = 1.4e-6 per route.
VULN_CUT = 0.25
WSR_ALPHA = 0.05  # two-sided budget split alpha/2 + alpha/2 (Bonferroni) in delta_upper
SR = 16_000
# Target splits: dev (73) and the auxiliary clone_eval (train-clean-100, 251;
# owner decision 2026-10-21) used only as extra targets, never fitted on.
TARGET_SPLITS = ("dev", "clone_eval")
HEADLINE_SPLIT = "clone_eval"  # owner decision after review invert-r5; dev is exploratory
# Floors: dev keeps cyclic within-dev partners (exploratory); the headline split
# gets unique same-sex train partners (independent floors).
TRAIN_PARTNER_SPLITS = ("clone_eval",)
PARTNER_SEED = 7330
ORDER_SEED = 7331  # pre-registered permutation of targets for the betting bounds


# ------------------------------------------------------------------ data

def load_ovse(split: str, generation: str | None = None) -> tuple[dict[str, np.ndarray], dict]:
    """OpenVoice se cache of a split, one pinned generation (CURRENT resolved
    once), validated for completeness and for the pinned OpenVoice weights and
    code (review clone-r1 #6)."""
    from . import openvoice
    from .extract import planned_ids
    from .ovse import OVSE_ROOT

    c = embcache.read(OVSE_ROOT / split, generation)
    want = {u for u, full in planned_ids(split) if full}
    have = {r.utt_id for r in c.rows}
    if c.meta.get("limit_speakers") or have != want:
        raise ValueError(f"OpenVoice se cache for {split} is partial or does not match the plan")
    if c.meta.get("weights_sha256") != openvoice.PINNED["checkpoint.pth"] \
            or c.meta.get("code_commit") != openvoice.SRC_COMMIT:
        raise ValueError(f"OpenVoice se cache for {split} was built from other weights or code")
    return {r.utt_id: e.astype(np.float64) for r, e in zip(c.rows, c.emb)}, c.meta


def partners(dev: DevSet) -> dict[str, str]:
    """Fixed different same-sex dev speaker (next in id order, cyclic)."""
    out = {}
    for sex in ("F", "M"):
        group = [s for s in dev.speakers if dev.sex[s] == sex]
        for i, s in enumerate(group):
            out[s] = group[(i + 1) % len(group)]
    return out


def train_partners(train, targets_sex: list[str], exclude: set[str], seed: int = PARTNER_SEED,
                   min_utts: int = K_MAIN + 2) -> list[str]:
    """One UNIQUE same-sex train speaker per target (no reuse), seeded, so the
    wrong-person floors of the headline split are independent across targets
    (review invert-r5 #1). Speakers in `exclude` (the linfn cohort) and with
    fewer than `min_utts` cached utterances are not eligible."""
    rng = np.random.default_rng(seed)
    pool = {}
    for sex in ("F", "M"):
        cands = sorted((s for s in np.unique(train.y) if train.sex[s] == sex and s not in exclude
                        and int(np.sum(train.y == s)) >= min_utts), key=int)
        pool[sex] = [cands[i] for i in rng.permutation(len(cands))]
    used = {"F": 0, "M": 0}
    out = []
    for sex in targets_sex:
        if used[sex] >= len(pool[sex]):
            raise ValueError(f"not enough {sex} train speakers for unique partners")
        out.append(pool[sex][used[sex]])
        used[sex] += 1
    return out


def train_partner_rows(train, spk: str) -> tuple[np.ndarray, np.ndarray]:
    """Rows of a train partner: profile = first K_MAIN cached utterances (id
    order), audio for other-audio-10s = the rest."""
    rows = np.flatnonzero(train.y == spk)
    return rows[:K_MAIN], rows[K_MAIN:]


def pick_sources(seed: int = SOURCE_SEED) -> list[dict]:
    """5 F + 5 M train utterances of 4-8 s from distinct speakers (seeded)."""
    rows = [(r, p) for r, p in plan_rows("train") if r.is_full and 4 * SR <= r.num_samples <= 8 * SR]
    rng = np.random.default_rng(seed)
    out = []
    for sex in ("F", "M"):
        cand = [rp for rp in rows if rp[0].sex == sex]
        order = rng.permutation(len(cand))
        seen: set[str] = set()
        for i in order:
            r, p = cand[i]
            if r.speaker not in seen:
                seen.add(r.speaker)
                out.append({"utt_id": r.utt_id, "speaker": r.speaker, "sex": sex, "path": str(p),
                            "num_samples": r.num_samples})
            if len(seen) == N_SOURCES_PER_SEX:
                break
    return out


_PLAN_CACHE: dict[str, dict] = {}


def dev_audio(dev: DevSet, utt_ids, split: str = "dev") -> list[np.ndarray]:
    if split not in _PLAN_CACHE:
        _PLAN_CACHE[split] = {r.utt_id: (r, p) for r, p in plan_rows(split) if r.is_full}
    plan = _PLAN_CACHE[split]
    return [load_segment(*plan[u]) for u in utt_ids]


def first_seconds(clips: list[np.ndarray], seconds: float) -> np.ndarray:
    a = np.concatenate(clips)
    n = int(seconds * SR)
    if a.size < n:
        raise ValueError("not enough audio")
    return a[:n]


# ------------------------------------------------------------------ prepare

def fit_router(name: str, prot, suite: AttackSuite, se_k: np.ndarray, bridge, cfg: Config) -> dict:
    """Route models for one protection: direct ridge / MLP from template
    features to the se centroid of the same utterances (fit on tr, early stop on va)."""
    pp, tr, va = suite.pp, suite.tr, suite.va
    S_pp = np.stack([se_k[m].mean(0) for m in pp.members])
    F = suite.F_pp
    ridge = attacks.RidgeMSE().fit(F[tr], S_pp[tr], F[va], S_pp[va])
    mlp = attacks.MLP(0, epochs=cfg.mlp_epochs, loss="mse").fit(F[tr], S_pp[tr], F[va], S_pp[va])
    return {"direct-ridge": ridge, "direct-mlp": mlp, "S_pp": S_pp}


def route_outputs(suite: AttackSuite, router: dict, bridge, T: np.ndarray, sel_gallery: bool) -> dict:
    F = suite.prot.features(T)
    inv = suite.invert(suite.selected, T, sel_gallery=sel_gallery)
    return {"inv+bridge": bridge.invert(inv), "direct-ridge": router["direct-ridge"].invert(F),
            "direct-mlp": router["direct-mlp"].invert(F)}


def fusion_alpha(se3: np.ndarray, route_se: np.ndarray, truth: np.ndarray) -> tuple[float, dict]:
    scores = {a: attacks.mean_cos(a * se3 + (1 - a) * route_se, truth) for a in ALPHAS}
    return max(scores, key=scores.get), scores


def fuse(se3: np.ndarray, route_se: np.ndarray, alpha: float) -> np.ndarray:
    return alpha * se3 + (1 - alpha) * route_se


def prepare(embedder: str, names: list[str], cfg: Config, out: Path, log=print,
            target_splits: tuple[str, ...] = TARGET_SPLITS) -> None:
    """Fit bridge, routes and fusion weights on train (selection on held-out
    train speakers) and write every target se for each target split. Target
    splits (dev and the auxiliary clone_eval) are never fitted on."""
    from .openvoice import ToneColorConverter

    train = load_train(embedder)
    targets = {sp: load_dev(embedder, split=sp) for sp in target_splits}
    for ds in targets.values():
        if train.meta["weights_sha256"] != ds.meta["weights_sha256"]:
            raise SystemExit("caches come from different embedder weights")
    se_train, ovse_train_meta = load_ovse("train")
    se_tgt = {sp: load_ovse(sp) for sp in target_splits}
    ids = train.utt_ids
    se_tr = np.stack([se_train[u] for u in ids])  # aligned with train.X rows
    tr_spk, va_spk, sel_spk = speaker_sets(train.y, cfg.val_frac)

    # Bridge: raw centroid -> se centroid, on raw pseudo-profiles (tr/va), chosen
    # by se cosine on the selection speakers.
    raw = build("raw", PROT_SEED).fit(train.X, train.y, PROT_SEED)
    raw_suite = AttackSuite(raw, "raw", train, cfg)
    pp = raw_suite.pp
    S_pp = np.stack([se_tr[raw_suite.keep][m].mean(0) for m in pp.members])
    tr, va, sel = raw_suite.tr, raw_suite.va, raw_suite.sel
    cands = {"ridge": attacks.RidgeMSE().fit(pp.C[tr], S_pp[tr], pp.C[va], S_pp[va]),
             "mlp": attacks.MLP(0, epochs=cfg.mlp_epochs, loss="mse").fit(pp.C[tr], S_pp[tr], pp.C[va], S_pp[va])}
    bridge_sel = {k: attacks.mean_cos(b.invert(pp.C[sel]), S_pp[sel]) for k, b in cands.items()}
    bridge_name = max(bridge_sel, key=bridge_sel.get)
    bridge = cands[bridge_name]
    log(f"[{embedder}] bridge {bridge_name} sel se-cos {bridge_sel}")

    # Fusion selection set: per selection speaker, one k=10 profile from its
    # first 10 cached utterances, 3 s from the 11th, truth = se mean of the rest.
    tc = ToneColorConverter("cpu")
    plan_tr = {r.utt_id: (r, p) for r, p in plan_rows("train") if r.is_full}
    fus = []
    for s in sel_spk:
        rows = np.flatnonzero(train.y == s)
        if len(rows) < 13:
            continue
        audio = load_segment(*plan_tr[ids[rows[10]]])
        if audio.size < 3 * SR:
            continue
        fus.append({"speaker": s, "prof": rows[:10], "se3": tc.extract_se([audio[: 3 * SR]]),
                    "truth": se_tr[rows[11:]].mean(0)})
    log(f"[{embedder}] fusion selection speakers: {len(fus)}")

    result: dict = {"embedder": embedder, "bridge": bridge_name, "bridge_sel_cos": bridge_sel,
                    "target_splits": list(target_splits),
                    "speakers": {sp: ds.speakers for sp, ds in targets.items()}, "protections": {}}
    arrays: dict[str, np.ndarray] = {}
    pidx: dict[str, np.ndarray] = {}
    partner_utts: dict[str, list[np.ndarray]] = {}  # train partners: profile embeddings
    cohort = set(build("linfn", PROT_SEED).fit(train.X, train.y, PROT_SEED).cohort)
    result["partners"] = {}
    for sp, ds in targets.items():
        if sp in TRAIN_PARTNER_SPLITS:
            spk = train_partners(train, [ds.sex[s] for s in ds.speakers], cohort)
            prof = [train_partner_rows(train, x)[0] for x in spk]
            partner_utts[sp] = [train.X[r] for r in prof]
            raw_p = np.stack([l2n(l2n(e).mean(0)) for e in partner_utts[sp]])
            pidx[sp] = np.full(len(ds.speakers), -1)
            result["partners"][sp] = {
                "kind": "train", "seed": PARTNER_SEED, "speakers": spk,
                "profile_utts": [[train.utt_ids[i] for i in r] for r in prof],
                "audio_utts": [[train.utt_ids[i] for i in train_partner_rows(train, x)[1]] for x in spk]}
            arrays[f"{sp}/other-raw"] = bridge.invert(raw_p)  # floor: partner's raw profile
        else:
            part = partners(ds)
            pidx[sp] = np.array([ds.speakers.index(part[s]) for s in ds.speakers])
            result["partners"][sp] = {"kind": "internal", "speakers": [part[s] for s in ds.speakers]}
            arrays[f"{sp}/other-raw"] = bridge.invert(ds.raw_profiles(K_MAIN)[pidx[sp]])
        se_map = se_tgt[sp][0]
        arrays[f"{sp}/se-centroid"] = np.stack([np.mean([se_map[u] for u in ds.roles[s].E[:K_MAIN]], axis=0)
                                                for s in ds.speakers])
    for name in names:
        t0 = time.time()
        prot = build(name, PROT_SEED).fit(train.X, train.y, PROT_SEED)
        suite = raw_suite if name == "raw" else AttackSuite(prot, name, train, cfg)
        router = fit_router(name, prot, suite, se_tr[suite.keep], bridge, cfg)
        # fusion weights on held-out train speakers (their own templates); a
        # cohort speaker is never a pseudo-user of the protection using it
        fus_p = [f for f in fus if f["speaker"] not in set(getattr(prot, "cohort", []))]
        T_f = templates(prot, [train.X[f["prof"]] for f in fus_p], 98)
        outs_f = route_outputs(suite, router, bridge, T_f, sel_gallery=True)
        se3_f = np.stack([f["se3"] for f in fus_p])
        truth_f = np.stack([f["truth"] for f in fus_p])
        info = {"selected_attacker": suite.selected, "sel_cos": suite.sel_cos, "fusion": {}}
        for route in ROUTES:
            a, sc = fusion_alpha(se3_f, outs_f[route], truth_f)
            info["fusion"][route] = {"alpha": a, "sel_cos_by_alpha": sc,
                                     "route_sel_se_cos": attacks.mean_cos(outs_f[route], truth_f)}
        for sp, ds in targets.items():
            T_t = templates(prot, ds.profile_utts(K_MAIN), K_MAIN)
            outs = route_outputs(suite, router, bridge, T_t, sel_gallery=False)
            if sp in partner_utts:  # same routes on the train partners' own templates
                outs_o = route_outputs(suite, router, bridge, templates(prot, partner_utts[sp], 97),
                                       sel_gallery=False)
            for route, val in outs.items():
                arrays[f"{sp}/{name}|{route}"] = val
                arrays[f"{sp}/{name}|{route}|other"] = (outs_o[route] if sp in partner_utts
                                                        else val[pidx[sp]])  # partner's template
        info["seconds"] = time.time() - t0
        result["protections"][name] = info
        log(f"[{embedder}] {name}: selected {suite.selected}, "
            f"alphas {[info['fusion'][r]['alpha'] for r in ROUTES]} ({info['seconds']:.0f}s)")
    out.mkdir(parents=True, exist_ok=True)
    np.savez(out / f"prepare-{embedder}.npz", **{k: v.astype(np.float32) for k, v in arrays.items()})
    gens = {"emb_train": train.meta["generation"], "ovse_train": ovse_train_meta["generation"]}
    for sp, ds in targets.items():
        gens[f"emb_{sp}"] = ds.meta["generation"]
        gens[f"ovse_{sp}"] = se_tgt[sp][1]["generation"]
    result.update({"git_commit": git_commit(), "command": " ".join(sys.argv), "config": cfg.__dict__,
                   "train_meta": train.meta, "target_meta": {sp: ds.meta for sp, ds in targets.items()},
                   "ovse_train_meta": ovse_train_meta,
                   "ovse_target_meta": {sp: se_tgt[sp][1] for sp in target_splits},
                   "generations": gens})
    (out / f"prepare-{embedder}.json").write_text(json.dumps(result, indent=2, default=list) + "\n")


# ------------------------------------------------------------------ synth

def conditions(prepared: dict[str, tuple[dict, dict]]) -> list[tuple[str, str, str | None]]:
    """(condition id, kind, alias). Audio conditions and se-centroid once
    (embedder-independent); profile conditions per embedder: each route, its
    route-matched wrong-person control (`|other`), and the fusion with 3 s of
    audio. A fusion with weight 1 is `audio-3s` and with weight 0 the route
    itself: those are aliases (no synthesis; identical by shared seeds)."""
    out: list[tuple[str, str, str | None]] = [
        ("audio-10s", "audio", None), ("audio-3s", "audio", None), ("other-audio-10s", "audio", None),
        ("source", "source", None), ("se-centroid", "se-global", None)]
    for emb, (info, arrays) in prepared.items():
        out.append((f"{emb}/other-raw", "se", None))
        for name, pinfo in info["protections"].items():
            for route in ROUTES:
                out.append((f"{emb}/{name}|{route}", "se", None))
                out.append((f"{emb}/{name}|{route}|other", "se", None))
                alpha = pinfo["fusion"][route]["alpha"]
                alias = "audio-3s" if alpha == 1.0 else f"{emb}/{name}|{route}" if alpha == 0.0 else None
                out.append((f"{emb}/audio-3s+{name}|{route}", "fused", alias))
    return out


def attempt_seed(i: int, j: int, d: int, set_code: int = 0) -> int:
    """One seed per (target split, target, source, attempt), shared by every
    condition, so equivalent conditions give identical conversions (review
    clone-r1 #7). set_code 0 = dev keeps dev's seeds unchanged."""
    key = [SOURCE_SEED, i, j, d] if set_code == 0 else [SOURCE_SEED, i, j, d, set_code]
    return int(np.random.SeedSequence(key).generate_state(1)[0])


def synth(embedders: list[str], out: Path, log=print, provenance: dict | None = None,
          limit_targets: int | None = None) -> None:
    """Synthesise and score every condition for every target split. Writes
    scores-<split>.npz per split. Real verifier trials are kept for every split;
    only dev's are used for thresholds (stats)."""
    import torch

    from ..embed.embedder import load_embedder
    from .openvoice import ToneColorConverter

    if torch.cuda.is_available() and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    device = "cuda" if torch.cuda.is_available() else "cpu"
    prepared = {}
    for emb in embedders:
        info = json.loads((out / f"prepare-{emb}.json").read_text())
        prepared[emb] = (info, dict(np.load(out / f"prepare-{emb}.npz")))
    first = prepared[embedders[0]][0]
    splits_ = tuple(first["target_splits"])
    targets = {sp: load_dev(embedders[0], generation=first["generations"][f"emb_{sp}"], split=sp) for sp in splits_}
    for emb, (info, arrays) in prepared.items():
        if tuple(info["target_splits"]) != splits_:
            raise SystemExit("target splits differ between prepare runs")
        for sp, ds in targets.items():
            if info["speakers"][sp] != ds.speakers:
                raise SystemExit("speaker order differs between prepare and synth")
            if not np.allclose(arrays[f"{sp}/se-centroid"], prepared[embedders[0]][1][f"{sp}/se-centroid"], atol=1e-4):
                raise SystemExit("se-centroid differs between embedders' prepare runs")
    tc = ToneColorConverter(device)
    verifiers = {v: load_embedder(v, device) for v in VERIFIERS}
    sources = pick_sources()
    src_audio = [load_segment(embcache.Row(s["utt_id"], s["speaker"], "", s["sex"], -1, -1, s["num_samples"]),
                              Path(s["path"])) for s in sources]
    src_se = [tc.extract_se([a]) for a in src_audio]
    src_by_sex = {sex: [j for j, s in enumerate(sources) if s["sex"] == sex] for sex in ("F", "M")}
    conds = conditions(prepared)
    index = {c: k for k, (c, _, _) in enumerate(conds)}
    t0 = time.time()
    for set_code, (sp, ds) in enumerate(targets.items()):
        n = len(ds.speakers)
        pinfo = first["partners"][sp]
        # Smoke runs synthesise only the first few targets (indices stay
        # aligned with the prepared arrays); "needed" adds their in-split partners.
        active = list(range(min(limit_targets, n))) if limit_targets else list(range(n))
        needed = sorted(set(active) | ({ds.speakers.index(pinfo["speakers"][i]) for i in active}
                                       if pinfo["kind"] != "train" else set()))
        se3, se10 = np.zeros((n, 256)), np.zeros((n, 256))
        ref = {v: np.zeros((n, verifiers[v].dim)) for v in VERIFIERS}
        for i in needed:
            s = ds.speakers[i]
            a = dev_audio(ds, ds.roles[s].A, sp)
            se3[i] = tc.extract_se([first_seconds(a, 3.0)])
            se10[i] = tc.extract_se([first_seconds(a, 10.0)])
            r_audio = dev_audio(ds, ds.roles[s].R, sp)
            for v in VERIFIERS:
                ref[v][i] = l2n(verifiers[v].embed_batch(r_audio).mean(0))
        for emb, (info, _) in prepared.items():
            if info["partners"][sp] != pinfo:
                raise SystemExit("partners differ between embedders' prepare runs")
        if pinfo["kind"] == "train":
            pidx = np.full(n, -1)
            other10 = np.zeros((n, 256))
            for i in active:
                other10[i] = tc.extract_se([first_seconds(dev_audio(ds, pinfo["audio_utts"][i], "train"), 10.0)])
        else:
            pidx = np.array([ds.speakers.index(x) for x in pinfo["speakers"]])
            other10 = se10  # filled above; indexed by pidx below

        def target_se(cond: str, kind: str, i: int) -> np.ndarray:
            if cond == "audio-10s":
                return se10[i]
            if cond == "audio-3s":
                return se3[i]
            if cond == "other-audio-10s":
                return other10[i] if pidx[i] < 0 else se10[pidx[i]]
            if kind == "se-global":
                return prepared[embedders[0]][1][f"{sp}/se-centroid"][i]
            emb, rest = cond.split("/", 1)
            info, arrays = prepared[emb]
            if kind == "se":
                return arrays[f"{sp}/{rest}"][i]
            name_route = rest[len("audio-3s+"):]
            name, route = name_route.split("|")
            alpha = info["protections"][name]["fusion"][route]["alpha"]
            return fuse(se3[i], arrays[f"{sp}/{name_route}"][i], alpha)

        scores = {v: np.zeros((len(conds), n, N_ATTEMPTS), dtype=np.float32) for v in VERIFIERS}
        for c, (cond, kind, alias) in enumerate(conds):
            if alias is not None:  # identical conversions by construction: reuse
                for v in VERIFIERS:
                    scores[v][c] = scores[v][index[alias]]
                continue
            for i in active:
                s = ds.speakers[i]
                clips = []
                for j in src_by_sex[ds.sex[s]]:
                    for d in range(DRAWS_PER_SOURCE):
                        if kind == "source":
                            clips.append(src_audio[j])
                        else:
                            torch.manual_seed(attempt_seed(i, j, d, set_code))
                            clips.append(tc.convert(src_audio[j], src_se[j], target_se(cond, kind, i)))
                for v in VERIFIERS:
                    scores[v][c, i] = l2n(verifiers[v].embed_batch(clips)) @ ref[v][i]
                del clips  # synthesised audio never leaves memory
            log(f"[{sp} {c + 1}/{len(conds)}] {cond} ({time.time() - t0:.0f}s)")

        # Real trials: R centroid of target i vs each T utterance of j. Only
        # dev's set the thresholds; clone_eval's are context.
        t_emb = {v: {} for v in VERIFIERS}
        for j in needed:
            t_audio = dev_audio(ds, ds.roles[ds.speakers[j]].T, sp)
            for v in VERIFIERS:
                t_emb[v][j] = l2n(verifiers[v].embed_batch(t_audio))
        real = {}
        nd = np.array(needed)
        for v in VERIFIERS:
            own, oth, sc = [], [], []
            for j in needed:
                S = ref[v][nd] @ t_emb[v][j].T  # [|needed|, |T_j|]
                own.append(np.repeat(nd, S.shape[1]))
                oth.append(np.full(S.size, j))
                sc.append(S.ravel())
            real[v] = (np.concatenate(own), np.concatenate(oth), np.concatenate(sc))
        np.savez(out / f"scores-{sp}.npz", conds=np.array([c for c, _, _ in conds]),
                 kinds=np.array([k for _, k, _ in conds]), aliases=np.array([a or "" for _, _, a in conds]),
                 speakers=np.array(ds.speakers), partner=pidx,
                 partner_speakers=np.array(pinfo["speakers"]),
                 selection_commit=np.array((provenance or {}).get("selection_commit", "")),
                 **{f"scores_{v}": scores[v] for v in VERIFIERS},
                 **{f"real_owner_{v}": real[v][0] for v in VERIFIERS},
                 **{f"real_other_{v}": real[v][1] for v in VERIFIERS},
                 **{f"real_score_{v}": real[v][2] for v in VERIFIERS})
    (out / "synth.json").write_text(json.dumps({
        "sources": sources, "embedders": embedders, "verifiers": VERIFIERS, "target_splits": list(splits_),
        "verifier_weights": {v: verifiers[v].weights_sha256 for v in VERIFIERS},
        "generations": {e: prepared[e][0]["generations"] for e in embedders},
        "provenance": provenance,
        "git_commit": git_commit(), "command": " ".join(sys.argv), "seconds": time.time() - t0,
    }, indent=2) + "\n")


# ------------------------------------------------------------------ stats

def per_speaker_accept(S: np.ndarray, thr: float) -> np.ndarray:
    """S [n, attempts] scores of one condition -> per-target acceptance fraction."""
    return (S >= thr).mean(axis=1)


def success_within(S: np.ndarray, thr: float, k: int) -> np.ndarray:
    """Per target, the probability that at least one of k attempts drawn without
    replacement from the recorded ones is accepted: 1 - C(m - a, k) / C(m, k)
    = 1 - prod_{t<k} (m - a - t) / (m - t)."""
    m = S.shape[1]
    if not 1 <= k <= m:
        raise ValueError("need 1 <= k <= attempts")
    a = (S >= thr).sum(axis=1).astype(np.float64)
    t = np.arange(k, dtype=np.float64)
    ratio = np.clip((m - a[:, None] - t) / (m - t), 0.0, None)
    return 1.0 - ratio.prod(axis=1)


def weighted_mean(x: np.ndarray, w: np.ndarray) -> float:
    return float(np.sum(w * x) / np.sum(w))


def worst_decile(x: np.ndarray, w: np.ndarray, frac: float = 0.1) -> float:
    """Mean of the worst `frac` of the (weighted) population: per-target values
    x with integer multiplicities w form an expanded sample of W = sum(w)
    draws; take its k = ceil(frac W) largest values, consuming only the weight
    still needed at the boundary (reviews invert-r3 #3, clone-r1 #3). The point
    estimate (all w = 1, 73 targets) uses the worst 8."""
    w = np.asarray(w, dtype=np.float64)
    keep = w > 0
    x, w = np.asarray(x, dtype=np.float64)[keep], w[keep]
    k = math.ceil(frac * w.sum() - 1e-9)
    order = np.argsort(-x, kind="stable")
    take = np.minimum(w[order], np.maximum(k - np.concatenate([[0.0], np.cumsum(w[order])[:-1]]), 0.0))
    return float(np.sum(take * x[order]) / k)


def resolution_table(ns=(73, 251), levels=(0.0, 0.01, 0.05, 0.10, 0.30)) -> dict:
    """Delta_upper in the constant zero-excess cases (a_i = f_i = level for
    every target), computed by the implementation and rounded UP to 3
    decimals: the table printed in DESIGN section 3."""
    return {n: {lv: math.ceil(metrics.delta_upper(np.full(n, lv), np.full(n, lv)) * 1000 - 1e-9) / 1000
                for lv in levels} for n in ns}


def tier(upper: float) -> str:
    for bound, label in TIERS:
        if upper <= bound:
            return label
    return TIERS[-1][1]


INSUFFICIENT = "insufficient power"


def _rates(S: np.ndarray, rows, thr: float) -> np.ndarray:
    """Per-target acceptance rates of the largest-rate condition among rows."""
    return (S[rows] >= thr).mean(axis=2).max(axis=0)


def risk_bounds(a: np.ndarray, f_primary: np.ndarray, f_matched: np.ndarray) -> dict:
    """Betting bounds (Waudby-Smith & Ramdas 2023) on mean excess acceptance,
    one value per target (rows in the pre-registered order)."""
    return {"n": int(a.size), "mean_a": float(a.mean()), "mean_floor": float(f_primary.mean()),
            "upper_a": metrics.wsr_upper_mean(a, WSR_ALPHA / 2),
            "vs_primary": metrics.delta_upper(a, f_primary, WSR_ALPHA),
            "vs_matched": metrics.delta_upper(a, f_matched, WSR_ALPHA),
            "lower_vs_primary": metrics.delta_lower(a, f_primary, WSR_ALPHA)}


def set_stats(z, n_boot: int, seed: int, fixed_thr: dict | None = None) -> tuple[dict, dict]:
    """Descriptive statistics for one target split, plus per-target rates at
    the point threshold for the betting bounds.

    Thresholds: from the split's own real trials, recomputed in each
    joint-bootstrap draw (dev); or, with fixed_thr {verifier: {far: t}}, fixed
    at dev's point thresholds for every draw (clone_eval: nothing is calibrated
    on it). Every clip counts with the multiplicity of the speakers it involves
    (the target, and the partner for wrong-person controls); envelopes take the
    maximum over attack routes. Draw 0 is the point estimate."""
    conds = [str(c) for c in z["conds"]]
    speakers = [str(s) for s in z["speakers"]]
    n = len(speakers)
    pidx = z["partner"]
    order = metrics.target_order(speakers, ORDER_SEED)
    idx = {c: i for i, c in enumerate(conds)}
    floor_cond = {c.split("/")[0]: c for c in conds if c.endswith("/other-raw")}
    rng = np.random.default_rng(seed)
    draws = [np.ones(n, dtype=int)] + [np.bincount(rng.integers(0, n, n), minlength=n) for _ in range(n_boot)]
    metrics_names = ["accept"] + [f"within{k}" for k in KS_ATTEMPTS] + ["worst_decile"]

    def is_wrong_person(cond: str) -> bool:
        return cond.endswith("|other") or cond.endswith("other-raw") or cond == "other-audio-10s"

    def ci(x):
        return {"mean": float(x[0]), "lo": float(np.quantile(x[1:], 0.025)), "hi": float(np.quantile(x[1:], 0.975))}

    res: dict = {"n_targets": n, "thresholds_from": "own real trials" if fixed_thr is None else "dev (fixed)",
                 "verifiers": {}}
    per_target: dict = {}
    for v in VERIFIERS:
        S = z[f"scores_{v}"]
        own, oth, sc = z[f"real_owner_{v}"], z[f"real_other_{v}"], z[f"real_score_{v}"]
        tgt = own == oth
        vals = {f: {m: np.zeros((len(draws), len(conds))) for m in metrics_names} for f in FARS}
        thr_log = {f: np.zeros(len(draws)) for f in FARS}
        for b, m in enumerate(draws):
            if fixed_thr is None:
                w_real = metrics.joint_multiplicity_weights(own, oth, m)
            for f in FARS:
                thr = (metrics.threshold_at_far(sc[~tgt], f, w_real[~tgt]) if fixed_thr is None
                       else fixed_thr[v][f])
                thr_log[f][b] = thr
                for c, cond in enumerate(conds):
                    # internal partners are resampled with the targets; external
                    # (train) partners are fixed, so only the target's count applies
                    w = (m * np.where(pidx >= 0, m[np.maximum(pidx, 0)], 1)
                         if is_wrong_person(cond) else m).astype(np.float64)
                    if w.sum() == 0:
                        continue
                    acc = per_speaker_accept(S[c], thr)
                    vals[f]["accept"][b, c] = weighted_mean(acc, w)
                    vals[f]["worst_decile"][b, c] = worst_decile(acc, w)
                    for k in KS_ATTEMPTS:
                        vals[f][f"within{k}"][b, c] = weighted_mean(success_within(S[c], thr, k), w)
        own_eer = metrics.eer(sc, tgt)[0]
        out_v: dict = {"thresholds": {str(f): ci(thr_log[f]) for f in FARS}, "real_trials_eer": own_eer,
                       "real_trials_far_at_threshold": {str(f): float(np.mean(sc[~tgt] >= thr_log[f][0]))
                                                       for f in FARS},
                       "conditions": {}, "protections": {}}
        for c, cond in enumerate(conds):
            out_v["conditions"][cond] = {
                f"far{f:g}": {mn: ci(vals[f][mn][:, c]) for mn in metrics_names} for f in FARS}
            out_v["conditions"][cond]["mean_score"] = float(S[c].mean())
        thr_point = thr_log[FAR][0]
        thr_lo = float(np.quantile(thr_log[FAR][1:], 0.025)) if len(draws) > 1 else thr_point
        per_target[v] = {}
        for emb, fl in floor_cond.items():
            names = sorted({c.split("/", 1)[1].split("|")[0] for c in conds
                            if c.startswith(emb + "/") and "|" in c and "audio-3s+" not in c})
            for name in names:
                routes = [idx[f"{emb}/{name}|{r}"] for r in ROUTES]
                matched = [idx[f"{emb}/{name}|{r}|other"] for r in ROUTES]
                fused = [idx[f"{emb}/audio-3s+{name}|{r}"] for r in ROUTES]
                entry: dict = {}
                for f in FARS:
                    e: dict = {}
                    for mn in metrics_names:
                        env = vals[f][mn][:, routes].max(axis=1)
                        e[mn] = {"envelope": ci(env), "delta_vs_floor": ci(env - vals[f][mn][:, idx[fl]]),
                                 "delta_vs_matched": ci((vals[f][mn][:, routes] - vals[f][mn][:, matched]).max(axis=1))}
                    acc = vals[f]["accept"]
                    e["per_route_delta"] = {r: ci(acc[:, idx[f"{emb}/{name}|{r}"]] - acc[:, idx[fl]]) for r in ROUTES}
                    e["per_route_delta_matched"] = {
                        r: ci(acc[:, idx[f"{emb}/{name}|{r}"]] - acc[:, idx[f"{emb}/{name}|{r}|other"]])
                        for r in ROUTES}
                    e["marginal_over_audio3"] = ci(acc[:, fused].max(axis=1) - acc[:, idx["audio-3s"]])
                    entry[f"far{f:g}"] = e
                rates = {"speakers": speakers, "a": _rates(S, routes, thr_point),
                         "f_primary": (S[idx[fl]] >= thr_point).mean(axis=1),
                         "f_matched": _rates(S, matched, thr_point)}
                per_target[v][f"{emb}/{name}"] = rates
                o = order  # pre-registered seeded permutation of targets
                entry["wsr"] = {"point": risk_bounds(rates["a"][o], rates["f_primary"][o], rates["f_matched"][o])}
                if fixed_thr is None:  # descriptive sensitivity to the threshold's sampling
                    entry["wsr"]["threshold_q025"] = risk_bounds(
                        _rates(S, routes, thr_lo)[o], (S[idx[fl]] >= thr_lo).mean(axis=1)[o],
                        _rates(S, matched, thr_lo)[o])
                # Descriptive only: prevalence of targets with some route accepted
                # in >= VULN_CUT of attempts, and any-success counts.
                vuln = ((S[routes] >= thr_point).mean(axis=2) >= VULN_CUT).any(axis=0)
                floor_vuln = (S[idx[fl]] >= thr_point).mean(axis=1) >= VULN_CUT
                d = entry[f"far{FAR:g}"]["accept"]["delta_vs_floor"]
                entry["vulnerable"] = {
                    "targets": int(vuln.sum()), "n": n, "cut": VULN_CUT,
                    "cp_upper": metrics.clopper_pearson_upper(int(vuln.sum()), n),
                    "floor_targets": int(floor_vuln.sum()),
                    "any_success_targets": int((S[routes] >= thr_point).any(axis=(0, 2)).sum()),
                    "floor_any_success_targets": int((S[idx[fl]] >= thr_point).any(axis=1).sum())}
                entry["bootstrap_fails_clearly"] = d["lo"] > DELTA  # descriptive
                out_v["protections"][f"{emb}/{name}"] = entry
        res["verifiers"][v] = out_v
    return res, per_target


def assign_tiers(entries: dict, per_target: dict) -> dict:
    """Tier per verifier and protection from the betting bound at the point
    threshold, gated on raw's power check (betting lower bound of raw's excess
    over the primary floor > DELTA, per embedder and verifier); then the
    aggregate per protection: worst tier among powered verifiers, coverage
    disclosed. `entries[v][p]` receives the fields; returns the aggregate."""
    order = [label for _, label in TIERS]
    for v in VERIFIERS:
        for p, e in entries[v].items():
            b = e["wsr"]["point"]
            e["risk_upper"] = max(b["vs_primary"], b["vs_matched"])
            e["tier_ungated"] = tier(e["risk_upper"])
        for p, e in entries[v].items():
            emb = p.split("/")[0]
            raw = entries[v].get(f"{emb}/raw")
            powered = bool(raw is not None and raw["wsr"]["point"]["lower_vs_primary"] > DELTA)
            e["powered"] = powered
            e["tier"] = e["tier_ungated"] if powered else INSUFFICIENT  # raw too (clone-r2 #1)
    agg = {}
    for p in entries[VERIFIERS[0]]:
        powered_v = [v for v in VERIFIERS if entries[v][p]["tier"] != INSUFFICIENT]
        tiers = [entries[v][p]["tier"] for v in powered_v]
        agg[p] = {"tier": max(tiers, key=order.index) if tiers else INSUFFICIENT,
                  "coverage": f"{len(powered_v)} of {len(VERIFIERS)} verifiers powered",
                  "powered_verifiers": powered_v,
                  "risk_upper_by_verifier": {v: entries[v][p]["risk_upper"] for v in VERIFIERS},
                  # conservative companion: bound on mean acceptance with no floor subtracted
                  "upper_a_by_verifier": {v: entries[v][p]["wsr"]["point"]["upper_a"] for v in VERIFIERS},
                  "ungated_by_verifier": {v: entries[v][p]["tier_ungated"] for v in VERIFIERS}}
    return agg


def stats(out: Path, n_boot: int = 1000, seed: int = 7311, ledger: Path | None = None) -> dict:
    """Per target split.

    Headline (owner decision after review invert-r5): the tier on clone_eval
    alone (251 targets), whose FAR-1 % thresholds come from dev (independent
    calibration speakers) and whose floors use unique train partners
    (independent across targets). dev's tiers are exploratory: its thresholds
    are calibrated on the same speakers and its floors share partners."""
    split_files = {sp: out / f"scores-{sp}.npz" for sp in TARGET_SPLITS if (out / f"scores-{sp}.npz").exists()}
    if "dev" not in split_files:
        raise FileNotFoundError("scores-dev.npz is required (it calibrates the thresholds)")
    res: dict = {"fars": FARS, "tiers": TIERS, "power_delta": DELTA, "wsr_alpha": WSR_ALPHA,
                 "order_seed": ORDER_SEED, "attempts": N_ATTEMPTS, "splits": {}}
    dev_res, _ = set_stats(np.load(split_files["dev"]), n_boot, seed)
    dev_res["status"] = "exploratory (thresholds calibrated on the same speakers; shared partners)"
    res["splits"]["dev"] = dev_res
    fixed = {v: {f: dev_res["verifiers"][v]["thresholds"][str(f)]["mean"] for f in FARS} for v in VERIFIERS}
    for sp in split_files:
        if sp == "dev":
            continue
        r, _ = set_stats(np.load(split_files[sp]), n_boot, seed + 1, fixed_thr=fixed)
        r["status"] = "headline" if sp == HEADLINE_SPLIT else "secondary"
        res["splits"][sp] = r
    for sp, r in res["splits"].items():
        r["tiers_by_protection"] = assign_tiers({v: r["verifiers"][v]["protections"] for v in VERIFIERS}, None)
        far = {v: r["verifiers"][v]["real_trials_far_at_threshold"][str(FAR)] for v in VERIFIERS}
        for agg in r["tiers_by_protection"].values():
            agg["achieved_far_by_verifier"] = far
            baseline = ("excess over the training-speaker baseline" if sp in TRAIN_PARTNER_SPLITS
                        else "excess over the within-split partner baseline (exploratory)")
            agg["estimand"] = baseline
            agg["label"] = (baseline + ", at the dev-calibrated nominal 1 % FAR threshold; achieved " + sp
                            + " FAR = " + ", ".join(f"{v} {far[v]:.4f}" for v in VERIFIERS))
    ledger = LEDGER if ledger is None else ledger  # one experiment ledger
    res["ledger"] = ([json.loads(x) for x in ledger.read_text().splitlines() if x.strip()]
                     if ledger.exists() else [])
    res["new_preregistrations"] = [e for e in res["ledger"] if e.get("new_preregistration")]
    res["headline"] = HEADLINE_SPLIT if HEADLINE_SPLIT in res["splits"] else None
    res["tiers_by_protection"] = (res["splits"][HEADLINE_SPLIT]["tiers_by_protection"]
                                  if res["headline"] else None)
    (out / "results.json").write_text(json.dumps(res, indent=2) + "\n")
    return res


SECONDS_PER_CLIP = 0.026  # measured 2026-10-21: conversion 0.019 s + both verifiers 0.007 s
REPO = Path(__file__).resolve().parents[2]
SELECTION_LOG = REPO / "lfspk" / "protect" / "selection.json"  # committed before any synth


def parse_names(text: str) -> list[str]:
    """Strict protection list for one embedder (review clone-r3 #2): non-empty,
    no empty items, no duplicates, known names; 'raw' alone means raw only."""
    from .transforms import build

    items = text.split(",")
    if not text or any(not x.strip() or x != x.strip() for x in items):
        raise ValueError(f"empty or padded protection name in {text!r}")
    if len(set(items)) != len(items):
        raise ValueError(f"duplicate protection in {text!r}")
    if "raw" in items and len(items) > 1:
        raise ValueError("raw is always included; list it only for a raw-only run")
    for x in items:
        build(x, PROT_SEED)  # raises ValueError for unknown names
    return items


def parse_selection(text: str, embedders: list[str]) -> dict[str, set[str]]:
    """'emb:a,b;emb2:raw' -> {emb: {a, b}, emb2: set()} (raw implied). Every
    requested embedder must appear exactly once and nothing else."""
    out: dict[str, set[str]] = {}
    if not text:
        raise ValueError("empty selection")
    for part in text.split(";"):
        if ":" not in part:
            raise ValueError(f"selection entry without embedder: {part!r}")
        emb, names = part.split(":", 1)
        if emb in out:
            raise ValueError(f"embedder listed twice: {emb}")
        out[emb] = set(parse_names(names)) - {"raw"}
    if set(out) != set(embedders):
        raise ValueError(f"selection embedders {sorted(out)} differ from {sorted(embedders)}")
    return out


def _sha256_file(path: Path) -> str:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


def plan(embedders: list[str], out: Path) -> dict:
    """Non-aliased conditions, clips and expected GPU hours for the prepared
    selections, bound to the exact prepared files by their SHA-256 (for the
    committed selection log, before any synthesis)."""
    prepared = {e: (json.loads((out / f"prepare-{e}.json").read_text()), {}) for e in embedders}
    conds = conditions(prepared)
    synthesised = [c for c, k, a in conds if a is None and k != "source"]
    n_targets = {sp: len(v) for sp, v in prepared[embedders[0]][0]["speakers"].items()}
    clips = len(synthesised) * sum(n_targets.values()) * N_ATTEMPTS
    return {"protections": {e: sorted(prepared[e][0]["protections"]) for e in embedders},
            "targets": n_targets,
            "conditions": len(conds), "aliases": sum(1 for _, _, a in conds if a),
            "synthesised_conditions": len(synthesised), "clips": clips,
            "expected_gpu_hours": clips * SECONDS_PER_CLIP / 3600,
            "prepared_sha256": {e: {"json": _sha256_file(out / f"prepare-{e}.json"),
                                    "npz": _sha256_file(out / f"prepare-{e}.npz")} for e in embedders}}


def plan_sha256(p: dict) -> str:
    import hashlib

    return hashlib.sha256(json.dumps(p, sort_keys=True).encode()).hexdigest()


INVERT_ROOT = paths.RUNS / "W4" / "invert"
BUDGET_EER_REL = 1.15  # DESIGN 6.2: primary EER at most 15 % relative above raw
BUDGET_DCF_ABS = 0.02  # and minDCF at most 0.02 above raw
LEDGER = OUT / "ledger.jsonl"  # append-only record of every synthesis start


def selection_evidence(embedders: list[str], protections: dict[str, list[str]],
                       invert_root: Path = INVERT_ROOT) -> dict:
    """The utility and inversion numbers behind the selection: per embedder,
    the invert summary.tsv rows of every candidate (the whole grid, so the
    unselected ones are on record too) and the file's SHA-256."""
    ev = {}
    for e in embedders:
        f = invert_root / e / "summary.tsv"
        lines = f.read_text().splitlines()
        cols = lines[0].split("\t")
        rows = [dict(zip(cols, ln.split("\t"))) for ln in lines[1:]]
        by_name = {r["protection"]: r for r in rows}
        if "raw" not in by_name:
            raise ValueError(f"{e}: no raw row, so the utility budget cannot be checked")

        def exact(name: str) -> tuple[float, float, str]:
            """Full-precision primary EER and minDCF from <name>.json (the
            summary.tsv rows are rounded and kept for reporting only)."""
            jf = invert_root / e / f"{name}.json"
            u = json.loads(jf.read_text())["utility"]["k10_crop"]["all"]
            return float(u["eer"]), float(u["mindcf"]), _sha256_file(jf)

        raw_eer, raw_dcf, _ = exact("raw")
        for r in rows:  # utility budget (DESIGN 6.2) next to the inversion numbers
            eer, dcf, sha = exact(r["protection"])
            r["eer_exact"], r["mindcf_exact"], r["result_json_sha256"] = eer, dcf, sha
            r["eer_rel_to_raw"] = eer / raw_eer - 1.0 if raw_eer > 0 else float("inf")
            r["mindcf_minus_raw"] = dcf - raw_dcf
            r["within_utility_budget"] = bool(eer <= BUDGET_EER_REL * raw_eer and dcf <= raw_dcf + BUDGET_DCF_ABS)
        missing = set(protections[e]) - set(by_name)
        if missing:
            raise ValueError(f"{e}: selected protections without inversion results: {sorted(missing)}")
        outside = [x for x in protections[e] if x != "raw" and not by_name[x]["within_utility_budget"]]
        if outside:
            raise ValueError(f"{e}: selected protections outside the utility budget: {outside}")
        ev[e] = {"summary_tsv": str(f), "sha256": _sha256_file(f), "rows": rows,
                 "selected": protections[e],
                 "budget": {"eer_rel_max": BUDGET_EER_REL, "mindcf_abs_max": BUDGET_DCF_ABS,
                            "raw_eer_crop_k10": raw_eer, "raw_mindcf": raw_dcf}}
    return ev


def write_selection_log(embedders: list[str], out: Path, rationale: str, path: Path = SELECTION_LOG,
                        invert_root: Path = INVERT_ROOT) -> dict:
    """Write the selection log (plan + its hash, the inversion/utility evidence
    and the rationale). It must then be committed before `synth` will run."""
    if not rationale or not rationale.strip():
        raise ValueError("the selection log needs a rationale")
    p = plan(embedders, out)
    log = {"plan": p, "plan_sha256": plan_sha256(p), "rationale": rationale,
           "evidence": selection_evidence(embedders, p["protections"], invert_root)}
    path.write_text(json.dumps(log, indent=2, sort_keys=True) + "\n")
    return log


def check_selection_log(embedders: list[str], want: dict[str, set[str]], out: Path,
                        path: Path = SELECTION_LOG, repo: Path = REPO, max_gpu_hours: float = 8.0) -> dict:
    """Refuse synthesis unless the selection log is tracked by git, unmodified
    against HEAD, and records the plan of exactly these prepared files and
    this selection (review clone-r3 #1)."""
    import subprocess

    rel = str(path.resolve().relative_to(repo.resolve()))
    git = lambda *a: subprocess.run(["git", *a], cwd=repo, capture_output=True, text=True)
    if git("ls-files", "--error-unmatch", "--", rel).returncode != 0:
        raise SystemExit(f"{rel} is not tracked by git: commit the selection log first")
    if git("cat-file", "-e", f"HEAD:{rel}").returncode != 0:
        raise SystemExit(f"{rel} is not in HEAD: commit it first")
    if git("diff", "--quiet", "HEAD", "--", rel).returncode != 0:
        raise SystemExit(f"{rel} differs from HEAD")
    existing = sorted(str(x.name) for x in out.glob("scores-*.npz"))
    if existing:
        raise SystemExit(f"score files already exist in {out}: {existing}; synthesis runs once per logged plan")
    log = json.loads(path.read_text())
    if not log.get("evidence"):
        raise SystemExit("the selection log records no inversion/utility evidence")
    fresh = plan(embedders, out)
    if plan_sha256(fresh) != log.get("plan_sha256") or plan_sha256(log.get("plan", {})) != log.get("plan_sha256"):
        raise SystemExit("the committed plan does not match the prepared files")
    for emb in embedders:
        if set(fresh["protections"][emb]) != {"raw"} | want[emb]:
            raise SystemExit(f"{emb}: prepared protections {fresh['protections'][emb]} differ from --only")
    if fresh["expected_gpu_hours"] > max_gpu_hours:
        raise SystemExit(f"plan needs {fresh['expected_gpu_hours']:.2f} GPU-hours > limit {max_gpu_hours}")
    commit = git("log", "-1", "--format=%H", "--", rel).stdout.strip()
    return {"selection_commit": commit, "plan_sha256": log["plan_sha256"],
            "expected_gpu_hours": fresh["expected_gpu_hours"]}


def record_synthesis_start(gate: dict, new_preregistration: str | None, ledger: Path = LEDGER) -> dict:
    """Append-only ledger of synthesis starts (review clone-r4 #1). A start
    whose selection-log commit differs from the FIRST entry's is refused unless
    an explicit new pre-registration reason is given; that reason is recorded
    and reported by stats."""
    import datetime as dt

    entries = [json.loads(x) for x in ledger.read_text().splitlines() if x.strip()] if ledger.exists() else []
    if entries and entries[0]["selection_commit"] != gate["selection_commit"]:
        if not (new_preregistration and new_preregistration.strip()):
            raise SystemExit(f"the first synthesis used selection log {entries[0]['selection_commit']}; "
                             "a different one needs --new-preregistration \"<reason>\"")
    entry = {**gate, "new_preregistration": new_preregistration or None, "command": " ".join(sys.argv),
             "started": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")}
    ledger.parent.mkdir(parents=True, exist_ok=True)
    with open(ledger, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")
    return entry


def run_synth(embedders: list[str], only: str, out: Path, max_gpu_hours: float, new_preregistration: str | None,
              smoke: bool, canonical: Path = OUT, ledger: Path = LEDGER,
              gate_fn=None, synth_fn=None) -> dict | None:
    """The only entry point to synthesis (review clone-r5 #1).

    Real runs must write to the canonical run directory and always consult and
    append the ONE experiment ledger, whatever --out says. Smoke runs must use
    another directory, skip the selection gate and never touch the ledger."""
    gate_fn = gate_fn or check_selection_log
    synth_fn = synth_fn or synth
    out_r, canon_r = Path(out).resolve(), Path(canonical).resolve()
    if smoke:
        if out_r == canon_r or canon_r in out_r.parents:
            raise SystemExit("--smoke must write outside the canonical clone run directory")
        synth_fn(embedders, out, provenance={"smoke": True}, limit_targets=2)
        return None
    if out_r != canon_r:
        raise SystemExit(f"real synthesis writes only to {canonical} (got {out}); use --smoke for tests")
    want = parse_selection(only, embedders)
    gate = gate_fn(embedders, want, out, max_gpu_hours=max_gpu_hours)
    entry = record_synthesis_start(gate, new_preregistration, ledger)
    synth_fn(embedders, out, provenance=entry)
    return entry


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--embedder", required=True)
    p.add_argument("--only", required=True,
                   help="comma list: the staged selection (budget-passing subset of CLONED plus extras); "
                        "raw is always added; 'raw' alone for a raw-only run")
    p.add_argument("--smoke", action="store_true")
    s = sub.add_parser("synth")
    s.add_argument("--embedders", default="redimnet2-b2,ecapa-vox,titanet-s")
    s.add_argument("--only", required=True,
                   help="per-embedder selections 'emb:a,b;emb2:raw' that must equal the prepared ones")
    s.add_argument("--max-gpu-hours", type=float, default=8.0)
    s.add_argument("--new-preregistration", default=None,
                   help="reason, required if the selection log differs from the first synthesis's")
    s.add_argument("--smoke", action="store_true",
                   help="2 targets per split, non-canonical --out only, no selection gate, no ledger")
    pl = sub.add_parser("plan")
    pl.add_argument("--embedders", default="redimnet2-b2,ecapa-vox,titanet-s")
    lg = sub.add_parser("log")
    lg.add_argument("--embedders", default="redimnet2-b2,ecapa-vox,titanet-s")
    lg.add_argument("--rationale", required=True, help="why these protections (utility and inversion numbers)")
    sub.add_parser("stats")
    for q in (p, s, pl, lg):
        q.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args(argv)
    paths.require_mount()
    if args.cmd == "prepare":
        cfg = Config(per_speaker=3, per_speaker_linfn=2, mlp_epochs=3, mlp_seeds=(0,)) if args.smoke else Config()
        names = ["raw"] + [x for x in parse_names(args.only) if x != "raw"]
        prepare(args.embedder, names, cfg, args.out)
    elif args.cmd == "plan":
        print(json.dumps(plan(args.embedders.split(","), args.out), indent=2))
    elif args.cmd == "log":
        print(json.dumps(write_selection_log(args.embedders.split(","), args.out, args.rationale), indent=2))
    elif args.cmd == "synth":
        run_synth(args.embedders.split(","), args.only, args.out, args.max_gpu_hours,
                  args.new_preregistration, args.smoke)
    else:
        stats(OUT)


if __name__ == "__main__":
    main()
