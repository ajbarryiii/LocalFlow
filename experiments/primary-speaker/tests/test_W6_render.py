"""W6 render sets: speaker audits, identity binding, manifests, the packed bank (DESIGN 2.2-2.5)."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.personal import render as R
from lfspk.personal.signals import arrays_digest


def meta(target, interferers=(), utt="1-2-3"):
    return {"target": {"speaker": target, "utt": utt}, "interferers": [{"speaker": s} for s in interferers]}


class TestAudits(unittest.TestCase):
    def test_public(self):
        R.audit_public(meta("10", ("11", "12")), held=("20", "21"))
        with self.assertRaises(AssertionError):
            R.audit_public(meta("20"), held=("20",))
        with self.assertRaises(AssertionError):
            R.audit_public(meta("10", ("21",)), held=("20", "21"))

    def test_score_present(self):
        pilot, scoring = ("1", "2"), ("30", "31", "32")
        R.audit_score(meta("1", ("30", "31")), "1", scoring, pilot)
        with self.assertRaises(AssertionError):  # another pilot subject as interferer
            R.audit_score(meta("1", ("2",)), "1", scoring, pilot)
        with self.assertRaises(AssertionError):  # a non-scoring interferer
            R.audit_score(meta("1", ("99",)), "1", scoring, pilot)
        with self.assertRaises(AssertionError):  # wrong target
            R.audit_score(meta("2", ("30",)), "1", scoring, pilot)

    def test_score_absent(self):
        pilot, scoring = ("1", "2"), ("30", "31", "32")
        R.audit_score(meta("30", ("31",)), None, scoring, pilot)
        with self.assertRaises(AssertionError):
            R.audit_score(meta("1", ("31",)), None, scoring, pilot)

    def test_tv_programme_speakers_audited(self):
        m = {"target": {"speaker": "10", "utt": "u"}, "interferers": [{"kind": "tv", "speakers": ["20", "11"]}]}
        with self.assertRaises(AssertionError):
            R.audit_public(m, held=("20",))


def _write(root: Path, name: str, keys, ident, f16=False, n_base=1600):
    d = root / name / "mix"
    d.mkdir(parents=True)
    (root / name / "render_identity.json").write_text(json.dumps(ident))
    rng = np.random.default_rng(0)
    for i, k in enumerate(keys):
        n = n_base * (i + 2)
        arrs = {"info": np.array(json.dumps({"family": k.split("-")[0], "index": int(k.split("-")[1]), "speaker": "10",
                                             "utt": "u", "seed": i, "interferers": [], "sir_db": 3.0, "ntr": 0.1,
                                             "p_target_active": 1e-3}))}
        if f16:
            for c in R.CHANNELS:
                arrs[c] = rng.standard_normal(n).astype(np.float16)
            arrs["target_active"] = rng.random(n // 160) > 0.5
            arrs["interferer_active"] = rng.random(n // 160) > 0.5
        else:
            arrs["audio"] = rng.standard_normal(n).astype(np.float32)
        np.savez(d / f"{k}.npz", **arrs)


class TestIdentityBinding(unittest.TestCase):
    def test_manifest_and_tamper(self):
        ident = {"kind": "w6-render", "set": "x", "v": 1, "w0": {"w0_commit": "a", "w0_code_sha256": "c"}}
        keys = ["S1-000", "S1-001", "S2-000"]
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _write(root, "x", keys, ident)
            R.finish("x", root, keys=keys)
            fn = lambda name: ident  # noqa: E731
            R.validated_manifest("x", root, fn, keys=keys)
            got = [k for k, _ in R.load_set("x", out=root, identity_fn=fn, expected=keys)]
            self.assertEqual(got, sorted(keys))
            # w0_commit is recorded, not compared
            R.validated_manifest("x", root, lambda n: {**ident, "w0": {"w0_commit": "b", "w0_code_sha256": "c"}}, keys=keys)
            with self.assertRaises(RuntimeError):  # another current identity
                R.validated_manifest("x", root, lambda n: {**ident, "v": 2}, keys=keys)
            with self.assertRaises(RuntimeError):  # missing key
                R.validated_manifest("x", root, fn, keys=keys + ["S3-000"])
            z = dict(np.load(root / "x" / "mix" / "S1-001.npz"))
            z["audio"] = z["audio"] * 2
            np.savez(root / "x" / "mix" / "S1-001.npz", **z)
            with self.assertRaises(RuntimeError):
                R.validated_manifest("x", root, fn, keys=keys)
            with self.assertRaises(RuntimeError):
                list(R.load_set("x", out=root, identity_fn=fn, expected=keys))

    def test_prepare_refuses_other_identity(self):
        from lfspk.extract.stage0 import prepare_render_dir

        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / "x"
            self.assertEqual(prepare_render_dir(root, {"a": 1}, ["k"]), ["k"])
            with self.assertRaises(RuntimeError):
                prepare_render_dir(root, {"a": 2}, ["k"])


class TestPack(unittest.TestCase):
    def test_round_trip(self):
        from lfspk.personal.stream import Bank

        ident = {"kind": "w6-render", "set": "bank"}
        keys = [f"{f}-{i:03d}" for f in R.SCEN for i in range(2)]
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _write(root, "bank", keys, ident, f16=True)
            R.finish("bank", root, keys=keys)
            meta = R.pack(root, identity_fn=lambda n: ident, keys=keys)
            with self.assertRaises(ValueError):  # code1-r1 m5: no current verification needs a pinned pack
                Bank(root / R.PACK, verify_current=False)
            import hashlib

            pin = hashlib.sha256((root / R.PACK / "pack.json").read_bytes()).hexdigest()
            bank = Bank(root / R.PACK, verify_current=False, pack_sha256=pin)
            for k in keys:
                f, i = k.split("-")
                z = np.load(root / "bank" / "mix" / f"{k}.npz")
                D = bank.get(f, int(i))
                np.testing.assert_array_equal(D.target, z["target"].astype(np.float32))
                np.testing.assert_array_equal(D.event, z["event"].astype(np.float32))
                np.testing.assert_array_equal(D.interferer_active, z["interferer_active"])
                self.assertEqual(D.sir_db, 3.0)
            self.assertEqual(bank.counts["S3"], 2)
            Bank(root / R.PACK, verify_current=False, pack_sha256=bank.pack_sha256)
            with self.assertRaises(RuntimeError):
                Bank(root / R.PACK, verify_current=False, pack_sha256="0" * 64)
            a = np.load(root / R.PACK / "bank16.npy", mmap_mode="r+")
            a[0, 0] = a[0, 0] + np.float16(1)
            a.flush()
            del a
            with self.assertRaises(RuntimeError):
                Bank(root / R.PACK, verify_current=False, pack_sha256=pin)
            self.assertIn("files", meta)


class TestDigest(unittest.TestCase):
    def test_digest_sensitivity(self):
        a = {"x": np.zeros(3, np.float32), "info": np.array("{}")}
        b = {"x": np.zeros(3, np.float16), "info": np.array("{}")}
        self.assertNotEqual(arrays_digest(a), arrays_digest(b))
        self.assertEqual(arrays_digest(a), arrays_digest(dict(a)))


@unittest.skipUnless(os.path.ismount("/mnt/hd") and os.environ.get("W6_RENDER_INTEGRATION") == "1",
                     "real W0 renders (set W6_RENDER_INTEGRATION=1; held-out TRAIN speakers only)")
class TestRealRenders(unittest.TestCase):
    """One unit of each set through the production jobs, into a temporary directory."""

    def test_units(self):
        from lfspk.personal import subjects as S

        with tempfile.TemporaryDirectory() as t:
            out = Path(t)
            spk = S.PILOT["F"][0]
            self.assertEqual(R._job(("dict", f"{spk}-00", str(out))), [f"{spk}-00"])
            d = R.decode(R._npz(out / f"{spk}-00.npz"))
            self.assertEqual(d["info"]["role"], "tune")
            self.assertGreaterEqual(int(d["target_active"].sum()), 50)
            self.assertEqual(R._job(("bank", "S4-000", str(out))), ["S4-000"])
            b = R.decode(R._npz(out / "S4-000.npz"))
            self.assertEqual(b["target"].dtype, np.float16)
            self.assertIsNotNone(b["info"]["sir_db"])
            self.assertFalse(({b["info"]["speaker"]} | set(b["info"]["interferers"])) & set(S.held_out()))
            keys = R._job(("score", f"{spk}-p-0", str(out)))
            self.assertEqual(sorted(keys), sorted(f"{spk}-p-{f}-00" for f in R.FAMILIES))
            n = R.decode(R._npz(out / f"{spk}-p-N-00.npz"))
            self.assertFalse(n["interfering"].any())
            np.testing.assert_allclose(n["audio"], n["target_image"] + n["noise"], atol=1e-6)
            a = R._job(("score", f"{spk}-a-S4-0", str(out)))
            ad = R.decode(R._npz(out / f"{a[0]}.npz"))
            self.assertTrue(ad["info"]["absent"])
            self.assertIn(ad["info"]["talker"], S.scoring_interferers())


if __name__ == "__main__":
    unittest.main()


class TestDictationActivity(unittest.TestCase):
    """Erratum E1: only tuning dictations need >= 50 target-active frames."""

    def test_short_drift_dictation_allowed(self):
        R.check_dictation_activity("497-31", 31, 25)  # 497-129325-0061: 1.075 s, 25 active frames, drift (D3 only)

    def test_short_tuning_dictation_refused(self):
        with self.assertRaises(AssertionError):
            R.check_dictation_activity("497-04", 4, 49)
        R.check_dictation_activity("497-04", 4, 50)

    def test_precheck_contract(self):
        rows = [{"key": "497-04", "utt": "u", "seconds": 2.175, "active_frames": 120, "role": "tune"},
                {"key": "497-31", "utt": "v", "seconds": 1.075, "active_frames": 25, "role": "drift"}]
        res = R.summarise_scan(rows, "a" * 64)
        self.assertEqual(res["set_identity_sha256"], "a" * 64)
        self.assertEqual([r["key"] for r in res["drift_below_50_active"]], ["497-31"])
        self.assertEqual(len(res["outside_3_20s_source"]), 2)
        rows[0]["active_frames"] = 30
        with self.assertRaises(AssertionError):  # a short tuning dictation fails the precheck
            R.summarise_scan(rows, "a" * 64)


class TestProfileWindows(unittest.TestCase):
    def test_tuning_dictation_without_window_fails(self):
        from lfspk.personal import profiles as P

        ok = [{"windows_kept": 3}] * 10
        P.check_tuning_windows("x", ok, 10)
        with self.assertRaises(RuntimeError):
            P.check_tuning_windows("x", ok[:9] + [{"windows_kept": 0}], 10)
        with self.assertRaises(RuntimeError):
            P.check_tuning_windows("x", ok, 9)

    def test_enroll_equivalence_check(self):
        from lfspk.personal import profiles as P

        class Prof:
            def __init__(self, b):
                self.b = b

            def to_bytes(self):
                return self.b

        P.check_enroll_equivalence("x", Prof(b"\x01\x02"), Prof(b"\x01\x02"))
        with self.assertRaises(RuntimeError):
            P.check_enroll_equivalence("x", Prof(b"\x01\x02"), Prof(b"\x01\x03"))


@unittest.skipUnless(os.path.ismount("/mnt/hd"), "needs W1's artefacts and the redimnet2-b2 weights")
class TestEnrollEquivalenceReal(unittest.TestCase):
    def test_enroll_windows_equals_enroll(self):
        import torch

        from lfspk.personal import profiles as P

        torch.set_num_threads(1)
        prof = P.make_profiler()
        rng = np.random.default_rng(0)
        t = np.arange(3 * 16000) / 16000.0
        audios = []
        for f0 in (140.0, 180.0, 220.0):  # synthetic voiced-like signals with an amplitude envelope
            x = sum(np.sin(2 * np.pi * f0 * h * t) / h for h in range(1, 12)) * (0.5 + 0.5 * np.sin(2 * np.pi * 3 * t))
            audios.append((0.1 * x / np.abs(x).max() + 0.002 * rng.standard_normal(len(t))).astype(np.float32))
        via_w, rows = P.enroll_window_counts(prof, audios)
        P.check_enroll_equivalence("synthetic", via_w, prof.enroll(audios))
        self.assertEqual(len(rows), 3)
