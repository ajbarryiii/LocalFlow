import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias.features import trie_features
from learned_bias.fixtures import synthetic_phrases, synthetic_shard
from learned_bias.shards import Candidates, Shard, list_shards
from learned_bias.trie import ROOT, BiasTrie

from tests.helpers import prep_fixtures  # noqa: E402


def check_candidates_against_tree(test, arrays):
    """Every state's reconstructed candidates equal an independent
    Aho-Corasick built from the shard's tree arrays alone."""
    token, parent = arrays["trie.token"], arrays["trie.parent"]
    is_end = arrays["trie.nf"][:, 1] > 0.5
    bt = BiasTrie.from_tree(token, parent, is_end)
    c = Candidates(arrays["cand.root"], arrays["cand.override.offset"], arrays["cand.override"])
    test.assertEqual(c.states(), bt.states())
    for s in range(bt.states()):
        test.assertEqual(c.list(s), bt.candidates(s), f"state {s}")
    return bt


class CandidateReconstructionTests(unittest.TestCase):
    def test_override_semantics(self):
        # Root set {1->1, 2->4}; state 3 replaces 2's destination and adds 7.
        c = Candidates([[1, 1], [2, 4]], [0, 0, 0, 0, 2, 2], [[7, 5], [2, 9]])
        self.assertEqual(c.list(0), [(1, 1), (2, 4)])
        self.assertEqual(c.list(3), [(1, 1), (2, 9), (7, 5)])
        self.assertEqual(c.list(4), [(1, 1), (2, 4)])

    def test_rejects_bad_offsets(self):
        with self.assertRaises(ValueError):
            Candidates([[1, 1]], [0, 2], [[3, 4]])

    def test_python_automaton_matches_known_failure_links(self):
        # he, she, his, hers (h=1 e=2 s=3 i=4 r=5), as in lf-cpu's tests.
        bt = BiasTrie([[1, 2], [3, 1, 2], [1, 4, 3], [1, 2, 5, 3]])
        s = ROOT
        for t in [3, 1, 2]:
            s = bt.step(s, t)
        she = s
        self.assertEqual(bt.depth[she], 3)
        # At "she", 5 continues "he" -> "her" via the failure link.
        cands = dict(bt.candidates(she))
        self.assertEqual(bt.depth[cands[5]], 3)
        self.assertEqual(set(cands), {1, 3, 5})  # root children h, s plus r
        self.assertEqual(bt.candidates(ROOT), [(1, 1), (3, 3)])

    def test_synthetic_shard_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "train" / "call.a1.0.safetensors"
            bt, phrases = synthetic_shard(p, seed=4, utterances=3)
            sh = Shard(p)
            # Identity comes from the metadata, not the file name.
            self.assertEqual((sh.dataset, sh.call, sh.sample, sh.call_id),
                             ("spgispeech", "spgispeech/synthcall", 0, "spgispeech/synthcall"))
            self.assertEqual(sh.nodes, bt.states())
            a = sh.arrays()
            check_candidates_against_tree(self, a)
            tf = trie_features(a["trie.token"], a["trie.parent"], a["trie.nf"][:, 1] > 0.5)
            np.testing.assert_array_equal(tf["nf"], a["trie.nf"])
            sd = sh.load()
            self.assertEqual(sd.decisions(), sh.decisions)
            idx = np.array([0, 3, 1])
            cd, ct, cdst = sd.batch_candidates(idx)
            for j, i in enumerate(idx):
                got = list(zip(ct[cd == j].tolist(), cdst[cd == j].tolist()))
                self.assertEqual(got, bt.candidates(int(a["dec.state"][i])))
            z = sd.z(torch.as_tensor(idx))
            u, t, k = (int(a[n][3]) for n in ("dec.utt", "dec.t", "dec.u"))
            f = a["enc"][a["utt.frame_offset"][u] + t]
            g = a["pred"][a["utt.pred_offset"][u] + k]
            np.testing.assert_array_equal(z[1].numpy(), np.maximum(f + g, 0))

    def test_g_size_must_match_entries(self):
        from safetensors.numpy import save_file

        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c.0.safetensors"
            synthetic_shard(p, seed=1)
            sh = Shard(p)
            a = sh.arrays()
            save_file(a, str(p), metadata=dict(sh.meta, entries="999"))
            with self.assertRaises(ValueError):
                Shard(p).load()

    def test_list_shards_index_and_glob(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            for name in ("b.0", "a.1", "a.0"):
                synthetic_shard(d / "train" / f"{name}.safetensors", seed=0, utterances=1)
            self.assertEqual([p.name for p in list_shards(d, "train")],
                             ["a.0.safetensors", "a.1.safetensors", "b.0.safetensors"])
            (d / "index.json").write_text(json.dumps({"splits": {"train": {"shards": ["train/b.0.safetensors"]}}}))
            self.assertEqual([p.name for p in list_shards(d, "train")], ["b.0.safetensors"])

    def test_namespaced_call_ids_from_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "icsi.Bmr001.1.safetensors"
            synthetic_shard(p, session="Bmr001", sample=1, dataset="icsi")
            sh = Shard(p)
            self.assertEqual((sh.call_id, sh.sample), ("icsi/Bmr001", 1))
            p2 = Path(d) / "nometa.0.safetensors"
            synthetic_shard(p2, meta_extra={"call": None, "sample": None, "dataset": None})
            sh2 = Shard(p2)
            self.assertEqual((sh2.call, sh2.sample, sh2.call_id), (None, None, None))


class RustPrepFixtureTests(unittest.TestCase):
    """On R2's lf-bias-prep fixture, once it exists."""

    def test_reader_and_candidates_on_rust_fixture(self):
        paths = prep_fixtures()
        if not paths:
            self.skipTest("no Rust prep fixture yet (set LF_PREP_FIXTURE)")
        for p in paths:
            sh = Shard(p)
            a = sh.arrays()
            check_candidates_against_tree(self, a)
            tf = trie_features(a["trie.token"], a["trie.parent"], a["trie.nf"][:, 1] > 0.5)
            np.testing.assert_allclose(tf["nf"], a["trie.nf"], rtol=1e-6, atol=1e-7)
            np.testing.assert_array_equal(tf["depth"], a["trie.depth"])
            sd = sh.load()
            n = sd.decisions()
            self.assertTrue(np.all(a["dec.state"] < sh.nodes))
            self.assertTrue(np.all((a["dec.label"] >= 0) & (a["dec.label"] <= 1024)))
            self.assertTrue(set(np.unique(a["dec.kind"]).tolist()) <= {0, 1})
            if n:
                sd.z(torch.arange(n))  # every (utt, t, u) indexes inside enc/pred


class SyntheticPhraseTests(unittest.TestCase):
    def test_fixture_phrases_exercise_overrides(self):
        bt = BiasTrie(synthetic_phrases(np.random.default_rng(0)))
        _, offsets, rows = bt.override_table()
        self.assertGreater(len(rows), 0)


if __name__ == "__main__":
    unittest.main()
