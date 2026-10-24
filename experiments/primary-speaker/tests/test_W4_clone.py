"""W4 cloning-stage statistics and helpers on synthetic scores (no audio)."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.protect import clone_exp
from lfspk.protect.data import DevSet

FUSION = {"fusion": {r: {"alpha": 0.5} for r in clone_exp.ROUTES}}


def write_invert(root: Path, emb: str, rows: dict[str, tuple[float, float]]) -> None:
    """Synthetic inversion outputs: summary.tsv rounded to 4 decimals (as
    invert_exp writes it) and per-protection JSON with the exact values."""
    import json

    (root / emb).mkdir(parents=True, exist_ok=True)
    lines = ["protection\teer_crop_k10\tmindcf"]
    for name, (eer, dcf) in rows.items():
        lines.append(f"{name}\t{eer:.4f}\t{dcf:.4f}")
        (root / emb / f"{name}.json").write_text(json.dumps(
            {"protection": name, "utility": {"k10_crop": {"all": {"eer": eer, "mindcf": dcf}}}}))
    (root / emb / "summary.tsv").write_text("\n".join(lines) + "\n")


def fake_scores(path: Path, n: int = 73, seed: int = 0, raw_level: float = 0.8, prot_level: float = 0.0,
                split: str = "dev", id0: int = 0, real_shift: float = 0.0, external_partners: bool = False):
    """Real trials: 10 genuine per speaker ~ N(0.7, .1) and 10 random impostor
    trials ~ N(0.1, .1). Clips score like genuine with probability `level`
    (per condition), else like impostors. Wrong-person controls: level 0."""
    rng = np.random.default_rng(seed)
    prepared = {"emb": ({"protections": {"raw": FUSION, "prot": FUSION}}, {})}
    conds = clone_exp.conditions(prepared)
    level = {}
    for c, _, _ in conds:
        level[c] = 0.0
        if c in ("audio-10s", "audio-3s", "se-centroid"):
            level[c] = 0.9
        if c.startswith("emb/raw|") or c.startswith("emb/audio-3s+"):
            level[c] = raw_level
        if c.startswith("emb/prot|"):
            level[c] = prot_level
        if c.endswith("|other"):
            level[c] = 0.0
    arrays = {}
    for v in clone_exp.VERIFIERS:
        S = np.zeros((len(conds), n, clone_exp.N_ATTEMPTS), dtype=np.float32)
        for ci, (c, _, _) in enumerate(conds):
            good = rng.random((n, clone_exp.N_ATTEMPTS)) < level[c]
            S[ci] = np.where(good, rng.normal(0.7, 0.1, good.shape), rng.normal(0.1, 0.1, good.shape))
        oth = np.concatenate([np.arange(n).repeat(10), np.repeat(np.arange(n), 10)[rng.permutation(n * 10)]])
        own = np.concatenate([np.arange(n).repeat(10), rng.integers(0, n, n * 10)])
        sc = np.where(own == oth, rng.normal(0.7, 0.1, own.size), rng.normal(0.1, 0.1, own.size)) + real_shift
        arrays.update({f"scores_{v}": S, f"real_owner_{v}": own, f"real_other_{v}": oth, f"real_score_{v}": sc})
    np.savez(path / f"scores-{split}.npz", conds=np.array([c for c, _, _ in conds]),
             kinds=np.array([k for _, k, _ in conds]),
             speakers=np.array([str(id0 + i) for i in range(n)]),
             partner=np.full(n, -1) if external_partners else (np.arange(n) + 1) % n, **arrays)


class CloneStatsTest(unittest.TestCase):
    def test_raw_risky_and_null_protection_resolves_to_low_at_best(self):
        with tempfile.TemporaryDirectory() as d:
            fake_scores(Path(d))
            res = clone_exp.stats(Path(d), n_boot=100, ledger=Path(d) / "no-ledger.jsonl")
            for v in clone_exp.VERIFIERS:
                p = res["splits"]["dev"]["verifiers"][v]["protections"]
                self.assertTrue(p["emb/raw"]["powered"])
                self.assertEqual(p["emb/raw"]["tier"], "high")
                # a null protection: no vulnerable target; with 73 targets the
                # betting bound cannot go below ~0.064, so the tier is "moderate"
                self.assertEqual(p["emb/prot"]["vulnerable"]["targets"], 0)
                self.assertGreater(p["emb/prot"]["vulnerable"]["any_success_targets"], 10)
                self.assertGreater(p["emb/prot"]["risk_upper"], 0.05)
                self.assertEqual(p["emb/prot"]["tier"], "moderate")
                e = p["emb/raw"]["far0.01"]
                d_ = e["accept"]["delta_vs_floor"]
                self.assertLessEqual(d_["lo"], d_["mean"])
                self.assertLessEqual(d_["mean"], d_["hi"])
                w = [e[f"within{k}"]["envelope"]["mean"] for k in clone_exp.KS_ATTEMPTS]
                self.assertEqual(w, sorted(w))
                self.assertGreaterEqual(e["worst_decile"]["envelope"]["mean"] + 1e-12, e["accept"]["envelope"]["mean"])
                self.assertAlmostEqual(e["within1"]["envelope"]["mean"], e["accept"]["envelope"]["mean"])
                for r in clone_exp.ROUTES:
                    acc = res["splits"]["dev"]["verifiers"][v]["conditions"][f"emb/raw|{r}"]["far0.01"]["accept"]["mean"]
                    self.assertGreaterEqual(e["accept"]["envelope"]["mean"] + 1e-12, acc)
                    self.assertIn(r, e["per_route_delta_matched"])
                self.assertIn("far0.001", p["emb/raw"])
            self.assertEqual(res["splits"]["dev"]["tiers_by_protection"]["emb/raw"]["tier"], "high")
            self.assertEqual(res["splits"]["dev"]["tiers_by_protection"]["emb/prot"]["tier"], "moderate")
            self.assertEqual(res["splits"]["dev"]["tiers_by_protection"]["emb/prot"]["coverage"], "2 of 2 verifiers powered")

    def test_invert_r4_counterexample_reads_high(self):
        # 97 % accept 2/20 and 3 % accept 4/20 on every route, floor 0. The
        # unlucky sample (no 4/20 target drawn) must still bound above 0.10.
        with tempfile.TemporaryDirectory() as d:
            fake_scores(Path(d))
            z = dict(np.load(Path(d) / "scores-dev.npz"))
            conds = [str(c) for c in z["conds"]]
            for v in clone_exp.VERIFIERS:
                S = z[f"scores_{v}"]
                for c in conds:
                    if c.startswith("emb/prot|") or c == "emb/other-raw":
                        k = conds.index(c)
                        S[k] = -1.0  # never accepted
                        if not c.endswith("|other") and c != "emb/other-raw":
                            S[k, :, :2] = 2.0  # exactly 2 of 20 accepted for every target
            np.savez(Path(d) / "scores-dev.npz", **z)
            res = clone_exp.stats(Path(d), n_boot=50, ledger=Path(d) / "no-ledger.jsonl")
            for v in clone_exp.VERIFIERS:
                p = res["splits"]["dev"]["verifiers"][v]["protections"]["emb/prot"]
                self.assertGreaterEqual(p["risk_upper"], 0.10)
                self.assertEqual(p["tier"], "high")

    def test_fully_vulnerable_minority_is_caught(self):
        # invert-r3 #1: 3 % fully vulnerable speakers must not read as negligible
        with tempfile.TemporaryDirectory() as d:
            fake_scores(Path(d))
            z = dict(np.load(Path(d) / "scores-dev.npz"))
            conds = [str(c) for c in z["conds"]]
            for v in clone_exp.VERIFIERS:
                S = z[f"scores_{v}"]
                for r in clone_exp.ROUTES:
                    S[conds.index(f"emb/prot|{r}"), :2] = 0.9  # 2 of 73 targets always accepted
            np.savez(Path(d) / "scores-dev.npz", **z)
            res = clone_exp.stats(Path(d), n_boot=50, ledger=Path(d) / "no-ledger.jsonl")
            for v in clone_exp.VERIFIERS:
                p = res["splits"]["dev"]["verifiers"][v]["protections"]["emb/prot"]
                self.assertEqual(p["vulnerable"]["targets"], 2)
                self.assertIn(p["tier"], ("moderate", "high"))

    def test_clone_eval_headline_with_dev_thresholds(self):
        with tempfile.TemporaryDirectory() as d:
            fake_scores(Path(d))
            # clone_eval: 251 targets, external (train) partners, and real trials
            # shifted by +0.5, which must not move its thresholds
            fake_scores(Path(d), n=251, seed=1, split="clone_eval", id0=10000, real_shift=0.5,
                        external_partners=True)
            res = clone_exp.stats(Path(d), n_boot=30, ledger=Path(d) / "no-ledger.jsonl")
            self.assertEqual(res["headline"], "clone_eval")
            self.assertIn("exploratory", res["splits"]["dev"]["status"])
            self.assertNotIn("pooled", res)
            for v in clone_exp.VERIFIERS:
                dev_t = res["splits"]["dev"]["verifiers"][v]["thresholds"]["0.01"]["mean"]
                ce = res["splits"]["clone_eval"]["verifiers"][v]["thresholds"]["0.01"]
                self.assertEqual(ce["mean"], dev_t)
                self.assertEqual(ce["lo"], ce["hi"])  # fixed, not resampled
                b = res["splits"]["clone_eval"]["verifiers"][v]["protections"]["emb/prot"]["wsr"]["point"]
                self.assertEqual(b["n"], 251)
                b_dev = res["splits"]["dev"]["verifiers"][v]["protections"]["emb/prot"]["wsr"]["point"]
                self.assertLess(b["vs_primary"], b_dev["vs_primary"])
            self.assertIs(res["tiers_by_protection"], res["splits"]["clone_eval"]["tiers_by_protection"])
            self.assertEqual(res["tiers_by_protection"]["emb/raw"]["tier"], "high")
            self.assertIn(res["tiers_by_protection"]["emb/prot"]["tier"], ("negligible", "low"))
            agg = res["tiers_by_protection"]["emb/prot"]
            self.assertIn("dev-calibrated nominal 1 % FAR threshold", agg["label"])
            self.assertTrue(agg["label"].startswith("excess over the training-speaker baseline"))
            self.assertIn("exploratory", res["splits"]["dev"]["tiers_by_protection"]["emb/prot"]["label"])
            for v in clone_exp.VERIFIERS:
                # clone_eval real trials were shifted +0.5, so the achieved FAR is far above 1 %
                self.assertGreater(agg["achieved_far_by_verifier"][v], 0.5)
                self.assertGreaterEqual(agg["upper_a_by_verifier"][v], agg["risk_upper_by_verifier"][v] - 1e-12)

    def test_bound_uses_seeded_order_not_listing_order(self):
        with tempfile.TemporaryDirectory() as d:
            fake_scores(Path(d))
            r1 = clone_exp.stats(Path(d), n_boot=10, ledger=Path(d) / "no-ledger.jsonl")
            z = dict(np.load(Path(d) / "scores-dev.npz"))
            perm = np.random.default_rng(5).permutation(73)
            inv = np.argsort(perm)
            for k in list(z):
                if k.startswith("scores_"):
                    z[k] = z[k][:, perm]
            z["speakers"] = z["speakers"][perm]
            z["partner"] = inv[z["partner"][perm]]
            for v in clone_exp.VERIFIERS:
                z[f"real_owner_{v}"] = inv[z[f"real_owner_{v}"]]
                z[f"real_other_{v}"] = inv[z[f"real_other_{v}"]]
            np.savez(Path(d) / "scores-dev.npz", **z)
            r2 = clone_exp.stats(Path(d), n_boot=10, ledger=Path(d) / "no-ledger.jsonl")
            for v in clone_exp.VERIFIERS:
                p1 = r1["splits"]["dev"]["verifiers"][v]["protections"]["emb/prot"]["wsr"]["point"]
                p2 = r2["splits"]["dev"]["verifiers"][v]["protections"]["emb/prot"]["wsr"]["point"]
                self.assertAlmostEqual(p1["vs_primary"], p2["vs_primary"], places=9)

    def test_failed_power_check_withholds_tiers(self):
        # review clone-r1 #1: ineffective raw attacks -> no tier for protections
        with tempfile.TemporaryDirectory() as d:
            fake_scores(Path(d), raw_level=0.0)
            res = clone_exp.stats(Path(d), n_boot=50, ledger=Path(d) / "no-ledger.jsonl")
            for v in clone_exp.VERIFIERS:
                p = res["splits"]["dev"]["verifiers"][v]["protections"]
                self.assertFalse(p["emb/raw"]["powered"])
                self.assertEqual(p["emb/prot"]["tier"], clone_exp.INSUFFICIENT)
                self.assertEqual(p["emb/raw"]["tier"], clone_exp.INSUFFICIENT)  # clone-r2 #1
            for q in ("emb/prot", "emb/raw"):
                self.assertEqual(res["splits"]["dev"]["tiers_by_protection"][q]["tier"], clone_exp.INSUFFICIENT)
                self.assertEqual(res["splits"]["dev"]["tiers_by_protection"][q]["coverage"], "0 of 2 verifiers powered")

    def test_plan_counts_and_selection(self):
        with tempfile.TemporaryDirectory() as d:
            info = {"speakers": [str(i) for i in range(73)],
                    "protections": {"raw": FUSION, "lda32": {"fusion": {
                        "inv+bridge": {"alpha": 1.0}, "direct-ridge": {"alpha": 0.5}, "direct-mlp": {"alpha": 0.0}}}}}
            (Path(d) / "prepare-e.json").write_text(__import__("json").dumps(info))
            info["speakers"] = {"dev": info["speakers"], "clone_eval": [str(i) for i in range(1000, 1251)]}
            (Path(d) / "prepare-e.json").write_text(__import__("json").dumps(info))
            np.savez(Path(d) / "prepare-e.npz", x=np.zeros(1))
            pl = clone_exp.plan(["e"], Path(d))
            # 4 audio/source + se-centroid + other-raw + 2 x 3 x 3 = 24; 2 aliases; source not synthesised
            self.assertEqual(pl["conditions"], 24)
            self.assertEqual(pl["aliases"], 2)
            self.assertEqual(pl["synthesised_conditions"], 21)
            self.assertEqual(pl["clips"], 21 * (73 + 251) * clone_exp.N_ATTEMPTS)
        self.assertEqual(clone_exp.parse_selection("a:lda32;b:raw", ["a", "b"]), {"a": {"lda32"}, "b": set()})
        # review clone-r3 #2: strict parsing
        bad_cases = (("", ["a"]), ("a:", ["a"]), ("a:lda32,,lda16", ["a"]), ("a:lda32,lda32", ["a"]),
                     ("a:raw,lda32", ["a"]), ("a:lda32;a:lda16", ["a"]), ("a:lda32", ["a", "b"]),
                     ("a:lda32;c:raw", ["a"]), ("a:nonsense", ["a"]), ("lda32", ["a"]))
        for text, embs in bad_cases:
            with self.assertRaises(ValueError, msg=text):
                clone_exp.parse_selection(text, embs)

    def test_selection_log_gate(self):
        import json
        import subprocess

        with tempfile.TemporaryDirectory() as d:
            repo, out = Path(d) / "repo", Path(d) / "out"
            repo.mkdir()
            out.mkdir()
            info = {"speakers": {"dev": ["1", "2"], "clone_eval": ["3", "4"]},
                    "protections": {"raw": FUSION, "lda32": FUSION}}
            (out / "prepare-e.json").write_text(json.dumps(info))
            np.savez(out / "prepare-e.npz", x=np.zeros(1))
            run = lambda *a: subprocess.run(["git", *a], cwd=repo, check=True, capture_output=True)
            run("init", "-q")
            run("config", "user.email", "t@example.invalid")
            run("config", "user.name", "t")
            log_path = repo / "selection.json"
            want = {"e": {"lda32"}}

            def gate():
                return clone_exp.check_selection_log(["e"], want, out, path=log_path, repo=repo)

            inv = Path(d) / "invert"
            write_invert(inv, "e", {"raw": (0.05, 0.30), "lda32": (0.055, 0.31), "lda16": (0.09, 0.40)})
            with self.assertRaises(ValueError):  # evidence must cover every selected protection
                bad = Path(d) / "invert_bad"
                write_invert(bad, "e", {"raw": (0.05, 0.3)})
                clone_exp.write_selection_log(["e"], out, "synthetic", path=log_path, invert_root=bad)
            with self.assertRaises(ValueError):  # empty rationale
                clone_exp.write_selection_log(["e"], out, "  ", path=log_path, invert_root=inv)
            log = clone_exp.write_selection_log(["e"], out, "synthetic", path=log_path, invert_root=inv)
            self.assertEqual(log["evidence"]["e"]["selected"], ["lda32", "raw"])
            rows = {r["protection"]: r for r in log["evidence"]["e"]["rows"]}
            self.assertTrue(rows["lda32"]["within_utility_budget"])  # 0.055 <= 1.15 x 0.05, +0.01
            self.assertFalse(rows["lda16"]["within_utility_budget"])
            with self.assertRaises(SystemExit):  # untracked
                gate()
            run("add", "selection.json")
            with self.assertRaises(SystemExit):  # tracked but not committed
                gate()
            run("commit", "-q", "-m", "log")
            g = gate()  # committed and matching: passes
            self.assertEqual(len(g["selection_commit"]), 40)
            with self.assertRaises(SystemExit):  # GPU-hour limit
                clone_exp.check_selection_log(["e"], want, out, path=log_path, repo=repo, max_gpu_hours=0.0)
            with self.assertRaises(SystemExit):  # selection differs from the prepared files
                clone_exp.check_selection_log(["e"], {"e": {"lda16"}}, out, path=log_path, repo=repo)
            np.savez(out / "prepare-e.npz", x=np.ones(1))  # re-prepared after the log
            with self.assertRaises(SystemExit):
                gate()
            np.savez(out / "prepare-e.npz", x=np.zeros(1))
            gate()
            np.savez(out / "scores-dev.npz", x=np.zeros(1))  # earlier synthesis output present
            with self.assertRaises(SystemExit):
                gate()
            (out / "scores-dev.npz").unlink()
            gate()
            log_path.write_text(log_path.read_text() + " ")  # modified against HEAD
            with self.assertRaises(SystemExit):
                gate()

    def test_train_partners_unique_same_sex(self):
        from lfspk.protect.data import TrainSet

        rng = np.random.default_rng(0)
        spk = [str(100 + i) for i in range(40)]
        y = np.repeat(spk, 15)
        sex = {s: "F" if i % 2 else "M" for i, s in enumerate(spk)}
        train = TrainSet(rng.standard_normal((len(y), 4)), y, sex, {})
        want = ["F"] * 12 + ["M"] * 10
        exclude = {"101", "102"}
        p = clone_exp.train_partners(train, want, exclude, seed=3)
        self.assertEqual(len(set(p)), len(p))  # no reuse
        self.assertEqual([sex[x] for x in p], want)
        self.assertFalse(set(p) & exclude)
        self.assertEqual(p, clone_exp.train_partners(train, want, exclude, seed=3))
        with self.assertRaises(ValueError):  # more targets than eligible speakers
            clone_exp.train_partners(train, ["F"] * 25, exclude, seed=3)

    def test_outside_budget_selection_refused(self):
        import json

        with tempfile.TemporaryDirectory() as d:
            out, inv = Path(d) / "out", Path(d) / "invert"
            out.mkdir()
            write_invert(inv, "e", {"raw": (0.05, 0.30), "lda16": (0.09, 0.40)})
            info = {"speakers": {"dev": ["1"], "clone_eval": ["2"]}, "protections": {"raw": FUSION, "lda16": FUSION}}
            (out / "prepare-e.json").write_text(json.dumps(info))
            np.savez(out / "prepare-e.npz", x=np.zeros(1))
            with self.assertRaises(ValueError):
                clone_exp.write_selection_log(["e"], out, "x", path=Path(d) / "sel.json", invert_root=inv)
            # review clone-r5 #3: .010051 vs .0116 violates the exact 15 % budget
            # (.0116 / .010051 = 1.154) although the rounded summary (.0101, .0116) passes
            inv2 = Path(d) / "invert2"
            write_invert(inv2, "e", {"raw": (0.010051, 0.30), "lda16": (0.0116, 0.30)})
            self.assertLessEqual(0.0116, 1.15 * 0.0101)  # the rounded values would pass
            with self.assertRaises(ValueError):
                clone_exp.write_selection_log(["e"], out, "x", path=Path(d) / "sel.json", invert_root=inv2)

    def test_ledger_refuses_a_changed_preregistration(self):
        import json

        with tempfile.TemporaryDirectory() as d:
            ledger = Path(d) / "ledger.jsonl"
            g1 = {"selection_commit": "a" * 40, "plan_sha256": "p1", "expected_gpu_hours": 1.0}
            g2 = {"selection_commit": "b" * 40, "plan_sha256": "p2", "expected_gpu_hours": 1.0}
            clone_exp.record_synthesis_start(g1, None, ledger)
            clone_exp.record_synthesis_start(g1, None, ledger)  # same log: allowed (e.g. a crash rerun)
            with self.assertRaises(SystemExit):
                clone_exp.record_synthesis_start(g2, None, ledger)
            with self.assertRaises(SystemExit):
                clone_exp.record_synthesis_start(g2, "  ", ledger)
            e = clone_exp.record_synthesis_start(g2, "reviewer asked for an extra protection", ledger)
            self.assertEqual(e["new_preregistration"], "reviewer asked for an extra protection")
            lines = [json.loads(x) for x in ledger.read_text().splitlines()]
            self.assertEqual([x["selection_commit"][0] for x in lines], ["a", "a", "b"])
            fake_scores(Path(d))
            res = clone_exp.stats(Path(d), n_boot=5, ledger=ledger)
            self.assertEqual(len(res["ledger"]), 3)
            self.assertEqual(len(res["new_preregistrations"]), 1)

    def test_design_resolution_table_regenerates(self):
        # invert-r6 #3: the table in DESIGN section 3 is the implementation's output
        import re

        design = (Path(clone_exp.__file__).parent / "DESIGN.md").read_text()
        table = clone_exp.resolution_table()
        rows = re.findall(r"^  \| ([0-9.]+)[^|]*\| ([0-9.]+) \| ([0-9.]+) \|$", design, flags=re.M)
        self.assertEqual(len(rows), 5)
        for level, v73, v251 in rows:
            self.assertAlmostEqual(table[73][float(level)], float(v73), places=6)
            self.assertAlmostEqual(table[251][float(level)], float(v251), places=6)
        self.assertEqual(table[251][0.0], 0.020)
        self.assertEqual(table[251][0.01], 0.029)
        self.assertEqual(table[251][0.30], 0.021)

    def test_synth_out_bypass_is_refused(self):
        # review clone-r5 #1: a fresh --out directory must not escape the ledger
        with tempfile.TemporaryDirectory() as d:
            canon, other, ledger = Path(d) / "clone", Path(d) / "B", Path(d) / "clone" / "ledger.jsonl"
            canon.mkdir()
            other.mkdir()
            commits = iter(["a" * 40, "b" * 40, "b" * 40])
            calls = []
            gate = lambda embs, want, out, max_gpu_hours: {"selection_commit": next(commits),
                                                          "plan_sha256": "p", "expected_gpu_hours": 1.0}
            synth_stub = lambda embs, out, provenance=None, limit_targets=None: calls.append((out, provenance))
            kw = dict(canonical=canon, ledger=ledger, gate_fn=gate, synth_fn=synth_stub)
            clone_exp.run_synth(["e"], "e:raw", canon, 8.0, None, False, **kw)  # run A
            with self.assertRaises(SystemExit):  # revised selection in a fresh directory B
                clone_exp.run_synth(["e"], "e:raw", other, 8.0, None, False, **kw)
            with self.assertRaises(SystemExit):  # back in the canonical directory: ledger has A
                clone_exp.run_synth(["e"], "e:raw", canon, 8.0, None, False, **kw)
            clone_exp.run_synth(["e"], "e:raw", canon, 8.0, "documented reason", False, **kw)
            self.assertEqual(len(calls), 2)
            # smoke: outside the canonical directory only, no gate, no ledger entry
            n_before = len(ledger.read_text().splitlines())
            clone_exp.run_synth(["e"], "", other, 8.0, None, True, **kw)
            self.assertEqual(calls[-1][1], {"smoke": True})
            self.assertEqual(len(ledger.read_text().splitlines()), n_before)
            with self.assertRaises(SystemExit):
                clone_exp.run_synth(["e"], "", canon, 8.0, None, True, **kw)

    def test_worst_decile_boundary_weight(self):
        # invert-r3 #3: counts [6, 4, 63] -> worst 8 draws -> 7/8
        self.assertAlmostEqual(clone_exp.worst_decile(np.array([1.0, 0.5, 0.0]), np.array([6, 4, 63])), 0.875)
        # clone-r1 #3: 20 draws, one success copy then three failures -> worst 2 -> 0.5
        self.assertAlmostEqual(clone_exp.worst_decile(np.array([1.0, 0.0, 0.0]), np.array([1, 3, 16])), 0.5)
        x = np.arange(20, dtype=float)
        self.assertAlmostEqual(clone_exp.worst_decile(x, np.ones(20)), 18.5)

    def test_success_within_and_tiers(self):
        S = np.array([[1.0, 0.0, 0.0, 0.0], [0.0] * 4, [1.0] * 4])
        np.testing.assert_allclose(clone_exp.success_within(S, 0.5, 1), [0.25, 0, 1])
        np.testing.assert_allclose(clone_exp.success_within(S, 0.5, 2), [0.5, 0, 1])
        np.testing.assert_allclose(clone_exp.success_within(S, 0.5, 4), [1, 0, 1])
        self.assertEqual(clone_exp.tier(0.02), "negligible")
        self.assertEqual(clone_exp.tier(0.03), "low")
        self.assertEqual(clone_exp.tier(0.11), "high")

    def test_conditions_aliases_and_seeds(self):
        info = {"protections": {"p": {"fusion": {"inv+bridge": {"alpha": 1.0}, "direct-ridge": {"alpha": 0.0},
                                                 "direct-mlp": {"alpha": 0.25}}}}}
        conds = {c: (k, a) for c, k, a in clone_exp.conditions({"e": (info, {})})}
        self.assertEqual(conds["e/audio-3s+p|inv+bridge"][1], "audio-3s")
        self.assertEqual(conds["e/audio-3s+p|direct-ridge"][1], "e/p|direct-ridge")
        self.assertIsNone(conds["e/audio-3s+p|direct-mlp"][1])
        self.assertIn("e/p|direct-mlp|other", conds)
        self.assertEqual(sum(1 for c in conds if c.endswith("se-centroid")), 1)
        self.assertNotIn("keyrot", clone_exp.CLONED)
        self.assertEqual(clone_exp.attempt_seed(1, 2, 3), clone_exp.attempt_seed(1, 2, 3))
        self.assertNotEqual(clone_exp.attempt_seed(1, 2, 3), clone_exp.attempt_seed(1, 2, 4))

    def test_fusion_alpha_and_partners(self):
        rng = np.random.default_rng(0)
        truth = rng.standard_normal((30, 8))
        se3 = truth + 0.1 * rng.standard_normal((30, 8))
        route = rng.standard_normal((30, 8))
        a, _ = clone_exp.fusion_alpha(se3, route, truth)
        self.assertEqual(a, 1.0)
        a, _ = clone_exp.fusion_alpha(route, se3, truth)
        self.assertEqual(a, 0.0)
        dev = DevSet(["1", "2", "3", "4", "5"], {"1": "F", "2": "M", "3": "F", "4": "M", "5": "F"}, {}, {}, {}, {})
        p = clone_exp.partners(dev)
        self.assertEqual(p, {"1": "3", "3": "5", "5": "1", "2": "4", "4": "2"})


if __name__ == "__main__":
    unittest.main()
