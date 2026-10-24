# W1 design: pretrained speaker embeddings plus an adaptive profile

Status: pre-registration, written before any number was seen (2026-10-21).
Changes after the first sol round are listed at the bottom with dates.

## Question

Can a small, pretrained, frozen speaker-embedding model, a profile that is a
robust running summary of the user's own dictations, cohort score
normalisation and a tiny calibration head drop other people's words from a
LocalFlow dictation at the contract's 0.5 % target-word budget, at negligible
on-device cost and with no on-device gradient training?

## Hypotheses and decision rules

Every comparison below is a paired difference (same speakers, same bootstrap
replicates; joint speaker bootstrap, 1000 resamples) with a 95 % CI, judged
against a margin fixed here, before any result. Each has three outcomes:
*supported*, *refuted*, or *inconclusive* (the CI straddles the margin), and
inconclusive results are reported as such, never rounded to either side.
"Operating point" means the impostor pass rate at a 1 % target-segment miss
rate (`fpr@fnr0.01`; also reported at 0.5 %), the segment-level analogue of
the contract's target-word budget. EER is reported alongside but never used
alone to drop a candidate (a low-EER system can still pass most impostors at
the budget).

H1. Embedder survey (dev, no added noise; k = 10; raw cosine). Errors rise
steeply below 1 s. Decision rule for W1's viability as a stand-alone word
filter: if every embedder passes more than 50 % of impostor 1.5 s segments at
1 % target miss (CI lower bound above 50 %), window embeddings are too weak at
word resolution, and W1 becomes a conditioning input for W3 instead of a
scorer (*refuted*). If some embedder's CI upper bound is below 50 %, W1
proceeds (*supported*); otherwise *inconclusive*, and W1 proceeds to the
scenario evaluation, which decides. Size claim: the smallest credible model
(ReDimNet2-B0, 1.1 M) is non-inferior to TitaNet-small if the paired
difference in operating point at 1.5 s has a CI upper bound below +10 points
(absolute); *inferior* if the lower bound is above +10; else inconclusive.

H2. Normalisation (k = 10, all speakers, K = 200 fixed in advance). AS-norm vs
raw cosine, paired EER and operating-point differences at 0.5, 1.0, 1.5 s.
*Supported* (AS-norm helps) if the CI is entirely below 0 at one length or
more and above 0 at none; *refuted* (it hurts) if the CI is entirely above 0 at
one length or more; otherwise inconclusive, and then the product does not ship
a cohort (simpler wins ties).

H3. Profile size (raw cosine, 1.0 and 1.5 s). k = 10 vs 3: improvement if the
EER difference CI is entirely below 0. k = 30 vs 10: *flat* (equivalent) if the
CI lies within +-0.5 EER points; *still improving* if the CI is entirely below
-0.5; else inconclusive.

H4. Contamination (Stage C, W0 enrollment streams with 20 % of dictations
contaminated, S4-like). For each update rule, paired difference of EER (all
impostors, 1.5 s windows) between contaminated and clean streams at k = 10
and 30. A rule is *robust* if the CI upper bound is below +0.5 points
(non-inferiority margin, about 10-15 % relative at the expected EER), *harmed*
if the lower bound is above +0.5, else inconclusive. Prediction: robust and gated rules are robust; naive may not be.

H5. Poisoning (Stage C; a same-sex, and separately a cross-sex, second
speaker supplies 30 % or 50 % of the 27 updates). Primary outcome: spouse EER
(user's windows vs the second speaker's) at k = 30, paired against the
clean-update condition. A rule *resists* poisoning at a fraction if the CI
upper bound of the difference is below +1 point; it is *poisoned* if the lower
bound is above +1 point; else inconclusive. Also reported: fraction of the
second speaker's dictations accepted, and the profile's cosine to each
speaker's held-out centroid. Prediction: naive is poisoned at 30 %; gated and
robust resist at 30 %.
H5-long (capture of a mature profile, the shared-account case over months).
After 300 clean dictations, 300 more in which 10, 30 or 50 % come from a
same-sex second speaker, and separately a burst of 20 consecutive
second-speaker dictations. Primary outcome: spouse EER at dictation 600 (and
320 for the burst), paired against the clean 600-dictation stream, same
margins as H5 (+1 point). Prediction: gated and robust are captured at 30-50 %
over this horizon (a capped rate never forgets an accepted voice), anchored
resists. *If no rule resists at 30 %*, the recommendation is that LocalFlow
must not adapt from unverified dictations on shared accounts (explicit
enrollment only, or adaptation only above a strict gate), stated plainly.
H5-change (the cost of resisting: following the genuine user). (a) Session
change: 300 dictations from one LibriVox project of the speaker, then 300
from another project (a new microphone or room in practice), paired against a
control that shares the exact first 300 and continues in the first project.
Session dictations are extra renders of the speaker's utterances outside the
test chapter; a speaker qualifies with at least 15 distinct dictations in
each of two projects (at most 40 used), and the number of qualifying speakers
is reported (too few is itself a result). (b) Device change: the
600-dictation clean stream with the headset colouring after dictation 300,
paired against the built-in stream, both evaluated on headset-coloured
targets. Outcomes: genuine acceptance per block of 50 dictations; the ratio of
last-block to pre-change-block acceptance with a speaker-bootstrap CI; the
paired last-block acceptance difference against the control; and EER at 400
and 600 paired against the control. A rule *follows* the change if the
ratio's CI lower bound is at least 0.8; it *locks out* the user if the CI
upper bound is below 0.5; else inconclusive. If anchored locks out the
genuine user, that is reported plainly as a negative result and points to a
product design (re-enrollment prompts, per-route anchors) rather than to the
anchored rule as is. All long-horizon results are *replay dynamics over a
few distinct dictations* (27 updates, or 15-40 per project) cycled to 600;
months of fresh acoustic variation are untested, and every conclusion is
stated with that limit.

H6. Scenario performance (W0 harness, dev scenario set, contract metrics at
the 0.5 % budget). Primary: interferer words kept, paired difference best W1
scorer minus the energy-only baseline, per scenario. *Supported* in a scenario
if the CI is entirely below 0; *no gain* if it includes 0. The S0 guardrail is
the contract's (WER increase below 0.1 points). Prediction: gains in S1, S3
and S4 non-overlap; little gain in overlap regions (a window containing the
user must score high), so a large S4 overlap gain would surprise us.

H7. Calibration head. Full-feature head vs the score-only head (a logistic
map of the normalised score), paired difference in interferer words kept at
the budget, pooled and per scenario. *Supported* if the pooled CI is entirely
below 0; *refuted* (the head hurts) if entirely above 0; else inconclusive,
and the score-only head is recommended (simpler wins ties).

## Candidates (all public weights; licences in RESULTS.md and PROVENANCE.md)

All candidates are served through the shared interface
`lfspk/embed/embedder.py` (`load_embedder(name)`, reviewed separately; W3 and
W4 use it too). Registered names:

| name | model | params (embedding path) | weights licence | training data |
|---|---|---|---|---|
| titanet-s | NeMo TitaNet-small | 6.8 M | NeMo/NGC (Apache-2.0 per catalog) | VoxCeleb1/2, Fisher, Switchboard, LibriSpeech, RIR |
| titanet-l | NeMo TitaNet-large (upper bound) | about 23 M | CC-BY-4.0 | as above plus SRE 2004-10 |
| ecapa-vox | SpeechBrain ECAPA-TDNN | 20.8 M | Apache-2.0 | VoxCeleb1+2 |
| wespeaker-r34lm | WeSpeaker ResNet34-LM (PyTorch; ONNX export as cross-check) | 6.6 M | CC-BY-4.0 | VoxCeleb2 dev |
| wespeaker-campp | WeSpeaker CAM++ (PyTorch; ONNX cross-check) | 7.2 M | Apache-2.0 | VoxCeleb2 dev |
| redimnet2-b0 | ReDimNet2-B0 vox2-LM (smallest credible) | 1.1 M | MIT | VoxCeleb2 dev |
| redimnet2-b2 | ReDimNet2-B2 vox2-LM | 3.7 M | MIT | VoxCeleb2 dev |

Known confound: TitaNet's training data includes LibriSpeech (subsets not
stated on the model card; presumably the training subsets, which are speaker
disjoint from dev and test, but that is not established). Dev speakers are
probably unseen; this stays flagged unconditionally. The domain
(read audiobook speech) is matched for TitaNet and not for the VoxCeleb-only
models, so TitaNet's advantage on LibriSpeech may overstate its advantage on
real dictation, and train-clean-360 speakers (our cohort and head-training
pool) may have been seen by TitaNet. A cohort or calibration head fitted on
train-360 with TitaNet features may then behave differently on unseen
speakers. A descriptive diagnostic only (`survey.seen_speaker_check`): the
mean within-speaker cosine of two same-chapter utterances for train-clean-360
cohort speakers minus the same for dev-clean speakers (quality-matched), with
a bootstrap CI, for every embedder. It cannot establish or exclude training
overlap (recording differences and model robustness also move it); a TitaNet
gap much larger than the VoxCeleb-only models' gaps would be suggestive and
reported, nothing more. The fit/cohort speaker split (Stage B) removes the
separate, certain mismatch of a fitted speaker appearing in its own cohort.

Licence flags: VoxCeleb audio is YouTube content released for research; Fisher,
Switchboard and SRE are LDC corpora. The weight licences are permissive, but
commercial use of weights trained on these corpora carries a data-licence
question for the owner, flagged in RESULTS.md.

Cost for each candidate: parameters on the embedding path (classifier heads
excluded), MACs per second of audio (counted with
`torch.utils.flop_counter.FlopCounterMode`, MACs = FLOPs / 2, on the trunk
after the acoustic front end, at 1.0 s and 1.5 s), CPU latency on this host
(x86, 1 and 4 threads, median of 20 runs on 1.0 s and 1.5 s inputs, front end
included; a proxy, not Apple silicon), and Core ML friendliness: the trunk is
traced and converted to an ML program (macOS 14, float16) with coremltools 9
on Linux, and the MIL op inventory is recorded. Conversion on Linux shows op
support only, not Neural Engine placement or speed. coremltools 9 is untested
with torch 2.11 and needs a one-line numpy-compatibility shim for constant
casts (`cost._patch_coremltools_cast`); a conversion failure is therefore
reported with its error, not read as proof that the model cannot run in Core ML.

## Stage A: intrinsic survey (dev = dev-clean + dev-other, no added noise)

Protocol (`lfspk/embed/protocol.py`, deterministic). A LibriSpeech chapter is
not a recording session: chapters of one LibriVox project probably share a
microphone and room (CHAPTERS.TXT), so session separation is by project.
- Speakers: the 73 dev speakers (40 dev-clean, 33 dev-other; the dev split
  was widened by the orchestrator before any real run). Utterances sorted by
  (chapter, utterance id).
- Speakers with two or more projects (40): test pool = the project of the
  speaker's last chapter, enrollment pool = the other projects
  (`cross_project`). Several chapters of one project (19): test pool = the
  last chapter (`same_project`). One chapter (14): enrollment = first 30
  utterances, test = the rest (`same_chapter`). Results are reported for all
  speakers and per relation; only `cross_project` is read as session
  independent, and even it is not channel independent in any controlled way.
- Enrollment pools hold at most 30 utterances; a few are shorter (smallest:
  5, 8, 9). k = 10 and 30 use whatever the pool has, and the counts are
  recorded. dev-clean and dev-other are also reported separately.
- Dev halves: W0's canonical halves (`lfspk.harness.halves`, stratified by
  sex and session class), shared by all workstreams. Anything chosen on dev (the two embedders carried into
  Stage B, window length and hop, gates, head features) is chosen on half A;
  half B gives the selection-free estimate, and full-dev numbers for selected
  configurations are labelled exploratory (CONTRACT: selection-aware CIs).
- Profile from the first k pool utterances, k in {1, 3, 10, 30} (if a pool has
  fewer than k, all of it; actual counts reported). Profile = normalised mean of
  L2-normalised full-utterance embeddings.
- Test segments: for each test utterance and each length in {0.5, 1.0, 1.5,
  2.0} s, one segment at a seeded start drawn uniformly among the 10 ms-aligned
  starts whose speech fraction is at least 0.5 under the energy gate without
  its p95 cap (if none qualifies, the most speech-dense start, counted as a
  placement fallback and reported);
  plus the full utterance. Seeds 0, 1, 2; every seed is reported.
- Trials: every test segment against every dev profile (1 target : 39
  non-target). Same-sex non-target trials reported separately (the spouse
  case). Relation subsets restrict the enrolled speaker (impostors stay all
  dev speakers); halves and the clean/other subsets restrict both sides.
- Metrics: EER and minDCF (P_target 0.01 and 0.05, C_miss = C_fa = 1). 95 %
  CIs by a joint speaker bootstrap (1000 resamples, `metrics.py`): one speaker
  set per resample; a target trial counts with its speaker's multiplicity m,
  a non-target trial between enrolled A and test B with m_A * m_B, and copies
  of one speaker are never paired as impostors. All systems share the same
  resamples, so paired differences are valid.
- Primary comparison (pre-stated): EER at 1.0 s, k = 10, all non-targets,
  raw cosine, per embedder, all 73 dev speakers. Every embedder is reported, so
  this table involves no selection. Everything else is secondary.
- Normalisation: raw cosine, s-norm, AS-norm (top-K in {50, 100, 200, 400}).
  K = 200 is fixed in advance for the CI tables and paired comparisons; the
  other K values are point estimates, labelled exploratory.
  Cohort: train speakers are split once by a stable hash into a *cohort*
  half (about 460 speakers) and a *fit* half (`protocol.cohort_role`). The
  cohort is 2 utterances of each cohort-half speaker, embedded both as full
  utterances and as seeded segments of each test length (length-matched vs
  full-utterance cohort is reported). The fit half alone trains the head and
  calibrates the gates, so no fitted speaker is ever in its own cohort (on
  dev that cannot happen either). The shipped cohort is this cohort half.
- Shortlist for Stage B (selection on half A, pre-stated): rank embedders by
  the half-A operating point (`fpr@fnr0.01`) at 1.5 s, k = 10, raw cosine.
  Carry forward the best two and, regardless of rank, the smallest
  (redimnet2-b0); if the half-A EER ranking puts a different embedder first,
  carry it too (at most four). Their half-B numbers are the selection-free
  estimates; their full-dev numbers are labelled exploratory.

Stage A2 (robustness, needs W0's mixing API): repeat the primary comparison on
dev segments with noise and reverberation from W0's mixing functions at the
scenario SNR ranges.

## Stage B: frame scorer (`EmbeddingScorer`, `scorer.py`)

1. Speech activity: the adaptive energy gate of `audio.speech_gate` (floor =
   10th percentile of frame energy; threshold = max(-70 dBFS, min(max(floor +
   10, p95 - 40), p95 - 6)) dB; 3-frame hangover). The p95 - 6 dB cap keeps
   pause-free speech from being gated away; uniform noise is then marked as
   speech, which an energy gate cannot avoid.
2. Windows of length L in {1.0, 1.5} s with hop H in {0.25, 0.5} s over the
   whole recording (plus one window ending at the last sample); windows with
   speech fraction below 0.3 are not embedded. Recordings no longer than L give
   one window over everything; shorter than 0.2 s, none.
3. Window score: max over profile centroids of the cosine to the centroid's
   direction, raw or AS-norm (K = 200; profile side against the full-utterance
   cohort, window side against the cohort at the window length).
4. Frame features: Hann-weighted mean of the scores of windows covering the
   frame (uncovered frames get the recording's lowest window score, or a fixed
   fallback if none was embedded), raw cosine likewise, local max and min of
   covering windows, coverage flag, frame energy relative to the recording's
   95th percentile, frame SNR over the noise floor, gate flag, and the
   recording's mean and max window score.
5. Heads: the *score-only* head (logistic map of the window score) and the
   *full* head (logistic regression on all features). Positive labels are
   frames 1 and 3, negatives 0 and 2. Both are fitted on fit-half train
   mixtures from W0's `MixtureSampler` (targets and interferers from fit-half
   speakers, enrollment from `with_enrollment`; 3000 mixtures, rendered once
   for all shortlisted embedders and scoring windows). The L2 strength is
   fixed at C = 1 (millions of training frames make it immaterial; not
   selected). Choices among L, H, normalisation and feature set are made on
   dev half A; half B is reported.
6. Pre-stated configurations (all reported): {shortlisted embedders} x
   {L = 1.0, 1.5} x {H = 0.25, 0.5} x {raw, AS-norm} x {score-only, full head}.
   Cost grows as 1 / H forward passes of an L-second window per second of
   audio, so H = 0.5 is the cheaper point on the frontier.
7. Enrollment and updates always use 1.5 s windows every 0.25 s (the update
   window), whatever the scoring window: they run in the background, and one
   set of gates calibrated on that window then serves every scoring
   configuration. AS-norm uses the cohort embedded at the matching length on
   each side (scoring length for scores, 1.5 s for update decisions).

## Stage C: profile and adaptation

Profile bytes (little endian, `lfspk/embed/profile.py`, format version 2,
recorded in NOTES): magic `LFW1`, version, embedder code, dimension, centroid
count, flags, uint16 dictations seen and accepted (saturating at 65535, per
W4), then per centroid a uint16 count n and the float32 *unnormalised running
mean* m of the unit dictation embeddings folded into it, then, for the
anchored rule only, the float32 unit anchor (the enrollment direction). This
is the state W4 analyses (mean plus count; float32 because float16 dropped
small updates at large n). It keeps the naive running mean exact across
persisted updates (m' = m + (d - m) / (n + 1)) up to float32 rounding, until
the count saturates. Scoring uses m / |m|. A 192-dimensional single-centroid
profile is 784 bytes, 1552 with an anchor. Load-time invariants (flags,
counts, norms) are checked. No audio, no per-dictation embeddings, no second
moments, no per-user calibration. One centroid: the scorer API has no
microphone-route argument, so per-route centroids are out of scope (they
would need a contract change).

A dictation's embedding d is the normalised mean of its embedded windows
(naive) or of its kept windows (gated, robust, anchored).

Update rules (all reported):
- naive: every dictation with speech, m <- m + (d - m) / (n + 1).
- gated: window scores against the profile; windows below the window gate are
  dropped; the dictation is accepted only if at least half of its windows
  remain and their mean score reaches the dictation gate; then
  m <- m + (d - m) / (min(n, 50) + 1).
- robust: gated updates plus robust enrollment (windows of the k first
  dictations trimmed against their spherical median, below median - 3 MAD;
  each dictation's d from its kept windows).
- anchored: robust, plus a fixed anchor (the enrollment direction, stored in
  the profile). A dictation is also rejected if cos(d, anchor) is below the
  anchor gate, or if accepting it would move the profile direction below the
  drift floor in cosine to the anchor. It bounds how far any voice can pull
  the profile, at the price of not following genuine long-term change (a new
  microphone, a cold) beyond the floor.
- Per-route centroids (K > 1): pre-registered trigger. If, at k = 10 with
  clean enrollment, W0's mismatched-device condition keeps more interferer
  words than the matched condition at the 0.5 % budget by more than 5 points
  absolute (paired CI lower bound above 0 and point estimate above 5), or
  removes more target words by more than 0.25 points, W1 proposes an optional
  route argument on enroll/update/score to the orchestrator, with per-route
  centroids. Otherwise K = 1.
Gates are calibrated on fit-half train speakers only (`adapt calibrate`,
`gates_<norm>.json`, validated against the embedder, norm, window and
min_kept it was fitted for): window gate = the score reached by 10 % of
same-sex impostor windows; dictation gate = the threshold at which 1 % of all
same-sex impostor dictations pass the complete acceptance rule (min_kept
included); anchor gate = the raw cosine to the anchor reached by 1 % of
same-sex impostor dictations; drift floor = the 1st percentile over train
speakers of the lowest cosine between a clean gated profile and its anchor
along a 300-dictation train stream (the 27 cached updates cycled: the
longest horizon available on train, stated with the results). Achieved own
and impostor pass rates are computed through the updater's own decision
function, so calibration and updates agree to the last bit.

Experiments (`adapt.py`, dev speakers, W0's speaker plans and enrollment
streams rendered by W0's generator: clean S0-like dictations, the plan's
contaminated positions rendered S4-like, and the plan's 10 test targets
rendered as S0): growth at 3/10/30 dictations; the 20 %-contaminated stream;
poisoning with 30 % and 50 % of the 27 updates replaced by a same-sex (and,
separately, cross-sex) second speaker's dictations at seeded positions (the
second speaker is drawn from the same dev half); and the long-horizon
conditions of H5-long, built by cycling each speaker's 27 cached update
dictations in seeded permutations (an approximation: repeated embeddings, no
new sessions; it exercises the update dynamics). Metrics: EER (all impostors)
and spouse EER over 1.5 s windows of the held-out targets, the second
speaker's acceptance rate, and cosine of the profile to each speaker's
held-out centroid. Evaluation uses non-overlapping 1.5 s windows of the
held-out targets (every 6th window of the 0.25 s hop): a runtime choice made
before any Stage C result; it reduces the number of trial windows about
sixfold and so widens the CIs somewhat. Every condition is paired with its clean baseline on the
same speakers and replicates. Speakers enter a snapshot only if their stream
reaches it. Headline numbers exclude speakers whose first k dictations
include a same-chapter one (W0's relation flags), as the contract requires;
all speakers are reported separately. Joint-role bootstrap: when a second
speaker's dictations entered a profile, each trial of that profile also
requires that speaker to be drawn (weight = product of the multiplicities of
the distinct identities). Contaminating speakers of the 20 % stream are not
resampled, as in W0's harness, and this is stated with the results.

## Stage D: scenario evaluation (W0 harness)

Each pre-stated configuration is registered with the harness and evaluated
on the frozen dev scenario set (hash cited), with the contract's metrics,
enrollment conditions and the per-scorer tau. Final deliverables: the best
configuration and two cheaper ones as a size/quality frontier.

Selection rule (2026-10-21, fixed before any Stage D dev result; follows
contract amendment e4782a5, which makes the S0 guardrail a reported metric):
1. All 48 pre-stated configurations ({b2, r34lm, b0} x L {1.0, 1.5} x
   H {0.25, 0.5} x {raw, AS-norm} x {score-only, full head}; robust update
   rule, train-calibrated gates, scorer window cache of 128 recordings for
   scoring runs, which covers one speaker's ~70-mixture traversal; cache off
   and the evaluator's CPU_ENV for latency)
   run on dev half A.
2. Primary metric m: pooled interferer words kept at the calibrated 0.5 %
   budget, headline condition (k = 10, clean enrollment, matched device).
   Cost c: CostReport.macs_per_audio_second.
3. Best: let B0 be the configuration with the lowest m. Then order all
   configurations by ascending c (ties broken by lower m, then by name), and
   compare each in that order against B0 by the paired half-A bootstrap
   difference in m (config minus B0, the harness's speaker replicates). The
   selected configuration S is the first, i.e. the cheapest, whose CI lower
   bound is not above 0 (not significantly worse than B0); B0 itself
   qualifies, so S always exists.
4. Cheaper configurations: among configurations with c <= 0.5 c(S), take
   the lowest m (ties to lower c); the same among c <= 0.15 c(S). If a set is
   empty, it is reported empty.
5. The three run on half B and on the full dev set (half B is the
   selection-free estimate). S0 WER increase is reported for each beside the
   oracle's, and a configuration is flagged if its S0 increase exceeds the
   oracle's by more than the paired CI half-width; it is not a gate.
   Full-dev numbers are labelled exploratory (they include half A).
Disclosure: step 3 selects the cheapest configuration that is not
*significantly worse* than B0, which is not a non-inferiority test. A
materially worse cheap configuration can qualify through a wide CI, and
scanning up to 48 configurations raises that chance; the rule favours cheap
configurations. The rule stays as pre-registered; the half-B paired
difference of S against B0 (`selected_minus_b0` in the half-B and full-dev
reports) and the point estimates are reported so a reader can judge the size
of any loss.

## Shared artefacts

The shared clean-speech embedding cache is W4's (`runs/W4/emb/`, computed
through `load_embedder`). Stage A computes only what that cache does not
cover: its own seeded test segments (0.5-2 s, three seeds), the train cohort
at matched lengths, and all seven candidates (the survey needs every
embedder). Those files are survey internals under `runs/W1/survey/emb/`
(format in `survey.py`); W1 hands W4 the profile format and example profile
bytes.

## Risks

- LibriSpeech is clean read speech; dev numbers overstate real performance.
- 73 dev speakers (about 36 per half) give wide CIs; differences inside the
  CI are not claimed.
- Choosing K, L, H and gates on dev makes dev numbers optimistic; the sealed
  test run by the orchestrator is the honest estimate.
- Window embeddings blur turn boundaries shorter than L; short interjections
  next to the user's speech will be kept.
- Single-chapter speakers share a session between enrollment and test.
- Licence of VoxCeleb- and LDC-trained weights for commercial use.

## Packages

No new packages for Stages A-D. coremltools 9.0 (installed by the
orchestrator on request) for the conversion-only Core ML op check.

## Change log

- 2026-10-21, before any real run: registry names; LibriVox-project session
  separation and per-relation reporting; dev halves for selection-aware
  reporting; joint speaker bootstrap described; AS-norm K = 200 fixed for CI
  tables; minimal profile (no running statistics by default); W4 owns the
  shared embedding cache; TitaNet seen-speaker diagnostic; MIN_SAMPLES 0.2 s;
  Core ML conversion method and its caveats. Dev widened to dev-clean +
  dev-other (73 speakers) by the orchestrator; W0's canonical dev halves.
- 2026-10-21, after Stage A review r1, before any real run: decision rules
  rewritten as paired differences with pre-set margins and an inconclusive
  outcome; operating-point metric (impostor pass at 0.5 % / 1 % target miss)
  added and used for the shortlist and H1; train speakers split into cohort
  and fit halves; profile stores the unnormalised running mean plus count;
  seen-speaker check made descriptive and quality-matched; energy gate fixed
  for pause-free speech and short inputs.
- 2026-10-21, before any Stage B/C run: enrollment/update windows fixed at
  1.5 s / 0.25 s, separate from the scoring window, so gates calibrated once
  apply to the L = 1.0 scoring configurations too.
- 2026-10-21, after Stage B/C review r3, before any Stage C run: session
  change paired against a control sharing its first 300; at least 15 distinct
  dictations per project (extra renders outside the test chapter);
  bootstrap CIs for the H5-change verdicts; "replay dynamics" wording; smoke
  and provenance status propagated and checked through every artefact.
- 2026-10-21, after Stage B/C review r2, before any Stage C run: H5-change
  (session and device change after a mature profile); burst paired at its
  peak (320); second-speaker identity enters the bootstrap only after its
  first dictation; drift floor over a 300-dictation horizon; calibration
  through the updater's decision; caches and gates bound to their window;
  every real run refuses uncommitted code in any executed path
  (`survey.require_clean`, lfspk/harness included).
- 2026-10-21, after Stage B/C review r1, before any Stage C run: profile
  format version 2 (float32 running mean, optional anchor, load-time
  invariants); anchored rule; long-horizon, mature-profile and burst poisoning
  (H5-long); complete-rule dictation-gate calibration; gates bound to their
  norm and window; joint-role bootstrap including the second speaker;
  relation-stratified, paired evaluation; head profiles built as enroll(3)
  then updates; silence not covered by any window scores low.
