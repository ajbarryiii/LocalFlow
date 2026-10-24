# W1 results: speaker embeddings plus an adaptive profile

Status: in progress. Design and pre-registration: `DESIGN.md`. Stage A
summary for decision makers: `STAGE_A_SUMMARY.md`.

## Stage A results (intrinsic survey, dev, clean speech)

Reproduce (from a clean checkout of the cited commit; outputs under
`/mnt/hd/localflow-speaker/runs/W1/survey/`):

    ./python[-nemo] -m lfspk.embed.survey embed --embedder NAME --device cuda   # per embedder
    ./python -m lfspk.embed.survey score --embedders NAME                       # commit 4411471
    ./python -m lfspk.embed.survey render
    ./python -m lfspk.embed.survey compare --pairs redimnet2-b0:titanet-s ...   # commit 7927ea9
    ./python -m lfspk.embed.survey tail --embedders redimnet2-b2 wespeaker-r34lm redimnet2-b0   # commit 6bc4fab
    ./python[-nemo] -m lfspk.embed.cost --embedder NAME --coreml

Provenance. Embeddings were extracted at 17:57 UTC on 2026-10-21 from
HEAD 77f1d59, whose W1 code equals 2280e9d. Their meta.json label reads
"d08af76...-dirty" because the label was computed at the end of the job (after
a later commit) and its dirty check then covered other workstreams' files.
The embedding path (embedder.py, protocol.py, audio.py, survey.embed) is
unchanged from 2280e9d through 4411471, the scoring commit. Scoring ran from
a clean detached worktree of 4411471, n_boot = 1000, boot seed 20261021,
73 dev speakers, halves from W0's `lfspk.harness.halves` (37/36). Placement
fallbacks: dev segments 0; cohort segments 42 of 1840 (short utterances).
Cohort: 460 cohort-role train speakers x 2 utterances.

Primary (pre-stated): EER and impostor pass at 1 % target miss, 1.0 s
segments, k = 10, raw cosine. Selection on half A, selection-free on half
B. Full table in `STAGE_A_SUMMARY.md` and `intrinsic.md`; every embedder,
every length, every subset and every normalisation variant is reported there
(nothing omitted).

Pre-registered outcomes:
- H1 viability: supported. Some embedder's CI upper bound for impostor pass
  at 1.5 s / 1 % miss (all speakers) is below 50 % (r34lm 10.3 %, campp 18.3 %,
  b2 36.6 %).
- H1 size claim: supported. redimnet2-b0 minus titanet-s, operating point at
  1.5 s: -2.67 points [-42.3, +0.45], upper bound below the +10 margin.
- H2 (AS-norm K = 200 vs raw, EER, 0.5-1.5 s): supported for ecapa-vox
  (0.5 s: -0.47 [-0.70, -0.11]; 1.0 s: -0.33 [-0.67, -0.03]) and
  wespeaker-campp (0.5 s: -0.39 [-0.88, -0.02]); inconclusive for the other
  five. Never refuted. On the operating point, inconclusive for all.
  Consequence: raw cosine is the default for the shortlisted models.
- H3: k = 10 vs 3 improves at 1.0 s for ecapa, b0, b2 and r34lm (CI below 0).
  k = 30 vs 10 is inconclusive everywhere: neither within the +-0.5 band
  nor entirely below -0.5 (for example b2 at 1.0 s: -0.20 [-0.44, -0.00]).
- Shortlist (pre-stated rule): redimnet2-b2, wespeaker-r34lm, plus
  redimnet2-b0. The half-A EER winner is b2, so nothing is added.

Exploratory (not pre-registered): see the tail analysis in
`STAGE_A_SUMMARY.md`. One speaker (1988) carries 39-62 % of target misses at
the 1 % threshold; without 1988, b2 at 1.5 s has EER 0.90 % [0.55, 1.27] and
impostor pass 0.81 % [0.24, 1.54].

Seen-speaker diagnostic (descriptive): train-minus-dev within-speaker
cosine gap is +0.091 to +0.116 for every embedder (TitaNet-L +0.097,
TitaNet-S +0.100). No embedder stands out.

Surprises: (1) the operating-point tail is set by one speaker, not by the
models; (2) a 3.7 M-parameter model (ReDimNet2-B2) matches the 22 M TitaNet-L;
(3) AS-norm, a standard gain on VoxCeleb, did almost nothing here.


## Sol loop log

Reviewer: Codex gpt-6.1-sol, reasoning xhigh, priority tier, a new reviewer
each round. The orchestrator relays rounds because `delegate_task` is not
available to W1.

### Stage: shared embedder interface (`lfspk/embed/embedder.py`)

| round | reviewed | findings | outcome |
|---|---|---|---|
| r1 | 929b9be (interface, ECAPA, TitaNet-s) | 4 medium, 1 low | all fixed in 0305f7b |
| r2 | 929b9be..0305f7b (fixes plus TitaNet-L, WeSpeaker x2, ReDimNet2 x2) | 2 medium, 1 low | all fixed in f833cc8 |
| r3 | 0305f7b..f833cc8 (fix diff) | 1 medium | rejected with reason (below) |

Total: 3 rounds; 8 fixes (0 high, 6 medium, 2 low); 1 rejected.

Fixes by round:
- r1 medium: verified file and loaded file could differ (hash then reopen).
  Now each file is read once, hashed, and deserialised from the same bytes.
- r1 medium: CUDA determinism not enforced. cuDNN deterministic flags set for
  CUDA devices; CPU vs CUDA tolerance measured and recorded in NOTES.
- r1 medium: tests did not compare against upstream inference (removing
  ECAPA's sentence normalisation still passed). Added equality tests against
  SpeechBrain `encode_batch`, NeMo `infer_segment`, WeSpeaker's own
  `compute_features` and its ONNX export.
- r1 medium: batching tests used duplicate clips (batch-norm-style coupling
  would pass). Now distinct equal-length clips, across chunk boundaries.
- r1 low: `params` absent from the protocol. Added.
- r2 medium: a test imported an uncommitted module. Tests made self-contained,
  verified on a clean `git archive` export.
- r2 medium: fake `wespeaker` package left in `sys.modules` broke later
  imports. Vendored sources now load under private names
  `lfspk._vendor.<tag>`; regression test added.
- r2 low: three adapters untested. Contract tests now generated for every
  registered model, with a coverage test.

Rejected:
- r3 medium: a concurrent public `import wespeaker` in another thread during a
  cold adapter load could receive the temporary bare package. Rejected because
  neither `wespeaker` nor `redimnet2` is installed in `./python` or
  `./python-nemo` (find_spec returns None) and no code outside `embedder.py`
  imports them, so no public import can race the loader in this project; the
  limitation is stated in the `_import_vendored` docstring. Orchestrator
  agreed; no round 4.

Other change during review: MIN_SAMPLES raised from 0.1 s to 0.2 s, because
WeSpeaker ResNet34 returns NaN at 0.1 s (a single pooled frame); 0.2 s is the
shortest length every registered model handles (measured at 100, 150, 175,
200 and 250 ms).

### Stage: A, intrinsic survey (design, protocol, metrics, normalisation, survey, cost)

| round | reviewed | findings | outcome |
|---|---|---|---|
| r1 | f80f1ed (DESIGN.md whole, audio, protocol, metrics, norm, survey, cost, tests) | 1 high, 5 medium, 1 low | all fixed in 743705f |
| r2 | f80f1ed..743705f (fix diff) | 1 high, 3 medium | fixed in 2280e9d; the high one closes when W0 commits `halves.py` |
| r3 | 743705f..2280e9d (fix diff) | 1 medium | fixed; included in the Stage B/C r2 diff, as agreed with the orchestrator |

Total: 3 rounds; 12 findings (2 high, 9 medium, 1 low); 0 rejected.

Fixes by round:
- r1 high: survey hard-coded 40 speakers (dev was widened to 73). Population
  now derived from the plan and checked equal across embedders.
- r1 medium: seen-speaker check presented as a membership test. Now
  descriptive only, quality-matched (train-clean-360 vs dev-clean), and the
  TitaNet overlap flag is unconditional.
- r1 medium: decision rules used CI overlap. Rewritten as paired differences
  with pre-set margins and an explicit inconclusive outcome.
- r1 medium: head and gate fitting on train speakers that are also in the
  AS-norm cohort. Train speakers split once into cohort and fit halves.
- r1 medium: a normalised centroid plus count cannot continue a running mean.
  Stored state is now the unnormalised running mean plus count (W4's
  definition).
- r1 medium: EER-only pruning. Added the operating point (impostor pass at
  0.5 % / 1 % target-segment miss) for the shortlist and H1.
- r1 low: gate dilation changed the length of short inputs. Fixed with a
  regression test.
- r2 high: committed code depended on W0's uncommitted `halves.py`. Import
  kept lazy; scoring runs without it (half tables omitted) and an integration
  test covers that path.
- r2 medium: operating point wrong on FNR plateaus. Now the best attainable
  FPR within the miss budget, with the reviewer's case as a regression test.
- r2 medium: the gate's p95 cap admitted background-only crops in sparse
  speech. Placement now uses the uncapped gate, draws uniformly among
  qualifying starts, and counts fallbacks.
- r2 medium: H4 "harmed" rule inconsistent with the three-outcome rule. Fixed
  (and H3's "still improving" made consistent).
- r3 medium: a report rendered without halves did not say it was incomplete.
  A prominent INCOMPLETE banner is now rendered and tested.

### Stage: B/C, scorer, profile, update rules, head fitting, adaptation experiment, harness factory

| round | reviewed | findings | outcome |
|---|---|---|---|
| r1 | 2280e9d (profile, scorer, head, adapt, tests, DESIGN B/C) | 4 high, 6 medium, 3 low | fixed in 9c5150e |
| r2 | 2280e9d..b850fce | 1 high, 5 medium, 1 low | fixed in 4411471 |
| r3 | b850fce..4411471 | 3 medium, 1 low | fixed in 7c87f7f |
| r4 | 4411471..7c87f7f (plus factory f652531) | 4 medium, 3 low | fixed in 7bb67ee |
| r5 | 7c87f7f..7bb67ee (plus e59e371, 7927ea9) | 2 medium, 2 low | fixed in ac27945, verified by the orchestrator (no round 6) |

Total: 5 rounds; 35 findings (5 high, 20 medium, 10 low); 0 rejected. Stage
B/C CLOSED: 5 rounds plus post-final-round fixes verified by the orchestrator
at ac27945. e1b2dda (Stage C evaluation on non-overlapping held-out windows
and memoisation) was accepted by the orchestrator as a pre-registered
runtime choice, made before any Stage C result.

Post-close changes, checked by the orchestrator (no review round):
- e2437ef: caches and extractions record W0's mixture `index_hashes`,
  including the alignment hash, and refuse a change mid-run.
- 48f609e: head extraction renders once for several embedders and windows,
  with one immutable generation per pair.
- 71bb399: DESIGN fixes C = 1 and 3000 training mixtures.
- b7fbdf9: an optional per-recording cache of scoring-window embeddings
  (factory arg `cache`). It holds embeddings, not audio, and defaults to
  off. It is part of the factory kwargs, so W0's scorer identity records it.
  It stays off in anything that would ship, and latency is measured with
  cache = 0.

Main fixes:
- High:
  - gate calibration used cohort-half speakers;
  - one short stream dropped every k = 30 result;
  - no paired H4/H5 comparisons and no clean spouse baseline;
  - the bootstrap ignored the poisoner's identity;
  - the burst was not paired at its peak (320).
- Medium:
  - float16 storage lost small updates, so the profile now stores float32 (format v2);
  - head profiles were built differently from the harness;
  - relations were lost;
  - there was no long-horizon or anchored rule (added);
  - uncovered silence inherited target scores;
  - gates were not bound to their normalisation or window;
  - float32/float64 gate mismatch;
  - genuine change was untested (session and device change added, with a control sharing the first 300 dictations and at least 15 distinct dictations per project);
  - provenance gaps (dirty or smoke artefacts, extraction generations, factory root);
  - spouse identity counted before poisoning;
  - zero-baseline verdicts.
- Low:
  - calibration did not cover the complete rule;
  - cost terms were missing;
  - malformed profiles were accepted;
  - achieved rates were wrong at gate -inf;
  - various provenance records were missing.

Smoke runs before review (disclosed, not results): redimnet2-b0 on CPU with a
small cohort and 20 bootstrap resamples, to test the pipeline end to end. No
design choice was changed because of their numbers.

## Stage C results (profile adaptation, dev, W0 renders)

Runs: commit 48f609e (clean worktree). Caches: `runs/W1/adapt/{dev,train}/<embedder>/`,
gates `gates_<norm>.json`, results and rendered verdict tables
`runs/W1/adapt/results/<embedder>_<norm>.{json,md}`. n_boot = 1000, 73 dev
speakers (headline excludes same-chapter speakers), 1.5 s non-overlapping
held-out windows from S0 renders (room, device colouring, ambience).

    ./python -m lfspk.embed.adapt embed --split dev|train --embedders redimnet2-b2 wespeaker-r34lm redimnet2-b0 --device cuda
    ./python -m lfspk.embed.adapt calibrate --embedder E --norm raw|asnorm
    ./python -m lfspk.embed.adapt simulate --embedder E --norm raw|asnorm
    ./python -m lfspk.embed.adapt report

Calibration (fit-half train, 160 speakers, raw, all three embedders alike):
impostor window pass 10 %, impostor dictation pass 1.0 %, own dictation pass
99.8-100 %; anchor gate passes 1 % of impostors and 99.9-100 % of own
dictations; median lowest own drift cosine 0.957, drift floor 0.87 (b2).

Primary embedder redimnet2-b2, raw (the other five runs agree; see the .md files):

| rule | EER % k=3 / 10 / 30 | spouse dictations accepted: short 30 % / 50 %; long (mature) 30 % / 50 %; burst | genuine acceptance, last block after session change (pre 0.93-1.00) | after device change |
|---|---|---|---|---|
| naive | 3.86 / 3.71 / 3.77 | 100 % everywhere | 1.00 (follows) | 1.00 (follows) |
| gated | 3.86 / 3.72 / 3.77 | 1 / 2 %; 3 / 4 %; 2 % | 1.00 (follows) | 1.00 (follows) |
| robust | 3.95 / 3.72 / 3.77 | 1 / 2 %; 3 / 4 %; 2 % | 1.00 (follows) | 1.00 (follows) |
| anchored | 3.95 / 3.72 / 3.77 | 0 % everywhere | 0.40, ratio 0.43 [0.19, 0.67] | 0.90 (follows) |

Pre-registered verdicts:
- H3 (growth): flat. EER does not improve from 3 to 30 dictations on these
  renders for any rule (b2 3.9 -> 3.8 %; all within CI).
- H4 (20 % contamination): robust for all four rules and all three
  embedders (k = 30 difference +0.04 [-0.10, +0.13] points for b2 robust).
  Even the naive mean is unharmed: contaminated dictations are mostly the user.
- H5 (short poisoning): naive is poisoned at 50 % (spouse EER +36.6
  [+28.7, +44.4] points, same-sex; +40.8 cross-sex); at 30 % +6.3 [+0.8,
  +11.8], inconclusive by the +1 margin but clearly worse. Gated, robust and
  anchored: inconclusive by the rule (spouse-EER CIs are about +-5 points,
  wider than the margin, because each speaker has a single spouse), with
  point estimates +0.0 to +1.0 and only 0-2 % of spouse dictations accepted.
- H5-long (mature profile, 300 more dictations): naive drifts (+5.2 points at
  50 %); gated/robust accept 3-8 % of spouse dictations and their spouse EER
  rises +0.9 (30 %) and +2.0 (50 %) points for b2: inconclusive by the rule,
  but the direction is the slow capture the review predicted (for r34lm,
  whose gates let more through, robust is already +2.7 points at the short
  50 % condition). Anchored accepts 0-1 % and stays at +0.0 to +0.1 (b2).
  The burst of 20 is harmless for every gated rule.
- H5-change: gated and robust follow both a session change and a device
  change (acceptance 1.00). Anchored follows the device change (0.84-0.90)
  but, after a change of LibriVox project, accepts only 40-44 % of the
  genuine user's dictations (ratio 0.43 [0.19, 0.67], last minus control
  -0.52 [-0.75, -0.30] for b2; the same for all three embedders). By the
  pre-registered thresholds the verdict is "inconclusive" (the CI upper bound
  0.67 is not below 0.5), but the drop is large and significant against the
  control: **the anchored rule partly locks out a user whose recording
  setup changes.** Only 14 of 73 dev speakers qualify for this test.
- AS-norm vs raw: AS-norm lowers EER slightly (b2 k = 10: 3.52 vs 3.71 %;
  r34lm 3.15 vs 3.48 %) but its gates let more spouse dictations through
  over the long horizon (9-11 % vs 4-8 % at 50 %).

Reading: a gated update (1 % impostor dictation pass, calibrated on train)
removes almost all of the poisoning risk at no cost to genuine adaptation;
what remains is a slow drift when a second voice supplies a large share of
dictations for months. Anchoring stops that drift but breaks adaptation to a
genuinely new setup. The product needs either a gated rule plus an explicit
re-enrollment or per-route profile when the user changes setup, or an anchor
that can be re-based by the user. All long-horizon results are replay
dynamics over a few distinct dictations; months of fresh acoustic variation
are untested.

### Stage: D, configuration grid and selection rule (`stage_d.py`)

| round | reviewed | findings | outcome |
|---|---|---|---|
| r1 | 96373d9 | 3 medium, 2 low | fixed in 5a4c9d4 |
| r2 | 96373d9..5a4c9d4 | 1 medium, 1 low | fixed in a3e6224 |
| r3 | 5a4c9d4..a3e6224 | none | clean; Stage D CLOSED at a3e6224 |

Total: 3 rounds; 7 findings (0 high, 4 medium, 3 low); 0 rejected.

Fixes:
- latency was measured with the window cache on. Latency now runs as separate
  cache = 0 commands carrying the evaluator's CPU_ENV;
- non-finite costs could flip the selection;
- the S0 flag was not applied;
- full-dev results were unlabelled;
- the non-inferiority disclosure was missing. S versus B0 is now reported;
- latency commands lacked CPU_ENV;
- the cache was resized to 128 (no thrashing), with reuse unconditional.

### Stage D grid status (paused 2026-10-22 at the orchestrator's request; W5 prioritised)

Grid run from clean worktree 44b9984 (harness identical to READY 0d13957),
dev-v1 half A, factory cache=128, 8 workers per config. Order = `stage_d.grid()`.

Complete (results.json present; do not recompute), under
`/mnt/hd/localflow-speaker/runs/W1/eval/<name>/dev-v1-A/`:
- 00 w1-redimnet2-b2-L1.0-H0.25-raw-robust-score-C1.0
- 01 w1-redimnet2-b2-L1.0-H0.25-raw-robust-all-C1.0
- 02 w1-redimnet2-b2-L1.0-H0.25-asnorm-robust-score-C1.0
- 03 w1-redimnet2-b2-L1.0-H0.25-asnorm-robust-all-C1.0
- 04 w1-redimnet2-b2-L1.0-H0.5-raw-robust-score-C1.0
- 05 w1-redimnet2-b2-L1.0-H0.5-raw-robust-all-C1.0

Stopped mid-run (06 b2 L1.0 H0.5 asnorm score; 07 b2 L1.0 H0.5 asnorm all;
08 b2 L1.5 H0.25 raw score): partial score directories moved to
`/mnt/hd/localflow-speaker/runs/W1/eval_partial_quarantine_20261022/`; they
must be rerun from scratch, never resumed or read. Configs 09-47 and the
cache=0 latency job never started. No selection or result has been computed.
Measured footprint: about 11 GiB RSS per config (8 workers plus main); on
requeue cap memory per config and run at most 2 at a time.

Second pause (2026-10-23, W5 CPU priority): the requeue from worktree a6babc2
(2 lanes, --mem 13G) was stopped while running 06 and 07; nothing new
completed. Complete configs remain 00-05 only (list above, under
`runs/W1/eval/<name>/dev-v1-A/`, with CONTENT.json). Partial outputs of the
stopped 06 and 07 runs were moved to
`/mnt/hd/localflow-speaker/runs/W1/eval_partial_quarantine_20261023/`; rerun
from scratch. Configs 06-47 and the cache=0 latency job remain to run.

Third requeue (2026-10-23/24, worktree a6babc2, 8 workers per config):
w1-d3-06 (b2 L1.0 H0.5 asnorm score) and w1-d3-07 (… asnorm all) completed
at --mem 13G. w1-d3-09 (b2 L1.5 H0.25 raw all) and then w1-d3-08 (b2 L1.5
H0.25 raw score) were killed by the kernel OOM killer inside their own 13G
cgroups (systemd: "The kernel OOM killer killed some processes in this
unit"; BrokenProcessPool). Corrected peaks: 06 13.70 GB, 07 13.96 GB
(exactly the 13 GiB cap, completed), 08 13.75 GB and rising before the kill.
Worker RSS is 1.2-1.5 GB each and grows during a run; the earlier 11 GiB
estimate counted RSS only and was too low. Partial outputs of 08 and 09
quarantined in `/mnt/hd/localflow-speaker/runs/W1/eval_partial_quarantine_20261024/`.
Cap raised to --mem 18G (about 25 % above the observed peak) for all
remaining configs, requeued as w1-d4-* in the same order (two lanes), with the
cache=0 latency job w1-d4-latency after both lanes.

Completeness check (all eight completed half-A configs, 00-07): 37/37
speaker score files, 28560/28560 expected score keys (W0's
`expected_score_keys`), CONTENT.json and results.json present. 07 is complete
despite peaking at the cap.

Fourth pause (2026-10-24, W6 pilot priority). Complete half-A configs:
00-11 (results.json present). Running to completion, not stopped: w1-d4-12
and w1-d4-13 (b2 L1.5 H0.5 raw score / raw all), 18G. All other w1-d4-* jobs
stopped before starting. Pending, to requeue in this order with --mem 18G,
8 workers, two lanes:
- lane 1: 14, 32, 34, 36, 38, 40, 42, 44, 46, 16, 18, 20, 22, 24, 26, 28, 30
- lane 2: 15, 33, 35, 37, 39, 41, 43, 45, 47, 17, 19, 21, 23, 25, 27, 29, 31
- then the cache=0 latency job (quiet host, sequential, all 48), after both lanes.
If 12 or 13 fail, they go back to the heads of lanes 1 and 2 (outputs quarantined first).
Measured peaks at 18G: 08 15.7 GB, 09 15.1 GB.

Partial exploratory read (2026-10-24; configs 00-13 complete, grid paused;
NOT the pre-registered selection). Script `runs/W1/analysis/partial_b2_norm.py`,
output `runs/W1/eval_partial_b2_norm_read.json`. b2, half A, headline,
pooled S1-S4 interferer kept at the 0.5 % budget (oracle 18.5 %): asnorm is
lower than raw in all 6 matched pairs (by 0.5-4.2 points), every paired CI
includes 0. The full feature head is about 13-15 points worse than the
score-only head (its S0 cost equals the oracle's; score-only is about 1 point
below the oracle on S0). L1.5 beats L1.0. Best so far: b2 L1.5 H0.25 asnorm
score-only, 42.5 %.

## Closed

Closed 2026-10-24 by owner decision; Stage D incomplete (configs 00–13 of 48
done, half A only); no selection made. Complete Stage D outputs:
`runs/W1/eval/<name>/dev-v1-A/` for configs 00-13 (all ReDimNet2-B2; the B2
L1.5 H0.5 AS-norm pair 14/15 and all r34lm and b0 configs never completed).
Partial outputs of stopped runs (06-09 of earlier attempts, 14-15) are in
`runs/W1/eval_partial_quarantine_2026102{2,3,4}/` and must not be read. The
cache=0 latency measurements were never run. The only Stage D evidence is the
partial exploratory read above (`runs/W1/analysis/partial_b2_norm.py`,
output `runs/W1/eval_partial_b2_norm_read.json`): B2 only, half A, not the
pre-registered selection; AS-norm lower than raw in all 6 matched pairs but
every paired CI includes 0; score-only head about 13-15 points better than
the full head; best observed B2 L1.5 H0.25 AS-norm score-only at 42.5 %
interferer words kept (oracle 18.5 %).
