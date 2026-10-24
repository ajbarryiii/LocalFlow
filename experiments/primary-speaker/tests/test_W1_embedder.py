"""Contract tests for lfspk.embed.embedder (W1). Synthetic arrays except the
optional real-weight tests, which skip when weights, NeMo or dev-clean are
absent."""

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from lfspk.embed import embedder as E


def _audio(n, seed=0, scale=0.05):
    return (np.random.default_rng(seed).standard_normal(n) * scale).astype(np.float32)


class HashTest(unittest.TestCase):
    def test_single_file_hash_is_file_hash(self):
        self.assertEqual(E.combined_sha256({"a.pt": "ab" * 32}), "ab" * 32)

    def test_multi_file_hash_is_sorted_manifest_hash(self):
        files = {"b.pt": "22" * 32, "a.pt": "11" * 32}
        text = f"a.pt {'11' * 32}\nb.pt {'22' * 32}\n"
        self.assertEqual(E.combined_sha256(files), hashlib.sha256(text.encode()).hexdigest())

    def test_verify_files(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "w.bin"
            p.write_bytes(b"weights")
            good = hashlib.sha256(b"weights").hexdigest()
            self.assertEqual(E.verify_files(Path(d), {"w.bin": good}), good)
            with self.assertRaises(E.WeightHashError):
                E.verify_files(Path(d), {"w.bin": "00" * 32})
            with self.assertRaises(FileNotFoundError):
                E.verify_files(Path(d), {"missing.bin": good})


class NormaliseTest(unittest.TestCase):
    def test_unit_norm_float32(self):
        x = E.l2_normalise(np.array([[3.0, 4.0], [0.0, 2.0]]))
        self.assertEqual(x.dtype, np.float32)
        np.testing.assert_allclose(np.linalg.norm(x, axis=1), 1.0, rtol=1e-6)

    def test_rejects_zero_and_nonfinite(self):
        for bad in (np.zeros((1, 3)), np.array([[np.nan, 1.0]])):
            with self.assertRaises(FloatingPointError):
                E.l2_normalise(bad)


class _Toy(E._TorchEmbedder):  # noqa: D101
    """Deterministic toy embedder: the embedding depends on content and
    length, so a padded or reordered batch would change it. Records the batch
    shapes it was called with."""

    name, dim, weights_sha256, params = "toy", 3, "00" * 32, 0

    def __init__(self):
        super().__init__("cpu")
        self.calls = []

    def _forward(self, batch):
        self.calls.append(tuple(batch.shape))
        t = self._torch
        n = t.full((batch.shape[0],), float(batch.shape[1]))
        return t.stack([batch.mean(1) + 1.0, batch.abs().max(1).values + 0.5, n / 16000.0], dim=1)


class BatchingContractTest(unittest.TestCase):
    def test_batch_equals_single_and_keeps_order(self):
        toy = _Toy()
        items = [_audio(3200 + 1600, 1), _audio(9600, 2), _audio(3200 + 1600, 3), _audio(12000, 4)]
        batch = toy.embed_batch(items)
        self.assertEqual(batch.shape, (4, 3))
        self.assertEqual(batch.dtype, np.float32)
        for i, a in enumerate(items):
            np.testing.assert_allclose(batch[i], toy.embed(a), atol=1e-6)
        np.testing.assert_allclose(np.linalg.norm(batch, axis=1), 1.0, rtol=1e-6)

    def test_groups_by_exact_length_without_padding(self):
        toy = _Toy()
        toy.embed_batch([_audio(3200 + 1600, 1), _audio(9600, 2), _audio(3200 + 1600, 3)])
        self.assertCountEqual(toy.calls, [(2, 4800), (1, 9600)])

    def test_chunks_large_groups(self):
        toy = _Toy()
        with mock.patch.object(E, "_MAX_BATCH_SAMPLES", 9600):
            out = toy.embed_batch([_audio(3200 + 1600, i) for i in range(5)])
        self.assertEqual(out.shape, (5, 3))
        self.assertEqual([c[0] for c in toy.calls], [2, 2, 1])

    def test_empty_batch(self):
        self.assertEqual(_Toy().embed_batch([]).shape, (0, 3))

    def test_input_validation(self):
        toy = _Toy()
        for bad in (np.zeros(E.MIN_SAMPLES, np.float64), np.zeros((2, E.MIN_SAMPLES), np.float32),
                    np.zeros(E.MIN_SAMPLES - 1, np.float32), np.full(E.MIN_SAMPLES, 2.0, np.float32)):
            with self.assertRaises((TypeError, ValueError)):
                toy.embed(bad)

    def test_registry(self):
        self.assertIn("ecapa-vox", E.available())
        self.assertIn("titanet-s", E.available())
        self.assertIn("params", E.Embedder.__annotations__)
        with self.assertRaises(KeyError):
            E.load_embedder("no-such-model")


_HAS_NEMO = importlib.util.find_spec("nemo") is not None
_ECAPA_SNAPSHOT = (E.paths.ART / "cache/hf/hub/models--speechbrain--spkrec-ecapa-voxceleb/snapshots"
                   / "0f99f2d0ebe89ac095bcc5903c4dd8f72b367286")


def _speech(seconds=3.0, index=0):
    """A crop of a real dev-clean utterance (public corpus), or None."""
    from lfspk import splits

    if not (splits.paths.LIBRISPEECH / "dev-clean").is_dir():
        return None
    spk = [s for s in splits.speakers("dev") if s.subset == "dev-clean"][index]
    return _load(splits.utterances(spk)[0])[: int(seconds * 16000)]


def _load(path):
    import soundfile as sf

    audio, sr = sf.read(str(path), dtype="float32")
    assert sr == 16000 and audio.ndim == 1
    return audio


class _RealModelMixin:
    model_name = ""
    _cache: dict = {}

    @classmethod
    def model(cls):
        if cls.model_name not in cls._cache:
            cls._cache[cls.model_name] = E.load_embedder(cls.model_name)
        return cls._cache[cls.model_name]

    def clips(self):
        speech = _speech()
        a = speech[:16000] if speech is not None else _audio(16000, 1)
        c = _audio(16000, 2)  # same length as a, different content
        c[8000:] = 0.0  # half noise, half silence
        return a, _audio(12345, 3), c

    def test_contract(self):
        m = self.model()
        self.assertIsInstance(m, E.Embedder)
        self.assertEqual(m.name, self.model_name)
        self.assertEqual(len(m.weights_sha256), 64)
        self.assertGreater(m.params, 0)
        a, b, c = self.clips()
        x = m.embed(a)
        self.assertEqual(x.shape, (m.dim,))
        self.assertEqual(x.dtype, np.float32)
        self.assertAlmostEqual(float(np.linalg.norm(x)), 1.0, places=5)
        np.testing.assert_array_equal(m.embed(a), x)  # deterministic on CPU
        m.embed(_audio(E.MIN_SAMPLES, 3))  # shortest accepted input

    def test_batch_items_independent(self):
        """Distinct equal-length clips in one forward pass, and across a chunk
        boundary, equal their individual embeddings."""
        m = self.model()
        a, b, c = self.clips()
        single = [m.embed(v) for v in (b, a, c)]
        batch = m.embed_batch([b, a, c])
        for i in range(3):
            np.testing.assert_allclose(batch[i], single[i], atol=2e-5)
        with mock.patch.object(E, "_MAX_BATCH_SAMPLES", 2 * 16000):
            chunked = m.embed_batch([a, c, a, c, b])
        for got, want in zip(chunked, (single[1], single[2], single[1], single[2], single[0])):
            np.testing.assert_allclose(got, want, atol=2e-5)

    def test_same_speaker_closer_on_dev_clean(self):
        from lfspk import splits

        if not (splits.paths.LIBRISPEECH / "dev-clean").is_dir():
            self.skipTest("dev-clean not available")
        spk = [s for s in splits.speakers("dev") if s.subset == "dev-clean"][:2]
        utts = [splits.utterances(s)[:2] for s in spk]
        emb = [[self.model().embed(_load(u)) for u in pair] for pair in utts]
        same = [float(emb[i][0] @ emb[i][1]) for i in range(2)]
        diff = [float(emb[0][i] @ emb[1][j]) for i in range(2) for j in range(2)]
        self.assertGreater(min(same), max(diff))


@unittest.skipUnless((E.MODELS / "ecapa-vox").is_dir(), "ECAPA weights not on this host")
class EcapaRealTest(_RealModelMixin, unittest.TestCase):
    model_name = "ecapa-vox"

    @unittest.skipUnless(_ECAPA_SNAPSHOT.is_dir(), "SpeechBrain HF snapshot not on this host")
    def test_matches_speechbrain_encode_batch(self):
        """The adapter equals SpeechBrain's own EncoderClassifier.encode_batch
        (front end, sentence mean normalisation, embedding) on real speech and
        on noise/silence."""
        from speechbrain.inference.speaker import EncoderClassifier
        import torch

        with tempfile.TemporaryDirectory() as tmp:
            ref = EncoderClassifier.from_hparams(source=str(_ECAPA_SNAPSHOT), savedir=tmp, run_opts={"device": "cpu"})
            for clip in self.clips():
                with torch.inference_mode():
                    want = ref.encode_batch(torch.from_numpy(clip)[None]).squeeze().numpy()
                want = want / np.linalg.norm(want)
                np.testing.assert_allclose(self.model().embed(clip), want, atol=1e-5)


@unittest.skipUnless(_HAS_NEMO and (E.MODELS / "titanet-s").is_dir(), "needs ./python-nemo and TitaNet-s weights")
class TitaNetSmallRealTest(_RealModelMixin, unittest.TestCase):
    model_name = "titanet-s"

    def test_matches_nemo_infer_segment(self):
        """The adapter equals NeMo's own inference (an unmodified restore,
        infer_segment) and keeps the published preprocessor settings."""
        import logging

        from nemo.collections.asr.models import EncDecSpeakerLabelModel

        logging.disable(logging.WARNING)
        try:
            ref = EncDecSpeakerLabelModel.restore_from(str(E.MODELS / "titanet-s" / "titanet-s.nemo"),
                                                       map_location="cpu").eval()
        finally:
            logging.disable(logging.NOTSET)
        mine = self.model().model.preprocessor.featurizer
        self.assertEqual(mine.pad_to, ref.preprocessor.featurizer.pad_to)
        self.assertEqual(mine.normalize, ref.preprocessor.featurizer.normalize)
        for clip in self.clips():
            want = ref.infer_segment(clip)[0].squeeze().detach().numpy()
            want = want / np.linalg.norm(want)
            np.testing.assert_allclose(self.model().embed(clip), want, atol=1e-5)


class _WeSpeakerMixin(_RealModelMixin):
    def test_front_end_matches_upstream_and_trunk_matches_onnx(self):
        """Front end equals WeSpeaker's own Speaker.compute_features (extracted
        from the pinned source and run unmodified on int16-scaled audio, as its
        CLI loads it); embedding equals the published ONNX export."""
        import ast
        import types

        import onnxruntime as ort
        import torch
        import torchaudio.compliance.kaldi as kaldi

        src = (E._pinned_source(E._WESPEAKER_SRC) / "wespeaker/cli/speaker.py").read_text()
        fn = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef) and n.name == "compute_features")
        ns = {"kaldi": kaldi, "torch": torch}
        exec(compile(ast.Module([fn], []), "speaker.py", "exec"), ns)
        fake_self = types.SimpleNamespace(model=types.SimpleNamespace(frontend_type="fbank"), window_type="hamming")
        m = self.model()
        fname, sha = E.ONNX_REFERENCE[self.model_name]
        sess = ort.InferenceSession(E.read_verified(E.MODELS / self.model_name / fname, sha),
                                    providers=["CPUExecutionProvider"])
        for clip in self.clips():
            clip = (np.round(clip * 32767.0) / 32768.0).astype(np.float32)  # 16-bit PCM, as the CLI reads it
            int16_scaled = torch.from_numpy(np.round(clip * 32768.0).astype(np.float32))[None]
            want = ns["compute_features"](fake_self, int16_scaled).numpy()
            got = m.fbank(torch.from_numpy(clip)[None]).numpy()
            np.testing.assert_allclose(got, want, atol=1e-3)
            ref = sess.run(None, {"feats": want})[0][0]
            np.testing.assert_allclose(m.embed(clip), ref / np.linalg.norm(ref), atol=1e-3)


def _real(name, *mixins, nemo=False):
    base = mixins or (_RealModelMixin,)
    ok = (E.MODELS / name).is_dir() and (_HAS_NEMO or not nemo)
    reason = f"needs {name} weights" + (" and ./python-nemo" if nemo else "")
    cls = type(f"Real_{name.replace('-', '_')}", base + (unittest.TestCase,), {"model_name": name})
    return unittest.skipUnless(ok, reason)(cls)


WeSpeakerR34 = _real("wespeaker-r34lm", _WeSpeakerMixin)
WeSpeakerCampp = _real("wespeaker-campp", _WeSpeakerMixin)
ReDimNet2B0 = _real("redimnet2-b0")
ReDimNet2B2 = _real("redimnet2-b2")
TitaNetLarge = _real("titanet-l", nemo=True)


class RegistryCoverageTest(unittest.TestCase):
    def test_every_registered_model_has_a_real_test(self):
        tested = {c.model_name for c in globals().values()
                  if isinstance(c, type) and issubclass(c, _RealModelMixin) and c.model_name}
        self.assertEqual(tested, set(E.available()))


class VendoredImportIsolationTest(unittest.TestCase):
    """Loading the vendored WeSpeaker / ReDimNet2 sources must not occupy or
    replace the public package names (W4 uses upstream WeSpeaker)."""

    @unittest.skipUnless((E.MODELS / "wespeaker-campp").is_dir() and (E.MODELS / "redimnet2-b0").is_dir(),
                         "needs WeSpeaker and ReDimNet2 weights")
    def test_public_names_untouched(self):
        import sys
        import types

        sentinel = types.ModuleType("wespeaker")
        saved = {k: sys.modules.pop(k) for k in list(sys.modules) if k in ("wespeaker", "redimnet2")
                 or k.startswith(("wespeaker.", "redimnet2."))}
        try:
            sys.modules["wespeaker"] = sentinel  # stands in for an installed upstream package
            E.load_embedder("wespeaker-campp")
            E.load_embedder("redimnet2-b0")
            self.assertIs(sys.modules["wespeaker"], sentinel)
            self.assertFalse([k for k in sys.modules if k.startswith(("wespeaker.", "redimnet2"))])
            del sys.modules["wespeaker"]
            self.assertIsNone(importlib.util.find_spec("wespeaker"))  # not installed here; must not raise
            self.assertIsNone(importlib.util.find_spec("redimnet2"))
        finally:
            sys.modules.pop("wespeaker", None)
            sys.modules.update(saved)


if __name__ == "__main__":
    unittest.main()
