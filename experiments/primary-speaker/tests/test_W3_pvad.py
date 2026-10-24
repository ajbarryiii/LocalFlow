"""W3 personal VAD contracts, on synthetic arrays only."""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from lfspk import api
from lfspk.pvad import data as D
from lfspk.pvad import enrollment as E
from lfspk.pvad import features as F
from lfspk.pvad import losses as L
from lfspk.pvad import metrics as M
from lfspk.pvad import model as Mo
from lfspk.pvad import scorer as Sc
from lfspk.pvad import synthetic as Sy

STORED_FRONTEND = Path("/mnt/hd/wilderness-labs-stt/parakeet-ios/final-memory-20261005/native/frontend.f32bin")


def _audio(n, seed=0):
    return (np.random.default_rng(seed).normal(0, 0.1, n)).clip(-1, 1).astype(np.float32)


class FeaturesTest(unittest.TestCase):
    @unittest.skipUnless(STORED_FRONTEND.exists(), "Parakeet front-end constants not on this host")
    def test_constants_match_parakeet_stored_values(self):
        raw = np.fromfile(STORED_FRONTEND, "<f4")
        np.testing.assert_allclose(F.hann_window().numpy(), raw[:400], atol=1e-6)
        np.testing.assert_allclose(F.mel_filterbank().numpy(), raw[400:].reshape(128, 257), atol=1e-7)

    def test_shape_and_zeroed_tail(self):
        fe = F.ParakeetFrontEnd()
        for n in (160, 161, 16_000, 16_077):
            out = F.features_np(_audio(n), fe)
            self.assertEqual(out.shape, (128, n // 160 + 1))
            self.assertTrue(np.all(out[:, n // 160:] == 0))
            self.assertGreaterEqual(out.shape[1], api.frame_count(n))

    def test_per_feature_normalisation_over_valid_frames(self):
        out = F.features_np(_audio(32_000))
        valid = out[:, : 32_000 // 160]
        np.testing.assert_allclose(valid.mean(axis=1), 0, atol=1e-4)
        np.testing.assert_allclose(valid.std(axis=1, ddof=1), 1, atol=1e-3)

    def test_batched_equals_individual(self):
        fe = F.ParakeetFrontEnd()
        a, b = _audio(24_000, 1), _audio(15_123, 2)
        batch = torch.zeros(2, 24_000)
        batch[0] = torch.from_numpy(a)
        batch[1, :15_123] = torch.from_numpy(b)
        batch[1, 15_123:] = 0.5  # garbage past the length must not matter
        out = fe(batch, torch.tensor([24_000, 15_123]))
        np.testing.assert_allclose(out[0].numpy(), F.features_np(a, fe), atol=1e-4)
        nb = 15_123 // 160 + 1
        np.testing.assert_allclose(out[1, :, :nb].numpy(), F.features_np(b, fe), atol=1e-4)
        self.assertTrue(torch.all(out[1, :, nb:] == 0))

    def test_tiny_inputs(self):
        for n in (0, 1, 159, 320):
            out = F.features_np(_audio(n))
            self.assertEqual(out.shape, (128, n // 160 + 1))
            self.assertTrue(np.isfinite(out).all())


class ModelTest(unittest.TestCase):
    def _model(self, cond, size="S", emb_dim=16):
        torch.manual_seed(0)
        return Mo.PVAD(Mo.config_for(size, cond, emb_dim)).eval()

    def test_output_shape_all_conditionings(self):
        for cond in Mo.CONDITIONINGS:
            m = self._model(cond)
            for t in (1, 2, 7, 100, 101):
                emb = torch.randn(2, 16)
                out = m(torch.randn(2, 128, t), None if cond == "none" else emb)
                self.assertEqual(tuple(out.shape), (2, 3, t), (cond, t))

    def test_budget_for_every_size(self):
        for size in Mo.SIZES:
            cfg = Mo.config_for(size, "film_cos", 192)
            self.assertLessEqual(Mo.param_count(Mo.PVAD(cfg)), 500_000, size)
            self.assertLessEqual(Mo.macs_per_second(cfg), 20e6, size)
        sizes = [Mo.param_count(Mo.PVAD(Mo.config_for(s, "film_cos", 192))) for s in ("S", "M", "L")]
        self.assertEqual(sizes, sorted(sizes))

    def test_analytic_macs_match_flop_counter(self):
        from torch.utils.flop_counter import FlopCounterMode

        for cond in Mo.CONDITIONINGS:
            cfg = Mo.config_for("M", cond, 192)
            m = Mo.PVAD(cfg).eval()
            mel, emb = torch.randn(1, 128, 1000), torch.randn(1, 192)
            with FlopCounterMode(display=False) as fc:
                m(mel, None if cond == "none" else emb)
            counted_macs = fc.get_total_flops() / 2  # matmul/conv FLOPs = 2 x MACs
            parts = Mo.macs_per_frame_pair(cfg)
            analytic = 500 * (parts["stem"] + parts["blocks"] + parts["head"]) + Mo.per_recording_macs(cfg)
            if cond == "film_cos":
                analytic += 500 * cfg.channels * cfg.cos_dim  # the only counted part of the cos branch
            self.assertAlmostEqual(counted_macs / analytic, 1.0, delta=0.01, msg=cond)
            self.assertLessEqual(analytic / 10, Mo.macs_per_second(cfg) + Mo.per_recording_macs(cfg))

    def test_film_starts_as_identity(self):
        m = self._model("film_cos")
        mel = torch.randn(1, 128, 50)
        a = m(mel, torch.randn(1, 16))
        b = m(mel, torch.randn(1, 16))
        torch.testing.assert_close(a, b)

    def test_masked_padding_does_not_change_valid_frames(self):
        for cond in Mo.CONDITIONINGS:
            m = self._model(cond)
            # perturb FiLM away from identity so conditioning paths are exercised
            with torch.no_grad():
                for p in m.parameters():
                    p.add_(0.05 * torch.randn_like(p))
            for t in (37, 40):
                mel = torch.randn(1, 128, t)
                emb = torch.randn(1, 16)
                ref = m(mel, None if cond == "none" else emb)
                padded = torch.cat([mel, 3 * torch.randn(1, 128, 23)], dim=-1)
                mask = torch.zeros(1, t + 23)
                mask[:, :t] = 1
                out = m(padded, None if cond == "none" else emb, mask)
                torch.testing.assert_close(out[..., :t], ref, atol=1e-4, rtol=1e-4, msg=f"{cond} {t}")

    def test_embedding_scale_invariant(self):
        m = self._model("concat")
        mel, emb = torch.randn(1, 128, 30), torch.randn(1, 16)
        torch.testing.assert_close(m(mel, emb), m(mel, 7 * emb))

    def test_needs_embedding_when_conditioned(self):
        with self.assertRaises(ValueError):
            self._model("film")(torch.randn(1, 128, 10), None)


class LossTest(unittest.TestCase):
    def test_label_map(self):
        lab = np.array([0, 1, 2, 3])
        np.testing.assert_array_equal(L.classes_from_contract(lab), [Mo.NS, Mo.TSS, Mo.NTSS, Mo.TSS])
        np.testing.assert_array_equal(L.classes_from_contract(lab, target_present=False),
                                      [Mo.NS, Mo.NTSS, Mo.NTSS, Mo.NTSS])
        with self.assertRaises(ValueError):
            L.classes_from_contract(np.array([4]))

    def test_wpl_hand_value(self):
        z = torch.tensor([[[0.0], [1.0], [2.0]]])  # one frame: z_ns 0, z_tss 1, z_ntss 2
        y = torch.tensor([[Mo.TSS]])
        loss = L.weighted_pairwise_loss(z, y, torch.ones(1, 1))
        lsig = torch.nn.functional.logsigmoid
        expect = -(lsig(torch.tensor(1.0)) + lsig(torch.tensor(-1.0))) / 2
        torch.testing.assert_close(loss, expect)

    def test_wpl_down_weights_ns_ntss_confusion(self):
        y = torch.tensor([[Mo.NTSS]])
        conf_ns = torch.tensor([[[3.0], [-9.0], [0.0]]])  # ntss frame confused with ns
        conf_tss = torch.tensor([[[-9.0], [3.0], [0.0]]])  # ntss frame confused with tss
        a = L.weighted_pairwise_loss(conf_ns, y, torch.ones(1, 1))
        b = L.weighted_pairwise_loss(conf_tss, y, torch.ones(1, 1))
        self.assertLess(float(a) * 5, float(b))

    def test_mask_ignores_frames(self):
        z = torch.randn(1, 3, 4)
        y = torch.tensor([[0, 1, 2, 1]])
        m = torch.tensor([[1.0, 1.0, 0.0, 0.0]])
        z2 = z.clone()
        z2[..., 2:] = 100 * torch.randn(1, 3, 2)
        torch.testing.assert_close(L.weighted_pairwise_loss(z, y, m), L.weighted_pairwise_loss(z2, y, m))
        torch.testing.assert_close(L.masked_cross_entropy(z, y, m), L.masked_cross_entropy(z2, y, m))


CH_PROJ = {"100": "p1", "200": "p1", "300": "p2", "400": "p3"}


def _partitions():
    utts = {s: [f"{s}-{c}-{i:04d}" for c in ("100", "200", "300") for i in range(20)] for s in ("11", "22", "33")}
    return E.build_partitions(utts, CH_PROJ)


def _bank(parts=None, channels=("mic-a", "mic-b"), variants=(False, True)):
    parts = parts or _partitions()
    rows, spk, utt, ch, cont = [], [], [], [], []
    rng = np.random.default_rng(0)
    for s, part in parts.items():
        for u in E.bank_utterances(part, 40):
            for channel in channels:
                for contaminated in variants:
                    rows.append(rng.normal(size=8))
                    spk.append(s), utt.append(u), ch.append(channel), cont.append(contaminated)
    return E.EnrollmentBank(E.unit(np.array(rows)), np.array(spk), np.array(utt), np.array(ch), np.array(cont), "t", "0")


class PartitionTest(unittest.TestCase):
    def test_project_level_when_several_projects(self):
        part = _partitions()["11"]
        self.assertEqual(part.level, "cross_project")
        proj = lambda pool: {CH_PROJ[E.utterance_chapter(u)] for u in pool}  # noqa: E731
        self.assertFalse(proj(part.enroll) & proj(part.mixture))
        self.assertEqual(len(part.enroll) + len(part.mixture), 60)

    def test_chapter_then_utterance_fallback(self):
        two_ch = E.partition_speaker("7", [f"7-100-{i}" for i in range(6)] + [f"7-200-{i}" for i in range(6)], CH_PROJ)
        self.assertEqual(two_ch.level, "same_project_cross_chapter")
        ch = lambda pool: {E.utterance_chapter(u) for u in pool}  # noqa: E731
        self.assertFalse(ch(two_ch.enroll) & ch(two_ch.mixture))
        one = E.partition_speaker("8", [f"8-100-{i}" for i in range(9)], CH_PROJ)
        self.assertEqual(one.level, "same_chapter")
        self.assertFalse(one.enroll & one.mixture)
        self.assertEqual(len(one.enroll | one.mixture), 9)
        self.assertGreaterEqual(min(len(one.enroll), len(one.mixture)), 4)

    def test_deterministic_and_order_free(self):
        utts = [f"9-{c}-{i}" for c in ("100", "300", "400") for i in range(5)]
        self.assertEqual(E.partition_speaker("9", utts, CH_PROJ), E.partition_speaker("9", utts[::-1], CH_PROJ))

    def test_rejects_unknown_chapter_and_foreign_utterance(self):
        with self.assertRaises(ValueError):
            E.partition_speaker("9", ["9-999-0", "9-999-1"], CH_PROJ)
        with self.assertRaises(ValueError):
            E.partition_speaker("9", ["9-100-0", "10-100-1"], CH_PROJ)

    def test_parse_chapters_txt(self):
        txt = ";ID|READER|MIN|SUBSET|PROJ.|BOOK|T|PT\n199 | 98 | 11.68 | train-clean-360 | 219 | 121 | Ch | Book\n"
        self.assertEqual(E.parse_chapters_txt(txt), {"199": "219"})

    def test_bank_utterances_from_enroll_pool_spread_over_chapters(self):
        part = E.partition_speaker("5", [f"5-{c}-{i:03d}" for c in ("100", "200") for i in range(30)]
                                   + [f"5-300-{i:03d}" for i in range(30)], CH_PROJ)
        b = E.bank_utterances(part, 12)
        self.assertEqual(b, E.bank_utterances(part, 12))
        self.assertTrue(set(b) <= part.enroll)
        if {E.utterance_chapter(u) for u in part.enroll} == {"100", "200"}:
            self.assertEqual({E.utterance_chapter(u) for u in b}, {"100", "200"})


class EnrollmentTest(unittest.TestCase):
    def test_mean_profile_is_unit_mean_of_units(self):
        e = np.array([[2.0, 0.0], [0.0, 1.0]])
        np.testing.assert_allclose(E.mean_profile(e), [np.sqrt(0.5), np.sqrt(0.5)], atol=1e-6)

    def test_bank_check_catches_pool_violation_and_missing_variants(self):
        parts = _partitions()
        _bank(parts).check(parts, ("mic-a", "mic-b"))
        with self.assertRaises(ValueError):
            _bank(parts, variants=(True,)).check(parts, ("mic-a", "mic-b"))
        with self.assertRaises(ValueError):
            _bank(parts, channels=("mic-a",)).check(parts, ("mic-a", "mic-b"))
        swapped = {s: E.SpeakerPartition(p.speaker, p.level, p.mixture, p.enroll) for s, p in parts.items()}
        with self.assertRaises(ValueError):
            _bank(parts).check(swapped, ("mic-a", "mic-b"))
        with self.assertRaises(ValueError):
            _bank(parts).candidates(swapped["11"])

    def test_same_chapter_speakers_cannot_be_targets(self):
        one = E.partition_speaker("8", [f"8-100-{i}" for i in range(9)], CH_PROJ)
        self.assertFalse(E.target_eligible(one))
        with self.assertRaises(ValueError):
            E.check_mixture_targets(one, sorted(one.mixture)[:1])
        parts = dict(_partitions(), **{"8": one})
        bank = _bank({k: v for k, v in parts.items()})
        for i in range(30):
            spk, _ = E.draw_impostor(bank, parts, ["11"], E.EnrollPolicy(), np.random.default_rng(i), "mic-a")
            self.assertNotEqual(spk, "8")

    def test_bank_catalogue_is_cached(self):
        bank = _bank()
        self.assertEqual(bank.channels(), ["mic-a", "mic-b"])
        bank.channel = np.array(["changed"] * len(bank.channel))  # draws must not rescan the column
        self.assertEqual(bank.channels(), ["mic-a", "mic-b"])

    def test_mixture_targets_must_be_in_mixture_pool(self):
        part = _partitions()["22"]
        E.check_mixture_targets(part, sorted(part.mixture)[:2])
        with self.assertRaises(ValueError):
            E.check_mixture_targets(part, sorted(part.enroll)[:1])

    def test_draw_uses_enroll_pool_only(self):
        parts, bank = _partitions(), _bank()
        rng = np.random.default_rng(1)
        for _ in range(100):
            d = E.draw_profile(bank, parts["22"], "mic-a", E.EnrollPolicy(), rng)
            self.assertTrue(set(d.utts) <= parts["22"].enroll)
            self.assertEqual(len(d.utts), d.k)
            self.assertEqual(d.level, "cross_project")
            self.assertAlmostEqual(float(np.linalg.norm(d.profile)), 1.0, places=5)

    def test_clean30_policy_is_exact_or_fails(self):
        parts = _partitions()
        d = E.draw_profile(_bank(parts), parts["33"], "mic-b", E.EnrollPolicy.clean30(), np.random.default_rng(0))
        self.assertEqual(d.k, min(30, len(parts["33"].enroll)))
        self.assertEqual((d.contaminated, d.matched), (0, d.k))
        with self.assertRaises(ValueError):  # only contaminated variants: clean30 cannot be honoured
            E.draw_profile(_bank(parts, variants=(True,)), parts["33"], "mic-b", E.EnrollPolicy.clean30(),
                           np.random.default_rng(0))
        with self.assertRaises(ValueError):  # mixture channel missing from the bank
            E.draw_profile(_bank(parts, channels=("mic-a",)), parts["33"], "mic-b", E.EnrollPolicy.clean30(),
                           np.random.default_rng(0))

    def test_robust_policy_mixes_channels_within_a_profile(self):
        parts, bank = _partitions(), _bank()
        rng = np.random.default_rng(3)
        pol = E.EnrollPolicy(k_choices=(10,))
        draws = [E.draw_profile(bank, parts["11"], "mic-a", pol, rng) for _ in range(300)]
        partial = sum(0 < d.matched < d.k for d in draws)
        self.assertGreater(partial, 250)  # per-dictation channel choice, not all-or-nothing
        self.assertAlmostEqual(np.mean([d.matched / d.k for d in draws]), 0.5, delta=0.05)
        self.assertGreater(sum(d.contaminated > 0 for d in draws), 60)
        rates = [d.contamination_rate for d in draws]
        for r in (0.0, 0.2, 0.4):
            self.assertIn(r, rates)

    def test_impostor_is_absent(self):
        parts, bank = _partitions(), _bank()
        spk, _ = E.draw_impostor(bank, parts, ["11", "22"], E.EnrollPolicy(), np.random.default_rng(0), "mic-a")
        self.assertEqual(spk, "33")

    def test_save_load_roundtrip(self):
        bank = _bank()
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "bank.npz"
            bank.save(p)
            b2 = E.EnrollmentBank.load(p)
        np.testing.assert_array_equal(b2.emb, bank.emb)
        self.assertEqual(list(b2.utt), list(bank.utt))
        self.assertEqual(b2.embedder, "t")

    def test_duplicate_variant_rejected(self):
        b = _bank()
        with self.assertRaises(ValueError):
            E.EnrollmentBank(np.r_[b.emb[:1], b.emb[:1]], b.speaker[[0, 0]], b.utt[[0, 0]], b.channel[[0, 0]],
                             b.contaminated[[0, 0]])


class DataTest(unittest.TestCase):
    def setUp(self):
        spk = Sy.toy_speakers(6)
        self.parts = Sy.toy_partitions(spk)
        self.src = Sy.ToySource(spk, self.parts, seconds=2.0)
        self.bank = Sy.toy_bank(spk, self.parts, Sy.ToyEmbedder(), per_speaker=4)
        self.bank.check(self.parts, Sy.TOY_CHANNELS)

    def _example(self, i, policy=D.ExamplePolicy(), seed=0):
        rngs = D.ExampleRngs.for_example(seed, i)
        return D.build_example(self.src.sample(rngs.mix), self.bank, self.parts, policy, rngs)

    def test_mixture_validation(self):
        with self.assertRaises(ValueError):
            D.Mixture(np.zeros(320, np.float32), np.zeros(3, np.int8), "1", (), ("1",), "S0", "m")

    def test_absent_target_has_no_target_frames(self):
        pol = D.ExamplePolicy(p_absent_target=1.0)
        for i in range(5):
            ex = self._example(i, pol)
            self.assertTrue(ex.info["absent_target"])
            self.assertNotEqual(ex.info["impostor"], ex.info["target"])
            self.assertFalse(np.any(ex.classes == Mo.TSS))

    def test_policies_share_mixtures_and_absent_flags(self):
        robust = D.ExamplePolicy()
        clean = D.ExamplePolicy(enroll=E.EnrollPolicy(k_choices=(4,), contamination_rates=(0.0,),
                                                      contamination_probs=(1.0,), p_match_channel=1.0))
        for i in range(20):
            a, b = self._example(i, robust), self._example(i, clean)
            np.testing.assert_array_equal(a.audio, b.audio)
            np.testing.assert_array_equal(a.classes, b.classes)
            self.assertEqual(a.info["absent_target"], b.info["absent_target"])
        self.assertTrue(any(self._example(i).info["absent_target"] for i in range(60)))

    def test_rejects_target_from_enroll_pool(self):
        rngs = D.ExampleRngs.for_example(0, 0)
        mix = self.src.sample(rngs.mix)
        bad = D.Mixture(mix.audio, mix.labels, mix.target_speaker, (sorted(self.parts[mix.target_speaker].enroll)[0],),
                        mix.speakers, mix.scenario, mix.channel)
        with self.assertRaises(ValueError):
            D.build_example(bad, self.bank, self.parts, D.ExamplePolicy(), rngs)

    def test_prepare_batch_crops_whole_mixture_features(self):
        exs = [self._example(i) for i in range(3)]
        exs[1].audio = exs[1].audio[:16_000 + 77]
        exs[1].classes = exs[1].classes[: api.frame_count(16_077)]
        batch = D.collate(exs)
        fe = F.ParakeetFrontEnd()
        out = D.prepare_batch(batch, fe, 120, np.random.default_rng(5), "cpu")
        self.assertEqual(tuple(out["mel"].shape), (3, 128, 120))
        for i, e in enumerate(exs):
            s = out["starts"][i]
            self.assertEqual(s % 2, 0)
            full = F.features_np(e.audio, fe)
            n = min(120, len(e.classes) - s)
            np.testing.assert_allclose(out["mel"][i, :, :n].numpy(), full[:, s: s + n], atol=1e-4)
            np.testing.assert_array_equal(out["classes"][i, :n].numpy(), e.classes[s: s + n])
            self.assertEqual(int(out["mask"][i].sum()), n)


class MetricsTest(unittest.TestCase):
    def test_auc_against_sklearn(self):
        from sklearn.metrics import roc_auc_score

        rng = np.random.default_rng(0)
        pos, neg = rng.normal(1, 1, 300).round(1), rng.normal(0, 1, 200).round(1)
        ref = roc_auc_score(np.r_[np.ones(300), np.zeros(200)], np.r_[pos, neg])
        self.assertAlmostEqual(M.roc_auc(pos, neg), ref, places=10)
        self.assertEqual(M.roc_auc([1, 2], [0]), 1.0)
        self.assertEqual(M.roc_auc([0], [1, 2]), 0.0)
        self.assertEqual(M.roc_auc([1, 1], [1]), 0.5)
        self.assertTrue(np.isnan(M.roc_auc([], [1])))

    def test_ap_against_sklearn(self):
        from sklearn.metrics import average_precision_score

        rng = np.random.default_rng(1)
        y = rng.random(500) < 0.3
        s = (y * 0.5 + rng.random(500)).round(2)
        self.assertAlmostEqual(M.average_precision(s, y), average_precision_score(y, s), places=10)

    def test_eer_interpolates(self):
        self.assertEqual(M.eer([2, 3, 4], [0, 1]), 0.0)
        self.assertAlmostEqual(M.eer([0, 1], [0]), 1 / 3)
        self.assertAlmostEqual(M.eer(np.arange(100), np.arange(100)), 0.5, delta=0.02)
        rng = np.random.default_rng(2)
        pos, neg = rng.normal(1.5, 1, 4000), rng.normal(0, 1, 4000)
        from scipy.stats import norm

        self.assertAlmostEqual(M.eer(pos, neg), norm.cdf(-0.75), delta=0.015)

    def test_pass_rate(self):
        pos = np.arange(100, dtype=float)
        self.assertEqual(M.pass_rate_at_miss(pos, np.array([1.5, 50.0, -1.0, 2.0]), 0.02), 0.5)  # thr = pos[2] = 2
        self.assertEqual(M.pass_rate_at_miss(pos, np.array([1.0]), 0.0), 1.0)

    def test_frame_metrics_keys(self):
        lab = np.array([0, 1, 2, 3, 1, 2])
        p = np.array([0.1, 0.9, 0.2, 0.8, 0.7, 0.3])
        post = np.stack([1 - p, p, np.zeros_like(p)], axis=1)
        fm = M.frame_metrics(p, lab, post)
        self.assertEqual(fm["auc_tgt_vs_intf"], 1.0)
        self.assertEqual(fm["n_tgt"], 3)
        for k in ("ap_tss", "ap_ns", "ap_ntss"):
            self.assertIn(k, fm)

    def test_logit_from_logits(self):
        z = np.array([[0.0, 1.0, -1.0], [-30.0, 30.0, -30.0], [5.0, -40.0, 5.0]])
        ref = z[:, 1] - np.log(np.exp(z[:, 0]) + np.exp(z[:, 2]))
        np.testing.assert_allclose(M.logit_from_logits(z), ref)

    def test_saturating_logits_stay_ordered(self):
        # Review core-r3: float32 softmax gives P = 1 for both; the log-odds keep them apart.
        z_t, z_i = np.tile([0.0, 21.0, 0.0], (100, 1)), np.tile([0.0, 20.0, 0.0], (100, 1))
        p32 = torch.softmax(torch.tensor(np.r_[z_t, z_i], dtype=torch.float32), dim=1)[:, 1].numpy()
        self.assertTrue(np.all(p32 == 1.0))
        lab = np.r_[np.ones(100, int), np.full(100, 2)]
        score = M.logit_from_logits(np.r_[z_t, z_i])
        fm = M.frame_metrics(score, lab)
        self.assertEqual((fm["auc_tgt_vs_intf"], fm["intf_pass_at_2pct_miss"]), (1.0, 0.0))
        r = M.FrameRanks([score], [lab])
        self.assertEqual((r.auc(np.ones(1)), r.pass_at_miss(np.ones(1))), (1.0, 0.0))
        # Review core-r2 fixture, as exact float64 log-odds of the probabilities
        p = np.r_[np.full(1000, 0.9999), np.full(1000, 0.9998)]
        lab2 = np.r_[np.ones(1000, int), np.full(1000, 2)]
        r2 = M.FrameRanks([np.log(p) - np.log1p(-p)], [lab2])
        self.assertEqual((r2.auc(np.ones(1)), r2.pass_at_miss(np.ones(1))), (1.0, 0.0))

    def test_frame_ranks_exact_and_weighted(self):
        rng = np.random.default_rng(4)
        scores, labels = [], []
        for i in range(5):
            lab = rng.integers(0, 4, 300)
            scores.append(rng.normal(1.5 * ((lab == 1) | (lab == 3)), 1.0).round(1))  # ties on purpose
            labels.append(lab)
        r = M.FrameRanks(scores, labels)
        s, l = np.concatenate(scores), np.concatenate(labels)
        tgt, intf = s[(l == 1) | (l == 3)], s[l == 2]
        self.assertAlmostEqual(r.auc(np.ones(5)), M.roc_auc(tgt, intf), places=12)
        self.assertAlmostEqual(r.pass_at_miss(np.ones(5)), M.pass_rate_at_miss(tgt, intf), places=12)
        w = np.array([2.0, 0.0, 1.0, 3.0, 1.0])  # weight k == item repeated k times
        rep = [i for i in range(5) for _ in range(int(w[i]))]
        s2 = np.concatenate([scores[i] for i in rep])
        l2 = np.concatenate([labels[i] for i in rep])
        t2, i2 = s2[(l2 == 1) | (l2 == 3)], s2[l2 == 2]
        self.assertAlmostEqual(r.auc(w), M.roc_auc(t2, i2), places=12)
        self.assertAlmostEqual(r.pass_at_miss(w), M.pass_rate_at_miss(t2, i2), places=12)

    def test_frame_bootstrap_uses_exact_statistics(self):
        # Review core-r3 fixture: two mixtures with disjoint speakers, one nearly tied.
        a_s, a_l = np.r_[np.full(100, 10.0), np.full(100, -10.0)], np.r_[np.ones(100, int), np.full(100, 2)]
        b_s, b_l = np.array([1.0005, 1.001]), np.array([1, 2])
        r = M.FrameRanks([a_s, b_s], [a_l, b_l])
        items = [("p", "q"), ("x", "y")]
        out = M.frame_bootstrap(r, items, "auc_tgt_vs_intf", n_boot=400)
        self.assertEqual((out["lo"], out["hi"]), (0.0, 1.0))  # resamples holding only mixture b exist
        same = M.frame_bootstrap(r, items, "auc_tgt_vs_intf", other=r, n_boot=50)
        self.assertEqual((same["point"], same["lo"], same["hi"]), (0.0, 0.0, 0.0))
        with self.assertRaises(ValueError):
            M.frame_bootstrap(r, items[:1], "auc_tgt_vs_intf")

    def test_joint_weights_need_every_speaker(self):
        items = [("a",), ("a", "b"), ("b", "c")]
        w = M.joint_weights(items, {"a": 2, "b": 0, "c": 3})
        np.testing.assert_array_equal(w, [2, 0, 0])
        w = M.joint_weights(items, {"a": 2, "b": 1, "c": 3})
        np.testing.assert_array_equal(w, [2, 2, 3])
        np.testing.assert_array_equal(M.joint_weights([("a", "a")], {"a": 2}), [2])

    def test_joint_bootstrap(self):
        vals = np.array([1.0, 0.0, 0.5])
        items = [("a",), ("b",), ("a", "b")]
        stat = lambda w: float((w * vals).sum() / w.sum())  # noqa: E731
        r = M.joint_bootstrap(items, stat, n_boot=300)
        self.assertEqual(r["n_speakers"], 2)
        self.assertLessEqual(r["lo"], r["point"])
        self.assertLessEqual(r["point"], r["hi"])
        self.assertEqual((r["lo"], r["hi"]), (0.0, 1.0))  # resamples of only a or only b exist
        one = M.joint_bootstrap([("a",), ("a",)], lambda w: float(w.sum() / 2 / w.max()), n_boot=50)
        self.assertEqual((one["lo"], one["hi"]), (1.0, 1.0))
        paired = M.joint_bootstrap(items, lambda w: stat(w) - stat(w), n_boot=50)
        self.assertEqual((paired["point"], paired["lo"], paired["hi"]), (0.0, 0.0, 0.0))


class ScorerTest(unittest.TestCase):
    def _scorer(self, cond="film_cos", **kw):
        torch.manual_seed(0)
        m = Mo.PVAD(Mo.config_for("S", cond, 16))
        with torch.no_grad():
            for p in m.parameters():
                p.add_(0.05 * torch.randn_like(p))
        kw.setdefault("embedder_macs_per_s", 1e6)
        return Sc.PVADScorer(m, Sy.ToyEmbedder(), **kw)

    def test_conforms_and_scores_validly(self):
        s = self._scorer()
        self.assertIsInstance(s, api.TargetSpeakerScorer)
        prof = s.enroll([_audio(16_000, 1), _audio(20_000, 2), _audio(9_000, 3)])
        self.assertIsInstance(prof, api.Profile)
        for n in (0, 1, 160, 161, 16_000, 33_333):
            api.check_scores(s.score(prof, _audio(n, 4)), n)

    def test_profile_bytes_roundtrip_and_constant_size(self):
        s = self._scorer()
        prof = s.enroll([_audio(16_000, 1)])
        size = len(prof.to_bytes())
        for i in range(3):
            prof = s.update(prof, _audio(16_000 * (i + 1), 10 + i))
            self.assertEqual(len(prof.to_bytes()), size)
        back = Sc.PVADProfile.from_bytes(prof.to_bytes())
        self.assertEqual(back.count, 4)
        np.testing.assert_array_equal(back.mean, prof.mean)
        self.assertEqual(size, s.cost().profile_bytes)

    def test_mean_update_matches_batch_enroll(self):
        s = self._scorer()
        us = [_audio(16_000, i) for i in range(4)]
        a = s.enroll(us)
        b = s.enroll(us[:1])
        for u in us[1:]:
            b = s.update(b, u)
        np.testing.assert_allclose(a.embedding(), b.embedding(), atol=1e-5)
        e = np.stack([s.embedder.embed(u) for u in us])
        np.testing.assert_allclose(a.embedding(), E.mean_profile(e), atol=1e-5)

    def test_gated_update_skips_when_nothing_passes(self):
        s = self._scorer(update_rule="gated", gate=1.01)
        prof = s.enroll([_audio(16_000, 1)])
        after = s.update(prof, _audio(16_000, 2))
        self.assertEqual(after.count, prof.count)

    def test_recalibration_shift_is_monotone(self):
        s = self._scorer(recal_population=0.0)
        prof = s.enroll([_audio(16_000, 1)])
        audio = _audio(16_000, 5)
        base = s.score(prof, audio)
        shifted = Sc.PVADProfile(prof.count, prof.mean, recal_n=1, recal_mean=-2.0)
        up = s.score(shifted, audio)
        self.assertTrue(np.all(up >= base - 1e-6))
        self.assertTrue(np.array_equal(np.argsort(up, kind="stable"), np.argsort(base, kind="stable"))
                        or np.allclose(up, base))

    def test_recal_statistic_and_population_fit(self):
        self.assertIsNone(Sc.recal_statistic(np.full(50, 0.9, np.float32)))
        p = np.r_[np.full(100, 0.9), np.full(100, 0.1)].astype(np.float32)
        self.assertAlmostEqual(Sc.recal_statistic(p), float(np.log(9.0)), places=4)
        s = self._scorer(gate=0.0)
        prof = s.enroll([_audio(16_000, 1)])
        q = Sc.fit_recal_population(s, [(prof, [_audio(16_000, 2), _audio(16_000, 3)])])
        self.assertTrue(np.isfinite(q))

    def test_unconditioned_scorer(self):
        s = self._scorer("none")
        prof = s.enroll([_audio(8_000, 1)])
        api.check_scores(s.score(prof, _audio(8_000, 2)), 8_000)

    def test_cost_within_budget_and_includes_embedder(self):
        s = self._scorer()
        c = s.cost()
        self.assertLessEqual(c.macs_per_audio_second, 20e6)
        self.assertEqual(c.reads_parakeet_layers, ())
        self.assertEqual(c.params, Mo.param_count(s.model) + Sy.ToyEmbedder.params)
        self.assertEqual(c.update_macs, 10 * 1e6)  # mean rule: one embedder pass, no PVAD pass
        gated = self._scorer(update_rule="gated").cost()
        self.assertGreater(gated.update_macs, c.update_macs)

    def test_cost_refuses_unknown_embedder_cost(self):
        s = self._scorer(embedder_macs_per_s=None)
        with self.assertRaises(ValueError):
            s.cost()
        none = self._scorer("none", embedder_macs_per_s=None).cost()
        self.assertEqual(none.update_macs, 0.0)

    def test_update_runs_at_most_one_pvad_pass(self):
        for rule, recal in (("mean", None), ("mean", 0.0), ("gated", None), ("gated", 0.0)):
            s = self._scorer(update_rule=rule, recal_population=recal, gate=0.0)
            prof = s.enroll([_audio(16_000, 1)])
            calls = []
            orig = s._posteriors
            s._posteriors = lambda e, a: (calls.append(1), orig(e, a))[1]
            s.update(prof, _audio(16_000, 2))
            expected = 1 if (rule == "gated" or recal is not None) else 0
            self.assertEqual(len(calls), expected, (rule, recal))
            self.assertEqual(s.cost().update_macs > 10 * 1e6, expected == 1)


class TrainSmokeTest(unittest.TestCase):
    def test_tiny_toy_run_learns_and_reloads(self):
        import json

        from lfspk.pvad import train as T

        with tempfile.TemporaryDirectory() as d:
            cfg = T.TrainConfig(out_dir=d, size="S", steps=40, batch=8, crop_s=2.0, lr=3e-3, warmup=5, num_workers=0,
                                device="cpu", log_every=10, eval_every=40,
                                source={"kind": "toy", "speakers": 8, "seconds": 2.0})
            cfg_path = Path(d) / "config.json"
            cfg_path.write_text(json.dumps(cfg.__dict__))
            parts = T.make_partitions(cfg.source)
            src = T.make_source(cfg.source, parts)
            bank = T.make_bank(cfg, parts)
            dev = []
            for i in range(4):
                rngs = D.ExampleRngs.for_example(99, i)
                mix = src.sample(rngs.mix)
                dev.append((mix, E.draw_profile(bank, parts[mix.target_speaker], mix.channel, E.EnrollPolicy(),
                                                rngs.enroll).profile))
            ckpt = T.train(T.TrainConfig.from_json(cfg_path), dev)
            log = (Path(d) / "log.jsonl").read_text()
            losses = [json.loads(l)["loss"] for l in log.splitlines() if '"loss"' in l]
            self.assertLess(losses[-1], losses[0])
            model, meta = T.load_model(ckpt)
            self.assertEqual(meta["model"]["conditioning"], "film_cos")
            dev_rec = [json.loads(l) for l in log.splitlines() if "dev_frames" in l][-1]["dev_frames"]["pooled"]
            for k in ("ap_tss", "ap_ns", "ap_ntss"):
                self.assertIn(k, dev_rec)
            T.TrainConfig.from_json(cfg_path)  # the input config is still runnable


class _FakeUtt:
    def __init__(self, seconds):
        self.seconds = seconds


class _FakeRendered:
    def __init__(self, utt, spk, scenario, meta_extra):
        n = 16_000 * 2
        self.audio = np.zeros(n, np.float32)
        self.labels = np.zeros(api.frame_count(n), np.uint8)
        self.meta = {"target": {"utt": utt, "speaker": spk}, "scenario": scenario, **meta_extra}


class _FakeGen:
    """Stand-in for W0's MixtureGenerator: records calls, returns silent mixtures."""

    def __init__(self, utts, seconds=5.0):
        self.corpus = type("C", (), {"utterance_by_id": {u: _FakeUtt(seconds) for u in utts}})()
        self.calls = []

    def render(self, scenario, seed, target=None, device="builtin", rir_mode="coherent"):
        self.calls.append((scenario, seed, target, device, rir_mode))
        spk = target.split("-")[0]
        meta = {"interferers": [{"speaker": "99"}, {"speakers": ["98", "97"]}, {"speakers": []}]}
        return _FakeRendered(target, spk, scenario, meta)


class W0SourceTest(unittest.TestCase):
    def setUp(self):
        from lfspk.pvad import w0_source as W

        self.W = W
        self.parts = _partitions()
        self.parts["8"] = E.partition_speaker("8", [f"8-100-{i}" for i in range(9)], CH_PROJ)  # same_chapter
        utts = [u for p in self.parts.values() for u in p.enroll | p.mixture]
        self.gen = _FakeGen(utts)

    def test_targets_from_mixture_pool_of_eligible_speakers(self):
        src = self.W.W0Source(self.parts, generator=self.gen)
        self.assertNotIn("8", src.targets)
        rng = np.random.default_rng(0)
        for _ in range(200):
            m = src.sample(rng)
            self.assertIn(m.target_utts[0], self.parts[m.target_speaker].mixture)
            self.assertEqual(m.speakers, (m.target_speaker, "99", "98", "97"))
        sc = [c[0] for c in self.gen.calls]
        self.assertEqual(set(sc), {"S0", "S1", "S2", "S3", "S4"})
        self.assertEqual({c[3] for c in self.gen.calls}, {"builtin"})
        mixed = np.mean([c[4] == "mixed" for c in self.gen.calls])
        self.assertAlmostEqual(mixed, 0.2, delta=0.08)

    def test_length_filter_and_split_guard(self):
        short = _FakeGen(list(self.gen.corpus.utterance_by_id), seconds=1.0)
        with self.assertRaises(ValueError):
            self.W.W0Source(self.parts, generator=short)
        with self.assertRaises(ValueError):
            self.W.W0Source(self.parts, split="dev", generator=self.gen)

    def test_wrong_target_rendered_is_an_error(self):
        src = self.W.W0Source(self.parts, generator=self.gen)
        orig = self.gen.render
        self.gen.render = lambda *a, **k: _FakeRendered("11-100-0000", "11", "S0", {"interferers": []})
        with self.assertRaises(AssertionError):
            for i in range(20):
                src.sample(np.random.default_rng(i))
        self.gen.render = orig


class ResumeTest(unittest.TestCase):
    def setUp(self):
        spk = Sy.toy_speakers(6)
        self.parts = Sy.toy_partitions(spk)
        self.src = Sy.ToySource(spk, self.parts, seconds=1.0)
        self.bank = Sy.toy_bank(spk, self.parts, Sy.ToyEmbedder(), per_speaker=3)

    def _batches(self, start, n, workers):
        stream = D.ExampleStream(self.src, self.bank, self.parts, D.ExamplePolicy(), seed=3, start_step=start, batch=2)
        loader = torch.utils.data.DataLoader(stream, batch_size=2, collate_fn=D.collate, num_workers=workers)
        it = iter(loader)
        return [next(it) for _ in range(n)]

    def test_stream_independent_of_worker_count(self):
        one, two = self._batches(0, 4, 0), self._batches(0, 4, 2)
        for a, b in zip(one, two):
            torch.testing.assert_close(a["audio"], b["audio"])

    def test_resumed_loader_continues_the_stream(self):
        for workers in (0, 2):
            full = self._batches(0, 7, workers)
            resumed = self._batches(3, 4, workers)
            for a, b in zip(full[3:], resumed):
                torch.testing.assert_close(a["audio"], b["audio"])
                torch.testing.assert_close(a["emb"], b["emb"])

    def test_training_resume_matches_uninterrupted(self):
        import json
        import shutil

        from lfspk.pvad import train as T

        with tempfile.TemporaryDirectory() as d:
            base = dict(size="S", steps=12, batch=4, crop_s=1.0, lr=3e-3, warmup=2, num_workers=0, device="cpu",
                        log_every=6, eval_every=100, ckpt_every=6, source={"kind": "toy", "speakers": 6, "seconds": 1.0})
            a = T.train(T.TrainConfig(out_dir=f"{d}/a", **base))
            Path(f"{d}/b").mkdir()
            shutil.copy(f"{d}/a/last.pt", f"{d}/b/last.pt")  # the state at step 6
            b = T.train(T.TrainConfig(out_dir=f"{d}/b", **base))
            sa, sb = torch.load(a, weights_only=True)["model"], torch.load(b, weights_only=True)["model"]
            for k in sa:
                torch.testing.assert_close(sa[k], sb[k], msg=k)
            meta = json.loads(Path(f"{d}/b/run_meta.json").read_text())
            self.assertEqual(meta["resumed_from_step"], 6)


class ResumeIdentityTest(unittest.TestCase):
    def _cfg(self, d, **kw):
        from lfspk.pvad import train as T

        base = dict(out_dir=d, size="S", steps=4, batch=2, crop_s=1.0, warmup=1, num_workers=0, device="cpu",
                    log_every=2, eval_every=100, ckpt_every=2, source={"kind": "toy", "speakers": 6, "seconds": 1.0})
        base.update(kw)
        return T.TrainConfig(**base)

    def _partial(self, d):
        """A run dir holding only the step-2 checkpoint of a 4-step run."""
        import shutil

        from lfspk.pvad import train as T

        T.train(self._cfg(f"{d}/full"))
        Path(f"{d}/part").mkdir()
        shutil.copy(f"{d}/full/last.pt", f"{d}/part/last.pt")
        return f"{d}/part"

    def test_resume_refuses_a_changed_experiment(self):
        from lfspk.pvad import train as T

        with tempfile.TemporaryDirectory() as d:
            part = self._partial(d)
            for change in ({"seed": 1}, {"enroll_policy": "clean30"}, {"lr": 1e-3}, {"p_absent_target": 0.2}):
                with self.assertRaises(ValueError, msg=str(change)):
                    T.train(self._cfg(part, **change))
            T.train(self._cfg(part, log_every=1))  # a declared-safe change resumes
            self.assertTrue((Path(part) / "final.pt").exists())

    def test_finished_and_stale_dirs_are_refused(self):
        from lfspk.pvad import train as T

        with tempfile.TemporaryDirectory() as d:
            T.train(self._cfg(f"{d}/a"))
            with self.assertRaises(ValueError):
                T.train(self._cfg(f"{d}/a"))
            Path(f"{d}/b").mkdir()
            (Path(f"{d}/b") / "log.jsonl").write_text("{}\n")
            with self.assertRaises(ValueError):
                T.train(self._cfg(f"{d}/b"))

    def test_monitor_from_another_embedder_is_refused(self):
        from lfspk.pvad import train as T

        with tempfile.TemporaryDirectory() as d:
            mon = Path(d) / "mon.npz"
            np.savez(mon, embedder=np.array("titanet-s"), embedder_sha256=np.array("1" * 64))
            bank = _bank()
            with self.assertRaises(ValueError):
                T._check_monitor(self._cfg(d, dev_monitor=str(mon)), bank)
            np.savez(mon, embedder=np.array(bank.embedder), embedder_sha256=np.array(bank.embedder_sha256))
            T._check_monitor(self._cfg(d, dev_monitor=str(mon)), bank)

    def test_deterministic_flags_are_restored(self):
        from lfspk.pvad import train as T

        before = (torch.are_deterministic_algorithms_enabled(), torch.is_deterministic_algorithms_warn_only_enabled())
        try:
            for state in ((False, False), (True, True)):
                torch.use_deterministic_algorithms(state[0], warn_only=state[1])
                with tempfile.TemporaryDirectory() as d:
                    T.train(self._cfg(f"{d}/a", steps=2))
                self.assertEqual((torch.are_deterministic_algorithms_enabled(),
                                  torch.is_deterministic_algorithms_warn_only_enabled()), state)
        finally:
            torch.use_deterministic_algorithms(before[0], warn_only=before[1])

    def test_wrong_cublas_workspace_is_refused(self):
        import os

        from lfspk.pvad import train as T

        old = os.environ.get("CUBLAS_WORKSPACE_CONFIG")
        os.environ["CUBLAS_WORKSPACE_CONFIG"] = ":16:8"
        try:
            with tempfile.TemporaryDirectory() as d:
                with self.assertRaises(RuntimeError):
                    T.train(self._cfg(f"{d}/a", steps=2))
                T.train(self._cfg(f"{d}/b", steps=2, deterministic=False))
        finally:
            if old is None:
                os.environ.pop("CUBLAS_WORKSPACE_CONFIG")
            else:
                os.environ["CUBLAS_WORKSPACE_CONFIG"] = old


class SmokeResumeCheckTest(unittest.TestCase):
    def test_run_dirs_never_collide(self):
        from unittest import mock

        from lfspk.pvad import smoke_throughput as SM

        with tempfile.TemporaryDirectory() as d, mock.patch.object(SM, "OUT", Path(d)):
            dirs = [SM.run_dir("resume") for _ in range(5)]  # same second, same pid
        self.assertEqual(len(set(dirs)), 5)

    def test_accepts_indexed_cuda_device(self):
        from unittest import mock

        from lfspk.pvad import smoke_throughput as SM

        def fake_train(cfg, dev_items=None):
            out = Path(cfg.out_dir)
            out.mkdir(parents=True, exist_ok=True)
            (out / "run_meta.json").write_text(json.dumps({"train": {"device": cfg.device}}))
            (out / "last.pt").write_bytes(b"x")
            torch.save({"model": {"w": torch.zeros(2)}}, out / "final.pt")
            return out / "final.pt"

        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(SM, "OUT", Path(d)), mock.patch.object(SM, "train", fake_train), \
                mock.patch("torch.cuda.is_available", return_value=True), \
                mock.patch("torch.cuda.is_initialized", return_value=True), \
                mock.patch("torch.cuda.get_device_name", return_value="fake"):
            res = SM.resume_check("cuda:0")
            self.assertTrue(res["det"]["bit_identical"])
            with mock.patch("torch.cuda.is_initialized", return_value=False):
                with self.assertRaises(RuntimeError):
                    SM.resume_check("cuda:0")


class IdentityTest(unittest.TestCase):
    def test_mixer_identity_covers_mixer_modules_only(self):
        from lfspk.pvad import identity as I

        names = {p.name for p in I.mixer_modules()}
        self.assertIn("mix.py", names)
        self.assertIn("activity.py", names)
        self.assertNotIn("evaluate.py", names)  # evaluator edits must not invalidate rendered data

    def test_mismatches(self):
        from lfspk.pvad import identity as I

        self.assertEqual(I.mismatches({"a": 1, "b": [1, 2]}, {"a": 1, "b": [1, 2]}), [])
        self.assertEqual(I.mismatches({"a": 1, "b": 2}, {"a": 1, "c": 2}), ["b", "c"])
        self.assertEqual(I.mismatches({"a": 1, "x": 2}, {"a": 1, "x": 3}, ignore=("x",)), [])
        with self.assertRaises(ValueError):
            I.require_same({"a": 1}, {"a": 2}, "thing")


class LaunchTest(unittest.TestCase):
    def test_runs_differ_only_in_the_factor_under_test(self):
        from lfspk.pvad import launch as La

        with tempfile.TemporaryDirectory() as d:
            cfgs = [La.run_config(n, s, "/x/bank.npz", 1000, root=Path(d)) for n in La.RUNS for s in (0, 1)]
            common = La.common_fields(cfgs)
            self.assertEqual(common["steps"], 1000)
            self.assertEqual(len({c.out_dir for c in cfgs}), len(cfgs))
            cfgs[0].lr = 1e-3
            with self.assertRaises(ValueError):
                La.common_fields(cfgs)
            cmd = La.job_command(cfgs[1])
            self.assertIn("gpu:shared", cmd)
            self.assertIn("lfspk.pvad.train", cmd)

    def test_preregistered_runs(self):
        from lfspk.pvad import launch as La

        self.assertEqual(La.RUNS["M-none"], ("M", "none", "robust"))
        self.assertEqual(La.RUNS["M-film_cos-clean30"], ("M", "film_cos", "clean30"))
        self.assertEqual(len(La.RUNS), 7)


class BankBuildTest(unittest.TestCase):
    def _write_shard(self, out, rows, emb, identity, keep=None):
        keep = np.ones(len(rows), bool) if keep is None else keep
        col = lambda k: np.array([r[k] for r in rows])[keep]  # noqa: E731
        np.savez(out / "parts" / "part-0000.npz", emb=emb[keep], speaker=col(0), utt=col(1), channel=col(2),
                 contaminated=col(3), contaminator=np.array([""] * int(keep.sum())), identity=np.array(json.dumps(identity)))

    def setUp(self):
        from lfspk.pvad import bank_build as B

        self.B = B
        self.parts = _partitions()
        self.items = [(s, E.bank_utterances(p, 5)) for s, p in sorted(self.parts.items())]
        self.devices = ("builtin", "headset")
        w0 = {"w0_code_sha256": "c" * 64, "w0_commit": "abc", "w0_index_hashes": {"librispeech": "h"}}
        self.identity = B.bank_identity("toy", "0" * 64, self.devices, w0)
        self.rows = [(s, u, dev, c) for s, us in self.items for u in us for dev in self.devices for c in (False, True)]
        self.emb = E.unit(np.random.default_rng(0).normal(size=(len(self.rows), 8)))
        self.shards = [self.items]  # one shard

    def test_merge_checks_and_writes(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "parts").mkdir()
            self._write_shard(out, self.rows, self.emb, self.B.shard_identity(self.identity, self.items))
            path = self.B.merge(out, self.identity, 1, self.items, self.parts, self.shards)
            bank = E.EnrollmentBank.load(path)
            self.assertEqual(len(bank.emb), len(self.rows))
            meta = json.loads((out / "bank_meta.json").read_text())
            self.assertEqual(meta["rows"], len(self.rows))
            self.assertEqual(meta["identity"]["w0_index_hashes"], {"librispeech": "h"})
            # a missing variant must fail the merge
            keep = np.array([not (r[2] == "headset" and r[3]) for r in self.rows])
            self._write_shard(out, self.rows, self.emb, self.B.shard_identity(self.identity, self.items), keep)
            with self.assertRaises(ValueError):
                self.B.merge(out, self.identity, 1, self.items, self.parts, self.shards)

    def test_stale_shards_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "parts").mkdir()
            for change in ({"w0_code_sha256": "d" * 64}, {"weights_sha256": "1" * 64},
                           {"w0_index_hashes": {"librispeech": "other"}}):
                stale = self.B.shard_identity({**self.identity, **change}, self.items)
                self._write_shard(out, self.rows, self.emb, stale)
                with self.assertRaises(ValueError):
                    self.B.merge(out, self.identity, 1, self.items, self.parts, self.shards)
            ok = self.B.shard_identity({**self.identity, "w0_commit": "other"}, self.items)  # commit is not compared
            self._write_shard(out, self.rows, self.emb, ok)
            self.B.merge(out, self.identity, 1, self.items, self.parts, self.shards)
            np.savez(out / "parts" / "part-0007.npz", emb=self.emb[:1])  # an unexpected extra shard
            with self.assertRaises(ValueError):
                self.B.merge(out, self.identity, 1, self.items, self.parts, self.shards)

    def test_render_seed_is_stable_and_device_specific(self):
        B = self.B
        self.assertEqual(B.render_seed("1-2-3", "builtin"), B.render_seed("1-2-3", "builtin"))
        self.assertNotEqual(B.render_seed("1-2-3", "builtin"), B.render_seed("1-2-3", "headset"))
        self.assertLess(B.render_seed("1-2-3", "builtin"), 2**62)


class DevMonTest(unittest.TestCase):
    def test_select_caps_and_is_deterministic(self):
        from lfspk.pvad import devmon as DM

        manifest = [{"id": f"{sc}-{spk}-{j}", "scenario": sc, "speaker": spk, "rir_mode": mode}
                    for sc in ("S0", "S4") for spk in ("1", "2", "3") for j in range(5) for mode in ("coherent", "mixed")]
        rows = DM.select(manifest, per_scenario=4, per_speaker=2)
        self.assertEqual(rows, DM.select(list(reversed(manifest)), per_scenario=4, per_speaker=2))
        self.assertEqual(sum(r["scenario"] == "S0" for r in rows), 4)
        self.assertTrue(all(r["rir_mode"] == "coherent" for r in rows))
        for sc in ("S0", "S4"):
            for spk in ("1", "2", "3"):
                self.assertLessEqual(sum(r["scenario"] == sc and r["speaker"] == spk for r in rows), 2)

    def test_check_dev_rejects_test_sets(self):
        from lfspk.pvad import devmon as DM

        rows = [{"id": "S0-84-00", "speaker": "84", "meta": {"split": "dev"}}]
        DM.check_dev(rows, {"84"})
        with self.assertRaises(ValueError):
            DM.check_dev([{**rows[0], "meta": {"split": "test"}}], {"84"})
        with self.assertRaises(ValueError):
            DM.check_dev([{**rows[0], "speaker": "1089"}], {"84"})  # a test-clean speaker
        with self.assertRaises(ValueError):
            DM.check_dev([], {"84"})


class SelectionRuleTest(unittest.TestCase):
    def _rule(self, points, g_ok, his):
        from lfspk.pvad import compare as C

        names = ["S", "Mc", "Mf", "Mfc", "L"]
        calls = []

        def hi(a, b):
            calls.append((a, b))
            return his[a]

        return C.select_rule(names, points, g_ok, hi), calls

    def test_reviewer_counterexample_is_unique(self):
        # M indistinguishable from the best L, S indistinguishable from M but worse than L:
        # comparisons are against R = L only, so S (worse than L) is not selected; M is.
        points = {"S": 0.30, "Mc": 0.40, "Mf": 0.40, "Mfc": 0.26, "L": 0.25}
        his = {"S": 0.08, "Mc": 0.2, "Mf": 0.2, "Mfc": 0.015, "L": 0.0}
        out, calls = self._rule(points, dict.fromkeys(points, True), his)
        self.assertEqual((out["selected"], out["reference"]), ("Mfc", "L"))
        self.assertTrue(all(b == "L" for _, b in calls))

    def test_reference_selected_when_nothing_is_non_inferior(self):
        points = {"S": 0.3, "Mc": 0.3, "Mf": 0.3, "Mfc": 0.3, "L": 0.1}
        out, _ = self._rule(points, dict.fromkeys(points, True), dict.fromkeys(points, 0.5))
        self.assertEqual(out["selected"], "L")

    def test_guardrail_and_ties(self):
        points = {"S": 0.1, "Mc": 0.1, "Mf": 0.2, "Mfc": 0.2, "L": 0.05}
        g = {"S": True, "Mc": True, "Mf": True, "Mfc": True, "L": False}
        out, _ = self._rule(points, g, dict.fromkeys(points, 1.0))
        self.assertEqual((out["reference"], out["selected"]), ("S", "S"))  # L fails G; S wins the tie by order
        out, _ = self._rule(points, dict.fromkeys(points, False), {})
        self.assertIsNone(out["selected"])

    def test_select_requires_half_a(self):
        from lfspk.pvad import compare as C

        with self.assertRaises(ValueError):
            C.select("dev-v1", "B", [])

    def test_candidates_are_put_in_the_fixed_order(self):
        from lfspk.pvad import compare as C

        keys = {Path(f"/d/{i}"): k for i, k in enumerate(reversed(C.CANDIDATE_ORDER))}
        ordered = C.order_candidates(list(keys), keys.__getitem__)
        self.assertEqual([keys[d] for d in ordered], list(C.CANDIDATE_ORDER))
        with self.assertRaises(ValueError):  # an ablation is not a candidate
            bad = dict(keys)
            bad[Path("/d/0")] = ("M", "none", "robust")
            C.order_candidates(list(bad), bad.__getitem__)
        with self.assertRaises(ValueError):  # a missing candidate
            C.order_candidates(list(keys)[:4], keys.__getitem__)


def _tok(text, f0, f1, src, kind, op, reg="single"):
    return [text, f0, f1, 0, src, kind, 0, op, reg, reg, f0 / 100, f1 / 100]


class HarnessParityTest(unittest.TestCase):
    """compare.py must agree with W0's compute_metrics on a fabricated frozen set
    (synthetic labels, words and scores; the fixture follows W0's own test)."""

    def setUp(self):
        from lfspk.harness.frozen import FrozenSet

        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        root = Path(self._tmp.name) / "set"
        (root / "labels").mkdir(parents=True)
        rows, words, F = [], {}, 300
        spk = ["11", "12", "13", "14", "15", "16"]
        for i, t in enumerate(spk):
            other = spk[(i + 1) % len(spk)]
            for scen in ("S0", "S4"):
                mid = f"{scen}-{t}-00"
                lab = np.zeros(F, np.uint8)
                lab[0:100] = 1
                if scen == "S4":
                    lab[150:250] = 2
                np.savez_compressed(root / "labels" / f"{mid}.npz", labels=lab, target_active=(lab == 1) | (lab == 3),
                                    interferer_actives=np.array([(lab == 2) | (lab == 3)]) if scen == "S4" else np.zeros((0, F), bool))
                toks = [_tok(f"w{k}", 10 * k, 10 * k + 8, "target", "C", "C") for k in range(10)]
                ints = []
                if scen == "S4":
                    toks += [_tok(f"i{k}", 150 + 20 * k, 165 + 20 * k, "interferer", "C", "I") for k in range(5)]
                    ints = [{"kind": "dictator", "speaker": other, "sir_db": 0.0}]
                words[mid] = {"id": mid, "frames": F, "tokens": toks, "n_ref": {"single": 10, "overlap": 0},
                              "dels": {"single": 0, "overlap": 0}, "untimed_errors": {},
                              "target_ref": [[f"w{k}", k / 10, k / 10 + 0.08] for k in range(10)],
                              "n_interferer_ref": [5] if ints else []}
                rows.append({"id": mid, "scenario": scen, "rir_mode": "coherent", "speaker": t, "half": "A" if i < 3 else "B",
                             "target_index": 0, "seed": 0, "relation_at": {"3": "cross_project", "10": "cross_project", "30": None},
                             "enroll_len": 10, "files": {"labels": f"labels/{mid}.npz", "mix": "", "target_dry": "", "interferers_dry": []},
                             "meta": {"frames": F, "interferers": ints, "split": "dev", "target": {"utt": f"{t}-1-0"}}})
        (root / "manifest.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        # 10 clean dictations per (speaker, device) and one contaminated twin, so the
        # streams reach k = 3 and 10 but not 30: exactly the 8 conditions scored below
        enr = [{"speaker": t, "device": dev, "index": j, "contaminated": c, "relation": "cross_project",
                "utt": f"{t}-9-{j}", "file": f"enroll/{t}-{dev}-{j}-{int(c)}.flac", "interferer_speakers": [], "sources": {}}
               for t in spk for dev in ("builtin", "headset") for j in range(10) for c in ((False, True) if j == 2 else (False,))]
        (root / "enrollment.jsonl").write_text("".join(json.dumps(e) + "\n" for e in enr))
        (root / "plans.json").write_text(json.dumps({"plans": [{"speaker": s, "test_project_in_train": True} for s in spk]}))
        (root / "HASH").write_text("x\n")
        self.fs, self.words, self.rows = FrozenSet("fake", root=root), words, rows

    def tearDown(self):
        self._tmp.cleanup()

    def _scores(self, out: Path, fn, dtype=np.float32):
        (out / "scores").mkdir(parents=True, exist_ok=True)
        by = {}
        rng = np.random.default_rng(len(str(out)))
        for r in self.rows:
            lab = self.fs.labels(r)["labels"]
            for d in ("builtin", "headset"):
                for c in ("clean", "contaminated"):
                    for k in (3, 10):
                        by.setdefault(r["speaker"], {})[f"{d}|{c}|{k}|{r['id']}"] = fn(lab, rng).astype(dtype)
        for spk_, d in by.items():
            np.savez_compressed(out / "scores" / f"{spk_}.npz", **d)
        (out / "results.json").write_text(json.dumps({"set_id": "fake", "set_hash": "x"}))

    def test_points_and_differences_match_compute_metrics(self):
        from lfspk.harness import evaluate as EV
        from lfspk.pvad import compare as C

        good = lambda lab, rng: np.clip(np.where((lab == 1) | (lab == 3), 0.9, 0.2) + rng.normal(0, 0.1, lab.size), 0, 1)  # noqa: E731
        poor = lambda lab, rng: np.clip(np.where((lab == 1) | (lab == 3), 0.7, 0.5) + rng.normal(0, 0.2, lab.size), 0, 1)  # noqa: E731
        base = Path(self._tmp.name)
        self._scores(base / "a", good)
        self._scores(base / "b", poor)
        ra = EV.compute_metrics("fake", base / "a", "all", "x", boot=20, fs=self.fs, words=self.words)
        rb = EV.compute_metrics("fake", base / "b", "all", "x", boot=20, fs=self.fs, words=self.words)
        pa, pb = C.system_points("fake", "all", [base / "a", base / "b"], fs=self.fs, words=self.words)
        hl = "builtin|clean|10"
        for mine, theirs in ((pa, ra), (pb, rb)):
            self.assertAlmostEqual(mine["tau"], theirs["conditions"][hl]["tau"], places=12)
            for g in ("pooled_S1-S4", "S0", "S4", "pooled_all"):
                for m in ("interferer_kept/all", "target_removed/all", "wer_increase"):
                    a, b = mine[g][m], theirs["conditions"][hl]["point"][g][m]
                    self.assertTrue((np.isnan(a) and np.isnan(b)) or abs(a - b) < 1e-12, (g, m, a, b))
        d = C.paired("fake", "all", base / "a", base / "b", boot=50, fs=self.fs, words=self.words)
        want = (ra["conditions"][hl]["point"]["pooled_S1-S4"]["interferer_kept/all"]
                - rb["conditions"][hl]["point"]["pooled_S1-S4"]["interferer_kept/all"])
        self.assertAlmostEqual(d["point"], want, places=12)
        self.assertLessEqual(d["lo"], d["hi"])

    def test_oracle_relative_guardrail(self):
        from lfspk.harness import evaluate as EV
        from lfspk.pvad import compare as C

        f = lambda lab, rng: np.clip(np.where((lab == 1) | (lab == 3), 0.8, 0.3) + rng.normal(0, 0.3, lab.size), 0, 1)  # noqa: E731
        base = Path(self._tmp.name)
        self._scores(base / "a", f)
        (rec,) = C.s0_versus_oracle("fake", "all", [base / "a"], boot=30, fs=self.fs, words=self.words)
        ro = EV.compute_metrics("fake", base / "a", "all", "oracle", boot=5, fs=self.fs, words=self.words)
        self.assertAlmostEqual(rec["oracle_s0_wer_increase"],
                               ro["conditions"]["builtin|clean|10"]["point"]["S0"]["wer_increase"], places=12)
        self.assertAlmostEqual(rec["relative"], rec["s0_wer_increase"] - rec["oracle_s0_wer_increase"], places=12)
        self.assertLessEqual(rec["relative_ci"][0], rec["relative_ci"][1])

    def test_refuses_float16_and_unequal_coverage(self):
        from lfspk.pvad import compare as C

        f = lambda lab, rng: np.full(lab.size, 0.5)  # noqa: E731
        base = Path(self._tmp.name)
        self._scores(base / "h", f, np.float16)
        self._scores(base / "a", f)
        with self.assertRaises(ValueError):
            C.system_points("fake", "all", [base / "h"], fs=self.fs, words=self.words)
        self._scores(base / "c", f)
        z = dict(np.load(base / "c" / "scores" / "11.npz"))
        z.pop("builtin|clean|10|S4-11-00")
        np.savez_compressed(base / "c" / "scores" / "11.npz", **z)
        with self.assertRaises(ValueError):
            C.paired("fake", "all", base / "a", base / "c", boot=5, fs=self.fs, words=self.words)
        with self.assertRaises(ValueError):  # a system missing a key is refused on its own too
            C.system_points("fake", "all", [base / "c"], fs=self.fs, words=self.words)

    def test_refuses_scores_of_another_frozen_set(self):
        from lfspk.pvad import compare as C

        base = Path(self._tmp.name)
        self._scores(base / "a", lambda lab, rng: np.full(lab.size, 0.5))
        C.system_points("fake", "all", [base / "a"], fs=self.fs, words=self.words)
        for bad in ({"set_id": "dev-old", "set_hash": "x"}, {"set_id": "fake", "set_hash": "y"}, {}):
            (base / "a" / "results.json").write_text(json.dumps(bad))
            with self.assertRaises(ValueError):
                C.system_points("fake", "all", [base / "a"], fs=self.fs, words=self.words)
        (base / "a" / "results.json").unlink()
        with self.assertRaises(ValueError):
            C.system_points("fake", "all", [base / "a"], fs=self.fs, words=self.words)


class D1HelpersTest(unittest.TestCase):
    def test_mixture_utterances_collects_every_role(self):
        from lfspk.pvad import diag_swap as DS

        manifest = [{"meta": {"target": {"utt": "1-10-0"}, "interferers": [{"speaker": "2", "utts": ["2-20-1", "2-20-2"]},
                                                                             {"speakers": ["3"], "utts": [{"utt": "3-30-4"}]}]}}]
        self.assertEqual(DS.mixture_utterances(manifest), {"1": {"1-10-0"}, "2": {"2-20-1", "2-20-2"}, "3": {"3-30-4"}})

    def test_swap_dictations_are_disjoint_and_prefer_other_projects(self):
        from lfspk.pvad import diag_swap as DS

        cp = {"20": "pA", "21": "pA", "22": "pB"}
        stream = [{"utt": f"2-{c}-{i}"} for c in ("20", "21", "22") for i in range(5)]
        used = {"2-22-0", "2-20-0"}
        chosen, rel = DS.choose_swap_dictations(stream, used, ["2-20-0"], cp, k=4)
        self.assertTrue(all(r["utt"].split("-")[1] == "22" for r in chosen))  # other project first
        self.assertFalse({r["utt"] for r in chosen} & used)
        self.assertEqual(rel, "cross_project")
        chosen, rel = DS.choose_swap_dictations(stream, used, ["2-20-0"], cp, k=8)
        self.assertEqual(rel, "same_project_cross_chapter")
        self.assertIsNone(DS.choose_swap_dictations(stream, used, ["2-20-0"], cp, k=14))

    def test_rank_criterion_flips_and_ignores_contraction(self):
        from lfspk.pvad import diag_swap as DS

        lab = np.array([1, 1, 1, 2, 2, 2, 3, 0])
        items = [("a", "b"), ("b", "a"), ("c", "d"), ("d", "c"), ("e", "f"), ("f", "e")]
        rng = np.random.default_rng(0)
        base = [rng.normal(0, 0.1, lab.size) + np.where(lab == 1, 5.0, np.where(lab == 2, -5.0, 0.0)) for _ in items]
        own = [DS.single_speaker_auc(x, lab) for x in base]
        flipped = [DS.single_speaker_auc(-x, lab) for x in base]
        uninformative = [DS.single_speaker_auc(rng.normal(size=lab.size), lab) * 0 + 0.5 for _ in base]
        c = DS.auc_criterion(own, flipped, uninformative, items, n_boot=100)
        self.assertTrue(c["uses_identity"])
        # Review eval-r2: a swap that only contracts the logits (classification unchanged) must not pass.
        contracted = [DS.single_speaker_auc(x / 5, lab) for x in base]
        self.assertFalse(DS.auc_criterion(own, contracted, uninformative, items, n_boot=100)["uses_identity"])
        # nor a mixture-wide shift
        shifted = [DS.single_speaker_auc(x - 3.0, lab) for x in base]
        self.assertFalse(DS.auc_criterion(own, shifted, uninformative, items, n_boot=100)["uses_identity"])
        # nor a model whose own profile is no better than a random vector
        self.assertFalse(DS.auc_criterion(own, flipped, own, items, n_boot=100)["uses_identity"])

    def test_empty_population_is_inconclusive_with_attrition(self):
        from lfspk.pvad import diag_swap as DS

        att = {"84": {"target:no_single_speaker_frames": 3}, "174": {"interferer:no_single_speaker_frames": 3}}
        out = DS.summarize({"own": [], "swap": [], "random": [], "unrelated": []}, [], [], [], [], att, 3, n_boot=10)
        self.assertIsNone(out["uses_identity"])
        self.assertEqual(out["population"]["by_speaker"], att)
        self.assertEqual(out["population"]["mixtures_considered"], 3)

    def test_random_profile_is_seeded_unit(self):
        from lfspk.pvad import diag_swap as DS

        a, b = DS.random_profile("S4-84-00", 16), DS.random_profile("S4-84-00", 16)
        np.testing.assert_array_equal(a.mean, b.mean)
        self.assertAlmostEqual(float(np.linalg.norm(a.embedding())), 1.0, places=5)
        self.assertFalse(np.array_equal(a.mean, DS.random_profile("S4-84-01", 16).mean))


class HarnessFactoryTest(unittest.TestCase):
    def _toy_checkpoint(self, d, cond):
        from lfspk.pvad import train as T

        return T.train(T.TrainConfig(out_dir=f"{d}/{cond}", size="S", conditioning=cond, steps=2, batch=2, crop_s=1.0,
                                     warmup=1, num_workers=0, device="cpu",
                                     source={"kind": "toy", "speakers": 6, "seconds": 1.0}))

    def test_unconditioned_checkpoint_needs_no_embedder(self):
        from lfspk.pvad import harness_scorer as H

        with tempfile.TemporaryDirectory() as d:
            sc = H.make(str(self._toy_checkpoint(d, "none")))
            self.assertIsInstance(sc, api.TargetSpeakerScorer)
            prof = sc.enroll([_audio(8000, 1)])
            api.check_scores(sc.score(prof, _audio(8000, 2)), 8000)
            self.assertEqual(sc.cost().update_macs, 0.0)

    def test_conditioned_checkpoint_checks_embedder_hash(self):
        from unittest import mock

        from lfspk.pvad import harness_scorer as H

        with tempfile.TemporaryDirectory() as d:
            ck = self._toy_checkpoint(d, "film_cos")
            cost = Path(d) / "cost"
            cost.mkdir()
            (cost / "toy.json").write_text(json.dumps({"trunk_macs_per_s_slope": 2.5e6}))
            emb = Sy.ToyEmbedder()
            with mock.patch("lfspk.embed.embedder.load_embedder", return_value=emb), mock.patch.object(H, "COST_DIR", cost):
                sc = H.make(str(ck))
                self.assertEqual(sc.cost().update_macs, 10 * 2.5e6)
                emb2 = Sy.ToyEmbedder()
                emb2.weights_sha256 = "f" * 64
                with mock.patch("lfspk.embed.embedder.load_embedder", return_value=emb2):
                    with self.assertRaises(ValueError):
                        H.make(str(ck))

    def test_recal_file_is_tied_to_checkpoint(self):
        from lfspk.pvad import harness_scorer as H

        with tempfile.TemporaryDirectory() as d:
            ck = self._toy_checkpoint(d, "none")
            rec = Path(d) / "recal.json"
            rec.write_text(json.dumps({"population": 1.5, "checkpoint_sha256": H.file_sha256(ck)}))
            self.assertEqual(H.load_recal(str(rec), str(ck)), 1.5)
            rec.write_text(json.dumps({"population": 1.5, "checkpoint_sha256": "0" * 64}))
            with self.assertRaises(ValueError):
                H.load_recal(str(rec), str(ck))

    def test_log_odds_match_scores(self):
        torch.manual_seed(0)
        m = Mo.PVAD(Mo.config_for("S", "film_cos", 16))
        with torch.no_grad():
            for p in m.parameters():
                p.add_(0.05 * torch.randn_like(p))
        sc = Sc.PVADScorer(m, Sy.ToyEmbedder(), embedder_macs_per_s=1.0)
        prof = sc.enroll([_audio(16_000, 1)])
        a = _audio(12_345, 2)
        lo = sc.log_odds(prof, a)
        np.testing.assert_allclose(1 / (1 + np.exp(-lo)), sc.score(prof, a), atol=1e-5)


@unittest.skipUnless((Path("/mnt/hd") / "localflow-speaker").exists(), "LibriSpeech not on this host")
class RecalSpeakersTest(unittest.TestCase):
    def test_fit_speakers_are_eligible_and_split(self):
        from lfspk.pvad import fit_recal as FR

        items = FR.fit_speakers(5)
        self.assertEqual(items, FR.fit_speakers(5))
        parts = E.librispeech_partitions("train")
        for s, utts in items:
            self.assertTrue(E.target_eligible(parts[s]))
            self.assertEqual(len(set(utts)), FR.K_ENROLL + FR.N_EVAL)
            self.assertTrue(set(utts) <= parts[s].enroll)


if __name__ == "__main__":
    unittest.main()
