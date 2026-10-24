import unittest

import numpy as np

from lfspk import api


class FrameCountTest(unittest.TestCase):
    def test_partial_final_frame_counts(self):
        self.assertEqual(api.frame_count(0), 0)
        self.assertEqual(api.frame_count(1), 1)
        self.assertEqual(api.frame_count(160), 1)
        self.assertEqual(api.frame_count(161), 2)
        self.assertEqual(api.frame_count(16_000), 100)

    def test_negative_rejected(self):
        with self.assertRaises(ValueError):
            api.frame_count(-1)


class CheckTest(unittest.TestCase):
    def test_audio_validation(self):
        api.check_audio(np.zeros(10, np.float32))
        for bad in (np.zeros(10, np.float64), np.zeros((2, 5), np.float32), np.full(3, 1.5, np.float32),
                    np.array([np.nan], np.float32)):
            with self.assertRaises((TypeError, ValueError)):
                api.check_audio(bad)

    def test_scores_validation(self):
        api.check_scores(np.full(2, 0.5, np.float32), 161)
        for bad, n in ((np.full(1, 0.5, np.float32), 161), (np.full(2, 0.5, np.float64), 161),
                       (np.full(2, 1.1, np.float32), 161), (np.full(2, -0.1, np.float32), 161)):
            with self.assertRaises((TypeError, ValueError)):
                api.check_scores(bad, n)


class _Profile:
    def __init__(self, n):
        self.n = n

    def to_bytes(self):
        return self.n.to_bytes(4, "little")


class _Constant:
    """Minimal conforming scorer, to pin the protocol shape."""

    name = "constant"

    def enroll(self, utterances):
        return _Profile(len(utterances))

    def update(self, profile, utterance):
        return _Profile(profile.n + 1)

    def score(self, profile, audio):
        return np.ones(api.frame_count(len(audio)), np.float32)

    def cost(self):
        return api.CostReport(params=0, macs_per_audio_second=0, update_macs=0, profile_bytes=4)


class ProtocolTest(unittest.TestCase):
    def test_conforming_scorer(self):
        s = _Constant()
        self.assertIsInstance(s, api.TargetSpeakerScorer)
        p = s.update(s.enroll([np.zeros(1600, np.float32)]), np.zeros(800, np.float32))
        self.assertIsInstance(p, api.Profile)
        api.check_scores(s.score(p, np.zeros(1601, np.float32)), 1601)


if __name__ == "__main__":
    unittest.main()
