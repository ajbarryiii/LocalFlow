"""W5 stage-B hook (DESIGN section 10.2; review r2 #2; implI1-r1 #1-#3).

Needs NeMo: run with ./python-nemo (skipped under ./python). Uses NeMo's own
AudioToMelSpectrogramPreprocessor with Parakeet TDT 0.6B v2's preprocessor
config, no weights. The full transcription path through a real Parakeet model
is exercised by the smoke `lfspk.extract.smoke_hook` (a job), not here.
"""

from __future__ import annotations

import unittest

import numpy as np
import torch

from lfspk.extract import api, frontend
from lfspk.extract.api import LOG_G_MIN, InferenceConfig, MaskOutput

try:
    from nemo.collections.asr.modules import AudioToMelSpectrogramPreprocessor

    from lfspk.extract.nemo_hook import (MaskedPreprocessor, Row, audio_sha256, cpu_preprocessor, hook_code_sha256,
                                         transcribe_masked)
    HAVE_NEMO = True
except Exception:  # noqa: BLE001
    HAVE_NEMO = False

PARAKEET_PREPROCESSOR = dict(sample_rate=16000, normalize="per_feature", window_size=0.025, window_stride=0.01,
                             window="hann", features=128, n_fft=512, log=True, frame_splicing=1, dither=1.0e-05,
                             pad_to=0, pad_value=0.0)


def sig(n: int, seed: int, level_db: float = -25.0, tonal: bool = False) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = np.arange(n) / 16000.0
    if tonal:
        x = np.sin(2 * np.pi * 440 * t) + 0.3 * np.sin(2 * np.pi * 1320 * t) + 1e-4 * rng.standard_normal(n)
    else:
        x = 0.5 * np.sin(2 * np.pi * (200 + 50 * seed) * t) + rng.standard_normal(n)
    x = x / np.sqrt(np.mean(x ** 2)) * 10 ** (level_db / 20)
    return x.astype(np.float32)


def mask_for(n: int, seed: int) -> MaskOutput:
    rng = np.random.default_rng(100 + seed)
    t = api.feature_frames(n)
    lm = np.zeros((128, t), np.float32)
    a, b = sorted(rng.integers(0, t, 2))
    lm[20:90, a:b + 1] = rng.uniform(LOG_G_MIN, 0, (70, b + 1 - a)).astype(np.float32)
    u = rng.uniform(0, 1, t).astype(np.float32)
    return MaskOutput(lm.astype(np.float16), u)


def batch(audios):
    n = max(len(a) for a in audios)
    x = torch.zeros(len(audios), n)
    for i, a in enumerate(audios):
        x[i, : len(a)] = torch.from_numpy(a)
    return x, torch.tensor([len(a) for a in audios])


class FakeModel:
    """Stands in for a NeMo ASR model: `transcribe` below pads the given
    recordings into one batch, in order, and calls model.preprocessor once,
    as NeMo's transcription loop does."""

    def __init__(self, pre):
        self.preprocessor = pre
        self.seen = []


def fake_transcribe(model, audios, batch_size):
    assert batch_size == len(audios)
    x, n = batch(audios)
    with torch.no_grad():
        feats, lens = model.preprocessor(input_signal=x, length=n)
    model.seen.append((feats, lens))
    return [{"text": f"item{len(a)}", "words": []} for a in audios]


@unittest.skipUnless(HAVE_NEMO, "NeMo not importable (run with ./python-nemo)")
class TestHook(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(0)
        self.base = AudioToMelSpectrogramPreprocessor(**PARAKEET_PREPROCESSOR).eval()
        f = self.base.featurizer
        self.consts = (f.window.numpy().copy(), f.fb[0].numpy().copy())
        self.mel = frontend.MelPower(*self.consts)  # the same constants as this NeMo instance
        self.cfg = InferenceConfig("C2")
        self.audios = [sig(16000, 0), sig(23457, 1), sig(19123, 2), sig(30001, 3)]
        self.masks = [mask_for(len(a), i) for i, a in enumerate(self.audios)]

    def hooked(self, rows, audios):
        hook = MaskedPreprocessor(self.base).eval()
        hook.set_rows(rows)
        x, n = batch(audios)
        with torch.no_grad():
            return hook(input_signal=x, length=n)

    def nemo(self, audios):
        x, n = batch(audios)
        with torch.no_grad():
            return self.base(input_signal=x, length=n)

    def rows(self, audios, masks, keep=()):
        out = []
        for i, (a, m) in enumerate(zip(audios, masks)):
            w = frontend.weights(m.u, len(a), self.cfg)
            out.append(Row.make(a, None, None) if i in keep else Row.make(a, m.log_mask, w))
        return out

    def test_zero_mask_is_nemo_bit_for_bit(self):
        rows = [Row.make(a, np.zeros((128, api.feature_frames(len(a))), np.float32),
                         np.ones(api.feature_frames(len(a)), np.float32)) for a in self.audios]
        out, n_out = self.hooked(rows, self.audios)
        ref, n_ref = self.nemo(self.audios)
        self.assertTrue(torch.equal(out, ref))
        self.assertTrue(torch.equal(n_out, n_ref))

    def test_apply_equals_hook_exactly_with_the_same_constants(self):
        # implI1-r1 #1: quiet and tonal inputs, single-recording path
        cases = [sig(32000, 0, -90.0), sig(32000, 1, -25.0, tonal=True), sig(24000, 2, -60.0, tonal=True),
                 sig(20000, 3, -25.0)]
        for k, a in enumerate(cases):
            for mo in (mask_for(len(a), k), MaskOutput(np.zeros((128, api.feature_frames(len(a))), np.float32),
                                                       np.ones(api.feature_frames(len(a)), np.float32))):
                w = frontend.weights(mo.u, len(a), self.cfg)
                out, _ = self.hooked([Row.make(a, mo.log_mask, w)], [a])
                ref = frontend.apply(a, mo, self.cfg, self.mel)
                np.testing.assert_array_equal(out[0].numpy(), ref)
            np.testing.assert_array_equal(frontend.features_np(a, self.mel), self.nemo([a])[0][0].numpy())

    def test_mixed_unequal_batch_matches_items_alone(self):
        keep = (1, 3)
        rows = self.rows(self.audios, self.masks, keep)
        out, n_out = self.hooked(rows, self.audios)
        ref_batch, n_ref = self.nemo(self.audios)
        self.assertTrue(torch.equal(n_out, n_ref))
        for i, a in enumerate(self.audios):
            alone, n_alone = self.hooked([rows[i]], [a])
            self.assertEqual(int(n_alone[0]), int(n_out[i]))
            t_i = alone.shape[-1]
            np.testing.assert_allclose(out[i, :, :t_i].numpy(), alone[0].numpy(), atol=1e-5)
            self.assertTrue(torch.all(out[i, :, int(n_out[i]):] == 0.0))  # NeMo's pad value past each length
            if i in keep:
                self.assertTrue(torch.equal(out[i], ref_batch[i]))  # NeMo's own tensor, untouched
            else:
                self.assertGreater(float(np.abs(out[i] - ref_batch[i]).max()), 0.1)  # the mask did something

    def test_declared_rows_are_verified(self):
        rows = self.rows(self.audios[:2], self.masks[:2])
        with self.assertRaises(RuntimeError):  # wrong order
            self.hooked(list(reversed(rows)), self.audios[:2])
        with self.assertRaises(RuntimeError):  # row count
            self.hooked(rows[:1], self.audios[:2])
        padded = np.concatenate([np.zeros(80, np.float32), self.audios[0], np.zeros(80, np.float32)])
        with self.assertRaises(RuntimeError):  # a loader that pads (NeMo pads sub-second inputs)
            self.hooked(rows[:1], [padded])
        with self.assertRaises(RuntimeError):  # same length, other samples
            self.hooked(rows[:1], [self.audios[0] * 0.5])
        hook = MaskedPreprocessor(self.base)
        x, n = batch(self.audios[:1])
        with self.assertRaises(RuntimeError):  # no declaration
            hook(input_signal=x, length=n)
        hook.set_rows(rows[:1])
        with self.assertRaises(RuntimeError):  # a second declaration before the first was consumed
            hook.set_rows(rows[:1])

    def test_transcribe_masked(self):
        model = FakeModel(self.base)
        cfg = InferenceConfig("C3", theta_b=0.5)
        dup = self.audios[0].copy()
        audios = self.audios + [dup]
        masks = [MaskOutput(m.log_mask, np.full_like(m.u, v)) for m, v in zip(self.masks, (0.9, 0.1, 0.9, 0.9))]
        masks.append(MaskOutput(mask_for(len(dup), 9).log_mask, np.full_like(masks[0].u, 0.9)))  # duplicate audio, other mask
        res = transcribe_masked(model, audios, masks, cfg, batch_size=2, transcribe=fake_transcribe,
                                expected_constants=self.consts)
        self.assertIsNone(res[1])  # bypassed: not transcribed
        self.assertTrue(all(r is not None for i, r in enumerate(res) if i != 1))
        self.assertIs(model.preprocessor, self.base)  # uninstalled
        self.assertEqual(sum(f.shape[0] for f, _ in model.seen), 4)
        # every masked row equals apply() on that item alone (batch context aside)
        got = {}
        for feats, lens in model.seen:
            for j in range(feats.shape[0]):
                got.setdefault(int(lens[j]), []).append(feats[j])
        for i in (0, 2, 3, 4):
            ref = frontend.apply(audios[i], masks[i], cfg, self.mel)
            cands = got[api.valid_frames(len(audios[i]))]
            self.assertTrue(any(np.allclose(c[:, : ref.shape[1]].numpy(), ref, atol=1e-5) for c in cands), i)

    def test_transcribe_masked_refuses_short_and_detects_extra_passes(self):
        model = FakeModel(self.base)
        short = sig(9000, 5)
        kw = dict(transcribe=fake_transcribe, expected_constants=self.consts)
        with self.assertRaises(ValueError):
            transcribe_masked(model, [short], [mask_for(len(short), 5)], InferenceConfig("C1"), **kw)

        def twice(model, audios, batch_size):
            fake_transcribe(model, audios, batch_size)
            return fake_transcribe(model, audios, batch_size)

        with self.assertRaises(RuntimeError):
            transcribe_masked(FakeModel(self.base), self.audios[:1], self.masks[:1], InferenceConfig("C1"),
                              transcribe=twice, expected_constants=self.consts)

        def empty(model, audios, batch_size):
            fake_transcribe(model, audios, batch_size)
            return [None] * len(audios)

        with self.assertRaises(RuntimeError):  # a masked recording without a record must not read as "reuse B"
            transcribe_masked(FakeModel(self.base), self.audios[:1], self.masks[:1], InferenceConfig("C1"),
                              transcribe=empty, expected_constants=self.consts)

    def test_transcribe_masked_validates_batch_size(self):
        # implI1-r2 #2: a bad batch size must not silently return "bypassed" for every item
        for bad in (-1, 0, True, 2.0, "16"):
            with self.assertRaises(ValueError):
                transcribe_masked(FakeModel(self.base), self.audios[:1], self.masks[:1], InferenceConfig("C1"),
                                  batch_size=bad, transcribe=fake_transcribe, expected_constants=self.consts)

    def test_transcribe_masked_refuses_other_constants(self):
        # implI1-r2 #1: the model's buffers must be the constants apply() uses
        other = (self.consts[0] * np.float32(1.0000001), self.consts[1])
        with self.assertRaises(ValueError):
            transcribe_masked(FakeModel(self.base), self.audios[:1], self.masks[:1], InferenceConfig("C1"),
                              transcribe=fake_transcribe, expected_constants=other)
        from lfspk.extract import constants

        if constants.available():  # this fresh NeMo instance differs from the checkpoint by about one ulp
            with self.assertRaises(ValueError):
                transcribe_masked(FakeModel(self.base), self.audios[:1], self.masks[:1], InferenceConfig("C1"),
                                  transcribe=fake_transcribe)

    def test_device_mismatch_is_refused_clearly(self):
        # w5-smoke-hook 2026-10-22: featurizer fb on cuda:0, input on cpu. CPU-only stand-in:
        # move fb to the meta device; the hook must refuse before NeMo runs.
        f = self.base.featurizer
        orig = f._buffers["fb"]
        f._buffers["fb"] = orig.to("meta")
        self.addCleanup(f._buffers.__setitem__, "fb", orig)
        with self.assertRaisesRegex(RuntimeError, "different devices"):
            self.hooked(self.rows(self.audios[:1], self.masks[:1]), self.audios[:1])

    def test_cpu_preprocessor_rebuilds_on_cpu(self):
        from omegaconf import OmegaConf

        class M:
            pass

        m = M()
        m.preprocessor = self.base
        m.cfg = OmegaConf.create({"preprocessor": {"_target_": "nemo.collections.asr.modules.AudioToMelSpectrogramPreprocessor",
                                                   **PARAKEET_PREPROCESSOR}})
        from nemo.core.classes import ModelPT

        m.from_config_dict = ModelPT.from_config_dict
        c = cpu_preprocessor(m)
        self.assertIsNot(c, self.base)
        self.assertTrue(all(t.device.type == "cpu" for t in c.buffers()))
        self.assertTrue(torch.equal(c.featurizer.fb, self.base.featurizer.fb))
        self.assertTrue(torch.equal(c.featurizer.window, self.base.featurizer.window))
        a = self.audios[0]
        h = MaskedPreprocessor(c).eval()
        h.set_rows(self.rows([a], self.masks[:1]))
        x, n = batch([a])
        with torch.no_grad():
            out, _ = h(input_signal=x, length=n)
        np.testing.assert_array_equal(out[0].numpy(), frontend.apply(a, self.masks[0], self.cfg, self.mel))

    def test_install_and_code_hash(self):
        class M:
            preprocessor = self.base

        m = M()
        h = MaskedPreprocessor.install(m)
        self.assertIs(m.preprocessor, h)
        with self.assertRaises(RuntimeError):
            MaskedPreprocessor.install(m)
        MaskedPreprocessor.uninstall(m)
        self.assertIs(m.preprocessor, self.base)
        self.assertEqual(len(hook_code_sha256()), 64)
        self.assertEqual(audio_sha256(self.audios[0]), audio_sha256(self.audios[0].astype(np.float64)))


if __name__ == "__main__":
    unittest.main()
