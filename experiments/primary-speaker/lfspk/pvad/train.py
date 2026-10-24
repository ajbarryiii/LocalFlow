"""PVAD training loop (DESIGN.md section 5).

    ./python -m lfspk.pvad.train --config runs/W3/<run>/config.json

The config names a mixture source ("toy" for smoke runs; the W0 adapter once
W0's mixing API is announced), the enrollment bank, the model and the
optimiser. Output: <out_dir>/final.pt, <out_dir>/log.jsonl, <out_dir>/run_meta.json (the
input config is never overwritten).
Final checkpoint only; nothing here picks checkpoints by dev metrics.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

# Deterministic cuBLAS needs its workspace size fixed before the first cuBLAS
# handle exists; set it before torch is imported here (train() verifies it).
CUBLAS_WORKSPACE = ":4096:8"
_CUBLAS_PRESET = "CUBLAS_WORKSPACE_CONFIG" in os.environ
os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", CUBLAS_WORKSPACE)

import torch  # noqa: E402

# If CUDA was already initialised when this module set the variable, cuBLAS may
# have read the old value: deterministic CUDA training is then refused.
_CUBLAS_LATE = (not _CUBLAS_PRESET) and torch.cuda.is_initialized()

from .data import ExamplePolicy, ExampleStream, Mixture, collate, prepare_batch
from .enrollment import LEVELS, EnrollmentBank, EnrollPolicy, target_eligible
from .features import ParakeetFrontEnd
from .losses import masked_cross_entropy, weighted_pairwise_loss, wpl_weights
from .metrics import frame_metrics, logit_from_logits
from .model import PVAD, PVADConfig, config_for, macs_per_second, param_count


@dataclass
class TrainConfig:
    out_dir: str
    size: str = "M"
    conditioning: str = "film_cos"
    enroll_policy: str = "robust"  # "robust" (default) or "clean30" (A5)
    p_absent_target: float = 0.1
    loss: str = "wpl"
    w_ns_ntss: float = 0.1
    steps: int = 20_000
    batch: int = 64
    crop_s: float = 8.0
    lr: float = 2e-3
    weight_decay: float = 0.01
    warmup: int = 1000
    clip: float = 5.0
    seed: int = 0
    num_workers: int = 6
    device: str = "cuda"
    amp: bool = True
    log_every: int = 50
    eval_every: int = 2000
    source: dict = field(default_factory=lambda: {"kind": "toy"})
    bank: str = ""  # path to an EnrollmentBank .npz ("" for toy)
    dev_monitor: str = ""  # path from lfspk.pvad.devmon build ("" for none)
    ckpt_every: int = 1000  # resumable checkpoint (last.pt) interval
    deterministic: bool = True  # torch.use_deterministic_algorithms on CUDA (DESIGN.md section 5)

    @classmethod
    def from_json(cls, path: Path) -> "TrainConfig":
        return cls(**json.loads(Path(path).read_text()))


def git_commit() -> str:
    try:
        root = Path(__file__).resolve().parents[2]
        out = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
        dirty = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "--", "lfspk/pvad"],
                               capture_output=True, text=True, timeout=10).stdout.strip()
        return out.stdout.strip() + ("-dirty" if dirty else "")
    except Exception:  # noqa: BLE001
        return "unknown"


# Fields that may change between a run and its resumption: they do not affect
# the example stream, the model or the optimiser.
RESUME_SAFE = ("out_dir", "num_workers", "log_every", "eval_every", "ckpt_every", "dev_monitor", "device")


def run_identity(cfg: TrainConfig, mcfg: PVADConfig, bank: EnrollmentBank) -> dict:
    """What a checkpoint's continuation depends on; compared on resume."""
    from .identity import w3_code_identity

    ident = {"train": {k: v for k, v in asdict(cfg).items() if k not in RESUME_SAFE}, "model": mcfg.to_dict(),
             "bank_sha256": _sha256(cfg.bank) if cfg.bank else "", "bank_embedder": bank.embedder,
             "bank_embedder_sha256": bank.embedder_sha256, "torch": str(torch.__version__), **w3_code_identity()}
    if cfg.source.get("kind") == "w0":
        from .identity import w0_identity

        ident.update(w0_identity("train"))
    return ident


IDENTITY_IGNORED = ("repo_head", "w0_commit")  # recorded; the code hashes are compared instead


def lr_at(step: int, cfg: TrainConfig) -> float:
    if step < cfg.warmup:
        return cfg.lr * (step + 1) / cfg.warmup
    prog = (step - cfg.warmup) / max(1, cfg.steps - cfg.warmup)
    return cfg.lr * 0.5 * (1 + math.cos(math.pi * min(1.0, prog)))


def make_partitions(spec: dict) -> dict:
    kind = spec.get("kind")
    if kind == "toy":
        from .synthetic import toy_partitions, toy_speakers

        return toy_partitions(toy_speakers(spec.get("speakers", 24), spec.get("seed", 0)))
    if kind == "w0":
        from .enrollment import librispeech_partitions

        return librispeech_partitions("train")
    raise ValueError(f"unknown source kind {kind!r}")


def make_source(spec: dict, partitions: dict):
    kind = spec.get("kind")
    if kind == "toy":
        from .synthetic import ToySource, toy_speakers

        return ToySource(toy_speakers(spec.get("speakers", 24), spec.get("seed", 0)), partitions,
                         seconds=spec.get("seconds", 4.0))
    if kind == "w0":
        from .w0_source import W0Source  # written once W0's mixing API is announced

        return W0Source(partitions=partitions, **{k: v for k, v in spec.items() if k != "kind"})
    raise ValueError(f"unknown source kind {kind!r}")


def make_bank(cfg: TrainConfig, partitions: dict) -> EnrollmentBank:
    """Every run loads the bank, conditioned or not, so all ablations share one
    example distribution (absent-target draws included)."""
    if cfg.bank:
        return EnrollmentBank.load(Path(cfg.bank))
    if cfg.source.get("kind") == "toy":
        from .synthetic import ToyEmbedder, toy_bank, toy_speakers

        return toy_bank(toy_speakers(cfg.source.get("speakers", 24), cfg.source.get("seed", 0)), partitions,
                        ToyEmbedder())
    raise ValueError("training needs an enrollment bank")


def _metrics(rows: list[tuple[np.ndarray, np.ndarray]]) -> dict:
    z = np.concatenate([r[0] for r in rows])
    post = np.exp(z - z.max(axis=1, keepdims=True))
    post /= post.sum(axis=1, keepdims=True)
    return frame_metrics(logit_from_logits(z), np.concatenate([r[1] for r in rows]), post)


@torch.no_grad()
def evaluate_frames(model: PVAD, frontend: ParakeetFrontEnd, items: list[tuple[Mixture, np.ndarray]],
                    device) -> dict:
    """Frame metrics per scenario and pooled, on whole mixtures (no crop)."""
    model.eval()
    by_sc: dict[str, list[tuple[np.ndarray, np.ndarray]]] = {}
    for mix, emb in items:
        n = len(mix.labels)
        mel = frontend(torch.from_numpy(mix.audio)[None].to(device))[:, :, :n]
        e = None if model.cfg.conditioning == "none" else torch.from_numpy(emb)[None].to(device)
        z = model(mel, e).float()[0].T.cpu().numpy().astype(np.float64)  # [T, 3] logits
        by_sc.setdefault(mix.scenario, []).append((z, mix.labels))
    out = {}
    for sc, rows in sorted(by_sc.items()):
        out[sc] = _metrics(rows)
    out["pooled"] = _metrics([r for rows in by_sc.values() for r in rows])
    model.train()
    return out


def train(cfg: TrainConfig, dev_items: list[tuple[Mixture, np.ndarray]] | None = None) -> Path:
    """Train one configuration; deterministic algorithms are on for the call
    (cfg.deterministic) and the process-wide flags are restored afterwards."""
    prev = (torch.are_deterministic_algorithms_enabled(), torch.is_deterministic_algorithms_warn_only_enabled(),
            torch.backends.cudnn.benchmark, torch.backends.cudnn.deterministic)
    if cfg.deterministic:
        if os.environ.get("CUBLAS_WORKSPACE_CONFIG") != CUBLAS_WORKSPACE or (_CUBLAS_LATE and cfg.device != "cpu"):
            # changing it after cuBLAS is in use is unsafe, so never set it here
            raise RuntimeError(f"deterministic training needs CUBLAS_WORKSPACE_CONFIG={CUBLAS_WORKSPACE} "
                               "in the environment before torch initialises CUDA")
        torch.use_deterministic_algorithms(True)
        torch.backends.cudnn.benchmark = False
        torch.backends.cudnn.deterministic = True
    try:
        return _train(cfg, dev_items)
    finally:
        torch.use_deterministic_algorithms(prev[0], warn_only=prev[1])
        torch.backends.cudnn.benchmark, torch.backends.cudnn.deterministic = prev[2], prev[3]


def _train(cfg: TrainConfig, dev_items: list[tuple[Mixture, np.ndarray]] | None = None) -> Path:
    out = Path(cfg.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    if (out / "final.pt").exists():
        raise ValueError(f"{out} already holds a finished run")
    torch.manual_seed(cfg.seed)
    device = torch.device(cfg.device if (cfg.device != "cuda" or torch.cuda.is_available()) else "cpu")
    if device.type == "cuda" and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    partitions = make_partitions(cfg.source)
    source = make_source(cfg.source, partitions)
    bank = make_bank(cfg, partitions)
    bank.check({s: partitions[s] for s in bank.speakers()}, bank.channels())
    ineligible = [s for s in bank.speakers() if not target_eligible(partitions[s])]
    if ineligible:
        raise ValueError(f"bank holds non-target speakers {ineligible[:3]}")
    emb_dim = bank.dim
    mcfg: PVADConfig = config_for(cfg.size, cfg.conditioning, emb_dim)
    model = PVAD(mcfg).to(device)
    if cfg.enroll_policy not in ("robust", "clean30"):
        raise ValueError("enroll_policy must be robust or clean30")
    enroll = EnrollPolicy() if cfg.enroll_policy == "robust" else EnrollPolicy.clean30()
    policy = ExamplePolicy(enroll=enroll, p_absent_target=cfg.p_absent_target)
    identity = run_identity(cfg, mcfg, bank)
    start = 0
    last = out / "last.pt"
    resume = torch.load(last, map_location=device, weights_only=True) if last.exists() else None
    if resume is None and ((out / "run_meta.json").exists() or (out / "log.jsonl").exists()):
        raise ValueError(f"{out} holds a stale run without a checkpoint; use a new out_dir")
    if resume is not None:
        from .identity import require_same

        require_same(json.loads(resume["identity"]), identity, f"checkpoint {last}", IDENTITY_IGNORED)
        model.load_state_dict(resume["model"])
        start = int(resume["step"])
    stream = ExampleStream(source, bank, partitions, policy, cfg.seed, start_step=start, batch=cfg.batch)
    loader = torch.utils.data.DataLoader(stream, batch_size=cfg.batch, collate_fn=collate, num_workers=cfg.num_workers,
                                         persistent_workers=cfg.num_workers > 0, prefetch_factor=2 if cfg.num_workers else None,
                                         pin_memory=device.type == "cuda")
    frontend = ParakeetFrontEnd().to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    if resume is not None:
        opt.load_state_dict(resume["opt"])
    crop_frames = int(round(cfg.crop_s * 100))
    meta = {"train": asdict(cfg), "model": mcfg.to_dict(), "params": param_count(model),
            "macs_per_s": macs_per_second(mcfg), "git": git_commit(),
            "embedder": bank.embedder, "embedder_sha256": bank.embedder_sha256,
            "levels": {lv: sum(p.level == lv for p in partitions.values()) for lv in LEVELS},
            "bank_sha256": _sha256(cfg.bank) if cfg.bank else "", "dev_monitor": cfg.dev_monitor,
            "resumed_from_step": start}
    meta["identity"] = identity
    if dev_items:
        _check_monitor(cfg, bank)
    # run_meta.json, not config.json: the input config may live in out_dir and must stay runnable.
    # Written once; a resumption appends to resumes.jsonl instead.
    if (out / "run_meta.json").exists():
        with (out / "resumes.jsonl").open("a") as f:
            f.write(json.dumps({"step": start, "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                "safe_fields": {k: getattr(cfg, k) for k in RESUME_SAFE}}) + "\n")
    else:
        (out / "run_meta.json").write_text(json.dumps(meta, indent=1))
    log = (out / "log.jsonl").open("a")
    t0 = time.time()
    model.train()
    it = iter(loader)
    stats = {"loss": 0.0, "n": 0, "frames": 0.0}
    for step in range(start, cfg.steps):
        crop_rng = np.random.default_rng([cfg.seed, 991, step])  # per step, so a resumed run crops identically
        batch = prepare_batch(next(it), frontend, crop_frames, crop_rng, device)
        for g in opt.param_groups:
            g["lr"] = lr_at(step, cfg)
        with torch.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=cfg.amp and device.type == "cuda"):
            logits = model(batch["mel"], batch["emb"] if mcfg.conditioning != "none" else None, batch["mask"])
        logits = logits.float()
        if cfg.loss == "wpl":
            loss = weighted_pairwise_loss(logits, batch["classes"], batch["mask"], wpl_weights(cfg.w_ns_ntss))
        else:
            loss = masked_cross_entropy(logits, batch["classes"], batch["mask"])
        opt.zero_grad(set_to_none=True)
        loss.backward()
        gn = torch.nn.utils.clip_grad_norm_(model.parameters(), cfg.clip)
        opt.step()
        stats["loss"] += loss.item()
        stats["n"] += 1
        stats["frames"] += float(batch["mask"].sum())
        if (step + 1) % cfg.log_every == 0 or step + 1 == cfg.steps:
            rec = {"step": step + 1, "loss": stats["loss"] / stats["n"], "lr": lr_at(step, cfg), "grad_norm": float(gn),
                   "elapsed_s": time.time() - t0, "frames_per_s": stats["frames"] / max(1e-9, time.time() - t0)}
            log.write(json.dumps(rec) + "\n")
            log.flush()
            print(json.dumps(rec), flush=True)
            stats["loss"], stats["n"] = 0.0, 0
        if dev_items and ((step + 1) % cfg.eval_every == 0 or step + 1 == cfg.steps):
            rec = {"step": step + 1, "dev_frames": evaluate_frames(model, frontend, dev_items, device)}
            log.write(json.dumps(rec) + "\n")
            log.flush()
            print(json.dumps({"step": step + 1, "dev_pooled": rec["dev_frames"]["pooled"]}), flush=True)
        if (step + 1) % cfg.ckpt_every == 0 and step + 1 < cfg.steps:
            tmp = out / "last.tmp.pt"
            torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "step": step + 1,
                        "identity": json.dumps(identity, sort_keys=True)}, tmp)
            os.replace(tmp, last)
    ckpt = out / "final.pt"
    torch.save({"model": model.state_dict(), "meta": meta, "step": cfg.steps}, ckpt)
    log.close()
    return ckpt


def _check_monitor(cfg: TrainConfig, bank: EnrollmentBank) -> None:
    """The dev monitor's profiles must come from the bank's embedder."""
    if not cfg.dev_monitor:
        return
    z = np.load(cfg.dev_monitor, allow_pickle=False)
    if (str(z["embedder"]), str(z["embedder_sha256"])) != (bank.embedder, bank.embedder_sha256):
        raise ValueError(f"dev monitor embedder {z['embedder']} differs from the bank's {bank.embedder}")


def _sha256(path: str) -> str:
    import hashlib

    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_model(path: Path, device: str = "cpu") -> tuple[PVAD, dict]:
    ck = torch.load(path, map_location=device, weights_only=True)
    model = PVAD(PVADConfig(**ck["meta"]["model"]))
    model.load_state_dict(ck["model"])
    return model.eval(), ck["meta"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True, type=Path)
    args = ap.parse_args()
    cfg = TrainConfig.from_json(args.config)
    dev_items = None
    if cfg.dev_monitor:
        from .devmon import load

        dev_items = load(Path(cfg.dev_monitor))
    print(train(cfg, dev_items))


if __name__ == "__main__":
    main()
