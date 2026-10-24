"""Cost against the budget of DESIGN section 6 (MACs at most 1 % of Parakeet's
encoder; at most 5 ms per audio second on one CPU core for the network plus the
extra log-and-normalise pass).

    ./python-nemo -m lfspk.extract.cost encoder [--seconds 10]     # Parakeet base encoder MACs, CPU
    ./python      -m lfspk.extract.cost latency [--size M]         # mask path, one thread, no GPU

The latency measurement mirrors W0's CPU_ENV discipline: it refuses to run with
a visible GPU or with more than one thread. W0's harness takes the official
measurement (`analyse` + `apply`). This one checks the budget before training,
on untrained weights; latency does not depend on the weight values.
"""

from __future__ import annotations

import argparse
import json
import os
import time

import numpy as np

CPU_ENV = {"CUDA_VISIBLE_DEVICES": "", "OMP_NUM_THREADS": "1", "MKL_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"}


def encoder_macs(seconds: float = 10.0) -> dict:
    import torch
    from torch.utils.flop_counter import FlopCounterMode

    from lfspk.harness.asr import load_model

    model = load_model("cpu")
    n = int(seconds * 16000)
    x = torch.randn(1, n) * 0.05
    with torch.no_grad():
        feats, flen = model.preprocessor(input_signal=x, length=torch.tensor([n]))
        with FlopCounterMode(display=False) as fc:
            model.encoder(audio_signal=feats, length=flen)
    macs = fc.get_total_flops() / 2
    return {"seconds": seconds, "encoder_macs": macs, "encoder_macs_per_audio_second": macs / seconds,
            "budget_1pct_macs_per_audio_second": macs / seconds / 100}


def check_cpu_env() -> None:
    for k, v in CPU_ENV.items():
        if os.environ.get(k) != v:
            raise SystemExit(f"run with {k}={v!r} (CPU_ENV)")


def latency(size: str = "M", repeats: int = 30) -> dict:
    check_cpu_env()
    import torch

    torch.set_num_threads(1)
    if torch.cuda.is_available():
        raise SystemExit("a GPU is visible")
    from .api import valid_frames
    from .frontend import analytic_mel_power, log_norm, masked_log_norm
    from .model import MaskNet, config_for, macs_per_second

    net = MaskNet(config_for(size)).eval()
    mel = analytic_mel_power()  # the constants do not affect timing
    rng = np.random.default_rng(0)
    out = {"size": size, "threads": torch.get_num_threads(), "macs_per_audio_second": macs_per_second(net.cfg)}
    for secs in (10, 20):
        n = secs * 16000
        audio = torch.from_numpy((rng.standard_normal(n) * 0.05).astype(np.float32))[None]
        emb = torch.from_numpy(rng.standard_normal(192).astype(np.float32))[None]
        lens = torch.tensor([n])
        with torch.no_grad():
            p = mel(audio, lens)
            x = log_norm(p, lens)  # LocalFlow already computes P and X; not timed
            times = []
            for _ in range(repeats + 3):
                t0 = time.perf_counter()
                lm, u = net(x, emb, torch.tensor([valid_frames(n)]))
                w = torch.sigmoid(u)
                masked_log_norm(p, lm, w, lens)  # the extra log-and-normalise pass
                times.append(time.perf_counter() - t0)
        t = np.array(times[3:]) / secs * 1000
        out[f"{secs}s"] = {"median_ms_per_audio_second": float(np.median(t)), "p90_ms_per_audio_second": float(np.quantile(t, 0.9))}
    return out


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("encoder")
    e.add_argument("--seconds", type=float, default=10.0)
    lt = sub.add_parser("latency")
    lt.add_argument("--size", default="M")
    a = ap.parse_args(argv)
    print(json.dumps(encoder_macs(a.seconds) if a.cmd == "encoder" else latency(a.size), indent=1))


if __name__ == "__main__":
    main()
