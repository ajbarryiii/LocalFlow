"""W5 word metrics, overlay bank, front-end implementation, profile check and
stage-0 helpers, on synthetic data."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from lfspk.extract import evalwords as ev
from lfspk.extract import overlay, profilecheck
from lfspk.harness.align import Word
from lfspk.pvad.enrollment import EnrollmentBank


def W(t, s, e):
    return Word(t, s, e)


class TestEvalWords(unittest.TestCase):
    """Stage-0 glue over lfspk.harness.tmetrics (the definitions are W0F's and tested there,
    with W5's f6bea72 values frozen as a fixture)."""

    def setUp(self):
        self.ref = [W("red", 0.0, 0.3), W("blue", 0.5, 0.8), W("green", 1.0, 1.3)]
        self.labels = np.ones(200, np.uint8)

    def rec(self, ref, hyps, int_refs=(), labels=None, family="S1", speakers=("1",)):
        from lfspk.harness.tmetrics import unreachable

        r = ev.MixRecord("k", family, tuple(speakers), list(ref), [list(x) for x in int_refs],
                         self.labels if labels is None else labels)
        for k, v in hyps.items():
            r.hyps[k] = v
            r.evaluate(k)
        r.unreachable = unreachable(r.hyps["B"], ref)
        return r

    def summ(self, r, system):
        from lfspk.harness import tmetrics as tm

        return tm.summarize(ev.counts(r, system))

    def test_reviewer_case_deletion_is_not_recovery(self):
        b = [W("one", 0.0, 0.2), W("two", 0.3, 0.5), W("red", 0.6, 0.8)]
        r = self.rec(self.ref, {"B": b, "F": [b[0], b[2]]})
        s = self.summ(r, "F")
        self.assertAlmostEqual(s["G/all"], 1 / 3)  # re-alignment makes "red" correct ...
        self.assertEqual(s["G_u/all"], 0.0)  # ... but a filter could do that

    def test_losses_gains_unreachable(self):
        b = [W("red", 0.0, 0.3), W("blew", 0.5, 0.8)]
        f = [W("bread", 0.0, 0.3), W("blue", 0.5, 0.8), W("green", 1.0, 1.3)]
        r = self.rec(self.ref, {"B": b, "F": f}, int_refs=[[W("hello", 2.0, 2.3)]], speakers=("1", "2"))
        self.assertEqual(r.unreachable, frozenset({1, 2}))
        s = self.summ(r, "F")
        self.assertAlmostEqual(s["L+/all"], 1 / 3)
        self.assertAlmostEqual(s["G_u/all"], 2 / 3)
        self.assertAlmostEqual(s["net_L/all"], -1 / 3)

    def test_oracle_filter_threshold_search_repeated_word(self):
        # implI2-r1 #1 through the shared search: ref "red red", B "blue red"
        from lfspk.harness import tmetrics as tm

        ref = [W("red", 0.0, 0.3), W("red", 0.5, 0.8)]
        b = [W("blue", 0.0, 0.1), W("red", 0.2, 0.4)]
        r = self.rec(ref, {"B": b})
        steps = [ev.filter_steps(r, np.array([0.1, 0.9]))]
        tau, _, tot = tm.search_tau(steps, np.ones(1), tm.budget_rule(0.4))
        self.assertLessEqual(tau, 0.1)  # removing "blue" alone costs L+ = 0.5
        self.assertEqual(tm.summarize(tot)["L+/all"], 0.0)
        tau, _, tot = tm.search_tau(steps, np.ones(1), tm.budget_rule(0.5))
        self.assertEqual(tau, float("inf"))
        self.assertEqual(ev.filtered(b, np.array([0.1, 0.9]), tau), [])

    def test_token_means_and_filter(self):
        labels = np.zeros(100, np.uint8)
        labels[:40] = 1
        hyp = [W("a", 0.05, 0.2), W("b", 0.7, 0.9)]
        m = ev.token_means(hyp, ev.oracle_scores(labels))
        self.assertEqual(m[1], 0.0)
        self.assertEqual([w.text for w in ev.filtered(hyp, m, 0.5)], ["a"])

    def test_boot_weights_match_w0_draws(self):
        from lfspk.harness.metrics import speaker_weights

        recs = [self.rec(self.ref, {"B": list(self.ref)}, speakers=sp) for sp in (("3",), ("1", "3"), ("2",))]
        W_ = ev.boot_weights(recs, n_boot=5, seed=0)
        rng = np.random.default_rng(0)
        for b in range(5):  # tmetrics draws as W0's compute_metrics: one generator over the sorted universe
            np.testing.assert_array_equal(W_[b], speaker_weights([r.speakers for r in recs], ["1", "2", "3"], rng))


class TestOverlay(unittest.TestCase):
    def bank(self):
        rng = np.random.default_rng(0)
        rows = [(s, u, ch, c) for s in ("1", "2") for u in (f"{s}-1-1", f"{s}-1-2") for ch in ("builtin", "headset")
                for c in (False, True)]
        e = rng.standard_normal((len(rows), 4)).astype(np.float32)
        e /= np.linalg.norm(e, axis=1, keepdims=True)
        return EnrollmentBank(e, np.array([r[0] for r in rows]), np.array([r[1] for r in rows]),
                              np.array([r[2] for r in rows]), np.array([r[3] for r in rows]), "x", "y"), rows

    def test_audit_and_apply(self):
        bank, rows = self.bank()
        table = {(s, u, ch): (("9",) if (s, u) == ("1", "1-1-2") else ("7", "8")) for s, u, ch, c in rows if c}
        hits = overlay.audit(bank, table, held_out=("9",))
        self.assertEqual(len(hits), 2)  # both devices of 1-1-2
        # scope "heldout": every contaminated row of a held-out speaker, whoever contaminated it (implT-r1 #5)
        h2 = overlay.audit(bank, table, held_out=("2",), scope="heldout")
        self.assertEqual({h["speaker"] for h in h2}, {"2"})
        self.assertEqual(len(h2), 4)  # 2 utterances x 2 devices
        with self.assertRaises(ValueError):
            overlay.audit(bank, table, ("2",), scope="other")
        self.assertTrue(all(bool(bank.contaminated[h["row"]]) for h in hits))
        new = np.tile(np.array([[1, 0, 0, 0]], np.float32), (2, 1))
        b2 = overlay.apply_overlay(bank, np.array([h["row"] for h in hits]), new)
        self.assertTrue(np.array_equal(b2.emb[hits[0]["row"]], new[0]))
        others = [i for i in range(len(rows)) if i not in {h["row"] for h in hits}]
        self.assertTrue(np.array_equal(b2.emb[others], bank.emb[others]))
        clean = next(i for i, r in enumerate(rows) if not r[3])
        with self.assertRaises(ValueError):
            overlay.apply_overlay(bank, np.array([clean]), new[:1])
        with self.assertRaises(ValueError):
            overlay.audit(bank, {k: v for k, v in list(table.items())[1:]}, ("9",))  # a row without a record

    def test_contaminator_table_checks_identity(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "parts").mkdir()
            ident = {"embedder": "e", "w0_commit": "a"}
            np.savez(d / "parts" / "part-0000.npz", speaker=np.array(["1", "1"]), utt=np.array(["1-1-1", "1-1-1"]),
                     channel=np.array(["builtin", "builtin"]), contaminated=np.array([False, True]),
                     contaminator=np.array(["", "5,6"]), identity=np.array(json.dumps({**ident, "w0_commit": "b"})))
            t = overlay.contaminator_table(d, {"identity": ident})
            self.assertEqual(t, {("1", "1-1-1", "builtin"): ("5", "6")})
            with self.assertRaises(ValueError):
                overlay.contaminator_table(d, {"identity": {"embedder": "other"}})

    def test_read_verified(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x"
            p.write_bytes(b"abc")
            with self.assertRaises(ValueError):
                overlay.read_verified(p, "0" * 64)


class StubProfile:
    def __init__(self, d):
        self.directions = [d]


class StubProfiler:
    name = "stub"

    def enroll(self, utts):
        v = np.ones(192, np.float32)
        return StubProfile(v / np.linalg.norm(v))

    def update(self, p, u):
        return p

    def cost(self):
        from lfspk.api import CostReport

        return CostReport(params=100, macs_per_audio_second=0.0, update_macs=5.0, profile_bytes=784)


class TestFrontEndImpl(unittest.TestCase):
    def test_checkpoint_roundtrip_analyse_identity_cost(self):
        from lfspk.extract import harness_frontend as hf
        from lfspk.extract.api import check_mask_output, feature_frames
        from lfspk.extract.model import MaskNet, config_for

        torch.manual_seed(0)
        net = MaskNet(config_for("S"))
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "ck.pt"
            hf.save_checkpoint(p, net, {"embedder": "redimnet2-b2", "identity_sha256": "abc", "run": "R1", "seed": 0})
            net2, meta, sha = hf.load_checkpoint(p)
            self.assertEqual(meta["embedder"], "redimnet2-b2")
            for k, v in net.state_dict().items():
                self.assertTrue(torch.equal(v, net2.state_dict()[k]))
            fe = hf.ExtractFrontEnd(net2, StubProfiler(), str(p), sha, {"embedder": "redimnet2-b2"}, meta)
        prof = fe.enroll([np.zeros(16000, np.float32)])
        a = (np.random.default_rng(1).standard_normal(33000) * 0.05).astype(np.float32)
        o1, o2 = fe.analyse(prof, a), fe.analyse(prof, a)
        check_mask_output(o1, len(a))
        self.assertEqual(o1.log_mask.shape, (128, feature_frames(len(a))))
        np.testing.assert_array_equal(o1.log_mask, o2.log_mask)  # deterministic on CPU
        self.assertTrue((o1.u[len(a) // 160:] == 0).all())
        ident = fe.identity()
        self.assertEqual(ident["checkpoint_sha256"], sha)
        self.assertEqual((ident["run"], ident["seed"]), ("R1", 0))  # W0F fe-10: confirmatory label needs run and seed
        self.assertEqual(len(ident["w5_code_sha256"]), 64)
        fe.profiler_settings["norm"] = "asnorm"
        self.assertNotEqual(json.dumps(ident, sort_keys=True), json.dumps(fe.identity(), sort_keys=True))
        c = fe.cost()
        self.assertEqual(c.profile_bytes, 784)
        self.assertGreater(c.params, 100)

    def test_analyse_is_single_threaded_and_restores(self):
        # implI2-r2 #1: identical output whatever the caller's thread count; the caller's setting is restored
        from lfspk.extract import harness_frontend as hf
        from lfspk.extract.model import MaskNet, config_for

        torch.manual_seed(0)
        net = MaskNet(config_for("S")).eval()
        with torch.no_grad():
            torch.nn.init.normal_(net.mask_head.weight, std=0.2)
            torch.nn.init.normal_(net.aux_head.weight, std=0.2)
        fe = hf.ExtractFrontEnd(net, StubProfiler(), "", "x" * 64, {}, {}, None)
        prof = fe.enroll([np.zeros(16000, np.float32)])
        a = (np.random.default_rng(2).standard_normal(16000 * 6) * 0.05).astype(np.float32)
        prev = torch.get_num_threads()
        self.addCleanup(torch.set_num_threads, prev)
        outs = []
        for th in (1, 4):
            torch.set_num_threads(th)
            outs.append(fe.analyse(prof, a))
            self.assertEqual(torch.get_num_threads(), th)  # restored
        self.assertGreater(float(np.std(outs[0].log_mask)), 1e-3)
        np.testing.assert_array_equal(outs[0].log_mask, outs[1].log_mask)
        np.testing.assert_array_equal(outs[0].u, outs[1].u)

    def test_theta_b_from_checkpoint_artefact(self):
        from lfspk.extract import harness_frontend as hf
        from lfspk.extract.model import MaskNet, config_for

        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "final.pt"
            hf.save_checkpoint(p, MaskNet(config_for("S")), {})
            _, _, sha = hf.load_checkpoint(p)
            self.assertIsNone(hf.read_theta_b(p, sha))
            fe = hf.ExtractFrontEnd(MaskNet(config_for("S")), StubProfiler(), str(p), sha, {}, {}, None)
            with self.assertRaises(ValueError):
                fe.config("C3")
            self.assertFalse(fe.config("C1").bypass)
            (Path(d) / "theta_b.json").write_text(json.dumps({"checkpoint_sha256": sha, "theta_b": 0.31}))
            self.assertEqual(hf.read_theta_b(p, sha), 0.31)
            fe = hf.ExtractFrontEnd(MaskNet(config_for("S")), StubProfiler(), str(p), sha, {}, {}, 0.31)
            self.assertEqual(fe.config("C4").theta_b, 0.31)
            self.assertEqual(fe.identity()["theta_b"], 0.31)
            (Path(d) / "theta_b.json").write_text(json.dumps({"checkpoint_sha256": "x", "theta_b": 0.31}))
            with self.assertRaises(ValueError):
                hf.read_theta_b(p, sha)

    def test_load_refuses_other_files(self):
        from lfspk.extract import harness_frontend as hf

        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.pt"
            torch.save({"kind": "other"}, p)
            with self.assertRaises(ValueError):
                hf.load_checkpoint(p)


class TestProfileCheck(unittest.TestCase):
    def test_decision_rule(self):
        self.assertEqual(profilecheck.decide([0.99, 0.98], [0.97, 0.96])["decision"], "use_w3_bank")
        self.assertEqual(profilecheck.decide([0.90, 0.91], [0.97, 0.96])["decision"], "build_windowed_bank")
        self.assertEqual(profilecheck.decide([0.95], [0.95])["decision"], "use_w3_bank")  # ties: at least


class TestStage0Identity(unittest.TestCase):
    """implI2-r1 #2-#3: render generations, manifests, transcript binding, involvement."""

    def test_render_dir_binding(self):
        from lfspk.extract import stage0

        keys = stage0.expected_keys(2)
        self.assertEqual(len(keys), 12)
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            self.assertEqual(stage0.prepare_render_dir(out, {"id": 1}, keys), keys)
            np.savez(out / "mix" / f"{keys[0]}.npz", audio=np.zeros(3, np.float32))
            self.assertEqual(stage0.prepare_render_dir(out, {"id": 1}, keys), keys[1:])  # resume, same identity
            with self.assertRaises(RuntimeError):
                stage0.prepare_render_dir(out, {"id": 2}, keys)  # another generation
            np.savez(out / "mix" / "S9-000.npz", audio=np.zeros(3, np.float32))
            with self.assertRaises(RuntimeError):
                stage0.prepare_render_dir(out, {"id": 1}, keys)  # an unexpected file
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "mix").mkdir()
            np.savez(out / "mix" / f"{keys[0]}.npz", audio=np.zeros(3, np.float32))
            with self.assertRaises(RuntimeError):
                stage0.prepare_render_dir(out, {"id": 1}, keys)  # renders without an identity

    def test_transcripts_bound_to_manifest(self):
        from lfspk.extract import stage0

        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            ident = {"id": 1}
            (out / "render_identity.json").write_text(json.dumps(ident))
            man = {"identity_sha256": stage0._sha(ident), "keys": {"S0-000": "aa", "S1-000": "bb"}}
            (out / "render.json").write_text(json.dumps(man))
            self.assertEqual(stage0.read_manifest(out), man)
            (out / "asr").mkdir()

            def write(aid, recs):
                (out / "asr" / "identity.json").write_text(json.dumps({"render_identity_sha256": aid}))
                for s in stage0.SYSTEMS:
                    (out / "asr" / f"{s}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs))

            good = [{"key": "S0-000", "audio_sha256": "aa", "words": []}, {"key": "S1-000", "audio_sha256": "bb", "words": []}]
            write(man["identity_sha256"], good)
            self.assertEqual(set(stage0.load_transcripts(out, man)["B"]), {"S0-000", "S1-000"})
            write("other", good)
            with self.assertRaises(RuntimeError):
                stage0.load_transcripts(out, man)
            write(man["identity_sha256"], good[:1])
            with self.assertRaises(RuntimeError):
                stage0.load_transcripts(out, man)
            write(man["identity_sha256"], [good[0], {**good[1], "audio_sha256": "cc"}])
            with self.assertRaises(RuntimeError):
                stage0.load_transcripts(out, man)
            (out / "render.json").write_text(json.dumps({**man, "identity_sha256": "x"}))
            with self.assertRaises(RuntimeError):
                stage0.read_manifest(out)

    def test_validated_manifest_checks_current_identity(self):
        # implI2-r2 #2: consumers compare against the identity the current code would produce
        from lfspk.extract import stage0

        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            ident = {"id": 1, "n_per_family": 1}
            keys = stage0.expected_keys(1)
            stage0.prepare_render_dir(out, ident, keys)
            hashes = {}
            for i, k in enumerate(keys):
                a = np.full(10, i, np.float32)
                np.savez(out / "mix" / f"{k}.npz", audio=a)
                hashes[k] = stage0.audio_sha256(a)
            (out / "render.json").write_text(json.dumps({"identity_sha256": stage0._sha(ident), "keys": hashes}))
            self.assertEqual(stage0.validated_manifest(out, lambda n: dict(ident))["keys"], hashes)
            with self.assertRaises(RuntimeError):  # a seed, policy or code change since rendering
                stage0.validated_manifest(out, lambda n: {**ident, "id": 2})
            (out / "mix" / f"{keys[0]}.npz").unlink()
            with self.assertRaises(RuntimeError):
                stage0.validated_manifest(out, lambda n: dict(ident))

    def test_involvement_and_weights(self):
        from lfspk.extract import stage0
        from lfspk.harness.metrics import speaker_weights

        absent_n = {"speaker": "1", "interferers": [], "removed_interferers": ["2"], "absent": True, "impostor": "3"}
        self.assertEqual(stage0.involved_speakers(absent_n), ("1", "3"))  # implI2-r2 #4
        self.assertEqual(stage0.involved_speakers({"speaker": "1", "interferers": ["4"], "absent": False,
                                                   "impostor": None}), ("1", "4"))

        n_info = {"speaker": "1", "interferers": [], "removed_interferers": ["2"]}
        self.assertEqual(stage0.involved_speakers(n_info), ("1",))
        # the mixture's weight is the target's draw count alone, whatever happened to the removed talker
        for seed in range(20):
            counts = np.bincount(np.random.default_rng(seed).integers(0, 2, 2), minlength=2)
            w = speaker_weights([stage0.involved_speakers(n_info)], ["1", "2"], np.random.default_rng(seed))
            self.assertEqual(float(w[0]), float(counts[0]))
        self.assertEqual(stage0.involved_speakers({"speaker": "1", "interferers": ["2", "2", "3"]}), ("1", "2", "3"))


class TestStage0Report(unittest.TestCase):
    def test_report_on_synthetic_records(self):
        # the rewired report: groups, W_o search, stop rule and parity, on invented records
        from unittest import mock

        from lfspk.extract import stage0
        from lfspk.harness.tmetrics import unreachable

        def rec(fam, k, int_words, sp):
            ref = [W("a", 0.0, 0.2), W("b", 0.3, 0.5), W("c", 0.6, 0.8)]
            labels = np.ones(120, np.uint8)
            labels[90:] = 3  # the interferer word overlaps the target, so the oracle word filter keeps it
            r = ev.MixRecord(f"{fam}-{k}", fam, sp, ref, [int_words], labels)
            base = list(ref) + list(int_words)
            for s in stage0.SYSTEMS:
                r.hyps[s] = list(ref) if s in ("O2", "O1") else list(base)
                r.evaluate(s)
            r.unreachable = unreachable(r.hyps["B"], ref)
            return r

        recs = []
        for i, f in enumerate(stage0.FAMILIES):
            for k in range(3):
                iw = [] if f in ("S0", "N") else [W("zed", 0.95, 1.1)]
                recs.append(rec(f, k, iw, (str(10 + k), str(20 + i)) if iw else (str(10 + k),)))
        with tempfile.TemporaryDirectory() as d, mock.patch.object(stage0, "build_records", return_value=recs), \
                mock.patch.object(stage0, "guard_shares", return_value={}):
            res = stage0.report(Path(d), n_boot=50)
            self.assertTrue((Path(d) / "report.json").exists())
        self.assertEqual(res["groups"]["S1-S4"]["O2"]["R/all"], 0.0)  # the oracle mask removed every interferer word
        self.assertEqual(res["groups"]["S1-S4"]["B"]["R/all"], 1.0)
        self.assertEqual(res["stop_rule"]["R_Wo_S1-S4"], 1.0)
        self.assertFalse(res["stop_rule"]["stop"])  # R(O2) = 0 < R(W_o) = 1; O2 loses nothing
        self.assertFalse(res["parity_fix_needed"])
        self.assertEqual(res["stop_rule"]["L+_O2_all"], 0.0)


class TestStage0Helpers(unittest.TestCase):
    @unittest.skipUnless(__import__("lfspk.extract.constants", fromlist=["x"]).available(), "W5 constants not extracted")
    def test_oracle_masks(self):
        from lfspk.extract import stage0
        from lfspk.extract.api import LOG_G_MIN, check_mask_output

        rng = np.random.default_rng(0)
        t = (rng.standard_normal(32000) * 0.05).astype(np.float32)
        n = (rng.standard_normal(32000) * 0.005).astype(np.float32)
        i = np.zeros(32000, np.float32)
        i[16000:] = (rng.standard_normal(16000) * 0.2).astype(np.float32)
        mix = {"audio": t + n + i, "target_image": t, "noise": n}
        o2, o1 = stage0.oracle_mask(mix, "T2"), stage0.oracle_mask(mix, "T1")
        for o in (o2, o1):
            check_mask_output(o, 32000)
            self.assertEqual(o.log_mask.dtype, np.float16)
        self.assertGreater(float(o2.log_mask[:, 10:90].astype(np.float32).min()), -0.05)  # no interferer: pass
        self.assertLess(float(o2.log_mask[:, 110:190].astype(np.float32).mean()), -1.0)  # interferer: suppress
        self.assertLessEqual(float(o1.log_mask.astype(np.float32).mean()), float(o2.log_mask.astype(np.float32).mean()))
        self.assertGreaterEqual(float(o1.log_mask.astype(np.float32).min()), LOG_G_MIN - 0.01)
        clean = {"audio": t + n, "target_image": t, "noise": n}
        self.assertTrue(np.all(stage0.oracle_mask(clean, "T2").log_mask == 0))  # T2 on target-only: exactly 1


if __name__ == "__main__":
    unittest.main()
