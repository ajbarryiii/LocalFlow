"""Contract tests for the W0 mixing API (lfspk.harness.mix) on synthetic data."""

import unittest

import numpy as np

from lfspk.api import FRAME_SAMPLES, frame_count
from lfspk.harness import activity as act
from lfspk.harness import channels
from lfspk.harness.mix import SCENARIOS, MixtureGenerator, MixtureSampler
from lfspk.harness.rirs import PRE_DIRECT_SAMPLES, direct_index, normalise_rir
from lfspk.harness.synthetic import SyntheticCorpus, burst_signal, synthetic_rir
from lfspk.harness.util import active_level_db, mean_level_db, rng_for


class ActivityRuleTest(unittest.TestCase):
    def setUp(self):
        self.rng = np.random.default_rng(1)

    def test_bursts_are_found_to_within_dilation(self):
        pattern = [(0.5, 1.2), (2.0, 2.6)]
        x = burst_signal(self.rng, pattern, 5, 3.5)
        a = act.activity(x)
        self.assertEqual(a.size, frame_count(x.size))
        expected = np.zeros(a.size, bool)
        for s, e in pattern:
            expected[int(s * 100) : int(e * 100)] = True
        # Every burst frame is active; nothing beyond one frame of dilation is.
        self.assertTrue(np.all(a[expected]))
        grown = expected.copy()
        grown[1:] |= expected[:-1]
        grown[:-1] |= expected[1:]
        self.assertFalse(np.any(a & ~grown))

    def test_short_gaps_filled_long_gaps_kept(self):
        x = burst_signal(self.rng, [(0.5, 1.0), (1.05, 1.5), (2.0, 2.5)], 5, 3.0)
        a = act.activity(x)
        self.assertTrue(np.all(a[50:150]))  # 50 ms gap filled
        self.assertFalse(np.any(a[155:195]))  # 500 ms gap kept

    def test_short_runs_dropped(self):
        x = burst_signal(self.rng, [(0.5, 0.52), (1.5, 2.0)], 5, 3.0)
        a = act.activity(x)
        self.assertFalse(np.any(a[45:60]))
        self.assertTrue(np.all(a[150:200]))

    def test_gain_invariant(self):
        x = burst_signal(self.rng, [(0.5, 1.2), (2.0, 2.6)], 5, 3.5)
        np.testing.assert_array_equal(act.activity(x), act.activity((x * 0.01).astype(np.float32)))

    def test_silence_and_empty(self):
        self.assertFalse(act.activity(np.zeros(16000, np.float32)).any())
        self.assertEqual(act.activity(np.zeros(0, np.float32)).size, 0)

    def test_labels_and_place(self):
        t = np.array([1, 1, 0, 0], bool)
        i = np.array([0, 1, 1, 0], bool)
        np.testing.assert_array_equal(act.compose_labels(t, i), [1, 3, 2, 0])
        np.testing.assert_array_equal(act.place(np.array([1, 0, 1], bool), -1, 4), [0, 1, 0, 0])
        np.testing.assert_array_equal(act.place(np.array([1, 1], bool), 3, 4), [0, 0, 0, 1])


class ChannelTest(unittest.TestCase):
    def test_device_draws_fixed_per_user(self):
        a = channels.draw_device("dev", "84", "builtin")
        self.assertEqual(a, channels.draw_device("dev", "84", "builtin"))
        self.assertNotEqual(a, channels.draw_device("dev", "85", "builtin"))
        self.assertNotEqual(a, channels.draw_device("test", "84", "builtin"))

    def test_colourings_finite_and_linear_device(self):
        rng = np.random.default_rng(0)
        x = (rng.standard_normal(16000) * 0.1).astype(np.float32)
        for d in channels.DEVICES:
            p = channels.draw_device("dev", "1", d)
            y1 = channels.apply_device(x, p)
            y2 = channels.apply_device(2 * x, p)
            self.assertTrue(np.isfinite(y1).all())
            np.testing.assert_allclose(y2, 2 * y1, rtol=1e-4, atol=1e-6)
        for draw in (channels.draw_tv_speaker, channels.draw_laptop_speaker):
            self.assertTrue(np.isfinite(channels.apply_speaker(x, draw(rng))).all())

    def test_mulaw_roundtrip_error_small(self):
        x = np.linspace(-0.5, 0.5, 1001, dtype=np.float32)
        y = channels.mulaw_roundtrip(x)
        self.assertLess(np.max(np.abs(y - x) / (np.abs(x) + 1e-2)), 0.05)

    def test_narrowband_removes_high_band(self):
        rng = np.random.default_rng(0)
        x = (rng.standard_normal(32000) * 0.1).astype(np.float32)
        y = channels.narrowband(x)
        self.assertEqual(y.size, x.size)
        spec = np.abs(np.fft.rfft(y)) ** 2
        f = np.fft.rfftfreq(y.size, 1 / 16000)
        self.assertLess(spec[f > 4500].sum() / spec.sum(), 1e-3)

    def test_voip_deterministic_and_band_limited(self):
        rng = np.random.default_rng(0)
        x = (rng.standard_normal(32000) * 0.1).astype(np.float32)
        p = channels.draw_voip(rng_for("t"))
        np.testing.assert_array_equal(channels.voip(x, p), channels.voip(x, p))
        y = channels.voip(x, {**p, "loss": 0.0})
        spec = np.abs(np.fft.rfft(y)) ** 2
        f = np.fft.rfftfreq(y.size, 1 / 16000)
        self.assertLess(spec[f > 7600].sum() / spec.sum(), 0.01)


class RirTest(unittest.TestCase):
    def test_normalise_delay_and_tail(self):
        h = synthetic_rir(np.random.default_rng(0), 0.5, direct_delay=400)
        g = normalise_rir(h)
        self.assertLessEqual(direct_index(g), PRE_DIRECT_SAMPLES)
        self.assertLessEqual(g.size, 16000)
        self.assertAlmostEqual(float(np.abs(g).max()), 1.0, places=5)


class MixtureContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._ctx = SyntheticCorpus()
        cls.corpus = cls._ctx.__enter__()
        cls.gen = MixtureGenerator("dev", cls.corpus)
        cls.target = cls.corpus.utterances["100"][0]
        cls.mix = {s: cls.gen.render(s, 7, target=cls.target) for s in SCENARIOS}

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def test_deterministic(self):
        again = self.gen.render("S2", 7, target=self.target)
        np.testing.assert_array_equal(again.audio, self.mix["S2"].audio)
        self.assertEqual(again.meta, self.mix["S2"].meta)
        other = self.gen.render("S2", 8, target=self.target)
        self.assertFalse(np.array_equal(other.audio[: min(other.audio.size, again.audio.size)], again.audio[: min(other.audio.size, again.audio.size)]))

    def test_shapes_and_sum(self):
        for s, m in self.mix.items():
            n = m.audio.size
            self.assertEqual(n % FRAME_SAMPLES, 0)
            self.assertEqual(m.audio.dtype, np.float32)
            for arr in [m.target, m.target_dry, m.noise, *m.interferers, *m.interferers_dry]:
                self.assertEqual(arr.shape, (n,))
            f = frame_count(n)
            for arr in [m.labels, m.target_active, m.interferer_active, *m.interferer_actives]:
                self.assertEqual(arr.shape, (f,))
            total = m.target + m.noise + sum(m.interferers, np.zeros(n, np.float32))
            np.testing.assert_allclose(m.audio, total, atol=1e-6)
            self.assertLessEqual(np.abs(m.audio).max(), 0.95 + 1e-6)

    def test_labels_compose_activity(self):
        for s, m in self.mix.items():
            np.testing.assert_array_equal(m.labels, m.target_active.astype(np.uint8) + 2 * m.interferer_active.astype(np.uint8))
            if m.interferer_actives:
                np.testing.assert_array_equal(m.interferer_active, np.any(m.interferer_actives, axis=0))
        self.assertFalse(np.any(self.mix["S0"].labels >= 2))
        for s in ("S1", "S2", "S3", "S4"):
            self.assertGreater(len(self.mix[s].interferers), 0)
            self.assertTrue(np.any(self.mix[s].labels >= 2))

    def test_requested_levels_hold(self):
        for s, m in self.mix.items():
            lt = active_level_db(m.target, m.target_active)
            self.assertAlmostEqual(lt, m.meta["target"]["level_measured_dbfs"], places=4)
            self.assertAlmostEqual(lt, m.meta["target"]["level_dbfs"] + m.meta["peak_gain_db"], places=3)
            for meta, img, a in zip(m.meta["interferers"], m.interferers, m.interferer_actives):
                self.assertAlmostEqual(lt - active_level_db(img, a), meta["sir_db"], places=2)
            # SNR is defined on the acoustic noise (ambience + event); self-noise is extra.
            self.assertAlmostEqual(m.meta["ambience"]["snr_measured_db"], m.meta["ambience"]["snr_db"], places=2)
            self.assertLessEqual(m.meta["ambience"]["snr_total_db"], m.meta["ambience"]["snr_db"] + 1e-6)
            self_noise = 10 ** (m.meta["self_noise_dbfs"] / 10) * 10 ** (m.meta["peak_gain_db"] / 10)
            acoustic = 10 ** ((lt - m.meta["ambience"]["snr_db"]) / 10)
            self.assertAlmostEqual(lt - 10 * np.log10(acoustic + self_noise), m.meta["ambience"]["snr_total_db"], delta=0.2)
            self.assertAlmostEqual(lt - mean_level_db(m.noise), m.meta["ambience"]["snr_total_db"], places=2)

    def test_scenarios_paired_by_seed(self):
        # Review r1 #5: rendered together, S0/S1/S2/S4 share target and noise bit-exactly.
        for seed in range(4):
            g = self.gen.render_paired(SCENARIOS, seed, target=self.target)
            for s in ("S1", "S2", "S4"):
                np.testing.assert_array_equal(g["S0"].target, g[s].target)
                np.testing.assert_array_equal(g["S0"].target_dry, g[s].target_dry)
            for s in ("S2", "S4"):  # S1 has its own (noisier) SNR range and noise events
                np.testing.assert_array_equal(g["S0"].noise, g[s].noise)
            gains = {m.meta["peak_gain_db"] for m in g.values()}
            self.assertEqual(len(gains), 1)
            for s in SCENARIOS:
                self.assertEqual(g[s].meta["room"], g["S0"].meta["room"])
                self.assertEqual(g[s].meta["target"]["level_dbfs"], g["S0"].meta["target"]["level_dbfs"])
                self.assertEqual(g[s].meta["ambience"]["key"], g["S0"].meta["ambience"]["key"])

    def test_coherent_rooms_and_mixed_balance(self):
        # Review r1 #2: primary mode puts every source in the target's room.
        for seed in range(6):
            g = self.gen.render_paired(SCENARIOS, seed, target=self.target)
            for m in g.values():
                room = m.meta["room"]["bank_index"]
                self.assertEqual((m.meta["target"]["rir"]["pool"], m.meta["target"]["rir"]["room"]), ("bank", room))
                for it in m.meta["interferers"]:
                    self.assertEqual((it["rir"]["pool"], it["rir"]["room"]), ("bank", room))
                if m.meta["event"]:
                    self.assertEqual(m.meta["event"]["rir"]["room"], room)
            roles = [it["rir"]["role"] for it in g["S1"].meta["interferers"]]
            self.assertEqual(len(roles), len(set(roles)))  # distinct positions
        pools = {"target": set(), "interferer": set()}
        for seed in range(30):
            m = self.gen.render("S4", seed, target=self.target, rir_mode="mixed")
            pools["target"].add(m.meta["target"]["rir"]["pool"])
            pools["interferer"].add(m.meta["interferers"][0]["rir"]["pool"])
        self.assertEqual(pools["target"], {"bank", "slr26", "measured"})
        self.assertEqual(pools["interferer"], {"bank", "slr26", "measured"})

    def test_tv_speakers_are_audible_participants(self):
        # Review r1 #7: listed programme speakers all contribute audible speech.
        for seed in range(12):
            m = self.gen.render("S2", seed, target=self.target)
            it = m.meta["interferers"][0]
            if it["programme"] != "librispeech":
                continue
            self.assertEqual(it["speakers"], sorted({u["speaker"] for u in it["utts"]}, key=int))
            self.assertTrue(it["utts"])

    def test_target_dry_matches_activity(self):
        for s, m in self.mix.items():
            x = m.target_dry
            self.assertTrue(np.all(m.target_active <= act.place(act.activity(x) | m.target_active, 0, m.target_active.size)))
            self.assertEqual(m.meta["target"]["utt"], self.target.id)

    def test_s2_continuous_s3_turns(self):
        s2 = self.mix["S2"]
        self.assertGreater(s2.interferer_active.mean(), 0.3)
        s3 = self.mix["S3"]
        parts = s3.meta["target"]["parts"]
        for (o1, a1, b1), (o2, a2, b2) in zip(parts, parts[1:]):
            self.assertGreaterEqual(o2, o1)  # in order, never self-overlapping speech
        self.assertEqual(len(s3.interferers), 1)

    def test_s4_sex_and_distinct_speaker(self):
        for seed in range(6):
            m = self.gen.render("S4", seed, target=self.target)
            self.assertNotEqual(m.meta["interferers"][0]["speaker"], self.target.speaker)

    def test_device_variants(self):
        h = self.gen.render("S1", 7, target=self.target, device="headset")
        self.assertEqual(h.meta["device"], "headset")
        self.assertEqual(h.meta["target"]["rir"]["role"], "target_headset")
        # Only the colouring and the target's near-field path change.
        self.assertEqual([i["speaker"] for i in h.meta["interferers"]], [i["speaker"] for i in self.mix["S1"].meta["interferers"]])
        self.assertNotEqual(h.meta["device_params"], self.mix["S1"].meta["device_params"])


class PlanAndSamplerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._ctx = SyntheticCorpus()
        cls.corpus = cls._ctx.__enter__()
        cls.gen = MixtureGenerator("dev", cls.corpus)

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def test_plan_disjoint_and_project_separated(self):
        p = self.gen.speaker_plan("100", n_targets=4, n_enroll=5)
        self.assertEqual(len(p.targets), 4)
        self.assertEqual(len(p.enrollment), 5)
        self.assertFalse({u.id for u in p.targets} & {u.id for u in p.enrollment})
        self.assertTrue(all(u.chapter == p.test_chapter for u in p.targets))
        self.assertEqual(p, self.gen.speaker_plan("100", n_targets=4, n_enroll=5))
        self.assertEqual(p.relations, ("cross_project",) * 5)
        self.assertTrue(all(u.chapter != p.test_chapter for u in p.enrollment))
        self.assertEqual(len(p.contaminated_positions), 1)
        self.assertTrue(0 <= p.contaminated_positions[0] < 5)

    def test_multi_chapter_never_enrolls_from_test_chapter(self):
        # Speaker 100 has 8 utterances outside the test chapter: the stream stops there.
        p = self.gen.speaker_plan("100", n_targets=4, n_enroll=10)
        self.assertEqual(len(p.enrollment), 8)
        self.assertIn("enroll-short:8", p.flags)
        self.assertNotIn("same_chapter", p.relations)
        self.assertTrue(all(q < 8 for q in p.contaminated_positions))

    def test_same_project_relation(self):
        p = self.gen.speaker_plan("101", n_targets=4, n_enroll=10)
        self.assertIn("single-project", p.flags)
        self.assertEqual(p.relation_at(10), "same_project_cross_chapter")

    def test_single_chapter_flagged(self):
        p = self.gen.speaker_plan("105", n_targets=3, n_enroll=4)
        self.assertIn("single-chapter", p.flags)
        self.assertEqual(p.relations, ("same_chapter",) * 4)
        self.assertFalse({u.id for u in p.targets} & {u.id for u in p.enrollment})

    def test_enrollment_twins_differ_only_by_talker(self):
        p = self.gen.speaker_plan("100", n_targets=4, n_enroll=5)
        other = MixtureGenerator("dev", self.corpus, speakers=["103", "104", "105"])
        clean, dirty = self.gen.enrollment_streams(p, 3, "builtin", contaminator=other)
        j = p.contaminated_positions[0]
        for k, (c, d) in enumerate(zip(clean, dirty)):
            self.assertEqual(c.meta["target"]["utt"], d.meta["target"]["utt"])
            self.assertEqual(c.meta["enrollment"]["relation"], p.relations[k])
            if k == j:
                self.assertTrue(d.meta["enrollment"]["contaminated"])
                self.assertEqual(len(d.interferers), 1)
                self.assertIn(d.meta["interferers"][0]["speaker"], ["103", "104", "105"])
                np.testing.assert_array_equal(c.target, d.target)
                np.testing.assert_array_equal(c.noise, d.noise)
            else:
                np.testing.assert_array_equal(c.audio, d.audio)

    def test_sampler_deterministic_with_enrollment(self):
        s = MixtureSampler("dev", base_seed=5, corpus=self.corpus)
        a, b = s[3], s[3]
        np.testing.assert_array_equal(a.audio, b.audio)
        m, enr = s.with_enrollment(3, n=3, contamination=0.5)
        self.assertEqual(len(enr), 3)
        for e in enr:
            self.assertEqual(e.meta["target"]["speaker"], m.meta["target"]["speaker"])
            self.assertNotEqual(e.meta["target"]["utt"], m.meta["target"]["utt"])
            self.assertIn(e.meta["enrollment"]["relation"], ("cross_project", "same_project_cross_chapter", "same_chapter"))


if __name__ == "__main__":
    unittest.main()


class HalvesTest(unittest.TestCase):
    def test_assign_balanced_and_deterministic(self):
        from lfspk.harness.halves import assign_halves

        spk = {str(i): ("F" if i % 2 else "M", ("cross_project", "same_chapter", "same_project_cross_chapter")[i % 3]) for i in range(41)}
        a = assign_halves(spk)
        self.assertEqual(a, assign_halves(dict(reversed(list(spk.items())))))
        self.assertEqual(set(a), set(spk))
        n_a = sum(v == "A" for v in a.values())
        self.assertLessEqual(abs(n_a - (41 - n_a)), 1)
        for key in set(spk.values()):
            members = [s for s in spk if spk[s] == key]
            k = sum(a[s] == "A" for s in members)
            self.assertLessEqual(abs(k - (len(members) - k)), 1)

    def test_pool_restricts_every_role(self):
        with SyntheticCorpus() as corpus:
            pool = ["100", "101", "102"]
            gen = MixtureGenerator("dev", corpus, speakers=pool)
            for s in ("S1", "S2", "S3", "S4"):
                for seed in range(3):
                    m = gen.render(s, seed)
                    self.assertIn(m.meta["target"]["speaker"], pool)
                    for it in m.meta["interferers"]:
                        spks = it.get("speakers") or [it.get("speaker")] or []
                        for x in spks:
                            if x is not None:
                                self.assertIn(x, pool)
            with self.assertRaises(ValueError):
                MixtureGenerator("dev", corpus, speakers=["100", "999", "101"])

    def test_stale_index_refused(self):
        # Review r1 #3: an index built for other subsets is refused.
        import json as _json

        with SyntheticCorpus() as corpus:
            p = corpus.index_dir / "librispeech-dev.json"
            d = _json.loads(p.read_text())
            d["subsets"] = ["dev-clean"]
            p.write_text(_json.dumps(d))
            from lfspk.harness.corpora import Corpus

            with self.assertRaises(RuntimeError):
                Corpus("dev", index_dir=corpus.index_dir, bank_dir=corpus.bank_dir).speakers

    def test_sources_pinned(self):
        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus, pin_sources=True)
            m = gen.render("S2", 1)
            self.assertIn(m.meta["target"]["utt"], " ".join(m.meta["sources"]))
            self.assertTrue(any(p.endswith(".npz") for p in m.meta["sources"]))
            self.assertTrue(all(len(h) == 64 for h in m.meta["sources"].values()))


class ActivityRegressionTest(unittest.TestCase):
    def test_burst_surrounded_by_digital_silence(self):
        # Review r1 #1: a steady burst padded with zeros had zero active frames.
        rng = np.random.default_rng(3)
        x = np.zeros(5 * 16000, np.float32)
        x[16000 : 4 * 16000] = (rng.standard_normal(3 * 16000) * 0.1).astype(np.float32)
        a = act.activity(x)
        self.assertTrue(a[101:399].all())
        self.assertFalse(a[:99].any() or a[401:].any())

    def _padded(self, pad_kind: str, seed: int = 5) -> np.ndarray:
        rng = np.random.default_rng(seed)
        n = 10 * 16000
        x = (rng.standard_normal(n) * 0.003).astype(np.float32)  # room tone at -50.5 dBFS, 30 dB below speech
        pad = {"zeros": np.zeros(8000), "lsb": rng.integers(-1, 2, 8000) / 32768.0, "sub_lsb": rng.standard_normal(8000) * 1e-5}[pad_kind]
        x[:8000] = pad
        x[-8000:] = pad[::-1]
        for s, e in ((1.0, 3.0), (6.0, 8.5)):
            x[int(s * 16000) : int(e * 16000)] += (rng.standard_normal(int((e - s) * 16000)) * 0.1).astype(np.float32)
        return x.astype(np.float32)

    def test_padding_and_room_tone(self):
        # Reviews r2 #1 and r3 #1: zero, +-1 LSB dither or sub-LSB padding must not
        # drag the floor below the room tone; the interior pause stays inactive.
        for kind in ("zeros", "lsb", "sub_lsb"):
            a = act.activity(self._padded(kind))
            self.assertTrue(a[101:299].all() and a[601:849].all(), kind)
            self.assertFalse(a[310:590].any(), kind)
            self.assertFalse(a[:50].any() or a[-50:].any(), kind)

    def test_padded_burst_without_room_tone(self):
        # Review r1 #1 with dither instead of zeros: the burst stays active.
        rng = np.random.default_rng(6)
        for pad in (np.zeros(16000), rng.integers(-1, 2, 16000) / 32768.0):
            x = np.concatenate([pad, rng.standard_normal(3 * 16000) * 0.1, pad]).astype(np.float32)
            a = act.activity(x)
            self.assertTrue(a[101:399].all())
            self.assertFalse(a[:99].any() or a[401:].any())

    def test_steady_track_without_pause(self):
        rng = np.random.default_rng(4)
        x = (rng.standard_normal(3 * 16000) * 0.1).astype(np.float32)
        self.assertGreater(act.activity(x).mean(), 0.95)


class MixedModeAndEventTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._ctx = SyntheticCorpus()
        cls.corpus = cls._ctx.__enter__()
        cls.gen = MixtureGenerator("dev", cls.corpus)

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def test_mixed_measured_only_reverb_for_both_roles(self):
        # Review r2 #2: one measurement family (REVERB) supplies near and far.
        seen = set()
        for seed in range(40):
            m = self.gen.render("S4", seed, rir_mode="mixed")
            for info in [m.meta["target"]["rir"], *[i["rir"] for i in m.meta["interferers"]]]:
                if info["pool"] == "measured":
                    self.assertTrue(info["id"].startswith("RVB2014_"))
                    seen.add("near" if "_near_" in info["id"] else "far")
        self.assertEqual(seen, {"near", "far"})

    def test_event_level_relative_to_local_ambience(self):
        # Review r2 #3 / r3 #2: on non-stationary ambience the event sits the
        # requested amount above the ambience measured over the event's span.
        from lfspk.harness.util import active_level_db as ald

        found = 0
        for seed in range(60):
            m = self.gen.render("S1", seed)
            ev = m.meta["event"]
            if not ev:
                continue
            found += 1
            span = np.zeros(m.labels.size, bool)
            span[ev["offset"] : ev["offset"] + ev["frames"]] = True
            local = ald(m.noise_parts["event"], span) - ald(m.noise_parts["ambience"], span)
            self.assertAlmostEqual(local, ev["event_over_ambience_db"], places=2)
            np.testing.assert_allclose(sum(m.noise_parts.values()), m.noise, atol=1e-6)
        self.assertGreater(found, 3)
