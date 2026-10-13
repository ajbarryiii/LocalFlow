"""Contract tests for experiment 3's global selection (DESIGN-3 "Training
runs", "Seed replicates"): learned_bias.select3."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import select3
from learned_bias.select3 import FROZEN_PLAN, SelectionError, fixed_lambda, select_global, select_within
from learned_bias.select3 import main as _main

from tests.helpers import coverage_for, make_exp3_run


def main(argv):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return _main(argv)


PLAN = (250, 500)
CMD = "the frozen dev command"
FLAT = (0.99, 0.99, 0.99, 0.99, 0.99)


def flat(x):
    return lambda step: (x,) * 5


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def run_(self, name, objectives=flat(0.99), **kw):
        kw.setdefault("plan", PLAN)
        kw.setdefault("cmd", CMD)
        return make_exp3_run(self.root, name, objectives, **kw)

    def grid(self, **override):
        """The four selectable runs of DESIGN-3 (A1-A3, B) on a short plan."""
        specs = {"A1": dict(lr=1e-3, horizon=6000), "A2": dict(lr=3e-4, horizon=6000),
                 "A3": dict(lr=1e-4, horizon=6000), "B": dict(lr=1e-3, horizon=44228)}
        dirs = []
        for name, spec in specs.items():
            spec = dict(spec, **override.get(name, {}))
            dirs.append(self.run_(name, **spec))
        return dirs


class GlobalSelectionTests(Base):
    def test_frozen_plan(self):
        self.assertEqual(FROZEN_PLAN, (250, 500, 1000, 1500, 2000, 3000, 4000, 6000))

    def test_minimum_over_runs_steps_and_lambdas(self):
        def a2(step):
            return (0.99, 0.96, 0.95, 0.97, 0.99) if step == 500 else FLAT

        dirs = self.grid(A2={"objectives": a2})
        sel = select_global(dirs, CMD, plan=PLAN)
        s = sel["selected"]
        self.assertEqual((s["run"], s["step"], s["lambda"], s["objective"]), ("A2", 500, 1.0, 0.95))
        self.assertEqual((s["lr"], s["horizon_steps"], s["model_id"]), (3e-4, 6000, "L2/A2/model-s500"))
        self.assertFalse(sel["baseline_fallback"])
        self.assertEqual(sel["mode"], "global")
        # The full grid: 4 runs × 2 steps × 5 λ, plus the baseline.
        self.assertEqual(len(sel["candidates"]), 4 * 2 * 5 + 1)
        self.assertEqual(sel["candidates"][0]["run"], "baseline")
        self.assertEqual(sel["coverage"], sorted(coverage_for(), key=lambda c: c["name"]))
        self.assertEqual(len(sel["cmd_sha256"]), 64)

    def test_baseline_fallback_and_baseline_wins_ties(self):
        sel = select_global(self.grid(**{n: {"objectives": flat(1.01)} for n in ("A1", "A2", "A3", "B")}), CMD,
                            plan=PLAN)
        self.assertEqual(sel["selected"]["run"], "baseline")
        self.assertTrue(sel["baseline_fallback"])
        self.assertEqual(sel["selected"]["lambda"], 0.0)
        # The best learned candidate exactly 1.0: the baseline wins the tie.
        all_one = select_global(self.grid(**{n: {"objectives": flat(1.0)} for n in ("A1", "A2", "A3", "B")}),
                                CMD, plan=PLAN)
        self.assertEqual(all_one["selected"]["run"], "baseline")

    def test_ties_go_to_fewer_steps_then_lower_lr(self):
        # The same best objective at A1 s500, A2 s250 and A3 s250: fewer
        # steps first (s250), then the lower lr (A3, 1e-4).
        def at(step_best):
            return lambda step: (0.95,) * 5 if step == step_best else FLAT

        sel = select_global(self.grid(A1={"objectives": at(500)}, A2={"objectives": at(250)},
                                      A3={"objectives": at(250)}), CMD, plan=PLAN)
        self.assertEqual((sel["selected"]["run"], sel["selected"]["step"]), ("A3", 250))
        # Same step and lr (A1 and B, both 1e-3): the documented further
        # order is the --runs order, then λ in grid order.
        sel = select_global(self.grid(A1={"objectives": at(250)}, B={"objectives": at(250)}), CMD, plan=PLAN)
        self.assertEqual((sel["selected"]["run"], sel["selected"]["step"], sel["selected"]["lambda"]),
                         ("A1", 250, 0.5))

    def test_refuses_incomplete_grids(self):
        dirs = self.grid()
        # A missing devcheck record.
        db = json.loads((dirs[1] / "devcheck.json").read_text())
        del db["s500"]
        (dirs[1] / "devcheck.json").write_text(json.dumps(db))
        with self.assertRaises(SelectionError) as cm:
            select_global(dirs, CMD, plan=PLAN)
        self.assertIn("A2", str(cm.exception))
        self.assertIn("s500", str(cm.exception))

    def test_refuses_a_run_without_every_planned_checkpoint(self):
        dirs = self.grid()
        info = json.loads((dirs[2] / "run.json").read_text())
        info["checkpoints"] = ["s250"]
        (dirs[2] / "run.json").write_text(json.dumps(info))
        with self.assertRaises(SelectionError):
            select_global(dirs, CMD, plan=PLAN)
        # Another plan than the requested one.
        with self.assertRaises(SelectionError):
            select_global(self.grid(), CMD, plan=(250, 500, 1000))

    def test_refuses_missing_or_duplicate_runs(self):
        dirs = self.grid()
        with self.assertRaises(SelectionError):
            select_global(dirs + [self.root / "nope"], CMD, plan=PLAN)
        with self.assertRaises(SelectionError):
            select_global(dirs + [dirs[0]], CMD, plan=PLAN)

    def test_refuses_mismatched_coverage(self):
        other = [dict(d, utterances=11) if d["name"] == "icsi_dev" else d for d in coverage_for()]
        dirs = self.grid(B={"coverage": other})
        with self.assertRaises(SelectionError) as cm:
            select_global(dirs, CMD, plan=PLAN)
        self.assertIn("coverage", str(cm.exception))

    def test_refuses_another_dev_command(self):
        dirs = self.grid(A3={"cmd_for": lambda step: "another command" if step == 500 else CMD})
        with self.assertRaises(SelectionError) as cm:
            select_global(dirs, CMD, plan=PLAN)
        self.assertIn("A3", str(cm.exception))

    def test_refuses_an_invalid_result(self):
        dirs = self.grid()
        db = json.loads((dirs[0] / "devcheck.json").read_text())
        res = Path(db["s250"]["results"])
        res.write_text(json.dumps(dict(json.loads(res.read_text()), eligible_for_selection=False)))
        with self.assertRaises(SelectionError):
            select_global(dirs, CMD, plan=PLAN)

    def test_control_c_is_never_a_candidate(self):
        dirs = self.grid()
        c = self.run_("C", objectives=flat(0.5), calls_file={"path": "calls.txt", "sha256": "a" * 64, "calls": 3})
        with self.assertRaises(SelectionError) as cm:
            select_global(dirs + [c], CMD, plan=PLAN)
        self.assertIn("not arms of the registered search", str(cm.exception))
        # A subset in an arm's place, by --calls-file or by --call-fraction.
        for extra in ({"calls_file": {"path": "calls.txt", "sha256": "a" * 64, "calls": 3}},
                      {"args": {"call_fraction": "0.25"}}):
            dirs = self.grid(B={"extra_info": extra})
            with self.assertRaises(SelectionError) as cm:
                select_global(dirs, CMD, plan=PLAN)
            self.assertIn("subset", str(cm.exception))
        with self.assertRaises(SelectionError):
            select_global(self.grid(A1={"toy": True}), CMD, plan=PLAN)

    def test_the_registered_search_is_required(self):
        # Review finding 3: an omitted arm, or one arm alone, is refused.
        dirs = self.grid()
        for subset in (dirs[:3], dirs[:1], [dirs[0], dirs[1], dirs[3]]):
            with self.assertRaises(SelectionError) as cm:
                select_global(subset, CMD, plan=PLAN)
            self.assertIn("the registered search needs arms", str(cm.exception))
        wrong = {
            "lr": {"A2": {"lr": 1e-3}},
            "horizon_steps": {"B": {"horizon": 6000}},
            "variant": {"A3": {"variant": "L1"}},
            "train_seed": {"A1": {"train_seed": 20261012}},
        }
        for needle, override in wrong.items():
            with self.assertRaises(SelectionError, msg=needle) as cm:
                select_global(self.grid(**override), CMD, plan=PLAN)
            self.assertIn(needle, str(cm.exception))
        # The CLI has no way around the frozen plan and arms.
        out = self.root / "sel.json"
        rc = main(["--runs", "A1,A2,A3", "--root", str(self.root), "--cmd", CMD, "--out", str(out)])
        self.assertEqual(rc, 1)
        self.assertFalse(out.exists())

    def test_written_selection_file(self):
        self.grid()
        out = self.root / "selection3.json"
        with mock.patch.object(select3, "FROZEN_PLAN", PLAN):  # a short plan stands in for the frozen one
            rc = main(["--runs", "A1,A2,A3,B", "--root", str(self.root), "--cmd", CMD, "--out", str(out)])
            self.assertEqual(rc, 0)
            sel = json.loads(out.read_text())
            self.assertEqual(sel["mode"], "global")
            self.assertEqual(sel["runs"], ["A1", "A2", "A3", "B"])
            self.assertEqual(sel["plan"], [250, 500])
            # A refusal writes nothing and exits non-zero.
            out.unlink()
            rc = main(["--runs", "A1,A2,A3,B,Z", "--root", str(self.root), "--cmd", CMD, "--out", str(out)])
            self.assertEqual(rc, 1)
            self.assertFalse(out.exists())
        # With the real frozen plan these 2-checkpoint runs are incomplete.
        rc = main(["--runs", "A1,A2,A3,B", "--root", str(self.root), "--cmd", CMD, "--out", str(out)])
        self.assertEqual(rc, 1)


class WithinRunTests(Base):
    def test_within_run_reports_a_controls_best(self):
        c = self.run_("C", objectives=lambda s: (0.98, 0.97, 0.99, 1.0, 1.0) if s == 500 else FLAT,
                      calls_file={"path": "calls.txt", "sha256": "a" * 64, "calls": 3})
        sel = select_within(c, CMD, plan=PLAN)
        self.assertEqual(sel["mode"], "within_run")
        self.assertTrue(sel["control"])
        self.assertEqual(sel["subset"], "calls-file")
        self.assertEqual((sel["selected"]["step"], sel["selected"]["lambda"]), (500, 0.71))
        f = self.run_("F", extra_info={"args": {"call_fraction": "0.25"}})
        self.assertEqual(select_within(f, CMD, plan=PLAN)["subset"], "call-fraction")


class FixedLambdaTests(Base):
    def test_reports_the_frozen_lambdas_objective_not_a_minimum(self):
        r1 = self.run_("R1", objectives=lambda s: (0.90, 0.91, 0.96, 0.92, 0.93), plan=(1000,), train_seed=20261012)
        r2 = self.run_("R2", objectives=lambda s: (0.80, 0.81, 0.98, 0.82, 0.83), plan=(1000,), train_seed=20261013)
        sel = fixed_lambda([r1, r2], CMD, 1.0)
        self.assertEqual(sel["mode"], "fixed_lambda")
        self.assertTrue(sel["fixed"])
        self.assertEqual(sel["lambda"], 1.0)
        rows = {(r["run"], r["step"]): r["objective"] for r in sel["rows"]}
        self.assertEqual(rows, {("R1", 1000): 0.96, ("R2", 1000): 0.98})
        self.assertNotIn("selected", sel)
        self.assertEqual(sel["summary"]["mean"], 0.97)
        self.assertEqual((sel["summary"]["min"], sel["summary"]["max"]), (0.96, 0.98))
        self.assertEqual({r["train_seed"] for r in sel["rows"]}, {20261012, 20261013})

    def test_lambda_must_be_on_the_grid(self):
        r1 = self.run_("R1", plan=(1000,))
        with self.assertRaises(SelectionError):
            fixed_lambda([r1], CMD, 0.8)

    def test_cli_fixed_mode(self):
        self.run_("R1", plan=(1000,))
        out = self.root / "rep.json"
        rc = main(["--runs", "R1", "--root", str(self.root), "--cmd", CMD, "--fixed-lambda", "1",
                   "--out", str(out)])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.read_text())["mode"], "fixed_lambda")


if __name__ == "__main__":
    unittest.main()
