"""The front-end contract (DESIGN.md section 10.1; CONTRACT.md "Front ends that change the transcript").

A front end learns the user's voice like a scorer (`enroll`, `update`) and, for
a recording, returns a mask on Parakeet's mel power plus a per-frame
interference probability (`analyse`). The pure function
`lfspk.extract.frontend.apply` turns a stored `MaskOutput` and an
`InferenceConfig` into the features Parakeet's encoder sees, or None when the
configuration bypasses the recording (the harness then uses B's cached
transcript, pinned by `lfspk.extract.cachepin`).

Frames here are Parakeet's feature frames: N // 160 + 1 for N samples, of
which the first M = N // 160 are valid (Parakeet zeroes the rest). Contract
frame i (samples [160 i, 160 i + 160)) is feature frame i.

How the harness uses it (W0 builds this; W5 supplies the pieces named here):

1. Factory. A front end is built like a scorer, `MODULE:CALLABLE(**kwargs)`
   with string kwargs, e.g. `lfspk.extract.harness_frontend:make
   checkpoint=/path/to/ckpt.pt`. The object satisfies `FeatureFrontEnd`.
   `identity()` returns a JSON-safe dict (checkpoint path and SHA-256, model
   config, W5 code hash, embedder and profile settings) that keys stage A.
2. Stage A (CPU). For each enrollment condition, `enroll(first k)` and then
   `update` per further dictation, exactly as for scorers; then
   `analyse(profile, mixture_audio) -> MaskOutput` per mixture. Store
   `log_mask` as float16 and `u` as float32 (DESIGN 10.2).
3. Bypass decision. `lfspk.extract.frontend.bypassed(mask_output, n, config)`
   (equivalently `apply(...) is None`). A bypassed mixture is never sent to
   stage B; its entry is B's cached record, copied and pinned with
   `lfspk.extract.cachepin.pin_bypass` and re-checked on every load with
   `cachepin.verify_bypass`.
4. Stage B (GPU). `lfspk.extract.nemo_hook.transcribe_masked(model, audios,
   mask_outputs, config, batch_size=16)` returns W0's {"text", "words"} per
   recording, or None for a bypassed one (not transcribed). It installs the
   hook, sorts the masked recordings by length, and calls W0's
   `lfspk.harness.asr.transcribe` once per batch with the rows declared in
   order. Every row is verified (length and sample hash), and any mismatch
   raises. Recordings shorter than 1 s are refused (NeMo would pad them), and
   duplicates are fine. The ASR cache identity comes from
   `cachepin.frontend_cache_identity(...)` with `nemo_hook.hook_code_sha256()`
   and batching mode `batched`; headline loaders call
   `cachepin.require_headline`.
5. `apply(audio, mask_output, config)` is the reference for what the hook
   computes (one recording, CPU, with the checkpoint's own front-end
   constants from `lfspk.extract.constants`). With the same constants the two
   are equal exactly (tests; the smoke checks it on the restored model).
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from typing import Protocol, Sequence, runtime_checkable

import numpy as np

from lfspk.api import CostReport, Profile

N_MELS = 128
HOP = 160
G_MIN_DB = -30.0  # DESIGN section 3: fixed, no sweep
G_MIN = 10.0 ** (G_MIN_DB / 10.0)
LOG_G_MIN = math.log(G_MIN)
SMOOTH_FRAMES = 51  # centred 0.5 s moving average of u (+-25 frames)
CONFIGS = ("C1", "C2", "C3", "C4")


def feature_frames(num_samples: int) -> int:
    """Parakeet feature frames of a recording: N // 160 + 1."""
    if num_samples < 0:
        raise ValueError("negative sample count")
    return num_samples // HOP + 1


def valid_frames(num_samples: int) -> int:
    """Frames Parakeet normalises over and keeps: N // 160."""
    return num_samples // HOP


@dataclass(frozen=True)
class MaskOutput:
    """What `analyse` returns and stage A stores.

    log_mask: float32 [128, N // 160 + 1], natural log of the mask m on mel
        power, in [LOG_G_MIN, 0].
    u: float32 [N // 160 + 1], probability that speech of anyone other than
        the profile's speaker is present, in [0, 1].
    """

    log_mask: np.ndarray
    u: np.ndarray


@dataclass(frozen=True)
class InferenceConfig:
    """The safeguard configuration (DESIGN section 7).

    C1: raw mask, w = 1 everywhere, no bypass.
    C2: adaptive w(t) = ubar(t), no bypass.
    C3: bypass + adaptive, s = 1.
    C4: bypass + adaptive, s = 0.5.
    theta_b: bypass threshold on max_t ubar (fixed per checkpoint on held-out
        train speakers); required for C3 and C4, ignored otherwise.
    """

    name: str
    theta_b: float | None = None

    def __post_init__(self):
        if self.name not in CONFIGS:
            raise ValueError(f"unknown configuration {self.name!r}")
        if self.bypass:
            if self.theta_b is None or not (0.0 <= float(self.theta_b) <= 1.0) or not math.isfinite(float(self.theta_b)):
                raise ValueError(f"{self.name} needs theta_b in [0, 1]")

    @property
    def bypass(self) -> bool:
        return self.name in ("C3", "C4")

    @property
    def adaptive(self) -> bool:
        return self.name != "C1"

    @property
    def strength(self) -> float:
        return 0.5 if self.name == "C4" else 1.0

    def to_dict(self) -> dict:
        return asdict(self)


def check_mask_output(out: MaskOutput, num_samples: int, tol: float = 1e-4) -> MaskOutput:
    """Validate an analyse() result against the contract (float16-stored masks
    are accepted and compared with a tolerance that covers their rounding)."""
    t = feature_frames(num_samples)
    lm, u = np.asarray(out.log_mask), np.asarray(out.u)
    if lm.shape != (N_MELS, t):
        raise ValueError(f"log_mask must be [{N_MELS}, {t}], got {lm.shape}")
    if u.shape != (t,):
        raise ValueError(f"u must be [{t}], got {u.shape}")
    if lm.dtype not in (np.float32, np.float16) or u.dtype != np.float32:
        raise TypeError("log_mask must be float32 or float16 and u float32")
    lm32 = lm.astype(np.float32)
    if not np.isfinite(lm32).all() or not np.isfinite(u).all():
        raise ValueError("mask output must be finite")
    tol_lm = max(tol, 0.01) if lm.dtype == np.float16 else tol
    if lm32.min() < LOG_G_MIN - tol_lm or lm32.max() > tol_lm:
        raise ValueError("log_mask outside [log g_min, 0]")
    if u.min() < 0.0 or u.max() > 1.0:
        raise ValueError("u outside [0, 1]")
    return out


@runtime_checkable
class FeatureFrontEnd(Protocol):
    name: str

    def enroll(self, utterances: Sequence[np.ndarray]) -> Profile:
        ...

    def update(self, profile: Profile, utterance: np.ndarray) -> Profile:
        ...

    def analyse(self, profile: Profile, audio: np.ndarray) -> MaskOutput:
        """CPU, deterministic; non-causal over the whole recording."""
        ...

    def cost(self) -> CostReport:
        ...

    def identity(self) -> dict:
        """JSON-safe identity of everything `analyse` depends on (checkpoint path
        and SHA-256, model config, W5 code hash, profile settings)."""
        ...
