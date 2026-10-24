"""Integration test of the evaluator's metric computation on a fabricated frozen
set (synthetic labels, words and scores; no audio, no ASR)."""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.harness import evaluate as E
from lfspk.harness.frozen import FrozenSet


def _tok(text, f0, f1, src, kind, op, reg="single"):
    return [text, f0, f1, 0, src, kind, 0, op, reg, reg, f0 / 100, f1 / 100]


class EvaluatorTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        root = Path(self._tmp.name) / "set"
        (root / "labels").mkdir(parents=True)
        self.root = root
        rows, words = [], {}
        F = 300
        spk = ["11", "12", "13", "14"]
        for i, t in enumerate(spk):
            other = spk[(i + 1) % 4]
            for scen in ("S0", "S4"):
                mid = f"{scen}-{t}-00"
                lab = np.zeros(F, np.uint8)
                lab[0:100] = 1  # target 0-1 s
                if scen == "S4":
                    lab[150:250] = 2  # interferer only 1.5-2.5 s
                np.savez_compressed(root / "labels" / f"{mid}.npz", labels=lab, target_active=(lab == 1) | (lab == 3),
                                    interferer_actives=np.array([(lab == 2) | (lab == 3)]) if scen == "S4" else np.zeros((0, F), bool))
                toks = [_tok(f"w{k}", 10 * k, 10 * k + 8, "target", "C", "C") for k in range(10)]
                ints = []
                if scen == "S4":
                    toks += [_tok(f"i{k}", 150 + 20 * k, 165 + 20 * k, "interferer", "C", "I") for k in range(5)]
                    ints = [{"kind": "dictator", "speaker": other, "sir_db": 0.0}]
                words[mid] = {"id": mid, "frames": F, "tokens": toks, "n_ref": {"single": 10, "overlap": 0}, "dels": {"single": 0, "overlap": 0},
                              "untimed_errors": {}, "target_ref": [[f"w{k}", k / 10, k / 10 + 0.08] for k in range(10)], "n_interferer_ref": [5] if ints else []}
                rows.append({"id": mid, "scenario": scen, "rir_mode": "coherent", "speaker": t, "half": "A" if i < 2 else "B", "target_index": 0,
                             "seed": 0, "relation_at": {"3": "cross_project", "10": "cross_project", "30": None}, "enroll_len": 10,
                             "files": {"labels": f"labels/{mid}.npz", "mix": "", "target_dry": "", "interferers_dry": []},
                             "meta": {"frames": F, "interferers": ints, "split": "dev"}})
        (root / "manifest.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        enr = []
        for t in spk:
            for d in ("builtin", "headset"):
                for j in range(10):
                    enr.append({"speaker": t, "device": d, "index": j, "contaminated": False, "file": f"enroll/{t}-{d}-{j}.flac", "relation": "cross_project"})
                enr.append({"speaker": t, "device": d, "index": 1, "contaminated": True, "file": f"enroll/{t}-{d}-1c.flac", "relation": "cross_project"})
        (root / "enrollment.jsonl").write_text("".join(json.dumps(e) + "\n" for e in enr))
        (root / "plans.json").write_text(json.dumps({"plans": [{"speaker": s, "test_project_in_train": True} for s in spk]}))
        (root / "HASH").write_text("x\n")
        self.fs = FrozenSet("fake", root=root)
        self.words = words
        self.rows = rows

    def tearDown(self):
        self._tmp.cleanup()

    def _scores(self, out: Path, fn):
        (out / "scores").mkdir(parents=True, exist_ok=True)
        by = {}
        for r in self.rows:
            lab = self.fs.labels(r)["labels"]
            for d in ("builtin", "headset"):
                for c in ("clean", "contaminated"):
                    for k in (3, 10):
                        by.setdefault(r["speaker"], {})[f"{d}|{c}|{k}|{r['id']}"] = fn(lab)
        for spk, d in by.items():
            E.save_scores(out / "scores" / f"{spk}.npz", d)

    def test_oracle_reaches_ceiling_and_keep_is_unfiltered(self):
        out = Path(self._tmp.name) / "o"
        res = E.compute_metrics("fake", out, "all", "oracle", boot=50, fs=self.fs, words=self.words)
        c = res["conditions"]["builtin|clean|10"]
        self.assertEqual(c["point"]["S4"]["interferer_kept/all"], 0.0)
        self.assertEqual(c["point"]["pooled_all"]["target_removed/all"], 0.0)
        self.assertAlmostEqual(c["point"]["S4"]["wer_after/all"], 0.0)
        self.assertAlmostEqual(c["point"]["S4"]["wer_before/all"], 0.5)  # 5 insertions / 10 words
        self.assertIn("skipped", res["conditions"]["builtin|clean|30"])
        out2 = Path(self._tmp.name) / "k"
        self._scores(out2, lambda lab: np.ones(lab.size, np.float32))
        res2 = E.compute_metrics("fake", out2, "all", "keep", boot=50, fs=self.fs, words=self.words)
        c2 = res2["conditions"]["builtin|clean|10"]
        self.assertEqual(c2["point"]["S4"]["interferer_kept/all"], 1.0)
        self.assertEqual(c2["point"]["S4"]["wer_after/all"], c2["point"]["S4"]["wer_before/all"])
        # The oracle is reported beside every scorer.
        self.assertEqual(c2["oracle"]["S4"]["interferer_kept/all"], 0.0)

    def test_budget_and_cis(self):
        # A scorer that is right except for one target word per mixture scored 0.
        def fn(lab):
            s = ((lab == 1) | (lab == 3)).astype(np.float32)
            s[0:8] = 0.0
            return s

        out = Path(self._tmp.name) / "b"
        self._scores(out, fn)
        res = E.compute_metrics("fake", out, "all", "x", boot=200, fs=self.fs, words=self.words)
        c = res["conditions"]["builtin|clean|10"]
        # Removing 1 of 10 words per mixture exceeds 0.5 %: tau must stay at or below 0,
        # so nothing is removed and every interferer word is kept.
        self.assertLessEqual(c["point"]["pooled_all"]["target_removed/all"], 0.005)
        self.assertEqual(c["point"]["S4"]["interferer_kept/all"], 1.0)
        lo, hi = c["ci95"]["S4|wer_before/all"]
        self.assertLessEqual(lo, 0.5)
        self.assertGreaterEqual(hi, 0.5)
        self.assertIn("A->B", c["crossfit"])


class ApplyAndReportTest(EvaluatorTest):
    def test_apply_uses_fixed_taus_and_refuses_test_calibration(self):
        out = Path(self._tmp.name) / "a"
        self._scores(out, lambda lab: ((lab == 1) | (lab == 3)).astype(np.float32))
        res = E.compute_metrics("fake", out, "all", "x", boot=30, fs=self.fs, words=self.words)
        cal = E.calibration_artefact(res, "x", {}, "fake", "h", "all", "dev")
        with self.assertRaises(SystemExit):
            E.calibration_artefact(res, "x", {}, "fake", "h", "all", "train")
        self.assertEqual(cal["hash"], E.calibration_hash(cal))
        self.assertIn("oracle_widen50ms|builtin|clean|10", cal["taus"])
        taus = {k: 0.25 for k in cal["taus"]}
        # Apply never fits the widening-sensitivity oracle taus (eval r5 #1).
        no_w = {k: v for k, v in taus.items() if not k.startswith("oracle_widen")}
        with self.assertRaises(SystemExit):
            E.compute_metrics("fake", out, "all", "x", boot=5, fs=self.fs, words=self.words, fixed_taus=no_w)
        # Apply never fits an oracle tau: a missing oracle key is an error (eval r2 #2).
        no_oracle = {k: v for k, v in taus.items() if not k.startswith("oracle|")}
        with self.assertRaises(SystemExit):
            E.compute_metrics("fake", out, "all", "x", boot=5, fs=self.fs, words=self.words, fixed_taus=no_oracle)
        # An uncalibrated dev condition is not evaluable.
        unc = dict(taus)
        unc["builtin|clean|3"] = None
        r3 = E.compute_metrics("fake", out, "all", "x", boot=5, fs=self.fs, words=self.words, fixed_taus=unc)
        self.assertIn("uncalibrated", r3["conditions"]["builtin|clean|3"]["skipped"])
        res2 = E.compute_metrics("fake", out, "all", "x", boot=30, fs=self.fs, words=self.words, fixed_taus=taus)
        c = res2["conditions"]["builtin|clean|10"]
        self.assertEqual(c["tau"], 0.25)
        self.assertEqual(c["tau_ci95"], (0.25, 0.25))  # never re-fit in the bootstrap
        self.assertNotIn("crossfit", c)
        # Test and train sets can only be applied, never calibrated (eval r2 #3).
        for split in ("test", "train"):
            for r in self.fs.manifest:
                r["meta"]["split"] = split
            with self.assertRaises(SystemExit):
                E.compute_metrics("fake", out, "all", "x", boot=10, fs=self.fs, words=self.words)
            E.compute_metrics("fake", out, "all", "x", boot=10, fs=self.fs, words=self.words, fixed_taus=taus)

    def test_report_shows_every_family(self):
        out = Path(self._tmp.name) / "r"
        self._scores(out, lambda lab: ((lab == 1) | (lab == 3)).astype(np.float32))
        res = E.compute_metrics("fake", out, "all", "x", boot=30, fs=self.fs, words=self.words)
        res.update({"scorer": "x", "set_id": "fake", "set_hash": "h", "half": "all"})
        md = E.report_md(res)
        for needle in ("kept nd", "kept+amb", "cover", "EER", "no-merge", "one product threshold", "Relation cross_project", "Cross-fit", "oracle"):
            self.assertIn(needle, md)

    def test_latency_refuses_without_cpu_env(self):
        with self.assertRaises(SystemExit):
            E.latency("fake", "lfspk.harness.baselines:keep_everything", {})

    def test_thread_change_after_init_refused(self):
        # Eval r2 #4: a factory that raises torch's thread count is caught.
        import os

        import torch

        old_env = {k: os.environ.get(k) for k in E.CPU_ENV}
        old_threads = torch.get_num_threads()
        try:
            os.environ.update(E.CPU_ENV)
            torch.set_num_threads(1)
            E._verify_threads({}, "ok")
            torch.set_num_threads(4)
            with self.assertRaises(SystemExit):
                E._verify_threads({}, "after scorer construction")
            torch.set_num_threads(1)
            os.environ["OMP_NUM_THREADS"] = "4"
            with self.assertRaises(SystemExit):
                E._verify_threads({}, "after measurement")
        finally:
            torch.set_num_threads(old_threads)
            for k, v in old_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_score_identity_binding(self):
        # Eval r2 #1: scores of one configuration cannot be calibrated as another's.
        out = Path(self._tmp.name) / "id"
        (out / "scores").mkdir(parents=True)
        ident = E.scorer_identity("a:b", {"x": "1"}, "fake", "x")
        (out / "scores" / "IDENTITY.json").write_text(json.dumps(ident))
        (out / "scores" / "COMPLETE.json").write_text(json.dumps({"identity": ident["hash"], "n_keys": 0, "keys_sha256": E._keys_hash([])}))
        E.check_score_identity(out, "a:b", {"x": "1"}, "fake", "x")
        for spec, kw, sid in (("a:c", {"x": "1"}, "fake"), ("a:b", {"x": "2"}, "fake"), ("a:b", {"x": "1"}, "other")):
            with self.assertRaises(SystemExit):
                E.check_score_identity(out, spec, kw, sid, "x")


class CompletenessTest(EvaluatorTest):
    def test_partial_or_unidentified_scores_refused(self):
        out = Path(self._tmp.name) / "p"
        self._scores(out, lambda lab: ((lab == 1) | (lab == 3)).astype(np.float32))
        # Drop one mixture's keys: metrics must refuse rather than shrink the pool (eval r3 #2).
        z = E.load_scores(out / "scores" / "11.npz")
        E.save_scores(out / "scores" / "11.npz", {k: v for k, v in z.items() if not k.endswith("S4-11-00")})
        with self.assertRaises(SystemExit):
            E.compute_metrics("fake", out, "all", "x", boot=5, fs=self.fs, words=self.words)
        # Identity and completeness markers (eval r3 #1).
        want = E.scorer_identity("a:b", {}, "fake", "x")
        with self.assertRaises(SystemExit):
            E.prepare_score_dir(out / "scores", want)  # archives without an identity
        sdir = Path(self._tmp.name) / "q" / "scores"
        E.prepare_score_dir(sdir, want)
        exp = E.expected_score_keys(self.fs, self.rows)
        with self.assertRaises(SystemExit):
            E.check_score_identity(sdir.parent, "a:b", {}, "fake", "x", exp)  # no COMPLETE yet
        (sdir / "COMPLETE.json").write_text(json.dumps({"identity": want["hash"], "n_keys": len(exp), "keys_sha256": E._keys_hash(exp)}))
        E.check_score_identity(sdir.parent, "a:b", {}, "fake", "x", exp)
        with self.assertRaises(SystemExit):
            E.check_score_identity(sdir.parent, "a:b", {}, "fake", "x", exp[1:])
        with self.assertRaises(SystemExit):
            E.prepare_score_dir(sdir, E.scorer_identity("a:c", {}, "fake", "x"))
        E.prepare_score_dir(sdir, want)
        self.assertFalse((sdir / "COMPLETE.json").exists())

    def test_crossfit_direction_uncalibrated(self):
        # Eval r3 #3: no correct target words in half A -> A->B uncalibrated.
        words = json.loads(json.dumps(self.words))
        for mid, w in words.items():
            if mid.split("-")[1] in ("11", "12"):  # half A
                for t in w["tokens"]:
                    if t[4] == "target":
                        t[5] = "S"
        out = Path(self._tmp.name) / "cf"
        self._scores(out, lambda lab: ((lab == 1) | (lab == 3)).astype(np.float32))
        res = E.compute_metrics("fake", out, "all", "x", boot=5, fs=self.fs, words=words)
        cf = res["conditions"]["builtin|clean|10"]["crossfit"]
        self.assertTrue(cf["A->B"]["uncalibrated"])
        self.assertIn("pooled_all", cf["B->A"])


class ReadOnlyHashTest(unittest.TestCase):
    def test_content_hash_does_not_write(self):
        from lfspk.harness.frozen import content_hash

        with tempfile.TemporaryDirectory(dir="/tmp") as d:
            root = Path(d)
            (root / "a.txt").write_text("x")
            (root / "HASH").write_text("frozen\n")
            h = content_hash(root)
            self.assertEqual((root / "HASH").read_text(), "frozen\n")
            self.assertFalse((root / "CONTENT.sha256").exists())
            self.assertEqual(content_hash(root, write=True), h)
            self.assertEqual((root / "HASH").read_text().strip(), h)


class AsrResumeTest(unittest.TestCase):
    def test_resume_refuses_other_identity_or_audio(self):
        from lfspk.harness.asr import check_resume

        with tempfile.TemporaryDirectory(dir="/tmp") as d:
            out = Path(d) / "asr.jsonl"
            ident = {"model": "m", "model_sha256": "a", "decoding": "x", "nemo": "1"}
            (Path(d) / "asr.meta.json").write_text(json.dumps(ident))
            out.write_text(json.dumps({"key": "k1", "audio_sha256": "s1", "text": "", "words": []}) + "\n")
            self.assertEqual(check_resume(out, ident, [{"key": "k1", "audio_sha256": "s1"}]), {"k1"})
            with self.assertRaises(SystemExit):
                check_resume(out, {**ident, "model_sha256": "b"}, [{"key": "k1", "audio_sha256": "s1"}])
            with self.assertRaises(SystemExit):
                check_resume(out, ident, [{"key": "k1", "audio_sha256": "s2"}])


class ScoreStorageTest(unittest.TestCase):
    def test_float32_round_trip_keeps_order_near_one(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as d:
            a = np.array([0.999, 0.9991, 0.99905, 1.0], dtype=np.float32)
            E.save_scores(Path(d) / "s.npz", {"k": a})
            b = E.load_scores(Path(d) / "s.npz")["k"]
            np.testing.assert_array_equal(a, b)
            self.assertEqual(b.dtype, np.float32)
            self.assertTrue(b[0] < b[2] < b[1] < b[3])


if __name__ == "__main__":
    unittest.main()
