"""Contract tests of the front-end evaluator, part 3 (DESIGN.md 14.2 fe-6 to
fe-13): evaluation records and the reference guard, the bootstrap contract, the
selection rules, select / report end to end on the synthetic set, provenance
and transfer refusals, the confirmatory evidence and the code closure hash."""

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.extract.nemo_hook import audio_sha256
from lfspk.harness import evaluate as E
from lfspk.harness import fe_registry as R
from lfspk.harness import fe_stage_a as A
from lfspk.harness import fe_stage_b as B
from lfspk.harness import frontend_eval as FE
from lfspk.harness import tmetrics as T
from lfspk.harness.frozen import FrozenSet
from lfspk.harness.util import load_audio
from tests import w0_frontend_fixtures as X

SPEC = "tests.w0_frontend_fixtures:make"
FSPEC = "tests.fake:oracle"  # a word filter's scorer identity (scores written by hand)
PERFECT = [["alpha", 0.1, 0.3], ["beta", 0.4, 0.6], ["gamma", 0.9, 1.1]]


def write_scores(d: Path, fs: FrozenSet, spec: str, args: dict, fn, half: str = "all") -> Path:
    """A complete `evaluate run` score directory (of one half or all), written by hand."""
    (d / "scores").mkdir(parents=True)
    ident = E.scorer_identity(spec, args, fs.set_id, fs.hash)
    (d / "scores" / "IDENTITY.json").write_text(json.dumps(ident, indent=1, sort_keys=True))
    keys = E.expected_score_keys(fs, [r for r in fs.manifest if half == "all" or r["half"] == half])
    rows = {r["id"]: r for r in fs.manifest}
    by: dict = {}
    for k in keys:
        mid = k.rsplit("|", 1)[1]
        by.setdefault(rows[mid]["speaker"], {})[k] = fn(fs.labels(rows[mid])["labels"])
    for s, v in by.items():
        E.save_scores(d / "scores" / f"{s}.npz", v)
    (d / "scores" / "COMPLETE.json").write_text(json.dumps({"identity": ident["hash"], "n_keys": len(keys), "keys_sha256": E._keys_hash(keys)}))
    # A fixed content identity: the hand-written scorer identity names no importable scorer.
    E.write_content_identity(d / "scores", {"code": [], "loaded": [], "warmup": "not run", "sha256": "c" * 64}, ident)
    return d


def oracle(lab):
    return np.isin(lab, (1, 3)).astype(np.float32)


class Pipeline:
    """The synthetic set run through stage A (registered, confirmatory-eligible),
    stage B for C1-C4 and B*, plus one word filter."""

    def __init__(self, t: Path, register: bool = True, extra_short: bool = False):
        self.t = t
        self.set_root = X.build_set(t / "set", extra_short=extra_short)
        self.fs = FrozenSet("fake-set", root=self.set_root)
        self.repo = X.init_repo(t / "repo")
        if register:
            X.register(self.repo, "ab" * 32)
        self.b_dir = t / "B"
        self.b_recs = X.write_b_cache(self.b_dir, self.set_root)
        self.words = X.write_words(self.b_dir, self.set_root, self.b_recs)
        self.masks, self.out, self.ledger = t / "masks", t / "out", t / "LEDGER.jsonl"
        self.fe = X.make()
        A.run_stage_a(self.fs, SPEC, {}, A.HEADLINE, workers=2, root=self.masks, exploratory=not register, repo=self.repo, ledger=self.ledger)
        st = self.stage_a()
        # F: S1 recovers "gamma" and drops the interferer's "delta"; S0 unchanged.
        script = {}
        for r in self.fs.manifest:
            a = load_audio(self.fs.root / r["files"]["mix"])
            script[audio_sha256(a)] = PERFECT
        for c in FE.CONFIGS:
            B.run_stage_b(self.fs, self.out, stage_a=st, fe=self.fe, config_name=c, model=X.FakeASR(script), asr_identity=dict(X.B_IDENTITY),
                          b_dir=self.b_dir, transcribe_fn=X.fake_transcribe_masked, repo=self.repo, ledger=self.ledger)
        B.run_stage_b(self.fs, self.out, stage_a=None, fe=None, config_name="C1", model=X.FakeASR(), asr_identity=dict(X.B_IDENTITY),
                      b_dir=self.b_dir, transcribe_fn=X.fake_transcribe_masked, repo=self.repo, ledger=self.ledger, exploratory=not register)
        self.filter_dir = write_scores(t / "W", self.fs, FSPEC, {}, oracle)

    def stage_a(self):
        return A.load_stage_a(self.fs, SPEC, {}, A.HEADLINE, root=self.masks, repo=self.repo, fe=self.fe)

    def inputs(self):
        return FE.inputs(self.fs, self.out, b_dir=self.b_dir, repo=self.repo, masks_root=self.masks, ledger=self.ledger, use_corpus=False)

    def select(self, n_boot=E.BOOT):
        return FE.select(self.inputs(), SPEC, {}, [[self.filter_dir]], n_boot=n_boot)


class RulesTest(unittest.TestCase):
    def _s(self, hi, lp, r, rb):
        return {"dwer_s0_hi": hi, "lplus": lp, "r": r, "r_boot": np.asarray(rb, float)}

    def test_select_config(self):
        boot = lambda m: m + np.linspace(-0.01, 0.01, 101)
        st = {"C1": self._s(0.0, 0.001, 0.30, boot(0.30)), "C2": self._s(0.0, 0.001, 0.31, boot(0.31)),
              "C3": self._s(0.0005, 0.002, 0.40, boot(0.40)), "C4": self._s(0.002, 0.0, 0.50, boot(0.50))}
        # C4 not eligible (S0 CI upper end 0.002 >= 0.001); reference C1 (lowest R); C3 is 0.10 worse;
        # C2 is non-inferior (difference CI upper end 0.01 + 0.01 < 0.02).
        got = FE.select_config(st)
        self.assertEqual((got["selected"], got["reference"], got["eligible"]), ("C2", "C1", ["C1", "C2", "C3"]))
        st["C2"] = self._s(0.0, 0.006, 0.31, boot(0.31))  # over the L+ budget
        self.assertEqual(FE.select_config(st)["selected"], "C1")  # the reference itself qualifies
        none = {c: self._s(0.01, 0.0, 0.1, boot(0.1)) for c in FE.CONFIGS}
        self.assertIsNone(FE.select_config(none)["selected"])
        tie = {c: self._s(0.0, 0.0, 0.2, boot(0.2)) for c in FE.CONFIGS}
        got = FE.select_config(tie)
        self.assertEqual((got["selected"], got["reference"]), ("C4", "C4"))  # ties go to the more conservative
        nan_r = {"C1": self._s(0.0, 0.0, None, [np.nan] * 5), "C2": self._s(0.0, 0.0, 0.2, boot(0.2))}
        self.assertEqual(FE.select_config(nan_r)["reference"], "C2")
        self.assertIsNone(FE.select_config({"C1": self._s(None, 0.0, 0.1, [0.1])})["selected"])

    def test_choose_pairing(self):
        self.assertEqual(FE.choose_pairing([("a", 0.3, 0.2), ("b", 0.4, 0.1), ("c", None, None)]), ("b", 0.4, 0.1))
        self.assertEqual(FE.choose_pairing([("a", 0.3, 0.1), ("b", 0.4, 0.1)])[0], "a")  # ties: first in the list
        self.assertIsNone(FE.choose_pairing([("a", None, None)]))

    def test_noise_groups(self):
        rows = [{"scenario": "N", "noise_family": f, "snr_db": float(s)} for f in ("music", "noise") for s in (20, 0)]
        g = FE.group_masks(rows, [])
        self.assertEqual(sorted(g), ["N-music", "N-music-0dB", "N-music-20dB", "N-noise", "N-noise-0dB", "N-noise-20dB", "pooled_N"])
        self.assertEqual(g["N-noise-0dB"].tolist(), [False, False, False, True])


class RecordsAndBootTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        t = Path(cls._tmp.name)
        cls.set_root = X.build_set(t / "set")
        cls.fs = FrozenSet("fake-set", root=cls.set_root)
        cls.b_recs = X.write_b_cache(t / "B", cls.set_root)
        cls.words = X.write_words(t / "B", cls.set_root, cls.b_recs)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_records_and_counts(self):
        recs = FE.build_records(self.fs, self.fs.manifest, self.b_recs, self.words, None)
        r = next(x for x in recs if x.id == "S1-11-00")
        self.assertEqual([w.text for w in r.target_ref], ["alpha", "beta", "gamma"])
        self.assertEqual(r.unreach, frozenset({2}))  # B never says "gamma"
        s = T.summarize(FE.counts_of(r, FE.hyp_of({"words": PERFECT})))
        self.assertEqual((s["G/all"], s["G_u/all"], s["L+/all"], s["R/all"]), (1 / 3, 1 / 3, 0.0, 0.0))
        self.assertEqual(T.summarize(FE.counts_of(r, r.b_hyp))["R/all"], 1.0)

    def test_reference_guard(self):
        import copy

        FE.build_records(self.fs, self.fs.manifest, self.b_recs, self.words, None)
        cases = {}
        w = copy.deepcopy(self.words)
        w["S0-11-00"]["tokens"][0][10] += 0.001  # a timestamp in words.jsonl
        cases["timestamp"] = (self.fs.manifest, self.b_recs, w)
        w = copy.deepcopy(self.words)
        w["S1-12-00"]["dropout"] = not w["S1-12-00"]["dropout"]
        cases["dropout flag"] = (self.fs.manifest, self.b_recs, w)
        rows = copy.deepcopy(self.fs.manifest)
        rows[0]["meta"]["target"]["text"] = "alpha beta green"  # the reference changes while B's words do not
        cases["reference word"] = (rows, self.b_recs, self.words)
        b = copy.deepcopy(self.b_recs)
        b["tdry:S0-11-00"]["words"][2][1] = 0.95  # a reference time (pseudo-reference branch)
        cases["reference time"] = (self.fs.manifest, b, self.words)
        for name, (rows_, b_, w_) in cases.items():
            with self.subTest(name):
                with self.assertRaises(SystemExit):
                    FE.build_records(self.fs, rows_, b_, w_, None)

    def test_alignment_file_pinned(self):
        class C:
            def index_hashes(self):
                return {"alignment": "other"}

        rows = [dict(r, meta={**r["meta"], "index_hashes": {"alignment": "rendered"}}) for r in self.fs.manifest]
        with self.assertRaises(SystemExit):
            FE.build_records(self.fs, rows, self.b_recs, self.words, C())

    def test_bootstrap_contract(self):
        rows = [r for r in self.fs.manifest if r["half"] == "A"]
        bt = FE.make_boot(self.fs, "A", rows, 50)
        self.assertEqual(bt.universe, ["11", "12"])  # speaker 11's S1 involves 12 as an interferer
        rng = np.random.default_rng(0)
        want = [np.bincount(rng.integers(0, 2, 2), minlength=2).astype(float) for _ in range(50)]
        from lfspk.harness import metrics as M

        inv = M.involvement_matrix([E.involved_speakers(r) for r in rows], bt.universe)
        np.testing.assert_array_equal(bt.W, np.stack([M.weights_from_counts(inv, c) for c in want]))
        with self.assertRaises(SystemExit):
            FE.make_boot(self.fs, "A", rows[::-1], 50)  # not manifest order
        with self.assertRaises(SystemExit):
            FE.make_boot(self.fs, "A", self.fs.manifest, 50)  # rows of another half


class EndToEndTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        cls.p = Pipeline(Path(cls._tmp.name))
        cls.sel = cls.p.select()
        cls.sel_path = Path(cls._tmp.name) / "selection.json"
        cls.sel_path.write_text(json.dumps(cls.sel))

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_selection(self):
        sel = FE.load_selection(self.sel_path)
        tr, res = sel["transfer"], sel["results"]
        # F changes nothing on S0 and is perfect on S1: every configuration is eligible; ties -> C4.
        self.assertEqual(res["choice"]["selected"], "C4")
        self.assertEqual(tr["config"], {"name": "C4", "theta_b": 0.5})
        self.assertEqual(res["configs"]["C4"]["dwer_s0"], 0.0)
        self.assertEqual(res["configs"]["C4"]["r"], 0.0)
        eq = tr["pairings"]["equal_budget"]
        self.assertEqual((eq["scorer"], eq["args"]), (FSPEC, {}))
        f = res["filters"][0]
        self.assertEqual(f["equal_budget"]["R_S1-S4"], 0.0)  # the oracle filter removes "delta" within the budget
        self.assertEqual(f["equal_budget"]["L+"], 0.0)
        self.assertLessEqual(f["matched_s0"]["dWER_S0"], 0.0)
        self.assertTrue(tr["confirmatory"], sel["provenance"]["confirmatory_evidence"]["reasons"])
        self.assertEqual(sel["provenance"]["confirmatory_evidence"]["ledger_sha256"], R.ledger_sha256(self.p.ledger))
        self.assertEqual(tr["code_closure_sha256"], FE.closure_sha256())
        self.assertIsNotNone(tr["stack"])
        bad = dict(sel, git="x")
        p = Path(self._tmp.name) / "bad.json"
        p.write_text(json.dumps(bad))
        with self.assertRaises(SystemExit):
            FE.load_selection(p)

    def test_report_half_b(self):
        res = FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir]], bstar=True)
        self.assertEqual(sorted(res["tables"]), sorted(["B", "F(C4)", "F(C1) [exploratory]", "F(C2) [exploratory]", "F(C3) [exploratory]",
                                                         "B* [diagnostic]", "W equal_budget", "W matched_s0", "F+W [exploratory]"]))
        f = res["tables"]["F(C4)"]["pooled_S1-S4"]
        self.assertEqual((f["G/all"]["point"], f["G_u/all"]["point"], f["R/all"]["point"]), (1 / 3, 1 / 3, 0.0))
        self.assertEqual(res["tables"]["F(C4)"]["S0"]["dWER/all"]["point"], 0.0)
        fam = res["confirmatory_family"]
        self.assertTrue(fam["confirmatory"], fam["evidence"]["reasons"])
        self.assertEqual(fam["level"], 0.9875)
        self.assertIn("98.75 % CIs", FE.report_md(res))
        self.assertEqual(fam["claims"]["H5"]["verdict"], "supported")  # dWER_S0 = 0 in every resample
        self.assertEqual(fam["claims"]["H1a"]["verdict"], "not resolved")  # R_F - R_W = 0
        self.assertIn("F(C4) - W equal_budget", res["paired"])
        self.assertEqual(res["bypass_rate"]["pooled_all"], 0.0)
        self.assertEqual(res["masked_identical_to_B"], 0.5)  # S0 identical, S1 differs
        self.assertIn("results", FE.report_md(res) + "results")

    def test_report_refusals(self):
        ip = self.p.inputs()
        with self.assertRaises(SystemExit):  # the selection's own set is reported on half B only
            FE.report(ip, self.sel, SPEC, {}, "A", [[self.p.filter_dir]], n_boot=20)
        with self.assertRaises(SystemExit):  # another front-end configuration
            FE.report(ip, self.sel, SPEC, {"gain": "2.0"}, "B", [[self.p.filter_dir]], n_boot=20)
        # A half-A B record rebuilt under unchanged metadata (C1-C4 have no bypass pins to catch it).
        recs = [json.loads(l) for l in (self.p.b_dir / "asr.jsonl").read_text().splitlines()]
        saved = (self.p.b_dir / "asr.jsonl").read_text()
        try:
            for r in recs:
                if r["key"] == "tdry:S0-11-00":
                    r["text"] = "rebuilt"
            (self.p.b_dir / "asr.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs))
            with self.assertRaises(SystemExit):
                FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir]], n_boot=20)
        finally:
            (self.p.b_dir / "asr.jsonl").write_text(saved)
        # A score file the selection was fitted on changed.
        f = self.p.filter_dir / "scores" / "11.npz"
        saved = f.read_bytes()
        try:
            E.save_scores(f, {k: v * 0.5 for k, v in E.load_scores(f).items()})
            with self.assertRaises(SystemExit):
                FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir]], n_boot=20)
        finally:
            f.write_bytes(saved)
        # The code closure changed.
        bad = json.loads(json.dumps(self.sel))
        bad["transfer"]["code_closure_sha256"] = "0" * 64
        with self.assertRaises(SystemExit):
            FE.report(ip, bad, SPEC, {}, "B", [[self.p.filter_dir]], n_boot=20)

    def test_report_binds_the_pinned_score_files(self):
        # A copy of the word filter's directory with other scores, same scorer identity (code3-r1 #1).
        swap = Path(self._tmp.name) / "W-swap"
        if not swap.exists():
            write_scores(swap, self.p.fs, FSPEC, {}, lambda lab: np.ones(lab.size, np.float32))
        with self.assertRaises(SystemExit):
            FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[swap]], n_boot=20)
        with self.assertRaises(SystemExit):  # conflicting duplicates of one scorer identity
            FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir], [swap]], n_boot=20)
        with self.assertRaises(SystemExit):
            FE.select(self.p.inputs(), SPEC, {}, [[self.p.filter_dir], [swap]], n_boot=20)

    def test_overlapping_directories_within_a_group_refused(self):
        # An "all" directory and a half-A directory with other scores, same identity: whichever order,
        # the overlap is refused, never resolved by order (code3-r2 #1).
        over = Path(self._tmp.name) / "W-overlap-A"
        if not over.exists():
            write_scores(over, self.p.fs, FSPEC, {}, lambda lab: np.ones(lab.size, np.float32), half="A")
        for group in ([self.p.filter_dir, over], [over, self.p.filter_dir]):
            with self.subTest(order=[g.name for g in group]):
                with self.assertRaisesRegex(SystemExit, "more than one file"):
                    FE.load_filter(self.p.fs, group)
                with self.assertRaises(SystemExit):
                    FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [group], n_boot=20)

    def test_every_configuration_is_reverified(self):
        # A non-selected configuration's half-A entry rebuilt (no bypass pins can see it): refused (code3-r1 #3).
        d = B.stage_b_dir(self.p.out, "base", A.slug(A.HEADLINE), "C1")
        saved = (d / "asr.jsonl").read_text()
        try:
            lines = [json.loads(l) for l in saved.splitlines()]
            for e in lines:
                if e["key"] == "mix:S1-11-00":
                    e["words"] = e["words"][:1]
                    e["text"] = e["words"][0][0]
            (d / "asr.jsonl").write_text("".join(json.dumps(e) + "\n" for e in lines))
            with self.assertRaises(SystemExit):
                FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir]], n_boot=20)
        finally:
            (d / "asr.jsonl").write_text(saved)

    def test_bootstrap_size_and_exploratory_level(self):
        res = FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir]], n_boot=20)  # not B = 2000 (code3-r1 #2, #5)
        fam = res["confirmatory_family"]
        self.assertFalse(fam["confirmatory"])
        self.assertEqual(fam["level"], 0.95)
        self.assertTrue(any("bootstrap" in x for x in fam["evidence"]["reasons"]))
        self.assertTrue(all(v.get("verdict") is None for v in fam["claims"].values()))
        small = self.p.select(n_boot=20)
        self.assertFalse(small["transfer"]["confirmatory"])

    def test_select_reads_half_a_only(self):
        # Changing a half-B word record (which would fail the guard) does not affect selection.
        p = self.p.b_dir / "words.jsonl"
        saved = p.read_text()
        try:
            w = [json.loads(l) for l in saved.splitlines()]
            for r in w:
                if r["id"] == "S1-12-00":
                    r["dry_target_wer"] = 0.5
            p.write_text("".join(json.dumps(r) + "\n" for r in w))
            again = self.p.select()
            self.assertEqual(again["results"], self.sel["results"])
            with self.assertRaises(SystemExit):  # while the half-B report refuses it
                FE.report(self.p.inputs(), self.sel, SPEC, {}, "B", [[self.p.filter_dir]], n_boot=20)
        finally:
            p.write_text(saved)


class ShortEnrollmentTest(unittest.TestCase):
    def test_streams_short_of_k_are_masked_not_fatal(self):
        # Speaker 13 (half B) never reaches k = 10: absent from stage A/B, masked placeholders (code3-r1 #4).
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            p = Pipeline(Path(t), extra_short=True)
            self.assertNotIn("S0-13-00", p.stage_a().hashes)
            sel = p.select(n_boot=50)
            res = FE.report(p.inputs(), sel, SPEC, {}, "B", [[p.filter_dir]], n_boot=50)
            self.assertEqual(res["n_without_condition"], 2)
            self.assertEqual(res["n_mixtures_headline"], 2)  # speaker 12's two mixtures only
            rows = [r for r in p.fs.manifest if r["half"] == "B"]
            sb = B.load_stage_b(p.fs, p.out, stage_a=p.stage_a(), fe=p.fe, config_name="C4", b_dir=p.b_dir, repo=p.repo)
            self.assertNotEqual(FE.digest_entries(rows, sb.entries), FE.digest_entries(rows[:2], sb.entries))


class ConfirmatoryEvidenceTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.t = Path(self._tmp.name)
        self.repo = X.init_repo(self.t / "repo")
        self.led = self.t / "L.jsonl"
        self.fe_id = {"run": "R1", "seed": 0, "checkpoint_sha256": "ab" * 32}

    def tearDown(self):
        self._tmp.cleanup()

    def test_rules(self):
        ev = FE.confirmatory_evidence(self.fe_id, [], self.repo, self.led)
        self.assertFalse(ev["confirmatory"])  # no registration
        pre = R.run_event(self.repo)
        R.append_ledger(self.led, {"event": "start", "checkpoint_sha256": "ab" * 32, "registration": None, "stage": "A", **pre})
        X.register(self.repo, "ab" * 32)
        reg = R.current_registration(self.repo)
        art = {"registration": reg, "confirmatory_eligible": True, "exploratory": False}
        ev = FE.confirmatory_evidence(self.fe_id, [("stage A", art)], self.repo, self.led)
        self.assertFalse(ev["confirmatory"])  # a dev run of the checkpoint predates the registration
        self.led.unlink()
        post = R.run_event(self.repo)
        R.append_ledger(self.led, {"event": "start", "checkpoint_sha256": "ab" * 32, "registration": reg, "stage": "A", **post})
        self.assertTrue(FE.confirmatory_evidence(self.fe_id, [("stage A", art)], self.repo, self.led)["confirmatory"])
        # a start without a complete is still a run; one lacking the registration blocks
        R.append_ledger(self.led, {"event": "start", "checkpoint_sha256": "ab" * 32, "registration": None, "stage": "B", **post})
        self.assertFalse(FE.confirmatory_evidence(self.fe_id, [("stage A", art)], self.repo, self.led)["confirmatory"])
        self.led.unlink()
        self.assertFalse(FE.confirmatory_evidence({**self.fe_id, "seed": 1}, [("stage A", art)], self.repo, self.led)["confirmatory"])
        self.assertFalse(FE.confirmatory_evidence(self.fe_id, [("stage A", {**art, "exploratory": True})], self.repo, self.led)["confirmatory"])

    def test_unregistered_pipeline_is_exploratory(self):
        p = Pipeline(self.t / "p", register=False)
        sel = p.select(n_boot=50)
        self.assertFalse(sel["transfer"]["confirmatory"])
        res = FE.report(p.inputs(), sel, SPEC, {}, "B", [[p.filter_dir]], n_boot=50)
        fam = res["confirmatory_family"]
        self.assertFalse(fam["confirmatory"])
        self.assertTrue(all(v.get("verdict") is None for v in fam["claims"].values()))


class TransferTest(unittest.TestCase):
    def test_apply_to_another_set(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            t = Path(t)
            p = Pipeline(t / "src")
            sel = p.select(n_boot=50)
            # The destination: the same fixture under another set id (its own caches, validated independently).
            q = Pipeline(t / "dst")
            fs2 = FrozenSet("other-set", root=q.set_root)
            A.run_stage_a(fs2, SPEC, {}, A.HEADLINE, workers=2, root=q.masks, exploratory=True, repo=q.repo, ledger=q.ledger)
            st2 = A.load_stage_a(fs2, SPEC, {}, A.HEADLINE, root=q.masks, repo=q.repo, fe=q.fe)
            out2 = t / "out2"
            B.run_stage_b(fs2, out2, stage_a=st2, fe=q.fe, config_name="C4", model=X.FakeASR(), asr_identity=dict(X.B_IDENTITY),
                          b_dir=q.b_dir, transcribe_fn=X.fake_transcribe_masked, repo=q.repo, ledger=q.ledger)
            ip = FE.inputs(fs2, out2, b_dir=q.b_dir, repo=q.repo, masks_root=q.masks, ledger=q.ledger, use_corpus=False)
            res = FE.report(ip, sel, SPEC, {}, "all", [], n_boot=50)
            self.assertFalse(res["source_set"])
            self.assertFalse(res["confirmatory_family"]["confirmatory"])
            self.assertIn("F(C4)", res["tables"])
            with self.assertRaises(SystemExit):  # the destination must use the transfer's front end
                FE.report(ip, sel, SPEC, {"gain": "2.0"}, "all", [], n_boot=50)


class ClosureTest(unittest.TestCase):
    def test_closure_covers_accounting_and_api(self):
        files = dict(FE.closure())
        for f in ("lfspk/harness/tmetrics.py", "lfspk/harness/align.py", "lfspk/harness/refs.py", "lfspk/harness/metrics.py",
                  "lfspk/harness/evaluate.py", "lfspk/harness/frontend_eval.py", "lfspk/api.py", "lfspk/paths.py"):
            self.assertIn(f, files)

    def test_edit_outside_harness_changes_hash_and_is_refused(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            repo = Path(t) / "repo"
            shutil.copytree(R.REPO / "lfspk", repo / "lfspk", ignore=shutil.ignore_patterns("__pycache__"))
            h1 = FE.closure_sha256(repo)
            FE.check_code({"code_closure_sha256": h1}, repo)
            api = repo / "lfspk" / "api.py"
            api.write_text(api.read_text() + "\n# an edit outside lfspk/harness\n")
            self.assertNotEqual(FE.closure_sha256(repo), h1)
            with self.assertRaises(SystemExit):
                FE.check_code({"code_closure_sha256": h1}, repo)


class LatencyTest(unittest.TestCase):
    def test_refused_without_cpu_env(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            fs = FrozenSet("fake-set", root=X.build_set(Path(t) / "set"))
            with self.assertRaises(SystemExit):
                FE.latency(fs, SPEC, {})

    def test_measures_in_a_cpu_env_worker(self):
        # The CLI path: a fresh interpreter started with CPU_ENV (code3-r1 #6); every configuration (#7).
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            root = X.build_set(Path(t) / "set")
            res = FE.latency_subprocess("fake-set", SPEC, {}, selected="C3", set_root=root)
        self.assertEqual(res["threads"], 1)
        self.assertEqual(res["n_mixtures"], 4)
        for c in FE.CONFIGS:
            self.assertGreater(res["s_per_audio_s"][f"apply_{c}"]["median"], 0)
            self.assertGreater(res["s_per_audio_s"][f"analyse_plus_apply_{c}"]["median"], 0)
        self.assertEqual(res["selected"]["config"], "C3")
        self.assertEqual(res["selected"]["analyse_plus_apply"], res["s_per_audio_s"]["analyse_plus_apply_C3"])
        self.assertIsNone(res["parakeet_preprocessor_plus_encoder_s_per_audio_s"])


class SmokeTest(unittest.TestCase):
    def test_smoke_chain_and_refusals(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            t = Path(t)
            src = FrozenSet("fake-set", root=X.build_set(t / "src"))
            b_dir = t / "B"
            b_recs = X.write_b_cache(b_dir, src.root)
            X.write_words(b_dir, src.root, b_recs)
            repo, led, sdir = X.init_repo(t / "repo"), t / "L.jsonl", t / "smoke"
            fs = FE.smoke_prepare(src, sdir, FE.IDENTITY_SPEC, {}, workers=2, repo=repo, ledger=led)
            self.assertTrue(FE.is_smoke(fs))
            self.assertEqual(fs.set_id, "fake-set-smoke")
            self.assertEqual(len(fs.manifest), 4)  # target-0 coherent groups of the (two) fixture speakers
            self.assertNotEqual(fs.hash, src.hash)
            listing = (fs.root / "CONTENT.sha256").read_text()
            self.assertTrue(all(line in (src.root / "CONTENT.sha256").read_text() for line in listing.splitlines()))
            self.assertTrue((fs.root / fs.manifest[0]["files"]["mix"]).is_symlink())
            with self.assertRaises(SystemExit):  # never into an existing directory
                FE.build_smoke_set(src, sdir / "set")
            FE.smoke_asr(fs, sdir, FE.IDENTITY_SPEC, {}, X.FakeASR(), dict(X.B_IDENTITY), b_dir, transcribe_fn=X.fake_transcribe_masked,
                         repo=repo, ledger=led)
            res = FE.smoke_metrics(fs, sdir, FE.IDENTITY_SPEC, {}, b_dir, use_corpus=False, repo=repo, n_boot=20)
            self.assertTrue(res["exploratory"])
            self.assertEqual(res["n_mixtures"], 4)
            self.assertEqual(res["bypass"]["C1"], 0)
            self.assertGreater(res["bypass"]["C3"], 0)  # u = 0.1 for some mixtures
            self.assertLess(res["bypass"]["C3"], 4)
            self.assertIn("F(C3)", res["tables"])
            # The fake B* transcriber returns other words than B: every mixture is listed with its WER delta.
            self.assertEqual(len(res["bstar_differs"]), 4)
            self.assertTrue(all(d["dWER"] is not None for d in res["bstar_differs"]))
            self.assertIsNotNone(res["bstar_dWER_pooled"])
            st = A.load_stage_a(fs, FE.IDENTITY_SPEC, {}, A.HEADLINE, root=sdir / "masks", repo=repo)
            self.assertTrue(st.key["exploratory"])
            self.assertFalse(st.key["confirmatory_eligible"])
            self.assertTrue(all(e["exploratory"] for e in R.read_ledger(led) if e.get("event") == "start"))
            ip = FE.inputs(fs, sdir, b_dir=b_dir, repo=repo, masks_root=sdir / "masks", ledger=led, use_corpus=False)
            with self.assertRaises(SystemExit):  # select can never consume a smoke set
                FE.select(ip, FE.IDENTITY_SPEC, {}, [], n_boot=10)
            with self.assertRaises(SystemExit):
                FE.report(ip, {"transfer": {}, "provenance": {}}, FE.IDENTITY_SPEC, {}, "all", [], n_boot=10)

    def test_smoke_masks_rows_short_of_k(self):
        # A speaker whose built-in stream is short of k = 10: no F entry, masked out (code3-r2 #2).
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            t = Path(t)
            src = FrozenSet("fake-set", root=X.build_set(t / "src", extra_short=True))
            b_dir = t / "B"
            X.write_words(b_dir, src.root, X.write_b_cache(b_dir, src.root))
            repo, led, sdir = X.init_repo(t / "repo"), t / "L.jsonl", t / "smoke"
            fs = FE.smoke_prepare(src, sdir, FE.IDENTITY_SPEC, {}, workers=2, repo=repo, ledger=led)
            self.assertEqual(len(fs.manifest), 6)
            FE.smoke_asr(fs, sdir, FE.IDENTITY_SPEC, {}, X.FakeASR(), dict(X.B_IDENTITY), b_dir, transcribe_fn=X.fake_transcribe_masked,
                         repo=repo, ledger=led)
            res = FE.smoke_metrics(fs, sdir, FE.IDENTITY_SPEC, {}, b_dir, use_corpus=False, repo=repo, n_boot=20)
            self.assertEqual(res["n_without_condition"], 2)
            self.assertEqual(res["tables"]["F(C1)"]["pooled_all"]["n_mixtures"], 4)  # placeholders never enter a sum
            self.assertEqual(res["tables"]["F(C1)"]["pooled_all"]["N/all"], 4 * 3)
            self.assertEqual(len(res["bstar_differs"]), 6)  # B* covers every mixture

    def test_smoke_refuses_the_confirmatory_checkpoint(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            t = Path(t)
            src = FrozenSet("fake-set", root=X.build_set(t / "src"))
            repo, led = X.init_repo(t / "repo"), t / "L.jsonl"
            for kw in ({}, {"run": "R1", "seed": "0"}):  # the fixture's default identity is R1 seed 0
                with self.subTest(**kw):
                    with self.assertRaisesRegex(SystemExit, "R1 seed 0"):
                        FE.smoke_prepare(src, t / "s0", SPEC, kw, workers=1, repo=repo, ledger=led)
            X.register(repo, "cd" * 32)  # a relabelled copy of the registered checkpoint
            with self.assertRaisesRegex(SystemExit, "registered"):
                FE.smoke_prepare(src, t / "s1", SPEC, {"run": "R9", "sha": "cd" * 32}, workers=1, repo=repo, ledger=led)
            for fn in (lambda: FE.smoke_asr(FE.smoke_set(t / "s2", "fake-set"), t / "s2", SPEC, {}, X.FakeASR(), {}, t, repo=repo, ledger=led),
                       lambda: FE.smoke_metrics(FE.smoke_set(t / "s2", "fake-set"), t / "s2", SPEC, {}, t, repo=repo)):
                FE.build_smoke_set(src, t / "s2" / "set") if not (t / "s2" / "set").exists() else None
                with self.assertRaisesRegex(SystemExit, "R1 seed 0"):
                    fn()
            self.assertFalse((t / "s0").exists() or (t / "s1").exists())  # refused before anything was written
            self.assertEqual(R.read_ledger(led), [])
            FE.smoke_prepare(src, t / "ok", SPEC, {"seed": "1"}, workers=1, repo=repo, ledger=led)  # R1 seed 1 is allowed

    def test_identity_front_end(self):
        fe = FE.identity_frontend()
        a = np.random.default_rng(0).standard_normal(16000).astype(np.float32)
        mo = fe.analyse(fe.enroll([a]), a)
        self.assertEqual(float(np.abs(mo.log_mask).max()), 0.0)
        self.assertIn(mo.u[0], (np.float32(0.1), np.float32(0.9)))
        self.assertEqual(fe.config("C3").theta_b, 0.5)
        self.assertIsNone(fe.config("C1").theta_b)
        self.assertEqual(fe.identity()["analyse_threads"], 1)


if __name__ == "__main__":
    unittest.main()
