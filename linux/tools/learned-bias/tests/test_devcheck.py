import copy
import json
import math
import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import torch

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias.devcheck import (
    DevCheckError,
    check_run,
    model_id,
    revalidate,
    run_dev_check,
    select,
    validate_command,
    validate_results,
)
from learned_bias.model import BiasModel, export_model

from tests.helpers import (
    DEV_SET_FLAGS,
    RESULTS_FIXTURE,
    coverage_for,
    fake_eval,
    fixture_train_df,
    results_for,
    rust_results,
    write_json,
)

PY = shlex.quote(sys.executable)
GOOD = (f"{PY} --export E --sets dev --no-l0 --threads 16 {DEV_SET_FLAGS} --learned {{model}} "
        f"--out /tmp/x/{{run}} --lambdas 0.5,0.71,1,1.41,2")
# R1's final template with its *_MANIFEST/*_CASED tokens replaced.
R1_TEMPLATE = (
    "{py} --export /e --cache /c --group-cache /g --out /w/eval/{{run}} --sets dev --no-l0 --threads 16 "
    "--session /e22.json:/test_earnings22.jsonl --rare-words /r.txt --common-words /c.txt "
    "--libri-dev /ldo.jsonl --spgi-dev /spgi.jsonl "
    "--set dev:slidespeech_dev:{sd}:dataset=slidespeech,cased={sc},df={st} "
    "--set dev:icsi_dev:{idv}:dataset=icsi,cased={ic},df={it} "
    "--set dev:acl6060_dev:{ad}:dataset=acl6060,cased={ac},df=scored --learned {{model}}"
)


def r1_template(**tok):
    vals = dict(py=PY, sd="/s/dev.jsonl", sc="true", st="/s/train.jsonl", idv="/i/dev.jsonl", ic="false",
                it="/i/train.jsonl", ad="/a/dev.jsonl", ac="true")
    vals.update(tok)
    return R1_TEMPLATE.format(**vals)


class CommandValidationTests(unittest.TestCase):
    def test_accepts_a_full_dev_evaluation(self):
        validate_command(GOOD)
        validate_command(GOOD.replace(" --lambdas 0.5,0.71,1,1.41,2", ""))  # default grid
        validate_command(r1_template())
        validate_command(GOOD + " --seed 20261011 --l0 1.414,3,off,on --costs --hyps")

    def test_rejects_missing_or_smoke_commands(self):
        bad = {
            "": "required",
            GOOD.replace("--sets dev", "--sets both"): "--sets",
            GOOD.replace("--sets dev", "--sets heldout"): "--sets",
            GOOD.replace("--learned {model}", "--learned {model}@1.0"): "--learned",
            GOOD.replace("--learned {model}", "--learned {model}@meta"): "--learned",
            GOOD.replace("--learned {model}", "--learned random:L3"): "--learned",
            GOOD.replace("/tmp/x/{run}", "/tmp/x/fixed"): "--out",
            GOOD.replace("0.5,0.71,1,1.41,2", "1"): "--lambdas",
            GOOD + " --limit 50": "smoke flag",
            GOOD + " --sizes 100": "smoke flag",
            GOOD + " --dev-subset 600": "smoke flag",
            GOOD + " --allow-partial-dev": "smoke flag",
            GOOD + " --seed 7": "--seed",
            GOOD + " --l0 2,3,off,on": "--l0",
            GOOD.replace(PY, "/nonexistent/lf-bias-eval"): "not found",
            r1_template(sd="SLIDESPEECH_DEV_MANIFEST"): "unreplaced template token",
            r1_template(ic="ICSI_CASED"): "unreplaced template token",
            # --set dataset= and DF modes (R1's frozen datasets).
            r1_template().replace("dataset=icsi,", ""): "dataset=None",
            r1_template().replace("dataset=icsi,", "dataset=ami,"): "dataset='ami'",
            r1_template().replace("dataset=icsi,", "dataset=slidespeech,"): "not the frozen dev domain",
            r1_template(it="scored"): "df= must name its train manifest",
            r1_template().replace("df=scored", "df=/a/train.jsonl"): "df= must be 'scored'",
            r1_template().replace("--set dev:acl6060_dev:", "--set heldout:acl6060_dev:"): "role 'heldout'",
            r1_template() + " --set dev:gigaspeech_dev:/g.jsonl:dataset=gigaspeech,df=scored":
                "not the frozen dev domain",
            r1_template().replace("--session /e22.json:/test_earnings22.jsonl ", ""): "exactly once",
            r1_template() + " --set dev:icsi_dev:/i/dev2.jsonl:dataset=icsi,cased=false,df=/i/train.jsonl":
                "exactly once",
        }
        for cmd, needle in bad.items():
            with self.assertRaises(DevCheckError, msg=cmd) as cm:
                validate_command(cmd)
            self.assertIn(needle, str(cm.exception), cmd)


class ResultValidationTests(unittest.TestCase):
    M = "/x/run/model-e1.0.safetensors"
    ID = "L3/run/model-e1.0"

    def ok(self, data, train_df=None):
        return validate_results(data, self.M, self.ID, fixture_train_df() if train_df is None else train_df)

    def test_rust_fixture_is_accepted_as_written(self):
        # Second re-review #1: R1's production serializer output, unmodified.
        self.assertTrue(RESULTS_FIXTURE.exists(), RESULTS_FIXTURE)
        r = rust_results()
        e = r["learned"][0]
        v = validate_results(r, e["model"], e["id"], fixture_train_df())
        want = {b["lambda"]: b["dev_objective"] for b in e["by_lambda"][1:]}
        self.assertEqual(v["objectives"], want)
        self.assertEqual(v["model_id"], e["id"])
        # Without eval_table_sha256 on a match (the defect Codex found), it fails.
        bad = rust_results()
        del bad["df_source"]["icsi_dev"]["prep_index"]["eval_table_sha256"]
        with self.assertRaises(DevCheckError):
            validate_results(bad, e["model"], e["id"], fixture_train_df())

    def test_dev_other_identity_is_frozen(self):
        # Second re-review #2: another manifest or another selection of 600.
        def edit(fn):
            r = results_for(self.M, self.ID)
            fn(r["spec"])
            return r

        cases = {
            "test-other manifest": edit(lambda s: s["dev_other"].update(manifest="librispeech_test_other.jsonl")),
            "manifest bytes": edit(lambda s: s["dev_other"].update(manifest_sha256="0" * 64)),
            "frozen manifest": edit(lambda s: s["dev_other"].update(frozen_manifest_sha256="0" * 64)),
            "other ids": edit(lambda s: s["dev_other"].update(ids_sha256="1" * 64)),
            "frozen ids": edit(lambda s: s["dev_other"].update(frozen_ids_sha256="1" * 64)),
            "selected": edit(lambda s: s["dev_other"].update(selected=599)),
            "selected as float": edit(lambda s: s["dev_other"].update(selected=600.0)),
            "extra field": edit(lambda s: s["dev_other"].update(note="x")),
            "missing": edit(lambda s: s.pop("dev_other")),
        }
        for name, data in cases.items():
            with self.assertRaises(DevCheckError, msg=name):
                self.ok(data)

    def test_valid_result(self):
        v = self.ok(results_for(self.M, self.ID))
        self.assertEqual(v["objectives"], {0.5: 0.99, 0.71: 0.98, 1.0: 0.97, 1.41: 0.985, 2.0: 0.995})
        self.assertEqual((v["model_id"], v["baseline"]), (self.ID, 1.0))
        # Baseline selected by R1 when nothing beats it (row baseline@0).
        r = results_for(self.M, self.ID, objectives=(1.0, 1.1, 1.2, 1.3, 1.4))
        self.assertEqual(r["dev_objective_row"]["row"], "baseline@0")
        self.ok(r)

    def test_df_source_is_bound_to_the_training_tables(self):
        R = lambda **kw: results_for(self.M, self.ID, **kw)  # noqa: E731

        def edit(fn):
            r = R()
            fn(r)
            return r

        cases = {
            "prep_index mismatch": edit(lambda r: r["df_source"]["icsi_dev"]["prep_index"].update(status="mismatch")),
            "prep_index absent": edit(lambda r: r["df_source"]["icsi_dev"].update(prep_index={"status": "absent"})),
            "no prep_index": edit(lambda r: r["df_source"]["icsi_dev"].pop("prep_index")),
            "hashes disagree": edit(lambda r: r["df_source"]["icsi_dev"]["prep_index"].update(
                eval_table_sha256="f" * 64)),
            "scored DF for a train dataset": edit(lambda r: r["df_source"]["icsi_dev"].update(split="scored")),
            "train DF for acl6060": edit(lambda r: r["df_source"]["acl6060_dev"].update(split="train")),
            "missing spgispeech": edit(lambda r: r["df_source"].pop("spgispeech_dev")),
            "unknown dataset": edit(lambda r: r["df_source"]["icsi_dev"].update(dataset="ami")),
            "no df_source": {k: v for k, v in R().items() if k != "df_source"},
            # Evaluation's table is internally consistent but not the training one.
            "another train table": R(df_table="f" * 64),
        }
        for name, data in cases.items():
            with self.assertRaises(DevCheckError, msg=name):
                self.ok(data)
        with self.assertRaises(DevCheckError):
            self.ok(R(), train_df=dict(fixture_train_df(), icsi="0" * 64))

    def test_rejections(self):
        R = lambda **kw: results_for(self.M, self.ID, **kw)  # noqa: E731
        doms = R()["dev_domains_present"]

        def edit(fn):
            r = R()
            fn(r)
            return r

        other = results_for("/x/other/model-e1.0.safetensors", "L3/other/model-e1.0")
        cases = {
            "wrong format": R(format="lf-bias-eval experiment 2 v1"),
            "ineligible": R(eligible_for_selection=False, ineligible_reasons=["--limit"]),
            "reasons while eligible": R(ineligible_reasons=["x"]),
            "no eligibility field": {k: v for k, v in R().items() if k != "eligible_for_selection"},
            "partial": R(partial=True),
            "limited": R(limit=20),
            "parity failure": R(parity_failures=["baseline mismatch"]),
            "missing domain": R(dev_domains_present=doms[:-1]),
            "duplicate domain": R(dev_domains_present=doms[:-1] + [doms[0]]),
            "spec sets": edit(lambda r: r["spec"].update(sets="both")),
            "spec seed": edit(lambda r: r["spec"].update(seed=7)),
            "spec dev subset": edit(lambda r: r["spec"].update(dev_subset=100)),
            "spec dev subset flag": edit(lambda r: r["spec"].update(dev_subset_flag=600)),
            "spec sizes flag": edit(lambda r: r["spec"].update(sizes_flag=[100])),
            "spec partial": edit(lambda r: r["spec"].update(allow_partial_dev=True)),
            "spec lambdas": edit(lambda r: r["spec"].update(lambdas=[1.0])),
            "spec domain sizes": edit(lambda r: r["spec"]["domains"][0].update(sizes=[100])),
            "spec domain twice": edit(lambda r: r["spec"]["domains"].append(copy.deepcopy(r["spec"]["domains"][0]))),
            "spec two models": edit(lambda r: r["spec"]["models"].append(other["spec"]["models"][0])),
            "spec other source": edit(lambda r: r["spec"]["models"][0].update(source="/x/other.safetensors")),
            "no spec": {k: v for k, v in R().items() if k != "spec"},
            "other model": R(learned=other["learned"]),
            "two models": R(learned=R()["learned"] + other["learned"]),
            "other id": edit(lambda r: r["learned"][0].update(id="L1/run/model-e1.0")),
            "no fallback row": edit(lambda r: r["learned"][0]["by_lambda"].pop(0)),
            "non-finite": R(objectives=(0.9, math.nan, 0.9, 0.9, 0.9)),
            "null objective": R(objectives=(0.9, None, 0.9, 0.9, 0.9)),
            "missing λ": R(objectives=(0.9, 0.9, 0.9, 0.9)),
            "bad baseline": R(baseline_dev_objective=0.8),
            "row disagrees": edit(lambda r: r.update(dev_objective_row={"model": "baseline", "lambda": 0.0,
                                                                         "fallback": True}, dev_objective=1.0)),
            "objective disagrees": R(dev_objective=0.5),
            # Coverage (re-review #5).
            "dev-other undersized": R(domains=[dict(d, utterances=1) if d["name"] == "librispeech_dev_other_600"
                                               else d for d in coverage_for()]),
            "zero groups": R(domains=[dict(d, groups=0) for d in coverage_for()]),
            "no utterances field": R(domains=[{k: v for k, v in d.items() if k != "utterances"}
                                              for d in coverage_for()]),
            "sets summary disagrees": R(sets=[dict(d, role="tune", utterances=11) for d in coverage_for()]),
            # Cross-field consistency (re-review #5, #8).
            "model lambdas": edit(lambda r: r["spec"]["models"][0].update(lambdas=[0.5, 1.0])),
            "model variant": edit(lambda r: r["spec"]["models"][0].update(variant="L1")),
            "learned variant": edit(lambda r: r["learned"][0].update(variant="L2")),
            "learned label": edit(lambda r: r["learned"][0].update(label="L3/run/model-e0.5")),
            "f64 row id": edit(lambda r: r["learned"][0]["by_lambda"][2].update(row=f"{self.ID}@0.7099999785423279")),
            "row of another model": edit(lambda r: r["learned"][0]["by_lambda"][3].update(row="L3/x/m@1")),
            "rows out of order": edit(lambda r: r["learned"][0]["by_lambda"].insert(
                1, r["learned"][0]["by_lambda"].pop(2))),
            "f64 map key": edit(lambda r: r["dev_objectives_learned"].update(
                {f"{self.ID}@0.7099999785423279": r["dev_objectives_learned"].pop(f"{self.ID}@0.71")})),
            "map without baseline": edit(lambda r: r["dev_objectives_learned"].pop("baseline@0")),
            "map value disagrees": edit(lambda r: r["dev_objectives_learned"].update({f"{self.ID}@1": 0.5})),
            # R1's final row format.
            "f32 lambda": edit(lambda r: r["learned"][0]["by_lambda"][2].update({"lambda": 0.7099999785423279})),
            "f32 spec lambda": edit(lambda r: r["spec"]["lambdas"].__setitem__(1, 0.7099999785423279)),
            "old baseline row id": edit(lambda r: r["learned"][0]["by_lambda"][0].update(row="baseline")),
            "spec rows": edit(lambda r: r["spec"]["models"][0].update(rows=r["spec"]["models"][0]["rows"][:4])),
            "spec rows f64": edit(lambda r: r["spec"]["models"][0]["rows"].__setitem__(
                1, f"{self.ID}@0.7099999785423279")),
            "no spec rows": edit(lambda r: r["spec"]["models"][0].pop("rows")),
            "selected row without row": edit(lambda r: r["dev_objective_row"].pop("row")),
            "selected row id wrong": edit(lambda r: r["dev_objective_row"].update(row=f"{self.ID}@0.5")),
            "dev_subset other than 600": edit(lambda r: r["spec"].update(dev_subset=599)),
            "no map": {k: v for k, v in R().items() if k != "dev_objectives_learned"},
        }
        for name, data in cases.items():
            with self.assertRaises(DevCheckError, msg=name):
                self.ok(data)

    def test_coverage_is_returned(self):
        v = self.ok(results_for(self.M, self.ID))
        self.assertEqual(v["coverage"], sorted(coverage_for(), key=lambda c: c["name"]))
        self.assertEqual(next(c for c in v["coverage"] if c["name"] == "librispeech_dev_other_600")["utterances"],
                         600)

    def test_model_id_is_variant_run_stem(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "L3-c50" / "model-e2.5.safetensors"
            p.parent.mkdir()
            export_model(BiasModel("L3S"), p)
            self.assertEqual(model_id(p), "L3S/L3-c50/model-e2.5")


def rec(ck, objs, coverage="c"):
    return {"model": f"/r/model-{ck}.safetensors", "model_sha256": "s", "model_id": ck, "coverage": coverage,
            "objectives": {repr(l): o for l, o in zip((0.5, 0.71, 1.0, 1.41, 2.0), objs)}}


class SelectionTests(unittest.TestCase):
    def test_picks_the_best_checkpoint_and_lambda(self):
        s = select({"e0.5": rec("e0.5", [0.99] * 5), "e1.0": rec("e1.0", [0.98, 0.95, 0.96, 0.99, 1.1])},
                   ["e0.5", "e1.0"])
        self.assertEqual((s["selected"]["checkpoint"], s["selected"]["lambda"]), ("e1.0", 0.71))
        self.assertFalse(s["baseline_fallback"])
        self.assertEqual(len(s["candidates"]), 11)

    def test_baseline_fallback_when_nothing_beats_it(self):
        s = select({"e0.5": rec("e0.5", [1.01, 1.2, 1.3, 1.4, 1.5])}, ["e0.5"])
        self.assertEqual(s["selected"], {"checkpoint": "baseline", "lambda": 0.0, "objective": 1.0})
        self.assertTrue(s["baseline_fallback"])

    def test_baseline_wins_ties(self):
        s = select({"e0.5": rec("e0.5", [1.0] * 5)}, ["e0.5"])
        self.assertTrue(s["baseline_fallback"])

    def test_every_expected_checkpoint_needs_a_check(self):
        with self.assertRaises(DevCheckError):
            select({"e0.5": rec("e0.5", [0.9] * 5)}, ["e0.5", "e1.0"])

    def test_checkpoints_must_share_coverage(self):
        with self.assertRaises(DevCheckError):
            select({"e0.5": rec("e0.5", [0.9] * 5), "e1.0": rec("e1.0", [0.9] * 5, coverage="other")},
                   ["e0.5", "e1.0"])


class RunCheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.run = self.root / "train" / "L1"
        self.cmd, self.res = fake_eval(self.root)
        self.run.mkdir(parents=True)
        for ck in ("e0.5", "e1.0"):
            export_model(BiasModel("L1"), self.run / f"model-{ck}.safetensors")
        write_json(self.run / "run.json", {"toy": False, "checkpoints": ["e0.5", "e1.0"], "train_df": fixture_train_df()})
        self.count = self.root / "count.txt"
        self.env = mock.patch.dict(os.environ, {"FAKE_EVAL_COUNT": str(self.count)})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self._tmp.cleanup()

    def calls(self):
        return len(self.count.read_text().splitlines()) if self.count.exists() else 0

    def test_checks_selects_and_persists(self):
        sel = check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), 2)
        self.assertEqual((sel["selected"]["checkpoint"], sel["selected"]["lambda"]), ("e0.5", 1.0))
        saved = json.loads((self.run / "selection.json").read_text())
        self.assertEqual(saved["selected"]["checkpoint"], "e0.5")
        self.assertEqual(saved["selected"]["lambda"], 1.0)
        self.assertTrue(saved["selected"]["model"].endswith("model-e0.5.safetensors"))
        self.assertEqual(saved["selected"]["model_id"], "L1/L1/model-e0.5")
        db = json.loads((self.run / "devcheck.json").read_text())
        self.assertEqual(set(db), {"e0.5", "e1.0"})

    def test_cached_records_are_revalidated(self):
        check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), 2)  # valid cache reused
        # A changed model file invalidates its cached check.
        m = BiasModel("L1")
        with torch.no_grad():
            m.l1[2].bias.fill_(0.5)
        export_model(m, self.run / "model-e1.0.safetensors")
        check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), 3)
        # A cached result that no longer validates is re-run.
        db = json.loads((self.run / "devcheck.json").read_text())
        r = Path(db["e0.5"]["results"])
        r.write_text(json.dumps(dict(json.loads(r.read_text()), partial=True)))
        with self.assertRaises(DevCheckError):
            revalidate(db["e0.5"], self.run / "model-e0.5.safetensors", self.cmd)
        check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), 4)

    def test_cached_record_must_be_bound_to_the_requested_checkpoint(self):
        # Re-review #3: an unrelated, internally valid record (another run's
        # checkpoint with its own valid results) filed under tag e0.5.
        other = self.root / "train" / "other"
        other.mkdir()
        export_model(BiasModel("L1"), other / "model-e9.0.safetensors")
        write_json(other / "run.json", {"toy": False, "checkpoints": ["e9.0"], "train_df": fixture_train_df()})
        check_run(other, self.cmd, self.res, log=lambda *_: None)
        foreign = json.loads((other / "devcheck.json").read_text())["e9.0"]
        write_json(self.run / "devcheck.json", {"e0.5": foreign})
        n = self.calls()
        sel = check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), n + 2)  # e0.5 re-evaluated, not taken from the foreign record
        db = json.loads((self.run / "devcheck.json").read_text())
        self.assertEqual(db["e0.5"]["model"], str((self.run / "model-e0.5.safetensors").resolve()))
        self.assertEqual(db["e0.5"]["model_id"], "L1/L1/model-e0.5")
        self.assertNotIn("/train/other/", json.dumps(sel["candidates"]))
        with self.assertRaises(DevCheckError):
            revalidate(foreign, self.run / "model-e0.5.safetensors", self.cmd)
        # Same bytes copied in place under a different id/path still do not bind.
        with self.assertRaises(DevCheckError):
            revalidate(dict(db["e0.5"], model_id="L1/other/model-e9.0"), self.run / "model-e0.5.safetensors",
                       self.cmd)

    def test_cached_record_must_match_the_command(self):
        check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), 2)
        cmd2 = self.cmd + " --threads 8"
        db = json.loads((self.run / "devcheck.json").read_text())
        with self.assertRaises(DevCheckError):
            revalidate(db["e0.5"], self.run / "model-e0.5.safetensors", cmd2)
        check_run(self.run, cmd2, self.res, log=lambda *_: None)
        self.assertEqual(self.calls(), 4)

    def test_coverage_is_bound_to_the_run(self):
        check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        cov = json.loads((self.run / "dev_coverage.json").read_text())
        self.assertEqual(cov["first_checkpoint"], "e0.5")
        self.assertEqual(cov["coverage"], sorted(coverage_for(), key=lambda c: c["name"]))
        # A later check on different coverage is refused.
        with mock.patch.dict(os.environ, {"FAKE_EVAL_UTTS": "11"}), self.assertRaises(DevCheckError):
            check_run(self.run, self.cmd, self.res, force=True, log=lambda *_: None)

    def test_baseline_selected_when_learned_is_worse(self):
        with mock.patch.dict(os.environ, {"FAKE_EVAL_OBJS": "[1.1, 1.2, 1.3, 1.05, 1.01]"}):
            sel = check_run(self.run, self.cmd, self.res, log=lambda *_: None)
        self.assertEqual(sel["selected"]["checkpoint"], "baseline")
        self.assertEqual(json.loads((self.run / "selection.json").read_text())["selected"]["lambda"], 0.0)

    def test_toy_runs_cannot_be_selected(self):
        write_json(self.run / "run.json", {"toy": True, "checkpoints": ["e0.5"]})
        with self.assertRaises(DevCheckError):
            check_run(self.run, self.cmd, self.res, log=lambda *_: None)

    def test_failing_or_silent_eval_is_an_error(self):
        model = self.run / "model-e0.5.safetensors"
        with self.assertRaises(DevCheckError):
            run_dev_check(model, "r", GOOD.replace(PY, f"{PY} -c 'import sys; sys.exit(3)'"), self.res)
        quiet = f"{PY} -c pass --sets dev --learned {{model}} --out {self.root}/eval/{{run}}"
        with self.assertRaises(DevCheckError):
            run_dev_check(model, "r", quiet, self.res)


if __name__ == "__main__":
    unittest.main()
