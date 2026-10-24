"""OpenVoice tone-colour embeddings (`se`, 256-d, unnormalised) per utterance,
for the bridge and direct cloning routes (W4 only).

    ./python-nemo -m lfspk.protect.ovse --split train
    ./python-nemo -m lfspk.protect.ovse --split dev

Same layout and rows as the embedding cache's full-utterance rows
(`runs/W4/ovse/<split>/`, embcache format, vectors not normalised): one row per
planned utterance, the reference encoder's output on the whole utterance.
OpenVoice's own `extract_se` over several files is the mean of these rows.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from .. import paths
from . import embcache, openvoice
from .extract import git_commit, load_segment, plan_rows

OVSE_ROOT = paths.RUNS / "W4" / "ovse"


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", required=True, choices=("train", "dev", "clone_eval"))
    ap.add_argument("--limit-speakers", type=int, default=0)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--device", default=None)
    args = ap.parse_args(argv)
    paths.require_mount()
    import torch

    if torch.cuda.is_available() and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    tc = openvoice.ToneColorConverter(device)
    plan = [(r, p) for r, p in plan_rows(args.split) if r.is_full]
    if args.limit_speakers:
        if args.out is None or embcache.is_inside_or_contains(args.out, OVSE_ROOT) \
                or embcache.is_inside_or_contains(args.out, embcache.CACHE_ROOT):
            raise SystemExit("--limit-speakers needs --out outside the shared root")
        keep = sorted({r.speaker for r, _ in plan}, key=int)[: args.limit_speakers]
        plan = [(r, p) for r, p in plan if r.speaker in keep]
    out = np.zeros((len(plan), openvoice.SE_DIM), dtype=np.float32)
    chunk, lookahead = 64, 2
    starts = list(range(0, len(plan), chunk))
    with ThreadPoolExecutor(max_workers=6) as pool:
        submit = lambda st: [pool.submit(load_segment, *rp) for rp in plan[st : st + chunk]]
        pending = {st: submit(st) for st in starts[:lookahead]}
        for j, st in enumerate(starts):
            if j + lookahead < len(starts):
                pending[starts[j + lookahead]] = submit(starts[j + lookahead])
            for i, f in enumerate(pending.pop(st)):
                out[st + i] = tc.extract_se([f.result()])
            if st % 2048 == 0:
                print(f"{st}/{len(plan)}", flush=True)
    meta = {
        "embedder": "openvoice-v2-se", "weights_sha256": openvoice.PINNED["checkpoint.pth"],
        "code_commit": openvoice.SRC_COMMIT, "split": args.split, "limit_speakers": args.limit_speakers,
        "normalised": False, "librispeech_root": str(paths.LIBRISPEECH), "git_commit": git_commit(),
        "command": " ".join(sys.argv), "created": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }
    gen = embcache.write(args.out or OVSE_ROOT / args.split, meta, [r for r, _ in plan], out, require_unit=False)
    print(f"wrote {len(plan)} rows, generation {gen}")


if __name__ == "__main__":
    main()
