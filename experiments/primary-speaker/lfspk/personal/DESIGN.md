# W6 per-user fine-tuning of the conditioned mask network: pilot design (pre-registration)

Status: draft r3 (fixes for sol rounds r1 and r2; responses in section 13),
for the orchestrator's verification of the r2 delta. Nothing in this design
has been run. The only measurements so far are read-only inspections;
RESULTS.md lists them.
Held-out TRAIN speakers only. No dev, no test, no noise-dev or noise-test, and
nothing from runs/W5/masks_quarantine_R1-s0_20261023/.

## 0. Question

W5's mask network (0.77 M params, FiLM plus cosine conditioning on a
redimnet2-b2 profile) barely uses the profile: in W5's fix screen each
conditioned run scores almost like its unconditioned twin. AJ's question is
whether a per-user copy, fine-tuned on that user's own enrollment dictations
mixed with public interference, starts using identity: does it suppress
other voices more while protecting the user's speech? And can that
fine-tune run in the background on the user's Mac CPU?

Hypotheses, per arm (section 1). All are judged by the gates in section 6.
- H-P1 (matched-user versus wrong-user adaptation; r1 M2): on the subject's
  own test set, conditioned on the subject's profile, the model fine-tuned on
  the subject suppresses S4 interference (second dictator, the identity-hard
  case) more than a model fine-tuned the same way on a different speaker of
  the same sex. S2 is the secondary family.
  - This is narrower than "the network starts using identity". The control
    was tuned at another speaker's profile and is scored at the subject's,
    so the contrast mixes unfamiliar speech with an unfamiliar conditioning
    point.
  - The crossed weight x profile diagnostic of section 3 (X1) measures
    profile sensitivity only. It is a mandatory interpretive check, not a
    gate, and the pilot does not claim where identity sits (r2 M2).
- H-P2 (safety): the personal model stays within W5's over-suppression bounds
  on every family, S0 included.
- H-P3 (product): one fine-tune fits a pre-registered wall-time and memory
  budget on the Mac, on 2 threads at background QoS.

Predictions, stated before any run:
- V0 (alpha 10) will probably fail the suppression gate G1. Its mask head is
  saturated (W5: sigma(z) > 0.99 in 78-99.8 % of bins), and alpha 10 favours
  pass-through, so 1,000 small steps are unlikely to reach 20 %.
- VB (alpha 3) will probably pass G1. Whether it passes the safety gate G3
  depends on whether training on the user's own voice lowers over-suppression
  of that voice. I have no basis for a confident prediction on G3 or on the
  personalisation gain G4.

## 1. Arms, bases and what adapts

| arm | base checkpoint (sha256) | effective alpha | twin (diagnostic only) |
|---|---|---|---|
| A-V0 | runs/W5/train/V0-s0/final.pt (a3d5a6e0...a942) | 10 | V0u-s0 (7090b127...549f) |
| A-VB | runs/W5/train/VB-s0/final.pt (72691027...54d5) | 3 | VBu-s0 (0662ca0c...2e07) |

I re-hashed all four final.pt files against W5's handoff (RESULTS lists the
check). Each arm fine-tunes the conditioned network only (AJ's decision). No
voiceprint-free personal model is trained. The twins are scored untouched,
as a diagnostic (section 3).

Base models load through `lfspk.extract.harness_frontend.load_checkpoint`.
It returns the file's digest but compares it with nothing, so W6 compares
that digest explicitly with the full pinned hash and refuses any mismatch
(r1 m7). The pins are in `lfspk/personal/subjects.py`:

| file | sha256 |
|---|---|
| V0-s0 | a3d5a6e081d3dd090f3aedf7561d3a74f712cfb3f2e855795d9b08d63667a942 |
| V0u-s0 | 7090b127b7ea730abc529a2ad5905b884bca0cc112239d356bb2f5a1f2f6549f |
| VB-s0 | 726910270bba8ef9ca3038379536923d802f6ad63fbbc2ae309ece21dcad54d5 |
| VBu-s0 | 0662ca0c59e80d347405cd22ab6d1cea97f376336d7e0d54e4674cdab5642e07 |

The architecture is `lfspk.extract.model.MaskNet`, imported unchanged.

Adapted parameters, configuration P (primary): the conditioning path and
the heads.

| group | params |
|---|---|
| proj (profile -> 64) | 12,352 |
| films (8 FiLM generators, including the 4 cosine scalars) | 134,144 |
| cos_u, cos_v (cosine branch) | 6,208 |
| head_norm, mask_head, aux_head | 33,538 |
| **total adapted** | **186,242 (24.2 % of 771,074)** |

Frozen: the stem and the 8 DS blocks (584,832 params). Rationale:
- FiLM and the cosine branch are where identity enters the network.
- The mask head is where the decision to suppress is made.
- Freezing the trunk keeps the per-user artifact small (section 9). It also
  limits how far 10 dictations can pull the shared acoustic features.
- Gradients still flow back through the frozen blocks, because block-1 FiLM
  parameters need them. Only the weight gradients of frozen layers are
  skipped.

Configuration F (secondary, report-only): full fine-tuning, all 771,074
parameters, with everything else identical. Its gates are reported but never
used for selection.

## 2. Personal data

### 2.1 Pilot subjects (sample size from a CI argument)

The candidates are W5's 48 held-out train speakers (`overlay.held_out()`).
Base training excluded them from every role, so every one is an unseen
voice for both bases.

A subject's scoring session must differ from its enrollment session. That
means LibriVox projects disjoint between the enrollment and the mixture pool,
i.e. partition level `cross_project`. A read-only inspection of the 48 found
15 F and 11 M at `cross_project`. The rest are `same_project_cross_chapter`
(9 F, 13 M).

So the pilot has **22 subjects, 11 F and 11 M**, every one `cross_project`.
- M: all 11.
- F: the first 11 of the 15, in sha256("w6-pilot/<speaker>") order.
- Pilot order (the same rule within each sex):
  - F: 2775 1335 6120 5290 8677 1061 2592 5012 6519 4116 3967
  - M: 639 1456 2929 5239 5386 8011 497 7688 1025 439 119

The code recomputes this list and asserts it.

The other **26 held-out speakers are the scoring-interferer pool**: 13 F (166
5489 636 7868 plus the 9 same-project F) and 13 M. They appear only in the
scoring sets, as interferers and absent-target talkers. They are never a
subject, never a control donor and never in any tuning set.

Sample size (r1 M4). 22 is a **precision pilot**, not a powered
confirmatory test. The cross-project rule caps n at 26 (11 M), and balance by
sex sets n = 22. The roughly 24 in the brief is not reachable under that
rule.

The estimand is the one G4a gates (section 6.1): the pooled ratio difference

    Delta = frac_P - frac_C
          = (sum_r U_C(r) - sum_r U_P(r)) / sum_r U_id(r)

summed over the 352 present renders of the family. U_P, U_C and U_id are the
per-render under-suppression of the personal model, the control and the
identity mask.

Write Delta = sum_i w_i d_i, where:
- i runs over subjects;
- w_i = U_id(subject i) / U_id(all) is subject i's share of the oracle's
  under-suppression;
- d_i is subject i's own ratio gain.

So Delta is a weighted mean of subject gains, with nominal effective size
n_eff = 1 / sum w_i^2 <= 22. The d_i are not independent, though (next
paragraph), so n_eff alone does not give Delta-hat's standard error.

The control cycle adds dependence. Model W_X enters X's contrast with a plus
sign and its predecessor's contrast with a minus sign. A model that is good
for everyone therefore largely cancels in the pooled Delta, which is what a
matched-user contrast should do. The joint bootstrap (6.1) carries this
dependence through the control donor's involvement.

Let SE be the standard error of the joint estimator Delta-hat, cycle
covariance included (r2 M4). SE is not sigma_d / sqrt(n_eff) for a marginal
SD sigma_d of the d_i. For example, with d_i = delta + u_i - u_B(i), the
model terms u cancel in the sum. Two probabilities are distinguished:
- **detecting a positive effect**, i.e. the CI lower bound > 0, needs Delta
  > 1.96 SE;
- **passing G4a** needs the point estimate >= 0.05 AND the lower bound > 0.

Sensitivity of P(pass G4a) to a **hypothetical** SE of the joint estimator,
using the normal approximation. The SE values are not mapped to any marginal
subject SD.

| hypothetical SE of Delta-hat | Delta = 0.05 | 0.075 | 0.10 |
|---|---|---|---|
| 0.013 | 0.50 | 0.97 | 1.00 |
| 0.025 | 0.50 | 0.84 | 0.98 |
| 0.042 | 0.22 | 0.43 | 0.66 |

In the rows where 1.96 SE <= 0.05 (SE = 0.013 and 0.025), a true gain
exactly at the threshold passes about half the time, and the CI condition
hardly binds. At SE = 0.042 the CI condition binds, because the lower bound
needs Delta-hat > 0.082, and at the threshold the pass rate falls to about
0.22.

No prior estimate of the SE exists, since nobody has fine-tuned per user
yet. The pilot reports n_eff, the bootstrap SE of Delta-hat, the CI and,
descriptively, the spread of the per-subject d_i, so that a follow-up can
be sized.

### 2.2 Enrollment dictations (tuning input, product-faithful)

For subject s, the dictations are W3's bank utterances
(`enrollment.bank_utterances(partitions[s])`, up to 40, all from the
enrollment pool), ordered by sha256("w6-enroll/<s>/<utt>").
- The first **10** are the tuning dictations (k = 10, the headline condition).
- The rest (up to 30 more; 28 for speaker 1335) serve only the drift
  diagnostic D3.

Each dictation is rendered once, as in LocalFlow, with
`enrollment_dictation(utt, seed, device="builtin", contaminated=False)`.
- That is an S0 render, clean, on the built-in device, with seed =
  stable_int("w6-dict", s, utt) mod 2^63.
- The generator is the bank's valid train pool (r1 m9; MixtureGenerator
  needs at least 3 speakers), `MixtureGenerator("train", speakers=<train
  minus the 48 held-out>)`, with the subject's enrollment utterance passed
  explicitly as the target.
- S0 draws no interferer. Each render asserts that its meta lists no
  interferer, that the target is s and that the utterance is in s's
  enrollment pool.
- The render's audio is the "recorded dictation". Its target image and
  target_active frames are kept only to place and level the interference
  (2.4).
- Fresh clean renders, never W3's bank rows, so no bank contamination can
  enter.

Fixed recordings, not re-rendering. On device, LocalFlow has 10 recordings,
not 10 dry utterances it can re-room. So the tuning stream never re-renders
the subject's speech: it reuses these 10 fixed recordings. Each dictation
sits in its own random simulated room (W0's draw). That makes the pilot
harder than a real user, who usually enrolls and dictates in the same room.

### 2.3 Public interference bank (shared by every subject)

A fixed bank of 1,000 W0 renders from **train speakers outside the 48
held-out**, with train-split noise, RIR and music files: 200 renders for each
of S0, S1, S2, S3 and S4.
- Generator: `MixtureGenerator("train", speakers=<train minus the 48
  held-out>)`, built-in device, coherent RIR mode.
- Targets: target-eligible non-held-out speakers, from their mixture pools,
  drawn by a seeded rule.
- Every render asserts that `interferer_speakers(meta)` and the target are
  outside the 48. This is the guarantee that tuning data contains no
  held-out voice other than the subject.

Each donor stores, in float16:
- the target image, the summed interferer images, the noise image and the
  event part of the noise;
- the target_active and interferer_active frames;
- its meta (device and room parameters, interferer SIRs).

It also stores the donor's measured summed SIR, computed once from the
float16 arrays:

    SIR_D = 10 log10( Pact(D.target; D.target_active) / Pact(D.interf; D.interferer_active) )

Pact(x; a) is the mean power of x over the 10 ms frames where a is true. float16 keeps the bank at about
1.8 GB on disk; its relative error of about 5e-4 is far below the
features' resolution. The bank is defined as the float16 arrays, so nixos and
the Mac read identical data.

Product note: a shipped app would need such a bank, or a compact version of
it (section 9).

### 2.4 Tuning examples (personal stream): a registered additive augmentation

What this is (r1 M1). The tuning stream is an **additive augmentation**: the
subject's fixed recordings plus public interference transplanted from donor
renders. It is **not** W0's mixture distribution.

Departures from W0, all known in advance:
- The donor's interference keeps the donor's room and device colouring,
  while d keeps the subject's. W0's coherent mode shares one room and one
  device response. This is closer to W0's `mixed` RIR mode, which the bases
  saw 20 % of the time, but with the device response differing as well.
- Timing is re-placed relative to d's speech, not scheduled by W0 around it.
  For S3 especially, W0 schedules the call's turns around a re-timed target,
  which transplanting cannot reproduce exactly.

The scoring sets (2.5) are W0 coherent renders. Scoring therefore tests
whether what the augmentation teaches transfers to coherent mixtures (r2
M1):
- A channel or timing cue learned from the augmentation is absent at
  scoring, so it is not expected to raise suppression there.
- The personal model and the control both tune on the same augmentation.
  That does not prove that the effects of such cues cancel between them:
  each model is tuned on different dictations, so its reliance on these cues
  may differ.
- The audit below measures the departures before any training.

The subject's recordings stay fixed throughout: the 10 renders of 2.2,
never re-rendered.

Draws. Example k of subject s, seed 0, uses independent RNG streams,
default_rng([0, int(s), k, tag]) per stream, so it is a pure function of
(s, k). (The tag values are registered in amendment A1.)
- Family: the base policy's weights (S0 0.2, N 0.1, S1-S4 0.175 each).
- Absent target: probability 0.05.
- Dictation j: uniform over the 10.
- Donor: drawn from the family's 200 renders (N uses the S1 bank) by a
  deterministic candidate sequence from the example's donor stream
  (rejection below).

Placement, per family. d is dictation j's audio (its target image plus its
own noise), with target activity a_d; D is the donor. First a shift Delta
(in samples, a multiple of 160) places D's timeline on d's: D's sample t goes
to d's sample t + Delta. Then everything is cut or zero-padded to len(d).
- **S1, S2, S4:** Delta = 160 (first(a_d) - first(D.target_active)). The
  donor's target onset lands on d's target onset, which keeps W0's
  target-relative interferer timing (S4's placement relative to the target's
  first active frame, S1's partial overlap). S2 is continuous, so the
  alignment barely matters there.
- **S3 (call):** turn-taking is approximated. Delta is the shift, on a 10 ms
  grid within +-2 s of the onset alignment, that minimises the number of
  frames where a_d and the shifted D.interferer_active overlap. Ties go to
  the smaller |shift|, then to the earlier shift. A long continuous dictation
  can leave no gap; the remaining overlap is reported in the audit.
  *Amended 2026-10-24 (amendment A1, below): the eligible shifts, the
  retention threshold, the rounding, the tie-break on Delta and the rejection
  behaviour are registered there.*
- **N:** Delta = 0. The noise needs no alignment.

Levels are measured **after** placement, on the placed window:
- For S1-S4, I' is the placed **speech interference only**: D.interf after
  the shift and cut, never including the event noise (r2 M1). g_I is derived
  from I' alone:

      10 log10( Pact(d.target; a_d) / Pact(g_I I'; a_I') ) = SIR_D

  a_I' is the placed interferer activity. SIR_D is likewise defined on
  D.interf only (2.3), so the donor's own measured speech SIR is reproduced
  inside the dictation window.
- For S1 only, the placed event part E' (D.event after the same shift and
  cut) is then added with the same gain g_I, applied separately. Its level
  relative to the interfering speech stays the donor's.
- For N, the donor noise is scaled by g_N so that its power over the window,
  relative to Pact(d.target; a_d), equals the donor's noise-to-target ratio,
  then raised by U[0, 15] dB (W5's N rule).

Empty activity is handled explicitly (W0's MIN_ACTIVE_FRAMES = 50, 0.5 s):
- A present S1-S4 draw whose placed window holds fewer than 50
  interferer-active frames is rejected, and the next donor of the candidate
  sequence is tried, up to 20 candidates; then the example raises.
- Draws where d has fewer than 50 target-active frames cannot occur: every
  tuning dictation is checked to hold at least 50 (asserted at render time and
  at load). *Corrected by erratum E1 (2026-10-24); the earlier sentence said
  "every dictation is 3-20 s of read speech", which was false.*
- Rejections are counted and reported.

| case | mixture | y* (T2) | aux label (interfering) |
|---|---|---|---|
| S0 present | d | d | 0 |
| N present | d + g_N N' | the mixture | 0 |
| S1 present | d + g_I I' + g_I E' | d + g_I E' | a_I' |
| S2/S3/S4 present | d + g_I I' | d | a_I' |
| absent, family f | D's own mixture, cut to the crop rules only (N: D.target + g D.noise) | D.noise (N: g D.noise) | D.target_active, OR D.interferer_active except for N |

Absent examples are W5's T2 absent case, unchanged: the subject's profile,
with someone else talking.

If the peak exceeds 0.95, every component is scaled together, as in W5. The
ideal mask, the normalisation over the whole mixture, the 8 s even-aligned
crop and the labels follow W5 exactly. W6 reimplements `prepare_batch`'s
rules on the same `frontend` functions, because prepare_batch takes Example
objects, and a test pins equality with prepare_batch on synthetic examples.

The conditioning vector of every tuning example is the subject's
enrollment profile p0 (section 5).

**Pre-training augmentation audit** (gating the start of the tuning runs).
It runs on the first 2,000 examples of each of 4 subjects (the first 2 F and
first 2 M in pilot order), against the same statistics on the bank donors
themselves (W0 coherent) and on 200 W0 `mixed`-mode renders per family from
the same train pool. Per family it reports:
1. **SIR**: the distribution of measured SIR after placement, against
   SIR_D. By construction they agree to 0.1 dB; any larger difference is a
   bug.
2. **Overlap**: the share of d's target-active frames that are also
   interferer-active, against the donors' own share, per family.
3. **Channel consistency**: per example, the distance between the long-term
   mel spectra of target and interference. Each spectrum is the mean of log
   mel power over its active frames, minus its mean over bins (level
   removed); the distance is the RMS over the 128 bins of the difference.
   Compared against the same statistic on W0 coherent and on W0 mixed
   renders.
4. Rejection counts and the share of padded (zero) interference within the
   window.

Response, fixed now:
- A SIR mismatch above 0.1 dB stops the pilot until the bug is fixed. That
  is a code fix, not a method change.
- If any family's median channel distance exceeds the 95th percentile of
  W0 mixed-mode renders of that family, or the S1, S2 or S4 median overlap
  is below half the donors' median overlap, W6 stops before tuning and
  reports to the orchestrator. Any change to the recipe needs a reviewed
  amendment.
- S3's overlap is reported only; its turn-taking is a known, registered
  departure.
- Otherwise the audit table goes into RESULTS and tuning proceeds.

### 2.5 Scoring set (per subject, never tuned on)

For subject s:
- 16 target utterances from the subject's MIXTURE pool (3-20 s; the smallest
  pool, speaker 119, has 19), first in sha256("w6-score/<s>/<utt>") order.
  The mixture pool's projects are disjoint from the enrollment pool's
  projects, so the session changes.
- Each utterance is rendered paired:
  `render_paired(("S0","S1","S2","S3","S4"), seed, target=utt,
  device="builtin", rir_mode="coherent")`. The generator's speaker pool is the
  26 scoring-interferer speakers.
- N is built from the S1 member as W5 does: interferers removed, noise
  raised U[0, 15] dB, with a seeded gain.
- That gives 16 present renders per family per subject: 96 per subject and
  352 per family pooled. W5's monitor had about 4 per family per subject.
- Report-only absent renders: 4 per family per subject. The target is from a
  scoring-interferer speaker's mixture pool, the profile is the subject's,
  and y* is the noise image.

The scoring set uses train-split noise, RIR and music files, which the bases
and the bank also use; only the voices are new. So the pilot makes no claim
about unseen noise files. Personal and control tune on the same bank, so this
does not bias the contrast between them.

Every render asserts that its speakers are {s} plus scoring-interferer
speakers, and that the target utterance is in s's mixture pool. Each render
set is bound to an identity: seeds, subject lists, W0 identity, W5 code hash,
W6 render-code hash, and a manifest of keys and audio hashes. Consumers
validate the current identity, following W5's calibrate pattern.

## 3. Controls and diagnostics

- **Non-personal control (key control).** For subject A_i, take the personal
  model of the next subject of the same sex in pilot order, B =
  A_{(i+1) mod 11} (a same-sex derangement), and score it on A_i's test set
  with A_i's profile.
  - It is the same base, recipe, steps and bank. The only difference is
    whose dictations and profile it was tuned on.
  - Same sex makes the control stringent: a gain cannot come from sex-level
    adaptation.
  - The donor B is a held-out speaker, so B's voice is as new to the base as
    A's.
  - B never occurs in A's test set, because pilot subjects are never
    scoring interferers.
  - This needs no extra fine-tunes: every personal model doubles as one
    other subject's control.
  - **Personalisation gain = personal - control**, per family. Per r1 M2,
    this is a **matched-user versus wrong-user adaptation** contrast.
  - Mismatch-triggered muting cannot inflate the gain: a control that floors
    everything has frac = 1. Mismatch-triggered pass-through can inflate it.
- **Base untouched.** V0-s0 or VB-s0 scored on the same sets with the same
  profile. Reported for every family.
- **Mandatory interpretive checks** (r1 M2). They are reported for every
  arm, never gate, and limit what may be claimed.
  - **X1, profile-sensitivity diagnostic (crossed weight x profile, on A's
    test set; r2 M2).**
    - Cells: W_A.pA (personal), W_B.pA (control), W_A.pB (profile swap) and
      W_B.pB (the control at its own tuning point, on A's speech).
    - Metric and reference: the 6.1 measurement against **A's T2 oracle**
      (y* = A's target image plus noise, present renders) for all four cells,
      including the pB cells. Every cell reports frac, the under-suppression
      mean, the over-suppression mean and the S0 tail, pooled over subjects,
      per family, with the shared-resample paired 95 % CIs of 6.1.
    - Contrasts reported: the profile contrasts (W_A.pA - W_A.pB) and
      (W_B.pA - W_B.pB), and the weight contrasts (W_A.pA - W_B.pA) and
      (W_A.pB - W_B.pB), each in frac, under and over.
    - Wording, fixed now: if the 95 % CI of frac(W_A.pA) - frac(W_A.pB) on S4
      excludes 0 (either sign), the report says "profile sensitivity
      observed"; otherwise "profile sensitivity not detected". **In both
      cases the identity mechanism is reported as unresolved.**
    - Why X1 cannot locate identity:
      - A positive contrast can come from a generic suppressor switched on
        near the tuning profile, with pass-through elsewhere, without any
        selection by identity.
      - A negative or null contrast can come from a model that is correctly
        identity-conditioned: queried with pB, whose speaker is absent from
        A's mixtures, it may mute everything, and against A's oracle that
        reads as high frac with high over-suppression.
      - The over and under columns are reported so that such patterns are
        visible, not so that they decide anything.
  - **X2, control degradation.** frac(control) - frac(base) per family. If on
    S4 frac(control) < frac(base) - 0.02, G4 is labelled **control-degraded**:
    the wrong-user model under-suppresses relative to the untouched base,
    possibly by pass-through at an unfamiliar profile. The personal-minus-base
    gain and its CI are then reported beside G4, and the claim narrows to
    "better than wrong-user adaptation".
  - **X3, safety of both models.** Every over-suppression statistic of 6.2
    (pooled and per user, all families) is reported for the control too, not
    only for the personal model.
- Optional extra control (orchestrator ruling on M2). I use none beyond X1's
  profile swap, which costs no training. I considered fine-tuning the twin
  (V0u or VBu) on A's data and rejected it: the twin has no conditioning
  path, so configuration P would adapt only its heads (33,538 params against
  186,242). That confounds capacity with conditioning, and it would add 44
  fine-tunes.
- Diagnostics, report-only, never selection:
  - D1, twin context: V0u-s0 and VBu-s0 on the same sets, so the base's
    identity gain (W5's gate-4 quantity) is measured on this larger set.
  - D3, drift: the personal model scored with the profile after W1's
    `update` over the subject's remaining enrollment dictations (up to 30
    more, in order), and cos(p0, p_end).
  - D4, dose-response: personal and control at steps 250 and 500 of the same
    runs. The learning rate is constant after warm-up, so these are
    meaningful shorter runs.
  - D5, platform: registered with a tolerance and a response in section 7;
    it can affect G5.
  - D6: absent-target frac per family.

  (D2, the profile swap, is now part of X1.)

## 4. Hyperparameters (fixed; no grid; nothing tuned on a scoring set)

| item | value | rationale |
|---|---|---|
| steps | 1,000 (primary readout) | 8,000 examples is about 800 passes over each 10-dictation set with fresh interference. That is short enough for the Mac budget (section 7: about 0.62 s/step measured on synthetic tensors). |
| batch | 8, 8 s crops | 64 s of audio per step. Fits a 2-thread CPU step in about 0.6 s at background QoS. |
| optimiser | AdamW, fresh state, weight decay 0 | Decoupled decay pulls toward zero, not toward the base, so it is not a sensible fine-tune regulariser. Regularisation comes from the short schedule, the frozen trunk and the identity targets in S0/N. |
| lr | 3e-4, linear warm-up over 50 steps, then constant | About 0.15x the base's 2e-3 peak, a usual fine-tuning ratio. Constant so that D4's readouts are interpretable. A product fine-tune may also be interrupted and resumed. |
| clip | 5 (W5) | inherited |
| loss | W5's `total_loss`, alpha = the arm's (10 or 3), lambda_aux 0.1 | single factor: same loss as the base |
| data policy | section 2.4, family weights and p_absent 0.05 from the base | single factor: only the speaker changes |
| augmentation | only the stream draws (dictation, family, donor, absent, N gain, crop) | no gain or speed augmentation, to keep the base's distribution |
| seed | 0, one run per (arm, subject, configuration) | |
| device (nixos) | CUDA, deterministic algorithms, FP32 | as W5 |

The only pre-registered comparison of configurations is P against F, with F
report-only. Readouts at steps 250 and 500 are report-only. The gates use
P at step 1,000.

## 5. Profile handling

- **Factory.** W5's fixed conditioning profile (DESIGN amendment a19490a):
  `lfspk.embed.factory:make(embedder="redimnet2-b2", rule="robust",
  norm="raw", head="score", window="1.5", hop="0.25", C="1.0", cache="0")`,
  i.e. `harness_frontend.W1_DEFAULTS`. I keep norm = raw: W5's bases were
  scored with raw, W1's Stage D is not final, and any other norm would add a
  second factor.
- **p0.** p0(s) = `enroll(<the 10 tuning dictations' audio>).directions[0]`,
  computed on CPU. It conditions every tuning example of s (present and
  absent) and every scoring render of s. The same 10 recordings both tune the
  network and define its conditioning vector, as on device.
- **Drift.** On device, the W1 profile keeps updating after accepted
  dictations. The personal network was tuned at a single conditioning point,
  p0. The pilot's proposal for the product:
  - store p_tune = p0 inside the encrypted per-user artifact, and condition
    the personal network on p_tune, not on the live profile;
  - re-tune in the background when the live profile has drifted, i.e.
    cos(p_live, p_tune) < a threshold, or after N new accepted dictations.
    Neither the threshold nor N is chosen here.
  - A re-tune draws its tuning audio from LocalFlow's dictation history
    (AJ's decision, relayed by the orchestrator on 2026-10-23). The history
    is encrypted with the voiceprint key. A re-tune would use recent
    dictations the profile gate accepted, and set p_tune to the live profile
    at that time. The pilot simulates only the first tune (k = 10).
  - D3 measures what happens if the live profile is used instead. Nothing in
    the pilot depends on drift.

## 6. Metrics, gates and the selection rule (fixed before any pilot run)

### 6.1 Measurement

W5's frozen screen measurement, `monitor_reference.v3.py` (sha256
eae20c10...fffe2), re-implemented in `lfspk/personal/score.py`, with
identical definitions:
- Per render: the mean over valid (t, f) bins of the squared log-mask error
  against the T2 oracle, split into under- and over-suppression.
  - The identity mask's under term is mean(ideal^2).
  - The mask comes from `run_mask` (one thread, C1, raw mask).
- Per group: means over renders.
- frac = 1 - under(model) / under(identity).
- tail = the per-render 99th percentile of over-suppression (numpy "higher").
- Groups: family x present/absent.
- Pooling: all 22 subjects' renders together (16 per family per subject, so
  each subject has equal weight).

Parity, before any pilot scoring: on the W5 monitor set, score.py must
reproduce screen_gate_table.json's frac, over and q99 for V0-s0 and VB-s0 to
1e-9. This is a held-out-train read through `calibrate.load_set`, with no
training.

CIs (r1 M3): the 95 % percentile joint speaker bootstrap, B = 2000, seed 0.
- **Universe:** the 48 held-out speakers (22 subjects plus 26 scoring
  interferers), in sorted id order, drawn with W0's `tmetrics.boot_draws`.
- **Involvement set of a render of subject A's set:** {A, B(A), the audible
  interferers}.
  - B(A) is A's control donor.
  - The audible interferers are `lfspk.pvad.w0_source.interferer_speakers`
    of the final mixture. N has none, since its interferers are removed.
  - For an absent render, the absent talker joins the set.
  - B(A) is included because A's contrast depends on B's enrollment and
    tuned model. B's model also enters B's own result, and the shared draw
    count of B carries that dependence.
- **Weights:** a render's weight in a resample is the product of the draw
  counts of its involvement set (`tmetrics.boot_weights`). The same weight
  vector is used for every quantity, so both sides of every paired contrast
  (personal and control, personal and base, the X1 cells) share one
  resample. Every difference and ratio is recomputed inside each resample.
- **Undefined resamples:** a resample in which a gated group's identity
  under-suppression sum is 0 (all its renders weighted 0) makes frac
  undefined.
  - Such resamples are dropped, and the percentile CI is taken over the
    finite ones (`tmetrics.ci`).
  - The number dropped is reported.
  - If more than 1 % (20 of 2000) are undefined for a gated quantity, its CI
    is "unresolved", and a gate needing it fails.
- **Synthetic verification** (a code-stage test):
  - (i) the weights of A's renders are 0 in every resample that does not
    draw B(A), and paired sides share weights;
  - (ii) a coverage **smoke test**, not calibration evidence (r2 M3).
    - The synthetic generator and its seed are frozen in the stage-3 code
      review, before the test is first run.
    - The generator has:
      - 22 subjects with nonzero subject effects;
      - nonzero donor-model effects;
      - the same cyclic pairing, and therefore its dependence;
      - unequal per-subject oracle denominators U_id;
      - 200 replications.
    - Tolerance: the nominal 95 % interval of the pooled ratio gain must
      cover the true value in at least 90 % of replications.
    - That is a smoke-test tolerance. It catches gross dependence errors.
      With 200 replications, a procedure whose true coverage is exactly 90 %
      passes only about 56 % of the time, so passing is not evidence of
      calibration.
    - The observed coverage is reported with its Monte Carlo SE,
      sqrt(c (1 - c) / 200). No larger simulation study is run.
- The CI is conditional on the fixed pairing and the fixed bank.

Result identity (r1 m7). Every score file is bound to:
- the tuned checkpoint's sha256;
- the full tuning config;
- the W6 code hash (lfspk/personal/*.py) and W5's `harness_frontend.code_sha256()`;
- W0's identity (`lfspk.pvad.identity.w0_identity("train")`);
- the pinned base hash;
- the bank, dictation and scoring-set manifests (keys and audio hashes);
- the profile digest (sha256 of p0's float32 bytes);
- W1's code hash and artifact hashes
  (`harness_frontend.w1_code_sha256`, `w1_artifact_sha256s` for
  W1_DEFAULTS).

score.py validates all of these against the current state before it
aggregates, and refuses mixed or stale inputs.

### 6.2 Gates (per arm, on configuration P at step 1,000, target-present groups)

These are mask-error screens on held-out train speakers. They are **not**
transcript-level safety: W5's dWER_S0 guardrail (H5) would need an ASR
evaluation in a later registered plan (r1 M5).

| gate | requirement |
|---|---|
| G1 suppression | frac(personal) >= 0.20 in each of S1, S2 and S4 |
| G2 S3 non-regression | frac(personal, S3) >= 0.45 (W5's inherited floor) AND the lower end of the 95 % CI of frac(personal, S3) - frac(base, S3) > -0.05 (paired, base-relative; r1 m10) |
| G3a over-suppression, pooled | over mean <= 0.010 in each family; S0 over mean <= 0.001 and S0 tail <= 0.01 |
| G3b worst user, S0 | **every** subject (22 of 22) has an S0 over mean <= 0.003 (16 S0 renders each) |
| G3c worst user, other families | **every** subject has an over mean <= 0.020 in each of N, S1, S2, S3 and S4 |
| G4a personalisation, S4 | gain(S4) = frac(personal) - frac(control) >= 0.05, and the lower end of its 95 % CI > 0 |
| G4b personalisation, S2 | gain(S2) >= 0.025 (point estimate) |
| G5 Mac CPU budget | section 7: every measured primary fine-tune of the arm takes at most 20 min wall and at most 1.5 GiB peak memory footprint, and D5 is within tolerance |

Rationale:
- G1 and G3a are W5's screen gates unchanged.
- G2 keeps W5's floor and adds a paired margin. Without it VB could fall
  from about 0.81 to 0.45 and still pass.
- G3b and G3c (r1 M5) are worst-user limits at 3x and 2x the pooled
  bounds. The pooled G3a cannot catch a few badly served users: two subjects
  at 0.0069 on every S0 render pass a pooled S0 mean of 0.001.
- G4 replaces W5's twin gain with the matched-user minus wrong-user gain:
  - Its S4 threshold equals W5's gate-4 threshold. I added the CI
    requirement because this is a paired design with a defined sampling
    unit.
  - The S2 threshold is half of that, for a secondary family: the TV
    programme is often music or broadcast speech, where identity matters
    less than for a second dictator.
- Per-user over-suppression is reported for every family, for the personal
  model, the control and the base (X3).

### 6.3 Selection rule

- An arm passes if G1-G5 all hold. The gates are conjunctive, so a single
  subject failing G3b or G3c fails the arm. No subject is excluded and no
  vote is taken.
- If exactly one passes, it is selected.
- If both pass, the selected arm is the one with the higher mean of
  frac(personal) over S1, S2 and S4. If the two means differ by less than
  0.01, A-V0 is selected (the more conservative loss).
- If neither passes, W6 reports "neither arm passes", with the full gate
  table and the subjects who failed G3b or G3c.
- In every case: no combination of arms or configurations, no further
  variant, and no re-run with other hyperparameters without a new reviewed
  amendment. F, X1-X3, D1-D6 and the 250/500-step readouts are reported and
  never select. X1 and X2 limit the wording of any claim (section 3): X1
  allows only "profile sensitivity observed / not detected; identity
  mechanism unresolved".
- A selected arm is a pilot result on held-out train speakers only. Any dev
  use needs a later registered plan approved by the orchestrator.

## 7. Mac CPU measurement plan

The pilot measures the product requirement on the Mac (MacBook Pro M1 Pro,
8P + 2E cores, 16 GiB, macOS 27) through the jobs-mac tools. Nothing is
inferred from GPU runs.

What runs: the same `lfspk.personal.tune` code as on nixos, with device cpu.
It loads the base, memory-maps the float16 bank, reads the 10 dictations, then
mixes, computes features, trains and saves the adapted weights. Wall time
counts all of it, including Python and torch start-up.

What is copied, to ~/localflow-speaker-w6/ (outside every repo,
deleted when the pilot closes):
- the code: lfspk/personal, lfspk/extract (unchanged), lfspk/api.py,
  lfspk/paths.py and the lfspk/pvad modules that frontend imports;
- the pinned mel constants npz (Parakeet's window and filterbank, sha
  f8254e0d...);
- the two base checkpoints;
- the bank (about 1.8 GB);
- for two subjects only, the 10 dictation renders and p0.

Copied back to nixos: only the Mac-tuned adapted weights, the run logs and
the `/usr/bin/time -l` output.

All of it is public-corpus data, with licences as W0 recorded them
(lfspk/harness/DESIGN.md section 2, data/PROVENANCE.md):
- LibriSpeech speech, CC BY 4.0;
- MUSAN events and music, CC BY 4.0, with W0's per-file music check;
- DEMAND ambience, CC BY-SA 3.0;
- OpenSLR 26/28 noise and RIRs, Apache 2.0;
- simulated RIRs.

No user data, nothing from dev or test. The orchestrator confirmed the
DEMAND and SLR28 copy.

Settings:
- Subjects: the first F (2775) and the first M (639) in pilot order.
- Arms: both. Configuration P, 1,000 steps.
- 2 repetitions each, so 8 runs, executed one at a time.
- Command: `taskpolicy -c background` (macOS background QoS, the setting a
  background fine-tune would use; it schedules on the efficiency cores),
  `OMP_NUM_THREADS=2` and `torch.set_num_threads(2)`, wrapped in
  `/usr/bin/time -l`.
- Recorded per run: wall time, user and system CPU, maximum RSS, peak memory
  footprint (the gate metric: it excludes the clean file-backed pages of the
  memory-mapped bank), and load averages at start and end.

Budget (G5), fixed now: each run at most **20 min wall** and at most
**1.5 GiB peak memory footprint**, at 2 threads and background QoS. All
measured runs of an arm must meet it. The basis is a synthetic-tensor
microbenchmark on this Mac (RESULTS):
- 0.615 s per step at background QoS on 2 threads, for P at batch 8 and 8 s
  crops; 1,000 steps is about 10.3 min of training;
- 419 MB maximum RSS.

So the budget leaves 20 / 10.25 = about 1.95x headroom over the benchmark's
training time for data, features and start-up (r1 m8). It holds only if
mixing and features stay cheap.

**D5, platform discrepancy: tolerance and response, fixed now (r1 m8).**
- The 8 Mac-tuned models (2 subjects x 2 arms x 2 repetitions) are copied
  back to nixos and scored on their subject's full scoring set. Each is
  compared with the nixos (CUDA, torch 2.11) model of the same subject and
  arm.
- To attribute any difference, the same 4 (subject, arm) pairs are also
  tuned on the nixos CPU (2 threads, torch 2.11). That is report-only, about
  4 short CPU jobs.
- Tolerance, per (subject, arm, repetition):
  - |delta frac| <= 0.03 in each of S1, S2, S3 and S4;
  - |delta over mean| <= 0.001 in each family, and <= 0.0005 on S0.
- Why these values: the platforms differ in torch version and in the order
  of floating-point reductions, so trajectories are not expected to be
  identical. A frac discrepancy above 0.03, more than half of G4a's
  threshold, could flip a gate decision. The over-suppression tolerances are
  a tenth and half of the pooled bounds.
- Response: if any Mac-tuned model of an arm exceeds the tolerance, that arm
  **fails G5** ("the Mac path is not shown to be equivalent"). The Mac-tuned
  model is the one a product would use. The nixos-CPU runs are reported to
  show whether the gap is CPU versus GPU or Mac versus nixos. The two Mac
  repetitions of a pair are also compared with each other; a difference
  between them is reported as Mac run-to-run nondeterminism.

Report-only:
- 1 thread, background QoS: one run, subject 2775, A-VB (bench: 1.11 s/step).
- F, 2 threads: one run (bench: 0.755 s/step).
- Default QoS, 2 threads: one run (bench: 0.136 s/step on the performance
  cores).

The Mac's environment is the existing miniforge `orthonet` env, used
read-only (orchestrator ruling): torch 2.5.1, numpy 2.0.1, Python 3.11.11.
Nothing is ever pip-installed into it. nixos runs torch 2.11. Each run
records the versions it actually loaded. A Swift or Core ML
trainer in the product could be faster or slower; this is a PyTorch-CPU
proxy, not an app measurement.

## 8. Compute estimate and coexistence with W1's grid

W1's Stage D grid holds two lanes of 13G host memory each, CPU only. At
inspection, 28 GB of the memory lease was free and the GPU was idle. Every W6
job is low priority, prefixed `w6-`, with an honest `--mem`. None uses
quiet_host or full_machine. At most about 16G is leased at a time.

| job | resources | estimate |
|---|---|---|
| w6-render-dict: 22 x up to 40 dictations + W1 p0 and drift profiles (CPU embedder) | CPU, 4 workers, mem 10G | about 20-30 min |
| w6-render-bank: 1,000 donor renders | CPU, 6 workers, mem 16G (W5 measured 14.5 GiB for 8 workers) | about 20-30 min |
| w6-render-score: 22 x 120 renders | CPU, 6 workers, mem 16G | about 30-40 min |
| w6-render-audit: 200 W0 mixed-mode renders per family S1-S4 (the audit's reference only; never tuned on) | CPU, 6 workers, mem 16G | about 15-20 min |
| w6-audit: the section 2.4 augmentation audit, 4 subjects x 2,000 examples | CPU, mem 8G | about 10 min |
| w6-parity: score.py vs W5's screen on the monitor set | CPU, mem 6G | about 5 min |
| w6-tune-smoke: 1 subject, 20 steps (VRAM and mem measured) | gpu:shared 2G, mem 6G | about 2 min |
| w6-tune-*: 2 arms x 22 subjects x {P, F} = 88 fine-tunes of 1,000 steps, 2 lanes | gpu:shared 2G each (to be confirmed by the smoke), mem 6G each | about 100 s each, so about 2.5 GPU-hours (low utilisation), about 1.3 h wall |
| w6-tune-cpu: D5's nixos-CPU attribution runs, 4 x 1,000 steps, 2 threads | CPU, mem 6G | about 5 min each |
| w6-score: about 24 model evaluations (including the X1 cells) x 2,640 renders, 1-thread run_mask, plus 8 Mac-tuned models on 2 subjects | CPU, 4 processes, mem 8G | about 40-50 min |
| w6-boot: the joint bootstrap (2,000 resamples) and the coverage simulation | CPU, mem 8G | about 10 min |
| Mac: 8 gated + 3 report-only runs | Mac CPU, background QoS | about 11-15 min each, about 2.5 h of Mac background time |

Total: about 2.5 GPU-hours, about 4 h of host CPU jobs, and about
2.5 h of Mac background time. The renders run one at a time and not
alongside tuning lanes, so W6 never holds more than 16G.

## 9. Privacy, storage and product notes (nothing to build)

- **Per-user artifact.** The adapted weights are a per-user voice artifact:
  186,242 values (364 KiB in fp16, 728 KiB in fp32) for P, or 771,074 for
  F, plus p_tune (192 floats) and the base checkpoint's hash. Their
  invertibility (whether the weights leak the voice) is not measured here;
  that would be W4's question.
- **Product requirement** (AJ's decision; W4's STORAGE.md design). Every
  per-user artifact is encrypted at rest with AES-GCM. The key lives in the
  Keychain with a ThisDeviceOnly accessibility class. Nothing is synced or
  exported. This covers:
  - the tuned weights and p_tune;
  - the profile;
  - every checkpoint, including intermediate ones;
  - resumable tuning state (optimiser moments, step counters);
  - every temporary write during a tune: feature caches, mixed batches and
    scratch files.

  Plaintext exists only in memory.
- **Pilot exemption** (r1 M6; orchestrator ruling of 2026-10-23, citing the
  orchestrator's brief, "note it in the design; nothing to build"). The
  pilot does not encrypt its artifacts:
  - its subjects are public LibriSpeech speakers;
  - every input is a public corpus;
  - no user data exists anywhere in the pilot;
  - the artifacts stay on the experiment disk (/mnt/hd), apart from the
    public-data copy to the Mac (section 7), which is deleted when the
    pilot closes.

  This exemption covers the pilot only. It does not carry over to anything
  that touches a real user's voice. The orchestrator informs AJ.
- **Tuning audio in the product** (AJ's decision, relayed 2026-10-23). The
  tuning dictations come from LocalFlow's dictation history, which is
  encrypted with the voiceprint key. The first tune uses the first k = 10
  accepted dictations; re-tunes draw recent accepted dictations from the same
  history (section 5).
  - This resolves the r1 draft's stored-audio question for the product: the
    audio is the existing encrypted history, not a new store.
  - The contract's "no stored audio" wording concerns the profile and the
    scorer API. Any change to that wording is the orchestrator's; the pilot
    needs none.
  - A tune is gradient training on the device, so a product CostReport must
    say so.
- **Interference bank.** The product would have to ship or download public
  interference: about 1.8 GB in the pilot's float16 form. A compact bank (for
  example fewer, shorter donors, or Opus-compressed) is future work. Its size
  is a product cost the pilot reports and does not solve.
- No telemetry, no persistent logs of user content. The pilot uses public
  corpora only and stays on the nixos host apart from the public-data copy to
  the Mac in section 7.

## 10. Code, tests and stages

New package `lfspk/personal/`. It imports lfspk.extract, lfspk.harness,
lfspk.pvad and lfspk.embed and never edits them.
- `subjects.py`: the pilot and interferer lists, and the control pairing.
- `render.py`: dictations, bank and scoring sets, with identities and
  manifests.
- `profiles.py`: p0 and the drift profiles.
- `stream.py`: the section 2.4 recipe.
- `tune.py`: P and F, the readouts at 250/500/1000, and saving.
- `score.py`: the section 6.1 measurement and bootstrap.
- `gates.py`: the section 6.2 table and the selection rule.
- `macbench.py`: the Mac wrapper.

Tests in tests/test_W6_*.py, on synthetic fixtures:
- the subject lists and the derangement (same sex, no fixed point);
- the speaker audit: a tuning stream never yields a held-out speaker other
  than the subject, and a scoring render never involves a pilot subject other
  than s;
- stream determinism and independence from the worker count;
- the recipe table of 2.4, case by case, including that mix = y* +
  interferers;
- equality with W5's prepare_batch;
- the 2.4 placement rules per family: onset alignment, the S3 shift search
  and its tie-breaks, post-placement levelling to SIR_D within 0.1 dB, and
  rejection of empty activity;
- the audit statistics on synthetic signals with a known channel difference;
- frozen parameters bit-identical after a P fine-tune;
- the base-hash pins: a modified checkpoint is refused;
- score.py against a hand computation;
- the bootstrap involvement and shared weights, and the coverage simulation
  (6.1);
- the result-identity binding: a stale manifest or a profile digest
  mismatch is refused;
- the gate and selection logic on synthetic tables, including one failing
  subject failing the arm.

Stages, each sol-reviewed before it runs:
1. This design.
2. Code: render, profiles and stream.
3. Code: tune, score, gates and Mac bench. Then the parity check, the
   augmentation audit and the smoke. Any measured lease changes are recorded as resources-only notes;
   any method change needs an amendment.
4. The pilot runs.
5. RESULTS.

Commits are W6-only, `git commit -- lfspk/personal tests/test_W6_*`.

## 11. What would change our mind; stopping rules

- If the parity check fails, stop and fix score.py before scoring anything.
- If the smoke shows non-finite losses, or the tuning-speaker audit trips,
  stop and report.
- If the augmentation audit (2.4) trips its stop rule, stop before tuning and
  report to the orchestrator.
- If both arms fail G4a with gain CIs centred near 0, personalisation by
  this recipe does not buy identity use at this scale. That is a result, not
  a reason to try variants.
- If an arm passes G1-G4 but fails G5, the method works but does not fit the
  stated Mac budget. That is reported as such. Any cheaper re-design needs
  a new amendment.
- If G3b or G3c fails while G3a passes, a per-user model harms some users
  while the pool looks safe. The arm fails, and the failing subjects are
  reported.
- If X2 labels G4 control-degraded, the gain is not claimed as
  personalisation beyond "better than wrong-user adaptation".

## 12. Questions to the orchestrator (r1 answers recorded)

1. DEMAND and SLR28 renders on the Mac: allowed (public corpora). Licences
   are recorded in section 7 and RESULTS.
2. The Mac's orthonet env: allowed read-only, with versions recorded and
   never pip-installed into.
3. Stored audio: AJ chose to reuse LocalFlow's dictation history, encrypted
   with the voiceprint key (sections 5 and 9).

## 13. Responses to sol round r1 (lfspk-W6-design-r1, on ad6f783)

| finding | response | where |
|---|---|---|
| M1 the transplant does not preserve W0's distribution | Fixed:<br>- registered as an additive augmentation, with its departures stated<br>- per-family alignment: onset alignment for S1/S2/S4, an overlap-minimising shift for S3, none for N<br>- levels re-measured after placement against the donor's measured SIR<br>- explicit empty-activity rejection (at least 50 active frames, 20 candidates)<br>- a pre-training audit of SIR, overlap and channel distance against W0 coherent and mixed renders, with a fixed stop rule<br>- subject recordings stay fixed | 2.3, 2.4, 8, 10, 11 |
| M2 the control is narrower than "uses identity" | Accepted:<br>- H-P1 and G4 are now matched-user versus wrong-user adaptation<br>- mandatory interpretive checks X1 (crossed weight x profile, with a pre-registered threshold for any conditioning claim), X2 (control-degraded label, which reports personal-minus-base) and X3 (safety of both models)<br>- the optional twin fine-tune was rejected with reasons (capacity confound, 44 extra runs) | 0, 3, 6.3 |
| M3 the bootstrap omits the control donor | Fixed:<br>- involvement set {A, B(A), audible interferers} (plus the absent talker)<br>- one shared weight vector for both sides of every contrast<br>- undefined resamples dropped and counted; above 1 % the CI is unresolved and the gate fails<br>- synthetic verification: a weights test and a coverage simulation that must reach at least 90 % | 6.1, 10 |
| M4 the power argument targets the wrong statistic | Fixed:<br>- 22 kept as a precision pilot<br>- the estimand is written as the pooled ratio (a weighted mean of subject gains, n_eff)<br>- the cycle's dependence is explained<br>- detection is separated from passing G4a, with a pass-probability table (about 0.5 at the threshold) | 2.1 |
| M5 an arm can pass while failing particular users | Fixed:<br>- G3b: all 22 subjects at S0 over <= 0.003<br>- new G3c: all 22 subjects at over <= 0.020 in N and S1-S4<br>- conjunctive, so one failing subject fails the arm<br>- per-user safety reported for every family and every model<br>- stated as mask-error screens, not transcript safety | 6.2, 6.3, 3 (X3) |
| M6 the pilot persists checkpoints without encryption | Rebutted, as the orchestrator ruled:<br>- the product requirement now explicitly covers weights, profile, checkpoints, resumable state and temporary writes<br>- the pilot is exempt on stated grounds (public corpora, no user data, experiment disk), citing the brief | 9 |
| m7 load_checkpoint's digest is not compared | Fixed:<br>- full base hashes pinned and compared explicitly<br>- every result bound to the tuned-checkpoint sha, config, code identities, manifests, profile digest and W1 code and artifact hashes | 1, 6.1 |
| m8 D5 has no tolerance; the headroom arithmetic is wrong | Fixed:<br>- tolerance (frac 0.03, over 0.001, S0 over 0.0005) and response (the arm fails G5), with nixos-CPU attribution runs<br>- headroom corrected to 20 / 10.25 = 1.95x | 7, 6.2 |
| m9 MixtureGenerator needs at least 3 speakers | Fixed: the dictations use the bank's train pool with the explicit enrollment utterance, and assert that no interferer is drawn | 2.2 |
| m10 G2 is only an absolute floor | Fixed: a paired base-relative margin, CI lower bound of frac(P, S3) - frac(base, S3) > -0.05, on top of the inherited 0.45 floor | 6.2 |

### Round r2 (lfspk-W6-design-r2, on ad6f783..fa2a414)

| finding | response | where |
|---|---|---|
| MAJOR M2/X1 the identity-location claims are unsupported | Fixed:<br>- X1 is now a profile-sensitivity diagnostic, with its metric and reference defined (the 6.1 measurement against A's T2 oracle for all four cells)<br>- frac, under, over and the S0 tail are reported for every cell<br>- both location claims are replaced by "profile sensitivity observed / not detected; identity mechanism unresolved", with the reasons stated<br>- no extra training | 0, 3, 6.3 |
| minor M1 I' is ambiguous in S1; "shortcuts cannot help" overstates | Fixed:<br>- I' is speech interference only and g_I is derived from it, matching SIR_D<br>- E' gets g_I separately, and the table is written that way<br>- the shortcut sentence now says scoring tests transfer and does not prove cancellation between personal and control | 2.4 |
| minor M3 the coverage check is a smoke test | Fixed:<br>- the generator and seed are frozen at the stage-3 review<br>- nonzero donor effects, cyclic dependence and unequal denominators<br>- 90 % is called a smoke-test tolerance (a true-90 % procedure passes about 56 %)<br>- the Monte Carlo SE is reported | 6.1 |
| minor M4 the SE formula omits cycle covariance | Fixed:<br>- the SE = sigma_d / sqrt(n_eff) statement is removed, with the d_i = delta + u_i - u_B(i) counterexample<br>- the table is relabelled as sensitivity to a hypothetical SE of the joint estimator<br>- "half the time" is limited to the rows with 1.96 SE <= 0.05 | 2.1 |

## Amendments

- **E1, 2026-10-24, erratum** (w6-render-dict failure; orchestrator ruling,
  focused sol round). This is a factual correction of section 2.4. No
  selection changes: the dictations and subjects are exactly those of
  section 2.2.
  - Dictations are W3 bank utterances (`bank_utterances`), with **no length
    filter**. W3's 3-20 s target-length filter applies to mixture targets
    only. W6 applies it to its scoring targets (2.5) and never applied it to
    dictations.
  - 20 of the 878 dictations lie outside 3-20 s:
    - 18 are below 3 s, the shortest 1.075 s (497-31, 25 active frames,
      drift);
    - 2 are above 20 s (20.26 s and 29.7 s, both drift).
  - All 220 tuning dictations hold at least 50 target-active frames. Five of
    them are 2.2-2.7 s: 1456-00 (2.66 s), 5386-04 (2.715 s), 497-04
    (2.175 s), 497-08 (2.465 s) and 119-05 (2.375 s).
  - The at-least-50-active-frames requirement applies to tuning dictations
    only. A drift dictation without usable speech windows is not accepted by
    W1's gated update, and that is reported only through D3.
  - A recorded pre-render scan (`render precheck`) checks every dictation's
    duration and alignment activity and fails on any tuning dictation under
    50 active frames.
  - A recorded stream dry-run (`audit dryrun`, all 8,000 tuning examples of
    every subject) runs before tuning. It checks that short dictations never
    exhaust the 20-donor rejection path.

- **A1, 2026-10-24** (before any production render; sol lfspk-W6-code1-r1
  M2, m3 and m4). This is a method choice registered here. It is not implied
  by the closed design.
  - **S3 shift.**
    - Onset-aligned shift, in samples as in section 2.4 (code1-r2 m2):
      Delta0 = 160 (first(a_d) - first(D.target_active)).
    - Baseline c0: the number of placed interferer-active frames inside the
      dictation window at Delta0.
    - Candidates: Delta = Delta0 + 160 j for integer j in [-200, 200]
      (+-2 s on the 10 ms grid). The code works in frames (Delta / 160)
      and converts to samples when it places the audio.
    - A candidate is eligible if its placed interferer-active count is at
      least need = max(50, ceil(0.9 c0)). The 0.9 is a fixed engineering
      choice, not searched or tuned; the rounding is ceil.
    - Among eligible candidates the chosen one minimises the number of
      overlap frames (a_d AND the placed interferer activity). Ties go to
      the smaller |Delta|, then to the smaller Delta.
    - If no candidate is eligible, the donor is rejected and the next
      candidate donor is drawn, as for the other families, up to 20 in
      total.
    - Reason: without a retention constraint the minimum is degenerate,
      because shifting the call out of the window gives zero overlap.
    - Acknowledged consequence: a shift can lower overlap partly by trimming
      up to 10 % of the onset-aligned interference. For example, a
      continuously active dictation with c0 = 300 can keep 270. The audit
      reports the kept share (kept / c0) for S3. When c0 = 0 (allowed if
      another shift keeps at least 50 frames) the share is undefined: it is
      left out of the numeric summary, and the number of such cases is
      reported separately (code1-r2 m1).
  - **RNG streams.** The exact initialisation is
    default_rng([seed, int(s), k, tag]) with seed 0. The tags are family 0,
    absent 1, dictation 2, donor 3 and gain 4. There is no further namespace
    element.
  - Not amended (code1-r1 M1, a ruling to follow the closed design): N's
    noise power is measured over the whole placed window, padding included,
    exactly as section 2.4 states. Only the implementation changed.

## Responses to code review rounds

### Stage 1 (data), sol lfspk-W6-code1-r1 on ef4a148..a624a3d

| finding | response |
|---|---|
| MAJOR 1: N levelling used the covered samples | Fixed in stream.py: the noise power is over the whole placed window, as the closed design says. The test now checks shorter (padded), equal and longer (cut) donors against the full-window ratio. |
| MAJOR 2: S3 retention is a method choice | Amendment A1 registers the threshold (0.9, fixed), the baseline (the onset-aligned count), the rounding (ceil) and the rejection behaviour. The audit now reports S3's kept share. |
| minor 3: the tie-break used \|j\| | Fixed: the key is (overlap, \|Delta\|, Delta) with Delta = f0 + j. Regression tests cover a nonzero onset (expect Delta = 0) and an equal-\|Delta\| tie (expect -16). |
| minor 4: an extra RNG namespace element | Removed: default_rng([seed, int(s), k, tag]). The tags are registered in A1, and a test pins the draws against that initialisation. |
| minor 5: an unpinned stale pack could load | Fixed: `Bank(verify_current=False)` now requires pack_sha256, and a test checks that an omitted pin is rejected. |

### Stage 1, sol lfspk-W6-code1-r2 on a624a3d..fb88d8e (orchestrator verifies)

| finding | response |
|---|---|
| m1: kept/c0 reported 50.0 at c0 = 0 | Fixed: `audit.s3_kept_share` returns undefined when c0 = 0. These cases are excluded from the summary and counted in `s3_kept_share_undefined_c0_zero`. A1 documents the convention, and a regression test covers it. Donor eligibility is unchanged. |
| m2: Delta changed units in A1 | Fixed: A1 now defines Delta0 = 160 (first(a_d) - first(D.target_active)) samples and candidates Delta = Delta0 + 160 j, matching section 2.4. It states that the code works in frames and converts to samples when placing audio. |
