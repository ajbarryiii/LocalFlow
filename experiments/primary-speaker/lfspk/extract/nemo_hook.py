"""Stage B: Parakeet transcription with a stored W5 mask (DESIGN section 10.2).

Entry point for the harness:

    results = transcribe_masked(model, audios, mask_outputs, config, batch_size=16)

returns, per input recording, W0's `{"text", "words"}` record, or None where
`config` bypasses the recording. A bypassed recording is never transcribed;
the harness copies B's cached record and pins it (`cachepin`).

How it works. `MaskedPreprocessor` replaces `model.preprocessor` for the
duration of the call. Items are identified by position, not by content:
`transcribe_masked` sorts the non-bypassed items by length, cuts them into
batches, and for each batch declares the rows (`set_rows`) and then calls W0's
`lfspk.harness.asr.transcribe` on exactly those recordings with
`batch_size = len(batch)`, so NeMo makes one forward pass whose row i is item i.
The hook consumes the declaration in that one forward pass and verifies
every row: its reported length must equal the item's length, and the SHA-256
of its samples must equal the item's. Any mismatch raises, for example NeMo's
padding of sub-second inputs, a reordering, or a second forward pass. There is
no fallback. Recordings shorter than 1 s are refused up front, because NeMo's
transcription dataset pads them to 1 s, which would shift the mask's timing.
Duplicate recordings are fine: rows are positional.

Features: NeMo's own FilterbankFeatures is stopped at the power spectrum
(`linear_spec=True`), then NeMo's own steps continue (filterbank matmul, log
guard, `normalize_batch`, padding mask, pad_to), with the mask multiplied onto
the mel power before the log. At log_mask = 0 the result is NeMo's output bit
for bit within the same batch.

Batch-context effects on masked items (padding, reduction order) are a harness
artefact, absent from LocalFlow's single-recording path, and are not
quantified here (DESIGN section 10.2).
"""

from __future__ import annotations

import hashlib
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Callable, Sequence

import numpy as np
import torch

from .api import N_MELS, InferenceConfig, MaskOutput, check_mask_output, feature_frames

MIN_SAMPLES = 16_000  # NeMo's TranscriptionTensorDataset pads shorter inputs to 1 s


def hook_code_sha256() -> str:
    """Content hash of the code stage B's features depend on (this module,
    frontend.py, api.py, constants.py, and W3's front-end constants module that
    frontend.py imports), for the ASR cache identity."""
    from pathlib import Path

    lfspk_dir = Path(__file__).resolve().parents[1]
    h = hashlib.sha256()
    for rel in ("extract/api.py", "extract/constants.py", "extract/frontend.py", "extract/nemo_hook.py", "pvad/features.py"):
        h.update(f"{rel} {hashlib.sha256((lfspk_dir / rel).read_bytes()).hexdigest()}\n".encode())
    return h.hexdigest()


def audio_sha256(audio) -> str:
    a = np.ascontiguousarray(np.asarray(audio), dtype=np.float32)
    return hashlib.sha256(a.tobytes()).hexdigest()


@dataclass(frozen=True)
class Row:
    """One declared batch row: the recording's length and sample hash, and its
    mask (log_mask [128, N // 160 + 1] with w [N // 160 + 1]) or None for a row
    that keeps NeMo's features."""

    n: int
    sha256: str
    log_mask: torch.Tensor | None
    w: torch.Tensor | None

    @classmethod
    def make(cls, audio: np.ndarray, log_mask: np.ndarray | None, w: np.ndarray | None) -> "Row":
        n = int(np.asarray(audio).shape[0])
        t = feature_frames(n)
        if (log_mask is None) != (w is None):
            raise ValueError("log_mask and w must both be given, or both be None")
        if log_mask is None:
            return cls(n, audio_sha256(audio), None, None)
        lm = np.asarray(log_mask, dtype=np.float32)
        wv = np.asarray(w, dtype=np.float32)
        if lm.shape != (N_MELS, t) or wv.shape != (t,):
            raise ValueError(f"mask shapes must be [{N_MELS}, {t}] and [{t}]")
        if not (np.isfinite(lm).all() and np.isfinite(wv).all()):
            raise ValueError("mask must be finite")
        return cls(n, audio_sha256(audio), torch.from_numpy(lm.copy()), torch.from_numpy(wv.copy()))


class MaskedPreprocessor(torch.nn.Module):
    def __init__(self, base: torch.nn.Module):
        super().__init__()
        if getattr(base, "featurizer", None) is None:
            raise TypeError("base must be a NeMo AudioToMelSpectrogramPreprocessor")
        self.base = base
        self._rows: list[Row] | None = None
        self.calls = 0
        self.rows_masked = 0
        self.rows_kept = 0

    @classmethod
    def install(cls, model) -> "MaskedPreprocessor":
        if isinstance(model.preprocessor, cls):
            raise RuntimeError("a MaskedPreprocessor is already installed")
        hook = cls(model.preprocessor)
        model.preprocessor = hook
        return hook

    @staticmethod
    def uninstall(model) -> None:
        if isinstance(model.preprocessor, MaskedPreprocessor):
            model.preprocessor = model.preprocessor.base

    def set_rows(self, rows: Sequence[Row]) -> None:
        """Declare the rows of the next (and only the next) forward pass, in order."""
        if self._rows is not None:
            raise RuntimeError("previous rows were never consumed")
        self._rows = list(rows)

    @property
    def pending(self) -> bool:
        return self._rows is not None

    def _check_featurizer(self, f) -> None:
        if f.training or getattr(f, "frame_splicing", 1) != 1 or getattr(f, "nb_augmentation_prob", 0.0) > 0:
            raise RuntimeError("the wrapped featurizer must be in eval mode without splicing or augmentation")
        if not f.log or f.log_zero_guard_type != "add" or f.normalize != "per_feature":
            raise RuntimeError("expected Parakeet's featurizer settings (log, add guard, per_feature)")

    def forward(self, input_signal: torch.Tensor, length: torch.Tensor):
        from nemo.collections.asr.parts.preprocessing.features import normalize_batch

        rows, self._rows = self._rows, None
        if rows is None:
            raise RuntimeError("forward pass without declared rows")
        self.calls += 1
        if input_signal.shape[0] != len(rows):
            raise RuntimeError(f"batch has {input_signal.shape[0]} rows, {len(rows)} were declared")
        lens = length.detach().cpu().long()
        cpu = input_signal.detach().to(torch.float32).cpu()
        for i, r in enumerate(rows):
            if int(lens[i]) != r.n:
                raise RuntimeError(f"row {i}: length {int(lens[i])} != declared {r.n} (padded or reordered by the loader?)")
            if audio_sha256(cpu[i, : r.n].numpy()) != r.sha256:
                raise RuntimeError(f"row {i}: samples differ from the declared recording")
        check_devices(self.base, input_signal, length)
        base_out, base_len = self.base(input_signal=input_signal, length=length)
        if all(r.log_mask is None for r in rows):
            self.rows_kept += len(rows)
            return base_out, base_len
        f = self.base.featurizer
        self._check_featurizer(f)
        power, seq_len = f(input_signal.to(torch.float32), length, linear_spec=True)  # NeMo's own STFT and power
        with torch.amp.autocast(power.device.type, enabled=False):
            mel = torch.matmul(f.fb.to(power.dtype), power)  # [B, 128, T]
        t = mel.shape[-1]
        factor = torch.ones_like(mel)
        for i, r in enumerate(rows):
            if r.log_mask is None:
                continue
            ti = feature_frames(r.n)
            if ti > t:
                raise ValueError(f"row {i}: mask has {ti} frames, the batch only {t}")
            factor[i, :, :ti] = torch.exp(r.w[None, :].to(mel.device) * r.log_mask.to(mel.device))
        mel = mel * factor
        mel = torch.log(mel + f.log_zero_guard_value_fn(mel))
        mel, _, _ = normalize_batch(mel, seq_len, normalize_type=f.normalize)
        pad = torch.arange(t, device=mel.device)[None, :] >= seq_len[:, None]
        mel = mel.masked_fill(pad[:, None, :], f.pad_value)
        pad_to = f.pad_to
        if pad_to == "max":
            mel = torch.nn.functional.pad(mel, (0, f.max_length - mel.size(-1)), value=f.pad_value)
        elif pad_to > 0 and mel.size(-1) % pad_to != 0:
            mel = torch.nn.functional.pad(mel, (0, pad_to - mel.size(-1) % pad_to), value=f.pad_value)
        if mel.shape != base_out.shape or not torch.equal(seq_len, base_len):
            raise AssertionError("masked features disagree with NeMo's output shape or lengths")
        keep = torch.tensor([r.log_mask is None for r in rows], device=mel.device)
        self.rows_kept += int(keep.sum())
        self.rows_masked += int((~keep).sum())
        out = torch.where(keep[:, None, None], base_out.to(mel.dtype), mel)
        return out.to(base_out.dtype), base_len


def check_devices(pre: torch.nn.Module, input_signal: torch.Tensor, length: torch.Tensor) -> None:
    """Every buffer and parameter of the wrapped preprocessor, and the inputs,
    must be on one device. NeMo would otherwise fail deep inside its featurizer
    (w5-smoke-hook, 2026-10-22: fb on cuda:0, input on cpu)."""
    devs = {str(t.device) for t in list(pre.buffers()) + list(pre.parameters())}
    devs |= {str(input_signal.device), str(length.device)}
    if len(devs) > 1:
        where = {n: str(t.device) for n, t in list(pre.named_buffers()) + list(pre.named_parameters())}
        raise RuntimeError(f"preprocessor and inputs on different devices: input {input_signal.device}, "
                           f"length {length.device}, preprocessor {where}")


def cpu_preprocessor(model) -> torch.nn.Module:
    """A fresh CPU copy of the model's NeMo preprocessor: rebuilt from the
    model's own preprocessor config and loaded with its state (window, fb) moved
    to CPU, so nothing depends on deep-copying CUDA modules. Every buffer is
    checked to be on CPU."""
    pre = model.preprocessor
    pre = getattr(pre, "base", pre) if isinstance(pre, MaskedPreprocessor) else pre
    fresh = model.from_config_dict(model.cfg.preprocessor)
    fresh.load_state_dict({k: v.detach().cpu() for k, v in pre.state_dict().items()}, strict=True)
    fresh = fresh.cpu().eval()
    bad = {n: str(t.device) for n, t in list(fresh.named_buffers()) + list(fresh.named_parameters())
           if t.device.type != "cpu"}
    if bad:
        raise RuntimeError(f"CPU preprocessor copy has tensors elsewhere: {bad}")
    return fresh


@contextmanager
def installed(model):
    hook = MaskedPreprocessor.install(model)
    try:
        yield hook
    finally:
        MaskedPreprocessor.uninstall(model)


def transcribe_masked(model, audios: Sequence[np.ndarray], mask_outputs: Sequence[MaskOutput],
                      config: InferenceConfig, batch_size: int = 16, transcribe: Callable | None = None,
                      expected_constants: tuple[np.ndarray, np.ndarray] | None = None) -> list[dict | None]:
    """Per recording: W0's {"text", "words"} transcript with the mask applied
    under `config`, or None if `config` bypasses it (not transcribed).
    `transcribe(model, audios, batch_size)` defaults to W0's
    `lfspk.harness.asr.transcribe` (same decoding and timestamps as B). The
    model's front-end buffers must equal `expected_constants` (default: the
    pinned constants `apply` uses), else this refuses."""
    from .constants import check_model
    from .frontend import weights

    if transcribe is None:
        from lfspk.harness.asr import transcribe as transcribe
    if isinstance(batch_size, bool) or not isinstance(batch_size, (int, np.integer)) or batch_size < 1:
        raise ValueError(f"batch_size must be a positive integer, got {batch_size!r}")
    if len(audios) != len(mask_outputs):
        raise ValueError("audios and mask_outputs differ in length")
    check_model(model, expected_constants)
    rows: list[Row | None] = []
    for a, mo in zip(audios, mask_outputs):
        n = int(np.asarray(a).shape[0])
        check_mask_output(mo, n)
        w = weights(mo.u, n, config)
        if w is None:
            rows.append(None)
            continue
        if n < MIN_SAMPLES:
            raise ValueError(f"recording of {n} samples is shorter than 1 s; NeMo would pad it, W5 refuses")
        rows.append(Row.make(a, mo.log_mask, w))
    todo = sorted((i for i, r in enumerate(rows) if r is not None), key=lambda i: rows[i].n)
    out: list[dict | None] = [None] * len(audios)
    with installed(model) as hook:
        for s in range(0, len(todo), batch_size):
            idx = todo[s: s + batch_size]
            hook.set_rows([rows[i] for i in idx])
            calls = hook.calls
            res = transcribe(model, [np.asarray(audios[i], dtype=np.float32) for i in idx], batch_size=len(idx))
            if hook.pending or hook.calls != calls + 1:
                raise RuntimeError("NeMo did not make exactly one forward pass for the declared batch")
            if len(res) != len(idx):
                raise RuntimeError("transcription returned a different number of results")
            for i, r in zip(idx, res):
                if r is None:
                    raise RuntimeError("transcription returned no record for a masked recording")
                out[i] = r
    missing = [i for i, r in enumerate(rows) if r is not None and out[i] is None]
    if missing:
        raise RuntimeError(f"{len(missing)} masked recordings got no transcript")
    return out
