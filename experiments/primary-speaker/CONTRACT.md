# Primary-speaker detection: shared contract

Owner: the orchestrator (the main session). Workstreams change this file only
through the orchestrator. Questions about it go to the orchestrator, not to a
guess. Implementers record authoritative field lists and formats they define in
the `NOTES` section at the bottom (append-only, dated, with the author's
workstream).

## Goal

LocalFlow dictation on macOS (first), later iOS and Linux, should silently drop
words that were spoken by someone other than the user while the dictation key
was held. The situations the user actually meets:

- **office chatter**: one to three other people talking at a distance;
- **TV**: broadcast speech and music from a loudspeaker in the room;
- **call audio**: the far end of a call playing from the laptop's speakers,
  close to the microphone, band-limited and codec-coloured;
- **second dictator**: another LocalFlow user (the user's spouse) dictating on
  their own machine 1-3 m away, often at the same time, at similar loudness.
  Both are adults, possibly of the same sex.

The user's own words matter more than removing other people's: dropping one of
the user's words is worse than keeping a stray word. A scorer that harms clean,
single-speaker dictation is not shippable, whatever it does elsewhere.

The voiceprint must stay small, adapt in the background from the user's own
dictations without stored audio, and be protected so that a stolen profile
does not let anyone reproduce the user's voice (workstream W4).

## Interface

`lfspk/api.py` is the contract: `TargetSpeakerScorer` (`enroll`, `update`,
`score`, `cost`), `Profile.to_bytes`, `CostReport`, 16 kHz float32 audio,
10 ms frames. Read its docstrings. Every approach (W1, W2, W3) delivers one or
more scorers implementing it, registered by name in the harness.

## Splits

`lfspk/splits.py`: LibriSpeech train-clean-360 = train (921 speakers),
dev-clean + dev-other = dev (73), test-clean + test-other = **sealed test**
(73). dev-other joined dev on 2026-10-21, before any real dev evaluation, so
that dev halves each hold enough cross-project speakers; dev and test now have
the same make-up. `paths.LIBRISPEECH` is one root of symlinks covering every
subset. An auxiliary split, `clone_eval` = train-clean-100 (251 speakers,
`splits.AUX_SUBSETS`, deliberately outside `SPLIT_SUBSETS`), was added on
2026-10-21 by owner decision, solely as extra target speakers for W4's
cloning-risk bound; nothing may train, tune or choose on it. Other corpora used for evaluation
must have an equivalent train / dev / sealed split that is recorded in NOTES
before anything is scored on them (AMI: its official train/dev/eval meetings).

Sealed means: no scoring, listening, inspecting per-utterance outputs or tuning
on test speakers or test meetings during development. The orchestrator runs
the final comparison once per frozen configuration. A workstream that thinks
it needs a test-set number asks the orchestrator.

## Benchmark (W0 owns the implementation)

### Scenarios

Each scenario is a family of deterministic, seeded mixtures. A frozen scenario
set is a manifest plus rendered audio under `/mnt/hd/localflow-speaker/data/`,
identified by a content hash recorded in NOTES; results always cite that hash.

| id | interferer | geometry and level | overlap |
|---|---|---|---|
| S0 | none (room noise only) | target near field | none: the guardrail |
| S1 office | 1-3 distant LibriSpeech speakers + MUSAN noise | interferers far field, reverberant | partial |
| S2 TV | MUSAN speech/music with vocals, or LibriSpeech, through a loudspeaker colouring | far field, continuous | continuous |
| S3 call | LibriSpeech through a telephony/VoIP channel (band limit, codec-like distortion, small-speaker colouring) | close to the mic, can be louder than the user | mostly turn-taking |
| S4 second dictator | one LibriSpeech speaker, >= 50 % same sex as the target | 1-3 m, similar level | frequent overlap |

W0 chooses the exact level ranges (signal-to-interference ratio), room impulse
responses, microphone colourings and overlap statistics. It documents them,
justifies them from the literature or from measurements of real laptop
microphones where possible, and gets them reviewed before freezing. The target
is always near field, as with a laptop's built-in microphone. Each scenario
also has a **device-mismatch** variant: the profile is enrolled under one
microphone colouring and tested under another (built-in mic vs headset).

### Frame labels

Every 10 ms frame of a mixture is labelled from the clean source signals before
mixing: `0` no speech, `1` target only, `2` interferer only, `3` target and
interferer overlap. W0 defines how speech activity is decided from each clean
source (forced alignment or a fixed activity rule) and documents it.

### Enrollment protocol

For each target user the harness builds a stream of that speaker's own
utterances, disjoint from the utterances used in test mixtures. A chapter is
not a recording session: a speaker's chapters often share one LibriVox project
(CHAPTERS.TXT), and so probably one microphone and room. Enrollment therefore
comes from a different project than the test target utterance where the
speaker has more than one, otherwise from a different chapter; each target is
flagged `cross_project` or `same_project_cross_chapter`, and results are
reported both ways. The scorer sees `enroll(first k)` and
then `update` for each further dictation, in order. A fixed fraction of
enrollment dictations (0 % and 20 % conditions) are themselves contaminated
with S4-like interference, because real dictations sometimes are. Results are
reported after 3, 10 and 30 dictations.

### Word-level decision rule (identical for every scorer)

The harness transcribes each mixture once with Parakeet TDT 0.6B v2 (word
timestamps), caches the hypotheses, and keeps a hypothesis word iff the mean
score over its frames is at least the threshold `tau`. A word's frames are its
Parakeet timestamp span widened by 80 ms on each side (one Parakeet encoder
frame), clipped to the recording. Amended 2026-10-21, before any scorer was
evaluated: on dev-v1, 0.64 % of correctly recognised target words had
Parakeet spans lying wholly in labelled pauses, so the unwidened rule removed
them for every scorer, the oracle included. The widening applies identically
to every scorer and to the oracle, and mirrors what LocalFlow would have to do
with the same timestamps. Oracle ceilings are also reported at 0, 50 and
200 ms widening as a sensitivity check. `tau` is set per scorer
on **dev** so that the words filtering removes from correctly recognised
target words is at most **0.5 %** of target reference words, pooled over all
dev scenarios including S0. Scorers are therefore compared at equal cost to
the user.

### Metrics (all reported per scenario, overlap vs non-overlap, and pooled)

- Target WER before filtering, after filtering, and with oracle frame labels
  (the ceiling).
- Interferer words kept: hypothesis words aligned to the interferer that
  survive filtering, as a fraction of those present before filtering. **This
  is the primary metric**, at the 0.5 % budget.
- Target words removed by filtering (the budget, checked on every scenario,
  with S0 reported separately: the S0 increase in WER must stay below 0.1
  points absolute). Amended 2026-10-21: the pooled 0.5 % budget and the
  0.1-point S0 guardrail can conflict, since a scorer that spends its budget
  evenly removes about 0.5 % of S0 words. The S0 increase is therefore a
  reported guardrail metric, with its CI and the oracle's value beside it, not
  a hard pass/fail; a scorer whose S0 increase is materially above the
  oracle's is flagged. Whether a shipped product needs a separate clean-speech
  safeguard is a product question for the owner.
- Frame-level ROC AUC and equal error rate for target-speech vs
  interferer-only frames.
- 95 % confidence intervals by bootstrap over speakers, not utterances,
  resampling all roles jointly: each resample draws one speaker set, and a
  mixture (or verification trial) counts, with multiplicity, only when every
  speaker it involves (target and interferers; enrollment and test) is drawn.
- A configuration chosen as the best of several on dev speakers is reported
  with that selection accounted for (held-out dev half, or labelled
  exploratory), never as if it had been fixed in advance.
- Results after 3, 10 and 30 enrollment dictations, clean and contaminated
  enrollment, matched and mismatched device.
- `CostReport` and measured CPU latency per second of audio.

A real-acoustics check set (AMI headset and distant microphones, with real
crosstalk) complements the synthetic scenarios if W0 can build it with honest
labels; it uses AMI's own meeting split.

### Front ends that change the transcript (amended 2026-10-21, W5)

Amended by owner decision before any front end was trained or evaluated. On
dev-v1, the oracle word filter keeps every interferer word in an overlap
region, which leaves 18.5 % of interferer words pooled over S1-S4. The owner
therefore asked for an approach that separates overlapping speech, and noted
it may also help in general noise. W5 delivers a speaker-conditioned mask on
Parakeet's mel power, placed in front of the unchanged ASR. A front end
changes the transcript instead of dropping words, so the word-level decision
rule above does not apply to it. Its normative specification is W5's
`lfspk/extract/DESIGN.md` §9-10 at commit f7d74ba (sol-reviewed, five rounds,
closed clean). In summary:

- **Interface.** `FeatureFrontEnd` (`enroll`, `update`, `analyse`, `cost`) in
  `lfspk/extract/api.py`, plus a pure `apply()` that returns `None` on bypass.
  On bypass the harness uses B's cached transcript, pinned by identity and
  record digest, and never a recomputation.
- **Baseline.** All claims are relative to B: the unchanged Parakeet path,
  the harness's existing ASR cache. B* (the mask path at mask = 1) is
  diagnostic only.
- **Metrics.**
  - R: interferer words in the output, relative to B.
  - Gross target-word loss L+, by reference-word identity. All budgets apply
    to L+ only.
  - Gain G, and unreachable-by-filtering gain G_u.
  - Net L, E, "other" insertions, dropout and dWER_S0.
  - All use W0's exact re-aligned accounting and the joint speaker bootstrap.
- **Clean-speech guardrail.** Non-inferiority: the upper end of the
  Bonferroni-adjusted paired CI of dWER_S0 against B must be below
  +0.10 points. This is stricter than the reported-only guardrail for word
  filters, and is possible because bypass returns the original features.
- **Comparison with word filters.** Run on dev half B, with half-A-fitted
  quantities held fixed. The word filter is chosen per pairing on half A,
  either at an equal L+ budget or at matched half-A dWER_S0. The infeasible
  case is reported as such.
- **Confirmatory family.** {H1a, H1b, H2, H5}, half B only, 98.75 % CIs.
  Everything else is exploratory.
- **Noise-only check.** A new frozen pair, `noise-dev-v1` and the sealed
  `noise-test-v1`: dev/test targets with MUSAN noise or music at SNR 20, 10,
  5 and 0 dB. W0 builds it under the same freezing rules as dev-v1/test-v1.
  Each mixture is its paired dev-v1/test-v1 S0 render, unchanged, plus the
  added MUSAN source. The target gain and the S0 ambience (DEMAND or SLR28
  isotropic noise) are inherited from that render, so the only manipulated
  factor is the added source.
- **Who builds what.** W0 implements the harness side (`evaluate frontend`,
  the two-stage cache, the metrics). W5 supplies the hook, `apply`,
  `cachepin` and their tests. Both go through the sol loop.

## Workstreams

| id | owner directory | deliverable |
|---|---|---|
| W0 | `lfspk/harness/` | data preparation, scenario generator, frozen dev scenario sets, the ASR cache, the evaluator, baselines (keep-everything, oracle, energy-only) |
| W1 | `lfspk/embed/` | approach 1: pretrained speaker-embedding models, profile plus cohort score normalisation, online adaptation that resists contamination, a small calibration head |
| W2 | `lfspk/probe/` | approach 2: how much speaker identity each Parakeet encoder layer carries, and a scorer reading Parakeet activations if one is viable |
| W3 | `lfspk/pvad/` | approach 3: a personal VAD (frame classifier conditioned on the profile), trained on synthetic mixtures from the train split |
| W4 | `lfspk/protect/` | voiceprint protection: threat model, on-device storage design for macOS, and measured invertibility of profiles before and after protection transforms |
| W5 | `lfspk/extract/` | approach 4: speaker-conditioned target-speech extraction, a mask on Parakeet's mel power in front of the frozen ASR, trained on synthetic mixtures from the train split (added 2026-10-21) |

Each workstream writes `DESIGN.md` (hypotheses, method, what would change our
mind) before running experiments and `RESULTS.md` at the end, both in its
owner directory. Code reads paths from `lfspk/paths.py`. Run outputs go to
`/mnt/hd/localflow-speaker/runs/<workstream>/`.

## NOTES

(append-only; `YYYY-MM-DD Wn: ...`)

- 2026-10-21 W2: Parakeet encoder tap indices, used in
  `CostReport.reads_parakeet_layers`: `0` = output of `encoder.pre_encode`
  (dw_striding subsampling, 80 ms frames, before positional encoding;
  xscaling is off), `1..24` = output of conformer layer `i`
  (`encoder.layers[i-1]`), so `24` is the final encoder output and is the
  same tensor as `-1`. Encoder frame `j` covers 10 ms frames `[8j, 8j+8)`.
  "Shipped weights" = the ternary export `main-M1-P2-lr5e-4` step 250000,
  SHA-256 `a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503`
  (LocalFlow `Resources/Parakeet/INTEGRATION.md`; macOS/iOS Core ML with FP16
  activations, Linux `lf-cpu` with FP32/INT8-residual activations); W2 calls it
  `m1`, and the NVIDIA FP32 checkpoint `base`.
- 2026-10-21 W2: clarification of the tap entry above: tap `24` (= `-1`) is
  the output of conformer layer 24, which ends in that layer's `norm_out`
  LayerNorm; this config has no encoder `out_proj` (`feat_out = -1`), so it is
  exactly `ConformerEncoder`'s returned output (transposed), before the joint
  network's encoder projection (1024 -> 640). Each tap `i` in `1..24` is
  likewise after layer `i`'s `norm_out`.
- 2026-10-21 W4: shared clean-speech embedding cache (draft until W4's sol
  loop on extraction is clean; then announced by the orchestrator).
  `/mnt/hd/localflow-speaker/runs/W4/emb/<embedder>/<split>/` with
  `<embedder>` a name from `lfspk.embed.embedder.available()` and `<split>` in
  {train, dev} (never test). Files: `meta.json` (embedder, weights_sha256, dim,
  split, subsets, crop_seconds, crop_seed, train_limit, select_seed, git_commit,
  command, created UTC); `index.tsv` with header `row utt_id speaker chapter
  sex crop_start crop_len num_samples` (samples at 16 kHz; `crop_start =
  crop_len = -1` means the full utterance); `emb.npy` float32 `[rows, dim]`,
  L2-normalised, row i = index row i. dev = every dev-clean utterance, full,
  plus one 2 s crop per utterance at `lfspk.protect.roles.crop_offset(utt_id,
  num_samples, 32000, crop_seed)` (utterances <= 2 s: crop = whole utterance,
  `crop_start = 0`, `crop_len = num_samples`). train = up to 40 utterances per
  train-clean-360 speaker chosen by `lfspk.protect.roles.select_train_utts(ids,
  speaker, select_seed, 40)`, full only. Reader: `lfspk.protect.embcache.read`.
  Built by `lfspk/protect/extract.py` through W1's `load_embedder`.

2026-10-21 W1: `lfspk/embed/embedder.py` is final at commit 711551d (sol loop:
3 rounds, clean). Interface: `Embedder` protocol (`name`, `dim`,
`weights_sha256`, `params`, `embed(audio) -> float32[dim]`,
`embed_batch(audios) -> float32[n, dim]`, both L2-normalised) and
`load_embedder(name, device="cpu")`. Input: 1-D float32 16 kHz in [-1, 1]
(`api.check_audio`), at least `MIN_SAMPLES` = 3200 samples (0.2 s), else
ValueError. `embed_batch` equals per-item `embed` (grouped by exact length,
never padded). Registered names (dim, params on the embedding path, launcher):
`ecapa-vox` (192, 20.8 M, ./python), `titanet-s` (192, 6.8 M, ./python-nemo),
`titanet-l` (192, about 23 M, ./python-nemo), `wespeaker-r34lm` (256, 6.6 M,
./python), `wespeaker-campp` (512, 7.2 M, ./python), `redimnet2-b0` (192,
1.1 M, ./python), `redimnet2-b2` (192, 3.7 M, ./python). Weights under
`DATA/models/<name>/`, SHA-256-pinned, read once and deserialised from the
verified bytes; `weights_sha256` names what was loaded. Determinism: CPU
repeated calls are bit-identical; CUDA repeated calls are bit-identical
(cuDNN deterministic flags set, process-wide); CPU vs CUDA agree to cosine
>= 0.9999 and max abs difference <= 2e-3 per element (measured worst case:
cosine 0.99996, 1.5e-3 for redimnet2-b0, 2026-10-21). WeSpeaker and ReDimNet2
model code is imported from pinned source archives under private module names
`lfspk._vendor.<tag>`; the public names `wespeaker` / `redimnet2` are never
occupied.
- 2026-10-21 W0: mixing API (draft until W0's sol loop on mixing is clean; the
  orchestrator announces it). `lfspk.harness.mix.MixtureGenerator(split)`:
  `.render(scenario, seed, target=None|Utterance|utt_id, device="builtin"|"headset")
  -> Mixture`; `.speaker_plan(speaker, n_targets=10, n_enroll=30) -> SpeakerPlan`;
  `.enrollment(plan, set_seed, device, contaminated) -> list[Mixture]`;
  `.enrollment_dictation(utt, seed, device, contaminated) -> Mixture`.
  `lfspk.harness.mix.MixtureSampler(split, base_seed=0, scenarios=S0..S4,
  weights=None, p_headset=0.0)`: `sampler[i] -> Mixture` (pure function of
  split, base_seed, i) and `.with_enrollment(i, n, contamination=0.0) ->
  (Mixture, list[Mixture])`. `Mixture` fields: `audio` (float32, 16 kHz, length a
  multiple of 160), `target`, `target_dry`, `interferers` (list), `interferers_dry`
  (list; TV: speech only), `noise` (all float32, same length; `audio == target +
  sum(interferers) + noise` up to float rounding, peak <= 0.95), `labels` (uint8 per
  10 ms frame: 0 none, 1 target only, 2 interferer only, 3 both), `target_active`,
  `interferer_active`, `interferer_actives` (bool per frame), `meta` (JSON-safe:
  split, scenario, seed, device, device_params, target{utt, speaker, chapter, sex,
  text, parts, level_dbfs, rir}, room, interferers[{kind, sir_db,
  sir_measured_db, rir, speaker(s), utts, offsets, channel params}], ambience{snr_db,
  ...}, event, label_fractions, overlap_of_target, index_hashes). A mixture with
  the same seed and target in different scenarios shares target placement, room,
  ambience, levels and device (paired). Activity rule: `lfspk.harness.activity.activity`
  on the dry track (DESIGN.md section 5). Splits of auxiliary corpora (rooms,
  noises, music, us-gov, real RIR rooms): DESIGN.md section 2,
  `lfspk/harness/corpora.py` (`REAL_ROOM_SPLIT`, `split_by_hash`), index files
  under `/mnt/hd/localflow-speaker/data/harness/index/v1/` and room banks under
  `.../data/harness/rirbank/<split>/`; mixture meta records their SHA-256.
  Enrollment relation flags per enrollment dictation and per (target, k):
  `cross_project`, `same_project_cross_chapter`, and `same_chapter` (only for
  speakers with a single chapter, utterance-disjoint; excluded from headline
  numbers and reported separately). Multi-chapter speakers never enroll from the
  test chapter; a short stream is flagged `enroll-short:n` and has no k = 30
  result. dev: k = 10 relation counts cross_project 19, same_project_cross_chapter
  11, same_chapter 9, too short 1 (of 40 speakers).
- 2026-10-21 W1: profile format (`lfspk/embed/profile.py`, `EmbProfile`;
  draft until W1's Stage B/C sol loop is clean). `Profile.to_bytes`, little
  endian: magic `LFW1` (4 bytes), format version uint8 (1), embedder code
  uint8 (1 ecapa-vox, 2 titanet-s, 3 titanet-l, 4 wespeaker-r34lm,
  5 wespeaker-campp, 6 redimnet2-b0, 7 redimnet2-b2), dimension uint16 D,
  centroid count uint8 K (W1 uses K = 1; no microphone-route argument exists
  in the scorer API), 3 reserved zero bytes, dictations seen uint32,
  dictations accepted uint32, then per centroid: count n uint16 (saturating)
  and D float16 values of the unnormalised running mean m of the unit
  dictation embeddings folded in (|m| <= 1; scoring uses m / |m|). Size
  20 + K (2 + 2D) bytes: 406 for one 192-dim centroid, 534 for 256, 1046 for
  512. Nothing else is stored: no audio, no per-dictation or window
  embeddings, no second moments, no score statistics.
- 2026-10-21 W4: cache layout revision (supersedes the layout in the earlier
  W4 entry; content and row policy unchanged). Each
  `runs/W4/emb/<embedder>/<split>/` holds immutable generations
  `gen-<id>/{meta.json,index.tsv,emb.npy}` plus a `CURRENT` file naming the
  current id. `meta.json` adds `n_rows`, `index_sha256`, `emb_sha256`,
  `generation` (= first 16 hex of SHA-256(index_sha256 + emb_sha256)),
  `embedder_module_commit` and `librispeech_root`. Generations are never
  modified or deleted by code. Readers: `lfspk.protect.embcache.read(dir,
  generation=None)` resolves CURRENT once, reads each file into memory once,
  verifies its hash and parses those bytes; cite the generation id with
  results. dev covers all 73 dev speakers (dev-clean + dev-other).
- 2026-10-21 W1: profile format change (supersedes the counters and sizes of
  the entry above, per W4's STORAGE.md section 1): dictations seen and
  accepted are uint16 saturating at 65535 (not uint32), and the reserved field
  is 1 byte, so the header is 14 bytes: magic (4), version (1), embedder code
  (1), D uint16, K uint8, reserved (1), seen uint16, accepted uint16. Size
  14 + K (2 + 2D): 400 bytes for one 192-dim centroid, 528 for 256, 1040 for
  512. Counters and counts are allowed only inside the ciphertext.
- 2026-10-21 W0: mixing API revision after review r1 (still draft until the
  mixing stage is clean). Additions to the entry above:
  `MixtureGenerator(split, corpus=None, speakers=None, pin_sources=False)`;
  `.render(..., rir_mode="coherent"|"mixed")`; `.render_paired(scenarios, seed,
  target, device, rir_mode) -> {scenario: Mixture}` (one shared limiter gain:
  target and noise components of paired variants are bit-identical, except S1's
  noise, which has its own SNR range and events, and S3, which re-times the
  target); `.enrollment_streams(plan, set_seed, device, contaminator=None) ->
  (clean, contaminated)`; `MixtureSampler(..., speakers=None, p_mixed_rir=0.0)`.
  RIR modes: `coherent` (primary) = every source in the target's simulated room;
  `mixed` (secondary) = every source, target included, draws other-bank-room /
  OpenSLR 26 / measured with p 1/3 each. Meta additions: `rir_mode`,
  `ambience.snr_total_db` (target over all noise incl. device self-noise; `snr_db`
  is target over acoustic noise = ambience + event), `peak_gain_db`,
  `paired_with`, `sources` (file -> SHA-256, when pinned), `enrollment{contaminated,
  relation, index}`. Auxiliary splits: DEMAND by whole environment (test
  OHALLWAY, dev OOFFICE, train OMEETING DLIVING DKITCHEN DWASHING); LibriVox
  projects are not held out across splits (71 shared train/dev project ids);
  dev results also report targets whose test project never occurs in train.
- 2026-10-21 W0: canonical dev halves, `lfspk.harness.halves.dev_halves()` ->
  {"A": ids, "B": ids}; A (37 speakers) for selection, B (36) for reporting.
  Stratified by subset (dev-clean/dev-other), sex and session class
  (`SpeakerPlan.relation_at(10)`), dealt alternately in stable-hash order. Frozen
  dev mixtures never cross halves; dev enrollment contamination talkers come
  from the other half. A: 84 116 174 700 777 1255 1272 1585 1651 1673 1701 1993
  2035 2078 2086 2803 2902 3170 3536 3576 3663 3853 3915 4572 4831 5849 5895 6313
  6345 6455 6467 6841 7601 7641 7976 8173 8297. B: 251 422 652 1462 1630 1650
  1686 1919 1988 2277 2412 2428 2506 3000 3081 3660 3752 4153 4323 4515 4570 5338
  5536 5543 5694 6123 6241 6267 6295 6319 6599 7697 7850 8254 8288 8842. Dev (73)
  relation at k = 10: cross_project 39, same_project_cross_chapter 17,
  same_chapter 14 (single-chapter speakers, excluded from headline numbers),
  stream shorter than 10: 3.
- 2026-10-21 W0: bootstrap unit. 95 % percentile bootstrap, B = 2000, seed 0,
  over the LibriSpeech speakers of the evaluated set jointly across mixture
  roles (target, office talkers, audible TV programme speakers, call talker,
  second dictator): a mixture's weight is the product of its speakers' draw
  counts; tau is re-calibrated in each resample. The CIs are conditional on the
  fixed, seeded enrollment contamination streams (contaminators not resampled).
- 2026-10-21 W1: profile format version 2 (supersedes the vector precision,
  flags and sizes of the two W1 profile entries above; draft until W1's Stage
  B/C sol loop is clean). Header 14 bytes: magic `LFW1`, version uint8 = 2,
  embedder code uint8, D uint16, K uint8, flags uint8 (bit 0: anchor present;
  other bits must be zero), seen uint16, accepted uint16 (both saturating at
  65535). Then per centroid: count n uint16 (1..65535, saturating) and D
  float32 values of the unnormalised running mean m (0 < |m| <= 1). Then, only
  if flags bit 0: D float32 values of the anchor, a unit vector (the
  enrollment-time direction, never updated; used only by W1's "anchored"
  update rule). Load rejects: unknown flags, n = 0, accepted > seen,
  n > accepted (unless saturated), non-finite values, |m| outside (0, 1],
  |anchor| != 1. Size 14 + K (2 + 4D) (+ 4D with anchor): 784 bytes for one
  192-dim centroid, 1552 with anchor; 1040 / 2064 for 256-dim; 2064 / 4112
  for 512-dim. The anchor is a second speaker-specific vector and needs the
  same protection as m.
- 2026-10-21 W4: the shared clean-speech cache also covers the auxiliary
  split `clone_eval` (train-clean-100; owner decision): directory
  `runs/W4/emb/<embedder>/clone_eval/`, same generation layout and the same
  row policy as dev (every utterance, full and one seeded 2 s crop). It is for
  W4's cloning-risk targets only; other workstreams must not fit, select or
  tune on it. W4's OpenVoice se cache (`runs/W4/ovse/<split>/`) has the same
  layout for train, dev and clone_eval (vectors unnormalised).
- 2026-10-21 W0: activity rule bound (mix review r3): the noise floor is
  estimated from frames >= -70 dBFS of the dry source and clamped to
  [-70, -40] dBFS (as LocalFlow's silence gate), threshold
  min(max(L_hi - 35, floor + 8), L_hi - 15) dB. `Mixture.noise_parts` =
  {"ambience", "event", "self"}, summing to `noise`. REVERB 2014 measured RIRs
  (the only measured family in the mixed RIR mode), counted from the index file
  names: train 14 near + 14 far (7 rooms), dev 2 + 2 (RVB2014_mediumroom2),
  test 2 + 2 (RVB2014_smallroom2).
- 2026-10-21 W0: forced alignments (frame labels; DESIGN.md section 5) are
  complete: /mnt/hd/localflow-speaker/data/harness/align/v1/<split>.jsonl, CTC
  forced alignment with torchaudio WAV2VEC2_ASR_BASE_960H (weights SHA-256
  488fd4f1...945d, MIT). Coverage: train 104014/104014, dev 5567/5567, test
  5559/5559 utterances aligned; 0 failures, 0 Parakeet fallbacks. File SHA-256:
  train 1a8f6cbdd6ac3166..., dev
  eddae63e2818f534..., test
  1e61f09ce562e99d... (full values in mixture
  meta.index_hashes.alignment). Label rule: merge inter-word gaps < 200 ms, pad
  40 ms (lfspk.harness.forced.words_to_frames); sensitivity variant without
  merging stored as labels_nomerge in frozen sets.
- 2026-10-21 W0: frozen scenario sets (lfspk.harness.frozen, rendered at commit
  949504f's mixing code; layout in frozen.py; content hash = SHA-256 of the
  sorted file listing in CONTENT.sha256). dev-v1: HASH
  6d5fd40a4704a810b59295647be6d68a5cbe4c7f1ec210b890351e7441bf8638, 5110 mixtures (73 speakers x 10 targets x S0-S4
  coherent, plus 4 targets x S0-S4 in the mixed RIR mode, ids S*m-), 4898 enrollment
  dictations (built-in and headset, clean plus contaminated twins), mixtures
  within dev halves, contaminators from the other half. test-v1 (SEALED; rendered,
  hashed, never inspected or scored by W0): HASH
  c4a27094c5e3326e0edfb21262e14d952e41dd4779f0062ce8ffa04374ca3f05, 5110 mixtures, 5114 enrollment dictations.
- 2026-10-21 W3: PVAD training enrollment bank (W3-internal; train split only).
  `/mnt/hd/localflow-speaker/runs/W3/emb/<embedder>/bank.npz`
  (`lfspk.pvad.enrollment.EnrollmentBank.load`): `emb` float32 [N, dim]
  unit rows; `speaker`, `utt`, `channel` (W0 device: builtin / headset) str [N];
  `contaminated` bool [N]; `embedder`, `embedder_sha256`. One row per (bank
  utterance, device, clean / contaminated twin from W0
  `render_paired(("S0","S4"))`). Bank utterances: up to 40 per target-eligible
  train speaker (727; LibriVox project, else chapter, split; `same_chapter`
  speakers excluded) from the enrollment pool (`enrollment.partition_speaker`).
  `bank_meta.json` holds the identity (embedder hash, W0 mixer-code and index
  hashes, seed rule). Built: redimnet2-b2, 113,376 rows, sha256 b34c8b68...1801.
  W3 scorer factory for the harness: `lfspk.pvad.harness_scorer:make`
  (`--arg checkpoint=... [update_rule=gated] [recal=...]`).
- 2026-10-22 W0: harness READY: /mnt/hd/localflow-speaker/data/harness/READY.json
  (dev-v1 6d5fd40a..., test-v1 c4a27094..., ASR identity Parakeet TDT 0.6B v2
  sha256 d99e3995..., NeMo 3.0.0; word records built at 5f795f8 with the 80 ms
  decision widening and 0.5 s alignment tolerance). Evaluate on dev:
  `./python -m lfspk.harness.evaluate run --set dev-v1 --scorer MODULE:CALLABLE
  [--arg k=v] [--half A|B|all]`; the sealed test is evaluated only by the
  orchestrator with `apply --calibration <dev run>/calibration.json`.
- 2026-10-23 W0 (W0F): noise-only twin set noise-dev-v1 (`frozen render-noise --pair dev-v1`; DESIGN.md 14.1): HASH
  8677da542fe347f44fe6a57c936e465542f2720ad9488559c89272e707bfaae2 (= SHA-256 of its CONTENT.sha256), 2336 mixtures (73 speakers x 4
  targets x {noise, music} x SNR {20, 10, 5, 0} dB), ids `N<n|m><snr>-<speaker>-<jj>`, scenario `N`. Enrollment: all 4898 enroll/ files
  have the same SHA-256 as dev-v1's (CONTENT.sha256), and enrollment.jsonl is byte-identical to dev-v1's. B: data/harness/asr/noise-dev-v1/
  (asr.jsonl with keys mix: and tdry:, asr.meta.json equal to dev-v1's B identity, words.jsonl from refs.build). Re-draw rates (noise /
  music family): 11.3 % / 3.1 % (RESULTS.md). noise-test-v1 (sealed) is rendered; its HASH follows when its ASR and refs finish.
- 2026-10-23 W0 (W0F): sealed noise-only twin set noise-test-v1 (`frozen render-noise --pair test-v1`; never scored or inspected): HASH
  70e3d2054eac64763eb720bd7e32dec64f8208ac9522108e49c2d8510c41dccc (= SHA-256 of its CONTENT.sha256), 2336 mixtures. Enrollment: all 5114
  enroll/ files have the same SHA-256 as test-v1's (CONTENT.sha256), and enrollment.jsonl is byte-identical to test-v1's. B:
  data/harness/asr/noise-test-v1/ (asr.jsonl, asr.meta.json equal to dev-v1's B identity, words.jsonl), built after the orchestrator
  accepted the noise-family re-draw rate of 21.9 % (above the 20 % check line; RESULTS.md).
