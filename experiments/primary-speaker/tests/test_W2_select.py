import unittest

import numpy as np

from lfspk.probe import select as S


def fake_ids(spk, chapters):
    return [f"{spk}-{c}-{i:04d}" for c, n in chapters for i in range(n)]


class TestActivity(unittest.TestCase):
    def test_rule(self):
        sr = 16000
        quiet = np.zeros(sr // 2, np.float32)
        loud = (0.1 * np.sin(np.arange(sr // 2) * 0.3)).astype(np.float32)
        faint = (0.1 * 10 ** (-40 / 20) * np.sin(np.arange(sr // 2) * 0.3)).astype(np.float32)
        act = S.activity(np.r_[quiet, loud, faint])
        self.assertEqual(act.size, 150)
        self.assertFalse(act[:50].any())
        self.assertTrue(act[50:100].all())
        self.assertFalse(act[100:].any())  # 40 dB below the loudest frame
        # absolute floor: a whole utterance at -70 dBFS is inactive
        self.assertFalse(S.activity(np.full(1600, 10 ** (-70 / 20), np.float32)).any())

    def test_external_reference(self):
        x = np.full(1600, 0.01, np.float32)  # -40 dBFS
        self.assertTrue(S.activity(x).all())
        self.assertFalse(S.activity(x, reference_db=0.0).any())

    def test_partial_final_frame_counts(self):
        self.assertEqual(S.activity(np.ones(161, np.float32) * 0.1).size, 2)


class TestCrop(unittest.TestCase):
    def test_crop_is_active_aligned_and_deterministic(self):
        sr = 16000
        x = np.zeros(10 * sr, np.float32)
        x[6 * sr:8 * sr] = 0.1  # only 2 s of speech
        c1 = S.choose_crop(x, 1.0, S.rng_for("a"))
        c2 = S.choose_crop(x, 1.0, S.rng_for("a"))
        self.assertEqual(c1, c2)
        self.assertEqual(c1.length, sr)
        self.assertEqual(c1.start % 160, 0)
        self.assertGreaterEqual(c1.active_fraction, 0.5)
        self.assertGreaterEqual(c1.start, 5.5 * sr - 160)
        self.assertFalse(c1.fallback)

    def test_short_utterance_returns_whole(self):
        x = np.full(8000, 0.1, np.float32)
        c = S.choose_crop(x, 2.0, S.rng_for("b"))
        self.assertEqual((c.start, c.length), (0, 8000))

    def test_fallback_flagged(self):
        x = np.zeros(5 * 16000, np.float32)
        x[:1600] = 0.1
        c = S.choose_crop(x, 2.0, S.rng_for("c"))
        self.assertTrue(c.fallback or c.active_fraction >= 0.5)


class TestTrainSelection(unittest.TestCase):
    def test_round_robin_and_cap(self):
        utts = {"10": fake_ids("10", [("1", 30), ("2", 5)]), "2": fake_ids("2", [("7", 3)])}
        sel = S.train_selection(utts, per_speaker=24)
        self.assertEqual(list(sel), ["2", "10"])
        self.assertEqual(len(sel["10"]), 24)
        self.assertEqual(sum(S.chapter_of(u) == "2" for u in sel["10"]), 5)
        self.assertEqual(len(set(sel["10"])), 24)
        self.assertEqual(len(sel["2"]), 3)
        # order independence
        rev = {k: list(reversed(v)) for k, v in reversed(list(utts.items()))}
        self.assertEqual(S.train_selection(rev), sel)

    def test_rejects_foreign_utterance(self):
        with self.assertRaises(ValueError):
            S.train_selection({"1": ["2-1-0001"]})


class TestDevPlan(unittest.TestCase):
    def test_sessions_and_disjoint(self):
        utts = {"5": fake_ids("5", [("100", 12), ("200", 30), ("300", 8)]),
                "6": fake_ids("6", [("1", 40)]),
                "7": fake_ids("7", [("10", 15), ("11", 12)]),
                "8": fake_ids("8", [("20", 15), ("21", 3)])}
        # 5: chapters 100 and 200 share project A, 300 is project B
        proj = {"100": "A", "200": "A", "300": "B", "1": "C", "10": "D", "11": "D", "20": "E", "21": "E"}
        plans = {p.speaker: p for p in S.dev_plan(utts, proj)}
        p5 = plans["5"]
        self.assertEqual(p5.session, "cross_project")
        enroll = [u for m in p5.enroll_models for u in m]
        self.assertEqual(len(enroll), 9)
        self.assertEqual(len(set(enroll)), 9)
        # enrollment from the chapter leaving the most cross-project material (project A, largest)
        self.assertEqual({S.chapter_of(u) for u in enroll}, {"200"})
        self.assertEqual({S.chapter_of(u) for u in p5.test}, {"300"})
        self.assertEqual(len(p5.test), 8)
        p6 = plans["6"]
        self.assertEqual(p6.session, "same_chapter")
        self.assertFalse({u for m in p6.enroll_models for u in m} & set(p6.test))
        self.assertEqual(len(p6.test), 20)
        p7 = plans["7"]
        self.assertEqual(p7.session, "cross_chapter")
        e7 = {S.chapter_of(u) for m in p7.enroll_models for u in m}
        self.assertEqual(len(e7), 1)
        self.assertFalse(e7 & {S.chapter_of(u) for u in p7.test})
        # 8: other chapter has < MIN_TEST utterances -> same chapter
        self.assertEqual(plans["8"].session, "same_chapter")
        self.assertTrue(all(S.chapter_of(u) == "20" for u in plans["8"].test))

    def test_deterministic(self):
        utts = {"5": fake_ids("5", [("100", 12), ("200", 30)])}
        proj = {"100": "A", "200": "B"}
        a = S.dev_plan(utts, proj)
        b = S.dev_plan({"5": list(reversed(utts["5"]))}, proj)
        self.assertEqual(a, b)

    def test_parse_chapters(self):
        text = "; comment\n1 | 110 | 19.77 | train-other-500 | 53 | 1023 | In Chancery | Bleak House\n"
        self.assertEqual(S.parse_chapters_txt(text), {"1": "53"})

    def test_dev_halves(self):
        sex = {str(i): ("F" if i % 2 else "M") for i in range(1, 42)}
        ses = {str(i): ("cross_project" if i % 3 else "same_chapter") for i in range(1, 42)}
        strata = {k: (sex[k], ses[k]) for k in sex}
        s_half, e_half = S.dev_halves(strata)
        self.assertEqual(len(s_half) + len(e_half), 41)
        self.assertFalse(set(s_half) & set(e_half))
        for st in set(strata.values()):
            n_s = sum(strata[x] == st for x in s_half)
            n_e = sum(strata[x] == st for x in e_half)
            self.assertLessEqual(abs(n_s - n_e), 1)
        self.assertLessEqual(abs(len(s_half) - len(e_half)), 2)
        self.assertEqual(S.dev_halves(dict(reversed(list(strata.items())))), (s_half, e_half))

    def test_odd_strata_alternate(self):
        # strata sizes 1, 2, 1, 2, 1 in sorted order: extras go E, S, E -> S 3, E 4
        sizes = {"a": 1, "b": 2, "c": 1, "d": 2, "e": 1}
        strata, k = {}, 1
        for st, n in sizes.items():
            for _ in range(n):
                strata[str(k)] = st
                k += 1
        s_half, e_half = S.dev_halves(strata)
        self.assertEqual((len(s_half), len(e_half)), (3, 4))
        by = {st: (sum(strata[x] == st for x in s_half), sum(strata[x] == st for x in e_half)) for st in sizes}
        self.assertEqual(by, {"a": (0, 1), "b": (1, 1), "c": (1, 0), "d": (1, 1), "e": (0, 1)})

    def test_dev_strata(self):
        p = S.DevSpeakerPlan("3", "cross_chapter")
        self.assertEqual(S.dev_strata([p, {"speaker": "4", "session": "same_chapter"}], {"3": "F", "4": "M"},
                                      {"3": "dev-clean", "4": "dev-other"}),
                         {"3": ("dev-clean", "F", "cross_chapter"), "4": ("dev-other", "M", "same_chapter")})


if __name__ == "__main__":
    unittest.main()
