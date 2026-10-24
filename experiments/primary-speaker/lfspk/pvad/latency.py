"""CPU latency of PVAD scoring per second of audio (DESIGN.md section 7).

    ./python -m lfspk.pvad.latency [--checkpoint final.pt] [--threads 1]

Single-threaded torch on this host's CPU, median of `--repeats` runs after
warm-up, for 10 s and 30 s inputs; reported with and without the log-mel front
end (which LocalFlow shares with Parakeet). Not a Core ML / Apple-silicon
measurement.
"""

from __future__ import annotations

import argparse
import json
import platform
import time

import numpy as np
import torch

from .features import ParakeetFrontEnd
from .model import PVAD, config_for, macs_per_second, param_count


def measure(model: PVAD, seconds: float, repeats: int = 20) -> dict:
    fe = ParakeetFrontEnd()
    audio = torch.from_numpy(np.random.default_rng(0).normal(0, 0.1, int(seconds * 16_000)).astype(np.float32))[None]
    n = audio.shape[1] // 160
    emb = None if model.cfg.conditioning == "none" else torch.randn(1, model.cfg.emb_dim)
    with torch.inference_mode():
        mel = fe(audio)[:, :, :n]
        for _ in range(3):
            model(mel, emb)
        net, full = [], []
        for _ in range(repeats):
            t = time.perf_counter()
            model(mel, emb)
            net.append(time.perf_counter() - t)
            t = time.perf_counter()
            model(fe(audio)[:, :, :n], emb)
            full.append(time.perf_counter() - t)
    return {"seconds": seconds, "net_ms_per_audio_s": 1e3 * float(np.median(net)) / seconds,
            "with_frontend_ms_per_audio_s": 1e3 * float(np.median(full)) / seconds}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--repeats", type=int, default=20)
    args = ap.parse_args()
    torch.set_num_threads(args.threads)
    if args.checkpoint:
        from .train import load_model

        models = {args.checkpoint: load_model(args.checkpoint)[0]}
    else:
        models = {f"{s}/{c}": PVAD(config_for(s, c)).eval() for s in ("S", "M", "L") for c in ("none", "film_cos")}
    for name, m in models.items():
        rec = {"model": name, "params": param_count(m), "macs_per_s": macs_per_second(m.cfg), "threads": args.threads,
               "cpu": platform.processor() or platform.machine(), "torch": torch.__version__,
               "runs": [measure(m, s, args.repeats) for s in (10.0, 30.0)]}
        print(json.dumps(rec))


if __name__ == "__main__":
    main()
