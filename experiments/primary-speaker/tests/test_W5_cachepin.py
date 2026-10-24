"""W5 cache pinning (DESIGN section 10.2; review r3 #1, r4 #1, r4 #2)."""

from __future__ import annotations

import copy
import unittest

from lfspk.extract import cachepin
from lfspk.extract.cachepin import StaleCache

B_ID = {"model": "/m/parakeet.nemo", "model_sha256": "ab" * 32, "decoding": "greedy TDT, fp32, timestamps", "nemo": "3.0"}


def rec(key="mix:S1-84-00", text="hello world", words=None, audio="cd" * 32):
    return {"key": key, "audio_sha256": audio, "text": text,
            "words": words if words is not None else [["hello", 0.32, 0.56], ["world", 0.64, 1.04]]}


class TestDigest(unittest.TestCase):
    def test_field_order_does_not_matter(self):
        r = rec()
        reordered = {"words": r["words"], "text": r["text"], "audio_sha256": r["audio_sha256"], "key": r["key"]}
        self.assertEqual(cachepin.record_digest(r), cachepin.record_digest(reordered))

    def test_extra_fields_are_ignored(self):
        r = rec()
        self.assertEqual(cachepin.record_digest(r), cachepin.record_digest({**r, "bypass": True, "other": 1}))

    def test_timestamp_only_change(self):
        r, s = rec(), rec()
        s["words"][1][1] = 0.6400001
        self.assertNotEqual(cachepin.record_digest(r), cachepin.record_digest(s))

    def test_word_only_change(self):
        r, s = rec(), rec()
        s["words"][0][0] = "hullo"
        self.assertNotEqual(cachepin.record_digest(r), cachepin.record_digest(s))

    def test_word_order_matters(self):
        r = rec()
        s = rec(words=list(reversed(r["words"])))
        self.assertNotEqual(cachepin.record_digest(r), cachepin.record_digest(s))

    def test_missing_field(self):
        r = rec()
        del r["words"]
        with self.assertRaises(KeyError):
            cachepin.record_digest(r)


class TestBypassPins(unittest.TestCase):
    def setUp(self):
        self.b = {r["key"]: r for r in (rec(), rec(key="mix:S0-84-00", text="a b", audio="ef" * 32))}
        self.frozen = {k: r["audio_sha256"] for k, r in self.b.items()}
        self.entries = {k: cachepin.pin_bypass(r, B_ID, self.frozen[k]) for k, r in self.b.items()}

    def test_unchanged_b_loads(self):
        self.assertEqual(cachepin.verify_bypass(self.entries, self.b, B_ID, self.frozen), 2)

    def test_changed_b_record_is_refused(self):
        b = copy.deepcopy(self.b)
        b["mix:S1-84-00"]["text"] = "hello word"
        with self.assertRaises(StaleCache):
            cachepin.verify_bypass(self.entries, b, B_ID, self.frozen)

    def test_changed_b_timestamps_are_refused(self):
        b = copy.deepcopy(self.b)
        b["mix:S1-84-00"]["words"][0][2] = 0.57
        with self.assertRaises(StaleCache):
            cachepin.verify_bypass(self.entries, b, B_ID, self.frozen)

    def test_changed_b_identity_is_refused(self):
        with self.assertRaises(StaleCache):
            cachepin.verify_bypass(self.entries, self.b, {**B_ID, "nemo": "3.1"}, self.frozen)

    def test_missing_b_record_is_refused(self):
        b = dict(self.b)
        del b["mix:S0-84-00"]
        with self.assertRaises(StaleCache):
            cachepin.verify_bypass(self.entries, b, B_ID, self.frozen)

    def test_altered_copy_is_refused(self):
        e = copy.deepcopy(self.entries)
        e["mix:S1-84-00"]["text"] = "edited"
        with self.assertRaises(StaleCache):
            cachepin.verify_bypass(e, self.b, B_ID, self.frozen)

    def test_audio_hash_must_match_frozen_set(self):
        with self.assertRaises(StaleCache):
            cachepin.pin_bypass(rec(), B_ID, "00" * 32)
        with self.assertRaises(StaleCache):
            cachepin.verify_bypass(self.entries, self.b, B_ID, {**self.frozen, "mix:S1-84-00": "00" * 32})

    def test_non_bypass_entries_are_not_checked(self):
        e = {**self.entries, "mix:S2-84-00": {**rec(key="mix:S2-84-00"), "bypass": False}}
        self.assertEqual(cachepin.verify_bypass(e, self.b, B_ID, self.frozen), 2)


class TestIdentity(unittest.TestCase):
    def ident(self, **kw):
        args = dict(stage_a_identity_hash="aa", config={"name": "C3", "theta_b": 0.2}, asr_identity=B_ID,
                    b_identity=B_ID, hook_code_sha256="bb", batching="batched", batch_size=16)
        args.update(kw)
        return cachepin.frontend_cache_identity(**args)

    def test_batched_identity_is_headline(self):
        ident = self.ident()
        cachepin.require_headline(ident)
        self.assertEqual(ident["b_identity_hash"], cachepin.identity_hash(B_ID))

    def test_replay_is_separate(self):
        batched = self.ident()
        replay = self.ident(batching="single", batch_size=1, compared_with=cachepin.identity_hash(batched))
        self.assertNotEqual(cachepin.identity_hash(batched), cachepin.identity_hash(replay))
        with self.assertRaises(ValueError):
            cachepin.require_headline(replay)
        with self.assertRaises(ValueError):
            self.ident(batching="single", batch_size=1)  # must pin the batched cache
        with self.assertRaises(ValueError):
            self.ident(compared_with="x")  # only the replay may
        with self.assertRaises(ValueError):
            self.ident(batching="sorted")

    def test_asr_identity_must_equal_b(self):
        with self.assertRaises(StaleCache):
            self.ident(asr_identity={**B_ID, "model_sha256": "00" * 32})


if __name__ == "__main__":
    unittest.main()
