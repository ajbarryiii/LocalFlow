"""Training of the mask network (DESIGN section 8), train split only.

    ./python -m lfspk.extract.train run --run R1 --seed 0 --steps N [--workers 6] [--device cuda]
    ./python -m lfspk.extract.train smoke --run R1 --steps 60 --workers 6      # step-rate measurement

Runs (pre-registered): R1 = M, film_cos, T2 (seeds 0, 1, 2); R2 = M, no
conditioning (same example stream), T2; R3 = M, film_cos, T1. R4 (V-asr) is a
separate fine-tune, not implemented here.

Determinism: example k of the run is `ExampleSource.example(seed, k)`, a pure
function of (seed, k); step g uses examples [g B, (g + 1) B), rendered by a
process pool whose ordered `imap` makes the stream independent of the worker
count; the crop RNG of step g is default_rng([seed, g, 99]). CUDA runs with
deterministic algorithms (CUBLAS_WORKSPACE_CONFIG is set when this module is
imported, before torch). A checkpoint (`last.pt`, every 1000 steps) stores the
model, optimiser, scheduler, step and an identity record; resuming refuses any
identity mismatch. Final checkpoint only (`final.pt`, the W5 checkpoint format);
no early stopping, no checkpoint picking.
"""

from __future__ import annotations

import os

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import time  # noqa: E402
from dataclasses import asdict, dataclass, field  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402

from lfspk import paths  # noqa: E402

from .data import ExamplePolicy, prepare_batch  # noqa: E402
from .losses import ALPHA, LAMBDA_AUX, total_loss  # noqa: E402
from .model import MaskNet, config_for, param_count  # noqa: E402

OUT = paths.RUNS / "W5" / "train"
RUNS = {"R1": dict(size="M", conditioning="film_cos", target_kind="T2"),
        "R2": dict(size="M", conditioning="none", target_kind="T2"),
        "R3": dict(size="M", conditioning="film_cos", target_kind="T1")}
# The fix screen (DESIGN amendment, draft d17dade8): single-factor variants of R1, each with an
# unconditioned twin ("u"). Keys beyond size/conditioning/target_kind override the defaults
# head = "sigmoid", alpha = ALPHA, p_absent = 0.05 (see `effective`).
SCREEN = {"V0": {}, "VA": {"head": "linear"}, "VB": {"alpha": 3.0}, "VC": {"p_absent": 0.5}}
# Screen runs are fully explicit (fix-r2 #1): these TrainConfig fields must take exactly these values.
SCREEN_FIXED = {"steps": 6500, "warmup": 1000, "batch": 32, "workers": 8}
for _name, _over in SCREEN.items():
    RUNS[_name] = dict(size="M", conditioning="film_cos", target_kind="T2", fixed=dict(SCREEN_FIXED), **_over)
    RUNS[_name + "u"] = dict(size="M", conditioning="none", target_kind="T2", fixed=dict(SCREEN_FIXED), **_over)
RECIPE_RUNS = ("R1", "R2")  # the final runs take the screen winner's factor through `recipe` (fix-r2 #2)
DEFAULTS = {"head": "sigmoid", "alpha": ALPHA, "p_absent": 0.05}
SAFE_FIELDS = ("workers", "device", "log_every", "ckpt_every", "out")


@dataclass(frozen=True)
class TrainConfig:
    run: str
    seed: int
    steps: int
    batch: int = 32
    lr: float = 2e-3
    weight_decay: float = 0.01
    warmup: int = 1000
    clip: float = 5.0
    crop_frames: int = 800  # 8 s
    alpha: float = ALPHA
    lambda_aux: float = LAMBDA_AUX
    workers: int = 6
    device: str = "cuda"
    log_every: int = 50
    ckpt_every: int = 1000
    out: str = ""
    recipe: str = "V0"  # R1/R2 only: the screen factor to apply; V0 = the original behaviour

    def __post_init__(self):
        if self.run not in RUNS:
            raise ValueError(f"unknown run {self.run!r}")
        if self.recipe not in SCREEN:
            raise ValueError(f"recipe must be one of {sorted(SCREEN)}")
        if self.recipe != "V0" and self.run not in RECIPE_RUNS:
            raise ValueError(f"recipe applies to {RECIPE_RUNS} only, not {self.run}")
        if self.steps < 1 or self.batch < 1:
            raise ValueError("steps and batch must be positive")

    @property
    def spec(self) -> dict:
        return RUNS[self.run]

    def name(self) -> str:
        return f"{self.run}-s{self.seed}"


def effective(cfg: TrainConfig) -> dict:
    """The run's head, loss alpha and absent-target probability. A run that sets
    its own alpha refuses a different TrainConfig.alpha (no silent override)."""
    spec = {**cfg.spec, **SCREEN[cfg.recipe]}
    if "alpha" in spec and cfg.alpha != ALPHA and cfg.alpha != spec["alpha"]:
        raise ValueError(f"run {cfg.run} fixes alpha = {spec['alpha']}; TrainConfig.alpha = {cfg.alpha} conflicts")
    return {"head": spec.get("head", DEFAULTS["head"]), "alpha": float(spec.get("alpha", cfg.alpha)),
            "p_absent": float(spec.get("p_absent", DEFAULTS["p_absent"]))}


def check_fixed(cfg: TrainConfig) -> None:
    """A screen run's fixed fields must have exactly their pre-registered values."""
    for k, v in cfg.spec.get("fixed", {}).items():
        if getattr(cfg, k) != v:
            raise ValueError(f"run {cfg.run} fixes {k} = {v}; got {getattr(cfg, k)}")


def model_config(cfg: TrainConfig):
    return config_for(cfg.spec["size"], cfg.spec["conditioning"], effective(cfg)["head"])


def example_policy(cfg: TrainConfig) -> ExamplePolicy:
    return ExamplePolicy(target_kind=cfg.spec["target_kind"], p_absent=effective(cfg)["p_absent"])


def lr_at(step: int, cfg: TrainConfig) -> float:
    """Linear warm-up to lr over `warmup` steps, then cosine decay to 0 at `steps`."""
    if step < cfg.warmup:
        return cfg.lr * (step + 1) / cfg.warmup
    p = (step - cfg.warmup) / max(1, cfg.steps - cfg.warmup)
    return cfg.lr * 0.5 * (1 + math.cos(math.pi * min(1.0, p)))


# --- example stream ---------------------------------------------------------------

_SRC = None  # {(target_kind, conditioned, p_absent): ExampleSource}, one per configuration


def _source(target_kind: str, conditioned: bool, p_absent: float = DEFAULTS["p_absent"]):
    global _SRC
    if _SRC is None:
        _SRC = {}
    key = (target_kind, bool(conditioned), float(p_absent))
    if key not in _SRC:
        from lfspk import splits
        from lfspk.harness.mix import MixtureGenerator
        from lfspk.pvad.enrollment import librispeech_partitions, target_eligible

        from .data import ExampleSource
        from .overlay import held_out, load_bank

        held = set(held_out())
        parts = librispeech_partitions("train")
        bank, _ = load_bank()
        bank.check({s: parts[s] for s in bank.speakers()}, bank.channels())
        pool = [s.id for s in splits.speakers("train") if s.id not in held]
        targets = [s for s, p in parts.items() if target_eligible(p) and s not in held]
        _SRC[key] = ExampleSource(MixtureGenerator("train", speakers=pool), parts, bank, targets, sorted(held),
                                  ExamplePolicy(target_kind=target_kind, p_absent=p_absent), conditioned=conditioned)
    return _SRC[key]


def _example(args):
    seed, k, target_kind, conditioned, p_absent = args
    e = _source(target_kind, conditioned, p_absent).example(seed, k)
    e.meta = None  # not needed for training; keeps IPC small
    e.labels = None
    e.target_image = None
    e.noise = None
    return e


class Stream:
    """Ordered examples [start, ...) from a process pool, with backpressure: at
    most `prefetch` batches are in flight (implT-r1 #2); global example indices
    and order are kept, so the worker count does not change the stream.
    workers = 0 renders in this process from `source` (tests)."""

    def __init__(self, cfg: TrainConfig, start_step: int, source=None, prefetch: int = 3):
        from collections import deque

        self.cfg = cfg
        cond = cfg.spec["conditioning"] != "none"
        self.ks = iter(range(start_step * cfg.batch, cfg.steps * cfg.batch))
        p_absent = effective(cfg)["p_absent"]
        self.args = (cfg.seed, cfg.spec["target_kind"], cond, p_absent)
        self.pool = None
        self.src = None
        if cfg.workers == 0:
            self.src = source or _source(cfg.spec["target_kind"], cond, p_absent)
            if (self.src.conditioned != cond or self.src.policy.target_kind != cfg.spec["target_kind"]
                    or self.src.policy.p_absent != p_absent):
                raise ValueError("the injected source does not match the run")
        else:
            from multiprocessing import get_context

            if source is not None:
                raise ValueError("an injected source needs workers = 0")
            self.pool = get_context("spawn").Pool(cfg.workers)
        self.limit = max(1, prefetch) * cfg.batch
        self.pending = deque()
        self._fill()

    def _fill(self):
        if self.pool is None:
            return
        while len(self.pending) < self.limit:
            k = next(self.ks, None)
            if k is None:
                return
            seed, kind, cond, p_absent = self.args
            self.pending.append(self.pool.apply_async(_example, ((seed, k, kind, cond, p_absent),)))

    def _next(self):
        if self.pool is None:
            k = next(self.ks)
            return self.src.example(self.cfg.seed, k)
        if not self.pending:
            raise StopIteration
        e = self.pending.popleft().get()
        self._fill()
        return e

    def batch(self):
        return [self._next() for _ in range(self.cfg.batch)]

    def close(self):
        if self.pool is not None:
            self.pool.terminate()


# --- identity and checkpoints --------------------------------------------------------

def code_sha256() -> str:
    from .harness_frontend import code_sha256 as c

    return c()


_W3_MODULES: list[str] | None = None


def w3_modules() -> list[str]:
    """Every lfspk.pvad module W5's data, overlay, training and calibration code
    imports, transitively, found in a fresh interpreter (so the answer does not
    depend on what this process happened to import; implT-r2)."""
    global _W3_MODULES
    if _W3_MODULES is None:
        import subprocess
        import sys

        code = ("import json, sys; import lfspk.extract.data, lfspk.extract.overlay, lfspk.extract.train, "
                "lfspk.extract.calibrate, lfspk.pvad.bank_build; print(json.dumps(sorted(m.__file__ for n, m in "
                "list(sys.modules.items()) if (n == 'lfspk.pvad' or n.startswith('lfspk.pvad.')) "
                "and getattr(m, '__file__', None))))")
        root = Path(__file__).resolve().parents[2]
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=300, cwd=str(root),
                             check=True).stdout.strip().splitlines()[-1]
        pvad = root / "lfspk"
        _W3_MODULES = sorted(str(Path(f).resolve().relative_to(pvad)) for f in json.loads(out))
    return list(_W3_MODULES)


def files_sha256(paths: list[Path], root: Path) -> str:
    h = hashlib.sha256()
    for p in sorted(paths):
        h.update(f"{p.relative_to(root)} {hashlib.sha256(p.read_bytes()).hexdigest()}\n".encode())
    return h.hexdigest()


def w3_code_sha256() -> str:
    """Hash of every W3 module W5 imports, transitively (partitions, draws,
    interferer speakers, front-end constants, the bank seed rule, ...)."""
    root = Path(__file__).resolve().parents[1]
    return files_sha256([root / rel for rel in w3_modules()], root)


def json_safe(obj):
    """Plain JSON types only (torch's TorchVersion and similar str subclasses
    break `torch.load(weights_only=True)`; implT-r1 #1)."""
    return json.loads(json.dumps(obj))


def identity(cfg: TrainConfig) -> dict:
    import platform

    from lfspk.pvad.identity import w0_identity

    from .overlay import OUT_DIR, W3_BANK_SHA256, held_out

    ov = json.loads((OUT_DIR / "overlay_meta.json").read_text())
    d = {k: v for k, v in asdict(cfg).items() if k not in SAFE_FIELDS}
    d.update({"kind": "w5-train", "model_config": model_config(cfg).to_dict(), "effective": effective(cfg),
              "target_kind": cfg.spec["target_kind"], "w5_code_sha256": code_sha256(), "w3_bank_sha256": W3_BANK_SHA256,
              "overlay_sha256": ov["overlay_sha256"], "embedder": ov["identity"]["embedder"],
              "embedder_weights_sha256": ov["identity"]["weights_sha256"],
              "held_out_sha256": hashlib.sha256(",".join(sorted(held_out(), key=int)).encode()).hexdigest(),
              "w0": w0_identity("train"), "w3_code_sha256": w3_code_sha256(), "torch": str(torch.__version__),
              "numpy": str(np.__version__), "python": platform.python_version()})
    return json_safe(d)


def identity_sha256(ident: dict) -> str:
    return hashlib.sha256(json.dumps(ident, sort_keys=True).encode()).hexdigest()


def _determinism(device: str) -> None:
    if device.startswith("cuda"):
        if os.environ.get("CUBLAS_WORKSPACE_CONFIG") != ":4096:8":
            raise RuntimeError("CUBLAS_WORKSPACE_CONFIG must be :4096:8 for deterministic CUDA training")
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False
    torch.use_deterministic_algorithms(True)


def train(cfg: TrainConfig, out: Path | None = None, smoke: bool = False, source=None, ident: dict | None = None,
          mel=None, stop_after: int | None = None) -> Path | None:
    """`source`, `ident`, `mel` and `stop_after` (simulate an interruption after
    that many steps, once `last.pt` is written) are test hooks; production runs
    use the real example source, identity and the pinned Parakeet constants."""
    from .frontend import parakeet_mel_power
    from .harness_frontend import save_checkpoint

    if source is None and ident is None:  # production entry (tests inject both)
        check_fixed(cfg)
    out = Path(out or cfg.out or (OUT / cfg.name()))
    if (out / "final.pt").exists():
        raise FileExistsError(f"{out} is finished; refusing to train into it")
    out.mkdir(parents=True, exist_ok=True)
    if cfg.device.startswith("cuda") and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    _determinism(cfg.device)
    torch.manual_seed(cfg.seed)
    ident = json_safe(identity(cfg) if ident is None else ident)
    ish = identity_sha256(ident)
    net = MaskNet(model_config(cfg)).to(cfg.device)
    eff = effective(cfg)
    opt = torch.optim.AdamW(net.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    step = 0
    last = out / "last.pt"
    if last.exists():
        ck = torch.load(last, map_location=cfg.device, weights_only=False)
        from .identities import differing, same

        if not same(ck["identity"], ident):
            raise RuntimeError(f"resume refused: identity differs in {differing(ck['identity'], ident)}")
        # keep the persisted identity for every later write (checkpoints, final metadata), so it
        # stays equal to run_meta.json after a commit-only change (sol stepbudget-r2 #2)
        ident = ck["identity"]
        ish = identity_sha256(ident)
        net.load_state_dict(ck["model"])
        opt.load_state_dict(ck["opt"])
        step = int(ck["step"])
    elif (out / "log.jsonl").exists():
        raise RuntimeError(f"{out} has a log but no checkpoint; refusing")
    else:
        (out / "run_meta.json").write_text(json.dumps({"config": asdict(cfg), "identity": ident, "identity_sha256": ish,
                                                       "params": param_count(net)}, indent=1))
    mel = (mel or parakeet_mel_power()).to(cfg.device)
    if cfg.device.startswith("cuda"):
        torch.cuda.reset_peak_memory_stats()
    stream = Stream(cfg, step, source)
    log = open(out / "log.jsonl", "a")
    t0, t_data = time.time(), 0.0
    try:
        net.train()
        while step < cfg.steps:
            td = time.time()
            exs = stream.batch()
            t_data += time.time() - td
            b = prepare_batch(exs, mel, cfg.crop_frames, np.random.default_rng([cfg.seed, step, 99]), cfg.device)
            for g in opt.param_groups:
                g["lr"] = lr_at(step, cfg)
            loss, parts = step_loss(net, b, cfg)
            if not torch.isfinite(loss):
                raise FloatingPointError(f"non-finite loss at step {step}")
            opt.zero_grad(set_to_none=True)
            loss.backward()
            gn = float(torch.nn.utils.clip_grad_norm_(net.parameters(), cfg.clip))
            opt.step()
            step += 1
            if step % cfg.log_every == 0 or step == cfg.steps:
                el = time.time() - t0
                log.write(json.dumps({"step": step, "loss": float(loss.detach()), **parts, "grad_norm": gn,
                                      "lr": lr_at(step - 1, cfg), "elapsed_s": round(el, 1),
                                      "data_wait_s": round(t_data, 1)}) + "\n")
                log.flush()
            if step % cfg.ckpt_every == 0 and not smoke:
                tmp = out / "last.tmp.pt"
                torch.save({"model": net.state_dict(), "opt": opt.state_dict(), "step": step, "identity": ident}, tmp)
                os.replace(tmp, last)
            if stop_after is not None and step >= stop_after:
                return None
    finally:
        stream.close()
        log.close()
    rate = (time.time() - t0) / max(1, step)
    if smoke:
        res = {"steps": step, "s_per_step": rate, "data_wait_fraction": t_data / max(1e-9, time.time() - t0),
               "steps_in_3h": int(3 * 3600 / rate), "budget_steps": int(3 * 3600 / rate) // 1000 * 1000,
               "peak_vram_gb": (torch.cuda.max_memory_allocated() / 2**30) if cfg.device.startswith("cuda") else None}
        (out / "smoke.json").write_text(json.dumps(res, indent=1))
        print(json.dumps(res), flush=True)
        return out / "smoke.json"
    meta = json_safe({"identity_sha256": ish, "identity": ident, "steps": step, "embedder": ident.get("embedder"),
                      "run": cfg.run, "seed": cfg.seed, "s_per_step": rate})
    save_checkpoint(out / "final.pt", net.cpu(), meta)
    return out / "final.pt"


def step_loss(net, b: dict, cfg: TrainConfig):
    """One training step's loss on a prepared batch, with the run's effective alpha."""
    emb = None if cfg.spec["conditioning"] == "none" else b["profile"]
    lm, ul = net(b["x"], emb, b["valid"].sum(1).long())
    return total_loss(lm, ul, b["ideal"], b["labels"], b["valid"], effective(cfg)["alpha"], cfg.lambda_aux)


def resume_check(run: str, seed: int, workers: int, device: str, out: Path, recipe: str = "V0") -> dict:
    """A 4-step run against the same run interrupted after its step-2 checkpoint
    and resumed: are the final weights bit-identical on this device? A
    measurement, not a gate (implT-r1)."""
    from .harness_frontend import load_checkpoint

    def cfg(name):
        return TrainConfig(run=run, seed=seed, steps=4, workers=workers, device=device, ckpt_every=2, out=str(out / name),
                           recipe=recipe)

    full = train(cfg("full"))
    train(cfg("cut"), stop_after=2)
    resumed = train(cfg("cut"))
    a, _, _ = load_checkpoint(full)
    b, _, _ = load_checkpoint(resumed)
    same = all(torch.equal(v, b.state_dict()[k]) for k, v in a.state_dict().items())
    diff = max(float((v - b.state_dict()[k]).abs().max()) for k, v in a.state_dict().items())
    res = {"device": device, "resume_bit_identical": bool(same), "max_abs_weight_diff": diff}
    (out / "resume_check.json").write_text(json.dumps(res, indent=1))
    return res


def _parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("run", "smoke"))
    ap.add_argument("--run", required=True, choices=sorted(RUNS))
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--steps", type=int, default=None)
    ap.add_argument("--workers", type=int, default=None)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--out", default="")
    ap.add_argument("--recipe", default="V0", choices=sorted(SCREEN))
    return ap


def config_from_args(argv) -> TrainConfig:
    """CLI -> TrainConfig. A screen run takes its fixed fields; a conflicting CLI value is an
    error. Other runs need --steps; workers default to 6."""
    ap = _parser()
    a = ap.parse_args(argv)
    fixed = RUNS[a.run].get("fixed", {})
    kw = dict(fixed)
    for k, v in (("steps", a.steps), ("workers", a.workers)):
        if v is None:
            continue
        if k in fixed and v != fixed[k]:
            ap.error(f"run {a.run} fixes --{k} {fixed[k]}; got {v}")
        kw[k] = v
    if "steps" not in kw:
        ap.error(f"run {a.run} needs --steps")
    kw.setdefault("workers", 6)
    return TrainConfig(run=a.run, seed=a.seed, device=a.device, out=a.out, recipe=a.recipe, **kw)


def main(argv=None) -> None:
    import sys

    ap = _parser()
    a = ap.parse_args(argv if argv is not None else sys.argv[1:])
    if a.cmd == "smoke" and "fixed" in RUNS[a.run]:
        ap.error(f"smoke does not run fixed screen run {a.run}; use `smoke --run R1 --recipe <V0|VA|VB|VC>` instead")
    cfg = config_from_args(argv if argv is not None else sys.argv[1:])
    if a.cmd == "smoke":
        out = Path(a.out) if a.out else OUT / "smoke" / f"{cfg.name()}-{time.strftime('%Y%m%dT%H%M%S')}"
        print(train(cfg, out, smoke=True))
        print(json.dumps(resume_check(a.run, a.seed, cfg.workers, a.device, out / "resume", recipe=cfg.recipe)), flush=True)
    else:
        print(train(cfg))


if __name__ == "__main__":
    main()
