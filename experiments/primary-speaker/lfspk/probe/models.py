"""Parakeet weights (base FP32 and the shipped ternary M1 export) and layer taps.

NeMo is imported lazily so the pure parts of the package (and their tests) run
under ./python. See DESIGN.md section 2 for which weights ship where.
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

import torch

from lfspk import paths

from . import N_TAPS
from .pooling import mean_std

M1_EXPORT = Path("/mnt/hd/wilderness-labs-stt/parakeet-ternary/runs/main-M1-P2-lr5e-4/export")
M1_EXPORT_SHA256 = "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503"  # LocalFlow INTEGRATION.md
M1_FORMAT = "parakeet-ternary-v1"
TITANET_S = paths.DATA / "models" / "titanet-s" / "titanet-s.nemo"  # pinned read-only copy (W1 provenance)
TITANET_S_SHA256 = "c9d82e1bffb53b240f2ca33c1eff23867869bebadb3ab0f834cc11be83a73ffe"

_SHIFTS = torch.tensor([0, 2, 4, 6], dtype=torch.uint8)


def sha256_file(path: Path) -> str:
    with open(path, "rb") as fh:
        return hashlib.file_digest(fh, "sha256").hexdigest()


def unpack_codes(packed: torch.Tensor, in_features: int) -> torch.Tensor:
    """uint8 [out, ceil(in/4)] -> int8 [out, in] in {-1, 0, 1}.

    Format parakeet-ternary-v1: 2-bit fields, code j at bits 2*(j % 4) of byte
    j // 4; 00 -> 0, 01 -> +1, 10 -> -1, 11 invalid; tail padding must be 0.
    """
    if packed.dtype != torch.uint8 or packed.dim() != 2 or packed.shape[1] != math.ceil(in_features / 4):
        raise ValueError(f"expected uint8 [out, {math.ceil(in_features / 4)}], got {packed.dtype} {tuple(packed.shape)}")
    fields = ((packed[..., None] >> _SHIFTS) & 3).flatten(1)
    if (fields == 3).any() or fields[:, in_features:].any():
        raise ValueError("invalid packed codes")
    fields = fields[:, :in_features]
    return (fields == 1).to(torch.int8) - (fields == 2).to(torch.int8)


def m1_state_dict(export_dir: Path = M1_EXPORT) -> tuple[dict[str, torch.Tensor], dict]:
    """Dequantized FP32 state dict and manifest of the shipped export; hashes verified."""
    from safetensors.torch import load_file

    manifest = json.loads((export_dir / "manifest.json").read_text())
    if manifest["format"] != M1_FORMAT:
        raise ValueError(f"unknown export format {manifest['format']!r}")
    if manifest["files"]["export.safetensors"] != M1_EXPORT_SHA256:
        raise ValueError("manifest does not describe the shipped export")
    for rel, digest in manifest["files"].items():
        if sha256_file(export_dir / rel) != digest:
            raise ValueError(f"{rel} does not match the manifest SHA-256")
    tensors = load_file(export_dir / manifest["file"])
    state: dict[str, torch.Tensor] = {}
    for name, layer in manifest["quantized_layers"].items():
        out_f, in_f = layer["shape"]
        codes = unpack_codes(tensors.pop(f"{name}.codes"), in_f)
        weight = codes.float() * tensors.pop(f"{name}.scale").float()[:, None]
        state[f"{name}.weight"] = weight.unsqueeze(2) if layer["kind"] == "pointwise_conv1d" else weight
        if layer["bias"]:
            state[f"{name}.bias"] = tensors.pop(f"{name}.bias")
    state.update((k, v.float() if v.is_floating_point() else v) for k, v in tensors.items())
    return state, manifest


def _strict_fp32() -> None:
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cudnn.benchmark = False


def load_parakeet(weights: str, device: str = "cuda"):
    """'base' (NVIDIA FP32 checkpoint) or 'm1' (shipped ternary export, FP32 arithmetic)."""
    _strict_fp32()
    from nemo.collections.asr.models import ASRModel, EncDecRNNTBPEModel
    from omegaconf import OmegaConf, open_dict

    if weights == "base":
        model = ASRModel.restore_from(str(paths.PARAKEET_V2_NEMO), map_location="cpu")
    elif weights == "m1":
        state, manifest = m1_state_dict()
        cfg = OmegaConf.create(manifest["config"])
        with open_dict(cfg):
            tok = M1_EXPORT / "tokenizer"
            cfg.tokenizer.dir = str(tok)
            cfg.tokenizer.model_path = str(tok / "tokenizer.model")
            cfg.tokenizer.vocab_path = str(tok / "vocab.txt")
            cfg.tokenizer.spe_tokenizer_vocab = str(tok / "tokenizer.vocab")
            for ds in ("train_ds", "validation_ds", "test_ds"):
                if ds in cfg:
                    cfg[ds] = None
        model = EncDecRNNTBPEModel(cfg=cfg)
        model.load_state_dict(state, strict=True)
    else:
        raise ValueError(f"unknown weights {weights!r}")
    return model.to(device=device, dtype=torch.float32).eval()


class TapEncoder:
    """Runs Parakeet's preprocessor and encoder, exposing taps 0..24.

    `frames(audio, lengths)` returns (list of N_TAPS tensors [B, T, 1024],
    encoder lengths [B]); `pooled(...)` returns [B, N_TAPS, 2048] mean+std
    without keeping all taps alive at once; `raw_logmel(...)` returns the
    128-band log-mel without per-utterance normalisation ([B, T, 128], lengths).
    """

    def __init__(self, model):
        self.model = model
        self.enc = model.encoder
        if len(self.enc.layers) != N_TAPS - 1:
            raise ValueError("unexpected layer count")
        self._sink = None
        self._lengths = None
        self._handles = [self.enc.pre_encode.register_forward_hook(self._pre_hook)]
        for i, layer in enumerate(self.enc.layers):
            self._handles.append(layer.register_forward_hook(self._make_hook(i + 1)))

    def _pre_hook(self, module, inputs, output):
        x, lengths = output
        self._lengths = lengths.to(torch.int64)
        if self._sink is not None:
            self._sink(0, x)

    def _make_hook(self, tap):
        def hook(module, inputs, output):
            if self._sink is not None:
                self._sink(tap, output)
        return hook

    def features(self, audio: torch.Tensor, lengths: torch.Tensor):
        return self.model.preprocessor(input_signal=audio, length=lengths)

    @torch.inference_mode()
    def frames(self, audio: torch.Tensor, lengths: torch.Tensor, taps: tuple[int, ...] | None = None,
               with_features: bool = False):
        """Taps (list, None for unrequested taps) and encoder lengths; with
        with_features also the normalised log-mel encoder input ([B, 128, T10], lengths)."""
        wanted = set(range(N_TAPS)) if taps is None else set(taps)
        out: dict[int, torch.Tensor] = {}

        def sink(tap, x):
            if tap in wanted:
                out[tap] = x
        self._sink = sink
        try:
            feats, flen = self.features(audio, lengths)
            _, enc_len = self.enc(audio_signal=feats, length=flen)
        finally:
            self._sink = None
        result = ([out.get(t) for t in range(N_TAPS)], enc_len.to(torch.int64))
        return result + ((feats, flen.to(torch.int64)),) if with_features else result

    @torch.inference_mode()
    def pooled(self, audio: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
        res: dict[int, torch.Tensor] = {}

        def sink(tap, x):
            res[tap] = mean_std(x, self._lengths)
        self._sink = sink
        try:
            feats, flen = self.features(audio, lengths)
            _, enc_len = self.enc(audio_signal=feats, length=flen)
        finally:
            self._sink = None
        if not torch.equal(enc_len.to(torch.int64), self._lengths):
            raise RuntimeError("encoder lengths changed after pre_encode")
        return torch.stack([res[t] for t in range(N_TAPS)], dim=1)

    @torch.inference_mode()
    def raw_logmel(self, audio: torch.Tensor, lengths: torch.Tensor):
        fz = self.model.preprocessor.featurizer
        saved = fz.normalize
        fz.normalize = None
        try:
            x, xl = self.model.preprocessor(input_signal=audio, length=lengths)
        finally:
            fz.normalize = saved
        return x.transpose(1, 2), xl.to(torch.int64)


def load_titanet(device: str = "cuda"):
    _strict_fp32()
    if sha256_file(TITANET_S) != TITANET_S_SHA256:
        raise ValueError("titanet-s.nemo hash mismatch")
    from nemo.collections.asr.models import EncDecSpeakerLabelModel

    return EncDecSpeakerLabelModel.restore_from(str(TITANET_S), map_location="cpu").to(device).eval()


@torch.inference_mode()
def titanet_embed(model, audio: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
    _, emb = model.forward(input_signal=audio, input_signal_length=lengths)
    return emb.to(torch.float64)
