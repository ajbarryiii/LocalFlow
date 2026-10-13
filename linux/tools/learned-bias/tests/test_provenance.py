import contextlib
import hashlib
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from safetensors import safe_open
from safetensors.numpy import save_file

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias.fixtures import synthetic_shard, write_index
from learned_bias.provenance import (
    RARE_RULE,
    ExportIdentity,
    ProvenanceError,
    production_policy_problems,
    shard_policy,
    validate_training_shards,
)

from tests.helpers import REPO_FIXTURES, SPGI_DEV, SPGI_TRAIN, fake_eval, make_prep, real_export, real_root


def read_meta(path):
    with safe_open(str(path), framework="np") as f:
        return dict(f.metadata())


def rewrite_meta(path, **changes):
    """Rewrite a shard with metadata fields changed (None removes)."""
    with safe_open(str(path), framework="np") as f:
        meta = dict(f.metadata())
        t = {k: f.get_tensor(k) for k in f.keys()}
    meta.update(changes)
    save_file(t, str(path), metadata={k: v for k, v in meta.items() if v is not None})


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.export, self.prep, self.ident = make_prep(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def refuses(self, needle, reindex=False):
        if reindex:
            write_index(self.prep)
        with self.assertRaises(ProvenanceError) as cm:
            validate_training_shards(self.prep, self.export)
        self.assertTrue(any(needle in p for p in cm.exception.problems),
                        f"no problem mentions {needle!r}: {cm.exception.problems}")

    def shard(self, ds="icsi", sess="S000", sample=0):
        return self.prep / "train" / f"{ds}.{sess}.{sample}.safetensors"

    @staticmethod
    def names(ds):
        return SPGI_TRAIN[:2] if ds == "spgispeech" else ["S000", "S001"]

    def replace(self, ds="icsi", sess="S000", sample=0, **kw):
        """Rewrite one train shard with different arguments, then reindex."""
        args = dict(dataset=ds, session=sess, sample=sample, split_session_ids=self.names(ds), identity=self.ident,
                    utterances=3)
        args.update(kw)
        synthetic_shard(self.shard(ds, sess, sample), **args)
        write_index(self.prep)

    # -- the valid tree

    def test_valid_tree_passes_and_ids_come_from_metadata(self):
        shards = validate_training_shards(self.prep, self.export)
        self.assertEqual(len(shards), 12)
        self.assertEqual({s.dataset for s in shards}, {"spgispeech", "slidespeech", "icsi"})
        s = next(s for s in shards if s.dataset == "icsi")
        self.assertEqual((s.call, s.sample, s.call_id), ("icsi/S000", 0, "icsi/S000"))

    # -- split, dataset, identity

    def test_split_must_be_train(self):
        self.replace(split="dev")
        self.refuses("is not 'train'")

    def test_dataset_must_be_in_training_mix(self):
        self.replace(ds="acl6060", sess="T1")
        self.refuses("not in the training mix")

    def test_every_mix_dataset_needs_train_shards(self):
        shutil.rmtree(self.prep)
        make_prep(self.root / "two", datasets=("spgispeech", "icsi"))
        with self.assertRaises(ProvenanceError) as cm:
            validate_training_shards(self.root / "two" / "prep", self.root / "two" / "export")
        self.assertTrue(any("'slidespeech' of the training mix" in p for p in cm.exception.problems))

    def test_export_and_cache_identity_must_match(self):
        self.replace(policy_extra={"export_sha256": "0" * 64})
        self.refuses("export_sha256 '000")
        self.replace(policy_extra={"cache_identity": "1" * 64})
        self.refuses("cache_identity '111")

    def test_export_weights_must_match_their_manifest(self):
        w = self.export / "export.safetensors"
        w.write_bytes(w.read_bytes()[:-1] + b" ")
        with self.assertRaises(ProvenanceError):
            ExportIdentity(self.export)

    # -- the bundled policy

    def test_policy_string_must_hash_to_policy_sha256(self):
        rewrite_meta(self.shard(), policy_sha256="f" * 64)
        self.refuses("does not hash its policy string", reindex=True)

    def test_metadata_must_agree_with_its_policy(self):
        rewrite_meta(self.shard(), rare_rule="{}")
        self.refuses("metadata rare_rule='{}' disagrees with its policy")
        rewrite_meta(self.shard(), rare_rule=None)
        self.refuses("metadata lacks policy field 'rare_rule'")

    def test_policy_must_have_exactly_the_production_keys(self):
        m = read_meta(self.shard())
        pol = json.loads(m["policy"])
        del pol["graph"]
        s = json.dumps(pol, sort_keys=True, separators=(",", ":"))
        rewrite_meta(self.shard(), policy=s, policy_sha256=hashlib.sha256(s.encode()).hexdigest())
        self.refuses("policy keys", reindex=True)

    def test_one_policy_per_dataset(self):
        self.replace(policy_extra={"df_source_sha256": "e" * 64})
        self.refuses("policy_sha256 differs")

    def test_policy_values(self):
        cases = {
            "seed '7'": {"seed": "7"},
            "not the frozen rule": {"rare_rule": dict(RARE_RULE, max_df_percent=10)},
            "df_source is not the train split": {"df_source": {"manifests": [{"path": "/x", "sha256": "a" * 64}],
                                                               "split": "dev", "sessions": 40, "max_df": 2}},
            "split_rule": {"split_rule": "spgi call hash (exp2_data::spgi_is_dev)"},
            "casing": {"casing": "mixed"},
            "targets_mode": {"targets_mode": "words"},
        }
        for needle, extra in cases.items():
            self.replace(policy_extra=extra)
            self.refuses(needle)

    def test_casing_is_frozen_per_dataset_and_mixed_is_rejected(self):
        # The valid tree has slidespeech uncased, spgispeech and icsi cased.
        pols = {s.dataset: json.loads(s.meta["policy"])["casing"]
                for s in validate_training_shards(self.prep, self.export)}
        self.assertEqual(pols, {"spgispeech": "cased", "slidespeech": "uncased", "icsi": "cased"})
        self.replace(policy_extra={"casing": "mixed"})
        self.refuses("mixed is rejected")
        self.replace(policy_extra={"casing": "uncased"})
        self.refuses("icsi train is frozen as 'cased'")
        self.replace(ds="slidespeech", policy_extra={"casing": "cased"})
        self.refuses("slidespeech train is frozen as 'uncased'")

    def test_manifest_sha256_is_one_opaque_hash_per_dataset(self):
        # Any 64-hex value (one file's hash or the hash of several), the same
        # on every train shard of the dataset.
        for sess in self.names("icsi"):
            for s in (0, 1):
                self.replace(sess=sess, sample=s, policy_extra={"manifest_sha256": "7" * 64})
        validate_training_shards(self.prep, self.export)
        self.replace(policy_extra={"manifest_sha256": "8" * 64})
        self.refuses("manifest_sha256 differs across shards")
        self.replace(policy_extra={"manifest_sha256": "7" * 63})
        self.refuses("is not a sha256")

    def test_spgi_dev_session_cannot_train(self):
        os.remove(self.shard("spgispeech", SPGI_TRAIN[0], 0))
        synthetic_shard(self.prep / "train" / "spgi-dev.safetensors", dataset="spgispeech", session=SPGI_DEV[1],
                        sample=0, split_session_ids=self.names("spgispeech"), identity=self.ident)
        self.refuses("is a dev call by the split hash", reindex=True)

    def test_call_is_dataset_slash_session(self):
        rewrite_meta(self.shard(), call="S000")
        self.refuses("!= dataset/session", reindex=True)

    def test_supported_policy_only(self):
        cases = {
            "only cancel_unfinished=false": {"graph": {"case_variants": True, "cancel_unfinished": True}},
            "only case_variants=true": {"graph": {"case_variants": False, "cancel_unfinished": False}},
            "case_variants='<missing>'": {"graph": {"cancel_unfinished": False}},
            "unsupported settings ['depth_scaling']": {"graph": {"case_variants": True, "cancel_unfinished": False,
                                                                 "depth_scaling": 1}},
            "is not a JSON object": {"graph": "case_variants=true cancel_unfinished=false"},
            "sha256 of the common-words file": {"rare_rule": dict(RARE_RULE)},
            "is not the frozen rule": {"rare_rule": dict(RARE_RULE, common_words_file_sha256="c" * 64,
                                                         requires_letter=1)},
            "manifests": {"df_source": {"manifests": [], "split": "train", "sessions": 40, "max_df": 2}},
            "are not [{path, sha256}": {"df_source": {"manifests": [{"path": "/x", "sha256": "nothex"}],
                                                      "split": "train", "sessions": 40, "max_df": 2}},
            "max_df 3 != max(floor(5% of 40), 2)": {"df_source": {"manifests": [{"path": "/x", "sha256": "a" * 64}],
                                                                  "split": "train", "sessions": 40, "max_df": 3}},
            "does not have exactly": {"df_source": {"manifests": [{"path": "/x", "sha256": "a" * 64}],
                                                    "split": "train", "sessions": 40}},
            "df_source_sha256 'none' is not a sha256": {"df_source_sha256": "none"},
            "manifest_sha256 '' is not a sha256": {"manifest_sha256": ""},
        }
        for needle, extra in cases.items():
            self.replace(policy_extra=extra)
            self.refuses(needle)

    def test_keywords_mode_policy(self):
        kw = {"targets_mode": "keywords", "rare_rule": {"rule": "keywords", "keywords_file_sha256": None},
              "df_source": None, "df_source_sha256": "none"}
        for ds in ("icsi",):
            for sess in self.names(ds):
                for s in (0, 1):
                    self.replace(ds=ds, sess=sess, sample=s, policy_extra=kw)
        validate_training_shards(self.prep, self.export)  # supported
        self.replace(policy_extra=dict(kw, df_source_sha256="d" * 64))
        self.refuses("keywords mode with a df_source")

    # -- completeness from the shards' own metadata (re-review #4)

    def test_each_session_needs_every_sample(self):
        # Re-review #4: one sample per session while samples = 2, with an
        # index that claims completeness.
        for sess in self.names("icsi"):
            os.remove(self.shard("icsi", sess, 1))
        idx = write_index(self.prep)
        g = idx["datasets"]["icsi"]["splits"]["train"]
        g.update(expected_shards=2, present_shards=2, complete=True)
        idx["complete"] = True
        (self.prep / "index.json").write_text(json.dumps(idx))
        self.refuses("has samples [0], expected [0, 1]")
        self.refuses("2 shards, expected 4 from the metadata")
        self.refuses("index expected_shards 2")

    def test_sessions_must_be_the_expected_set(self):
        # A session swapped for an unexpected one: the count still matches.
        for s in (0, 1):
            os.remove(self.shard("icsi", "S001", s))
            synthetic_shard(self.prep / "train" / f"icsi.S777.{s}.safetensors", dataset="icsi", session="S777",
                            sample=s, split_session_ids=self.names("icsi"), identity=self.ident)
        self.refuses("do not hash to split_sessions_sha256", reindex=True)
        # A missing session (count and hash both catch it).
        for s in (0, 1):
            os.remove(self.prep / "train" / f"icsi.S777.{s}.safetensors")
        self.refuses("1 sessions present, split_sessions = 2", reindex=True)

    def test_policy_split_sessions_is_required_and_matches_the_sessions(self):
        # Required in the bundled policy (R2 writes it there).
        m = read_meta(self.shard())
        pol = json.loads(m["policy"])
        del pol["split_sessions"]
        s = json.dumps(pol, sort_keys=True, separators=(",", ":"))
        rewrite_meta(self.shard(), policy=s, policy_sha256=hashlib.sha256(s.encode()).hexdigest())
        self.refuses("policy keys", reindex=True)
        # Consistent everywhere but not the sessions actually present.
        for sess in self.names("icsi"):
            for smp in (0, 1):
                self.replace(sess=sess, sample=smp, policy_extra={"split_sessions": 3})
        self.refuses("2 sessions present, split_sessions = 3")
        self.replace(policy_extra={"split_sessions": "2"})
        self.refuses("policy split_sessions '2' is not a positive integer")

    def test_shards_must_agree_on_the_session_set(self):
        self.replace(split_session_ids=["S000", "S001", "S002"])
        self.refuses("shards disagree on (split_sessions, split_sessions_sha256)")

    # -- the index

    def test_index_format_and_completeness(self):
        idx = json.loads((self.prep / "index.json").read_text())
        idx["format"] = "lf-bias-prep-index-v1"
        (self.prep / "index.json").write_text(json.dumps(idx))
        self.refuses("index format")
        os.remove(self.shard(sample=1))
        self.refuses("complete is False", reindex=True)
        self.refuses("3 shards, expected 4 from the metadata")

    def test_index_must_list_exactly_the_files_present(self):
        synthetic_shard(self.prep / "train" / "extra.safetensors", dataset="icsi", session="S009",
                        split_session_ids=self.names("icsi"), identity=self.ident)
        self.refuses("not in the index")
        os.remove(self.prep / "train" / "extra.safetensors")
        os.remove(self.shard(sample=1))
        self.refuses("in the index but missing")

    def test_index_entries_totals_and_policy_must_match(self):
        idx = json.loads((self.prep / "index.json").read_text())
        idx["splits"]["train"]["shards"][0]["decisions"] += 1
        (self.prep / "index.json").write_text(json.dumps(idx))
        self.refuses("index decisions=")
        idx = write_index(self.prep)
        idx["splits"]["train"]["totals"]["decisions"] += 5
        (self.prep / "index.json").write_text(json.dumps(idx))
        self.refuses("totals.decisions")
        idx = write_index(self.prep)
        idx["datasets"]["icsi"]["splits"]["train"]["policy_sha256"] = "9" * 64
        (self.prep / "index.json").write_text(json.dumps(idx))
        self.refuses("index policy_sha256")
        idx = write_index(self.prep)
        idx["datasets"]["icsi"]["splits"]["train"]["policy"]["seed"] = "1"
        (self.prep / "index.json").write_text(json.dumps(idx))
        self.refuses("index policy object differs")

    def test_a_call_cannot_be_in_two_splits(self):
        synthetic_shard(self.prep / "dev" / "icsi.S000.0.safetensors", dataset="icsi", session="S000",
                        split="dev", samples=1, identity=self.ident)
        self.refuses("also appears in split 'dev'", reindex=True)

    def test_index_is_required(self):
        os.remove(self.prep / "index.json")
        self.refuses("index.json is missing")

    def test_duplicate_call_and_sample(self):
        shutil.copy(self.shard(), self.prep / "train" / "copy.safetensors")
        self.refuses("duplicate (call, sample)", reindex=True)

    # -- training refuses

    def test_training_refuses_before_touching_the_gpu(self):
        from learned_bias import train

        cmd, res = fake_eval(self.root)
        self.replace(split="dev")
        base = ["--variant", "L1", "--run", "r", "--prep", str(self.prep), "--out-root", str(self.root / "train"),
                "--export", str(self.export), "--device", "cuda:0", "--dev-check-results", res,
                "--gpu-lock", str(self.root / "gpu.lock")]
        with self.assertRaises(SystemExit) as cm, contextlib.redirect_stdout(io.StringIO()):
            train.main(base + ["--dev-check-cmd", cmd])
        self.assertIn("provenance problem", str(cm.exception))
        self.assertFalse((self.root / "gpu.lock").exists())  # refused before the lock
        self.assertFalse((self.root / "train" / "r" / "run.json").exists())


class RustShardTests(unittest.TestCase):
    """R2's shards: the repo's synthetic fixture always; real data (the
    regenerated real fixture and the pilot under W) when LF_EXP2_ROOT and
    LF_EXPORT are set."""

    def real(self):
        root, export = real_root(), real_export()
        if not root or not export:
            self.skipTest("set LF_EXP2_ROOT and LF_EXPORT to check real shards")
        return root, export

    def test_r2_synthetic_fixture_policy(self):
        p = REPO_FIXTURES / "prep-shard.safetensors"
        self.assertTrue(p.exists(), p)
        m = read_meta(p)
        pol, problems = shard_policy(m, p.name, full=False)
        self.assertEqual(problems, [])
        self.assertEqual((m["call"], m["dataset"], m["session"]), ("synthetic/fixture", "synthetic", "fixture"))
        self.assertEqual(pol["dataset"], "synthetic")

    def test_real_fixture_policy_and_identity(self):
        root, export = self.real()
        p = root / "fixtures" / "prep-spgi-0018ad92.0.safetensors"
        m = read_meta(p)
        pol, problems = shard_policy(m, p.name, full=True)
        self.assertEqual(problems, [])
        ident = ExportIdentity(export, verify_file=False)
        self.assertEqual(production_policy_problems(pol, m, p.name, ident, "train", ("spgispeech",)), [])

    def test_smoke_prep_of_all_three_datasets(self):
        # R2's multi-dataset smoke run ($LF_SMOKE_PREP, e.g. a few sessions
        # per dataset): refused only for completeness.
        smoke = os.environ.get("LF_SMOKE_PREP")
        if not smoke or not real_export():
            self.skipTest("set LF_SMOKE_PREP and LF_EXPORT to check R2's smoke shards")
        with self.assertRaises(ProvenanceError) as cm:
            validate_training_shards(smoke, real_export())
        problems = cm.exception.problems
        marks = ("complete is False", "expected_shards", "sessions present", "do not hash to", "from the metadata")
        completeness = [p for p in problems if any(k in p for k in marks)]
        self.assertTrue(completeness)
        self.assertEqual([p for p in problems if p not in completeness], [])
        for ds in ("spgispeech", "slidespeech", "icsi"):
            self.assertTrue(any(p.startswith(f"{ds}/train") for p in completeness), ds)

    def test_pilot_prep_passes_provenance(self):
        root, export = self.real()
        # The pilot is 20 SPGISpeech calls of 1010, so it is (correctly)
        # incomplete and must be refused; every other production check must
        # pass on its real shards.
        with self.assertRaises(ProvenanceError) as cm:
            validate_training_shards(root / "pilot" / "prep", export, train_mix=("spgispeech",))
        problems = cm.exception.problems
        marks = ("complete is False", "expected_shards", "sessions present", "do not hash to", "from the metadata")
        completeness = [p for p in problems if any(k in p for k in marks)]
        self.assertTrue(completeness)
        self.assertEqual([p for p in problems if p not in completeness], [])


if __name__ == "__main__":
    unittest.main()
