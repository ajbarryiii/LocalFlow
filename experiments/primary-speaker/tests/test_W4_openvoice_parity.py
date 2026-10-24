"""W4: the OpenVoice wrapper matches upstream ToneColorConverter waveform for
waveform (review clone-r1). Synthetic, non-speech input only; the one temporary
file upstream needs is deleted with its directory.

Needs the pinned weights and source on the data disk and librosa (./python-nemo):

    ./python-nemo -m unittest tests.test_W4_openvoice_parity -v
"""

from __future__ import annotations

import importlib
import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path

import numpy as np


def _available() -> bool:
    try:
        from lfspk.protect import openvoice
    except Exception:
        return False
    return (importlib.util.find_spec("librosa") is not None
            and (openvoice.CKPT_DIR / "checkpoint.pth").exists() and openvoice.SRC.exists())


@unittest.skipUnless(_available(), "needs librosa (./python-nemo) and the pinned OpenVoice files")
class OpenVoiceParityTest(unittest.TestCase):
    def test_extract_se_and_convert_match_upstream(self):
        import soundfile as sf
        import torch

        from lfspk.protect import openvoice

        wrapper = openvoice.ToneColorConverter("cpu")
        # Upstream's api imports its text front end (inflect etc.), which the
        # converter never uses: stub it.
        stub = types.ModuleType("openvoice.text")
        stub.text_to_sequence = lambda *a, **k: []
        sys.modules.setdefault("openvoice.text", stub)
        api = importlib.import_module("openvoice.api")
        up = api.ToneColorConverter.__new__(api.ToneColorConverter)
        api.OpenVoiceBaseClass.__init__(up, str(openvoice.CKPT_DIR / "config.json"), device="cpu")
        state = torch.load(openvoice.CKPT_DIR / "checkpoint.pth", map_location="cpu", weights_only=True)["model"]
        up.model.load_state_dict(state, strict=False)
        up.watermark_model, up.version = None, "v2"

        sr = wrapper.sr
        rng = np.random.default_rng(0)
        t = np.arange(int(1.5 * sr)) / sr
        sig = (0.2 * np.sin(2 * np.pi * 220 * t) + 0.1 * np.sin(2 * np.pi * 660 * t)
               + 0.02 * rng.standard_normal(t.size)).astype(np.float32)
        tgt_sig = (0.2 * np.sin(2 * np.pi * 330 * t) + 0.03 * rng.standard_normal(t.size)).astype(np.float32)
        with tempfile.TemporaryDirectory() as d:
            src_path, tgt_path = Path(d) / "src.wav", Path(d) / "tgt.wav"
            sf.write(src_path, sig, sr, subtype="FLOAT")
            sf.write(tgt_path, tgt_sig, sr, subtype="FLOAT")
            x, _ = sf.read(src_path, dtype="float32")
            y, _ = sf.read(tgt_path, dtype="float32")
            se_up_src = up.extract_se([str(src_path)])
            se_up_tgt = up.extract_se([str(tgt_path)])
            torch.manual_seed(123)
            out_up = up.convert(str(src_path), se_up_src, se_up_tgt, output_path=None, tau=0.3)
        se_src = wrapper.extract_se_22([x])
        se_tgt = wrapper.extract_se_22([y])
        np.testing.assert_allclose(se_src, se_up_src.cpu().numpy().ravel(), atol=1e-4)
        np.testing.assert_allclose(se_tgt, se_up_tgt.cpu().numpy().ravel(), atol=1e-4)
        torch.manual_seed(123)
        out = wrapper.convert22(x, se_src, se_tgt, tau=0.3)
        self.assertEqual(out.shape, out_up.shape)
        np.testing.assert_allclose(out, out_up, atol=1e-4)


if __name__ == "__main__":
    unittest.main()
