# W5 target-speech extraction: design (pre-registration)

Status: written 2026-10-21 before any code, data generation, training or
evaluation. Changes after the first result are appended in a dated
"Amendments" section, never edited in place. Owner: W5. Directory
`lfspk/extract/`, tests `tests/test_W5_*.py`, outputs
`/mnt/hd/localflow-speaker/runs/W5/`.

## 1. Question and motivation

W1-W3 score frames and drop whole Parakeet words. On dev-v1 (built-in, clean
enrollment, k = 10, headline targets) the oracle frame labels at the 0.5 %
budget still keep 18.5 % of interferer words pooled over S1-S4 (S1 56.7 %,
S2 37.4 %, S3 1.4 %, S4 48.9 %), and the oracle itself raises S0 WER by
1.08 points (W0, `runs/W0/eval/oracle/dev-v1-all`). Word dropping also cannot
recover what interference already destroyed: before any filtering, target
coverage (correctly recognised target words) is 96.9 % on S0 but 77.0 % on S4
and 80.2 % on S2, and Parakeet loses more than half the target words in 18 % of
S4 and 16 % of S2 mixtures (W0 sanity, target dropout). The working hypothesis
(W0's diagnostic pending) is that the surviving interferer words overlap the
user's speech. The orchestrator's summary of W0's baselines (0d13957) adds
that the oracle keeps every interferer word in an overlap region, so overlap
is where word filtering fails.

W5 asks: **does a small speaker-conditioned mask on Parakeet's input features
(VoiceFilter-Lite style) reduce interferer words in the transcript and recover
target words lost to overlap, without harming clean or noisy single-speaker
dictation, at a cost that is negligible next to Parakeet's encoder?**
Parakeet stays frozen and unchanged.

## 2. Prior work followed

- VoiceFilter-Lite (Wang et al., Interspeech 2020, arXiv:2009.04323): a mask
  on the ASR's own filterbank features, so no waveform reconstruction; an
  asymmetric L2 loss, g(x, a) = x for x <= 0 and a x for x > 0 on
  x = S_clean - S_enh, with a = 10, because most WER damage came from
  over-suppression (false deletions); and "adaptive suppression strength",
  S_out = w S_enh + (1 - w) S_in, with w driven by a side output predicting
  overlapped speech, because feature masking "will often harm" a noise-robust
  ASR under non-speech noise. On realistic queries, plain L2 masking improved
  speech-interference WER but degraded non-speech-noise WER; asymmetric loss
  plus adaptive w removed that harm. 3 x 512 LSTM, 2.2-6.8 MB.
- VoiceFilter (Wang et al. 2019): soft magnitude mask conditioned on a
  d-vector; the generic enhancement-hurts-ASR caveat.
- Personal VAD 2.0 / W3: FiLM conditioning plus an in-network cosine score
  beat concatenation; W3's dilated depthwise-separable convolution trunk runs
  on the Neural Engine with a fixed cost per second. W5 reuses that trunk
  design (its own copy of the architecture, not W3's module, so W3's code
  changes cannot alter W5 checkpoints; W3 is credited).

## 3. Where the mask applies (reproducible in LocalFlow's front end)

LocalFlow's `VDSPFrontEnd.compute` (read-only, `Sources/Parakeet/ParakeetFrontEnd.swift`
at origin/main 47a6b6c) and NeMo's FilterbankFeatures compute, per chunk:
pre-emphasis -> centred STFT -> |X|^2 -> Slaney mel power P [128, T]
(one sgemm) -> log(P + 2^-24) -> per-feature normalisation over the valid
frames -> encoder. Choice: **a multiplicative mask on mel power P, after the
filterbank and before the log; the log and per-feature normalisation are then
recomputed on the masked power.**

    X   = norm(log(P + eps))                    # what LocalFlow computes today
    m, u = net(X, e)                            # mask in [g_min, 1], interference prob.
    w   = safeguard(u)                          # section 7
    X'  = norm(log(m^w * P + eps))              # what the encoder sees

Reasons:
- Physical meaning: m approximates the share of a bin's energy that belongs to
  what Parakeet should hear (a ratio mask); suppression has a meaning in dB
  and a floor g_min can bound it.
- Recomputing the normalisation keeps the encoder input in its trained
  distribution (zero mean, unit variance per bin over the chunk). Masking
  after normalisation would be wrong: a normalised value of 0 is the bin's
  mean, not silence, so "suppress" has no consistent meaning there.
- Where P >> eps the mask is additive in the log domain,
  log(m P + eps) ~= log m + log P, so VoiceFilter-Lite's linear interpolation
  of log features with weight w is approximately m^w here, and the loss in
  section 5 (on log m) is approximately the un-normalised feature error. Both
  are approximations, not identities (r1 #4): where m^w P is within a few
  orders of magnitude of eps = 2^-24 the guard dominates (for P = 100 eps and
  m = 10^-3 the masked power is 0.1 eps, so log(m P + eps) ~= log eps, not
  log m + log P). How often that regime occurs is not derived here: the share
  of (t, f) bins with g_min P < 100 eps is measured on stage-0 inputs per
  scenario and reported (bins where even the floored mask stays above
  100 eps are outside it).
- LocalFlow cost: the mel power already exists inside `compute`; the change is
  one element-wise multiply before the existing log, plus one more
  log-and-normalise pass (128 x T, negligible) and the network. The network
  input X is the existing output, so the feature cost is zero.

g_min = 10^(-30/10) (-30 dB), fixed, no sweep. Reason: Parakeet still
transcribes interferers at 10-20 dB SIR (W0 interferer yield: S2 3.9 %, S1
2.3 % of reference words), and S3's SIR goes down to -6 dB, so removing an S3
talker to about 25 dB below the target needs about 30 dB. Because the training
target keeps the room noise (section 4), the ideal mask rarely reaches the
floor. What the floor bounds is **power** removed per bin, not encoder
distortion or word loss (r1 #4): per-feature normalisation over the recording
undoes any attenuation that is constant over time in a bin (a constant log m
is subtracted with the mean), while time-varying attenuation of a few dB can
still delete a word. Safety therefore rests on the measured guardrails
(sections 7 and 9), not on the floor. Unit-test fixtures pin the arithmetic:
a quiet-bin fixture (P near eps, the guard regime), a constant-mask fixture
(X' equals X up to the normalisation epsilon) and an absent-speaker fixture
(section 4's target for a conditioning speaker not in the mixture).

App chunking (disclosed mismatch). LocalFlow compacts silence
(`ParakeetSilenceCompactor`) and then transcribes overlapping 15 s chunks
during recording, normalising each chunk on its own; only the last chunk is
transcribed after key release. The harness transcribes each whole mixture
(3-20 s target plus 0.3-1 s lead and tail) without compaction. W5 trains and
evaluates on whole mixtures like the harness and computes the mask per
recording; in LocalFlow the mask would be computed per chunk. The network's
receptive field is about +-3.2 s, so this matters only near chunk edges and
through the normalisation statistics; a chunked-evaluation check is a listed
follow-up, not part of this design.

## 4. Training target

Target signal y* = **target reverberant image + noise image** (ambience,
noise event and device self-noise, as W0's mixer renders them, after the
shared limiter gain). Ideal mask m* = clip(P(y*) / P(mix), g_min, 1), with P
the mel power through the same front end (pre-emphasis included).

Reasons:
- Reverberant, not dry: Parakeet is robust to reverberation and W0's RIRs are
  delay-normalised, so the reverberant image is time-aligned with the labels;
  asking a 0.75 M-parameter mask to dereverberate adds artefacts and
  over-suppression of the target's own tail, the error the owner fears most.
- Noise kept (T2 primary): the owner's problem is other people's words. A
  noise-robust ASR is usually hurt, not helped, by feature-domain denoising
  (VoiceFilter-Lite Table 2), so the primary model is trained to leave
  non-speech noise in place: for target-only audio, with or without noise,
  y* = mix and m* = 1, which teaches the clean-speech pass-through directly.
- The owner asked whether this could also help in general noisy environments.
  That is tested, not assumed: variant **T1** (y* = target image only, so the
  mask also removes noise) is trained with everything else identical and
  compared on the noise-only check (section 9.4).
- TV (S2): W0's TV image contains the programme's speech and its music bed
  through a compressor and loudspeaker colouring; they cannot be separated, so
  the whole TV image counts as interference and the music bed is removed with
  it. Stated, not hidden; the noise-only check reports music separately.
- Absent target (the key is held while only someone else talks): y* = noise
  only, m* removes all speech.

## 5. Loss

Primary: asymmetric L2 on the log mask, which approximates the error in
un-normalised log-mel features wherever m P >> eps (section 3; not in the
guard regime, and not the error after normalisation):

    x  = log m*(t, f) - log m(t, f)          (> 0: over-suppression of y*)
    L_mask = mean over valid (t, f) of g(x, a)^2,   g(x, a) = x if x <= 0 else a x,   a = 10

a = 10 as in VoiceFilter-Lite, fixed, not tuned. Working in log-mask space
makes the loss level-invariant (target level spans -34 to -20 dBFS) and makes
the asymmetry physical (energy removed from y*), which would not hold after
per-feature normalisation, where removing interferer energy shifts every
frame's normalised value.

Auxiliary: per-frame binary cross-entropy of u(t), the probability that
speech of anyone other than the conditioning speaker is present (labels
relative to the conditioning identity, section 8; for a present target this
is W0's `interferer_active`, label 2 or 3), weight lambda_aux = 0.1, fixed. It drives the safeguard (section 7) and costs
one 1x1 output channel.

Variant **V-asr** (ASR-aware; run only if the primary passes stage T's gate
and fits a shared lease of at most 14 GB): fine-tune the selected primary
checkpoint for 25 % of its step budget with L_mask + lambda L_enc, where
L_enc = mean squared difference between frozen Parakeet `base` encoder outputs
(tap 24, `lfspk/probe` indexing) on X' and on X* = norm(log(P(y*) + eps)),
each normalised by the mean square of the latter. lambda is set once, so that
the two terms are equal on average over the first 100 batches; no other value
is tried. Encoder-output matching was chosen over the TDT loss on the target
transcript because it needs no decoder pass, keeps the timing that word
timestamps depend on, and does not ask the mask to fix Parakeet's own errors
on clean speech. bf16 autocast for the encoder in V-asr only (disclosed).

## 6. Model and cost

    X [128, T] at 100 fps (Parakeet's normalised log-mel, already computed)
    stem: Conv1d(128 -> C, k = 3, stride 2) + GELU                        -> 50 fps
    blocks 1..4: DS block with FiLM(g(e)), dilations 1, 3, 9, 27
    cos branch : s_t = cos(W_u h_t, W_v g(e)), D_p = 32
    blocks 5..8: DS block with FiLM([g(e), s_t]), dilations 1, 3, 9, 27
    mask head  : LayerNorm, Conv1d(C -> 2 x 128) -> two 10 ms frames per step ("sub-pixel")
                 log m = log(g_min) * (1 - sigmoid(z))       -> m in [g_min, 1]
    aux head   : Conv1d(C -> 2 x 1) -> u(t) per 10 ms frame
    DS block(x) = x + PW2(GELU(PW1(FiLM(DWConv_k5,dil(LN(x))))))   PW1: C -> 2C, PW2: 2C -> C
    g(e) = GELU(Linear(e, 64)), e = unit profile direction (192-d)

Receptive field about +-3.2 s (non-causal, as the product allows: transcription
runs after key release). The 50 fps trunk with two output frames per step keeps
10 ms mask resolution at half the trunk cost. FiLM generators start at the
identity. Convolution only, for the same Neural Engine and fixed-cost reasons
W3 gives (DESIGN W3 4.2).

Sizes. Primary **M: C = 128**, about 0.75 M parameters and about 31 M MACs per
audio second (analytic, to be checked with `torch.utils.flop_counter`). Fallback
S: C = 96 (about 0.43 M, 18 M MACs/s), used only if M misses the latency
budget. No size sweep.

Cost budget, relative to Parakeet's encoder. The FastConformer encoder
(24 layers, d = 1024, 12.5 frames/s) costs on the order of 7-8 G MACs per
audio second (my estimate; measured with the flop counter on `base` in stage I
and recorded). Budget:
- MACs: the mask network at most 1 % of the encoder's MACs per audio second.
- CPU latency (W0's CPU_ENV: no GPU, one thread): network plus the extra
  log-and-normalise pass at most 5 ms per audio second (median over 30 fixed
  inputs of 10 s and 20 s), reported beside the same measurement of Parakeet's
  encoder.
- Post-release latency: LocalFlow transcribes chunks while recording, so only
  the final chunk (at most 15 s) waits for the mask after release: at most
  75 ms on one CPU core at the budget; Neural Engine latency is not measurable
  here and is not claimed.
- Profile: the conditioning vector comes from W1's profile, which LocalFlow
  would already store for any W1/W3 approach; W5 adds no stored state. The
  embedder runs only at enroll/update, never per transcription.

## 7. Clean-speech safeguard

The owner's priority makes this central. Three layers, all pre-registered:

1. Training: target-only examples (S0 and the noise family, 30 % of examples)
   have m* = 1 everywhere, and the asymmetric loss charges over-suppression
   ten times more.
2. Adaptive suppression strength: the applied mask is m^w(t), with
   w(t) = s * ubar(t), ubar the centred 0.5 s moving average of u, and global
   strength s in {0.5, 1} (VoiceFilter-Lite's interpolation with a
   non-causal smoother instead of its causal one).
3. Bypass: if max_t ubar(t) < theta_b for a recording, the mask is not applied
   at all: the front end returns the **original** features, i.e. the output
   of the unmodified path (NeMo's own preprocessor in the harness,
   `VDSPFrontEnd.compute` in LocalFlow), not W5's recomputation with w = 0
   (r1 #2). In LocalFlow a bypassed recording runs the unchanged pipeline on
   that single recording, so its transcript is today's. In the harness a
   bypassed recording is not transcribed again: it **reuses B's cached
   transcript** (r2 #2), because re-running it in a different batch, with
   different padding, could flip a borderline decode through shape-dependent
   floating-point reductions. Only masked recordings go through the hook
   (section 10.2). theta_b is fixed per checkpoint,
   before any dev evaluation, as the 99th percentile of max_t ubar over 500 S0
   renders of the held-out train speakers (section 8, profiles drawn with W3's
   policy at k = 10, clean, matched), so that about 1 % of clean recordings
   from unseen speakers reach the mask at all. The bypass rate on dev S0 and on
   the noise-only set is reported.

Inference configurations (no retraining), in order from most to least
conservative: C4 = bypass + adaptive, s = 0.5; C3 = bypass + adaptive, s = 1;
C2 = adaptive, s = 1, no bypass; C1 = raw mask, w = 1. Selection between them
is in section 9.3.

## 8. Training data (train split only)

Examples come from W0's mixer (`MixtureGenerator("train", speakers=...)`), on
the fly, following W3's pattern and reusing W3's train speaker partitions
(`lfspk.pvad.enrollment.librispeech_partitions`, enrollment and mixture pools by
LibriVox project, then chapter; the 194 `same_chapter` speakers are never
targets) and W3's enrollment draw policy (k in {1, 2, 3, 5, 10, 20, 30},
contamination 0 / 0.2 / 0.4, per-dictation device). W5 writes its own adapter
because W3's `W0Source` discards the source images W5's target needs; it
mirrors W3's sampling (same pools and target-length filter) and keeps
`target`, `interferers` and `noise_parts`.

- **Held-out train speakers**: 48 target-eligible train speakers chosen by
  stable SHA-256 order (24 female, 24 male) are excluded from every training
  role (target, interferer via the generator's `speakers` pool, impostor).
  They serve stage 0, the training monitor and the theta_b calibration, so W5
  never needs dev for anything but the final evaluation. They stay in W3's
  bank, so they are passed as `absent` to `draw_impostor` and are never an
  impostor profile. Their voices could still enter training through
  contaminated enrollment embeddings of training speakers (r1 #7). W3's bank
  shards record each contaminated row's contaminating speakers
  (`contaminator`); before training W5 audits every contaminated row, counts
  those whose contaminator is a held-out speaker, and regenerates exactly those
  rows into a W5 overlay bank (`runs/W5/bank/`): the same utterance, device and
  W3 seed rule, rendered with `render_paired(("S0", "S4"), ...)` by a
  `MixtureGenerator("train", speakers=<train minus held-out>)`, embedded with
  the same redimnet2-b2 weights, the new contaminator recorded and checked to
  be outside the held-out set. The overlay has its own identity record (W3 bank
  hash, replaced row ids, W0 code and index hashes); the count of replaced rows
  is reported. The same rule applies to a windowed bank if one is built.
- Checks taken from W3 (2026-10-21): the bank file's SHA-256 is verified
  against `bank_meta.json` (b34c8b68...1801) and `bank.check` is called on the
  training speakers' partitions before training; mixture targets come only
  from `partitions[spk].mixture` (`check_mixture_targets` on every example);
  every render asserts `meta["target"]["utt"]` is the requested utterance,
  since an explicit target bypasses the generator's `speakers` pool; and
  `target + sum(interferers) + noise == audio` is checked per example before
  the target is built.
- Scenario mix: S0 0.2; **N** (noise-heavy target only) 0.1; S1, S2, S3, S4
  0.175 each. N = an S1 render without its interferers (ambience plus MUSAN
  event, train files), with the noise image raised by U[0, 15] dB (acoustic
  SNR then about -5 to 25 dB), both components rescaled together if the peak
  exceeds 0.95. Built-in device always (the frozen sets score built-in
  mixtures); RIR mode `mixed` with p 0.2, else `coherent` (as W3).
- Absent target, p 0.05 over all scenarios: the conditioning profile belongs
  to another training speaker who is not in the mixture (W3's `draw_impostor`),
  y* = noise only. Kept rare because it is also what teaches the mask to remove
  a mismatched user; its effect on the guardrail is measured, not assumed.
- Training labels are relative to the conditioning identity (r1 #3), so the
  mask target and the aux target never disagree. With c the conditioning
  speaker: interfering speech at frame t = activity of any speech source other
  than c. Present target: W0's `interferer_active`. Absent target: the
  rendered target's `target_active` OR `interferer_active` (every voice is
  someone else). N family with a present target: all zero, because its
  interferers are removed. N with an absent target: the rendered target's
  `target_active`. N labels are always recomputed from the kept components,
  never copied from the S1 render. W0's frozen evaluation labels are not touched; these are W5's
  training labels only, built in `lfspk/extract/data.py` and unit-tested on
  the three cases.
- Conditioning vector, and a pre-registered check. At evaluation the profile is
  W1's `EmbProfile` from `lfspk.embed.factory:make(embedder="redimnet2-b2",
  rule="robust", norm=<W1's Stage D choice>, ...)`, using only enroll/update
  and `profile.directions[0]` (W1, 2026-10-21). W1 embeds a dictation as the
  mean of unit 1.5 s window embeddings; W3's bank embeds whole dictations. Before
  training, on 20 held-out train speakers with 10 rendered dictations each:
  if the median cosine between W1-style and bank-style profiles of the same
  dictations is at least the median cosine between two bank-style profiles of
  the same speaker from disjoint dictation sets (the within-speaker spread the
  model is trained on), W3's bank is used; otherwise W5 builds a windowed bank
  with W1's `enroll_windows` on the same renders as W3's bank and trains on it.
- Crops: features normalised over the whole mixture, then a random 8 s crop
  (shorter mixtures padded and masked out of the loss), so training and
  inference see the same normalisation.
- Determinism and resumption as in W3 (pure function of seed and example
  index; deterministic CUDA; identity record in each checkpoint; resume
  refuses mismatches).
- Optimiser: AdamW, lr 2e-3, weight decay 0.01, 1000 warm-up steps then cosine,
  batch 32, gradient clip 5, FP32. Fixed step budget, identical for every run:
  the largest multiple of 1000 steps fitting about 3 h of wall time at the rate
  measured in a few-minute smoke of the primary run, recorded as an amendment
  before the first run. For scale, W3 measured about 32 mixtures/s per run
  with 6 render workers on the NVMe mirror (two runs in parallel), which would
  give about 10,000 steps of batch 32 in 3 h; the smoke decides. Final
  checkpoint only; no early stopping, no checkpoint picking.
- Monitor (logged, never used for a choice): on 200 fixed held-out-train
  mixtures per family, log-mask error split by over- and under-suppression,
  and u's frame AUC.

Training runs (all seed 0 unless stated): **R1** primary (M, T2, film_cos,
a = 10) at seeds 0, 1, 2; **R2** unconditioned (no embedding; FiLM identity,
no cos branch; same example stream including absent-target examples, which it
cannot resolve, as in deployment); **R3** T1 target (noise removed too);
**R4** V-asr fine-tune of R1 seed 0 (conditional, section 5). About 6 runs of
3 h, each a shared GPU lease of 6 GB, 6 render workers (about 1.1 GB RSS
each, W3's measurement), 12 GB memory; at most two runs at a time.

## 9. Evaluation (needs a contract amendment; proposal in section 10)

### 9.0 Stage 0: feasibility screen and pipeline check (held-out train speakers, before training)

On 150 renders per family (S0, N, S1-S4) of the held-out train speakers,
Parakeet `base` transcribes: **B** (NeMo's own preprocessor, as the harness
cache), **B*** (W5's recomputation with log_mask = 0, a diagnostic), **O2**
(the clipped power-ratio mask m* for the T2 target, floor included, applied
raw, w = 1, through the deployed path), **O1** (the same for T1), and **W_o**,
the oracle word filter on the same examples: W0's oracle frame scores (1 on
labels 1 and 3) under the contract's decision rule, with tau set on these
stage-0 examples to the 0.5 % gross budget (section 9.2; for an oracle that is
its definition here). Attribution and WER with W0's functions
(`align.attribute`, `refs.placed_words`, imported unchanged).

What stage 0 can and cannot show (r1 #8): it is a feasibility screen, not a
ceiling. The clipped ratio mask optimises a power-reconstruction surrogate;
cross terms can make P(y*) exceed P(mix), where it is clipped to 1; and a
learned mask with adaptive weakening can avoid errors that the raw oracle
mask makes. Failing the screen therefore means only that this surrogate mask,
applied raw through this path, does not work with Parakeet on these mixtures,
which is reason to stop and consult the orchestrator, not proof that no
feature mask can beat word filtering. Held-out-train numbers are not
comparable with dev's 18.5 %; the only comparison is with W_o on the same
examples.
- Parity diagnostic: B* against B (transcripts identical, WER difference per
  family). Every claim is measured against B (9.2), so any parity error
  counts against F; no exact-parity claim is made. The diagnostic decides
  only whether to fix W5's recomputation path before training: it is fixed if
  B* differs from B on more than 1 % of transcripts or by more than 0.05 WER
  points in any family.
- Baseline batching sensitivity (r2 #2, renamed r3 #2): B is computed once in
  W0's own batching (length-sorted, batch 16, as `lfspk.harness.asr`). It is
  then re-run with the same model and no hook, in batches of the same size
  whose membership is shuffled with a fixed seed, so each item sees other
  padding. The share of transcripts that change and the WER difference per
  family are reported. This describes unmasked B only. It does **not**
  quantify batch effects on masked items: a mask can move a token close to a
  decoding boundary where unmasked B is stable, and removing bypassed items
  changes batch membership anyway. It is a measurement, not a gate.
- The guard-regime share (section 3) is reported.
- Stop rule (pre-registered; paired joint speaker bootstrap over the 48
  held-out speakers, B = 2000): stop and report if (a) R(O2) >= R(W_o) pooled
  over S1-S4 (point estimates), or (b) O2's gross target-word loss L+
  relative to B (9.2), pooled over the six families, exceeds 1.0 % and the
  lower end of its 95 % CI exceeds 0.5 %. A single word cannot trigger (b).
  On S0 and N, m* = 1 by construction, so (b) is about S1-S4 targets.

### 9.1 Systems

**B** (keep everything with NeMo's preprocessor: the existing harness cache
and the reference for every claim); **B*** (W5's recomputation with
log_mask = 0; diagnostic only, never the reference, r1 #2); **F** = a trained
mask with an inference configuration, whose bypassed recordings return the
original features (section 7); **W** = a word-filter scorer (W1's and W3's
selected configurations, their saved scores, the contract's rule); **F+W** =
mask, then the word filter applied to F's transcript with the scorer's frame
scores of the original audio (stacking; optional, cheap since scores are
saved).

### 9.2 Metrics (per scenario S0-S4, overlap / non-overlap, pooled S1-S4; dev-v1 primary coherent mixtures of headline targets, as the contract)

With W0's time-constrained alignment and attribution, unchanged, and W0's
exact re-aligned accounting for every system (not the fixed-alignment upper
bound), so that front ends and word filters are counted the same way:
- **R** = interferer-attributed hypothesis words of the system / those of B,
  ratio of sums. For a word filter this is the contract's "interferer words
  kept", so R is the shared primary metric.
- **Target-word losses and gains by reference-word identity** (r1 #1). For
  each target reference word r, correct_X(r) means r is an exact match in X's
  alignment. Gross loss **L+** = #{r : correct_B(r) and not correct_sys(r)} / N;
  gain **G** = #{r : not correct_B(r) and correct_sys(r)} / N; net L = L+ - G
  (N = target reference words). **Every budget applies to the gross loss L+,
  never to the net**: recovered words cannot pay for newly lost ones. G and
  net L are reported separately. G can be positive even for a word filter,
  because a deletion can change the alignment so that a token B already had
  becomes a match (r2 #1). Recovery is therefore claimed only through
  **G_u**, the gain in words that are unreachable by filtering (9.3, H2),
  which is 0 for any word filter. For a word filter, L+ is the contract's
  "removed", and W0's fixed-alignment value is reported beside it.
- Target WER (insertions included) and target-side error E = (S + D) / N;
  coverage; insertions attributed to neither source ("other", to catch
  mask-induced hallucinations); dropout mixtures before and after.
- **S0 guardrail**: dWER_S0 = WER_S0(system) - WER_S0(B), re-aligned, paired.
  B* is never the reference; B* - B is reported as a diagnostic.
- CIs: W0's joint speaker bootstrap (B = 2000, seed 0, all roles), every
  comparison paired inside each resample. On half B, every quantity fitted on
  half A (each word filter's tau, F's configuration) is held fixed in every
  resample (r1 #5), so half-B CIs are conditional on the half-A selection and
  calibration; theta_b comes from train speakers and is fixed throughout.
- Cost and latency (section 6).

### 9.3 Selection and the headline comparison

Pre-registered, on W0's canonical dev halves.
- F, on half A only: among C1-C4 of R1 seed 0, those with S0 non-inferiority
  against B (upper end of the paired 95 % CI of dWER_S0 below +0.10 points)
  and a pooled S0-S4 gross loss L+ of at most 0.5 % (point estimate; the word
  filters' budget) are eligible. The reference is the eligible configuration
  with the lowest pooled S1-S4 R; the selected configuration is the most
  conservative eligible one (order C4, C3, C2, C1) whose paired CI of (its R -
  the reference's R) has its upper end below +0.02, i.e. non-inferior to the
  reference within two points (the reference qualifies trivially; W3's rule).
  If none is eligible, F fails the guardrail and W5 reports that as its result.
- W, on half A only, chosen separately for each pairing (r1 #6) from the
  candidate word filters (W1's and W3's selected configurations):
  1. **equal budget**: each candidate's tau is the largest tau whose half-A
     pooled S0-S4 L+ is at most 0.5 %; W is the candidate with the lowest
     half-A pooled S1-S4 R at its tau.
  2. **matched S0 harm**: each candidate's tau is the largest tau whose half-A
     dWER_S0 (re-aligned, the same accounting as F's) does not exceed F's
     half-A dWER_S0; W is the candidate with the lowest half-A R at its tau.
     Keep-everything (no removal, dWER_S0 = 0) is one of the attainable
     operating points. If no attainable threshold of any candidate matches
     (F's half-A dWER_S0 is negative and below every candidate's), the pairing
     is reported as infeasible ("no word-filter threshold reaches F's S0
     harm") and F is compared with B only.
- Headline, on half B (held out): F against B and against each pairing's W,
  with the half-A choices fixed. Reported: R, L+, G, net L, E per scenario,
  dWER_S0, overlap vs non-overlap, with paired CIs of F - W and F - B.

**Confirmatory family** (half B only, r1 #5): four claims, each judged by a
Bonferroni-adjusted interval, the 98.75 % paired joint-bootstrap percentile CI
(alpha = 0.05 / 4):
- **H1a** F keeps fewer interferer words than W at equal budget: CI of
  R_F - R_W (pooled S1-S4) entirely below 0.
- **H1b** the same at matched S0 harm (not tested if that pairing is infeasible;
  the family size stays 4).
- **H2** F recovers more target words that no word filter could produce than
  it loses (r2 #1). A target reference word r is **unreachable by filtering**
  if B's hypothesis contains no token with r's normalised text that is
  time-compatible with r (W0's `align.compatible`, 0.5 s tolerance), anywhere
  in the hypothesis and not only in B's alignment. A word filter only
  deletes B's tokens, so it can never make such a word correct. G_u =
  #{r : r unreachable by filtering and correct_F(r)} / N. H2 is supported if
  the CI of G_u - L+ (pooled S1-S4) lies entirely above 0. G_u is 0 for every
  word filter by construction, so the claim is recovery that word filtering
  cannot provide, net of every word F loses. Requiring the recoveries to
  exceed the losses follows the owner's priority, since a lost word costs more
  than a stray one. The change in target-side error E_F - E_B (pooled S1-S4)
  is reported beside it as a secondary, descriptive figure. Under
  re-alignment, deletions alone can lower E, so E is not evidence of
  recovery.
- **H5** clean-speech safety: upper end of the CI of dWER_S0 (F - B) below
  +0.10 points (non-inferiority).
Otherwise each is "not resolved". Claims about the selected F are made on
half B only; its full-dev (73-speaker) numbers are reported as exploratory.

**Exploratory** (95 % CIs, labelled exploratory, no confirmatory claim):
- **H3** the advantage is concentrated in overlap: (R_F - R_W) more negative
  for interferer words in overlap regions than outside (half B).
- **H4** identity matters: R1 keeps fewer interferer words than R2 on S4 (and
  reported on S1-S3), both at C1 (fixed, so all 73 speakers may be used).
- **H6** noise (9.4): selected F within +0.25 points of B per SNR band (half B
  speakers); C1 and T1 at C1 (fixed) on all speakers; prediction stated in
  advance: T1 does not improve on B at SNR >= 5 dB.
- **H7** (if R4 runs) V-asr lowers E pooled S1-S4 versus R1 at the same
  inference configuration, with dWER_S0 non-inferior.
- **H8** (optional) F+W, with W's tau fitted on half A so that the combined
  pooled L+ relative to B is at most 0.5 %, keeps fewer interferer words than
  F alone.
- App-path replay (optional, r3 #2): the selected F's masked half-B
  recordings are transcribed again from the identical stored mask outputs, at
  batch size 1, which is LocalFlow's path. Reported: the share of transcripts
  that differ from the batched run, and the change in R, L+ and dWER_S0 if
  the batch-1 transcripts are used instead. This is a partial check of batch
  effects for this one configuration, not a bound for the others. The replay
  is a separate artefact (r4 #2), kept apart from the headline cache:
  - It lives in its own directory, `runs/W5/replay/`.
  - Its identity records batching mode `single` and pins the hash of the
    batched ASR cache it is compared against.
  - The cache loader requires batching mode `batched` and refuses any other,
    so the replay can never satisfy or overwrite a headline-cache load.
  - Selection, headline and confirmatory code read only the batched
    artefact.
- Other scenarios, enrollment conditions, seeds 1 and 2 of R1 at the selected
  configuration (seed spread reported beside every difference), and m1.

### 9.4 Noise-only check

The owner asked about general noisy rooms; generic enhancement in front of a
robust end-to-end ASR often raises WER, so it is measured. Proposed frozen set
(W0 to render): the first 4 dev targets per speaker, coherent room, no
interfering speech, non-speech noise at acoustic SNR 20, 10, 5 and 0 dB, in
two families, MUSAN noise (dev files: events and continuous, over DEMAND dev
ambience) and MUSAN music without vocals (dev files), paired with the S0 render
of the same target (same room, level and device). 73 x 4 x 4 x 2 = 2336
mixtures (about 6 h); a sealed test twin. Systems: B, F (selected), F at C1,
T1 at C1, with B* as a diagnostic. Metric: target WER, E, L+ and G per SNR band
and family, paired CIs against B; bypass rate per band.

### 9.5 ASR identity

Everything is reported on `base` (the harness's Parakeet TDT 0.6B v2, FP32).
The app ships the ternary `m1`; W2's loader (`lfspk.probe.models.load_parakeet("m1")`)
makes an m1 cache cheap, so B, B* and the selected F are also reported on m1
(FP32 arithmetic; the app's FP16 Core ML is not reproduced). The mask is
trained on features only (except V-asr, which uses `base`), so it is
ASR-agnostic by construction; m1 tests that claim.

### 9.6 Enrollment conditions

Headline: built-in, clean, k = 10. The selected F is also reported at
k = 3 / 30, 20 % contaminated, and mismatched device (W0's conditions), with
the profile from W1's factory under each condition.

## 10. Proposed contract amendment (for the orchestrator; W0 implements)

Why not W0's draft audio-in/audio-out hook: a mask on 128 mel bins cannot be
turned back into a waveform that reproduces X' through Parakeet's front end
(mel power discards phase and the 257 -> 128 bin structure; any resynthesis
would add its own artefacts and would not be what LocalFlow runs). The
interface is therefore a transform on Parakeet's preprocessor, split into a CPU
stage that needs the profile and a GPU stage that needs only cached arrays.

1. **Front-end protocol** (`lfspk/extract/api.py`, W5; added to the contract
   beside `TargetSpeakerScorer`):

        class FeatureFrontEnd(Protocol):
            name: str
            def enroll(self, utterances) -> Profile          # as the scorer API
            def update(self, profile, utterance) -> Profile  # as the scorer API
            def analyse(self, profile, audio) -> MaskOutput  # CPU, deterministic
            def cost(self) -> CostReport

        MaskOutput: log_mask float32 [128, N // 160 + 1] in [log g_min, 0]
                    (Parakeet's feature frames, not the contract's 10 ms frame
                    count), u float32 [N // 160 + 1] in [0, 1]

   and one pure function, `lfspk.extract.frontend.apply(audio, mask_output,
   config) -> float32 [128, N // 160 + 1] | None`, which computes P, the
   configured weight w(t) (C1-C4, theta_b, s from `config`), and X' =
   norm(log(m^w P + eps)). It returns None when the configuration bypasses the
   recording; the caller then uses the original features of the unmodified
   path (NeMo's preprocessor output in the harness), never a recomputation
   (section 7, r1 #2).
2. **Caching and storage** (r1 #9). Stage A (CPU workers, no GPU): for each
   (front-end checkpoint, enrollment condition, mixture), `analyse` output
   stored as `<key>.npz` {log_mask float16, u float32} under a directory with
   W0's IDENTITY.json / COMPLETE.json pattern (checkpoint SHA-256, front-end
   kwargs, set id and hash, condition list, expected-key coverage). Size:
   128 bins x 100 frames/s x 2 bytes = 25.6 kB per audio second, about
   92 MB per audio hour per (checkpoint, condition), plus 0.4 kB/s for u.
   dev-v1's 5110 mixtures are about 14 h (W0: about 10 h primary plus the
   mixed-mode subset), so about 1.3 GB per (checkpoint, condition) and about
   0.6 GB for the noise set. Plan: stage A is cached persistently for the
   headline condition only (6 checkpoints, about 12 GB in total with the noise
   set), under `/mnt/hd/localflow-speaker/runs/W5/masks/` on the HDD (4.9 TB
   free on 2026-10-21; not the NVMe mirror). The selected F's 11 other
   conditions are processed one condition at a time: stage A writes that
   condition's arrays (about 1.3 GB), stage B transcribes them, and the arrays
   are then deleted, keeping only the identity record and the per-key array
   hashes. They are regenerable bit-exactly, because `analyse` is
   deterministic on CPU. float16 is the precision that is applied, and the
   transcript is a deterministic function of the stored arrays.
   Configurations C1-C4 differ only in w(t), so they share one stage A.
   Stage B (shared GPU lease): Parakeet transcribes with `model.preprocessor`
   replaced by `lfspk.extract.nemo_hook.MaskedPreprocessor`. This drop-in
   module wraps NeMo's own preprocessor: forward(input_signal, length) first
   runs it, then replaces each item's features with `apply(...)`, after the
   caller has set that batch's stored mask outputs and configuration.
   **Bypassed recordings are not sent to stage B**: their entry in the
   front end's ASR cache is B's cached transcript, copied and flagged
   `bypass` (r2 #2). The copy is pinned to its source (r3 #1):
   - The front end's cache identity includes B's cache identity hash, the
     SHA-256 of B's `.meta.json` identity (model and its hash, decoding,
     NeMo version). B's ASR identity must equal the one stage B runs with,
     or the front-end cache is refused.
   - Each copied entry stores B's key, B's audio SHA-256 and `record_digest`
     of B's record (r4 #1). One shared function,
     `lfspk.extract.cachepin.record_digest(record)`, is used for both writing
     and checking. It is the SHA-256 of
     `json.dumps({"key", "audio_sha256", "text", "words"}, sort_keys=True,
     separators=(",", ":"), ensure_ascii=False).encode("utf-8")`. It covers
     exactly those four fields, taken from the record as the cache's JSONL
     parser returns it:
     - `words` keeps its order as the list of [word, start, end];
     - the floats are serialised by Python's shortest round-trip repr, so
       each value is exactly what the cache holds;
     - there is no further rounding, no text normalisation, and no other
       field.

     Planned tests: the same record with its fields in another order hashes
     equal; a change to only one word's timestamp hashes differently, and so
     does a change to only one word's text.
   - The audio hash must equal the frozen set's hash for that mixture.
   - On every load (metrics, export, apply), each copied entry is re-checked
     against the current B cache. A missing record, a changed record hash or
     a changed B identity makes the front-end cache stale. It is refused and
     cannot be used until the stale bypass entries are re-copied, so a
     rebuilt B can never sit in a paired L+/G comparison next to an old copy.
   - A unit test changes one B record's text and, separately, B's identity,
     and checks that both are refused. It also checks that an unchanged B
     loads.

   Any item whose `apply`
   returns None inside the hook keeps NeMo's tensor (defensive; the caller
   should already have removed it). A unit test feeds unequal-length batches
   that mix bypassed and masked items. It checks that each item's features,
   returned lengths and padding frames equal those of the same item processed
   alone: masked features equal `apply` on that item alone, bypassed items
   equal NeMo's per-item output, and frames past each length are NeMo's
   padding value. Batch-context effects on masked items remain, because the
   preprocessor and encoder reduce over padded shapes. They are a harness
   artefact, absent from LocalFlow's single-recording path, and are **not
   quantified** by this design (r3 #2). Stage 0's "baseline batching
   sensitivity" (section 9.0) measures only unmasked B. An optional
   exploratory replay (section 9.3) gives a partial check for the selected F.
   W5 also supplies
   a parity diagnostic at log_mask = 0 (section 9.0). The ASR cache is keyed
   by (stage-A identity hash, configuration, mixture), and its identity is
   extended by the ASR weights (`base` or `m1`), the hook's code hash and the
   batching mode. That mode is `batched` (W0's length-sorted batches,
   batch size recorded) for every headline artefact, and `single` only for
   the replay of 9.3 (r4 #2). B*
   is the same path with log_mask = 0 and no bypass (no stage A).
3. The metrics of 9.2 for transcript-changing systems, all relative to B:
   R, gross target-word loss L+, gain G and unreachable-by-filtering gain G_u
   by reference-word identity (budgets
   on L+ only), net L, E, "other" insertions, dWER_S0, dropout, per region,
   with W0's exact re-aligned accounting, the joint speaker bootstrap,
   half-A-fitted quantities held fixed in half-B resamples, and paired
   comparisons against B and a word filter, with W's tau fitted on half A per
   pairing (equal L+ budget, or matched half-A dWER_S0, with the infeasible
   case reported). B* - B is reported as a diagnostic.
4. Stacking (optional): the word-filter rule applied to a front end's
   transcript with saved frame scores, tau calibrated on half A to the joint
   L+ budget relative to B.
5. A new frozen pair `noise-dev-v1` / sealed `noise-test-v1` (9.4).
6. CPU latency for front ends in W0's CPU_ENV subprocess: `analyse` plus
   `apply`, median and p90 per audio second, beside Parakeet's encoder measured
   the same way.
The S0 guardrail for front ends is the non-inferiority of H5 (CI upper end
below +0.10 points against B, the Bonferroni-adjusted interval of 9.3). A front
end whose bypass returns the original features can meet it on bypassed
recordings by construction; a word filter, which removes about 0.5-1 % of S0
words at its budget, cannot.

## 11. What would change our mind, and stopping rules

- Stage 0 stop rule triggers (9.0): stop and report to the orchestrator.
  The conclusion is limited: the raw clipped ratio-mask surrogate does not
  work with Parakeet on held-out-train mixtures. That is not proof that no
  feature mask can beat word filtering. Continuing would need the
  orchestrator's decision.
- H4 not supported on S4 (R1 within the CI of R2): the mask is a near-field or
  channel enhancer, not a speaker model; report it as such and do not claim
  speaker extraction.
- No configuration passes the half-A guardrail and budget: not shippable as
  tested; report, and propose mid-encoder conditioning only with the
  orchestrator's approval.
- H5 not supported on half B, or F (T2) shows a WER increase against B in a
  noise band whose 95 % CI excludes 0: the safeguard is insufficient. The
  result is reported as harmful in that condition, whatever it does
  elsewhere.
- Neither H1a nor H1b is supported, and H2 is not supported: W5 does not beat
  word filtering, and stacking (H8) is the only remaining question.
- Cost: M over the latency budget -> S; S over the budget -> report and stop.
- Training: a run that diverges (non-finite loss) is restarted once from its
  last checkpoint with the same seed; a second divergence is reported, not
  re-tuned.
- Profile-direction check (section 8) fails: build the windowed bank before
  training (a change of data, not of the experiment).

## 12. Later options (out of scope unless the orchestrator approves)

- Mid-encoder conditioning: W2 found speaker identity in encoder taps 6-8
  (tap 7 EER 3.4 % base, 3.9 % m1 at 2 s) and the shipped Core ML encoder is
  hand-built MIL, so a FiLM at tap 7 is conceivable; it changes what the app
  runs (a modified encoder graph), so it is not attempted here.
- Fine-tuning or conditioning Parakeet's encoder; waveform-domain separation.
- The mask as a frame scorer for W0's word rule (target-energy share per
  frame); chunked (15 s, compacted) evaluation as LocalFlow runs it.

## 13. Risks and confounds

- Channel shortcut: each LibriSpeech speaker has a recording chain; R1 vs R2
  and the cross_project / same_project split are the checks; real shared rooms
  (AMI) are not covered.
- Simulated rooms, colourings and levels (W0's caveats apply).
- Feature artefacts: a mask can create spectral holes that Parakeet turns into
  deletions or hallucinated words. "Other" insertions, gross loss L+ and gain
  G are reported for this reason.
- Train/eval conditioning mismatch (bank vs W1 windowed profiles): checked
  (section 8).
- Parakeet `base` and `m1` both trained on data including LibriSpeech train
  audio; dev speakers are unseen by both, and the mask never sees dev.
- Whole-recording vs per-chunk processing (section 3).
- 73 dev speakers, 36-37 per half: wide CIs; differences inside them are
  reported as not resolved.

## 14. Stages and review gates

Each stage's design and code are reviewed in the sol loop (the orchestrator
relays) before anything in it runs at scale; before a stage closes, only unit
tests and smoke runs of a few minutes on tiny data.
1. **D**: this document.
2. **I** (implementation): `frontend.py` (mel power, `apply`, parity with W3's
   front end and NeMo), `nemo_hook.py`, `data.py` (W0 adapter keeping
   components, targets, held-out speakers, N family), `model.py`, `losses.py`,
   `train.py`, `oracle.py` (stage 0), `api.py` (front-end protocol and
   factory), `cost.py` (analytic MACs, flop-counter check, Parakeet encoder
   MACs); tests `tests/test_W5_*.py`.
3. **0**: the contaminator audit and overlay bank (section 8), the
   profile-direction check (section 8) and the stage-0 feasibility screen
   (9.0) on held-out train speakers. Results go to the orchestrator before
   training.
4. **T**: step-budget smoke (amendment), R1 x 3 seeds, R2, R3; theta_b per
   checkpoint; R4 only if R1 passes the half-A guardrail later.
5. **E**: after the contract amendment and W0's extension; W5's evaluation
   glue reviewed; dev runs; RESULTS.md. The sealed test sets are run only by
   the orchestrator.

## 15. Packages

None beyond the shared venv (torch, NeMo via `./python-nemo` for Parakeet,
W0/W1/W2/W3 modules imported unchanged).

## Amendments

- 2026-10-22 (clarification, no change of method; W0's noise-set review):
  section 9.4's "over DEMAND dev ambience" is imprecise. Each noise-dev-v1
  mixture keeps its paired dev-v1 S0 render exactly (target gain and S0
  ambience). That ambience is DEMAND or SLR28 isotropic noise; SLR28 covers
  about 40 % of the groups. The manipulated factor is only the added MUSAN
  noise or no-vocals music at SNR 20/10/5/0.
- 2026-10-22 (before stage T; sol implT-r1). The held-out monitor (section 8)
  is computed after training on the final checkpoint, not during training. It
  never feeds a choice, so only its timing changes. Its 200 renders per
  family use held-out speakers in every role. Its contaminated enrollment
  profiles come from a held-out-only bank overlay (scope "heldout"): every
  contaminated twin of a held-out speaker is re-rendered with held-out
  contaminators.
- 2026-10-23 (before stage T; the step budget pre-registered in section 8):
  measured on the train smoke `w5-train-smoke`.
  - Configuration: R1, size M, batch 32, 8 s crops, 3 render workers, CUDA
    with deterministic algorithms, gpu:shared, host memory capped at 16G.
  - Steps: 60, startup included, so the measured time per step slightly
    overstates the steady state and the budget is conservative.
  - Results: 0.819 s per step. VRAM: peak torch-allocated 0.753 GiB, and
    2.94 GiB peak process VRAM (CUDA context included); peak host memory
    7.87 GiB.
  - Data-wait fraction 0.91: training is render-bound. Its speed therefore
    depends on host CPU load, which a 60-step sample measures only roughly.
  - 13,000 steps x 32 = 416,000 training examples per run.
  - GPU resume check (4 steps, interrupted at 2 and resumed):
    bit-identical true, max weight difference 0.0.
  - Budget rule: the largest multiple of 1000 steps that fits about 3 h of
    wall time at that rate, giving **13,000 optimiser steps for every
    run** (R1 s0/s1/s2, R2, R3).
  - The rate was measured with 3 workers, not 6 (host memory: measured peak
    10.1 GiB with 3 workers), so every run uses 3 render workers.
  - The step count is fixed. If shared-host contention or two concurrent
    runs slow a run down, it takes longer than 3 h, but its step count does
    not change. VRAM lease per run: gpu:shared 4G, against 2.94 GiB measured
    process VRAM; host cap 16G, against 7.87 GiB measured.
- 2026-10-23 (orchestrator decision; before any dev evaluation of any trained
  W5 checkpoint): the conditioning profile is fixed. This replaces section
  8's "norm=<W1's Stage D choice>" with
  `lfspk.embed.factory:make(embedder="redimnet2-b2", rule="robust",
  norm="raw", head="score", window="1.5", hop="0.25", C="1.0", cache="0")`.
  These are the existing defaults of `lfspk.extract.harness_frontend.make`,
  so no code changes.
  - Reason: W1's binding Stage D selection needs its full
    48-configuration grid, about 3 days away, and W1's evidence already
    available is enough to fix the norm:
    - Stage A: AS-norm gave no reliable gain for redimnet2-b2.
    - Stage C: at the 50 % spouse condition over the long horizon, AS-norm
      gates admitted more spouse dictations than raw gates (9-11 % vs
      4-8 %).
    - W5's profile-direction check passed under raw (RESULTS).
  - Scope: raw fixes the conditioning of the front end F only. Every word
    filter W, including the W inside F+W, keeps its independently selected
    W1 or W3 configuration (section 9.3).
  - All confirmatory claims (H1a, H1b, H2, H5) use norm=raw.
  - asnorm sensitivity:
    - If W1's final selection is asnorm, an asnorm evaluation of W5 is
      exploratory only.
    - It runs only after a separately reviewed procedure for
      post-registration exploratory runs exists, because the harness's
      eligibility and run-ledger machinery would otherwise let an
      `--exploratory` run of the registered checkpoint block later raw
      confirmatory reports. Nothing for it is built now.
    - The profile-direction check is repeated under asnorm before any such
      evaluation.
  - Ordering:
    - This amendment's commit must be an ancestor of the `REGISTER
      confirmatory-checkpoint R1-s0` anchor commit.
    - R1-s0 gets no dev use of any kind before that anchor exists.
  - Audit basis for "before any dev evaluation", checked at HEAD a6babc2:
    - Run roots checked: runs/W5/ and runs/W0/frontend/.
    - runs/W5/: no masks/ directory exists. runs/W5/train/ holds only
      smoke/, so no R1-R3 run directory exists yet.
    - runs/W0/frontend/LEDGER.jsonl (12 lines, sha256
      a5e20d98be9af067419d514fc789d69bb487074ba5613ada2fed9c7c00f8b39f)
      records only W0F's exploratory harness smokes on `dev-v1-smoke`:
      - five stage-A/B start/complete pairs with W0F's synthetic
        identity-mask checkpoint (sha256 1a64e922...f679, built for the
        smoke under runs/W0/frontend/smoke/identity-mask, never trained);
      - one B* pair without a checkpoint.
    - No trained W5 checkpoint appears.
  - What exists so far is of two kinds:
    - Held-out train speakers only: the stage-0 feasibility screen (oracle
      masks, so no profile is involved) and the profile-direction check.
    - Train-split speakers only (held-out speakers excluded): the train
      smoke (60 steps) and its 4-step GPU resume checks, the only trained
      W5 weights so far.
- 2026-10-23 (orchestrator decision, for throughput; before any dev
  evaluation of any trained W5 checkpoint): render workers go from 3 to 8.
  - R1-s0 trained steps 1-2000 with 3 workers. It was stopped after its
    step-2000 checkpoint (last.pt, step 2000, all weights finite) and resumed
    from it with 8 workers.
  - R2, R3, R1-s1 and R1-s2 run with 8 workers throughout.
  - Reason: W1's grid was paused, which freed host CPUs. The 3-worker run was
    render-bound (data wait about 89 %, 1.38 s/step on a host at load 38 on
    32 cores).
  - The example stream does not depend on the worker count:
    - Example k is ExampleSource.example(seed, k), with per-(seed, index)
      RNG streams.
    - Batches are consumed in global index order with bounded prefetch.
    - Crops use default_rng([seed, step, 99]).
    - Sol implT-r1 reviewed this. `workers` is a declared safe field of the
      resume identity.
  - Measured: the first 20 batches of R1-s0's stream (32 examples each),
    the examples plus the prepared batches (features, ideal masks, labels,
    valid masks, profiles), are bit-identical with workers=3 and workers=8
    (w5-stream-invariance, 2026-10-23, script
    runs/W5/drafts/stream_invariance_check.py, outside git, sha256
    3ef9eeeac2fbcedde59268a59a53039ce88691f6ffe10797c642b9680eea8dea, run
    against HEAD b9132c8 with lfspk/extract, lfspk/pvad and lfspk/harness
    clean against it; result digest
    a2b5d08e95d74bbf9a0de189f74908ca61f11819b924a7f387e37d5ff35cc2c8,
    identical for both).
  - The GPU resume check was bit-identical, as recorded in the step-budget
    amendment.
  - Unchanged: 13,000 steps per run, batch 32, every hyperparameter, and
    gpu:shared 4G.
  - Changed:
    - The host memory cap goes from 16G to 24G. The check's process tree
      (main process plus 8 render workers, CPU only) peaked at 14.5 GiB;
      the training process adds the model, optimiser and CUDA context.
    - The wall time per run is now no longer the step-budget smoke's
      3-worker rate. The step count is unchanged.
- 2026-10-23 (owner decision; closed after sol review r1-r3 and orchestrator verification): post-hoc method
  amendment. R1-s0 is superseded as the confirmatory checkpoint and a
  screened fix is trained. The owner decided AFTER seeing held-out-train
  evidence and BEFORE any dev outcome existed.
  - History of the superseded checkpoint (sha256 87dc3765...6888, anchor
    f46c010):
    - Dev stage A produced 770 masks of dev-v1 (headline condition
      builtin-clean-10) from two incomplete starts in W0F's ledger (run ids
      270dfb61... and 11e5a428..., 10:28 and 10:44 UTC).
    - These masks are quarantined, unscored and uninspected, in
      runs/W5/masks_quarantine_R1-s0_20261023/ (QUARANTINE.json; listing
      sha256 37a2ee63...b8ae8).
    - No stage B, no transcript and no metric of R1-s0 exists on dev or
      test.
    - R1-s0, R2-s0, R3-s0 and R1-s1 (step 11000, stopped) are exploratory
      from now on.
  - Held-out-train evidence: the monitor set, 48 held-out train speakers,
    notes in runs/W5/notes/.
    - Fraction of the oracle T2 mask's suppression reached, all renders:

      | run | S1 | S2 | S4 | S3 |
      |---|---|---|---|---|
      | R1-s0 | 4.5 % | 8.4 % | 5.3 % | 59 % |
      | R2-s0 (unconditioned) | 3.6 % | 7.4 % | 3.7 % | 59 % |

    - So the profile adds about 1-2 points, and S3 is channel-driven.
    - R3 (T1, the same head, initialisation and alpha) reaches 22-39 %.
    - Mask pre-activations sit in the sigmoid's saturated tail:
      sigma(z) > 0.99 in 78-99.8 % of bins.
    - Along the oracle direction, the training loss falls from 3.10
      (identity) through 1.75 (a quarter) and 0.78 (half); R1-s0 stands at
      2.60.
    - Reading: the profile is barely used, and under that uncertainty the
      alpha = 10 loss favours pass-through. The saturated head is present
      but not shown to be the cause.
  - Screen: exactly 8 runs, R1 seed 0 settings except the factor named.
    There are no combinations. If no variant passes, W5 reports that and
    stops; any further variant needs a new amendment.
    - V0: control.
    - VA: linear head, log m = clamp(z, log g_min, 0) (torch.clamp; the
      gradient d(log m)/dz is 1 inside [log g_min, 0], bounds included, and
      0 outside). Weights start at 0 and the bias at -0.05, approximately
      the existing initial log mask of -0.0462. The head type is serialised
      in the model config, and configs without it load as sigmoid.
    - VB: alpha = 3 instead of 10.
    - VC: absent-target probability p_absent = 0.5 in total, replacing the
      5 %.
      - The conditioning profile is drawn with the train-only,
        overlay-corrected draw_impostor, which excludes the held-out
        speakers and every speaker of the mixture.
      - The T2 target is the noise image only.
      - The aux labels are the activity of every remaining voice.
      - Target-present S0 and N keep the identity target (y* = mix).
    - Unconditioned twins V0u, VAu, VBu and VCu (conditioning none) see
      identical mixtures, absent flags, targets and labels, with the
      profile zeroed.
    - Budget: 6,500 steps per run, batch 32, 8 render workers, warm-up of
      1000 steps, then cosine decay over the remaining 5,500. These four
      values are fixed in each screen run's configuration, and any other
      value is refused. This is a
      compressed schedule relative to the 13,000-step runs, stated
      explicitly. Failure means failure within this budget. About 6.5
      GPU-hours serial.
  - Measurement, frozen now:
    - Script: runs/W5/drafts/monitor_reference.v3.py, sha256
      eae20c1056ca96591ba9fecb092242020b008590c51743e7938d4b611f4fffe2,
      outside the repo, run against the screen's committed code.
    - Data: the held-out monitor set, render identity sha256
      9f2143e980d1a2822650eab6853f924ed6f6d78846643337b978f1db7bc8f65d
      (1,200 renders, 200 per family).
    - Groups: "<family>/present", "<family>/absent" and "<family>/all".
    - Aggregation:
      - per render, the mean over valid (t, f) bins of the squared log-mask
        error against the T2 oracle, split into under- and
        over-suppression;
      - per group, the mean over its renders;
      - frac = 1 - under(V) / under(identity mask), on those means;
      - tail = the 99th percentile over renders (numpy "higher") of the
        per-render over-suppression.
    - The 48-speaker held-out-train pool is train-only selection and
      calibration data, shared with theta_b and the profile-direction
      check. Dev confirmation stays independent of it.
  - Acceptance gates, fixed before any screen run, all on target-present
    groups ("<family>/present"):
    1. frac >= 0.20 in each of S1, S2 and S4. 0.20 means a 20 % reduction
       of the identity mask's under-suppression squared error.
    2. S3 non-regression: frac(S3) >= 0.45 (R1-s0: 0.62).
    3. over-suppression mean <= 0.010 nats^2 in each family; on S0, <=
       0.001 and a tail <= 0.01.
    4. identity gain: frac(V) - frac(V's twin) >= 0.05 on S4.
  - Reported, not gating: the absent-target frac per family, the u frame
    AUC, and the interfering-frame share.
  - H5, the transcript-level clean-speech guardrail on dev, is unchanged
    and independent of this screen.
  - Selection: among V in VA, VB, VC that pass gates 1-4, the first in
    that order (simplest first). V0 is the control and is not selectable.
  - Supersession, a prerequisite for running the chain:
    - W0F's supersession patch must close review and be committed first.
    - One dedicated SUPERSEDE commit on RESULTS.md changes exactly one line
      out and two in (the placeholder and the superseded-checkpoint line).
      The old anchor and W0F's ledger are preserved.
    - A separate commit adds a supersession note citing this amendment. No
      other RESULTS.md line begins with either checkpoint keyword.
    - The selected change is retrained at the full 13,000 steps as R1 seed
      0, with `recipe` = the screen winner (VA, VB or VC). The run label
      stays R1, so identity() reports run R1 / seed 0 and the checkpoint
      stays eligible for registration. A matching R2-s0 is trained with the
      same recipe.
    - `recipe` is a training-config field of R1 and R2 only, recorded in the
      training identity. Its default V0 is the original behaviour, and each
      other value applies exactly that screen run's factor. It was fixed
      before any screen outcome, so no code changes after the screen.
    - The new checkpoint is registered with a new REGISTER commit (a new
      sha) before any dev use. theta_b is recomputed for it on the theta
      set, and the C1-C4 configurations and cached-B bypass behaviour are
      unchanged.
  - Review: sol lfspk-W5-fix r1, r2 and r3 (r1: 3 high, 4 medium, 1 low;
    r2: 4 medium on the patch; r3: 1 medium, 1 low on the patch), all
    fixed. The orchestrator verified r4 (patch screen_variants.r4.patch,
    sha256 d0a62b46...c24c). Closed at amendment sha256 554608e1...aaa.
