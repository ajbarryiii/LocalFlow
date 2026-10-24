"""W5's FeatureFrontEnd and its harness factory (DESIGN sections 6, 8, 10.1).

    lfspk.extract.harness_frontend:make checkpoint=/mnt/hd/.../final.pt [norm=raw] [device=cpu]

Profiles are W1's: `lfspk.embed.factory:make(embedder="redimnet2-b2",
rule="robust", norm=..., head="score", window="1.5", hop="0.25", C="1.0",
cache="0")`, of which only enroll/update are used; the conditioning vector is
`profile.directions[0]` (the unit centroid). W5 stores nothing beyond W1's
profile. `analyse` runs the mask network on Parakeet's features of the whole
recording on CPU.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any, Sequence

import numpy as np
import torch

from lfspk.api import CostReport, check_audio

from .api import MaskOutput, check_mask_output, valid_frames
from .frontend import features_np
from .model import MaskNet, MaskNetConfig, macs_per_second, param_count, per_recording_macs

W1_DEFAULTS = dict(embedder="redimnet2-b2", rule="robust", norm="raw", head="score", window="1.5", hop="0.25", C="1.0")
CHECKPOINT_KIND = "w5-masknet"


def code_sha256() -> str:
    """Content hash of lfspk/extract/*.py (sorted), for identities."""
    here = Path(__file__).resolve().parent
    h = hashlib.sha256()
    for p in sorted(here.glob("*.py")):
        h.update(f"{p.name} {hashlib.sha256(p.read_bytes()).hexdigest()}\n".encode())
    return h.hexdigest()


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def save_checkpoint(path: Path, net: MaskNet, meta: dict[str, Any]) -> None:
    """Model weights plus JSON-safe metadata (training identity, steps, ...)."""
    torch.save({"kind": CHECKPOINT_KIND, "config": net.cfg.to_dict(),
                "state_dict": {k: v.detach().cpu() for k, v in net.state_dict().items()}, "meta": meta}, path)


def load_checkpoint(path: Path) -> tuple[MaskNet, dict[str, Any], str]:
    """(net in eval mode on CPU, meta, file SHA-256). Reads the file once and
    deserialises the verified bytes."""
    import io

    raw = Path(path).read_bytes()
    sha = hashlib.sha256(raw).hexdigest()
    ck = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=True)
    if ck.get("kind") != CHECKPOINT_KIND:
        raise ValueError(f"{path} is not a W5 mask-network checkpoint")
    net = MaskNet(MaskNetConfig(**ck["config"]))  # configs written before `head` existed default to "sigmoid"
    net.load_state_dict(ck["state_dict"], strict=True)
    return net.eval(), ck.get("meta", {}), sha


def run_mask(net: MaskNet, audio: np.ndarray, emb: np.ndarray | None) -> tuple[np.ndarray, np.ndarray]:
    """(log_mask, u) of one recording: Parakeet's features, the network, sigmoid(u)
    zeroed past the valid frames. Runs with ONE torch thread, restoring the
    caller's setting afterwards: results differ in the last bits between 1 and
    more threads, and stage A caches must be reproducible (review implI2-r2 #1).
    Shared by `ExtractFrontEnd.analyse` and theta_b calibration."""
    n = int(audio.shape[0])
    m = valid_frames(n)
    prev = torch.get_num_threads()
    torch.set_num_threads(1)
    try:
        with torch.no_grad():
            x = torch.from_numpy(features_np(audio))[None]
            e = None if net.cfg.conditioning == "none" else torch.from_numpy(np.asarray(emb, dtype=np.float32))[None]
            lm, ul = net(x, e, torch.tensor([m]))
            u = torch.sigmoid(ul)[0]
            u[m:] = 0.0
            return lm[0].numpy().astype(np.float32), u.numpy().astype(np.float32)
    finally:
        torch.set_num_threads(prev)


class ExtractFrontEnd:
    """FeatureFrontEnd: W1 profile + W5 mask network."""

    def __init__(self, net: MaskNet, profiler, checkpoint: str = "", checkpoint_sha256: str = "",
                 profiler_settings: dict | None = None, meta: dict | None = None, theta_b: float | None = None):
        self.net = net.eval()
        self.theta_b = theta_b
        self.profiler = profiler
        self.checkpoint = checkpoint
        self.checkpoint_sha256 = checkpoint_sha256
        self.profiler_settings = dict(profiler_settings or {})
        self.meta = dict(meta or {})
        self.name = f"w5-mask-{net.cfg.conditioning}-C{net.cfg.channels}-{checkpoint_sha256[:12] or 'untrained'}"

    def enroll(self, utterances: Sequence[np.ndarray]):
        return self.profiler.enroll(utterances)

    def update(self, profile, utterance: np.ndarray):
        return self.profiler.update(profile, utterance)

    def conditioning(self, profile) -> np.ndarray:
        e = np.asarray(profile.directions[0], dtype=np.float32)
        if e.shape != (self.net.cfg.emb_dim,) or not np.isfinite(e).all():
            raise ValueError("profile direction has the wrong shape or is not finite")
        return e

    def analyse(self, profile, audio: np.ndarray) -> MaskOutput:
        """Deterministic on CPU: always one torch thread (`run_mask`), whatever
        the caller's setting (`identity()["analyse_threads"]`)."""
        check_audio(audio)
        emb = None if self.net.cfg.conditioning == "none" else self.conditioning(profile)
        lm, u = run_mask(self.net, audio, emb)
        return check_mask_output(MaskOutput(lm, u), int(audio.shape[0]))

    def cost(self) -> CostReport:
        base = self.profiler.cost()
        own = param_count(self.net)
        return CostReport(
            params=int(own + base.params), macs_per_audio_second=float(macs_per_second(self.net.cfg)),
            update_macs=float(base.update_macs), profile_bytes=int(base.profile_bytes), reads_parakeet_layers=(),
            notes=(f"mask network {own} params (W1 profile path adds {base.params}); macs_per_audio_second counts the "
                   f"mask network only (per recording +{per_recording_macs(self.net.cfg):.0f} MACs; the extra "
                   "log-and-normalise pass is element-wise); Parakeet's features are reused, not recomputed; "
                   "update_macs and profile_bytes are W1's profile path; W5 stores nothing else"))

    def config(self, name: str):
        """The InferenceConfig for C1-C4. theta_b is the checkpoint's own (fixed on
        held-out train speakers by `lfspk.extract.calibrate theta`), never a
        caller's value; C3 and C4 need it."""
        from .api import InferenceConfig

        if name in ("C3", "C4") and self.theta_b is None:
            raise ValueError(f"{name} needs theta_b; none is calibrated for this checkpoint")
        return InferenceConfig(name, self.theta_b if name in ("C3", "C4") else None)

    def identity(self) -> dict:
        import copy

        return {"kind": "w5-frontend", "name": self.name, "checkpoint": self.checkpoint,
                "checkpoint_sha256": self.checkpoint_sha256, "model_config": self.net.cfg.to_dict(),
                "w5_code_sha256": code_sha256(), "profiler": copy.deepcopy(self.profiler_settings),
                "training_identity_sha256": self.meta.get("identity_sha256", ""), "theta_b": self.theta_b,
                "run": self.meta.get("run"), "seed": self.meta.get("seed"),
                "analyse_threads": 1}


def make(checkpoint: str, embedder: str = W1_DEFAULTS["embedder"], norm: str = W1_DEFAULTS["norm"],
         rule: str = W1_DEFAULTS["rule"], head: str = W1_DEFAULTS["head"], window: str = W1_DEFAULTS["window"],
         hop: str = W1_DEFAULTS["hop"], C: str = W1_DEFAULTS["C"], device: str = "cpu", runs: str = "") -> ExtractFrontEnd:
    """Harness factory (string kwargs). The profile path is W1's factory with
    cache=0; the checkpoint's embedder must be the one named here. `runs` is
    W1's run root (default RUNS/W1), passed to W1's factory and used to resolve
    the hashed W1 artefacts, so both read the same files."""
    from lfspk.embed.factory import make as w1_make

    net, meta, sha = load_checkpoint(Path(checkpoint))
    trained_with = meta.get("embedder")
    if trained_with and trained_with != embedder:
        raise ValueError(f"checkpoint trained with {trained_with}, profile embedder {embedder}")
    settings = dict(embedder=embedder, norm=norm, rule=rule, head=head, window=window, hop=hop, C=C, cache="0")
    from lfspk import paths

    # the effective W1 root, resolved the same way whether it was given explicitly or not, so equal
    # files give an equal identity (sol stepbudget-r3)
    root = (Path(runs) if runs else paths.RUNS / "W1").resolve()
    before = w1_artifact_sha256s(embedder, norm, rule, head, window, hop, C, root=root)
    profiler = w1_make(device=device, runs=str(root), **settings)
    after = w1_artifact_sha256s(embedder, norm, rule, head, window, hop, C, root=root)
    if before != after:
        raise RuntimeError("W1 artifacts changed while the profile path was being built")
    settings["profiler_name"] = getattr(profiler, "name", "")
    settings["w1_artifact_sha256"] = after
    settings["w1_code_sha256"] = w1_code_sha256()
    settings["w1_runs_root"] = str(root)
    w = getattr(profiler, "embedder", None)
    if w is not None and getattr(w, "weights_sha256", None):
        settings["embedder_weights_sha256"] = w.weights_sha256
    return ExtractFrontEnd(net, profiler, str(Path(checkpoint).resolve()), sha, settings, meta,
                           read_theta_b(Path(checkpoint), sha))


def w1_artifact_paths(embedder: str, norm: str, rule: str, head: str, window: str, hop: str, C: str,
                      root: Path | None = None) -> dict[str, Path]:
    """Every W1 file `lfspk.embed.factory.make` reads for these kwargs (factory.py:
    the head and its provenance sidecar, the update gates unless rule is naive,
    the AS-norm cohort files when norm is asnorm), resolved as the factory does."""
    from lfspk import paths
    from lfspk.embed.adapt import gates_path
    from lfspk.embed.head import _tag

    root = root or paths.RUNS / "W1"
    head_file = root / "head" / _tag(embedder, float(window), float(hop)) / f"head_{norm}_{rule}_{head}_C{float(C)}.json"
    out = {"head": head_file, "head_sidecar": head_file.with_suffix(".meta.json")}
    if rule != "naive":
        out["gates"] = gates_path(embedder, norm, root / "adapt")
    if norm == "asnorm":
        d = root / "survey" / "emb" / embedder
        out.update(cohort_full=d / "cohort_full.f32.npy", cohort_seg=d / "cohort_seg.f32.npy",
                   cohort_seg_tsv=d / "cohort_seg.tsv")
    return out


def w1_artifact_sha256s(*args, **kwargs) -> dict[str, str | None]:
    """Content SHA-256 of each W1 artifact the profile path reads (None if a
    file does not exist; the factory refuses or treats it as absent)."""
    return {k: (file_sha256(p) if p.is_file() else None) for k, p in w1_artifact_paths(*args, **kwargs).items()}


def w1_code_sha256() -> str:
    """Content hash of every module of the lfspk.embed package (the code enroll and
    update run; the vendored model sources are pinned by W1's own hashes)."""
    root = Path(__file__).resolve().parents[1]
    h = hashlib.sha256()
    for p in sorted((root / "embed").rglob("*.py")):
        if "__pycache__" in p.parts:
            continue
        h.update(f"{p.relative_to(root)} {file_sha256(p)}\n".encode())
    return h.hexdigest()


def read_theta_b(checkpoint: Path, sha: str) -> float | None:
    """theta_b from `theta_b.json` beside the checkpoint (written by
    `lfspk.extract.calibrate theta`), which must name this checkpoint's SHA-256;
    None if the checkpoint has not been calibrated."""
    import json

    p = Path(checkpoint).parent / "theta_b.json"
    if not p.is_file():
        return None
    d = json.loads(p.read_text())
    if d.get("checkpoint_sha256") != sha:
        raise ValueError(f"{p} belongs to another checkpoint")
    th = float(d["theta_b"])
    if not 0.0 <= th <= 1.0:
        raise ValueError("theta_b outside [0, 1]")
    return th
