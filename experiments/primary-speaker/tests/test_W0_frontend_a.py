"""Contract tests of the front-end evaluator, part 1 (DESIGN.md 14.2 fe-3, fe-5
check 3, fe-10 registration and ledger): the confirmatory registration anchor,
run events and the ledger, stage A (protocol, storage, identity, persistence)
and its fresh-validation loader. Synthetic set and fake front end only."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.harness import fe_registry as R
from lfspk.harness import fe_stage_a as A
from lfspk.harness.frozen import FrozenSet
from lfspk.harness.util import load_audio
from tests import w0_frontend_fixtures as X

SHA = "c0" * 32
SPEC = "tests.w0_frontend_fixtures:make"


class RegistrationTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.repo = X.init_repo(Path(self._tmp.name) / "repo")

    def tearDown(self):
        self._tmp.cleanup()

    def test_placeholder_is_not_a_registration(self):
        self.assertIsNone(R.current_registration(self.repo))

    def test_valid_anchor(self):
        anchor = X.register(self.repo, SHA)
        reg = R.current_registration(self.repo)
        self.assertEqual(reg["sha256"], SHA)
        self.assertEqual(reg["anchor"], anchor)
        self.assertEqual(reg["blob"], X.git(self.repo, "rev-parse", f"{anchor}:{X.RESULTS}").strip())
        # Later unrelated commits (also to the file) keep the same registration.
        (self.repo / X.RESULTS).write_text((self.repo / X.RESULTS).read_text() + "later\n")
        X.git(self.repo, "commit", "-qam", "W5: later note")
        self.assertEqual(R.current_registration(self.repo), reg)

    def test_refusals(self):
        cases = {}
        # valid line without an anchor commit (tag missing)
        cases["no anchor"] = lambda r: X.register(r, SHA, message="W5: record sha")
        # the anchor's diff changes another line of the file too
        cases["other change"] = lambda r: X.register(r, SHA, extra_line="sneaked")
        # the tag names another SHA than the line
        cases["tag mismatch"] = lambda r: X.register(r, SHA, message=f"REGISTER confirmatory-checkpoint R1-s0 {'d1' * 32}")

        def two_anchors(r):
            X.register(r, SHA)
            X.git(r, "commit", "-q", "--allow-empty", "-m", f"note: REGISTER confirmatory-checkpoint R1-s0 {SHA}")
        cases["two anchors"] = two_anchors

        def head_line_changed(r):
            X.register(r, SHA)
            p = r / X.RESULTS
            p.write_text(p.read_text().replace(SHA, "e2" * 32))
            X.git(r, "commit", "-qam", "edit")
        cases["head line differs"] = head_line_changed

        def two_lines(r):
            X.register(r, SHA)
            p = r / X.RESULTS
            p.write_text(p.read_text() + f"    confirmatory-checkpoint: R1-s0 sha256={SHA}\n")
            X.git(r, "commit", "-qam", "dup")
        cases["two valid lines"] = two_lines

        def uncommitted(r):
            X.register(r, SHA)
            p = r / X.RESULTS
            p.write_text(p.read_text() + "draft\n")
        cases["uncommitted edit"] = uncommitted

        def line_removed(r):
            X.register(r, SHA)
            p = r / X.RESULTS
            p.write_text(p.read_text().replace(f"    confirmatory-checkpoint: R1-s0 sha256={SHA}\n", ""))
            X.git(r, "commit", "-qam", "removed")
        cases["anchor but no line"] = line_removed
        for name, make in cases.items():
            with self.subTest(name):
                repo = X.init_repo(Path(self._tmp.name) / name.replace(" ", "_"))
                make(repo)
                with self.assertRaises(R.RegistrationError):
                    R.current_registration(repo)

    def test_inherited_git_environment_is_ignored(self):
        import os

        other = X.init_repo(Path(self._tmp.name) / "other")
        X.register(other, "d1" * 32)
        anchor = X.register(self.repo, SHA)
        saved = {k: os.environ.get(k) for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
        try:
            os.environ["GIT_DIR"] = str(other / ".git")
            os.environ["GIT_WORK_TREE"] = str(other)
            os.environ["GIT_INDEX_FILE"] = str(other / ".git" / "index")
            reg = R.current_registration(self.repo)
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual((reg["sha256"], reg["anchor"]), (SHA, anchor))

    def test_foreign_owned_checkout_is_trusted_per_command(self):
        anchor = X.register(self.repo, SHA)
        orig = R.git_env
        try:
            R.git_env = lambda: {**orig(), "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"}  # git's own simulation of another owner
            import subprocess

            plain = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, env=R.git_env(), capture_output=True, text=True)
            self.assertIn("dubious ownership", plain.stderr)  # without the scoped trust git refuses
            reg = R.current_registration(self.repo)
        finally:
            R.git_env = orig
        self.assertEqual(reg["anchor"], anchor)

    def test_diff_lines_beginning_with_dashes_or_pluses_count(self):
        for extra in ("++ sneaked", "-- sneaked", "+++ b/sneaked"):
            with self.subTest(extra):
                repo = X.init_repo(Path(self._tmp.name) / f"r{abs(hash(extra))}")
                X.register(repo, SHA, extra_line=extra)
                with self.assertRaises(R.RegistrationError):
                    R.current_registration(repo)

    def test_shallow_clone_refused(self):
        X.register(self.repo, SHA)
        X.git(self.repo, "commit", "-q", "--allow-empty", "-m", "later")
        clone = Path(self._tmp.name) / "shallow"
        X.git(Path(self._tmp.name), "clone", "-q", "--depth", "1", f"file://{self.repo}", str(clone))
        with self.assertRaises(R.RegistrationError):
            R.current_registration(clone)

    def test_only_the_exact_placeholder_means_unregistered(self):
        for name, text in (("broken", "    confirmatory-checkpoint: R1-s0 sha256=BROKEN"), ("absent", None)):
            with self.subTest(name):
                repo = X.init_repo(Path(self._tmp.name) / f"p-{name}")
                p = repo / X.RESULTS
                p.write_text(p.read_text().replace(X.PLACEHOLDER + "\n", "" if text is None else text + "\n"))
                X.git(repo, "commit", "-qam", name)
                with self.assertRaises(R.RegistrationError):
                    R.current_registration(repo)

    def test_working_tree_compared_as_bytes(self):
        X.register(self.repo, SHA)
        p = self.repo / X.RESULTS
        p.write_bytes(p.read_bytes().replace(b"\n", b"\r\n"))
        with self.assertRaises(R.RegistrationError):
            R.current_registration(self.repo)

    def test_run_event_and_ledger(self):
        ev = R.run_event(self.repo)
        self.assertEqual(ev["head"], X.git(self.repo, "rev-parse", "HEAD").strip())
        self.assertTrue(ev["clean"])
        self.assertEqual(len(ev["run_id"]), 32)
        led = Path(self._tmp.name) / "LEDGER.jsonl"
        R.append_ledger(led, {"a": 1})
        R.append_ledger(led, {"b": 2})
        self.assertEqual(R.read_ledger(led), [{"a": 1}, {"b": 2}])
        self.assertEqual(len(R.ledger_sha256(led)), 64)
        self.assertTrue(R.is_ancestor(self.repo, ev["head"], ev["head"]))  # equality counts


OLD, NEW = "c0" * 32, "c1" * 32


class SupersessionTest(unittest.TestCase):
    """A registered checkpoint superseded before any stage-B run of it, then a
    new registration (DESIGN 14.2 fe-10, supersession)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.t = Path(self._tmp.name)
        self.repo = X.init_repo(self.t / "repo")
        self.led = self.t / "LEDGER.jsonl"
        self.old_anchor = X.register(self.repo, OLD)
        # the old checkpoint's two incomplete stage-A starts, as R1-s0 left them
        old_reg = R.current_registration(self.repo, self.led)
        for _ in range(2):
            R.append_ledger(self.led, {"event": "start", "stage": "A", "set_id": "dev-v1", "checkpoint_sha256": OLD,
                                       "registration": old_reg, **R.run_event(self.repo)})

    def tearDown(self):
        self._tmp.cleanup()

    def test_supersede_then_register(self):
        sup = X.supersede(self.repo, OLD)
        self.assertIsNone(R.current_registration(self.repo, self.led))  # between the two commits: unregistered
        new_anchor = X.register(self.repo, NEW)
        reg = R.current_registration(self.repo, self.led)
        self.assertEqual((reg["sha256"], reg["anchor"]), (NEW, new_anchor))
        self.assertEqual(reg["superseded"], [{"sha256": OLD, "register": self.old_anchor, "supersede": sup}])
        # later unrelated commits keep it
        (self.repo / X.RESULTS).write_text((self.repo / X.RESULTS).read_text() + "later\n")
        X.git(self.repo, "commit", "-qam", "W5: a later note")
        self.assertEqual(R.current_registration(self.repo, self.led), reg)

    def test_no_supersession_keeps_the_old_identity_shape(self):
        reg = R.current_registration(self.repo, self.led)
        self.assertEqual(sorted(reg), ["anchor", "blob", "sha256"])

    def test_refused_after_any_stage_b_event_of_the_old_checkpoint(self):
        for ev in ("start", "complete"):
            with self.subTest(ev):
                led = self.t / f"L-{ev}.jsonl"
                led.write_text(self.led.read_text())
                R.append_ledger(led, {"event": ev, "stage": "B", "set_id": "dev-v1", "checkpoint_sha256": OLD})
                repo = X.init_repo(self.t / f"r-{ev}")
                X.register(repo, OLD)
                X.supersede(repo, OLD)
                with self.assertRaisesRegex(R.RegistrationError, "stage-B"):
                    R.current_registration(repo, led)

    def test_malformed_chains_refused(self):
        cases = {
            "wrong old sha in tag": lambda r: X.supersede(r, OLD, message=f"SUPERSEDE confirmatory-checkpoint R1-s0 {'d2' * 32}"),
            "other change": lambda r: X.supersede(r, OLD, extra_line="sneaked"),
            "valid line kept": lambda r: X.supersede(r, OLD, keep_line=True),
            "re-register the old sha": lambda r: (X.supersede(r, OLD), X.register(r, OLD)),
            "two supersedes": lambda r: (X.supersede(r, OLD), X.git(r, "commit", "-q", "--allow-empty", "-m",
                                                                    f"SUPERSEDE confirmatory-checkpoint R1-s0 {OLD}")),
            "register without supersede": lambda r: X.git(r, "commit", "-q", "--allow-empty", "-m",
                                                          f"REGISTER confirmatory-checkpoint R1-s0 {NEW}"),
        }

        def superseded_line_removed(r):
            X.supersede(r, OLD)
            X.register(r, NEW)
            p = r / X.RESULTS
            p.write_text(p.read_text().replace(f"    superseded-checkpoint: R1-s0 sha256={OLD}\n", ""))
            X.git(r, "commit", "-qam", "edit")
        cases["superseded line removed later"] = superseded_line_removed
        for name, make in cases.items():
            with self.subTest(name):
                repo = X.init_repo(self.t / name.replace(" ", "_"))
                X.register(repo, OLD)
                make(repo)
                with self.assertRaises(R.RegistrationError):
                    R.current_registration(repo, self.led)

    def test_old_is_exploratory_only_and_never_blocks_the_new(self):
        from lfspk.harness import frontend_eval as FE

        X.supersede(self.repo, OLD)
        X.register(self.repo, NEW)
        reg = R.current_registration(self.repo, self.led)
        R.append_ledger(self.led, {"event": "start", "stage": "A", "set_id": "dev-v1", "checkpoint_sha256": NEW, "registration": reg,
                                   **R.run_event(self.repo)})
        art = {"registration": reg, "confirmatory_eligible": True, "exploratory": False}
        new_fe = {"run": "R1", "seed": 0, "checkpoint_sha256": NEW}
        ev = FE.confirmatory_evidence(new_fe, [("stage A", art)], self.repo, self.led)
        self.assertTrue(ev["confirmatory"], ev["reasons"])  # the old checkpoint's ledger runs do not count
        old_fe = {"run": "R1", "seed": 0, "checkpoint_sha256": OLD}
        self.assertFalse(FE.confirmatory_evidence(old_fe, [("stage A", art)], self.repo, self.led)["confirmatory"])
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        key = A.make_key(fs, "x", {}, old_fe, A.HEADLINE, reg, False, False)
        self.assertFalse(key["confirmatory_eligible"])


class SupersessionReview1Test(SupersessionTest):
    """sol lfspk-W0F-supersede-r1: each test fails on r1 and passes on r2."""

    test_supersede_then_register = None  # inherited fixtures only
    test_no_supersession_keeps_the_old_identity_shape = None
    test_refused_after_any_stage_b_event_of_the_old_checkpoint = None
    test_malformed_chains_refused = None
    test_old_is_exploratory_only_and_never_blocks_the_new = None

    def _b(self, led, event, head, run_id):
        R.append_ledger(led, {"event": event, "stage": "B", "set_id": "dev-v1", "checkpoint_sha256": OLD, "run_id": run_id,
                              **({"head": head} if head else {})})

    def test_veto_only_for_runs_that_began_before_the_supersession(self):
        pre = X.git(self.repo, "rev-parse", "HEAD").strip()
        X.supersede(self.repo, OLD)
        X.register(self.repo, NEW)
        post = X.git(self.repo, "rev-parse", "HEAD").strip()
        led = self.t / "L-post.jsonl"
        led.write_text(self.led.read_text())
        self._b(led, "start", post, "x1")  # an exploratory stage B of the superseded checkpoint, after the supersession
        self._b(led, "complete", None, "x1")
        self.assertEqual(R.current_registration(self.repo, led)["sha256"], NEW)
        for name, events in (("start before", [("start", pre, "y1")]),
                             ("complete paired with a start before", [("start", pre, "y2"), ("complete", None, "y2")]),
                             ("complete without its start", [("complete", None, "y3")]),
                             ("start without a head", [("start", None, "y4")])):
            with self.subTest(name):
                l2 = self.t / f"L-{name.replace(' ', '_')}.jsonl"
                l2.write_text(led.read_text())
                for ev in events:
                    self._b(l2, *ev)
                with self.assertRaisesRegex(R.RegistrationError, "stage-B"):
                    R.current_registration(self.repo, l2)

    def test_register_post_image_must_hold_one_valid_line(self):
        repo = X.init_repo(self.t / "dup")
        p = repo / X.RESULTS
        p.write_text(p.read_text() + f"    confirmatory-checkpoint: R1-s0 sha256={NEW}\n")
        X.git(repo, "commit", "-qam", "an earlier stray valid line")
        X.register(repo, NEW)  # post-image: two valid lines
        p.write_text("".join(p.read_text().splitlines(True)[:-1]))  # the stray line is the file's last
        X.git(repo, "commit", "-qam", "remove one")
        self.assertEqual(len([l for l in p.read_text().splitlines() if l.startswith("    confirmatory-checkpoint:")]), 1)
        with self.assertRaises(R.RegistrationError):
            R.current_registration(repo, self.led)

    def test_stage_a_uses_the_given_ledger(self):
        pre = X.git(self.repo, "rev-parse", "HEAD").strip()
        X.supersede(self.repo, OLD)
        X.register(self.repo, NEW)
        led = self.t / "L-veto.jsonl"
        led.write_text(self.led.read_text())
        self._b(led, "start", pre, "z1")  # this ledger vetoes the supersession; the default one does not
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        with self.assertRaises(SystemExit):
            A.run_stage_a(fs, "tests.w0_frontend_fixtures:make", {"sha": NEW}, A.HEADLINE, workers=1, root=self.t / "m",
                          exploratory=False, repo=self.repo, ledger=led)
        A.run_stage_a(fs, "tests.w0_frontend_fixtures:make", {"sha": NEW}, A.HEADLINE, workers=1, root=self.t / "m",
                      exploratory=False, repo=self.repo, ledger=self.led)
        with self.assertRaises(SystemExit):
            A.load_stage_a(fs, "tests.w0_frontend_fixtures:make", {"sha": NEW}, A.HEADLINE, root=self.t / "m", repo=self.repo, ledger=led)
        A.load_stage_a(fs, "tests.w0_frontend_fixtures:make", {"sha": NEW}, A.HEADLINE, root=self.t / "m", repo=self.repo, ledger=self.led)

    def test_malformed_keyword_lines_rejected(self):
        for name, line in (("malformed superseded", "    superseded-checkpoint: R1-s0 sha256=BROKEN"),
                           ("unexpected superseded", f"    superseded-checkpoint: R1-s0 sha256={'d3' * 32}"),
                           ("odd indentation", f"  superseded-checkpoint: R1-s0 sha256={OLD}")):
            with self.subTest(name):
                repo = X.init_repo(self.t / name.replace(" ", "_"))
                X.register(repo, OLD)
                X.supersede(repo, OLD)
                p = repo / X.RESULTS
                p.write_text(p.read_text() + line + "\n")
                X.git(repo, "commit", "-qam", "a stray keyword line")
                with self.assertRaises(R.RegistrationError):
                    R.current_registration(repo, self.led)


class StageATest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        t = Path(self._tmp.name)
        self.set_root = X.build_set(t / "set")
        self.fs = FrozenSet("fake-set", root=self.set_root)
        self.root = t / "masks"
        self.repo = X.init_repo(t / "repo")
        self.led = t / "LEDGER.jsonl"

    def tearDown(self):
        self._tmp.cleanup()

    def run_a(self, cond=A.HEADLINE, kwargs=None, exploratory=True, **kw):
        return A.run_stage_a(self.fs, SPEC, kwargs or {}, cond, workers=2, root=self.root, exploratory=exploratory,
                             repo=self.repo, ledger=self.led, **kw)

    def load(self, cond=A.HEADLINE, kwargs=None, exploratory=True):
        return A.load_stage_a(self.fs, SPEC, kwargs or {}, cond, root=self.root, exploratory=exploratory, repo=self.repo)

    def test_headline_protocol_and_storage(self):
        d = self.run_a()
        self.assertEqual(d, self.root / ("ab" * 6) / "fake-set" / "builtin-clean-10")
        st = self.load()
        self.assertEqual(sorted(st.hashes), A.expected_mixtures(self.fs, A.HEADLINE))
        fe = X.make()
        for mid in st.hashes:
            row = next(r for r in self.fs.manifest if r["id"] == mid)
            stream = self.fs.enrollment_stream(row["speaker"], "builtin", False)
            prof = fe.enroll([self.fs.audio(r["file"]) for r in stream[:3]])
            for r in stream[3:10]:
                prof = fe.update(prof, self.fs.audio(r["file"]))
            want = fe.analyse(prof, load_audio(self.fs.root / row["files"]["mix"]))
            got = A.read_mask(st, mid)
            np.testing.assert_array_equal(got.log_mask, want.log_mask.astype(np.float16))
            self.assertEqual(got.log_mask.dtype, np.float16)
            np.testing.assert_array_equal(got.u, want.u)
            self.assertEqual(st.hashes[mid], A.array_sha256(got.log_mask, got.u))
        self.assertTrue(st.key["exploratory"])
        self.assertIsNone(st.key["registration"])
        self.assertFalse(st.key["confirmatory_eligible"])
        self.assertEqual(st.key["torch_threads"], 1)
        led = R.read_ledger(self.led)
        self.assertEqual([e["event"] for e in led], ["start", "complete"])
        self.assertEqual(led[0]["stage"], "A")
        self.assertEqual(led[0]["checkpoint_sha256"], "ab" * 32)
        self.assertEqual(led[0]["run_id"], led[1]["run_id"])

    def test_contaminated_and_short_conditions(self):
        self.run_a(("builtin", True, 3))
        st = self.load(("builtin", True, 3))
        self.assertEqual(len(st.hashes), 4)
        self.assertEqual(A.expected_mixtures(self.fs, ("builtin", False, 30)), [])  # streams of 10 never reach 30

    def test_mixture_loader_is_bs(self):
        row = self.fs.manifest[0]
        np.testing.assert_array_equal(load_audio(self.fs.root / row["files"]["mix"]), self.fs.audio(row["files"]["mix"]))

    def test_dir_claiming(self):
        self.run_a()
        with self.assertRaises(SystemExit):  # another configuration's directory
            self.run_a(kwargs={"gain": "2.0"}, _sha_dir="ab" * 6)
        d = self.root / "x" / "fake-set" / "builtin-clean-10" / "masks"
        d.mkdir(parents=True)
        np.savez(d / "S0-11-00.npz", log_mask=np.zeros(1))
        with self.assertRaises(SystemExit):  # arrays without an identity
            self.run_a(_sha_dir="x")

    def test_fresh_validation_refusals(self):
        self.run_a()
        self.load()
        with self.assertRaises(SystemExit):  # another configuration expected now
            self.load(kwargs={"gain": "2.0"})
        d = A.stage_dir(self.root, "ab" * 6, "fake-set", A.HEADLINE)
        c = json.loads((d / "COMPLETE.json").read_text())
        bad = dict(c, arrays={k: v for i, (k, v) in enumerate(c["arrays"].items()) if i})
        (d / "COMPLETE.json").write_text(json.dumps(bad))
        with self.assertRaises(SystemExit):  # missing coverage key
            self.load()
        (d / "COMPLETE.json").unlink()
        with self.assertRaises(SystemExit):  # not complete
            self.load()

    def test_self_consistent_cache_at_two_threads_refused(self):
        # A cache that is consistent in itself but was made at 2 threads (by older
        # code, say): the loader validates against the current expectation.
        from lfspk.extract.cachepin import identity_hash

        self.run_a()
        d = A.stage_dir(self.root, "ab" * 6, "fake-set", A.HEADLINE)
        ident = json.loads((d / "IDENTITY.json").read_text())
        ident["key"]["torch_threads"] = 2
        ident["key_sha256"] = identity_hash(ident["key"])
        (d / "IDENTITY.json").write_text(json.dumps(ident))
        c = json.loads((d / "COMPLETE.json").read_text())
        (d / "COMPLETE.json").write_text(json.dumps({**c, "key_sha256": ident["key_sha256"], "observed_threads": [2]}))
        with self.assertRaises(SystemExit):
            self.load()

    def test_front_end_must_declare_one_thread(self):
        with self.assertRaises(SystemExit):
            self.run_a(kwargs={"threads": "2"})
        with self.assertRaises(SystemExit):  # no declaration at all
            self.run_a(kwargs={"declare_threads": "0"})

    def test_observed_threads_refused_before_complete(self):
        with self.assertRaises(SystemExit):
            self.run_a(kwargs={"set_threads": "2"})
        d = A.stage_dir(self.root, "ab" * 6, "fake-set", A.HEADLINE)
        self.assertFalse((d / "COMPLETE.json").exists())

    def test_interrupted_run_leaves_a_start_event(self):
        with self.assertRaises(SystemExit):
            self.run_a(kwargs={"set_threads": "2"})
        led = R.read_ledger(self.led)
        self.assertEqual([e["event"] for e in led], ["start"])

    def test_lock_excludes_concurrent_writers(self):
        import fcntl

        base = self.root / ("ab" * 6) / "fake-set"
        base.mkdir(parents=True)
        with open(base / ".stage_a.lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            with self.assertRaises(SystemExit):
                self.run_a(("builtin", False, 3))
        self.run_a(("builtin", False, 3))
        st = self.load(("builtin", False, 3))
        with open(base / ".stage_a.lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            with self.assertRaises(SystemExit):
                A.purge_arrays(st)

    def test_failed_regeneration_cleans_up_and_live_arrays_count(self):
        cond = ("builtin", False, 3)
        self.run_a(cond)
        st = self.load(cond)
        A.purge_arrays(st)
        c = json.loads((st.dir / "COMPLETE.json").read_text())
        c["arrays"][next(iter(c["arrays"]))]["sha256"] = "0" * 64
        (st.dir / "COMPLETE.json").write_text(json.dumps(c))
        with self.assertRaises(SystemExit):
            self.run_a(cond)
        self.assertEqual(list((st.dir / "masks").glob("*.npz")), [])  # nothing hidden behind PURGED.json
        # Arrays left behind a PURGED marker still count as live and block another condition.
        np.savez(st.dir / "masks" / "S0-11-00.npz", log_mask=np.zeros(1))
        with self.assertRaises(SystemExit):
            self.run_a(("headset", False, 3))
        with self.assertRaises(SystemExit):  # and the loader refuses the inconsistent directory
            self.load(cond)

    def test_registration_gate(self):
        with self.assertRaises(SystemExit):  # dev set, no registration, not exploratory
            self.run_a(exploratory=False)
        X.register(self.repo, "ab" * 32)
        self.run_a(exploratory=False)
        st = self.load(exploratory=False)
        self.assertTrue(st.key["confirmatory_eligible"])
        self.assertEqual(st.key["registration"]["sha256"], "ab" * 32)
        self.assertFalse(st.key["exploratory"])
        led = R.read_ledger(self.led)
        self.assertEqual(led[-2]["registration"]["anchor"], st.key["registration"]["anchor"])
        self.assertEqual(led[-2]["run_id"], st.run["run_id"])
        self.assertEqual(led[-1], {"event": "complete", "stage": "A", "run_id": st.run["run_id"], "key_sha256": st.key_sha256,
                                   "checkpoint_sha256": "ab" * 32, "set_id": "fake-set"})

    def test_not_eligible_unless_registered_r1_s0(self):
        X.register(self.repo, "ab" * 32)
        for kwargs in ({"seed": "1"}, {"run": "R2"}, {"sha": "99" * 32}):
            with self.subTest(**kwargs):
                self.run_a(kwargs=kwargs, exploratory=False)
                sha12 = kwargs.get("sha", "ab" * 32)[:12]
                st = A.load_stage_a(self.fs, SPEC, kwargs, A.HEADLINE, root=self.root, exploratory=False, repo=self.repo)
                self.assertFalse(st.key["confirmatory_eligible"])
                self.assertEqual(st.dir.parent.parent.name, sha12)
                shutil.rmtree(st.dir)

    def test_sealed_split_refused_without_orchestrator_flag(self):
        t = Path(self._tmp.name)
        fs = FrozenSet("fake-test", root=X.build_set(t / "test-set", split="test"))
        with self.assertRaises(SystemExit):
            A.run_stage_a(fs, SPEC, {}, A.HEADLINE, workers=1, root=self.root, exploratory=True, repo=self.repo, ledger=self.led)
        A.run_stage_a(fs, SPEC, {}, A.HEADLINE, workers=1, root=self.root, exploratory=True, repo=self.repo, ledger=self.led,
                      sealed_apply=True)
        # A malformed registration is never silently treated as none (code1-r1 #8).
        p = self.repo / X.RESULTS
        p.write_text(p.read_text().replace(X.PLACEHOLDER, "    confirmatory-checkpoint: R1-s0 sha256=BROKEN"))
        X.git(self.repo, "commit", "-qam", "broken")
        with self.assertRaises(SystemExit):
            A.run_stage_a(fs, SPEC, {}, A.HEADLINE, workers=1, root=self.root / "x", exploratory=True, repo=self.repo,
                          ledger=self.led, sealed_apply=True)

    def test_one_non_headline_condition_at_a_time_and_purge(self):
        self.run_a(("builtin", False, 3))
        with self.assertRaises(SystemExit):
            self.run_a(("headset", False, 3))
        self.run_a(A.HEADLINE)  # the headline is always allowed
        st = self.load(("builtin", False, 3))
        with self.assertRaises(SystemExit):
            A.purge_arrays(self.load())  # the headline is never purged
        A.purge_arrays(st)
        self.assertFalse(any((st.dir / "masks").glob("*.npz")))
        st2 = self.load(("builtin", False, 3))  # still loads: identity and hashes kept
        self.assertTrue(st2.purged)
        self.assertEqual(st2.hashes, st.hashes)
        with self.assertRaises(SystemExit):
            A.read_mask(st2, next(iter(st2.hashes)))
        self.run_a(("headset", False, 3))  # now allowed
        # Regeneration reproduces every recorded hash, else it is refused.
        A.purge_arrays(self.load(("headset", False, 3)))
        self.run_a(("builtin", False, 3))
        self.assertFalse(self.load(("builtin", False, 3)).purged)
        A.purge_arrays(self.load(("builtin", False, 3)))
        c = json.loads((st.dir / "COMPLETE.json").read_text())
        k0 = next(iter(c["arrays"]))
        c["arrays"][k0]["sha256"] = "0" * 64
        (st.dir / "COMPLETE.json").write_text(json.dumps(c))
        with self.assertRaises(SystemExit):
            self.run_a(("builtin", False, 3))

    def test_stage_a_code_hash_in_key(self):
        self.run_a()
        st = self.load()
        self.assertEqual(st.key["stage_a_code_sha256"], A.code_sha256())
        self.assertEqual(len(st.key_sha256), 64)


class ProtocolParityTest(unittest.TestCase):
    """Stage A must feed `analyse` exactly what evaluate._score_speaker feeds
    `score`: the same dictations in the same order for every condition, and the
    same mixture samples (code1-r1 #9), across all 12 conditions, including
    contaminated, mismatched-device and short streams."""

    def test_inputs_equal_score_speaker(self):
        from lfspk.harness import evaluate as E

        with tempfile.TemporaryDirectory(dir="/tmp") as t:
            t = Path(t)
            fs = FrozenSet("fake-set", root=X.build_set(t / "set"))
            repo = X.init_repo(t / "repo")
            log_a, log_s = t / "a.jsonl", t / "s.jsonl"
            spec = "tests.w0_frontend_fixtures:make_recording"
            n_keys = 0
            for device in ("builtin", "headset"):
                for contaminated in (False, True):
                    for k in (3, 10, 30):
                        cond = (device, contaminated, k)
                        mids = A.expected_mixtures(fs, cond)
                        n_keys += len(mids)
                        if mids:
                            A.run_stage_a(fs, spec, {"log": str(log_a)}, cond, workers=2, root=t / "m", exploratory=True,
                                          repo=repo, ledger=t / "L.jsonl")
                            if cond != A.HEADLINE:  # one non-headline condition at a time
                                A.purge_arrays(A.load_stage_a(fs, spec, {"log": str(log_a)}, cond, root=t / "m", repo=repo))
            self.assertEqual(n_keys, len(E.expected_score_keys(fs, fs.manifest)))
            orig = (E.FrozenSet, E._SCORER)
            try:
                E.FrozenSet = lambda set_id: fs
                E._SCORER = X.RecordingScorer(str(log_s))
                (t / "o" / "scores").mkdir(parents=True)
                for spk in X.SPEAKERS:
                    ids = [r["id"] for r in fs.manifest if r["speaker"] == spk]
                    E._score_speaker(("fake-set", "unused", {}, spk, ids, str(t / "o")))
            finally:
                E.FrozenSet, E._SCORER = orig
            rd = lambda p: {json.dumps(json.loads(l), sort_keys=True) for l in p.read_text().splitlines()}
            a, sc = rd(log_a), rd(log_s)
            self.assertEqual(a, sc)
            # Stage A analysed exactly the expected (condition, mixture) keys, once each;
            # profiles are built from k = 3 or 10 dictations (streams of 10 never reach 30,
            # and the short headset stream of 7 only reaches 3).
            self.assertEqual(len(log_a.read_text().splitlines()), n_keys)
            self.assertEqual({len(json.loads(x)["profile"]) for x in a}, {3, 10})
            self.assertEqual(n_keys, 4 * 4 + 2 * 4 + 2 * 2)  # builtin: 4 conditions x 4 mixtures; headset k=3: 2 x 4; k=10: speaker 11 only, 2 x 2


if __name__ == "__main__":
    unittest.main()
