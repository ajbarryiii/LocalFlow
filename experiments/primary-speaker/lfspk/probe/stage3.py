"""Stage 3 jobs (DESIGN 6): half-A back ends, frame-head training, dev scoring.

    ./python -m lfspk.probe.stage3 fit-backends --feature base      # CPU
    ./python-nemo -m lfspk.probe.stage3 train --weights base --seed 1   # GPU

Outputs under RUNS/W2/frames/: backends/<feature>-halfA.npz,
<weights>-seed<s>/heads.pt, dev_scores.npz, train_log.jsonl, run.json.
Mixtures are W2-simplemix (simplemix.NAME); results always say so.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from pathlib import Path

import numpy as np

from lfspk import paths

from . import N_TAPS
from .backend import LDA_DIM, Backend
from .extract import git_commit
from .frames import (FrameHead, MixPlan, ProfileTable, dev_plans, frame_stats, halves, make_example,
                     masked_bce, stack_logmel, train_plan)
from .simplemix import NAME as MIX_NAME
from .simplemix import encoder_targets, upsample_scores
from .select import dev_halves, dev_strata
from .verify import load_feats, row_lookup

OUT = paths.RUNS / "W2" / "frames"
STEPS = 6000
BATCH = 32
LR = 1e-3
WD = 0.01
WARMUP = 200
DEV_BATCH_SECONDS = 240.0
ENCODE_CHUNK = 8  # mixtures per encoder call


# --- back ends on half A -------------------------------------------------------------------------


def check_inputs(metas: list[dict], smoke: bool) -> None:
    from .guard import check_inputs as check

    check(metas, smoke, OUT, "stage-3")


def fit_backends(feature: str, smoke: bool = False) -> Path:
    arr, index, sel, meta = load_feats(feature, "train")
    check_inputs([meta], smoke)
    a, _ = halves(list(sel["selection"]))
    a = set(a)
    rows = [i for i, it in enumerate(index) if it["speaker"] in a]
    y = np.array([index[i]["speaker"] for i in rows])
    out = {}
    for tap in range(arr.shape[0]):
        be = Backend.fit(np.asarray(arr[tap][rows], dtype=np.float64), y, LDA_DIM)
        for k, v in be.to_npz().items():
            out[f"tap{tap}/{k}"] = v
        print(f"{feature} tap {tap}: shrinkage {be.shrinkage:.3f}, dim {be.proj.shape[1]}", flush=True)
    d = OUT / "backends"
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{feature}-halfA.npz"
    np.savez(path, **out, speakers=np.array(sorted(a, key=int)))
    return path


def load_backends(feature: str) -> list[Backend]:
    z = np.load(OUT / "backends" / f"{feature}-halfA.npz")
    n = len({k.split("/")[0] for k in z.files if k.startswith("tap")})
    return [Backend.from_npz({k: z[f"tap{t}/{k}"] for k in ("mean", "scale", "proj", "center", "shrinkage")})
            for t in range(n)]


# --- data ----------------------------------------------------------------------------------------


class _Mixtures:
    """torch Dataset: index -> (audio, labels, plan). `plans` is a list or a
    callable index -> MixPlan (the training stream is built lazily)."""

    def __init__(self, plans, n: int, train: bool, caches):
        self.plans, self.n, self.train = plans, n, train
        self.caches = list(caches)

    def __len__(self):
        return self.n

    def plan(self, i) -> MixPlan:
        return self.plans(i) if callable(self.plans) else self.plans[i]

    def _load(self, utt):
        """Verified packed audio only (audiocache.py); a missing utterance is an error."""
        for c in self.caches:
            if utt in c:
                return c.load(utt)
        raise KeyError(f"{utt} is not in the audio caches")

    def __getitem__(self, i):
        plan = self.plan(i)
        audio, labels, _ = make_example(plan, self._load, self.train)
        return audio, labels, plan


def _collate(items):
    import torch

    n = max(a.size for a, _, _ in items)
    x = np.zeros((len(items), n), np.float32)
    for j, (a, _, _) in enumerate(items):
        x[j, : a.size] = a
    return torch.from_numpy(x), torch.tensor([a.size for a, _, _ in items]), [l for _, l, _ in items], \
        [i for _, _, i in items]


class _Stream:
    """Index-seeded training plans for one seed (picklable for workers)."""

    def __init__(self, seed, selection, speakers, sex):
        self.args = (seed, selection, list(speakers), sex)

    def __call__(self, i: int) -> MixPlan:
        seed, selection, speakers, sex = self.args
        return train_plan(i, seed, selection, speakers, sex)


# --- heads ---------------------------------------------------------------------------------------


def open_caches(train_selection: dict, dev_selection: dict):
    """The verified audio caches [train half B, dev], each holding exactly the
    utterances of the stage-2 manifests this run uses. Reads every byte once
    (hash check, page-cache warm-up). Called before any output is touched."""
    from .audiocache import ROOT as CACHE_ROOT
    from .audiocache import AudioCache, dev_utts, require_ids, train_half_b_utts

    train = AudioCache(CACHE_ROOT / "train-halfB")
    require_ids(train, train_half_b_utts(train_selection["selection"]), "stage-3 train audio")
    dev = AudioCache(CACHE_ROOT / "dev")
    require_ids(dev, dev_utts(dev_selection["plans"]), "stage-3 dev audio")
    for c in (train, dev):
        c.verify()
    print("audio caches:", [(c.directory.name, c.generation, len(c.index)) for c in (train, dev)], flush=True)
    return [train, dev]


def head_names(weights: str) -> list[tuple[str, str, int, bool]]:
    """(name, feature, tap, conditioned) for every head trained in one job."""
    out = []
    for tap in range(N_TAPS):
        for cond in (True, False):
            out.append((f"{weights}:tap{tap}:{'cond' if cond else 'uncond'}", weights, tap, cond))
    for cond in (True, False):
        out.append((f"logmel:tap0:{'cond' if cond else 'uncond'}", "logmel", 0, cond))
    return out


def train(weights: str, seed: int, steps: int, smoke: bool) -> None:
    import torch
    from torch.utils.data import DataLoader

    from .models import TapEncoder, load_parakeet

    if "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    torch.manual_seed(seed)
    device = "cuda"
    # Every input is validated before anything is created or removed.
    feats_w, idx_w, sel_w, meta_w = load_feats(weights, "train")
    feats_l, idx_l, _, meta_l = load_feats("logmel", "train")
    dfeats_w, didx_w, dsel, dmeta_w = load_feats(weights, "dev")
    dfeats_l, _, _, dmeta_l = load_feats("logmel", "dev")
    check_inputs([meta_w, meta_l, dmeta_w, dmeta_l], smoke)
    caches = open_caches(sel_w, dsel)
    out = OUT / (f"{weights}-seed{seed}" + ("-smoke" if smoke else ""))
    out.mkdir(parents=True, exist_ok=True)
    (out / "run.json").unlink(missing_ok=True)

    # train side: half B speakers, stage-2 pooled features for profiles
    if [(i["utt"], i["length"]) for i in idx_w] != [(i["utt"], i["length"]) for i in idx_l]:
        raise ValueError("feature indices differ")
    selection = sel_w["selection"]
    sex = sel_w["sex"]
    _, half_b = halves(list(selection))
    rows = row_lookup(idx_w)
    b_rows = {u: rows[(u, "full")] for s in half_b for u in selection[s]}
    be_w, be_l = load_backends(weights), load_backends("logmel")
    prof_w = ProfileTable.build(feats_w, b_rows, be_w)
    prof_l = ProfileTable.build(feats_l, b_rows, be_l)
    mu, sd = frame_stats(feats_w, sorted(b_rows.values()))
    mu_t, sd_t = torch.from_numpy(mu).to(device), torch.from_numpy(sd).to(device)

    # dev side
    drows = row_lookup(didx_w)
    dplans = dev_plans(dsel["plans"], dsel["sex"], dev_halves(dev_strata(dsel["plans"], dsel["sex"], dsel["subset"])))
    enr = sorted({u for p in dplans for u in p.enroll})
    dprof_w = ProfileTable.build(dfeats_w, {u: drows[(u, "full")] for u in enr}, be_w)
    dprof_l = ProfileTable.build(dfeats_l, {u: drows[(u, "full")] for u in enr}, be_l)


    names = head_names(weights)
    k_w, k_l = be_w[0].proj.shape[1], be_l[0].proj.shape[1]
    heads = torch.nn.ModuleDict({
        n.replace(":", "_"): FrameHead(1024, k_w if f != "logmel" else k_l, cond) for n, f, _, cond in names
    }).to(device)
    opt = torch.optim.AdamW(heads.parameters(), lr=LR, weight_decay=WD)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: min(1.0, (s + 1) / WARMUP) * 0.5 * (1 + math.cos(math.pi * min(s, steps) / steps)))
    tap = TapEncoder(load_parakeet(weights, device))
    stream = _Stream(seed, selection, half_b, sex)
    loader = DataLoader(_Mixtures(stream, steps * BATCH, True, caches), batch_size=BATCH, shuffle=False, num_workers=8,
                        collate_fn=_collate, prefetch_factor=4, persistent_workers=False)

    def encode(x, l):
        """Encoder taps and stacked log-mel in micro-batches of ENCODE_CHUNK
        (bounds the subsampling conv's memory), padded to a common length."""
        outs = []
        for i in range(0, x.size(0), ENCODE_CHUNK):
            xs, ls = x[i:i + ENCODE_CHUNK], l[i:i + ENCODE_CHUNK]
            xs = xs[:, : int(ls.max())]
            fr, el, (feat, _) = tap.frames(xs, ls, with_features=True)
            outs.append((fr, el, stack_logmel(feat, el, fr[0].size(1))))
        t = max(o[0][0].size(1) for o in outs)

        def pad(v):
            return torch.nn.functional.pad(v, (0, 0, 0, t - v.size(1)))
        frames = [torch.cat([pad(o[0][k]) for o in outs]) for k in range(N_TAPS)]
        return frames, torch.cat([o[1] for o in outs]), torch.cat([pad(o[2]) for o in outs])

    def inputs(x, l, plan_list, ptab_w, ptab_l):
        frames, enc_len, lm = encode(x, l)
        pw = torch.from_numpy(np.stack([ptab_w.profile(p.enroll) for p in plan_list])).to(device)
        pl = torch.from_numpy(np.stack([ptab_l.profile(p.enroll) for p in plan_list])).to(device)
        return frames, enc_len, lm, pw, pl

    def run_heads(frames, lm, pw, pl, enc_len):
        res = {}
        for n, f, t, cond in names:
            if f == "logmel":
                xin, prof = lm, pl[:, 0]
            else:
                xin = (frames[t] - mu_t[t]) / sd_t[t]
                prof = pw[:, t]
            res[n] = heads[n.replace(":", "_")](xin, prof if cond else None, enc_len)
        return res

    log = open(out / "train_log.jsonl", "w")
    t0 = time.time()
    heads.train()
    for step, (x, l, labels, batch_plans) in enumerate(loader):
        x, l = x.to(device), l.to(device)
        frames, enc_len, lm, pw, pl = inputs(x, l, batch_plans, prof_w, prof_l)
        tgt = torch.from_numpy(np.stack([np.pad(encoder_targets(lab, int(n)), (0, frames[0].size(1) - int(n)))
                                         for lab, n in zip(labels, enc_len.tolist())])).to(device)
        losses = {n: masked_bce(lo, tgt, enc_len) for n, lo in run_heads(frames, lm, pw, pl, enc_len).items()}
        opt.zero_grad(set_to_none=True)
        sum(losses.values()).backward()
        opt.step()
        sched.step()
        if step % 100 == 0 or step == steps - 1:
            rec = {"step": step, "seconds": time.time() - t0, "lr": sched.get_last_lr()[0],
                   "loss": {n: float(v) for n, v in losses.items()},
                   "max_mem_gb": torch.cuda.max_memory_allocated() / 1e9}
            log.write(json.dumps(rec) + "\n")
            log.flush()
            best = min(losses, key=lambda n: float(losses[n]))
            print(f"step {step} {time.time() - t0:.0f}s mem {rec['max_mem_gb']:.1f}GB best {best} "
                  f"{float(losses[best]):.4f} logmel:cond {float(losses['logmel:tap0:cond']):.4f}", flush=True)
    torch.save(heads.state_dict(), out / "heads.pt")
    np.savez(out / "frame_stats.npz", mu=mu, sd=sd)

    # dev scoring
    heads.eval()
    dplans_eval = dplans[:64] if smoke else dplans
    dset = _Mixtures(dplans_eval, len(dplans_eval), False, caches)
    sizes = [2 * caches[1].index[p.target][1] for p in dplans_eval]  # upper bound of the mixture length
    order = np.argsort(sizes, kind="stable")
    batches, cur = [], []
    for i in order:
        if cur and sizes[i] * (len(cur) + 1) > DEV_BATCH_SECONDS * 16000:
            batches.append(cur)
            cur = []
        cur.append(int(i))
    batches.append(cur)
    scores = {n: [None] * len(dplans_eval) for n, *_ in names}
    labels_all = [None] * len(dplans_eval)
    with torch.no_grad():
        for b in batches:
            items = [dset[i] for i in b]
            x, l, labels, bplans = _collate(items)
            x, l = x.to(device), l.to(device)
            frames, enc_len, lm, pw, pl = inputs(x, l, bplans, dprof_w, dprof_l)
            res = run_heads(frames, lm, pw, pl, enc_len)
            for j, i in enumerate(b):
                labels_all[i] = labels[j]
                for n, lo in res.items():
                    p = torch.sigmoid(lo[j, : int(enc_len[j])]).cpu().numpy()
                    scores[n][i] = upsample_scores(p, int(l[j])).astype(np.float16)
    lens = np.array([lab.size for lab in labels_all])
    np.savez(out / "dev_scores.npz",
             labels=np.concatenate(labels_all), lengths=lens,
             target_speaker=np.array([p.target.split("-")[0] for p in dplans_eval]),
             same_sex=np.array([p.same_sex for p in dplans_eval]),
             target_session=np.array([{q["speaker"]: q["session"] for q in dsel["plans"]}[p.target.split("-")[0]]
                                      for p in dplans_eval]),
             target=np.array([p.target for p in dplans_eval]),
             interferer=np.array([p.interferer for p in dplans_eval]),
             interferer_speaker=np.array([p.interferer.split("-")[0] for p in dplans_eval]),
             half_S=np.array(dev_halves(dev_strata(dsel["plans"], dsel["sex"], dsel["subset"]))[0]), half_E=np.array(dev_halves(dev_strata(dsel["plans"], dsel["sex"], dsel["subset"]))[1]),
             **{f"score/{n}": np.concatenate(v) for n, v in scores.items()})
    (out / "run.json").write_text(json.dumps({
        "weights": weights, "seed": seed, "steps": steps, "batch": BATCH, "mixtures": MIX_NAME,
        "smoke": smoke, "commit": git_commit(), "seconds": time.time() - t0, "heads": [n for n, *_ in names],
        "dev_mixtures": len(dplans_eval), "audio_caches": {c.directory.name: {"generation": c.generation, "audio_sha256": c.meta["audio_sha256"]}
                                          for c in caches}, "head_params": sum(p.numel() for p in heads.parameters()) // len(names),
    }, indent=1))


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fit-backends")
    f.add_argument("--feature", required=True)
    f.add_argument("--smoke", action="store_true")
    t = sub.add_parser("train")
    t.add_argument("--weights", choices=["base", "m1"], required=True)
    t.add_argument("--seed", type=int, required=True)
    t.add_argument("--steps", type=int, default=STEPS)
    t.add_argument("--smoke", action="store_true")
    args = ap.parse_args(argv)
    paths.require_mount()
    if args.cmd == "fit-backends":
        print(fit_backends(args.feature, args.smoke))
    else:
        train(args.weights, args.seed, args.steps, args.smoke)


if __name__ == "__main__":
    main()
