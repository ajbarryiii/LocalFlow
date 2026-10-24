"""W6 scoring, the joint bootstrap, gates and selection (DESIGN 3, 6), on synthetic data."""

from __future__ import annotations

import unittest

import numpy as np
import torch

from lfspk.extract.frontend import analytic_mel_power, ideal_log_mask
from lfspk.personal import boot as B
from lfspk.personal import gates as G
from lfspk.personal import score as SC
from lfspk.personal import subjects as S


class TestMeasurement(unittest.TestCase):
    def test_ideal_t2_present_absent(self):
        rng = np.random.default_rng(0)
        n = 16000
        tgt = (0.05 * rng.standard_normal(n)).astype(np.float32)
        noise = (0.01 * rng.standard_normal(n)).astype(np.float32)
        itf = (0.03 * rng.standard_normal(n)).astype(np.float32)
        mel = analytic_mel_power()
        d = {"audio": tgt + noise + itf, "target_image": tgt, "noise": noise, "info": {"absent": False}}
        ideal, m = SC.ideal_of(d, mel)
        want = ideal_log_mask(mel(torch.from_numpy(tgt + noise)[None]), mel(torch.from_numpy(d["audio"])[None]))[0].numpy()
        np.testing.assert_array_equal(ideal, want[:, :m])
        d["info"]["absent"] = True
        ideal2, _ = SC.ideal_of(d, mel)
        want2 = ideal_log_mask(mel(torch.from_numpy(noise)[None]), mel(torch.from_numpy(d["audio"])[None]))[0].numpy()
        np.testing.assert_array_equal(ideal2, want2[:, :m])

    def test_metrics_arithmetic(self):
        from lfspk.extract.harness_frontend import run_mask
        from lfspk.extract.model import MaskNet, config_for

        torch.manual_seed(0)
        net = MaskNet(config_for("M", "film_cos")).eval()
        rng = np.random.default_rng(1)
        audio = (0.05 * rng.standard_normal(16000)).astype(np.float32)
        prof = np.ones(192, np.float32) / np.sqrt(192)
        ideal = -np.abs(rng.standard_normal((128, 100))).astype(np.float32)
        idu, u, o = SC.metrics(net, {"audio": audio}, prof, ideal, 100)
        lm, _ = run_mask(net, audio, prof)
        x = ideal - lm[:, :100]
        self.assertEqual(idu, float(np.mean(ideal.astype(np.float64) ** 2)))
        self.assertEqual(u, float(np.mean(np.clip(-x, 0, None).astype(np.float64) ** 2)))
        self.assertEqual(o, float(np.mean(np.clip(x, 0, None).astype(np.float64) ** 2)))

    def test_involvement(self):
        a = S.PILOT["F"][0]
        inv = SC.involvement(a, {"interferers": ["166", "5489"], "absent": False})
        self.assertEqual(inv, [a, S.control_donor(a), "166", "5489"])
        inv = SC.involvement(a, {"interferers": [], "absent": True, "talker": "636"})
        self.assertEqual(inv, [a, S.control_donor(a), "636"])

    def test_cells(self):
        a = S.PILOT["M"][3]
        c = {n: (m, p) for n, m, p in SC.cells("A-VB", a)}
        b = S.control_donor(a)
        self.assertEqual(c["P1000|personal"], (("tuned", "A-VB", "P", a, 1000), ("p0", a)))
        self.assertEqual(c["P1000|control"], (("tuned", "A-VB", "P", b, 1000), ("p0", a)))
        self.assertEqual(c["P1000|swapA"], (("tuned", "A-VB", "P", a, 1000), ("p0", b)))
        self.assertEqual(c["P1000|swapB"], (("tuned", "A-VB", "P", b, 1000), ("p0", b)))
        self.assertEqual(c["P1000|drift"], (("tuned", "A-VB", "P", a, 1000), ("p_end", a)))
        self.assertEqual(c["twin"], (("base", "VBu-s0"), None))


class TestBootstrap(unittest.TestCase):
    def test_donor_dependence_and_shared_weights(self):
        universe = ["a", "b", "c", "i1", "i2"]
        involved = [["a", "b", "i1"], ["b", "c", "i2"], ["c", "a"]]
        inv = B.involvement_matrix(involved, universe)
        from lfspk.harness.tmetrics import boot_draws

        draws = boot_draws(len(universe), 300, 7)
        W = B.weights(inv, len(universe), 300, 7)
        for r in range(300):
            for k, spk in enumerate(involved):
                want = np.prod([draws[r, universe.index(s)] for s in spk])
                self.assertEqual(W[r, k], want)
                if draws[r, universe.index(spk[1])] == 0:  # the control donor not drawn -> weight 0
                    self.assertEqual(W[r, k], 0)
        idu = np.array([1.0, 2.0, 3.0])
        res = B.contrast(W, np.ones(3, bool), idu, np.array([0.5, 1.0, 1.5]), np.array([0.8, 1.6, 2.4]))
        self.assertAlmostEqual(res["point"], 0.5 - 0.2)
        self.assertGreater(res["ci"]["lo"], 0.29)  # same proportional gain in every render -> a degenerate CI
        with self.assertRaises(ValueError):
            B.involvement_matrix([["a", "a"]], universe)

    def test_undefined_resamples(self):
        v = np.r_[np.full(1975, 0.1), np.full(25, np.nan)]
        r = B.ci(v)
        self.assertEqual(r["undefined"], 25)
        self.assertFalse(r["resolved"])
        self.assertTrue(B.ci(np.r_[np.full(1990, 0.1), np.full(10, np.nan)])["resolved"])
        self.assertTrue(np.isnan(B.frac(np.zeros(3), np.ones(3), np.ones(3))))

    def test_coverage_generator_deterministic(self):
        a = B.coverage_dataset(np.random.default_rng(1))
        b = B.coverage_dataset(np.random.default_rng(1))
        np.testing.assert_array_equal(a["up"], b["up"])
        self.assertEqual(len(a["id"]), 22 * 16)
        self.assertEqual(len(set(np.round(a["id"], 6))), len(a["id"]))  # unequal denominators
        r = B.coverage_smoke(reps=3, seed=1, n_boot=200)  # a unit run with a different seed; the frozen run is separate
        self.assertEqual(r["reps"], 3)


def synthetic_scores(p_frac=0.35, c_frac=0.25, base_frac=0.30, s3_frac=0.6, over=0.0002, bad_user=None, bad_over=0.01):
    """Cells for both arms: per subject, 4 present renders per family and 1 absent per family."""
    rng = np.random.default_rng(0)
    subj, fam, absent, inv = [], [], [], []
    for s in S.pilot_order():
        for f in G.FAMILIES:
            for k in range(5):
                subj.append(s)
                fam.append(f)
                absent.append(k == 4)
                inv.append([s, S.control_donor(s), str(90000 + len(inv) % 26)])
    n = len(subj)
    fam_a = np.asarray(fam)
    idu = rng.uniform(0.5, 1.5, n)

    def cell(fr, ov):
        f = np.full(n, fr)
        f[fam_a == "S3"] = max(fr, s3_frac) if fr != base_frac else s3_frac + 0.01
        u = idu * (1 - f)
        o = np.full(n, ov)
        return np.stack([idu, u, o], axis=1)

    cells = {}
    for arm in S.ARMS:
        cells[f"{arm}|base"] = cell(base_frac, over)
        cells[f"{arm}|twin"] = cell(base_frac - 0.01, over)
        for st in SC.STEPS:
            cells[f"{arm}|P{st}|personal"] = cell(p_frac, over)
            cells[f"{arm}|P{st}|control"] = cell(c_frac, over)
        for r in ("F1000|personal", "F1000|control", "P1000|swapA", "P1000|swapB", "P1000|drift"):
            cells[f"{arm}|{r}"] = cell(p_frac if "personal" in r or "drift" in r else c_frac, over)
        if bad_user:
            x = cells[f"{arm}|P1000|personal"]
            m = (np.asarray(subj) == bad_user) & (fam_a == "S0")
            x[m, 2] = bad_over
    return {"cells": cells, "subject": np.asarray(subj), "family": fam_a, "absent": np.asarray(absent), "involved": inv}


def ctx_for(sc):
    universe = sorted(set(S.pilot_order()) | {str(90000 + j) for j in range(26)}, key=int)
    W = B.weights(B.involvement_matrix(sc["involved"], universe), len(universe), 300, 0)
    return G.Ctx(sc, W)


def passing_measures(arm):
    from lfspk.personal.macbench import MAC_SUBJECTS

    return [{"arm": arm, "config": "P", "threads": 2, "qos": "background", "subject": s, "rep": r, "exit_code": 0,
             "wall_s": 700.0, "peak_footprint_bytes": 600_000_000, "max_rss_bytes": 700_000_000} for s in MAC_SUBJECTS
            for r in (1, 2)]


def d5_identical(arm, delta=0.0):
    from lfspk.personal.macbench import MAC_SUBJECTS

    out = {}
    fam = [f for f in G.FAMILIES for _ in range(3)]
    m = np.stack([np.ones(len(fam)), np.full(len(fam), 0.6), np.full(len(fam), 1e-4)], axis=1)
    for s in MAC_SUBJECTS:
        for v in ("nixos", "mac-r1", "mac-r2"):
            x = m.copy()
            if v == "mac-r2":
                x[:, 1] -= delta
            out[f"{arm}|{s}|{v}"] = {"metrics": x.tolist(), "family": fam, "absent": [False] * len(fam)}
    return {"results": out, "errors": {}}


def merge_d5(*ds):
    return {"results": {k: v for d in ds for k, v in d["results"].items()},
            "errors": {k: v for d in ds for k, v in d["errors"].items()}}


class TestGates(unittest.TestCase):
    def test_pass_and_select(self):
        ctx = ctx_for(synthetic_scores())
        reps = {a: G.arm_report(ctx, a, passing_measures(a), merge_d5(d5_identical("A-V0"), d5_identical("A-VB")))
                for a in S.ARMS}
        for a in S.ARMS:
            self.assertTrue(reps[a]["pass"], reps[a]["gates"])
            self.assertTrue(reps[a]["G4a"]["ci"]["resolved"])
            self.assertIn("identity mechanism unresolved", reps[a]["X1"]["wording"])
        self.assertEqual(G.select(reps)["selected"], "A-V0")  # equal means -> A-V0

    def test_gain_too_small(self):
        ctx = ctx_for(synthetic_scores(c_frac=0.32))
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), d5_identical("A-VB"))
        self.assertFalse(r["gates"]["G4a"])
        self.assertFalse(r["pass"])

    def test_one_user_fails_arm(self):
        bad = S.PILOT["M"][5]
        ctx = ctx_for(synthetic_scores(bad_user=bad, bad_over=0.0069))
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), d5_identical("A-VB"))
        self.assertFalse(r["gates"]["G3b"])
        self.assertEqual(r["G3"]["G3b_failing"], [bad])
        self.assertFalse(r["pass"])

    def test_g5_and_d5(self):
        ctx = ctx_for(synthetic_scores())
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB")[:3], d5_identical("A-VB"))
        self.assertFalse(r["gates"]["G5"])  # a missing repetition
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), d5_identical("A-VB", delta=0.05))
        self.assertFalse(r["gates"]["G5"])  # Mac frac differs by 0.05 > 0.03
        slow = passing_measures("A-VB")
        slow[0]["wall_s"] = 1300.0
        self.assertFalse(G.arm_report(ctx, "A-VB", slow, d5_identical("A-VB"))["gates"]["G5"])
        self.assertFalse(G.arm_report(ctx, "A-VB", passing_measures("A-VB"), None)["gates"]["G5"])

    def test_control_degraded_label(self):
        ctx = ctx_for(synthetic_scores(c_frac=0.20, base_frac=0.30))
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), d5_identical("A-VB"))
        self.assertTrue(r["X2"]["control_degraded"])
        self.assertIn("personal_minus_base", r["X2"])

    def test_select_rules(self):
        mk = lambda ok, f: {"pass": ok, "personal": {x: {"frac": f} for x in ("S1", "S2", "S4")}}  # noqa: E731
        self.assertEqual(G.select({"A-V0": mk(False, .3), "A-VB": mk(False, .4)})["outcome"], "neither arm passes")
        self.assertEqual(G.select({"A-V0": mk(False, .3), "A-VB": mk(True, .4)})["selected"], "A-VB")
        self.assertEqual(G.select({"A-V0": mk(True, .3), "A-VB": mk(True, .4)})["selected"], "A-VB")
        self.assertEqual(G.select({"A-V0": mk(True, .395), "A-VB": mk(True, .4)})["selected"], "A-V0")


if __name__ == "__main__":
    unittest.main()


# --- code3-r1 regressions -------------------------------------------------------------------------------------

from lfspk.personal.tune import EXPECTED_ALPHA as T_ALPHA  # noqa: E402
from lfspk.personal.tune import PILOT_FIXED  # noqa: E402


def _tune_config(arm, cfg, subj, tag, device, threads=2):
    c = {k: (list(v) if k == "readouts" else v) for k, v in PILOT_FIXED.items()}
    return {**c, "arm": arm, "config": cfg, "subject": subj, "tag": tag, "device": device, "threads": threads}


def _current():
    tin = {s: {"dict_identity_sha256": "d", "dict_digests": {f"{s}-00": "x"}, "bank_pack_sha256": "b",
               "profile_sha256": f"p0-{s}", "profiles_identity_sha256": "P", "dict_manifest_sha256": "m"}
           for s in S.pilot_order()}
    return {"score_manifest_sha256": "M", "profiles_identity_sha256": "P", "code": {"w6_score_code_sha256": "c",
            "w5_code_sha256": "w"}, "bases": dict(S.BASES),
            "tune_code": {"w6_tune_code_sha256": "t", "w5_code_sha256": "w5"},
            "profiles": {s: {"p0": f"p0-{s}", "p_end": f"pe-{s}"} for s in S.pilot_order()}, "tuning_inputs": tin}


def _records(a, current, mutate=None):
    """Synthetic current model records for subject a's cells (what model_record would read from the files)."""
    def rec(mref):
        if mref[0] == "base":
            return {"kind": "base", "name": mref[1], "sha256": current["bases"][mref[1]]}
        _, arm, cfg, subj, step = mref
        r = {"kind": "tuned", "path": f"/x/{arm}/{cfg}/{subj}/step{step}.pt", "sha256": f"sha-{arm}-{cfg}-{subj}-{step}",
             "identity_sha256": f"id-{arm}-{cfg}-{subj}", "step": step, "arm": arm, "config": cfg, "subject": subj,
             "tag": "", "device": "cuda", "platform": "Linux-x", "inputs": dict(current["tuning_inputs"][subj]),
             "base_sha256": current["bases"][S.ARMS[arm][0]], "code": dict(current["tune_code"]),
             "tune_config": _tune_config(arm, cfg, subj, "", "cuda"), "alpha": T_ALPHA[arm],
             "n_adapted": 186_242 if cfg == "P" else 771_074}
        return mutate(r) if mutate else r
    return {mref: rec(mref) for arm in S.ARMS for _, mref, _ in SC.cells(arm, a)}


def _expected(a, current, recs):
    cache = dict(recs)
    return SC.expected_records(a, current, cache, path_fn=None)


def _meta(a, current, expected):
    return {"subject": a, "keys": ["k"], "cells": list(expected), "score_manifest_sha256": current["score_manifest_sha256"],
            "profiles_identity_sha256": current["profiles_identity_sha256"], "code": dict(current["code"]),
            "models": {n: dict(r) for n, (r, _) in expected.items()}, "profile_sha256": {n: p for n, (_, p) in expected.items()}}


class TestProvenance(unittest.TestCase):
    def setUp(self):
        self.a = S.PILOT["F"][2]
        self.cur = _current()
        self.exp = _expected(self.a, self.cur, _records(self.a, self.cur))
        self.meta = _meta(self.a, self.cur, self.exp)

    def test_valid(self):
        SC.validate_meta(self.meta, self.cur, self.exp)

    def test_uniformly_stale_profiles(self):
        cur = dict(self.cur, profiles_identity_sha256="P2")
        with self.assertRaises(RuntimeError):
            SC.validate_meta(self.meta, cur, self.exp)
        cur = dict(self.cur, profiles={s: {"p0": "new", "p_end": "new"} for s in S.pilot_order()})
        with self.assertRaises(RuntimeError):  # every cell's recorded profile digest is checked
            SC.validate_meta(self.meta, cur, _expected(self.a, cur, _records(self.a, self.cur)))

    def test_uniformly_stale_code(self):
        cur = dict(self.cur, code={"w6_score_code_sha256": "c2", "w5_code_sha256": "w"})
        with self.assertRaises(RuntimeError):
            SC.validate_meta(self.meta, cur, self.exp)

    def test_replaced_checkpoint(self):
        recs = _records(self.a, self.cur, mutate=lambda r: {**r, "sha256": r["sha256"] + "-new"})
        with self.assertRaises(RuntimeError):
            SC.validate_meta(self.meta, self.cur, _expected(self.a, self.cur, recs))

    def test_changed_tuning_inputs(self):
        cur = dict(self.cur, tuning_inputs={s: {**v, "bank_pack_sha256": "b2"} for s, v in self.cur["tuning_inputs"].items()})
        with self.assertRaises(RuntimeError):  # the current readouts were tuned on other inputs
            _expected(self.a, cur, _records(self.a, self.cur))

    def test_wrong_run_at_cell(self):
        recs = _records(self.a, self.cur, mutate=lambda r: {**r, "tag": "cpu"})
        with self.assertRaises(RuntimeError):
            _expected(self.a, self.cur, recs)


class TestD5Provenance(unittest.TestCase):
    def setUp(self):
        self.cur = _current()
        self.a = S.PILOT["F"][0]

    def rec(self, tag, device, platform, extra=None):
        inputs = dict(self.cur["tuning_inputs"][self.a], **(extra or {}))
        return {"path": "/p", "sha256": "s", "identity_sha256": "i", "step": 1000, "arm": "A-VB", "config": "P",
                "subject": self.a, "tag": tag, "device": device, "platform": platform, "inputs": inputs,
                "base_sha256": S.BASES["VB-s0"], "code": dict(self.cur["tune_code"]),
                "tune_config": _tune_config("A-VB", "P", self.a, tag, device), "alpha": 3.0, "n_adapted": 186_242}

    def test_variant_checks(self):
        specs = SC.d5_variants("A-VB", self.a, "/mac")
        SC.check_variant(self.rec("", "cuda", "Linux-6"), "A-VB", self.a, "nixos", specs["nixos"], self.cur)
        SC.check_variant(self.rec("mac-background-t2-r1", "cpu", "macOS-27", {"bundle_json_sha256": "z"}), "A-VB", self.a,
                         "mac-r1", specs["mac-r1"], self.cur)
        with self.assertRaises(RuntimeError):  # a CUDA readout copied into a Mac path
            SC.check_variant(self.rec("", "cuda", "Linux-6"), "A-VB", self.a, "mac-r1", specs["mac-r1"], self.cur)
        with self.assertRaises(RuntimeError):  # right tag, wrong platform
            SC.check_variant(self.rec("mac-background-t2-r1", "cpu", "Linux-6", {"bundle_json_sha256": "z"}), "A-VB",
                             self.a, "mac-r1", specs["mac-r1"], self.cur)
        with self.assertRaises(RuntimeError):  # the other repetition
            SC.check_variant(self.rec("mac-background-t2-r2", "cpu", "macOS-27", {"bundle_json_sha256": "z"}), "A-VB",
                             self.a, "mac-r1", specs["mac-r1"], self.cur)
        with self.assertRaises(RuntimeError):  # tuned with another profile
            r = self.rec("", "cuda", "Linux-6")
            r["inputs"]["profile_sha256"] = "other"
            SC.check_variant(r, "A-VB", self.a, "nixos", specs["nixos"], self.cur)

    def _payload(self, key, n_rows=None):
        fam, absent = SC.expected_rows(self.a)
        n = len(fam) if n_rows is None else n_rows
        res = {"sha256": "s1", "metrics": [[1.0, 0.5, 1e-4]] * n, "family": fam[:n], "absent": absent[:n]}
        prov = {"score_manifest_sha256": "M", "profiles_identity_sha256": "P", "code": self.cur["code"],
                "variants": {key: {"sha256": "s1", "identity_sha256": "i1"}}}
        return {"provenance": prov, "results": {key: res}}

    @unittest.skipUnless(__import__("os").path.ismount("/mnt/hd"), "scoring keys need the corpus metadata")
    def test_stale_and_truncated_d5(self):
        key = f"A-VB|{self.a}|nixos"
        recs = {key: {"sha256": "s1", "identity_sha256": "i1"}}
        v = SC.validate_d5(self._payload(key), self.cur, recs)
        self.assertIn(key, v["results"])
        v = SC.validate_d5(self._payload(key), self.cur, {key: {"sha256": "s2", "identity_sha256": "i1"}})
        self.assertIn(key, v["errors"])  # the readout was replaced after d5.json was written: that variant only
        v = SC.validate_d5(self._payload(key, n_rows=6), self.cur, recs)
        self.assertIn(key, v["errors"])  # code3-r2 M3: 6 rows instead of the subject's 120
        with self.assertRaises(RuntimeError):  # global provenance: scored with other code
            SC.validate_d5(self._payload(key), dict(self.cur, code={"w6_closure_sha256": "z"}), recs)

    @unittest.skipUnless(__import__("os").path.ismount("/mnt/hd"), "scoring keys need the corpus metadata")
    def test_malformed_results_isolated(self):
        """code3-r3: schema and conversion errors stay with their variant; a malformed CPU result is report-only and
        a malformed Mac result fails only its own arm."""
        a = self.a
        fam, absent = SC.expected_rows(a)
        good = {"sha256": "s1", "metrics": [[1.0, 0.6, 1e-4]] * len(fam), "family": fam, "absent": absent}
        keys = [f"{arm}|{a}|{v}" for arm in ("A-V0", "A-VB") for v in ("nixos", "mac-r1", "mac-r2", "cpu")]
        res = {k: dict(good) for k in keys}
        res[f"A-VB|{a}|cpu"] = {k: v for k, v in good.items() if k != "family"}  # missing field -> KeyError
        res[f"A-V0|{a}|mac-r1"] = {**good, "metrics": [[1.0, 0.6]] + good["metrics"][1:]}  # ragged row -> ValueError
        res[f"A-V0|{a}|mac-r2"] = {**good, "metrics": None}  # wrong type
        prov = {"score_manifest_sha256": "M", "profiles_identity_sha256": "P", "code": self.cur["code"],
                "variants": {k: {"sha256": "s1", "identity_sha256": "i1"} for k in keys}}
        recs = {k: {"sha256": "s1", "identity_sha256": "i1"} for k in keys}
        v = SC.validate_d5({"provenance": prov, "results": res}, self.cur, recs)
        self.assertEqual(sorted(v["errors"]), sorted([f"A-VB|{a}|cpu", f"A-V0|{a}|mac-r1", f"A-V0|{a}|mac-r2"]))
        self.assertIn("KeyError", v["errors"][f"A-VB|{a}|cpu"])
        # gates: only the subject `a` is present here, so evaluate d5_check per arm on this subject's rows
        from unittest import mock

        with mock.patch("lfspk.personal.macbench.MAC_SUBJECTS", (a,)):
            self.assertTrue(G.d5_check("A-VB", v)["ok"])  # the malformed CPU result is report-only
            r0 = G.d5_check("A-V0", v)
            self.assertFalse(r0["ok"])  # the malformed Mac results fail their own arm only
            self.assertIn(f"A-V0|{a}|mac-r1", r0["missing_or_invalid"])


class TestGatesR1(unittest.TestCase):
    def test_g5_duplicate_records(self):
        ctx = ctx_for(synthetic_scores())
        ms = passing_measures("A-VB")
        bad = dict(ms[0], wall_s=1300.0)
        r = G.arm_report(ctx, "A-VB", [bad] + ms, d5_identical("A-VB"))  # a failing and a passing record for one rep
        self.assertFalse(r["gates"]["G5"])
        self.assertTrue(r["G5"]["duplicates"])
        r = G.arm_report(ctx, "A-VB", ms + [bad], d5_identical("A-VB"))  # order does not matter
        self.assertFalse(r["gates"]["G5"])
        extra = dict(ms[0], rep=3, wall_s=1300.0)  # every eligible measured run must meet the budget
        self.assertFalse(G.arm_report(ctx, "A-VB", ms + [extra], d5_identical("A-VB"))["gates"]["G5"])

    def test_x1_under_over_contrasts(self):
        sc = synthetic_scores()
        rng = np.random.default_rng(3)
        for arm in S.ARMS:  # non-proportional under and over in the profile-swap cell
            x = sc["cells"][f"{arm}|P1000|swapA"].copy()
            x[:, 1] = x[:, 1] * rng.uniform(0.8, 1.4, len(x)) + rng.uniform(0, 0.05, len(x))
            x[:, 2] = x[:, 2] + rng.uniform(0, 0.004, len(x))
            sc["cells"][f"{arm}|P1000|swapA"] = x
        ctx = ctx_for(sc)
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), d5_identical("A-VB"), cosines={"1": 0.98, "2": 0.96})
        c = r["X1"]["contrasts"]["profile|W_A"]["S4"]
        m = ctx.mask("S4")
        a, b = ctx.cell("A-VB", "P1000|personal"), ctx.cell("A-VB", "P1000|swapA")
        for k, col in (("under", 1), ("over", 2)):
            self.assertAlmostEqual(c[k]["point"], a[m, col].mean() - b[m, col].mean())
            self.assertTrue(c[k]["ci"]["resolved"])
            self.assertLess(c[k]["ci"]["lo"], c[k]["ci"]["hi"])
            self.assertLessEqual(c[k]["ci"]["lo"], c[k]["point"])
            self.assertGreaterEqual(c[k]["ci"]["hi"], c[k]["point"])
        cell = r["X1"]["cells"]["W_A.pB"]["S4"]
        self.assertTrue(all(cell[k]["ci"]["resolved"] for k in ("frac", "under", "over")))
        # minor 5 report-only outputs
        self.assertIn("per_user", r["base_safety"])
        self.assertEqual(r["D3_drift"]["cos_median"], 0.97)
        self.assertTrue(np.isfinite(r["sizing"]["bootstrap_se_gain_S4"]))
        self.assertEqual(set(r["F"]["gates_report_only"]), {"G1", "G2", "G3a", "G3b", "G3c", "G4a", "G4b"})
        self.assertIn(f"{S.PILOT['F'][0]}|mac-r1-vs-r2", r["G5"]["d5"]["rows"])

    def test_d5_error_fails_g5(self):
        ctx = ctx_for(synthetic_scores())
        r = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), {"error": "RuntimeError: stale"})
        self.assertFalse(r["gates"]["G5"])


class TestR2(unittest.TestCase):
    def test_closure_covers_every_file(self):
        """code3-r2 M1: a change to any file of the calculation and reporting closure changes the identity."""
        import shutil
        import tempfile
        from pathlib import Path

        repo = Path(SC.__file__).resolve().parents[2]
        files = [p.relative_to(repo) for d, g in SC.CLOSURE.values() for p in sorted((repo / d).glob(g))]
        files += [Path(f) for f in SC.W0_BOOTSTRAP]
        for must in ("lfspk/personal/boot.py", "lfspk/personal/gates.py", "lfspk/personal/macbench.py",
                     "lfspk/harness/tmetrics.py", "lfspk/harness/metrics.py", "lfspk/harness/align.py"):
            self.assertIn(Path(must), files)
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            for f in files:
                (root / f).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(repo / f, root / f)
            base = SC.code_identity(root)
            self.assertEqual(base, SC.code_identity(repo))
            for f in files:
                orig = (root / f).read_bytes()
                (root / f).write_bytes(orig + b"\n# probe\n")
                self.assertNotEqual(SC.code_identity(root), base, str(f))
                (root / f).write_bytes(orig)

    def test_tuning_config_substitutions(self):
        """code3-r2 M2: wrong hyperparameters, execution settings or training code are refused."""
        cur = _current()
        a = S.PILOT["M"][0]
        good = _records(a, cur)[("tuned", "A-V0", "P", a, 1000)]
        good = {**good, "alpha": 10.0}
        SC.check_tuned(good, "A-V0", "P", a, 1000, "", cur)
        for k, v in (("lr", 1e-3), ("seed", 1), ("threads", 4), ("device", "cpu"), ("steps", 2000), ("batch", 16),
                     ("readouts", [1000])):
            bad = {**good, "tune_config": {**good["tune_config"], k: v}}
            with self.assertRaises(RuntimeError, msg=k):
                SC.check_tuned(bad, "A-V0", "P", a, 1000, "", cur)
        with self.assertRaises(RuntimeError):  # stale training code
            SC.check_tuned({**good, "code": {"w6_tune_code_sha256": "old", "w5_code_sha256": "w5"}}, "A-V0", "P", a, 1000,
                           "", cur)
        with self.assertRaises(RuntimeError):  # another arm's alpha
            SC.check_tuned({**good, "alpha": 3.0}, "A-V0", "P", a, 1000, "", cur)
        with self.assertRaises(RuntimeError):  # the Mac variant must be CPU
            mac = {**good, "tag": "mac-background-t2-r1", "tune_config": {**good["tune_config"], "tag": "mac-background-t2-r1"}}
            SC.check_tuned(mac, "A-V0", "P", a, 1000, "mac-background-t2-r1", cur)

    def test_d5_isolated_per_arm(self):
        """code3-r2 M4: one arm's (or the CPU run's) missing readout fails only what it affects."""
        ctx = ctx_for(synthetic_scores())
        d5 = merge_d5(d5_identical("A-V0"), d5_identical("A-VB"))
        k = f"A-V0|{S.PILOT['F'][0]}|mac-r1"
        d5["results"].pop(k)
        d5["errors"][k] = "FileNotFoundError: missing"
        d5["errors"][f"A-VB|{S.PILOT['F'][0]}|cpu"] = "FileNotFoundError: missing"  # report-only attribution run
        rv0 = G.arm_report(ctx, "A-V0", passing_measures("A-V0"), d5)
        rvb = G.arm_report(ctx, "A-VB", passing_measures("A-VB"), d5)
        self.assertFalse(rv0["gates"]["G5"])
        self.assertIn(k, rv0["G5"]["d5"]["missing_or_invalid"])
        self.assertTrue(rvb["gates"]["G5"], rvb["G5"]["d5"])
        self.assertFalse(G.arm_report(ctx, "A-VB", passing_measures("A-VB"), {"error": "global"})["gates"]["G5"])
