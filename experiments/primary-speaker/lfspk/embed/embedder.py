"""Shared speaker-embedder interface (owned by W1; W3 conditions on it).

An `Embedder` maps 16 kHz mono float32 audio to one L2-normalised float32
speaker embedding. Weights are frozen, public and pinned by SHA-256: the loader
refuses a file whose hash differs from the pinned value, so every result names
the exact weights it used (`weights_sha256`).

Contract:
- `embed(audio)` takes a 1-D float32 array in [-1, 1] (validated with
  `lfspk.api.check_audio`) of at least `MIN_SAMPLES` samples and returns a
  float32 vector of length `dim` with unit L2 norm.
- `embed_batch(audios)` returns the same embeddings as calling `embed` on each
  item, in order (up to float tolerance): items are grouped by exact length and
  never padded, so batching cannot change a result. An empty batch returns an
  array of shape (0, dim).
- Inference is deterministic: eval mode, no dither, no augmentation. On CPU,
  repeated calls give identical results. On CUDA the adapter sets
  `torch.backends.cudnn.deterministic = True` and `benchmark = False`
  (process-wide); CUDA results agree with CPU only to float tolerance.
- Front ends are part of the embedder: callers pass raw audio.
- `params` is the number of weights on the embedding path (classifier heads
  excluded), for cost reports.
- Each weight file is read into memory once, hashed, and deserialised from
  those same bytes, so the reported hash is the hash of what was loaded.

`weights_sha256` is the SHA-256 of the single weight file when there is one;
for several files it is the SHA-256 of the UTF-8 text formed by one line
"<file name> <file sha256>\n" per file, sorted by file name.

Model files live under `paths.DATA / "models" / <name>/`. NeMo models
(`titanet-*`) need `./python-nemo`; the others run under `./python`.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol, Sequence, runtime_checkable

import numpy as np

from .. import paths
from ..api import SAMPLE_RATE, check_audio

MODELS = paths.DATA / "models"
MIN_SAMPLES = SAMPLE_RATE // 5  # 0.2 s, the shortest every registered model handles (ResNet34 fails at 0.1 s)
_MAX_BATCH_SAMPLES = 64 * SAMPLE_RATE * 2  # per forward pass, bounds memory


@runtime_checkable
class Embedder(Protocol):
    name: str
    dim: int
    weights_sha256: str
    params: int

    def embed(self, audio: np.ndarray) -> np.ndarray:
        """16 kHz float32 1-D audio -> float32 [dim], L2-normalised."""
        ...

    def embed_batch(self, audios: Sequence[np.ndarray]) -> np.ndarray:
        """-> float32 [n, dim], L2-normalised, identical to embed() per item."""
        ...


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def combined_sha256(files: dict[str, str]) -> str:
    """Hash of several weight files: see the module docstring."""
    if len(files) == 1:
        return next(iter(files.values()))
    text = "".join(f"{name} {digest}\n" for name, digest in sorted(files.items()))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class WeightHashError(RuntimeError):
    pass


def read_verified(path: Path, expected: str) -> bytes:
    """The file's bytes, after checking their SHA-256 against `expected`."""
    if not path.is_file():
        raise FileNotFoundError(f"missing weight file {path}")
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise WeightHashError(f"{path}: sha256 {actual} != pinned {expected}")
    return data


def _torch_load_bytes(data: bytes):
    import io

    import torch

    return torch.load(io.BytesIO(data), map_location="cpu", weights_only=True)


def verify_files(directory: Path, pinned: dict[str, str]) -> str:
    """Check every pinned file's SHA-256; return the combined weights hash."""
    for name, expected in pinned.items():
        path = directory / name
        if not path.is_file():
            raise FileNotFoundError(f"missing weight file {path}")
        actual = file_sha256(path)
        if actual != expected:
            raise WeightHashError(f"{path}: sha256 {actual} != pinned {expected}")
    return combined_sha256(pinned)


def l2_normalise(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float32)
    norm = np.linalg.norm(x, axis=-1, keepdims=True)
    if not np.all(np.isfinite(x)) or np.any(norm <= 0):
        raise FloatingPointError("embedder produced a non-finite or zero embedding")
    return (x / norm).astype(np.float32)


def _validate(audio: np.ndarray) -> np.ndarray:
    check_audio(audio)
    if audio.size < MIN_SAMPLES:
        raise ValueError(f"audio shorter than {MIN_SAMPLES} samples ({audio.size})")
    return audio


class _TorchEmbedder:
    """Shared batching logic. Subclasses implement `_forward(batch)` for a
    [B, T] float32 torch tensor of equal-length clips on `self.device`, returning
    [B, dim] raw (unnormalised) embeddings."""

    name: str
    dim: int
    weights_sha256: str
    params: int  # weights on the embedding path (classifier heads excluded)

    def __init__(self, device: str):
        import torch

        self.device = torch.device(device)
        self._torch = torch
        if self.device.type == "cuda":
            torch.backends.cudnn.deterministic = True
            torch.backends.cudnn.benchmark = False

    def _forward(self, batch):  # pragma: no cover - abstract
        raise NotImplementedError

    def embed(self, audio: np.ndarray) -> np.ndarray:
        return self.embed_batch([audio])[0]

    def embed_batch(self, audios: Sequence[np.ndarray]) -> np.ndarray:
        audios = [_validate(a) for a in audios]
        out = np.empty((len(audios), self.dim), np.float32)
        by_len: dict[int, list[int]] = {}
        for i, a in enumerate(audios):
            by_len.setdefault(a.size, []).append(i)
        torch = self._torch
        with torch.inference_mode():
            for length, idx in by_len.items():
                step = max(1, _MAX_BATCH_SAMPLES // length)
                for s in range(0, len(idx), step):
                    chunk = idx[s:s + step]
                    batch = torch.from_numpy(np.stack([audios[i] for i in chunk])).to(self.device)
                    emb = self._forward(batch).float().cpu().numpy()
                    out[chunk] = l2_normalise(emb)
        return out


class EcapaSpeechBrain(_TorchEmbedder):
    """SpeechBrain ECAPA-TDNN (speechbrain/spkrec-ecapa-voxceleb), built
    directly from the published hyperparameters; only the embedding
    checkpoint is loaded (weights_only), no YAML is executed."""

    PINNED = {"embedding_model.ckpt": "0575cb64845e6b9a10db9bcb74d5ac32b326b8dc90352671d345e2ee3d0126a2"}

    def __init__(self, name: str, directory: Path, device: str):
        super().__init__(device)
        from speechbrain.lobes.features import Fbank
        from speechbrain.lobes.models.ECAPA_TDNN import ECAPA_TDNN
        from speechbrain.processing.features import InputNormalization

        self.name = name
        (fname, sha), = self.PINNED.items()
        state = _torch_load_bytes(read_verified(directory / fname, sha))
        self.weights_sha256 = sha
        self.features = Fbank(n_mels=80).to(self.device).eval()
        self.norm = InputNormalization(norm_type="sentence", std_norm=False).to(self.device).eval()
        self.model = ECAPA_TDNN(
            input_size=80, channels=[1024, 1024, 1024, 1024, 3072], kernel_sizes=[5, 3, 3, 3, 1],
            dilations=[1, 2, 3, 4, 1], attention_channels=128, lin_neurons=192)
        self.model.load_state_dict(state, strict=True)
        self.model.to(self.device).eval()
        self.dim = 192
        self.params = sum(p.numel() for p in self.model.parameters())

    def _forward(self, batch):
        lens = self._torch.ones(batch.shape[0], device=self.device)
        feats = self.norm(self.features(batch), lens)
        return self.model(feats, lens).squeeze(1)


class TitaNetNeMo(_TorchEmbedder):
    """NVIDIA NeMo TitaNet (small or large) restored from the NGC .nemo file.
    Dither is disabled for determinism (the published preprocessor is
    otherwise unchanged); `params` excludes the speaker
    classifier (`decoder.final`), which inference does not use."""

    def __init__(self, name: str, directory: Path, filename: str, sha256: str, device: str):
        super().__init__(device)
        import logging

        try:
            from nemo.collections.asr.models import EncDecSpeakerLabelModel
        except ImportError as e:  # pragma: no cover - environment dependent
            raise ImportError(f"{name} needs NeMo: run under ./python-nemo") from e
        import tempfile

        self.name = name
        data = read_verified(directory / filename, sha256)
        self.weights_sha256 = sha256
        previous = logging.root.manager.disable
        logging.disable(logging.WARNING)
        try:
            # restore_from needs a path: restore from a private copy of the
            # verified bytes, not from the shared file.
            with tempfile.TemporaryDirectory() as tmp:
                private = Path(tmp) / filename
                private.write_bytes(data)
                del data
                model = EncDecSpeakerLabelModel.restore_from(str(private), map_location="cpu")
        finally:
            logging.disable(previous)
        # NeMo applies dither only in training mode; zeroing it is defensive.
        # Every other preprocessor setting (including pad_to) stays as published.
        model.preprocessor.featurizer.dither = 0.0
        self.model = model.to(self.device).eval()
        self.dim = int(model.cfg.decoder.emb_sizes if isinstance(model.cfg.decoder.emb_sizes, int)
                       else model.cfg.decoder.emb_sizes[-1])
        self.params = sum(p.numel() for n, p in model.named_parameters() if not n.startswith("decoder.final"))

    def _forward(self, batch):
        lens = self._torch.full((batch.shape[0],), batch.shape[1], dtype=self._torch.long, device=self.device)
        _, emb = self.model.forward(input_signal=batch, input_signal_length=lens)
        return emb


SRC = MODELS / "src"
_WESPEAKER_SRC = ("wespeaker-9fecd6cb4f47475d01761d87c826298dff4ef18c",
                  "bd5a560e671c644e6ed83cbcd780643b7ad8132324f2b9187da5b5e6229ccca2", "wespeaker-9fecd6c.zip")
_REDIMNET2_SRC = ("redimnet2-c5bbe0b76e37df698c403f8844e41304ceab6307",
                  "c4e0367c9f844c4e8a7869afd424749d083411b6a37be11e9e0139db46ed8cfb", "redimnet2-c5bbe0b.zip")


def _pinned_source(entry: tuple[str, str, str]) -> Path:
    """Directory of a pinned third-party model-definition source tree. The
    archive is hash-checked in memory and every extracted .py file must equal
    its copy in the archive. (The interpreter then imports those files from
    disk; the data disk is trusted not to change them in between.)"""
    import io
    import zipfile

    tree, sha, archive = entry
    data = read_verified(SRC / archive, sha)
    root = SRC / tree
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            if info.filename.endswith(".py"):
                local = SRC / info.filename
                if not local.is_file() or local.read_bytes() != z.read(info):
                    raise WeightHashError(f"{local} differs from pinned archive {archive}")
    return root


_VENDOR_LOCK = __import__("threading").Lock()
_VENDOR_PREFIX = "lfspk._vendor"


def _import_vendored(package: str, root: Path, module: str, tag: str):
    """Import `<package>.<module>` from a pinned source tree without leaving the
    public name `<package>` in sys.modules.

    The vendored code imports itself by its public package name, so during the
    import a bare package module (no __init__ executed) is installed under that
    name; afterwards every `<package>*` entry is moved to the private name
    `lfspk._vendor.<tag>*` and whatever was there before (an installed
    upstream package, or nothing) is restored. The loaded modules keep
    references to each other through their globals. Not safe against a
    concurrent public import of the same package name in another thread;
    neither package is installed in this project."""
    import importlib
    import sys
    import types

    private = f"{_VENDOR_PREFIX}.{tag}"
    with _VENDOR_LOCK:
        target = f"{private}.{module}"
        if target in sys.modules:
            return sys.modules[target]

        def public(name):
            return name == package or name.startswith(package + ".")

        saved = {k: v for k, v in sys.modules.items() if public(k)}
        for k in saved:
            del sys.modules[k]
        try:
            # Reuse modules already vendored under this tag so repeated loads share them.
            for k, v in list(sys.modules.items()):
                if k == private or k.startswith(private + "."):
                    sys.modules[package + k[len(private):]] = v
            if package not in sys.modules:
                pkg = types.ModuleType(package)
                pkg.__path__ = [str(root / package)]
                sys.modules[package] = pkg
            mod = importlib.import_module(f"{package}.{module}")
            loaded = {k: v for k, v in sys.modules.items() if public(k)}
        finally:
            for k in [k for k in sys.modules if public(k)]:
                del sys.modules[k]
            sys.modules.update(saved)
        for k, v in loaded.items():
            sys.modules[private + k[len(package):]] = v
        return mod


class WeSpeakerTorch(_TorchEmbedder):
    """WeSpeaker ResNet34-LM or CAM++ (VoxCeleb2) in PyTorch, with WeSpeaker's
    own inference front end: Kaldi fbank (80 bins, 25/10 ms, Hamming, no
    dither) on int16-scaled audio, then per-clip mean normalisation (CMN).
    The published ONNX export is a cross-check in the tests."""

    def __init__(self, name: str, directory: Path, ckpt: str, sha256: str, module: str,
                 builder: str, kwargs: dict, device: str):
        super().__init__(device)
        self.name = name
        state = _torch_load_bytes(read_verified(directory / ckpt, sha256))
        self.weights_sha256 = sha256
        mod = _import_vendored("wespeaker", _pinned_source(_WESPEAKER_SRC), f"models.{module}", "wespeaker_9fecd6c")
        self.model = getattr(mod, builder)(**kwargs)
        state = {k: v for k, v in state.items() if not k.startswith("projection.")}
        self.model.load_state_dict(state, strict=True)
        self.model.to(self.device).eval()
        self.dim = int(kwargs["embed_dim"])
        self.params = sum(p.numel() for p in self.model.parameters())

    def fbank(self, batch):
        from torchaudio.compliance import kaldi

        feats = [kaldi.fbank(x.unsqueeze(0) * 32768.0, num_mel_bins=80, frame_length=25, frame_shift=10,
                             dither=0.0, sample_frequency=SAMPLE_RATE, window_type="hamming") for x in batch]
        feats = self._torch.stack(feats)
        return feats - feats.mean(dim=1, keepdim=True)

    def _forward(self, batch):
        out = self.model(self.fbank(batch))
        return out[-1] if isinstance(out, tuple) else out


class ReDimNet2(_TorchEmbedder):
    """ReDimNet2 (PalabraAI/redimnet2, MIT, VoxCeleb2 large-margin weights).
    The model includes its own front end (pre-emphasis, signal normalisation,
    mel features). Weights load with weights_only=True."""

    def __init__(self, name: str, directory: Path, ckpt: str, sha256: str, device: str):
        super().__init__(device)
        self.name = name
        full = _torch_load_bytes(read_verified(directory / ckpt, sha256))
        self.weights_sha256 = sha256
        mod = _import_vendored("redimnet2", _pinned_source(_REDIMNET2_SRC), "redimnet2", "redimnet2_c5bbe0b")
        self.model = mod.ReDimNet2Wrap(**full["model_config"])
        self.model.load_state_dict(full["state_dict"], strict=True)
        self.model.to(self.device).eval()
        self.dim = int(full["model_config"]["embed_dim"])
        self.params = sum(p.numel() for p in self.model.parameters())

    def _forward(self, batch):
        return self.model(batch)


@dataclass(frozen=True)
class _Entry:
    factory: Callable[[str, str], _TorchEmbedder]
    needs_nemo: bool = False


_REGISTRY: dict[str, _Entry] = {
    "ecapa-vox": _Entry(lambda name, dev: EcapaSpeechBrain(name, MODELS / name, dev)),
    "titanet-s": _Entry(lambda name, dev: TitaNetNeMo(
        name, MODELS / name, "titanet-s.nemo",
        "c9d82e1bffb53b240f2ca33c1eff23867869bebadb3ab0f834cc11be83a73ffe", dev), needs_nemo=True),
    "titanet-l": _Entry(lambda name, dev: TitaNetNeMo(
        name, MODELS / name, "titanet-l.nemo",
        "e838520693f269e7984f55bc8eb3c2d60ccf246bf4b896d4be9bcabe3e4b0fe3", dev), needs_nemo=True),
    "wespeaker-r34lm": _Entry(lambda name, dev: WeSpeakerTorch(
        name, MODELS / name, "avg_model", "9872b375f2c6a3851ca471cbbf59e06efd23a627d78bf5872e1f0269fd298449",
        "resnet", "ResNet34", {"feat_dim": 80, "embed_dim": 256, "pooling_func": "TSTP", "two_emb_layer": False},
        dev)),
    "wespeaker-campp": _Entry(lambda name, dev: WeSpeakerTorch(
        name, MODELS / name, "avg_model.pt", "07abeeb5150441995b51ea65c9ccc8feed78b33040012f1d2fad29a0e4f5b8d7",
        "campplus", "CAMPPlus", {"feat_dim": 80, "embed_dim": 512, "pooling_func": "TSTP"}, dev)),
    "redimnet2-b0": _Entry(lambda name, dev: ReDimNet2(
        name, MODELS / name, "b0-vox2-lm.pt", "4b5a8c00f813ab0d92fc81ea7c504475d8201bed608fb2c6aaba65be723e9c61", dev)),
    "redimnet2-b2": _Entry(lambda name, dev: ReDimNet2(
        name, MODELS / name, "b2-vox2-lm.pt", "0545a29679a87fe1c662d2bbd05e3b3fe0d1b392832729abaa135e4079a2f77a", dev)),
}

ONNX_REFERENCE = {  # published ONNX exports, used only to cross-check the PyTorch adapters
    "wespeaker-r34lm": ("voxceleb_resnet34_LM.onnx", "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068"),
    "wespeaker-campp": ("voxceleb_CAM++.onnx", "b50810498b5bcf5773d086f6993d344476bd0c88b566a41e8d801aaf8461efad"),
}


def available() -> list[str]:
    return sorted(_REGISTRY)


def needs_nemo(name: str) -> bool:
    return _REGISTRY[name].needs_nemo


def load_embedder(name: str, device: str = "cpu") -> Embedder:
    """Load a registered embedder; raises KeyError for an unknown name and
    WeightHashError if the weight files differ from the pinned hashes."""
    if name not in _REGISTRY:
        raise KeyError(f"unknown embedder {name!r}; available: {available()}")
    return _REGISTRY[name].factory(name, device)
