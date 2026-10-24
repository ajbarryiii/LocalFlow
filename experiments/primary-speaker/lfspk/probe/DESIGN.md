# W2 design: does Parakeet's encoder already know who is speaking?

Status: pre-registration. Written before any real run; every comparison below
is stated before its numbers exist. Changes after a sol-loop round are logged
in `RESULTS.md`, never silently edited here.

## 1. Question and why it matters

LocalFlow runs Parakeet TDT 0.6B v2's FastConformer encoder (dw_striding
subsampling x8, then 24 conformer layers, d_model 1024, 80 ms frames) on every
dictation. If some layer carries speaker identity, a tiny head on that layer's
frames, conditioned on the enrolled profile, could mark the primary speaker's
frames at almost no extra cost. ASR training rewards speaker invariance, so we
expect identity to fade with depth.

## 2. Which weights

| tag | weights | where they ship | how we run them |
|---|---|---|---|
| `base` | `lfspk.paths.PARAKEET_V2_NEMO`, NVIDIA FP32 checkpoint | nowhere directly; reference | NeMo, FP32 arithmetic, TF32 disabled |
| `m1` | ternary QAT run `main-M1-P2-lr5e-4` step 250000, packed export SHA-256 `a287e977...1503` | macOS and iOS (Core ML C6s8: ternary LUT, FP16 activations, FP16 row scales); Linux (`lf-cpu`, same export, FP32 or residual-INT8 activations) | export dequantized into the NeMo model, FP32 arithmetic (W2's own loader, `lfspk/probe/models.py`, verified against the export manifest hashes) |

Facts from the LocalFlow repo (read-only): `Resources/Parakeet/INTEGRATION.md`
pins the export hash above, and it matches the file on this machine
(`/mnt/hd/wilderness-labs-stt/parakeet-ternary/runs/main-M1-P2-lr5e-4/export/export.safetensors`).
Linux `linux/crates/lf-asr/src/encoder.rs` runs the same export layer by
layer. So `m1` is the shipped network on all three platforms, up to activation
arithmetic (FP16 on Apple, FP32/INT8-residual on Linux). The FP16 vs FP32
difference is not measured here beyond one optional check (section 7).

`base` is the primary probe (as instructed); `m1` is run through the same
utterance-level pipeline in full and through the frame-level stage, so every
key number exists for both. Every table names its weights.

Caveat recorded up front: both networks were trained on data that includes
LibriSpeech training audio (M1's stream lists `librispeech`; Parakeet v2's
Granary mix includes it). Dev-clean speakers are not in any training set.
Closed-set identification on train-clean-360 speakers (2a) therefore runs on
speakers whose audio the ASR model has seen; we expect no effect on a linear
probe of speaker identity, but the open-set verification on dev (2b), which
has no such exposure, is the number that decides.

## 3. Layer indexing (recorded in CONTRACT NOTES)

Tap `0` = output of `encoder.pre_encode` (subsampling, before positional
encoding; `xscaling` is off in this config). Taps `1..24` = output of
conformer layer `i` (`encoder.layers[i-1]`). Tap 24 is the final encoder
output; `CostReport.reads_parakeet_layers` uses these numbers and `-1` for the
final output as the contract says (24 and -1 denote the same tensor).

Parakeet normalises the 128 log-mel features per utterance (`per_feature`)
before the encoder, so absolute level and long-term spectral mean are removed
before tap 0. This is relevant to interpretation: a mixture's normalisation
statistics come from the whole recording.

## 4. Hypotheses (stated before data)

- H1 Speaker identity, measured by dev open-set EER, is best in an early or
  middle tap (we guess taps 2-10) and degrades towards tap 24.
- H2 Even the best tap is worse than TitaNet-small at 1 s and 2 s
  (TitaNet is trained for it), but clearly better than the log-mel floor.
- H3 Ternary QAT (`m1`) does not change the best tap's EER materially:
  equivalence margin 1.0 EER point at 2 s (absolute). Verdict on half E at
  the base-selected tap: "equivalent" only if the whole 95 % CI of
  EER(m1) - EER(base) lies inside (-1, +1) points; "different" if it
  excludes 0; otherwise "inconclusive" (never read as "no change").
- H4 At frame level, a profile-conditioned head on the best region of taps
  separates target frames from interferer-only frames clearly better than (a)
  the same head without the profile and (b) the same head on stacked log-mel
  frames.

## 5. Stage 2: utterance-level layer probe

### 5.1 Data selection (`lfspk/probe/select.py`, deterministic, seed 20261021)

Train (train-clean-360, 921 speakers): per speaker up to 24 utterances,
chosen round-robin across the speaker's chapters (sorted chapter ids, seeded
shuffle inside each chapter), so multi-chapter speakers have both chapters.

Dev (dev-clean + dev-other, 73 speakers, per `lfspk.splits` since commit
86ef446; dev-other joined before any real dev evaluation). Session unit: a chapter is one recording
session, but chapters of one LibriVox project (CHAPTERS.TXT `PROJ.`) may share
microphone and room, so the project is the stronger session boundary.
- Enrollment comes from one chapter with at least 9 utterances: the one
  leaving the most test material in *other projects* (if no chapter leaves at
  least 5, the most in other chapters; ties: larger chapter, lower id).
- Test pool and session class per speaker: other projects if at least 5
  utterances (`cross_project`, 40 speakers: 19 clean, 21 other), else other
  chapters of the same project (`cross_chapter`, 19: 12 clean, 7 other), else
  the rest of the enrollment chapter (`same_chapter`, 14: 9 clean, 5 other).
  Every result is reported on all speakers, on
  `cross_chapter` = cross_project + cross_chapter speakers, and on
  `cross_project` speakers only.
- Two fixed halves (`select.dev_halves`, seeded, stratified by LibriSpeech
  subset x sex x session class; within a stratum a seeded permutation, and
  the extra speaker of odd-sized strata goes to E, S, E, ... in sorted
  stratum order): **S** (selection, 36 speakers: 20 cross_project,
  8 cross_chapter, 8 same_chapter; 18 F, 18 M; 20 clean, 16 other; 714 test
  utterances) and **E** (evaluation, 37 speakers: 20 / 11 / 6; 18 F, 19 M;
  20 clean, 17 other; 713 test utterances). Any choice made from results (the best tap) is made on
  S and reported on E; full-dev curves are exploratory. W0's canonical
  halves replace these once published (before any real dev evaluation if
  they arrive in time; otherwise both are reported). The cross_project subset
  of E (20 target speakers) is descriptive: its CIs will be wide and an
  inconclusive result there is reported as such; the pre-registered
  inference about channel rests on the colour control over all of E.
- 3 enrollment models per speaker, each the mean of 3 disjoint full
  utterances from the enrollment pool (9 utterances in total).
- 20 test utterances per speaker from the test pool (all if fewer).

Length conditions: `full`, `2s`, `1s`. A crop is one seeded window of the
given length per utterance, chosen among windows whose 10 ms frames are at
least 50 % active by a fixed energy rule (frame energy within 35 dB of the
utterance's loudest frame and above an absolute floor of -60 dBFS); if no
window qualifies after 50 draws the most active of them is used and counted.
Every system sees the cropped audio itself, not a window of a longer
context; this is the usual short-segment verification protocol and is the
fair comparison with TitaNet. Enrollment is always full utterances.

### 5.2 Features

- Parakeet taps 0..24 (`base`, `m1`): per tap, mean and standard deviation over
  valid frames (padding excluded), 2048 values, stored float16.
- `logmel` floor: Parakeet's own 128-band log-mel front end *without* the
  per-utterance normalisation, mean and std, 256 values.
- `titanet-s`: NeMo `titanet_small` embedding (192, `forward()` embs output),
  from the pinned read-only copy `data/models/titanet-s/titanet-s.nemo`
  (SHA-256 `c9d82e1b...3ffe`; provenance entry by W1, cited in mine). One
  reference point only; W1 does the survey. If W1's reviewed
  `load_embedder("titanet-s")` computes embeddings differently, W2 switches
  to it before the real run so all workstreams share one baseline. Checked
  2026-10-21 on 18 dev utterances: cosine between W2's and W1's
  `load_embedder("titanet-s")` embeddings >= 0.999999, so W2 keeps its own
  call (same `forward()` output; W1 only L2-normalises).

Batches are formed from utterances of similar length. On the first, middle
and last batch, the first two and last two items are re-run alone; if any
pooled statistic differs by more than 1e-3 relative to its largest value,
the extraction fails and writes no `meta.json`, and downstream loading
refuses any feature set whose recorded invariance exceeds 1e-3. A loading
error in the audio producer aborts the job (no silent hang).

Channel control (`-colour` feature sets): dev test segments (never
enrollment) re-extracted after **W2-colour-v1** (`lfspk/probe/colour.py`, W2's
own fixed laptop-like colouring until W0's device colourings exist:
200 Hz 2nd-order high-pass, +6 dB peak at 3 kHz Q 1, 6 kHz 4th-order
low-pass), same crops as the clean run. Back ends stay the clean train ones.

### 5.3 Back end (identical for every feature type)

Fitted on train only, one back end per (weights, tap), on the union of the
train full, 2 s and 1 s features: per-dimension standardisation, LDA with
Ledoit-Wolf shrinkage to 200 dimensions (fewer if the input has fewer),
length normalisation. Scoring: cosine between the enrollment model (mean of
its 3 length-normalised embeddings, renormalised) and the test segment.
TitaNet is additionally scored with plain cosine on its raw embeddings (its
intended use); both are reported. No score normalisation (W1 owns that).

LDA dimension sensitivity (100, 400) is run once at the best tap and reported
whatever it shows; the headline uses 200.

### 5.4 Metrics

- Trials: every enrollment model x every test segment of a length condition,
  both speakers inside the half being reported (full dev: 73 x 3 models x up
  to 20 x 73 segments, 4281 target and about 310k non-target trials per
  length). Subsets:
  all, same-sex non-targets only (the second-dictator case), cross_chapter,
  cross_project (5.1).
- EER and minDCF (P_target 0.01, C_miss = C_fa = 1, normalised).
- 95 % CI: **two-way** percentile speaker bootstrap, 1000 resamples, seed
  20261021 (+ half index). Each resample draws the half's speakers with
  replacement, stratified by session class; that one draw serves both trial
  roles: a non-target trial (a, b) gets weight m_a m_b, a target trial m_a.
  This includes test-speaker variability (one hard impostor recording reused
  against every model), which enrollment-only resampling misses. Paired
  differences share the resamples. Subsets or halves where a class is empty
  are reported as undefined.
- Channel control: EER of each system on coloured test segments, and the
  degradation EER(colour) - EER(clean), compared between the best tap and
  TitaNet-small (raw cosine), paired. A tap whose identity relies on channel
  more than TitaNet's would degrade more.
- 2a closed-set identification: 200 train speakers with at least two chapters
  among their selected utterances (seeded choice); multinomial logistic
  regression on standardised tap features of chapter A's utterances, accuracy
  on chapter B's. (A, B) is the first pair of selected chapters from
  different LibriVox projects when the speaker has one, else the first two.
  Chapter separation does not remove channel (same-project pairs may share
  microphone and room), so accuracy is reported for all 200, for
  cross-project speakers and for same-project speakers separately, and a high
  accuracy alone is not read as channel-independent identity. Inverse
  regularisation C chosen per tap by 3-fold CV inside chapter A from
  {0.01, 0.1, 1}. Full and 2 s. CI by one-way bootstrap over speakers
  stratified by cross/same project (only test utterances vary here; the
  classifier's classes are fixed).

### 5.5 Pre-stated comparisons

1. EER(2 s) and minDCF(2 s) per tap, `base` and `m1`: the layer curves (H1),
   on full dev (exploratory) and on each half.
2. Best tap = argmin EER(2 s, all trials) on half **S** (ties: lower tap),
   separately for `base` and `m1`. On half **E**, at that tap: vs
   TitaNet-small (raw cosine and LDA) and vs log-mel, at 1 s, 2 s, full, all
   subsets, with paired CIs (H2). The selection-on-S / report-on-E split is
   what makes these intervals honest: an argmin over 25 noisy taps evaluated
   on the same speakers would be optimistically biased.
3. `m1` vs `base` at the base-selected tap on E, H3 verdict with the 1-point
   margin; `m1` at its own selected tap vs TitaNet.
4. Channel control on E: degradation of the base-selected tap vs TitaNet.
5. 2a accuracy curves (all, cross-project, same-project).

Utterance-level "competitive" means: best-tap EER(2 s) at most 1.5x
TitaNet-small's raw-cosine EER(2 s). This is a description, not the
go/no-go; the product decision is stage 3's.

## 6. Stage 3: frame-level separability (the product question)

### 6.1 Mixtures

Until the orchestrator announces W0's mixing API, W2 uses its own
**W2-simplemix-v2** (labelled as such everywhere; probe only;
`lfspk/probe/simplemix.py`): target = one utterance of speaker A (on train
cropped to a seeded 10 s window); interferer = a segment of one utterance of
speaker B != A from the same split, 30-100 % of the target's length, cut at a
seeded point. Two modes, equally likely: **overlap** (segment placed inside
the target's span) and **turn** (segment placed before or after the target,
overlapping it by 0-30 % of the segment; the mixture extends beyond the
target, as in turn-taking with call audio or a second dictator who starts or
stops at a different time). Signal-to-interference ratio of active speech
uniform in [-5, +5] dB (similar level, S4-like); additive, no reverberation,
no noise; both scaled together if the peak exceeds 0.99; all placements on
10 ms boundaries. Labels per 10 ms frame from the clean sources with the 5.1
activity rule: 0 none, 1 target only, 2 interferer only, 3 overlap. (v1,
overlap only, was replaced before any real run because LibriSpeech targets
have few pauses, so interferer-only frames were only about 8 % of frames, all
in short gaps, in a smoke run.) Without reverberation or level differences
(SIR centred on 0 dB), loudness and distance cues are absent, so the head
must use identity; this is deliberately the hardest, cleanest form of the
question, and optimistic in that real rooms add confounds W0 models.

When W0's API arrives, stage 3 is re-run on W0 train-split mixtures with the
same heads (no change in method), and both are reported.

Train mixtures are generated on the fly from the train selection, index-seeded
(mixture i always identical), never repeating within the run. Dev: one
mixture per dev test utterance (1427), target from the dev test pool,
interferer from the test pool of another dev speaker **of the same half**
(S or E, 5.1), so the halves share no speaker; even-numbered mixtures of a
speaker are same-sex. Profile = enrollment model 0 of 5.1.

### 6.2 Heads

One head per (weights, tap, conditioning), all trained in the same job on the
same batches (paired comparison, no selection of taps beforehand: all 25
taps, each conditioned and unconditioned, plus the two log-mel heads: 52
heads per job). `lfspk/probe/frames.py`, `stage3.py`.

Back end for stage 3: train speakers are split by a seeded permutation into
halves A (461) and B (460). The stage-3 back end of each tap is the 5.3
recipe fitted on half A only; heads train on mixtures whose target and
interferer both come from half B. Otherwise train-time profiles would come
from a back end that saw those very speakers (sharper than on dev, where the
back end has never seen the speaker), a train/dev mismatch the head could
learn to rely on. Dev profiles use the same half-A back end.

Input per encoder frame t: tap frame x_t (1024), standardised with per-tap
mean/std derived from the stage-2 pooled statistics of half-B full
utterances (equal weight per utterance). Profile p: the target's enrollment
model from the half-A back end of the same tap (200, length-normalised; on
train, 3 utterances of the target other than the mixture's target utterance,
from another chapter when the speaker has at least 3 there; on dev,
enrollment model 0 of 5.1). Head: Linear(1024->256); FiLM with (gamma, beta)
= Linear(200->512)(p), applied as h*(1+gamma)+beta; GELU; Conv1d(256->256,
k=5) over time; GELU; Linear(256->1); sigmoid. About 0.70 M parameters. Target:
fraction of the 8 covered 10 ms frames whose label is 1 or 3 (soft BCE,
padding masked). Scores are upsampled to 10 ms by repetition for evaluation.
Training targets are cropped to at most 10 s (seeded window; mixtures up to
20 s); dev mixtures use whole utterances.

Controls trained identically:
- `uncond`: same head with the FiLM parameters a learned constant instead of
  a function of p (tests whether identity, rather than energy, voice activity,
  ASR confidence or "which voice is louder in this mixture", drives the
  separation). Trained for every tap.
- `logmel`: same head on 8 stacked 10 ms frames of the encoder's own input
  (Parakeet's per-utterance-normalised 128-band log-mel, 8 x 128 = 1024 per
  80 ms frame), conditioned on the logmel back-end profile (raw log-mel
  mean+std, half-A back end), and its unconditioned twin. This asks whether
  the encoder adds anything beyond its input for a head of this size.

Training: AdamW lr 1e-3, weight decay 0.01, batch 32 mixtures, 6000 steps,
200-step linear warm-up then cosine decay; seeds 1, 2, 3 (the seed sets the
head initialisation and the index-seeded mixture stream), all reported. No
early stopping and no checkpoint selection on dev: the final step is
evaluated.

### 6.3 Metrics

On dev mixtures, at 10 ms: ROC AUC and EER of target-present (labels 1, 3)
vs interferer-only (2) frames, and two operating points nearer the product's
(it may drop almost none of the user's words): the fraction of
interferer-only frames kept at the strictest threshold that drops at most
1 % and at most 2 % of target-present frames (`fa_at_miss1`, `fa_at_miss2`); also target-only (1) vs interferer-only and
overlap (3) vs interferer-only; for all mixtures, same-sex mixtures, and
mixtures whose target speaker is `cross_project` (enrollment and mixture
utterance from different LibriVox projects: the profile cannot match the
target by its recording chain, the remaining recording-chain confound of
W2-simplemix, which applies identical processing, none, to both roles but
takes each role's audio from its own LibriSpeech recording); on full dev
(exploratory) and on each half. CI: two-way speaker bootstrap (1000
resamples), one draw of the half's speakers serving both roles; a mixture's
frames get weight m_target x m_interferer. Per-head numbers are the mean over
3 seeds (the statistic inside each resample is the seed mean), with every
seed listed.

### 6.4 Decision rule (what would change our mind)

The tap is selected on half S: argmax of the seed-mean conditioned AUC
(target-present vs interferer-only, all mixtures; ties: lower tap),
separately for `base` and `m1`. The verdict is then judged on half E only, at
that one tap, so "any of 25 taps" cannot pass by luck. The verdict is
**permission to continue to the harness** (stage 5), not product
suitability: frame-level numbers on W2-simplemix cannot establish the
word-level 0.5 % budget. It is granted if, on dev half E, all mixtures, for
`m1` (the shipped weights):
(a) conditioned AUC minus `uncond` AUC >= 0.05 with the 95 % CI excluding 0;
(b) conditioned AUC exceeds the `logmel` head's with the CI excluding 0;
(c) the conditioned target-present vs interferer-only AUC is at least 0.90;
(d) operating point: at the strictest threshold that drops at most 2 % of
target-present frames, the conditioned head keeps at most 50 % of
interferer-only frames, and fewer than the `uncond` head (CI of the
difference below 0). AUC alone measures average ranking; (d) guards against
a head whose ranking is good on average but which cannot reject any
interferer speech without first losing a slice of the user's. 50 % is a
minimal usefulness bar (remove at least half of the interferer-only speech
at a target cost the word rule's averaging can still absorb), chosen before
any data; the harness measures the real word-level trade-off.
Otherwise we report a negative result (with the `base` verdict and all
curves alongside).

Identity versus recording chain: W2-simplemix processes both roles
identically (no processing), but each role's audio carries its own
LibriSpeech recording channel, and for same-project targets the enrollment
utterances share it. A conditioned head could therefore partly match the
recording chain. The verdict quantities (a)-(d) are also reported for
cross-project targets of E (enrollment and mixture target from different
LibriVox projects), and the conclusion is stated as "speaker identity or
recording channel" unless the cross-project block supports the same
conclusion. The harness's device-mismatch condition is the stronger test.

## 7. Stage 4: deployment cost (analysis, plus at most one cheap check)

For the best tap: Mac/iOS Core ML (re-export with a second output from the
encoder graph: output tensor size, extra memory per function, whether the
Neural Engine partitioning changes, from the conversion code in
wilderness-labs-stt `finetune/parakeet-ternary/ios`; a Mac conversion run only
if the orchestrator wants it); Linux `lf-asr` (copy one layer's activations
inside `run_layers`); the head's own MACs. Ternary effect: covered by `m1`.
Optional cheap check: FP16 autocast of `m1` at the best tap, EER(2 s) only.

## 8. Stage 5: scorer

If a tap is viable: `ParakeetLayerScorer` implementing `TargetSpeakerScorer`
(`lfspk/probe/scorer.py`). Profile = running mean of per-dictation tap
embeddings (stage-2 back end), with an update gate that rejects dictations
whose embedding has cosine to the current profile below a threshold set on
train mixtures (contamination guard); `to_bytes` = 200 float16 values plus a
version byte. Scores = the head's output upsampled to 10 ms.
`CostReport.reads_parakeet_layers = (tap,)`. Evaluated with W0's harness on
the dev scenario set once `data/harness/READY.json` exists.

## 9. Risks and confounds

- LibriSpeech chapter = recording session: same-chapter trials inflate
  identity. Mitigated by cross-chapter enrollment/test and closed-set
  cross-chapter testing; 9 single-chapter dev speakers reported separately.
- Read audiobook speech is cleaner and more consistent than dictation.
- 1 s gives about 12 encoder frames; std pooling is noisy there. Same for
  every Parakeet tap, so the layer comparison is fair; it may disadvantage
  Parakeet against TitaNet's attentive pooling.
- Layer curves are a dev selection; the selected tap is then evaluated on dev
  again in stage 3 (all taps are trained there, so there is no selection
  inside stage 3). The sealed test belongs to the orchestrator.
- W2-simplemix lacks rooms, noise and level cues. Its numbers are an upper
  bound on identity-only separability, not product performance.
- Per-utterance feature normalisation in Parakeet's front end changes with
  the mixture; the head sees what deployment would see.
- 80 ms resolution is coarse at word boundaries; the harness's word rule
  averages over a word's frames, which softens this.

## 10. Packages

None beyond the shared venv (torch, NeMo via `./python-nemo`, scikit-learn,
numpy, soundfile via NeMo deps).

## 11. Outputs

`/mnt/hd/localflow-speaker/runs/W2/`: `select/` (selection manifests),
`feats/<weights>/<split>/` (pooled features + index), `verify/` (JSON tables),
`frames/` (stage-3 checkpoints and metrics). All commands are listed in
`RESULTS.md` with the commit they ran from.
