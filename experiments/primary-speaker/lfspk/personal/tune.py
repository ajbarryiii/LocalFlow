"""Per-user fine-tuning (DESIGN 1, 4, 7): configuration P (conditioning path + heads) or F (all).

    ./python -m lfspk.personal.tune run --arm A-VB --subject 2775 --config P [--device cuda]
    ./python -m lfspk.personal.tune run --arm A-VB --subject 2775 --config P --device cpu --threads 2 --tag cpu
    python -m lfspk.personal.tune bundle-run --bundle DIR --arm A-VB --subject 2775 --config P --out DIR --threads 2

Fixed hyperparameters (DESIGN 4): 1,000 steps, batch 8, 8 s crops, AdamW with
fresh state and weight decay 0, lr 3e-4 after a 50-step linear warm-up then
constant, clip 5, W5's total_loss with the base's own effective alpha and
lambda_aux 0.1, seed 0; readouts at steps 250, 500 and 1,000 (1,000 gates).

The base checkpoint's SHA-256 is compared with the full pin in
`subjects.BASES` before anything else (r1 m7). A run is bound to an identity:
config, base pin, adapted parameter names, W6 tuning code, W5 code, the bank
pack, the subject's 10 dictation digests, the profile digest and the profile
build identity, runtime versions and device. A readout stores only the adapted
parameters plus that identity; `load_tuned` rebuilds the network from the
pinned base and refuses any mismatch.

`bundle-run` is the Mac path (DESIGN 7): every input comes from a bundle built
on nixos by `lfspk.personal.macbench bundle`, verified against the bundle's
recorded digests and the pins, with the copied code's hashes compared with the
bundle's (the corpus-dependent identities cannot be recomputed off nixos).
"""

from __future__ import annotations

import os

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import platform  # noqa: E402
import shutil  # noqa: E402
import time  # noqa: E402
from dataclasses import asdict, dataclass, field  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402

from lfspk import paths  # noqa: E402

from . import subjects as S  # noqa: E402

OUT = paths.RUNS / "W6" / "tune"
P_GROUPS = ("proj", "films", "cos_u", "cos_v", "head_norm", "mask_head", "aux_head")
P_COUNT = 186_242
CONFIGS = ("P", "F")
EXPECTED_ALPHA = {"A-V0": 10.0, "A-VB": 3.0}
TUNE_FILES = ("__init__.py", "subjects.py", "signals.py", "stream.py", "tune.py")


@dataclass(frozen=True)
class TuneConfig:
    arm: str
    subject: str
    config: str = "P"
    steps: int = 1000
    batch: int = 8
    crop_frames: int = 800
    lr: float = 3e-4
    warmup: int = 50
    weight_decay: float = 0.0
    clip: float = 5.0
    lambda_aux: float = 0.1
    seed: int = 0
    readouts: tuple[int, ...] = (250, 500, 1000)
    device: str = "cuda"
    threads: int = 2
    tag: str = ""  # output variant ("" = the pilot run; e.g. "cpu" for D5's attribution runs)

    def __post_init__(self):
        if self.arm not in S.ARMS:
            raise ValueError(f"arm must be one of {sorted(S.ARMS)}")
        if self.config not in CONFIGS:
            raise ValueError("config must be P or F")
        if self.subject not in S.pilot_order():
            raise ValueError(f"{self.subject} is not a pilot subject")
        if not self.readouts or max(self.readouts) != self.steps or any(r < 1 or r > self.steps for r in self.readouts):
            raise ValueError("readouts must lie in [1, steps] and end at steps")


PILOT_FIXED = dict(steps=1000, batch=8, crop_frames=800, lr=3e-4, warmup=50, weight_decay=0.0, clip=5.0, lambda_aux=0.1,
                   seed=0, readouts=(250, 500, 1000))


def check_pilot(cfg: TuneConfig) -> None:
    """Production runs must use exactly the pre-registered hyperparameters (DESIGN 4)."""
    for k, v in PILOT_FIXED.items():
        if getattr(cfg, k) != v:
            raise ValueError(f"the pilot fixes {k} = {v}; got {getattr(cfg, k)}")


def lr_at(step: int, cfg: TuneConfig) -> float:
    """Linear warm-up over `warmup` steps (step 0 at lr / warmup), then constant."""
    return cfg.lr * min(1.0, (step + 1) / cfg.warmup)


# --- the base and the adapted set ----------------------------------------------------------

def base_name(arm: str) -> str:
    return S.ARMS[arm][0]


def load_base(path: Path, name: str, pins: dict | None = None):
    """(net, meta, sha) of a base checkpoint whose file SHA-256 equals the full pin."""
    from lfspk.extract.harness_frontend import load_checkpoint

    net, meta, sha = load_checkpoint(Path(path))
    want = (pins or S.BASES)[name]
    if sha != want:
        raise RuntimeError(f"{path}: sha256 {sha} != pinned {want} for {name}")
    return net, meta, sha


def base_path(name: str) -> Path:
    return paths.RUNS / "W5" / "train" / name / "final.pt"


def effective_alpha(meta: dict) -> float:
    return float(meta["identity"]["effective"]["alpha"])


def adapted_names(net, config: str) -> list[str]:
    names = [n for n, _ in net.named_parameters()]
    if config == "F":
        return names
    out = [n for n in names if n.split(".")[0] in P_GROUPS]
    if sum(dict(net.named_parameters())[n].numel() for n in out) != P_COUNT:
        raise RuntimeError("configuration P does not have the registered 186,242 parameters")
    return out


def code_sha256(files=TUNE_FILES) -> str:
    h = hashlib.sha256()
    here = Path(__file__).resolve().parent
    for f in sorted(files):
        h.update(f"{f} {hashlib.sha256((here / f).read_bytes()).hexdigest()}\n".encode())
    return h.hexdigest()


def w5_code_sha256() -> str:
    from lfspk.extract.harness_frontend import code_sha256 as c

    return c()


def runtime() -> dict:
    return {"torch": str(torch.__version__), "numpy": str(np.__version__), "python": platform.python_version(),
            "platform": platform.platform(), "machine": platform.machine()}


# --- data sources ----------------------------------------------------------------------------

@dataclass
class Inputs:
    dictations: list
    bank: object
    profile: np.ndarray
    base_path: Path
    provenance: dict = field(default_factory=dict)  # identity fragments of the inputs


def nixos_inputs(cfg: TuneConfig) -> Inputs:
    """Inputs from the validated render sets, the packed bank and the profile file (nixos)."""
    from .profiles import load as load_profiles
    from .profiles import vec_sha256
    from .render import validated_manifest
    from .stream import Bank, load_dictations
    from .signals import json_sha256

    man = validated_manifest("dict", check_digests=False)
    keys = [f"{cfg.subject}-{j:02d}" for j in range(S.N_TUNE)]
    dicts = load_dictations(cfg.subject)  # digest-checked per file
    bank = Bank(paths.RUNS / "W6" / "render" / "bank_pack")
    prof = load_profiles()[cfg.subject]["p0"]
    pmeta = json.loads((paths.RUNS / "W6" / "profiles" / "profiles.json").read_text())
    prov = {"dict_identity_sha256": man["identity_sha256"], "dict_digests": {k: man["keys"][k] for k in keys},
            "bank_pack_sha256": bank.pack_sha256, "profile_sha256": vec_sha256(prof),
            "profiles_identity_sha256": pmeta["identity_sha256"], "dict_manifest_sha256": json_sha256(man)}
    return Inputs(dicts, bank, prof, base_path(base_name(cfg.arm)), prov)


def identity(cfg: TuneConfig, base_sha: str, alpha: float, names: list[str], inputs: Inputs, code: dict) -> dict:
    d = dict(asdict(cfg))  # threads included: CPU numerics depend on them
    d["readouts"] = list(cfg.readouts)
    return json.loads(json.dumps({
        "kind": "w6-tune", "config": d, "base": base_name(cfg.arm), "base_sha256": base_sha, "alpha": alpha,
        "adapted": names, "n_adapted": None, "inputs": inputs.provenance, "code": code, "runtime": runtime()}))


def identity_sha256(ident: dict) -> str:
    return hashlib.sha256(json.dumps(ident, sort_keys=True).encode()).hexdigest()


# --- training --------------------------------------------------------------------------------

def _determinism(device: str) -> None:
    if device.startswith("cuda"):
        if os.environ.get("CUBLAS_WORKSPACE_CONFIG") != ":4096:8":
            raise RuntimeError("CUBLAS_WORKSPACE_CONFIG must be :4096:8")
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False
    torch.use_deterministic_algorithms(True)


def tune(cfg: TuneConfig, inputs: Inputs, out: Path, code: dict | None = None, mel=None, pins: dict | None = None,
         log_every: int = 50, _keep_net: bool = False) -> dict:
    """Run one fine-tune into `out` (written through a temporary directory and renamed at the end).
    Returns {step: (path, sha256)} of the readouts."""
    from lfspk.extract.data import prepare_batch
    from lfspk.extract.frontend import parakeet_mel_power
    from lfspk.extract.losses import total_loss

    from .stream import make_example, to_example

    out = Path(out)
    if out.exists():
        raise FileExistsError(f"{out} exists; a finished run is never overwritten")
    tmp = out.with_name(out.name + ".partial")
    if tmp.exists():
        shutil.rmtree(tmp)  # an interrupted attempt of this same run; runs restart from step 0
    tmp.mkdir(parents=True)
    torch.set_num_threads(int(cfg.threads))
    if cfg.device.startswith("cuda") and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    _determinism(cfg.device)
    torch.manual_seed(cfg.seed)
    net, meta, sha = load_base(inputs.base_path, base_name(cfg.arm), pins)
    alpha = effective_alpha(meta)
    if alpha != EXPECTED_ALPHA[cfg.arm]:
        raise RuntimeError(f"{cfg.arm}: base alpha {alpha} != {EXPECTED_ALPHA[cfg.arm]}")
    names = adapted_names(net, cfg.config)
    code = code or {"w6_tune_code_sha256": code_sha256(), "w5_code_sha256": w5_code_sha256()}
    ident = identity(cfg, sha, alpha, names, inputs, code)
    ident["n_adapted"] = int(sum(dict(net.named_parameters())[n].numel() for n in names))
    ish = identity_sha256(ident)
    net = net.to(cfg.device).train()
    params = dict(net.named_parameters())
    for n, p in params.items():
        p.requires_grad_(n in names)
    opt = torch.optim.AdamW([params[n] for n in names], lr=cfg.lr, weight_decay=cfg.weight_decay)
    mel = (mel or parakeet_mel_power()).to(cfg.device)
    prof = np.asarray(inputs.profile, np.float32)
    (tmp / "run_meta.json").write_text(json.dumps({"identity": ident, "identity_sha256": ish}, indent=1))
    log = open(tmp / "log.jsonl", "w")
    t0, t_data = time.time(), 0.0
    saved = {}
    if cfg.device.startswith("cuda"):
        torch.cuda.reset_peak_memory_stats()
    try:
        for step in range(cfg.steps):
            td = time.time()
            exs = [to_example(make_example(cfg.subject, step * cfg.batch + i, inputs.dictations, inputs.bank, cfg.seed), prof)
                   for i in range(cfg.batch)]
            b = prepare_batch(exs, mel, cfg.crop_frames, np.random.default_rng([cfg.seed, step, 99]), cfg.device)
            t_data += time.time() - td
            for g in opt.param_groups:
                g["lr"] = lr_at(step, cfg)
            lm, ul = net(b["x"], b["profile"], b["valid"].sum(1).long())
            loss, parts = total_loss(lm, ul, b["ideal"], b["labels"], b["valid"], alpha, cfg.lambda_aux)
            if not torch.isfinite(loss):
                raise FloatingPointError(f"non-finite loss at step {step}")
            opt.zero_grad(set_to_none=True)
            loss.backward()
            gn = float(torch.nn.utils.clip_grad_norm_([params[n] for n in names], cfg.clip))
            opt.step()
            done = step + 1
            if done % log_every == 0 or done == cfg.steps:
                log.write(json.dumps({"step": done, "loss": float(loss.detach()), **parts, "grad_norm": gn,
                                      "lr": lr_at(step, cfg), "elapsed_s": round(time.time() - t0, 2),
                                      "data_s": round(t_data, 2)}) + "\n")
                log.flush()
            if done in cfg.readouts:
                path = tmp / f"step{done}.pt"
                torch.save({"kind": "w6-tuned", "step": done, "identity": ident, "identity_sha256": ish,
                            "adapted": {n: params[n].detach().cpu().clone() for n in names}}, path)
                saved[done] = path.name
    finally:
        log.close()
    res = {"identity_sha256": ish, "wall_s": round(time.time() - t0, 2), "data_s": round(t_data, 2),
           "peak_vram_gib": (torch.cuda.max_memory_allocated() / 2**30) if cfg.device.startswith("cuda") else None,
           "readouts": {str(k): {"file": v, "sha256": _file_sha(tmp / v)} for k, v in saved.items()}}
    (tmp / "result.json").write_text(json.dumps(res, indent=1))
    os.replace(tmp, out)
    if _keep_net:  # test hook: the in-memory trained network (not serialised)
        res = dict(res, _net=net)
    return res


def _file_sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_tuned(path: Path, base: Path | None = None, pins: dict | None = None, expect_identity_sha256: str | None = None):
    """(net in eval mode on CPU, identity, file sha256): the pinned base plus the stored adapted parameters."""
    import io

    raw = Path(path).read_bytes()
    fsha = hashlib.sha256(raw).hexdigest()
    ck = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=True)
    if ck.get("kind") != "w6-tuned":
        raise ValueError(f"{path} is not a W6 tuned readout")
    ident = ck["identity"]
    if identity_sha256(ident) != ck["identity_sha256"]:
        raise RuntimeError("readout identity does not match its digest")
    if expect_identity_sha256 is not None and ck["identity_sha256"] != expect_identity_sha256:
        raise RuntimeError("readout belongs to another run identity")
    name = ident["base"]
    if ident["base_sha256"] != (pins or S.BASES)[name]:
        raise RuntimeError("readout was tuned from an unpinned base")
    net, _, _ = load_base(base or base_path(name), name, pins)
    want = adapted_names(net, ident["config"]["config"])
    if sorted(ck["adapted"]) != sorted(want) or sorted(ident["adapted"]) != sorted(want):
        raise RuntimeError("readout's adapted parameter set differs from its configuration")
    params = dict(net.named_parameters())
    with torch.no_grad():
        for n, v in ck["adapted"].items():
            if params[n].shape != v.shape:
                raise RuntimeError(f"{n}: shape mismatch")
            params[n].copy_(v)
    return net.eval(), ident, fsha


def run_dir(cfg: TuneConfig, root: Path = OUT) -> Path:
    leaf = cfg.subject if not cfg.tag else f"{cfg.subject}-{cfg.tag}"
    return root / cfg.arm / cfg.config / leaf


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("run", "bundle-run", "smoke"))
    ap.add_argument("--arm", required=True, choices=sorted(S.ARMS))
    ap.add_argument("--subject", required=True)
    ap.add_argument("--config", default="P", choices=CONFIGS)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--tag", default="")
    ap.add_argument("--bundle", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--steps", type=int, default=20, help="smoke only")
    a = ap.parse_args(argv)
    if a.cmd == "bundle-run":
        from .macbench import bundle_inputs

        cfg = TuneConfig(arm=a.arm, subject=a.subject, config=a.config, device="cpu", threads=a.threads, tag=a.tag or "mac")
        check_pilot(cfg)
        inputs, code = bundle_inputs(Path(a.bundle), cfg)
        res = tune(cfg, inputs, Path(a.out), code=code)
        from .macbench import require_isolated_bytecode, verify_modules

        res["modules_verified_after_run"] = verify_modules(Path(a.bundle))  # lazily imported modules too (code2-r1 M2)
        require_isolated_bytecode(Path(a.bundle))  # no bytecode was read from or written to anywhere (code2-r2)
    elif a.cmd == "smoke":
        cfg = TuneConfig(arm=a.arm, subject=a.subject, config=a.config, device=a.device, threads=a.threads, steps=a.steps,
                         readouts=(a.steps,), tag="smoke")
        out = Path(a.out) if a.out else OUT / "smoke" / f"{a.arm}-{a.config}-{a.subject}-{time.strftime('%Y%m%dT%H%M%S')}"
        res = tune(cfg, nixos_inputs(cfg), out, log_every=1)
    else:
        cfg = TuneConfig(arm=a.arm, subject=a.subject, config=a.config, device=a.device, threads=a.threads, tag=a.tag)
        check_pilot(cfg)
        res = tune(cfg, nixos_inputs(cfg), run_dir(cfg))
    print(json.dumps(res, indent=1), flush=True)


if __name__ == "__main__":
    main()
