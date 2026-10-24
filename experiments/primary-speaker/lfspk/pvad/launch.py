"""Write the pre-registered training run configs (DESIGN.md section 6) and the
`job start` commands that run them.

    ./python -m lfspk.pvad.launch --bank RUNS/W3/emb/<embedder>/bank.npz --steps N [--dev-monitor PATH] [--seeds 0]

Every run shares one TrainConfig except the factor under test (size,
conditioning or enrollment policy) and the seed, so the ablations differ only in
that factor; `common_fields` is checked by a unit test. Configs go to
RUNS/W3/train/<run>/config.json; the commands are printed, not executed.
"""

from __future__ import annotations

import argparse
import json
import shlex
from dataclasses import asdict, fields
from pathlib import Path

from lfspk import paths

from .train import TrainConfig

ROOT = paths.RUNS / "W3" / "train"
REPO = Path(__file__).resolve().parents[2]

# name -> (size, conditioning, enroll_policy); pre-registered in DESIGN.md section 6
RUNS = {
    "S-film_cos": ("S", "film_cos", "robust"),  # A7
    "M-film_cos": ("M", "film_cos", "robust"),  # A7, A6, reference for A1 and A5
    "L-film_cos": ("L", "film_cos", "robust"),  # A7
    "M-concat": ("M", "concat", "robust"),  # A6
    "M-film": ("M", "film", "robust"),  # A6
    "M-none": ("M", "none", "robust"),  # A1
    "M-film_cos-clean30": ("M", "film_cos", "clean30"),  # A5
}
VARIED = ("out_dir", "size", "conditioning", "enroll_policy", "seed")

SOURCE = {"kind": "w0", "scenario_weights": [0.2, 0.2, 0.2, 0.2, 0.2], "p_headset": 0.0, "p_mixed_rir": 0.2}


def run_config(name: str, seed: int, bank: str, steps: int, dev_monitor: str = "", num_workers: int = 6,
               root: Path = ROOT) -> TrainConfig:
    size, cond, policy = RUNS[name]
    return TrainConfig(out_dir=str(root / f"{name}-s{seed}"), size=size, conditioning=cond, enroll_policy=policy,
                       steps=steps, seed=seed, num_workers=num_workers, source=dict(SOURCE), bank=bank,
                       dev_monitor=dev_monitor)


def common_fields(cfgs: list[TrainConfig]) -> dict:
    """Fields that must be identical across runs, and their shared value."""
    out = {}
    for f in fields(TrainConfig):
        if f.name in VARIED:
            continue
        vals = {json.dumps(getattr(c, f.name), sort_keys=True) for c in cfgs}
        if len(vals) != 1:
            raise ValueError(f"field {f.name} differs across runs: {sorted(vals)}")
        out[f.name] = getattr(cfgs[0], f.name)
    return out


def job_command(cfg: TrainConfig, vram: str = "4G", mem: str = "12G", cpus: int = 7, timeout: str = "6h") -> str:
    name = "w3-train-" + Path(cfg.out_dir).name
    argv = ["job", "start", name, "--cwd", str(REPO), "--needs", "gpu:shared", "--vram", vram, "--mem", mem,
            "--cpus", str(cpus), "--timeout", timeout, "--stall", "20m", "--",
            "./python", "-m", "lfspk.pvad.train", "--config", str(Path(cfg.out_dir) / "config.json")]
    return " ".join(shlex.quote(a) for a in argv)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bank", required=True)
    ap.add_argument("--steps", type=int, required=True)
    ap.add_argument("--dev-monitor", default="")
    ap.add_argument("--seeds", type=int, nargs="+", default=[0])
    ap.add_argument("--runs", nargs="+", default=list(RUNS))
    ap.add_argument("--num-workers", type=int, default=6)
    a = ap.parse_args()
    cfgs = [run_config(n, s, a.bank, a.steps, a.dev_monitor, a.num_workers) for n in a.runs for s in a.seeds]
    common_fields(cfgs)
    for c in cfgs:
        out = Path(c.out_dir)
        out.mkdir(parents=True, exist_ok=True)
        path = out / "config.json"
        if path.exists() and json.loads(path.read_text()) != asdict(c):
            raise SystemExit(f"{path} exists with a different config; refusing to overwrite")
        path.write_text(json.dumps(asdict(c), indent=1))
        print(job_command(c))


if __name__ == "__main__":
    main()
