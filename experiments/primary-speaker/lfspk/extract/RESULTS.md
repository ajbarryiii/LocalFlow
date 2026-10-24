# W5 target-speech extraction: results

Status: design closed; implementation stage I in progress. No results yet.
DESIGN.md is the pre-registration (closed at f7d74ba; contract amendment
7c7c1fa makes its sections 9-10 normative for front ends).

## Sol-loop log

Reviewer: Codex gpt-6.1-sol, reasoning xhigh, relayed by the orchestrator. A
new reviewer each round; rounds after the first review the fix diff only.

### Stage D (design)

| round | reviewed | high | medium | low | fixed | rejected |
|---|---|---|---|---|---|---|
| r1 | 0f41398 (DESIGN.md) | 2 | 6 | 1 | 9 | 0 |
| r2 | 0f41398..cb2774a | 0 | 2 | 0 | 2 | 0 |
| r3 | cb2774a..4f50020 | 0 | 2 | 0 | 2 | 0 |
| r4 | 4f50020..1b1fb21 | 0 | 2 | 0 | 2 | 0 |
| r5 | 1b1fb21..f7d74ba | 0 | 0 | 0 | - | - |

Closed clean at f7d74ba after 5 rounds: 2 high, 12 medium, 1 low; all fixed,
none rejected.

r1 (fixed in cb2774a):
- High: the budget counted net loss, so recovered words could pay for lost
  ones. It now counts gross loss L+ by reference-word identity, with gain G
  and net L reported separately.
- High: B* could hide a guardrail violation. B is now the reference for every
  claim, B* is diagnostic only, and bypass returns the original features.
- Medium: absent-target examples had contradictory aux labels. Training labels
  are now relative to the conditioning identity, and N has none.
- Medium: the guard and floor claims were overstated. They are now
  approximations, the guard-regime share is measured, the floor bounds power
  only, and fixtures were added.
- Medium: the selection boundaries were inconsistent. Half-A quantities are
  held fixed in half-B resamples, and the confirmatory family {H1a, H1b, H2,
  H5} uses Bonferroni 98.75 % CIs.
- Medium: one word filter was reused across the two pairings. W is now chosen
  per pairing on half A, with re-aligned dWER_S0 and an infeasible case.
- Medium: held-out voices could reach training through contaminated profiles.
  A contaminator audit now feeds an overlay bank.
- Medium: stage 0 is now framed as a feasibility screen, with W_o measured on
  the same examples and a paired practical stop rule.
- Low: the mask-cache storage estimate was about 30x too small. It is now
  92 MB per audio hour per condition, and only the headline condition is
  cached.

r2 (fixed in 4f50020):
- Medium: H2 could pass on deletions under re-alignment. It now uses G_u,
  words unreachable by filtering, and is supported if CI(G_u - L+) > 0.
- Medium: a bypassed item re-run in another batch could differ from B.
  Bypassed items now reuse B's cached transcript, a mixed-batch hook test was
  added, and baseline batching is measured.

r3 (fixed in 1b1fb21):
- Medium: copied bypass entries were not pinned to their source B. They are
  now pinned to the B cache identity and record hash, re-validated on every
  load and refused when stale.
- Medium: the shuffled-B measurement was overclaimed. It is renamed "baseline
  batching sensitivity", masked-item batch effects are stated as unquantified,
  and an optional batch-1 replay was added.

r4 (fixed in f7d74ba):
- Medium: the record digest had no defined encoding. One `record_digest` over
  four fields, with deterministic JSON and exact floats, is now specified.
- Medium: the replay could satisfy or overwrite the headline cache. The
  replay is now a separate artefact, and batching mode is part of the
  identity.

### Stage I part 1 (harness interface: api, frontend.apply, nemo_hook, cachepin)

| round | reviewed | high | medium | low | fixed | rejected |
|---|---|---|---|---|---|---|
| r1 | f4762c9 | 0 | 4 | 0 | 4 | 0 |
| r2 | f4762c9..60c8567 | 0 | 2 | 1 | 3 | 0 |
| r3 | 60c8567..f2638ba | 0 | 0 | 0 | - | - |

Closed clean at f2638ba after 3 rounds: 6 medium, 1 low; all fixed, none
rejected.

r1 (fixed in 60c8567):
- Medium: apply() used W3's analytic constants, which differ from NeMo's by
  about 1 ulp. Normalisation amplified this to 0.009 on a -90 dB input. Fix:
  the checkpoint's own window and filterbank buffers (`constants.py`, read
  lazily from the .nemo and hash-pinned), plus an operation-for-operation
  NeMo mirror (stft call, fb matmul, `normalize_batch` port). hook == apply
  exactly on quiet and tonal inputs.
- Medium: content-hash matching rejected duplicates and broke on NeMo's
  sub-second padding. Fix: positional, verified rows through
  `transcribe_masked`; set_batch was removed. Sub-second inputs are refused
  and duplicates are allowed.
- Medium: same root cause as the previous finding, fixed by the same change.
- Medium: the ideal mask had a guard in the ratio. It is now the raw clipped
  ratio, with the zero-power cases defined.

r2 (fixed in f2638ba):
- Medium: the constants were not bound to the active model. `check_model` now
  refuses a model whose buffers differ, and extraction enforces the source
  hash.
- Medium: batch_size <= 0 silently returned "bypassed". batch_size is now
  validated and every masked item must get a record.
- Low: the smoke did not enforce parity. It now asserts exact CPU hook/apply
  parity in its exit status.

r3: no findings. The reviewer confirmed that the buffers are persistent and
restored, that the .nemo buffers equal the pinned constants, and that the
restored-preprocessor hook matches apply() with max diff 0.0.

Facts recorded during part 1 (synthetic inputs, not results):
- Parakeet's mel power is small. On white noise, the share of bins with
  g_min P < 100 eps is 14 % at -10 dBFS, 73 % at -30 dBFS and 100 % at
  -40 dBFS. A floored bin therefore often reads as the log guard, as DESIGN
  section 3 anticipated. Stage 0 measures this on real renders.
- Mask path latency (size M, untrained, one thread, CPU_ENV, loaded host) is
  1.03-1.07 ms per audio second median on 10 s and 20 s inputs, against a
  budget of 5 ms. The analytic count is 30.9 M MACs per audio second.

### Stage I part 2 (model, losses, data, overlay, front end, metrics, stage 0, profile check, cost)

| round | reviewed | high | medium | low | fixed | rejected |
|---|---|---|---|---|---|---|
| r1 | 7105b4f | 1 | 2 | 1 | 4 | 0 |
| r2 | 7105b4f..faafdfd + 12c176c | 1 | 3 | 0 | 4 | 0 |
| r3 | 3796c09..f6bea72 | 0 | 0 | 0 | - | - |

Closed clean at f6bea72 after 3 rounds: 2 high, 5 medium, 1 low; all fixed,
none rejected.

r1 (fixed in faafdfd):
- High: W_o's tau counted removals under B's fixed alignment. It is now the
  largest attainable threshold by re-aligned gross L+, with every candidate
  checked. A repeated-word regression is tested.
- Medium: N recorded the removed interferers as mixture speakers. Only
  present speakers count for bootstrap involvement now.
- Medium: stage-0 renders and transcripts were not bound to a generation. They
  are now bound to an identity, with exact keys, audio hashes and a manifest.
- Low: the padding test used a constant mask. It now uses live heads, at odd
  and even lengths.

r2 (fixed in f6bea72):
- High: analyse_threads was recorded but not enforced. `run_mask` now pins one
  thread and restores the caller's setting.
- Medium: consumers did not validate the CURRENT identity. Stage 0 now does,
  through validated_manifest.
- Medium: calibration had the same gap, closed in 3796c09 and f6bea72.
- Medium: absent-target involvement now includes the conditioning identity.
- Also, outside the review: 12c176c added theta_b from the checkpoint artefact
  and analyse_threads to the identity, both requested by W0F.

r3: no findings. The orchestrator ran the W5 suite at HEAD: 95 tests OK.

Follow-up review lfspk-W5-tmswitch-r1, closed clean in one round, covered:
- 1dd036c: the switch of evalwords to the shared `lfspk.harness.tmetrics`.
- 82e4a4c: run and seed in identity(), and the confirmatory-checkpoint
  pre-registration format.

The reviewer confirmed:
- the gross-L+ tau search, the keep convention and both stop predicates are
  preserved;
- the bootstrap's row order, universe and involvement are unchanged;
- evalwords is glue only;
- run and seed sit inside SHA-covered bytes;
- the registration line is unique, and its placeholder fails the strict
  pattern.

All W5 code stages are closed. What remains is the run order: overlays,
profile check, stage 0 (results to the orchestrator before any training),
calibration renders, train smoke and step-budget amendment, then R1 s0,
R2, R3 and R1 s1/s2.

### Stage I-train (train.py, calibrate.py)

| round | reviewed | high | medium | low | fixed | rejected |
|---|---|---|---|---|---|---|
| r1 | 52b4916 + 4182bcf | 1 | 4 | 0 | 5 | 0 |
| r2 | 4182bcf..3796c09 | 0 | 2 | 0 | 2 | 0 |
| r3 | 3796c09..77df5ee | 0 | 0 | 0 | - | - |

Closed clean at 77df5ee after 3 rounds: 1 high, 6 medium; all fixed, none
rejected.

r1 (fixed in 3796c09):
- High: the identity held torch's TorchVersion, so `weights_only` loads of
  production checkpoints failed. Identities and metadata are now JSON-safe.
- Medium: the stream had no backpressure. Prefetch is now capped at 3 batches,
  with order kept.
- Medium: W3 code was not in the resume identity. Its hash and the runtime
  versions are now included.
- Medium: calibration sets could reuse stale samples. They are now bound to a
  set identity with exact keys, audio hashes and per-sample conditions, and
  the theta population is validated.
- Medium: monitor contaminants came from training speakers. A held-out-only
  bank overlay (scope "heldout") now supplies them.
- Also added: the smoke records peak VRAM and runs a GPU resume check, and the
  DESIGN amendment records the post-hoc monitor.

r2 (fixed in 77df5ee; f6bea72's calibrate changes are included):
- Medium: the current identity was not checked. load_set now checks it first,
  and is tested against a stale but self-consistent generation.
- Medium: the render code hash did not cover calibrate.py. It now does, and
  stage 0 likewise hashes stage0.py. The W3 hash covers every transitively
  imported pvad module, found in a fresh interpreter (11 files).

r3: no findings.

## Pre-registered confirmatory checkpoint

Only the R1 seed-0 final checkpoint gets confirmatory labels on dev half B;
every other checkpoint is exploratory (W0 DESIGN 14.2 fe-10). Its SHA-256 is
recorded on the line below, in this exact machine-readable form, as soon as
`runs/W5/train/R1-s0/final.pt` exists and before any dev evaluation. The
recording is ONE dedicated single-parent commit (W0 DESIGN 14.2 fe-10 at
9704a68). Its message contains `REGISTER confirmatory-checkpoint R1-s0
<sha256>`. Its only change to this file replaces the placeholder line below
with the same hex. There is never a second commit with that tag and never a
rebase; a wrong hash is reported to the orchestrator, not re-tagged. Until
that commit exists, nothing touches dev with the R1-s0 checkpoint: no
exploratory run and no W0F smoke. W0F's ledger would permanently remove its
confirmatory status. Held-out-train uses (theta_b, monitor, stage-0 replay)
are fine.

    confirmatory-checkpoint: R1-s0 sha256=<to be recorded after training>
    superseded-checkpoint: R1-s0 sha256=87dc3765ec933f735dfc75f4d20153f103b28a03e349ec6277e9a5171e6c6888

## Post-review fixes and known limitations

- ffd2297 (mechanical post-review fix, verified by the orchestrator): the smoke's CPU parity check deep-copied the CUDA preprocessor and failed with fb on cuda:0. The smoke now rebuilds the preprocessor on CPU (`nemo_hook.cpu_preprocessor`), and the hook refuses device mismatches (`check_devices`). Diag (w5-diag-device, 2026-10-23): deepcopy+.cpu() moves fb correctly in isolation; smoke failure cause not determined; sidestepped by ffd2297, and check_devices guards production. No claim is made that the CPU copy's fb came from the state_dict (a non-persistent fb would come from the config rebuild; the smoke's exact parity check, which passed with max_abs 0.0, would show any difference).
- Measured memory peaks (job mem_peak): overlay build, 3 render workers, 10.1 GiB (w5-overlay-train, 36 min); hook smoke 5.4 GiB host. Later 3-worker render caps (14G) keep about 38 % headroom.
- Known limitation: with the hook installed, NeMo's transcribe cannot zero `featurizer.dither` or `pad_to` through `model.preprocessor`. This is harmless: dither applies only in training mode, Parakeet's pad_to is 0, and W0F's smoke through the real hook matched B on 20 of 20 mixtures.

## Profile-direction check (DESIGN section 8; w5-profilecheck, 2026-10-23)

20 held-out train speakers, 10 rendered dictations each (W3 bank renders),
W1 profile with redimnet2-b2, rule robust, norm raw.
- median cos(W1 profile, bank-style profile of the same 10) = 0.9658
  (range 0.950-0.977);
- median cos(bank profile of dictations 1-5, of 6-10) = 0.9628 (range
  0.897-0.981).
- Decision by the pre-registered rule: **use W3's bank** (0.9658 >= 0.9628).
  The margin is small (0.003). On this measure, the W1-vs-bank difference is
  about as large as the within-speaker spread the model is trained on. It is
  not smaller.
- Sanity: re-rendered dictations embed to cos >= 0.999997 with the stored bank
  rows, so the bank matches current W0 renders.
- Caveat (revised 2026-10-23 by the norm amendment in DESIGN, which
  supersedes the earlier wording): confirmatory profiles stay norm=raw
  whatever W1's Stage D selects. This check is repeated under asnorm only
  before any asnorm sensitivity evaluation, and that evaluation is
  exploratory.
- Known limitation (sol stepbudget-r1 B3, accepted): W0's code closure in the render and training identities covers `lfspk.harness.*` only, not `lfspk.api`, `lfspk.paths` or `lfspk.splits`. Those three files are frozen procedurally for the rest of the experiment (orchestrator).
- Known limitation (sol stepbudget-r1 B4, accepted): W0's index hashes do not pin RIR arrays or the speech and noise audio. The corpora under /mnt/hd are treated as immutable, and nothing in this experiment writes to them.

### Stage "step budget + identity fix" (sol stepbudget r1-r3, orchestrator-verified)

| round | reviewed | high | medium | low | outcome |
|---|---|---|---|---|---|
| r1 | step-budget amendment draft + identity proposal | 0 | 0 (A clean; B: B5 required, B2 required, B3/B4 accepted as limitations) | 0 | A committed 2d6f1dd; B3/B4 in 8d5dec0 |
| r2 | identity_fix_B5_B2.patch (sha c608ee91...5651) | 1 | 2 | 0 | all fixed in r2 patch (ccdcf823...9c53) |
| r3 | r1-to-r2 delta (ebdfbaa9...1287) | 0 | 1 | 0 | fixed in r3 patch; verified by the orchestrator, no r4 |

Applied: identity_fix_B5_B2.r3.patch, sha256
b12ea094f4ea396992adb72fdf5c5f9348533032dd7799b6dd92a628513e0398, on base 8d5dec0. It was applied
only after w5-stage0-report finished, and its SHA was verified before applying.
- r2 high: both render commands bound the manifest to the current identity. They now bind it to the persisted one.
- r2 medium: training resume rewrote the stored identity. It now keeps the checkpoint's identity.
- r2 medium: the integration tests were missing. Added: render resume for both commands, calibration consumption, training resume, and make().identity() with a replaced artefact at the same path.
- r3 medium: the implicit and explicit default W1 roots recorded different identities. The root is now resolved once and only that path is recorded.
- Orchestrator verification of r3: the delta sha matches; W1's factory defaults to RUNS/W1, so the resolved root reads the same files; test_W5_identities passes 10/10. Stage closed at the r3 patch. Applied here after verifying its sha; 107 W5 tests pass.

## Stage 0 (feasibility screen; held-out train speakers; DESIGN 9.0; accepted by the orchestrator 2026-10-23)

900 mixtures (150 per family S0, N, S1-S4), 48 held-out train speakers, Parakeet `base`, runs/W5/stage0/report.json.

- Stop rule not triggered:
  - (a) R(O2) = 14.3 % < R(W_o) = 29.6 %, pooled S1-S4.
  - (b) O2's pooled L+ = 0.49 %, 95 % CI [0.14, 1.25]. Neither condition of (b) holds.
- Parity: B* equals B exactly. 0 transcripts changed and dWER = 0 in every family.
- Baseline batching sensitivity: 0 transcripts changed, except S3, where 1 in 150 (0.67 %) changed.
- O2 (oracle T2 mask, raw C1) against B. R is relative to B; L+, G_u, net L and dWER are in points of target words.

| family | R | L+ | G_u | net L | dWER |
|---|---|---|---|---|---|
| S0 | n/a | 0 | 0 | 0 | 0 |
| N | n/a | 0 | 0 | 0 | 0 |
| S1 (62 interferer words) | 0.40 | 0.51 | 5.7 | -5.2 | -5.5 |
| S2 | 0.06 | 1.57 | 19.4 | -18.0 | -22.3 |
| S3 | 0.21 | 0.53 | 17.4 | -16.9 | -35.1 |
| S4 | 0.06 | 0.27 | 23.7 | -23.5 | -30.1 |

- W_o (oracle word filter, gross budget 0.5 %, tau 0.21): R(S1-S4) 0.30, of which 1.01 in overlap and 0.06 single; dWER_S0 +0.80 points.
- O1 (oracle T1 mask, noise removed too): R(S1-S4) 0.23, L+ 2.76 %.

Caveats:
1. O1 improves clean and noise-only speech: S0 dWER -0.56 points, N -2.19 points. DESIGN predicted that the trained T1 would not improve on B at SNR >= 5 dB. This is an oracle, not that prediction's test, but the headroom exists.
2. Guard regime: in 91-95 % of valid bins, g_min P < 100 eps. Among bins where the O2 mask is floored, 60-71 % are in that regime. A floored bin therefore mostly reads as the log guard (near digital silence), not as -30 dB, so the floor acts as a mute in most bins. On consistency: the training loss is on log m, the clipped raw power ratio, which has no guard term. The guard enters only where a mask is applied to features, and that application is identical in stage 0, the hook and apply(). The network's input X uses the same guarded features in training and inference.
3. O2's single-region R in S3 is 0.21, higher than in S2 and S4. Call-audio interferers remain partly audible under T2, plausibly because the laptop speaker sits close to the microphone. The numbers are small.
4. W_o's R in overlap can exceed 1.0 (S4: 1.03). After filtering, re-alignment makes a token that B attributed as a target substitution interferer-attributed. This is an accounting effect of the shared tmetrics definitions, not a bug.
5. These are held-out train speakers and raw oracle masks. Per DESIGN 9.0, they are not comparable to dev's 18.5 %.
- Measured resource peaks of w5-train-R1-s0 (resumed segment, 8 workers): host mem_peak 24.0 GiB, exactly the 24G cap; this probably includes page cache. The CPU-only stream check measured 14.5 GiB for main plus 8 workers.
- Measured VRAM peak of w5-train-R1-s0: 4.39 GiB, above its gpu:shared 4G lease (an under-declaration on a shared GPU). The 3-worker smoke measured 2.94 GiB.
- Lease change (resources, not design): R2-s0, R3-s0, R1-s1 and R1-s2 are requeued with mem 28G and gpu:shared 6G; everything else is unchanged.
- R1-s0 bypass threshold (held-out train, 500 clean S0 renders): theta_b = 0.934. Quantiles of max_t ubar are median 0.21, p90 0.77, p95 0.87 and p99 0.93; the smoothed interference output often runs high on clean speech. Design consequence, not a bug: C3 and C4 will be very conservative, bypassing any recording whose smoothed u never reaches 0.93.
- R1-s0 held-out monitor, mean squared log-mask error against the oracle T2 mask, in nats^2 (over / under): S0 0.0001 / 0.91; N 0.0003 / 0.14; S1 0.0004 / 1.33; S2 0.0012 / 5.99; S3 0.0028 / 1.53; S4 0.0010 / 5.70. Over-suppression of the target is essentially absent; under-suppression is large. The first run's u frame AUC was NaN: a label-format bug in calibrate.monitor, with a fix pending.
- Known limitation: the reviewed `calibrate.monitor` reports u_frame_auc as NaN. It passes boolean interference labels to W0's exact_auc_eer, which expects contract labels. A fix is verified-ready, with a test that fails before it: runs/W5/drafts/monitor_auc_fix.patch, sha256 609d4076b303caf428b3443ca96d3a878da572557c1270b4b3918b89ab5cd55f, against base 9525f30. It is deferred until every W5 dev evaluation has finished (orchestrator), because any lfspk/extract/*.py edit changes the front-end identity and the in-flight resume identities. Until then the frame AUC comes from the out-of-repo reference script runs/W5/drafts/monitor_reference.py, sha256 a076a87385083ea52204ebb2bb7821e5bfa3878bd5644926f78ab6c62cbd0ce1.
- Code freeze (orchestrator, 2026-10-23): no edits to lfspk/extract/*.py, lfspk/harness/*.py or lfspk/embed/*.py until the W5 dev evaluation is done.

## Supersession of the first R1-s0 (2026-10-23)

The first registered R1-s0 (sha256 prefix 87dc3765, registered in anchor
f46c010) was superseded in commit 353b618, by the owner's decision, before any
dev outcome existed. This is a post-hoc method amendment. It was decided after
held-out-train evidence and before any dev result.

What exists of it on dev:
- 770 stage-A masks of dev-v1 (builtin-clean-10), quarantined, unscored and
  uninspected, in runs/W5/masks_quarantine_R1-s0_20261023/ (QUARANTINE.json,
  listing sha256 prefix 37a2ee63).
- Two incomplete stage-A starts in W0F's ledger (run ids 270dfb61 and
  11e5a428).
- No stage-B event, no transcript and no metric, on dev or test.

Held-out-train evidence (48 held-out train speakers; runs/W5/notes/):
- Fraction of the oracle T2 mask's suppression reached:

  | run | S1 | S2 | S4 | S3 |
  |---|---|---|---|---|
  | R1-s0 | 4.5 % | 8.4 % | 5.3 % | 59 % |
  | R2-s0 (unconditioned) | 3.6 % | 7.4 % | 3.7 % | 59 % |

- The speaker profile therefore added about 1-2 points, and S3's suppression
  is channel-driven.
- R3-s0 (T1, the same head and loss) reaches 22-39 % in S1, S2 and S4.
- The mask head's pre-activations are saturated (sigma(z) > 0.99 in 78-99.8 %
  of bins).
- The training loss along the oracle direction shows large available gains.

The old R1-s0, R2-s0, R3-s0 and R1-s1 (step 11000) are exploratory. The fix is
a pre-registered screen (DESIGN amendment, under review; its sol trail is
logged when that review closes). Its winner is retrained as R1 seed 0 with
`recipe` = the winner, and is registered with a new REGISTER commit before any
dev use.

### Stage "fix amendment" (sol lfspk-W5-fix r1-r3, orchestrator-verified r4)

| round | reviewed | high | medium | low | outcome |
|---|---|---|---|---|---|
| r1 | amendment draft d17dade8 | 3 | 4 | 1 | all fixed (amendment r2, patch r2) |
| r2 | amendment r2 + patch r2 | 0 | 4 | 0 | all fixed (recipe field, explicit screen configs, production-path tests) |
| r3 | patch r2-to-r3 delta | 0 | 1 | 1 | fixed in patch r4: real-source stream test, keyed source cache, smoke refusal, recipe forwarding |
| r4 | patch r3-to-r4 delta | - | - | - | verified by the orchestrator (sha d0a62b46...c24c; 29/29 screen tests) |

Closed at amendment sha256 554608e1...aaa (DESIGN Amendments) and patch r4.
The frozen screen measurement is monitor_reference.v3.py, sha256 eae20c10...fffe2.

## Fix screen result (2026-10-23): none passes, so report and stop

The 8 pre-registered screen runs (6,500 steps each; DESIGN amendment
554608e1) were scored with the frozen monitor_reference.v3.py (sha256 prefix
eae20c10) on the held-out monitor set (render identity prefix 9f2143e9). The
gate table was computed by runs/W5/drafts/screen_gate_table.py (sha256 prefix
08d8db3b), with output in runs/W5/notes/screen_gate_table.json. Every score
was checked to name its run's final.pt sha256.

Gates on target-present groups. frac is the fraction of the oracle's
suppression reached; over is the mean over-suppression in nats^2; gain is
frac(S4) of V minus frac(S4) of its unconditioned twin.

| variant | frac S1 | frac S2 | frac S4 | frac S3 | max over (family) | S0 over / S0 q99 | gain S4 | gates 1/2/3/4 |
|---|---|---|---|---|---|---|---|---|
| V0 (control) | 0.029 | 0.044 | 0.029 | 0.539 | 0.0025 (S3) | 0.0001 / 0.0012 | 0.001 | F P P F |
| VA linear head | 0.005 | 0.004 | 0.003 | 0.547 | 0.0027 (S3) | 0.0001 / 0.0001 | 0.002 | F P P F |
| VB alpha = 3 | 0.312 | 0.439 | 0.386 | 0.810 | 0.0731 (S2) | 0.0069 / 0.107 | 0.049 | P P F F |
| VC p_absent 0.5 | 0.043 | 0.067 | 0.073 | 0.528 | 0.0144 (S3) | 0.0011 / 0.0123 | -0.005 | F P F F |

Twins' frac (S1/S2/S4/S3): V0u 0.026/0.040/0.027/0.548; VAu
0.001/0.001/0.001/0.542; VBu 0.297/0.425/0.338/0.798; VCu
0.067/0.101/0.078/0.562.

Absent-target frac (reported only; S0/N/S1/S2/S3/S4): V0
0.003/0.002/0.016/0.023/0.216/0.017; VA 0.000/0.000/0.000/0.002/0.207/0.000;
VB 0.314/0.328/0.161/0.302/0.471/0.470; VC 0.294/0.229/0.089/0.142/0.389/0.340.

Selection under the pre-registered order (VA, VB, VC): no variant passes
gates 1-4. Per the amendment, no combination and no further variant is tried,
no retrain is started, and no new confirmatory checkpoint is registered.

Observations (not used for selection):
- Only alpha = 3 (VB) moves suppression substantially (31-44 % in S1, S2 and
  S4). The cost is over-suppression of the user's speech, 7-24x the bound, and
  an S0 tail of 0.107 against 0.01.
- Its unconditioned twin VBu reaches almost the same (30-43 %). The identity
  gain on S4 is 0.049, just under 0.05, so the extra suppression is mostly
  not speaker extraction.
- VC moved mostly absent-target suppression (29-34 % in S0, N and S4), not
  present-target interference.
- VA's linear head made the mask even more conservative than V0's.
