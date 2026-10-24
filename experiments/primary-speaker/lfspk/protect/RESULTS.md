# W4 results: voiceprint protection

Status: final (2026-10-21).
- Run: utility, inversion and adaptation, for three embedders.
- Not run: the cloning stage, by owner decision; see "Cloning: not run".
- Recommendation: encryption at rest; see "Recommendation" and
  STORAGE.md section 9.

## Sol-loop log

Rounds are run by the orchestrator (subagents cannot call `delegate_task`);
reviewer: Codex gpt-6.1-sol, reasoning xhigh, priority tier.

### Stage invert (design, cache extraction, utility and inversion)

| round | scope | findings (H/M/L) | outcome |
|---|---|---|---|
| r1 | 7afb228 | 3 / 8 / 0 | all accepted, fixed in 840b245, 0d3dc11, 056222b |
| r2 | 7afb228..056222b | 1 / 6 / 1 | all accepted, fixed in b53b3e8 (+ NOTES a2d40df) |
| r3 | 056222b..b53b3e8 | 1 / 3 / 0 | 3 accepted as stated; #1 accepted with a modified bound (below) |
| r4 | b53b3e8..363793e | 1 / 0 / 0 | accepted: tier now from the Waudby-Smith & Ramdas betting bound |
| r5 | 363793e..105b99e | 2 / 2 / 0 | all accepted; owner allowed a 6th round |
| r6 | 105b99e..61cd489 (incl. 135a99a) | 1 / 3 / 0 | #1 rejected by the orchestrator with reason (below); #2-#4 accepted; stage closed |

r1 high findings:
- seed-replayable noise; fixed by a CSPRNG-never-stored product model plus a
  `seedleak` worst-case attacker;
- decision rules that could pass on inconclusive evidence; replaced by an
  absolute criterion with a power check;
- missing cheap constraint attacks; added max-margin, code-consistent and KKT
  inversions.

r1 mediums:
- update contract;
- logistic function not linear;
- cloning bottleneck; added direct routes;
- unequal session relations; the attacker's audio moved to the profile side;
- unbounded extraction memory;
- mixed cache generations;
- partial caches;
- anchor sign definition.

r2 high finding: a 0.10 margin is too loose for a product claim. The
experiment now carries no verdict and reports:
- Delta at FAR 1 % and 0.1 %;
- worst-decile acceptance;
- success within 1, 5 and 20 attempts;
- risk tiers.

AJ chooses the acceptable tier.

r2 mediums:
- cache read race; now immutable generations;
- smoke guard missed the root itself;
- constraint attacks could end infeasible; now feasibility masks and
  fallbacks;
- identification CI shrank the gallery; now fixed-gallery CIs;
- linfn §6.5 text;
- STORAGE A2 row.

r2 low: Apple citations.

r3 findings:
- #1 (H): zero accepts gave a degenerate "negligible" tier. Added an exact
  Clopper-Pearson bound; the tier uses the larger bound; the best tier
  resolvable on 73 speakers is "low".
  - Partial pushback on the prescribed form. The orchestrator asked for the
    bound on targets with **any** accepted clone. Assuming independent accepts
    at FAR 1 % (illustrative; shared seeds correlate routes), 3 routes x 20
    attempts give about 45 % of targets one chance success, which would rate a
    null protection "high".
  - The bound is instead on **vulnerable** targets: some route accepted in at
    least 5 of 20 attempts. That threshold is pre-registered. Under the same
    illustrative assumption chance reaches it with probability 1.4e-6 per
    route (my first figure, 1.6e-5, was an arithmetic error caught in
    clone-r2 #4). The orchestrator accepted this definition.
  - This still detects the reviewer's 3 % fully-vulnerable case (unit test).
    Any-success counts are reported alongside.
- #2 (M): FAR threshold now the minimal cutoff.
- #3 (M): worst decile now consumes only the boundary weight it needs.
- #4 (M): quantiser attack validates codes, searches the cell boundary, and
  reports infeasible cells.

r4 #1 (H): max(bootstrap UB, CP of vulnerable) did not bound mean excess
acceptance. The reviewer's counterexample: 97 % of targets at 2/20, 3 % at
4/20, floor 0, true Delta 0.103; an unlucky 73-target sample read
"moderate". Fix (orchestrator decision): distribution-free betting bound on
mean per-target excess (Waudby-Smith & Ramdas 2023), implemented from the
paper. That sample now bounds at 0.158 ("high"). Consequence, stated in
DESIGN: with 73 targets even all-zero data bounds at 0.065, so the best
resolvable tier on dev is **moderate**. Bootstrap CI and CP interval are
kept as descriptive statistics.

I also tried the bound at the bootstrap 2.5 % threshold quantile as a tier
input. A null synthetic protection then read "high" from chance accepts alone,
so that sensitivity is descriptive only; the tier uses the point FAR-1 %
threshold.

Rejected findings: invert-r6 #1, by the orchestrator (reason below); r3 #1
modified (reasons above).

### Stage clone (cloning end to end, adaptation)

| round | scope | findings | outcome |
|---|---|---|---|
| r1 | openvoice.py, ovse.py, clone_exp.py, adapt.py, test_W4_clone.py at b53b3e8 | 1 / 6 / 0 | all accepted |
| r2 | b53b3e8..363793e | 0 / 3 / 1 | all accepted |
| r3 | 363793e..105b99e | 1 / 1 / 0 | all accepted |
| r4 | 61cd489 | 1 / 2 / 0 | all accepted (with e600e43) |
| r5 | 61cd489..b0aa2fa (+ 5eecace) | 1 / 1 / 1 | all accepted; post-final-round fixes (clone-r5 #1-#3), verified by the orchestrator at c31bae0 |

Clone stage tally: 5 review rounds plus the post-final-round fixes.

clone-r2:
- #1: raw is power-gated too.
- #2: aggregate tier = worst among powered verifiers, with coverage disclosed.
- #3: the GPU count was too low. Selection is now mandatory in code, `plan`
  counts conditions and hours, and the budget is up to 2.5 GPU-hours.
- #4 (L): chance arithmetic corrected (1.37e-6, not 1.6e-5) and labelled
  illustrative.

clone-r1:
- #1 (H): tiers gated on raw's power check.
- #2: route-matched wrong-person controls.
- #3: worst-decile boundary weight (same fix as invert-r3 #3).
- #4: adaptation noise truth.
- #5: vote counts evaluated as protections with the full suite.
- #6: OpenVoice cache generations validated and recorded.
- #7: staged cloning, shared seeds, aliases, keyrot dropped, a single
  se-centroid.
- Also added: a waveform parity test against upstream OpenVoice. It passes:
  tone-colour embeddings and converted waveforms agree to 1e-4.

### Design change: clone_eval targets (owner decision, 2026-10-21)

AJ added 251 public target speakers (train-clean-100) so the risk bound can
resolve tiers below "moderate". In code and DESIGN (commit after 105b99e):
- targets only: thresholds and selection come from dev, unchanged;
- per-split reports plus the pooled 324-target headline;
- the power check is now the betting lower bound;
- resolution table for n = 73, 251 and 324;
- TitaNet caveat extended to clone_eval;
- GPU budget 8 GPU-hours.

The next sol rounds review this change.

invert-r5 and clone-r3 (combined fix):
- invert-r5 #1 (H): floors shared through partner chains made the betting
  bound undercover (7.7 % in the reviewer's simulation).
- invert-r5 #2 (H): thresholds calibrated on the same speakers break
  conditional coverage.
- Owner decision for #1 and #2:
  - the headline is clone_eval alone, with dev's thresholds and unique
    same-sex train partners;
  - dev is exploratory;
  - the pooled 324 headline from 135a99a is withdrawn.
- invert-r5 #3 (M): inversion rounded inward; it now rounds outward
  (bisection with conservative brackets). Both reviewer examples are tests.
- invert-r5 #4 (M): the resolution table is qualified as covering constant
  zero-excess cases.
- Ordering: a pre-registered seeded permutation of targets.
- clone-r3 #1 (H): `synth` refuses unless the selection log is tracked,
  committed, unmodified and hash-matched to the prepared files.
- clone-r3 #2 (M): strict selection parsing.
- W1's enrollment anchor (format v2) is covered in DESIGN §6.1 and STORAGE §1.

invert-r6 (final invert round; the stage is closed at the owner's 6-round
limit, and its fixes are reviewed inside clone-r5):
- #1 (H), rejected by the orchestrator (not the owner; AJ authorised the sixth
  round) with a reason, recorded here and in DESIGN §3.
  - The finding: WSR needs a common conditional mean, and fixed partners can
    have unequal floor rates.
  - The reason for rejecting: the estimand is defined under a randomised
    design. Targets are a random sample of speakers; each partner is drawn
    uniformly at random from the eligible same-sex train pool; the order is a
    uniform random permutation. Under that design the (a_i, f_i) pairs are
    exchangeable with a common mean.
  - The reviewer's example is a fixed, non-random design that this
    randomisation rules out.
  - The guarantee is stated for the randomised design, not conditional on
    the realised assignment.
  - U(a), with no floor subtracted, is reported beside every tier.
- #2 (M): the floor is now called the "training-speaker baseline", with no
  claimed direction for memorisation. The real-audio floor is kept beside it.
- #3 (M): the resolution table is now generated by the implementation and
  rounded up. At n = 251 the values are 0.020, 0.029, 0.027, 0.026 and 0.021.
  A unit test regenerates it from DESIGN.
- #4 (M): the anchor is protected once at enrollment and stored
  byte-identically. Any experiment on the anchored rule must test joint
  disclosure.
- Every tier now carries the label "at the dev-calibrated nominal 1 % FAR
  threshold; achieved clone_eval FAR = x".

clone-r4:
- #1 (H): an append-only synthesis ledger records each start's
  selection-log commit. A different commit needs `--new-preregistration`
  with a reason, and stats reports it. Combined with e600e43, existing
  score files block synthesis.
- #2 (M): the selection log requires utility-budget numbers per row and a
  non-empty rationale, and refuses any selected protection outside the
  budget.
- #3 (M): synthesis is refused above `--max-gpu-hours` (default 8).

## Results

### Utility and inversion (DESIGN §6.2-6.3), all 36 grid protections x 3 embedders

Runs: `./python -m lfspk.protect.invert_exp --embedder <e> --clone-eval` (jobs
w4-inv-redim, w4-inv-ecapa, w4-inv-titanet; outputs in
`runs/W4/invert/<e>/`, with each run's config.json recording seeds, git commit
and cache generations). Every configuration was run and all are in
`summary.tsv`; the tables below show a fixed subset (the in-budget set, the
nearest misses and a few strong protections) generated by
`./python -m lfspk.protect.report invert --rows ...`.

- Utility: primary EER on 2 s crops, k = 10, with joint speaker-bootstrap
  95 % CIs.
- Inversion: the attacker selected on held-out **train** speakers (never dev),
  with speaker-bootstrap CIs and identification galleries kept at their
  declared size.
- clone_eval values are point estimates (no CI, context only).

**Findings.**

1. **No free lunch (H3 confirmed, all three embedders).** Every protection
   inside the utility budget still lets the train-selected attacker do all of
   the following on all 73 dev speakers:
   - recover the profile (cosine 0.91 to 1.00);
   - identify the speaker, among 73 and among 994;
   - pass embedding-level spoofing at the raw EER threshold.
   For ReDimNet2-B2 (primary) that covers:
   - 2- and 4-bit quantisation of the centred profile (48 and 96 bytes);
   - noise at s = 0.25;
   - the stored logistic decision function, which KKT inversion recovers at
     cosine 0.998.
2. **What does reduce identification costs a lot of utility.** On
   ReDimNet2-B2:
   - 32 sign bits (4 bytes) raise EER from 0.81 % to 7.9 % and still give
     top-1 of 73 = 0.75 and spoof acceptance 0.85;
   - LDA-32 with 1-bit codes (4 bytes) gives EER 3.9 %, top-1 of 73 = 0.85 and
     spoof acceptance 0.96.
   Identification among 994 falls much faster than among 73 (0.19 and 0.30),
   so short codes mainly blunt linkability across large populations, not
   re-identification of a known person.
3. **Sex leaks from everything** (accuracy 0.75 to 0.96), including
   4-byte codes.
4. **Keyed rotation is raw** under full compromise, by construction and
   measurement. Without the key (the `wrongkey` control) recovery collapses:
   cosine -0.02 to 0.00, top-1 of 73 at most 0.014, spoof acceptance 0, on
   all three embedders. That is the A1 case and the reason the file is
   encrypted.
5. **Constraint attacks** (max-margin and code-consistent projections)
   reproduced the stored code in all 216 feasibility records (every sign
   and quantiser protection, three embedders, on the selection, dev and
   clone_eval sets),
   and are the selected attacker for the sign codes and 1-bit quantisers.

**redimnet2-b2** (dev, 73 speakers; raw EER 0.0081, raw minDCF 0.0504; budget: EER <= 1.15 x raw and minDCF <= raw + 0.02)

| protection | bytes | EER 2 s, k=10 [95 % CI] | minDCF | in budget | attacker (sel. on train) | cos to true profile | top-1 of 73 | top-1 of 994 | spoof accept | sex acc. | clone_eval top-1 of 251 (point) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| raw | 768 | 0.0081 [0.0034, 0.0180] | 0.050 | yes | analytic | 1.000 [1.000, 1.000] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 0.996 |
| keyrot | 768 | 0.0081 [0.0034, 0.0180] | 0.050 | yes | analytic | 1.000 [1.000, 1.000] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 0.996 |
| center+q4 | 96 | 0.0089 [0.0028, 0.0182] | 0.045 | yes | analytic | 0.995 [0.995, 0.995] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 0.996 |
| center+q2 | 48 | 0.0084 [0.0035, 0.0186] | 0.052 | yes | ridge | 0.944 [0.940, 0.947] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 0.996 |
| linfn | 772 | 0.0084 [0.0028, 0.0175] | 0.047 | yes | analytic | 0.998 [0.997, 0.998] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.93 [0.88, 0.99] | 0.996 |
| center+noise0.25 | 768 | 0.0090 [0.0033, 0.0184] | 0.047 | yes | ridge | 0.976 [0.974, 0.977] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.996 |
| center+noise0.5 | 768 | 0.0096 [0.0040, 0.0191] | 0.059 | no | ridge | 0.929 [0.924, 0.932] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 0.996 |
| center+q1 | 24 | 0.0096 [0.0046, 0.0191] | 0.075 | no | ridge+cons | 0.859 [0.851, 0.866] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 0.996 |
| pca64 | 256 | 0.0096 [0.0042, 0.0192] | 0.070 | no | analytic | 0.901 [0.893, 0.908] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.996 |
| center+sh256 | 32 | 0.0129 [0.0067, 0.0223] | 0.119 | no | ridge+cons | 0.851 [0.844, 0.856] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.996 |
| center+sh64 | 8 | 0.0373 [0.0286, 0.0495] | 0.408 | no | ridge+cons | 0.648 [0.629, 0.664] | 0.96 [0.90, 1.00] | 0.68 [0.58, 0.79] | 0.99 [0.96, 1.00] | 0.75 [0.64, 0.85] | 0.952 |
| lda32 | 128 | 0.0278 [0.0176, 0.0398] | 0.301 | no | ridge | 0.702 [0.686, 0.716] | 0.95 [0.89, 0.99] | 0.77 [0.66, 0.86] | 0.99 [0.96, 1.00] | 0.93 [0.88, 0.99] | 0.952 |
| lda32+q1 | 4 | 0.0385 [0.0280, 0.0499] | 0.570 | no | ridge | 0.599 [0.582, 0.614] | 0.85 [0.75, 0.93] | 0.30 [0.21, 0.40] | 0.96 [0.90, 1.00] | 0.96 [0.90, 1.00] | 0.789 |
| anchor32 | 128 | 0.0624 [0.0504, 0.0762] | 0.563 | no | ridge | 0.705 [0.688, 0.720] | 0.99 [0.96, 1.00] | 0.82 [0.73, 0.90] | 1.00 [1.00, 1.00] | 0.93 [0.88, 0.99] | 0.976 |
| center+sh32 | 4 | 0.0785 [0.0689, 0.0896] | 0.790 | no | ridge+cons | 0.543 [0.522, 0.560] | 0.75 [0.64, 0.85] | 0.19 [0.11, 0.27] | 0.85 [0.75, 0.92] | 0.78 [0.68, 0.88] | 0.610 |

**ecapa-vox** (dev, 73 speakers; raw EER 0.0104, raw minDCF 0.0821; budget: EER <= 1.15 x raw and minDCF <= raw + 0.02)

| protection | bytes | EER 2 s, k=10 [95 % CI] | minDCF | in budget | attacker (sel. on train) | cos to true profile | top-1 of 73 | top-1 of 994 | spoof accept | sex acc. | clone_eval top-1 of 251 (point) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| raw | 768 | 0.0104 [0.0054, 0.0202] | 0.082 | yes | analytic | 1.000 [1.000, 1.000] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 0.996 |
| keyrot | 768 | 0.0104 [0.0054, 0.0202] | 0.082 | yes | analytic | 1.000 [1.000, 1.000] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 0.996 |
| center+q4 | 96 | 0.0099 [0.0047, 0.0202] | 0.069 | yes | analytic | 0.994 [0.994, 0.995] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 0.996 |
| center+q2 | 48 | 0.0105 [0.0049, 0.0199] | 0.083 | yes | ridge | 0.927 [0.922, 0.931] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.992 |
| linfn | 772 | 0.0102 [0.0048, 0.0194] | 0.072 | yes | analytic | 0.997 [0.996, 0.997] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.996 |
| center+noise0.25 | 768 | 0.0101 [0.0046, 0.0198] | 0.074 | yes | ridge | 0.971 [0.969, 0.972] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 0.992 |
| center+noise0.5 | 768 | 0.0101 [0.0049, 0.0201] | 0.085 | yes | ridge | 0.907 [0.901, 0.912] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.93 [0.86, 0.99] | 0.992 |
| center+q1 | 24 | 0.0129 [0.0064, 0.0222] | 0.121 | no | ridge+cons | 0.821 [0.811, 0.829] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.93 [0.86, 0.99] | 0.992 |
| pca64 | 256 | 0.0137 [0.0079, 0.0216] | 0.128 | no | analytic | 0.814 [0.797, 0.828] | 1.00 [1.00, 1.00] | 0.99 [0.96, 1.00] | 1.00 [1.00, 1.00] | 0.93 [0.88, 0.99] | 0.992 |
| center+sh256 | 32 | 0.0191 [0.0116, 0.0283] | 0.164 | no | ridge+cons | 0.820 [0.812, 0.827] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.992 |
| center+sh64 | 8 | 0.0449 [0.0358, 0.0553] | 0.492 | no | ridge+cons | 0.571 [0.551, 0.589] | 0.86 [0.78, 0.93] | 0.53 [0.41, 0.64] | 0.88 [0.79, 0.95] | 0.82 [0.74, 0.90] | 0.861 |
| lda32 | 128 | 0.0349 [0.0240, 0.0451] | 0.439 | no | mlp-s2 | 0.637 [0.615, 0.657] | 0.93 [0.86, 0.99] | 0.45 [0.33, 0.56] | 0.97 [0.93, 1.00] | 0.96 [0.90, 1.00] | 0.932 |
| lda32+q1 | 4 | 0.0495 [0.0380, 0.0605] | 0.665 | no | mlp-s2 | 0.553 [0.533, 0.572] | 0.79 [0.70, 0.88] | 0.15 [0.07, 0.23] | 0.84 [0.74, 0.92] | 0.96 [0.90, 1.00] | 0.713 |
| anchor32 | 128 | 0.0875 [0.0709, 0.1039] | 0.659 | no | mlp-s0 | 0.614 [0.588, 0.637] | 0.82 [0.73, 0.90] | 0.55 [0.42, 0.66] | 0.88 [0.79, 0.95] | 0.93 [0.86, 0.99] | 0.916 |
| center+sh32 | 4 | 0.1038 [0.0908, 0.1207] | 0.897 | no | ridge+cons | 0.479 [0.455, 0.500] | 0.51 [0.38, 0.62] | 0.11 [0.04, 0.18] | 0.66 [0.55, 0.77] | 0.82 [0.73, 0.90] | 0.478 |

**titanet-s** (dev, 73 speakers; raw EER 0.0125, raw minDCF 0.1041; budget: EER <= 1.15 x raw and minDCF <= raw + 0.02)

| protection | bytes | EER 2 s, k=10 [95 % CI] | minDCF | in budget | attacker (sel. on train) | cos to true profile | top-1 of 73 | top-1 of 994 | spoof accept | sex acc. | clone_eval top-1 of 251 (point) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| raw | 768 | 0.0125 [0.0064, 0.0216] | 0.104 | yes | analytic | 1.000 [1.000, 1.000] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 1.000 |
| keyrot | 768 | 0.0125 [0.0064, 0.0216] | 0.104 | yes | analytic | 1.000 [1.000, 1.000] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 1.000 |
| center+q4 | 96 | 0.0125 [0.0064, 0.0217] | 0.126 | no | analytic | 0.994 [0.994, 0.995] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.95 [0.89, 0.99] | 0.996 |
| center+q2 | 48 | 0.0131 [0.0063, 0.0226] | 0.117 | yes | ridge | 0.933 [0.929, 0.936] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.996 |
| linfn | 772 | 0.0149 [0.0071, 0.0228] | 0.131 | no | analytic | 0.998 [0.997, 0.998] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.96 [0.90, 1.00] | 1.000 |
| center+noise0.25 | 768 | 0.0137 [0.0067, 0.0220] | 0.129 | no | ridge | 0.971 [0.969, 0.973] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.93 [0.88, 0.99] | 0.992 |
| center+noise0.5 | 768 | 0.0149 [0.0074, 0.0240] | 0.140 | no | ridge | 0.915 [0.910, 0.920] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.93 [0.88, 0.99] | 0.992 |
| center+q1 | 24 | 0.0140 [0.0078, 0.0232] | 0.133 | no | ridge+cons | 0.835 [0.826, 0.843] | 1.00 [1.00, 1.00] | 0.99 [0.96, 1.00] | 1.00 [1.00, 1.00] | 0.90 [0.84, 0.96] | 0.996 |
| pca64 | 256 | 0.0182 [0.0086, 0.0284] | 0.172 | no | analytic | 0.874 [0.863, 0.885] | 1.00 [1.00, 1.00] | 0.99 [0.96, 1.00] | 1.00 [1.00, 1.00] | 0.92 [0.85, 0.97] | 0.988 |
| center+sh256 | 32 | 0.0215 [0.0120, 0.0307] | 0.205 | no | ridge+cons | 0.835 [0.829, 0.840] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] | 0.89 [0.81, 0.96] | 0.988 |
| center+sh64 | 8 | 0.0460 [0.0327, 0.0631] | 0.404 | no | ridge+cons | 0.593 [0.571, 0.613] | 0.93 [0.88, 0.99] | 0.68 [0.58, 0.79] | 0.88 [0.79, 0.95] | 0.79 [0.70, 0.88] | 0.932 |
| lda32 | 128 | 0.0304 [0.0192, 0.0426] | 0.399 | no | mlp-s1 | 0.656 [0.634, 0.676] | 0.95 [0.89, 0.99] | 0.67 [0.56, 0.77] | 0.96 [0.90, 1.00] | 0.96 [0.90, 1.00] | 0.960 |
| lda32+q1 | 4 | 0.0415 [0.0303, 0.0546] | 0.529 | no | ridge | 0.537 [0.515, 0.557] | 0.81 [0.71, 0.89] | 0.34 [0.23, 0.45] | 0.85 [0.77, 0.93] | 0.96 [0.90, 1.00] | 0.813 |
| anchor32 | 128 | 0.0693 [0.0495, 0.0870] | 0.533 | no | ridge | 0.651 [0.630, 0.671] | 0.92 [0.85, 0.97] | 0.74 [0.63, 0.84] | 0.93 [0.88, 0.99] | 0.90 [0.84, 0.96] | 0.964 |
| center+sh32 | 4 | 0.0956 [0.0745, 0.1168] | 0.741 | no | ridge+cons | 0.468 [0.447, 0.489] | 0.66 [0.56, 0.77] | 0.18 [0.10, 0.27] | 0.68 [0.58, 0.79] | 0.74 [0.63, 0.84] | 0.625 |

### Adaptation compatibility (DESIGN §6.5)

Runs: `./python -m lfspk.protect.adapt --embedder <e>` for redimnet2-b2 and
ecapa-vox (jobs w4-adapt-redim and w4-adapt-ecapa; outputs in
`runs/W4/adapt/<e>/results.json`).

- Primary EER: 2 s crops, all impostors, joint speaker bootstrap.
- Profiles start from 3 dictations and are updated one dictation at a time.
- Results are read at n = 3, 10 and 20 dictations.
- "batch" = the template of the first n dictations computed at once, which
  needs the unprotected running mean.

ReDimNet2-B2, EER [95 % CI]:

| protection | rule | n = 3 | n = 10 | n = 20 |
|---|---|---|---|---|
| raw, lda32 | exact projected running mean | identical to batch at every n | | |
| center+q2 | batch | 0.0101 | 0.0084 | 0.0085 [0.0033, 0.0189] |
| | deterministic rounding | 0.0101 | 0.0099 | 0.0100 [0.0044, 0.0198] |
| | stochastic rounding | 0.0101 | 0.0090 | 0.0100 [0.0045, 0.0201] |
| lda32+q1 | batch | 0.0421 | 0.0385 | 0.0383 [0.0275, 0.0500] |
| | deterministic rounding | 0.0421 | 0.0421 | 0.0428 [0.0320, 0.0557] |
| | stochastic rounding | 0.0421 | 0.0767 | 0.0957 [0.0716, 0.1192] |
| center+sh128 | batch | 0.0212 | 0.0179 | 0.0175 [0.0121, 0.0264] |
| | per-bit vote counts | 0.0227 | 0.0182 | 0.0191 [0.0128, 0.0264] |
| | signs only, stochastic flips | 0.0212 | 0.0215 | 0.0220 [0.0162, 0.0294] |
| center+noise0.5 | noise once, then running mean | 0.0099 | 0.0084 | 0.0079 [0.0029, 0.0183] |

ECAPA shows the same pattern; all its numbers are in `results.json`.

1. **Float templates update exactly (H5).** The projected running mean with
   its count reproduces batch enrollment at every n.
2. **Quantised templates do not update well.**
   - Deterministic rounding freezes the code: one dictation rarely moves a
     coarse cell, so the template stays at its 3-dictation state.
   - Stochastic rounding is unbiased per step, but over 20 steps it is a
     random walk. For 1-bit codes it more than doubles the EER (0.096 vs
     0.038 batch). For 2-bit centred codes the loss is small but consistent
     (0.0100 vs 0.0085). That gap is not resolved by the CIs.
3. **Sign codes need state that leaks more.**
   - Majority votes track batch, but they require storing per-bit vote
     counts. As a protection (`center+shv128`) those counts give recovery
     cosine 0.83 against 0.76 for the signs alone, with identification still
     1.00.
   - Signs alone with a stochastic flip rule lose utility (0.0220 vs 0.0175
     at n = 20).
4. **Noise protects only a fresh, single snapshot (H4 confirmed).**
   - Noise injected once is averaged away by later dictations. The stored
     direction's cosine to the true state is 0.89 at n = 3, 0.986 at n = 10
     and 0.996 at n = 20.
   - Re-noising at every save does not help either: an attacker averaging N
     saved snapshots gets 0.89 (N = 1), 0.94 (2), 0.98 (5) and 0.99 (10).
   - Backups and repeated thefts therefore undo noise.
5. **Consequence.** Every protection that adapts cheaply and keeps utility
   is a float template, and those invert almost exactly (section above). The
   background update needs the running mean in some form, and the template
   is only as protected as that state.

### Cloning: not run (owner decision, 2026-10-21)

The end-to-end cloning stage (DESIGN §6.4) was **not executed**. The owner
decided on 2026-10-21 to skip it, and no synthesis was ever run in this
experiment.

- **Reason (owner):** encryption at rest is the shipping protection. An
  attacker who can decrypt the profile can also decrypt, or simply read, the
  dictation audio LocalFlow keeps. That audio is better cloning material
  than any embedding. So resistance of the template to inversion is not a
  shipping gate.
- **What was done:**
  - the code, its tests and five review rounds (plus the post-final fixes);
  - the OpenVoice waveform parity check;
  - `prepare` for the selected protections;
  - the committed selection log `lfspk/protect/selection.json` (commit
    d5460d9, plan_sha256 ec43d756..., 5.80 GPU-hours), kept as the record of
    the plan that was not executed.
- **What was not run:** no audio was ever synthesised. The ledger is empty
  and no score file exists.
- **What this leaves unmeasured, stated plainly:** whether a recovered
  embedding yields a cloned voice that an independent verifier (or a person)
  accepts. W4 shows that the stored template is recoverable and identifying
  for every utility-preserving protection: identification, embedding-level
  spoofing against the profile embedder, and sex. W4 does **not** show that
  this recovered information is enough to synthesise the user's voice, and
  no risk tier for cloning exists. Hypothesis H1 (the raw profile is a real
  cloning asset) is untested.
- Separately, the inversion results already establish that the profile is
  sensitive biometric data. It links the user across systems and reveals
  their sex.

## Recommendation

**Protect the voiceprint by encrypting it at rest. Do not rely on
transforming its contents.** The full design is in STORAGE.md. In short:

1. **Store** the profile as described in STORAGE.md §1:
   - a float32 running mean plus saturating counts (and the v2 anchor,
     protected identically and stored byte-identically);
   - about 1 KB, AES-256-GCM, in `Application Support`;
   - excluded from backup;
   - the key is a random 256-bit key in the login keychain, never
     synchronised, read once per session; optionally wrapped by the Secure
     Enclave.
2. **Encrypt the dictation history with the same key** (STORAGE.md §0), or
   make it opt-in. Otherwise a disk attacker clones from the WAVs and the
   voiceprint's protection is moot.
3. **Missing key: start over, never crash, never fall back to plaintext.**
   Deletion and opt-out are immediate. The profile is excluded from logs,
   exports and history.
4. **Optional keyed rotation is defence in depth only.** It costs no utility
   and is exactly invertible with the key (measured). Without the key,
   recovery collapses (cosine -0.02 to 0.00, top-1 at most 0.014). It
   therefore adds protection only against an attacker who gets the file but
   not the key, which encryption already covers. If used, keep its key next
   to the file key.
5. **Do not ship a transform as the protection.** Inside the utility budget:
   - quantisation, noise and the stored decision function all invert to
     cosine 0.91 or more, and identification stays at 1.00;
   - noise is averaged away by updates and by multiple snapshots;
   - coarse codes either cannot adapt or leak through the state they need.
   Transforms that do cut identification cost 4x to 10x the EER.

**What this does and does not guarantee.**

- It guarantees confidentiality of the profile against an attacker who gets
  the files without the keychain or the Mac (A0, A1).
- It does not protect against anyone who can run code as the logged-in user
  or read LocalFlow's memory (A2, A3). For them the profile is a recoverable,
  identifying voiceprint, and condition (2), "not easily reversible", is
  **not met** by any protection that keeps the scorer usable. Whether it is
  enough to clone the voice was not measured.
- Against those attackers the dictation audio is the larger exposure, which
  is why the history must be encrypted too.
