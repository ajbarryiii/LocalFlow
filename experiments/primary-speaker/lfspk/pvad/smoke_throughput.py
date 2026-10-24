"""Training-throughput smoke for the step budget (DESIGN.md section 5).

    ./python -m lfspk.pvad.smoke_throughput --steps 200 --workers 6

Runs the M film_cos configuration on W0's mixer for a few hundred steps with a
**random-vector** enrollment bank (same rows and variants as the real bank,
embedding values meaningless), so it measures the data pipeline and the
optimiser only. No dev metric is computed; the checkpoint is discarded.
Output: RUNS/W3/smoke/throughput/ (log.jsonl, throughput.json).
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import uuid
import time
from pathlib import Path

import numpy as np

from lfspk import paths

from .enrollment import EnrollmentBank, bank_utterances, librispeech_partitions, target_eligible, unit
from .launch import SOURCE
from .train import TrainConfig, train

OUT = paths.RUNS / "W3" / "smoke" / "throughput"


def run_dir(kind: str) -> Path:
    """A fresh directory per invocation, so parallel smokes never share artifacts."""
    d = OUT / f"{kind}-{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}-{os.getpid()}-{uuid.uuid4().hex[:12]}"
    d.mkdir(parents=True, exist_ok=False)
    return d


def random_bank(dim: int = 192, seed: int = 0) -> EnrollmentBank:
    from lfspk.harness.channels import DEVICES

    parts = librispeech_partitions("train")
    spk, utt, ch, cont = [], [], [], []
    for s, p in sorted(parts.items()):
        if not target_eligible(p):
            continue
        for u in bank_utterances(p, 40):
            for d in DEVICES:
                for c in (False, True):
                    spk.append(s), utt.append(u), ch.append(d), cont.append(c)
    emb = unit(np.random.default_rng(seed).normal(size=(len(spk), dim)).astype(np.float32))
    return EnrollmentBank(emb, np.array(spk), np.array(utt), np.array(ch), np.array(cont), "random-smoke", "0" * 64)


def resume_check(device: str = "cuda") -> dict:
    """GPU resume equality (DESIGN.md section 5) on toy data, no mixer: a 40-step
    run against the same run resumed from its step-20 checkpoint, deterministic
    algorithms on and off."""
    import shutil

    import torch

    if not torch.cuda.is_available():
        raise RuntimeError("the GPU resume check needs CUDA")
    base_dir = run_dir("resume")
    out = {"device": torch.cuda.get_device_name(0), "torch": str(torch.__version__), "dir": str(base_dir)}
    for det in (True, False):
        root = base_dir / ("det" if det else "nondet")
        base = dict(size="M", steps=40, batch=16, crop_s=4.0, warmup=5, num_workers=2, device=device, log_every=20,
                    eval_every=10**9, ckpt_every=20, deterministic=det, source={"kind": "toy", "speakers": 24, "seconds": 4.0})
        t0 = time.time()
        a = train(TrainConfig(out_dir=str(root / "a"), **base))
        if torch.device(json.loads((root / "a" / "run_meta.json").read_text())["train"]["device"]).type != "cuda" or \
                not torch.cuda.is_initialized():
            raise RuntimeError("the resume check did not run on CUDA")
        t_full = time.time() - t0
        (root / "b").mkdir(parents=True)
        shutil.copy(root / "a" / "last.pt", root / "b" / "last.pt")
        b = train(TrainConfig(out_dir=str(root / "b"), **base))
        sa, sb = torch.load(a, weights_only=True)["model"], torch.load(b, weights_only=True)["model"]
        diff = max(float((sa[k].float() - sb[k].float()).abs().max()) for k in sa)
        out["det" if det else "nondet"] = {"max_abs_weight_diff": diff, "bit_identical": diff == 0.0, "full_run_s": t_full}
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=200)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--deterministic", type=int, default=1)
    ap.add_argument("--resume-check", action="store_true", help="only the toy GPU resume-equality check")
    a = ap.parse_args()
    paths.require_mount()
    if a.resume_check:
        res = resume_check()
        (Path(res["dir"]) / "resume_check.json").write_text(json.dumps(res, indent=1))
        print(json.dumps(res))
        return
    out = run_dir("throughput")
    bank_path = out / "random_bank.npz"
    random_bank().save(bank_path)
    cfg = TrainConfig(out_dir=str(out), size="M", conditioning="film_cos", steps=a.steps, batch=a.batch,
                      num_workers=a.workers, log_every=25, source=dict(SOURCE), bank=str(bank_path), ckpt_every=10**9,
                      deterministic=bool(a.deterministic))
    t0 = time.time()
    train(cfg, None)
    wall = time.time() - t0
    recs = [json.loads(l) for l in (out / "log.jsonl").read_text().splitlines() if '"loss"' in l]
    # steady state: from the first logged step after warm-up to the end
    first = recs[1] if len(recs) > 1 else recs[0]
    rate = (recs[-1]["step"] - first["step"]) / max(1e-9, recs[-1]["elapsed_s"] - first["elapsed_s"])
    res = {"steps": a.steps, "workers": a.workers, "batch": a.batch, "deterministic": bool(a.deterministic),
           "wall_s": wall, "steady_steps_per_s": rate,
           "steps_in_2h": int(rate * 7200), "maxrss_main_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
           "maxrss_children_mb": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024}
    (out / "throughput.json").write_text(json.dumps(res, indent=1))
    (out / "final.pt").unlink(missing_ok=True)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
