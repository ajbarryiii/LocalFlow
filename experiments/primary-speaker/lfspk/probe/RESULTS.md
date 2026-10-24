# W2 results: Parakeet encoder speaker probe

Pre-registration: `DESIGN.md`. Every configuration run is listed here.

## Sol-loop log

| round | scope | high | medium | low | fixed | rejected |
|---|---|---|---|---|---|---|
| stage2-r1 | bb0e377 (stage 2 design + code) | 0 | 5 | 1 | 6 | 0 |
| stage2-r2 | bb0e377..762874a fix diff | 0 | 1 | 1 | 2 | 0 |
| stage2-r3 | 762874a..64e4c86 fix diff | 0 | 1 | 1 | 2 | 0 |
| stage2-r4 | 64e4c86..7fce750 fix diff | 0 | 4 | 0 | 2 | 2 |
| stage2-r5 | 7fce750..bdf14ba (r4 #3, #4 only) | 0 | 0 | 0 | 0 | 0 |
| stage3-r1 | d93eb08 (stage 3 design + code) | 0 | 3 | 0 | 3 | 0 |
| stage3-r2 | d93eb08..a3a8d82 fix diff | 0 | 0 | 0 | 0 | 0 |
| audiocache-r1 | 06283b4..083076f (stage-3 audio cache) | 2 | 2 | 0 | 4 | 0 |
| audiocache-r2 | 083076f..3ed5d24 fix diff | 0 | 1 | 0 | 1 | 0 |

stage2-r1 findings and responses (all accepted):
- M1 enrollment-only bootstrap misses test-speaker variability -> two-way
  speaker bootstrap (one draw serves both roles; non-target weight m_a m_b,
  target m_a), stratified by session class; same scheme (target x
  interferer) for stage-3 frames (`metrics.two_way`, `pair_weights`).
- M2 best-tap CIs ignore selection -> fixed dev halves S/E (stratified by
  sex); tap chosen on S, all headline comparisons and the stage-3 viability
  verdict on E; full-dev curves labelled exploratory; stage-3 dev mixtures
  never cross halves.
- M3 cross-chapter is not cross-session -> LibriVox project as session unit
  (CHAPTERS.TXT); dev enrollment/test chosen to maximise cross-project test
  material; subsets all / cross_chapter / cross_project; closed-set pairs
  prefer different projects and report cross- vs same-project; claim
  qualified; pre-registered channel-mismatch control (W2-colour-v1 on test
  segments, degradation vs TitaNet).
- M4 producer exception hangs extraction -> exceptions forwarded through the
  queue and re-raised (test).
- M5 invariance tolerance not enforced -> extraction fails above 1e-3 and
  `load_feats` refuses such feature sets (tests).
- L1 H3 lacks an equivalence margin -> 1.0 EER point margin with
  equivalent / different / inconclusive verdicts.

stage2-r2 findings and responses (both accepted):
- M non-finite singleton rerun could pass the invariance check (NaN dropped
  by max) -> `extract.invariance_rel` raises on any non-finite input or
  result (test).
- L empty session subset aborted the closed-set report -> NaN for an empty
  subset (`closedset.subset_accuracies`, test).
- Reviewer note: E had 10 cross-project speakers on the 40-speaker dev. The
  orchestrator then enlarged dev to dev-clean + dev-other (73 speakers,
  commit 86ef446); halves are now stratified by subset x sex x session
  (E: 19 cross-project speakers), and DESIGN states that the E
  cross-project subset is descriptive.

stage2-r3 findings and responses (both accepted):
- M smoke isolation compared path spelling -> `probe/guard.py`: resolved
  paths; smoke inputs and outputs refused when they resolve to, inside or
  above W2's production directories (`..` and `--out` cases tested); stage-3
  outputs from smoke features guarded too.
- L odd-strata alternation advanced on even strata -> toggles only on odd
  strata (test with sizes 1,2,1,2,1). New halves: S 36 (20/8/8), E 37
  (20/11/6).

stage2-r4 findings and responses:
- M1 (symlinked subdirectory of a scratch --out into production) and M2
  (production LFSPK_ART with feats symlinked to scratch smoke features):
  REJECTED (orchestrator decision). Reason: out of threat model; both need
  someone to deliberately plant symlinks inside our own artifact tree. The
  guard exists to prevent accidental smoke/production mixing, not
  adversarial filesystem manipulation. Stated in `guard.py`.
- M3 dev feature metadata omitted from the guard: ACCEPTED in its simple
  form: every entry point (stage3 train and fit-backends, verify, closedset)
  checks the metadata of every input feature set, train and dev, and refuses
  any smoke extraction unless `--smoke` is given (then outputs must be
  outside production) (`guard.check_inputs`; tests).
- M4 rejection after output mutation: ACCEPTED: all inputs are validated
  before any output is created or removed (stage3.train reordered; test that
  an existing run.json survives a refused run; verify writes nothing when
  refused).

Stage 2 total: 5 rounds; fixed 0 high, 11 medium (incl. 2 accepted from
r4), 3 low; 2 medium rejected (r4 #1, #2: out of threat model). Clean at
stage2-r5.

stage3-r1 findings and responses (all accepted):
- M padding reached valid scores through the head's temporal convolution
  -> `FrameHead.forward(..., lengths)` zeroes hidden padding before the
  conv; regression test with junk padding.
- M identity claim permits recording-channel matching -> dev scores store
  each target's session class; every stage-3 statistic and paired
  difference is also reported for cross-project targets; DESIGN 6.4 states
  the conclusion as "identity or recording channel" unless the
  cross-project block agrees.
- M AUC gate without a low-miss operating point -> metric
  `fa_at_miss1/2` (interferer-only frames kept at <= 1 % / 2 % target-frame
  miss) and gate (d): <= 50 % kept at 2 % miss and fewer than `uncond`
  (CI); verdict renamed "permission to continue to the harness".

Stage 3 total: 2 rounds; fixed 3 medium; none rejected. Clean at stage3-r2
(reviewer also checked the operating point picks the best FA within the miss
budget, not the first point reaching it).

audiocache-r1 findings and responses (all accepted; W4's generation pattern):
- H audio SHA-256 never verified -> `AudioCache.verify()` hashes every byte
  (it doubles as the page-cache warm-up) and `load` refuses before it.
- H unsafe concurrent builds/publication -> immutable content-addressed
  `gen-<id>/` built in a private mkdtemp directory, published by one rename,
  CURRENT replaced atomically; readers pin a generation; id = hash of audio
  and index hashes, re-checked on open.
- M unchecked index -> index hash checked against meta; every entry
  bounds-checked; entries must tile the audio exactly; utterance-set hash
  checked.
- M stale selections / silent FLAC fallback -> the cache is built from the
  stage-2 feature manifest; stage 3 requires both caches, checks their
  utterance sets exactly against the manifests it trains from, verifies them
  before touching any output, and has no FLAC fallback (missing entry ->
  KeyError).
Smoke: step-0 losses identical to the FLAC path (0.6811 / 0.6862).
audiocache-r2: M dev cache job lacked its dev-extraction dependency ->
`--after w2-s3-cache-train,w2-x-base-dev` (one-line job-graph fix, verified
by the orchestrator; no round 3). Audio cache total: 2 rounds; fixed 2 high,
3 medium; none rejected.

Changes outside review findings before any real run: W2-simplemix v1 -> v2
(turn-taking mode; v1 smoke dev had only 8 % interferer-only frames);
smoke-only `--max-speakers` mode that loads only under a scratch LFSPK_ART.

## Runs

All on the 73-speaker dev (dev-clean + dev-other). W2 code for stage 2: commit
9084d2a (`lfspk/probe/run_stage2.sh`, relaunched with `--skip-base` after the
/mnt/hd I/O stall; no probe code that stage 2 runs changed in between).
Jobs: w2-x-{base,m1,tn}-{train,dev,dev-colour}, w2-v-{base,m1,tn},
w2-report, w2-closedset. Features under runs/W2/feats/ (meta.json per set:
items, crop fallbacks (train 16, dev 12), batch-invariance max relative
difference <= 9e-8 everywhere, TF32 off). Report:
runs/W2/verify/report.json and report.md (1000 two-way stratified
resamples, seed 20261021); closed set: runs/W2/closedset/report.json.

### Stage 2 headline (half E, tap chosen on half S)

Selected tap on S, by EER at 2 s: **base: tap 7**, m1: tap 8.
EER % [95 % CI], half E (37 speakers), all trials:

| system | 1 s | 2 s | full | minDCF 2 s |
|---|---|---|---|---|
| Parakeet base, tap 7 | 6.22 [4.16, 8.48] | 3.37 [1.79, 5.02] | 2.40 [1.14, 3.67] | 0.34 [0.20, 0.46] |
| Parakeet m1 (shipped), tap 7 | 6.49 [4.14, 9.12] | 3.86 [1.95, 5.78] | 3.45 [1.77, 4.99] | 0.44 |
| Parakeet m1, tap 8 (m1's own S choice) | 7.25 | 4.02 [2.29, 6.10] | 3.42 | 0.53 |
| Parakeet base, tap 24 (final output) | 38.85 | 34.92 [32.48, 37.48] | 26.78 | 1.00 |
| TitaNet-small, raw cosine | 2.24 [1.19, 3.25] | 1.45 [0.49, 2.55] | 0.92 [0.33, 1.52] | 0.15 |
| TitaNet-small, same LDA back end | 3.02 | 1.64 | 1.33 | 0.15 |
| log-mel mean+std (floor) | 13.14 | 12.68 [8.48, 17.02] | 12.47 | 0.82 |

Layer curve, EER % at 2 s on E, taps 0..24:
- base: 9.1 8.2 7.0 5.8 4.3 3.6 3.1 3.4 4.4 5.0 7.7 11.7 16.4 20.5 21.6 22.3 21.3 18.7 18.7 20.2 24.1 27.2 30.2 32.3 34.9
- m1: 8.6 7.9 6.7 6.0 4.8 4.3 3.9 3.9 4.0 5.5 7.1 10.3 13.6 17.4 19.2 20.5 20.0 18.1 18.2 19.5 22.3 26.1 28.3 30.0 32.5
(S shows the same shape; full-dev curves in report.md are exploratory.)

Paired differences on E (EER points, base tap 7 minus X): vs TitaNet raw
+3.98 [2.36, 5.79] at 1 s, +1.92 [0.85, 2.94] at 2 s, +1.48 [0.52, 2.63]
full; vs log-mel -9.32 [-13.43, -5.33] at 2 s. Cross-project speakers at 2 s:
tap 7 5.07 [2.42, 7.57] vs TitaNet 2.12; difference +2.94 [1.27, 4.60].
Same-sex non-targets at 2 s: tap 7 4.62, TitaNet 1.82.

H3 (m1 vs base at tap 7, E, 2 s, margin 1 point): **inconclusive**,
difference +0.49 [-0.33, +1.50] points (at full length m1 is worse:
+1.05 [0.22, 1.80]). Ternary QAT keeps the layer profile and the peak
region (taps 6-8); a small loss cannot be excluded.

Channel control (W2-colour-v1 on test segments), E: tap 7 degrades by
+1.08 [0.18, 2.17] EER points at 2 s (1 s +1.43, full +1.01); TitaNet raw
by +0.46 [0.09, 1.05] at 2 s (full -0.01); difference of degradations
+0.62 [-0.41, 1.67] at 2 s, +1.01 [0.23, 1.66] at full length. The log-mel
floor nearly doubles (12.7 -> 23.5). Tap 7 relies somewhat more on channel
than TitaNet, clearly less than raw spectra.

Closed-set identification (200 train speakers, chapter A -> chapter B),
accuracy % [CI], full / 2 s: base tap 7 96.9 / 82.3 (cross-project speakers
94.2 / 76.7, same-project 99.2 / 86.9); tap 6 97.0 / 87.1; tap 0 85.7 / 56.0;
tap 12 61.9 / 11.0; tap 24 21.1 / 3.3 (cross-project 5.7 / 1.2); m1 tap 7
96.1 / 70.1; log-mel 70.8 / 57.9; TitaNet 99.7 / 97.9. The same-project vs
cross-project gap grows in the upper layers (tap 24 full: 34.1 vs 5.7), so
what identity survives up there is largely channel.

Pre-stated hypotheses: H1 confirmed (peak at taps 6-8, about a quarter to a
third up; collapse above 10; final output near chance for verification).
H2 confirmed (best tap worse than TitaNet-small at every length, far better
than log-mel; "competitive" (<= 1.5x TitaNet at 2 s) is NOT met: 3.37 vs
1.45, 2.3x). H3 inconclusive (above).

### Stage 4: deployment cost of reading tap 7 (analysis; nothing measured on device)

Which weights ship: one ternary export (`main-M1-P2-lr5e-4` step 250000,
SHA-256 a287e977...1503; hash checked on this machine) on all three
platforms: macOS and iOS as a Core ML C6s8 multifunction encoder (ternary
LUTs, FP16 activations), Linux as `lf-cpu` kernels (FP32 or residual-INT8
activations). W2's `m1` numbers use that export dequantised, with FP32
arithmetic; the FP16/INT8 activation effect was not measured.

- macOS / iOS (same bundle): the encoder exposes only the final output
  (`encoder`, [1, 1024, T]), and tap 24 carries almost no identity (34.9 %
  EER at 2 s). Reading tap 7 needs a re-export. The encoder graph is built
  by hand in MIL (wilderness-labs-stt `finetune/parakeet-ternary/ios/mil/encoder.py`,
  `forward`: `for i in range(P.n_layers): x = _layer(...)`), so a second
  output is a few lines: keep `x` after i = 6 and return
  `mb.cast(mb.transpose(x, [0, 2, 1]), "fp32", name="tap7")` from every
  function (the bundle now ships b15 only). Extra output: 1024 x T values
  (T = 188 frames for 15 s): 0.77 MB as FP32, 0.38 MB as FP16. Unknown until
  measured on the Mac: whether exposing an intermediate splits the
  Neural-Engine program (the current plan places 1379 of 1385 ops on the
  ANE; `mil/computeplan.swift` reports placement), and the latency cost.
  A re-export changes the bundle hash, so every user goes through model
  preparation again (about 100 s on first use). Proposed check, if stage 3
  passes: build b15 with and without the extra output, then compare the
  compute plans and the warm latency on the M1 Pro.
- Linux: `linux/crates/lf-asr/src/encoder.rs` `run_layers` runs the layers
  in a Rust loop; copying `buf.x` (T x 1024 f32) after `li == 6` costs one
  memcpy (0.77 MB per 15 s).
- Head: 0.69 M parameters; about 0.59 M MACs per 80 ms frame (7.4 M MACs
  per second of audio). Profile: mean+std pooling of tap 7 plus a
  2048 x 200 LDA projection per dictation (0.4 M MACs), stored as 200
  values.

### Stage 3 results (W2-simplemix-v2, probe evidence only; not the harness)

Runs: w2-s3-{m1,base}-s{1,2,3} (code 34bf905; lease 11G VRAM / 22G host
after a kill at 9G and an OOM at 16G, see run_stage3.sh), w2-s3-report ->
runs/W2/frames/report.json. 1427 dev mixtures, 6000 steps x 32 mixtures per
run, 3 seeds per weights; statistics are seed means inside each two-way
(target x interferer speaker) bootstrap, 1000 resamples; seeds agree to
+-0.001 AUC. Tap selected on S by conditioned AUC: m1 tap 5, base tap 6.

Half E, target-present vs interferer-only frames, all mixtures:

| head | AUC [95 % CI] | interferer frames kept at <= 2 % target miss |
|---|---|---|
| m1 tap 5, conditioned | 0.973 [0.959, 0.983] | 0.184 [0.126, 0.261] |
| m1 tap 5, unconditioned | 0.949 [0.927, 0.965] | 0.351 [0.262, 0.459] |
| base tap 6, conditioned | 0.974 [0.960, 0.984] | 0.189 [0.126, 0.284] |
| base tap 6, unconditioned | 0.958 [0.939, 0.971] | 0.311 [0.223, 0.413] |
| log-mel input, conditioned | 0.895 [0.863, 0.920] | 0.555 [0.427, 0.764] |
| log-mel input, unconditioned | 0.789 [0.761, 0.818] | 0.801 [0.737, 0.863] |
| m1 tap 24 (final output), conditioned | 0.849 [0.825, 0.871] | 0.684 [0.611, 0.751] |

Gate (DESIGN 6.4, m1 tap 5 on E): (a) cond - uncond AUC +0.024 [0.011,
0.043], below the 0.05 bar -> FAIL; (b) cond - log-mel +0.079 [0.057,
0.105] pass; (c) AUC 0.973 pass; (d) 18.4 % kept at 2 % miss (<= 50 %) and
cond - uncond -0.166 [-0.247, -0.093] pass. **Verdict: no permission to
continue to the harness under the pre-registered rule** (base: same, (a)
+0.016 [0.006, 0.033]). Cross-project targets give the same picture
(m1: +0.026 [0.011, 0.048] AUC, -0.152 FA), so the profile's contribution is
not a recording-chain match. Same-sex mixtures: +0.022 [0.006, 0.046].
Conditioned AUC by tap peaks at 4-7 and falls to 0.85 at tap 24; the
profile's contribution is largest at tap 0 (+0.087) and shrinks with depth.

Post-hoc dominance check (NOT pre-registered; `lfspk/probe/dominance.py`,
runs/W2/frames/dominance.json). In W2-simplemix the target is a whole
utterance and the interferer a 30-100 % segment, so "who talks most" names
the target without a voiceprint. Split of E mixtures by interferer-active /
target-active frames (threshold 0.7, chosen before looking; 33 % of
mixtures are "balanced", S4-like):

| m1 tap 5, E | mixtures | cond AUC | uncond AUC | cond - uncond AUC | FA@2 % cond / uncond |
|---|---|---|---|---|---|
| balanced (ratio >= 0.7) | 228 | 0.948 [0.905, 0.973] | 0.829 [0.747, 0.888] | +0.119 [0.062, 0.189] | 0.32 / 0.75 (diff -0.43 [-0.59, -0.20]) |
| dominant target (< 0.7) | 485 | 0.983 | 0.982 | +0.001 [-0.002, 0.005] | 0.13 / 0.14 |

(base tap 6: balanced +0.089 [0.042, 0.162], FA 0.36 / 0.67; dominant
+0.000.) The unconditioned head's strength, and therefore the gate (a)
failure, comes from dominant-target mixtures; where both talk comparably (the
second-dictator case) the voiceprint carries the decision. This is the
confound flagged earlier; the pre-registered verdict stands as recorded, and
the balanced split is the argument for a harness re-test, not a passed gate.

### Status and recommended next experiment

W2 CLOSED (2026-10-22). The harness re-test is deferred by the orchestrator:
W5 (target-speech extraction) has priority, and every word-level filter is
bounded by the oracle frame-label ceiling (about 18.5 % of interferer words
kept on dev), which W5's oracle beats by a wide margin.

If a word filter ships, the next experiment is an exploratory harness
comparison. It is not a gate: the pre-registered stage-3 gate failed.
- Scorer: `ParakeetLayerScorer` (DESIGN 8) reading m1 tap 5 and the 3-seed
  frame head. The profile is a running mean of per-dictation tap-5 LDA
  embeddings, with a cosine update gate set on train mixtures;
  `reads_parakeet_layers = (5,)`.
- Data: W0's frozen dev set, scored on half B. Primary is S4 (second
  dictator), reported with S0 as the guardrail and S1-S3 alongside, at 3, 10
  and 30 enrollment dictations, with clean and contaminated enrollment.
- Comparison: the harness's interferer-words-kept at the 0.5 % budget,
  against W1's best embedder and W3's personal VAD under identical tau
  calibration. Report the result split by the dominance ratio (as in
  `dominance.py`).
- Cost: reusing Parakeet compute only pays off if the scorer comes within
  the CIs of W1/W3. If it does, the Core ML re-export with a tap-5 output is
  measured on the M1 Pro: compute plan and warm latency of b15 with and
  without the extra output.
