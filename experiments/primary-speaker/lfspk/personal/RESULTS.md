# W6 per-user fine-tuning pilot: results

Status: DESIGN CLOSED at ef4a148 (orchestrator-verified r2 delta, 2026-10-23). Code stage 1 (data): sol r1 not clean (2 major, 3 minor); fixes and amendment A1 committed, awaiting r2. No render, tuning or Mac job has run.

## Design and review trail

| round | reviewed | high | medium | low | outcome |
|---|---|---|---|---|---|
| r1 | ad6f783 (DESIGN sha256 fdf3ac33...cce8) | 6 major | | 4 minor | M1-M5 and m7-m10 fixed; M6 rebutted (pilot exemption) per the orchestrator's ruling; responses in DESIGN section 13 |
| r2 | ad6f783..fa2a414 | 1 major (M2/X1) | | 3 minor (M1, M3, M4) | all fixed as stated (wording and definitions); responses in DESIGN section 13 |
| r2 verify | fa2a414..ef4a148 (DESIGN sha256 f256a733...ba90) | - | - | - | the orchestrator verified all four fixes, with no scope beyond the findings; **DESIGN CLOSED at ef4a148** |

## Pre-design inspections (read-only, 2026-10-23)

1. Handoff note: runs/W5/notes/handoff_W6.md, sha256 7a1c6f54...4e18,
   verified.
2. Base checkpoints, re-hashed: V0-s0 a3d5a6e0...a942, V0u-s0
   7090b127...549f, VB-s0 72691027...54d5 and VBu-s0 0662ca0c...2e07 all
   match the handoff. VB-s0's run_meta identity records effective alpha 3.0.
3. Screen figures, re-read from runs/W5/notes/screen_gate_table.json:

   | | S1 | S2 | S3 | S4 |
   |---|---|---|---|---|
   | V0 frac | 0.029 | 0.044 | 0.539 | 0.029 |
   | VB frac | 0.312 | 0.439 | 0.810 | 0.386 |

   - VB over-suppression means: S0 0.0069, N 0.0136, S1 0.0169, S2 0.0731,
     S3 0.0640, S4 0.0668. The S0 q99 is 0.107.
   - Gains over the twin, S4: VB 0.049, V0 0.001.
   - Against the bounds, VB's over-suppression is 6.9x on S0 (mean), 7.3x
     on S2, 6.4x on S3, 6.7x on S4, 1.4x on N and 1.7x on S1. The S0 tail is
     10.7x.
   - The handoff's "7-24x" range is **not reproduced** from the gate table:
     the largest ratio found is 10.7x (S0 q99). The design relies only on the
     table values.
4. Held-out speaker partitions, from `librispeech_partitions("train")`, CPU,
   4 s:
   - Partition levels: 15 F and 11 M are cross_project; 9 F and 13 M are
     same_project_cross_chapter.
   - Smallest pools: the cross_project mixture pool (3-20 s) of speaker 119
     has 19 utterances. Speaker 1335 has 38 bank utterances; every other
     speaker has 40.
5. Parameter groups of the M network, counted from VB-s0: stem 49,280,
   blocks 535,552, proj 12,352, films 134,144, cos_u 4,128, cos_v 2,080,
   head_norm 256, mask_head 33,024, aux_head 258. Configuration P adapts
   186,242 of them.
6. Mac synthetic-tensor microbenchmark:
   - Setup: random x of shape [8, 128, 800], an untrained M net, AdamW, W5's
     loss, the median of 4 steps after 2 warm-up steps. No data was read and
     nothing was kept. Code copied to /tmp/w6bench on the Mac: lfspk/api.py,
     lfspk/extract/{api,model,losses}.py and the bench script.
   - Environment: torch 2.5.1, miniforge env orthonet.
   - Time: about 75 s across 4 invocations, slightly over the 1-minute
     inspection allowance. Recorded here so the overrun is visible.

   | QoS | threads | P s/step | F s/step | max RSS |
   |---|---|---|---|---|
   | default | 2 | 0.136 | 0.205 | 618 MB |
   | background | 2 | 0.615 | 0.755 | 419 MB |
   | background | 1 | 1.114 | 1.392 | 446 MB |
   | utility, batch 16 | 2 | 1.952 | 2.077 | 994 MB |

   - The batch-16 utility run was unexpectedly slow and is unexplained. It is
     not used.
   - The Mac's load average was 2.3-2.4 at the time.
7. nixos resources at design time: W1's grid holds w1-d3-06 and w1-d3-07,
   13G memory each. 28.4 GB of the memory lease was free. The GPU had no
   holders.

## Orchestrator rulings on r1 and the open questions (2026-10-23)

- M6: rebut, don't build. The product encryption requirement is written into
  DESIGN section 9, and the pilot is exempt (public corpora, no user data).
- M2: the narrowing is accepted. One optional report-only extra control was
  allowed; I chose none beyond the zero-cost profile swap (DESIGN section 3).
- Copying DEMAND and SLR28 renders to the Mac is allowed.
- The Mac's orthonet env is allowed read-only: torch 2.5.1, numpy 2.0.1,
  Python 3.11.11 (checked 2026-10-23). Never pip-install into it.
- Product tuning audio: LocalFlow's dictation history, encrypted with the
  voiceprint key (AJ's decision).

Licences of the corpora in Mac-copied renders, as W0 recorded them
(lfspk/harness/DESIGN.md section 2; data/PROVENANCE.md):
- LibriSpeech: CC BY 4.0
- MUSAN: CC BY 4.0, with per-file music licences checked by W0 and
  non-commercial files excluded
- DEMAND: CC BY-SA 3.0
- OpenSLR 26/28: Apache 2.0

## Code stage 1: data (render sets, profiles, tuning stream, audit)

Files:
- lfspk/personal/{__init__,subjects,signals,render,profiles,stream,audit}.py
- tests/test_W6_{subjects,stream,render,audit}.py

Unit tests, CPU only, all under `job`:
- w6-unit-s1 (run 20261024T010637Z): 1 failure, test_gain_invariant. The
  channel statistic used the features' log guard of 2^-24, which dominates
  quiet bins: Parakeet's mel power is small (W5 part 1). The guard is now
  1e-20, so the statistic measures acoustics. The test is unchanged.
- w6-unit-s1-int (run 20261024T010703Z): the integration test had a test-side
  path bug (missing ".npz").
- w6-unit-s1-all (run 20261024T010733Z): 35 of 35 OK, including the
  integration test.
  - The integration test renders one unit of each set through the production
    jobs, into a temporary directory that is deleted afterwards: one
    dictation, one bank donor, one paired scoring group and one absent
    render. These are held-out TRAIN speakers; nothing is kept.
  - I disclose it because the stage's production renders wait for review.
- w6-keys-check (run 20261024T010804Z), key counts:
  - dict 878 (21 x 40, plus 38 for speaker 1335);
  - bank 1000, auditref 800, score 2640;
  - every subject has at least 16 scoring utterances;
  - eligible donor targets: 679; eligible absent talkers: 26.

Implementation notes for review:
1. **S3 retention constraint.** As written, the DESIGN's overlap-minimising
   S3 shift is degenerate. The review ruled this a method choice, registered
   as DESIGN amendment A1 (below).
2. **Batches use W5's own prepare_batch on Example objects.** It is not a
   reimplementation, so equality with W5 holds by construction. The DESIGN
   anticipated a reimplementation plus an equality test.
3. **The bank is read through a memory-mapped float16 pack.**
   - Per-donor npz files are written by the render workers. `render pack`
     then joins them into bank16.npy [samples, 4], frames.npy and
     index.json.
   - pack.json records file hashes and the bank render's identity and
     manifest hashes.
   - On nixos, `Bank` validates against the current render identity. The Mac
     passes the pinned sha256 of pack.json instead.
4. **N present: the donor noise power was measured over the samples the
   donor covered.** That departed from the closed design and was fixed in
   r1 (below).
5. **Profiles use one torch thread per worker**, for determinism.

### Stage 1 review trail

| round | reviewed | high | medium | low | outcome |
|---|---|---|---|---|---|
| r1 | ef4a148..a624a3d | 2 major | | 3 minor | all fixed. M1 follows the closed design (N power over the whole window); M2, minor 3 and minor 4 are registered in DESIGN amendment A1 (S3 retention, tie-break on Delta, RNG tags); minor 5 (pinned pack) fixed; responses in DESIGN "Responses to code review rounds" |

The reviewer cleared the following:
- no held-out leakage path;
- the control donor is excluded from the subject's scoring voices;
- the mixture partition is disjoint;
- the speech-only post-placement SIR, the S1 event gain, the absent labels,
  the float16 SIR and the common peak scaling;
- the profiles built through W1's factory;
- the manifest checks against the current identity and the pack pins;
- the spawn pools and the guarded CLIs;
- the reuse of prepare_batch and the 1e-20 log guard.

Tests after the r1 fixes: w6-unit-s1-r2 (run 20261024T011500Z), 37 of 37 OK, including the opt-in integration test (temporary directory, deleted afterwards).

## Code stage 2: tuning, the hash-pinned load path, identity binding, the Mac runner

Files:
- lfspk/personal/tune.py, lfspk/personal/macbench.py
- tests/test_W6_tune.py
- tests/test_W6_render.py: the `_write` fixture gains a donor-length parameter

Unit tests, CPU only:
- w6-unit-s2 (run 20261024T011546Z): 1 error. The synthetic bundle's donors
  were 0.2-0.6 s long, so every present draw was rejected for empty activity.
  This was a fixture problem: the fixture now writes 2-3 s donors.
- w6-unit-s2b (run 20261024T011608Z): tune, render and stream suites, 33 OK
  with 1 opt-in test skipped.

Not run, waiting for this stage's review: the tuning smoke, any GPU job, the
bundle build and any Mac job.

## Code stage 3: scoring, bootstrap, gates, interpretive checks, coverage smoke test

Files:
- lfspk/personal/boot.py, lfspk/personal/score.py, lfspk/personal/gates.py
- tests/test_W6_score.py

Unit tests (CPU):
- w6-unit-s3 (run 20261024T012143Z): **FAILED**, 12 of 13. The failing
  test was test_pass_and_select: G2 and G4a evaluated False.
  - Cause, in the fixture: every synthetic render involved the same
    interferer, "166". Every resample that did not draw "166" (about
    (22/23)^23, or 36 %) therefore had zero total weight. ci() correctly
    marked the CIs unresolved (more than 20 undefined resamples), and
    unresolved CIs fail G2 and G4a.
  - Fix, to the fixture: interferers are spread over 26 ids, and the test
    now also asserts that the G4a CI resolves.
- **Correction, at the orchestrator's request (2026-10-24, 01:44 UTC job
  watch).** The stage-3 report claimed "13 of 13 OK". That rerun was done
  outside `job` (direct ./python), so nothing recorded it. The claim was
  wrong as worded.
  - The recorded rerun is w6-unit-s3b. Run 20261024T014457Z was stopped by
    me while still queued.
  - The current run is 20261024T014732Z. It is queued: another project's job
    (another project, 36G) is first in the memory queue until about
    13:17 UTC, when W1's lanes end.
  - Its outcome is recorded below when it runs.

Parity with W5's frozen screen measurement (DESIGN 6.1), w6-parity-2 (run
20261024T012357Z):
- score.py on W5's monitor set (held-out train, read through
  calibrate.load_set) reproduces screen_gate_table.json for V0-s0 and VB-s0.
  The maximum absolute difference is **0.0** for both, over frac S1-S4, the
  over-suppression means of all six families and the S0 q99. The tolerance
  was 1e-9.
- The first attempt, w6-parity (run 20261024T012207Z), failed only while
  writing JSON (a numpy bool); the values were not affected.
- Output: runs/W6/scores/parity.json.
- I ran this before the stage review because it is a read-only check of
  score.py against a frozen reference.

Not run, waiting for review: the coverage smoke test. Its generator and seed
are frozen in boot.py (COVERAGE_SEED 20261024, 200 replications, generator
parameters in COV) and are first run only after the stage-3 review. The unit
test runs 3 replications with seed 1.

## Stage 1 r2 minors and stage 2 r1 fixes (2026-10-24)

Stage 1, sol lfspk-W6-code1-r2 (a624a3d..fb88d8e): no blockers or majors,
and all five r1 fixes resolved. Two minors, both fixed (DESIGN responses):
- m1: S3 kept/c0 is undefined at c0 = 0; such cases are counted, not
  summarised.
- m2: amendment A1 now states Delta in samples.

Stage 2, sol lfspk-W6-code2-r1 (fb88d8e..405594f): 2 major, 1 minor, all
fixed.
- M1: the `/usr/bin/time -l` parser now matches complete lines only (C
  locale), each field exactly once, and fails closed. The child process runs
  with LC_ALL=C. A decimal-comma report is refused and can never pass the
  budget.
- M2: a bundle-run now preloads every lfspk module it uses. Every loaded
  lfspk.* module must come from <bundle>/code and match bundle.json's
  sha256; this is checked before training and again after it, to cover lazy
  imports. Subprocess tests use an alternate tree with only
  pvad/features.py PREEMPH changed, and a bundle edited after its manifest;
  both are refused.
- m3: a new test checks the frozen parameters of the in-memory trained
  network directly. The reconstruction tests are kept.
- Taildrop transfer (AJ's decision):
  - `macbench tar` makes one tar of the verified bundle and records its
    sha256 and bundle.json's sha256.
  - `mac_receive_command` gives the jobs-mac argv: shasum check, extract
    into ~/localflow-speaker-w6/bundle, `macbench verify` against the
    bundle.json pin (no extra files), then delete the tar from ~/Downloads.
  - A test covers the tar round trip and the order of the receive command's
    steps.

Tests:
- Run directly (outside `job`) as a pre-check: 64 OK, 1 skipped. This is
  not a record.
- The recorded runs are queued behind another project's job's memory reservation:
  w6-unit-s3b (stage 3 suite) and w6-unit-all-r3 (all W6 suites).

### Stage 1 status (orchestrator, 2026-10-24)

- The orchestrator verified the code1-r2 minors (e8f3504..ea13b9d; DESIGN
  sha256 ed432dcf...dd1a).
- **Stage 1 is CLOSED, conditional on the recorded run w6-unit-all-r3
  passing.** It is queued behind the memory reservation.
- Reporting rule from now on: only `job`-recorded runs are reported as
  passes. Direct pre-checks are labelled as unrecorded pre-checks.

## Stage 3 r1 fixes (sol lfspk-W6-code3-r1, 405594f..e8f3504: 4 major, 1 minor)

- M1: `load_scores` now validates every subject's record against the CURRENT
  inputs (`current_state`, `expected_records`, `validate_meta`): the scoring
  manifest, the profile build, every cell's profile digest, the code closure
  (SCORE_FILES is now score, profiles, render, subjects, signals, stream and
  tune, plus W5's extract), and every model file's current sha and identity.
  - Each readout must be the expected untagged run, tuned from the pinned
    base on exactly its subject's current tuning inputs (dict digests, bank
    pack, profile, profile build).
  - Regressions cover uniformly stale profiles (identity and digests),
    uniformly stale code, a replaced checkpoint, changed tuning inputs and a
    wrong run at a cell.
- M2: D5 checks every variant's run (`check_variant`): arm, subject, P, step
  1,000, tag, device and platform prefix (Linux / macOS), and the subject's
  current inputs; Mac runs must also name their bundle.
  - d5.json now carries provenance: the scoring set, the profile build, the
    code, and each variant's sha and identity sha. `load_d5` re-validates it
    against the current readouts.
  - Regressions cover a CUDA readout at a Mac path, the wrong platform, the
    other repetition, another profile and a stale d5.json.
  - An invalid d5.json fails G5 with its reason.
- M3: G5 refuses duplicate (subject, rep) records, and every eligible
  measured run must pass (extra repetitions included). The regression puts a
  failing and a passing record on the same rep, in either order.
- M4: X1 reports all four contrasts in frac, under and over with
  shared-resample CIs (`contrast3`), and every cell summary has CIs. The
  regression uses non-proportional synthetic data.
- minor 5, all report-only:
  - the base's per-user safety;
  - D3's cos(p0, p_end), per subject and median;
  - the bootstrap SE of the pooled S4 gain;
  - F's applicable gate table (G1-G4);
  - D5's Mac r1-vs-r2 comparison.
- Unrecorded pre-check (direct ./python): test_W6_score 24 OK. The recorded
  run is w6-unit-s3-r2.

## Stage 2 r2 fix (sol lfspk-W6-code2-r2, ea13b9d..e33eab7: 1 major left)

- MAJOR, cached bytecode: every bundle Python now runs as `python -B -X
  pycache_prefix=<fresh empty temp dir>` (`python_argv`, `fresh_prefix`):
  - the measure child;
  - the measure parent, through `mac_measure_command`;
  - the receive-and-verify step in `mac_receive_command`.
- `require_isolated_bytecode` refuses to run unless -B is set, the prefix
  lies outside the bundle and the prefix is empty. It runs before preload,
  after module verification, and again after training.
- `verify` refuses any __pycache__, *.pyc or *.pyo inside the bundle.
- Regression (subprocess): in-tree bytecode compiled from features.py with
  PREEMPH 0.50, given the pinned source's mtime and size.
  - Under plain -B it executes (0.5), which reproduces the attack.
  - Under the bundle launch the source runs (0.97).
  - `verify` refuses the bundle while the cache exists.
  - A launch without the prefix is refused.
- Unrecorded pre-check (direct ./python): test_W6_tune 15 OK. The recorded
  run is w6-unit-s2-r3.

### Stage 2 status (orchestrator, 2026-10-24)

- The orchestrator verified the code2-r2 bytecode fix (a959312..8c3460b).
- **Stage 2 is CLOSED, conditional on the recorded run w6-unit-s2-r3
  passing.** It is queued.
- G5 run count, checked against DESIGN 7 (the point flagged for stage-3 r2):
  the design's "2 repetitions each, so 8 runs" is 2 subjects x 2 arms x 2
  repetitions in total, which is 4 gated runs per arm. G5 is evaluated per
  arm over exactly those 4 (P, 2 threads, background QoS, reps 1-2).
- The 3 report-only runs (1 thread; configuration F; default QoS) differ in
  threads, configuration or QoS. G5's eligibility filter therefore excludes
  them, and D5 looks only for the mac-background-t2-r{1,2} paths. The two
  are consistent.

## Stage 3 r2 fixes (sol lfspk-W6-code3-r2, cab6756..a959312: 4 major)

- M1: `code_identity` now binds the whole calculation and reporting closure:
  every lfspk/personal/*.py (boot, gates and macbench included), every
  lfspk/extract/*.py, and W0's bootstrap providers with their transitive
  imports (lfspk/{__init__,api}.py, lfspk/harness/{__init__,tmetrics,align,metrics}.py,
  found by importing tmetrics in a fresh interpreter). The test appends a
  byte to each closure file in a copied tree and checks that the identity
  changes for every one.
- M2: readout records keep the full tuning config, the training-code hashes,
  alpha and the adapted count. `check_tuned` validates:
  - every PILOT_FIXED hyperparameter;
  - the variant's registered execution settings (device and threads for
    nixos-CUDA, Linux-CPU and Mac);
  - the arm's alpha and P's 186,242 parameters;
  - the training code against the current code.

  Runtime versions and platform strings may differ between Mac and Linux.
  Substitution regressions cover lr, seed, threads, device, steps, batch,
  readouts, stale training code, another arm's alpha, and a CUDA config
  under a Mac tag.
- M3: every D5 result must have exactly one 3-metric, finite row per scoring
  render of its subject, with family and presence in scoring-key order
  (`check_rows`). The regression is a 6-row payload.
- M4: D5 failures are isolated. `d5_records` and `validate_d5` return
  per-variant errors, and global provenance (scoring set, profile build,
  code) still invalidates everything. G5 for an arm needs only that arm's
  nixos reference and its two Mac repetitions for both subjects. Another
  arm's problems and the Linux-CPU attribution runs are reported, never
  gating. The regression puts a missing A-V0 Mac readout and a missing
  A-VB CPU readout together: A-V0 fails and A-VB passes.
- Unrecorded pre-check (direct ./python): test_W6_score 27 OK. The recorded
  run is w6-unit-s3-r3.

## Stage 3 r3 fix (sol lfspk-W6-code3-r3, bead576..38a77d4: 1 major left)

- MAJOR, D5 isolation: `validate_d5` now turns per-result schema and
  conversion errors (KeyError, ValueError, TypeError, IndexError, plus
  RuntimeError) into that variant's error entry. A result that is not an
  object is refused as TypeError. Global provenance validation stays outside
  that boundary and still raises.
- Regression: a CPU result missing `family` (KeyError), a ragged Mac row
  (ValueError) and Mac metrics given as None (TypeError).
  - Each becomes an error on its own variant.
  - A-VB's D5 still passes with its malformed CPU result, which is
    report-only.
  - A-V0 fails on its malformed Mac results.
- Unrecorded pre-check (direct ./python): test_W6_score 28 OK. The recorded
  run is w6-unit-s3-r4.

Recorded test outcome: w6-unit-s3b (run 20261024T014732Z) **succeeded**,
test_W6_score 27 of 27 OK. It ran on the working tree at its start time,
which was the stage-3 r2 code (38a77d4: 27 tests). It is therefore the
recorded pass of the stage-3 suite through r2, and it supersedes the
unrecorded claim corrected above. The r3 fix (28 tests) is recorded by
w6-unit-s3-r4, which is queued.

### Stage 3 status, and GO (orchestrator, 2026-10-24)

- The orchestrator verified the code3-r3 fix (38a77d4..727d9c0).
- **Stage 3 is CLOSED, conditional on the recorded run w6-unit-s3-r4
  passing.** All three code stages are closed, each conditional on its
  recorded run (all-r3, s2-r3, s3-r4).
- GO for production, gated on the recorded runs. Nothing starts until
  w6-unit-all-final (the full suite on the current tree) has passed as a
  recorded job; any recorded failure means stop and report.
- Order:
  1. renders and the pack;
  2. the audit, whose verdict goes to the orchestrator before any tuning;
  3. on the orchestrator's go, the smoke tune, then the 88 fine-tunes;
  4. in parallel, once s2-r3 has passed: the Mac bundle, the Taildrop
     transfer, verification and the measurements;
  5. the coverage smoke test;
  6. scoring and gates.

Execution: the render chain and the coverage smoke test are submitted with
`after` dependencies on w6-unit-all-final, so the job tool enforces the
gate. They run one at a time, so W6 leases at most 16G of host memory.

### Recorded test runs (orchestrator job watch, 02:37 UTC, 2026-10-24)

All recorded runs succeeded:
- w6-unit-all-r3: 81 OK, 1 skipped;
- w6-unit-s2-r3: OK;
- w6-unit-s3-r2: 28 OK;
- w6-unit-s3-r3: OK;
- w6-unit-s3-r4: 28 OK;
- w6-unit-s3b: 27 OK.

**The closure conditions of stages 1, 2 and 3 are met; all three code
stages are CLOSED.** w6-unit-all-final (the full suite with the opt-in
integration test) gates the production chain and is queued. The Mac
bundle's s2-r3 condition is met; the bundle still needs the bank pack.

Report-only addition to the Mac measurement (orchestrator, 2026-10-24).
`measure` records `power_snapshot()` before and after each run: `pmset -g
batt` (AC or battery and the charge), `pmset -g therm`, the load averages
and an on_ac flag, written to measure.json as power_start and power_end. It
does not change G5. A run on battery is noted here and reported to the
orchestrator before the gated runs count. The change touches macbench.py
and test_W6_tune.py before the bundle is built, so the queued
w6-unit-all-final records it. Unrecorded pre-check: test_W6_tune 16 OK.

Production gate (orchestrator job watch, 04:07 UTC): w6-unit-all-final
succeeded, 82 tests OK, recorded. It covers the current tree, including the
pmset addition (9409ef0). The render chain is released; w6-render-dict is
queued for memory.

## w6-render-dict failure (run 20261024T020621Z, 2026-10-24): diagnosis

- Failure: `AssertionError: 497-31: dictation has fewer than 50
  target-active frames` after 37 s. Everything later in the chain was
  skipped from w6-profiles on.
- Partial output: 708 of 878 renders. They are quarantined, not deleted, in
  runs/W6/quarantine/dict_failed_20261024T0206/. runs/W6/render/ is now
  empty.
- Diagnostic: a read-only scan of the 878 dictation keys, using utterance
  durations and W0's alignment activity
  (`mix.activity_from_alignment`, as `placed_activity` uses), with no
  rendering. Script /tmp/w6diag/scan_dict.py (sha256 6b7ac646...9acc). It was
  run directly with a 90 s timeout and is **unrecorded**. The recorded rerun,
  w6-diag-dict-scan, is queued for memory.
- **497-31 is genuinely short; the labels are right.** Its utterance,
  497-129325-0061, lasts 1.075 s, with 25 aligned active frames (0.25 s).
  On the 708 rendered files, the rendered target_active equals the
  alignment activity exactly (0 mismatches), so neither the labels nor the
  alignment are at fault.
- **Only 1 of 878 dictations fails the 50-frame check, and it is a drift
  dictation** (index 31 of 36; D3 only). All 220 tuning dictations have at
  least 50 active frames.
- **The closed DESIGN contains a false premise.** Section 2.2 selects the
  dictations as `bank_utterances(partition)` (W3's bank rule), which has no
  target-length filter. Section 2.4 claims "every dictation is 3-20 s of
  read speech".
  - In fact 20 of 878 lie outside 3-20 s: 18 below 3 s (minimum 1.075 s) and
    2 above 20 s (20.26 s and 29.7 s, both drift).
  - 5 of the 220 tuning dictations are 2.2-2.7 s: 1456-00, 5386-04, 497-04,
    497-08 and 119-05. All of them still have at least 50 active frames.
  - W3's target-length filter (3-20 s) applies to mixture targets only, and
    W6's scoring targets apply it. DESIGN never applied it to dictations.
- Why keys-check and the tests missed it:
  - w6-keys-check counted keys and checked scoring-pool sizes, but not
    dictation durations or activity.
  - The opt-in integration test rendered only 2775-00.
  - The render-time assert was the only check, and it fired as designed.

## Erratum E1 fix (orchestrator ruling, 2026-10-24): downstream check of the 3-20 s assumption

Code changes:
- render.check_dictation_activity: the at-least-50-active-frames assert now
  applies only to tuning dictations (index < 10). stream.Dictation's
  load-time check is kept.
- `render precheck` (a recorded job before render-dict) scans the durations
  and alignment activity of all dictations.
- `audit dryrun` (recorded, before tuning) generates all 8,000 tuning
  examples of every subject.
- Regressions: a short drift dictation is allowed, a short tuning dictation
  is refused, and a 2.2 s dictation is run through the stream.

Every downstream place that might have assumed 3-20 s dictations, and
whether behaviour changes:
1. 8 s crops and padding (prepare_batch). A 2.2 s mixture has about 220
   valid frames; the rest of the 800-frame crop is padding, masked out of
   the loss and the features (W5's rule for short mixtures). Unchanged.
2. S3 ±2 s shift (amendment A1). In a short window the onset-aligned c0 may
   be small; eligibility is max(50, ceil(0.9 c0)). If no shift is eligible
   the donor is rejected, and after 20 rejections the example raises. This
   path is designed but untested on real short dictations:
   - The synthetic regression shows a 2.2 s dictation through S1, S3, S4 and
     N with the retention rule holding.
   - The recorded stream dry-run checks the real bank with all five short
     tuning dictations (the same stream for P and F).
   - Exhaustion would fail loudly, never silently.
3. S1, S2 and S4 placement: the same at-least-50-placed-frames rejection
   applies. A shorter window can raise the rejection rate, which the dry-run
   and the audit report. Unchanged.
4. N levelling over the full window: donor noise is cut to len(d) and its
   power taken over the whole placed window. That is correct for any
   length. Unchanged.
5. Audit padded share: short dictations are usually shorter than the donor,
   so the donor is cut and the padded share is low. Reported as is.
   Unchanged. Subject 1456, one of the 4 audit subjects, has a short tuning
   dictation (1456-00).
6. Profiles. *Corrected (E1-r1 m1):* the durations above are SOURCE
   utterance durations. The rendered recording is longer, because W0 adds a
   room-noise lead and tail. Reproduced from the registered seed, 497-31
   renders to 2.38 s, which gives five 1.5 s candidate windows, so W1's
   short-window fallback does not apply to it.
   - Source duration cannot show that a tuning dictation keeps windows after
     W1's speech gate and robust trimming. "No tuning dictation is skipped"
     is therefore **unverified** until w6-profiles has run.
   - w6-profiles now records, per tuning dictation, the rendered duration
     and the windows in the layout, after the speech gate and after robust
     trimming. It fails if any tuning dictation contributes 0 windows or if
     p0 accepts fewer than 10. Per drift dictation it records the rendered
     duration and whether W1's update accepted it.
7. D3 drift: the gated update accepts or rejects each drift dictation, and
   w6-profiles records which. Report-only. Unchanged.
8. Scoring sets: their targets already use the 3-20 s filter (2.5).
   Unaffected.

Net: no selection change. The only behaviour change is that drift dictations
are no longer refused at render time.

Training-distribution effects of short tuning dictations (E1-r1 m2;
documented here, no method change):
- The loss averages over valid (t, f) bins of the whole batch, so a short
  example contributes in proportion to its valid frames. A 220-frame (2.2 s)
  example weighs 220/800 = 27.5 % of a full 8 s crop. The five 2.2-2.7 s
  tuning dictations of subjects 1456, 5386, 497 (two) and 119 are therefore
  under-weighted relative to their share of draws (1 in 10 each).
- Short recordings offer fewer distinct crops: a recording no longer than
  8 s always gives the whole recording, padded. A short dictation's examples
  therefore differ only in the interference, not in which part of the
  subject's speech is shown.
- Rejection of empty placements (at least 50 interferer-active frames)
  conditions the accepted donor distribution on short dictations, towards
  donors whose interference falls early or densely. The stream dry-run
  reports rejections per family and per dictation, as draws, total and max.
- The audit's padded_share measures interference padding (donor shorter than
  the window), not crop padding. Its pooled-median stop rules cover 4
  subjects and may not detect these per-dictation effects; only one audit
  subject (1456) has a short tuning dictation.
- Each model tunes on its own subject's dictations. A subject with short
  dictations therefore has a slightly different training distribution from
  its control donor, which is a known source of per-subject heterogeneity in
  the gain d_i.

p0 path (orchestrator condition, 2026-10-24):
- profiles.py builds p0 through W1's enroll_windows, so that it can count
  windows per dictation. `windows_kept` reconstructs W1's robust trimming
  (robust_keep, split by dictation) for diagnosis only.
- What guarantees p0 is unchanged is an equality assert. For every subject,
  w6-profiles also computes the reviewed `prof.enroll(<10 tuning
  dictations>)` and requires its `to_bytes()` to be bit-identical to the
  enroll_windows profile. Any difference fails the job. profiles.json
  records "enroll_equivalence": true.
- Tests:
  - a unit test of the check;
  - a test of the equality with the real redimnet2-b2 profiler on synthetic
    audio, skipped without /mnt/hd. Unrecorded pre-check: OK. The recorded
    run is w6-unit-e2.

Quarantine cleared (2026-10-24, after the E1 round closed): runs/W6/quarantine/dict_failed_20261024T0206 (708 partial renders) deleted. The chain is resubmitted with w6-unit-e2 at its head.

Recorded: w6-unit-e2 (run 20261024T072102Z) succeeded, 90 tests OK (orchestrator job watch, 09:07 UTC). Head of the resubmitted chain.

### Dictation precheck and render (2026-10-24)

- w6-dict-precheck succeeded. 878 dictations; the minimum over the tuning
  dictations is 94 active frames.
  - Drift dictations under 50 active frames: 497-31 only.
  - Tuning dictations outside 3-20 s (source duration): 1456-00, 5386-04,
    497-04, 497-08 and 119-05.
  - These match erratum E1.
- Set identity sha256: b0ca12bf24f6e52b88daba270196e2a3a8fd86fe230e43c45e886dd1955b2cf9.
- w6-render-dict succeeded in about 45 s. 878 renders.
- `render verify --set dict` passes against the current identity, with all
  878 digests checked. The manifest's identity equals the precheck's set
  identity.
- w6-profiles is queued for memory behind W1's lanes 12 and 13.

### Profiles, bank, pack, stream dry-run, Mac bundle (2026-10-24)

w6-profiles (22 min 46 s):
- **enroll_equivalence true**: enroll_windows is bit-identical to
  prof.enroll for all 22 subjects.
- Tuning windows kept after the speech gate and robust trimming: at least 8
  per dictation over all 220. The lowest are 5386-04 and 497-04 (8 each),
  then 1456-00, 497-08 and 119-05 (9 each), all of them the short source
  dictations.
- Rendered lengths of the short tuning dictations are 3.11-3.91 s.
- Drift accepted by W1's update: every update for 21 subjects (30 of 30;
  1335 has 28 of 28). For 497 it is 29 of 30; the rejected one is 497-31
  (confirmed from profiles.json).
- cos(p0, p_end): median 0.992, minimum 0.979.

w6-render-bank (35 s) and w6-render-pack (32 s):
- bank set identity 8f01f918...; pack.json sha256 064cf937...

w6-stream-dryrun (2 min 14 s): all 8,000 tuning examples of each of the 22
subjects were generated, with **no donor exhaustion**. The largest
rejection count for one example is 11 of 20.

| family | present draws | rejections | max for one example |
|---|---|---|---|
| S1 | 29,315 | 2,152 | 11 |
| S2 | 29,452 | 0 | 0 |
| S3 | 29,364 | 1,992 | 9 |
| S4 | 29,132 | 20 | 3 |
| N | 16,552 | 0 | 0 |

Short tuning dictations (draws / rejections / max):
- 1456-00: 563 / 223 / 7
- 5386-04: 584 / 197 / 7
- 497-04: 615 / 315 / 11
- 497-08: 618 / 284 / 9
- 119-05: 631 / 202 / 7

Short dictations reject several times more often than average, as the E1
training-distribution note anticipated.

w6-macbundle failure and recovery:
- w6-macbundle (first attempt) failed after 4 s: "profiles were built under
  another identity (differs in ['w1.w1_code_sha256'])". W1 had committed
  lfspk/embed/partial_b2_norm.py (2298acc) while w6-profiles ran. The
  identity check caught it.
- W1 moved the file out of the hashed closure (cc23365), restoring
  w1_code_sha256 7f3f11e1...aa74. Current profiles.identity() equals the
  stored identity, and profiles.load() passes. Nothing was rebuilt.
- The dict and bank render identities do not include W1. The dry-run read
  pack 064cf937..., the current pack, so all of these stay valid.

w6-macbundle (rerun, 22 s):
- 85 files, 1,945,358,185 bytes.
- bundle.json sha256 7694283fdee2b0db4cc539c1dfeebb3d7d0ad4a596454c80a9084a3e0b7ffae4.
- tar runs/W6/w6-macbundle.tar, sha256
  bdd84fe12cada211dac58e069d8b4453b1729bdd3b0c2b423fde37ad844b2b26.
- Taildrop: the Mac's Tailscale device name is "laptop" (online, direct).
  Job w6-taildrop is running.

### Mac transfer (2026-10-24)

- w6-taildrop (nixos, 34.8 s) succeeded: `tailscale file cp
  w6-macbundle.tar laptop:`.
- The first w6-mac-receive (run 20261024T164128Z) failed at the shasum
  step: the tar was not in ~/Downloads. Taildrop on this Mac holds incoming
  files in Tailscale's inbox until they are accepted.
- w6-mac-file-get ran `tailscale file get --wait=false --conflict=skip
  ~/Downloads/` on the Mac, which wrote the tar to ~/Downloads
  (1,945,528,320 bytes, the nixos size). This uses the Tailscale CLI only,
  with no SSH helper or credential.
- The second w6-mac-receive (run 20261024T164240Z) started at 16:42:42 UTC.
  The Mac then went offline (Tailscale: last seen about 16:43, ping
  timeout), so the job's outcome is unknown. The receive chain deletes the
  tar only after verify passes and refuses an existing bundle directory, so
  an interrupted run is safe to inspect and redo.

Orchestrator rulings on the Mac transfer:
- `tailscale file get` is the approved receive half of the Taildrop flow
  (no SSH credential). It is now the first step of `mac_receive_command`,
  tolerated to find nothing because the sha256 check fails closed, with the
  test asserting the step order.
- The bundle on the Mac carries the earlier macbench.py copy. The receive
  command is generated on nixos, and the bundle runs only its own verified
  copy, so the bundle is unaffected. Unrecorded pre-check: TestTar OK.
- Confirmed from profiles.json: subject 497's only rejected drift dictation
  is index 31 (497-31, rendered 2.38 s).

Recorded: w6-unit-tar (run 20261024T164724Z) succeeded, test_W6_tune 16 OK (includes the receive step-order test).

Bundle code vs current tree (checked 2026-10-24, after 0b8a814):
- The tuning-code identity that readouts carry, and that check_tuned
  compares, is `tune.code_sha256()` over TUNE_FILES = lfspk/personal/
  {__init__, subjects, signals, stream, tune}.py, plus W5's
  `code_sha256()` over lfspk/extract/*.py.
- bundle.json's code equals the current tree: w6_tune_code_sha256
  7a06446a...b0a5 and w5_code_sha256 599f6752...daad.
- Of lfspk/personal/*.py, only macbench.py differs from the bundle's copy.
  It is not in TUNE_FILES, so Mac and nixos readouts carry identical
  training-code identities and scoring will not falsely refuse the Mac runs.
  The current bundle (bundle.json 7694283f...) is kept.
- **Freeze:** lfspk/personal/*.py stays unchanged from now until scoring,
  unless the orchestrator approves a change, so the Mac and nixos code stay
  identical.

## Augmentation audit (w6-audit, 1 min 08 s, 2026-10-24): **verdict PROCEED**

Data: the first 2,000 examples of each of 2775, 1335, 639 and 1456 (8,000
in all: 372 absent, 1,533 S0, 720 N). The bank pack is 064cf937. Values are
medians, with the 5-95 % range in brackets. T is the transplant, D the bank
donors (W0 coherent), M the W0 mixed-mode references.

| family | n | overlap T | overlap D | overlap M | channel T | channel D | channel M (p95) | padded share T | rejections |
|---|---|---|---|---|---|---|---|---|---|
| S1 | 1,328 | 0.354 [0.10-0.70] | 0.411 | 0.366 | 5.55 | 5.81 | 5.67 (10.08) | 0.031 [0-0.58] | 46 |
| S2 | 1,293 | 0.696 [0.30-0.87] | 0.741 | 0.743 | 5.41 | 5.61 | 5.86 (9.21) | 0.034 [0-0.56] | 0 |
| S3 | 1,340 | 0.127 [0-0.31] | 0.008 | 0.007 | 10.81 | 9.93 | 10.74 (15.75) | 0.005 [0-0.43] | 40 |
| S4 | 1,414 | 0.662 [0.17-0.86] | 0.703 | 0.706 | 5.72 | 5.63 | 6.31 (9.88) | 0.029 [0-0.58] | 0 |

Stop rules (DESIGN 2.4):
- SIR: max |SIR - SIR_D| = 5.2e-7 dB, against a limit of 0.1. Pass.
- Channel: every family's transplant median is below its mixed-mode p95.
  Pass. Transplant channel distances are at or below the coherent donors'
  in S1, S2 and S4, and 0.9 dB higher in S3.
- Overlap (S1, S2, S4): each transplant median is at least half the donors'
  median (0.354 against 0.206, 0.696 against 0.371, 0.662 against 0.352).
  Pass.
- S3 overlap is report-only: the transplant median is 0.127, against 0.008
  for the donors. Turn-taking is only approximated (amendment A1), and
  dictations are often continuous speech with few gaps. This is the known,
  registered departure, and it is larger than W0's.
- S3 kept share (kept / c0): n = 1,320, median 1.00, p05 0.90, p95 1.27,
  maximum 24.25. Shares above 1 arise when c0 is small and the shift finds
  more interference. 20 cases are undefined (c0 = 0) and are counted
  separately.
- N rejections: 0.

## Coverage smoke test (w6-coverage, 5 s; frozen seed 20261024)

- **coverage 1.000 over 200 replications, MC SE 0.000.** Tolerance 0.90:
  PASS.
- Recorded replay through the real boot.py functions (w6-coverage-diag,
  script /tmp/w6diag/coverage_diag.py, sha256 92f901fd...7426, outside the
  repo):
  - 200 replications, n_boot 2,000 per replication, 5.1 s. It reproduces the
    stored result.
  - Undefined resamples: 34 in total, at most 2 in one replication (the
    limit is 20).
  - Point estimate: mean 0.0590 against a true 0.06, so no detectable bias.
- **Finding: the joint bootstrap is strongly conservative on this
  generator.**
  - The mean bootstrap SE is 0.0277, while the SD of the point estimate
    across replications is 0.0107, a ratio of 2.6. The median CI width is
    0.108.
  - Likely cause: a render's weight is the product of the draw counts of
    three involved speakers (subject, control donor, interferer). That
    inflates the variance of the resampled ratio relative to the true
    sampling variance.
  - The smoke test cannot detect over-coverage. If the real data behave
    similarly, G4a's "lower CI bound > 0" condition costs power well beyond
    the DESIGN 2.1 table. With SE about 0.028, a true gain of 0.05 passes
    G4a only about 1 time in 4.
  - Reported, not acted on. Changing the bootstrap would be a method change.

## Render sets (validated against the current identities)

| set | keys | identity sha256 |
|---|---|---|
| dict | 878 | b0ca12bf24f6e52b88daba270196e2a3a8fd86fe230e43c45e886dd1955b2cf9 |
| bank | 1,000 | 8f01f918337c6bff2b128ddf5bcde72c5158d7c439b0deda51a690f1c0030bd5 (pack.json 064cf937...) |
| auditref | 800 | 787310a01e1ca8232a787f5e0f01571366dec291829889caa9d29d41e8decbe4 |
| score | 2,640 | fbad9c49dbab848e7620caa9df5109359b5f36b5e436595a4d5dc5337fa4937a |

The `render verify` runs, with every digest checked against the current
identity, were done directly with ./python. They are **unrecorded**
validations; the render jobs that wrote the sets are recorded.

### Orchestrator rulings after the audit (2026-10-24)

- Audit PROCEED accepted. The final report will state the S3 overlap
  departure (0.127 against 0.008) plainly, as a limitation of the
  turn-taking approximation.
- Coverage: the registered bootstrap and G4a are kept, with no method
  change. The coverage result (1.000; SE_boot / SD = 2.6) is recorded as a
  known conservatism.
- **Correction of my power reading above.** G4a passes iff Delta-hat >= 0.05
  and Delta-hat - 1.96 SE_boot > 0. With SE_boot about 0.028, the second
  condition is Delta-hat > 0.055. The pass probability depends on
  Delta-hat's true sampling SD (0.0107 in the simulation), not on SE_boot:
  P(pass) is about Phi((Delta - 0.055) / 0.0107).

  | true Delta | 0.05 | 0.075 | 0.10 |
  |---|---|---|---|
  | P(pass G4a) | about 0.32 | about 0.97 | about 1.0 |

  That is close to DESIGN 2.1's SE = 0.013 row; only the exact-threshold
  case drops. My "about 1 time in 4" was wrong: I had used SE_boot as the
  sampling SD.
- The final gate table reports the bootstrap SE next to G4a.
- GO for tuning: a GPU smoke tune first, then the 88 fine-tunes.

## GPU smoke tune and the 88 fine-tunes (2026-10-24)

w6-tune-smoke (run 20261024T171225Z): A-V0, P, subject 2775, the full
registered config (check_pilot, 1,000 steps, CUDA, 2 threads). gpu:shared
3G, mem 6G.
- Job wall 40.3 s; training 25.9 s (0.026 s per step), of which the data
  wait was 19.6 s (75 %).
- Peak torch-allocated VRAM 0.23 GiB; process VRAM peak 1.38 GB; host
  memory peak 2.79 GB.
- Final logged loss 2.15 at step 1000 (log.jsonl). Every logged loss and
  gradient was finite (the run raises otherwise).
- Readouts 250/500/1000 load through load_tuned, and all three pass
  score.check_tuned against current_state(): pinned base, PILOT_FIXED,
  execution settings (cuda, 2 threads), alpha 10, 186,242 adapted
  parameters, training code and tuning inputs. step1000.pt sha256 is
  cdfc6620...325d.
- This is exactly the production run for (A-V0, P, 2775), so it counts as
  one of the 88; it is not rerun.

The remaining 87 run as three serial lanes (round-robin split; scripts
runs/W6/tune/lanes/lane{0,1,2}.sh, sha256 ef24e07b..., b72834e7...,
6d97d4ea...). Each lane has gpu:shared 2G and mem 4G, so W6 holds 12G of
host memory. Each lane stops at its first failure (set -eu).
- Jobs: w6-tune-lane0, w6-tune-lane1 and w6-tune-lane2, started 17:13 UTC.
- Expected: 29 runs per lane at about 40-60 s each, roughly 20-30 min, if
  the lanes do not slow each other much. They are data-bound on CPU.

### Fine-tunes done (2026-10-24, 17:34 UTC)

- w6-tune-lane0/1/2 all exited 0 (20 min 25 s, 20 min 34 s, 20 min 34 s),
  plus the smoke run.
- w6-verify-tunes (script /tmp/w6diag/verify_tunes.py, sha256
  d6629dac...1e17, outside the repo): **all 264 readouts** (2 arms x 2
  configurations x 22 subjects x steps 250/500/1000) exist and pass
  score.check_tuned against current_state(). Failures: none.
- Losses: no non-finite values in any run. The last-5-logged mean loss has
  no outlier beyond 2x or 0.5x its configuration median.

  | arm, config | median | range |
  |---|---|---|
  | A-V0 P | 2.86 | 1.61-4.39 |
  | A-V0 F | 2.75 | 1.58-4.39 |
  | A-VB P | 1.88 | 1.18-3.16 |
  | A-VB F | 1.79 | 0.99-2.62 |

- Observation, not an anomaly flag. The logged losses are single batches of
  8, logged every 50 steps, so they are dominated by the batch's family mix.
  The mean of the first 5 logs against the last 5 shows little decrease:

  | arm, config | first 5 | last 5 | subjects lower at the end |
  |---|---|---|---|
  | A-V0 P | 2.91 | 2.86 | 12/22 |
  | A-V0 F | 2.87 | 2.77 | 12/22 |
  | A-VB P | 2.10 | 2.04 | 15/22 |
  | A-VB F | 1.98 | 1.75 | 16/22 |

  The fine-tune does not change the training loss much at this scale, and
  scoring will show whether the masks changed.

Next (nixos):
- w6-tune-cpu: D5's 4 Linux-CPU attribution runs (2 subjects x 2 arms, P,
  tag cpu, 2 threads; script lanes/cpu.sh, sha256 7f8a53af...), mem 4G.
- w6-score: all cells, 22 subjects, 4 workers, mem 10G.
- These run concurrently, holding 14G of host memory.

## PROVISIONAL gate table (2026-10-24, 17:47 UTC; G5 and D5 pending, the Mac offline)

Scoring: w6-score (6 min 47 s, 22 subjects, every record validated against
the current state). Report: w6-gates-provisional, saved as
runs/W6/report_provisional_20261024T1747.json. These are configuration P at
step 1,000, target-present renders. All CIs are joint-bootstrap 95 %
intervals with shared resamples, B = 2000.

| gate | A-V0 | A-VB |
|---|---|---|
| G1 frac >= 0.20 in S1/S2/S4 | **FAIL**: 0.053 / 0.068 / 0.050 | pass: 0.395 / 0.483 / 0.459 |
| G2 S3 >= 0.45, and the CI of (P - base) has lower bound > -0.05 | **FAIL**: 0.489; P - base = -0.070 [-0.111, -0.028] | **FAIL**: 0.788; P - base = -0.031 [-0.060, -0.009] |
| G3a pooled over-suppression | pass: max over 0.0021 (S3); S0 0.0002, tail 0.0049 | **FAIL**: S2 0.114, S4 0.111; S0 0.014, tail 0.270 |
| G3b, every user S0 over <= 0.003 | pass (0 failing) | **FAIL** (15 of 22 failing) |
| G3c, every user other families <= 0.020 | pass (0 failing) | **FAIL** (22 of 22 failing) |
| G4a S4 gain >= 0.05 and CI lower bound > 0 | **FAIL**: 0.0139 [-0.0041, 0.0341], SE_boot 0.0092 | **FAIL**: 0.0396 [-0.0157, 0.1031], SE_boot 0.0291 |
| G4b S2 gain >= 0.025 | **FAIL**: 0.0175 | **FAIL**: 0.0106 |
| G5 Mac budget and D5 | pending (fails while d5.json is missing) | pending |

**Outcome: neither arm passes.** Each arm already fails several of G1-G4,
and the gates are conjunctive, so G5 cannot change the outcome. Per DESIGN
6.3: no combination, no variant, no re-run.

Context, report-only:
- frac in S4, personal / control / base: A-V0 0.050 / 0.037 / 0.030; A-VB
  0.459 / 0.419 / 0.379.
- Fine-tuning raises suppression a little over the base in both arms. The
  matched-user model leads the wrong-user model by 0.014 (A-V0) and 0.040
  (A-VB) on S4, and neither CI excludes 0.
- A-VB's over-suppression roughly doubles its base's. S0 goes from 0.0044
  to 0.014, the S0 tail from 0.087 to 0.270, and S2/S4 from 0.077/0.066 to
  0.114/0.111. A-VB's personal model is less safe than its base.
- S3 regresses in both arms: P - base is -0.070 (A-V0) and -0.031 (A-VB).
- X1:
  - A-V0: "profile sensitivity observed; identity mechanism unresolved".
    W_A.pA - W_A.pB on S4 is 0.0125 [0.002, 0.026].
  - A-VB: "profile sensitivity not detected; identity mechanism
    unresolved". The same contrast is 0.026 [-0.011, 0.065].
- X2: not control-degraded in either arm (control minus base on S4: +0.007
  and +0.040).
- D1, the base's own gain over its twin on S4 with this larger set: V0
  0.005, VB 0.050. W5 measured 0.001 and 0.049.
- D3: the drift profile changes S4 frac by at most 0.0002. The median
  cos(p0, p_end) is 0.992.
- D4, S4 gain at steps 250 / 500 / 1,000: A-V0 0.006 / 0.007 / 0.014; A-VB
  0.027 / 0.030 / 0.040.
- F (full fine-tune, report-only): A-V0 fails G1-G4; A-VB passes G1 and G2
  but fails G3 and G4 (S4 gain -0.016).
- Sizing: n_eff 21.5. The SD of the per-subject gains d_i is 0.026 (A-V0)
  and 0.072 (A-VB).

## CLOSED 2026-10-24 by owner decision

AJ ended the experiment and chose to skip the Mac measurements.

- **Final outcome: neither arm passes G1-G4.** The PROVISIONAL gate table
  above (2026-10-24, 17:47 UTC) is the final outcome. The report is
  runs/W6/report_provisional_20261024T1747.json, a copy of report.json as
  written by w6-gates-provisional, run 20261024T174739Z.
- Selection per DESIGN 6.3: none. No combination, variant or re-run.
- **G5 and D5 were not measured** (the owner skipped the Mac runs). H-P3,
  whether a fine-tune fits the Mac CPU budget, is unanswered. The only Mac
  timing evidence is the synthetic-tensor microbenchmark in the pre-design
  inspections: 0.615 s per step for P at background QoS on 2 threads.
- The 4 Linux-CPU D5 attribution runs completed (w6-tune-cpu, exit 0) and
  were not scored.
- Limitations to state with the result:
  - S3 transplant overlap is 0.127, against 0.008 in W0's renders. The
    turn-taking approximation (amendment A1) works poorly on continuous
    dictations.
  - The joint bootstrap is conservative: in the frozen generator SE_boot is
    2.6 times the sampling SD.
  - Short tuning dictations: erratum E1 and its training-distribution note.
  - These are mask-error screens on held-out TRAIN speakers, not transcript
    safety.
- Jobs: no W6 job is running or queued on nixos.

**Open item: Mac cleanup is pending.** The Mac was offline at closure, so
nothing there was cleaned. The orchestrator is handling it with AJ. Possible
leftovers:
- w6-macbundle.tar (1.95 GB, sha256 bdd84fe1...2b26), in Tailscale's inbox
  or ~/Downloads;
- a partial or complete ~/localflow-speaker-w6/bundle/;
- the jobs-mac record of w6-mac-receive (run 20261024T164240Z), outcome
  unknown;
- the earlier synthetic microbenchmark directory /tmp/w6bench.

Only public-corpus data is involved. On nixos, runs/W6/ keeps the
renders, profiles, readouts, scores and reports. Diagnostic scripts used
during the run are in /tmp/w6diag/, with their sha256 recorded above.
