"""OpenVoice V2 tone-colour converter, loaded from pinned files (PROVENANCE.md).

Only the converter is used: `extract_se` (reference encoder -> 256-d tone-colour
embedding, averaged over clips as OpenVoice does) and `convert` (voice
conversion of source speech from src_se to tgt_se). Audio in and out is 16 kHz
float32; the model runs at 22.05 kHz. Nothing is written to disk.
"""

from __future__ import annotations

import hashlib
import importlib
import sys
from pathlib import Path

import numpy as np

from .. import paths

EXT = paths.RUNS / "W4" / "ext"
SRC = EXT / "openvoice-src"  # github.com/myshell-ai/OpenVoice @ 74a1d14
CKPT_DIR = EXT / "OpenVoiceV2" / "converter"
SRC_COMMIT = "74a1d147b17a8c3092dd5430504bd83ef6c7eb23"
PINNED = {
    "checkpoint.pth": "9652c27e92b6b2a91632590ac9962ef7ae2b712e5c5b7f4c34ec55ee2b37ab9e",
    "config.json": "9dfff60350b8c63f2c664efd92a61b2516efb22671466960f0e5dfebd881fa47",
}
SE_DIM = 256


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def resample(audio, sr_in: int, sr_out: int):
    import torch
    import torchaudio.functional as AF

    t = audio if isinstance(audio, torch.Tensor) else torch.from_numpy(np.ascontiguousarray(audio))
    return AF.resample(t, sr_in, sr_out)


class ToneColorConverter:
    def __init__(self, device: str = "cpu"):
        import torch

        for name, digest in PINNED.items():
            if _sha256(CKPT_DIR / name) != digest:
                raise RuntimeError(f"{CKPT_DIR / name}: SHA-256 mismatch")
        import subprocess

        head = subprocess.check_output(["git", "-C", str(SRC), "rev-parse", "HEAD"], text=True).strip()
        dirty = subprocess.run(["git", "-C", str(SRC), "diff", "--quiet", "HEAD"]).returncode != 0
        if head != SRC_COMMIT or dirty:
            raise RuntimeError("OpenVoice source is not the pinned, unmodified commit")
        if str(SRC) not in sys.path:
            sys.path.insert(0, str(SRC))
        utils = importlib.import_module("openvoice.utils")
        models = importlib.import_module("openvoice.models")
        self.hps = utils.get_hparams_from_file(str(CKPT_DIR / "config.json"))
        d = self.hps.data
        self.sr = d.sampling_rate
        self.n_fft, self.hop, self.win = d.filter_length, d.hop_length, d.win_length
        model = models.SynthesizerTrn(0, self.n_fft // 2 + 1, n_speakers=d.n_speakers, **self.hps.model.__dict__)
        state = torch.load(CKPT_DIR / "checkpoint.pth", map_location="cpu", weights_only=True)["model"]
        missing, unexpected = model.load_state_dict(state, strict=False)
        if missing:
            raise RuntimeError(f"OpenVoice checkpoint misses weights: {missing[:5]}")
        self.unexpected = list(unexpected)  # text-encoder weights the converter does not use
        self.model = model.to(device).eval()
        self.device = torch.device(device)
        self._torch = torch
        self._window = torch.hann_window(self.win).to(self.device)

    def spectrogram(self, y22):
        """Magnitude spectrogram as openvoice.mel_processing.spectrogram_torch
        (reflect pad (n_fft - hop) / 2, center=False, sqrt(|X|^2 + 1e-6))."""
        torch = self._torch
        pad = (self.n_fft - self.hop) // 2
        y = torch.nn.functional.pad(y22.unsqueeze(1), (pad, pad), mode="reflect").squeeze(1)
        spec = torch.stft(y, self.n_fft, hop_length=self.hop, win_length=self.win, window=self._window,
                          center=False, normalized=False, onesided=True, return_complex=True)
        return torch.sqrt(spec.real ** 2 + spec.imag ** 2 + 1e-6)

    def _to22(self, audio16: np.ndarray):
        return resample(np.asarray(audio16, dtype=np.float32), 16_000, self.sr)

    def extract_se_22(self, clips22) -> np.ndarray:
        """Mean tone-colour embedding over 22.05 kHz clips (upstream extract_se)."""
        torch = self._torch
        gs = []
        with torch.inference_mode():
            for clip in clips22:
                y = torch.as_tensor(np.asarray(clip, dtype=np.float32)).to(self.device)
                spec = self.spectrogram(y.unsqueeze(0))
                gs.append(self.model.ref_enc(spec.transpose(1, 2)))
        return torch.stack(gs).mean(0)[0].float().cpu().numpy()

    def extract_se(self, clips16: list[np.ndarray]) -> np.ndarray:
        """Mean tone-colour embedding over 16 kHz clips."""
        return self.extract_se_22([self._to22(c) for c in clips16])

    def convert22(self, src22, src_se: np.ndarray, tgt_se: np.ndarray, tau: float = 0.3) -> np.ndarray:
        """Upstream ToneColorConverter.convert on a 22.05 kHz waveform (no
        watermark); returns 22.05 kHz float32. Draws from torch's RNG (tau)."""
        torch = self._torch
        with torch.inference_mode():
            y = torch.as_tensor(np.asarray(src22, dtype=np.float32)).to(self.device)
            spec = self.spectrogram(y.unsqueeze(0))
            lengths = torch.LongTensor([spec.size(-1)]).to(self.device)
            g_src = torch.tensor(src_se, dtype=torch.float32, device=self.device).view(1, -1, 1)
            g_tgt = torch.tensor(tgt_se, dtype=torch.float32, device=self.device).view(1, -1, 1)
            out = self.model.voice_conversion(spec, lengths, sid_src=g_src, sid_tgt=g_tgt, tau=tau)[0][0, 0]
        return out.float().cpu().numpy()

    def convert(self, src16: np.ndarray, src_se: np.ndarray, tgt_se: np.ndarray, tau: float = 0.3) -> np.ndarray:
        """Voice conversion of 16 kHz audio; returns 16 kHz float32 in [-1, 1]."""
        out22 = self.convert22(self._to22(src16), src_se, tgt_se, tau)
        out16 = resample(out22, self.sr, 16_000).numpy()
        return np.clip(out16, -1.0, 1.0).astype(np.float32)
