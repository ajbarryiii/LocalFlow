# W3 personal VAD: design (pre-registration)

Status: written 2026-10-21 before any training, dev evaluation or data
generation; revised in place after sol-loop round core-r1 and the
orchestrator's project-separation and joint-bootstrap rules, still before any
data. Changes after the first dev number are appended in a dated "Amendments"
section at the end, never edited in place.

## 1. Question

Does a very small frame classifier conditioned on the user's voiceprint (a
personal VAD, PVAD) remove other people's words better than scoring windows
with a speaker embedding (W1), at the contract's equal cost to the user? The
cost is CONTRACT.md's budget, computed by W0's harness: correctly recognised
target words that filtering removes, divided by all target reference words, at
most 0.5 %, pooled over the dev scenarios including S0; and the S0 WER increase
below 0.1 points absolute. The hypothesised advantage: sharper word boundaries and better
behaviour in overlap, which matters most in S4 (second dictator).

## 2. Prior work the design follows

- Personal VAD 1.0 (Ding et al., Odyssey 2020, arXiv:1908.04284). Three
  classes per 10 ms frame: non-speech (ns), target speech (tss), non-target
  speech (ntss). 40-d log-mel, 2-layer LSTM of 64, d-vector concatenated to every
  frame ("ET", 130K parameters) or a frame-level cosine score with a running
  speaker verifier ("ST", "SET"). Weighted pairwise loss (WPL): pairs involving
  tss weight 1, the ns/ntss pair weight 0.1 (0.05 and 0.01 were worse).
  Training mixtures were **concatenations** of 1-3 utterances, no overlap.
- Personal VAD 2.0 (Ding et al., Interspeech 2022, arXiv:2204.03793). 128-d
  log-mel at 10 ms, 4 Conformer layers of dimension 64. Conditioning by FiLM
  from the d-vector beat input concatenation; a "speaker pre-net" that produces
  a learned per-frame embedding whose cosine with the target embedding also
  drives FiLM helped further on concatenated (multi-speaker) audio; FiLM of both
  (E3) was best on the multi-speaker set. 8-bit quantisation cost little.
  Enrollment-less training: with p = 0.2, zero the embedding and relabel ntss
  as tss. About 9.6 MFLOPs (as reported).
- Later work (COIN-AT-PVAD 2024; an MDPI Electronics 2025 study adding a
  Bi-GRU, cross-attention and an AUROC term; AS-pVAD) reports small gains on
  LibriSpeech concatenations. One useful trick: in 20 % of training examples the
  conditioning speaker is absent from the mixture. None evaluates heavy overlap,
  which is our S4. TS-VAD (Medennikov et al. 2020) handles overlap in diarisation
  with heavier models and is outside the size budget.

What we take: three classes with overlap labelled tss, WPL, FiLM plus a
learned in-network cosine score, absent-target examples. What we change:
overlapped mixtures from W0's scenario generator instead of concatenations;
deliberately degraded enrollment embeddings; Parakeet's front end; a
convolution-only backbone (see 4.2).

## 3. Hypotheses and pre-stated comparisons

All comparisons are on **dev** (dev-clean + dev-other, 73 speakers, W0's
frozen dev scenario set), with 95 % percentile CIs from a bootstrap over speakers that resamples
all roles jointly (CONTRACT.md): each resample draws one speaker multiset, and
a mixture counts with the product of the draw counts of every speaker it
involves (target and interferers), so it is dropped when any of them is not
drawn. W0's harness computes the word-level numbers this way; W3's frame
metrics use the same rule (`metrics.joint_bootstrap`, `metrics.frame_bootstrap`). Comparisons are paired:
the difference of the two systems is computed inside each resample. "Better"
below means the paired CI of the difference excludes zero; "not resolved"
otherwise. All differences are in interferer words kept (fraction, primary
metric) at each system's own 0.5 % tau.

- **H1 (conditioning buys identity).** M film_cos keeps fewer interferer words
  than the same network trained without an embedding (A1, M none, same example
  stream),
  pooled over S1-S4 and in each of S3 and S4. An unconditioned VAD can still use
  level, near-field and channel cues, so on S1/S2 the gap may be small; on S3
  (call audio louder than the user) and S4 (similar level) it should be large.
- **H2 (PVAD vs window scoring).** On S4, interferer words kept by the selected
  PVAD is lower than W1's selected scorer at the same 0.5 % budget, and the gap
  is larger on overlapped words than on non-overlapped words. Evaluated only if
  W1 registers a scorer in the harness on the same frozen dev set; otherwise
  reported as not run.
- **H3 (conditioning method).** At size M: FiLM+cos <= FiLM <= concatenation in
  interferer words kept (A6), following PVAD 2.0.
- **H4 (robust enrollment training).** Training with short, contaminated and
  channel-mismatched enrollment embeddings (the default, M film_cos) against
  training with clean 30-utterance matched embeddings only (A5). H4 holds if
  (a) the default is better (paired CI of default minus A5 entirely below 0) in
  both the (3, clean, matched) and (10, 20 %, matched) conditions, and (b) it is
  non-inferior in (30, clean, matched): the upper end of that paired CI is below
  +0.02 (two points of interferer words kept). If (b)'s CI straddles the margin
  the result is "not resolved", not "non-inferior". The margin is about half of
  W0's expected CI half-width on one system, so the comparison may well be
  unresolved with 73 speakers (fewer per half); that outcome is reported as such.
- **H5 (size).** Performance increases from S to M; whether M to L helps is
  open. Selection rule in section 7.
- **Guardrail (G).** At the pooled dev tau, the S0 WER increase is below 0.1
  points absolute. A configuration failing G is reported but cannot be selected.
  Amended 2026-10-21, fixed before any dev result; follows contract e4782a5
  (the S0 guardrail became a reported metric with the oracle beside it): G is
  oracle-relative. A candidate passes iff its S0 wer_increase minus the
  oracle's, on the same half, headline condition and shared population, each
  at its own tau, is below 0.001 (0.1 points). Absolute and relative values,
  and the paired joint-speaker CI of the relative difference, are reported for
  every candidate; the rule uses the point (`compare.s0_versus_oracle`).

## 4. Model

### 4.1 Features

Exactly Parakeet TDT 0.6B v2's front end as LocalFlow computes it
(`ParakeetFrontEnd.swift`, NeMo FilterbankFeatures at inference): dither off,
pre-emphasis 0.97, centred STFT n_fft 512, hop 160, symmetric Hann 400, |X|^2,
Slaney mel 128 bins, log(x + 2^-24), per-feature normalisation over the valid
frames M = N // 160 of the **whole recording** (mean, unbiased std + 1e-5),
frames >= M set to 0. Contract frame i (samples [160 i, 160 i + 160)) is mel
frame i, whose window is centred 80 samples (5 ms) earlier; frame_count(N) <=
N // 160 + 1 always holds, so every contract frame has a mel frame.

Why: LocalFlow already computes these features for Parakeet, so the PVAD's
feature cost on device is zero. Not sharing would cost about 4.3M MACs per
second (a 512-point real FFT per frame plus a 128 x 257 filterbank) and a second
pass over the audio. The window and filterbank are generated analytically
(torch Hann, Slaney mel); a test checks them against the values stored in the
Parakeet .nemo when that file is present.

Training crops are cut **after** normalising the whole mixture, so training and
inference see the same normalisation.

### 4.2 Network

```
mel [128, T] (100 fps)
  stem: Conv1d(128 -> C, k=3, stride=2) + GELU                     -> 50 fps
  blocks 1..L/2 : DS block, FiLM(g(e))
  cos branch    : u_t = W_u h_t (D_p = 32); v = W_v g(e); s_t = cos(u_t, v)
  blocks L/2+1..L: DS block, FiLM([g(e), s_t])
  head: LayerNorm, Conv1d(C -> 3, k=1)  -> logits at 50 fps -> repeat x2 -> 100 fps
DS block(x) = x + PW2(GELU(PW1(FiLM(DWConv_k=5,dil=d(LN(x))))))   PW1: C->2C, PW2: 2C->C
g(e) = GELU(Linear(e / |e|, D_g = 64))                            embedder-agnostic projection
```

Dilations are 1, 3, 9, 27 within each half (k = 5 keeps the coverage
contiguous), so L = 8 gives a receptive field of 1 + 2 * 4 * (1 + 3 + 9 + 27) =
321 frames at 50 fps, about 3.2 s each side of centre: enough to accumulate
identity evidence over several words, as a window embedder does. Non-causal, as
the contract allows.

Why convolutions and not a Conformer or Bi-GRU: on Apple silicon, Core ML runs
dilated depthwise and pointwise convolutions, LayerNorm, GELU and elementwise
FiLM on the Neural Engine, while recurrent layers fall back to the CPU and full
self-attention costs O(T^2), so a 60 s dictation would cost several times more
per second than a 5 s one. A fixed cost per second of audio fits a MAC budget
honestly. Running at 50 fps loses nothing that matters: Parakeet word
timestamps come in 80 ms encoder frames, and the decision is the mean score
over a word.

Conditioning variants (same trunk):
- `none`: no embedding; FiLM is identity (the A1 ablation).
- `concat`: g(e) concatenated to the stem input at every frame (PVAD 1.0 ET).
- `film`: FiLM(g(e)) in every block, no cos branch.
- `film_cos` (default): as drawn above (PVAD 2.0 E3 adapted).

FiLM generators are initialised to the identity (gamma = 1, beta = 0) so that
early training is not dominated by the embedding scale.

Embedder: a frozen public model behind W1's `lfspk.embed.embedder.Embedder`
interface (name, dim, weights_sha256, L2-normalised output). The PVAD only
assumes a fixed-dimension unit vector; swapping embedders means retraining g and
the PVAD, nothing else. Default: whichever of ECAPA (SpeechBrain, VoxCeleb) and
TitaNet-small W1 reports as better on dev; if W1 has not reported when training
starts, ECAPA (already downloaded, trained on VoxCeleb only, so no LibriSpeech
overlap at all). The choice is recorded before training.
Recorded 2026-10-21, before the bank or any training: W1's Stage A survey
(commit 7927ea9; half-A operating point at 1.5 s, the EER winner agreeing)
selected `redimnet2-b2` (ReDimNet2 B2, VoxCeleb2, MIT; 192-d, 3.7M parameters,
about 0.45 GMAC per audio second, Core ML convertible), so the bank and every
W3 run use it; its weights_sha256 and the survey commit are in the bank
identity. (The rule above named ECAPA and TitaNet-small because they were W1's
only adapters when it was written; W1's survey finally covered seven models,
and the orchestrator directed W3 to take W1's pick.)

### 4.3 Sizes (the sweep)

| size | C | L | params (PVAD only, D_e = 192) | MACs / s of audio |
|---|---|---|---|---|
| S | 48 | 8 | about 0.16M | about 5M |
| M | 72 | 8 | about 0.29M | about 10M |
| L | 96 | 8 | about 0.46M | about 17M |

The sweep varies width only (same depth and receptive field), so size is not
confounded with temporal context.

Exact counts come from `lfspk.pvad.model.cost` (analytic) and are checked
against `torch.utils.flop_counter` in a unit test. All sizes stay within 0.5M
parameters and 20M MACs per second. The embedder's own parameters and MACs are
reported separately in the CostReport (the scorer ships it for enroll and
update; `params` includes it, `notes` gives the PVAD-only count).

### 4.4 Loss

Weighted pairwise loss over the three classes (Ding et al. 2020) with
w(tss, ns) = w(tss, ntss) = 1 and w(ns, ntss) = 0.1, averaged over valid frames.
Contract label map: 0 -> ns, 1 -> tss, 2 -> ntss, 3 (overlap) -> tss. Fixed, not
tuned. `score` returns softmax P(tss) at each frame.

## 5. Training data (train split only)

Every example comes from W0's scenario generator / mixing API on train-split
speakers (921 speakers of train-clean-360); W3 writes no mixer
(`lfspk.pvad.w0_source.W0Source` calls `MixtureGenerator("train").render` with
a target utterance W3 picks from the mixture pool; interferers, rooms, levels,
noise and devices are W0's). Per example:

- Scenario family: S0-like single speaker with room noise p = 0.2; S1, S2,
  S3, S4 each p = 0.2. Families, levels, rooms and colourings are W0's.
  Target speaker uniform over the 727 eligible speakers, then a mixture-pool
  utterance of W0's target length (3-20 s). Device: built-in microphone always
  (the frozen sets score built-in mixtures; the headset appears only through
  enrollment variants). RIR mode: W0's secondary "mixed" mode with p = 0.2,
  else "coherent" (one room for every source); "mixed" applies to every role at
  equal rates, so it adds real reverberation without a role cue.
- Absent target: with p = 0.1 the conditioning embedding belongs to a train
  speaker who is not in the mixture, and every speech frame becomes ntss.
- Absent-target examples are part of the deployment distribution (the key is
  held while someone else talks), so every model, conditioned or not, sees the
  same example stream: example i of a run is a pure function of (seed, worker,
  i), with independent random streams for the mixture, the absent-target
  decision and the enrollment draw. Runs with the same seed therefore see the
  same mixtures, the same absent flags and the same crops; A1 differs only in
  not being given the embedding, and A5 only in the enrollment draw. (For A1
  an absent-target example is label noise it cannot resolve; that is the
  honest deployment condition.)
- **Fixed pools.** Each train speaker's utterances are split once into an
  enrollment pool and a mixture pool (`enrollment.partition_speaker`). The unit
  is the LibriVox project (CHAPTERS.TXT) when the speaker has two or more, since
  a project probably means one microphone and room; otherwise the chapter;
  otherwise single utterances. Units are visited in sha256(speaker/unit) order,
  each going to the smaller pool so far. The level is recorded per speaker
  (train-clean-360: 377 cross_project, 350 same_project_cross_chapter, 194
  same_chapter). The 194 `same_chapter` speakers (a single chapter, so
  enrollment and mixture would share one recording) are never training
  targets or impostor profiles; they still appear as interferers, whose
  enrollment is never used. This removes the same-recording shortcut at its
  source; 727 target speakers remain. `same_project_cross_chapter` targets are
  kept (the contract's fallback), and the dev results are split by the
  harness's `cross_project` flag so a residual session shortcut would show.
  Mixture targets are drawn from the mixture pool and enrollment dictations
  from the enrollment pool; both are checked on every example and a violation
  raises instead of falling back. Bank utterances: up to 40 per target speaker
  from the enrollment pool, round-robin over its chapters (28,344 in total; 22
  speakers have fewer than 30, so k is capped for them). Then:
  - number of dictations k uniform over {1, 2, 3, 5, 10, 20, 30} (capped by the
    pool size);
  - contamination rate r drawn from {0 (p 0.5), 0.2 (p 0.3), 0.4 (p 0.2)}; each
    enrollment dictation independently uses its precomputed contaminated
    variant (an S4-like mixture rendered by W0's API with another train speaker)
    with probability r;
  - channel: each dictation independently uses the mixture's device (W0's
    per-user colouring, e.g. the built-in microphone) with p = 0.5, otherwise
    another device of the bank (e.g. the headset), so a profile usually mixes
    devices as a real one would;
  - a variant the policy asks for that the bank lacks is an error, never a
    silent substitution (`EnrollmentBank.check` verifies coverage up front);
  - profile = L2-normalised mean of the per-dictation unit embeddings, the same
    rule the scorer's `enroll` uses.
- Enrollment-variant embeddings are precomputed once per (utterance, variant)
  with the frozen embedder (`lfspk.pvad.bank_build`) and stored under
  `runs/W3/emb/<embedder>/` (format in CONTRACT NOTES when written). For each
  bank utterance and each W0 device (built-in, headset), one
  `render_paired(("S0", "S4"), seed, target=utt, device, rir_mode="coherent")`
  call yields the clean dictation and its contaminated twin (identical target
  and noise, plus an S4-like talker), exactly as the harness builds enrollment
  streams; seed = sha256("w3-bank/<utt>/<device>"). 727 speakers x up to 40
  utterances x 2 devices x 2 = 113,376 embeddings. W1's and W4's cached train
  embeddings are not reused: they embed dry utterances, while the bank's
  variants are rendered dictations (room, device colouring, noise).
- Crops: whole mixture normalised, then a random 8 s crop (shorter mixtures are
  zero-padded and masked).

Training budget: fixed number of optimiser steps, identical for every
configuration, chosen from data-pipeline throughput alone in a few-minute smoke
of the M film_cos run on the announced (post-review) mixer, before any dev
metric exists: the largest multiple of 1000 steps that fits about 2 h of wall
time per run at the measured rate, two runs in parallel (6 render workers, a
4 GB shared GPU lease and 12 GB of memory each). The number and the measured
throughput are recorded here as an amendment before the first run.
Smoke measurements so far (2026-10-21, draft mixer d8355d5): bank build on 2
speakers, 160 paired renders and 320 ECAPA embeddings with 4 workers, took 94 s
wall for 17 s of user CPU, i.e. disk-bound on the shared HDD; the first
training throughput smoke was stopped for the same reason. The orchestrator
is mirroring LibriSpeech to the NVMe disk; the budget smoke is repeated after
that switch.

**Amendment 2026-10-22, step budget fixed before any dev metric: 3000 steps
per run.** Source: two `smoke_throughput` runs (M film_cos, batch 64, 6 render
workers, gpu:shared 4 GB, random-vector bank) started together on 2026-10-21
after LibriSpeech and the auxiliary data (RIR bank, OpenSLR 26/28, MUSAN) were
on NVMe, i.e. exactly the target condition of two runs in parallel; both were
killed by a supervisor restart after 225 and 275 steps (logs in
runs/W3/smoke/throughput/throughput-20261021T2356*). Mean time per step from
step 100 to the end of each log: 2.01 s and 1.81 s. The slower figure, 2.01
s/step, gives 7200 / 2.01 = 3582 steps in 2 h, rounded down to 3000. The last
logged intervals were faster (1.2-1.8 s/step, caches warming), so the budget
is conservative. A clean rerun was blocked behind another project's
quiet-host job; the orchestrator approved fixing the budget from these logs.
3000 steps x 64 examples = 192,000 training mixtures (about 2.5 per
eligible-speaker mixture-pool utterance) per run; warm-up stays 1000 steps,
cosine decay to step 3000. Same for every run.
Runs are resumable (`last.pt` every 1000 steps): example g * batch + j is a
pure function of (seed, g * batch + j) whatever the worker count, crops are
drawn per step, and the optimiser state is restored. Training runs with
`torch.use_deterministic_algorithms(True)` (CUBLAS_WORKSPACE_CONFIG=:4096:8,
cuDNN deterministic, no benchmark); the model avoids ops without deterministic
CUDA backward passes (upsampling by expand + reshape, the loss by one-hot
products rather than gather). CUBLAS_WORKSPACE_CONFIG=:4096:8 is set when
`lfspk.pvad.train` is imported, before torch; train() refuses deterministic
CUDA training if the variable differs or CUDA was initialised before it was
set. Resume equality is unit-tested on CPU and was checked on the GPU
(`smoke_throughput --resume-check`: NVIDIA GeForce RTX 5090, torch 2.11.0+cu128,
toy data, size M, 40 steps against 20 + resume: bit-identical weights; the
deterministic run took 6-16 % more wall time in two such toy checks, startup
included; the budget smoke measures it on real data).
A checkpoint stores an identity record (the TrainConfig minus declared-safe
fields, model config, bank SHA-256 and embedder hash, W3 and W0 code hashes, W0
corpus index hashes, torch version); resumption refuses any mismatch. Safe
fields: out_dir, num_workers, log_every, eval_every, ckpt_every, dev_monitor,
device. A finished run directory, or one with a log but no checkpoint, is
refused. Bank shards carry the same kind of identity (embedder and weights
hash, W0 code and index hashes, bank code hash, seed rule, devices, shard
contents) and are reused or merged only on an exact match. AdamW, lr 2e-3, weight
decay 0.01, cosine decay with 1000 warm-up steps, batch 64, gradient clip 5.
Final checkpoint only; no early stopping, no checkpoint picking.

## 6. Ablations (pre-registered)

| id | what | kind |
|---|---|---|
| A1 | unconditioned VAD, same trunk (`none`) | training run |
| A2 | 3 vs 10 vs 30 enrollment dictations | evaluation condition |
| A3 | contaminated enrollment 0 % vs 20 %, with plain-mean vs PVAD-gated update | evaluation condition |
| A4 | device mismatch: matched vs mismatched enrollment | evaluation condition |
| A5 | trained only with clean, matched, 30-dictation embeddings | training run |
| A6 | conditioning: concat vs film vs film_cos at size M | training runs |
| A7 | size sweep S, M, L with film_cos | training runs |
| A8 | on-device score recalibration (section 8) on vs off | evaluation condition |
| D1 | diagnostic: give the interferer's embedding instead of the target's on S4 | frame-level only |

Training runs: S, M, L (film_cos), M concat, M film, M none, M A5: seven runs at
seed 0. The selected configuration and `none` are retrained at seeds 1 and 2 to
measure seed spread; every seed is reported.

## 7. Evaluation and selection

- During training, a frame-level monitor on a fixed dev subset
  (`lfspk.pvad.devmon`: up to 60 coherent-room mixtures per scenario from W0's
  frozen dev set, at most 2 per target speaker and scenario, in sha256 order of
  mixture id, each with its speaker's (10, clean, built-in) profile; speakers
  with fewer than 10 such dictations are left out; only dev sets are accepted,
  checked before any audio is read; the monitor's embedder must equal the
  bank's): per scenario, ROC AUC and EER for target-present frames
  (labels 1, 3) against interferer-only frames (2), AP of each class (for
  comparison with the PVAD papers), and the fraction of interferer-only frames
  passing at the threshold that rejects 2 % of target-present frames. Logged,
  not used for any choice.
- Final: W0's harness on the frozen dev set (word decision rule, tau at the
  0.5 % pooled budget). Primary metric: interferer words kept, per scenario and
  pooled, overlap vs non-overlap; plus every contract metric, after 3, 10 and 30
  dictations, clean and contaminated, matched and mismatched device.
- Selection (decided now). Candidates in a fixed total order by PVAD parameter
  count: S film_cos < M concat < M film < M film_cos < L film_cos. A1 and A5
  are ablations, not candidates. Selection metric: pooled S1-S4 interferer
  words kept in the headline condition (10, clean, matched). Among candidates
  passing G, the reference R is the one with the lowest point estimate (ties:
  earlier in the order). The selected configuration is the first candidate in
  the order whose paired CI of (candidate - R) has its upper end below +0.02,
  i.e. non-inferior to R within two points; R qualifies trivially. "Passing G"
  means the oracle-relative G of section 3. Every
  comparison is against R only (no chaining), so the result is unique.
- Selection-aware reporting (CONTRACT.md). The 73 dev speakers are split into
  two halves by W0's canonical function (stratified by subset, sex and session
  class; to be published in the harness and recorded here before the first
  evaluation). Selection runs on half A only; the selected configuration's
  numbers are reported on half B (held out) and, labelled exploratory, on all
  73 speakers. The sealed test (orchestrator) is the only unbiased final number.
- Cost: params, MACs per second, update MACs, profile bytes, CPU latency per
  second of audio (single thread, torch, 10 s and 30 s inputs, median of 20).

### 7.1 Evaluation procedure (fixed before any dev number)

1. Every trained checkpoint is scored once by W0's evaluator on the whole dev
   set (`lfspk.harness.evaluate run --half all --scorer
   lfspk.pvad.harness_scorer:make --arg checkpoint=...`, CPU workers, one
   thread each; the factory loads the checkpoint's own embedder and refuses a
   different weights hash; embedder MACs come from W1's cost survey). Metrics
   for half A, half B and all are computed from those same saved scores.
2. Selection (section 7 rule) runs on half A with `lfspk.pvad.compare select`;
   paired differences reuse W0's word ledger: in each of W0's 2000 joint
   speaker resamples (seed 0) both systems get the same mixture weights and
   each recalibrates its own tau to the 0.5 % budget.
3. The selected configuration is reported on half B (held out) and on all 73
   speakers (exploratory), in every harness condition (k 3/10/30 = A2,
   clean/contaminated = A3, matched/mismatched device = A4), together with:
   the gated update rule (A3, a second scorer run with `update_rule=gated`),
   recalibration (A8: population value fitted on 60 train speakers with
   `lfspk.pvad.fit_recal`, a third run with `recal=`), and D1
   (`lfspk.pvad.diag_swap`, frame level, exploratory).
4. H1, H3 and H4 compare fixed, pre-registered configurations (not chosen on
   dev), so they use all 73 speakers: paired CIs from `compare pair` at the
   headline condition, plus H4's two robustness conditions. H2 uses W1's
   saved scores on the same frozen set if W1 provides them.
5. Seeds: after selection, the selected configuration and `none` are
   retrained at seeds 1 and 2 and scored the same way; every seed is reported
   and the seed spread is set against the between-configuration differences.

## 8. Adaptation (on device, no gradients)

- Profile: count n and the running mean of unit embeddings; `update` adds one
  dictation's embedding. Two pre-registered rules: `mean` (plain) and `gated`:
  embed only the frames the current PVAD scores P(tss) >= 0.5 (if at least 1 s
  of such frames, otherwise skip the update), so a contaminated dictation does
  not pull the profile toward the interferer. Enrollment uses the same rule
  after an initial plain mean of the first k. An update runs at most one PVAD
  pass (with the pre-update profile, shared by gating and recalibration) and
  one embedder pass; the CostReport counts exactly that.
- Recalibration (A8): the scorer keeps a running per-user estimate of the 10th
  percentile of logit P(tss) over frames of the user's own update dictations
  with P(tss) >= 0.5, and shifts output logits so that this percentile matches
  the train-population value. The aim is that one global tau gives every user
  the same budget. Kept only if it lowers pooled interferer words kept at the
  0.5 % budget on dev without breaking G; otherwise reported as negative.

## 9. What would change our mind

- If `none` is within the CI of `film_cos` on S3 and S4, the PVAD is a
  near-field VAD and not a speaker model; we would recommend W1 or an energy
  baseline instead.
- D1 (revised in reviews eval-r1 and eval-r2, before any data). On S4
  mixtures with one second dictator, per mixture, the AUC of target-only
  (label 1) against interferer-only (label 2) frames in the target log-odds,
  under the target's own profile, the interferer's profile (from its own clean
  dictations, disjoint from every mixture utterance of that speaker, other
  project first), a seeded random unit vector, and an unrelated same-sex dev
  speaker (control: real embeddings occupy a narrow cone, so a random direction
  may be out of distribution; the unrelated-speaker AUC is the reported
  sensitivity check on the random baseline). The model is shown to use identity iff the joint
  (target, interferer) bootstrap CI of mean AUC_swap lies below 0.5 and that
  of mean(AUC_own - AUC_random) lies above 0. Being a rank statistic per
  mixture, it is immune to logit contraction and mixture-wide shifts. Pooled
  log-odds deltas and pooled AUCs are reported as diagnostics only; retained
  and excluded mixtures are counted by speaker, role and reason, and the
  conclusion holds for the retained population only.
- If W1 at equal budget keeps fewer S4 overlapped interferer words, H2 is
  refuted; the recommendation becomes W1, or a fusion if they err differently.
- If G fails for every configuration, PVAD is not shippable as tested.
- If 3-dictation results are far worse than 30, onboarding must collect more
  dictations before filtering turns on.

## 10. Risks and confounds

- **Channel shortcut.** Each LibriSpeech speaker has a distinctive recording
  chain, so a model (and the embedder) can identify recordings by channel, not
  voice. In real use the user and spouse share the room and microphone.
  Mitigations: enrollment and mixture targets from different LibriVox projects
  where the speaker has them (otherwise different chapters; results reported
  separately for `cross_project` and the rest, as the harness flags them),
  independent devices per enrollment dictation, W0's shared room/microphone
  colouring on both sources, and the device-mismatch condition. The residual risk is reported, and the AMI check
  set (real shared rooms) is the honest test if W0 builds it.
- Read speech (LibriSpeech) versus dictation; synthetic rooms versus real.
- Overlap labels depend on W0's activity rule; label noise at boundaries caps
  frame metrics.
- The profile is one averaged embedding, so its invertibility is that of the
  embedder (W4's measurement applies). A W4 protection transform R applied to
  the stored vector would need the PVAD's first layer to see R(e) (retrain) or
  W' = W R^T folded in at load time; flagged to W4, not solved here.
- Few dev speakers (73, about 36 per half) give wide CIs; differences smaller
  than the CI are reported as not resolved, not as wins.
- Frame-level statistics use one score representation, the target log-odds
  z_tss - logsumexp(z_ns, z_ntss) in float64 from the model's logits, so float32
  probabilities cannot saturate into ties. Point estimates and every bootstrap
  resample are exact weighted rank statistics (`metrics.FrameRanks`); there is
  no binning.

## 11. Packages

None beyond the shared venv. W1's embedder adapters (`lfspk.embed.embedder`,
interface final at commit 711551d) provide model loading; run metadata records
the repository commit and the embedder's weights_sha256.
