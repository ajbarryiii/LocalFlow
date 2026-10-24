"""Contract tests of the front-end evaluator, part 2 (DESIGN.md 14.2 fe-4, fe-5):
stage B caches (bypass pinning, fixed chunks and whole-chunk resume), B*, the
load-time checks and their refusals, and purge's precondition. NeMo-free:
`fake_transcribe_masked` keeps nemo_hook.transcribe_masked's contract."""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.extract import cachepin, nemo_hook
from lfspk.harness import fe_stage_a as A
from lfspk.harness import fe_stage_b as B
from lfspk.harness.frozen import FrozenSet
from tests import w0_frontend_fixtures as X

SPEC = "tests.w0_frontend_fixtures:make"
K3 = ("builtin", False, 3)


class StageBTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        t = Path(cls._tmp.name)
        cls.set_root = X.build_set(t / "set")
        cls.fs = FrozenSet("fake-set", root=cls.set_root)
        cls.repo = X.init_repo(t / "repo")
        cls.masks = t / "masks"
        for cond in (A.HEADLINE, K3):
            A.run_stage_a(cls.fs, SPEC, {}, cond, workers=2, root=cls.masks, exploratory=True, repo=cls.repo, ledger=t / "L0.jsonl")

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        self._t = tempfile.TemporaryDirectory(dir="/tmp")
        t = Path(self._t.name)
        self.b_dir = t / "B"
        self.b_recs = X.write_b_cache(self.b_dir, self.set_root)
        self.out = t / "out"
        self.led = t / "LEDGER.jsonl"
        self.fe = X.make()

    def tearDown(self):
        self._t.cleanup()

    def st_a(self, cond=A.HEADLINE):
        return A.load_stage_a(self.fs, SPEC, {}, cond, root=self.masks, repo=self.repo, fe=self.fe)

    def run_b(self, cond=A.HEADLINE, config="C1", bstar=False, model=None, **kw):
        model = model or X.FakeASR()
        d = B.run_stage_b(self.fs, self.out, stage_a=None if bstar else self.st_a(cond), fe=None if bstar else self.fe,
                          config_name=config, model=model, asr_identity=dict(X.B_IDENTITY), b_dir=self.b_dir,
                          transcribe_fn=X.fake_transcribe_masked, repo=self.repo, ledger=self.led,
                          exploratory=True if bstar else None, **kw)
        return d, model

    def load_b(self, cond=A.HEADLINE, config="C1", bstar=False, **kw):
        return B.load_stage_b(self.fs, self.out, stage_a=None if bstar else self.st_a(cond), fe=None if bstar else self.fe,
                              config_name=config, b_dir=self.b_dir, repo=self.repo, **kw)

    # --- writing ----------------------------------------------------------------------------

    def test_c1_headline_all_masked(self):
        d, model = self.run_b()
        sb = self.load_b()
        self.assertEqual(sorted(sb.entries), sorted(f"mix:{m}" for m in A.expected_mixtures(self.fs, A.HEADLINE)))
        self.assertEqual(sb.n_bypass, 0)
        st = self.st_a()
        for k, e in sb.entries.items():
            self.assertFalse(e["bypass"])
            self.assertEqual(e["mask_sha256"], st.hashes[k[4:]])
            self.assertEqual(e["audio_sha256"], X.frozen_mix_hashes(self.set_root)[k])
            self.assertTrue(e["text"].startswith("f "))
        ident = sb.identity
        self.assertEqual(ident["batching"], "batched")
        self.assertEqual(ident["batch_size"], B.BATCH)
        self.assertEqual(ident["stage_a"], st.key_sha256)
        self.assertEqual(ident["config"], self.fe.config("C1").to_dict())
        self.assertIsNone(ident["config"]["theta_b"])  # C1 stores None although the front end has a numeric theta_b
        self.assertEqual(ident["hook_code_sha256"], nemo_hook.hook_code_sha256())

    def test_bypass_entries_are_pinned_copies_of_b(self):
        self.run_b(K3, "C3")
        sb = self.load_b(K3, "C3")
        self.assertEqual(sb.n_bypass, 2)  # speaker 12 (u 0.15 < theta_b 0.5); speaker 11 is masked (0.55)
        for k, e in sb.entries.items():
            if e["bypass"]:
                self.assertTrue(k.endswith("-12-00"))
                for f in cachepin.RECORD_FIELDS:
                    self.assertEqual(e[f], self.b_recs[k][f])
                self.assertEqual(e["b_record_digest"], cachepin.record_digest(self.b_recs[k]))
            else:
                self.assertTrue(k.endswith("-11-00"))
        self.assertEqual(sb.identity["config"]["theta_b"], 0.5)

    def test_masked_inputs_and_fixed_chunks(self):
        d, model = self.run_b(chunk=3)
        # 4 masked mixtures in id order: chunks [3, 1], each one call
        self.assertEqual([len(c) for c in model.calls], [3, 1])
        lines = [json.loads(l) for l in (d / "asr.jsonl").read_text().splitlines()]
        self.assertEqual([e["chunk"] for e in lines], [0, 0, 0, 1])
        self.assertEqual([e["key"] for e in lines], sorted(e["key"] for e in lines))

    def test_resume_redoes_a_partial_chunk_whole(self):
        d0, _ = self.run_b(chunk=3)
        full = (d0 / "asr.jsonl").read_text()
        lines = full.splitlines()
        # A crash while writing chunk 0's block: two of its three entries got out.
        (d0 / "asr.jsonl").write_text("\n".join(lines[:2]) + "\n")
        (d0 / "COMPLETE.json").unlink()
        d1, model = self.run_b(chunk=3)
        self.assertEqual([len(c) for c in model.calls], [3, 1])  # chunk 0 redone whole, chunk 1 was missing
        self.assertEqual(sorted((d1 / "asr.jsonl").read_text().splitlines()), sorted(lines))
        self.load_b(chunk=3)
        # A crash after chunk 0: only chunk 1 is redone.
        (d0 / "asr.jsonl").write_text("\n".join(lines[:3]) + "\n" + '{"key": "mix:trunc')
        (d0 / "COMPLETE.json").unlink()
        _, model = self.run_b(chunk=3)
        self.assertEqual([len(c) for c in model.calls], [1])

    def test_claiming(self):
        self.run_b()
        meta = self.out / "stageB" / "base" / A.slug(A.HEADLINE) / "C1" / "asr.meta.json"
        m = json.loads(meta.read_text())
        m["identity"]["batch_size"] = 8
        meta.write_text(json.dumps(m))
        with self.assertRaises(SystemExit):  # holds another identity
            self.run_b()

    # --- loading: refusals ---------------------------------------------------------------------

    def _edit_b(self, key, **fields):
        recs = [json.loads(l) for l in (self.b_dir / "asr.jsonl").read_text().splitlines()]
        for r in recs:
            if r["key"] == key:
                r.update(fields)
        (self.b_dir / "asr.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs))

    def test_stale_b_record_refused(self):
        self.run_b(K3, "C3")
        self.load_b(K3, "C3")
        self._edit_b("mix:S0-12-00", text="rebuilt")
        with self.assertRaises(SystemExit):
            self.load_b(K3, "C3")

    def test_changed_b_identity_refused(self):
        self.run_b(K3, "C3")
        (self.b_dir / "asr.meta.json").write_text(json.dumps({**X.B_IDENTITY, "nemo": "3.1.0"}))
        with self.assertRaises(SystemExit):
            self.load_b(K3, "C3")

    def _edit_entries(self, d, fn):
        lines = [json.loads(l) for l in (d / "asr.jsonl").read_text().splitlines()]
        (d / "asr.jsonl").write_text("".join(json.dumps(fn(e)) + "\n" for e in lines))

    def test_altered_copy_refused(self):
        d, _ = self.run_b(K3, "C3")
        self._edit_entries(d, lambda e: {**e, "text": "x"} if e["bypass"] else e)
        with self.assertRaises(SystemExit):
            self.load_b(K3, "C3")

    def test_mask_hash_mismatch_refused(self):
        d, _ = self.run_b()
        self._edit_entries(d, lambda e: {**e, "mask_sha256": "0" * 64} if e["key"] == "mix:S1-11-00" else e)
        with self.assertRaises(SystemExit):
            self.load_b()

    def test_masked_entry_wrong_audio_refused(self):
        d, _ = self.run_b()
        self._edit_entries(d, lambda e: {**e, "audio_sha256": "1" * 64} if e["key"] == "mix:S1-11-00" else e)
        with self.assertRaises(SystemExit):
            self.load_b()

    def test_wrong_batching_mode_refused(self):
        d, _ = self.run_b()
        m = json.loads((d / "asr.meta.json").read_text())
        m["identity"]["batching"] = "single"
        (d / "asr.meta.json").write_text(json.dumps(m))
        with self.assertRaises(SystemExit):
            self.load_b()

    def test_missing_coverage_key_refused(self):
        d, _ = self.run_b()
        lines = (d / "asr.jsonl").read_text().splitlines()
        (d / "asr.jsonl").write_text("\n".join(lines[1:]) + "\n")
        with self.assertRaises(SystemExit):
            self.load_b()

    def test_hook_hash_change_refused(self):
        self.run_b()
        orig = B.hook_code_sha256
        try:
            B.hook_code_sha256 = lambda: "f" * 64
            with self.assertRaises(SystemExit):
                self.load_b()
        finally:
            B.hook_code_sha256 = orig
        self.load_b()

    def test_bypass_flag_recomputed_from_arrays(self):
        d, _ = self.run_b(K3, "C3")
        # Mark a masked entry as if it had been bypassed (with B's pinned record).
        def flip(e):
            if e["key"] == "mix:S0-11-00":
                pin = cachepin.pin_bypass(self.b_recs[e["key"]], X.B_IDENTITY, e["audio_sha256"])
                return {**pin, "mask_sha256": e["mask_sha256"], "chunk": -1}
            return e
        self._edit_entries(d, flip)
        c = json.loads((d / "COMPLETE.json").read_text())
        (d / "COMPLETE.json").write_text(json.dumps({**c, "n_bypass": c["n_bypass"] + 1}))  # consistent count: only check 7 can see it
        with self.assertRaises(SystemExit):
            self.load_b(K3, "C3")

    def test_bypass_count_must_agree(self):
        d, _ = self.run_b(K3, "C3")
        c = json.loads((d / "COMPLETE.json").read_text())
        (d / "COMPLETE.json").write_text(json.dumps({**c, "n_bypass": c["n_bypass"] + 1}))
        with self.assertRaises(SystemExit):
            self.load_b(K3, "C3")

    def test_stage_a_change_refused(self):
        self.run_b()
        st = self.st_a()
        other = A.StageA(st.dir, st.key, "9" * 64, st.run, st.hashes, st.purged)
        with self.assertRaises(SystemExit):
            B.load_stage_b(self.fs, self.out, stage_a=other, fe=self.fe, config_name="C1", b_dir=self.b_dir, repo=self.repo)

    # --- code2-r1 fixes --------------------------------------------------------------------------

    def test_m1_refused_until_b_m1_exists(self):
        with self.assertRaises(SystemExit):
            self.run_b(weights="m1")
        self.run_b()
        with self.assertRaises(SystemExit):
            self.load_b(weights="m1")
        with self.assertRaises(SystemExit):
            B.purge(self.fs, self.out, self.st_a(K3), self.fe, ["C1"], self.b_dir, self.repo, weights="m1")

    def test_decoded_bytes_are_the_frozen_bytes(self):
        from lfspk.harness.util import load_audio

        row = self.fs.manifest[0]
        p = self.fs.root / row["files"]["mix"]
        want = X.frozen_mix_hashes(self.set_root)[f"mix:{row['id']}"]
        np.testing.assert_array_equal(B.decode_verified(p, want), load_audio(p))
        with self.assertRaises(SystemExit):
            B.decode_verified(p, "0" * 64)

    def test_only_the_frozen_format_is_decoded(self):
        import hashlib

        import soundfile as sf

        t = Path(self._t.name)
        for name, data, sr in (("48k", np.zeros(48000, np.float32), 48000), ("stereo", np.zeros((16000, 2), np.float32), 16000)):
            with self.subTest(name):
                p = t / f"{name}.flac"
                sf.write(p, data, sr, subtype="PCM_24")
                with self.assertRaisesRegex(SystemExit, "16 kHz mono"):
                    B.decode_verified(p, hashlib.sha256(p.read_bytes()).hexdigest())

    def test_swapped_file_of_same_length_refused(self):
        import shutil

        rows = {r["id"]: r for r in self.fs.manifest}
        a, b = self.fs.root / rows["S0-11-00"]["files"]["mix"], self.fs.root / rows["S1-11-00"]["files"]["mix"]
        saved = a.read_bytes()
        try:
            shutil.copyfile(b, a)  # same length, other audio
            with self.assertRaises(SystemExit):
                self.run_b()
        finally:
            a.write_bytes(saved)

    def test_resume_verifies_retained_bypass_copies(self):
        d, _ = self.run_b(K3, "C3")
        (d / "COMPLETE.json").unlink()  # an interrupted run
        self._edit_b("mix:S0-12-00", text="rebuilt")  # B changed meanwhile, same identity
        with self.assertRaises(SystemExit):
            self.run_b(K3, "C3")
        self.assertFalse((d / "COMPLETE.json").exists())

    # --- B* ------------------------------------------------------------------------------------

    def test_bstar(self):
        d, model = self.run_b(bstar=True)
        self.assertEqual(d, self.out / "stageB" / "base" / "bstar" / "C1")
        sb = self.load_b(bstar=True)
        self.assertEqual(sorted(sb.entries), sorted(f"mix:{r['id']}" for r in self.fs.manifest))
        self.assertEqual(sb.identity["stage_a"], B.BSTAR_STAGE_A)
        self.assertEqual(sb.identity["config"], {"name": "C1", "theta_b": None})
        for k, e in sb.entries.items():
            self.assertFalse(e["bypass"])
        for name, fn in (("nonzero mask", lambda e: {**e, "mask_sha256": "2" * 64}),
                         ("wrong audio, right key and length", lambda e: {**e, "audio_sha256": "3" * 64}),
                         ("bypass entry", lambda e: {**cachepin.pin_bypass(self.b_recs[e["key"]], X.B_IDENTITY, e["audio_sha256"]),
                                                     "mask_sha256": e["mask_sha256"], "chunk": -1})):
            with self.subTest(name):
                good = (d / "asr.jsonl").read_text()
                self._edit_entries(d, lambda e: fn(e) if e["key"] == "mix:S0-11-00" else e)
                with self.assertRaises(SystemExit):
                    self.load_b(bstar=True)
                (d / "asr.jsonl").write_text(good)
        self.load_b(bstar=True)

    # --- purge -----------------------------------------------------------------------------------

    def test_purge_requires_complete_stage_b(self):
        with self.assertRaises(SystemExit):
            B.purge(self.fs, self.out, self.st_a(K3), self.fe, ["C1", "C3"], self.b_dir, self.repo)
        self.run_b(K3, "C1")
        with self.assertRaises(SystemExit):  # C3 still missing
            B.purge(self.fs, self.out, self.st_a(K3), self.fe, ["C1", "C3"], self.b_dir, self.repo)
        self.run_b(K3, "C3")
        B.purge(self.fs, self.out, self.st_a(K3), self.fe, ["C1", "C3"], self.b_dir, self.repo)
        st = self.st_a(K3)
        self.assertTrue(st.purged)
        sb = self.load_b(K3, "C3")  # still loads: pins and hashes survive the purge
        self.assertEqual(sb.n_bypass, 2)
        A.run_stage_a(self.fs, SPEC, {}, K3, workers=2, root=self.masks, exploratory=True, repo=self.repo,
                      ledger=self.led)  # regenerate for the other tests


if __name__ == "__main__":
    unittest.main()
