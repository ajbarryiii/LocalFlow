"""Contract tests for experiment 3's analysis (DESIGN-3 "Evaluation"):
learned_bias.analysis3, on synthetic per-session data in R1's schema."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import analysis3 as a3

from tests.helpers import per_session_record as rec

SIZES = (100, 500, 1000)
SEEDS3 = ("L2/sel/model-s1000@1", "L2/rep1/model-s1000@1", "L2/rep2/model-s1000@1")
REF = "L2/L2/model-e0.5@1"


def build(rows_errors, set_="earnings21", sessions=10, ref_words=1000, base=100, role="held-out", sizes=SIZES):
    """Per-session records: baseline plus each row with errors
    `rows_errors[row](session index, size)`."""
    out = []
    for i in range(sessions):
        s = f"call{i:03d}"
        for z in sizes:
            out.append(rec("baseline", set_, z, s, ref_words, base, base, role=role))
            for row, f in rows_errors.items():
                out.append(rec(row, set_, z, s, ref_words, f(i, z), base, role=role))
    return a3.PerSession(out)


class SchemaTests(unittest.TestCase):
    def test_reads_r1s_schema_and_validates_counts(self):
        good = [rec("baseline", "x", 100, "s", 50, 5, 5), rec("r", "x", 100, "s", 50, 7, 5)]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "per_session.jsonl"
            p.write_text("".join(json.dumps(r) + "\n" for r in good))
            ps = a3.read_per_session(p)
        self.assertEqual(ps.get("r", "x", 100, "s")["net_errors"], 2)
        bad = {
            "errors != sub+del+ins": dict(good[1], errors=8, net_errors=3),
            "b+u errors": dict(good[1], b_errors=0, u_errors=1),
            "net": dict(good[1], net_errors=1),
            "missing field": {k: v for k, v in good[1].items() if k != "ref_words"},
            "float count": dict(good[1], ref_words=50.0),
            "size": dict(good[1], size=200),
        }
        for name, r in bad.items():
            with self.assertRaises(a3.AnalysisError, msg=name):
                a3.PerSession([good[0], r])
        with self.assertRaises(a3.AnalysisError):
            a3.PerSession(good + [good[1]])  # duplicate key
        with self.assertRaises(a3.AnalysisError):  # ref words differ between rows of one session
            a3.PerSession([good[0], dict(good[1], ref_words=51, u_ref_words=good[1]["u_ref_words"] + 1)])


class BootstrapTests(unittest.TestCase):
    def test_point_estimate_and_degenerate_ci(self):
        # Every session: new has 2 fewer net errors per size than the reference.
        ps = build({"new": lambda i, z: 90, "ref": lambda i, z: 92})
        r = a3.paired_bootstrap(ps, ["new"], "ref", "earnings21")
        self.assertEqual(r["sum_d"], -2 * 3 * 10)
        self.assertEqual(r["sum_ref_words"], 1000 * 3 * 10)
        self.assertAlmostEqual(r["point"], 100 * -60 / 30000)
        self.assertAlmostEqual(r["ci"][0], r["point"])
        self.assertAlmostEqual(r["ci"][1], r["point"])
        self.assertEqual((r["resamples"], r["seed"], r["sessions"]), (10000, 20261011, 10))

    def test_ci_is_deterministic_and_seeded(self):
        rng = np.random.default_rng(0)
        noise = rng.integers(-6, 7, size=10)
        ps = build({"new": lambda i, z: 100 + int(noise[i]), "ref": lambda i, z: 100})
        a = a3.paired_bootstrap(ps, ["new"], "ref", "earnings21")
        b = a3.paired_bootstrap(ps, ["new"], "ref", "earnings21")
        c = a3.paired_bootstrap(ps, ["new"], "ref", "earnings21", seed=1)
        self.assertEqual(a, b)
        self.assertNotEqual(a["ci"], c["ci"])
        self.assertLess(a["ci"][0], a["point"])
        self.assertGreater(a["ci"][1], a["point"])
        self.assertAlmostEqual(a["point"], 100 * 3 * noise.sum() / 30000)

    def test_seeds_are_averaged_per_call(self):
        # Seeds 90, 93, 96 average to 93; reference 95: d = -2 per size.
        ps = build({SEEDS3[0]: lambda i, z: 90, SEEDS3[1]: lambda i, z: 93, SEEDS3[2]: lambda i, z: 96,
                    REF: lambda i, z: 95})
        r = a3.paired_bootstrap(ps, list(SEEDS3), REF, "earnings21")
        self.assertEqual(r["sum_d"], -2 * 3 * 10)

    def test_exploratory_per_domain(self):
        recs = list(build({"new": lambda i, z: 99, "ref": lambda i, z: 100}, set_="gigaspeech").records.values())
        recs += list(build({"new": lambda i, z: 101, "ref": lambda i, z: 100}, set_="icsi_eval").records.values())
        res = a3.exploratory(a3.PerSession(recs), ["new"], "ref")
        self.assertEqual(set(res), {"gigaspeech", "icsi_eval"})
        self.assertLess(res["gigaspeech"]["point"], 0)
        self.assertGreater(res["icsi_eval"]["point"], 0)
        self.assertEqual(res["gigaspeech"]["resamples"], 10000)


def frozen_of(sessions, utterances=3, ref_words=1000):
    """The frozen coverage that `build(..., sessions)` data satisfies."""
    return {"manifest_sha256": "f" * 64,
            "calls": {f"call{i:03d}": {"utterances": utterances, "ref_words": ref_words} for i in range(sessions)}}


def run_json(run, seed, step, lr, horizon, selected):
    """A run.json as train.py writes it for an experiment-3 run (all fields)."""
    plan = [250, 500, step, 6000] if selected else [step]
    args = {"variant": "L2", "run": run, "prep": "/w/prep", "split": "train", "out_root": "/w/train",
            "export": "/e", "epochs": "None", "batch": "1024", "lr": str(lr), "weight_decay": "0.01",
            "w_correction": "1.0", "w_preservation": "1.0", "seed": "20261011", "call_fraction": "1.0",
            "window": "16", "device": "cuda", "gpu_lock": "/l", "wait_gpu_lock": "False", "log_every": "50",
            "overwrite": "False", "dev_check_cmd": "DEV", "dev_check_results": "/w/eval/{run}/results.json",
            "toy": "False", "max_steps": "0", "horizon_steps": str(horizon),
            "checkpoint_steps": ",".join(map(str, plan))}
    if not selected:
        args.update(train_seed=str(seed), fixed_lambda="1.0")
    return {"args": args, "toy": False, "train_df": {"spgispeech": "d" * 64}, "variant": "L2", "params": 3499585,
            "shards": 10, "calls": 5, "decisions": 999, "datasets": {"spgispeech": {"shards": 10, "decisions": 999}},
            "steps_per_epoch": 11057, "total_steps": plan[-1], "checkpoints_planned": [f"s{s}" for s in plan],
            "checkpoints": [f"s{s}" for s in plan], "torch": "2.13.0+cu130", "device": "RTX",
            "lr": lr, "horizon_steps": horizon, "train_seed": seed, "step_plan": plan, "calls_file": None,
            "checkpoint_stats": {f"s{s}": {"step": s, "seen": {}} for s in plan},
            "identity": {"prep_index_sha256": "1" * 64, "policy_sha256": {"spgispeech": ["2" * 64]},
                         "shard_pool_sha256": "3" * 64, "export_weights_sha256": "4" * 64,
                         "dev_cmd_sha256": "5" * 64}}


def write_seed_runs(root, sel_run="sel", step=1000, lr=3e-4, horizon=6000, seeds=(20261011, 20261012, 20261013),
                    runs=("sel", "rep1", "rep2"), extra=None):
    """run.json of the selected run and its replicates; returns a
    selection3.json dict selecting `sel_run` at `step`, λ 1. `extra[run]`
    updates a run's run.json (an "args" dict is merged into its args)."""
    for run, s in zip(runs, seeds):
        info = run_json(run, s, step, lr, horizon, run == sel_run)
        over = dict((extra or {}).get(run, {}))
        info["args"].update(over.pop("args", {}))
        info.update(over)
        (Path(root) / run).mkdir(parents=True, exist_ok=True)
        (Path(root) / run / "run.json").write_text(json.dumps(info))
    return {"mode": "global", "baseline_fallback": False,
            "selected": {"run": sel_run, "step": step, "lambda": 1.0, "lr": lr, "horizon_steps": horizon}}


class Earnings21Tests(unittest.TestCase):
    def verdict(self, f_new, f_ref=lambda i, z: 100, sessions=20, **kw):
        rows = {s: f_new for s in SEEDS3}
        rows[REF] = f_ref
        ps = build(rows, sessions=sessions)
        return a3.earnings21_verdict(ps, list(SEEDS3), REF, frozen=frozen_of(sessions), **kw)

    def test_supported_not_supported_inconclusive(self):
        self.assertEqual(self.verdict(lambda i, z: 95)["verdict"], "supported")
        self.assertEqual(self.verdict(lambda i, z: 100)["verdict"], "not supported")  # point = 0
        self.assertEqual(self.verdict(lambda i, z: 103)["verdict"], "not supported")
        # Small mean improvement with noise: CI straddles 0.
        rng = np.random.default_rng(3)
        noise = rng.integers(-10, 11, size=20)
        noise[0] -= int(noise.sum()) + 2  # make the mean slightly negative
        v = self.verdict(lambda i, z: 100 + int(noise[i]))
        self.assertLess(v["point"], 0)
        self.assertGreaterEqual(v["ci"][1], 0)
        self.assertEqual(v["verdict"], "inconclusive")
        self.assertFalse(v["incomplete"])
        self.assertEqual(v["comparison"], {"new": list(SEEDS3), "reference": REF, "set": "earnings21",
                                           "sizes": list(SIZES)})

    def test_truncated_set_is_not_supported(self):
        # Review finding 1: every row covers only 1 of the 20 frozen calls.
        rows = {s: (lambda i, z: 50) for s in SEEDS3} | {REF: lambda i, z: 100}
        v = a3.earnings21_verdict(build(rows, sessions=1), list(SEEDS3), REF, frozen=frozen_of(20))
        self.assertEqual((v["verdict"], v["incomplete"]), ("not supported", True))
        self.assertIn("missing", v["reason"])
        # Frozen calls all present but with other utterance or word counts.
        ps = build(rows, sessions=20)
        for frozen in (frozen_of(20, utterances=4), frozen_of(20, ref_words=999)):
            v = a3.earnings21_verdict(ps, list(SEEDS3), REF, frozen=frozen)
            self.assertEqual((v["verdict"], v["incomplete"]), ("not supported", True))
        # A call outside the freeze.
        v = a3.earnings21_verdict(build(rows, sessions=21), list(SEEDS3), REF, frozen=frozen_of(20))
        self.assertIn("outside the freeze", v["reason"])

    def test_exactly_three_distinct_seed_rows(self):
        # Review finding 2: a repeated row would double-weight a seed.
        rows = {s: (lambda i, z: 90) for s in SEEDS3} | {REF: lambda i, z: 100}
        ps = build(rows, sessions=20)
        for new in ([SEEDS3[0], SEEDS3[0], SEEDS3[1], SEEDS3[2]], [SEEDS3[0], SEEDS3[0], SEEDS3[1]],
                    list(SEEDS3[:2])):
            v = a3.earnings21_verdict(ps, new, REF, frozen=frozen_of(20))
            self.assertEqual((v["verdict"], v["incomplete"]), ("not supported", True), new)
        v = a3.earnings21_verdict(ps, list(SEEDS3), REF, frozen=frozen_of(20), seed_problems=["x"])
        self.assertEqual(v["verdict"], "not supported")

    def test_parity_fallback_and_evaluation_binding(self):
        self.assertEqual(self.verdict(lambda i, z: 90, parity_ok=False)["verdict"], "not supported")
        v = self.verdict(lambda i, z: 90, selection_fallback=True)
        self.assertEqual(v["verdict"], "not supported")
        self.assertIn("baseline", v["reason"])
        good = {"parity_failures": [], "df_source": {"earnings21": {
            "split": "scored", "manifests": [{"path": "m", "sha256": "f" * 64}]}}}
        self.assertEqual(self.verdict(lambda i, z: 90, results=good)["verdict"], "supported")
        for bad in (dict(good, parity_failures=["x"]),
                    {"parity_failures": [], "df_source": {"earnings21": {"split": "scored",
                                                                          "manifests": [{"sha256": "0" * 64}]}}},
                    {"parity_failures": [], "df_source": {}}):
            self.assertEqual(self.verdict(lambda i, z: 90, results=bad)["verdict"], "not supported")


class SeedRowTests(unittest.TestCase):
    ROWS = ["L2/sel/model-s1000@1", "L2/rep1/model-s1000@1", "L2/rep2/model-s1000@1"]

    def problems(self, **kw):
        with tempfile.TemporaryDirectory() as d:
            sel = write_seed_runs(d, **kw)
            return a3.seed_row_problems(self.ROWS, sel, d)

    def test_seed_rows_are_verified_against_the_runs(self):
        with tempfile.TemporaryDirectory() as d:
            sel = write_seed_runs(d)
            self.assertEqual(a3.seed_row_problems(self.ROWS, sel, d), [])
            bad_rows = {
                "duplicate": [self.ROWS[0], self.ROWS[0], self.ROWS[1]],
                "other λ": [self.ROWS[0], self.ROWS[1], "L2/rep2/model-s1000@0.71"],
                "other step": [self.ROWS[0], self.ROWS[1], "L2/rep2/model-s500@1"],
                "other variant": [self.ROWS[0], self.ROWS[1], "L3/rep2/model-s1000@1"],
                "unknown run": [self.ROWS[0], self.ROWS[1], "L2/rep9/model-s1000@1"],
            }
            for name, rows in bad_rows.items():
                self.assertTrue(a3.seed_row_problems(rows, sel, d), name)
        cases = {
            "lr": {"extra": {"rep1": {"lr": 1e-3}}},
            "horizon": {"extra": {"rep2": {"horizon_steps": 44228}}},
            "seeds": {"seeds": (20261011, 20261012, 20261012)},
            "subset": {"extra": {"rep2": {"args": {"call_fraction": "0.25"}}}},
            "no checkpoint": {"extra": {"rep1": {"checkpoints": ["s500"]}}},
            "selected run": {"seeds": (20261012, 20261011, 20261013)},
        }
        for name, kw in cases.items():
            self.assertTrue(self.problems(**kw), name)

    def test_replicates_match_the_selected_runs_full_configuration(self):
        # Re-check finding 8: everything but the allow-listed fields must
        # equal the selected run's.
        cases = {
            "args.batch": {"rep1": {"args": {"batch": "1"}}},
            "args.weight_decay": {"rep2": {"args": {"weight_decay": "1.0"}}},
            "args.w_correction": {"rep1": {"args": {"w_correction": "2.0"}}},
            "args.window": {"rep1": {"args": {"window": "8"}}},
            "args.prep": {"rep2": {"args": {"prep": "/other/prep"}}},
            "args.dev_check_cmd": {"rep1": {"args": {"dev_check_cmd": "OTHER"}}},
            "args.seed": {"rep1": {"args": {"seed": "7"}}},
            "toy": {"rep2": {"toy": True}},
            "params": {"rep1": {"params": 1}},
            "train_df": {"rep1": {"train_df": {"spgispeech": "e" * 64}}},
            "decisions": {"rep2": {"decisions": 998}},
            "identity": {"rep1": {"identity": {"shard_pool_sha256": "9" * 64}}},
            "fixed_lambda": {"rep2": {"args": {"fixed_lambda": "0.71"}}},
            "absent field": {"rep1": {"identity": None}},
        }
        for name, extra in cases.items():
            p = self.problems(extra=extra)
            self.assertTrue(p, name)
        p = self.problems(extra={"rep1": {"args": {"batch": "1"}}})
        self.assertTrue(any("args.batch" in x for x in p), p)
        self.assertTrue(any("toy run" in x for x in self.problems(extra={"rep2": {"toy": True}})))
        # A toy selected run is refused too.
        self.assertTrue(self.problems(extra={"sel": {"toy": True}, "rep1": {"toy": True}, "rep2": {"toy": True}}))
        # The allow-listed differences are accepted.
        ok = {"rep1": {"args": {"log_every": "10", "overwrite": "True", "wait_gpu_lock": "True"}}}
        self.assertEqual(self.problems(extra=ok), [])

    def test_allow_list_is_explicit(self):
        self.assertEqual(a3.REPLICATE_MAY_DIFFER, {"train_seed", "step_plan", "total_steps", "checkpoints_planned",
                                                   "checkpoints", "checkpoint_stats"})
        self.assertEqual(a3.REPLICATE_ARGS_MAY_DIFFER, {"run", "train_seed", "checkpoint_steps", "fixed_lambda",
                                                        "overwrite", "wait_gpu_lock", "log_every"})

    def test_malformed_run_json_is_a_problem_not_a_crash(self):
        with tempfile.TemporaryDirectory() as d:
            sel = write_seed_runs(d)
            (Path(d) / "rep1" / "run.json").write_text('{"args": {"batch"')  # truncated
            self.assertTrue(any("rep1" in x for x in a3.seed_row_problems(self.ROWS, sel, d)))
            (Path(d) / "rep1" / "run.json").write_text("[]")
            self.assertTrue(a3.seed_row_problems(self.ROWS, sel, d))
            (Path(d) / "sel" / "run.json").write_text("null")
            self.assertTrue(a3.seed_row_problems(self.ROWS, sel, d))
        for bad_sel in ([], {"mode": "global", "selected": []}, {"mode": "global", "selected": {"run": 1}}):
            self.assertTrue(a3.seed_row_problems(self.ROWS, bad_sel, "/nonexistent"))


class FreezeTests(unittest.TestCase):
    def test_normalization_matches_the_evaluator(self):
        self.assertEqual(a3.normalize_words("Good morning, ladies & gentlemen -- Q3's EPS: $1.20!"),
                         ["good", "morning", "ladies", "gentlemen", "q3's", "eps", "1", "20"])
        self.assertEqual(a3.normalize_words("'quoted' rock'n'roll ''"), ["quoted", "rock'n'roll"])

    def test_the_real_freeze_binds(self):
        import os

        root = os.environ.get("LF_EXP2_ROOT")
        freeze = Path(root or "") / "datasets" / "earnings21" / "FREEZE.json"
        if not root or not freeze.exists():
            self.skipTest("set LF_EXP2_ROOT to check the real Earnings-21 freeze")
        if not freeze.with_name(a3.RUST_COUNTS_NAME).exists():
            self.skipTest("PENDING: the runner writes ref_counts.json with R1's counting pass")
        fc = a3.frozen_coverage(freeze)
        self.assertEqual(len(fc["calls"]), 44)
        self.assertEqual(sum(c["utterances"] for c in fc["calls"].values()), 7754)

    def test_frozen_coverage_is_bound_to_the_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            man, freeze = write_freeze(d, calls=3)
            fc = a3.frozen_coverage(freeze)
            self.assertEqual(fc["calls"]["call000"], {"utterances": 3, "ref_words": 1000})
            self.assertEqual(len(fc["calls"]), 3)
            f = json.loads(freeze.read_text())
            for bad in (dict(f, manifest_sha256="0" * 64), dict(f, calls=4), dict(f, utterances=10),
                        dict(f, per_call=dict(f["per_call"], call000={"utterances": 2})), dict(f, per_call=[])):
                freeze.write_text(json.dumps(bad))
                with self.assertRaises(a3.AnalysisError):
                    a3.frozen_coverage(freeze)
            freeze.write_text("[]")
            with self.assertRaises(a3.AnalysisError):
                a3.frozen_coverage(freeze)

    def test_rust_counts_are_authoritative_and_cross_checked(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            man, freeze = write_freeze(d, calls=3)
            rc = freeze.with_name(a3.RUST_COUNTS_NAME)
            good = json.loads(rc.read_text())

            def with_counts(obj):
                rc.write_text(json.dumps(obj))
                return a3.frozen_coverage(freeze)

            self.assertEqual(with_counts(good)["ref_counts"], str(rc))
            sess = [dict(s) for s in good["sessions"]]
            sess[1]["ref_words"] += 1
            bad = {
                "missing": None,
                "not json": "{",
                "format": dict(good, format="other"),
                "session rule": dict(good, session_rule="before:/"),
                "unscored lines": dict(good, unscored_lines=1, utterances=good["utterances"] - 1),
                "unbound": dict(good, manifest_sha256="0" * 64),
                "mismatch": dict(good, sessions=sess, ref_words=good["ref_words"] + 1),
                "totals": dict(good, ref_words=good["ref_words"] + 1),
                "unsorted": dict(good, sessions=list(reversed(good["sessions"]))),
                "other calls": dict(good, sessions=good["sessions"][:2], utterances=6,
                                    manifest_lines=6, ref_words=2000),
                "shape": dict(good, sessions={"call000": 1}),
            }
            for name, obj in bad.items():
                if obj is None:
                    rc.unlink(missing_ok=True)
                elif isinstance(obj, str):
                    rc.write_text(obj)
                else:
                    rc.write_text(json.dumps(obj))
                with self.assertRaises(a3.PipelineError, msg=name):
                    a3.frozen_coverage(freeze)


def write_freeze(d, calls):
    """A synthetic manifest (3 utterances, 1000 words per call), its
    FREEZE.json, and R1-format ref_counts.json beside it."""
    from learned_bias.provenance import sha256_file

    man = Path(d) / "manifest.jsonl"
    with open(man, "w") as f:
        for i in range(calls):
            for k, n in enumerate((333, 333, 334)):
                f.write(json.dumps({"id": f"call{i:03d}/{k}", "session": f"call{i:03d}", "split": "heldout",
                                    "text": " ".join(["Word,"] * n)}) + "\n")
    sha = sha256_file(man)
    freeze = Path(d) / "FREEZE.json"
    freeze.write_text(json.dumps({"manifest": str(man), "manifest_sha256": sha, "calls": calls,
                                  "utterances": 3 * calls,
                                  "per_call": {f"call{i:03d}": {"utterances": 3} for i in range(calls)}}))
    freeze.with_name(a3.RUST_COUNTS_NAME).write_text(json.dumps({
        "format": "lf-bias-eval reference counts v1", "manifest": man.name, "manifest_sha256": sha,
        "session_rule": "field:session", "normalizer": "wer::normalize", "manifest_lines": 3 * calls,
        "unscored_lines": 0, "utterances": 3 * calls, "ref_words": 1000 * calls,
        "sessions": [{"session": f"call{i:03d}", "utterances": 3, "ref_words": 1000} for i in range(calls)]}))
    return man, freeze


DEV = ("d1", "d2")


def dev_ps(cands, sessions=8, seed=0):
    """Dev per-session data: candidate rows with errors per (domain, session)
    from `cands[row](rng, domain, session)`, baseline errors 100."""
    rng = np.random.default_rng(seed)
    out = []
    for dom in DEV:
        sizes = (500,) if dom == "d2" else SIZES
        for i in range(sessions):
            for z in sizes:
                s = f"{dom}-{i}"
                out.append(rec("baseline", dom, z, s, 1000, 100, 100, role="dev"))
                for row, f in cands.items():
                    out.append(rec(row, dom, z, s, 1000, int(f(rng, dom, i)), 100, role="dev"))
    return a3.PerSession(out)


def cand(run, step, lr, lam=1.0):
    return {"run": run, "step": step, "lr": lr, "lambda": lam, "model_id": f"L2/{run}/model-s{step}",
            "row": f"L2/{run}/model-s{step}@{a3.LAMBDA_LITERALS[lam]}"}


class DevTests(unittest.TestCase):
    def test_dev_objective_from_sessions(self):
        ps = dev_ps({"r": lambda rng, dom, i: 90 if dom == "d1" else 80})
        obj = a3.dev_objectives(ps, ["r", "baseline"], domains=DEV)
        self.assertAlmostEqual(obj["r"], (0.9 + 0.8) / 2)
        self.assertEqual(obj["baseline"], 1.0)
        with self.assertRaises(a3.AnalysisError):
            a3.dev_objectives(ps, ["r"], domains=DEV + ("d3",))

    def test_dev_grid_per_domain_contributions(self):
        c1 = cand("A1", 250, 1e-3)
        ps = dev_ps({c1["row"]: lambda rng, dom, i: 90 if dom == "d1" else 80})
        g = a3.dev_grid(ps, [c1], domains=DEV)
        self.assertAlmostEqual(g[c1["row"]]["d1"], 0.9)
        self.assertAlmostEqual(g[c1["row"]]["d2"], 0.8)
        self.assertAlmostEqual(g[c1["row"]]["objective"], 0.85)

    def test_stability_clear_winner(self):
        c1, c2 = cand("A1", 250, 1e-3), cand("A2", 500, 3e-4)
        ps = dev_ps({c1["row"]: lambda rng, d, i: 80, c2["row"]: lambda rng, d, i: 95})
        st = a3.selection_stability(ps, [c1, c2], domains=DEV, run_order=["A1", "A2"])
        self.assertEqual(st["winner"], {"run": "A1", "step": 250})
        self.assertEqual(st["share"], 1.0)
        self.assertEqual((st["resamples"], st["seed"]), (1000, 20261011))

    def test_stability_near_tie_is_unstable_and_reproducible(self):
        c1, c2 = cand("A1", 250, 1e-3), cand("B", 250, 1e-3)
        f = {c1["row"]: lambda rng, d, i: 90 + rng.integers(-8, 9), c2["row"]: lambda rng, d, i: 90 + rng.integers(-8, 9)}
        ps = dev_ps(f, sessions=12)
        st = a3.selection_stability(ps, [c1, c2], domains=DEV, run_order=["A1", "B"])
        st2 = a3.selection_stability(ps, [c1, c2], domains=DEV, run_order=["A1", "B"])
        self.assertEqual(st, st2)
        self.assertGreater(st["share"], 0.0)
        self.assertLess(st["share"], 1.0)
        self.assertEqual(sum(st["winners"].values()) + st["undefined"], 1000)

    def test_stability_baseline_wins_ties(self):
        c1 = cand("A1", 250, 1e-3)
        ps = dev_ps({c1["row"]: lambda rng, d, i: 100})
        st = a3.selection_stability(ps, [c1], domains=DEV, run_order=["A1"], resamples=50)
        self.assertEqual(st["winner"], {"run": "baseline", "step": 0})
        self.assertEqual(st["share"], 1.0)


class SensitivityTests(unittest.TestCase):
    def test_half_width_shrinks_with_more_units(self):
        rng = np.random.default_rng(1)
        noise = rng.integers(-15, 16, size=60)
        ps = build({"new": lambda i, z: 100 + int(noise[i]), "ref": lambda i, z: 100}, set_="gigaspeech",
                   sessions=60)
        small = a3.sensitivity(ps, "new", "ref", "gigaspeech", units=10)
        large = a3.sensitivity(ps, "new", "ref", "gigaspeech", units=200)
        self.assertGreater(small["half_width_points"], large["half_width_points"])
        self.assertEqual(small, a3.sensitivity(ps, "new", "ref", "gigaspeech", units=10))
        self.assertEqual((small["source_sessions"], small["units"], small["draws"]), (60, 10, 10000))
        by_words = a3.sensitivity(ps, "new", "ref", "gigaspeech", target_words=30000)
        # Review finding 6: matched on physical words (1000 per session), not
        # the 3000 summed over the three list sizes.
        self.assertEqual(by_words["units"], 30)
        self.assertEqual(by_words["source_mean_words"], 1000.0)


class CliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        d = self.d = Path(self._tmp.name)
        self.man, self.freeze = write_freeze(d, calls=12)
        sel = write_seed_runs(d / "train")
        self.sel = d / "selection3.json"
        self.sel.write_text(json.dumps(sel))
        self.rows = ["L2/sel/model-s1000@1", "L2/rep1/model-s1000@1", "L2/rep2/model-s1000@1"]
        self.ev = d / "eval"
        self.ev.mkdir()
        self.ps = self.ev / "per_session.jsonl"
        from learned_bias.provenance import sha256_file

        (self.ev / "results.json").write_text(json.dumps({"parity_failures": [], "df_source": {"earnings21": {
            "split": "scored", "manifests": [{"path": str(self.man), "sha256": sha256_file(self.man)}]}}}))

    def tearDown(self):
        self._tmp.cleanup()

    def write_ps(self, new=95):
        rows = {r: (lambda i, z, n=new: n) for r in self.rows}
        rows[REF] = lambda i, z: 100
        self.ps.write_text("".join(json.dumps(r) + "\n" for r in build(rows, sessions=12).records.values()))

    def run_(self, *extra):
        out = self.d / "e21.json"
        rc = a3.main(["earnings21", "--per-session", str(self.ps), "--new", ",".join(self.rows), "--ref", REF,
                      "--selection", str(self.sel), "--freeze", str(self.freeze), "--runs-root",
                      str(self.d / "train"), "--out", str(out), *extra])
        self.assertEqual(rc, 0)
        return json.loads(out.read_text())

    def test_earnings21_command(self):
        self.write_ps(95)
        v = self.run_()
        self.assertEqual(v["verdict"], "supported")
        self.assertEqual(v["frozen_calls"], 12)
        self.write_ps(103)
        self.assertEqual(self.run_()["verdict"], "not supported")

    def test_aborted_evaluations_still_get_the_registered_verdict(self):
        # Review finding 5: no per-session output at all.
        v = self.run_()
        self.assertEqual((v["verdict"], v["incomplete"]), ("not supported", True))
        v = self.run_("--parity-failed")
        self.assertEqual((v["verdict"], v["reason"]), ("not supported", "a parity check failed"))
        self.sel.write_text(json.dumps(dict(json.loads(self.sel.read_text()), baseline_fallback=True)))
        self.assertIn("baseline", self.run_()["reason"])
        self.sel.write_text("not json")
        self.assertEqual(self.run_()["verdict"], "not supported")
        # Output present but results.json missing.
        self.sel.write_text(json.dumps(write_seed_runs(self.d / "train")))
        self.write_ps(95)
        (self.ev / "results.json").unlink()
        self.assertEqual(self.run_()["verdict"], "not supported")

    def test_seed_rows_from_the_cli(self):
        self.write_ps(95)
        out = self.d / "e21.json"
        a3.main(["earnings21", "--per-session", str(self.ps), "--new", ",".join([self.rows[0]] * 2 + self.rows[1:]),
                 "--ref", REF, "--selection", str(self.sel), "--freeze", str(self.freeze), "--runs-root",
                 str(self.d / "train"), "--out", str(out)])
        self.assertEqual(json.loads(out.read_text())["verdict"], "not supported")

    def test_selection_is_required(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            a3.main(["earnings21", "--per-session", str(self.ps), "--new", ",".join(self.rows), "--ref", REF,
                     "--out", str(self.d / "x.json")])

    def test_malformed_metadata_gets_the_registered_verdict(self):
        # Re-check finding 9: Codex's two cases, plus malformed results and
        # per-session data.
        self.write_ps(95)
        (self.d / "train" / "rep1" / "run.json").write_text('{"args": {"batch"')  # truncated
        v = self.run_()
        self.assertEqual((v["verdict"], v["incomplete"]), ("not supported", True))
        self.assertIn("rep1", v["reason"])
        write_seed_runs(self.d / "train")
        self.sel.write_text("[]")
        v = self.run_()
        self.assertEqual(v["verdict"], "not supported")
        self.sel.write_text(json.dumps(write_seed_runs(self.d / "train")))
        (self.ev / "results.json").write_text("[1, 2]")
        self.assertEqual(self.run_()["verdict"], "not supported")
        (self.ev / "results.json").write_text("{")
        self.assertEqual(self.run_()["verdict"], "not supported")
        self.ps.write_text("[]\n")
        self.assertEqual(self.run_()["verdict"], "not supported")
        self.ps.write_text("{\n")
        self.assertEqual(self.run_()["verdict"], "not supported")

    def test_nested_malformed_run_json_gets_the_registered_verdict(self):
        # Final check #9: wrong types inside an otherwise valid run.json.
        self.write_ps(95)
        cases = {
            "checkpoints": {"checkpoints": 1},
            "args": {"args": [1]},
            "args.call_fraction": {"args": {"call_fraction": None}},
            "train_seed": {"train_seed": None},
        }
        for name, change in cases.items():
            for run in ("rep1", "sel"):
                path = self.d / "train" / run / "run.json"
                info = json.loads(path.read_text())
                if name == "args.call_fraction":
                    info["args"].update(change["args"])
                else:
                    info.update(change)
                path.write_text(json.dumps(info))
                v = self.run_()
                self.assertEqual((v["verdict"], v["incomplete"]), ("not supported", True), (name, run))
                write_seed_runs(self.d / "train")

    def test_results_manifest_list_must_be_exactly_the_frozen_one(self):
        # Final check: a non-object entry next to the frozen one is refused.
        self.write_ps(95)
        res = json.loads((self.ev / "results.json").read_text())
        man = res["df_source"]["earnings21"]["manifests"]
        for bad in (man + [42], man + man, [], [man[0]["sha256"]], {"sha256": man[0]["sha256"]}):
            res["df_source"]["earnings21"]["manifests"] = bad
            (self.ev / "results.json").write_text(json.dumps(res))
            self.assertEqual(self.run_()["verdict"], "not supported", bad)
        res["df_source"]["earnings21"]["manifests"] = man
        (self.ev / "results.json").write_text(json.dumps(res))
        self.assertEqual(self.run_()["verdict"], "supported")

    def test_a_reference_count_mismatch_aborts_without_a_verdict(self):
        self.write_ps(95)
        rc = self.freeze.with_name(a3.RUST_COUNTS_NAME)
        obj = json.loads(rc.read_text())
        obj["sessions"][0]["ref_words"] += 1
        obj["ref_words"] += 1
        rc.write_text(json.dumps(obj))
        out = self.d / "e21.json"
        with contextlib.redirect_stderr(io.StringIO()) as err:
            rc_ = a3.main(["earnings21", "--per-session", str(self.ps), "--new", ",".join(self.rows), "--ref", REF,
                           "--selection", str(self.sel), "--freeze", str(self.freeze), "--runs-root",
                           str(self.d / "train"), "--out", str(out)])
        self.assertEqual(rc_, 2)
        self.assertFalse(out.exists())
        self.assertIn("pipeline error", err.getvalue())
        rc.unlink()
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(a3.main(["earnings21", "--per-session", str(self.ps), "--new", ",".join(self.rows),
                                      "--ref", REF, "--selection", str(self.sel), "--freeze", str(self.freeze),
                                      "--runs-root", str(self.d / "train"), "--out", str(out)]), 2)
        self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
