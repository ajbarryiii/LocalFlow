"""W1 profile format and EmbeddingScorer contracts, on synthetic tones with a
toy spectral embedder (no model weights needed)."""

import unittest
from pathlib import Path

import numpy as np

from lfspk import api
from lfspk.embed import scorer as S
from lfspk.embed.profile import EmbProfile

SR = 16000


class ToyEmbedder:
    """Unit vector of log band energies: tones at different pitches act as
    different 'speakers'."""

    name, dim, weights_sha256, params = "redimnet2-b0", 16, "00" * 32, 0

    def embed(self, audio):
        spec = np.abs(np.fft.rfft(audio * np.hanning(audio.size))) ** 2
        bands = np.array_split(spec[: spec.size // 2], self.dim)
        v = np.log(np.array([b.sum() for b in bands]) + 1e-6)
        v = v - v.mean()
        return (v / np.linalg.norm(v)).astype(np.float32)

    def embed_batch(self, audios):
        return np.stack([self.embed(a) for a in audios]) if audios else np.zeros((0, self.dim), np.float32)


def tone(seconds, f0, amp=0.3, seed=0):
    t = np.arange(int(seconds * SR)) / SR
    x = sum(amp / h * np.sin(2 * np.pi * f0 * h * t) for h in (1, 2, 3))
    x = x + np.random.default_rng(seed).standard_normal(t.size) * 1e-3
    return x.astype(np.float32)


def silence(seconds, seed=0):
    return (np.random.default_rng(seed).standard_normal(int(seconds * SR)) * 1e-4).astype(np.float32)


TARGET, OTHER = 220.0, 1100.0


def make(rule="robust", norm="raw", **upd):
    cfg = S.ScorerConfig("redimnet2-b0", S.WindowConfig(1.0, 0.25, 0.3), norm=norm,
                         update=S.UpdateConfig(rule=rule, **upd), head=S.Head(coef=(8.0,), intercept=-4.0))
    return S.EmbeddingScorer(cfg, embedder=ToyEmbedder())


class ProfileFormatTest(unittest.TestCase):
    def test_round_trip_and_size(self):
        rng = np.random.default_rng(0)
        c = rng.standard_normal((2, 192))
        c *= np.array([[0.9], [0.4]]) / np.linalg.norm(c, axis=1, keepdims=True)  # running means, |m| <= 1
        p = EmbProfile("titanet-s", c, [3, 70000], seen=70001, accepted=70000)
        b = p.to_bytes()
        self.assertEqual(len(b), EmbProfile.size_bytes(192, 2))
        self.assertEqual(EmbProfile.size_bytes(192, 1), 784)
        self.assertEqual(EmbProfile.size_bytes(192, 1, anchor=True), 1552)
        q = EmbProfile.from_bytes(b)
        self.assertEqual((q.embedder, q.seen, q.accepted), ("titanet-s", 65535, 65535))  # counters saturate
        np.testing.assert_array_equal(q.counts, [3, 65535])  # counts saturate
        np.testing.assert_array_equal(q.centroids, p.centroids)  # float32: exact
        np.testing.assert_allclose(np.linalg.norm(q.centroids, axis=1), [0.9, 0.4], atol=1e-6)  # magnitude kept
        np.testing.assert_allclose(np.linalg.norm(q.directions, axis=1), 1.0, atol=1e-6)
        self.assertIsNone(q.anchor)
        self.assertEqual(q.to_bytes(), b)
        self.assertIsInstance(p, api.Profile)

    def test_anchor_round_trip(self):
        a = np.zeros(8)
        a[0] = 1.0
        p = EmbProfile("titanet-s", np.full((1, 8), 0.3), [1], seen=1, accepted=1, anchor=a)
        q = EmbProfile.from_bytes(p.to_bytes())
        np.testing.assert_array_equal(q.anchor, a.astype(np.float32))
        self.assertEqual(len(p.to_bytes()), EmbProfile.size_bytes(8, 1, anchor=True))

    def test_rejects_malformed(self):
        good = EmbProfile("titanet-s", np.full((1, 8), 0.3), [1], seen=2, accepted=1).to_bytes()

        def patched(offset, raw):
            return good[:offset] + raw + good[offset + len(raw):]

        bad_bytes = {
            "truncated": good[:-1], "magic": patched(0, b"XXXX"), "version": patched(4, b"\x01"),
            "embedder": patched(5, b"\xff"), "flags": patched(9, b"\x02"),
            "anchor flag without anchor": patched(9, b"\x01"),
            "accepted > seen": patched(10, (1).to_bytes(2, "little") + (2).to_bytes(2, "little")),
            "count 0": patched(14, (0).to_bytes(2, "little")),
            "count > accepted": patched(14, (5).to_bytes(2, "little")),
            "nan": patched(16, np.array([np.nan], "<f4").tobytes()),
        }
        for why, bad in bad_bytes.items():
            with self.assertRaises(ValueError, msg=why):
                EmbProfile.from_bytes(bad)
        with self.assertRaises(ValueError):
            EmbProfile("unknown", np.full((1, 8), 0.3), [1], seen=1, accepted=1)
        for bad in (np.zeros((1, 8)), np.ones((1, 8))):  # zero, or longer than a mean of unit vectors
            with self.assertRaises(ValueError):
                EmbProfile("titanet-s", bad, [1], seen=1, accepted=1)
        with self.assertRaises(ValueError):  # anchor not unit
            EmbProfile("titanet-s", np.full((1, 8), 0.3), [1], seen=1, accepted=1, anchor=np.full(8, 0.5))

    def test_running_mean_survives_many_persisted_updates(self):
        """Reviewer's cases: small updates at large n must not be lost, and
        many updates toward a unit vector must stay valid."""
        sc = make("naive")
        m0 = np.array([0.7071, 0.7071] + [0.0] * 14)
        p = EmbProfile("redimnet2-b0", m0, [10000], seen=10000, accepted=10000)
        d = np.zeros(16)
        d[0] = 1.0
        want = m0.copy()
        for i in range(1000):
            n = int(p.counts[0])
            p = EmbProfile.from_bytes(EmbProfile("redimnet2-b0", p.centroids + (d - p.centroids) / (n + 1), [n + 1],
                                                 seen=p.seen + 1, accepted=p.accepted + 1).to_bytes())
            want = want + (d - want) / (n + 1)
        np.testing.assert_allclose(p.centroids[0], want, atol=1e-5)
        self.assertGreater(p.centroids[0][0], 0.73)
        del sc


class WindowLayoutTest(unittest.TestCase):
    def test_covers_recording(self):
        cfg = S.WindowConfig(1.0, 0.25)
        for n in (3200, 15999, 16000, 16001, 37777):
            lay = S.window_layout(n, cfg)
            self.assertTrue(lay)
            self.assertEqual(lay[0][0], 0)
            self.assertEqual(max(s + L for s, L in lay), n)
            self.assertTrue(all(s + L <= n for s, L in lay))
        self.assertEqual(S.window_layout(10000, cfg), [(0, 10000)])
        self.assertEqual(S.window_layout(3199, cfg), [])


class ScorerContractTest(unittest.TestCase):
    def setUp(self):
        self.sc = make()
        self.profile = self.sc.enroll([tone(3, TARGET, seed=i) for i in range(3)])

    def test_conforms_to_api(self):
        self.assertIsInstance(self.sc, api.TargetSpeakerScorer)
        for n in (0, 100, 3199, 3200, 16000, 40000):
            audio = tone(n / SR, TARGET)[:n] if n else np.zeros(0, np.float32)
            api.check_scores(self.sc.score(self.profile, audio), n)

    def test_target_beats_other_and_silence(self):
        audio = np.concatenate([tone(3, TARGET, seed=5), silence(2), tone(3, OTHER, seed=6)])
        s = self.sc.score(self.profile, audio)
        target, other = s[50:250].mean(), s[550:750].mean()
        self.assertGreater(target, 0.8)
        self.assertLess(other, 0.2)

    def test_enrollment_is_robust_to_contamination(self):
        clean = [tone(3, TARGET, seed=i) for i in range(4)]
        dirty = clean[:3] + [np.concatenate([tone(1, TARGET, seed=9), tone(2, OTHER, seed=9)])]
        ref = make().enroll(clean).directions[0]
        robust = make("robust").enroll(dirty).directions[0]
        naive = make("naive").enroll(dirty).directions[0]
        self.assertGreater(robust @ ref, naive @ ref)

    def test_gated_update_rejects_other_speaker(self):
        sc = make("gated", window_gate=0.5, dictation_gate=0.5)
        p = sc.enroll([tone(3, TARGET, seed=i) for i in range(3)])
        rejected = sc.update(p, tone(4, OTHER, seed=7))
        self.assertEqual((rejected.seen, rejected.accepted), (p.seen + 1, p.accepted))
        np.testing.assert_array_equal(rejected.centroids, p.centroids)
        accepted = sc.update(p, tone(4, TARGET, seed=8))
        self.assertEqual(accepted.accepted, p.accepted + 1)
        naive = make("naive").update(p, tone(4, OTHER, seed=7))
        self.assertEqual(naive.accepted, p.accepted + 1)
        self.assertLess(naive.directions[0] @ p.directions[0], 0.999)

    def test_n_cap_bounds_inertia(self):
        sc = make("gated", window_gate=-1.0, dictation_gate=-1.0, min_kept=0.0, n_cap=1)
        p = EmbProfile("redimnet2-b0", sc.enroll([tone(3, TARGET)]).centroids, [1000], seen=1000, accepted=1000)
        d = sc.dictation_embedding(S.embed_windows(sc.embedder, tone(3, OTHER), sc.config.update_window))
        q = sc.update(p, tone(3, OTHER))
        want = p.centroids[0] + (d - p.centroids[0]) / 2  # rate 1 / (min(1000, n_cap = 1) + 1)
        np.testing.assert_allclose(q.centroids[0], want, atol=2e-3)
        self.assertEqual(int(q.counts[0]), 1001)

    def test_naive_updates_are_an_exact_running_mean(self):
        """Persisted naive updates equal the mean of all dictation embeddings
        (the stored state is the unnormalised mean plus count)."""
        sc = make("naive")
        clips = [tone(2, f, seed=i) for i, f in enumerate((TARGET, OTHER, 400.0, TARGET, 700.0))]
        ds = [sc.dictation_embedding(S.embed_windows(sc.embedder, c, sc.config.update_window)) for c in clips]
        p = sc.enroll(clips[:2])
        for c in clips[2:]:
            p = EmbProfile.from_bytes(sc.update(p, c).to_bytes())  # store and reload between updates
        np.testing.assert_allclose(p.centroids[0], np.mean(ds, axis=0), atol=2e-3)
        self.assertEqual(int(p.counts[0]), 5)

    def test_uncovered_silence_scores_low(self):
        """Reviewer's case: a long quiet gap between target speech; frames no
        window covers must not inherit the target score."""
        audio = np.concatenate([tone(2, TARGET, seed=1), silence(4), tone(2, TARGET, seed=2)])
        f = self.sc.frame_features(self.profile, audio)
        gap = slice(300, 500)  # 3-5 s: inside the gap, beyond any window with enough speech
        self.assertFalse(f["covered"][gap].any())
        s = self.sc.score(self.profile, audio)
        self.assertLess(float(s[gap].mean()), 0.05)
        self.assertGreater(float(s[50:150].mean()), 0.8)

    def test_anchored_rule_bounds_drift(self):
        sc = make("anchored", window_gate=-1.0, dictation_gate=-1.0, min_kept=0.0, anchor_gate=-1.0,
                  drift_floor=0.95)
        p = sc.enroll([tone(3, TARGET, seed=i) for i in range(3)])
        self.assertIsNotNone(p.anchor)
        for i in range(40):  # a persistent other voice that passes every other gate
            p = sc.update(p, tone(3, OTHER, seed=100 + i))
        self.assertGreaterEqual(float(p.directions[0] @ p.anchor), 0.95 - 1e-6)
        q = make("gated", window_gate=-1.0, dictation_gate=-1.0, min_kept=0.0).enroll(
            [tone(3, TARGET, seed=i) for i in range(3)])
        for i in range(40):
            q = make("gated", window_gate=-1.0, dictation_gate=-1.0, min_kept=0.0).update(q, tone(3, OTHER, seed=100 + i))
        self.assertLess(float(q.directions[0] @ p.anchor), 0.95)  # without the anchor it is captured

    def test_update_keeps_profile_size(self):
        p = self.sc.update(self.profile, tone(5, TARGET, seed=3))
        self.assertEqual(len(p.to_bytes()), len(self.profile.to_bytes()))

    def test_asnorm_needs_cohort_at_least_top_k(self):
        rng = np.random.default_rng(0)
        c = rng.standard_normal((50, 16)).astype(np.float32)
        c /= np.linalg.norm(c, axis=1, keepdims=True)
        cfg = S.ScorerConfig("redimnet2-b0", norm="asnorm", top_k=20)
        sc = S.EmbeddingScorer(cfg, embedder=ToyEmbedder(), cohort=S.Cohort(c, c))
        p = sc.enroll([tone(3, TARGET)])
        api.check_scores(sc.score(p, tone(2, TARGET)), 32000)
        with self.assertRaises(ValueError):
            S.EmbeddingScorer(S.ScorerConfig("redimnet2-b0", norm="asnorm", top_k=60),
                              embedder=ToyEmbedder(), cohort=S.Cohort(c, c))

    def test_features_cover_every_frame(self):
        audio = np.concatenate([silence(1), tone(2.37, TARGET)])
        f = self.sc.frame_features(self.profile, audio)
        n = api.frame_count(audio.size)
        self.assertEqual(set(f), set(S.FEATURES))
        for v in f.values():
            self.assertEqual(v.shape, (n,))
            self.assertTrue(np.isfinite(v).all())

    def test_head_json_round_trip(self):
        h = S.Head(("score", "snr"), (0.1, 20.0), (1.0, 10.0), (2.0, 0.5), -1.0)
        self.assertEqual(S.Head.from_json(h.to_json()), h)
        with self.assertRaises(ValueError):
            S.Head(("score", "bogus"), (0, 0), (1, 1), (1, 1), 0.0)

    def test_cost_report(self):
        c = self.sc.cost()
        self.assertIsInstance(c, api.CostReport)
        self.assertEqual(c.profile_bytes, len(self.profile.to_bytes()))


class HeadFitTest(unittest.TestCase):
    def test_fit_head_separates_and_round_trips(self):
        from lfspk.embed.head import fit_head

        rng = np.random.default_rng(0)
        y = rng.random(4000) < 0.4
        X = np.stack([rng.standard_normal(4000) + 3 * y, rng.standard_normal(4000) * 5 + 20], axis=1)
        h = fit_head(X, y.astype(int), ("score", "snr"), C=1.0)
        z = h.logits({"score": X[:, 0], "snr": X[:, 1]})
        self.assertGreater(((z > 0) == y).mean(), 0.9)
        self.assertEqual(S.Head.from_json(h.to_json()), h)

    def test_features_from_stored_windows_match_audio_path(self):
        from lfspk.embed.head import _pack, _unpack, features_for

        sc = make("gated", window_gate=0.2, dictation_gate=0.3)
        enrol = [tone(3, TARGET, seed=i) for i in range(4)] + [tone(3, OTHER, seed=9)]
        audio = np.concatenate([tone(2, TARGET, seed=7), silence(1), tone(2, OTHER, seed=8)])
        w = S.embed_windows(sc.embedder, audio, sc.config.window)
        rec = {"mix": _pack(w), "energy_db": w.energy_db, "gate": w.gate,
               "labels": np.zeros(api.frame_count(audio.size), np.uint8),
               "enroll": [_pack(S.embed_windows(sc.embedder, e, sc.config.update_window)) for e in enrol]}
        stored, _ = features_for(sc, rec)
        prof = sc.enroll(enrol[:3])  # the harness's order: enroll 3, then update with the rest
        for e in enrol[3:]:
            prof = sc.update(prof, e)
        self.assertEqual(prof.seen, 5)
        direct = sc.frame_features(prof, audio)
        for k in S.FEATURES:
            np.testing.assert_allclose(stored[k], direct[k], atol=1e-9, err_msg=k)
        self.assertEqual(len(_unpack(rec["mix"]).spans), len(w.spans))


class RobustMeanTest(unittest.TestCase):
    def test_outliers_trimmed(self):
        rng = np.random.default_rng(0)
        a = rng.standard_normal(8)
        a /= np.linalg.norm(a)
        inl = a + 0.05 * rng.standard_normal((40, 8))
        out = -a + 0.05 * rng.standard_normal((10, 8))
        x = np.concatenate([inl, out])
        x /= np.linalg.norm(x, axis=1, keepdims=True)
        self.assertGreater(S.robust_mean(x, 3.0) @ a, 0.99)


if __name__ == "__main__":
    unittest.main()


class AdaptHelpersTest(unittest.TestCase):
    def test_poisoned_stream(self):
        from lfspk.embed.adapt import _poisoned

        a = [f"a/{i}" for i in range(30)]
        b = [f"b/{i}" for i in range(30)]
        for frac, n in ((0.3, 8), (0.5, 14)):
            p = _poisoned(a, b, frac, "seed")
            self.assertEqual(p[:3], a[:3])  # enrollment untouched
            self.assertEqual(sum(x.startswith("b/") for x in p), n)  # round(frac * 27)
            self.assertEqual([x for x in p if x.startswith("b/")], b[3:3 + n])  # B's dictations in order
            self.assertEqual(p, _poisoned(a, b, frac, "seed"))
            self.assertEqual(len(p), 30)

    def test_spouse_same_half_and_sex(self):
        from lfspk.embed.adapt import spouse_of

        spk = [str(i) for i in range(10)]
        sex = {s: "F" if int(s) % 2 else "M" for s in spk}
        half = {s: "A" if int(s) < 5 else "B" for s in spk}
        for a in spk:
            b = spouse_of(a, spk, sex, half, True)
            self.assertNotEqual(a, b)
            self.assertEqual((sex[a], half[a]), (sex[b], half[b]))
            c = spouse_of(a, spk, sex, half, False)
            self.assertNotEqual(sex[a], sex[c])
            self.assertEqual(half[a], half[c])

    def test_window_methods_equal_audio_methods(self):
        sc = make("gated", window_gate=0.2, dictation_gate=0.2)
        clips = [tone(3, TARGET, seed=i) for i in range(3)]
        upd = tone(4, TARGET, seed=9)
        p1 = sc.update(sc.enroll(clips), upd)
        W = [S.embed_windows(sc.embedder, c, sc.config.update_window) for c in clips]
        p2 = sc.update_windows(sc.enroll_windows(W), S.embed_windows(sc.embedder, upd, sc.config.update_window))
        self.assertEqual(p1.to_bytes(), p2.to_bytes())


class LongHorizonTest(unittest.TestCase):
    def test_long_stream_cycles_updates(self):
        from lfspk.embed.adapt import _long

        a = [f"a/{i}" for i in range(30)]
        s = _long(a, 300, "x")
        self.assertEqual(len(s), 300)
        self.assertEqual(s[:3], a[:3])
        self.assertTrue(set(s[3:]) <= set(a[3:]))
        for start in range(3, 300 - 27, 27):  # every full pass is a permutation of the 27 updates
            self.assertEqual(sorted(s[start:start + 27]), sorted(a[3:]))
        self.assertEqual(s, _long(a, 300, "x"))

    def test_poison_cycles_short_spouse_stream(self):
        from lfspk.embed.adapt import _poisoned

        a = [f"a/{i}" for i in range(300)]
        b = [f"b/{i}" for i in range(10)]
        p = _poisoned(a, b, 0.5, "k")
        self.assertEqual(sum(x.startswith("b/") for x in p), round(0.5 * 297))
        self.assertTrue({x for x in p if x.startswith("b/")} <= set(b[3:]))


class StreamConditionsTest(unittest.TestCase):
    def _cache(self):
        from lfspk.embed.adapt import Cache

        by_key = {}
        for spk in ("1", "2"):
            for j in range(30):
                by_key[f"{spk}/enroll/{j}"] = {"key": f"{spk}/enroll/{j}", "speaker": spk, "kind": "enroll", "j": j,
                                               "relation": "cross_project" if j < 20 else "same_project_cross_chapter"}
        by_key["1/dirty/5"] = {"key": "1/dirty/5", "speaker": "1", "kind": "dirty", "j": 5, "relation": "cross_project"}
        return Cache(np.zeros((0, 4)), by_key, {})

    def test_mature_poison_and_burst(self):
        from lfspk.embed import adapt as AD

        cache = self._cache()
        conds = AD.conditions()
        s = AD.stream_for(cache, "1", conds["long_mature_poison30_samesex"], "2")
        self.assertEqual(len(s), AD.LONG_HORIZON)
        self.assertFalse(any(k.startswith("2/") for k in s[:AD.MATURE]))  # mature profile first
        self.assertEqual(sum(k.startswith("2/") for k in s[AD.MATURE:]), round(0.3 * (AD.LONG_HORIZON - AD.MATURE)))
        b = AD.stream_for(cache, "1", conds["long_mature_burst20_samesex"], "2")
        self.assertTrue(all(k.startswith("2/") for k in b[AD.MATURE:AD.MATURE + AD.BURST]))
        self.assertFalse(any(k.startswith("2/") for k in b[:AD.MATURE] + b[AD.MATURE + AD.BURST:]))
        clean = AD.stream_for(cache, "1", conds["long_clean"], None)
        self.assertEqual(clean[:AD.MATURE], s[:AD.MATURE])  # paired with its baseline
        dirty = AD.stream_for(cache, "1", conds["contaminated20"], None)
        self.assertEqual(dirty[5], "1/dirty/5")
        self.assertEqual(cache.relation("1", 10), "cross_project")
        self.assertEqual(cache.relation("1", 30), "same_project_cross_chapter")

    def test_complete_rule_gate(self):
        from lfspk.embed.adapt import complete_rule_gate

        scores = np.array([-np.inf] * 150 + list(np.linspace(0, 1, 50)))
        g = complete_rule_gate(scores, 0.01)  # 2 of 200 may pass
        self.assertEqual(int((scores >= g).sum()), 2)
        self.assertEqual(complete_rule_gate(np.array([-np.inf] * 10 + [0.5]), 0.1), -np.inf)  # 1 of 11 allowed


def _toy_cache(dim=8, n=30, projects=("P1",) * 30, session=None):
    """Two speakers with 30 dictations each (2 windows per dictation), clustered
    around different directions; headset twins slightly rotated."""
    from lfspk.embed.adapt import WINDOW, Cache

    rng = np.random.default_rng(0)
    centres = {"1": np.eye(dim)[0], "2": np.eye(dim)[1]}
    rows, by_key = [], {}

    def add(key, spk, kind, j, centre, extra=None):
        v = centre + 0.2 * rng.standard_normal((2, dim))
        v /= np.linalg.norm(v, axis=1, keepdims=True)
        by_key[key] = dict({"key": key, "speaker": spk, "kind": kind, "j": j, "row": len(rows) * 2, "n": 2,
                            "n_layout": 2, "spans": [[0, 24000], [4000, 24000]]}, **(extra or {}))
        rows.append(v)

    for spk, c in centres.items():
        hs = c + 0.3 * np.eye(dim)[2]
        for j in range(n):
            rel = {"relation": "cross_project", "project": projects[j], "chapter": "1"}
            add(f"{spk}/enroll/{j}", spk, "enroll", j, c, rel)
            add(f"{spk}/enroll_hs/{j}", spk, "enroll_hs", j, hs / np.linalg.norm(hs), rel)
        for proj, count in (session or {}).items():
            for j in range(count):
                add(f"{spk}/session/{proj}/{j}", spk, "session", j, c, {"project": proj, "chapter": "9"})
    return Cache(np.concatenate(rows).astype(np.float32), by_key, WINDOW.__dict__,
                 {"git": "abc", "smoke": False})


class SimulationCoreTest(unittest.TestCase):
    def _scorer(self, rule):
        from lfspk.embed.adapt import _NoModel

        cfg = S.ScorerConfig("redimnet2-b0", norm="raw", update=S.UpdateConfig(rule=rule, window_gate=0.5,
                                                                               dictation_gate=0.6))
        return S.EmbeddingScorer(cfg, embedder=_NoModel("redimnet2-b0"))

    def test_second_speaker_involved_only_after_entering(self):
        from lfspk.embed import adapt as AD

        cache = _toy_cache()
        c = AD.conditions()["long_mature_poison30_samesex"]
        run = AD.simulate_condition(self._scorer("naive"), cache, ["1", "2"], c, {"1": "2", "2": "1"})
        self.assertEqual(run.involved[300], {})  # mature, before any spouse dictation
        self.assertEqual(run.involved[400], {"1": "2", "2": "1"})
        self.assertEqual(set(run.snaps[600]), {"1", "2"})

    def test_bases_cover_snapshots(self):
        from lfspk.embed import adapt as AD

        conds = AD.conditions()
        for name, c in conds.items():
            if "base" in c:
                self.assertTrue(set(c["snaps"]) <= set(conds[c["base"]]["snaps"]), name)
        self.assertIn(320, conds["long_clean"]["snaps"])  # the burst's peak exposure is paired

    def test_change_streams(self):
        from lfspk.embed import adapt as AD

        conds = AD.conditions()
        cache = _toy_cache(session={"P1": 20, "P2": 16, "P3": 9})
        s = AD.stream_for(cache, "1", conds["long_session_change"], None)
        ctl = AD.stream_for(cache, "1", conds["long_session_control"], None)
        self.assertEqual(len(s), AD.LONG_HORIZON)
        self.assertEqual(s[:AD.MATURE], ctl[:AD.MATURE])  # the control shares the first 300 exactly
        self.assertTrue(all(cache.by_key[k]["project"] == "P1" for k in s[:AD.MATURE] + ctl))
        self.assertTrue(all(cache.by_key[k]["project"] == "P2" for k in s[AD.MATURE:]))
        self.assertEqual(conds["long_session_change"]["base"], "long_session_control")
        thin = _toy_cache(session={"P1": 20, "P2": AD.SESSION_MIN - 1})
        self.assertIsNone(AD.stream_for(thin, "1", conds["long_session_change"], None))  # too few distinct
        cache = _toy_cache()
        d = AD.stream_for(cache, "1", conds["long_device_change"], None)
        self.assertTrue(all("/enroll/" in k for k in d[:AD.MATURE]))
        self.assertTrue(all("/enroll_hs/" in k for k in d[AD.MATURE:]))
        self.assertEqual(conds["long_device_change"]["targets"], "headset")

    def test_cache_refuses_other_window(self):
        import json
        import tempfile
        from unittest import mock

        from lfspk.embed import adapt as AD

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "train" / "x"
            d.mkdir(parents=True)
            np.save(d / "emb.f32.npy", np.zeros((0, 4), np.float32))
            (d / "index.json").write_text(json.dumps({"window": {"window_s": 1.0, "hop_s": 0.5, "min_speech": 0.3},
                                                      "dictations": []}))
            with mock.patch.object(AD, "OUT", Path(tmp)), self.assertRaises(ValueError):
                AD.Cache.load("train", "x")


class AcceptancePathCalibrationTest(unittest.TestCase):
    def test_gate_matches_updater_decision(self):
        """Reviewer's case: identical statistics. Calibration and the updater
        agree because both use the float64 statistic of `scorer.accepts`."""
        from lfspk.embed.adapt import complete_rule_gate

        cfg = S.UpdateConfig(rule="gated", window_gate=0.0, min_kept=0.5)
        windows = [np.full(6, 0.5, np.float32) for _ in range(100)]
        stats = np.array([S.dictation_statistic(w, cfg.window_gate, cfg.min_kept) for w in windows])
        gate = complete_rule_gate(stats, 0.01)
        cfg = S.UpdateConfig(rule="gated", window_gate=0.0, dictation_gate=gate, min_kept=0.5)
        self.assertLessEqual(sum(S.accepts(w, cfg) for w in windows), 1)
        rng = np.random.default_rng(3)
        windows = [rng.standard_normal(10).astype(np.float32) for _ in range(500)]
        stats = np.array([S.dictation_statistic(w, 0.0, 0.5) for w in windows])
        gate = complete_rule_gate(stats, 0.02)
        cfg = S.UpdateConfig(rule="gated", window_gate=0.0, dictation_gate=gate, min_kept=0.5)
        self.assertEqual(sum(S.accepts(w, cfg) for w in windows), 10)

    def test_rejected_dictations_never_pass_an_infinite_gate(self):
        cfg = S.UpdateConfig(rule="gated", window_gate=1.0, dictation_gate=-np.inf, min_kept=0.5)
        self.assertFalse(S.accepts(np.zeros(10), cfg))  # min_kept fails: rejected even at gate -inf
        self.assertFalse(S.accepts(np.zeros(0), cfg))


class FactoryTest(unittest.TestCase):
    def _root(self, tmp, head_prov, gates_prov):
        import json

        from lfspk.embed import adapt as AD

        runs = Path(tmp)
        hd = runs / "head" / "redimnet2-b0_L1.5_H0.25"
        hd.mkdir(parents=True)
        h = S.Head(("score",), (0.5,), (0.1,), (3.0,), 0.2)
        (hd / "head_raw_robust_score_C1.0.json").write_text(h.to_json())
        if head_prov is not None:
            (hd / "head_raw_robust_score_C1.0.meta.json").write_text(json.dumps(head_prov))
        gd = runs / "adapt" / "train" / "redimnet2-b0"
        gd.mkdir(parents=True)
        gates = {"embedder": "redimnet2-b0", "norm": "raw", "window": AD.WINDOW.__dict__, "min_kept": 0.5,
                 "window_gate": 0.3, "dictation_gate": 0.4, "anchor_gate": 0.1, "drift_floor": 0.8, **gates_prov}
        (gd / "gates_raw.json").write_text(json.dumps(gates))
        return runs, h

    @unittest.skipUnless((Path("/mnt/hd/localflow-speaker/data/models/redimnet2-b0")).is_dir(), "needs weights")
    def test_one_root_and_provenance(self):
        import tempfile

        from lfspk.embed import factory as F

        real = {"git": "abc", "smoke": False}
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError):
                F.make("redimnet2-b0", norm="raw", runs=tmp)
            runs, h = self._root(tmp, real, real)
            sc = F.make("redimnet2-b0", norm="raw", runs=str(runs))  # gates found beneath the same root
        self.assertEqual(sc.name, "w1-redimnet2-b0-L1.5-H0.25-raw-robust-score-C1.0")
        self.assertEqual(sc.config.head, h)
        self.assertEqual((sc.config.update.window_gate, sc.config.update.dictation_gate), (0.3, 0.4))
        api.check_scores(sc.score(sc.enroll([tone(3, TARGET)]), tone(2, TARGET)), 32000)
        bad_cases = ((None, real), ({"git": "abc", "smoke": True}, real), (real, {"git": "abc-dirty", "smoke": False}),
                     (real, {"git": "abc", "smoke": True}))
        for head_prov, gates_prov in bad_cases:
            with tempfile.TemporaryDirectory() as tmp:
                runs, _ = self._root(tmp, head_prov, gates_prov)
                with self.assertRaises(RuntimeError):
                    F.make("redimnet2-b0", norm="raw", runs=str(runs))
                F.make("redimnet2-b0", norm="raw", runs=str(runs), smoke="1")  # smoke runs may use them


class ChangeAcceptanceTest(unittest.TestCase):
    def _run(self, pre_ok, post_ok, n_spk=20):
        from lfspk.embed.adapt import MATURE, LONG_HORIZON, Run

        run = Run({}, {}, {}, [])
        for a in range(n_spk):
            run.accept_user[str(a)] = [(i, (pre_ok if i <= MATURE else post_ok)) for i in range(4, LONG_HORIZON + 1)]
        return run

    def test_verdicts(self):
        from lfspk.embed import metrics as M
        from lfspk.embed.adapt import change_acceptance

        sidx = {str(a): a for a in range(20)}
        mults = M.speaker_multiplicities(20, 200, 1)
        self.assertEqual(change_acceptance(self._run(True, True), self._run(True, True), mults, sidx)["verdict"],
                         "follows")
        lock = change_acceptance(self._run(True, False), self._run(True, True), mults, sidx)
        self.assertEqual(lock["verdict"], "locks_out")
        self.assertAlmostEqual(lock["last_minus_control"]["value"], -1.0)


class ProvenanceTest(unittest.TestCase):
    def test_real_runs_refuse_smoke_or_dirty_upstream(self):
        from lfspk.embed.adapt import check_upstream

        check_upstream({"git": "abc", "smoke": False}, False, "x")
        check_upstream({"git": "abc", "smoke": True}, True, "x")  # smoke may consume smoke
        for prov in ({"git": "abc", "smoke": True}, {"git": "abc-dirty", "smoke": False}, {}):
            with self.assertRaises(RuntimeError):
                check_upstream(prov, False, "x")


class UpdateWindowTest(unittest.TestCase):
    def test_update_window_independent_of_scoring_window(self):
        """Enrollment and updates use the fixed update window whatever the
        scoring window, so calibrated gates apply to every scoring config."""
        clips = [tone(3, TARGET, seed=i) for i in range(3)]
        a = S.EmbeddingScorer(S.ScorerConfig("redimnet2-b0", S.WindowConfig(1.0, 0.25), norm="raw"),
                              embedder=ToyEmbedder())
        b = S.EmbeddingScorer(S.ScorerConfig("redimnet2-b0", S.WindowConfig(1.5, 0.5), norm="raw"),
                              embedder=ToyEmbedder())
        self.assertEqual(a.enroll(clips).to_bytes(), b.enroll(clips).to_bytes())
        self.assertEqual(a.config.update_window, S.UPDATE_WINDOW)

    def test_cohort_lengths(self):
        rng = np.random.default_rng(0)
        c = rng.standard_normal((300, 16)).astype(np.float32)
        c /= np.linalg.norm(c, axis=1, keepdims=True)
        coh = S.Cohort(c, c[:250], c[50:])
        self.assertIs(coh.update_or_window, coh.update)
        self.assertIs(S.Cohort(c, c).update_or_window, c)


class R4RegressionTest(unittest.TestCase):
    def test_zero_baselines_are_unidentifiable(self):
        """Reviewer's cases: nothing accepted before the change."""
        from lfspk.embed import metrics as M
        from lfspk.embed.adapt import change_acceptance

        sidx = {str(a): a for a in range(14)}
        mults = M.speaker_multiplicities(14, 200, 2)
        mk = ChangeAcceptanceTest()._run
        for post in (False, True):
            r = change_acceptance(mk(False, post, 14), mk(True, True, 14), mults, sidx)
            self.assertEqual(r["verdict"], "unidentifiable")
            self.assertIsNone(r["ratio"])
        empty = change_acceptance(type(mk(True, True))({}, {}, {}, []), mk(True, True), mults, sidx)
        self.assertEqual(empty["verdict"], "no qualifying speakers")

    def test_head_fit_reads_one_complete_generation(self):
        """Reviewer's r5 case: a complete extraction, then an interrupted
        rerun that replaced shards. With generations the rerun writes a fresh
        directory and never moves CURRENT, so the fit reads only the complete
        run; a CURRENT pointing at an incomplete generation is refused."""
        import json
        import tempfile

        from lfspk.embed.head import check_extraction_provenance, current_generation

        with tempfile.TemporaryDirectory() as tmp:
            tag = Path(tmp)
            with self.assertRaises(FileNotFoundError):
                current_generation(tag)
            a = tag / "gen-a"
            a.mkdir()
            np.save(a / "shard_0000.npy", np.array([{}] * 250, dtype=object), allow_pickle=True)
            np.save(a / "shard_0001.npy", np.array([{}], dtype=object), allow_pickle=True)
            (a / "meta.json").write_text(json.dumps({"n_mix": 251, "git": "abc", "smoke": False}))
            (tag / "CURRENT").write_text("gen-a")
            b = tag / "gen-b"  # interrupted smoke rerun: one shard, no metadata, CURRENT untouched
            b.mkdir()
            np.save(b / "shard_0000.npy", np.array([{}] * 250, dtype=object), allow_pickle=True)
            self.assertEqual(current_generation(tag), a)
            check_extraction_provenance(current_generation(tag), False)
            (tag / "CURRENT").write_text("gen-b")
            with self.assertRaises(RuntimeError):
                check_extraction_provenance(current_generation(tag), False)
            (a / "meta.json").write_text(json.dumps({"n_mix": 300, "git": "abc", "smoke": False}))
            (tag / "CURRENT").write_text("gen-a")
            with self.assertRaises(RuntimeError):  # count mismatch
                check_extraction_provenance(current_generation(tag), False)


class R4MoreRegressionTest(unittest.TestCase):
    def test_stale_dev_cache_rejected_before_simulation(self):
        import argparse
        import json
        import tempfile
        from unittest import mock

        from lfspk.embed import adapt as AD

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "dev" / "x"
            d.mkdir(parents=True)
            np.save(d / "emb.f32.npy", np.zeros((2, 4), np.float32))
            (d / "index.json").write_text(json.dumps({"window": AD.WINDOW.__dict__, "git": "a", "smoke": True,
                                                      "dictations": [{"key": "1/enroll/0", "speaker": "1",
                                                                      "kind": "enroll", "j": 0, "row": 0, "n": 2,
                                                                      "n_layout": 2, "spans": [[0, 1], [0, 1]]}]}))
            args = argparse.Namespace(embedder="x", norm="raw", survey_root=None, smoke=True, n_boot=5)
            with mock.patch.object(AD, "OUT", Path(tmp)), mock.patch.object(AD, "require_clean", lambda s: "a"), \
                    self.assertRaisesRegex(ValueError, "rebuild"):
                AD.cmd_simulate(args)

    def test_merged_smoke_flag_is_any(self):
        import argparse
        import contextlib
        import io
        import json
        import tempfile

        from lfspk.embed import survey as SV

        def one(name, smoke):
            return {"git": "a", "smoke": smoke, "n_boot": 1, "boot_seed": 1,
                    "embedders": {name: {"meta": {"params": 1}, "ci": {}, "point": {}, "speakers": ["1"],
                                         "smoke": smoke, "paired": {},
                                         "seen_speaker_check": {"train_within_cos": 0, "dev_within_cos": 0,
                                                                "gap": 0, "gap_ci": [0, 0]}}}}
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "results"
            d.mkdir()
            (d / "intrinsic_a.json").write_text(json.dumps(one("a", False)))  # real result sorts first
            (d / "intrinsic_b.json").write_text(json.dumps(one("b", True)))
            with contextlib.redirect_stdout(io.StringIO()):
                SV.cmd_render(argparse.Namespace(out=tmp))
            merged = json.loads((d / "intrinsic.json").read_text())
        self.assertTrue(merged["smoke"])


class R5RegressionTest(unittest.TestCase):
    def _survey(self, meta, half):
        import types

        return types.SimpleNamespace(meta=meta, half=half)

    def test_embedding_provenance_rules(self):
        import argparse

        from lfspk.embed.survey import embedding_provenance

        real = argparse.Namespace(smoke=False, accept_embed_provenance=[], provenance_reason="")
        self.assertIsNone(embedding_provenance(self._survey({"git": "abc", "smoke": False}, None), "x", real, "c"))
        for meta in ({"git": "abc", "smoke": True}, {"git": "abc-dirty", "smoke": False}, {}):
            with self.assertRaises(RuntimeError):
                embedding_provenance(self._survey(meta, None), "x", real, "c")
        ok = argparse.Namespace(smoke=False, accept_embed_provenance=["x"], provenance_reason="same code path")
        for meta in ({"git": "abc", "smoke": True}, {"git": "abc-dirty", "smoke": False}):
            rec = embedding_provenance(self._survey(meta, None), "x", ok, "c")  # smoke inputs recorded too
            self.assertEqual(rec["reason"], "same code path")
            self.assertEqual(rec["embedding_smoke"], meta["smoke"])


class WindowCacheTest(unittest.TestCase):
    def test_cache_gives_identical_scores_and_is_bounded(self):
        calls = []

        class Counting(ToyEmbedder):
            def embed_batch(self, audios):
                calls.append(len(audios))
                return super().embed_batch(audios)

        cached = S.EmbeddingScorer(S.ScorerConfig("redimnet2-b0", S.WindowConfig(1.0, 0.25), norm="raw"),
                                   embedder=Counting(), cache_windows=2)
        plain = S.EmbeddingScorer(S.ScorerConfig("redimnet2-b0", S.WindowConfig(1.0, 0.25), norm="raw"),
                                  embedder=ToyEmbedder())
        p = plain.enroll([tone(3, TARGET)])
        q = plain.update(p, tone(3, TARGET, seed=4))  # a second profile, as the harness uses 12
        clips = [tone(2, TARGET, seed=i) for i in range(3)]
        calls.clear()
        for prof in (p, q):
            for c in clips[:2]:
                np.testing.assert_array_equal(cached.score(prof, c), plain.score(prof, c))
        self.assertEqual(len(calls), 2)  # the second profile is served from the cache
        cached.score(p, clips[2])
        self.assertEqual(len(cached._cache), 2)  # bounded


class StageCReportTest(unittest.TestCase):
    def test_verdict_rules(self):
        from lfspk.embed.adapt import H4_MARGIN, H5_MARGIN, verdict

        self.assertEqual(verdict({"value": 0.001, "lo": -0.002, "hi": 0.004}, H4_MARGIN, "robust", "harmed"), "robust")
        self.assertEqual(verdict({"value": 0.006, "lo": 0.001, "hi": 0.009}, H4_MARGIN, "robust", "harmed"),
                         "inconclusive")  # straddles +0.5
        self.assertEqual(verdict({"value": 0.03, "lo": 0.02, "hi": 0.04}, H5_MARGIN, "resists", "poisoned"), "poisoned")
