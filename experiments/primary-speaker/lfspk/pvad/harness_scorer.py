"""Factory for W0's evaluator (lfspk.harness.evaluate --scorer MODULE:CALLABLE).

    ./python -m lfspk.harness.evaluate run --set <dev set> --half A \
        --scorer lfspk.pvad.harness_scorer:make --arg checkpoint=RUNS/W3/train/M-film_cos-s0/final.pt \
        [--arg update_rule=gated] [--arg recal=RUNS/W3/recal/<run>.json]

The checkpoint names its embedder (from the training bank); the factory loads
that embedder through W1's `load_embedder` and refuses a different weights
hash. Embedder MACs per second come from W1's cost survey
(RUNS/W1/survey/cost/<name>.json, `trunk_macs_per_s_slope`, front end excluded)
and are required for a conditioned scorer's CostReport. Scoring runs on CPU
with one intra-op thread per evaluator worker.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from lfspk import paths

from .scorer import PVADScorer

COST_DIR = paths.RUNS / "W1" / "survey" / "cost"


def embedder_macs_per_s(name: str, cost_dir: Path | None = None) -> float:
    rec = json.loads(((cost_dir or COST_DIR) / f"{name}.json").read_text())
    return float(rec["trunk_macs_per_s_slope"])


def file_sha256(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_recal(path: str, checkpoint: str) -> float:
    rec = json.loads(Path(path).read_text())
    if rec["checkpoint_sha256"] != file_sha256(Path(checkpoint)):
        raise ValueError("the recalibration file was fitted for a different checkpoint")
    return float(rec["population"])


def make(checkpoint: str, update_rule: str = "mean", recal: str = "", device: str = "cpu", name: str = "",
         threads: str = "1", gate: str = "0.5") -> PVADScorer:
    import torch

    from .train import load_model

    torch.set_num_threads(int(threads))
    model, meta = load_model(Path(checkpoint), device)
    run = Path(checkpoint).parent.name
    base = name or f"pvad-{run}-{update_rule}" + ("-recal" if recal else "")
    if model.cfg.conditioning == "none":
        return PVADScorer(model, None, name=base, update_rule="mean", gate=float(gate),
                          recal_population=load_recal(recal, checkpoint) if recal else None, device=device)
    from lfspk.embed.embedder import load_embedder

    emb = load_embedder(meta["embedder"], device)
    if emb.weights_sha256 != meta["embedder_sha256"]:
        raise ValueError(f"embedder {meta['embedder']} weights differ from those the PVAD was trained with")
    return PVADScorer(model, emb, name=base, update_rule=update_rule, gate=float(gate),
                      recal_population=load_recal(recal, checkpoint) if recal else None, device=device,
                      embedder_params=getattr(emb, "params", None), embedder_macs_per_s=embedder_macs_per_s(emb.name))
